#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "esp_timer.h"
#include "esp_sleep.h"
#include "cpu.h"
#include "disasm.h"
#include "editor.h"
#include "panel.h"
#include "display.h"
#include "spi_flash_storage.h"
#include "iomap.h"
#include "ui.h"

using namespace compi;

// --- Asignación de pines (ESP32-C3 SuperMini) ---------------------------
// Cableado y lista de materiales: docs/hardware.md. 8 entradas del panel
// (2 encoders x 3 + 2 interruptores) multiplexadas por un 74HC165.
constexpr uint8_t PIN_HC165_LOAD  = 10;
constexpr uint8_t PIN_HC165_CLOCK = 0;
constexpr uint8_t PIN_HC165_DATA  = 1;

constexpr uint8_t PIN_FLASH_CS = 7;   // SCK/MISO/MOSI = 4/5/6 (por defecto del C3)
constexpr uint8_t PIN_I2C_SDA  = 20;  // IO18/19 van al USB nativo en el SuperMini
constexpr uint8_t PIN_I2C_SCL  = 21;

// LED azul de a bordo del SuperMini (GPIO8), ACTIVO A NIVEL BAJO. Doble uso:
// aviso de fallo en el arranque (failBlink) y salida del ordenador emulado
// (puerto PORT_LED). Si tu placa lo lleva a nivel alto, pon _ACTIVE_LOW=false.
constexpr uint8_t PIN_LED = 8;
constexpr bool PIN_LED_ACTIVE_LOW = true;

// Zumbador piezo PASIVO en GPIO3 (único pin libre). Tono por hardware (tone()).
constexpr uint8_t PIN_BUZZER = 3;

// EJECUCIÓN + CONTINUO: instrucciones por vuelta de loop() y refresco del
// framebuffer.
constexpr int EXEC_BATCH = 4000;
// Cada volcado a la OLED bloquea ~30 ms de I2C; con 50 ms de periodo eso deja
// el "duty cycle" de cómputo en solo ~40% (ver specs.txt §16). Subir el
// periodo reparte ese coste fijo entre más tiempo: a 100 ms, ~30 ms
// bloqueado de cada 100 = ~70% de cómputo (casi el doble que antes) a costa
// de refrescar la pantalla a la mitad de frecuencia (más "a saltos" en
// animaciones rápidas como cubo.asm). Medido con programs/benchmark.asm.
constexpr unsigned long FB_FLUSH_MS = 125;

// EditMem: umbral para distinguir pulsación corta (insertar NOP) de larga
// (borrar byte) en el pulsador de DIRECCIÓN -- ver el bloque EditMem.
constexpr unsigned long DIR_LONG_PRESS_MS = 500;

// --- Ahorro de energía (funcionamiento con batería) --------------------
// El panel se muestrea desde un esp_timer, NO desde loop(), así que sigue
// respondiendo aunque la OLED esté volcando (~30 ms) o se esté grabando la
// flash (~1 s). El ritmo es adaptativo: rápido mientras hay actividad, más
// lento en reposo (menos despertares -> menos consumo). Con la CPU en reposo
// prolongado se apaga la OLED y se entra en light sleep (conserva los 64 KiB
// de RAM).
//
// La diferencia entre "activo" y "reposo" se mantiene A PROPÓSITO pequeña
// (2 ms vs 4/8 ms, no 2 ms vs 20/100 ms como en versiones anteriores):
// un salto grande hacía que, nada más dejar de tocar el panel, un giro
// posterior pudiera empezar a perderse casi por completo hasta girar muy
// rápido -- con separaciones así de pequeñas el consumo extra en reposo es
// mínimo y la respuesta se mantiene prácticamente igual que "activo".
//
// Nota de hardware: para despertar del light sleep girando un encoder haría
// falta una línea de "actividad de panel" (OR de las señales activas-bajas)
// a un GPIO RTC. Sin ella, en light sleep se muestrea el '165 cada
// SAMPLE_IDLE_MS; un giro corto y rápido puede caer entero dentro del hueco
// entre dos muestras y perderse -- de ahí que SAMPLE_IDLE_MS se mantenga
// bajo en vez de subirlo para ahorrar más batería.
constexpr uint32_t SAMPLE_ACTIVE_MS  = 2;      // muestreo del '165 en uso
constexpr uint32_t SAMPLE_SCREENON_MS = 4;     // pantalla encendida pero sin tocar (antes 20)
constexpr uint32_t SAMPLE_IDLE_MS    = 8;      // pantalla atenuada/apagada (antes 40, y 100 antes de eso)
constexpr uint32_t ACTIVE_WINDOW_MS  = 2000;   // sigue a 2 ms tras la última actividad
constexpr uint32_t SCREEN_DIM_MS     = 20000;  // atenuar la OLED por inactividad
constexpr uint32_t SCREEN_OFF_MS     = 45000;  // apagar la OLED
constexpr uint32_t LIGHT_SLEEP_MS    = 45000;  // dormir la CPU (light sleep); >= SCREEN_OFF_MS
constexpr uint8_t  OLED_CONTRAST_FULL = 0xCF;
constexpr uint8_t  OLED_CONTRAST_DIM  = 0x10;
// Arrancar ya atenuada (en vez de a pleno brillo) ahorra batería mientras el
// aparato espera a que alguien lo toque; cualquier actividad del panel la
// sube a pleno brillo al momento (ver noteActivity()).
constexpr bool     START_SCREEN_DIMMED = true;

Cpu cpu;
FrontPanel panel(PIN_HC165_LOAD, PIN_HC165_CLOCK, PIN_HC165_DATA);
OledPanel oled(0x3C);
SpiFlashStorage flash(PIN_FLASH_CS);

static uint8_t g_fb[FB_BYTES];              // framebuffer del dispositivo (puertos)
static uint8_t g_text[TEXT_CELLS];          // rejilla de texto (puertos 0x0400+)
static uint8_t g_attr[TEXT_CELLS];          // atributos de texto (puertos 0x0500+)
static uint8_t g_preview[PREVIEW_BYTES];    // primeros bytes del slot (EditPrg)

UiState ui;
bool prevExec = false;
bool prevAbajo = false;
View prevView = View::EditMem;
// EditMem: estado del pulsador de DIRECCIÓN para lo de arriba (DIR_LONG_PRESS_MS).
bool dirBtnHeld = false;
unsigned long dirBtnPressMs = 0;
bool dirBtnLongFired = false;
uint8_t prevSlot = 0xFF;
// ExecPaso: giro de DATOS hacia atras ("ejecutar hasta volver aqui") -- ver
// el bloque ExecPaso mas abajo.
bool pasoRunning = false;
uint16_t pasoTargetPC = 0;
bool running = false;
unsigned long lastFlush = 0;
uint8_t g_led = 0;                          // estado del LED (puerto PORT_LED)
uint8_t g_timer[TIMER_COUNT] = {0};         // temporizadores (puertos 0x0620+)
unsigned long g_timerLast[TIMER_COUNT] = {0};

// Sonido (puertos 0x0630..0x0633). g_sndHz = tono que suena ahora (0 = silencio).
uint8_t  g_sndLo = 0, g_sndHi = 0;          // frecuencia enganchada (bytes)
uint8_t  g_sndNote = 0;                     // última nota MIDI escrita (eco de IN)
uint8_t  g_sndDurUnits = 0;                 // duración auto en unidades de 10 ms
uint16_t g_sndHz = 0;
unsigned long g_sndOffAt = 0;               // millis() en que callar; 0 = sostenido

void setLed(bool on) {
    bool level = PIN_LED_ACTIVE_LOW ? !on : on;
    digitalWrite(PIN_LED, level ? HIGH : LOW);
}

// Hace decrecer los temporizadores según el tiempo transcurrido. Se llama en
// cada vuelta de loop() mientras hay una ejecución en marcha (CONTINUO).
void tickTimers() {
    unsigned long now = millis();
    for (uint8_t i = 0; i < TIMER_COUNT; ++i) {
        if (g_timer[i] == 0) { g_timerLast[i] = now; continue; }
        unsigned long period = TIMER_BASE_MS << i;   // t0, 2·t0, 4·t0, ...
        unsigned long elapsed = now - g_timerLast[i];
        if (elapsed >= period) {
            unsigned long ticks = elapsed / period;
            g_timer[i] = (ticks >= g_timer[i]) ? 0 : (uint8_t)(g_timer[i] - ticks);
            g_timerLast[i] += ticks * period;
        }
    }
}

void resetTimers() {
    unsigned long now = millis();
    for (uint8_t i = 0; i < TIMER_COUNT; ++i) { g_timer[i] = 0; g_timerLast[i] = now; }
}

// --- Sonido (piezo pasivo en PIN_BUZZER, puertos 0x0630..0x0633) -----
uint16_t noteToHz(uint8_t note) {
    if (note == 0 || note > 127) return 0;            // 0 = silencio
    float hz = 440.0f * powf(2.0f, ((int)note - 69) / 12.0f);   // 69 = LA4
    return (uint16_t)lroundf(hz);
}

void sndApply(uint16_t hz) {
    if (hz == 0) {
        if (g_sndHz) noTone(PIN_BUZZER);
        g_sndHz = 0;
        g_sndOffAt = 0;
        return;
    }
    tone(PIN_BUZZER, hz);
    g_sndHz = hz;
    g_sndOffAt = g_sndDurUnits
                     ? millis() + (unsigned long)g_sndDurUnits * 10
                     : 0;                             // 0 = sostenido
}

void tickSound() {
    if (g_sndOffAt && (long)(millis() - g_sndOffAt) >= 0) sndApply(0);
}

void resetSound() {
    g_sndLo = g_sndHi = g_sndNote = g_sndDurUnits = 0;
    sndApply(0);
}

// Índice en g_text de un puerto de la rejilla de texto, o -1 si el puerto no
// cae en una celda válida (fila 0..7, col 0..20; TEXT_STRIDE = 32 por fila).
int textIndex(uint16_t port) {
    if (port < TEXT_PORT_BASE || port >= TEXT_PORT_BASE + TEXT_PORT_SPAN) return -1;
    uint16_t off = (uint16_t)(port - TEXT_PORT_BASE);
    uint8_t row = (uint8_t)(off >> 5);
    uint8_t col = (uint8_t)(off & 31);
    if (row >= TEXT_ROWS || col >= TEXT_COLS) return -1;
    return row * TEXT_COLS + col;
}

// Lo mismo que textIndex() pero para el banco de atributos (0x0500+, misma
// disposición fila*32+col -- ver iomap.h).
int attrIndex(uint16_t port) {
    if (port < ATTR_PORT_BASE || port >= ATTR_PORT_BASE + ATTR_PORT_SPAN) return -1;
    uint16_t off = (uint16_t)(port - ATTR_PORT_BASE);
    uint8_t row = (uint8_t)(off >> 5);
    uint8_t col = (uint8_t)(off & 31);
    if (row >= TEXT_ROWS || col >= TEXT_COLS) return -1;
    return row * TEXT_COLS + col;
}

// --- Puertos de E/S de la CPU (espacio de 16 bits) --------------------
uint8_t portRead(uint16_t port) {
    if (port < FB_BYTES) return g_fb[port];
    { int ti = textIndex(port); if (ti >= 0) return g_text[ti]; }
    { int ai = attrIndex(port); if (ai >= 0) return g_attr[ai]; }
    if (port >= PORT_TIMER_BASE && port < PORT_TIMER_BASE + TIMER_COUNT)
        return g_timer[port - PORT_TIMER_BASE];
    if (port >= PORT_SND_BASE && port < PORT_SND_BASE + SND_PORT_COUNT) {
        switch (port) {
            case PORT_SND_FREQ_LO: return g_sndLo;
            case PORT_SND_FREQ_HI: return g_sndHi;
            case PORT_SND_NOTE:    return g_sndNote;
            case PORT_SND_DUR: {
                if (!g_sndOffAt) return 0;
                long rem = (long)(g_sndOffAt - millis());
                if (rem <= 0) return 0;
                long units = (rem + 9) / 10;
                return units > 255 ? 255 : (uint8_t)units;
            }
        }
        return 0;
    }
    switch (port) {
        case PORT_DIR_POS: return panel.dirPos();
        case PORT_DIR_BTN: return panel.dirDown() ? 1 : 0;
        case PORT_DAT_POS: return panel.datPos();
        case PORT_DAT_BTN: return panel.datDown() ? 1 : 0;
        case PORT_LED:     return g_led;
        default:           return 0;
    }
}
void portWrite(uint16_t port, uint8_t value) {
    if (port < FB_BYTES) { g_fb[port] = value; return; }
    { int ti = textIndex(port); if (ti >= 0) { g_text[ti] = value; return; } }
    { int ai = attrIndex(port); if (ai >= 0) { g_attr[ai] = value; return; } }
    if (port >= PORT_TIMER_BASE && port < PORT_TIMER_BASE + TIMER_COUNT) {
        uint8_t i = (uint8_t)(port - PORT_TIMER_BASE);
        g_timer[i] = value;
        g_timerLast[i] = millis();
        return;
    }
    if (port >= PORT_SND_BASE && port < PORT_SND_BASE + SND_PORT_COUNT) {
        switch (port) {
            case PORT_SND_FREQ_LO: g_sndLo = value; break;          // solo engancha
            case PORT_SND_FREQ_HI: g_sndHi = value;
                sndApply((uint16_t)(((uint16_t)value << 8) | g_sndLo)); break;
            case PORT_SND_NOTE:    g_sndNote = value;
                sndApply(noteToHz(value)); break;
            case PORT_SND_DUR:     g_sndDurUnits = value; break;
        }
        return;
    }
    if (port == PORT_LED) { g_led = (uint8_t)(value & 1); setLed(g_led); }
}

void failBlink(int delayMs) {
    pinMode(PIN_LED, OUTPUT);
    bool on = false;
    while (true) {
        on = !on;
        setLed(on);
        delay(delayMs);
    }
}

static uint16_t clamp16(long v) {
    return v < 0 ? 0 : (v > 0xFFFF ? 0xFFFF : (uint16_t)v);
}

// Mueve `cursor` detentes instrucciones enteras (no bytes sueltos): adelante,
// instrLen() del opcode actual (asume que cursor ya está alineado a un
// límite real, como garantiza siempre este mismo navegador); atrás,
// prevInstrStart() (recorre desde 0, como listBase, para no caer nunca en
// mitad de una instrucción de 2/3 bytes). Compartido por EditMem (ADDR
// girar) y ExecPaso (ADDR girar, para elegir la dirección objetivo).
static void stepCursorByInstr(uint16_t& cursor, int16_t detentes) {
    int16_t steps = detentes;
    while (steps > 0) {
        uint8_t len = instrLen(cpu.ram(), 65536u, cursor);
        long next = (long)cursor + len;
        if (next > 0xFFFF) break;   // no cabe otra instruccion entera
        cursor = (uint16_t)next;
        --steps;
    }
    while (steps < 0 && cursor) {
        cursor = prevInstrStart(cpu.ram(), 65536u, cursor);
        ++steps;
    }
}

// --- Muestreo del panel (esp_timer) y gestión de energía ---------------
esp_timer_handle_t g_sampler = nullptr;
volatile uint32_t  g_lastActivity = 0;     // millis() de la última actividad del panel
volatile bool      g_execActive   = false; // programa ejecutando en CONTINUO

enum ScreenPwr : uint8_t { SCR_FULL, SCR_DIM, SCR_OFF };
ScreenPwr g_scr = SCR_FULL;
bool      g_forceRender = false;

// Se re-arma a sí mismo: 2 ms si hay actividad reciente o un programa
// ejecutando, 100 ms en reposo. Corre en la tarea de esp_timer (prioridad
// alta), así que sigue muestreando aunque loop() esté bloqueado en un volcado
// I2C de la OLED o en un guardado de la flash.
void samplerCb(void*) {
    if (panel.update()) g_lastActivity = millis();
    uint32_t idle = millis() - g_lastActivity;
    uint32_t next_ms = (g_execActive || idle < ACTIVE_WINDOW_MS) ? SAMPLE_ACTIVE_MS
                     : (idle < SCREEN_DIM_MS)                     ? SAMPLE_SCREENON_MS
                     :                                             SAMPLE_IDLE_MS;
    esp_timer_start_once(g_sampler, (uint64_t)next_ms * 1000);
}

void applyScreenPower(ScreenPwr want) {
    if (want == g_scr) return;
    if (want == SCR_OFF) {
        oled.power(false);
    } else {
        if (g_scr == SCR_OFF) {
            oled.power(true);
            g_forceRender = true;   // repinta vistas de depuración
            lastFlush = 0;          // fuerza volcado del framebuffer (ExecCont)
        }
        oled.contrast(want == SCR_DIM ? OLED_CONTRAST_DIM : OLED_CONTRAST_FULL);
    }
    g_scr = want;
}

void noteActivity() {
    g_lastActivity = millis();
    applyScreenPower(SCR_FULL);
}

void loadSlot(uint8_t s) {
    if (flash.loadProgram((int)s, cpu.ram())) {
        cpu.reset();
        ui.cursor = 0;
        ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);   // resincroniza el editor
    }
}

void saveSlot(uint8_t s) {
    char m[24];
    snprintf(m, sizeof(m), "SAVING slot %02u", (unsigned)s);
    oled.message(m);
    flash.saveProgram((int)s, cpu.ram());
}

// Borra la RAM (todo a 0x00 = NOP, ver isa.h) para empezar a teclear un
// programa desde cero en EditMem, sin leer ni escribir la flash -- para
// que quede grabado en el slot elegido hace falta un Guardar aparte,
// igual que con cualquier otro cambio hecho a mano en la RAM.
void newSlot() {
    cpu.clearMemory();
    cpu.reset();
    ui.cursor = 0;
    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);   // resincroniza el editor
}

// --- Insertar/borrar un byte en EditMem (desplaza el resto de la RAM) ------
// Ninguna de las dos toca nunca nada en [SP, 0xFFFF]: ahí vive la pila
// (crece hacia abajo desde 0xFFFF, ver cpu.h), y desplazarla sin darse
// cuenta la corromperia. Si el cursor ya esta en la pila o mas alla
// (cursor >= sp), no hay hueco libre por encima donde desplazar sin
// pisarla: la operacion no hace nada.

// Abre un hueco de 1 byte en `cursor`, desplazando [cursor, sp-2] a
// [cursor+1, sp-1] (el byte que hubiera en sp-1 se pierde: es el ultimo
// libre antes de la pila, no queda otro sitio donde meterlo) y deja
// mem[cursor] = 0x00 (NOP) listo para teclear.
void insertByteAt(uint16_t cursor) {
    uint16_t sp = cpu.sp();
    if (cursor >= sp) return;
    uint8_t* mem = cpu.ram();
    for (uint32_t i = (uint32_t)sp - 1; i > cursor; --i) {
        mem[i] = mem[i - 1];
    }
    mem[cursor] = 0x00;
}

// Borra mem[cursor], desplazando [cursor+1, sp-1] a [cursor, sp-2] y
// rellenando el hueco que queda arriba (sp-1) con 0x00 (NOP).
void deleteByteAt(uint16_t cursor) {
    uint16_t sp = cpu.sp();
    if (cursor >= sp) return;
    uint8_t* mem = cpu.ram();
    for (uint32_t i = cursor; i + 1 < sp; ++i) {
        mem[i] = mem[i + 1];
    }
    mem[sp - 1] = 0x00;
}

// --- Provisioning por USB-CDC ----------------------------------------------
// Mete o saca una imagen de RAM (64 KiB) por el puerto serie, en un slot de
// la flash, sin tener que teclearla byte a byte en el panel.
//
// Protocolo LOAD (host -> aparato, provisionLoad()):
//     "COMPI LOAD <slot> <len>\n"     cabecera ASCII (slot 0..59, len 0..65536)
//     <len> bytes crudos, EN BLOQUES DE COMPI_CHUNK bytes (el ultimo puede
//     ser mas corto); el host espera el "COMPI CHUNK <total>" de cada bloque
//     antes de mandar el siguiente. El resto de los 64 KiB (hasta 65536) va
//     a 0.
// Respuestas del aparato por la misma linea serie:
//     "COMPI READY\n"                 cabecera aceptada, enviar ya los bytes
//     "COMPI CHUNK <n>\n"             van <n> bytes recibidos hasta ahora
//     "COMPI OK <sum>\n"              grabado; <sum> = suma de los 65536 bytes
//                                     modulo 2^32 (para verificar en el host)
//     "COMPI ERR <motivo>\n"          error
//
// Por que a trozos y con eco en LOAD: el USB-CDC nativo del C3 (USBCDC.cpp,
// core de Arduino) mete los bytes que llegan en una cola de software de solo
// 256 bytes por defecto; si se llena, LOS DESCARTA SIN AVISAR (no hay control
// de flujo a nivel de aplicacion). Ya se agranda esa cola en setup(), pero
// exigir un "COMPI CHUNK" por cada bloque obliga al host a ir al ritmo del
// aparato pase lo que pase, en vez de fiarlo todo al tamaño del buffer.
//
// Protocolo DUMP (aparato -> host, provisionDump()): la mitad "sacar" --
// ver ahi mismo por que no le hace falta trocear con eco como a LOAD.
//     "COMPI DUMP <slot> [<len>]\n"   pide el slot (0..59); <len> opcional
//                                     (0..65536) para no mandar mas que los
//                                     primeros <len> bytes -- sin el, la
//                                     imagen entera (PROGRAM_SIZE), que es
//                                     lo unico que guarda la flash (no hay
//                                     "longitud de programa" que recordar,
//                                     solo imagenes completas de 64 KiB)
//     "COMPI READY <len>\n"           cabecera aceptada; <len> = el pedido,
//                                     o PROGRAM_SIZE si no se pidio ninguno
//     <len> bytes crudos, de un tiron (sin trocear)
//     "COMPI OK <sum>\n"              enviado; <sum> = checksum de esos <len>
//                                     bytes (mismo cálculo que LOAD, pero
//                                     solo sobre el trozo mandado)
//     "COMPI ERR <motivo>\n"          error (slot/len fuera de rango o vacio)
//
// Se sondea al principio de cada loop(). Las lineas que no empiezan por
// "COMPI LOAD " o "COMPI DUMP " se ignoran (se puede seguir usando el
// monitor serie).
constexpr size_t COMPI_CHUNK = 1024;

void provisionLoad(int slot, long len) {
    if (slot < 0 || (size_t)slot >= MAX_PROGRAM_SLOTS ||
        len < 0 || len > (long)PROGRAM_SIZE) {
        Serial.println("COMPI ERR header");
        return;
    }

    noteActivity();                     // enciende la OLED si estaba apagada
    oled.message("RECEIVING...");
    Serial.println("COMPI READY");

    cpu.clearMemory();
    Serial.setTimeout(5000);
    size_t total = (size_t)len;
    size_t got = 0;
    while (got < total) {
        size_t want = total - got;
        if (want > COMPI_CHUNK) want = COMPI_CHUNK;
        size_t n = Serial.readBytes(cpu.ram() + got, want);
        got += n;
        if (n != want) break;               // hueco/timeout: se corta abajo
        Serial.print("COMPI CHUNK ");
        Serial.println((unsigned long)got);
    }
    Serial.setTimeout(1000);
    if (got != total) {
        Serial.print("COMPI ERR datos ");
        Serial.println((unsigned long)got);
        cpu.reset();
        ui.cursor = 0;
        ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
        noteActivity();
        oled.render(cpu, ui);
        return;
    }

    uint32_t sum = 0;
    const uint8_t* img = cpu.ram();
    for (size_t i = 0; i < PROGRAM_SIZE; ++i) sum += img[i];

    char m[24];
    snprintf(m, sizeof(m), "WRITING slot %02d", slot);
    oled.message(m);
    bool ok = flash.saveProgram(slot, cpu.ram());

    cpu.reset();
    ui.cursor = 0;
    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
    prevSlot = 0xFF;                    // fuerza recargar la previsualizacion
    running = false;

    if (ok) {
        Serial.print("COMPI OK ");
        Serial.println((unsigned long)sum);
    } else {
        Serial.println("COMPI ERR flash");
    }
    noteActivity();
    oled.render(cpu, ui);
}

void provisionDump(int slot, long len) {
    if (slot < 0 || (size_t)slot >= MAX_PROGRAM_SLOTS ||
        len < 0 || len > (long)PROGRAM_SIZE) {
        Serial.println("COMPI ERR header");
        return;
    }
    if (!flash.slotUsed(slot)) {
        Serial.println("COMPI ERR empty");
        return;
    }

    noteActivity();
    char m[24];
    snprintf(m, sizeof(m), "SENDING slot %02d", slot);
    oled.message(m);

    // cpu.ram() de scratch para leer la imagen, igual que provisionLoad() lo
    // usa de scratch para recibirla -- ya se acepta que el provisioning
    // pisa lo que hubiera en RAM (ver cpu.clearMemory() de arriba), no hace
    // falta un buffer de 64 KiB aparte solo para esto. Se lee siempre la
    // imagen ENTERA (loadProgram no admite leer solo un trozo), <len> solo
    // decide cuanto de ella se manda.
    flash.loadProgram(slot, cpu.ram());

    uint32_t sum = 0;
    const uint8_t* img = cpu.ram();
    for (long i = 0; i < len; ++i) sum += img[i];

    Serial.print("COMPI READY ");
    Serial.println((unsigned long)len);
    // Sin trocear ni esperar eco: eso hacia falta en LOAD porque la cola de
    // RECEPCION del USB-CDC del C3 es de solo 256 bytes y descarta en
    // silencio si se llena (ver arriba). Para ENVIAR no hay ese problema --
    // Serial.write() ya bloquea lo que haga falta hasta que cabe.
    Serial.write(cpu.ram(), (size_t)len);
    Serial.print("COMPI OK ");
    Serial.println((unsigned long)sum);

    cpu.reset();
    ui.cursor = 0;
    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
    running = false;
    noteActivity();
    oled.render(cpu, ui);
}

void provisionPoll() {
    if (!Serial.available()) return;

    char line[48];
    size_t n = 0;
    unsigned long t0 = millis();
    while (millis() - t0 < 1000) {
        if (!Serial.available()) continue;
        char c = (char)Serial.read();
        if (c == '\n') break;
        if (c == '\r') continue;
        if (n < sizeof(line) - 1) line[n++] = c;
        t0 = millis();
    }
    line[n] = '\0';

    int slot = -1;
    long len = -1;
    if (sscanf(line, "COMPI LOAD %d %ld", &slot, &len) == 2) {
        provisionLoad(slot, len);
        return;
    }
    if (sscanf(line, "COMPI DUMP %d %ld", &slot, &len) == 2) {
        provisionDump(slot, len);
        return;
    }
    if (sscanf(line, "COMPI DUMP %d", &slot) == 1) {
        provisionDump(slot, (long)PROGRAM_SIZE);   // sin <len>: la imagen entera
        return;
    }
}

void setup() {
    // El USB-CDC nativo del C3 usa una cola de recepción por software de solo
    // 256 bytes por defecto; si se llega a llenar (p. ej. provisionPoll()
    // recibiendo una imagen de 64 KiB), descarta bytes SIN avisar. Hay que
    // fijar esto antes de begin() (ver USBCDC::begin() en el core).
    Serial.setRxBufferSize(8192);
    Serial.begin(115200);
    pinMode(PIN_LED, OUTPUT);
    setLed(false);                     // GPIO8 alto en el arranque (strapping OK)
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);     // piezo en reposo (tone() lo reconfigura)
    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
    panel.begin();
    cpu.setPortRead(portRead);
    cpu.setPortWrite(portWrite);

    if (!oled.begin())  failBlink(200); // parpadeo lento = falla la OLED
    if (!flash.init())  failBlink(80);  // parpadeo rápido = falla la flash

    cpu.reset();
    prevExec = panel.ejecutar();
    prevAbajo = panel.swAbajo();
    running = prevExec && prevAbajo;   // arrancado en EJECUTAR+CONTINUO
    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);   // arranca el editor en lo que haya

    g_scr = START_SCREEN_DIMMED ? SCR_DIM : SCR_FULL;
    oled.contrast(START_SCREEN_DIMMED ? OLED_CONTRAST_DIM : OLED_CONTRAST_FULL);
    oled.render(cpu, ui);

    // Muestreo del panel en su propio temporizador, independiente de loop().
    // Si arranca atenuada, se retrasa g_lastActivity para que la gestión de
    // energía de loop() (basada en tiempo de inactividad) la vea ya "inactiva"
    // desde el primer fotograma, en vez de subirla a pleno brillo de inmediato.
    g_lastActivity = millis() - (START_SCREEN_DIMMED ? SCREEN_DIM_MS : 0);
    esp_timer_create_args_t sargs = {};
    sargs.callback = &samplerCb;
    sargs.dispatch_method = ESP_TIMER_TASK;
    sargs.name = "panel";
    esp_timer_create(&sargs, &g_sampler);
    esp_timer_start_once(g_sampler, (uint64_t)SAMPLE_ACTIVE_MS * 1000);
}

void loop() {
    provisionPoll();
    // panel.update() lo hace el esp_timer (samplerCb), no loop().
    const bool exec  = panel.ejecutar();
    const bool abajo = panel.swAbajo();

    // Vista derivada de los dos interruptores.
    const View view = !exec ? (abajo ? View::EditPrg : View::EditMem)
                            : (abajo ? View::ExecCont : View::ExecPaso);
    ui.view = view;

    const bool enterExec = (exec && !prevExec);
    const bool pasoToggle = (exec && !enterExec && abajo != prevAbajo);
    bool changed = (view != prevView);

    // Entrar en CONTINUO (por el interruptor de modo o por el de paso) siempre
    // reinicia: "CONTINUO ejecuta el programa desde el principio". Entrar en
    // PASO solo congela (para poder inspeccionar dónde quedó / seguir paso a
    // paso desde ahí).
    if (enterExec || (pasoToggle && abajo)) {
        cpu.reset();                       // los programas arrancan en PC=0
        panel.resetPositions();
        memset(g_fb, 0, sizeof(g_fb));
        memset(g_text, 0, sizeof(g_text)); // rejilla de texto -> transparente
        memset(g_attr, 0, sizeof(g_attr)); // atributos de texto -> ninguno
        g_led = 0; setLed(false);          // apaga el LED del programa
        resetTimers();
        resetSound();                      // calla el piezo
        running = abajo;                   // CONTINUO corre; PASO espera
        lastFlush = 0;
    } else if (pasoToggle) {               // -> PASO: congelar
        running = false;
    }
    prevExec = exec;
    prevAbajo = abajo;
    prevView = view;

    // El piezo solo suena en CONTINUO; en PASO / EDITAR se calla.
    if (view != View::ExecCont && g_sndHz) sndApply(0);

    switch (view) {
    case View::EditMem: {
        // Selector de mnemónico (editor.h): DATOS gira cambia el campo activo
        // (verbo -> mode -> operandos); DATOS pulsa confirma y pasa al
        // siguiente, o -si ya era el último campo- avanza el cursor la
        // longitud de la instrucción ya compuesta. DIRECCIÓN navega
        // INSTRUCCIÓN A INSTRUCCIÓN (cada detente = una línea del listado,
        // no un byte): adelante, instrLen() del opcode actual (el cursor
        // siempre está alineado a un límite real, así que instrLen() nunca
        // se equivoca); atrás, prevInstrStart() -- para acceder a un byte
        // suelto DENTRO de la instrucción actual (p. ej. su segundo byte)
        // hace falta convertirla en NOP y avanzar a la línea siguiente, ya
        // no se puede aterrizar a mitad byte a byte. Su pulsador distingue
        // pulsación corta de larga (DIR_LONG_PRESS_MS): corta inserta un NOP
        // suelto en el cursor (insertByteAt), larga borra el byte del cursor
        // (deleteByteAt) -- ninguna de las dos mueve el cursor. Antes esto se
        // hacía manteniendo pulsado DIRECCIÓN mientras se giraba DATOS; se
        // sustituyó por el gesto de pulsación corta/larga, que no roba el
        // giro de DATOS para nada más (ver más abajo).
        if (changed) {
            // vista recién entrada (o venimos de otra): re-decodifica en lo
            // que ya haya en memoria en el cursor actual.
            ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            dirBtnHeld = false; // por si veníamos de otra vista a media pulsación
        }

        if (int16_t d = panel.takeDirDelta()) {
            stepCursorByInstr(ui.cursor, d);
            ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            changed = true;
        }

        if (int16_t v = panel.takeDatDelta()) {
            applyDelta(ui.compose, v);
            assemble(cpu.ram(), 65536u, ui.cursor, ui.compose);   // en vivo
            changed = true;
        }

        if (panel.takeDirPress()) {
            // Flanco de bajada: arranca el cronómetro. Todavía no se sabe si
            // será corta o larga -- eso se decide más abajo, mientras se
            // mantiene pulsado (larga) o al soltar (corta).
            dirBtnHeld = true;
            dirBtnPressMs = millis();
            dirBtnLongFired = false;
        }
        if (dirBtnHeld) {
            if (panel.dirDown()) {
                if (!dirBtnLongFired && millis() - dirBtnPressMs >= DIR_LONG_PRESS_MS) {
                    // Pulsación larga: se dispara en cuanto se cumple el
                    // umbral, sin esperar a soltar (feedback inmediato de
                    // que ya entró en "modo borrar"). deleteByteAt() ya para
                    // sola antes de tocar la pila (cursor >= sp).
                    deleteByteAt(ui.cursor);
                    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
                    dirBtnLongFired = true;
                    changed = true;
                }
            } else {
                // Soltado sin llegar al umbral: pulsación corta -> inserta
                // un NOP suelto en el cursor sin moverlo (insertByteAt,
                // misma frontera de la pila que deleteByteAt).
                if (!dirBtnLongFired) {
                    insertByteAt(ui.cursor);
                    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
                    changed = true;
                }
                dirBtnHeld = false;
            }
        }

        if (panel.takeDatPress()) {
            uint8_t last = lastStep(ui.compose.verb, ui.compose.mode);
            if (ui.compose.step < last) {
                ++ui.compose.step;
            } else {
                uint8_t len = assemble(cpu.ram(), 65536u, ui.cursor, ui.compose);
                ui.cursor = clamp16((long)ui.cursor + len);
                ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            }
            changed = true;
        }
        break;
    }
    case View::EditPrg: {
        int16_t d = panel.takeDirDelta();
        if (d) {
            int s = ((int)ui.slot + d) % (int)MAX_PROGRAM_SLOTS;
            if (s < 0) s += (int)MAX_PROGRAM_SLOTS;
            ui.slot = (uint8_t)s;
            // cambiar de slot vuelve siempre a LOAD: si se dejaba SAVE o
            // NEW elegido de un slot anterior, girar a otro slot sin
            // querer podria acabar guardando/borrando el que no tocaba
            ui.prgAction = PrgAction::Cargar;
            changed = true;
        }
        if (int16_t dd = panel.takeDatDelta()) {
            // gira entre las 3 acciones (Cargar/Guardar/Nuevo); el sentido
            // del giro decide para qué lado se avanza en el ciclo
            int a = ((int)ui.prgAction + (dd > 0 ? 1 : -1) + 3) % 3;
            ui.prgAction = (PrgAction)a;
            changed = true;
        }
        // Los dos pulsadores hacen lo mismo aquí: ejecutan prgAction (LOAD,
        // SAVE o NEW, lo que esté elegido con el giro de DATOS). No hay una
        // acción "solo cargar" fija en ningún botón -- si prgAction está en
        // SAVE, pulsar cualquiera de los dos guarda. Ambos take*Press() se
        // llaman siempre (sin cortocircuito de ||): cada uno consume su
        // propio evento de pulsación, y saltarse la llamada dejaría una
        // pulsación sin consumir para el siguiente fotograma.
        const bool datPressed = panel.takeDatPress();
        const bool dirPressed = panel.takeDirPress();
        if (datPressed || dirPressed) {
            switch (ui.prgAction) {
                case PrgAction::Cargar:  loadSlot(ui.slot); break;
                case PrgAction::Guardar: saveSlot(ui.slot); break;
                case PrgAction::Nuevo:   newSlot();         break;
            }
            prevSlot = 0xFF;               // fuerza recargar la previsualización
            changed = true;
        }

        if (ui.slot != prevSlot) {
            prevSlot = ui.slot;
            ui.slotUsed = flash.slotUsed((int)ui.slot);
            ui.preview = g_preview;
            ui.previewLen = (ui.slotUsed &&
                             flash.previewProgram((int)ui.slot, g_preview, PREVIEW_BYTES))
                                ? PREVIEW_BYTES : 0;
            changed = true;
        }
        break;
    }
    case View::ExecPaso: {
        // DIRECCIÓN aquí NO ejecuta nada al girar: solo elige una dirección
        // (ui.cursor, navegado instrucción a instrucción igual que en
        // EditMem -- ver stepCursorByInstr) para usarla como objetivo. Su
        // pulsador distingue corta de larga (mismo gesto y umbral que ya usa
        // EditMem para insertar/borrar, DIR_LONG_PRESS_MS): corta arranca
        // una carrera hacia ADELANTE hasta que el PC llegue a esa dirección
        // (no hay forma de "ir hacia atrás" en la ejecución, así que apuntar
        // detrás del PC actual da una vuelta completa antes de llegar);
        // larga resetea, igual que antes hacía cualquier pulsación de
        // DIRECCIÓN. DATOS sigue ejecutando (girar adelante = varios pasos
        // de golpe, pulsar = un paso); girar DATOS hacia atrás NO hace nada
        // por ahora (queda para DIRECCIÓN, que lo hace de forma más lógica:
        // eliges destino y lo ves llegar, en vez de volver "a donde estabas").
        if (changed) {
            dirBtnHeld = false;          // por si veníamos de otra vista a media pulsación
            ui.pasoFollowCursor = false; // al entrar, el listado sigue al PC
            ui.cursor = cpu.pc();        // y el # arranca coincidiendo con él
        }

        // Sigue una carrera ya en marcha ANTES de leer más entrada de este
        // fotograma: a trozos de EXEC_BATCH pasos, para no bloquear ni el
        // sondeo del panel ni el refresco de pantalla mientras dura -- el
        // listado (siguiendo al PC, ver ui.pasoFollowCursor/display.cpp) se
        // ve avanzar solo, fotograma a fotograma, hasta llegar o pararse.
        // tickTimers() aquí, una vez por fotograma, igual que en CONTINUO:
        // una carrera SÍ es "tiempo real corriendo" (tarda fotogramas de
        // verdad en completarse), así que los temporizadores tienen que
        // avanzar de verdad para que un bucle de espera con IN/CMP/JMPNZ
        // pueda llegar a terminar por sí solo durante la carrera.
        if (pasoRunning) {
            tickTimers();
            for (int i = 0; i < EXEC_BATCH; ++i) {
                if (cpu.halted()) { pasoRunning = false; break; }
                cpu.step();
                if (cpu.pc() == pasoTargetPC) { pasoRunning = false; break; }
            }
            ui.cursor = cpu.pc();         // el # sigue al PC (nunca se queda atrás)
            ui.pasoFollowCursor = false;   // termine como termine, a ver el PC
            changed = true;
        }

        if (panel.takeDatPress() && !pasoRunning && !cpu.halted()) {
            // tickTimers() justo antes del paso: pone los temporizadores al
            // día con el tiempo real transcurrido desde el ÚLTIMO paso
            // ejecutado (no mientras se está quieto sin pulsar nada -- eso
            // seguiría siendo "congelado" de verdad, para poder mirar la
            // pantalla el rato que haga falta sin que nada avance solo).
            // Los rápidos (t0..t7, <=128 ms/paso) van a dar casi siempre 0,
            // porque hasta la pulsación más rápida de un humano tarda más
            // que eso; los lentos (t8/t9, 256/512 ms) sí pueden reflejar de
            // verdad el tiempo que ha pasado entre una pulsación y la
            // siguiente.
            tickTimers();
            cpu.step();
            ui.cursor = cpu.pc();         // el # sigue al PC (nunca se queda atrás)
            ui.pasoFollowCursor = false;   // el PC se movió: que se vea
            changed = true;
        }

        if (int16_t d = panel.takeDirDelta()) {
            stepCursorByInstr(ui.cursor, d);
            // Girar ADDRESS SÍ hace que el listado siga al cursor en vez de
            // al PC -- para poder ver el código mientras se elige un
            // objetivo lejos de donde está el PC ahora mismo. En cuanto se
            // toque DATOS (arriba/abajo) o arranque/termine una carrera,
            // vuelve a seguir al PC: la garantía de "el PC siempre se ve"
            // solo cede mientras se está eligiendo, nunca mientras se
            // ejecuta algo.
            ui.pasoFollowCursor = true;
            changed = true;
        }

        if (panel.takeDirPress()) {
            dirBtnHeld = true;
            dirBtnPressMs = millis();
            dirBtnLongFired = false;
        }
        if (dirBtnHeld) {
            if (panel.dirDown()) {
                if (!dirBtnLongFired && millis() - dirBtnPressMs >= DIR_LONG_PRESS_MS) {
                    // Larga: reset, sin esperar a soltar (igual que el resto
                    // de gestos corta/larga de este firmware).
                    cpu.reset();
                    pasoRunning = false;   // un reset a medio camino invalida el objetivo
                    ui.cursor = cpu.pc();  // el # sigue al PC (que vuelve a 0)
                    ui.pasoFollowCursor = false;   // PC vuelve a 0: que se vea
                    panel.resetPositions();
                    memset(g_fb, 0, sizeof(g_fb));
                    memset(g_text, 0, sizeof(g_text));
                    memset(g_attr, 0, sizeof(g_attr));
                    g_led = 0; setLed(false);
                    resetTimers();
                    resetSound();
                    dirBtnLongFired = true;
                    changed = true;
                }
            } else {
                // Corta: arranca la carrera hacia ui.cursor. Si el PC nunca
                // llega ahí (o el programa hace HALT antes), no termina sola
                // -- una pulsación larga (reset) o volver a EDIT la corta.
                if (!dirBtnLongFired && !pasoRunning && !cpu.halted()) {
                    pasoTargetPC = ui.cursor;
                    pasoRunning = true;
                    ui.pasoFollowCursor = false;   // arranca la carrera: a ver el PC moverse
                    changed = true;
                }
                dirBtnHeld = false;
            }
        }

        if (int16_t d = panel.takeDatDelta()) {
            // Adelante: cada detente ejecuta una instruccion mas, igual que
            // pulsar DATOS pero contando los detentes de golpe (para poder
            // pasar varias de un tiron girando rapido, sin pulsar una a
            // una). Atras: nada (ver el comentario de arriba).
            if (!pasoRunning && !cpu.halted() && d > 0) {
                // tickTimers() una vez para todo el grupo de pasos de este
                // giro (mismo motivo que en el pulsador de arriba): son
                // pasos "de un tirón" en tiempo real, no uno por cada uno.
                tickTimers();
                for (int16_t i = 0; i < d && !cpu.halted(); ++i) cpu.step();
                ui.cursor = cpu.pc();         // el # sigue al PC (nunca se queda atrás)
                ui.pasoFollowCursor = false;   // el PC se movió: que se vea
                changed = true;
            }
        }
        break;
    }
    case View::ExecCont: {
        tickTimers();
        tickSound();
        if (running && !cpu.halted()) {
            // cpu.run(N) en vez de un bucle propio llamando a cpu.step(): al
            // estar run()/step() en el mismo archivo (cpu.cpp), el compilador
            // integra step() dentro del bucle de run() (visto con -O3, ver
            // platformio.ini). Llamado asi desde main.cpp, cada iteracion
            // pagaba una llamada de funcion real cruzando de fichero -- la
            // que -O3 no puede eliminar sin LTO -- en la instruccion mas
            // ejecutada de todo el firmware.
            cpu.run(EXEC_BATCH);
        }
        if (cpu.halted() && g_sndHz) sndApply(0);   // silencio al llegar a HALT
        if (g_scr != SCR_OFF && (millis() - lastFlush) >= FB_FLUSH_MS) {
            oled.renderFramebuffer(g_fb, g_text, g_attr, cpu.halted());
            lastFlush = millis();
        }
        panel.takeDirPress();
        panel.takeDatPress();
        panel.takeDirDelta();
        panel.takeDatDelta();
        break;
    }
    }

    // --- gestión de energía ------------------------------------------
    // Un programa ejecutando en CONTINUO cuenta como "en uso" (no atenúa, no
    // duerme, muestreo rápido).
    g_execActive = (view == View::ExecCont && running && !cpu.halted());
    const uint32_t idleMs = g_execActive ? 0 : (millis() - g_lastActivity);

    applyScreenPower(idleMs < SCREEN_DIM_MS ? SCR_FULL
                   : idleMs < SCREEN_OFF_MS ? SCR_DIM : SCR_OFF);

    if (view != View::ExecCont && (changed || g_forceRender)) {
        oled.render(cpu, ui);
    }
    g_forceRender = false;   // en ExecCont repinta el volcado del framebuffer

#ifndef COMPI_NO_LIGHT_SLEEP
    // Reposo prolongado y sin programa en marcha: light sleep. Conserva la RAM
    // (los 64 KiB de la CPU emulada) y despierta en <1 ms. No dormimos si hay
    // un host de serie conectado (desarrollo / provisioning por USB-CDC).
    if (!g_execActive && idleMs >= LIGHT_SLEEP_MS && !Serial) {
        digitalWrite(PIN_BUZZER, LOW);
        setLed(false);
        // Despierta con el timer (backstop) o con la propia alarma del sampler,
        // que corre justo al despertar y refresca el panel / g_lastActivity.
        esp_sleep_enable_timer_wakeup((uint64_t)SAMPLE_IDLE_MS * 1000);
        esp_light_sleep_start();
    }
#endif
}
