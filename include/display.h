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
    void contrast(uint8_t level);
    // Igual que contrast(). Ver display.cpp: se probaron PRE-CHARGE/VCOMH y un
    // tramado por software para oscurecer más; los dos se descartaron.
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

    static void txTaskFn(void* arg);
    void lock();
    void unlock();
    SemaphoreHandle_t bus_ = nullptr;      // la pantalla / el I2C
    TaskHandle_t txTask_ = nullptr;
    volatile bool txBusy_ = false;         // hay un fotograma por mandar

    uint8_t i2cAddress_;
    Adafruit_SH1106G display_;
};

} // namespace compi
