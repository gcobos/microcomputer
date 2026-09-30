#include "editor.h"
#include "isa.h"

namespace compi {

namespace {

inline uint8_t rd(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    return (addr < memLen) ? mem[addr] : 0;
}

// Cuántas formas tiene un verbo (0 = no aplica, siempre reg,reg por defecto).
uint8_t modeCount(uint8_t verb) {
    switch (verb) {
        // MOV gana un 3er mode (reg16,#imm16); CMP se queda en 2.
        case V_MOV: return 3;
        case V_CMP: return 2;
        case V_AND: case V_OR: case V_XOR: return 3;
        // ADD/SUB: + mode 3 = reg16,reg8 (dst16 += / -= src8, ver isa.h OP_EXT2)
        case V_ADD: case V_SUB: return 4;
        // LDA/STA/IN/OUT: 0 = [addr16] (3 bytes) ; 1 = [AX|BX|CX|DX] indirecto (2 bytes)
        case V_LDA: case V_STA: case V_IN: case V_OUT: return 2;
        // SHR/SHL: 0 = desplaza 1 bit (1 byte) ; 1 = reg,#N, N=1..8 (2 bytes)
        case V_SHR: case V_SHL: return 2;
        default: return 0;
    }
}

// Campos de operando (sin contar Verb/Mode), hasta 3. Devuelve cuántos.
uint8_t operandFields(uint8_t verb, uint8_t mode, EField out[3]) {
    switch (verb) {
        case V_NOP: case V_HALT: case V_RET:
            return 0;
        case V_NOT: case V_PUSH: case V_POP:
            out[0] = EField::Reg;
            return 1;
        case V_SHR: case V_SHL:
            out[0] = EField::Reg;
            if (mode == 1) { out[1] = EField::Shift; return 2; }
            return 1;
        case V_LDA: case V_IN:
            if (mode == 1) { out[0] = EField::Reg; out[1] = EField::Ptr; return 2; }
            out[0] = EField::Reg; out[1] = EField::Lo; out[2] = EField::Hi;
            return 3;
        case V_STA: case V_OUT:
            // Destino primero, igual que en pantalla (STA [dir],reg / OUT (puerto),reg):
            // se teclea la dirección/puerto antes que el registro.
            if (mode == 1) { out[0] = EField::Ptr; out[1] = EField::Reg; return 2; }
            out[0] = EField::Lo; out[1] = EField::Hi; out[2] = EField::Reg;
            return 3;
        case V_JMP: case V_CALL:
            out[0] = EField::Cond; out[1] = EField::Lo; out[2] = EField::Hi;
            return 3;
        case V_MOV:
            if (mode == 0) { out[0] = EField::Dst; out[1] = EField::Src; return 2; }
            if (mode == 1) { out[0] = EField::Reg; out[1] = EField::Imm; return 2; }
            // mode 2: reg16,#imm16 -- destino primero (Ptr), luego el
            // inmediato de 16 bits en dos campos Lo/Hi (igual gesto que
            // teclear un addr16 en LDA/STA/JMP/...).
            out[0] = EField::Ptr; out[1] = EField::Lo; out[2] = EField::Hi;
            return 3;
        case V_CMP:
            if (mode == 0) { out[0] = EField::Dst; out[1] = EField::Src; return 2; }
            out[0] = EField::Reg; out[1] = EField::Imm;
            return 2;
        case V_AND: case V_OR: case V_XOR:
            if (mode == 0) { out[0] = EField::Dst; out[1] = EField::Src; return 2; }
            if (mode == 1) { out[0] = EField::Reg; out[1] = EField::Imm; return 2; }
            out[0] = EField::Reg; out[1] = EField::Lo; out[2] = EField::Hi;
            return 3;
        case V_ADD: case V_SUB:
            if (mode == 0) { out[0] = EField::Dst; out[1] = EField::Src; return 2; }
            if (mode == 1) { out[0] = EField::Reg; out[1] = EField::Imm; return 2; }
            if (mode == 2) { out[0] = EField::Reg; out[1] = EField::Lo; out[2] = EField::Hi; return 3; }
            // mode 3: reg16,reg8 -- dst16 primero (Ptr), luego src8 (Reg),
            // igual orden que se lee/teclea "ADD BX,CL".
            out[0] = EField::Ptr; out[1] = EField::Reg;
            return 2;
        case V_MUL: case V_DIV:
            out[0] = EField::Reg;
            return 1;
        case V_INC: case V_DEC:
            out[0] = EField::Ptr;
            return 1;
        case V_MOVB: case V_MOVW:
            return 0;
        default:
            return 0;
    }
}

uint8_t aluOpOf(uint8_t verb) {
    switch (verb) {
        case V_MOV: return ALU_MOV;
        case V_ADD: return ALU_ADD;
        case V_SUB: return ALU_SUB;
        case V_CMP: return ALU_CMP;
        case V_AND: return ALU_AND;
        case V_OR:  return ALU_OR;
        case V_XOR: return ALU_XOR;
        default:    return ALU_MOV;
    }
}

// Familia con mode de memoria (reg,[dir]) -- solo ADD/SUB/AND/OR/XOR.
uint8_t memFamilyOf(uint8_t verb) {
    switch (verb) {
        case V_ADD: return OP_ADD;
        case V_SUB: return OP_SUB;
        case V_AND: return OP_AND;
        case V_OR:  return OP_OR;
        case V_XOR: return OP_XOR;
        default:    return OP_ADD;
    }
}

// Nombre de cada verbo, indexado por su valor de enum (V_NOP..V_CMP, ver
// editor.h) -- para pantalla (verbName) y para construir el orden
// alfabético de abajo.
const char* const kVerbNames[VERB_COUNT] = {
    "NOP", "HALT", "MOV", "LDA", "STA", "ADD", "SUB", "AND", "OR", "XOR",
    "NOT", "SHR", "SHL", "IN", "OUT", "PUSH", "POP", "JMP", "CALL", "RET", "CMP",
    "MUL", "DIV", "INC", "DEC", "MOVB", "MOVW",
};

// Orden en que DATOS los va ofreciendo al girar en el campo Verb: alfabético
// por nombre (kVerbNames), no el orden interno del enum (que agrupa por
// familia de opcode y es irrelevante para quien teclea).
const uint8_t kVerbAlpha[VERB_COUNT] = {
    V_ADD, V_AND, V_CALL, V_CMP, V_DEC, V_DIV, V_HALT, V_IN, V_INC, V_JMP,
    V_LDA, V_MOV, V_MOVB, V_MOVW, V_MUL, V_NOP, V_NOT, V_OR, V_OUT, V_POP,
    V_PUSH, V_RET, V_SHL, V_SHR, V_STA, V_SUB, V_XOR,
};

uint8_t alphaIndexOf(uint8_t verb) {
    for (uint8_t i = 0; i < VERB_COUNT; ++i) {
        if (kVerbAlpha[i] == verb) return i;
    }
    return 0;
}

} // namespace

const char* verbName(uint8_t verb) {
    return (verb < VERB_COUNT) ? kVerbNames[verb] : "?";
}

EField fieldAt(uint8_t verb, uint8_t mode, uint8_t step) {
    if (step == 0) return EField::Verb;
    uint8_t s = 1;
    if (modeCount(verb) > 0) {
        if (step == s) return EField::Mode;
        ++s;
    }
    EField ops[3];
    uint8_t n = operandFields(verb, mode, ops);
    uint8_t idx = (uint8_t)(step - s);
    if (idx < n) return ops[idx];
    return EField::Done;
}

uint8_t lastStep(uint8_t verb, uint8_t mode) {
    uint8_t step = 0;
    while (fieldAt(verb, mode, (uint8_t)(step + 1)) != EField::Done) ++step;
    return step;
}

void applyDelta(ComposeState& st, int16_t delta) {
    EField f = fieldAt(st.verb, st.mode, st.step);
    switch (f) {
        case EField::Verb: {
            int16_t idx = (int16_t)(((int16_t)alphaIndexOf(st.verb) + delta) % (int16_t)VERB_COUNT);
            if (idx < 0) idx += VERB_COUNT;
            st.verb = kVerbAlpha[idx];
            // El verbo nuevo no hereda campos del anterior: evita mezclas raras
            // (p. ej. un registro/condición que por casualidad coincidiera).
            st.mode = 0; st.reg = 0; st.dst = 0; st.src = 0; st.cond = 0;
            st.imm = 0; st.addr16 = 0; st.ptr = 0; st.shift = 1;
            break;
        }
        case EField::Mode: {
            uint8_t n = modeCount(st.verb);
            if (n == 0) break;
            int16_t v = (int16_t)(((int16_t)st.mode + delta) % (int16_t)n);
            if (v < 0) v += n;
            st.mode = (uint8_t)v;
            break;
        }
        case EField::Cond: {
            int16_t v = (int16_t)(((int16_t)st.cond + delta) % (int16_t)COND_COUNT);
            if (v < 0) v += COND_COUNT;
            st.cond = (uint8_t)v;
            break;
        }
        case EField::Reg: st.reg = (uint8_t)(((int16_t)st.reg + delta) & 7); break;
        case EField::Dst: st.dst = (uint8_t)(((int16_t)st.dst + delta) & 7); break;
        case EField::Src: st.src = (uint8_t)(((int16_t)st.src + delta) & 7); break;
        case EField::Ptr: st.ptr = (uint8_t)(((int16_t)st.ptr + delta) & 3); break;
        case EField::Imm: st.imm = (uint8_t)((int16_t)st.imm + delta); break;
        case EField::Shift: {
            // 1..8 con envoltura (a diferencia de Imm, que es un byte libre).
            int16_t v = (int16_t)(((int16_t)(st.shift - 1) + delta) % 8);
            if (v < 0) v += 8;
            st.shift = (uint8_t)(v + 1);
            break;
        }
        case EField::Lo: {
            uint8_t lo = (uint8_t)((int16_t)(st.addr16 & 0xFF) + delta);
            st.addr16 = (uint16_t)((st.addr16 & 0xFF00) | lo);
            break;
        }
        case EField::Hi: {
            uint8_t hi = (uint8_t)((int16_t)((st.addr16 >> 8) & 0xFF) + delta);
            st.addr16 = (uint16_t)((st.addr16 & 0x00FF) | ((uint16_t)hi << 8));
            break;
        }
        case EField::Done:
            break;
    }
}

uint8_t assemble(uint8_t* mem, uint32_t memLen, uint16_t addr, const ComposeState& st) {
    auto put = [&](uint16_t a, uint8_t v) { if (a < memLen) mem[a] = v; };
    auto putAddr16 = [&](uint16_t a) {
        put((uint16_t)(addr + 1), (uint8_t)(a & 0xFF));
        put((uint16_t)(addr + 2), (uint8_t)(a >> 8));
    };

    switch (st.verb) {
        case V_NOP:  put(addr, makeOpcode(OP_NOP, 0));  return 1;
        case V_HALT: put(addr, makeOpcode(OP_HALT, 0)); return 1;
        case V_RET:  put(addr, makeOpcode(OP_RET, 0));  return 1;
        case V_NOT:  put(addr, makeOpcode(OP_NOT, st.reg));  return 1;
        case V_SHR:
            if (st.mode == 1) { put(addr, makeOpcode(OP_SHRN, st.reg)); put((uint16_t)(addr + 1), (uint8_t)(st.shift - 1)); return 2; }
            put(addr, makeOpcode(OP_SHR, st.reg)); return 1;
        case V_SHL:
            if (st.mode == 1) { put(addr, makeOpcode(OP_SHLN, st.reg)); put((uint16_t)(addr + 1), (uint8_t)(st.shift - 1)); return 2; }
            put(addr, makeOpcode(OP_SHL, st.reg)); return 1;
        case V_PUSH: put(addr, makeOpcode(OP_PUSH, st.reg)); return 1;
        case V_POP:  put(addr, makeOpcode(OP_POP, st.reg));  return 1;
        case V_LDA:
            if (st.mode == 1) { put(addr, makeOpcode(OP_LDAR, st.reg)); put((uint16_t)(addr + 1), st.ptr); return 2; }
            put(addr, makeOpcode(OP_LDA, st.reg)); putAddr16(st.addr16); return 3;
        case V_STA:
            if (st.mode == 1) { put(addr, makeOpcode(OP_STAR, st.reg)); put((uint16_t)(addr + 1), st.ptr); return 2; }
            put(addr, makeOpcode(OP_STA, st.reg)); putAddr16(st.addr16); return 3;
        case V_IN:
            if (st.mode == 1) { put(addr, makeOpcode(OP_INR, st.reg)); put((uint16_t)(addr + 1), st.ptr); return 2; }
            put(addr, makeOpcode(OP_IN, st.reg));  putAddr16(st.addr16); return 3;
        case V_OUT:
            if (st.mode == 1) { put(addr, makeOpcode(OP_OUTR, st.reg)); put((uint16_t)(addr + 1), st.ptr); return 2; }
            put(addr, makeOpcode(OP_OUT, st.reg)); putAddr16(st.addr16); return 3;
        case V_JMP:
            // cond==8 ("NV") no cabe en el campo de 3 bits de OP_JMP: se
            // codifica aparte, en OP_EXT2 subop 4 (ver isa.h).
            if (st.cond == 8) { put(addr, makeOpcode(OP_EXT2, 4)); putAddr16(st.addr16); return 3; }
            put(addr, makeOpcode(OP_JMP, st.cond)); putAddr16(st.addr16); return 3;
        case V_CALL:
            if (st.cond == 8) { put(addr, makeOpcode(OP_EXT2, 5)); putAddr16(st.addr16); return 3; }
            put(addr, makeOpcode(OP_CALL, st.cond)); putAddr16(st.addr16); return 3;
        case V_MOV:
            if (st.mode == 0) {
                put(addr, makeOpcode(OP_EXT, ALU_MOV));
                put((uint16_t)(addr + 1), (uint8_t)((st.dst << 3) | (st.src & 7)));
                return 2;
            }
            if (st.mode == 1) {
                put(addr, makeOpcode(OP_LDI, st.reg));
                put((uint16_t)(addr + 1), st.imm);
                return 2;
            }
            // mode 2: reg16,#imm16 -- OP_EXT2 subop 6. NO se puede usar
            // putAddr16 (escribe fijo en addr+1/addr+2): aqui addr+1 ya lo
            // ocupa el byte de reg16, el imm16 va en addr+2/addr+3.
            put(addr, makeOpcode(OP_EXT2, 6));
            put((uint16_t)(addr + 1), (uint8_t)(st.ptr & 3));
            put((uint16_t)(addr + 2), (uint8_t)(st.addr16 & 0xFF));
            put((uint16_t)(addr + 3), (uint8_t)(st.addr16 >> 8));
            return 4;
        case V_CMP:
            if (st.mode == 0) {
                put(addr, makeOpcode(OP_EXT, ALU_CMP));
                put((uint16_t)(addr + 1), (uint8_t)((st.dst << 3) | (st.src & 7)));
                return 2;
            }
            put(addr, makeOpcode(OP_ALUI, ALU_CMP));
            put((uint16_t)(addr + 1), st.reg);
            put((uint16_t)(addr + 2), st.imm);
            return 3;
        case V_AND: case V_OR: case V_XOR: {
            uint8_t op = aluOpOf(st.verb);
            if (st.mode == 0) {
                put(addr, makeOpcode(OP_EXT, op));
                put((uint16_t)(addr + 1), (uint8_t)((st.dst << 3) | (st.src & 7)));
                return 2;
            }
            if (st.mode == 1) {
                put(addr, makeOpcode(OP_ALUI, op));
                put((uint16_t)(addr + 1), st.reg);
                put((uint16_t)(addr + 2), st.imm);
                return 3;
            }
            put(addr, makeOpcode(memFamilyOf(st.verb), st.reg));
            putAddr16(st.addr16);
            return 3;
        }
        case V_ADD: case V_SUB: {
            uint8_t op = aluOpOf(st.verb);
            if (st.mode == 0) {
                put(addr, makeOpcode(OP_EXT, op));
                put((uint16_t)(addr + 1), (uint8_t)((st.dst << 3) | (st.src & 7)));
                return 2;
            }
            if (st.mode == 1) {
                put(addr, makeOpcode(OP_ALUI, op));
                put((uint16_t)(addr + 1), st.reg);
                put((uint16_t)(addr + 2), st.imm);
                return 3;
            }
            if (st.mode == 2) {
                put(addr, makeOpcode(memFamilyOf(st.verb), st.reg));
                putAddr16(st.addr16);
                return 3;
            }
            // mode 3: reg16,reg8 -- OP_EXT2 subop 0 (ADD) / 1 (SUB)
            put(addr, makeOpcode(OP_EXT2, (st.verb == V_ADD) ? 0 : 1));
            put((uint16_t)(addr + 1), (uint8_t)(((st.ptr & 3) << 3) | (st.reg & 7)));
            return 2;
        }
        case V_MUL: put(addr, makeOpcode(OP_MUL, st.reg)); return 1;
        case V_DIV: put(addr, makeOpcode(OP_DIV, st.reg)); return 1;
        case V_INC: put(addr, makeOpcode(OP_INCDEC16, (uint8_t)(st.ptr & 3))); return 1;
        case V_DEC: put(addr, makeOpcode(OP_INCDEC16, (uint8_t)(0x04 | (st.ptr & 3)))); return 1;
        case V_MOVB: put(addr, makeOpcode(OP_EXT2, 2)); return 1;
        case V_MOVW: put(addr, makeOpcode(OP_EXT2, 3)); return 1;
        default:
            put(addr, makeOpcode(OP_NOP, 0));
            return 1;
    }
}

uint8_t composedLength(const ComposeState& st) {
    uint8_t scratch[8];   // ninguna instruccion pasa de 4 bytes hoy; de
                           // sobra incluso si esta constante creciera
    return assemble(scratch, sizeof(scratch), 0, st);
}

ComposeState decodeAt(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    ComposeState st;
    uint8_t op  = rd(mem, memLen, addr);
    uint8_t fam = opFamily(op);
    uint8_t r   = opReg(op);
    uint8_t b1  = rd(mem, memLen, (uint16_t)(addr + 1));
    uint8_t b2  = rd(mem, memLen, (uint16_t)(addr + 2));
    uint16_t a16 = (uint16_t)(b1 | (b2 << 8));

    switch (fam) {
        case OP_NOP:  st.verb = V_NOP;  break;
        case OP_HALT: st.verb = V_HALT; break;
        case OP_RET:  st.verb = V_RET;  break;
        case OP_LDI:  st.verb = V_MOV; st.mode = 1; st.reg = r; st.imm = b1; break;
        case OP_LDA:  st.verb = V_LDA; st.mode = 0; st.reg = r; st.addr16 = a16; break;
        case OP_STA:  st.verb = V_STA; st.mode = 0; st.reg = r; st.addr16 = a16; break;
        case OP_ADD:  st.verb = V_ADD; st.mode = 2; st.reg = r; st.addr16 = a16; break;
        case OP_SUB:  st.verb = V_SUB; st.mode = 2; st.reg = r; st.addr16 = a16; break;
        case OP_AND:  st.verb = V_AND; st.mode = 2; st.reg = r; st.addr16 = a16; break;
        case OP_OR:   st.verb = V_OR;  st.mode = 2; st.reg = r; st.addr16 = a16; break;
        case OP_XOR:  st.verb = V_XOR; st.mode = 2; st.reg = r; st.addr16 = a16; break;
        case OP_NOT:  st.verb = V_NOT;  st.reg = r; break;
        case OP_SHR:  st.verb = V_SHR;  st.mode = 0; st.reg = r; break;
        case OP_SHL:  st.verb = V_SHL;  st.mode = 0; st.reg = r; break;
        case OP_SHRN: st.verb = V_SHR;  st.mode = 1; st.reg = r; st.shift = (uint8_t)((b1 & 7) + 1); break;
        case OP_SHLN: st.verb = V_SHL;  st.mode = 1; st.reg = r; st.shift = (uint8_t)((b1 & 7) + 1); break;
        case OP_IN:   st.verb = V_IN;   st.mode = 0; st.reg = r; st.addr16 = a16; break;
        case OP_OUT:  st.verb = V_OUT;  st.mode = 0; st.reg = r; st.addr16 = a16; break;
        case OP_LDAR: st.verb = V_LDA; st.mode = 1; st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_STAR: st.verb = V_STA; st.mode = 1; st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_INR:  st.verb = V_IN;  st.mode = 1; st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_OUTR: st.verb = V_OUT; st.mode = 1; st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_PUSH: st.verb = V_PUSH; st.reg = r; break;
        case OP_POP:  st.verb = V_POP;  st.reg = r; break;
        case OP_JMP:  st.verb = V_JMP;  st.cond = r; st.addr16 = a16; break;
        case OP_CALL: st.verb = V_CALL; st.cond = r; st.addr16 = a16; break;
        case OP_ALUI: {
            switch (r) {
                case ALU_ADD: st.verb = V_ADD; break;
                case ALU_SUB: st.verb = V_SUB; break;
                case ALU_CMP: st.verb = V_CMP; break;
                case ALU_AND: st.verb = V_AND; break;
                case ALU_OR:  st.verb = V_OR;  break;
                case ALU_XOR: st.verb = V_XOR; break;
                default:      st.verb = V_MOV; break;   // op 0/7: sin uso normal
            }
            st.mode = 1;
            st.reg = (uint8_t)(b1 & 7);
            st.imm = b2;
            break;
        }
        case OP_EXT: {
            switch (r) {
                case ALU_MOV: st.verb = V_MOV; break;
                case ALU_ADD: st.verb = V_ADD; break;
                case ALU_SUB: st.verb = V_SUB; break;
                case ALU_CMP: st.verb = V_CMP; break;
                case ALU_AND: st.verb = V_AND; break;
                case ALU_OR:  st.verb = V_OR;  break;
                case ALU_XOR: st.verb = V_XOR; break;
                default:      st.verb = V_MOV; break;
            }
            st.mode = 0;
            st.dst = (uint8_t)((b1 >> 3) & 7);
            st.src = (uint8_t)(b1 & 7);
            break;
        }
        case OP_MUL: st.verb = V_MUL; st.reg = r; break;
        case OP_DIV: st.verb = V_DIV; st.reg = r; break;
        case OP_INCDEC16: {
            bool dec = (r & 0x04) != 0;
            st.verb = dec ? V_DEC : V_INC;
            st.ptr = (uint8_t)(r & 3);
            break;
        }
        case OP_EXT2: {
            switch (r) {
                case 0: st.verb = V_ADD; st.mode = 3; st.ptr = (uint8_t)((b1 >> 3) & 3); st.reg = (uint8_t)(b1 & 7); break;
                case 1: st.verb = V_SUB; st.mode = 3; st.ptr = (uint8_t)((b1 >> 3) & 3); st.reg = (uint8_t)(b1 & 7); break;
                case 2: st.verb = V_MOVB; break;
                case 3: st.verb = V_MOVW; break;
                case 4: st.verb = V_JMP;  st.cond = 8; st.addr16 = a16; break;   // JMPNV
                case 5: st.verb = V_CALL; st.cond = 8; st.addr16 = a16; break;   // CALLNV
                case 6: {
                    // MOV reg16,#imm16 -- b1=reg16, imm16 en b2/b3 (NO en
                    // a16, que aqui vale b1|b2<<8 y no es lo que hace falta)
                    uint8_t b2 = rd(mem, memLen, (uint16_t)(addr + 2));
                    uint8_t b3 = rd(mem, memLen, (uint16_t)(addr + 3));
                    st.verb = V_MOV;
                    st.mode = 2;
                    st.ptr = (uint8_t)(b1 & 3);
                    st.addr16 = (uint16_t)(b2 | (b3 << 8));
                    break;
                }
                default: st.verb = V_NOP; break;   // subop 7: reservado
            }
            break;
        }
        default:
            st.verb = V_NOP;   // sin familias reservadas por ahora: 27-30 ya se usan arriba
            break;
    }
    st.step = 0;
    return st;
}

} // namespace compi
