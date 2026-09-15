#pragma once
#include <stdint.h>
#include <stddef.h>

namespace compi {

// Un "programa" es la imagen COMPLETA de la RAM de la CPU (64 KiB). Guardar
// y cargar es un volcado total: sin tamaño variable, sin recortes, sin
// "dónde acaba el programa". Cada slot de la flash guarda una imagen entera.
constexpr size_t PROGRAM_SIZE = 65536;

// Slots que caben en la flash de 4 MiB. Cada slot ocupa 17 sectores de 4 KiB
// (1 de cabecera/marca + 16 para la imagen de 64 KiB): 17 * 4096 = 69632.
// 4194304 / 69632 = 60.
constexpr size_t MAX_PROGRAM_SLOTS = 60;

// Interfaz de almacenamiento. Cualquier implementación (flash SPI real,
// fichero...) es intercambiable.
class IProgramStorage {
public:
    virtual ~IProgramStorage() = default;
    virtual bool init() = 0;
    // ¿El slot tiene una imagen guardada?
    virtual bool slotUsed(int slot) = 0;
    // Lee la imagen del slot en 'dest' (PROGRAM_SIZE bytes). false si vacío.
    virtual bool loadProgram(int slot, uint8_t* dest) = 0;
    // Lee los primeros 'len' bytes de la imagen del slot (previsualización).
    virtual bool previewProgram(int slot, uint8_t* dest, uint32_t len) = 0;
    // Escribe 'src' (PROGRAM_SIZE bytes) en el slot. Borra y reescribe.
    virtual bool saveProgram(int slot, const uint8_t* src) = 0;
    // Marca el slot como libre.
    virtual bool deleteProgram(int slot) = 0;
};

} // namespace compi
