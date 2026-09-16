# programs/

Programas para compi escritos en ensamblador. Se ensamblan con
[`../tools/casm.py`](../tools/casm.py) y se graban en un slot de la flash con
[`../tools/compi_send.py`](../tools/compi_send.py).

| Fichero | Slot | Qué es |
|---|---|---|
| [`demo.asm`](demo.asm) | 4 | Menú principal que llama a rutinas de demostración: gráficos (caja rebotando), texto (máquina de escribir + juego de caracteres), sonido (escala + LED), animación (curva de Lissajous), luces (LED estroboscópico + destellos) y un juego, **ESQUIVA**, que usa todo junto. |
| [`estrellas.asm`](estrellas.asm) | 5 | Cielo estrellado: 16 estrellas en posiciones al azar que titilan (aparecen, crecen a una cruz de 5 píxeles y se apagan) de forma asíncrona. El LED azul se enciende junto con la pantalla cuando alguna estrella está en su brillo máximo. |
| [`cubo.asm`](cubo.asm) | 3 | Cubo de wireframe en 3D girando sobre el eje Y, en proyección ortográfica. Implementa desde cero multiplicación con signo (8×8→16 bits, la CPU no tiene `MUL`) y una línea de Bresenham de propósito general, ya que ninguna existía en el repo. |
| [`reloj.asm`](reloj.asm) | 1 | Reloj analógico de agujas con hora real (latido de 1 s por el temporizador T2, no un contador de fotogramas) y números romanos trazados como líneas. Encoder izquierdo (DIRECCION) ajusta la hora, encoder derecho (DATOS) ajusta los minutos. Reutiliza `smul64`/`line_draw` de `cubo.asm`. |
| [`pong.asm`](pong.asm) | 2 | Pong de dos jugadores: cada encoder mueve la paleta de su lado, y su pulsador saca la pelota (con ángulo según la posición y el sentido de giro de la paleta en ese momento) cuando no hay pelota en juego. Quien gana el punto saca en la ronda siguiente. Marcador en la capa de texto, independiente del framebuffer gráfico. Doble buffer por software igual que `cubo.asm`. |

## Flujo de trabajo

```sh
# 1. ensamblar  ->  bytes hasta la ultima direccion usada (no siempre 64 KiB:
#    ver "Tamano del .bin" mas abajo)
python3 ../tools/casm.py demo.asm -o demo.bin --list demo.lst

# 2. probar sin el aparato (vuelca la pantalla en ASCII)
python3 ../tools/sim.py demo.bin --steps 2000000

#    con entradas: un guion de eventos "<instr> <accion>"
python3 ../tools/sim.py demo.bin --steps 3000000 --script mi_guion.txt

# 3. grabar en el aparato (el slot se deduce de la ".slot 4" del propio .asm)
python3 ../tools/compi_send.py --port /dev/ttyACM0 demo.asm
```

`compi_send.py` acepta directamente un `.asm` (lo ensambla al vuelo) o un
`.bin` ya montado. Con un `.asm`, `--slot` es opcional: si no se indica, se usa
el de su directiva `.slot`; con un `.bin` (que no lleva esa directiva) hay que
darlo explícitamente. Un `--slot` explícito siempre gana, aunque no coincida
con el del fichero (avisa por si acaso, pero lo respeta).

## La sintaxis en 30 segundos

Es la del desensamblador (`src/disasm.cpp`) más etiquetas y directivas:

```asm
    .slot 4                 ; slot de destino sugerido
    .org 0x0000             ; contador de posicion

VALOR = 0x2A               ; constante  (tambien:  VALOR .equ 0x2A)

start:
    MOV AL,#VALOR           ; LDI  (reg,#imm8)
    MOV BL,AL               ; EXT  (reg,reg)
    ADD AL,#1               ; ALUI (reg,#imm8)
    LDA CL,[dato]           ; reg <- memoria
    STA [dato+1],CL
    OUT (0x0400),AL         ; puerto de 16 bits
    IN  AL,(0x0503)
    LDA CL,[DX]             ; indirecto: dirección en un registro de 16 bits
    STA [DX],CL             ; (AX/BX/CX/DX; ver docs/isa.md §4b) en vez de
    OUT (DX),AL             ; addr16/port16 inmediato -- 2 bytes en vez de 3
bucle:
    SUB AL,#1
    JMPNZ bucle             ; JMP/JMPZ/JMPNZ/JMPC/JMPNC/JMPN/JMPNN ; CALL... ; RET
    HALT

dato:   .db 0x11, 0x22, "texto", 0
tabla:  .dw 0x1234
cadena: .asciiz "HOLA"
hueco:  .space 16
```

Expresiones: `+ - * / % << >> & | ^ ~`, paréntesis, `0x..` `0b..` decimal,
`'A'` (código del carácter), `$` o `.` (posición actual), `lo(x)` `hi(x)` y
etiquetas.

## Tamaño del `.bin`

`casm.py` recorta el fichero justo tras el último byte de código/datos: el
resto de la RAM (hasta `0xFFFF`) lo rellena el propio aparato con ceros al
cargar el programa (`cpu.clearMemory()` en `src/main.cpp`), y el protocolo de
`compi_send.py` (`"COMPI LOAD <slot> <len>\n"`) ya admite `len` menor de
65536 — solo se manda por el cable lo que realmente ocupa el programa.

Para que esto ahorre de verdad, las variables y las tablas de datos hay que
colocarlas **justo después del código**, no en una dirección alta fija como
`0xFE00` (ese hueco de por medio pasa a formar parte del fichero igualmente,
relleno de ceros). `estrellas.asm` es el ejemplo: declara sus variables con
`.space 1` y sus tablas con `.space N` al final del fichero, sin ningún
`.org`, y el `.bin` resultante ocupa 967 bytes en vez de 65536. `demo.asm` es
anterior a esta convención y sigue usando direcciones altas fijas (`0xFE00`,
`0xF000`…); sigue siendo válido, solo que su `.bin` no se beneficia del
recorte tanto como podría.

El SP no cambia: sigue arrancando siempre en `0xFFFF` y creciendo hacia
abajo, así que nunca choca con el código+datos mientras el programa no ocupe
toda la RAM.

## Código automodificable

`LDA`/`STA`/`IN`/`OUT` tienen una segunda forma con la dirección/puerto en un
registro de 16 bits (`LDA reg,[AX|BX|CX|DX]`, ver `docs/isa.md` §4b) — para
programas nuevos, normalmente es más simple recorrer un buffer cargando el
puntero una vez en un registro de 16 bits y avanzándolo en cada vuelta (con
`ADD`/`SUB` sobre sus dos mitades de 8 bits, propagando el acarreo a mano).
`demo.asm` es anterior a
esa forma y usa el patrón clásico: parchea a mano los bytes de operando de la
instrucción en tiempo de ejecución (p. ej. `STA [cg_io+1],AL` antes de
`cg_io: OUT (...),AL`). Sigue siendo válido y es lo que vas a ver en ese
fichero, pero no hace falta para código nuevo.
