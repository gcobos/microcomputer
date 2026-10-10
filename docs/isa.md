# compi — referencia rápida del juego de instrucciones

Chuleta para teclear programas en el panel. La especificación formal está en
[`../specs.txt`](../specs.txt) §4 (instrucciones) y §8 (puertos); esto es lo
mismo en versión práctica. Todos los bytes están comprobados con el
ensamblador y el emulador (ISA versión 2, ver sección 3).

---

## 1. Cómo se teclea un programa

1. `SW_MODE` = **EDIT**, `SW_STEP` = **SINGLE** (vista EDIT MEMORY).
2. El cursor empieza en `0x0000`. La fila 0 dice qué **campo** estás rellenando
   ahora mismo (`OP`, `MODE`, `COND`, `REG`, `DST`, `SRC`, `IMM`, `LO`, `HI`,
   `PTR`, `SRC16`, `N` — abreviaturas en inglés, como los mnemónicos y los
   registros).
   Mientras el campo es `OP` (eligiendo el verbo), la cabecera muestra
   además el tamaño ya ensamblado, p. ej. `NOP (size 1)`, para comparar
   opciones sin confirmar cada una.
   **Giras DATA** para cambiar el valor de ese campo — el listado de abajo
   muestra la instrucción formándose en directo; en el campo `OP` el giro
   recorre los 30 verbos en **orden alfabético** (no por familia de opcode).
   **Pulsas DATA** para confirmar el campo y pasar al siguiente; en el
   último campo, esa misma pulsación ya te deja en la dirección siguiente,
   lista para la próxima instrucción.
   **Giras ADDR** para moverte INSTRUCCIÓN A INSTRUCCIÓN (nunca a mitad de
   una de 2/3 bytes): adelante o atrás, un detente = una línea del listado.
   **Pulsas ADDR** corto para insertar un `NOP` suelto en el cursor
   (desplazando el resto de la RAM un byte adelante); una pulsación
   **larga** (~medio segundo) borra el byte del cursor en su lugar
   (desplazando el resto un byte atrás). Ninguna de las dos toca la pila.
3. Cada instrucción se compone así:
   - **OP** (verbo): uno de 30, en orden alfabético (`ADC ADD AND CALL CMP
     DEC DIV HALT IN INC JMP LDA MOV MOVB MOVBR MOVW MUL NOP NOT OR OUT POP
     PUSH RET SBC SHL SHR STA SUB XOR`).
   - **MODE** (forma), solo en los verbos que tienen varias:
     - `MOV`: `reg,reg` · `reg,#imm` · `r16,r16` · `r16,#imm16`.
     - `ADD`/`SUB`: `reg,reg` · `reg,#imm` · `reg,[dir]` · `reg,[r16]` ·
       `r16,reg8` · `r16,r16` · `r16,#imm8`.
     - `CMP`: `reg,reg` · `reg,#imm` · `reg,[dir]` · `reg,[r16]` · `r16,r16` ·
       `r16,#imm16`.
     - `ADC`/`SBC`/`AND`/`OR`/`XOR`: `reg,reg` · `reg,#imm` · `reg,[dir]` ·
       `reg,[r16]`.
     - `LDA`/`STA`/`IN`/`OUT`: `[dir]` · `[r16]` (indirecto a través de
       `AX`/`BX`/`CX`/`DX`, campo `PTR`).
     - `INC`/`DEC`: `r16` · `reg` (8 bits). `PUSH`/`POP`: `reg` · `r16`.
     - `JMP`/`CALL`: `cond,dir` · `r16` (salto a la dirección del registro).
   - Luego los operandos que le toquen: condición (`JMP`/`CALL`), registro(s),
     inmediato, o dirección/puerto de 16 bits — éste último se teclea en dos
     campos separados, **byte bajo (`LO`) y luego byte alto (`HI`)** (p. ej.
     `0x1234` son los campos `34` y luego `12`), salvo en el modo `[reg16]`,
     que es un único campo **`PTR`** (gira entre `AX`/`BX`/`CX`/`DX`; en
     las formas `r16,r16` el segundo par es el campo `SRC16`).
   - Al aterrizar en una dirección con algo ya escrito, el selector arranca
     en lo que ya haya: si solo quieres cambiar un campo, ve pulsando DATA
     sin girar por los demás.
4. Para ejecutar: `SW_MODE` = **RUN** (`SW_STEP` en SINGLE = paso a paso, en CONTINUOUS = continuo). Siempre
   arranca en `PC = 0` al entrar en RUN desde EDIT. Dentro de RUN, cambiar
   entre paso a paso y continuo **no** reinicia: el programa sigue desde
   donde estaba (sirve para parar uno en marcha, mirarlo paso a paso y
   dejarlo seguir). En paso a paso (STEP), **DATA** sigue ejecutando
   (girar adelante = varios pasos de golpe, uno por detente; pulsar = un
   paso; girar atrás no hace nada, no hay forma de deshacer). **ADDR**
   gira para elegir una dirección objetivo sin ejecutar nada (el listado la
   sigue mientras eliges); pulsarlo **corto** ejecuta hacia adelante hasta
   llegar a esa dirección, y **largo** resetea. Los temporizadores (§8) no
   están del todo congelados en STEP: avanzan según el tiempo real
   transcurrido entre un paso ejecutado y el siguiente.

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

## 3. El byte de opcode (ISA versión 2)

    opcode = familia × 8 + bajo3

5 bits de **familia** (32 posibles, 30 usadas) y 3 bits **bajos** que, según
la familia, son un **registro de 8 bits** (AL…DH = 0…7), una **condición**
(saltos), un **par de 16 bits** o una **sub-operación**. Las operaciones de
la ALU no gastan familias: van en un byte de operando aparte (sección 6), así
que las 9 operaciones tienen las 4 formas de direccionamiento.

Ejemplo: `ADD BL,#5` → familia 11 (ALU con inmediato), registro BL = 2 →
opcode `11×8 + 2 = 0x5A`, luego la operación (`ADD` = 1) y el inmediato:
`5A 01 05`.

`0x00` es `NOP`: una RAM a cero es un programa vacío. Las familias 30 y 31
están libres (se ejecutan como `NOP` de 1 byte).

> **Versión 2 de la codificación (octubre 2026).** Se reordenó entera para
> que sea regular (antes había una familia "de extensión" que mezclaba
> instrucciones sin relación, y huecos sin forma, como `CMP` con memoria). Los
> mnemónicos no cambian: un programa en ensamblador solo hay que volver a
> ensamblarlo. Los `.bin` antiguos NO funcionan con el firmware nuevo.

---

## 4. Instrucciones

`LEN` = bytes totales. `imm8` = 1 byte. `addr16` / `port16` / `imm16` = 2
bytes (bajo, alto). `r` = registro de 8 bits del opcode; `r16` = par
`AX`/`BX`/`CX`/`DX` (0–3).

| Fam. | Opcode | Mnemónico | LEN | Bytes | Qué hace |
|---|---|---|---|---|---|
| 0 | `00`–`05` | `NOP` `HALT` `RET` `MOVB` `MOVW` `MOVBR` | 1 | `op` | ver sección 4a |
| 1 | `08`+r | `MOV r,#imm8` | 2 | `op imm` | `r = imm` |
| 2 | `10`+r | `LDA r,[addr16]` | 3 | `op lo hi` | `r = mem[addr]` (también se escribe `MOV r,[addr]`) |
| 3 | `18`+r | `STA [addr16],r` | 3 | `op lo hi` | `mem[addr] = r` |
| 4 | `20`+r | `LDA r,[r16]` | 2 | `op r16` | `r = mem[r16]` (también `MOV r,[BX]`) |
| 5 | `28`+r | `STA [r16],r` | 2 | `op r16` | `mem[r16] = r` |
| 6 | `30`+r | `IN r,(port16)` | 3 | `op lo hi` | `r = puerto` (sección 8) |
| 7 | `38`+r | `OUT (port16),r` | 3 | `op lo hi` | `puerto = r` |
| 8 | `40`+r | `IN r,(r16)` | 2 | `op r16` | `r = puerto[r16]` |
| 9 | `48`+r | `OUT (r16),r` | 2 | `op r16` | `puerto[r16] = r` |
| 10 | `50`+r | `<alu> r,src` | 2 | `op alu<<3\|src` | ALU registro-registro (sección 6) |
| 11 | `58`+r | `<alu> r,#imm8` | 3 | `op alu imm` | ALU con inmediato |
| 12 | `60`+r | `<alu> r,[addr16]` | 4 | `op alu lo hi` | ALU con memoria |
| 13 | `68`+r | `<alu> r,[r16]` | 2 | `op alu<<2\|r16` | ALU con memoria por puntero |
| 14 | `70`+r | `NOT r` | 1 | `op` | `r = ~r` |
| 15 | `78`+r | `SHR r,#N` | 2 | `op N-1` | `r >>= N` (N = 1…8; `SHR r` = `#1`) |
| 16 | `80`+r | `SHL r,#N` | 2 | `op N-1` | `r <<= N` |
| 17 | `88`+r | `MUL r` | 1 | `op` | `AX = AL × r` (sin signo) |
| 18 | `90`+r | `DIV r` | 1 | `op` | `AL = AX ÷ r`, `AH = AX mod r` (sin signo) |
| 19 | `98`+r | `INC r` | 1 | `op` | `r = r + 1` (8 bits; C no cambia) |
| 20 | `A0`+r | `DEC r` | 1 | `op` | `r = r − 1` (8 bits; C no cambia) |
| 21 | `A8`+r | `PUSH r` | 1 | `op` | `--SP; mem[SP] = r` |
| 22 | `B0`+r | `POP r` | 1 | `op` | `r = mem[SP]; ++SP` |
| 23 | `B8`+cc | `JMP<cc> addr16` | 3 | `op lo hi` | si se cumple `cc`: `PC = addr` (sección 5) |
| 24 | `C0`+cc | `CALL<cc> addr16` | 3 | `op lo hi` | si `cc`: apila PC, `PC = addr` |
| 25 | `C8` `C9` | `JMPNV` / `CALLNV addr16` | 3 | `op lo hi` | igual, si V = 0 |
| 25 | `CA` `CB` | `JMP r16` / `CALL r16` | 2 | `op r16` | salta/llama a la dirección que hay en el par |
| 26 | `D0`–`D3` | `MOV`/`ADD`/`SUB`/`CMP r16,r16` | 2 | `op d16<<3\|s16` | 16 bits (sección 4b) |
| 26 | `D4` `D5` | `ADD`/`SUB r16,r8` | 2 | `op d16<<3\|r8` | `r16 ±= r8` sin signo |
| 27 | `D8` `DB` | `MOV`/`CMP r16,#imm16` | 4 | `op r16 lo hi` | |
| 27 | `D9` `DA` | `ADD`/`SUB r16,#imm8` | 3 | `op r16 imm` | `r16 ±= imm` sin signo |
| 28 | `E0`+r16 / `E4`+r16 | `INC r16` / `DEC r16` | 1 | `op` | `r16 ± 1` |
| 29 | `E8`+r16 / `EC`+r16 | `PUSH r16` / `POP r16` | 1 | `op` | apila alto y luego bajo / desapila bajo y luego alto |

### 4a. Familia 0: instrucciones sin operandos

| Opcode | Mnemónico | Qué hace |
|---|---|---|
| `00` | `NOP` | nada |
| `01` | `HALT` | detiene la CPU |
| `02` | `RET` | `PC =` dirección apilada |
| `03` | `MOVB` | copia `CX` bytes de `[BX]` a `[DX]` hacia adelante |
| `04` | `MOVW` | igual, `CX` palabras de 16 bits (2·`CX` bytes) |
| `05` | `MOVBR` | copia `CX` bytes **hacia atrás**: `BX`/`DX` apuntan al **último** byte de origen/destino y bajan |

Las tres copias usan registros implícitos (`BX` origen, `DX` destino, `CX`
cuenta) y dejan `CX = 0` con `BX`/`DX` justo después (o antes, en `MOVBR`)
de lo copiado, para poder encadenarlas. `MOVB` copia hacia adelante, así que
con origen y destino solapados y el destino detrás no hace un `memmove`; para
eso está `MOVBR` (abrir hueco en un búfer). Un truco con `MOVB`: escribir un
byte y copiarlo sobre sí mismo desplazado 1 rellena un búfer entero de un
tirón. Ninguna toca flags.

### 4b. Aritmética de 16 bits

Mismos mnemónicos `MOV`/`ADD`/`SUB`/`CMP`: el ensamblador elige la forma de
16 bits porque el destino se llama `AX`/`BX`/`CX`/`DX`. `MOV`, `ADD` y `SUB` de
16 bits **no tocan flags** (son aritmética de punteros); `CMP` de 16 bits sí:
`Z` si son iguales, `C` si el primero es menor (sin signo), `N` = bit 15 de
la resta, `V` = desbordamiento con signo. `ADD`/`SUB r16,r8` y `r16,#imm8`
suman o restan un byte sin signo (para avanzar un puntero).

    MOV BX,#tabla        ; D8 01 lo hi: puntero a una tabla
    ADD BX,CL            ; BX += CL (con acarreo a BH)
    CMP BX,#tabla+64     ; ¿se ha pasado del final?
    JMPC sigue           ; C = 1 si BX < tabla+64

### 4c. Multiplicación y división

**`MUL r`**: `AX = AL × r`, sin signo (8×8 → 16 bits, nunca desborda).
Flags: `Z`/`N` del resultado de 16 bits; **`C = V = 1` si el producto no cupo
en 8 bits** (`AH ≠ 0`).

**`DIV r`**: `AL = AX ÷ r` (cociente), `AH = AX mod r` (resto), sin signo.
Dividir entre 0, o un cociente que no quepa en 8 bits, satura `AL = AH = 0xFF`
con `C = V = 1`. Con resultado válido: `C = V = 0`, `Z`/`N` del cociente.

### 4d. `INC`/`DEC` de 8 bits

`INC r` / `DEC r` (1 byte) actualizan `Z`, `N` y `V` pero **no `C`**, igual que
en el Z80: se pueden usar como contador de un bucle sin perder un acarreo
pendiente de una suma de varios bytes. `V` = 1 si se pasó de 127 a −128 (`INC
0x7F`) o al revés (`DEC 0x80`).

---

## 5. Condiciones de `JMP` / `CALL`

El opcode es `B8` (JMP) o `C0` (CALL) más el número de condición:

| cc | +n | JMP | CALL | salta si… |
|---|---|---|---|---|
| (siempre) | 0 | `B8` | `C0` | siempre |
| Z   | 1 | `B9` | `C1` | Z = 1 (resultado cero) |
| NZ  | 2 | `BA` | `C2` | Z = 0 |
| C   | 3 | `BB` | `C3` | C = 1 (hubo acarreo / préstamo) |
| NC  | 4 | `BC` | `C4` | C = 0 |
| N   | 5 | `BD` | `C5` | N = 1 (resultado negativo) |
| NN  | 6 | `BE` | `C6` | N = 0 |
| V   | 7 | `BF` | `C7` | V = 1 (desbordamiento con signo) |
| NV  | — | `C8` | `C9` | V = 0 (no cabe en los 3 bits: va en la familia 25) |

`JMP r16` / `CALL r16` (`CA`/`CB` + byte con el par) saltan a la dirección
que contiene el registro, sin condición: sirven para tablas de saltos
(cargar en `BL`/`BH` la dirección `tabla[i]` con dos `LDA` y luego `JMP BX`).

---

## 6. La ALU: operaciones y formas

Nueve operaciones, cada una en cuatro formas (familias 10–13):

| op | Mnemónico | Efecto | Flags |
|---|---|---|---|
| 0 | `MOV` | `dst = src` | — |
| 1 | `ADD` | `dst = dst + src` | N V Z C |
| 2 | `ADC` | `dst = dst + src + C` | N V Z C |
| 3 | `SUB` | `dst = dst − src` | N V Z C |
| 4 | `SBC` | `dst = dst − src − C` | N V Z C |
| 5 | `CMP` | flags de `dst − src`; `dst` no cambia | N V Z C |
| 6 | `AND` | `dst = dst & src` | N Z (C = V = 0) |
| 7 | `OR`  | `dst = dst \| src` | N Z (C = V = 0) |
| 8 | `XOR` | `dst = dst ^ src` | N Z (C = V = 0) |

| Forma | Bytes | Ejemplo | Bytes del ejemplo |
|---|---|---|---|
| `r,r` | `50+dst` `op<<3\|src` | `ADD AL,BL` | `50 0A` |
| `r,#imm8` | `58+r` `op` `imm` | `CMP CL,#0x0A` | `5C 05 0A` |
| `r,[addr16]` | `60+r` `op` `lo` `hi` | `SUB AL,[0x1234]` | `60 03 34 12` |
| `r,[r16]` | `68+r` `op<<2\|r16` | `ADD AL,[BX]` | `68 05` |

`MOV r,#imm8`, `MOV r,[addr16]` y `MOV r,[r16]` tienen su forma propia más
corta (familias 1, 2 y 4); el ensamblador las usa siempre.

**`ADC` y `SBC`** sirven para sumar y restar números de más de 8 bits a
trozos: la primera operación con `ADD`/`SUB` sobre los bytes bajos, y las
siguientes con `ADC`/`SBC`, que añaden (o restan) el acarreo que dejó la
anterior:

    ; 16 bits: [x_hi:x_lo] += [y_hi:y_lo]
    LDA AL,[x_lo]
    ADD AL,[y_lo]        ; C = 1 si se pasó de 255
    STA [x_lo],AL
    LDA AL,[x_hi]
    ADC AL,[y_hi]        ; suma también ese 1 que "me llevo"
    STA [x_hi],AL

---

## 7. Cómo quedan los flags

- **Aritmética** (`ADD`, `ADC`, `SUB`, `SBC`, `CMP`): `Z` si el resultado es 0,
  `N` = bit 7 del resultado.
  - `SUB`/`SBC`/`CMP`: `C` = 1 si hubo préstamo (`a < b`, o `a < b + C` en
    `SBC`). `V` = desbordamiento con signo.
  - `ADD`/`ADC`: `C` = 1 si la suma pasa de 255. `V` = desbordamiento con signo.
- **Lógica** (`AND`, `OR`, `XOR`, `NOT`): `Z` y `N` según el resultado; `C = V = 0`.
- **Desplazamientos** (`SHR`/`SHL r,#N`): resultado y flags iguales que
  desplazar N veces de 1 en 1. `C` = último bit que sale. `SHR`: `V` = bit 7
  de antes de la instrucción. `SHL`: `N` = bit 7, `V` = (C ≠ N).
- **`INC`/`DEC r`** (8 bits): `Z`, `N`, `V`; `C` no cambia (sección 4d).
- **`MUL`/`DIV`**: sección 4c.
- **`CMP r16`**: sección 4b.
- `MOV`, `LDA`, `STA`, `IN`, `OUT`, `PUSH`, `POP`, `JMP`, `CALL`, `RET`, `NOP`,
  `MOVB`/`MOVW`/`MOVBR`, `INC`/`DEC r16` y `MOV`/`ADD`/`SUB` de 16 bits **no
  tocan los flags**. Regla general: lo que calcula un valor de 8 bits que el
  programa puede querer comparar toca flags; mover datos o punteros no.
- `reset` (arranque de ejecución): todos los flags a 0.

---

## 8. Puertos de E/S (`IN` / `OUT`)

Espacio de 65536 puertos, **aparte de la memoria**. `IN` de un puerto no
mapeado devuelve 0; `OUT` a uno no mapeado no hace nada.

La pantalla (gráficos + texto + atributos) va en `0x0000`–`0x05FF`; el resto
de periféricos en `0x0600`–`0x0801`.

| Puerto | Dir. | Qué es |
|---|---|---|
| `0x0000` … `0x03FF` | E/S | **Gráficos** (framebuffer) 128×64. 1 puerto = 8 píxeles horizontales, bit 7 = izquierda, 1 = encendido. Puerto de `(xbyte, y)` = `y × 16 + xbyte` (xbyte 0–15, y 0–63). |
| `0x0400` … `0x04FF` | E/S | **Texto**. 1 puerto = 1 celda 6×8, superpuesta al gráfico. Puerto de `(col, fila)` = `0x0400 + fila × 32 + col` (fila 0–7, col 0–20). El byte es el código ASCII: `0` = celda transparente, `0x20` = celda en blanco, resto = glifo opaco. |
| `0x0500` … `0x05FF` | E/S | **Atributos de texto**. 1 puerto = atributos de la celda de texto correspondiente (misma fórmula que el texto: `0x0500 + fila × 32 + col`). Ver más abajo. |
| `0x0600` | IN | Encoder **ADDR**: posición (contador 0–255 que envuelve). |
| `0x0601` | IN | Encoder ADDR: bit 0 = pulsado. |
| `0x0602` | IN | Encoder **DATA**: posición. |
| `0x0603` | IN | Encoder DATA: bit 0 = pulsado. |
| `0x0610` | E/S | **LED** azul de a bordo: `OUT` bit 0 = 1 lo enciende. `IN` = eco. |
| `0x0611` | IN | **Número aleatorio**: un byte nuevo en cada lectura (generador por hardware del ESP32). |
| `0x0612` | E/S | **Ahorro de energía**: con cualquier programa en marcha la pantalla se atenúa a los 20 s sin tocar el panel y se apaga a los 45 s (como en edición). `OUT` bit 0 = 1 → antes: a los 5 s y a los 10 s; bit 1 = 1 → enciende la pantalla ya. `IN` bit 0 = modo ahorro, bit 1 = pantalla encendida. Vuelve a 0 al arrancar una ejecución. |
| `0x0614` | IN | **Batería**: carga aproximada 0–100 % (255 = aún sin medir). |
| `0x0615` | IN | **Batería**: tensión en pasos de 20 mV (210 = 4,20 V); 220 o más = alimentado por USB. Por debajo de 3,50 V el aparato avisa solo (icono de pila vacía y tres pitidos). |
| `0x0613` | OUT | **Dormir**: la CPU se para `n` × 10 ms y sigue en la instrucción siguiente. Mientras, el aparato no gasta (con la pantalla apagada y el modo ahorro, el ESP32 entra en reposo). Temporizadores, sonido y panel siguen. |
| `0x0620` … `0x0629` | E/S | **Temporizadores** t0…t9. `OUT` arma con 0–255; decrece solo hasta 0. `IN` lee el valor actual. |
| `0x0630` | E/S | **Sonido** – frecuencia, byte bajo (solo se engancha). |
| `0x0631` | E/S | **Sonido** – frecuencia, byte alto; al escribirlo suena `Hz = alto·256 + bajo` (0 = silencio). |
| `0x0632` | E/S | **Sonido** – nota MIDI 0–127 (0 = silencio). 69 = LA4 = 440 Hz, +12 = octava. La forma fácil. |
| `0x0633` | E/S | **Sonido** – duración automática = valor × 10 ms (0 = sostenida). "Pegajosa": cada nota la re-arma. |
| `0x0634` | E/S | **Sonido** – velocidad (fuerza) MIDI 1–127 de las notas siguientes, **solo por Bluetooth MIDI** (el zumbador suena igual). Pegajosa; 100 al arrancar. |
| `0x0635` | E/S | **Sonido** – instrumento de las notas siguientes: 0 ORGAN (constante), 1 PIANO, 2 GUITAR, 3 BELL. En el zumbador, la intensidad cae durante la nota (en 0,8 / 0,25 / 2 s); por Bluetooth MIDI, un Program Change (19, 0, 24, 14) antes de la nota siguiente. 0 al arrancar. |
| `0x0640` | E/S | **Cargar programa**: `OUT` con un número de slot (0–59) carga esa imagen entera en la RAM de la CPU y la reinicia (PC=0, SP=0xFFFF); también deja pantalla, LED y sonido apagados y los encoders a 0, igual que al entrar en una ejecución nueva por el panel — un salto a otro programa, sin vuelta atrás. Slot vacío o fuera de rango: no hace nada. `IN` = 1 si el último intento falló (solo tiene sentido leerlo tras un fallo: si la carga sale bien, quien iba a leerlo ya no es el programa que sigue corriendo). |
| `0x0641` | E/S | **Grabar programa**: `OUT` con un número de slot (0–59) graba ahí la RAM actual entera (equivale a "Guardar" del panel), con el nombre y la categoría del programa cargado. El programa sigue corriendo después. `IN` = 1 si la última grabación salió bien. |
| `0x0642` | E/S | **Consultar slot**: `OUT` con un número de slot lee su nombre y categoría a `0x0660`–`0x066E`. `IN` = 1 si ese slot tiene programa. |
| `0x0643` | IN | **Slot en curso**: el slot del que se cargó el programa que corre (para grabarse a sí mismo). |
| `0x0650` | E/S | **Brillo** de la pantalla, 0–255. `OUT` solo desde el slot 0 (SETTINGS de sisop); `IN` = valor actual. |
| `0x0651` | E/S | **Sonido** activado (≠0) / silenciado (0). `OUT` solo desde el slot 0; `IN` = 1 si está activado. |
| `0x0652` | OUT | **Grabar ajustes** (brillo y sonido) en la flash, si han cambiado. Solo desde el slot 0. |
| `0x0660` … `0x066E` | IN | **Metadatos del slot consultado**: `0x0660` = categoría (2 juego, 3 programa, 4 utilidad, 5 demo, 6 documentación, 1 sistema; `0xFF` = ninguna), `0x0661`… = nombre ASCII (hasta 14, relleno con 0). Los pone el ensamblador (`.name`, `.category`). |
| `0x0670` | E/S | **Hora real**: `OUT` congela la hora de ahora en `0x0671`–`0x067E` (para leerlas todas del mismo instante). `IN` = estado: bit 0 hay hora, bit 1 vino del Wi-Fi, bit 2 conectando, bit 3 hay red configurada. |
| `0x0671` … `0x0674` | IN | **Hora real**: segundos desde 1970 (UTC), byte bajo primero. |
| `0x0675` … `0x067B` | IN | **Hora real, local**: segundo, minuto, hora, día, mes, año − 2000, día de la semana (0 = domingo). |
| `0x067C` … `0x067E` | IN | **Hora real**: minutos locales desde el 1-1-2020 (24 bits): para contar cuánto ha pasado sin dividir. |
| `0x0700` … `0x07FF` | E/S | **EEPROM** del slot en curso: búfer de 256 bytes en RAM (instantáneo). |
| `0x0800` | E/S | **EEPROM**: `OUT` carga el búfer desde la flash. `IN` = 1 si falló. |
| `0x0801` | E/S | **EEPROM**: `OUT` graba el búfer en la flash. `IN` = 1 si salió bien. |

Gráficos, texto, atributos de texto, encoders, LED, temporizadores y sonido
se ponen a 0 cada vez que arranca una ejecución. En CONTINUOUS la pantalla es
el gráfico + el texto (refresco cada 125 ms, `FB_FLUSH_MS`).

**Texto** (`0x0400`–`0x04FF`): fuente monospace de 6×8 (5×7 de Adafruit GFX),
21 columnas × 8 filas. Para escribir una cadena, `OUT` carácter a carácter
incrementando el puerto (col + 1); no hay salto de línea automático. `IN`
devuelve el último carácter escrito en esa celda.

**Atributos de texto** (`0x0500`–`0x05FF`): un byte por celda, en la misma
disposición fila×32+col que el propio texto, justo a continuación de
`0x0400`–`0x04FF`. Se aplican al dibujar el carácter de esa celda; una
celda con carácter `0` (transparente) no dibuja nada aunque tenga atributos
puestos.

| Bit | Atributo | Efecto |
|---|---|---|
| 0 | inverso | intercambia fondo y trazo del carácter |
| 1 | parpadeo | deja de dibujarse la mitad de cada ciclo (~500 ms encendido, ~500 ms apagado) |
| 2 | subrayado | raya bajo el carácter |
| 3 | tachado | raya a media altura |
| 4 | subíndice | el carácter se desplaza 1 px hacia abajo dentro de la celda |
| 5 | superíndice | el carácter se desplaza 1 px hacia arriba (si se ponen 4 y 5 a la vez, gana subíndice) |
| 6–7 | rotación | `00`=0°, `01`=90°, `10`=180°, `11`=270°, sentido horario |

A esta resolución (glifos de 5×7 en una celda de 8 px de alto) no hay margen
para además encoger el carácter en subíndice/superíndice y que se siga
leyendo, así que solo se desplaza, a tamaño normal.

**Sonido** (`0x0630`–`0x0635`): zumbador piezo pasivo en GPIO2, o Bluetooth
MIDI (botón BOOT). `0x0634` solo cuenta por Bluetooth: la velocidad de la nota. Solo suena en
**CONTINUOUS**; se calla en paso a paso, al volver a EDIT y al `HALT`. Lo genera
el hardware, no gasta tiempo de CPU. Lo más simple: `OUT (0x0632),reg` con una
nota MIDI. Para efectos (sirenas, barridos) usa la frecuencia de 16 bits
(`0x0630` bajo, luego `0x0631` alto).

**Orden importante para un pitido con duración automática: `0x0633` SIEMPRE
antes que `0x0632`/`0x0631`.** `PORT_SND_DUR` es "pegajoso" pero no retroactivo:
al escribir la nota/frecuencia, el firmware arma el apagado automático con
el valor de `0x0633` que hubiera **en ese instante** (`sndApply()` en
`src/main.cpp`); escribirlo después no reprograma el pitido que ya empezó a
sonar, solo el siguiente. Si el orden es nota-luego-duración, el primer
pitido de la sesión suena sostenido para siempre (arranca con la duración a
0, su valor inicial) y, a partir de ahí, cada pitido usa por error la
duración del ANTERIOR en vez de la suya. Patrón correcto:
```
    MOV AL,#4          ; duración primero
    OUT (0x0633),AL    ; PORT_SND_DUR
    MOV AL,#69         ; luego la nota (o la frecuencia)
    OUT (0x0632),AL    ; PORT_SND_NOTE -- ya suena con la duración correcta
```

**Carga y grabado de programas** (`0x0640`–`0x0641`): dan acceso a los
mismos 60 slots de la flash (`storage.h`, `MAX_PROGRAM_SLOTS`) que usan el
panel físico y `tools/compi.py`, pero desde el propio programa
en ejecución — sirve para hacer un "menú" en un slot (típicamente el 0) que
liste y arranque otros: `OUT (0x0640),reg` con el número de slot salta a él
(carga sus 64 KiB en la RAM de la CPU y la reinicia, y de paso deja
pantalla/LED/sonido apagados y los encoders a 0, para que el programa que
arranca no herede nada del que lo cargó); `OUT (0x0641),reg` graba la RAM
actual en el slot dado y sigue ejecutando el mismo programa.
Igual que el resto de puertos, un slot vacío o un número ≥ 60 simplemente no
hace nada, no cuelga ni corrompe memoria.

**Ahorro de energía y dormir** (`0x0612`–`0x0613`): con un programa en
marcha, la pantalla se atenúa y se apaga igual que en edición (a los 20 y 45 s
sin tocar el panel; un giro o pulsación la enciende), y el panel se lee más
despacio si no se toca. Un programa que pase horas encendido, como
`tama.asm`, puede pedir tiempos más cortos (`OUT (0x0612),reg` con 1: 5 y
10 s) y, en vez de esperar dando vueltas en un bucle sobre un temporizador,
dormir: `MOV AL,#5` + `OUT (0x0613),AL` para 50 ms sin gastar.
Con la pantalla apagada, el primer giro o pulsación la enciende, y el
programa lo recibe igual: puede mirar el bit 1 de `IN (0x0612)` para no
tomarlo como una orden.

**Hora real** (`0x0670`–`0x067E`): la pone el Wi-Fi por NTP (la red que se le
haya dado con `tools/compi.py wifi` o, si no, cualquier red abierta: se
conecta un momento al arrancar y cada 12 h, y apaga la radio) o el PC por el USB (`tools/compi.py`, de paso en
cualquier orden, o `compi.py time`). Sin ninguna de las dos no hay hora:
el aparato no tiene pila. Patrón:
```
    OUT (0x0670),AL    ; congelar la hora de ahora
    IN  AL,(0x0670)
    AND AL,#1
    JMPZ sin_hora      ; bit 0 = 0: no hay hora
    IN  AL,(0x0677)    ; hora local (0..23)
```

**Temporizadores** (`0x0620`–`0x0629`): 10 cuentas atrás. Cada `t_i` baja 1
cada `1 << i` ms → t0 = 1 ms/paso, t1 = 2, t2 = 4, t3 = 8, t4 = 16, t5 = 32,
t6 = 64, t7 = 128, t8 = 256, t9 = 512 ms (t9: 255 → 0 en ~131 s). En
**CONTINUOUS** corren siempre; en **paso a paso** NO están del todo
congelados: avanzan según el tiempo real transcurrido entre un paso
ejecutado y el siguiente (nada mientras no se pulsa nada) — ver sección 1.
`IN` **no** cambia los flags: para esperar a que llegue a 0 hay que
`CMP reg,#0` antes del `JMPNZ`.

---

## 9. Programas de ejemplo (con sus bytes)

Teclea los bytes desde `0x0000`. Para ejecutar: `SW_MODE` = RUN.

### El LED sigue al pulsador DATA  *(RUN + CONTINUOUS)*
```
Dir  Bytes        Instrucción
0000 30 03 06     IN  AL,(0x0603)     ; lee el pulsador del encoder DATA
0003 38 10 06     OUT (0x0610),AL     ; lo manda al LED
0006 B8 00 00     JMP 0x0000          ; repetir para siempre
```
Pulsa el eje del encoder DATA → el LED se enciende. (Vuelve a EDIT para parar.)

### Escribir "HOLA" arriba a la izquierda  *(RUN + CONTINUOUS)*
```
Dir  Bytes        Instrucción
0000 08 48        MOV AL,#0x48        ; 'H'
0002 38 00 04     OUT (0x0400),AL     ; celda (col 0, fila 0)
0005 08 4F        MOV AL,#0x4F        ; 'O'
0007 38 01 04     OUT (0x0401),AL
000A 08 4C        MOV AL,#0x4C        ; 'L'
000C 38 02 04     OUT (0x0402),AL
000F 08 41        MOV AL,#0x41        ; 'A'
0011 38 03 04     OUT (0x0403),AL
0014 01           HALT
```
La fila siguiente empieza en `0x0420` (`0x0400 + 1×32`).

### Suma 5 + 3  *(RUN + SINGLE, paso a paso, para verlo)*
```
Dir  Bytes     Instrucción
0000 08 05     MOV AL,#0x05
0002 0A 03     MOV BL,#0x03
0004 50 0A     ADD AL,BL           ; AL = 8   (50 = ALU reg,reg con dst AL ; 0A = ADD(1)<<3 | src BL(2))
0006 01        HALT
```
O más corto, con inmediato: `08 05` `58 01 03` `01` (`MOV AL,#5` · `ADD AL,#3` · `HALT`).

### Tres puntos en el borde izquierdo de la pantalla  *(RUN + CONTINUOUS)*
```
Dir  Bytes        Instrucción
0000 08 80        MOV AL,#0x80        ; 0x80 = píxel más a la izquierda
0002 38 00 00     OUT (0x0000),AL     ; fila 0
0005 38 10 00     OUT (0x0010),AL     ; fila 1
0008 38 20 00     OUT (0x0020),AL     ; fila 2
000B 01           HALT
```

### Cuenta atrás desde 3 y para  *(bucle con `SUB` y `JMPNZ`)*
```
Dir  Bytes        Instrucción
0000 08 03        MOV AL,#0x03
0002 58 03 01     SUB AL,#0x01        ; AL = AL - 1
0005 BA 02 00     JMPNZ 0x0002        ; repite mientras AL != 0
0008 01           HALT
```
Míralo en **paso a paso** (`SW_STEP` en SINGLE): AL va 3 → 2 → 1 → 0 y para.

### Espera con temporizador y enciende el LED  *(RUN + CONTINUOUS)*
```
Dir  Bytes        Instrucción
0000 08 0A        MOV AL,#0x0A        ; 10 pasos de t5 (32 ms) ≈ 320 ms
0002 38 25 06     OUT (0x0625),AL     ; arma el temporizador 5
0005 30 25 06     IN  AL,(0x0625)     ; lee el temporizador
0008 58 05 00     CMP AL,#0x00        ; IN no toca flags: hay que comparar
000B BA 05 00     JMPNZ 0x0005        ; sigue esperando mientras != 0
000E 08 01        MOV AL,#0x01
0010 38 10 06     OUT (0x0610),AL     ; enciende el LED
0013 01           HALT
```
Cambia el temporizador (`0x0620`–`0x0629`) o el valor inicial para ajustar el
retardo. Recuerda: en paso a paso los temporizadores no avanzan.

### Dos notas: DO4 y luego SOL4  *(RUN + CONTINUOUS)*
```
Dir  Bytes        Instrucción
0000 08 0F        MOV AL,#0x0F        ; 15 × 10 ms = 150 ms por nota
0002 38 33 06     OUT (0x0633),AL     ; PORT_SND_DUR (se queda armado)
0005 08 3C        MOV AL,#0x3C        ; 60 = DO4 (~262 Hz)
0007 38 32 06     OUT (0x0632),AL     ; suena; se calla sola a los 150 ms
000A 08 14        MOV AL,#0x14        ; espera con t3 (8 ms): 20 pasos ≈ 160 ms
000C 38 23 06     OUT (0x0623),AL
000F 30 23 06     IN  AL,(0x0623)     ; ← espera
0012 58 05 00     CMP AL,#0x00
0015 BA 0F 00     JMPNZ 0x000F
0018 08 43        MOV AL,#0x43        ; 67 = SOL4 (~392 Hz)
001A 38 32 06     OUT (0x0632),AL
001D 01           HALT
```
Nota MIDI: 60 = DO4, 62 = RE, 64 = MI, 65 = FA, 67 = SOL, 69 = LA (440 Hz),
71 = SI, 72 = DO5. Sube/baja 12 para cambiar de octava.
