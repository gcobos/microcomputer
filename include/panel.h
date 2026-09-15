#pragma once
#include <Arduino.h>
#include <stdint.h>

namespace compi {

// --- Constantes de tiempo (ms) -----------------------------------------
constexpr unsigned long DEBOUNCE_MS = 20;   // antirrebote (encoders y switches)
// Transiciones de cuadratura por detente de los encoders. Un EC11 típico da
// 4; si tus encoders saltan de 4 en 4 pon 1, si van a mitad pon 2.
constexpr int16_t ENC_DIVISOR = 4;

// Lee UN 74HC165 (entrada paralela, salida serie) por sondeo bit a bit.
// Un pulso de carga (PL) captura las 8 entradas; luego se desplazan por Q7.
// Cableado: PL -> pin 1, CP -> pin 2, Q7 (pin 9) -> dataPin, SER (pin 10) -> GND,
// CLK INH (pin 15) -> GND. El primer bit que sale tras la carga es D7.
class ShiftRegister165 {
public:
    ShiftRegister165(uint8_t loadPin, uint8_t clockPin, uint8_t dataPin);
    void begin();
    // Devuelve las 8 entradas: bit (7 - k) = entrada Dk. 1 = alto (sin pulsar).
    uint8_t read();
private:
    uint8_t loadPin_, clockPin_, dataPin_;
};

// Decodifica un encoder incremental (dos señales en cuadratura) por sondeo.
class RotaryEncoder {
public:
    RotaryEncoder();
    void begin(uint8_t a, uint8_t b);           // nivel inicial (1 = alto)
    void update(uint8_t a, uint8_t b);          // nivel actual de A y B
    int16_t takeDelta();                         // detentes desde la última lectura
private:
    uint8_t prevState_ = 0;
    int16_t raw_ = 0;
};

// Pulsador momentáneo con antirrebote. Solo pulsación corta (un disparo al
// pulsar) y nivel instantáneo. Sin pulsación larga.
class PushButton {
public:
    PushButton();
    void begin(bool pressed);
    void update(bool pressed);                   // pressed = nivel bajo (a GND)
    bool takePress();                             // true una vez, al pulsar
    bool down() const { return stable_; }         // nivel instantáneo
private:
    bool stable_ = false, cand_ = false, pending_ = false;
    unsigned long tCand_ = 0;
};

// Interruptor de 2 posiciones con antirrebote. Expone el nivel, no eventos.
class ToggleSwitch {
public:
    ToggleSwitch();
    void begin(bool closed);
    void update(bool closed);                     // closed = nivel bajo (a GND)
    bool on() const { return stable_; }           // on = cerrado (a GND)
private:
    bool stable_ = false, cand_ = false;
    unsigned long tCand_ = 0;
};

// Agrega las 8 entradas del panel: 2 encoders con pulsador + 2 interruptores,
// multiplexados por un 74HC165. Es solo lectura de hardware: NO guarda estado
// de UI (cursor, slot, vista); eso vive en el sketch principal.
//
// Mapa de bits del 74HC165 (entrada Dk -> bit 7-k):
//   D0 ADDR_A   D1 ADDR_B   D2 ADDR_SW (pulsador DIRECCIÓN)
//   D3 DATA_A   D4 DATA_B   D5 DATA_SW (pulsador DATOS)
//   D6 SW_MODO  (abierto = EDITAR,  cerrado = EJECUTAR)
//   D7 SW_PASO  (abierto = ▲,       cerrado = ▼)   -- significado según SW_MODO
class FrontPanel {
public:
    FrontPanel(uint8_t hc165LoadPin, uint8_t hc165ClockPin, uint8_t hc165DataPin);

    void begin();

    // Una lectura del 74HC165 + decodificación. Se llama desde un temporizador
    // (esp_timer) a ritmo variable — 2 ms mientras hay actividad, 100 ms en
    // reposo — así que NO depende de la cadencia de loop() ni de que la OLED
    // esté volcando. Devuelve true si hubo actividad del usuario en esta
    // lectura (giro, pulsación o cambio de interruptor); el sketch lo usa para
    // decidir cuándo acelerar el muestreo, atenuar la pantalla o dormir.
    //
    // La lectura del '165 (bit-bang) se hace fuera de la sección crítica; solo
    // el reparto de bits y los contadores compartidos van bajo el spinlock,
    // porque los consumidores (take*/getters) corren en loop().
    bool update();

    // --- interruptores (nivel) -------------------------------------
    bool ejecutar() const { return swModo_.on(); }   // false = EDITAR
    bool swAbajo()  const { return swPaso_.on(); }    // false = ▲, true = ▼

    // --- encoders: detentes (se consumen) -------------------------
    int16_t takeDirDelta();
    int16_t takeDatDelta();

    // --- encoders: pulsadores (evento y nivel) -------------------
    bool takeDirPress();
    bool takeDatPress();

    // --- estado para los puertos IN (EJECUCIÓN) ------------------
    uint8_t dirPos()  const { return dirPos_; }       // posición absoluta 0..255
    uint8_t datPos()  const { return datPos_; }
    bool dirDown()     const { return dirBtn_.down(); }
    bool datDown()     const { return datBtn_.down(); }
    void resetPositions();

private:
    ShiftRegister165 inputs_;
    RotaryEncoder dirEnc_, datEnc_;
    PushButton dirBtn_, datBtn_;
    ToggleSwitch swModo_, swPaso_;

    int16_t dirPend_ = 0, datPend_ = 0;   // detentes pendientes de consumir
    uint8_t dirPos_ = 0, datPos_ = 0;
    uint8_t prevByte_ = 0xFF;

    // Protege dirPend_/datPend_/dirPos_/datPos_ y el estado de los sub-objetos
    // frente al acceso concurrente entre el temporizador de muestreo y loop().
    portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
};

} // namespace compi
