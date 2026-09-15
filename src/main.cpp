#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "esp_timer.h"
#include "esp_sleep.h"
#include "cpu.h"
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
constexpr unsigned long FB_FLUSH_MS = 50;

// --- Ahorro de energía (funcionamiento con batería) --------------------
// El panel se muestrea desde un esp_timer, NO desde loop(), así que sigue
// respondiendo aunque la OLED esté volcando (~30 ms) o se esté grabando la
// flash (~1 s). El ritmo es adaptativo: 2 ms mientras hay actividad, 100 ms en
// reposo (menos despertares -> menos consumo). Con la CPU en reposo prolongado
// se apaga la OLED y se entra en light sleep (conserva los 64 KiB de RAM).
//
// Nota de hardware: para despertar del light sleep girando un encoder haría
// falta una línea de "actividad de panel" (OR de las señales activas-bajas)
// a un GPIO RTC. Sin ella, en light sleep se muestrea el '165 cada 100 ms;
// un giro mantenido despierta en ~200 ms, un toque de pulsador también.
constexpr uint32_t SAMPLE_ACTIVE_MS  = 2;      // muestreo del '165 en uso
constexpr uint32_t SAMPLE_SCREENON_MS = 20;    // pantalla encendida pero sin tocar
constexpr uint32_t SAMPLE_IDLE_MS    = 100;    // pantalla atenuada/apagada
constexpr uint32_t ACTIVE_WINDOW_MS  = 2000;   // sigue a 2 ms tras la última actividad
constexpr uint32_t SCREEN_DIM_MS     = 20000;  // atenuar la OLED por inactividad
constexpr uint32_t SCREEN_OFF_MS     = 45000;  // apagar la OLED
constexpr uint32_t LIGHT_SLEEP_MS    = 45000;  // dormir la CPU (light sleep); >= SCREEN_OFF_MS
constexpr uint8_t  OLED_CONTRAST_FULL = 0xCF;
constexpr uint8_t  OLED_CONTRAST_DIM  = 0x10;

Cpu cpu;
FrontPanel panel(PIN_HC165_LOAD, PIN_HC165_CLOCK, PIN_HC165_DATA);
OledPanel oled(0x3C);
SpiFlashStorage flash(PIN_FLASH_CS);

static uint8_t g_fb[FB_BYTES];              // framebuffer del dispositivo (puertos)
static uint8_t g_text[TEXT_CELLS];          // rejilla de texto (puertos 0x0400+)
static uint8_t g_preview[PREVIEW_BYTES];    // primeros bytes del slot (EditPrg)

UiState ui;
bool prevExec = false;
bool prevAbajo = false;
View prevView = View::EditMem;
uint8_t prevSlot = 0xFF;
bool running = false;
unsigned long lastFlush = 0;
uint8_t g_led = 0;                          // estado del LED (puerto PORT_LED)
uint8_t g_timer[TIMER_COUNT] = {0};         // temporizadores (puertos 0x0520+)
unsigned long g_timerLast[TIMER_COUNT] = {0};

// Sonido (puertos 0x0530..0x0533). g_sndHz = tono que suena ahora (0 = silencio).
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

// --- Sonido (piezo pasivo en PIN_BUZZER, puertos 0x0530..0x0533) -----
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

// --- Puertos de E/S de la CPU (espacio de 16 bits) --------------------
uint8_t portRead(uint16_t port) {
    if (port < FB_BYTES) return g_fb[port];
    { int ti = textIndex(port); if (ti >= 0) return g_text[ti]; }
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

// --- Provisioning por USB-CDC ----------------------------------------------
// Recibe una imagen de RAM (<= 64 KiB) por el puerto serie y la graba en un
// slot de la flash, sin tener que teclearla byte a byte en el panel.
//
// Protocolo  (host -> aparato):
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
// Por que a trozos y con eco: el USB-CDC nativo del C3 (USBCDC.cpp, core de
// Arduino) mete los bytes que llegan en una cola de software de solo 256
// bytes por defecto; si se llena, LOS DESCARTA SIN AVISAR (no hay control de
// flujo a nivel de aplicacion). Ya se agranda esa cola en setup(), pero
// exigir un "COMPI CHUNK" por cada bloque obliga al host a ir al ritmo del
// aparato pase lo que pase, en vez de fiarlo todo al tamaño del buffer.
//
// Se sondea al principio de cada loop(). Las lineas que no empiezan por
// "COMPI LOAD " se ignoran (se puede seguir usando el monitor serie).
constexpr size_t COMPI_CHUNK = 1024;
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
    if (sscanf(line, "COMPI LOAD %d %ld", &slot, &len) != 2) return;
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

    oled.contrast(OLED_CONTRAST_FULL);
    oled.render(cpu, ui);

    // Muestreo del panel en su propio temporizador, independiente de loop().
    g_lastActivity = millis();
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
        // longitud de la instrucción ya compuesta. DIRECCIÓN sigue navegando
        // libremente byte a byte; su pulsador retrocede un campo (o una
        // dirección si ya estabas en el primero).
        if (changed) {
            // vista recién entrada (o venimos de otra): re-decodifica en lo
            // que ya haya en memoria en el cursor actual.
            ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
        }

        int16_t d = panel.takeDirDelta();
        if (d) {
            ui.cursor = clamp16((long)ui.cursor + d);
            ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            changed = true;
        }

        int16_t v = panel.takeDatDelta();
        if (v) {
            applyDelta(ui.compose, v);
            assemble(cpu.ram(), 65536u, ui.cursor, ui.compose);   // en vivo
            changed = true;
        }

        if (panel.takeDirPress()) {
            if (ui.compose.step > 0) {
                --ui.compose.step;
            } else if (ui.cursor) {
                --ui.cursor;
                ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            }
            changed = true;
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
            changed = true;
        }
        if (panel.takeDatDelta()) {
            ui.prgAction = (ui.prgAction == PrgAction::Cargar) ? PrgAction::Guardar
                                                              : PrgAction::Cargar;
            changed = true;
        }
        if (panel.takeDatPress()) {
            if (ui.prgAction == PrgAction::Cargar) loadSlot(ui.slot);
            else                                   saveSlot(ui.slot);
            prevSlot = 0xFF;               // fuerza recargar la previsualización
            changed = true;
        }
        panel.takeDirPress();              // sin uso en esta vista

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
        if (panel.takeDatPress() && !cpu.halted()) { cpu.step(); changed = true; }
        if (panel.takeDirPress()) {
            cpu.reset();
            panel.resetPositions();
            memset(g_fb, 0, sizeof(g_fb));
            memset(g_text, 0, sizeof(g_text));
            g_led = 0; setLed(false);
            resetTimers();
            resetSound();
            changed = true;
        }
        panel.takeDirDelta();
        panel.takeDatDelta();
        break;
    }
    case View::ExecCont: {
        tickTimers();
        tickSound();
        if (running && !cpu.halted()) {
            for (int i = 0; i < EXEC_BATCH && !cpu.halted(); ++i) cpu.step();
        }
        if (cpu.halted() && g_sndHz) sndApply(0);   // silencio al llegar a HALT
        if (g_scr != SCR_OFF && (millis() - lastFlush) >= FB_FLUSH_MS) {
            oled.renderFramebuffer(g_fb, g_text, cpu.halted());
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
