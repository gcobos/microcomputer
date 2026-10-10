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
static uint8_t g_wantProg = 0xFF;   // instrumento pedido (0xFF = ninguno)
static uint8_t g_sentProg = 0xFF;   // el ultimo enviado en esta conexion
static uint8_t g_curNote = 0;   // nota con NoteOn enviado y sin NoteOff (0 = ninguna)
// Intervalo de conexion: las notas solo salen en cada "cita" BLE, asi que
// llegan con un retraso al azar de 0 a un intervalo. Linux da 45 ms por
// defecto; medido en el PC (COMPI MIDITEST, notas cada 125 ms): con 45 ms,
// desviacion tipica 31 ms y hasta 132 ms (trompicones); con 15 ms, 9 ms; con
// 7,5 ms, 4,5 ms (max 14). Un poco despues de conectar (antes, algunos
// ordenadores rechazan la peticion mientras descubren los servicios) se
// pide 7,5 ms justos; si a los 1,5 s no se ha conseguido (hay quien no
// baja de 15 ms y rechaza la peticion entera), 7,5-15 ms. El que quede de
// verdad lo decide el ordenador: g_connItvl.
constexpr uint16_t BTMIDI_ITVL_MIN = 6;     // x 1,25 ms = 7,5 ms
constexpr uint16_t BTMIDI_ITVL_MAX = 12;    // 15 ms (segundo intento)
constexpr unsigned long BTMIDI_RETRY_MS = 1500;
constexpr uint16_t BTMIDI_TIMEOUT  = 200;   // x 10 ms = 2 s de supervision
constexpr unsigned long BTMIDI_PARAMS_DELAY_MS = 1000;
static volatile bool g_newConn = false;     // acaba de conectar (callback)
static unsigned long g_connMs = 0;
static bool g_paramsPending = false;
static uint8_t g_paramsTry = 0;             // 1 = pedido 7,5 ms; 2 = ya el segundo
static unsigned long g_paramsMs = 0;
static uint16_t g_connItvl = 0;             // x 1,25 ms; 0 = sin conexion
static unsigned long g_itvlNextMs = 0;
static uint8_t g_curVel = 0;    // su velocidad
static char g_name[16] = "";

void btmidiBegin() {
    if (g_state) return;
    g_state = 1;
    g_scanDone = false;
    // Primero, una búsqueda corta de otros compi anunciándose, para elegir
    // número. Sin bloquear: la emulación sigue y btmidiTick() termina el
    // arranque cuando acaba (el callback llega desde la tarea de NimBLE).
    NimBLEDevice::init("");
    NimBLEScan* scan = NimBLEDevice::getScan();
    scan->setActiveScan(true);   // el nombre suele ir en la respuesta al escaneo
    scan->start(BTMIDI_SCAN_S, [](NimBLEScanResults) { g_scanDone = true; }, false);
}

void btmidiEnd() {
    if (!g_state) return;
    if (g_state == 1) NimBLEDevice::getScan()->stop();
    NimBLEDevice::deinit(true);       // corta la conexion, para la radio y libera todo
    g_state = 0;
    g_scanDone = false;
    g_connected = false;
    g_connItvl = 0;
    g_paramsPending = false;
    g_paramsTry = 0;
    g_newConn = false;
    g_lost = false;                   // (este corte es a proposito, no un fallo)
    g_curNote = 0;
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
        BLEMIDI.setHandleConnected([]() { g_connected = true; g_sentProg = 0xFF; g_newConn = true; });
        BLEMIDI.setHandleDisconnected([]() { g_connected = false; g_lost = true; });
        MIDI.begin(MIDI_CHANNEL_OMNI);
        g_state = 2;
        return;
    }
    if (g_state != 2) return;
    if (!g_connected) { g_curNote = 0; g_connItvl = 0; g_paramsPending = false; }
    if (g_newConn) {
        g_newConn = false;
        g_paramsPending = true;
        g_connMs = millis();
    }
    NimBLEServer* srv = NimBLEDevice::getServer();
    if (g_connected && srv) {
        if (g_paramsPending && millis() - g_connMs >= BTMIDI_PARAMS_DELAY_MS) {
            g_paramsPending = false;
            g_paramsTry = 1;
            g_paramsMs = millis();
            for (uint16_t id : srv->getPeerDevices())
                srv->updateConnParams(id, BTMIDI_ITVL_MIN, BTMIDI_ITVL_MIN, 0, BTMIDI_TIMEOUT);
        }
        if (g_paramsTry == 1 && millis() - g_paramsMs >= BTMIDI_RETRY_MS) {
            g_paramsTry = 2;
            std::vector<uint16_t> peers = srv->getPeerDevices();
            if (!peers.empty() && srv->getPeerIDInfo(peers[0]).getConnInterval() > BTMIDI_ITVL_MIN)
                for (uint16_t id : peers)
                    srv->updateConnParams(id, BTMIDI_ITVL_MIN, BTMIDI_ITVL_MAX, 0, BTMIDI_TIMEOUT);
        }
        if ((long)(millis() - g_itvlNextMs) >= 0) {   // el negociado, para diag
            g_itvlNextMs = millis() + 1000;
            std::vector<uint16_t> peers = srv->getPeerDevices();
            g_connItvl = peers.empty() ? 0 : srv->getPeerIDInfo(peers[0]).getConnInterval();
        }
    }
    MIDI.read();
}

uint16_t btmidiConnIntervalUs() { return (uint16_t)(g_connItvl * 1250u); }

void btmidiRequestInterval(uint16_t minItvl, uint16_t maxItvl) {
    NimBLEServer* srv = NimBLEDevice::getServer();
    if (g_state != 2 || !g_connected || !srv) return;
    g_paramsPending = false;
    g_paramsTry = 2;
    for (uint16_t id : srv->getPeerDevices())
        srv->updateConnParams(id, minItvl, maxItvl, 0, BTMIDI_TIMEOUT);
    g_itvlNextMs = millis() + 1500;     // que diag lea el nuevo, no el de antes
}

const char* btmidiName() { return g_name; }

bool btmidiConnected() { return g_connected; }

void btmidiProgram(uint8_t prog) { g_wantProg = prog; }

uint8_t btmidiState() { return g_state; }

bool btmidiTakeLost() {
    if (!g_lost) return false;
    g_lost = false;
    return true;
}

void btmidiNote(uint8_t note, uint8_t vel) {
    if (note == g_curNote && (note == 0 || vel == g_curVel)) return;
    if (!g_connected) { g_curNote = 0; return; }
    if (g_curNote) MIDI.sendNoteOff(g_curNote, 0, BTMIDI_CHANNEL);
    if (note && g_wantProg != 0xFF && g_wantProg != g_sentProg) {
        MIDI.sendProgramChange(g_wantProg, BTMIDI_CHANNEL);
        g_sentProg = g_wantProg;
    }
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
