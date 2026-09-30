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
    switch (op) {
        case ALU_MOV: return "MOV";  case ALU_ADD: return "ADD";
        case ALU_SUB: return "SUB";  case ALU_CMP: return "CMP";
        case ALU_AND: return "AND";  case ALU_OR:  return "OR";
        case ALU_XOR: return "XOR";  default:      return "?";
    }
}
} // namespace

uint8_t instrLen(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    uint8_t op0 = rd(mem, memLen, addr);
    switch (opFamily(op0)) {
        case OP_LDI: case OP_EXT:
        case OP_LDAR: case OP_STAR: case OP_INR: case OP_OUTR:
        case OP_SHRN: case OP_SHLN:
            return 2;
        case OP_LDA: case OP_STA: case OP_ADD: case OP_SUB:
        case OP_AND: case OP_OR:  case OP_XOR:
        case OP_IN:  case OP_OUT:
        case OP_JMP: case OP_CALL: case OP_ALUI:
            return 3;
        // OP_MUL/OP_DIV/OP_INCDEC16 son LEN 1 -- caen al "default" de abajo.
        case OP_EXT2: {
            // Unica familia que mezcla longitudes (documentado en isa.h):
            // subop 0-1 (ADD/SUB dst16,src8) LEN2; 2-3 (MOVB/MOVW) LEN1;
            // 4-5 (JMPNV/CALLNV) LEN3; 6 (MOV reg16,#imm16) LEN4; 7
            // (reservado) LEN1.
            uint8_t sub = opReg(op0);
            if (sub <= 1) return 2;
            if (sub <= 3) return 1;
            if (sub <= 5) return 3;
            if (sub == 6) return 4;
            return 1;
        }
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
    uint8_t b3  = rd(mem, memLen, (uint16_t)(addr + 3));
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
        case OP_SHRN: snprintf(out, n, "SHR %s,#%d", regName8(r), (b1 & 7) + 1); return 2;
        case OP_SHLN: snprintf(out, n, "SHL %s,#%d", regName8(r), (b1 & 7) + 1); return 2;
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
        case OP_MUL: snprintf(out, n, "MUL %s", regName8(r)); return 1;
        case OP_DIV: snprintf(out, n, "DIV %s", regName8(r)); return 1;
        case OP_INCDEC16: {
            bool dec = (r & 0x04) != 0;
            snprintf(out, n, "%s %s", dec ? "DEC" : "INC", regName16((uint8_t)(r & 3)));
            return 1;
        }
        case OP_EXT2: {
            switch (r) {
                case 0: snprintf(out, n, "ADD %s,%s", regName16((uint8_t)((b1 >> 3) & 3)), regName8((uint8_t)(b1 & 7))); return 2;
                case 1: snprintf(out, n, "SUB %s,%s", regName16((uint8_t)((b1 >> 3) & 3)), regName8((uint8_t)(b1 & 7))); return 2;
                case 2: snprintf(out, n, "MOVB"); return 1;
                case 3: snprintf(out, n, "MOVW"); return 1;
                case 4: snprintf(out, n, "JMPNV 0x%04X", a16); return 3;
                case 5: snprintf(out, n, "CALLNV 0x%04X", a16); return 3;
                case 6: {
                    uint16_t imm16 = (uint16_t)(b2 | (b3 << 8));
                    snprintf(out, n, "MOV %s,#0x%04X", regName16((uint8_t)(b1 & 3)), imm16);
                    return 4;
                }
                default: snprintf(out, n, "DB 0x%02X", op); return 1;
            }
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
