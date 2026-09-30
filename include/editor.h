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

// Los ~21 "verbos" que se pueden teclear (agrupa las familias del opcode +
// las variantes de ALU/condición en un único mnemónico legible).
enum Verb : uint8_t {
    V_NOP = 0, V_HALT, V_MOV, V_LDA, V_STA, V_ADD, V_SUB, V_AND, V_OR, V_XOR,
    V_NOT, V_SHR, V_SHL, V_IN, V_OUT, V_PUSH, V_POP, V_JMP, V_CALL, V_RET, V_CMP,
    // Multiplicacion/division (acumulador implicito AX), INC/DEC de un par
    // de 16 bits, y copia de bloque MOVB/MOVW -- ver isa.h OP_MUL/OP_DIV/
    // OP_INCDEC16/OP_EXT2. ADD/SUB de 16 bits NO son verbos nuevos: son un
    // `mode` mas de los verbos ADD/SUB de siempre (ver ComposeState.mode).
    V_MUL, V_DIV, V_INC, V_DEC, V_MOVB, V_MOVW,
};
constexpr uint8_t VERB_COUNT = 27;
constexpr uint8_t COND_COUNT = 9;   // JC_ALWAYS..JC_NN, V (isa.h), y un 9o
                                      // valor logico "NV" que el editor
                                      // ofrece bajo JMP/CALL pero que por
                                      // debajo codifica distinto (isa.h
                                      // OP_EXT2 subop 4/5, no cabe en el
                                      // campo de 3 bits de JMP/CALL) -- ver
                                      // assemble()/decodeAt() en editor.cpp

// Campo que se está editando ahora mismo dentro de la instrucción.
enum class EField : uint8_t { Verb, Mode, Cond, Reg, Dst, Src, Imm, Lo, Hi, Ptr, Shift, Done };

// Estado de una instrucción en construcción en el cursor actual.
struct ComposeState {
    uint8_t  verb   = V_NOP;
    uint8_t  mode  = 0;      // 0..3; solo válido si el verbo tiene varias formas
                               //   (MOV: 0=reg,reg 1=reg,#imm8
                               //      2=reg16,#imm16 (ver `ptr`/`addr16` abajo) ;
                               //    CMP: 0=reg,reg 1=reg,#imm ;
                               //    AND/OR/XOR: + 2=reg,[dir] ;
                               //    ADD/SUB: + 2=reg,[dir] + 3=reg16,reg8
                               //      (dst de 16 bits -- ver `ptr`/`reg` abajo) ;
                               //    LDA/STA/IN/OUT: 0=[addr16] 1=[AX|BX|CX|DX] ;
                               //    SHR/SHL: 0=desplaza 1 bit  1=reg,#N (1..8))
    uint8_t  reg    = 0;      // registro único: LDA/STA/IN/OUT/NOT/SHR/SHL/PUSH/POP
                               //   y el "reg" de las formas reg,#imm / reg,[dir] ;
                               //   también MUL/DIV, y el src8 de ADD/SUB mode 3
    uint8_t  dst    = 0;      // mode reg,reg
    uint8_t  src    = 0;      // mode reg,reg
    uint8_t  cond   = 0;      // JMP/CALL (0..6 = condiciones normales, 7 = V,
                               //   8 = "NV" -- ver COND_COUNT arriba)
    uint8_t  imm    = 0;      // mode reg,#imm
    uint16_t addr16 = 0;      // LDA/STA/IN/OUT/JMP/CALL/mode reg,[dir] ;
                               //   también el imm16 de MOV mode 2 (reg16,#imm16)
    uint8_t  ptr    = 0;      // LDA/STA/IN/OUT mode 1: par de 16 bits (isa.h Reg16) ;
                               //   también INC/DEC, y el dst16 de ADD/SUB mode 3
    uint8_t  shift  = 1;      // SHR/SHL mode 1: cuenta de desplazamiento (1..8)
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
