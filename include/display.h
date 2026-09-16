#pragma once
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include "cpu.h"
#include "ui.h"

namespace compi {

// Dibuja en una SH1106 de 128x64 por I2C (librería Adafruit_SH110X, NO
// SSD1306). La vista depende de UiState (sección 14 de specs.txt).
class OledPanel {
public:
    explicit OledPanel(uint8_t i2cAddress = 0x3C);

    bool begin(); // false si no responde la pantalla

    // Vista de depuración/edición: EditMem, EditPrg, ExecPaso.
    void render(const Cpu& cpu, const UiState& ui);

    // Vista del programa (ExecCont): vuelca el framebuffer y compone encima la
    // rejilla de texto (TEXT_CELLS celdas, fila*TEXT_COLS + col; 0 = celda
    // transparente), con sus atributos (mismo índice, banco 0x0500+ -- ver
    // iomap.h ATTR_*; puede ser nullptr, equivale a "todo a 0"). Si 'halted',
    // superpone un aviso "HALT" en una esquina.
    void renderFramebuffer(const uint8_t* fb, const uint8_t* text, const uint8_t* attr, bool halted);

    // Mensaje a pantalla completa (p. ej. "GUARDANDO..." antes de bloquear).
    void message(const char* text);

    // Ahorro de energía. La OLED consume ~10-15 mA encendida; apagarla por
    // inactividad es de lo que más alarga la batería. `power(false)` manda
    // DISPLAY OFF (baja a µA, conserva el contenido); `power(true)` la reenciende
    // (hay que redibujar). `contrast()` la atenúa sin apagarla (0x00..0xFF).
    void power(bool on);
    void contrast(uint8_t level);

private:
    void renderEditMem(const Cpu& cpu, const UiState& ui);
    void renderEditPrg(const Cpu& cpu, const UiState& ui);

    uint8_t i2cAddress_;
    Adafruit_SH1106G display_;
};

} // namespace compi
