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
        case JC_V:  return "V";
        default:    return "?";
    }
}
const char* aluName(uint8_t op) {
    static const char* const N[ALU_COUNT] = {
        "MOV", "ADD", "ADC", "SUB", "SBC", "CMP", "AND", "OR", "XOR",
    };
    return (op < ALU_COUNT) ? N[op] : "?";
}
} // namespace

uint8_t instrLen(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    uint8_t op0 = rd(mem, memLen, addr);
    uint8_t r = opReg(op0);
    switch (opFamily(op0)) {
        case OP_LDI: case OP_LDAR: case OP_STAR: case OP_INR: case OP_OUTR:
        case OP_ALURR: case OP_ALUP: case OP_SHR: case OP_SHL:
            return 2;
        case OP_LDA: case OP_STA: case OP_IN: case OP_OUT:
        case OP_ALUI: case OP_JMP: case OP_CALL:
            return 3;
        case OP_ALUM:
            return 4;
        case OP_JX:
            if (r == JX_JMPNV || r == JX_CALLNV) return 3;
            if (r == JX_JMPR || r == JX_CALLR) return 2;
            return 1;
        case OP_R16:
            return (r <= R16_SUB8) ? 2 : 1;
        case OP_R16I:
            if (r == R16I_MOV || r == R16I_CMP) return 4;
            if (r == R16I_ADD || r == R16I_SUB) return 3;
            return 1;
        default:
            return 1;   // SYS, NOT, MUL, DIV, INC, DEC, PUSH, POP, 16 bits de 1 byte, libres
    }
}

uint8_t disassemble(const uint8_t* mem, uint32_t memLen, uint16_t addr,
                    char* out, size_t n) {
    uint8_t op  = rd(mem, memLen, addr);
    uint8_t fam = opFamily(op);
    uint8_t r   = opReg(op);
    uint8_t b1  = rd(mem, memLen, (uint16_t)(addr + 1));
    uint8_t b2  = rd(mem, memLen, (uint16_t)(addr + 2));
    uint8_t b3  = rd(mem, memLen, (uint16_t)(addr + 3));
    uint16_t a16 = (uint16_t)(b1 | (b2 << 8));
    uint16_t a16b = (uint16_t)(b2 | (b3 << 8));

    switch (fam) {
        case OP_SYS: {
            static const char* const S[8] = {"NOP", "HALT", "RET", "MOVB", "MOVW", "MOVBR", "DB 0x06", "DB 0x07"};
            snprintf(out, n, "%s", S[r]);
            return 1;
        }
        case OP_LDI:  snprintf(out, n, "MOV %s,#0x%02X", regName8(r), b1);   return 2;
        case OP_LDA:  snprintf(out, n, "LDA %s,[0x%04X]", regName8(r), a16); return 3;
        case OP_STA:  snprintf(out, n, "STA [0x%04X],%s", a16, regName8(r)); return 3;
        case OP_LDAR: snprintf(out, n, "LDA %s,[%s]", regName8(r), regName16(b1)); return 2;
        case OP_STAR: snprintf(out, n, "STA [%s],%s", regName16(b1), regName8(r)); return 2;
        case OP_IN:   snprintf(out, n, "IN %s,(0x%04X)",  regName8(r), a16); return 3;
        case OP_OUT:  snprintf(out, n, "OUT (0x%04X),%s", a16, regName8(r)); return 3;
        case OP_INR:  snprintf(out, n, "IN %s,(%s)",  regName8(r), regName16(b1)); return 2;
        case OP_OUTR: snprintf(out, n, "OUT (%s),%s", regName16(b1), regName8(r)); return 2;
        case OP_ALURR: snprintf(out, n, "%s %s,%s", aluName((uint8_t)(b1 >> 3)), regName8(r), regName8(b1)); return 2;
        case OP_ALUI:  snprintf(out, n, "%s %s,#0x%02X", aluName(b1), regName8(r), b2); return 3;
        case OP_ALUM:  snprintf(out, n, "%s %s,[0x%04X]", aluName(b1), regName8(r), a16b); return 4;
        case OP_ALUP:  snprintf(out, n, "%s %s,[%s]", aluName((uint8_t)(b1 >> 2)), regName8(r), regName16(b1)); return 2;
        case OP_NOT:  snprintf(out, n, "NOT %s", regName8(r)); return 1;
        case OP_SHR:  snprintf(out, n, "SHR %s,#%d", regName8(r), (b1 & 7) + 1); return 2;
        case OP_SHL:  snprintf(out, n, "SHL %s,#%d", regName8(r), (b1 & 7) + 1); return 2;
        case OP_MUL:  snprintf(out, n, "MUL %s", regName8(r)); return 1;
        case OP_DIV:  snprintf(out, n, "DIV %s", regName8(r)); return 1;
        case OP_INC:  snprintf(out, n, "INC %s", regName8(r)); return 1;
        case OP_DEC:  snprintf(out, n, "DEC %s", regName8(r)); return 1;
        case OP_PUSH: snprintf(out, n, "PUSH %s", regName8(r)); return 1;
        case OP_POP:  snprintf(out, n, "POP %s",  regName8(r)); return 1;
        case OP_JMP:  snprintf(out, n, "JMP%s 0x%04X",  condSuffix(r), a16); return 3;
        case OP_CALL: snprintf(out, n, "CALL%s 0x%04X", condSuffix(r), a16); return 3;
        case OP_JX:
            switch (r) {
                case JX_JMPNV:  snprintf(out, n, "JMPNV 0x%04X", a16);  return 3;
                case JX_CALLNV: snprintf(out, n, "CALLNV 0x%04X", a16); return 3;
                case JX_JMPR:   snprintf(out, n, "JMP %s", regName16(b1));  return 2;
                case JX_CALLR:  snprintf(out, n, "CALL %s", regName16(b1)); return 2;
                default: snprintf(out, n, "DB 0x%02X", op); return 1;
            }
        case OP_R16: {
            const char* d = regName16((uint8_t)(b1 >> 3));
            switch (r) {
                case R16_MOV:  snprintf(out, n, "MOV %s,%s", d, regName16(b1)); return 2;
                case R16_ADD:  snprintf(out, n, "ADD %s,%s", d, regName16(b1)); return 2;
                case R16_SUB:  snprintf(out, n, "SUB %s,%s", d, regName16(b1)); return 2;
                case R16_CMP:  snprintf(out, n, "CMP %s,%s", d, regName16(b1)); return 2;
                case R16_ADD8: snprintf(out, n, "ADD %s,%s", d, regName8(b1));  return 2;
                case R16_SUB8: snprintf(out, n, "SUB %s,%s", d, regName8(b1));  return 2;
                default: snprintf(out, n, "DB 0x%02X", op); return 1;
            }
        }
        case OP_R16I: {
            const char* d = regName16(b1);
            switch (r) {
                case R16I_MOV: snprintf(out, n, "MOV %s,#0x%04X", d, a16b); return 4;
                case R16I_ADD: snprintf(out, n, "ADD %s,#0x%02X", d, b2);   return 3;
                case R16I_SUB: snprintf(out, n, "SUB %s,#0x%02X", d, b2);   return 3;
                case R16I_CMP: snprintf(out, n, "CMP %s,#0x%04X", d, a16b); return 4;
                default: snprintf(out, n, "DB 0x%02X", op); return 1;
            }
        }
        case OP_INCDEC16:
            snprintf(out, n, "%s %s", (r & 0x04) ? "DEC" : "INC", regName16(r));
            return 1;
        case OP_PUSHPOP16:
            snprintf(out, n, "%s %s", (r & 0x04) ? "POP" : "PUSH", regName16(r));
            return 1;
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

uint16_t prevInstrStart(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    if (addr == 0) return 0;
    uint16_t p = 0, prev = 0;
    while (p < addr) {
        prev = p;
        uint16_t next = (uint16_t)(p + instrLen(mem, memLen, p));
        if (next <= p) break;   // misma salvaguarda que listBase (longitud 0)
        p = next;
    }
    return prev;
}

} // namespace compi
