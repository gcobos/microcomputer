#pragma once
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include "cpu.h"
#include "ui.h"

namespace compi {

// Columna de la RAM del SH1106 (132 columnas) donde empieza la imagen de 128.
// Depende del panel: la pantalla original (29,5 x 15,0 mm de zona visible)
// enseña de la 2 a la 129 (lo que pone la librería); la actual (35,1 x 18,0
// mm) de la 0 a la 127 -- con 2, la imagen salía 2 px corrida a la derecha
// (ruido a la izquierda, la última casilla de chessboard mas estrecha).
constexpr uint8_t OLED_COL_OFFSET = 0;

// Adafruit_SH1106G con el desplazamiento de columna a mano (_page_start_offset
// es protegido; begin() lo pone siempre a 2).
class Sh1106Panel : public Adafruit_SH1106G {
public:
    using Adafruit_SH1106G::Adafruit_SH1106G;
    void setColumnOffset(uint8_t cols) { _page_start_offset = cols; }
};

// Dibuja en una SH1106 de 128x64 por I2C (librería Adafruit_SH110X, NO
// SSD1306). La vista depende de UiState (sección 14 de specs.txt).
//
// El volcado del programa en marcha (renderFramebuffer) NO bloquea: compone
// el fotograma y lo manda por I2C una tarea aparte (txTask_), mientras la
// emulación y el sonido siguen. El volcado de 1 KiB tarda ~25-30 ms, casi
// todo esperando al periférico I2C: antes, en ese tiempo no avanzaba nada
// (ni el programa, ni el final de las notas), y las notas salían hasta
// 30 ms tarde al azar. Todo lo demás que toca la pantalla toma el mutex
// bus_, así que espera a que acabe un volcado en curso.
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
    // Devuelve false (sin hacer nada) si aún se está mandando el anterior:
    // basta con reintentarlo en la vuelta siguiente.
    bool renderFramebuffer(const uint8_t* fb, const uint8_t* text, const uint8_t* attr, bool halted);

    // Espera a que termine el volcado en curso, si lo hay (antes de dormir).
    void waitIdle();

    // Mensaje a pantalla completa (p. ej. "GUARDANDO..." antes de bloquear).
    void message(const char* text);

    // Ahorro de energía. La OLED consume ~10-15 mA encendida; apagarla por
    // inactividad es de lo que más alarga la batería. `power(false)` manda
    // DISPLAY OFF (baja a µA, conserva el contenido); `power(true)` la reenciende
    // (hay que redibujar). `contrast()` la atenúa sin apagarla (0x00..0xFF, solo SET_CONTRAST).
    void power(bool on);
    // Diagnóstico (COMPI OLEDCMD): manda bytes de comando tal cual (pruebas
    // de brillo: 0x81 contraste, 0xD9 precarga, 0xDB VCOMH, 0x30-0x33 bomba).
    void rawCommands(const uint8_t* cmds, uint8_t n);
    void contrast(uint8_t level);          // 0 = modo noche (ver display.cpp)
    // Igual que contrast(). Ver display.cpp: lo que se ha probado para
    // oscurecer más (el modo noche del nivel 0, y lo descartado).
    void contrastFromSettings(uint8_t level);

    // Aviso de batería baja: un icono de pila vacía en la esquina de arriba a
    // la derecha, encima de cualquier vista, mientras este activo.
    void setBatteryWarning(bool on) { batWarn_ = on; }

private:
    void renderView(const Cpu& cpu, const UiState& ui);
    void renderEditMem(const Cpu& cpu, const UiState& ui);
    void renderEditPrg(const Cpu& cpu, const UiState& ui);
    void drawBatteryWarning(bool blink);
    bool batWarn_ = false;
    bool on_ = true;                       // DISPLAY ON/OFF (power())
    bool night_ = false;                   // precarga/VCOMH del modo noche

    void clearControllerRam();             // las 132 columnas del SH1106
    static void txTaskFn(void* arg);
    void lock();
    void unlock();
    SemaphoreHandle_t bus_ = nullptr;      // la pantalla / el I2C
    TaskHandle_t txTask_ = nullptr;
    volatile bool txBusy_ = false;         // hay un fotograma por mandar

    uint8_t i2cAddress_;
    Sh1106Panel display_;
};

} // namespace compi
