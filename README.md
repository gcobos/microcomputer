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
python3 tools/compi_send.py --port /dev/ttyACM0 --slot 4 programs/demo.bin

# y al revés: sacar un slot del aparato (p. ej. uno editado a mano en el
# panel, que solo existe allí) de vuelta a un .bin, y verlo como texto
python3 tools/compi_recv.py --port /dev/ttyACM0 --slot 4 -o vuelta.bin
python3 tools/compi_disasm.py vuelta.bin -o vuelta.asm
```

- [`tools/casm.py`](tools/casm.py) — ensamblador (sintaxis = la del desensamblador
  + etiquetas y directivas). `tools/test_casm.py` lo verifica.
- [`tools/sim.py`](tools/sim.py) — emulador headless de la CPU y los puertos.
- [`tools/compi_send.py`](tools/compi_send.py) — graba una imagen en un slot por
  USB-CDC (protocolo LOAD, el firmware la recibe en `provisionPoll()`, ver
  `specs.txt` §7).
- [`tools/compi_recv.py`](tools/compi_recv.py) — saca la imagen de un slot por
  USB-CDC (protocolo DUMP, simétrico de LOAD; admite `--len` para traer solo
  un trozo).
- [`tools/compi_disasm.py`](tools/compi_disasm.py) — vuelca un `.bin` como
  texto ensamblador, reensamblable byte a byte con `casm.py` (ver su
  docstring para el porqué y sus límites con datos incrustados en el código).
- [`programs/`](programs/) — programas de ejemplo. [`programs/demo.asm`](programs/demo.asm)
  es una demo de todas las capacidades (menú + gráficos, texto, sonido,
  animación, luces y un juego); va al **slot 4**.
