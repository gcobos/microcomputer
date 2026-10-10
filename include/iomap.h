#pragma once
#include <stdint.h>

namespace compi {

// Mapa del espacio de PUERTOS (16 bits, 65536 puertos), independiente de la
// RAM. La instrucción IN lee un puerto, OUT lo escribe. Puertos no mapeados:
// IN devuelve 0, OUT no hace nada.
//
//   0x0000 .. 0x03FF   PANTALLA - gráficos (framebuffer, 1 byte = 8 píxeles)
//   0x0400 .. 0x04FF   PANTALLA - texto    (1 puerto = 1 celda de carácter)
//   0x0500 .. 0x05FF   PANTALLA - atributos de texto (1 puerto = 1 celda)
//   0x0600 .. 0x0603   encoders y pulsadores (solo IN)
//   0x0610             LED de a bordo
//   0x0611             número aleatorio (generador por hardware del ESP32)
//   0x0612 .. 0x0613   ahorro de energía del programa, y dormir la CPU
//   0x0614 .. 0x0615   batería: % y tensión
//   0x0620 .. 0x0629   temporizadores
//   0x0630 .. 0x0634   sonido (piezo / Bluetooth MIDI)
//   0x0640 .. 0x0643   carga/grabado de programas, consulta de slots, slot en curso
//   0x0650 .. 0x0652   configuración (brillo de pantalla, activar/desactivar sonido, grabar)
//   0x0660 .. 0x066E   metadatos (categoría + nombre) del slot consultado
//   0x0670 .. 0x067E   hora real (Wi-Fi/NTP o puesta desde el PC)
//   0x0700 .. 0x07FF   EEPROM del slot en curso (256 bytes persistentes)
//   0x0800 .. 0x0801   EEPROM: cargar/grabar de verdad en la flash
//   resto              IN -> 0 ; OUT -> nada
//
// ATTR_PORT_BASE (0x0500) va pegado a TEXT_PORT_BASE (0x0400 .. 0x04FF); el
// resto de periféricos vive en 0x06xx-0x08xx.

// --- PANTALLA · gráficos: framebuffer (puertos 0x0000 .. 0x03FF) -----
// 128x64 monocromo. 1 puerto = 1 byte = 8 píxeles horizontales,
// bit 7 = píxel más a la izquierda, 1 = píxel encendido.
// Puerto de (xbyte, y):  y * FB_STRIDE + xbyte     (xbyte 0..15, y 0..63)
//
// El firmware guarda estos 1024 bytes en su propio buffer (no en la RAM de la
// CPU). Se ponen a 0 al entrar en EJECUCIÓN. En modo CONTINUO se vuelcan a la
// OLED física cada FB_FLUSH_MS ms; en PASO no (se ve la vista de depuración).
constexpr uint16_t FB_PORT_BASE = 0x0000;
constexpr uint16_t FB_W      = 128;
constexpr uint16_t FB_H      = 64;
constexpr uint16_t FB_STRIDE = FB_W / 8;            // 16 puertos por fila
constexpr uint16_t FB_BYTES  = FB_STRIDE * FB_H;    // 1024 (0x0000..0x03FF)

// --- PANTALLA · texto: rejilla de caracteres (puertos 0x0400 .. 0x04FF) ---
// Superpuesta sobre el framebuffer. Fuente monospace de 6x8 px (5x7 propia,
// font5x7.h): 21 columnas x 8 filas = 168 celdas.
//
//   Puerto de (col, fila):  TEXT_PORT_BASE + fila*TEXT_STRIDE + col
//     fila 0..7   col 0..20   (TEXT_STRIDE = 32: fila << 5 | col)
//
//   OUT: el byte escrito es el código de carácter de esa celda:
//        0x00        -> celda transparente (se ve el gráfico de debajo)
//        0x20 (esp.) -> celda en blanco (negra)
//        resto       -> glifo, opaco (borra la celda 6x8 y dibuja encima)
//   IN:  devuelve el último código escrito en esa celda.
//
// El firmware guarda las 168 celdas en su propio buffer (g_text). Se ponen a 0
// (todo transparente) al (re)arrancar una ejecución, igual que el framebuffer.
// En CONTINUO se compone sobre el framebuffer cada FB_FLUSH_MS ms.
constexpr uint16_t TEXT_PORT_BASE = 0x0400;
constexpr uint8_t  TEXT_COLS      = 21;             // 128 / 6
constexpr uint8_t  TEXT_ROWS      = 8;              // 64 / 8
constexpr uint8_t  TEXT_STRIDE    = 32;             // puertos por fila (potencia de 2)
constexpr uint16_t TEXT_CELLS     = TEXT_COLS * TEXT_ROWS;   // 168 (buffer g_text)
constexpr uint16_t TEXT_PORT_SPAN = 0x0100;         // 0x0400 .. 0x04FF

// Puerto de una celda de texto (col, fila). Sin comprobación de rango.
constexpr uint16_t textPort(uint8_t col, uint8_t row) {
    return (uint16_t)(TEXT_PORT_BASE + ((uint16_t)row << 5) + col);
}

// --- PANTALLA · atributos de texto (puertos 0x0500 .. 0x05FF) --------
// Un byte de atributos por celda, en la misma disposición que TEXT_PORT_BASE
// (fila*32 + col) y sobre el mismo rango de 168 celdas -- ver attrPort().
// Se aplican al dibujar el carácter de esa celda; una celda con carácter 0
// (transparente) no dibuja nada aunque tenga atributos puestos.
//
//   bit 0  ATTR_INVERSE      vídeo inverso (fondo y trazo intercambiados)
//   bit 1  ATTR_BLINK        parpadea (se deja de dibujar la mitad del ciclo)
//   bit 2  ATTR_UNDERLINE    raya bajo el carácter
//   bit 3  ATTR_STRIKE       raya a media altura (tachado)
//   bit 4  ATTR_SUBSCRIPT    desplazado hacia abajo dentro de la celda
//   bit 5  ATTR_SUPERSCRIPT  desplazado hacia arriba dentro de la celda
//         (si se ponen ambos a la vez, gana subíndice)
//   bits 6-7  rotación del glifo, sentido horario -- ver ATTR_ROT_*
//
// El firmware guarda las 168 celdas en su propio buffer (g_attr), a la par
// que g_text: se ponen a 0 en los mismos momentos (arranque de ejecución).
constexpr uint16_t ATTR_PORT_BASE = 0x0500;
constexpr uint16_t ATTR_PORT_SPAN = 0x0100;         // 0x0500 .. 0x05FF

constexpr uint8_t ATTR_INVERSE     = 0x01;
constexpr uint8_t ATTR_BLINK       = 0x02;
constexpr uint8_t ATTR_UNDERLINE   = 0x04;
constexpr uint8_t ATTR_STRIKE      = 0x08;
constexpr uint8_t ATTR_SUBSCRIPT   = 0x10;
constexpr uint8_t ATTR_SUPERSCRIPT = 0x20;
constexpr uint8_t ATTR_ROT_MASK    = 0xC0;
constexpr uint8_t ATTR_ROT_SHIFT   = 6;
// (attr & ATTR_ROT_MASK) >> ATTR_ROT_SHIFT:  0=0°  1=90°  2=180°  3=270°

// Puerto de atributos de una celda (col, fila). Misma formula que textPort().
constexpr uint16_t attrPort(uint8_t col, uint8_t row) {
    return (uint16_t)(ATTR_PORT_BASE + ((uint16_t)row << 5) + col);
}

// --- Encoders y pulsadores (solo lectura, IN) ------------------------
// "Posición" = contador de 8 bits que se incrementa/decrementa con cada
// detente y ENVUELVE (0x00 <-> 0xFF). Absoluta, no un delta. Se pone a 0 al
// entrar en EJECUCIÓN. El pulsador: bit 0 = 1 mientras está pulsado.
// En modo PASO, el pulsador de DATOS lo usa el firmware (avanzar) y el de
// DIRECCIÓN también (reset): el programa los leerá a 1 en ese instante.
constexpr uint16_t PORT_DIR_POS = 0x0600; // encoder DIRECCIÓN: posición
constexpr uint16_t PORT_DIR_BTN = 0x0601; // encoder DIRECCIÓN: bit0 = pulsado
constexpr uint16_t PORT_DAT_POS = 0x0602; // encoder DATOS: posición
constexpr uint16_t PORT_DAT_BTN = 0x0603; // encoder DATOS: bit0 = pulsado

// --- Salida: LED de a bordo del módulo -------------------------------
// OUT: bit 0 = 1 enciende el LED azul del ESP32-C3 SuperMini (GPIO8).
// IN: devuelve el último valor escrito. Se apaga al (re)iniciar una ejecución.
constexpr uint16_t PORT_LED = 0x0610;

// --- Número aleatorio -------------------------------------------------
// IN: un byte aleatorio nuevo en cada lectura, del generador por hardware
// del ESP32 (esp_random(): ruido de RF/reloj, no una secuencia que se
// repita). OUT: no hace nada. Sustituye a los LFSR que cada juego sembraba
// a mano con la posición de un encoder.
constexpr uint16_t PORT_RANDOM = 0x0611;

// --- Ahorro de energía del programa (0x0612 .. 0x0613) ---------------
// Mientras un programa corre, la pantalla se atenúa y se apaga igual que en
// edición (SCREEN_DIM_MS / SCREEN_OFF_MS sin tocar el panel; un giro o
// pulsación la enciende) y el panel se muestrea más despacio si no se toca.
// La CPU no duerme sola (el programa tiene que seguir corriendo). Un
// programa que pasa horas encendido (p. ej. una mascota virtual) puede pedir
// tiempos más cortos, y además ceder la CPU en vez de esperar dando vueltas:
//
//   0x0612 PORT_POWER  OUT bit 0 = 1: modo ahorro. La pantalla se atenúa ya
//                      a los PS_DIM_MS sin tocar el panel y se apaga a los
//                      PS_OFF_MS (en vez de a los 20 / 45 s). Girar o pulsar
//                      algo la vuelve a encender (y el programa recibe ese
//                      giro/pulsación como siempre: puede mirar el bit 1 de
//                      IN antes, para no tomarlo como orden).
//                      OUT bit 1 = 1: enciende la pantalla ya (como si se
//                      hubiera tocado el panel), p. ej. para avisar.
//                      IN bit 0 = modo ahorro, bit 1 = pantalla encendida
//                      (aunque sea atenuada). Vuelve a 0 al arrancar una
//                      ejecución.
//   0x0613 PORT_SLEEP  OUT n: la CPU emulada se para n x 10 ms (0 = nada)
//                      y sigue en la instrucción siguiente. Mientras, el
//                      firmware no gasta (y con la pantalla apagada y el
//                      modo ahorro, el ESP32 entra en light sleep). Los
//                      temporizadores, el sonido y el panel siguen. Es la
//                      forma de esperar sin gastar batería: en vez de un
//                      bucle IN/CMP/JMPNZ sobre un temporizador. Solo en
//                      CONTINUO (en PASO no para). IN: 0.
constexpr uint16_t PORT_POWER = 0x0612;
constexpr uint16_t PORT_SLEEP = 0x0613;

// --- Batería (0x0614 .. 0x0615, solo IN) ---------------------------------
// La mide el firmware cada 2 s (divisor 1:2 a GPIO3, ver docs/wiring.svg).
// Con el USB enchufado y el interruptor en OFF, VSYS recibe ~4,7 V por el
// diodo D1; en ON, el firmware lo da por USB si hay un ordenador conectado
// y la batería está llena (ver batOnUsb() en main.cpp). Más de 4,4 V
// (PORT_BAT_V >= 220) = alimentado por USB.
//   0x0614 PORT_BAT_PCT  IN: carga aproximada, 0..100 % (curva de una LiPo
//                        en reposo); 255 = aun sin medir.
//   0x0615 PORT_BAT_V    IN: tensión en pasos de 20 mV (210 = 4,20 V); 0 =
//                        aun sin medir.
// Por debajo de 3,50 V el propio aparato avisa (icono de pila vacía arriba
// a la derecha y tres pitidos); el aviso se quita por encima de 3,60 V.
constexpr uint16_t PORT_BAT_PCT = 0x0614;
constexpr uint16_t PORT_BAT_V   = 0x0615;
constexpr uint32_t PS_DIM_MS = 5000;
constexpr uint32_t PS_OFF_MS = 10000;

// --- Temporizadores (10 puertos, 0x0620 .. 0x0629) -------------------
// OUT carga el temporizador con un valor (0-255). A partir de ahí decrece
// solo, 1 cada cierto tiempo, hasta llegar a 0 y quedarse ahí. IN lee el
// valor actual (0 = terminado).
//
// El temporizador i decrece 1 cada (TIMER_BASE_MS << i) milisegundos:
//   t0 = TIMER_BASE_MS ms/paso (el más rápido)
//   t1 = el doble de lento que t0 ... t9 = 512 ms/paso (el más lento).
//
// Solo corren en EJECUTAR + CONTINUO. Se ponen a 0 al (re)arrancar una
// ejecución. En PASO están congelados (para poder depurar bucles de espera).
constexpr uint16_t PORT_TIMER_BASE = 0x0620;
constexpr uint8_t  TIMER_COUNT     = 10;
constexpr unsigned long TIMER_BASE_MS = 1;   // periodo de t0 (ajustable)

// --- Sonido: zumbador piezo PASIVO en GPIO2 (0x0630 .. 0x0634) ------
// Tono de onda cuadrada generado por hardware (LEDC / tone()). Suena en
// cuanto se escribe una frecuencia o una nota; 0 = silencio. Solo suena en
// EJECUTAR + CONTINUO; se calla al (re)arrancar una ejecución, al pasar a
// PASO o EDITAR y al llegar a HALT.
//
//   0x0630 PORT_SND_FREQ_LO  byte bajo de la frecuencia en Hz (solo se engancha)
//   0x0631 PORT_SND_FREQ_HI  byte alto; AL ESCRIBIRLO se aplica  Hz = hi<<8 | lo
//                            (Hz = 0 -> silencio). Teclea LO y luego HI.
//   0x0632 PORT_SND_NOTE     nota MIDI 0..127 (0 = silencio). 69 = LA4 = 440 Hz.
//                            Se aplica al momento. La forma más fácil de tocar.
//   0x0633 PORT_SND_DUR      duración automática = valor * 10 ms; luego se calla
//                            sola. 0 = sostenida. Es "pegajosa": cada nota o
//                            frecuencia posterior re-arma esta misma duración.
//   0x0634 PORT_SND_VEL      velocidad (fuerza) MIDI 1..127 de las notas
//                            siguientes, SOLO para la salida Bluetooth MIDI
//                            (btmidi.h): el zumbador suena siempre igual.
//                            0 cuenta como 1. Pegajosa como 0x0633; vuelve a
//                            SND_VEL_DEFAULT (100) al arrancar una ejecución.
//   0x0635 PORT_SND_INSTR    instrumento 0..3 de las notas siguientes (se
//                            queda con los 2 bits bajos): 0 ORGAN (constante,
//                            el de siempre), 1 PIANO (se apaga en ~0,8 s),
//                            2 GUITAR (~0,25 s), 3 BELL (~2 s). En el
//                            zumbador es la envolvente (la intensidad baja
//                            durante la nota); por Bluetooth MIDI, un Program
//                            Change (órgano 19, piano 0, guitarra 24,
//                            campanas 14) antes de la nota siguiente -- solo
//                            si un programa lo escribe: sin escribirlo, el
//                            sintetizador sigue con el suyo. Vuelve a 0 al
//                            arrancar una ejecución.
//
//   IN 0x0630/0x0631/0x0632/0x0634/0x0635 -> eco del último valor escrito.
//   IN 0x0633 -> tiempo que queda, en unidades de 10 ms (0 = ya callado).
constexpr uint16_t PORT_SND_BASE    = 0x0630;
constexpr uint16_t PORT_SND_FREQ_LO = 0x0630;
constexpr uint16_t PORT_SND_FREQ_HI = 0x0631;
constexpr uint16_t PORT_SND_NOTE    = 0x0632;
constexpr uint16_t PORT_SND_DUR     = 0x0633;
constexpr uint16_t PORT_SND_VEL     = 0x0634;
constexpr uint16_t PORT_SND_INSTR   = 0x0635;
constexpr uint8_t  SND_PORT_COUNT   = 6;
constexpr uint8_t  SND_INSTR_COUNT  = 4;
constexpr uint8_t  SND_VEL_DEFAULT  = 100;

// --- Carga y grabado de programas (slots de la flash SPI, 0x0640/0x0641) --
// Para un "sistema operativo" en un slot que arranque otros: cargar y
// grabar la RAM completa (64 KiB) en un slot de flash SIN pasar por el
// panel físico ni el cable serie. Slots 0..59 (MAX_PROGRAM_SLOTS,
// storage.h); un numero fuera de rango, o -en carga- un slot vacio, no
// hace nada (falla en silencio, ver IN de cada puerto).
//
//   0x0640 PORT_PROG_LOAD  OUT: numero de slot -> lo carga entero en la RAM
//                          de la CPU y la reinicia (PC=0, SP=0xFFFF, flags y
//                          registros a 0) para que arranque a ejecutarlo en
//                          la SIGUIENTE instruccion -- un "salto" a otro
//                          programa, no un CALL: no hay vuelta atras salvo
//                          que el propio programa cargado use este mismo
//                          puerto otra vez. Si el slot esta vacio o fuera de
//                          rango no pasa nada (sigue ejecutandose el
//                          programa que hizo el OUT, tal cual iba). Si la
//                          carga sale bien, ADEMAS deja pantalla (grafico +
//                          texto + atributos), LED y sonido apagados, y los
//                          encoders a 0 -- lo mismo que ya se hace al entrar
//                          en una ejecucion nueva por el interruptor del
//                          panel (ver clearRuntimeOutputs() en main.cpp):
//                          el programa que arranca no debe heredar nada de
//                          quien lo cargo.
//                          IN: 1 si el ULTIMO intento de carga FALLO, 0 si
//                          salio bien (o si todavia no se ha pedido ninguna).
//                          Solo tiene sentido leerlo tras un fallo: si la
//                          carga sale bien, el programa que iba a leerlo ya
//                          no es el que esta corriendo.
//   0x0641 PORT_PROG_SAVE  OUT: numero de slot -> graba ahi la RAM actual
//                          entera (equivale a "Guardar" del panel, pero
//                          disparado por el propio programa). SIGUE
//                          ejecutandose el mismo programa despues -- esto es
//                          un volcado, no un salto. Tarda unos cuantos ms
//                          (borra flash antes de escribir): el resto de
//                          puertos (temporizadores, sonido) no avanzan
//                          mientras tanto porque el intérprete esta parado
//                          en este OUT, igual que ya pasa al grabar desde el
//                          panel.
//                          IN: 1 si la ULTIMA grabacion salio bien, 0 si
//                          fallo (numero de slot fuera de 0..59) o todavia
//                          no se ha pedido ninguna.
constexpr uint16_t PORT_PROG_LOAD = 0x0640;
constexpr uint16_t PORT_PROG_SAVE = 0x0641;

// --- Consulta de slots: nombre y categoría (para menús como sisop.asm) ---
// Cada slot guarda en su cabecera de la flash una categoría y un nombre
// (storage.h SLOT_META_SIZE, SLOT_CAT_*), puestos por el ensamblador con
// las directivas .name/.category y enviados por compi_send.py. Al grabar
// la RAM en un slot (Guardar del panel, PORT_PROG_SAVE) se graban los del
// programa que está cargado ahora.
//
//   0x0642 PORT_SLOT_QUERY  OUT: número de slot -> lee sus metadatos de la
//                           flash a PORT_SLOT_INFO. IN: 1 si ese slot (el
//                           último consultado) tiene programa, 0 si no.
//   0x0643 PORT_CUR_SLOT    IN: el slot en curso (el del programa cargado;
//                           ver g_currentSlot en main.cpp) -- para que un
//                           programa pueda grabarse a sí mismo
//                           (PORT_PROG_SAVE) sin llevar el número fijo.
//   0x0660 .. 0x066E PORT_SLOT_INFO  IN: los 15 bytes de metadatos del
//                           último slot consultado: 0x0660 = categoría
//                           (0xFF = ninguna, también en slots grabados antes
//                           de existir los metadatos), 0x0661..0x066E =
//                           nombre ASCII relleno con 0.
constexpr uint16_t PORT_SLOT_QUERY = 0x0642;
constexpr uint16_t PORT_CUR_SLOT   = 0x0643;
constexpr uint16_t PORT_SLOT_INFO_BASE = 0x0660;

// --- Hora real (0x0670 .. 0x067E) ---------------------------------------
// La da el Wi-Fi por NTP (la red configurada con compi.py wifi o, si no,
// cualquier red abierta; se conecta un momento al arrancar y cada 12 h, y
// apaga la radio) o el PC por
// el USB (compi.py time). Sin ninguna, no hay hora: el aparato no tiene pila
// que la conserve apagado. Ver netclock.h.
//
//   0x0670 PORT_TIME_CTRL  OUT (cualquier valor): congela la hora de ahora
//                          en los registros 0x0671..0x067E, para leerlos
//                          todos de la MISMA hora (sin que cambie el
//                          minuto entre una lectura y otra).
//                          IN: estado. bit 0 = hay hora, bit 1 = vino del
//                          Wi-Fi, bit 2 = conectando ahora, bit 3 = hay una
//                          red Wi-Fi configurada.
//   0x0671..0x0674  IN: segundos desde 1-1-1970 UTC (epoch), byte bajo primero
//   0x0675 segundo, 0x0676 minuto, 0x0677 hora (0..23) -- hora LOCAL
//   0x0678 dia (1..31), 0x0679 mes (1..12), 0x067A año - 2000
//   0x067B dia de la semana (0 = domingo)
//   0x067C..0x067E  IN: minutos locales desde el 1-1-2020 00:00 (24 bits,
//                   byte bajo primero): para contar cuanto ha pasado sin
//                   hacer divisiones (sirve hasta el año 2051).
//   Todos a 0 si no hay hora. Los registros solo cambian con OUT 0x0670.
constexpr uint16_t PORT_TIME_CTRL  = 0x0670;
constexpr uint16_t PORT_TIME_BASE  = 0x0671;   // 14 registros: ver clockLatch()
constexpr uint8_t  TIME_REG_COUNT  = 14;

// --- Configuración del propio aparato (0x0650 .. 0x0652) --------------
// Ajustes globales del aparato (brillo y sonido). Cualquier programa puede
// leerlos, pero solo el slot 0 (SETTINGS de sisop) puede cambiarlos.
//
//   0x0650 PORT_CFG_BRIGHTNESS  OUT: brillo de la pantalla, 0 (más tenue) a
//                                255 (máximo) -- se aplica al instante,
//                                directo al contraste real de la OLED (ver
//                                oled.contrastFromSettings() en display.cpp,
//                                solo SET_CONTRAST: se probaron PRE-CHARGE/
//                                VCOMH y un tramado por software para bajar
//                                más el brillo, y se descartaron en el panel
//                                real). Además
//                                queda como el nuevo brillo "a pleno uso":
//                                el atenuado automático por inactividad
//                                (specs.txt, ahorro de energía) sigue
//                                funcionando igual, y al recuperar el brillo
//                                pleno (por actividad del panel, o porque
//                                sigue corriendo el programa) vuelve a este
//                                valor en vez del de fábrica. Es una
//                                preferencia de TODO el aparato, igual que
//                                PORT_CFG_SOUND_EN: NO se reinicia en cada
//                                arranque de ejecución nueva (bug real
//                                reportado: el brillo elegido en SETTINGS se
//                                perdía al arrancar otro programa; ver
//                                clearRuntimeOutputs() en main.cpp).
//                                IN: eco del último valor escrito (de
//                                fábrica, el de OLED_CONTRAST_FULL).
//                                SOLO lo cambia el slot 0 (SETTINGS de
//                                sisop): un OUT desde cualquier otro
//                                programa se ignora. Se guarda en la flash
//                                (storage.h SETTINGS_SIZE) con un OUT a
//                                PORT_CFG_SAVE, y se recupera al arrancar.
//   0x0651 PORT_CFG_SOUND_EN    OUT: salida del sonido: 0 = Bluetooth MIDI
//                                (btmidi.h), 2 = silencio, otro = el
//                                zumbador --
//                                MISMO interruptor general que el botón BOOT
//                                del propio aparato (ver g_soundMode,
//                                main.cpp): es una preferencia
//                                de sesión, no un ajuste de este programa en
//                                concreto, así que NO se reinicia al
//                                arrancar una ejecución nueva (igual que
//                                pulsar BOOT a mano tampoco se olvida al
//                                cambiar de programa). A diferencia del
//                                botón BOOT, no reproduce el "jingle" de
//                                vuelta al zumbador (pensado para que lo
//                                note un humano, no para que lo dispare
//                                código). IN: 1 si el sonido va al
//                                zumbador ahora mismo, 0 si por Bluetooth,
//                                2 si en silencio (el Bluetooth no conectó
//                                en 30 s y se apagó solo). Igual que el
//                                brillo: SOLO el slot 0 puede cambiarlo
//                                (además del botón BOOT), y se guarda en
//                                la flash para sobrevivir a un reset (con
//                                PORT_CFG_SAVE; el botón BOOT graba solo).
//   0x0652 PORT_CFG_SAVE        OUT (cualquier valor, solo desde el slot
//                                0): graba brillo y salida del sonido si han
//                                cambiado desde la última vez. sisop lo hace
//                                al salir de SETTINGS (botón DIRECCIÓN), no
//                                en cada detente del dial, para no gastar la
//                                flash. IN: 0.
constexpr uint16_t PORT_CFG_BASE       = 0x0650;
constexpr uint16_t PORT_CFG_BRIGHTNESS = 0x0650;
constexpr uint16_t PORT_CFG_SOUND_EN   = 0x0651;
constexpr uint16_t PORT_CFG_SAVE       = 0x0652;
constexpr uint8_t  CFG_PORT_COUNT      = 2;

// --- EEPROM persistente por slot (0x0700 .. 0x07FF, 0x0800 .. 0x0801) -----
// Cada slot de programa (storage.h MAX_PROGRAM_SLOTS) tiene EEPROM_SLOT_SIZE
// (256) bytes propios en la flash SPI, aparte de la imagen del programa y
// con su propia dirección -- para records o ajustes que deben sobrevivir a
// apagar el aparato (p.ej. sisop.asm guardando ahí el brillo/sonido elegidos
// en SETTINGS, o un juego guardando su mejor puntuación). Vive en el resto
// de la flash que los 60 slots de programa no llegan a llenar (sobran
// exactamente 60*256 bytes, ver storage.h) -- no comparte sitio con ningún
// programa ni se borra al borrar uno (deleteProgram() no la toca).
//
// "El slot en curso": el aparato recuerda en todo momento a qué número de
// slot corresponde lo que hay cargado en la RAM ahora mismo (arranque
// automático del slot 0, un Cargar/Guardar del panel, o un OUT a
// PORT_PROG_LOAD/PORT_PROG_SAVE -- ver g_currentSlot en main.cpp) y estos
// puertos SIEMPRE operan sobre ESE slot: un programa nunca necesita conocer
// ni pasar su propio número de slot.
//
// El acceso es en DOS pasos, como PORT_PROG_LOAD/PORT_PROG_SAVE con la RAM
// completa, pero aquí con un búfer de trabajo de 256 bytes en vez de 64 KiB:
//
//   0x0700..0x07FF PORT_EEPROM_BASE+i  OUT/IN: byte i (0..255) del búfer de
//                                       trabajo en RAM -- INSTANTÁNEO, no
//                                       toca la flash para nada. Se puede
//                                       leer/escribir tantas veces como se
//                                       quiera sin coste. Se reinicia a 0 en
//                                       cada arranque de ejecución nueva
//                                       (clearRuntimeOutputs(), como el
//                                       resto de "salidas" -- no hereda el
//                                       búfer de quien corriera antes), así
//                                       que hace falta un 0x0800 para tener
//                                       algo de verdad.
//   0x0800         PORT_EEPROM_LOAD    OUT (cualquier valor): SUSTITUYE el
//                                       búfer de trabajo por los 256 bytes
//                                       que de verdad hay grabados en la
//                                       flash para el slot en curso. IN: 1
//                                       si el ÚLTIMO intento falló, 0 si
//                                       salió bien (mismo criterio que
//                                       PORT_PROG_LOAD) -- en la práctica
//                                       solo falla si el slot en curso
//                                       quedara fuera de rango, lo que no
//                                       debería poder pasar nunca.
//   0x0801         PORT_EEPROM_SAVE    OUT (cualquier valor): graba el búfer
//                                       de trabajo de verdad en la flash,
//                                       para el slot en curso (borra y
//                                       reescribe SOLO el sector de 4 KiB
//                                       que contiene ese slot, no toda la
//                                       zona de EEPROM -- unos cuantos ms,
//                                       como grabar un programa). IN: 1 si
//                                       la ÚLTIMA grabación salió bien, 0 si
//                                       falló (mismo criterio que
//                                       PORT_PROG_SAVE).
constexpr uint16_t PORT_EEPROM_BASE = 0x0700;
constexpr uint16_t PORT_EEPROM_LOAD = 0x0800;
constexpr uint16_t PORT_EEPROM_SAVE = 0x0801;

} // namespace compi
