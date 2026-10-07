#include "btmidi.h"

#include <Arduino.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <NimBLEDevice.h>
#include <BLEMIDI_Transport.h>
#include <hardware/BLEMIDI_ESP32_NimBLE.h>

// Crea BLEMIDI (el transporte) y MIDI (la interfaz de la MIDI Library). El
// nombre definitivo (compi-midiN) se pone con setName() antes de MIDI.begin().
BLEMIDI_CREATE_INSTANCE(compi::BTMIDI_PREFIX, MIDI);

namespace compi {

// 0 = parado, 1 = buscando otros compi-midiN, 2 = anunciándose (MIDI listo)
static uint8_t g_state = 0;
static volatile bool g_scanDone = false;
static volatile bool g_connected = false;
static volatile bool g_lost = false;   // se cortó una conexión (ver btmidiTakeLost)
static uint8_t g_curNote = 0;   // nota con NoteOn enviado y sin NoteOff (0 = ninguna)
static uint8_t g_curVel = 0;    // su velocidad
static char g_name[16] = "";

void btmidiBegin() {
    if (g_state) return;
    g_state = 1;
    // Primero, una búsqueda corta de otros compi anunciándose, para elegir
    // número. Sin bloquear: la emulación sigue y btmidiTick() termina el
    // arranque cuando acaba (el callback llega desde la tarea de NimBLE).
    NimBLEDevice::init("");
    NimBLEScan* scan = NimBLEDevice::getScan();
    scan->setActiveScan(true);   // el nombre suele ir en la respuesta al escaneo
    scan->start(BTMIDI_SCAN_S, [](NimBLEScanResults) { g_scanDone = true; }, false);
}

// El número más bajo que no use ningún compi-midiN de los encontrados
static int freeNumber() {
    const size_t plen = strlen(BTMIDI_PREFIX);
    uint32_t used = 0;
    NimBLEScanResults res = NimBLEDevice::getScan()->getResults();
    for (int i = 0; i < res.getCount(); i++) {
        NimBLEAdvertisedDevice dev = res.getDevice(i);
        if (!dev.haveName()) continue;
        std::string n = dev.getName();
        if (n.size() <= plen || n.compare(0, plen, BTMIDI_PREFIX) != 0) continue;
        int k = atoi(n.c_str() + plen);
        if (k >= 0 && k < 32) used |= 1u << k;
    }
    NimBLEDevice::getScan()->clearResults();
    int k = 0;
    while (k < 31 && (used & (1u << k))) k++;
    return k;
}

void btmidiTick() {
    if (g_state == 1) {
        if (!g_scanDone) return;
        snprintf(g_name, sizeof(g_name), "%s%d", BTMIDI_PREFIX, freeNumber());
        NimBLEDevice::setDeviceName(g_name);   // init() ya hecho: no lo repite
        BLEMIDI.setName(g_name);
        // Los callbacks llegan desde la tarea de NimBLE, no desde loop():
        // solo tocan el flag. Al desconectar, la nota pendiente se da por
        // cerrada (el otro lado ya no la está oyendo).
        BLEMIDI.setHandleConnected([]() { g_connected = true; });
        BLEMIDI.setHandleDisconnected([]() { g_connected = false; g_lost = true; });
        MIDI.begin(MIDI_CHANNEL_OMNI);
        g_state = 2;
        return;
    }
    if (g_state != 2) return;
    if (!g_connected) g_curNote = 0;
    MIDI.read();
}

const char* btmidiName() { return g_name; }

bool btmidiConnected() { return g_connected; }

bool btmidiTakeLost() {
    if (!g_lost) return false;
    g_lost = false;
    return true;
}

void btmidiNote(uint8_t note, uint8_t vel) {
    if (note == g_curNote && (note == 0 || vel == g_curVel)) return;
    if (!g_connected) { g_curNote = 0; return; }
    if (g_curNote) MIDI.sendNoteOff(g_curNote, 0, BTMIDI_CHANNEL);
    if (note) MIDI.sendNoteOn(note, vel, BTMIDI_CHANNEL);
    g_curNote = note;
    g_curVel = vel;
}

uint8_t hzToMidi(uint16_t hz) {
    if (hz == 0) return 0;
    long n = lroundf(69.0f + 12.0f * log2f(hz / 440.0f));   // 69 = LA4
    return n < 1 ? 1 : (n > 127 ? 127 : (uint8_t)n);
}

}  // namespace compi
