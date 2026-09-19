#pragma once
#include <stdint.h>
#include <stddef.h>

namespace compi {

// Desensamblador. Trabaja sobre un bloque de memoria plano ('mem', 'memLen'
// bytes); las direcciones >= memLen leen 0. Para la RAM de la CPU se pasa
// cpu.ram() y 65536; para una previsualización de un slot, el buffer parcial.

// Nombre de un registro de 8 bits (0..7 -> AL,AH,BL,BH,CL,CH,DL,DH).
const char* regName8(uint8_t reg);

// Nombre de un par de registro de 16 bits (0..3 -> AX,BX,CX,DX; isa.h Reg16).
const char* regName16(uint8_t pairCode);

// Longitud en bytes (1..3) de la instrucción que empieza en 'addr'.
uint8_t instrLen(const uint8_t* mem, uint32_t memLen, uint16_t addr);

// Desensambla la instrucción en 'addr': escribe el mnemónico en 'out'
// (outSize >= 24 recomendado) y devuelve su longitud en bytes.
uint8_t disassemble(const uint8_t* mem, uint32_t memLen, uint16_t addr,
                    char* out, size_t outSize);

// Dirección de instrucción alineada (recorriendo desde 0) que debe ser la
// primera línea del listado para que 'anchor' quede a la vista con una línea
// de contexto por encima.
uint16_t listBase(const uint8_t* mem, uint32_t memLen, uint16_t anchor);

// Dirección de inicio de la instrucción INMEDIATAMENTE ANTERIOR a 'addr',
// recorriendo desde 0 (igual que listBase). Asume que 'addr' ya es en sí un
// límite de instrucción válido; si no lo es (p. ej. cae en mitad de un
// operando), el resultado no tiene por qué tener sentido -- ver la nota en
// main.cpp sobre por qué EditMem solo llama a esto para retroceder desde un
// cursor que siempre se mantiene alineado.
uint16_t prevInstrStart(const uint8_t* mem, uint32_t memLen, uint16_t addr);

} // namespace compi
