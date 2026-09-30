#pragma once
#include <stdint.h>

namespace compi {

// 8 registros direccionables de 8 bits: mitades de AX, BX, CX, DX
enum Reg8 : uint8_t {
    REG_AL = 0, REG_AH = 1,
    REG_BL = 2, REG_BH = 3,
    REG_CL = 4, REG_CH = 5,
    REG_DL = 6, REG_DH = 7,
};

// Familias de opcode (5 bits altos). El byte de opcode es family<<3 | reg.
enum OpFamily : uint8_t {
    OP_NOP  = 0,
    OP_HALT = 1,
    OP_LDI  = 2,   // LDI  reg, #imm8   (forma corta de MOV reg,#imm)
    OP_LDA  = 3,   // LDA  reg, [addr16]   (MOV reg <- memoria)
    OP_STA  = 4,   // STA  reg, [addr16]   (MOV memoria <- reg)
    OP_ADD  = 5,   // ADD  reg, [addr16]
    OP_SUB  = 6,   // SUB  reg, [addr16]
    OP_AND  = 7,   // AND  reg, [addr16]
    OP_OR   = 8,   // OR   reg, [addr16]
    OP_XOR  = 9,   // XOR  reg, [addr16]
    OP_NOT  = 10,  // NOT  reg
    OP_SHR  = 11,  // SHR  reg
    OP_SHL  = 12,  // SHL  reg
    OP_IN   = 13,  // IN   reg, (port16)
    OP_OUT  = 14,  // OUT  reg, (port16)
    OP_PUSH = 15,  // PUSH reg
    OP_POP  = 16,  // POP  reg
    OP_JMP  = 17,  // JMP  addr16   (reg = condición, ver JumpCond)
    OP_CALL = 18,  // CALL addr16   (reg = condición)
    OP_RET  = 19,  // RET
    OP_ALUI = 20,  // <op> reg, #imm8   (reg de opcode = AluOp; operando: reg, imm8)
    // Direccionamiento indirecto por registro de 16 bits (LEN 2: opcode +
    // byte con el par AX/BX/CX/DX en los 2 bits bajos, ver Reg16 más abajo).
    // Mismo dato que LDA/STA/IN/OUT pero sin gastar los 2 bytes de addr16.
    OP_LDAR = 21,  // LDA  reg, [ptr16]    (MOV reg <- mem[ptr16])
    OP_STAR = 22,  // STA  [ptr16], reg    (MOV mem[ptr16] <- reg)
    OP_INR  = 23,  // IN   reg, (ptr16)
    OP_OUTR = 24,  // OUT  (ptr16), reg
    // SHR/SHL reg, #N (N=1..8, LEN 2: opcode + byte con (N-1) en los 3 bits
    // bajos, resto reservado a 0). Mismo dato que OP_SHR/OP_SHL, pero
    // desplaza N bits de una vez en vez de solo 1 -- para no tener que
    // repetir la instruccion N veces cuando se conoce N en tiempo de
    // ensamblado (multiplicar/dividir por potencias de 2, direcciones de
    // pantalla, etc).
    OP_SHRN = 25,  // SHR  reg, #N
    OP_SHLN = 26,  // SHL  reg, #N
    // Multiplicacion/division de 8x8->16 bits sin signo, acumulador
    // implicito AX (igual convencion que 8080/Z80/x86: el multiplicando/
    // dividendo vive en AX, el operando explicito es el multiplicador/
    // divisor) -- LEN 1, reg de opcode = ese operando. Reemplazan a rutinas
    // de software de ~60-70 instrucciones (ver smul64 en cubo.asm).
    OP_MUL  = 27,  // MUL reg   : AX = AL * reg           (Z/N/C/V, ver cpu.cpp)
    OP_DIV  = 28,  // DIV reg   : AL=AX/reg AH=AX%reg      (div/0 satura, ver cpu.cpp)
    // INC/DEC de un par de 16 bits (AX/BX/CX/DX) -- LEN 1, reg de opcode =
    // dir<<2|reg16 (dir 0=INC 1=DEC, reg16 en los 2 bits bajos). No toca
    // flags (aritmetica de punteros, no de programa -- ver isa.md).
    OP_INCDEC16 = 29,  // INC/DEC reg16
    // Familia de "extension 2": subop en los 3 bits bajos del opcode.
    // Mezcla longitudes a proposito (documentado en isa.md/specs.txt):
    //   0 ADD dst16,src8  (LEN2, dst16 += src8 sin signo -- MISMO mnemonico
    //                      ADD que reg,reg/reg,#imm/reg,[dir], el ensamblador
    //                      lo detecta por que dst es un nombre de 16 bits)
    //   1 SUB dst16,src8  (LEN2, igual pero resta)
    //   2 MOVB             (LEN1: copia CX bytes [BX]->[DX], sin operando)
    //   3 MOVW             (LEN1: igual, CX cuenta palabras de 16 bits)
    //   4 JMPNV addr16     (LEN3: salta si V=0 -- ver JC_V mas abajo)
    //   5 CALLNV addr16    (LEN3)
    //   6 MOV reg16,#imm16 (LEN4: reg16 = imm16 -- MISMO mnemonico MOV,
    //                       detectado por que el destino es de 16 bits;
    //                       unica instruccion de mas de 3 bytes de toda
    //                       la ISA. operando: [reg16(2)|--(6)][imm16 lo][imm16 hi])
    //   7 reservado (se ejecuta como NOP)
    OP_EXT2 = 30,
    OP_EXT  = 31,  // <op> dst, src     (reg de opcode = AluOp; operando: [--|dst:3|src:3])
};

// Par de registro de 16 bits, para el byte de operando de OP_LDAR/OP_STAR/
// OP_INR/OP_OUTR (2 bits bajos; el resto queda reservado a 0).
enum Reg16 : uint8_t {
    REG_AX = 0, REG_BX = 1, REG_CX = 2, REG_DX = 3,
};

// Condiciones codificadas en los 3 bits bajos de JMP/CALL
enum JumpCond : uint8_t {
    JC_ALWAYS = 0,
    JC_Z      = 1,
    JC_NZ     = 2,
    JC_C      = 3,
    JC_NC     = 4,
    JC_N      = 5,
    JC_NN     = 6,
    JC_V      = 7,  // salta si V=1 (overflow con signo) -- JMPV/CALLV
    // NV (salta si V=0) NO tiene hueco en este campo de 3 bits (0-7 ya
    // llenos): JMPNV/CALLNV se codifican aparte, en OP_EXT2 subop 4/5 --
    // ver isa.h arriba y editor.cpp (se ofrecen igualmente como el verbo
    // JMP/CALL de siempre, con un 9o valor de condicion en el editor).
};

// Operación de la ALU (bits bajos del opcode en OP_EXT y OP_ALUI).
//   OP_EXT  0xF8+op : <op> dst,src      (registro-registro, LEN 2)
//   OP_ALUI 0xA0+op : <op> reg,#imm8    (LEN 3; op 0 = MOV no se usa, ver LDI)
enum AluOp : uint8_t {
    ALU_MOV = 0,  // dst = src              (no toca flags)
    ALU_ADD = 1,  // dst = dst + src
    ALU_SUB = 2,  // dst = dst - src
    ALU_CMP = 3,  // solo flags de (dst - src); dst no cambia
    ALU_AND = 4,  // dst = dst & src
    ALU_OR  = 5,  // dst = dst | src
    ALU_XOR = 6,  // dst = dst ^ src
};

enum FlagBit : uint8_t {
    FLAG_C = 1 << 0,
    FLAG_Z = 1 << 1,
    FLAG_N = 1 << 2,
    FLAG_V = 1 << 3,
};

inline uint8_t makeOpcode(uint8_t family, uint8_t regOrCond) {
    return (uint8_t)((family << 3) | (regOrCond & 0x07));
}
inline uint8_t opFamily(uint8_t opcode) { return opcode >> 3; }
inline uint8_t opReg(uint8_t opcode)    { return opcode & 0x07; }

} // namespace compi
