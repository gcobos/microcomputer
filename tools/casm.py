#!/usr/bin/env python3
"""casm — ensamblador para la ISA de compi (ver ../specs.txt §4 y docs/isa.md).

Sintaxis = la del desensamblador (src/disasm.cpp) + etiquetas y directivas.

    ; comentario
    etiqueta:            ; una etiqueta, sola o delante de una instrucción
    NAME .equ EXPR       ; constante  (tambien:  NAME = EXPR)
    .org EXPR            ; mueve el contador de posicion (rellena con 0)
    .db  1, 2, "texto", 0
    .dw  0x1234          ; palabra de 16 bits, little-endian (bajo, alto)
    .ascii  "hola"       ; bytes de una cadena
    .asciiz "hola"       ; idem + terminador 0
    .space N            ; N bytes a 0    (alias: .res N)
    .slot N            ; slot de flash por defecto para este programa
    .name "PONG"       ; nombre del programa (hasta 14 caracteres) -- va a la
                       ; cabecera del slot, sisop.asm lo usa en sus menus
    .category GAME     ; GAME PROGRAM UTILITY DEMO DOCS SYSTEM (o un numero)
    .include "text.asm"  ; inserta otro fichero aqui (busca junto al que lo
                       ; incluye y luego en programs/lib/); cada fichero se
                       ; incluye una sola vez aunque se pida varias

Instrucciones (reg = AL AH BL BH CL CH DL DH):

    NOP  HALT  RET
    MOV reg,#imm     MOV dst,src     MOV AX|BX|CX|DX,#imm16
    LDA reg,[addr]   STA [addr],reg     (o [AX|BX|CX|DX]: indirecto por registro)
    ADD/SUB/AND/OR/XOR  reg,[addr] | reg,#imm | dst,src
    CMP reg,#imm | dst,src
    NOT/PUSH/POP reg
    SHR/SHL reg              (desplaza 1 bit)   o   SHR/SHL reg,#N  (N=1..8)
    IN  reg,(port)   OUT (port),reg     (o (AX|BX|CX|DX): indirecto por registro)
    JMP/JMPZ/JMPNZ/JMPC/JMPNC/JMPN/JMPNN/JMPV/JMPNV   addr
    CALL/CALLZ/CALLNZ/CALLC/CALLNC/CALLN/CALLNN/CALLV/CALLNV  addr
    MUL reg   DIV reg          (AX = AL*reg ; AL=AX/reg AH=AX%reg -- sin signo)
    INC AX|BX|CX|DX   DEC AX|BX|CX|DX      (par de 16 bits, +-1)
    ADD AX|BX|CX|DX,reg8   SUB AX|BX|CX|DX,reg8   (dst16 +=/-= reg8 sin signo;
                                                     MISMO mnemonico ADD/SUB)
    MOVB   MOVW              (copia BX->DX, CX bytes o CX palabras de 16 bits)

Expresiones: + - * / % , << >> & | ^ ~ , parentesis, 0x.. 0b.. decimal,
'A' (codigo del caracter), $ o . (posicion actual), lo(x) hi(x), y etiquetas.

Uso:
    casm.py demo.asm -o demo.bin        # bytes hasta la ultima direccion usada
    casm.py demo.asm --list demo.lst    # + listado

El fichero de salida NO son siempre 64 KiB: se recorta justo despues del
ultimo byte de codigo/datos (self.max_addr). El resto de la RAM (hasta
0xFFFF) lo pone a 0 el aparato al cargar el programa (protocolo "COMPI LOAD
<slot> <len>" de src/main.cpp, que ya acepta len < 65536), asi que conviene
colocar las variables y tablas justo despues del codigo -- no en direcciones
altas fijas como 0xFE00 -- para que el fichero (y el envio por serie con
compi_send.py) se queden pequenos. El SP arranca siempre en 0xFFFF y crece
hacia abajo, eso no cambia.
"""
import argparse
import os
import re
import sys

IMAGE_SIZE = 65536

REG = {"AL": 0, "AH": 1, "BL": 2, "BH": 3, "CL": 4, "CH": 5, "DL": 6, "DH": 7}

# familias de opcode (isa.h, ISA version 2 -- ver docs/isa.md)
F_SYS, F_LDI, F_LDA, F_STA, F_LDAR, F_STAR = 0, 1, 2, 3, 4, 5
F_IN, F_OUT, F_INR, F_OUTR = 6, 7, 8, 9
F_ALURR, F_ALUI, F_ALUM, F_ALUP = 10, 11, 12, 13
F_NOT, F_SHR, F_SHL, F_MUL, F_DIV, F_INC, F_DEC, F_PUSH, F_POP = 14, 15, 16, 17, 18, 19, 20, 21, 22
F_JMP, F_CALL, F_JX = 23, 24, 25
F_R16, F_R16I, F_INCDEC16, F_PUSHPOP16 = 26, 27, 28, 29
REG16 = {"AX": 0, "BX": 1, "CX": 2, "DX": 3}

SYS = {"NOP": 0, "HALT": 1, "RET": 2, "MOVB": 3, "MOVW": 4, "MOVBR": 5}
# AluOp (byte de operando de F_ALU*)
ALU_OP = {"MOV": 0, "ADD": 1, "ADC": 2, "SUB": 3, "SBC": 4, "CMP": 5,
          "AND": 6, "OR": 7, "XOR": 8}
UNARY = {"NOT": F_NOT, "MUL": F_MUL, "DIV": F_DIV}
# condiciones de JMP/CALL (3 bits bajos); NV va aparte, en F_JX
COND = {"": 0, "Z": 1, "NZ": 2, "C": 3, "NC": 4, "N": 5, "NN": 6, "V": 7}
JX_JMPNV, JX_CALLNV, JX_JMPR, JX_CALLR = 0, 1, 2, 3
R16_OP = {"MOV": 0, "ADD": 1, "SUB": 2, "CMP": 3}
R16_ADD8, R16_SUB8 = 4, 5
R16I_MOV, R16I_ADD, R16I_SUB, R16I_CMP = 0, 1, 2, 3


class AsmError(Exception):
    def __init__(self, msg, lineno=None):
        super().__init__(msg)
        self.lineno = lineno


def opcode(family, low):
    return ((family << 3) | (low & 7)) & 0xFF


# ---------------------------------------------------------------------------
# expresiones
# ---------------------------------------------------------------------------
def make_env(symbols, here):
    env = {"__builtins__": {}}
    env.update(symbols)
    env["lo"] = lambda v: v & 0xFF
    env["hi"] = lambda v: (v >> 8) & 0xFF
    env["here"] = here
    return env


CHAR_RE = re.compile(r"'(\\.|[^'\\])'")
TOKEN_RE = re.compile(
    r"0[xX][0-9A-Fa-f]+|0[bB][01]+|0[oO][0-7]+|\d+|[A-Za-z_][A-Za-z_0-9]*")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", "'": "'", '"': '"'}


def _char_value(m):
    s = m.group(1)
    if s.startswith("\\"):
        return str(ord(_ESCAPES.get(s[1], s[1])))
    return str(ord(s))


def eval_expr(text, symbols, here, lineno):
    text = text.strip()
    if not text:
        raise AsmError("expresion vacia", lineno)
    text = CHAR_RE.sub(_char_value, text)
    # $ y . -> posicion actual
    text = re.sub(r"(?<![A-Za-z_0-9])[.$](?![A-Za-z_0-9])", str(here), text)
    # comprueba simbolos desconocidos (los numeros literales se saltan)
    for m in TOKEN_RE.finditer(text):
        name = m.group(0)
        if name[0].isdigit():
            continue
        if name in ("lo", "hi", "here"):
            continue
        if name not in symbols:
            raise AsmError(f"simbolo indefinido: {name}", lineno)
    try:
        val = eval(text, make_env(symbols, here))  # noqa: S307 - entorno restringido
    except AsmError:
        raise
    except Exception as e:  # noqa: BLE001
        raise AsmError(f"expresion invalida '{text}': {e}", lineno)
    return int(val)


# ---------------------------------------------------------------------------
# troceado de una linea en campos respetando "..." , [..] , (..)
# ---------------------------------------------------------------------------
def strip_comment(line):
    out = []
    q = None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch
            out.append(ch)
            continue
        if ch == ";":
            break
        out.append(ch)
    return "".join(out).rstrip()


def split_operands(text):
    """divide por comas de nivel 0 (fuera de [], (), '', "")"""
    parts, buf, depth, q = [], [], 0, None
    for ch in text:
        if q:
            buf.append(ch)
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch
            buf.append(ch)
        elif ch in "[(":
            depth += 1
            buf.append(ch)
        elif ch in "])":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    if buf or parts:
        parts.append("".join(buf).strip())
    return [p for p in parts if p != ""]


def parse_string(tok, lineno):
    if len(tok) < 2 or tok[0] != '"' or tok[-1] != '"':
        raise AsmError(f"cadena mal formada: {tok}", lineno)
    body, out, i = tok[1:-1], [], 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            out.append(_ESCAPES.get(body[i + 1], body[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out).encode("latin-1")


# ---------------------------------------------------------------------------
# clasificacion de operandos de instruccion
# ---------------------------------------------------------------------------
class Operand:
    def __init__(self, kind, value):
        self.kind = kind      # 'reg' 'imm' 'mem' 'port' 'addr'
        self.value = value    # indice de registro, o texto de expresion


def classify(tok, lineno):
    t = tok.strip()
    if t.startswith("#"):
        return Operand("imm", t[1:].strip())
    if t.startswith("[") and t.endswith("]"):
        inner = t[1:-1].strip()
        if inner.upper() in REG16:
            # [AX]/[BX]/[CX]/[DX]: direccion indirecta via registro (LDA/STA)
            return Operand("memr", REG16[inner.upper()])
        return Operand("mem", inner)
    if t.startswith("(") and t.endswith(")"):
        inner = t[1:-1].strip()
        if inner.upper() in REG16:
            # (AX)/(BX)/(CX)/(DX): puerto indirecto via registro (IN/OUT)
            return Operand("portr", REG16[inner.upper()])
        return Operand("port", inner)
    if t.upper() in REG:
        return Operand("reg", REG[t.upper()])
    if t.upper() in REG16:
        # AX/BX/CX/DX sueltos (sin [] ni ()): solo tiene sentido como
        # destino de ADD/SUB (forma de 16 bits) o de INC/DEC -- ver
        # _emit_instr. El nombre del registro es justo lo que distingue
        # esta forma de la de 8 bits, sin mnemonico aparte (ADD sigue
        # siendo ADD).
        return Operand("reg16", REG16[t.upper()])
    return Operand("addr", t)


# ---------------------------------------------------------------------------
# ensamblador
# ---------------------------------------------------------------------------
CATEGORIES = {"SYSTEM": 1, "GAME": 2, "PROGRAM": 3, "UTILITY": 4, "DEMO": 5, "DOCS": 6}
NAME_MAX = 14
LIB_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "programs", "lib"))


class Assembler:
    def __init__(self):
        self.symbols = {}
        self.slot = None
        self.name = None        # .name    (cabecera del slot, ver storage.h)
        self.category = None    # .category
        self.origins = []       # linea expandida -> (fichero, linea original)
        self.image = bytearray(IMAGE_SIZE)
        self.max_addr = 0
        self.listing = []       # (lineno, addr, bytes, texto)

    # -- utilidades de emision --------------------------------------------
    def _put(self, addr, data, lineno):
        end = addr + len(data)
        if end > IMAGE_SIZE:
            raise AsmError(f"la imagen se sale de 64 KiB (0x{end:X})", lineno)
        self.image[addr:end] = bytes(data)
        self.max_addr = max(self.max_addr, end)

    # -- pass 1: calcula longitudes y define simbolos --------------------
    def first_pass(self, lines):
        pc = 0
        items = []          # (lineno, pc, kind, payload)
        pending_equ = []
        for lineno, raw in enumerate(lines, 1):
            line = strip_comment(raw)
            if not line.strip():
                continue
            work = line.strip()

            # etiqueta al principio
            m = re.match(r"^([A-Za-z_.][A-Za-z_.0-9]*)\s*:\s*(.*)$", work)
            if m:
                label = m.group(1)
                if label in self.symbols:
                    raise AsmError(f"etiqueta repetida: {label}", lineno)
                self.symbols[label] = pc
                work = m.group(2).strip()
                if not work:
                    continue

            # NAME = EXPR   /   NAME .equ EXPR
            m = re.match(r"^([A-Za-z_.][A-Za-z_.0-9]*)\s*=\s*(.+)$", work)
            if not m:
                m = re.match(r"^([A-Za-z_.][A-Za-z_.0-9]*)\s+\.equ\s+(.+)$", work, re.I)
            if m:
                pending_equ.append((lineno, m.group(1), m.group(2)))
                continue

            parts = work.split(None, 1)
            mnem = parts[0].upper()
            rest = parts[1].strip() if len(parts) > 1 else ""

            if mnem.startswith("."):
                kind, size = self._dir_size(mnem, rest, pc, lineno)
                items.append((lineno, pc, "dir", (mnem, rest)))
                if kind == "org":
                    pc = size
                else:
                    pc += size
                continue

            size = self._instr_size(mnem, rest, lineno)
            items.append((lineno, pc, "instr", (mnem, rest)))
            pc += size

        # resuelve .equ (varias vueltas por dependencias hacia adelante)
        for _ in range(len(pending_equ) + 2):
            progress = False
            unresolved = []
            for ln, name, expr in pending_equ:
                try:
                    self.symbols[name] = eval_expr(expr, self.symbols, 0, ln)
                    progress = True
                except AsmError:
                    unresolved.append((ln, name, expr))
            pending_equ = unresolved
            if not pending_equ:
                break
            if not progress:
                ln, name, expr = pending_equ[0]
                raise AsmError(f".equ irresoluble: {name} = {expr}", ln)
        return items

    def _dir_size(self, mnem, rest, pc, lineno):
        d = mnem.lower()
        if d in (".name", ".category"):
            return "data", 0
        if d == ".org":
            return "org", eval_expr(rest, self.symbols, pc, lineno)
        if d in (".space", ".res"):
            return "data", eval_expr(rest, self.symbols, pc, lineno)
        if d in (".slot",):
            return "data", 0
        if d == ".db":
            return "data", len(self._db_bytes(rest, pc, lineno, evaluate=False))
        if d == ".dw":
            return "data", 2 * len(split_operands(rest))
        if d == ".ascii":
            return "data", len(parse_string(rest.strip(), lineno))
        if d == ".asciiz":
            return "data", len(parse_string(rest.strip(), lineno)) + 1
        raise AsmError(f"directiva desconocida: {mnem}", lineno)

    def _db_bytes(self, rest, here, lineno, evaluate=True):
        out = bytearray()
        for tok in split_operands(rest):
            if tok.startswith('"'):
                out += parse_string(tok, lineno)
            elif evaluate:
                out.append(eval_expr(tok, self.symbols, here, lineno) & 0xFF)
            else:
                out.append(0)
        return out

    # -- tamano de una instruccion (sin evaluar expresiones) -------------
    def _instr_size(self, mnem, rest, lineno):
        # mismo codificador que la pasada 2, pero sin evaluar expresiones
        # (las etiquetas aun no se conocen): la longitud solo depende del
        # tipo de cada operando, nunca de su valor
        return len(self._encode(mnem, rest, 0, lineno, evaluate=False))

    # -- pass 2: emite bytes --------------------------------------------
    def second_pass(self, items):
        for lineno, pc, kind, payload in items:
            if kind == "dir":
                self._emit_dir(pc, payload, lineno)
            else:
                data = self._emit_instr(pc, payload, lineno)
                self._put(pc, data, lineno)
                self.listing.append((lineno, pc, bytes(data), " ".join(payload).strip()))

    def _emit_dir(self, pc, payload, lineno):
        mnem, rest = payload
        d = mnem.lower()
        if d == ".org":
            return
        if d == ".slot":
            self.slot = eval_expr(rest, self.symbols, pc, lineno)
            return
        if d == ".name":
            nm = parse_string(rest.strip(), lineno)
            if len(nm) > NAME_MAX or any(c < 0x20 or c > 0x7E for c in nm):
                raise AsmError(f".name: hasta {NAME_MAX} caracteres ASCII imprimibles", lineno)
            self.name = nm.decode()
            return
        if d == ".category":
            key = rest.strip().upper()
            self.category = CATEGORIES[key] if key in CATEGORIES else \
                eval_expr(rest, self.symbols, pc, lineno) & 0xFF
            return
        if d in (".space", ".res"):
            return  # ya es 0
        if d == ".db":
            data = self._db_bytes(rest, pc, lineno)
        elif d == ".dw":
            data = bytearray()
            for tok in split_operands(rest):
                v = eval_expr(tok, self.symbols, pc, lineno) & 0xFFFF
                data += bytes((v & 0xFF, (v >> 8) & 0xFF))
        elif d == ".ascii":
            data = parse_string(rest.strip(), lineno)
        elif d == ".asciiz":
            data = parse_string(rest.strip(), lineno) + b"\x00"
        else:
            raise AsmError(f"directiva desconocida: {mnem}", lineno)
        self._put(pc, data, lineno)
        self.listing.append((lineno, pc, bytes(data), " ".join(payload).strip()))

    def _imm8(self, op, pc, lineno):
        if not self._evaluate:
            return 0
        return eval_expr(op.value, self.symbols, pc, lineno) & 0xFF

    def _addr16(self, op, pc, lineno):
        if not self._evaluate:
            return 0, 0
        v = eval_expr(op.value, self.symbols, pc, lineno) & 0xFFFF
        return v & 0xFF, (v >> 8) & 0xFF

    def _emit_instr(self, pc, payload, lineno):
        mnem, rest = payload
        return self._encode(mnem, rest, pc, lineno, evaluate=True)

    def _encode(self, mnem, rest, pc, lineno, evaluate):
        self._evaluate = evaluate
        ops = [classify(t, lineno) for t in split_operands(rest)]
        kinds = tuple(o.kind for o in ops)

        def need(cond, msg):
            if not cond:
                raise AsmError(msg, lineno)

        if mnem in SYS:
            need(not ops, f"{mnem} no lleva operandos"
                          + (" (usa BX=origen, DX=destino, CX=cuenta)" if mnem.startswith("MOV") else ""))
            return [opcode(F_SYS, SYS[mnem])]

        if mnem in UNARY:
            need(kinds == ("reg",), f"{mnem} reg")
            return [opcode(UNARY[mnem], ops[0].value)]

        if mnem in ("INC", "DEC"):
            if kinds == ("reg",):
                return [opcode(F_INC if mnem == "INC" else F_DEC, ops[0].value)]
            need(kinds == ("reg16",), f"{mnem} reg  o  {mnem} AX|BX|CX|DX")
            return [opcode(F_INCDEC16, (0 if mnem == "INC" else 4) | ops[0].value)]

        if mnem in ("PUSH", "POP"):
            if kinds == ("reg",):
                return [opcode(F_PUSH if mnem == "PUSH" else F_POP, ops[0].value)]
            need(kinds == ("reg16",), f"{mnem} reg  o  {mnem} AX|BX|CX|DX")
            return [opcode(F_PUSHPOP16, (0 if mnem == "PUSH" else 4) | ops[0].value)]

        if mnem in ("SHR", "SHL"):
            fam = F_SHR if mnem == "SHR" else F_SHL
            if kinds == ("reg",):
                return [opcode(fam, ops[0].value), 0]        # 1 bit
            need(kinds == ("reg", "imm"), f"{mnem} reg  o  {mnem} reg,#N")
            n = self._imm8(ops[1], pc, lineno) if evaluate else 1
            need(1 <= n <= 8, f"{mnem}: N debe ser 1..8 (era {n})")
            return [opcode(fam, ops[0].value), n - 1]

        if mnem in ("LDA", "IN"):
            need(len(ops) == 2 and ops[0].kind == "reg", f"{mnem} reg,...")
            reg, src = ops
            if mnem == "LDA":
                if src.kind == "memr":
                    return [opcode(F_LDAR, reg.value), src.value]
                need(src.kind == "mem", "LDA reg,[addr] o LDA reg,[AX|BX|CX|DX]")
                lo, hi = self._addr16(src, pc, lineno)
                return [opcode(F_LDA, reg.value), lo, hi]
            if src.kind == "portr":
                return [opcode(F_INR, reg.value), src.value]
            need(src.kind == "port", "IN reg,(port) o IN reg,(AX|BX|CX|DX)")
            lo, hi = self._addr16(src, pc, lineno)
            return [opcode(F_IN, reg.value), lo, hi]

        if mnem in ("STA", "OUT"):
            # destino primero: STA [addr],reg / OUT (port),reg
            need(len(ops) == 2 and ops[1].kind == "reg", f"{mnem} ...,reg")
            dst, reg = ops
            if mnem == "STA":
                if dst.kind == "memr":
                    return [opcode(F_STAR, reg.value), dst.value]
                need(dst.kind == "mem", "STA [addr],reg o STA [AX|BX|CX|DX],reg")
                lo, hi = self._addr16(dst, pc, lineno)
                return [opcode(F_STA, reg.value), lo, hi]
            if dst.kind == "portr":
                return [opcode(F_OUTR, reg.value), dst.value]
            need(dst.kind == "port", "OUT (port),reg o OUT (AX|BX|CX|DX),reg")
            lo, hi = self._addr16(dst, pc, lineno)
            return [opcode(F_OUT, reg.value), lo, hi]

        if mnem in ALU_OP:
            need(len(ops) == 2, f"{mnem} necesita 2 operandos")
            dst, src = ops
            if dst.kind == "reg16":
                # formas de 16 bits: mismo mnemonico, detectadas por que el
                # destino es AX/BX/CX/DX
                d = dst.value
                if src.kind == "reg16":
                    need(mnem in R16_OP, f"{mnem}: no hay forma reg16,reg16 (MOV/ADD/SUB/CMP)")
                    return [opcode(F_R16, R16_OP[mnem]), (d << 3) | src.value]
                if src.kind == "reg":
                    need(mnem in ("ADD", "SUB"), f"{mnem}: no hay forma reg16,reg8 (ADD/SUB)")
                    return [opcode(F_R16, R16_ADD8 if mnem == "ADD" else R16_SUB8), (d << 3) | src.value]
                need(src.kind == "imm", f"{mnem}: segundo operando invalido para {mnem} reg16")
                if mnem in ("MOV", "CMP"):
                    lo, hi = self._addr16(src, pc, lineno)
                    return [opcode(F_R16I, R16I_MOV if mnem == "MOV" else R16I_CMP), d, lo, hi]
                need(mnem in ("ADD", "SUB"), f"{mnem}: no hay forma reg16,#imm")
                return [opcode(F_R16I, R16I_ADD if mnem == "ADD" else R16I_SUB), d,
                        self._imm8(src, pc, lineno)]
            need(dst.kind == "reg", f"{mnem}: destino debe ser registro")
            op = ALU_OP[mnem]
            r = dst.value
            if src.kind == "reg":
                return [opcode(F_ALURR, r), (op << 3) | src.value]
            if src.kind == "imm":
                if mnem == "MOV":
                    return [opcode(F_LDI, r), self._imm8(src, pc, lineno)]
                return [opcode(F_ALUI, r), op, self._imm8(src, pc, lineno)]
            if src.kind == "mem":
                lo, hi = self._addr16(src, pc, lineno)
                if mnem == "MOV":
                    return [opcode(F_LDA, r), lo, hi]
                return [opcode(F_ALUM, r), op, lo, hi]
            if src.kind == "memr":
                if mnem == "MOV":
                    return [opcode(F_LDAR, r), src.value]
                return [opcode(F_ALUP, r), (op << 2) | src.value]
            raise AsmError(f"{mnem}: segundo operando invalido", lineno)

        if mnem.startswith("JMP") or mnem.startswith("CALL"):
            is_jmp = mnem.startswith("JMP")
            suffix = mnem[3:] if is_jmp else mnem[4:]
            need(len(ops) == 1, f"{mnem} addr  o  {mnem} AX|BX|CX|DX")
            if ops[0].kind == "reg16":
                need(suffix == "", f"{mnem}: el salto por registro no lleva condicion")
                return [opcode(F_JX, JX_JMPR if is_jmp else JX_CALLR), ops[0].value]
            need(ops[0].kind in ("addr", "mem"), f"{mnem} addr")
            lo, hi = self._addr16(Operand("addr", ops[0].value), pc, lineno)
            if suffix == "NV":
                return [opcode(F_JX, JX_JMPNV if is_jmp else JX_CALLNV), lo, hi]
            need(suffix in COND, f"condicion desconocida: {mnem}")
            return [opcode(F_JMP if is_jmp else F_CALL, COND[suffix]), lo, hi]

        raise AsmError(f"instruccion desconocida: {mnem}", lineno)

    # -- .include: expande el texto antes de ensamblar, recordando de que
    # fichero y linea viene cada linea (para los mensajes de error) --------
    def _expand(self, text, path, seen):
        out = []
        base = os.path.dirname(os.path.abspath(path)) if path else os.getcwd()
        for i, raw in enumerate(text.splitlines(), 1):
            m = re.match(r'^\s*\.include\s+"([^"]+)"\s*(;.*)?$', raw, re.I)
            if not m:
                out.append(raw)
                self.origins.append((path or "<texto>", i))
                continue
            name = m.group(1)
            cands = [os.path.join(base, name), os.path.join(LIB_DIR, name)]
            found = next((c for c in cands if os.path.isfile(c)), None)
            if found is None:
                raise AsmError(f'.include: no encuentro "{name}" ({path or "<texto>"}:{i})')
            found = os.path.abspath(found)
            if found in seen:
                continue            # cada fichero una sola vez
            seen.add(found)
            with open(found, "r", encoding="utf-8") as f:
                out += self._expand(f.read(), found, seen)
        return out

    def assemble(self, text, path=None):
        self.origins = []
        try:
            lines = self._expand(text, path, set())
        except AsmError as e:
            raise AsmError(str(e)) from None
        try:
            items = self.first_pass(lines)
            self.second_pass(items)
        except AsmError as e:
            where = ""
            if e.lineno and 0 < e.lineno <= len(self.origins):
                fn, ln = self.origins[e.lineno - 1]
                where = f" (linea {ln})" if fn == (path or "<texto>") else f" ({os.path.basename(fn)}:{ln})"
            elif e.lineno:
                where = f" (linea {e.lineno})"
            raise AsmError(f"{e}{where}") from None
        return bytes(self.image)

    def format_listing(self):
        out = ["  linea  addr  bytes            fuente"]
        for lineno, addr, data, txt in self.listing:
            hexb = " ".join(f"{b:02X}" for b in data)
            out.append(f"  {lineno:5d}  {addr:04X}  {hexb:<16}  {txt}")
        out.append("")
        out.append("  simbolos:")
        for name, val in sorted(self.symbols.items(), key=lambda kv: kv[1]):
            out.append(f"    {name:<20} = 0x{val:04X}  ({val})")
        return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="ensamblador de compi")
    ap.add_argument("source")
    ap.add_argument("-o", "--output", help="imagen de salida (64 KiB)")
    ap.add_argument("--list", dest="listing", help="escribe un listado")
    ap.add_argument("--slot", type=int, help="anota el slot de flash de destino")
    args = ap.parse_args(argv)

    with open(args.source, "r", encoding="utf-8") as f:
        text = f.read()

    asm = Assembler()
    try:
        image = asm.assemble(text, args.source)
    except AsmError as e:
        print(f"casm: error: {e}", file=sys.stderr)
        return 1

    slot = args.slot if args.slot is not None else asm.slot
    out = args.output or (args.source.rsplit(".", 1)[0] + ".bin")
    used = max(1, asm.max_addr)
    with open(out, "wb") as f:
        f.write(image[:used])

    print(f"casm: {out}  ({used} bytes; el resto hasta {IMAGE_SIZE} "
          f"lo rellena el aparato con ceros al cargar)")
    if slot is not None:
        print(f"casm: slot de destino sugerido: {slot}")
    if asm.name is not None or asm.category is not None:
        print(f"casm: nombre {asm.name!r}, categoria {asm.category}")

    if args.listing:
        with open(args.listing, "w", encoding="utf-8") as f:
            f.write(asm.format_listing() + "\n")
        print(f"casm: listado en {args.listing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
