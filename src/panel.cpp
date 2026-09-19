#include "panel.h"

namespace compi {

namespace {
// Tabla de transición de cuadratura: índice = (estado_prev << 2) | estado_actual.
// Signo elegido para que GIRO HORARIO == avance (+1) con el cableado real de
// este panel (A/B como en docs/hardware.md) -- invertida respecto a la
// primera versión: con el cableado real, el signo original hacía que el
// giro horario RESTARA en vez de sumar en los dos mandos por igual (se
// comprobó a mano en el aparato). Si algún día se vuelve a cambiar el
// cableado de A/B de los encoders, esta es la tabla a invertir de nuevo.
const int8_t kQuadratureTable[16] = {
     0, -1,  1,  0,
     1,  0,  0, -1,
    -1,  0,  0,  1,
     0,  1, -1,  0
};

// Mapa de las 8 entradas dentro del byte de ShiftRegister165::read()
// (entrada Dk -> bit 7-k). Ver el cableado en docs/hardware.md.
constexpr uint8_t BIT_ADDR_A  = 7; // D0
constexpr uint8_t BIT_ADDR_B  = 6; // D1
constexpr uint8_t BIT_ADDR_SW = 5; // D2  (pulsador DIRECCIÓN)
constexpr uint8_t BIT_DATA_A  = 4; // D3
constexpr uint8_t BIT_DATA_B  = 3; // D4
constexpr uint8_t BIT_DATA_SW = 2; // D5  (pulsador DATOS)
constexpr uint8_t BIT_SW_MODO = 1; // D6
constexpr uint8_t BIT_SW_PASO = 0; // D7

inline uint8_t bitOf(uint8_t w, uint8_t n) { return (uint8_t)((w >> n) & 1u); }
inline bool low(uint8_t w, uint8_t n) { return bitOf(w, n) == 0; }
} // namespace

// --- ShiftRegister165 --------------------------------------------------

ShiftRegister165::ShiftRegister165(uint8_t loadPin, uint8_t clockPin, uint8_t dataPin)
    : loadPin_(loadPin), clockPin_(clockPin), dataPin_(dataPin) {}

void ShiftRegister165::begin() {
    pinMode(loadPin_, OUTPUT);
    pinMode(clockPin_, OUTPUT);
    pinMode(dataPin_, INPUT);
    digitalWrite(clockPin_, LOW);
    digitalWrite(loadPin_, HIGH);
}

uint8_t ShiftRegister165::read() {
    digitalWrite(loadPin_, LOW);
    delayMicroseconds(1);
    digitalWrite(loadPin_, HIGH);
    delayMicroseconds(1);

    uint8_t value = 0;
    for (uint8_t i = 0; i < 8; ++i) {
        value >>= 1;
        if (digitalRead(dataPin_)) value |= 0x80;
        digitalWrite(clockPin_, HIGH);
        delayMicroseconds(1);
        digitalWrite(clockPin_, LOW);
    }
    return value;
}

// --- RotaryEncoder --------------------------------------------------

RotaryEncoder::RotaryEncoder() {}

void RotaryEncoder::begin(uint8_t a, uint8_t b) {
    prevState_ = (uint8_t)(((a & 1) << 1) | (b & 1));
    raw_ = 0;
}

void RotaryEncoder::update(uint8_t a, uint8_t b) {
    uint8_t state = (uint8_t)(((a & 1) << 1) | (b & 1));
    uint8_t index = (uint8_t)((prevState_ << 2) | state);
    raw_ = (int16_t)(raw_ + kQuadratureTable[index & 0x0F]);
    prevState_ = state;
}

int16_t RotaryEncoder::takeDelta() {
    int16_t steps = (int16_t)(raw_ / ENC_DIVISOR);
    raw_ = (int16_t)(raw_ - steps * ENC_DIVISOR);
    return steps;
}

// --- PushButton ---------------------------------------------------

PushButton::PushButton() {}

void PushButton::begin(bool pressed) {
    stable_ = cand_ = pressed;
    pending_ = false;
}

void PushButton::update(bool pressed) {
    unsigned long now = millis();
    if (pressed != cand_) { cand_ = pressed; tCand_ = now; }
    if (cand_ != stable_ && (now - tCand_) >= DEBOUNCE_MS) {
        stable_ = cand_;
        if (stable_) pending_ = true;   // flanco de bajada = pulsación
    }
}

bool PushButton::takePress() { bool p = pending_; pending_ = false; return p; }

// --- ToggleSwitch -----------------------------------------------

ToggleSwitch::ToggleSwitch() {}

void ToggleSwitch::begin(bool closed) { stable_ = cand_ = closed; }

void ToggleSwitch::update(bool closed) {
    unsigned long now = millis();
    if (closed != cand_) { cand_ = closed; tCand_ = now; }
    if (cand_ != stable_ && (now - tCand_) >= DEBOUNCE_MS) stable_ = cand_;
}

// --- FrontPanel ------------------------------------------------

FrontPanel::FrontPanel(uint8_t hc165LoadPin, uint8_t hc165ClockPin, uint8_t hc165DataPin)
    : inputs_(hc165LoadPin, hc165ClockPin, hc165DataPin) {}

void FrontPanel::begin() {
    inputs_.begin();
    uint8_t b = inputs_.read();
    prevByte_ = b;
    // A/B invertidos a propósito en los DOS encoders: con el orden "natural"
    // (A,B tal cual llegan del '165) los dos contaban al revés del sentido
    // horario en este panel -- comprobado a mano en el aparato, primero en
    // DATOS y luego en DIRECCIÓN. Cruzar A/B aquí compensa eso en software
    // sin tocar kQuadratureTable.
    dirEnc_.begin(bitOf(b, BIT_ADDR_B), bitOf(b, BIT_ADDR_A));
    datEnc_.begin(bitOf(b, BIT_DATA_B), bitOf(b, BIT_DATA_A));
    dirBtn_.begin(low(b, BIT_ADDR_SW));
    datBtn_.begin(low(b, BIT_DATA_SW));
    swModo_.begin(low(b, BIT_SW_MODO));
    swPaso_.begin(low(b, BIT_SW_PASO));
}

bool FrontPanel::update() {
    const uint8_t b = inputs_.read();   // bit-bang del '165, fuera del lock

    const bool exec0  = swModo_.on();
    const bool abajo0 = swPaso_.on();
    const bool dirDn0 = dirBtn_.down();
    const bool datDn0 = datBtn_.down();

    portENTER_CRITICAL(&mux_);
    prevByte_ = b;
    dirEnc_.update(bitOf(b, BIT_ADDR_B), bitOf(b, BIT_ADDR_A));  // A/B cruzados, ver begin()
    datEnc_.update(bitOf(b, BIT_DATA_B), bitOf(b, BIT_DATA_A));  // A/B cruzados, ver begin()
    dirBtn_.update(low(b, BIT_ADDR_SW));
    datBtn_.update(low(b, BIT_DATA_SW));
    swModo_.update(low(b, BIT_SW_MODO));
    swPaso_.update(low(b, BIT_SW_PASO));

    const int16_t dd = dirEnc_.takeDelta();
    const int16_t td = datEnc_.takeDelta();
    dirPend_ = (int16_t)(dirPend_ + dd);
    datPend_ = (int16_t)(datPend_ + td);
    dirPos_  = (uint8_t)(dirPos_ + dd);   // contadores absolutos (puertos IN)
    datPos_  = (uint8_t)(datPos_ + td);
    portEXIT_CRITICAL(&mux_);

    // Actividad del usuario: giro, cambio de nivel de un pulsador (tras
    // antirrebote) o de un interruptor. Sirve para el gestor de energía.
    return dd != 0 || td != 0
        || swModo_.on() != exec0 || swPaso_.on() != abajo0
        || dirBtn_.down() != dirDn0 || datBtn_.down() != datDn0;
}

int16_t FrontPanel::takeDirDelta() {
    portENTER_CRITICAL(&mux_);
    int16_t d = dirPend_; dirPend_ = 0;
    portEXIT_CRITICAL(&mux_);
    return d;
}

int16_t FrontPanel::takeDatDelta() {
    portENTER_CRITICAL(&mux_);
    int16_t d = datPend_; datPend_ = 0;
    portEXIT_CRITICAL(&mux_);
    return d;
}

bool FrontPanel::takeDirPress() {
    portENTER_CRITICAL(&mux_);
    bool p = dirBtn_.takePress();
    portEXIT_CRITICAL(&mux_);
    return p;
}

bool FrontPanel::takeDatPress() {
    portENTER_CRITICAL(&mux_);
    bool p = datBtn_.takePress();
    portEXIT_CRITICAL(&mux_);
    return p;
}

void FrontPanel::resetPositions() {
    portENTER_CRITICAL(&mux_);
    dirPos_ = datPos_ = 0;
    portEXIT_CRITICAL(&mux_);
}

} // namespace compi
