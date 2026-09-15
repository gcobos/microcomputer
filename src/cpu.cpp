#include "cpu.h"
#include <string.h>

namespace compi {

uint8_t Registers::get8(uint8_t reg) const {
    switch (reg) {
        case REG_AL: return AX & 0xFF;
        case REG_AH: return (AX >> 8) & 0xFF;
        case REG_BL: return BX & 0xFF;
        case REG_BH: return (BX >> 8) & 0xFF;
        case REG_CL: return CX & 0xFF;
        case REG_CH: return (CX >> 8) & 0xFF;
        case REG_DL: return DX & 0xFF;
        case REG_DH: return (DX >> 8) & 0xFF;
        default: return 0;
    }
}

void Registers::set8(uint8_t reg, uint8_t value) {
    switch (reg) {
        case REG_AL: AX = (uint16_t)((AX & 0xFF00) | value); break;
        case REG_AH: AX = (uint16_t)((AX & 0x00FF) | (value << 8)); break;
        case REG_BL: BX = (uint16_t)((BX & 0xFF00) | value); break;
        case REG_BH: BX = (uint16_t)((BX & 0x00FF) | (value << 8)); break;
        case REG_CL: CX = (uint16_t)((CX & 0xFF00) | value); break;
        case REG_CH: CX = (uint16_t)((CX & 0x00FF) | (value << 8)); break;
        case REG_DL: DX = (uint16_t)((DX & 0xFF00) | value); break;
        case REG_DH: DX = (uint16_t)((DX & 0x00FF) | (value << 8)); break;
    }
}

uint16_t Registers::get16(uint8_t pairCode) const {
    switch (pairCode & 0x03) {
        case REG_AX: return AX;
        case REG_BX: return BX;
        case REG_CX: return CX;
        default:     return DX;   // REG_DX
    }
}

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
    switch (cond) {
        case JC_ALWAYS: return true;
        case JC_Z:  return z;
        case JC_NZ: return !z;
        case JC_C:  return c;
        case JC_NC: return !c;
        case JC_N:  return n;
        case JC_NN: return !n;
        default: return true;
    }
}

uint8_t Cpu::updateFlagsArith(uint8_t a, uint8_t b, bool isSub) {
    int full = isSub ? (int)a - (int)b : (int)a + (int)b;
    uint8_t result = (uint8_t)(full & 0xFF);
    bool carry = isSub ? (a < b) : (full > 0xFF);
    bool zero  = result == 0;
    bool neg   = (result & 0x80) != 0;
    bool overflow = isSub
        ? (((a ^ b) & (a ^ result) & 0x80) != 0)
        : ((~(a ^ b) & (a ^ result) & 0x80) != 0);

    flags_ = 0;
    if (carry)    flags_ |= FLAG_C;
    if (zero)     flags_ |= FLAG_Z;
    if (neg)      flags_ |= FLAG_N;
    if (overflow) flags_ |= FLAG_V;
    return result;
}

void Cpu::updateFlagsLogic(uint8_t result) {
    flags_ = 0;
    if (result == 0)      flags_ |= FLAG_Z;
    if (result & 0x80)    flags_ |= FLAG_N;
    // AND/OR/XOR/NOT no generan acarreo ni overflow: C y V quedan a 0.
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
        case OP_SHR: {
            uint8_t v = regs_.get8(r);
            bool carry = v & 0x01;
            bool originalMsb = v & 0x80;
            uint8_t result = (uint8_t)(v >> 1);
            regs_.set8(r, result);
            flags_ = 0;
            if (carry)         flags_ |= FLAG_C;
            if (result == 0)   flags_ |= FLAG_Z;
            if (result & 0x80) flags_ |= FLAG_N;
            if (originalMsb)   flags_ |= FLAG_V;
            break;
        }
        case OP_SHL: {
            uint8_t v = regs_.get8(r);
            bool carry = v & 0x80;
            uint8_t result = (uint8_t)(v << 1);
            regs_.set8(r, result);
            bool neg = result & 0x80;
            flags_ = 0;
            if (carry)        flags_ |= FLAG_C;
            if (result == 0)  flags_ |= FLAG_Z;
            if (neg)          flags_ |= FLAG_N;
            if (carry != neg) flags_ |= FLAG_V;
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
        default:
            // Familias 21-30: reservadas, se comportan como NOP por ahora.
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
