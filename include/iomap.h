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
//   0x0620 .. 0x0627   temporizadores
//   0x0630 .. 0x0633   sonido (piezo)
//   resto              IN -> 0 ; OUT -> nada
//
// ATTR_PORT_BASE (0x0500) va pegado a TEXT_PORT_BASE (0x0400 .. 0x04FF), tal
// como se pidió: encoders/LED/temporizadores/sonido -antes en 0x0500..0x0533-
// se han desplazado en bloque a 0x0600.. para dejarle sitio. Esto CAMBIA los
// puertos que ya usaban programs/*.asm (todos actualizados a la vez que este
// fichero); cualquier programa nuevo o de fuera del repo que siga usando las
// direcciones antiguas (0x0500 = encoder, 0x0510 = LED, ...) hay que
// migrarlo a mano.

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

// --- Temporizadores (8 puertos, 0x0620 .. 0x0627) -------------------
// OUT carga el temporizador con un valor (0-255). A partir de ahí decrece
// solo, 1 cada cierto tiempo, hasta llegar a 0 y quedarse ahí. IN lee el
// valor actual (0 = terminado).
//
// El temporizador i decrece 1 cada (TIMER_BASE_MS << i) milisegundos:
//   t0 = TIMER_BASE_MS ms/paso (el más rápido)
//   t1 = el doble de lento que t0 ... t7 = el más lento.
//
// Solo corren en EJECUTAR + CONTINUO. Se ponen a 0 al (re)arrancar una
// ejecución. En PASO están congelados (para poder depurar bucles de espera).
constexpr uint16_t PORT_TIMER_BASE = 0x0620;
constexpr uint8_t  TIMER_COUNT     = 8;
constexpr unsigned long TIMER_BASE_MS = 1;   // periodo de t0 (ajustable)

// --- Sonido: zumbador piezo PASIVO en GPIO3 (0x0630 .. 0x0633) ------
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
//
//   IN 0x0630/0x0631/0x0632 -> eco del último valor escrito.
//   IN 0x0633 -> tiempo que queda, en unidades de 10 ms (0 = ya callado).
constexpr uint16_t PORT_SND_BASE    = 0x0630;
constexpr uint16_t PORT_SND_FREQ_LO = 0x0630;
constexpr uint16_t PORT_SND_FREQ_HI = 0x0631;
constexpr uint16_t PORT_SND_NOTE    = 0x0632;
constexpr uint16_t PORT_SND_DUR     = 0x0633;
constexpr uint8_t  SND_PORT_COUNT   = 4;

} // namespace compi
