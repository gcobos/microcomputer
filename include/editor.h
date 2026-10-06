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
//   DIRECCIÓN pulsar -> salta a la instrucción anterior entera (a su
//                    opcode), sea cual sea el campo en el que estés
//
// La instrucción se escribe en memoria EN VIVO, sobreescribiendo en el sitio
// (nunca desplaza bytes) cada vez que cambia un campo — igual que ya hace la
// edición de byte crudo. Ver la explicación de qué pasa con los bytes
// siguientes al cambiar de tamaño en la conversación de diseño / specs.txt §12.

// Los "verbos" que se pueden teclear: cada uno agrupa todas sus formas
// (familias de opcode, operaciones de la ALU, condiciones) en un unico
// mnemonico legible, y el campo `mode` elige la forma (ver modeCount en
// editor.cpp y la tabla de docs/isa.md).
enum Verb : uint8_t {
    V_NOP = 0, V_HALT, V_RET, V_MOVB, V_MOVW, V_MOVBR,
    V_MOV, V_LDA, V_STA, V_IN, V_OUT,
    V_ADD, V_ADC, V_SUB, V_SBC, V_CMP, V_AND, V_OR, V_XOR,
    V_NOT, V_SHR, V_SHL, V_MUL, V_DIV, V_INC, V_DEC,
    V_PUSH, V_POP, V_JMP, V_CALL,
};
constexpr uint8_t VERB_COUNT = 30;
constexpr uint8_t COND_COUNT = 9;   // JC_ALWAYS..JC_V (isa.h) y un 9o valor
                                      // "NV" que se codifica en OP_JX

// Campo que se está editando ahora mismo dentro de la instrucción.
enum class EField : uint8_t { Verb, Mode, Cond, Reg, Dst, Src, Imm, Lo, Hi, Ptr, Shift, Ptr2, Done };

// Estado de una instrucción en construcción en el cursor actual.
struct ComposeState {
    uint8_t  verb   = V_NOP;
    uint8_t  mode   = 0;      // forma del verbo (ver modeCount/operandFields
                               //   en editor.cpp): p.ej. ADD 0=reg,reg
                               //   1=reg,#imm 2=reg,[dir] 3=reg,[r16]
                               //   4=r16,reg8 5=r16,r16 6=r16,#imm8
    uint8_t  reg    = 0;      // registro de 8 bits de una forma de un solo
                               //   registro (o el de reg,#imm / reg,[...])
    uint8_t  dst    = 0;      // forma reg,reg
    uint8_t  src    = 0;      // forma reg,reg
    uint8_t  cond   = 0;      // JMP/CALL: 0..7 = JumpCond, 8 = NV
    uint8_t  imm    = 0;      // inmediato de 8 bits
    uint16_t addr16 = 0;      // direccion/puerto de 16 bits, o inmediato de 16
    uint8_t  ptr    = 0;      // par de 16 bits (AX/BX/CX/DX): puntero, o
                               //   destino de una forma de 16 bits
    uint8_t  ptr2   = 0;      // par de 16 bits de origen (formas r16,r16)
    uint8_t  shift  = 1;      // SHR/SHL: cuenta (1..8)
    uint8_t  step   = 0;      // paso actual (0 = eligiendo verbo)
};

// Campo que le toca al paso `step` (0-based; step 0 siempre es Verb).
EField fieldAt(uint8_t verb, uint8_t mode, uint8_t step);

// Último paso con un campo real (el siguiente ya es Done). Al pulsar DATOS
// estando en este paso, se avanza la dirección en vez de pasar de campo.
uint8_t lastStep(uint8_t verb, uint8_t mode);

// Gira el encoder DATOS: cambia el campo activo (con wrap). Cambiar el verbo
// reinicia mode/reg/dst/src/cond/imm/addr16 a 0 (no hereda bits sueltos del
// verbo anterior). En el campo Verb, el orden en que se van ofreciendo al
// girar es alfabético por nombre (ver verbName), no el orden interno del
// enum de arriba (que agrupa por familia de opcode y no importa a quien
// teclea).
void applyDelta(ComposeState& st, int16_t delta);

// Nombre corto del verbo (p.ej. "NOP", "MOV"), para mostrarlo en pantalla
// mientras se elige en el campo Verb.
const char* verbName(uint8_t verb);

// Vuelca el estado a mem[addr..], sobreescribiendo en el sitio (nunca
// desplaza bytes siguientes). Devuelve la longitud escrita (1-4).
uint8_t assemble(uint8_t* mem, uint32_t memLen, uint16_t addr, const ComposeState& st);

// Cuanto ocuparía `st` si se ensamblase ahora mismo (1-4), SIN escribir
// nada en memoria de verdad (usa un buffer descartable aparte). Para saber
// el tamaño de una instrucción en construcción antes de comprometerse a
// escribirla en el sitio -- ver main.cpp (no pisar la instrucción
// siguiente mientras el verbo/mode aún se están eligiendo) y display.cpp
// (el "(size N)" de la cabecera mientras se elige el verbo).
uint8_t composedLength(const ComposeState& st);

// Reconstruye un ComposeState a partir de lo que YA hay en memoria en `addr`
// (para arrancar la edición de una instrucción existente en lo que ya hay,
// igual que la edición de byte crudo). step siempre vuelve a 0.
ComposeState decodeAt(const uint8_t* mem, uint32_t memLen, uint16_t addr);

} // namespace compi
