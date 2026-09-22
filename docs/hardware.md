# Hardware — panel frontal del microcomputador compi

Referencia de la electrónica: elección de placa, mapa de pines, conexiones y
lista de materiales. **La fuente de verdad del proyecto es `specs.txt`**; si
cambias un pin, actualízalo allí y aquí, y regenera el diagrama.

Diagrama de cableado: [`wiring.svg`](wiring.svg) / [`wiring.png`](wiring.png).
Vista del panel: [`panel.svg`](panel.svg). Mapa de puertos: [`ports.svg`](ports.svg).
Regenerar un PNG: `inkscape wiring.svg -o wiring.png -w 2200` (ídem panel, ports).

---

## 1. Placa: ESP32-C3

La CPU emulada reserva un array estático de **64 KiB** (`kMemSize = 65536`
en [`include/cpu.h`](../include/cpu.h)) para cubrir todo el espacio de
direcciones de 16 bits. Eso descarta las otras placas a mano:

| Placa | SRAM útil | Array de 64 KiB |
|---|---|---|
| Arduino Nano (ATmega328P) | 2 KiB | imposible |
| Wemos D1 R1 (ESP8266) | ~50 KiB | no enlaza (`dram0` overflow) |
| **ESP32-C3** | ~320 KiB | entra de sobra |

Módulo real: **ESP32-C3 SuperMini**. Board de PlatformIO: `esp32-c3-devkitm-1`
+ `build_flags = -DARDUINO_USB_MODE=1 -DARDUINO_USB_CDC_ON_BOOT=1` (ver
[`platformio.ini`](../platformio.ini)).

El SuperMini expone 13 GPIO: **IO0–IO10, IO20, IO21**.

### Pines que NO se pueden usar

| Pines | Motivo |
|---|---|
| GPIO18, GPIO19 | USB nativo del C3; **no salen a los pads del SuperMini** |
| GPIO2, GPIO9 | *strapping*. GPIO9 = botón BOOT |
| GPIO8 | *strapping*, pero se usa para el LED azul de a bordo (OK como salida) |
| GPIO11–GPIO17 | flash SPI interna del módulo |

Libres: **GPIO0, 1, 3, 4, 5, 6, 7, 10, 20, 21** (10 pines). El diseño los usa
todos: GPIO3 = zumbador piezo (sección 9).

### Flasheo

Por el **USB-C del módulo** (USB nativo del C3). No hay puente USB-UART. Si el
auto-reset falla, mantener pulsado **BOOT (GPIO9)** al enchufar.

---

## 2. Mapa de pines del ESP32-C3

Definido en [`src/main.cpp`](../src/main.cpp). SPI (SCK/MISO/MOSI) usa los
pines por defecto del C3; el driver de la flash los toma solo.

| GPIO | Señal | Dir | Conecta con |
|---|---|---|---|
| 0  | 74HC165 CP (reloj) | salida | pin 2 (CLK) |
| 1  | 74HC165 Q7 (datos serie) | entrada | pin 9 (Q7) |
| 3  | Sonido (tono PWM/LEDC) | salida | zumbador piezo pasivo → GND (sección 9) |
| 4  | SPI SCK | salida | flash pin 6 (CLK) |
| 5  | SPI MISO | entrada | flash pin 2 (DO) |
| 6  | SPI MOSI | salida | flash pin 5 (DI) |
| 7  | Flash /CS | salida | flash pin 1 (/CS) **+ `[10 kΩ]` a 3V3** |
| 8  | LED de fallo | salida | LED azul de a bordo (**activo a nivel bajo**) |
| 10 | 74HC165 PL (SH/LD) | salida | pin 1 (SH/LD) |
| 20 | I2C SDA | bidir | OLED SDA |
| 21 | I2C SCL | salida | OLED SCL |
| 3V3 | alimentación | — | VCC de 74HC165, flash y OLED |
| 5V / VBUS | alimentación (opc.) | entrada | batería, por el interruptor (sección 10) |
| GND | masa | — | GND común |

---

## 3. Un 74HC165 (entradas del panel)

Las **8 entradas** del panel (2 encoders × 2 señales + 2 pulsadores + 2
interruptores) se multiplexan con un solo 74HC165. Cuesta 3 pines del micro.

> **74HC165, no 74HCT165.** El HC funciona a 3,3 V con umbrales CMOS.

### Conexiones del integrado (DIP-16)

| Pin | Nombre | Va a |
|---|---|---|
| 1 | SH/LD (PL) | GPIO10 |
| 2 | CLK (CP) | GPIO0 |
| 3 | D4 | entrada DATA_B (ver tabla) `+ [10 kΩ]` a 3V3 |
| 4 | D5 | entrada DATA_SW `+ [10 kΩ]` a 3V3 |
| 5 | D6 | entrada SW_MODE `+ [10 kΩ]` a 3V3 |
| 6 | D7 | entrada SW_STEP `+ [10 kΩ]` a 3V3 |
| 7 | /Q7 | sin conectar |
| 8 | GND | GND |
| 9 | Q7 | GPIO1 |
| 10 | SER (DS) | GND |
| 11 | D0 | entrada ADDR_A `+ [10 kΩ]` a 3V3 |
| 12 | D1 | entrada ADDR_B `+ [10 kΩ]` a 3V3 |
| 13 | D2 | entrada ADDR_SW `+ [10 kΩ]` a 3V3 |
| 14 | D3 | entrada DATA_A `+ [10 kΩ]` a 3V3 |
| 15 | CLK INH | GND |
| 16 | VCC | 3V3 (+ 100 nF a GND) |

### Mapa entrada → señal

`ShiftRegister165::read()` devuelve un byte; entrada **Dk → bit (7 − k)**.
Definido en [`src/panel.cpp`](../src/panel.cpp).

| Pin · entrada | bit | Señal | Componente |
|---|---|---|---|
| 11 · D0 | 7 | ADDR_A  | Encoder ADDR, señal A |
| 12 · D1 | 6 | ADDR_B  | Encoder ADDR, señal B |
| 13 · D2 | 5 | ADDR_SW | Encoder ADDR, pulsador |
| 14 · D3 | 4 | DATA_A  | Encoder DATA, señal A |
| 3 · D4  | 3 | DATA_B  | Encoder DATA, señal B |
| 4 · D5  | 2 | DATA_SW | Encoder DATA, pulsador |
| 5 · D6  | 1 | SW_MODE | Interruptor EDIT / RUN |
| 6 · D7  | 0 | SW_STEP | Interruptor ▲ / ▼ (significado según SW_MODE) |

**Nivel bajo = activo** (contacto a GND). Cada entrada usada lleva un
pull-up de 10 kΩ a 3V3 (el 74HC165 no tiene pull-ups internos).

### Encoders (EC11 o similar)

- Terminales A y B → D0/D1 (ADDR), D3/D4 (DATA), cada uno con pull-up.
- Terminal común (C) → GND.
- Pulsador: una pata → D2/D5 con pull-up, otra → GND.

Decodificación por cuadratura, por sondeo (sin interrupciones). `ENC_DIVISOR`
en [`panel.h`](../include/panel.h) = transiciones por detente (4 para EC11).

### Interruptores SW_MODE y SW_STEP (SPST)

- Una pata → D6 / D7 con pull-up de 10 kΩ a 3V3.
- Otra pata → GND.
- **SW_MODE**: abierto (▲) = `EDIT` · cerrado (▼) = `RUN`.
- **SW_STEP**: abierto (▲) / cerrado (▼); su significado depende de SW_MODE:
  - editando: ▲ = memoria (teclear) · ▼ = programas (cargar/guardar)
  - ejecutando: ▲ = paso a paso · ▼ = continuo
- Ver el detalle de cada vista en `specs.txt` §12 y en `docs/panel.svg`.

---

## 4. Flash SPI — W25Q32 (25Q32FVSIG)

Winbond 32 Mbit / 4 MiB. Driver propio en
[`src/spi_flash_storage.cpp`](../src/spi_flash_storage.cpp).

| Flash (SOIC-8) | Pin | Va a |
|---|---|---|
| 1 | /CS   | GPIO7 **+ `[10 kΩ]` a 3V3** |
| 2 | DO    | GPIO5 (MISO) |
| 3 | /WP   | 3V3 |
| 4 | GND   | GND |
| 5 | DI    | GPIO6 (MOSI) |
| 6 | CLK   | GPIO4 (SCK) |
| 7 | /HOLD | 3V3 |
| 8 | VCC   | 3V3 (+ 100 nF a GND) |

- /WP y /HOLD **a 3V3** obligatorio.
- Reloj SPI a 8 MHz (`kFlashSpiSettings` en el .cpp).
- Un programa = imagen completa de la RAM (64 KiB). Un slot = 17 sectores de
  4 KiB (69632 B); caben **60 slots** en los 4 MiB.
- Guardar bloquea ~1 s (17 borrados de sector); cargar es rápido (~70 ms).
- `init()` comprueba el JEDEC ID: fabricante `0xEF` (Winbond).

---

## 5. Pantalla OLED — SH1106 128×64 I2C

Controlador **SH1106** (no SSD1306). Librería `adafruit/Adafruit SH110X`.

| OLED | Va a |
|---|---|
| VCC | 3V3 |
| GND | GND |
| SDA | GPIO20 |
| SCL | GPIO21 |

- Dirección `0x3C` por defecto; si no responde, `0x3D`.
- La mayoría de módulos llevan pull-ups de I2C. Si no, 4,7 kΩ a 3V3 en SDA/SCL.

---

## 6. LED de a bordo (GPIO8)

- El LED azul de a bordo del SuperMini, **activo a nivel bajo**
  (`digitalWrite(8, LOW)` = encendido). No hace falta LED externo.
- Doble uso:
  - **failBlink**: aviso de fallo en el arranque (parpadeo lento/rápido).
  - **salida del ordenador emulado**: puerto `PORT_LED` (0x0610) — `OUT` bit 0.
- `PIN_LED` / `PIN_LED_ACTIVE_LOW` en [`src/main.cpp`](../src/main.cpp).

| Ritmo de parpadeo | Fallo |
|---|---|
| lento (200 ms) | la pantalla OLED no responde |
| rápido (80 ms)  | la flash SPI no responde / JEDEC ID incorrecto |

Fuera del arranque, el LED lo controla el programa emulado con `OUT (0x0610),reg`.

---

## 7. Lista de materiales

| Cant. | Componente |
|---|---|
| 1 | ESP32-C3 SuperMini |
| 1 | 74HC165 (DIP-16 o SOIC-16) — **HC**, no HCT |
| 2 | encoder rotativo incremental con pulsador (EC11 o similar) |
| 2 | interruptores SPST panel (SW_MODE, SW_STEP) |
| 1 | módulo OLED SH1106 128×64 I2C |
| 1 | módulo flash SPI W25Q32 / 25Q32FVSIG (Winbond, 4 MiB) |
| 9 | resistencias 10 kΩ, 1/4 W (8 pull-ups de entrada + 1 en /CS de la flash) |
| ~3 | condensadores cerámicos 100 nF, 50 V, X7R (desacoplo: 74HC165, flash; el de la OLED sobra si el módulo ya lo lleva) |
| 1 | zumbador **piezo pasivo** (sección 9) |
| 0–1 | resistencia 100 Ω, 1/4 W, en serie con el piezo (opcional) |
| 1 | batería LiPo 1S 3,7 V, conector JST-PH 2,0 (capacidad según la carcasa; sección 10) |
| 1 | módulo cargador LiPo **TP4056 con protección** (DW01A + FS8205A), entrada USB-C o micro-USB (sección 10) |
| 1 | interruptor SPST de alimentación general (corta la batería; sección 10) |
| 0–1 | condensador electrolítico 100 µF / 16 V, en la entrada 5V/VBUS (opcional, colchón de arranque) |

El LED de fallo es el de a bordo del SuperMini (GPIO8); no hace falta LED
externo. La lógica del panel funciona a **3,3 V**; el bloque de batería
(sección 10) trabaja en el rango de un LiPo 1S (3,0–4,2 V) hasta el
interruptor, y entra a la SuperMini por su regulador de a bordo (pin 5V/VBUS).

---

## 8. Resumen 3V3 / GND

**3V3:** VCC de 74HC165, flash y OLED · flash /WP y /HOLD · un extremo de las
9 resistencias de pull-up.

**GND:** GND de 74HC165, flash y OLED · 74HC165 pin 10 (SER) y pin 15 (CLK INH) ·
común de los dos encoders · una pata de cada pulsador y de cada interruptor ·
una pata del zumbador piezo · B−/OUT− del cargador TP4056 y el polo − de la
batería (sección 10).

---

## 9. Sonido — zumbador piezo pasivo (GPIO3)

Salida de sonido del ordenador emulado (puertos `0x0630`–`0x0633`, ver
`specs.txt` §8). El firmware genera un tono de onda cuadrada con `tone()`
(controlador **LEDC** del ESP32-C3): frecuencia arbitraria, por hardware, sin
gastar tiempo de CPU. El C3 **no tiene DAC**, así que es tono, no audio PCM.

**Tiene que ser un piezo PASIVO** (sin oscilador propio). Un buzzer *activo*
solo daría un pitido de frecuencia fija.

| Piezo | Va a |
|---|---|
| una pata | GPIO3 (opcional: `[100 Ω]` en serie) |
| otra pata | GND |

- Un piezo es capacitivo (unos nF): la corriente media es despreciable y se
  puede atacar **directo** desde el GPIO. La resistencia de 100 Ω solo limita el
  pico de conmutación y suaviza el "clic"; opcional.
- Más volumen: transistor NPN (2N3904) con `[1 kΩ]` en la base, emisor a GND,
  colector a la pata del piezo, la otra pata a 3V3, y un diodo (1N4148) en
  paralelo con el piezo. Solo hace falta si se cambia el piezo por un altavoz.
- El tono suena **solo en modo CONTINUOUS**; se calla en paso a paso, al volver a
  EDIT y al `HALT`. `PIN_BUZZER` en [`src/main.cpp`](../src/main.cpp).
- En el panel, los agujeros de salida de sonido van sobre el piezo
  (ver [`panel.svg`](panel.svg)).

---

## 10. Alimentación por batería (opcional)

El aparato puede alimentarse solo por USB (como hasta ahora) o añadir una
batería LiPo con su cargador, para uso portátil. Ver el bloque
"ALIMENTACIÓN POR BATERÍA" y la nota "MODIFICACIÓN" en
[`wiring.svg`](wiring.svg) / `wiring.png`.

### Cadena de alimentación

```
                    diodo de fabrica de la SuperMini, cátodo reubicado
USB-C SuperMini (VBUS) ------------------|>|------------------> IN+/IN- (TP4056)
                                                                       |
LiPo 1S 3,7V --B+/B---------------------------------------------------+
                                                                       |
                                                              OUT+/OUT- (TP4056)
                                                                       |
                                                          interruptor -+-> 5V/VBUS (SuperMini)
```

| Bloque | Nota |
|---|---|
| Batería LiPo 1S | 3,0–4,2 V, capacidad según la carcasa (p. ej. 500–1200 mAh). Conector JST-PH 2,0. |
| Cargador **TP4056 con protección** | Módulo con **DW01A** (protección de sobre/infra-carga y cortocircuito) + **FS8205A** (doble MOSFET). Sin el DW01A/FS8205A el TP4056 pelado NO protege la celda — usar siempre la versión "con protección". **No usa su propio conector USB-C/micro-USB**: `IN+`/`IN−` se alimentan desde el USB-C de la propia SuperMini (ver "Modificación" abajo) — un solo cable USB-C programa y carga a la vez. |
| Interruptor SPST | En serie entre `OUT+` del cargador y el pin **5V/VBUS** de la SuperMini. Apaga el aparato sin desconectar la batería del cargador (sigue cargando con el interruptor en OFF). |

### Modificación: cargar por el mismo USB-C de la SuperMini

La SuperMini trae de fábrica un diodo entre el `VBUS` de su propio USB-C y su
pin `5V` — protege al **host USB** (el ordenador) por si además hay una fuente
de 5V externa puesta en ese pin cuando se enchufa el cable: sin el diodo, esa
tensión externa podría verse empujada de vuelta hacia el puerto del ordenador.

Para que ese mismo USB-C también cargue la batería, **no se quita ese diodo**
(sería quitar justo la protección que le da sentido) — se reaprovecha:

1. Localiza el diodo (continuidad/modo diodo con el polímetro, trazando desde
   el pin `VBUS` del conector USB-C hasta él, para identificar ánodo y cátodo
   con certeza antes de tocar nada).
2. Desuelda **solo su cátodo** (el extremo que iba hacia el pin `5V`/entrada
   del regulador) y llévalo, con un cable, a `IN+` del TP4056. El ánodo se
   deja intacto — sigue conectado al `VBUS` real del conector.
3. `IN−` del TP4056 a GND común.
4. Añade un cable nuevo, **sin diodo**, desde `OUT+` del TP4056 hasta el punto
   donde antes llegaba el cátodo (el pin `5V`/entrada del regulador, el mismo
   de siempre — vía el interruptor, sin cambios ahí).

Con esto: el diodo sigue haciendo exactamente su trabajo original (bloquear
que lo que sea que haya en el lado `IN+` — VBUS o una fuga interna del TP4056
desde la batería — llegue hasta el conector y de ahí al host), y de paso dejan
de existir un camino directo sin supervisar entre el USB y la batería: la
única forma en que el USB llega a cargar la celda es atravesando el propio
chip del TP4056. Usa un diodo **Schottky** (p. ej. 1N5819/SS14, caída
~0,2–0,3 V) si el original no lo es — con un diodo de silicio normal
(~0,6–0,7 V) el TP4056 puede quedarse sin margen para regular bien hasta los
4,2 V de corte.

Después de modificarlo, comprueba que programar/flashear
(`tools/compi_send.py`, monitor serie) sigue funcionando igual — esta
modificación no toca las líneas de datos USB (D+/D−), solo la alimentación,
pero conviene confirmarlo en la placa real.

### Por qué al pin 5V, no al 3V3

La SuperMini ya tiene un regulador 5V→3,3V a bordo; el pin 3V3 es su
**salida** regulada. Meter la batería (hasta 4,2 V a tope de carga)
directamente en el pin 3V3 sumaría esa tensión a la del regulador si además
hay USB conectado (p. ej. para programar) — puede superar el máximo absoluto
del ESP32-C3 (~3,6 V) y dañarlo. Entrando por **5V/VBUS** en cambio, el
regulador de la placa solo ve, como mucho, la tensión de la propia batería
(≤4,2 V) tanto si hay USB puesto (con la modificación de arriba, cargando a
través del TP4056) como si no.

El coste: el regulador de a bordo consume su propia corriente en reposo
(algo de mA en muchos clones — medirlo) y tiene una caída de tensión
(dropout) que resta algo de capacidad útil de la batería al final de la
descarga. Ver `specs.txt` §16 para el resto de medidas de ahorro
(atenuar/apagar la OLED, *light sleep*, flash en *deep power-down*) que sí
están bajo control del firmware.

### Notas de montaje

- El TP4056 soporta usar el aparato mientras carga (*pass-through*); no hace
  falta apagarlo para cargar.
- `OUT−`/`B−` del cargador y el polo − de la batería van al GND común.
- Condensador de 100 µF opcional en 5V/VBUS: colchón para los picos de
  corriente al despertar de *light sleep* o al escribir en la flash.
