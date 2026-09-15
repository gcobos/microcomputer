#pragma once
#include <stdint.h>

namespace compi {

// Selector de mnemónico para la vista EditMem (specs.txt §12): compone una
// instrucción CAMPO A CAMPO (verbo -> mode -> operandos) en vez de puerto a
// puerto. Sin dependencias de hardware (como cpu/disasm/panel): opera sobre
// un buffer plano (mem, memLen), igual que disasm.cpp.
//
//   DATOS girar   -> cambia el valor del campo activo (fieldAt)
//   DATOS pulsar  -> confirma el campo y pasa al siguiente; en el último,
//                    esa misma pulsación ya avanza el cursor a la dirección
//                    siguiente (longitud de la instrucción ya compuesta)
//   DIRECCIÓN pulsar -> retrocede un campo (o una dirección si ya estás en
//                    el primero)
//
// La instrucción se escribe en memoria EN VIVO, sobreescribiendo en el sitio
// (nunca desplaza bytes) cada vez que cambia un campo — igual que ya hace la
// edición de byte crudo. Ver la explicación de qué pasa con los bytes
// siguientes al cambiar de tamaño en la conversación de diseño / specs.txt §12.

// Los ~21 "verbos" que se pueden teclear (agrupa las familias del opcode +
// las variantes de ALU/condición en un único mnemónico legible).
enum Verb : uint8_t {
    V_NOP = 0, V_HALT, V_MOV, V_LDA, V_STA, V_ADD, V_SUB, V_AND, V_OR, V_XOR,
    V_NOT, V_SHR, V_SHL, V_IN, V_OUT, V_PUSH, V_POP, V_JMP, V_CALL, V_RET, V_CMP,
};
constexpr uint8_t VERB_COUNT = 21;
constexpr uint8_t COND_COUNT = 7;   // JC_ALWAYS..JC_NN (isa.h)

// Campo que se está editando ahora mismo dentro de la instrucción.
enum class EField : uint8_t { Verb, Mode, Cond, Reg, Dst, Src, Imm, Lo, Hi, Ptr, Done };

// Estado de una instrucción en construcción en el cursor actual.
struct ComposeState {
    uint8_t  verb   = V_NOP;
    uint8_t  mode  = 0;      // 0..2; solo válido si el verbo tiene varias formas
                               //   (MOV/CMP: 0=reg,reg 1=reg,#imm ;
                               //    ADD/SUB/AND/OR/XOR: + 2=reg,[dir] ;
                               //    LDA/STA/IN/OUT: 0=[addr16] 1=[AX|BX|CX|DX])
    uint8_t  reg    = 0;      // registro único: LDA/STA/IN/OUT/NOT/SHR/SHL/PUSH/POP
                               //   y el "reg" de las formas reg,#imm / reg,[dir]
    uint8_t  dst    = 0;      // mode reg,reg
    uint8_t  src    = 0;      // mode reg,reg
    uint8_t  cond   = 0;      // JMP/CALL
    uint8_t  imm    = 0;      // mode reg,#imm
    uint16_t addr16 = 0;      // LDA/STA/IN/OUT/JMP/CALL/mode reg,[dir]
    uint8_t  ptr    = 0;      // LDA/STA/IN/OUT mode 1: par de 16 bits (isa.h Reg16)
    uint8_t  step   = 0;      // paso actual (0 = eligiendo verbo)
};

// Campo que le toca al paso `step` (0-based; step 0 siempre es Verb).
EField fieldAt(uint8_t verb, uint8_t mode, uint8_t step);

// Último paso con un campo real (el siguiente ya es Done). Al pulsar DATOS
// estando en este paso, se avanza la dirección en vez de pasar de campo.
uint8_t lastStep(uint8_t verb, uint8_t mode);

// Gira el encoder DATOS: cambia el campo activo (con wrap). Cambiar el verbo
// reinicia mode/reg/dst/src/cond/imm/addr16 a 0 (no hereda bits sueltos del
// verbo anterior).
void applyDelta(ComposeState& st, int16_t delta);

// Vuelca el estado a mem[addr..], sobreescribiendo en el sitio (nunca
// desplaza bytes siguientes). Devuelve la longitud escrita (1-3).
uint8_t assemble(uint8_t* mem, uint32_t memLen, uint16_t addr, const ComposeState& st);

// Reconstruye un ComposeState a partir de lo que YA hay en memoria en `addr`
// (para arrancar la edición de una instrucción existente en lo que ya hay,
// igual que la edición de byte crudo). step siempre vuelve a 0.
ComposeState decodeAt(const uint8_t* mem, uint32_t memLen, uint16_t addr);

} // namespace compi
