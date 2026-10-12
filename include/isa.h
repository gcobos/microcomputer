#pragma once
#include <stdint.h>

namespace compi {

// ============================================================================
//  Codificacion de la ISA de compi (version 3, ver docs/isa.md).
//
//  El byte de opcode es  familia<<3 | bajo3 :  5 bits de familia (32
//  familias) y 3 bits bajos que, segun la familia, son un registro de 8
//  bits, una condicion, un par de 16 bits o una sub-operacion. Las
//  operaciones de la ALU van en un byte de operando aparte (AluOp), asi que
//  las 9 operaciones caben en las 4 formas de direccionamiento sin gastar
//  una familia por operacion. 0x00 = NOP (RAM a cero = programa vacio).
//
//  Version 3 (octubre 2026): las formas que no se usaban (ALU con memoria,
//  CALL con condicion) dejan sitio a desplazamientos con signo y rotaciones,
//  NEG, IMUL, operaciones de 16 bits (desplazar, NEG, MUL, DIV), saltos con
//  signo y MOV [mem],#imm. LDA/STA pasan a escribirse MOV (mismos opcodes).
// ============================================================================

// 8 registros direccionables de 8 bits: mitades de AX, BX, CX, DX
enum Reg8 : uint8_t {
    REG_AL = 0, REG_AH = 1,
    REG_BL = 2, REG_BH = 3,
    REG_CL = 4, REG_CH = 5,
    REG_DL = 6, REG_DH = 7,
};

// Par de 16 bits (en 2 bits de un operando o de los 3 bits bajos)
enum Reg16 : uint8_t {
    REG_AX = 0, REG_BX = 1, REG_CX = 2, REG_DX = 3,
};

enum OpFamily : uint8_t {
    // --- sin operandos: bajo3 = SysOp ------------------------------- LEN 1
    OP_SYS    = 0,
    // --- mover datos (bajo3 = reg8) -----------------------------------
    OP_LDI    = 1,   // MOV reg,#imm8             [op][imm]           LEN 2
    OP_LDA    = 2,   // MOV reg,[addr16]          [op][lo][hi]        LEN 3
    OP_STA    = 3,   // MOV [addr16],reg          [op][lo][hi]        LEN 3
    OP_LDAR   = 4,   // MOV reg,[reg16]           [op][r16]           LEN 2
    OP_STAR   = 5,   // MOV [reg16],reg           [op][r16]           LEN 2
    OP_IN     = 6,   // IN  reg,(port16)          [op][lo][hi]        LEN 3
    OP_OUT    = 7,   // OUT (port16),reg          [op][lo][hi]        LEN 3
    OP_INR    = 8,   // IN  reg,(reg16)           [op][r16]           LEN 2
    OP_OUTR   = 9,   // OUT (reg16),reg           [op][r16]           LEN 2
    // --- ALU de 8 bits: bajo3 = reg8 destino, operacion en un byte ----
    OP_ALURR  = 10,  // <alu> dst,src             [op][alu<<3|src]    LEN 2
    OP_ALUI   = 11,  // <alu> reg,#imm8           [op][alu][imm]      LEN 3
    // --- desplazamientos con signo y rotaciones; NEG (bajo3 = reg8) ---
    OP_SHX    = 12,  // <shx> reg,#N (N=1..8)     [op][shx<<3|N-1]    LEN 2
    OP_NEG    = 13,  // NEG reg : reg = -reg (flags de 0-reg)         LEN 1
    // --- unarias / desplazamientos / mul-div (bajo3 = reg8) -----------
    OP_NOT    = 14,  // NOT reg                                       LEN 1
    OP_SHR    = 15,  // SHR reg,#N  (N=1..8)      [op][N-1]           LEN 2
    OP_SHL    = 16,  // SHL reg,#N                [op][N-1]           LEN 2
    OP_MUL    = 17,  // MUL reg : AX = AL*reg                         LEN 1
    OP_DIV    = 18,  // DIV reg : AL=AX/reg AH=AX%reg                 LEN 1
    OP_INC    = 19,  // INC reg (8 bits; C no cambia)                 LEN 1
    OP_DEC    = 20,  // DEC reg (8 bits; C no cambia)                 LEN 1
    OP_PUSH   = 21,  // PUSH reg                                      LEN 1
    OP_POP    = 22,  // POP reg                                       LEN 1
    // --- saltos (bajo3 = condicion JumpCond) --------------------------
    OP_JMP    = 23,  // JMP<cc> addr16            [op][lo][hi]        LEN 3
    OP_CALL   = 24,  // bajo3 = CallOp: CALL addr16 (LEN 3) y
                     //   MOV [addr16],#imm8 (LEN 4) / MOV [reg16],#imm8 (LEN 2)
    OP_JX     = 25,  // bajo3 = JxOp: JMPNV y saltos con signo addr16
                     //   (LEN 3), JMP reg16 / CALL reg16 ([op][r16], LEN 2)
    // --- 16 bits (pares AX/BX/CX/DX) -----------------------------------
    OP_R16    = 26,  // bajo3 = R16Op; [op][dst16<<3|src]             LEN 2
    OP_R16I   = 27,  // bajo3 = R16IOp; [op][r16][imm8] (LEN 3) o
                     //   [op][r16][lo][hi] (LEN 4)
    OP_INCDEC16 = 28, // bajo3 = dec<<2|r16 : INC/DEC reg16           LEN 1
    OP_PUSHPOP16 = 29, // bajo3 = pop<<2|r16 : PUSH/POP reg16         LEN 1
    OP_IMUL   = 30,  // IMUL reg : AX = AL*reg con signo              LEN 1
    OP_X16    = 31,  // bajo3 = r16 (0..3; 4..7 libres): [op][x16<<4|N-1]
                     //   desplazar (N=1..16), NEG, MUL, DIV de 16 bits LEN 2
};

// Familia OP_SHX: sub-operacion en los bits 3-5 del operando
enum ShxOp : uint8_t {
    SHX_SAR = 0,     // desplazamiento a la derecha con signo (copia el bit 7)
    SHX_ROL = 1,     // rotar a la izquierda (el bit 7 vuelve por el 0)
    SHX_ROR = 2,     // rotar a la derecha
    SHX_RCL = 3,     // rotar a la izquierda a traves de C (9 bits)
    SHX_RCR = 4,     // rotar a la derecha a traves de C
    // 5..7: libres (no hacen nada; la instruccion ocupa 2 bytes igual)
};

// Familia OP_CALL
enum CallOp : uint8_t {
    CALL_ADDR  = 0,  // CALL addr16
    CALL_STI   = 1,  // MOV [addr16],#imm8       [op][lo][hi][imm]  LEN 4
    // 2, 3: libres (NOP de 1 byte)
    CALL_STIR  = 4,  // 4..7 = MOV [reg16],#imm8 (r16 = bajo3 & 3) [op][imm] LEN 2
};

// Familia OP_X16: sub-operacion en los 4 bits altos del operando
enum X16Op : uint8_t {
    X16_SHL = 0,     // r16 <<= N
    X16_SHR = 1,     // r16 >>= N (sin signo)
    X16_SAR = 2,     // r16 >>= N (con signo)
    X16_NEG = 3,     // r16 = -r16 (N no cuenta)
    X16_MUL = 4,     // DX:AX = AX * r16 (sin signo, 32 bits)
    X16_DIV = 5,     // AX = DX:AX / r16, DX = resto (sin signo)
    // 6..15: libres (no hacen nada)
};

// Familia OP_SYS: sub-operacion en los 3 bits bajos
enum SysOp : uint8_t {
    SYS_NOP   = 0,
    SYS_HALT  = 1,
    SYS_RET   = 2,
    SYS_MOVB  = 3,   // copia CX bytes [BX]->[DX] hacia adelante
    SYS_MOVW  = 4,   // igual, CX palabras de 16 bits
    SYS_MOVBR = 5,   // copia CX bytes hacia ATRAS: BX/DX apuntan al ULTIMO
                     //   byte de cada bloque (memmove seguro con dst > src)
};

// Familia OP_JX
enum JxOp : uint8_t {
    JX_JMPNV  = 0,   // JMPNV addr16  (salta si V=0)
    JX_JMPLT  = 1,   // JMPLT addr16  menor con signo (N != V) -- tras CMP
    JX_JMPR   = 2,   // JMP reg16     (salta a la direccion que hay en el par)
    JX_CALLR  = 3,   // CALL reg16
    JX_JMPGE  = 4,   // JMPGE addr16  mayor o igual con signo (N == V)
    JX_JMPLE  = 5,   // JMPLE addr16  menor o igual con signo (Z o N != V)
    JX_JMPGT  = 6,   // JMPGT addr16  mayor con signo (no Z y N == V)
    // 7: libre (NOP de 1 byte)
};

// Familia OP_R16 (operando: dst16<<3 | src)
enum R16Op : uint8_t {
    R16_MOV   = 0,   // MOV dst16,src16       (sin flags)
    R16_ADD   = 1,   // ADD dst16,src16       (sin flags)
    R16_SUB   = 2,   // SUB dst16,src16       (sin flags)
    R16_CMP   = 3,   // CMP dst16,src16       (flags de dst-src en 16 bits)
    R16_ADD8  = 4,   // ADD dst16,src8        (sin flags, src8 sin signo)
    R16_SUB8  = 5,   // SUB dst16,src8        (sin flags)
};

// Familia OP_R16I (byte 1: r16 en los 2 bits bajos)
enum R16IOp : uint8_t {
    R16I_MOV  = 0,   // MOV r16,#imm16   LEN 4 (sin flags)
    R16I_ADD  = 1,   // ADD r16,#imm8    LEN 3 (sin flags)
    R16I_SUB  = 2,   // SUB r16,#imm8    LEN 3 (sin flags)
    R16I_CMP  = 3,   // CMP r16,#imm16   LEN 4 (flags de r16-imm16)
};

// Condiciones (3 bits bajos de JMP/CALL); NV va aparte, en OP_JX
enum JumpCond : uint8_t {
    JC_ALWAYS = 0,
    JC_Z      = 1,
    JC_NZ     = 2,
    JC_C      = 3,
    JC_NC     = 4,
    JC_N      = 5,
    JC_NN     = 6,
    JC_V      = 7,
};

// Operaciones de la ALU de 8 bits (byte de operando de OP_ALU*)
enum AluOp : uint8_t {
    ALU_MOV = 0,  // dst = src                     (sin flags)
    ALU_ADD = 1,  // dst = dst + src
    ALU_ADC = 2,  // dst = dst + src + C           (sumas de varios bytes)
    ALU_SUB = 3,  // dst = dst - src
    ALU_SBC = 4,  // dst = dst - src - C (C = prestamo)
    ALU_CMP = 5,  // flags de dst - src; dst no cambia
    ALU_AND = 6,
    ALU_OR  = 7,
    ALU_XOR = 8,
    ALU_COUNT = 9,
};

enum FlagBit : uint8_t {
    FLAG_C = 1 << 0,
    FLAG_Z = 1 << 1,
    FLAG_N = 1 << 2,
    FLAG_V = 1 << 3,
};

inline uint8_t makeOpcode(uint8_t family, uint8_t low3) {
    return (uint8_t)((family << 3) | (low3 & 0x07));
}
inline uint8_t opFamily(uint8_t opcode) { return opcode >> 3; }
inline uint8_t opReg(uint8_t opcode)    { return opcode & 0x07; }

} // namespace compi
