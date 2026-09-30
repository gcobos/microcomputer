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

// Botón BOOT (GPIO9) reutilizado como MUTE/UNMUTE general, disponible EN
// TODO MOMENTO sin importar qué programa corre ni en qué modo esté el
// panel (por eso se sondea en loop() antes de cualquier otra cosa, nunca
// dentro del switch(view) de más abajo). docs/hardware.md lo marca como
// "pin que no se puede usar" por ser de *strapping* y por ser la vía de
// recuperación manual de flasheo (mantenerlo pulsado al enchufar si falla
// el auto-reset) -- eso solo importa en el instante del reset/arranque; leerlo
// como entrada normal durante la ejecución no interfiere con ninguna de
// las dos cosas. Activo a nivel bajo (pulsador a GND, pull-up interno).
constexpr uint8_t PIN_BOOT_BTN = 9;
constexpr unsigned long BOOT_BTN_DEBOUNCE_MS = 30;

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
// (2 ms vs 4/8 ms): un salto grande haría que, nada más dejar de tocar el
// panel, un giro posterior pudiera empezar a perderse casi por completo
// hasta girar muy rápido -- con separaciones así de pequeñas el consumo
// extra en reposo es mínimo y la respuesta se mantiene prácticamente igual
// que "activo".
//
// Nota de hardware: para despertar del light sleep girando un encoder haría
// falta una línea de "actividad de panel" (OR de las señales activas-bajas)
// a un GPIO RTC. Sin ella, en light sleep se muestrea el '165 cada
// SAMPLE_IDLE_MS; un giro corto y rápido puede caer entero dentro del hueco
// entre dos muestras y perderse -- de ahí que SAMPLE_IDLE_MS se mantenga
// bajo en vez de subirlo para ahorrar más batería.
constexpr uint32_t SAMPLE_ACTIVE_MS  = 2;      // muestreo del '165 en uso
constexpr uint32_t SAMPLE_SCREENON_MS = 4;     // pantalla encendida pero sin tocar
constexpr uint32_t SAMPLE_IDLE_MS    = 8;      // pantalla atenuada/apagada
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
// Búfer de recepción/envío del provisioning por USB (ver provisionLoad()/
// provisionDump() más abajo). Aparte de cpu.ram() a propósito: si se usara
// la RAM de la CPU como antes, mandar o pedir CUALQUIER slot por USB borraba
// y paraba lo que estuviera corriendo en ese momento, aunque fuera un slot
// distinto del que se estaba transmitiendo. El C3 tiene 320 KiB de sobra
// para permitirse este segundo búfer de 64 KiB.
static uint8_t g_provisionBuf[PROGRAM_SIZE];

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

// Brillo "a pleno uso" (puerto PORT_CFG_BRIGHTNESS, iomap.h): reemplaza a
// OLED_CONTRAST_FULL como el valor que usa applyScreenPower() para SCR_FULL,
// para que un programa pueda pedir su propio brillo sin desmontar el ahorro
// de energía automático (que sigue atenuando/apagando por inactividad igual
// que siempre, solo que "pleno" pasa a ser este valor). Vuelve al de fábrica
// en cada arranque de ejecución nueva, ver clearRuntimeOutputs().
uint8_t g_screenContrast = OLED_CONTRAST_FULL;
uint8_t g_timer[TIMER_COUNT] = {0};         // temporizadores (puertos 0x0620+)
unsigned long g_timerLast[TIMER_COUNT] = {0};

// Sonido (puertos 0x0630..0x0633). g_sndHz = tono que suena ahora (0 = silencio).
uint8_t  g_sndLo = 0, g_sndHi = 0;          // frecuencia enganchada (bytes)
uint8_t  g_sndNote = 0;                     // última nota MIDI escrita (eco de IN)
uint8_t  g_sndDurUnits = 0;                 // duración auto en unidades de 10 ms
uint16_t g_sndHz = 0;
unsigned long g_sndOffAt = 0;               // millis() en que callar; 0 = sostenido

// Mute general (botón BOOT, ver PIN_BOOT_BTN). Empieza con el sonido
// ACTIVADO. Mientras g_soundMuted esté a true, sndApply() no llama a
// tone() -- el programa en curso sigue escribiendo en los puertos de
// sonido con total normalidad, solo se corta la salida física.
bool g_soundMuted = false;
bool g_bootBtnRawPrev = HIGH;               // ultima lectura CRUDA (para detectar el cambio)
bool g_bootBtnStable = HIGH;                // estado ya anti-rebotado
unsigned long g_bootBtnLastChangeMs = 0;

// Jingle de "sonido reactivado": 2 notas cortas, NO bloqueante (se avanza
// un paso por vuelta de loop(), igual que tickSound() -- nunca se para la
// emulación de la CPU para reproducirlo). Mientras suena, g_soundMuted
// sigue en true (ver tickMuteJingle) para que no compita con el propio
// sonido del programa por el único zumbador: se desmutea de verdad justo
// al terminar la melodia.
constexpr uint16_t MUTE_JINGLE_HZ[2] = {880, 1175};   // La5, Re6 -- subida alegre
constexpr unsigned long MUTE_JINGLE_NOTE_MS = 110;
bool g_muteJingleActive = false;
uint8_t g_muteJingleStep = 0;                // 0 = sonando nota 1, 1 = sonando nota 2
unsigned long g_muteJingleNoteEndMs = 0;

// Carga/grabado de programas desde el propio programa (puertos 0x0640/41).
// Eco de si el ULTIMO intento salio bien -- ver el comentario de estos
// puertos en iomap.h (el de carga solo tiene sentido leerlo tras un fallo).
uint8_t g_lastLoadOk = 0;                   // 1 = el ultimo intento de carga FALLO
uint8_t g_lastSaveOk = 0;

// Numero de slot al que corresponde lo que hay AHORA MISMO en cpu.ram() --
// arranque automatico del slot 0, un Cargar/Guardar del panel, o un OUT a
// PORT_PROG_LOAD/PORT_PROG_SAVE lo actualizan (ver esas funciones/handlers
// mas abajo). Los puertos de EEPROM por slot (iomap.h PORT_EEPROM_*)
// siempre operan sobre ESTE slot, para que un programa no tenga que conocer
// ni pasar su propio numero.
uint8_t g_currentSlot = 0;

// EEPROM por slot (puertos 0x0700-0x07FF/0x0800/0x0801, iomap.h): bufer de
// trabajo en RAM -- LDA/OUT sobre 0x0700+i lo leen/escriben al instante, sin
// tocar la flash; PORT_EEPROM_LOAD/SAVE lo sincronizan de verdad contra
// flash.readEeprom()/writeEeprom() para g_currentSlot. Se reinicia a 0 en
// cada arranque de ejecucion nueva (clearRuntimeOutputs(), como el resto de
// "salidas") para no heredar el bufer de quien corriera antes.
uint8_t g_eeprom[EEPROM_SLOT_SIZE] = {0};
uint8_t g_lastEepromLoadOk = 0;             // 1 = el ultimo intento de carga FALLO
uint8_t g_lastEepromSaveOk = 0;             // 1 = la ultima grabacion salio bien

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
        // No toca el zumbador de verdad mientras suena el jingle de
        // reactivar el sonido (g_muteJingleActive): esta funcion la llaman
        // muchos sitios del firmware para "callar el sonido DEL PROGRAMA",
        // y ese silencio no tiene por que cortar una melodia de UI que esta
        // sonando encima en ese mismo instante -- el estado emulado
        // (g_sndHz/g_sndOffAt) se pone a cero igual, solo se salta la
        // llamada fisica a noTone().
        if (g_sndHz && !g_muteJingleActive) noTone(PIN_BUZZER);
        g_sndHz = 0;
        g_sndOffAt = 0;
        return;
    }
    // Mientras esta muteado NO se toca el zumbador de verdad -- el programa
    // sigue creyendo que el tono suena (g_sndHz/g_sndOffAt se actualizan
    // igual) para que, en cuanto se desmutee, todo siga su curso normal sin
    // que el programa tenga que volver a escribir nada.
    if (!g_soundMuted) tone(PIN_BUZZER, hz);
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

// --- Jingle de "sonido reactivado" (ver g_muteJingleActive más arriba) ---
void startMuteJingle() {
    g_muteJingleActive = true;
    g_muteJingleStep = 0;
    tone(PIN_BUZZER, MUTE_JINGLE_HZ[0]);
    g_muteJingleNoteEndMs = millis() + MUTE_JINGLE_NOTE_MS;
}

// Llamada una vez por vuelta de loop(), SIEMPRE (igual que tickBootButton) --
// avanza el jingle un paso sin bloquear nunca la emulación de la CPU.
void tickMuteJingle() {
    if (!g_muteJingleActive) return;
    if ((long)(millis() - g_muteJingleNoteEndMs) < 0) return;
    if (g_muteJingleStep == 0) {
        g_muteJingleStep = 1;
        tone(PIN_BUZZER, MUTE_JINGLE_HZ[1]);
        g_muteJingleNoteEndMs = millis() + MUTE_JINGLE_NOTE_MS;
    } else {
        noTone(PIN_BUZZER);
        g_muteJingleActive = false;
        g_soundMuted = false;   // ya termino la melodia: el sonido vuelve de verdad
    }
}

// --- Botón BOOT (GPIO9) como MUTE/UNMUTE general, con antirrebote --------
void toggleMute() {
    if (g_muteJingleActive) {
        // pulsacion durante la propia melodia de reactivacion: la corta y
        // mutea de nuevo directamente, sin dejarla terminar
        g_muteJingleActive = false;
        noTone(PIN_BUZZER);
        g_soundMuted = true;
        return;
    }
    if (g_soundMuted) {
        startMuteJingle();   // sigue "muteado" (ver tickMuteJingle) hasta que acabe
    } else {
        g_soundMuted = true;
        if (g_sndHz) noTone(PIN_BUZZER);
    }
}

// Llamada la PRIMERA en cada vuelta de loop(), antes de mirar el modo del
// panel: el mute tiene que responder pulse lo que pulse el interruptor de
// modo, y corra el programa que corra en ese slot.
void tickBootButton() {
    bool raw = digitalRead(PIN_BOOT_BTN);
    if (raw != g_bootBtnRawPrev) {
        g_bootBtnRawPrev = raw;
        g_bootBtnLastChangeMs = millis();
    }
    if ((millis() - g_bootBtnLastChangeMs) >= BOOT_BTN_DEBOUNCE_MS &&
        raw != g_bootBtnStable) {
        g_bootBtnStable = raw;
        if (g_bootBtnStable == LOW) toggleMute();   // flanco de pulsacion (activo a nivel bajo)
    }
}

// Deja pantalla/LED/sonido/encoders como al entrar en una ejecucion nueva
// (ver el bloque enterExec de más abajo, y el reset largo de ExecPaso) --
// SIN tocar la CPU (pc_/regs_/sp_/flags_/RAM), que cada llamador resetea o
// no segun le convenga. Factorizado aparte porque PORT_PROG_LOAD (ver
// portWrite) necesita exactamente esto mismo: el programa que arranca no
// debe heredar la pantalla, el LED o un tono en marcha del que lo cargo.
void clearRuntimeOutputs() {
    panel.resetPositions();
    memset(g_fb, 0, sizeof(g_fb));
    memset(g_text, 0, sizeof(g_text));
    memset(g_attr, 0, sizeof(g_attr));
    g_led = 0; setLed(false);
    resetTimers();
    resetSound();
    // Brillo (PORT_CFG_BRIGHTNESS): de fábrica en cada ejecución nueva, para
    // que un programa no le deje el brillo cambiado al siguiente -- a
    // diferencia del mute (g_soundMuted), que SÍ persiste (ver iomap.h).
    g_screenContrast = OLED_CONTRAST_FULL;
    oled.contrast(g_screenContrast);   // inofensivo aunque este apagada (DISPLAYOFF)
    // Bufer de trabajo de la EEPROM por slot: igual que el brillo, no debe
    // heredar lo que dejara escrito (sin grabar) el programa anterior.
    memset(g_eeprom, 0, sizeof(g_eeprom));
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
    if (port >= PORT_EEPROM_BASE && port < PORT_EEPROM_BASE + EEPROM_SLOT_SIZE)
        return g_eeprom[port - PORT_EEPROM_BASE];
    switch (port) {
        case PORT_DIR_POS: return panel.dirPos();
        case PORT_DIR_BTN: return panel.dirDown() ? 1 : 0;
        case PORT_DAT_POS: return panel.datPos();
        case PORT_DAT_BTN: return panel.datDown() ? 1 : 0;
        case PORT_LED:     return g_led;
        case PORT_PROG_LOAD: return g_lastLoadOk;
        case PORT_PROG_SAVE: return g_lastSaveOk;
        case PORT_CFG_BRIGHTNESS: return g_screenContrast;
        case PORT_CFG_SOUND_EN:   return g_soundMuted ? 0 : 1;
        case PORT_EEPROM_LOAD:    return g_lastEepromLoadOk;
        case PORT_EEPROM_SAVE:    return g_lastEepromSaveOk;
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
    if (port == PORT_LED) { g_led = (uint8_t)(value & 1); setLed(g_led); return; }
    if (port == PORT_PROG_LOAD) {
        // "salto" a otro programa: si el slot existe, sustituye la RAM
        // entera y reinicia la CPU (PC/SP/flags/registros) para que la
        // SIGUIENTE instruccion ejecutada ya sea la primera del programa
        // cargado -- ver el comentario de este puerto en iomap.h. Si falla
        // (slot vacio o fuera de 0..59) no se toca nada y sigue corriendo
        // el programa que hizo el OUT.
        const bool loadOk = flash.loadProgram((int)value, cpu.ram());
        g_lastLoadOk = loadOk ? 0 : 1;   // IN 0x0640 = 1 si FALLO (ver iomap.h)
        if (loadOk) {
            g_currentSlot = value;   // ver g_currentSlot arriba
            cpu.reset();
            // el programa que arranca no debe heredar la pantalla, el LED
            // ni un tono en marcha de quien lo cargo (p.ej. un "sistema
            // operativo" en un slot que encadena varios programas) -- lo
            // mismo que ya se hace al entrar en una ejecucion nueva por el
            // interruptor del panel, ver clearRuntimeOutputs().
            clearRuntimeOutputs();
        }
        return;
    }
    if (port == PORT_PROG_SAVE) {
        // volcado sin panel ni cable: graba la RAM actual entera en el slot
        // pedido y sigue ejecutandose el mismo programa (a diferencia de
        // PORT_PROG_LOAD, esto no es un salto).
        g_lastSaveOk = flash.saveProgram((int)value, cpu.ram()) ? 1 : 0;
        if (g_lastSaveOk) g_currentSlot = value;   // ver g_currentSlot arriba
        return;
    }
    if (port >= PORT_EEPROM_BASE && port < PORT_EEPROM_BASE + EEPROM_SLOT_SIZE) {
        g_eeprom[port - PORT_EEPROM_BASE] = value;   // solo el bufer en RAM
        return;
    }
    if (port == PORT_EEPROM_LOAD) {
        const bool ok = flash.readEeprom(g_currentSlot, g_eeprom);
        g_lastEepromLoadOk = ok ? 0 : 1;   // IN 0x0800 = 1 si FALLO (ver iomap.h)
        return;
    }
    if (port == PORT_EEPROM_SAVE) {
        g_lastEepromSaveOk = flash.writeEeprom(g_currentSlot, g_eeprom) ? 1 : 0;
        return;
    }
    if (port == PORT_CFG_BRIGHTNESS) {
        // Se aplica al instante (aunque ahora mismo este atenuada/apagada:
        // oled.contrast() no enciende la pantalla, solo cambia el registro
        // de contraste real -- se vera en cuanto vuelva a encenderse) y
        // ademas queda como el nuevo "pleno brillo" para el ahorro de
        // energia automatico -- ver g_screenContrast e iomap.h.
        g_screenContrast = value;
        oled.contrast(g_screenContrast);
        return;
    }
    if (port == PORT_CFG_SOUND_EN) {
        // Mismo interruptor general que el boton BOOT (g_soundMuted), pero
        // sin su "jingle" de reactivacion -- eso es una cortesia pensada
        // para que la note un humano, no para dispararla desde código. Ver
        // toggleMute() mas arriba para el equivalente con jingle.
        bool enable = (value != 0);
        if (!enable) {
            if (!g_soundMuted && g_sndHz) noTone(PIN_BUZZER);
            g_soundMuted = true;
        } else if (g_soundMuted) {
            g_soundMuted = false;
            if (g_sndHz) tone(PIN_BUZZER, g_sndHz);   // retoma el tono en marcha, si habia
        }
        return;
    }
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
        oled.contrast(want == SCR_DIM ? OLED_CONTRAST_DIM : g_screenContrast);
    }
    g_scr = want;
}

void noteActivity() {
    g_lastActivity = millis();
    applyScreenPower(SCR_FULL);
}

// Fuerza un repintado completo de la OLED en la siguiente vuelta de loop(),
// sin importar la vista actual -- para cuando oled.message() (provisioning)
// ha escrito un texto transitorio directo al panel, sin pasar por g_fb/
// oled.render(), y hay que asegurarse de que no se quede colgado en pantalla.
void forceRedraw() {
    g_forceRender = true;   // EditMem/EditPrg/ExecPaso: ver el switch de loop()
    lastFlush = 0;          // ExecCont: fuerza el proximo volcado del framebuffer
}

void loadSlot(uint8_t s) {
    if (flash.loadProgram((int)s, cpu.ram())) {
        g_currentSlot = s;   // ver g_currentSlot arriba (EEPROM por slot)
        cpu.reset();
        ui.cursor = 0;
        ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);   // resincroniza el editor
    }
}

void saveSlot(uint8_t s) {
    char m[24];
    snprintf(m, sizeof(m), "SAVING slot %02u", (unsigned)s);
    oled.message(m);
    if (flash.saveProgram((int)s, cpu.ram())) g_currentSlot = s;
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

// Si `st` (ya con el verbo/mode decididos, longitud final conocida) ocupa
// MÁS que `origLen` (lo que hubiera en `cursor` antes de empezar a
// editarla), abre hueco insertando NOPs justo DESPUÉS de esa longitud
// original -- nunca antes: todo lo que hay entre `cursor` y
// `cursor+origLen` es, como mucho, la instrucción vieja o la nueva ya
// escrita ahí dentro (ambas caben en ese hueco por definición), así que
// solo hace falta insertar donde empezaría a invadir la instrucción
// siguiente. Reutiliza insertByteAt (misma frontera de la pila: si no hay
// sitio, sencillamente no llega a abrir todo el hueco pedido, igual que ya
// pasa insertando a mano con ADDRESS). Si `st` cabe igual o mejor que
// antes, no hace falta nada.
void ensureRoomFor(uint16_t cursor, const ComposeState& st, uint8_t origLen) {
    uint8_t finalLen = composedLength(st);
    if (finalLen <= origLen) return;
    uint16_t at = (uint16_t)(cursor + origLen);
    for (uint8_t i = 0; i < (uint8_t)(finalLen - origLen); ++i) {
        insertByteAt(at);
    }
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

    memset(g_provisionBuf, 0, PROGRAM_SIZE);   // el resto de los 64 KiB va a 0
    Serial.setTimeout(5000);
    size_t total = (size_t)len;
    size_t got = 0;
    while (got < total) {
        size_t want = total - got;
        if (want > COMPI_CHUNK) want = COMPI_CHUNK;
        size_t n = Serial.readBytes(g_provisionBuf + got, want);
        got += n;
        if (n != want) break;               // hueco/timeout: se corta abajo
        Serial.print("COMPI CHUNK ");
        Serial.println((unsigned long)got);
    }
    Serial.setTimeout(1000);
    if (got != total) {
        Serial.print("COMPI ERR datos ");
        Serial.println((unsigned long)got);
        noteActivity();
        forceRedraw();
        return;
    }

    uint32_t sum = 0;
    for (size_t i = 0; i < PROGRAM_SIZE; ++i) sum += g_provisionBuf[i];

    char m[24];
    snprintf(m, sizeof(m), "WRITING slot %02d", slot);
    oled.message(m);
    bool ok = flash.saveProgram(slot, g_provisionBuf);

    // Ya NO se toca cpu/ui/running: grabar un slot por USB no debe alterar
    // nada de lo que estuviera corriendo o mostrandose (ver g_provisionBuf
    // mas arriba). Si el slot grabado es justo el que EditPrg tiene en
    // pantalla, refresca su previsualizacion la proxima vez que se pinte.
    if (ui.slot == (uint8_t)slot) prevSlot = 0xFF;

    if (ok) {
        Serial.print("COMPI OK ");
        Serial.println((unsigned long)sum);
    } else {
        Serial.println("COMPI ERR flash");
    }
    noteActivity();
    forceRedraw();
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

    // g_provisionBuf de scratch para leer la imagen -- NO cpu.ram(), para no
    // pisar ni parar lo que estuviera corriendo (ver su comentario). Se lee
    // siempre la imagen ENTERA (loadProgram no admite leer solo un trozo),
    // <len> solo decide cuanto de ella se manda.
    flash.loadProgram(slot, g_provisionBuf);

    uint32_t sum = 0;
    for (long i = 0; i < len; ++i) sum += g_provisionBuf[i];

    Serial.print("COMPI READY ");
    Serial.println((unsigned long)len);
    // Sin trocear ni esperar eco: eso hacia falta en LOAD porque la cola de
    // RECEPCION del USB-CDC del C3 es de solo 256 bytes y descarta en
    // silencio si se llena (ver arriba). Para ENVIAR no hay ese problema --
    // Serial.write() ya bloquea lo que haga falta hasta que cabe.
    Serial.write(g_provisionBuf, (size_t)len);
    Serial.print("COMPI OK ");
    Serial.println((unsigned long)sum);

    // Tampoco aqui se toca cpu/ui/running: pedir un slot por USB es una
    // lectura, no debe alterar nada de lo que estuviera corriendo.
    noteActivity();
    forceRedraw();
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
    // Lo PRIMERO de todo, antes de tocar la pantalla para nada (ni siquiera
    // oled.begin(), que ya puede dejar algo visible en la OLED): leer los
    // interruptores. panel.begin() no depende de Serial/Wire/OLED (el '165
    // es puro bit-bang por GPIO, ver ShiftRegister165::begin()), así que es
    // seguro adelantarlo aquí. Con el arranque automático del slot 0 (más
    // abajo) el aparato puede pasar a EJECUTAR nada más encender si los
    // interruptores ya están en EJECUTAR+CONTINUO, así que conviene conocer
    // su estado desde el instante cero, no después de haber inicializado la
    // pantalla.
    panel.begin();
    prevExec = panel.ejecutar();
    prevAbajo = panel.swAbajo();
    running = prevExec && prevAbajo;   // arrancado en EJECUTAR+CONTINUO

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
    // Botón BOOT (GPIO9) como MUTE/UNMUTE general -- ver PIN_BOOT_BTN.
    // Pull-up interno: a nivel alto en reposo, a nivel bajo al pulsarlo.
    pinMode(PIN_BOOT_BTN, INPUT_PULLUP);
    g_bootBtnRawPrev = digitalRead(PIN_BOOT_BTN);
    g_bootBtnStable = g_bootBtnRawPrev;
    g_bootBtnLastChangeMs = millis();
    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
    cpu.setPortRead(portRead);
    cpu.setPortWrite(portWrite);

    if (!oled.begin())  failBlink(200); // parpadeo lento = falla la OLED
    if (!flash.init())  failBlink(80);  // parpadeo rápido = falla la flash

    // Arranque automatico: si el slot 0 tiene algo grabado (pensado para un
    // "sistema operativo" que arranque otros programas, ver PORT_PROG_LOAD
    // en iomap.h), se carga solo nada mas encender, sin esperar a que el
    // usuario entre en EDITAR y pulse Cargar. Si esta vacio, arranca limpio
    // (RAM a 0x00 = NOP) como hasta ahora.
    if (!flash.loadProgram(0, cpu.ram())) {
        cpu.clearMemory();
    }
    g_currentSlot = 0;   // ver g_currentSlot arriba (EEPROM por slot)
    cpu.reset();
    ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);   // arranca el editor en lo que haya

    // `running` ya se calculó lo primero de todo (interruptores en EJECUTAR +
    // CONTINUO): en ese caso el aparato arranca directamente el programa del
    // slot 0 y NO se pinta el desensamblado del editor ni un instante -- la
    // pantalla se queda en blanco hasta el primer volcado del framebuffer del
    // propio programa (loop() lo hace ya en su primera vuelta, lastFlush=0).
    if (running) {
        g_scr = SCR_FULL;
        oled.contrast(g_screenContrast);
        oled.renderFramebuffer(g_fb, g_text, g_attr, false);   // pantalla limpia
    } else {
        g_scr = START_SCREEN_DIMMED ? SCR_DIM : SCR_FULL;
        oled.contrast(START_SCREEN_DIMMED ? OLED_CONTRAST_DIM : g_screenContrast);
        oled.render(cpu, ui);
    }

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
    // Mute/unmute: SIEMPRE lo primero, antes de mirar el modo del panel o
    // qué programa corre -- tiene que responder pulse lo que pulse el
    // interruptor de modo, en cualquiera de las 4 vistas.
    tickBootButton();
    tickMuteJingle();

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
        clearRuntimeOutputs();
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
        // (deleteByteAt) -- ninguna de las dos mueve el cursor. Este gesto no
        // roba el giro de DATOS para nada más (ver más abajo).
        //
        // Escritura en RAM mientras se compone: NO se toca nada mientras el
        // verbo o el mode todavía se están eligiendo (longitud final
        // desconocida) -- así el listado de abajo sigue mostrando la
        // instrucción que ya hubiera aquí, tal cual, sin arriesgarse a
        // corromper el principio de la siguiente a media elección. En
        // cuanto el tamaño final se conoce (verbo confirmado, y mode
        // también si el verbo tiene varias formas), se abre hueco UNA vez
        // si hace falta (ensureRoomFor, arriba) y desde ahí sí se escribe en
        // vivo en cada giro, como siempre. `ui.origLen`/`ui.roomEnsured`
        // (ui.h) llevan la cuenta de todo esto; resyncCompose() los
        // reinicia cada vez que se vuelve a sincronizar con lo que haya
        // realmente en memoria (cursor nuevo, insertar, borrar, o cerrar
        // una instrucción y pasar a la siguiente).
        auto resyncCompose = [&]() {
            ui.compose = decodeAt(cpu.ram(), 65536u, ui.cursor);
            ui.origLen = instrLen(cpu.ram(), 65536u, ui.cursor);
            ui.roomEnsured = false;
        };
        // Abre hueco (la primera vez que haga falta) y escribe la
        // instrucción en vivo, incondicionalmente -- usarlo solo cuando el
        // tamaño final YA se sabe seguro.
        auto commitWrite = [&]() {
            if (!ui.roomEnsured) {
                ensureRoomFor(ui.cursor, ui.compose, ui.origLen);
                ui.roomEnsured = true;
            }
            assemble(cpu.ram(), 65536u, ui.cursor, ui.compose);
        };
        // Igual, pero solo si el tamaño final ya se conoce a partir del
        // campo activo (eligiendo verbo o mode, todavía no); para el giro
        // de DATOS y el paso intermedio de confirmar campo. Verbos sin mode
        // ni operandos (NOP/HALT/RET/MOVB/MOVW, lastStep==0) nunca pasan por
        // aquí con el campo ya fuera de Verb -- su longitud se resuelve
        // directamente en la rama de confirmación final (más abajo), que
        // usa commitWrite() sin este filtro.
        auto liveUpdate = [&]() {
            EField f = fieldAt(ui.compose.verb, ui.compose.mode, ui.compose.step);
            if (f == EField::Verb || f == EField::Mode) return;
            commitWrite();
        };

        if (changed) {
            // vista recién entrada (o venimos de otra): re-decodifica en lo
            // que ya haya en memoria en el cursor actual.
            resyncCompose();
            dirBtnHeld = false; // por si veníamos de otra vista a media pulsación
        }

        if (int16_t d = panel.takeDirDelta()) {
            stepCursorByInstr(ui.cursor, d);
            resyncCompose();
            changed = true;
        }

        if (int16_t v = panel.takeDatDelta()) {
            applyDelta(ui.compose, v);
            liveUpdate();
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
                    resyncCompose();
                    dirBtnLongFired = true;
                    changed = true;
                }
            } else {
                // Soltado sin llegar al umbral: pulsación corta -> inserta
                // un NOP suelto en el cursor sin moverlo (insertByteAt,
                // misma frontera de la pila que deleteByteAt).
                if (!dirBtnLongFired) {
                    insertByteAt(ui.cursor);
                    resyncCompose();
                    changed = true;
                }
                dirBtnHeld = false;
            }
        }

        if (panel.takeDatPress()) {
            uint8_t last = lastStep(ui.compose.verb, ui.compose.mode);
            if (ui.compose.step < last) {
                ++ui.compose.step;
                liveUpdate();   // aquí es donde el tamaño puede pasar a
                                 // conocerse (p. ej. al confirmar el mode)
            } else {
                // Último campo confirmado (para NOP/HALT/RET/MOVB/MOVW esto
                // pasa ya en step 0, el propio campo Verb -- ver el
                // comentario de liveUpdate arriba): el tamaño es definitivo
                // se mire como se mire, así que aquí se escribe siempre, sin
                // el filtro de fieldAt que sí hace falta en el giro/paso
                // intermedio.
                commitWrite();   // asegura hueco y escribe la forma final
                uint8_t len = instrLen(cpu.ram(), 65536u, ui.cursor);
                ui.cursor = clamp16((long)ui.cursor + len);
                resyncCompose();
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
        // larga resetea. DATOS sigue ejecutando (girar adelante = varios pasos
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
                    clearRuntimeOutputs();
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
    // un host de serie conectado (desarrollo / provisioning por USB-CDC), ni
    // mientras suena el jingle de reactivar el sonido: el botón BOOT no pasa
    // por noteActivity() (no es parte del panel/'165), así que si llevaba
    // rato inactivo idleMs ya puede superar LIGHT_SLEEP_MS en el mismo
    // fotograma en que se pulsa -- sin esta condición, el digitalWrite(LOW)
    // de aquí abajo cortaría la melodía nada más empezar a sonar.
    if (!g_execActive && idleMs >= LIGHT_SLEEP_MS && !Serial && !g_muteJingleActive) {
        digitalWrite(PIN_BUZZER, LOW);
        setLed(false);
        // Despierta con el timer (backstop) o con la propia alarma del sampler,
        // que corre justo al despertar y refresca el panel / g_lastActivity.
        esp_sleep_enable_timer_wakeup((uint64_t)SAMPLE_IDLE_MS * 1000);
        esp_light_sleep_start();
    }
#endif
}
