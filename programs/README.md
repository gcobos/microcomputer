# programs/

Programas para compi escritos en ensamblador. Se ensamblan con
[`../tools/casm.py`](../tools/casm.py) y se graban en un slot de la flash con
[`../tools/compi_send.py`](../tools/compi_send.py).

| Fichero | Slot | Qué es |
|---|---|---|
| [`roto_debug.asm`](roto_debug.asm) | 0 | Depuración visual de los dos rotoencoders: un círculo sin rellenar por encoder (izquierda DIRECCION, derecha DATOS) con una aguja que apunta a una de 20 posiciones (una por detente), más la posición cruda (0-255) en decimal debajo. El círculo se rellena mientras su pulsador esté pulsado. Círculo dibujado con el algoritmo del punto medio (sin multiplicación); doble buffer por software igual que `cubo.asm`. |
| [`demo.asm`](demo.asm) | 4 | Menú principal que llama a rutinas de demostración: gráficos (caja rebotando), texto (máquina de escribir + juego de caracteres), sonido (escala + LED), animación (curva de Lissajous), luces (LED estroboscópico + destellos) y un juego, **ESQUIVA**, que usa todo junto. |
| [`estrellas.asm`](estrellas.asm) | 5 | Cielo estrellado: 16 estrellas en posiciones al azar que titilan (aparecen, crecen a una cruz de 5 píxeles y se apagan) de forma asíncrona. El LED azul se enciende junto con la pantalla cuando alguna estrella está en su brillo máximo. |
| [`cubo.asm`](cubo.asm) | 3 | Cubo de wireframe en 3D girando sobre el eje Y, en proyección ortográfica. Implementa desde cero multiplicación con signo (8×8→16 bits, la CPU no tiene `MUL`) y una línea de Bresenham de propósito general, ya que ninguna existía en el repo. |
| [`reloj.asm`](reloj.asm) | 1 | Reloj analógico de agujas con hora real (latido de 1 s por el temporizador T2, no un contador de fotogramas) y números romanos trazados como líneas. Encoder izquierdo (DIRECCION) ajusta la hora, encoder derecho (DATOS) ajusta los minutos. Reutiliza `smul64`/`line_draw` de `cubo.asm`. |
| [`pong.asm`](pong.asm) | 2 | Pong de dos jugadores: cada encoder mueve la paleta de su lado, y su pulsador saca la pelota (con ángulo según la posición y el sentido de giro de la paleta en ese momento) cuando no hay pelota en juego. Quien gana el punto saca en la ronda siguiente. Marcador en la capa de texto, independiente del framebuffer gráfico. Doble buffer por software igual que `cubo.asm`. |
| [`atributos.asm`](atributos.asm) | 6 | Muestra estática de los atributos de texto (`0x0500`–`0x05FF`, banco pegado a la rejilla de texto): una fila por atributo — inverso, parpadeo, subrayado, tachado, subíndice/superíndice (`H₂O`, `X²`) y las 4 rotaciones del glifo (0°/90°/180°/270°). Dibuja una vez y hace `HALT`; el parpadeo lo sigue animando el firmware sin ayuda de la CPU. |
| [`benchmark.asm`](benchmark.asm) | 57 | Mide la velocidad real del intérprete: cuenta vueltas de un bucle de 16 bits durante una ventana de 32,000 s exactos (temporizador T7 armado a 250 pasos de 128 ms) y muestra el resultado en hexadecimal (`N=0x....`). El propio fichero explica en la cabecera cómo pasar ese número a instrucciones/segundo. |
| [`fzero.asm`](fzero.asm) | 7 | "EXPRESS X-1": esquiva-obstáculos pseudo-3D estilo F-Zero, pensado para exigir a la CPU emulada. Carretera en perspectiva con curvas que se ven venir desde el horizonte, con una silueta de montañas al fondo que se desplaza lateralmente al girar; arbustos en el arcén con altura alterna que fluyen hacia la cámara dando sensación de avance; tocar un borde resetea la velocidad (hay que reacelerar a mano con DATOS); los obstáculos persiguen muy despacio el carril de la nave. Botón DIRECCION dispara (destruye el obstáculo que alcance), botón DATOS salta (esquiva automáticamente el que llegue mientras dura). Nave y obstáculos con sprites de varios píxeles (tablas (dx,dy)). Sonido: zumbido de motor que cambia de tono con la velocidad, con un riff corto de acción interrumpiéndolo cada pocas vueltas. Doble buffer por software igual que `cubo.asm`/`pong.asm`. Sin multiplicación real en ningún sitio. |
| [`calc.asm`](calc.asm) | 10 | Calculadora clásica al estilo de las de bolsillo baratas: caja arriba con un único valor (el número tecleado o el resultado, nunca la expresión completa), sin recuadro, alineado a la derecha y sin ceros de relleno (el 0 se muestra como un único "0"). Debajo, siempre visibles, los 6 botones de operación (+ − × ÷ = C) y los 10 dígitos (0-9), dibujados una sola vez al arrancar. Encoder DATOS elige/teclea el dígito resaltado (máx. 6 dígitos, hasta 999999); encoder DIRECCION elige/confirma la operación. Cambiar de selección solo apaga el marco del botón anterior y enciende el del nuevo (sin redibujar nada más); cada operación pulsada aplica de inmediato la operación pendiente sobre un acumulador de 24 bits y muestra el resultado, con la semántica clásica de "operador diferido" (`2 + 3 × 4 =` da 20, no 14, igual que en una calculadora de bolsillo real). Sin multiplicación ni división de la CPU: multiplicar es suma-y-desplaza sobre un intermedio de 48 bits (para detectar el desbordamiento antes de truncar), dividir es división binaria larga con resto (24 pasadas de "desplaza y compara" en vez de restar de uno en uno, que con números de 6 cifras podría tardar casi un millón de restas). División por cero y desbordamiento por encima de 999999 muestran "Err" en vez de colgarse o dar un resultado incorrecto. Doble buffer por software igual que `cubo.asm`. |
| [`raycast.asm`](raycast.asm) | 9 | Escena 3D en primera persona estilo Doom/Wolfenstein: motor de *raycasting* clásico sobre un mapa de 16×16 baldosas. Lanza 32 rayos por fotograma (campo de visión de 90°), cada uno "marcha" en pasos fijos hasta chocar con una pared; la distancia da la altura de la franja vertical de esa columna (más cerca = más alta), por tabla, sin división real. Las paredes se rellenan con una de 5 tramas de puntos según su distancia (negro completo la más lejana, blanco completo la más cercana, tres tramas de densidad creciente en medio — *dithering* ordenado para simular grises en una pantalla de 1 bit). El cielo lleva 8 nubes grandes, huecas y de líneas curvas (el contorno de varios círculos solapados, calculado una vez con Python; el interior queda vacío), de dos formas alternadas — rechoncha y alargada, esta última con el doble de deriva propia (se ve moverse más rápido) — que se deslizan solas hacia la izquierda; como se dibujan con el mismo ángulo de mundo que las paredes, girar a la derecha se suma a esa deriva (se ven más rápidas) y girar a la izquierda se le resta (más lentas, o incluso se ven ir hacia la derecha si el giro es más rápido que la deriva) — se ocultan tras cualquier pared que las tape. Al ser mucho más anchas que la franja de 4&nbsp;px de un rayo, se dibujan aparte del bucle de rayos, píxel a píxel (no por nibble como las paredes). Encoder DIRECCION gira la vista, DATOS avanza/retrocede sin atravesar paredes; pulsar cualquiera de los dos lanza un proyectil redondo ("bola de fuego", con silbido descendente), con hasta 4 en vuelo a la vez, cada uno con su propio ángulo y su propia distancia recorrida. Se dibujan rellenos de negro (para distinguirse tanto sobre una pared blanca sólida como sobre una con trama de puntos) y se encogen en 4 escalones según se alejan; cada uno viaja en línea recta hasta chocar con una pared o agotar el alcance, y se dibuja solo mientras esté más cerca que la pared de su columna en pantalla, para que se pierda correctamente al pasar detrás de una. Sin multiplicación, división ni trigonometría en tiempo de ejecución: posición y "baldosa" en potencias de 2 (`SHR`/`SHL` en vez de dividir/indexar filas), direcciones de 128 ángulos en tabla. Doble buffer por software igual que `cubo.asm`. |
| [`musica.asm`](musica.asm) | 8 | Obertura de Guillermo Tell (Rossini): arreglo monofónico del "galope" final, el tema más conocido de la obra, en bucle indefinido. LED y una barra vertical en pantalla laten con cada nota, más alta cuanto más aguda es. Tabla de melodía (nota MIDI, duración) recorrida con un puntero de 16 bits en memoria en vez de parcheo de código (evita la necesidad de alinear la tabla a página, ver el aviso de `.org` en `demo.asm`). |

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
    IN  AL,(0x0603)
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
