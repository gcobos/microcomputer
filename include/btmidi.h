#pragma once
#include <stdint.h>

// Salida del sonido por Bluetooth (BLE MIDI), alternativa al zumbador: el
// botón BOOT y SETTINGS de sisop eligen a dónde va (ver g_soundMode en
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

// Apaga del todo la pila BLE y la radio (al volver al zumbador): el
// controlador Bluetooth del C3, tal como viene compilado el core de Arduino,
// no duerme la radio, y encendido gasta ~80 mA de mas. btmidiBegin() la
// vuelve a arrancar.
void btmidiEnd();

// Una vez por vuelta de loop(): procesa lo que llegue (mantiene viva la
// conexión). No hace nada si no se ha arrancado.
void btmidiTick();

bool btmidiConnected();

// Intervalo de conexión BLE negociado, en µs (0 = sin conexión). El compi
// pide 7,5 ms al conectar (o 7,5-15 si no); el ordenador decide (btmidi.cpp).
uint16_t btmidiConnIntervalUs();

// PRUEBA (COMPI BTITVL): pide otro intervalo, en unidades de 1,25 ms.
void btmidiRequestInterval(uint16_t minItvl, uint16_t maxItvl);

// Instrumento (Program Change General MIDI, 0..127) de las notas
// siguientes: se envía justo antes de la próxima nota si es distinto del
// último enviado (y otra vez tras cada conexión nueva). 0xFF = no enviar
// nada (el sintetizador sigue con el suyo).
void btmidiProgram(uint8_t prog);

// 0 = parado, 1 = buscando otros compi, 2 = anunciandose / listo (diagnostico)
uint8_t btmidiState();

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
