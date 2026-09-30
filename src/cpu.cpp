#include "cpu.h"
#include <string.h>

namespace compi {

Cpu::Cpu() {
    memset(memory_, 0, sizeof(memory_));
    reset();
}

void Cpu::clearMemory() {
    memset(memory_, 0, sizeof(memory_));
}

void Cpu::fillMem(uint16_t addr, uint16_t len, uint8_t value) {
    for (uint16_t i = 0; i < len; ++i) {
        memory_[maskAddr((uint16_t)(addr + i))] = value;
    }
}

void Cpu::reset() {
    regs_ = Registers{};
    pc_ = 0;
    sp_ = 0xFFFF;
    flags_ = 0;
    halted_ = false;
}

void Cpu::loadBytes(uint16_t addr, const uint8_t* data, uint16_t len) {
    for (uint16_t i = 0; i < len; ++i) {
        memory_[maskAddr((uint16_t)(addr + i))] = data[i];
    }
}

void Cpu::dumpBytes(uint16_t addr, uint8_t* buffer, uint16_t len) const {
    for (uint16_t i = 0; i < len; ++i) {
        buffer[i] = memory_[maskAddr((uint16_t)(addr + i))];
    }
}

uint8_t Cpu::fetch8() {
    uint8_t v = memory_[maskAddr(pc_)];
    ++pc_;
    return v;
}

uint16_t Cpu::fetch16() {
    uint8_t lo = fetch8();
    uint8_t hi = fetch8();
    return (uint16_t)(lo | (hi << 8));
}

void Cpu::push8(uint8_t v) { --sp_; memory_[maskAddr(sp_)] = v; }
uint8_t Cpu::pop8() { uint8_t v = memory_[maskAddr(sp_)]; ++sp_; return v; }

bool Cpu::testCond(uint8_t cond) const {
    bool z = flags_ & FLAG_Z;
    bool c = flags_ & FLAG_C;
    bool n = flags_ & FLAG_N;
    bool v = flags_ & FLAG_V;
    switch (cond) {
        case JC_ALWAYS: return true;
        case JC_Z:  return z;
        case JC_NZ: return !z;
        case JC_C:  return c;
        case JC_NC: return !c;
        case JC_N:  return n;
        case JC_NN: return !n;
        case JC_V:  return v;
        default: return true;
    }
}

// Version sin ramas: cada flag (0/1) se desplaza directamente a su bit y se
// combina con OR, en vez de una cadena de "if (cond) flags_ |= BIT". Un
// salto condicional cuesta ciclos de pipeline en el RV32IMC del ESP32-C3;
// esto se ejecuta en CADA instruccion ADD/SUB/CMP.
uint8_t Cpu::updateFlagsArith(uint8_t a, uint8_t b, bool isSub) {
    int full = isSub ? (int)a - (int)b : (int)a + (int)b;
    uint8_t result = (uint8_t)(full & 0xFF);
    uint8_t carry = isSub ? (a < b) : (full > 0xFF);
    uint8_t zero  = (result == 0);
    uint8_t neg   = (result & 0x80) != 0;
    uint8_t overflow = isSub
        ? (((a ^ b) & (a ^ result) & 0x80) != 0)
        : ((~(a ^ b) & (a ^ result) & 0x80) != 0);

    flags_ = (uint8_t)(carry | (zero << 1) | (neg << 2) | (overflow << 3));
    return result;
}

void Cpu::updateFlagsLogic(uint8_t result) {
    // AND/OR/XOR/NOT no generan acarreo ni overflow: C y V quedan a 0.
    uint8_t zero = (result == 0);
    uint8_t neg  = (result & 0x80) != 0;
    flags_ = (uint8_t)((zero << 1) | (neg << 2));
}

void Cpu::doShr(uint8_t reg, uint8_t n) {
    uint32_t v = regs_.get8(reg);
    uint8_t originalMsb = (v & 0x80) != 0;
    // v cabe en 32 bits, asi que desplazar hasta 8 posiciones nunca es
    // comportamiento indefinido (a diferencia de desplazar un uint8_t).
    uint8_t result = (uint8_t)(v >> n);
    uint8_t carry = (uint8_t)((v >> (n - 1)) & 1);
    regs_.set8(reg, result);
    uint8_t zero = (result == 0);
    uint8_t neg  = (result & 0x80) != 0;
    flags_ = (uint8_t)(carry | (zero << 1) | (neg << 2) | (originalMsb << 3));
}

void Cpu::doShl(uint8_t reg, uint8_t n) {
    uint32_t v = regs_.get8(reg);
    uint8_t result = (uint8_t)((v << n) & 0xFF);
    uint8_t carry = (uint8_t)((v >> (8 - n)) & 1);
    regs_.set8(reg, result);
    uint8_t zero = (result == 0);
    uint8_t neg  = (result & 0x80) != 0;
    uint8_t overflow = (carry != neg);
    flags_ = (uint8_t)(carry | (zero << 1) | (neg << 2) | (overflow << 3));
}

// MUL reg: AX = AL * reg, sin signo (8x8->16, nunca desborda 16 bits).
// Flags: Z/N del resultado de 16 bits completo; C=V=1 si el producto no
// cupo en 8 bits (AH != 0) -- asi "JMPV tras un MUL" es literalmente "hizo
// falta el byte alto". Los dos operandos se leen ANTES de escribir AX, asi
// que `reg` puede ser AL o AH sin problema (p.ej. "MUL AL" = AL*AL).
void Cpu::doMul(uint8_t reg) {
    uint16_t product = (uint16_t)((uint16_t)regs_.get8(REG_AL) * (uint16_t)regs_.get8(reg));
    regs_.set16(REG_AX, product);
    uint8_t hi   = (product > 0xFF);
    uint8_t zero = (product == 0);
    uint8_t neg  = (product & 0x8000) != 0;
    flags_ = (uint8_t)(hi | (zero << 1) | (neg << 2) | (hi << 3));
}

// DIV reg: AL = AX/reg (cociente), AH = AX%reg (resto), sin signo. Sin
// trampas/excepciones (esta CPU no tiene interrupciones): division entre 0
// O cociente que no cabe en un byte (AX/reg > 255) saturan AL=AH=0xFF con
// C=V=1 -- un solo camino de saturacion para los dos casos, asi "JMPV tras
// un DIV" es "esto no ha dado un resultado valido de 8 bits", sin tener
// que comprobar el divisor a mano antes. Con resultado valido: C=V=0,
// Z/N del cociente (AL).
void Cpu::doDiv(uint8_t reg) {
    uint16_t ax = regs_.get16(REG_AX);
    uint8_t divisor = regs_.get8(reg);
    if (divisor != 0) {
        uint16_t q = (uint16_t)(ax / divisor);
        if (q <= 0xFF) {
            uint8_t al = (uint8_t)q;
            uint8_t ah = (uint8_t)(ax % divisor);
            regs_.set8(REG_AL, al);
            regs_.set8(REG_AH, ah);
            uint8_t zero = (al == 0);
            uint8_t neg  = (al & 0x80) != 0;
            flags_ = (uint8_t)((zero << 1) | (neg << 2));
            return;
        }
    }
    regs_.set8(REG_AL, 0xFF);
    regs_.set8(REG_AH, 0xFF);
    flags_ = (uint8_t)(FLAG_C | FLAG_V | FLAG_N);   // AL=0xFF -> Z=0, N=1
}

// MOVB/MOVW (OP_EXT2 subop 2/3): copia de [BX] a [DX], CX bytes (MOVB) o
// CX palabras de 16 bits (MOVW, o sea 2*CX bytes) -- registros implicitos,
// sin operando en el opcode. Copia siempre hacia adelante (como REP MOVSB
// de x86 o LDIR del Z80): si los rangos [BX..) y [DX..) se solapan con
// dst<src, el resultado puede no ser el de un memmove seguro -- limitacion
// deliberada, no es el caso de uso pensado (blits/descompresion/tablas).
// Al terminar: BX/DX avanzan el numero de bytes copiados, CX queda a 0. No
// toca flags (es movimiento de datos, no aritmetica -- ver isa.md).
void Cpu::doMovBlock(bool asWords) {
    uint16_t src = regs_.get16(REG_BX);
    uint16_t dst = regs_.get16(REG_DX);
    uint16_t count = regs_.get16(REG_CX);
    uint16_t bytes = asWords ? (uint16_t)(count * 2) : count;
    for (uint16_t i = 0; i < bytes; ++i) {
        memory_[maskAddr((uint16_t)(dst + i))] = memory_[maskAddr((uint16_t)(src + i))];
    }
    regs_.set16(REG_BX, (uint16_t)(src + bytes));
    regs_.set16(REG_DX, (uint16_t)(dst + bytes));
    regs_.set16(REG_CX, 0);
}

uint8_t Cpu::aluOp(uint8_t op, uint8_t a, uint8_t b) {
    switch (op) {
        case ALU_MOV: return b;                             // no toca flags
        case ALU_ADD: return updateFlagsArith(a, b, false);
        case ALU_SUB: return updateFlagsArith(a, b, true);
        case ALU_CMP: updateFlagsArith(a, b, true); return a; // dst no cambia
        case ALU_AND: { uint8_t r = (uint8_t)(a & b); updateFlagsLogic(r); return r; }
        case ALU_OR:  { uint8_t r = (uint8_t)(a | b); updateFlagsLogic(r); return r; }
        case ALU_XOR: { uint8_t r = (uint8_t)(a ^ b); updateFlagsLogic(r); return r; }
        default:      return a;
    }
}

bool Cpu::step() {
    if (halted_) return false;

    uint8_t opcode = fetch8();
    uint8_t family = opFamily(opcode);
    uint8_t r = opReg(opcode);

    switch (family) {
        case OP_NOP:
            break;
        case OP_HALT:
            halted_ = true;
            break;
        case OP_LDI: {
            uint8_t imm = fetch8();
            regs_.set8(r, imm);
            break;
        }
        case OP_LDA: {
            uint16_t addr = fetch16();
            regs_.set8(r, memory_[maskAddr(addr)]);
            break;
        }
        case OP_STA: {
            uint16_t addr = fetch16();
            memory_[maskAddr(addr)] = regs_.get8(r);
            break;
        }
        case OP_ADD: case OP_SUB: case OP_AND: case OP_OR: case OP_XOR: {
            // <op> reg, [addr16]  ->  reg = reg <op> mem[addr]
            uint8_t alu = (family == OP_ADD) ? ALU_ADD
                        : (family == OP_SUB) ? ALU_SUB
                        : (family == OP_AND) ? ALU_AND
                        : (family == OP_OR)  ? ALU_OR : ALU_XOR;
            uint16_t addr = fetch16();
            regs_.set8(r, aluOp(alu, regs_.get8(r), memory_[maskAddr(addr)]));
            break;
        }
        case OP_NOT: {
            uint8_t result = (uint8_t)(~regs_.get8(r));
            regs_.set8(r, result);
            updateFlagsLogic(result);
            break;
        }
        case OP_SHR:
            doShr(r, 1);
            break;
        case OP_SHL:
            doShl(r, 1);
            break;
        case OP_SHRN: {
            uint8_t n = (uint8_t)((fetch8() & 0x07) + 1);
            doShr(r, n);
            break;
        }
        case OP_SHLN: {
            uint8_t n = (uint8_t)((fetch8() & 0x07) + 1);
            doShl(r, n);
            break;
        }
        case OP_IN: {
            uint16_t port = fetch16();
            uint8_t value = portRead_ ? portRead_(port) : 0;
            regs_.set8(r, value);
            break;
        }
        case OP_OUT: {
            uint16_t port = fetch16();
            if (portWrite_) portWrite_(port, regs_.get8(r));
            break;
        }
        case OP_LDAR: {
            uint16_t addr = regs_.get16(fetch8());
            regs_.set8(r, memory_[maskAddr(addr)]);
            break;
        }
        case OP_STAR: {
            uint16_t addr = regs_.get16(fetch8());
            memory_[maskAddr(addr)] = regs_.get8(r);
            break;
        }
        case OP_INR: {
            uint16_t port = regs_.get16(fetch8());
            uint8_t value = portRead_ ? portRead_(port) : 0;
            regs_.set8(r, value);
            break;
        }
        case OP_OUTR: {
            uint16_t port = regs_.get16(fetch8());
            if (portWrite_) portWrite_(port, regs_.get8(r));
            break;
        }
        case OP_PUSH:
            push8(regs_.get8(r));
            break;
        case OP_POP:
            regs_.set8(r, pop8());
            break;
        case OP_JMP: {
            uint16_t addr = fetch16();
            if (testCond(r)) pc_ = addr;
            break;
        }
        case OP_CALL: {
            uint16_t addr = fetch16();
            if (testCond(r)) {
                push8((pc_ >> 8) & 0xFF);
                push8(pc_ & 0xFF);
                pc_ = addr;
            }
            break;
        }
        case OP_RET: {
            uint8_t lo = pop8();
            uint8_t hi = pop8();
            pc_ = (uint16_t)(lo | (hi << 8));
            break;
        }
        case OP_EXT: {
            // <op> dst, src   (op = r ; operando: [--|dst:3|src:3])
            uint8_t operand = fetch8();
            uint8_t dst = (uint8_t)((operand >> 3) & 0x07);
            uint8_t src = (uint8_t)(operand & 0x07);
            regs_.set8(dst, aluOp(r, regs_.get8(dst), regs_.get8(src)));
            break;
        }
        case OP_ALUI: {
            // <op> reg, #imm8   (op = r ; operando: reg, imm8)
            uint8_t dst = (uint8_t)(fetch8() & 0x07);
            uint8_t imm = fetch8();
            regs_.set8(dst, aluOp(r, regs_.get8(dst), imm));
            break;
        }
        case OP_MUL:
            doMul(r);
            break;
        case OP_DIV:
            doDiv(r);
            break;
        case OP_INCDEC16: {
            // opcode = dir<<2 | reg16 (dir 0=INC 1=DEC) -- ver isa.h
            uint8_t reg16 = (uint8_t)(r & 0x03);
            bool dec = (r & 0x04) != 0;
            uint16_t v = regs_.get16(reg16);
            regs_.set16(reg16, (uint16_t)(dec ? v - 1 : v + 1));
            break;
        }
        case OP_EXT2: {
            // subop en los 3 bits bajos del opcode (r) -- ver isa.h
            switch (r) {
                case 0: case 1: {
                    // ADD/SUB dst16,src8 : operando = (dst16<<3)|src8
                    uint8_t operand = fetch8();
                    uint8_t dst16 = (uint8_t)((operand >> 3) & 0x03);
                    uint8_t src8  = (uint8_t)(operand & 0x07);
                    uint16_t v = regs_.get16(dst16);
                    uint16_t ext = regs_.get8(src8);
                    regs_.set16(dst16, (uint16_t)(r == 0 ? v + ext : v - ext));
                    break;
                }
                case 2:
                    doMovBlock(false);   // MOVB
                    break;
                case 3:
                    doMovBlock(true);    // MOVW
                    break;
                case 4: {
                    // JMPNV addr16 : salta si V=0
                    uint16_t addr = fetch16();
                    if (!(flags_ & FLAG_V)) pc_ = addr;
                    break;
                }
                case 5: {
                    // CALLNV addr16 : llama si V=0
                    uint16_t addr = fetch16();
                    if (!(flags_ & FLAG_V)) {
                        push8((pc_ >> 8) & 0xFF);
                        push8(pc_ & 0xFF);
                        pc_ = addr;
                    }
                    break;
                }
                case 6: {
                    // MOV reg16,#imm16 : unica instruccion de LEN 4 de toda
                    // la ISA. No toca flags (mismo criterio que LDI/MOV).
                    uint8_t pair = (uint8_t)(fetch8() & 0x03);
                    uint16_t imm = fetch16();
                    regs_.set16(pair, imm);
                    break;
                }
                default:
                    // subop 7: reservado, se comporta como NOP.
                    break;
            }
            break;
        }
        default:
            // Sin familias reservadas por ahora: 27-30 ya se usan arriba.
            break;
    }
    return !halted_;
}

void Cpu::run(int32_t maxSteps) {
    int32_t count = 0;
    while (!halted_ && (maxSteps < 0 || count < maxSteps)) {
        step();
        ++count;
    }
}

} // namespace compi
