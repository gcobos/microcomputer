#!/usr/bin/env python3
"""compi_disasm — vuelca un .bin de compi como texto ensamblador (la misma
sintaxis que tools/casm.py, ver programs/README.md: "es la del desensamblador
[src/disasm.cpp] mas etiquetas y directivas"), REENSAMBLABLE byte a byte:

    python3 tools/compi_disasm.py demo.bin -o demo_out.asm
    python3 tools/casm.py demo_out.asm -o demo_out.bin   # ida y vuelta exacta

Solo desensambla los bytes que trae el fichero, SIN RELLENAR con ceros hasta
64 KiB si es mas corto (algo normal: casm.py recorta hasta la ultima
direccion usada, y compi_recv.py --len trae solo un trozo a proposito) --
inventarse el resto como si fuera NOP produciria decenas de miles de lineas
de relleno que no reflejan nada real, y con --len el resto ni siquiera es
zero, es simplemente "no se pidio".

Recorre la imagen linealmente desde 0x0000, igual que el listado del panel
(src/disasm.cpp: listBase/prevInstrStart) y que el propio bicho al ejecutar:
el primer byte de cada "instruccion" fija por si solo su longitud (1-3), asi
que la particion en instrucciones es total y deterministica -- no hace falta
adivinar donde empieza cada una.

OJO -- esta herramienta NO DISTINGUE CODIGO DE DATOS, igual que el listado
del panel tampoco lo hace: si el .bin tiene tablas de datos incrustadas
entre instrucciones (habitual en los .asm de programs/, p.ej. la tabla de
notas de musica.asm o las tablas de vertices de cubo.asm), esos bytes se
recorreran linealmente como si fueran instrucciones y es probable que la
particion se desincronice de la real a partir de ahi -- lo que sigue tras
una tabla asi puede salir con pinta de sopa de letras. Sigue siendo
REENSAMBLABLE byte a byte pase lo que pase (ver mas abajo), solo que no
necesariamente LEGIBLE en esas zonas.

Por que el resultado reensambla EXACTO: cada mnemonico que emite es el mismo
texto, byte a byte, que ya emite disasm.cpp (por eso casm.py lo entiende sin
cambios). Las combinaciones de bits que NO tienen un texto que reensamble
exacto -- familias o sub-operaciones libres, bits fuera del formato, u
operaciones MOV en las formas de la ALU con inmediato/memoria (casm.py las
escribiria con la forma corta LDI/LDA, que no ocupa los mismos bytes) -- se
vuelcan como `.db` con los bytes crudos en vez de inventarse un mnemonico,
para no perder ni cambiar ni un bit.

Genera una etiqueta L<addr> (p.ej. L0100) para cada destino de JMP/CALL que
caiga justo en el arranque de "su" instruccion segun esta misma particion; si
no (porque cae en mitad de una tabla de datos mal interpretada, ver arriba),
se deja la direccion en crudo (0x....), que sigue siendo valido.
"""
import argparse
import sys

IMAGE_SIZE = 65536

# Familias de opcode (include/isa.h, ISA version 2): opcode = family<<3 | bajo3.
(F_SYS, F_LDI, F_LDA, F_STA, F_LDAR, F_STAR, F_IN, F_OUT, F_INR, F_OUTR,
 F_ALURR, F_ALUI, F_ALUM, F_ALUP, F_NOT, F_SHR, F_SHL, F_MUL, F_DIV,
 F_INC, F_DEC, F_PUSH, F_POP, F_JMP, F_CALL, F_JX, F_R16, F_R16I,
 F_INCDEC16, F_PUSHPOP16) = range(30)

REG8 = ["AL", "AH", "BL", "BH", "CL", "CH", "DL", "DH"]
REG16 = ["AX", "BX", "CX", "DX"]
COND = ["", "Z", "NZ", "C", "NC", "N", "NN", "V"]
ALU_NAMES = ["MOV", "ADD", "ADC", "SUB", "SBC", "CMP", "AND", "OR", "XOR"]
SYS_NAMES = ["NOP", "HALT", "RET", "MOVB", "MOVW", "MOVBR"]
UNARY = {F_NOT: "NOT", F_MUL: "MUL", F_DIV: "DIV", F_INC: "INC", F_DEC: "DEC",
         F_PUSH: "PUSH", F_POP: "POP"}

# Longitud (bytes) de cada familia -- igual que instrLen() en disasm.cpp.
_LEN2 = {F_LDI, F_LDAR, F_STAR, F_INR, F_OUTR, F_ALURR, F_ALUP, F_SHR, F_SHL}
_LEN3 = {F_LDA, F_STA, F_IN, F_OUT, F_ALUI, F_JMP, F_CALL}


def instr_len(mem, addr):
    op = mem[addr]
    fam, r = op >> 3, op & 7
    if fam in _LEN3:
        return 3
    if fam in _LEN2:
        return 2
    if fam == F_ALUM:
        return 4
    if fam == F_JX:
        return 3 if r <= 1 else 2 if r <= 3 else 1
    if fam == F_R16:
        return 2 if r <= 5 else 1
    if fam == F_R16I:
        return 4 if r in (0, 3) else 3 if r in (1, 2) else 1
    return 1


def rd(mem, addr):
    return mem[addr] if 0 <= addr < len(mem) else 0


class Instr:
    __slots__ = ("addr", "length", "text", "target", "raw")

    def __init__(self, addr, length, text, target=None, raw=None):
        self.addr = addr
        self.length = length
        self.text = text          # None si `raw` (fallback .db)
        self.target = target      # direccion referenciada (JMP/CALL), o None
        self.raw = raw            # lista de bytes crudos si no hay mnemonico


def decode_one(mem, addr):
    """Una instruccion: texto que casm.py reensambla a EXACTAMENTE los mismos
    bytes, o None + raw (los bytes en crudo, .db) si no hay tal texto --
    p.ej. bits fuera del formato, o una forma que casm escribiria con otra
    codificacion mas corta (MOV reg,#imm en la ALU en vez de LDI)."""
    op = mem[addr]
    fam, r = op >> 3, op & 7
    b1 = rd(mem, addr + 1)
    b2 = rd(mem, addr + 2)
    b3 = rd(mem, addr + 3)
    a16 = b1 | (b2 << 8)
    a23 = b2 | (b3 << 8)
    n = instr_len(mem, addr)

    def raw():
        return Instr(addr, n, None, raw=[rd(mem, addr + i) for i in range(n)])

    if fam == F_SYS:
        return Instr(addr, 1, SYS_NAMES[r]) if r < len(SYS_NAMES) else raw()
    if fam == F_LDI:
        return Instr(addr, 2, f"MOV {REG8[r]},#0x{b1:02X}")
    if fam == F_LDA:
        return Instr(addr, 3, f"LDA {REG8[r]},[0x{a16:04X}]")
    if fam == F_STA:
        return Instr(addr, 3, f"STA [0x{a16:04X}],{REG8[r]}")
    if fam in (F_LDAR, F_STAR, F_INR, F_OUTR):
        if b1 & 0xFC:
            return raw()
        p = REG16[b1 & 3]
        return Instr(addr, 2, {F_LDAR: f"LDA {REG8[r]},[{p}]", F_STAR: f"STA [{p}],{REG8[r]}",
                               F_INR: f"IN {REG8[r]},({p})", F_OUTR: f"OUT ({p}),{REG8[r]}"}[fam])
    if fam == F_IN:
        return Instr(addr, 3, f"IN {REG8[r]},(0x{a16:04X})")
    if fam == F_OUT:
        return Instr(addr, 3, f"OUT (0x{a16:04X}),{REG8[r]}")
    if fam == F_ALURR:
        aop = b1 >> 3
        if aop >= len(ALU_NAMES):
            return raw()
        return Instr(addr, 2, f"{ALU_NAMES[aop]} {REG8[r]},{REG8[b1 & 7]}")
    if fam == F_ALUI:
        if b1 == 0 or b1 >= len(ALU_NAMES):    # MOV reg,#imm: casm usaria LDI
            return raw()
        return Instr(addr, 3, f"{ALU_NAMES[b1]} {REG8[r]},#0x{b2:02X}")
    if fam == F_ALUM:
        if b1 == 0 or b1 >= len(ALU_NAMES):    # MOV reg,[dir]: casm usaria LDA
            return raw()
        return Instr(addr, 4, f"{ALU_NAMES[b1]} {REG8[r]},[0x{a23:04X}]")
    if fam == F_ALUP:
        aop = b1 >> 2
        if aop == 0 or aop >= len(ALU_NAMES):  # MOV reg,[r16]: casm usaria LDA
            return raw()
        return Instr(addr, 2, f"{ALU_NAMES[aop]} {REG8[r]},[{REG16[b1 & 3]}]")
    if fam in UNARY:
        return Instr(addr, 1, f"{UNARY[fam]} {REG8[r]}")
    if fam in (F_SHR, F_SHL):
        if b1 & 0xF8:
            return raw()
        return Instr(addr, 2, f"{'SHR' if fam == F_SHR else 'SHL'} {REG8[r]},#{(b1 & 7) + 1}")
    if fam in (F_JMP, F_CALL):
        mnem = "JMP" if fam == F_JMP else "CALL"
        return Instr(addr, 3, f"{mnem}{COND[r]} 0x{a16:04X}", target=a16)
    if fam == F_JX:
        if r in (0, 1):
            return Instr(addr, 3, f"{'JMPNV' if r == 0 else 'CALLNV'} 0x{a16:04X}", target=a16)
        if r in (2, 3) and not (b1 & 0xFC):
            return Instr(addr, 2, f"{'JMP' if r == 2 else 'CALL'} {REG16[b1 & 3]}")
        return raw()
    if fam == F_R16:
        if r > 5 or (b1 & 0xE0):
            return raw()
        d = REG16[(b1 >> 3) & 3]
        if r <= 3:
            if b1 & 0x04:
                return raw()
            return Instr(addr, 2, f"{['MOV', 'ADD', 'SUB', 'CMP'][r]} {d},{REG16[b1 & 3]}")
        return Instr(addr, 2, f"{'ADD' if r == 4 else 'SUB'} {d},{REG8[b1 & 7]}")
    if fam == F_R16I:
        if r > 3 or (b1 & 0xFC):
            return raw()
        d = REG16[b1 & 3]
        if r in (0, 3):
            return Instr(addr, 4, f"{'MOV' if r == 0 else 'CMP'} {d},#0x{a23:04X}")
        return Instr(addr, 3, f"{'ADD' if r == 1 else 'SUB'} {d},#0x{b2:02X}")
    if fam == F_INCDEC16:
        return Instr(addr, 1, f"{'DEC' if r & 4 else 'INC'} {REG16[r & 3]}")
    if fam == F_PUSHPOP16:
        return Instr(addr, 1, f"{'POP' if r & 4 else 'PUSH'} {REG16[r & 3]}")
    return raw()                                # familias 30/31: libres


def disassemble(mem):
    """Recorre mem (bytes/bytearray, longitud IMAGE_SIZE) y devuelve la lista
    de Instr en orden, cubriendo 0..len(mem) sin huecos ni solapes."""
    out = []
    addr = 0
    n = len(mem)
    while addr < n:
        ins = decode_one(mem, addr)
        out.append(ins)
        addr += ins.length
    return out


def render(instrs, mem_len):
    starts = {ins.addr for ins in instrs}
    labels = {}
    for ins in instrs:
        if ins.target is not None and ins.target in starts:
            labels.setdefault(ins.target, f"L{ins.target:04X}")

    # Suprime la cola de NOP puros (0x00, sin etiqueta) que llegue hasta el
    # final de la imagen, POR CORTA QUE SEA (incluso un solo NOP final): es
    # el relleno de clearMemory()/la flash, no programa real. Un .space la
    # reproduce byte a byte igual de bien y no hace falta ver 65000 líneas
    # de "NOP" para un .bin de 64 KiB completo (p.ej. uno sacado con
    # compi_recv.py, que siempre trae la imagen entera).
    trim_from = None
    if instrs and instrs[-1].addr + instrs[-1].length == mem_len:
        i = len(instrs)
        while i > 0:
            ins = instrs[i - 1]
            if ins.text == "NOP" and ins.addr not in labels:
                i -= 1
                continue
            break
        if i < len(instrs):
            trim_from = instrs[i].addr

    lines = [".org 0x0000"]
    for ins in instrs:
        if trim_from is not None and ins.addr >= trim_from:
            break
        label = labels.get(ins.addr)
        if label:
            lines.append(f"{label}:")
        if ins.raw is not None:
            body = ", ".join(f"0x{b:02X}" for b in ins.raw)
            text = f".db {body}"
        elif ins.target is not None and ins.target in labels:
            # sustituye la direccion en crudo del final por la etiqueta
            mnem = ins.text.split(" ", 1)[0]
            text = f"{mnem} {labels[ins.target]}"
        else:
            text = ins.text
        lines.append(f"    {text:<24} ; {ins.addr:04X}")

    if trim_from is not None:
        lines.append(f"    .space {mem_len - trim_from:<17} ; {trim_from:04X}")

    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="fichero .bin (compi_recv.py o un .bin de programs/)")
    ap.add_argument("-o", "--output", help="fichero .asm de salida (por defecto, stdout)")
    args = ap.parse_args(argv)

    with open(args.image, "rb") as f:
        data = f.read()
    if len(data) > IMAGE_SIZE:
        print(f"compi_disasm: {len(data)} bytes pasa de {IMAGE_SIZE}", file=sys.stderr)
        return 2
    # OJO: NO se rellena con ceros hasta 65536 aqui. Un .bin mas corto que
    # eso es NORMAL (casm.py ya recorta hasta la ultima direccion usada, y
    # compi_recv.py --len trae solo un trozo a proposito) -- rellenar
    # inventaria un programa "el resto es NOP" que no es lo que hay
    # realmente en el aparato, y con --len en concreto el resto ni siquiera
    # es zero, es simplemente "no se pidio". Se desensambla exactamente lo
    # que trae el fichero, ni un byte mas.
    mem = bytearray(data)

    instrs = disassemble(mem)
    text = render(instrs, len(mem))

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"compi_disasm: {args.image} -> {args.output}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
