#pragma once
#include <stdint.h>
#include "editor.h"

namespace compi {

// Las 4 vistas, derivadas de los dos interruptores:
//   SW_MODO=EDITAR + SW_PASO=▲  -> EditMem
//   SW_MODO=EDITAR + SW_PASO=▼  -> EditPrg
//   SW_MODO=EJECUTAR + SW_PASO=▲ -> ExecPaso
//   SW_MODO=EJECUTAR + SW_PASO=▼ -> ExecCont
enum class View : uint8_t { EditMem, EditPrg, ExecPaso, ExecCont };

// Nuevo: borra la RAM (todo a NOP) para empezar un programa desde cero,
// sin tocar la flash -- para eso hace falta un Guardar aparte, como con
// cualquier otro cambio hecho en EditMem.
enum class PrgAction : uint8_t { Cargar, Guardar, Nuevo };

// Estado de la interfaz que el sketch principal mantiene y pasa al
// renderizador. No lo toca el FrontPanel (que es solo lectura de hardware).
struct UiState {
    View view = View::EditMem;
    uint16_t cursor = 0;          // dirección editada (EditMem)
    ComposeState compose;         // instrucción en construcción en `cursor` (EditMem)
    uint8_t slot = 0;             // slot seleccionado (EditPrg)
    bool slotUsed = false;        // ¿el slot tiene programa? (EditPrg)
    PrgAction prgAction = PrgAction::Cargar;

    // Previsualización del slot seleccionado (EditPrg): primeros bytes de la
    // imagen leídos de la flash. previewLen 0 = slot vacío / sin datos.
    const uint8_t* preview = nullptr;
    uint16_t previewLen = 0;
};

// Nº de bytes de imagen que se leen de la flash para la previsualización.
constexpr uint16_t PREVIEW_BYTES = 48;

} // namespace compi
