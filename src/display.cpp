#include "display.h"
#include "disasm.h"
#include "editor.h"
#include "isa.h"
#include "iomap.h"
#include "font5x7.h"
#include <stdio.h>
#include <string.h>

namespace compi {

namespace {
constexpr int16_t SCREEN_WIDTH = 128;
constexpr int16_t SCREEN_HEIGHT = 64;
constexpr int16_t ROW_H = 8;

void flagsStr(uint8_t f, char out[5]) {
    out[0] = (f & FLAG_N) ? 'N' : '-';
    out[1] = (f & FLAG_V) ? 'V' : '-';
    out[2] = (f & FLAG_Z) ? 'Z' : '-';
    out[3] = (f & FLAG_C) ? 'C' : '-';
    out[4] = 0;
}

// Nombre corto del campo que está editando ahora mismo el selector de
// mnemónico (editor.h), para el encabezado de EditMem.
const char* editFieldLabel(const UiState& ui) {
    static const char* const kLabel[12] = {
        "OP", "MODE", "COND", "REG", "DST", "SRC", "IMM", "LO", "HI", "PTR", "N", ""
    };
    EField f = fieldAt(ui.compose.verb, ui.compose.mode, ui.compose.step);
    return kLabel[(uint8_t)f];
}

constexpr int16_t CELL_W = 6;
constexpr int16_t CELL_H = 8;
constexpr unsigned long BLINK_PERIOD_MS = 500; // medio ciclo encendido, medio apagado

// Dibuja una celda de texto (esquina superior izquierda en x0,y0) aplicando
// sus atributos (ver iomap.h ATTR_*). No usa Adafruit_GFX::drawChar(): esa
// función no admite rotar un carácter por separado (solo rota la pantalla
// entera), así que aquí se recorre el bitmap de font5x7.h píxel a píxel y se
// coloca ya girado. Con attr=0 el resultado es igual, píxel a píxel, al que
// daba drawChar(..., fg, bg, 1) -- incluida la fila 8 de fondo, que el
// carácter nunca toca (la fuente clásica solo usa 7 de las 8 filas).
void drawTextCell(Adafruit_SH1106G& d, int16_t x0, int16_t y0, uint8_t ch, uint8_t attr) {
    if (attr & ATTR_BLINK) {
        bool on = ((millis() / BLINK_PERIOD_MS) & 1) == 0;
        if (!on) return; // medio ciclo "apagado": celda transparente este fotograma
    }

    const bool inverse = (attr & ATTR_INVERSE) != 0;
    const uint16_t fg = inverse ? SH110X_BLACK : SH110X_WHITE;
    const uint16_t bg = inverse ? SH110X_WHITE : SH110X_BLACK;
    d.fillRect(x0, y0, CELL_W, CELL_H, bg);

    // Subíndice/superíndice: desplazamiento vertical del glifo dentro de la
    // celda (a esta resolución -5x7 en una celda de 8 px- no hay margen para
    // además encogerlo y que se siga leyendo). Si se piden los dos a la vez,
    // gana subíndice.
    int8_t dy = 0;
    if (attr & ATTR_SUBSCRIPT) dy = 1;
    else if (attr & ATTR_SUPERSCRIPT) dy = -1;

    const uint8_t rot = (uint8_t)((attr & ATTR_ROT_MASK) >> ATTR_ROT_SHIFT);
    for (uint8_t col = 0; col < FONT5X7_COLS; ++col) {
        for (uint8_t row = 0; row < FONT5X7_ROWS; ++row) {
            if (!font5x7Bit((char)ch, col, row)) continue;
            int16_t px, py;
            switch (rot) {
                // 90°/270°: la fuente es de 7 filas pero la celda solo tiene 6 px de
                // ancho -- girada, no cabe entera, hay que perder 1 fila. A 90° sin
                // este -1, se perdía la fila 0 (arriba) del glifo original, que para
                // letras como 'R' es justo el rasgo que la distingue (el bucle
                // superior); con el -1 se pierde la fila 6 (abajo) en su lugar, igual
                // que ya pasa de forma natural en 270° (ver el caso 3, sin -1).
                case 1: px = (int16_t)(FONT5X7_ROWS - 2 - row); py = col; break;              // 90°
                case 2: px = (int16_t)(FONT5X7_COLS - 1 - col); py = (int16_t)(FONT5X7_ROWS - 1 - row); break; // 180°
                case 3: px = row; py = (int16_t)(FONT5X7_COLS - 1 - col); break;              // 270°
                default: px = col; py = row; break;                                           // 0°
            }
            py = (int16_t)(py + dy);
            if (px < 0 || px >= CELL_W || py < 0 || py >= CELL_H) continue; // no sangrar a la celda vecina
            d.drawPixel((int16_t)(x0 + px), (int16_t)(y0 + py), fg);
        }
    }

    if (attr & ATTR_UNDERLINE) d.drawFastHLine(x0, (int16_t)(y0 + CELL_H - 1), CELL_W, fg);
    if (attr & ATTR_STRIKE)    d.drawFastHLine(x0, (int16_t)(y0 + CELL_H / 2 - 1), CELL_W, fg);
}
} // namespace

OledPanel::OledPanel(uint8_t i2cAddress)
    : i2cAddress_(i2cAddress), display_(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1) {}

bool OledPanel::begin() {
    if (!display_.begin(i2cAddress_, true)) return false;
    display_.setTextColor(SH110X_WHITE);
    display_.setTextSize(1);
    display_.cp437(true);
    return true;
}

void OledPanel::render(const Cpu& cpu, const UiState& ui) {
    if (ui.view == View::EditPrg) renderEditPrg(cpu, ui);
    else                          renderEditMem(cpu, ui); // EditMem o ExecPaso
}

// Listado desensamblado + registros. Ancla = cursor (EditMem) o PC (ExecPaso).
void OledPanel::renderEditMem(const Cpu& cpu, const UiState& ui) {
    char buf[32], mnem[24], fl[5];
    const bool paso = (ui.view == View::ExecPaso);
    const uint16_t pc = cpu.pc();
    const uint16_t anchor = paso ? pc : ui.cursor;
    const uint16_t base = listBase(cpu.ram(), 65536u, anchor);
    const Registers& rg = cpu.regs();
    flagsStr(cpu.flags(), fl);

    display_.clearDisplay();

    display_.setCursor(0, 0);
    if (paso)
        snprintf(buf, sizeof(buf), "STEP %sPC=%04X", cpu.halted() ? "HLT " : "", pc);
    else
        snprintf(buf, sizeof(buf), "%04X %s", ui.cursor, editFieldLabel(ui));
    display_.print(buf);

    uint16_t a = base;
    for (int i = 0; i < 5; ++i) {
        uint8_t len = disassemble(cpu.ram(), 65536u, a, mnem, sizeof(mnem));
        bool onCur = (!paso && ui.cursor >= a && ui.cursor < (uint16_t)(a + len));
        bool onPc  = (pc >= a && pc < (uint16_t)(a + len));
        char mark = onCur ? '>' : (onPc ? '*' : ' ');
        display_.setCursor(0, (int16_t)(ROW_H + i * ROW_H));
        snprintf(buf, sizeof(buf), "%c%04X %s", mark, a, mnem);
        display_.print(buf);
        a = (uint16_t)(a + len);
    }

    const int16_t y6 = (int16_t)(SCREEN_HEIGHT - 2 * ROW_H);
    const int16_t y7 = (int16_t)(SCREEN_HEIGHT - ROW_H);
    if (paso) {
        display_.setCursor(0, y6);
        snprintf(buf, sizeof(buf), "AX%04X BX%04X SP%04X", rg.AX(), rg.BX(), cpu.sp());
        display_.print(buf);
        display_.setCursor(0, y7);
        snprintf(buf, sizeof(buf), "CX%04X DX%04X %s", rg.CX(), rg.DX(), fl);
        display_.print(buf);
    } else {
        display_.setCursor(0, y6);
        snprintf(buf, sizeof(buf), "cur %04X = 0x%02X", ui.cursor, cpu.mem(ui.cursor));
        display_.print(buf);
        display_.setCursor(0, y7);
        snprintf(buf, sizeof(buf), "PC %04X  SP %04X %s", pc, cpu.sp(), fl);
        display_.print(buf);
    }
    display_.display();
}

// Selector de programa: slot, estado, acción y previsualización del slot.
void OledPanel::renderEditPrg(const Cpu& cpu, const UiState& ui) {
    (void)cpu;
    char buf[32], mnem[24];
    display_.clearDisplay();

    display_.setCursor(0, 0);
    snprintf(buf, sizeof(buf), "PRG  slot %02u   %s",
             ui.slot, ui.slotUsed ? "[prog]" : "[----]");
    display_.print(buf);

    // Acción, en vídeo inverso para que destaque.
    display_.fillRect(0, ROW_H, SCREEN_WIDTH, ROW_H, SH110X_WHITE);
    display_.setTextColor(SH110X_BLACK);
    display_.setCursor(2, ROW_H);
    if (ui.prgAction == PrgAction::Guardar)
        display_.print(ui.slotUsed ? "SAVE  [overwrite]" : "SAVE");
    else if (ui.prgAction == PrgAction::Cargar)
        display_.print("LOAD");
    else
        display_.print("NEW   [blank RAM]");
    display_.setTextColor(SH110X_WHITE);

    // Previsualización (filas 2..6).
    if (ui.previewLen == 0) {
        display_.setCursor(0, (int16_t)(3 * ROW_H));
        display_.print(F("(slot empty)"));
    } else {
        uint16_t a = 0;
        for (int i = 0; i < 5; ++i) {
            uint8_t len = disassemble(ui.preview, ui.previewLen, a, mnem, sizeof(mnem));
            display_.setCursor(0, (int16_t)((2 + i) * ROW_H));
            snprintf(buf, sizeof(buf), " %04X %s", a, mnem);
            display_.print(buf);
            a = (uint16_t)(a + len);
            if (a >= ui.previewLen) break;
        }
    }

    display_.setCursor(0, (int16_t)(SCREEN_HEIGHT - ROW_H));
    display_.print(F("ADDR=slot DATA:turn/go"));
    display_.display();
}

void OledPanel::renderFramebuffer(const uint8_t* fb, const uint8_t* text, const uint8_t* attr, bool halted) {
    // clearDisplay() (no memset a pelo): además de poner el búfer a 0, marca
    // TODA la pantalla como "sucia" (window_x1/y1/x2/y2 = pantalla entera).
    // La librería (Adafruit_GrayOLED) solo manda por I2C esa ventana en
    // display(), y solo drawChar()/fillRect()/etc. (no la escritura directa
    // al búfer que hacemos aquí abajo para el framebuffer gráfico) la
    // amplían. Sin este clearDisplay(), display() solo transmitía el
    // rectángulo que tocaba el texto -- el resto de la pantalla se quedaba
    // sin refrescar en el panel físico aunque el búfer local sí estuviera
    // bien borrado (por eso se veían restos del listado de EditMem al lado
    // del menú, o el jugador no aparecía hasta que algún texto dibujado más
    // abajo ampliaba la ventana).
    display_.clearDisplay();
    uint8_t* dst = display_.getBuffer();
    for (uint16_t y = 0; y < FB_H; ++y) {
        const uint8_t* row = fb + (size_t)y * FB_STRIDE;
        uint8_t* page = dst + (y >> 3) * FB_W;
        const uint8_t ymask = (uint8_t)(1 << (y & 7));
        for (uint16_t xb = 0; xb < FB_STRIDE; ++xb) {
            uint8_t bits = row[xb];
            if (!bits) continue;
            uint16_t x0 = (uint16_t)(xb << 3);
            for (uint8_t b = 0; b < 8; ++b) {
                if (bits & (uint8_t)(0x80 >> b)) page[x0 + b] |= ymask;
            }
        }
    }

    // Capa de texto encima: cada celda no nula se dibuja opaca (6x8) sobre el
    // gráfico, con sus atributos (ver drawTextCell). Celda 0 = transparente
    // (se ve el framebuffer).
    if (text) {
        for (uint8_t r = 0; r < TEXT_ROWS; ++r) {
            for (uint8_t c = 0; c < TEXT_COLS; ++c) {
                uint8_t ch = text[r * TEXT_COLS + c];
                if (ch == 0) continue;
                uint8_t a = attr ? attr[r * TEXT_COLS + c] : 0;
                drawTextCell(display_, (int16_t)(c * CELL_W), (int16_t)(r * ROW_H), ch, a);
            }
        }
        display_.setTextColor(SH110X_WHITE);
    }

    if (halted) {
        display_.fillRect(SCREEN_WIDTH - 30, 0, 30, ROW_H + 1, SH110X_BLACK);
        display_.drawRect(SCREEN_WIDTH - 30, 0, 30, ROW_H + 1, SH110X_WHITE);
        display_.setTextColor(SH110X_WHITE);
        display_.setCursor(SCREEN_WIDTH - 27, 1);
        display_.print(F("HALT"));
    }
    display_.display();
}

void OledPanel::message(const char* text) {
    display_.clearDisplay();
    display_.setCursor(0, (int16_t)(SCREEN_HEIGHT / 2 - ROW_H / 2));
    display_.print(text);
    display_.display();
}

void OledPanel::power(bool on) {
    display_.oled_command(on ? SH110X_DISPLAYON : SH110X_DISPLAYOFF);
}

void OledPanel::contrast(uint8_t level) {
    display_.setContrast(level);
}

} // namespace compi
