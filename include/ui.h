#pragma once
#include <stdint.h>
#include "editor.h"

namespace compi {

// Las 4 vistas, derivadas de los dos interruptores:
//   SW_MODO=EDITAR + SW_PASO=SINGLE     -> EditMem
//   SW_MODO=EDITAR + SW_PASO=CONTINUOUS -> EditPrg
//   SW_MODO=EJECUTAR + SW_PASO=SINGLE     -> ExecPaso
//   SW_MODO=EJECUTAR + SW_PASO=CONTINUOUS -> ExecCont
enum class View : uint8_t { EditMem, EditPrg, ExecPaso, ExecCont };

// Nuevo: borra la RAM (todo a NOP) para empezar un programa desde cero,
// sin tocar la flash -- para eso hace falta un Guardar aparte, como con
// cualquier otro cambio hecho en EditMem.
enum class PrgAction : uint8_t { Cargar, Guardar, Nuevo };

// Estado de la interfaz que el sketch principal mantiene y pasa al
// renderizador. No lo toca el FrontPanel (que es solo lectura de hardware).
struct UiState {
    View view = View::EditMem;
    // Dirección editada (EditMem) O dirección objetivo elegida con ADDRESS
    // para ejecutar hasta ella (ExecPaso, ver main.cpp) -- las dos vistas
    // son mutuamente excluyentes, así que basta un solo campo.
    uint16_t cursor = 0;
    ComposeState compose;         // instrucción en construcción en `cursor` (EditMem)
    // EditMem: longitud de la instrucción que YA HABÍA en `cursor` al
    // empezar a editarla (capturada junto con cada decodeAt() fresco), y si
    // ya se ha abierto hueco de sobra para la que se está componiendo --
    // ver ensureRoomFor()/el bloque EditMem en main.cpp. Mientras el verbo
    // o el mode todavía se están eligiendo (longitud final desconocida) no
    // se escribe nada en RAM, así que el listado sigue mostrando la
    // instrucción de siempre tal cual, sin arriesgarse a pisar la
    // siguiente; en cuanto el tamaño final se sabe, se abre hueco UNA vez
    // (si hace falta) y se marca `roomEnsured` para no repetirlo en cada
    // giro posterior de la misma instrucción.
    uint8_t origLen = 1;
    bool roomEnsured = false;
    uint8_t slot = 0;             // slot seleccionado (EditPrg)
    bool slotUsed = false;        // ¿el slot tiene programa? (EditPrg)
    PrgAction prgAction = PrgAction::Cargar;

    // ExecPaso: ¿el listado debe seguir a `cursor` (se está eligiendo un
    // objetivo con ADDRESS) en vez de al PC? Por defecto false -- el PC
    // SIEMPRE debe verse mientras se ejecuta algo con DATOS o corre una
    // carrera; solo se pone a true justo al girar ADDRESS (para poder ver
    // el código mientras se elige un destino lejos del PC actual), y vuelve
    // a false en cuanto se toca DATOS, arranca/termina una carrera, se
    // resetea, o se entra en la vista -- ver main.cpp y renderEditMem en
    // display.cpp.
    bool pasoFollowCursor = false;

    // Previsualización del slot seleccionado (EditPrg): primeros bytes de la
    // imagen leídos de la flash. previewLen 0 = slot vacío / sin datos.
    const uint8_t* preview = nullptr;
    uint16_t previewLen = 0;
};

// Nº de bytes de imagen que se leen de la flash para la previsualización.
constexpr uint16_t PREVIEW_BYTES = 48;

} // namespace compi
