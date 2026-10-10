# compi_panel

Firmware del panel frontal de **compi**, un microcomputador de 8 bits emulado
con ISA propia y direcciones de 16 bits (no imita a ningún micro real). Corre en
un **ESP32-C3**.

- CPU emulada con **64 KiB** de RAM y direcciones de 16 bits.
- Panel: 2 encoders rotativos con pulsador + 2 interruptores, multiplexados por
  un 74HC165.
- Pantalla OLED SH1106 128×64: listado desensamblado al editar; framebuffer +
  capa de texto (puertos) al ejecutar.
- Salida de sonido: zumbador piezo pasivo (tono por hardware).
- Programas guardados/cargados en una flash SPI W25Q32 (60 slots de 64 KiB).

Se teclea el programa byte a byte, se guarda en la flash y se ejecuta paso a
paso o en continuo. Los registros solo se cargan ejecutando `MOV reg,#imm`.

El slot 0 lleva [`programs/sisop.asm`](programs/sisop.asm), un menú que se
carga al encender y monta solo sus carpetas (juegos, programas, utilidades,
demos, documentación) con el nombre y la categoría que cada programa graba
en su slot.

**ISA versión 2 (2026-10):** la codificación de las instrucciones cambió
entera (ver [`docs/isa.md`](docs/isa.md) §3). Tras flashear este firmware hay
que reenviar todos los programas con `tools/compi.py send`: los `.bin`
anteriores no son compatibles.

## Fuente de verdad: `specs.txt`

**[`specs.txt`](specs.txt) es la especificación completa y autoritativa** del
proyecto: ISA, semántica de la CPU, formato de la flash, pinout, panel,
máquina de estados, pantalla, puertos y constantes. El firmware se puede
regenerar entero a partir de ese archivo. Para cambiar el comportamiento del
aparato se edita `specs.txt` y luego se ajusta el código.

## Documentación de apoyo

| Documento | Contenido |
|---|---|
| [`docs/isa.md`](docs/isa.md) | **Referencia rápida del juego de instrucciones** (mnemónicos, bytes, ejemplos) — para empezar a programar. |
| [`docs/panel.svg`](docs/panel.svg) · [`docs/panel.png`](docs/panel.png) | Vista del panel de control (encoders, pantalla, switches y etiquetas). |
| [`docs/ports.svg`](docs/ports.svg) · [`docs/ports.png`](docs/ports.png) | Mapa del espacio de puertos (`IN` / `OUT`). |
| [`docs/hardware.md`](docs/hardware.md) | Mapa de pines y conexiones detalladas. |
| [`docs/wiring.svg`](docs/wiring.svg) · [`docs/wiring.png`](docs/wiring.png) | Diagrama de cableado. |
| [`docs/firmware.md`](docs/firmware.md) | Resumen de la arquitectura del código. |

## Compilar

```sh
pio run -t upload             # flashear por el USB-C del módulo (USB nativo del C3)
pio device monitor -b 115200
```

Board: `esp32-c3-devkitm-1` (ver [`platformio.ini`](platformio.ini)). Si el
`pio` del sistema falla (versión de `click` rota en algunos entornos), usar
`~/.platformio/penv/bin/pio` en su lugar.

## Programar desde el PC

Se puede escribir en ensamblador y grabar en un slot sin teclear byte a byte:

```sh
python3 tools/casm.py programs/demo.asm -o programs/demo.bin        # ensambla
python3 tools/sim.py  programs/demo.bin --steps 2000000             # prueba sin el aparato
python3 tools/compi.py send programs/demo.asm                       # slot, nombre y categoría salen del .asm

python3 tools/compi.py list                  # qué hay en cada slot
python3 tools/compi.py backup                # copia de TODO: programas, nombres y EEPROM
python3 tools/compi.py restore backups/compi-20261008-005444

# y al revés: sacar un slot del aparato (p. ej. uno editado a mano en el
# panel, que solo existe allí) de vuelta a un .bin, y verlo como texto
python3 tools/compi.py recv 4 -o vuelta.bin
python3 tools/compi_disasm.py vuelta.bin -o vuelta.asm
```

El puerto se busca solo (el USB-serie del ESP32-C3; `--port` para indicarlo
a mano), cada orden se reintenta si el aparato no contesta y todo se
comprueba con checksum.

- [`tools/casm.py`](tools/casm.py) — ensamblador (sintaxis = la del desensamblador
  + etiquetas y directivas). `tools/test_casm.py` lo verifica.
- [`tools/sim.py`](tools/sim.py) — emulador headless de la CPU y los puertos.
- [`tools/compi.py`](tools/compi.py) — todo lo que se hace con el aparato por
  USB: `list`, `send` (ensambla un `.asm` y lo graba con su nombre y
  categoría), `recv`, `backup`/`restore` (todos los slots, sus nombres y sus
  EEPROM; restore se salta lo que ya está igual) y `rm`. `send` **conserva
  los datos del programa**: las zonas que el `.asm` declara con `.persist`
  (p. ej. las canciones de `musicmaker.asm`) se leen del slot antes de grabar.
  Usa [`tools/compilink.py`](tools/compilink.py) (búsqueda del puerto,
  reintentos, protocolo; el firmware lo atiende en `provisionPoll()`, ver
  `specs.txt` §7).
- [`tools/compi_send.py`](tools/compi_send.py) /
  [`tools/compi_recv.py`](tools/compi_recv.py) — atajos de `compi.py send` /
  `recv` con las opciones de siempre (`--port` ya es opcional).
- [`tools/compi_disasm.py`](tools/compi_disasm.py) — vuelca un `.bin` como
  texto ensamblador, reensamblable byte a byte con `casm.py` (ver su
  docstring para el porqué y sus límites con datos incrustados en el código).
- [`programs/`](programs/) — programas de ejemplo, y en
  [`programs/lib/`](programs/lib/) rutinas comunes para `.include`
  (ver [`programs/README.md`](programs/README.md)).
  [`programs/demo.asm`](programs/demo.asm) es una demo de todas las
  capacidades (menú + gráficos, texto, sonido, animación, luces y un juego);
  va al **slot 23**.

**Hora real.** El aparato no tiene pila: la hora (puertos `0x0670`..) se la
da el Wi-Fi o el PC. Al encender se conecta un momento, pide la hora por NTP
y apaga la radio (y repite cada 12 h): a la red guardada con
`python3 tools/compi.py wifi MiRed` (pide la clave; se guarda en la flash)
o, si no hay o no va, a cualquier red abierta que encuentre. Sin Wi-Fi, cualquier orden de
`compi.py` le pone la hora y la zona horaria del PC de paso. `compi.py net`
enseña el estado. `compi.py sound bt|buzzer|off` cambia la salida del sonido
(como el botón BOOT) y `compi.py diag` dice si el Bluetooth MIDI está
encendido y conectado, reinicios, etc. La usan `reloj.asm` (se pone en hora solo) y `tama.asm`
(la mascota vive aunque el aparato esté apagado).

Si el USB deja de responder a veces, suele ser ModemManager abriendo el
puerto; la regla udev de [`docs/firmware.md`](docs/firmware.md) (sección de
provisioning) lo evita y además da permiso de acceso a `/dev/ttyACM0`.
