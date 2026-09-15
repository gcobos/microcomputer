# compi — referencia rápida del juego de instrucciones

Chuleta para teclear programas en el panel. La especificación formal está en
[`../specs.txt`](../specs.txt) §4 (instrucciones) y §8 (puertos); esto es lo
mismo en versión práctica. Todos los bytes están comprobados en el emulador.

---

## 1. Cómo se teclea un programa

1. `SW_MODE` = **EDIT**, `SW_STEP` = **▲** (vista EDIT MEMORY).
2. El cursor empieza en `0x0000`. La fila 0 dice qué **campo** estás rellenando
   ahora mismo (`OP`, `MODE`, `COND`, `REG`, `DST`, `SRC`, `IMM`, `LO`, `HI` —
   abreviaturas en inglés, como los mnemónicos y los registros).
   **Giras DATA** para cambiar el valor de ese campo — el listado de abajo
   muestra la instrucción formándose en directo. **Pulsas DATA** para
   confirmar el campo y pasar al siguiente; en el último campo, esa misma
   pulsación ya te deja en la dirección siguiente, lista para la próxima
   instrucción. Pulsas ADDR para retroceder un campo (o una dirección
   entera si ya estás en el primero).
3. Cada instrucción se compone así:
   - **OP** (verbo): uno de 21 (`NOP HALT MOV LDA STA ADD SUB AND OR XOR NOT
     SHR SHL IN OUT PUSH POP JMP CALL RET CMP`).
   - **MODE** (forma; solo `MOV`/`CMP`/`ADD`/`SUB`/`AND`/`OR`/`XOR`/`LDA`/`STA`/
     `IN`/`OUT`): `reg,reg` / `reg,#imm` / `reg,[dir]` (las dos primeras no
     existen para `LDA`/`STA`/`IN`/`OUT`; la memoria/puerto no existe para
     `MOV` ni `CMP`) — y para `LDA`/`STA`/`IN`/`OUT` además un segundo modo,
     **`[reg16]`**: dirección/puerto indirecto a través de `AX`/`BX`/`CX`/`DX`
     en vez de un valor de 16 bits inmediato (`PTR`, sección 4b).
   - Luego los operandos que le toquen: condición (`JMP`/`CALL`), registro(s),
     inmediato, o dirección/puerto de 16 bits — éste último se teclea en dos
     campos separados, **byte bajo (`LO`) y luego byte alto (`HI`)** (p. ej.
     `0x1234` son los campos `34` y luego `12`), salvo en el modo `[reg16]`,
     que es un único campo **`PTR`** (gira entre `AX`/`BX`/`CX`/`DX`).
   - Al aterrizar en una dirección con algo ya escrito, el selector arranca
     en lo que ya haya (como la edición de byte crudo de antes): si solo
     quieres cambiar un campo, ve pulsando DATA sin girar por los demás.
4. Para ejecutar: `SW_MODE` = **RUN** (▲ paso a paso, ▼ continuo). Siempre
   arranca en `PC = 0`.

Detalle completo del selector: [`../specs.txt`](../specs.txt) §12
(`include/editor.h`, `src/editor.cpp`).

No hace falta memorizar los opcodes: giras DATA y ves el mnemónico. Esta ficha
sirve para el camino inverso ("quiero un `MOV`, ¿qué byte es?").

---

## 2. Registros

| 16 bits | mitades de 8 bits (índice) |
|---|---|
| AX | AL = 0 · AH = 1 |
| BX | BL = 2 · BH = 3 |
| CX | CL = 4 · CH = 5 |
| DX | DL = 6 · DH = 7 |

Además: **PC** (puntero de instrucción, arranca en 0), **SP** (pila, arranca en
`0xFFFF` y crece hacia abajo), **FLAGS** (`N` negativo · `V` desbordamiento ·
`Z` cero · `C` acarreo).

Los registros **no se editan a mano**: se cargan ejecutando `MOV reg,#valor`.

---

## 3. El byte de opcode

    opcode = familia × 8 + registro       (o + condición, en JMP/CALL)

Ejemplo: `ADD BL,[dir]` → familia 5, registro BL = 2 → `5×8 + 2 = 0x2A`.

---

## 4. Instrucciones

`LEN` = bytes totales. `imm8` = 1 byte. `addr16` / `port16` = 2 bytes (bajo, alto).

Las **7 operaciones de la ALU** (`MOV ADD SUB CMP AND OR XOR`) tienen tres
formas — ver secciones 6 y 6b. El resto:

| Mnemónico | LEN | Familia | Opcode (AL … DH) | Qué hace | Flags |
|---|---|---|---|---|---|
| `NOP`              | 1 | 0  | `00` | nada | — |
| `HALT`             | 1 | 1  | `08` | detiene la CPU | — |
| `MOV reg,#imm8`    | 2 | 2  | `10 11 12 13 14 15 16 17` | `reg = imm8` | — |
| `LDA reg,[addr16]` | 3 | 3  | `18 … 1F` | `reg = mem[addr]` (MOV desde memoria) | — |
| `STA [addr16],reg` | 3 | 4  | `20 … 27` | `mem[addr] = reg` (MOV a memoria) | — |
| `ADD reg,[addr16]` | 3 | 5  | `28 … 2F` | `reg = reg + mem[addr]` | N V Z C |
| `SUB reg,[addr16]` | 3 | 6  | `30 … 37` | `reg = reg - mem[addr]` | N V Z C |
| `AND reg,[addr16]` | 3 | 7  | `38 … 3F` | `reg = reg & mem[addr]` | N Z (C=V=0) |
| `OR  reg,[addr16]` | 3 | 8  | `40 … 47` | `reg = reg \| mem[addr]` | N Z (C=V=0) |
| `XOR reg,[addr16]` | 3 | 9  | `48 … 4F` | `reg = reg ^ mem[addr]` | N Z (C=V=0) |
| `NOT reg`          | 1 | 10 | `50 … 57` | `reg = ~reg` | N Z (C=V=0) |
| `SHR reg`          | 1 | 11 | `58 … 5F` | `reg >>= 1` | C = bit que sale · V = bit 7 previo · N Z |
| `SHL reg`          | 1 | 12 | `60 … 67` | `reg <<= 1` | C = bit que sale · N = bit 7 · V = (C≠N) · Z |
| `IN  reg,(port16)` | 3 | 13 | `68 … 6F` | `reg = puerto` (sección 8) | — |
| `OUT (port16),reg` | 3 | 14 | `70 … 77` | `puerto = reg` | — |
| `<op> reg,#imm8`   | 3 | 20 | `A0` + op | ALU con inmediato (sección 6b) | según op |
| `LDA reg,[reg16]`  | 2 | 21 | `A8 … AF` | `reg = mem[reg16]` (sección 4b) | — |
| `STA [reg16],reg`  | 2 | 22 | `B0 … B7` | `mem[reg16] = reg` (sección 4b) | — |
| `IN  reg,(reg16)`  | 2 | 23 | `B8 … BF` | `reg = puerto[reg16]` (sección 4b) | — |
| `OUT (reg16),reg`  | 2 | 24 | `C0 … C7` | `puerto[reg16] = reg` (sección 4b) | — |
| `PUSH reg`         | 1 | 15 | `78 … 7F` | `--SP; mem[SP] = reg` | — |
| `POP reg`          | 1 | 16 | `80 … 87` | `reg = mem[SP]; ++SP` | — |
| `JMP<cc> addr16`   | 3 | 17 | `88` + cc | si se cumple `cc`: `PC = addr` | — |
| `CALL<cc> addr16`  | 3 | 18 | `90` + cc | si `cc`: apila PC, `PC = addr` | — |
| `RET`              | 1 | 19 | `98` | `PC = ` dirección apilada | — |
| *(reservadas)*     | 1 | 25–30 | `C8 … F7` | se ejecutan como `NOP` | — |
| `<op> dst,src`     | 2 | 31 | `F8` + op | ALU registro-registro (sección 6) | según op |

Columna "Opcode (AL … DH)": el primer valor es con el registro AL; cada
registro siguiente suma 1 (AL 0, AH 1, BL 2, BH 3, CL 4, CH 5, DL 6, DH 7).

---

## 4b. `LDA`/`STA`/`IN`/`OUT` indirecto por registro: `reg,[reg16]`

Segunda forma de `LDA`/`STA`/`IN`/`OUT` (familias 21-24): la dirección o
puerto de 16 bits sale de un registro (`AX`/`BX`/`CX`/`DX`) en vez de venir
como inmediato en la propia instrucción — **LEN 2** en vez de 3 (opcode +
1 byte, no opcode + addr16). Útil para recorrer un buffer con un bucle
(cargar el puntero una vez en, p. ej., `DX`, e ir incrementándolo) sin tener
que parchear los bytes de operando de la instrucción como hace el código
automodificable (`programs/README.md`).

    opcode  = familia×8 + reg        (igual que la forma con addr16)
    byte 2  = par de 16 bits         0=AX  1=BX  2=CX  3=DX  (bits altos sin usar)

| Mnemónico | Familia | Opcode (AL … DH) | Byte 2 | Qué hace |
|---|---|---|---|---|
| `LDA reg,[reg16]` | 21 | `A8 … AF` | 0-3 = AX/BX/CX/DX | `reg = mem[reg16]` |
| `STA [reg16],reg` | 22 | `B0 … B7` | 0-3 = AX/BX/CX/DX | `mem[reg16] = reg` |
| `IN  reg,(reg16)`  | 23 | `B8 … BF` | 0-3 = AX/BX/CX/DX | `reg = puerto[reg16]` |
| `OUT (reg16),reg`  | 24 | `C0 … C7` | 0-3 = AX/BX/CX/DX | `puerto[reg16] = reg` |

Ejemplo: `LDA AL,[DX]` con `DX = 0x1234` equivale a `LDA AL,[0x1234]`, pero en
2 bytes (`A8 03`) en vez de 3 (`18 34 12`), y con la dirección real fijada en
tiempo de ejecución por lo que valga `DX` en ese momento.

En el selector de mnemónico del panel (sección 1): al elegir `LDA`/`STA`/
`IN`/`OUT`, el campo `MODE` alterna entre `[dir]` (addr16 inmediato) y
`[reg16]` (este modo); en `[reg16]` el operando de dirección/puerto es un
único campo **`PTR`** que gira entre `AX`/`BX`/`CX`/`DX`, en vez de los dos
campos `LO`/`HI`.

---

## 5. Condiciones de `JMP` / `CALL`

El opcode base es `88` (JMP) o `90` (CALL); se le suma el número de condición:

| cc | +n | JMP | CALL | salta si… |
|---|---|---|---|---|
| ALWAYS (siempre) | 0 | `88` | `90` | siempre |
| Z   | 1 | `89` | `91` | Z = 1 (resultado cero) |
| NZ  | 2 | `8A` | `92` | Z = 0 |
| C   | 3 | `8B` | `93` | C = 1 (hubo acarreo) |
| NC  | 4 | `8C` | `94` | C = 0 |
| N   | 5 | `8D` | `95` | N = 1 (resultado negativo) |
| NN  | 6 | `8E` | `96` | N = 0 |

`JMP` y `CALL` **siempre ocupan 3 bytes**, aunque la condición no se cumpla.

---

## 6. ALU registro-registro:  `<op> dst,src`   (familia 31)

Las 7 operaciones de la ALU. El **opcode** lleva la operación; sigue **1 byte
de operando** con los dos registros:

    opcode  = 0xF8 + op         op = 0 MOV · 1 ADD · 2 SUB · 3 CMP · 4 AND · 5 OR · 6 XOR
    operando = dst×8 + src      dst, src = índices de registro (0–7)

| op | opcode | efecto | flags |
|---|---|---|---|
| MOV | `F8` | `dst = src` | — |
| ADD | `F9` | `dst = dst + src` | N V Z C |
| SUB | `FA` | `dst = dst - src` | N V Z C |
| CMP | `FB` | flags de `dst - src` (dst no cambia) | N V Z C |
| AND | `FC` | `dst = dst & src` | N Z (C=V=0) |
| OR  | `FD` | `dst = dst \| src` | N Z |
| XOR | `FE` | `dst = dst ^ src` | N Z |

Ejemplos: `MOV CL,AL` → `F8` `20` (dst CL=4 → 4×8=32=0x20, src AL=0) ·
`ADD AL,BL` → `F9` `02` · `XOR AL,BL` → `FE` `02`.

---

## 6b. ALU con inmediato:  `<op> reg,#imm8`   (familia 20)

Igual pero la fuente es una constante. **Opcode + registro + valor**:

    opcode = 0xA0 + op         (mismo op que arriba)
    byte 2 = reg               (0–7)
    byte 3 = imm8

| op | opcode | efecto |
|---|---|---|
| ADD | `A1` | `reg = reg + imm` |
| SUB | `A2` | `reg = reg - imm` |
| CMP | `A3` | flags de `reg - imm` |
| AND | `A4` | `reg = reg & imm` |
| OR  | `A5` | `reg = reg \| imm` |
| XOR | `A6` | `reg = reg ^ imm` |

(`MOV reg,#imm` no se usa por aquí: es `LDI` — familia 2, más corto.)

Ejemplos: `ADD AL,#0x05` → `A1` `00` `05` · `OR BL,#0x80` → `A5` `02` `80` ·
`CMP CL,#0x0A` → `A3` `04` `0A`.

Flags: iguales que en la sección 6 (aritméticos para ADD/SUB/CMP, lógicos para AND/OR/XOR).

---

## 7. Cómo quedan los flags

- **Aritmética** (`ADD`, `SUB`, `EXT ADD/SUB/CMP`): `Z` si el resultado es 0,
  `N` = bit 7 del resultado.
  - `SUB`/`CMP`: `C` = 1 si `a < b` (préstamo). `V` = desbordamiento con signo.
  - `ADD`: `C` = 1 si la suma pasa de 255. `V` = desbordamiento con signo.
- **Lógica** (`AND`, `OR`, `XOR`, `NOT`): `Z` y `N` según el resultado; `C = 0`, `V = 0`.
- **Desplazamientos**: ver la tabla de la sección 4.
- `MOV`, `LDA`, `STA`, `IN`, `OUT`, `PUSH`, `POP`, `JMP`, `CALL`, `RET`, `NOP`:
  **no tocan los flags**.
- `reset` (arranque de ejecución): todos los flags a 0.

---

## 8. Puertos de E/S (`IN` / `OUT`)

Espacio de 65536 puertos, **aparte de la memoria**. `IN` de un puerto no
mapeado devuelve 0; `OUT` a uno no mapeado no hace nada.

La pantalla (gráficos + texto) va en `0x0000`–`0x04FF`; el resto de periféricos
en `0x05xx`.

| Puerto | Dir. | Qué es |
|---|---|---|
| `0x0000` … `0x03FF` | E/S | **Gráficos** (framebuffer) 128×64. 1 puerto = 8 píxeles horizontales, bit 7 = izquierda, 1 = encendido. Puerto de `(xbyte, y)` = `y × 16 + xbyte` (xbyte 0–15, y 0–63). |
| `0x0400` … `0x04FF` | E/S | **Texto**. 1 puerto = 1 celda 6×8, superpuesta al gráfico. Puerto de `(col, fila)` = `0x0400 + fila × 32 + col` (fila 0–7, col 0–20). El byte es el código ASCII: `0` = celda transparente, `0x20` = celda en blanco, resto = glifo opaco. |
| `0x0500` | IN | Encoder **ADDR**: posición (contador 0–255 que envuelve). |
| `0x0501` | IN | Encoder ADDR: bit 0 = pulsado. |
| `0x0502` | IN | Encoder **DATA**: posición. |
| `0x0503` | IN | Encoder DATA: bit 0 = pulsado. |
| `0x0510` | E/S | **LED** azul de a bordo: `OUT` bit 0 = 1 lo enciende. `IN` = eco. |
| `0x0520` … `0x0527` | E/S | **Temporizadores** t0…t7. `OUT` arma con 0–255; decrece solo hasta 0. `IN` lee el valor actual. |
| `0x0530` | E/S | **Sonido** – frecuencia, byte bajo (solo se engancha). |
| `0x0531` | E/S | **Sonido** – frecuencia, byte alto; al escribirlo suena `Hz = alto·256 + bajo` (0 = silencio). |
| `0x0532` | E/S | **Sonido** – nota MIDI 0–127 (0 = silencio). 69 = LA4 = 440 Hz, +12 = octava. La forma fácil. |
| `0x0533` | E/S | **Sonido** – duración automática = valor × 10 ms (0 = sostenida). "Pegajosa": cada nota la re-arma. |

Gráficos, texto, encoders, LED, temporizadores y sonido se ponen a 0 cada vez
que arranca una ejecución. En CONTINUOUS la pantalla es el gráfico + el texto
(refresco cada 50 ms).

**Texto** (`0x0400`–`0x04FF`): fuente monospace de 6×8 (5×7 de Adafruit GFX),
21 columnas × 8 filas. Para escribir una cadena, `OUT` carácter a carácter
incrementando el puerto (col + 1); no hay salto de línea automático. `IN`
devuelve el último carácter escrito en esa celda.

**Sonido** (`0x0530`–`0x0533`): zumbador piezo pasivo en GPIO3. Solo suena en
**CONTINUOUS**; se calla en paso a paso, al volver a EDIT y al `HALT`. Lo genera
el hardware, no gasta tiempo de CPU. Lo más simple: `OUT (0x0532),reg` con una
nota MIDI. Para efectos (sirenas, barridos) usa la frecuencia de 16 bits
(`0x0530` bajo, luego `0x0531` alto).

**Temporizadores** (`0x0520`–`0x0527`): 8 cuentas atrás. Cada `t_i` baja 1
cada `1 << i` ms → t0 = 1 ms/paso, t1 = 2, t2 = 4, t3 = 8, t4 = 16, t5 = 32,
t6 = 64, t7 = 128 ms (t7: 255 → 0 en ~33 s). Solo corren en **CONTINUOUS**; en
paso a paso están congelados. `IN` **no** cambia los flags: para esperar a que
llegue a 0 hay que `CMP reg,#0` antes del `JMPNZ`.

---

## 9. Programas de ejemplo (con sus bytes)

Teclea los bytes desde `0x0000`. Para ejecutar: `SW_MODE` = RUN.

### El LED sigue al pulsador DATA  *(RUN ▼ continuo)*
```
Dir  Bytes        Instrucción
0000 68 03 05     IN  AL,(0x0503)     ; lee el pulsador del encoder DATA
0003 70 10 05     OUT (0x0510),AL     ; lo manda al LED
0006 88 00 00     JMP 0x0000          ; repetir para siempre
```
Pulsa el eje del encoder DATA → el LED se enciende. (Vuelve a EDIT para parar.)

### Escribir "HOLA" arriba a la izquierda  *(RUN ▼ continuo)*
```
Dir  Bytes        Instrucción
0000 10 48        MOV AL,#0x48        ; 'H'
0002 70 00 04     OUT (0x0400),AL     ; celda (col 0, fila 0)
0005 10 4F        MOV AL,#0x4F        ; 'O'
0007 70 01 04     OUT (0x0401),AL
000A 10 4C        MOV AL,#0x4C        ; 'L'
000C 70 02 04     OUT (0x0402),AL
000F 10 41        MOV AL,#0x41        ; 'A'
0011 70 03 04     OUT (0x0403),AL
0014 08           HALT
```
La fila siguiente empieza en `0x0420` (`0x0400 + 1×32`).

### Suma 5 + 3  *(RUN ▲ paso a paso, para verlo)*
```
Dir  Bytes     Instrucción
0000 10 05     MOV AL,#0x05
0002 12 03     MOV BL,#0x03
0004 F9 02     ADD AL,BL           ; AL = 8   (F9 = ADD reg,reg ; 02 = dst AL, src BL)
0006 08        HALT
```
O más corto, con inmediato: `10 05` `A1 00 03` `08` (`MOV AL,#5` · `ADD AL,#3` · `HALT`).

### Tres puntos en el borde izquierdo de la pantalla  *(RUN ▼ continuo)*
```
Dir  Bytes        Instrucción
0000 10 80        MOV AL,#0x80        ; 0x80 = píxel más a la izquierda
0002 70 00 00     OUT (0x0000),AL     ; fila 0
0005 70 10 00     OUT (0x0010),AL     ; fila 1
0008 70 20 00     OUT (0x0020),AL     ; fila 2
000B 08           HALT
```

### Cuenta atrás desde 3 y para  *(bucle con `SUB` y `JMPNZ`)*
```
Dir  Bytes        Instrucción
0000 10 03        MOV AL,#0x03
0002 A2 00 01     SUB AL,#0x01        ; AL = AL - 1
0005 8A 02 00     JMPNZ 0x0002        ; repite mientras AL != 0
0008 08           HALT
```
Míralo en **paso a paso** (`SW_STEP ▲`): AL va 3 → 2 → 1 → 0 y para. (Antes
hacía falta guardar el `1` en memoria; ahora `SUB AL,#1` lo hace directo.)

### Espera con temporizador y enciende el LED  *(RUN ▼ continuo)*
```
Dir  Bytes        Instrucción
0000 10 0A        MOV AL,#0x0A        ; 10 pasos de t5 (32 ms) ≈ 320 ms
0002 70 25 05     OUT (0x0525),AL     ; arma el temporizador 5
0005 68 25 05     IN  AL,(0x0525)     ; lee el temporizador
0008 A3 00 00     CMP AL,#0x00        ; IN no toca flags: hay que comparar
000B 8A 05 00     JMPNZ 0x0005        ; sigue esperando mientras != 0
000E 10 01        MOV AL,#0x01
0010 70 10 05     OUT (0x0510),AL     ; enciende el LED
0013 08           HALT
```
Cambia el temporizador (`0x0520`–`0x0527`) o el valor inicial para ajustar el
retardo. Recuerda: en paso a paso los temporizadores no avanzan.

### Dos notas: DO4 y luego SOL4  *(RUN ▼ continuo)*
```
Dir  Bytes        Instrucción
0000 10 0F        MOV AL,#0x0F        ; 15 × 10 ms = 150 ms por nota
0002 70 33 05     OUT (0x0533),AL     ; PORT_SND_DUR (se queda armado)
0005 10 3C        MOV AL,#0x3C        ; 60 = DO4 (~262 Hz)
0007 70 32 05     OUT (0x0532),AL     ; suena; se calla sola a los 150 ms
000A 10 14        MOV AL,#0x14        ; espera con t3 (8 ms): 20 pasos ≈ 160 ms
000C 70 23 05     OUT (0x0523),AL
000F 68 23 05     IN  AL,(0x0523)     ; ← espera
0012 A3 00 00     CMP AL,#0x00
0015 8A 0F 00     JMPNZ 0x000F
0018 10 43        MOV AL,#0x43        ; 67 = SOL4 (~392 Hz)
001A 70 32 05     OUT (0x0532),AL
001D 08           HALT
```
Nota MIDI: 60 = DO4, 62 = RE, 64 = MI, 65 = FA, 67 = SOL, 69 = LA (440 Hz),
71 = SI, 72 = DO5. Sube/baja 12 para cambiar de octava.
