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
// esto se ejecuta en CADA instruccion ADD/SUB/CMP. `cin` es el acarreo (o
// prestamo) de entrada: 0 para ADD/SUB/CMP, el bit C para ADC/SBC.
uint8_t Cpu::updateFlagsArith(uint8_t a, uint8_t b, bool isSub, uint8_t cin) {
    int full = isSub ? (int)a - (int)b - (int)cin : (int)a + (int)b + (int)cin;
    uint8_t result = (uint8_t)(full & 0xFF);
    uint8_t carry = isSub ? (full < 0) : (full > 0xFF);
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

// CMP de 16 bits: flags de a - b como numeros de 16 bits (C = prestamo,
// N = bit 15, V = desbordamiento con signo). No guarda el resultado.
void Cpu::cmp16(uint16_t a, uint16_t b) {
    uint16_t result = (uint16_t)(a - b);
    uint8_t carry = (a < b);
    uint8_t zero  = (result == 0);
    uint8_t neg   = (result & 0x8000) != 0;
    uint8_t overflow = (((a ^ b) & (a ^ result) & 0x8000) != 0);
    flags_ = (uint8_t)(carry | (zero << 1) | (neg << 2) | (overflow << 3));
}

// INC/DEC de 8 bits: Z/N/V del resultado; C NO cambia (asi se puede contar
// vueltas de un bucle sin perder un acarreo pendiente, como en el Z80).
void Cpu::doIncDec8(uint8_t reg, bool dec) {
    uint8_t a = regs_.get8(reg);
    uint8_t result = (uint8_t)(dec ? a - 1 : a + 1);
    regs_.set8(reg, result);
    uint8_t zero = (result == 0);
    uint8_t neg  = (result & 0x80) != 0;
    uint8_t overflow = dec ? (a == 0x80) : (a == 0x7F);
    flags_ = (uint8_t)((flags_ & FLAG_C) | (zero << 1) | (neg << 2) | (overflow << 3));
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

// MOVB/MOVW (OP_SYS): copia de [BX] a [DX], CX bytes (MOVB) o CX palabras
// de 16 bits (MOVW, o sea 2*CX bytes) -- registros implicitos, sin operando.
// Copia hacia adelante (como REP MOVSB de x86 o LDIR del Z80): con rangos
// solapados y dst > src, el resultado no es el de un memmove -- para eso
// esta MOVBR. Al terminar: BX/DX avanzan los bytes copiados, CX queda a 0.
// No toca flags.
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

// MOVBR (OP_SYS): copia CX bytes HACIA ATRAS -- BX y DX apuntan al ULTIMO
// byte de origen y de destino, y bajan a la vez (LDDR del Z80). Es el
// memmove seguro para abrir hueco (dst > src solapados). Al terminar: BX/DX
// bajan los bytes copiados, CX = 0. No toca flags.
void Cpu::doMovBack() {
    uint16_t src = regs_.get16(REG_BX);
    uint16_t dst = regs_.get16(REG_DX);
    uint16_t count = regs_.get16(REG_CX);
    for (uint16_t i = 0; i < count; ++i) {
        memory_[maskAddr((uint16_t)(dst - i))] = memory_[maskAddr((uint16_t)(src - i))];
    }
    regs_.set16(REG_BX, (uint16_t)(src - count));
    regs_.set16(REG_DX, (uint16_t)(dst - count));
    regs_.set16(REG_CX, 0);
}

void Cpu::pushPc() {
    push8((pc_ >> 8) & 0xFF);
    push8(pc_ & 0xFF);
}

uint8_t Cpu::aluOp(uint8_t op, uint8_t a, uint8_t b) {
    switch (op) {
        case ALU_MOV: return b;                             // no toca flags
        case ALU_ADD: return updateFlagsArith(a, b, false, 0);
        case ALU_ADC: return updateFlagsArith(a, b, false, flags_ & FLAG_C);
        case ALU_SUB: return updateFlagsArith(a, b, true, 0);
        case ALU_SBC: return updateFlagsArith(a, b, true, flags_ & FLAG_C);
        case ALU_CMP: updateFlagsArith(a, b, true, 0); return a; // dst no cambia
        case ALU_AND: { uint8_t r = (uint8_t)(a & b); updateFlagsLogic(r); return r; }
        case ALU_OR:  { uint8_t r = (uint8_t)(a | b); updateFlagsLogic(r); return r; }
        case ALU_XOR: { uint8_t r = (uint8_t)(a ^ b); updateFlagsLogic(r); return r; }
        default:      return a;                             // op sin uso: no hace nada
    }
}

bool Cpu::step() {
    if (halted_) return false;

    uint8_t opcode = fetch8();
    uint8_t family = opFamily(opcode);
    uint8_t r = opReg(opcode);

    switch (family) {
        case OP_SYS:
            switch (r) {
                case SYS_HALT:  halted_ = true; break;
                case SYS_RET: {
                    uint8_t lo = pop8();
                    uint8_t hi = pop8();
                    pc_ = (uint16_t)(lo | (hi << 8));
                    break;
                }
                case SYS_MOVB:  doMovBlock(false); break;
                case SYS_MOVW:  doMovBlock(true);  break;
                case SYS_MOVBR: doMovBack();       break;
                default: break;                    // NOP y reservados
            }
            break;
        case OP_LDI:
            regs_.set8(r, fetch8());
            break;
        case OP_LDA:
            regs_.set8(r, memory_[maskAddr(fetch16())]);
            break;
        case OP_STA:
            memory_[maskAddr(fetch16())] = regs_.get8(r);
            break;
        case OP_LDAR:
            regs_.set8(r, memory_[maskAddr(regs_.get16(fetch8()))]);
            break;
        case OP_STAR:
            memory_[maskAddr(regs_.get16(fetch8()))] = regs_.get8(r);
            break;
        case OP_IN: {
            uint16_t port = fetch16();
            regs_.set8(r, portRead_ ? portRead_(port) : 0);
            break;
        }
        case OP_OUT: {
            uint16_t port = fetch16();
            if (portWrite_) portWrite_(port, regs_.get8(r));
            break;
        }
        case OP_INR: {
            uint16_t port = regs_.get16(fetch8());
            regs_.set8(r, portRead_ ? portRead_(port) : 0);
            break;
        }
        case OP_OUTR: {
            uint16_t port = regs_.get16(fetch8());
            if (portWrite_) portWrite_(port, regs_.get8(r));
            break;
        }
        case OP_ALURR: {
            uint8_t operand = fetch8();
            uint8_t src = (uint8_t)(operand & 0x07);
            regs_.set8(r, aluOp((uint8_t)(operand >> 3), regs_.get8(r), regs_.get8(src)));
            break;
        }
        case OP_ALUI: {
            uint8_t op = fetch8();
            uint8_t imm = fetch8();
            regs_.set8(r, aluOp(op, regs_.get8(r), imm));
            break;
        }
        case OP_ALUM: {
            uint8_t op = fetch8();
            uint16_t addr = fetch16();
            regs_.set8(r, aluOp(op, regs_.get8(r), memory_[maskAddr(addr)]));
            break;
        }
        case OP_ALUP: {
            uint8_t operand = fetch8();
            uint16_t addr = regs_.get16(operand & 0x03);
            regs_.set8(r, aluOp((uint8_t)(operand >> 2), regs_.get8(r), memory_[maskAddr(addr)]));
            break;
        }
        case OP_NOT: {
            uint8_t result = (uint8_t)(~regs_.get8(r));
            regs_.set8(r, result);
            updateFlagsLogic(result);
            break;
        }
        case OP_SHR:
            doShr(r, (uint8_t)((fetch8() & 0x07) + 1));
            break;
        case OP_SHL:
            doShl(r, (uint8_t)((fetch8() & 0x07) + 1));
            break;
        case OP_MUL:
            doMul(r);
            break;
        case OP_DIV:
            doDiv(r);
            break;
        case OP_INC:
            doIncDec8(r, false);
            break;
        case OP_DEC:
            doIncDec8(r, true);
            break;
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
            if (testCond(r)) { pushPc(); pc_ = addr; }
            break;
        }
        case OP_JX:
            switch (r) {
                case JX_JMPNV: {
                    uint16_t addr = fetch16();
                    if (!(flags_ & FLAG_V)) pc_ = addr;
                    break;
                }
                case JX_CALLNV: {
                    uint16_t addr = fetch16();
                    if (!(flags_ & FLAG_V)) { pushPc(); pc_ = addr; }
                    break;
                }
                case JX_JMPR:
                    pc_ = regs_.get16(fetch8());
                    break;
                case JX_CALLR: {
                    uint16_t addr = regs_.get16(fetch8());
                    pushPc();
                    pc_ = addr;
                    break;
                }
                default: break;                    // reservados: NOP de 1 byte
            }
            break;
        case OP_R16: {
            uint8_t operand = fetch8();
            uint8_t dst = (uint8_t)((operand >> 3) & 0x03);
            uint8_t src = (uint8_t)(operand & 0x07);
            uint16_t d = regs_.get16(dst);
            switch (r) {
                case R16_MOV:  regs_.set16(dst, regs_.get16(src)); break;
                case R16_ADD:  regs_.set16(dst, (uint16_t)(d + regs_.get16(src))); break;
                case R16_SUB:  regs_.set16(dst, (uint16_t)(d - regs_.get16(src))); break;
                case R16_CMP:  cmp16(d, regs_.get16(src)); break;
                case R16_ADD8: regs_.set16(dst, (uint16_t)(d + regs_.get8(src))); break;
                case R16_SUB8: regs_.set16(dst, (uint16_t)(d - regs_.get8(src))); break;
                default: break;
            }
            break;
        }
        case OP_R16I: {
            uint8_t pair = (uint8_t)(fetch8() & 0x03);
            uint16_t d = regs_.get16(pair);
            switch (r) {
                case R16I_MOV: regs_.set16(pair, fetch16()); break;
                case R16I_ADD: regs_.set16(pair, (uint16_t)(d + fetch8())); break;
                case R16I_SUB: regs_.set16(pair, (uint16_t)(d - fetch8())); break;
                case R16I_CMP: cmp16(d, fetch16()); break;
                default: break;
            }
            break;
        }
        case OP_INCDEC16: {
            uint8_t pair = (uint8_t)(r & 0x03);
            uint16_t v = regs_.get16(pair);
            regs_.set16(pair, (uint16_t)((r & 0x04) ? v - 1 : v + 1));
            break;
        }
        case OP_PUSHPOP16: {
            uint8_t pair = (uint8_t)(r & 0x03);
            if (r & 0x04) {                        // POP: bajo y luego alto
                uint8_t lo = pop8();
                uint8_t hi = pop8();
                regs_.set16(pair, (uint16_t)(lo | (hi << 8)));
            } else {                               // PUSH: alto y luego bajo
                uint16_t v = regs_.get16(pair);
                push8((uint8_t)(v >> 8));
                push8((uint8_t)(v & 0xFF));
            }
            break;
        }
        default:
            break;                                 // 30, 31: libres (NOP)
    }
    return !halted_;
}

void Cpu::run(int32_t maxSteps) {
    int32_t count = 0;
    yield_ = false;
    while (!halted_ && !yield_ && (maxSteps < 0 || count < maxSteps)) {
        step();
        ++count;
    }
}

} // namespace compi
