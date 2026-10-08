#include "netclock.h"

#include <Arduino.h>
#include <WiFi.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include "esp_sntp.h"
#include "storage.h"

namespace compi {

static char g_ssid[33] = "";
static char g_pass[65] = "";
static char g_tz[64] = "";

// Off -> (Connecting a la red configurada) -> Scanning -> Connecting a cada
// red abierta, de la mas fuerte a la mas debil -> Off. Para en cuanto el
// SNTP da la hora.
enum class NetState : uint8_t { Off, Scanning, Connecting };
static NetState g_state = NetState::Off;
static uint32_t g_stateSince = 0;     // millis() al empezar la fase
static uint32_t g_lastSyncTry = 0;    // millis() del ultimo intento
static uint32_t g_retryMs = NET_RESYNC_MS;
static bool g_triedOnce = false;
static bool g_fromNtp = false;
static bool g_onConfigured = false;   // probando la red configurada
static volatile bool g_ntpGot = false;
static char g_curSsid[33] = "";       // la red que se esta probando
static char g_lastSsid[33] = "";      // la que dio la hora la ultima vez

constexpr uint8_t  NET_MAX_OPEN = 6;
static char g_open[NET_MAX_OPEN][33]; // redes abiertas encontradas, por señal
static uint8_t g_openN = 0, g_openI = 0;

static bool timeValid() { return time(nullptr) > 1600000000; }   // > sept. 2020

static void applyTz() {
    setenv("TZ", g_tz[0] ? g_tz : NET_DEFAULT_TZ, 1);
    tzset();
}

void netApply(const uint8_t* cfg) {
    g_ssid[0] = g_pass[0] = g_tz[0] = '\0';
    if (cfg && cfg[0] == NET_CONFIG_MAGIC) {
        memcpy(g_ssid, cfg + 1, 32);  g_ssid[32] = '\0';
        memcpy(g_pass, cfg + 34, 64); g_pass[64] = '\0';
        memcpy(g_tz, cfg + 99, 63);   g_tz[63] = '\0';
    }
    applyTz();
}

void netBuildConfig(uint8_t* cfg, const char* ssid, const char* pass, const char* tz) {
    memset(cfg, 0, NET_CONFIG_SIZE);
    cfg[0] = NET_CONFIG_MAGIC;
    strncpy((char*)cfg + 1, ssid ? ssid : "", 32);
    strncpy((char*)cfg + 34, pass ? pass : "", 64);
    strncpy((char*)cfg + 99, tz ? tz : "", 63);
}

const char* netSsid() { return g_ssid; }
const char* netLastSsid() { return g_lastSsid; }
const char* netTz() { return g_tz[0] ? g_tz : NET_DEFAULT_TZ; }

static void radioOff(bool ok) {
    sntp_stop();
    WiFi.scanDelete();
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    g_state = NetState::Off;
    // sin exito, se reintenta antes (puede que luego haya red)
    g_retryMs = ok ? NET_RESYNC_MS : NET_RETRY_MS;
}

static void startConnect(const char* ssid, const char* pass) {
    sntp_stop();
    WiFi.disconnect();
    strncpy(g_curSsid, ssid, 32); g_curSsid[32] = '\0';
    g_ntpGot = false;
    WiFi.begin(ssid, (pass && pass[0]) ? pass : nullptr);
    // configTzTime arranca el SNTP (y vuelve a poner la zona); el aviso de
    // "hora recibida" llega por el callback, desde la tarea de lwIP
    sntp_set_time_sync_notification_cb([](struct timeval*) { g_ntpGot = true; });
    configTzTime(netTz(), "pool.ntp.org", "time.google.com");
    g_state = NetState::Connecting;
    g_stateSince = millis();
}

static void startScan() {
    WiFi.disconnect();
    WiFi.scanNetworks(true);              // asincrono: clockTick() mira si acabo
    g_state = NetState::Scanning;
    g_stateSince = millis();
}

void clockSyncNow() {
    if (g_state != NetState::Off) return;
    g_lastSyncTry = millis();
    g_triedOnce = true;
    WiFi.mode(WIFI_STA);
    if (g_ssid[0]) {
        g_onConfigured = true;
        startConnect(g_ssid, g_pass);
    } else {
        g_onConfigured = false;
        startScan();
    }
}

void clockBegin(const uint8_t* cfg) {
    netApply(cfg);
    clockSyncNow();
}

// las redes abiertas del escaneo, de mas a menos señal
static void collectOpen(int n) {
    g_openN = 0;
    int32_t rssi[NET_MAX_OPEN];
    for (int i = 0; i < n; ++i) {
        if (WiFi.encryptionType(i) != WIFI_AUTH_OPEN) continue;
        String ss = WiFi.SSID(i);
        if (ss.length() == 0 || ss.length() > 32) continue;
        int32_t r = WiFi.RSSI(i);
        // insercion ordenada (pocas redes)
        int k = g_openN < NET_MAX_OPEN ? g_openN++ : NET_MAX_OPEN;
        if (k == NET_MAX_OPEN) {
            if (r <= rssi[NET_MAX_OPEN - 1]) continue;
            k = NET_MAX_OPEN - 1;
        }
        while (k > 0 && rssi[k - 1] < r) {
            rssi[k] = rssi[k - 1];
            memcpy(g_open[k], g_open[k - 1], 33);
            --k;
        }
        rssi[k] = r;
        strncpy(g_open[k], ss.c_str(), 32); g_open[k][32] = '\0';
    }
    WiFi.scanDelete();
}

void clockTick() {
    const uint32_t t = millis() - g_stateSince;
    switch (g_state) {
    case NetState::Scanning: {
        int n = WiFi.scanComplete();
        if (n == WIFI_SCAN_RUNNING) {
            if (t >= NET_SCAN_TIMEOUT_MS) radioOff(false);
            return;
        }
        if (n < 0) { radioOff(false); return; }   // fallo del escaneo
        collectOpen(n);
        if (!g_openN) { radioOff(false); return; }
        g_openI = 0;
        startConnect(g_open[0], nullptr);
        return;
    }
    case NetState::Connecting:
        if (g_ntpGot) {
            g_fromNtp = true;
            strncpy(g_lastSsid, g_curSsid, 33);
            radioOff(true);
            return;
        }
        if (t < (g_onConfigured ? NET_SYNC_TIMEOUT_MS : NET_OPEN_TIMEOUT_MS)) return;
        if (g_onConfigured) {                 // la suya no va: a las abiertas
            g_onConfigured = false;
            startScan();
        } else if (++g_openI < g_openN) {
            startConnect(g_open[g_openI], nullptr);
        } else {
            radioOff(false);
        }
        return;
    case NetState::Off:
        if (g_triedOnce && millis() - g_lastSyncTry >= g_retryMs) clockSyncNow();
        return;
    }
}

bool clockBusy() { return g_state != NetState::Off; }

uint8_t clockStatus() {
    uint8_t s = 0;
    if (timeValid()) s |= CLK_VALID;
    if (g_fromNtp) s |= CLK_NTP;
    if (g_state != NetState::Off) s |= CLK_SYNCING;     // buscando o conectando
    if (g_ssid[0]) s |= CLK_WIFI;
    return s;
}

void clockSetEpoch(uint32_t epoch) {
    struct timeval tv = {(time_t)epoch, 0};
    settimeofday(&tv, nullptr);
    g_fromNtp = false;
}

uint32_t clockEpoch() { return timeValid() ? (uint32_t)time(nullptr) : 0; }

// dias desde el 1-1-1970 de una fecha civil (algoritmo de H. Hinnant)
static int32_t daysFromCivil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int32_t)doe - 719468;
}

void clockLatch(uint8_t* r) {
    memset(r, 0, 14);
    if (!timeValid()) return;
    time_t now = time(nullptr);
    struct tm lt;
    localtime_r(&now, &lt);
    uint32_t e = (uint32_t)now;
    r[0] = e & 0xFF; r[1] = (e >> 8) & 0xFF; r[2] = (e >> 16) & 0xFF; r[3] = e >> 24;
    r[4] = (uint8_t)lt.tm_sec;
    r[5] = (uint8_t)lt.tm_min;
    r[6] = (uint8_t)lt.tm_hour;
    r[7] = (uint8_t)lt.tm_mday;
    r[8] = (uint8_t)(lt.tm_mon + 1);
    r[9] = (uint8_t)(lt.tm_year + 1900 - 2000);
    r[10] = (uint8_t)lt.tm_wday;
    int32_t days = daysFromCivil(lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday)
                 - daysFromCivil(2020, 1, 1);
    uint32_t lmin = (uint32_t)days * 1440u + (uint32_t)lt.tm_hour * 60u + (uint32_t)lt.tm_min;
    r[11] = lmin & 0xFF; r[12] = (lmin >> 8) & 0xFF; r[13] = (lmin >> 16) & 0xFF;
}

}  // namespace compi
