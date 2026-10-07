#pragma once
#include <stdint.h>

// Salida del sonido por Bluetooth (BLE MIDI), alternativa al zumbador: el
// botón BOOT y SETTINGS de sisop eligen a dónde va (ver g_soundBt en
// main.cpp). El aparato se anuncia como "compi-midiN": al arrancar el
// Bluetooth busca BTMIDI_SCAN_S segundos otros compi-midiN anunciándose y se
// queda con el número libre más bajo (0, 1, 2...). Uno que ya esté
// conectado a algo deja de anunciarse y no se ve: puede repetirse su
// número. Cualquier sintetizador o app BLE MIDI (móvil, ordenador) se
// conecta y recibe las notas por el canal BTMIDI_CHANNEL. Sin nada
// conectado, las notas no van a ningún sitio.
namespace compi {

constexpr const char* BTMIDI_PREFIX = "compi-midi";
constexpr uint32_t BTMIDI_SCAN_S  = 2;
constexpr uint8_t BTMIDI_CHANNEL  = 1;

// Arranca la pila BLE: busca otros compi, elige número y se anuncia. Solo
// la primera vez que se elige la salida Bluetooth (o al encender si estaba elegida): mientras no se use,
// no gasta RAM ni energía en la radio. Llamarla otra vez no hace nada.
void btmidiBegin();

// Una vez por vuelta de loop(): procesa lo que llegue (mantiene viva la
// conexión). No hace nada si no se ha arrancado.
void btmidiTick();

bool btmidiConnected();

// true UNA vez tras cortarse una conexión (el otro lado se ha ido): main.cpp
// vuelve entonces al zumbador, como si se pulsara BOOT.
bool btmidiTakeLost();

// El nombre con el que se anuncia ("compi-midi0"...), o "" mientras busca.
const char* btmidiName();

// Nota MIDI que debe sonar ahora (1..127), o 0 = silencio, con velocidad
// vel (1..127, PORT_SND_VEL). Manda el NoteOff de la anterior y el NoteOn
// de la nueva; repetir la misma nota con la misma velocidad no manda nada
// (como tone() con la misma frecuencia), con otra velocidad la vuelve a
// tocar.
void btmidiNote(uint8_t note, uint8_t vel = 100);

// Frecuencia en Hz -> la nota MIDI más cercana (1..127); 0 Hz -> 0.
uint8_t hzToMidi(uint16_t hz);

}  // namespace compi
