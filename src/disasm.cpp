#include "disasm.h"
#include "isa.h"
#include <stdio.h>

namespace compi {

const char* regName8(uint8_t reg) {
    static const char* const N[8] = {"AL","AH","BL","BH","CL","CH","DL","DH"};
    return N[reg & 7];
}

const char* regName16(uint8_t pairCode) {
    static const char* const N[4] = {"AX","BX","CX","DX"};
    return N[pairCode & 3];
}

namespace {
inline uint8_t rd(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    return (addr < memLen) ? mem[addr] : 0;
}
const char* condSuffix(uint8_t c) {
    switch (c) {
        case JC_ALWAYS: return "";
        case JC_Z:  return "Z";   case JC_NZ: return "NZ";
        case JC_C:  return "C";   case JC_NC: return "NC";
        case JC_N:  return "N";   case JC_NN: return "NN";
        default:    return "?";
    }
}
const char* aluName(uint8_t op) {
    switch (op) {
        case ALU_MOV: return "MOV";  case ALU_ADD: return "ADD";
        case ALU_SUB: return "SUB";  case ALU_CMP: return "CMP";
        case ALU_AND: return "AND";  case ALU_OR:  return "OR";
        case ALU_XOR: return "XOR";  default:      return "?";
    }
}
} // namespace

uint8_t instrLen(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    switch (opFamily(rd(mem, memLen, addr))) {
        case OP_LDI: case OP_EXT:
        case OP_LDAR: case OP_STAR: case OP_INR: case OP_OUTR:
            return 2;
        case OP_LDA: case OP_STA: case OP_ADD: case OP_SUB:
        case OP_AND: case OP_OR:  case OP_XOR:
        case OP_IN:  case OP_OUT:
        case OP_JMP: case OP_CALL: case OP_ALUI:
            return 3;
        default:
            return 1;
    }
}

uint8_t disassemble(const uint8_t* mem, uint32_t memLen, uint16_t addr,
                    char* out, size_t n) {
    uint8_t op  = rd(mem, memLen, addr);
    uint8_t fam = opFamily(op);
    uint8_t r   = opReg(op);
    uint8_t b1  = rd(mem, memLen, (uint16_t)(addr + 1));
    uint8_t b2  = rd(mem, memLen, (uint16_t)(addr + 2));
    uint16_t a16 = (uint16_t)(b1 | (b2 << 8));

    switch (fam) {
        case OP_NOP:  snprintf(out, n, "NOP");  return 1;
        case OP_HALT: snprintf(out, n, "HALT"); return 1;
        case OP_LDI:  snprintf(out, n, "MOV %s,#0x%02X", regName8(r), b1);   return 2;
        case OP_LDA:  snprintf(out, n, "LDA %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_STA:  snprintf(out, n, "STA [0x%04X],%s", a16, regName8(r)); return 3;
        case OP_ADD:  snprintf(out, n, "ADD %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_SUB:  snprintf(out, n, "SUB %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_AND:  snprintf(out, n, "AND %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_OR:   snprintf(out, n, "OR %s,[0x%04X]",  regName8(r), a16); return 3;
        case OP_XOR:  snprintf(out, n, "XOR %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_NOT:  snprintf(out, n, "NOT %s",  regName8(r)); return 1;
        case OP_SHR:  snprintf(out, n, "SHR %s",  regName8(r)); return 1;
        case OP_SHL:  snprintf(out, n, "SHL %s",  regName8(r)); return 1;
        case OP_IN:   snprintf(out, n, "IN %s,(0x%04X)",  regName8(r), a16); return 3;
        case OP_OUT:  snprintf(out, n, "OUT (0x%04X),%s", a16, regName8(r)); return 3;
        case OP_LDAR: snprintf(out, n, "LDA %s,[%s]", regName8(r), regName16(b1)); return 2;
        case OP_STAR: snprintf(out, n, "STA [%s],%s", regName16(b1), regName8(r)); return 2;
        case OP_INR:  snprintf(out, n, "IN %s,(%s)",  regName8(r), regName16(b1)); return 2;
        case OP_OUTR: snprintf(out, n, "OUT (%s),%s", regName16(b1), regName8(r)); return 2;
        case OP_PUSH: snprintf(out, n, "PUSH %s", regName8(r)); return 1;
        case OP_POP:  snprintf(out, n, "POP %s",  regName8(r)); return 1;
        case OP_JMP:  snprintf(out, n, "JMP%s 0x%04X",  condSuffix(r), a16); return 3;
        case OP_CALL: snprintf(out, n, "CALL%s 0x%04X", condSuffix(r), a16); return 3;
        case OP_RET:  snprintf(out, n, "RET"); return 1;
        case OP_EXT: {
            uint8_t dst = (uint8_t)((b1 >> 3) & 7);
            uint8_t src = (uint8_t)(b1 & 7);
            snprintf(out, n, "%s %s,%s", aluName(r), regName8(dst), regName8(src));
            return 2;
        }
        case OP_ALUI: {
            uint8_t dst = (uint8_t)(b1 & 7);
            snprintf(out, n, "%s %s,#0x%02X", aluName(r), regName8(dst), b2);
            return 3;
        }
        default:
            snprintf(out, n, "DB 0x%02X", op);
            return 1;
    }
}

uint16_t listBase(const uint8_t* mem, uint32_t memLen, uint16_t anchor) {
    uint16_t p = 0, home = 0, ctx = 0;
    while (p < anchor) {
        ctx = home;
        home = p;
        uint16_t next = (uint16_t)(p + instrLen(mem, memLen, p));
        if (next <= p) break;
        p = next;
    }
    return ctx;
}

} // namespace compi
