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

Instrucciones (reg = AL AH BL BH CL CH DL DH):

    NOP  HALT  RET
    MOV reg,#imm     MOV dst,src
    LDA reg,[addr]   STA [addr],reg     (o [AX|BX|CX|DX]: indirecto por registro)
    ADD/SUB/AND/OR/XOR  reg,[addr] | reg,#imm | dst,src
    CMP reg,#imm | dst,src
    NOT/SHR/SHL/PUSH/POP reg
    IN  reg,(port)   OUT (port),reg     (o (AX|BX|CX|DX): indirecto por registro)
    JMP/JMPZ/JMPNZ/JMPC/JMPNC/JMPN/JMPNN   addr
    CALL/CALLZ/CALLNZ/CALLC/CALLNC/CALLN/CALLNN  addr

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
import re
import sys

IMAGE_SIZE = 65536

REG = {"AL": 0, "AH": 1, "BL": 2, "BH": 3, "CL": 4, "CH": 5, "DL": 6, "DH": 7}

# familias de opcode (isa.h)
F_NOP, F_HALT, F_LDI, F_LDA, F_STA = 0, 1, 2, 3, 4
F_ADD, F_SUB, F_AND, F_OR, F_XOR = 5, 6, 7, 8, 9
F_NOT, F_SHR, F_SHL, F_IN, F_OUT = 10, 11, 12, 13, 14
F_PUSH, F_POP, F_JMP, F_CALL, F_RET = 15, 16, 17, 18, 19
F_ALUI, F_EXT = 20, 31
# Direccionamiento indirecto por registro de 16 bits: LEN 2 (opcode + par
# AX/BX/CX/DX), en vez de opcode + addr16/port16 de 2 bytes.
F_LDAR, F_STAR, F_INR, F_OUTR = 21, 22, 23, 24
REG16 = {"AX": 0, "BX": 1, "CX": 2, "DX": 3}

MEM_ALU = {"ADD": F_ADD, "SUB": F_SUB, "AND": F_AND, "OR": F_OR, "XOR": F_XOR}
# AluOp (bits bajos en EXT y ALUI)
ALU_OP = {"MOV": 0, "ADD": 1, "SUB": 2, "CMP": 3, "AND": 4, "OR": 5, "XOR": 6}
COND = {"": 0, "Z": 1, "NZ": 2, "C": 3, "NC": 4, "N": 5, "NN": 6}


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
    return Operand("addr", t)


# ---------------------------------------------------------------------------
# ensamblador
# ---------------------------------------------------------------------------
class Assembler:
    def __init__(self):
        self.symbols = {}
        self.slot = None
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
        ops = [classify(t, lineno) for t in split_operands(rest)]
        if mnem in ("NOP", "HALT", "RET"):
            return 1
        if mnem in ("NOT", "SHR", "SHL", "PUSH", "POP"):
            return 1
        if mnem == "MOV":
            if len(ops) != 2:
                raise AsmError("MOV necesita 2 operandos", lineno)
            return 2  # LDI (reg,#imm) o EXT (dst,src)
        if mnem in ("ADD", "SUB", "AND", "OR", "XOR", "CMP"):
            if len(ops) != 2:
                raise AsmError(f"{mnem} necesita 2 operandos", lineno)
            src = ops[1]
            if src.kind == "reg":
                return 2   # EXT
            if src.kind == "imm":
                return 3   # ALUI
            if src.kind == "mem":
                return 3   # familia con memoria
            raise AsmError(f"{mnem}: segundo operando invalido", lineno)
        if mnem in ("LDA", "IN"):
            if len(ops) != 2:
                raise AsmError(f"{mnem} necesita 2 operandos", lineno)
            return 2 if ops[1].kind in ("memr", "portr") else 3
        if mnem in ("STA", "OUT"):
            if len(ops) != 2:
                raise AsmError(f"{mnem} necesita 2 operandos", lineno)
            return 2 if ops[0].kind in ("memr", "portr") else 3
        if mnem.startswith("JMP") or mnem.startswith("CALL"):
            return 3
        raise AsmError(f"instruccion desconocida: {mnem}", lineno)

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
        return eval_expr(op.value, self.symbols, pc, lineno) & 0xFF

    def _addr16(self, op, pc, lineno):
        v = eval_expr(op.value, self.symbols, pc, lineno) & 0xFFFF
        return v & 0xFF, (v >> 8) & 0xFF

    def _emit_instr(self, pc, payload, lineno):
        mnem, rest = payload
        ops = [classify(t, lineno) for t in split_operands(rest)]

        if mnem == "NOP":
            return [opcode(F_NOP, 0)]
        if mnem == "HALT":
            return [opcode(F_HALT, 0)]
        if mnem == "RET":
            return [opcode(F_RET, 0)]

        if mnem in ("NOT", "SHR", "SHL", "PUSH", "POP"):
            fam = {"NOT": F_NOT, "SHR": F_SHR, "SHL": F_SHL,
                   "PUSH": F_PUSH, "POP": F_POP}[mnem]
            if len(ops) != 1 or ops[0].kind != "reg":
                raise AsmError(f"{mnem} reg", lineno)
            return [opcode(fam, ops[0].value)]

        if mnem == "MOV":
            dst, src = ops
            if dst.kind != "reg":
                raise AsmError("MOV: destino debe ser registro", lineno)
            if src.kind == "imm":
                return [opcode(F_LDI, dst.value), self._imm8(src, pc, lineno)]
            if src.kind == "reg":
                return [opcode(F_EXT, ALU_OP["MOV"]), (dst.value << 3) | src.value]
            raise AsmError("MOV: fuente debe ser #imm o registro (usa LDA para memoria)", lineno)

        if mnem in ("ADD", "SUB", "AND", "OR", "XOR", "CMP"):
            dst, src = ops
            if dst.kind != "reg":
                raise AsmError(f"{mnem}: destino debe ser registro", lineno)
            if src.kind == "reg":
                return [opcode(F_EXT, ALU_OP[mnem]), (dst.value << 3) | src.value]
            if src.kind == "imm":
                return [opcode(F_ALUI, ALU_OP[mnem]), dst.value & 7,
                        self._imm8(src, pc, lineno)]
            if src.kind == "mem":
                if mnem == "CMP":
                    raise AsmError("CMP no tiene forma con memoria (usa SUB o carga a registro)", lineno)
                lo, hi = self._addr16(src, pc, lineno)
                return [opcode(MEM_ALU[mnem], dst.value), lo, hi]
            raise AsmError(f"{mnem}: segundo operando invalido", lineno)

        if mnem == "LDA":
            reg, mem = ops
            if reg.kind != "reg" or mem.kind not in ("mem", "memr"):
                raise AsmError("LDA reg,[addr] o LDA reg,[AX|BX|CX|DX]", lineno)
            if mem.kind == "memr":
                return [opcode(F_LDAR, reg.value), mem.value]
            lo, hi = self._addr16(mem, pc, lineno)
            return [opcode(F_LDA, reg.value), lo, hi]

        if mnem == "STA":
            # El primer operando es el destino (mem[addr] = reg), igual que
            # el resto de instrucciones: STA [addr],reg. Codificacion igual
            # que LDA (mismos bytes, solo cambia el orden en que se leen).
            mem, reg = ops
            if mem.kind not in ("mem", "memr") or reg.kind != "reg":
                raise AsmError("STA [addr],reg o STA [AX|BX|CX|DX],reg", lineno)
            if mem.kind == "memr":
                return [opcode(F_STAR, reg.value), mem.value]
            lo, hi = self._addr16(mem, pc, lineno)
            return [opcode(F_STA, reg.value), lo, hi]

        if mnem == "IN":
            reg, port = ops
            if reg.kind != "reg" or port.kind not in ("port", "portr"):
                raise AsmError("IN reg,(port) o IN reg,(AX|BX|CX|DX)", lineno)
            if port.kind == "portr":
                return [opcode(F_INR, reg.value), port.value]
            lo, hi = self._addr16(port, pc, lineno)
            return [opcode(F_IN, reg.value), lo, hi]

        if mnem == "OUT":
            # Destino primero (port_write(port,reg)): OUT (port),reg.
            port, reg = ops
            if port.kind not in ("port", "portr") or reg.kind != "reg":
                raise AsmError("OUT (port),reg o OUT (AX|BX|CX|DX),reg", lineno)
            if port.kind == "portr":
                return [opcode(F_OUTR, reg.value), port.value]
            lo, hi = self._addr16(port, pc, lineno)
            return [opcode(F_OUT, reg.value), lo, hi]

        if mnem.startswith("JMP") or mnem.startswith("CALL"):
            base = F_JMP if mnem.startswith("JMP") else F_CALL
            suffix = mnem[3:] if mnem.startswith("JMP") else mnem[4:]
            if suffix not in COND:
                raise AsmError(f"condicion desconocida: {mnem}", lineno)
            if len(ops) != 1 or ops[0].kind not in ("addr", "mem"):
                raise AsmError(f"{mnem} addr", lineno)
            lo, hi = self._addr16(Operand("addr", ops[0].value), pc, lineno)
            return [opcode(base, COND[suffix]), lo, hi]

        raise AsmError(f"instruccion desconocida: {mnem}", lineno)

    # -- api -----------------------------------------------------------
    def assemble(self, text):
        lines = text.splitlines()
        try:
            items = self.first_pass(lines)
            self.second_pass(items)
        except AsmError as e:
            where = f" (linea {e.lineno})" if e.lineno else ""
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
        image = asm.assemble(text)
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

    if args.listing:
        with open(args.listing, "w", encoding="utf-8") as f:
            f.write(asm.format_listing() + "\n")
        print(f"casm: listado en {args.listing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
