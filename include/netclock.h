#pragma once
#include <stddef.h>
#include <stdint.h>

// Hora real para los programas (puertos 0x0670..0x067E, iomap.h).
//
// La pone el Wi-Fi por NTP: al arrancar se conecta a la red configurada
// (compi.py wifi) y, si no hay o no va, a cualquier red ABIERTA que vea (de
// la de mas señal a la de menos, NET_OPEN_TIMEOUT_MS cada una); pide la
// hora y APAGA la radio en cuanto la tiene. Repite cada NET_RESYNC_MS, o a
// los NET_RETRY_MS si no lo consiguio. Entre medias la hora la lleva el
// reloj interno del ESP32.
// También se puede poner desde el PC por el USB (compi.py time), sin Wi-Fi.
// Sin ninguna de las dos, la hora "no es valida" (bit 0 de PORT_TIME_CTRL)
// hasta que llegue una: no hay pila que la conserve con el aparato apagado.
//
// La zona horaria (POSIX, p. ej. "CET-1CEST,M3.5.0,M10.5.0/3" para la
// peninsula) da la hora local, con su cambio de verano.
namespace compi {

constexpr uint32_t NET_SYNC_TIMEOUT_MS = 30000;   // la red configurada
constexpr uint32_t NET_OPEN_TIMEOUT_MS = 15000;   // cada red abierta
constexpr uint32_t NET_SCAN_TIMEOUT_MS = 10000;
constexpr uint32_t NET_RESYNC_MS = 12UL * 3600UL * 1000UL;
constexpr uint32_t NET_RETRY_MS = 30UL * 60UL * 1000UL;
constexpr const char* NET_DEFAULT_TZ = "CET-1CEST,M3.5.0,M10.5.0/3";

// bits de clockStatus() (= IN PORT_TIME_CTRL)
constexpr uint8_t CLK_VALID   = 0x01;   // hay hora
constexpr uint8_t CLK_NTP     = 0x02;   // la ultima vino del Wi-Fi (si no, del USB)
constexpr uint8_t CLK_SYNCING = 0x04;   // buscando red o conectando ahora mismo
constexpr uint8_t CLK_WIFI    = 0x08;   // hay una red Wi-Fi configurada

// cfg = los NET_CONFIG_SIZE bytes guardados (storage.h); si no son validos,
// sin Wi-Fi y con la zona por defecto. Arranca la primera sincronizacion.
void clockBegin(const uint8_t* cfg);
void clockTick();                       // una vez por vuelta de loop()
void clockSyncNow();                    // pide una sincronizacion ya
bool clockBusy();                       // el Wi-Fi esta encendido
uint8_t clockStatus();
void clockSetEpoch(uint32_t epoch);     // desde el USB (UTC)
uint32_t clockEpoch();                  // 0 si no hay hora

// Rellena los 14 registros de PORT_TIME_EPOCH0..PORT_TIME_LMIN2 (iomap.h)
// con la hora de ahora: epoch UTC (4, little-endian), segundo, minuto,
// hora, dia, mes, año-2000, dia de la semana (0 = domingo), y minutos
// locales desde el 1-1-2020 (3, little-endian). Todo a 0 si no hay hora.
void clockLatch(uint8_t* regs);

// Configuracion (para guardarla; cfg = NET_CONFIG_SIZE bytes)
void netBuildConfig(uint8_t* cfg, const char* ssid, const char* pass, const char* tz);
const char* netSsid();
const char* netLastSsid();              // la red que dio la hora ("" si ninguna)
const char* netTz();
void netApply(const uint8_t* cfg);      // usa una configuracion nueva

}  // namespace compi
