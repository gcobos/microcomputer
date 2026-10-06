#include "editor.h"
#include "isa.h"

namespace compi {

namespace {

inline uint8_t rd(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    return (addr < memLen) ? mem[addr] : 0;
}

// --- Formas (modos de direccionamiento) que puede tener un verbo ---------
// Cada verbo tiene una lista de formas; el campo `mode` es el indice en esa
// lista. Una forma decide los campos a teclear y como se codifica.
enum Form : uint8_t {
    FK_NONE,       // sin operandos (NOP, HALT, RET, MOVB, MOVW, MOVBR)
    FK_RR,         // ALU reg,reg
    FK_RI,         // ALU reg,#imm8
    FK_RM,         // ALU reg,[dir]
    FK_RP,         // ALU reg,[r16]
    FK_LDI,        // MOV reg,#imm8
    FK_LDA, FK_LDAR, FK_STA, FK_STAR,
    FK_IN, FK_INR, FK_OUT, FK_OUTR,
    FK_R16R16,     // MOV/ADD/SUB/CMP r16,r16
    FK_R16R8,      // ADD/SUB r16,reg8
    FK_R16IMM8,    // ADD/SUB r16,#imm8
    FK_R16IMM16,   // MOV/CMP r16,#imm16
    FK_REG,        // un registro de 8 bits (NOT/MUL/DIV/INC/DEC/PUSH/POP)
    FK_REG16,      // un par de 16 bits (INC/DEC/PUSH/POP)
    FK_SHIFT,      // SHR/SHL reg,#N
    FK_JCC,        // JMP/CALL <cond>,dir
    FK_JR,         // JMP/CALL r16
};

struct VerbInfo {
    const char* name;
    uint8_t nForms;
    Form forms[7];
};

// Indexada por Verb (editor.h)
const VerbInfo kVerbs[VERB_COUNT] = {
    {"NOP",   1, {FK_NONE}},
    {"HALT",  1, {FK_NONE}},
    {"RET",   1, {FK_NONE}},
    {"MOVB",  1, {FK_NONE}},
    {"MOVW",  1, {FK_NONE}},
    {"MOVBR", 1, {FK_NONE}},
    {"MOV",   4, {FK_RR, FK_LDI, FK_R16R16, FK_R16IMM16}},
    {"LDA",   2, {FK_LDA, FK_LDAR}},
    {"STA",   2, {FK_STA, FK_STAR}},
    {"IN",    2, {FK_IN, FK_INR}},
    {"OUT",   2, {FK_OUT, FK_OUTR}},
    {"ADD",   7, {FK_RR, FK_RI, FK_RM, FK_RP, FK_R16R8, FK_R16R16, FK_R16IMM8}},
    {"ADC",   4, {FK_RR, FK_RI, FK_RM, FK_RP}},
    {"SUB",   7, {FK_RR, FK_RI, FK_RM, FK_RP, FK_R16R8, FK_R16R16, FK_R16IMM8}},
    {"SBC",   4, {FK_RR, FK_RI, FK_RM, FK_RP}},
    {"CMP",   6, {FK_RR, FK_RI, FK_RM, FK_RP, FK_R16R16, FK_R16IMM16}},
    {"AND",   4, {FK_RR, FK_RI, FK_RM, FK_RP}},
    {"OR",    4, {FK_RR, FK_RI, FK_RM, FK_RP}},
    {"XOR",   4, {FK_RR, FK_RI, FK_RM, FK_RP}},
    {"NOT",   1, {FK_REG}},
    {"SHR",   1, {FK_SHIFT}},
    {"SHL",   1, {FK_SHIFT}},
    {"MUL",   1, {FK_REG}},
    {"DIV",   1, {FK_REG}},
    {"INC",   2, {FK_REG16, FK_REG}},
    {"DEC",   2, {FK_REG16, FK_REG}},
    {"PUSH",  2, {FK_REG, FK_REG16}},
    {"POP",   2, {FK_REG, FK_REG16}},
    {"JMP",   2, {FK_JCC, FK_JR}},
    {"CALL",  2, {FK_JCC, FK_JR}},
};

// Orden en que DATOS los va ofreciendo al girar en el campo Verb:
// alfabetico por nombre, no el orden interno del enum.
const uint8_t kVerbAlpha[VERB_COUNT] = {
    V_ADC, V_ADD, V_AND, V_CALL, V_CMP, V_DEC, V_DIV, V_HALT, V_IN, V_INC,
    V_JMP, V_LDA, V_MOV, V_MOVB, V_MOVBR, V_MOVW, V_MUL, V_NOP, V_NOT, V_OR,
    V_OUT, V_POP, V_PUSH, V_RET, V_SBC, V_SHL, V_SHR, V_STA, V_SUB, V_XOR,
};

uint8_t alphaIndexOf(uint8_t verb) {
    for (uint8_t i = 0; i < VERB_COUNT; ++i) {
        if (kVerbAlpha[i] == verb) return i;
    }
    return 0;
}

Form formOf(uint8_t verb, uint8_t mode) {
    if (verb >= VERB_COUNT) return FK_NONE;
    const VerbInfo& v = kVerbs[verb];
    return v.forms[(mode < v.nForms) ? mode : 0];
}

// Numero de formas, o 0 si solo hay una (entonces no hay campo Mode)
uint8_t modeCount(uint8_t verb) {
    if (verb >= VERB_COUNT) return 0;
    uint8_t n = kVerbs[verb].nForms;
    return (n > 1) ? n : 0;
}

// Campos de operando de una forma (sin contar Verb/Mode), hasta 3
uint8_t formFields(Form f, EField out[3]) {
    switch (f) {
        case FK_NONE:      return 0;
        case FK_RR:        out[0] = EField::Dst; out[1] = EField::Src; return 2;
        case FK_RI:
        case FK_LDI:       out[0] = EField::Reg; out[1] = EField::Imm; return 2;
        case FK_RM:
        case FK_LDA:
        case FK_IN:        out[0] = EField::Reg; out[1] = EField::Lo; out[2] = EField::Hi; return 3;
        case FK_RP:
        case FK_LDAR:
        case FK_INR:       out[0] = EField::Reg; out[1] = EField::Ptr; return 2;
        // Destino primero, igual que en pantalla (STA [dir],reg / OUT (puerto),reg)
        case FK_STA:
        case FK_OUT:       out[0] = EField::Lo; out[1] = EField::Hi; out[2] = EField::Reg; return 3;
        case FK_STAR:
        case FK_OUTR:      out[0] = EField::Ptr; out[1] = EField::Reg; return 2;
        case FK_R16R16:    out[0] = EField::Ptr; out[1] = EField::Ptr2; return 2;
        case FK_R16R8:     out[0] = EField::Ptr; out[1] = EField::Reg; return 2;
        case FK_R16IMM8:   out[0] = EField::Ptr; out[1] = EField::Imm; return 2;
        case FK_R16IMM16:  out[0] = EField::Ptr; out[1] = EField::Lo; out[2] = EField::Hi; return 3;
        case FK_REG:       out[0] = EField::Reg; return 1;
        case FK_REG16:     out[0] = EField::Ptr; return 1;
        case FK_SHIFT:     out[0] = EField::Reg; out[1] = EField::Shift; return 2;
        case FK_JCC:       out[0] = EField::Cond; out[1] = EField::Lo; out[2] = EField::Hi; return 3;
        case FK_JR:        out[0] = EField::Ptr; return 1;
    }
    return 0;
}

uint8_t aluOpOf(uint8_t verb) {
    switch (verb) {
        case V_ADD: return ALU_ADD;
        case V_ADC: return ALU_ADC;
        case V_SUB: return ALU_SUB;
        case V_SBC: return ALU_SBC;
        case V_CMP: return ALU_CMP;
        case V_AND: return ALU_AND;
        case V_OR:  return ALU_OR;
        case V_XOR: return ALU_XOR;
        default:    return ALU_MOV;
    }
}

uint8_t verbOfAlu(uint8_t op) {
    switch (op) {
        case ALU_ADD: return V_ADD;
        case ALU_ADC: return V_ADC;
        case ALU_SUB: return V_SUB;
        case ALU_SBC: return V_SBC;
        case ALU_CMP: return V_CMP;
        case ALU_AND: return V_AND;
        case ALU_OR:  return V_OR;
        case ALU_XOR: return V_XOR;
        default:      return V_MOV;
    }
}

// Indice de la forma `f` dentro de la lista de `verb` (para decodeAt)
uint8_t modeOf(uint8_t verb, Form f) {
    const VerbInfo& v = kVerbs[verb];
    for (uint8_t i = 0; i < v.nForms; ++i) {
        if (v.forms[i] == f) return i;
    }
    return 0;
}

} // namespace

const char* verbName(uint8_t verb) {
    return (verb < VERB_COUNT) ? kVerbs[verb].name : "?";
}

EField fieldAt(uint8_t verb, uint8_t mode, uint8_t step) {
    if (step == 0) return EField::Verb;
    uint8_t s = 1;
    if (modeCount(verb) > 0) {
        if (step == s) return EField::Mode;
        ++s;
    }
    EField ops[3];
    uint8_t n = formFields(formOf(verb, mode), ops);
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
            // El verbo nuevo no hereda campos del anterior
            st.mode = 0; st.reg = 0; st.dst = 0; st.src = 0; st.cond = 0;
            st.imm = 0; st.addr16 = 0; st.ptr = 0; st.ptr2 = 0; st.shift = 1;
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
        case EField::Reg:  st.reg  = (uint8_t)(((int16_t)st.reg + delta) & 7); break;
        case EField::Dst:  st.dst  = (uint8_t)(((int16_t)st.dst + delta) & 7); break;
        case EField::Src:  st.src  = (uint8_t)(((int16_t)st.src + delta) & 7); break;
        case EField::Ptr:  st.ptr  = (uint8_t)(((int16_t)st.ptr + delta) & 3); break;
        case EField::Ptr2: st.ptr2 = (uint8_t)(((int16_t)st.ptr2 + delta) & 3); break;
        case EField::Imm:  st.imm  = (uint8_t)((int16_t)st.imm + delta); break;
        case EField::Shift: {
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
    uint8_t b[4];
    uint8_t n = 1;
    const uint8_t lo = (uint8_t)(st.addr16 & 0xFF);
    const uint8_t hi = (uint8_t)(st.addr16 >> 8);
    const uint8_t alu = aluOpOf(st.verb);
    const uint8_t r = (uint8_t)(st.reg & 7);
    const uint8_t p = (uint8_t)(st.ptr & 3);

    switch (formOf(st.verb, st.mode)) {
        case FK_NONE: {
            uint8_t sys = SYS_NOP;
            switch (st.verb) {
                case V_HALT:  sys = SYS_HALT;  break;
                case V_RET:   sys = SYS_RET;   break;
                case V_MOVB:  sys = SYS_MOVB;  break;
                case V_MOVW:  sys = SYS_MOVW;  break;
                case V_MOVBR: sys = SYS_MOVBR; break;
                default: break;
            }
            b[0] = makeOpcode(OP_SYS, sys);
            break;
        }
        case FK_RR:
            b[0] = makeOpcode(OP_ALURR, (uint8_t)(st.dst & 7));
            b[1] = (uint8_t)((alu << 3) | (st.src & 7)); n = 2;
            break;
        case FK_RI:
            b[0] = makeOpcode(OP_ALUI, r); b[1] = alu; b[2] = st.imm; n = 3;
            break;
        case FK_RM:
            b[0] = makeOpcode(OP_ALUM, r); b[1] = alu; b[2] = lo; b[3] = hi; n = 4;
            break;
        case FK_RP:
            b[0] = makeOpcode(OP_ALUP, r); b[1] = (uint8_t)((alu << 2) | p); n = 2;
            break;
        case FK_LDI:  b[0] = makeOpcode(OP_LDI, r);  b[1] = st.imm; n = 2; break;
        case FK_LDA:  b[0] = makeOpcode(OP_LDA, r);  b[1] = lo; b[2] = hi; n = 3; break;
        case FK_LDAR: b[0] = makeOpcode(OP_LDAR, r); b[1] = p; n = 2; break;
        case FK_STA:  b[0] = makeOpcode(OP_STA, r);  b[1] = lo; b[2] = hi; n = 3; break;
        case FK_STAR: b[0] = makeOpcode(OP_STAR, r); b[1] = p; n = 2; break;
        case FK_IN:   b[0] = makeOpcode(OP_IN, r);   b[1] = lo; b[2] = hi; n = 3; break;
        case FK_INR:  b[0] = makeOpcode(OP_INR, r);  b[1] = p; n = 2; break;
        case FK_OUT:  b[0] = makeOpcode(OP_OUT, r);  b[1] = lo; b[2] = hi; n = 3; break;
        case FK_OUTR: b[0] = makeOpcode(OP_OUTR, r); b[1] = p; n = 2; break;
        case FK_R16R16: {
            uint8_t op = (st.verb == V_ADD) ? R16_ADD : (st.verb == V_SUB) ? R16_SUB
                       : (st.verb == V_CMP) ? R16_CMP : R16_MOV;
            b[0] = makeOpcode(OP_R16, op); b[1] = (uint8_t)((p << 3) | (st.ptr2 & 3)); n = 2;
            break;
        }
        case FK_R16R8:
            b[0] = makeOpcode(OP_R16, (st.verb == V_SUB) ? R16_SUB8 : R16_ADD8);
            b[1] = (uint8_t)((p << 3) | r); n = 2;
            break;
        case FK_R16IMM8:
            b[0] = makeOpcode(OP_R16I, (st.verb == V_SUB) ? R16I_SUB : R16I_ADD);
            b[1] = p; b[2] = st.imm; n = 3;
            break;
        case FK_R16IMM16:
            b[0] = makeOpcode(OP_R16I, (st.verb == V_CMP) ? R16I_CMP : R16I_MOV);
            b[1] = p; b[2] = lo; b[3] = hi; n = 4;
            break;
        case FK_REG: {
            uint8_t fam = OP_NOT;
            switch (st.verb) {
                case V_MUL:  fam = OP_MUL;  break;
                case V_DIV:  fam = OP_DIV;  break;
                case V_INC:  fam = OP_INC;  break;
                case V_DEC:  fam = OP_DEC;  break;
                case V_PUSH: fam = OP_PUSH; break;
                case V_POP:  fam = OP_POP;  break;
                default: break;
            }
            b[0] = makeOpcode(fam, r);
            break;
        }
        case FK_REG16:
            if (st.verb == V_INC || st.verb == V_DEC)
                b[0] = makeOpcode(OP_INCDEC16, (uint8_t)(((st.verb == V_DEC) ? 4 : 0) | p));
            else
                b[0] = makeOpcode(OP_PUSHPOP16, (uint8_t)(((st.verb == V_POP) ? 4 : 0) | p));
            break;
        case FK_SHIFT:
            b[0] = makeOpcode((st.verb == V_SHL) ? OP_SHL : OP_SHR, r);
            b[1] = (uint8_t)((st.shift - 1) & 7); n = 2;
            break;
        case FK_JCC:
            if (st.cond == 8)   // NV no cabe en el campo de 3 bits: va en OP_JX
                b[0] = makeOpcode(OP_JX, (st.verb == V_CALL) ? JX_CALLNV : JX_JMPNV);
            else
                b[0] = makeOpcode((st.verb == V_CALL) ? OP_CALL : OP_JMP, st.cond);
            b[1] = lo; b[2] = hi; n = 3;
            break;
        case FK_JR:
            b[0] = makeOpcode(OP_JX, (st.verb == V_CALL) ? JX_CALLR : JX_JMPR);
            b[1] = p; n = 2;
            break;
    }
    for (uint8_t i = 0; i < n; ++i) {
        uint16_t a = (uint16_t)(addr + i);
        if (a < memLen) mem[a] = b[i];
    }
    return n;
}

uint8_t composedLength(const ComposeState& st) {
    uint8_t scratch[8];
    return assemble(scratch, sizeof(scratch), 0, st);
}

ComposeState decodeAt(const uint8_t* mem, uint32_t memLen, uint16_t addr) {
    ComposeState st;
    uint8_t op = rd(mem, memLen, addr);
    uint8_t r  = opReg(op);
    uint8_t b1 = rd(mem, memLen, (uint16_t)(addr + 1));
    uint8_t b2 = rd(mem, memLen, (uint16_t)(addr + 2));
    uint8_t b3 = rd(mem, memLen, (uint16_t)(addr + 3));
    uint16_t a12 = (uint16_t)(b1 | (b2 << 8));
    uint16_t a23 = (uint16_t)(b2 | (b3 << 8));
    auto set = [&](uint8_t verb, Form f) { st.verb = verb; st.mode = modeOf(verb, f); };

    switch (opFamily(op)) {
        case OP_SYS:
            switch (r) {
                case SYS_HALT:  st.verb = V_HALT;  break;
                case SYS_RET:   st.verb = V_RET;   break;
                case SYS_MOVB:  st.verb = V_MOVB;  break;
                case SYS_MOVW:  st.verb = V_MOVW;  break;
                case SYS_MOVBR: st.verb = V_MOVBR; break;
                default:        st.verb = V_NOP;   break;
            }
            break;
        case OP_LDI:  set(V_MOV, FK_LDI);  st.reg = r; st.imm = b1; break;
        case OP_LDA:  set(V_LDA, FK_LDA);  st.reg = r; st.addr16 = a12; break;
        case OP_STA:  set(V_STA, FK_STA);  st.reg = r; st.addr16 = a12; break;
        case OP_LDAR: set(V_LDA, FK_LDAR); st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_STAR: set(V_STA, FK_STAR); st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_IN:   set(V_IN, FK_IN);    st.reg = r; st.addr16 = a12; break;
        case OP_OUT:  set(V_OUT, FK_OUT);  st.reg = r; st.addr16 = a12; break;
        case OP_INR:  set(V_IN, FK_INR);   st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_OUTR: set(V_OUT, FK_OUTR); st.reg = r; st.ptr = (uint8_t)(b1 & 3); break;
        case OP_ALURR:
            set(verbOfAlu((uint8_t)(b1 >> 3)), FK_RR);
            st.dst = r; st.src = (uint8_t)(b1 & 7);
            break;
        case OP_ALUI: {
            uint8_t v = verbOfAlu(b1);
            set(v, (v == V_MOV) ? FK_LDI : FK_RI);
            st.reg = r; st.imm = b2;
            break;
        }
        case OP_ALUM: {
            uint8_t v = verbOfAlu(b1);
            if (v == V_MOV) set(V_LDA, FK_LDA); else set(v, FK_RM);
            st.reg = r; st.addr16 = a23;
            break;
        }
        case OP_ALUP: {
            uint8_t v = verbOfAlu((uint8_t)(b1 >> 2));
            if (v == V_MOV) set(V_LDA, FK_LDAR); else set(v, FK_RP);
            st.reg = r; st.ptr = (uint8_t)(b1 & 3);
            break;
        }
        case OP_NOT: set(V_NOT, FK_REG); st.reg = r; break;
        case OP_SHR: set(V_SHR, FK_SHIFT); st.reg = r; st.shift = (uint8_t)((b1 & 7) + 1); break;
        case OP_SHL: set(V_SHL, FK_SHIFT); st.reg = r; st.shift = (uint8_t)((b1 & 7) + 1); break;
        case OP_MUL: set(V_MUL, FK_REG); st.reg = r; break;
        case OP_DIV: set(V_DIV, FK_REG); st.reg = r; break;
        case OP_INC: set(V_INC, FK_REG); st.reg = r; break;
        case OP_DEC: set(V_DEC, FK_REG); st.reg = r; break;
        case OP_PUSH: set(V_PUSH, FK_REG); st.reg = r; break;
        case OP_POP:  set(V_POP, FK_REG);  st.reg = r; break;
        case OP_JMP:  set(V_JMP, FK_JCC);  st.cond = r; st.addr16 = a12; break;
        case OP_CALL: set(V_CALL, FK_JCC); st.cond = r; st.addr16 = a12; break;
        case OP_JX:
            switch (r) {
                case JX_JMPNV:  set(V_JMP, FK_JCC);  st.cond = 8; st.addr16 = a12; break;
                case JX_CALLNV: set(V_CALL, FK_JCC); st.cond = 8; st.addr16 = a12; break;
                case JX_JMPR:   set(V_JMP, FK_JR);   st.ptr = (uint8_t)(b1 & 3); break;
                case JX_CALLR:  set(V_CALL, FK_JR);  st.ptr = (uint8_t)(b1 & 3); break;
                default:        st.verb = V_NOP; break;
            }
            break;
        case OP_R16:
            st.ptr = (uint8_t)((b1 >> 3) & 3);
            switch (r) {
                case R16_MOV:  set(V_MOV, FK_R16R16); st.ptr2 = (uint8_t)(b1 & 3); break;
                case R16_ADD:  set(V_ADD, FK_R16R16); st.ptr2 = (uint8_t)(b1 & 3); break;
                case R16_SUB:  set(V_SUB, FK_R16R16); st.ptr2 = (uint8_t)(b1 & 3); break;
                case R16_CMP:  set(V_CMP, FK_R16R16); st.ptr2 = (uint8_t)(b1 & 3); break;
                case R16_ADD8: set(V_ADD, FK_R16R8);  st.reg = (uint8_t)(b1 & 7); break;
                case R16_SUB8: set(V_SUB, FK_R16R8);  st.reg = (uint8_t)(b1 & 7); break;
                default:       st.verb = V_NOP; st.ptr = 0; break;
            }
            break;
        case OP_R16I:
            st.ptr = (uint8_t)(b1 & 3);
            switch (r) {
                case R16I_MOV: set(V_MOV, FK_R16IMM16); st.addr16 = a23; break;
                case R16I_ADD: set(V_ADD, FK_R16IMM8);  st.imm = b2; break;
                case R16I_SUB: set(V_SUB, FK_R16IMM8);  st.imm = b2; break;
                case R16I_CMP: set(V_CMP, FK_R16IMM16); st.addr16 = a23; break;
                default:       st.verb = V_NOP; st.ptr = 0; break;
            }
            break;
        case OP_INCDEC16:
            set((r & 4) ? V_DEC : V_INC, FK_REG16); st.ptr = (uint8_t)(r & 3);
            break;
        case OP_PUSHPOP16:
            set((r & 4) ? V_POP : V_PUSH, FK_REG16); st.ptr = (uint8_t)(r & 3);
            break;
        default:
            st.verb = V_NOP;   // familias libres
            break;
    }
    st.step = 0;
    return st;
}

} // namespace compi
