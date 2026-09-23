# Firmware — detalles de implementación

Notas de arquitectura. **La especificación completa y autoritativa está en
[`../specs.txt`](../specs.txt)** — este documento solo resume la estructura del
código. Para la electrónica, ver [`hardware.md`](hardware.md).

---

## 1. Estructura de archivos

PlatformIO compila **`src/`** y usa **`include/`** como ruta de cabeceras.

| Archivo | Contenido |
|---|---|
| `src/main.cpp` | pines, `setup()`, `loop()`, máquina de estados de la UI |
| `src/cpu.cpp` / `include/cpu.h` | núcleo de la CPU emulada, sin hardware |
| `include/isa.h` | opcodes, registros, flags (solo definiciones) |
| `include/iomap.h` | mapa del espacio de puertos: gráficos + texto + encoders + LED + temporizadores + sonido |
| `src/disasm.cpp` / `include/disasm.h` | desensamblador (byte → mnemónico) |
| `src/editor.cpp` / `include/editor.h` | selector de mnemónico de EditMem (mnemónico → bytes), sin hardware |
| `src/panel.cpp` / `include/panel.h` | lectura del panel (74HC165, encoders, pulsadores, switches) — solo hardware |
| `include/ui.h` | `enum View`, `PrgAction`, `struct UiState` (solo definiciones) |
| `src/display.cpp` / `include/display.h` | render en la OLED SH1106 (4 vistas) |
| `src/spi_flash_storage.cpp` / `include/spi_flash_storage.h` | driver de la flash SPI |
| `include/storage.h` | interfaz `IProgramStorage`; `PROGRAM_SIZE`, `MAX_PROGRAM_SLOTS` |

En la raíz solo hay `platformio.ini`, `README.md` y `specs.txt`. Todo el
código vive en `src/` e `include/`, dentro del namespace `compi`.

---

## 2. Modelo de memoria de la CPU

- `compi::kMemSize = 65536`: RAM = todo el espacio de 16 bits.
- `maskAddr(addr) = addr & (kMemSize - 1)` → identidad con 65536.
- `pc_`, `sp_` son `uint16_t`; `reset()` deja `sp_ = 0xFFFF`, `pc_ = 0`, regs y
  flags a 0. `reset()` **no** toca la memoria; para eso está `clearMemory()`.

### ⚠️ No renombrar `kMemSize` a `MEM_SIZE`

`lwIP` define `#define MEM_SIZE 1600` en `lwip/opt.h`, que entra por
`Arduino.h` en los SoC con USB-CDC nativo (ESP32-C3) y rompe la compilación.

---

## 3. Lectura del panel

`FrontPanel` es **solo lectura de hardware** (no guarda estado de UI). Todo
multiplexado por un 74HC165:

- 2 `RotaryEncoder` (cuadratura por sondeo; `takeDelta()` en detentes)
- 2 `PushButton` (antirrebote; la clase en sí solo da pulsación corta por
  flanco — `takePress()` — y nivel instantáneo — `down()`; la distinción
  corta/larga que usan `EditMem` y `ExecPaso` para el pulsador de DIRECCIÓN
  se construye en `main.cpp` por encima, cronometrando `down()` con
  `millis()`, no vive en esta clase)
- 2 `ToggleSwitch` (nivel con antirrebote)

`FrontPanel::update()` hace **una** lectura del 74HC165, reparte los bits y
actualiza `dirPos_`/`datPos_` (contadores absolutos que leen los puertos IN).
Lo llama un **`esp_timer`** (no `loop()`) a ritmo adaptativo — 2 ms con
actividad, 4 ms con la pantalla encendida sin tocar, 8 ms en reposo — así el
panel sigue respondiendo aunque `loop()` esté bloqueado en el volcado I2C de la
OLED (~30 ms) o en un guardado de flash (~1 s). Un spinlock (`mux_`) protege los
contadores frente a esa concurrencia; `update()` devuelve `true` si hubo
actividad del usuario (lo usa el gestor de energía). Ver `specs.txt` §11 y §16.

Expone: `ejecutar()`, `swAbajo()`, `takeDirDelta/DatDelta()`,
`takeDirPress/DatPress()`, `dirPos/datPos()`, `dirDown/datDown()`.

### Energía (batería)

`main.cpp` atenúa la OLED a los 20 s de inactividad, la apaga a los 45 s
(`oled.power/contrast`), y entra en **light sleep** a los 45 s si no hay
programa ejecutando ni host USB-CDC conectado (`!Serial`). Light sleep conserva
los 64 KiB de RAM emulada y despierta en <1 ms. La flash está en **deep
power-down** (~1 µA) salvo al leer/escribir un slot. `-DCOMPI_NO_LIGHT_SLEEP`
desactiva el sleep. Detalle y consumo: `specs.txt` §16.

---

## 4. Máquina de estados (en `loop()`, ver `specs.txt` §12)

La **vista** es función pura de los dos interruptores — nada oculto:

| SW_MODE | SW_STEP | Vista | Pantalla |
|---|---|---|---|
| EDIT | ▲ | `EditMem` | listado desensamblado + registros |
| EDIT | ▼ | `EditPrg` | selector de slot + previsualización |
| RUN | ▲ | `ExecPaso` | listado + registros, `*` en el PC |
| RUN | ▼ | `ExecCont` | framebuffer del programa |

| Vista | ADDR girar | ADDR pulsar CORTA | ADDR pulsar LARGA | DATA girar | DATA pulsar |
|---|---|---|---|---|---|
| `EditMem` | cursor ± instrucción entera (`stepCursorByInstr`, nunca a mitad de una de 2/3 bytes) | inserta un NOP en el cursor (`insertByteAt`, desplaza el resto) | borra el byte del cursor (`deleteByteAt`, desplaza el resto) | cambia el campo activo del selector de mnemónico (en vivo); en el campo Verb, alfabético (`kVerbAlpha`) | confirma campo → siguiente / avanza dirección |
| `EditPrg` | slot 0–59 (siempre vuelve a LOAD) | ejecutar la acción elegida (igual que DATA pulsar) | (igual que corta aquí) | cicla la acción LOAD → SAVE → NEW | ejecutar la acción elegida |
| `ExecPaso` | elige una dirección OBJETIVO (`ui.cursor`) sin ejecutar nada; el listado la sigue mientras se elige | ejecuta hacia ADELANTE hasta que el PC llegue a esa dirección (a trozos de `EXEC_BATCH`, sin bloquear) | `cpu.reset()` (igual que "RESET" de la fila de abajo) | 1 instrucción por detente, solo hacia ADELANTE (atrás no hace nada: no hay forma de deshacer) | 1 instrucción |
| `ExecCont` | → programa (IN) | → programa (IN) | → programa (IN) | → programa (IN) | → programa (IN) |

Insertar/borrar y "ejecutar hasta aquí"/reset usan el mismo gesto de
pulsación corta/larga (`DIR_LONG_PRESS_MS` = 500 ms, nivel vía `panel.dirDown()`,
no flanco): la larga se dispara en cuanto se cumple el umbral, sin esperar a
soltar. En `EditPrg`, ADDR y DATA pulsar hacen lo mismo (ejecutar la acción
elegida), así que si `prgAction` está en SAVE cualquiera de los dos guarda.

(El editor de instrucciones campo a campo se explica en `editor.cpp` más abajo
y en `specs.txt` §12; el detalle de `ExecPaso` en `specs.txt` §12 también.)

- Cualquier (re)inicio de ejecución — entrar en RUN, entrar en ▼ CONTINUOUS,
  o pulsación larga de ADDR en STEP — hace `cpu.reset()` (PC=0) +
  `resetPositions()` + borra el framebuffer y la capa de texto + `g_led=0` +
  `resetTimers()` + `resetSound()`. Entrar en ▲ STEP solo congela (sin reset).
- Volver a EDIT **no** resetea: se ve dónde quedó el PC.
- `ExecCont`: la CPU corre por lotes (`EXEC_BATCH`) hasta HALT; el framebuffer
  se vuelca cada `FB_FLUSH_MS` (con aviso "HALT" si procede).
- `EditPrg`: al cambiar de slot se releen `PREVIEW_BYTES` de la flash para la
  previsualización.
- Un programa = imagen completa de 64 KiB. Guardar (`flash.saveProgram(slot,
  cpu.ram())`) bloquea ~1 s y muestra "SAVING slot NN". Cargar
  (`flash.loadProgram(slot, cpu.ram())`) sobrescribe toda la RAM + `cpu.reset()`.
  60 slots en la flash de 4 MiB.

**No hay edición directa de registros**: se cargan ejecutando `MOV reg,#imm`
(opcode `OP_LDI`). Un valor de 16 bits se teclea en dos bytes.

---

## 4b. E/S del programa: espacio de puertos (`iomap.h`)

`IN`/`OUT` usan un **puerto de 16 bits** (operando de 3 bytes). Espacio de
65536 puertos, aparte de la RAM.

La pantalla (gráficos + texto + atributos) ocupa `0x0000..0x05FF`; el resto de
periféricos va en `0x06xx`.

- **Gráficos** (framebuffer): puertos `0x0000..0x03FF` (1024 B, lectura y
  escritura). 1 puerto = 8 px horizontales, bit 7 = izquierda, 1 = encendido.
  El buffer vive en `g_fb` (main.cpp), no en la RAM de la CPU.
- **Texto**: puertos `0x0400..0x04FF`. Rejilla monospace `TEXT_COLS`×`TEXT_ROWS`
  = 21×8 (fuente 6×8 propia, `font5x7.h` -- copia de `glcdfont.c` de Adafruit
  GFX recortada a `0x20..0x7F`, ver más abajo). Puerto = `0x0400 +
  fila*TEXT_STRIDE + col` (`TEXT_STRIDE` = 32; `textIndex()` valida y mapea a
  `g_text[fila*21+col]`). El byte es el código de carácter: `0` = celda
  transparente, `0x20` = blanco, resto = glifo opaco.
- **Atributos de texto**: puertos `0x0500..0x05FF`, misma disposición que el
  texto (`attrIndex()` mapea a `g_attr[fila*21+col]`; `attrPort()`/`ATTR_*` en
  `iomap.h`, ver `docs/isa.md` §8 para el significado de cada bit). Va pegado
  a `0x0400..0x04FF`; encoders/LED/temporizadores/sonido se desplazaron en
  bloque a `0x0600+` para dejarle el hueco.
  `renderFramebuffer(g_fb, g_text, g_attr, halted)` compone: blit del
  framebuffer + `drawTextCell()` (display.cpp) por celda no nula, aplicando
  sus atributos, + overlay "HALT". `drawTextCell()` no usa
  `Adafruit_GFX::drawChar()`: esa función no rota un carácter por separado
  (solo la pantalla entera), así que recorre `font5x7.h` píxel a píxel para
  poder rotarlo, desplazarlo (sub/superíndice) e invertirlo. Con
  atributos a 0 el resultado es idéntico, píxel a píxel, al `drawChar` de
  antes.
- **Encoders** (solo `IN`): `PORT_DIR_POS` 0x0600 / `PORT_DAT_POS` 0x0602 =
  posición absoluta (0–255, envuelve); `PORT_DIR_BTN` 0x0601 / `PORT_DAT_BTN`
  0x0603 = bit 0 = pulsador.
- **LED de a bordo** (`OUT`/`IN`): `PORT_LED` 0x0610, bit 0 controla el LED
  azul del SuperMini (GPIO8). Se apaga al (re)iniciar una ejecución.
- **Temporizadores** (`OUT`/`IN`): `PORT_TIMER_BASE` 0x0620..0x0629, 10 cuentas
  atrás. `OUT` arma con 0–255; decrecen solas de 1 en 1 hasta 0. El timer `i`
  baja 1 cada `TIMER_BASE_MS << i` ms (1, 2, 4, 8, 16, 32, 64, 128, 256, 512 ms).
  `IN` lee el valor actual. En `ExecCont`, `tickTimers()` corre una vez por
  vuelta de `loop()`, sin condiciones. En `ExecPaso` NO están del todo
  congelados: `tickTimers()` se llama justo antes de cada acción que
  ejecuta algo de verdad (pulsar/girar DATA, o cada tanda de una carrera de
  ADDR), con el tiempo real transcurrido desde la última vez -- si no se
  ejecuta nada, el reloj de cada temporizador no avanza. En la práctica los
  rápidos (≤128 ms/paso) casi siempre leen 0 nada más pulsar otra vez
  (ninguna pulsación humana es tan rápida), pero t8/t9 (256/512 ms) sí
  pueden reflejar el tiempo real entre pasos. `resetTimers()` los pone a 0
  al (re)iniciar una ejecución. `IN` **no** toca flags: para un bucle de espera
  hay que `CMP reg,#0` antes del `JMPNZ`.
- **Sonido** (`OUT`/`IN`): `PORT_SND_BASE` 0x0630..0x0633, zumbador piezo pasivo
  en `PIN_BUZZER` (GPIO3). `0x0630`/`0x0631` = frecuencia de 16 bits (LO
  engancha, HI aplica `Hz=hi<<8|lo`); `0x0632` = nota MIDI 0–127 (`noteToHz()`,
  `440·2^((n-69)/12)`); `0x0633` = auto-apagado `valor·10 ms` (pegajoso). El
  tono lo genera `tone()` (LEDC), no gasta CPU. `sndApply(hz)` centraliza
  `tone`/`noTone` y (re)arma `g_sndOffAt`. `tickSound()` aplica el auto-apagado
  en `ExecCont`; `resetSound()` calla y pone los 4 registros a 0. Se silencia
  también al salir de `ExecCont` y al `HALT` (`if (g_sndHz) sndApply(0)`).
- `main` fija `cpu.setPortRead(portRead)` y `cpu.setPortWrite(portWrite)`.
  Los contadores de posición viven en `FrontPanel`.

---

## 4c. Provisioning por USB-CDC (`main.cpp`)

`provisionPoll()` se sondea al principio de cada `loop()`, leyendo líneas del
puerto serie (115200 baudios). Dos protocolos, simétricos:

- **LOAD** (host → aparato, `provisionLoad()`): `"COMPI LOAD <slot> <len>\n"`
  + `<len>` bytes a trozos de `COMPI_CHUNK` (1024), con eco `"COMPI CHUNK
  <n>"` por bloque -- necesario porque la cola de RECEPCIÓN del USB-CDC
  nativo del C3 es de solo 256 B por defecto y descarta en silencio si se
  llena. Escribe directo en `cpu.ram()` y de ahí a `flash.saveProgram()`.
- **DUMP** (aparato → host, `provisionDump()`): `"COMPI DUMP <slot>
  [<len>]\n"` (`<len>` opcional, por defecto `PROGRAM_SIZE`) → lee el slot
  con `flash.loadProgram()` y lo manda de un tirón (`Serial.write()`, sin
  trocear: para ENVIAR no hay el problema de cola pequeña de LOAD).

Las dos terminan con `"COMPI OK <sum>"` (checksum de los bytes) o `"COMPI
ERR <motivo>"`. Detalle completo del protocolo: `specs.txt` §7. Herramientas
de host: `tools/compi_send.py` (LOAD), `tools/compi_recv.py` (DUMP) y
`tools/compi_disasm.py` (vuelca un `.bin` como texto ensamblador,
reensamblable byte a byte con `casm.py` -- ver su docstring para el porqué).

---

## 5. Desensamblador (`disasm.cpp`)

Trabaja sobre un buffer plano `(mem, memLen)`; direcciones `>= memLen` leen 0.

- `disassemble(mem, memLen, addr, out, n)` → mnemónico + longitud (1–3).
- `instrLen(mem, memLen, addr)` → longitud sin formatear.
- `listBase(mem, memLen, anchor)` → inicio de instrucción anterior al que
  contiene `anchor` (recorriendo desde 0), para dar una línea de contexto.
- `prevInstrStart(mem, memLen, addr)` → inicio de la instrucción
  INMEDIATAMENTE anterior a `addr` (recorriendo desde 0, igual que
  `listBase`); lo usa la navegación instrucción a instrucción de ADDR
  girar/pulsar en `EditMem` y `ExecPaso` (`stepCursorByInstr` en `main.cpp`).
- Para la RAM: `(cpu.ram(), 65536)`. Para la previsualización de un slot:
  `(g_preview, PREVIEW_BYTES)`.
- Las 7 ops de la ALU (`MOV ADD SUB CMP AND OR XOR`) tienen forma `reg,src`
  (`OP_EXT`, `0xF8+op`) y `reg,#imm` (`OP_ALUI`, `0xA0+op`); las que además
  operan con memoria son familias 5–9. `MOV reg,#imm` es `OP_LDI` (más corto).
  Familias reservadas → `DB 0xXX`. Detalle en [`isa.md`](isa.md).

---

## 5b. Selector de mnemónico (`editor.cpp`)

El "desensamblador al revés" de la vista `EditMem`: compone una instrucción
campo a campo (verbo → mode → operandos) en vez de teclear el byte crudo.
Trabaja sobre un buffer plano, igual que `disasm.cpp`, y vive en `ui.compose`.
Sin dependencias de hardware ni de `cpu`/`disasm` -- por eso `insertByteAt`/
`deleteByteAt` (que sí necesitan `cpu.sp()`) viven en `main.cpp`, no aquí.

- `ComposeState`: `verb, mode, reg, dst, src, cond, imm, addr16, ptr, shift,
  step`. `mode` distingue las formas de un verbo con varias (p. ej. LDA/STA/
  IN/OUT: `[addr16]` inmediato vs `[AX|BX|CX|DX]` indirecto por `ptr`;
  SHR/SHL: 1 bit vs `reg,#N` con `N` en `shift`).
- `fieldAt(verb, mode, step)` → qué campo toca ahora (`Verb/Mode/Cond/Reg/
  Dst/Src/Imm/Lo/Hi/Ptr/Shift/Done`); `lastStep(verb, mode)` → último paso
  con campo real (pulsar DATA ahí avanza la dirección en vez de pasar de
  campo).
- `applyDelta(st, delta)` → gira DATA: cambia el campo activo, con wrap. En
  el campo Verb, el wrap recorre `kVerbAlpha` -- ORDEN ALFABÉTICO por nombre
  (`verbName()`), no el orden interno del enum `Verb` (que agrupa por
  familia de opcode). Cambiar el verbo reinicia los demás campos a 0.
- `verbName(verb)` → nombre corto ("NOP", "MOV"...) para la cabecera de
  `EditMem` mientras se elige el verbo (con el tamaño ya ensamblado al lado,
  ver `display.cpp`).
- `assemble(mem, memLen, addr, st)` → escribe en el sitio (nunca desplaza),
  devuelve la longitud. Se llama en cada giro (edición en vivo).
- `decodeAt(mem, memLen, addr)` → reconstruye el estado a partir de lo que ya
  hay en memoria; se llama al entrar en la vista, al mover el cursor y tras
  cargar un programa (`loadSlot`, provisioning).

`insertByteAt(cursor)`/`deleteByteAt(cursor)` (`main.cpp`, no `editor.cpp`):
desplazan `[cursor, sp-2]`/`[cursor+1, sp-1]` un byte adelante/atrás,
usando `cpu.sp()` en ese instante como límite -- nunca leen ni escriben en
`[sp, 0xFFFF]` (la pila). Se disparan con la pulsación corta/larga de ADDR
en `EditMem` (ver la tabla de la sección 4).

Detalle de la interacción: `specs.txt` §12, [`isa.md`](isa.md) §1.

---

## 6. Pantalla (`display.cpp`)

128×64, fuente 6×8 (21 columnas × 8 filas). `render(cpu, ui)` elige la vista:

- **`EditMem` / `ExecPaso`**: cabecera + 5 líneas de listado + 2 de estado.
  Marcas en el listado: `>` cursor de edición (solo `EditMem`), `*` PC,
  `#` dirección objetivo de ADDR en `ExecPaso` si no coincide ya con el PC
  (`*` gana). Cabecera: en `EditMem`, dirección + campo activo del selector
  (o nombre+tamaño del verbo mientras se elige, ver 5b); en `ExecPaso`,
  `"PC=%04X A=%04X"` (+ `" HLT"` si `halted()`). El ancla del listado
  (`ui.pasoFollowCursor`) es el cursor mientras se elige un objetivo girando
  ADDR, y el PC en cuanto se ejecuta algo -- el PC debe verse siempre que
  algo se está ejecutando. Estado: los 6 registros (AX BX CX DX PC SP) y
  los flags siempre visibles.
- **`EditPrg`**: `PRG slot NN [prog/----]`, la acción `LOAD`/`SAVE
  [overwrite]`/`NEW [blank RAM]` en vídeo inverso, y una previsualización
  desensamblada del slot (o `"(slot empty)"`).
- **`ExecCont`**: `renderFramebuffer(g_fb, g_text, halted)` — vuelca el
  framebuffer, compone la capa de texto y superpone "HALT" si procede.

`render()` es sin estado: recalcula todo cada frame.

---

## 7. Compilar y flashear

```sh
pio run -t upload             # por el USB-C del SuperMini (USB nativo)
pio device monitor -b 115200
```

> El CLI de `pio` del entorno de desarrollo actual está roto (versión de
> `click`); usar `~/.platformio/penv/bin/pio` en su lugar. El código sin
> dependencias de Arduino (`cpu.cpp`, `disasm.cpp`, `editor.cpp` -- NO
> `panel.cpp`, que sí depende de `Arduino.h`) compila suelto con
> `g++ -std=c++17`, útil para probar contra un `Cpu` real sin la placa.

---

## 8. Cabos sueltos

- El listado se alinea siempre desde 0x0000; una zona de datos puede verse
  "torcida" (no hay mejor referencia).
- En `ExecPaso` el listado sigue al PC salvo mientras se gira ADDR para
  elegir una dirección objetivo (ahí sí se puede "hojear" el código); en
  cuanto se ejecuta algo, vuelve a seguir al PC (ver sección 6).
- La previsualización del slot (`EditPrg`) lee solo `PREVIEW_BYTES` bytes de la
  flash; puede cortar la última instrucción mostrada.
- LED de fallo: el LED de a bordo del SuperMini (GPIO8, activo bajo).
- En el SuperMini el USB nativo ocupa GPIO18/19; el I2C va en GPIO20/21.
