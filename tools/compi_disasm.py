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
cambios). Las pocas combinaciones de bits que NO tienen mnemonico documentado
-- familias de opcode reservadas (27-30) o el subcampo de ALU con valor 0 o 7
en las formas OP_EXT/OP_ALUI (ver include/isa.h: AluOp solo define 0-6, y el
valor 0 en la forma ALUI, aunque tecnicamente MOV, ambiguaria con la forma
LDI de 2 bytes si se escribiera "MOV reg,#imm" a secas: casm.py SIEMPRE
prefiere LDI, que no ocupa los mismos bytes) -- se vuelcan como `.db` con los
bytes crudos en vez de inventarse un mnemonico, para no perder ni cambiar ni
un bit.

Genera una etiqueta L<addr> (p.ej. L0100) para cada destino de JMP/CALL que
caiga justo en el arranque de "su" instruccion segun esta misma particion; si
no (porque cae en mitad de una tabla de datos mal interpretada, ver arriba),
se deja la direccion en crudo (0x....), que sigue siendo valido.
"""
import argparse
import sys

IMAGE_SIZE = 65536

# Familias de opcode (isa.h): opcode = family<<3 | reg.
(F_NOP, F_HALT, F_LDI, F_LDA, F_STA, F_ADD, F_SUB, F_AND, F_OR, F_XOR,
 F_NOT, F_SHR, F_SHL, F_IN, F_OUT, F_PUSH, F_POP, F_JMP, F_CALL, F_RET,
 F_ALUI, F_LDAR, F_STAR, F_INR, F_OUTR, F_SHRN, F_SHLN) = range(27)
F_EXT = 31

REG8 = ["AL", "AH", "BL", "BH", "CL", "CH", "DL", "DH"]
REG16 = ["AX", "BX", "CX", "DX"]
COND = ["", "Z", "NZ", "C", "NC", "N", "NN"]
ALU_NAMES = {0: "MOV", 1: "ADD", 2: "SUB", 3: "CMP", 4: "AND", 5: "OR", 6: "XOR"}

# Longitud (bytes) de cada familia -- igual que instrLen() en disasm.cpp.
_LEN2 = {F_LDI, F_EXT, F_LDAR, F_STAR, F_INR, F_OUTR, F_SHRN, F_SHLN}
_LEN3 = {F_LDA, F_STA, F_ADD, F_SUB, F_AND, F_OR, F_XOR, F_IN, F_OUT,
         F_JMP, F_CALL, F_ALUI}


def instr_len(mem, addr):
    fam = mem[addr] >> 3
    if fam in _LEN3:
        return 3
    if fam in _LEN2:
        return 2
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
    op = mem[addr]
    fam, r = op >> 3, op & 7
    b1 = rd(mem, addr + 1)
    b2 = rd(mem, addr + 2)
    a16 = b1 | (b2 << 8)

    if fam in (F_NOP, F_HALT, F_RET):
        # casm.py siempre codifica estos tres con reg=0 (sin operando que
        # transporte los otros valores posibles del campo reg); si el byte
        # real trae algo distinto de 0 ahi (tipico de una tabla de datos
        # coincidiendo con esta familia, no de codigo real: la CPU ignora
        # ese campo para estos tres), el mnemonico limpio NO reproduce el
        # byte exacto -- se deja en crudo.
        if r != 0:
            return Instr(addr, 1, None, raw=[op])
        return Instr(addr, 1, {F_NOP: "NOP", F_HALT: "HALT", F_RET: "RET"}[fam])
    if fam == F_LDI:
        return Instr(addr, 2, f"MOV {REG8[r]},#0x{b1:02X}")
    if fam == F_LDA:
        return Instr(addr, 3, f"LDA {REG8[r]},[0x{a16:04X}]")
    if fam == F_STA:
        return Instr(addr, 3, f"STA [0x{a16:04X}],{REG8[r]}")
    if fam in (F_ADD, F_SUB, F_AND, F_OR, F_XOR):
        name = {F_ADD: "ADD", F_SUB: "SUB", F_AND: "AND", F_OR: "OR", F_XOR: "XOR"}[fam]
        return Instr(addr, 3, f"{name} {REG8[r]},[0x{a16:04X}]")
    if fam == F_NOT:
        return Instr(addr, 1, f"NOT {REG8[r]}")
    if fam == F_SHR:
        return Instr(addr, 1, f"SHR {REG8[r]}")
    if fam == F_SHL:
        return Instr(addr, 1, f"SHL {REG8[r]}")
    if fam in (F_SHRN, F_SHLN):
        # casm.py solo escribe b1 = N-1 con N en 1..8 (0..7): si el byte real
        # trae algo en los 5 bits altos, el mnemonico limpio no lo reproduce.
        if b1 & 0xF8:
            return Instr(addr, 2, None, raw=[op, b1])
        mnem = "SHR" if fam == F_SHRN else "SHL"
        return Instr(addr, 2, f"{mnem} {REG8[r]},#{(b1 & 7) + 1}")
    if fam == F_IN:
        return Instr(addr, 3, f"IN {REG8[r]},(0x{a16:04X})")
    if fam == F_OUT:
        return Instr(addr, 3, f"OUT (0x{a16:04X}),{REG8[r]}")
    if fam in (F_LDAR, F_STAR, F_INR, F_OUTR):
        # b1 solo lleva el par de 16 bits en los 2 bits bajos (Reg16); si
        # trae algo en los 6 altos, no hay mnemonico limpio que lo reproduzca.
        if b1 & 0xFC:
            return Instr(addr, 2, None, raw=[op, b1])
        if fam == F_LDAR:
            return Instr(addr, 2, f"LDA {REG8[r]},[{REG16[b1 & 3]}]")
        if fam == F_STAR:
            return Instr(addr, 2, f"STA [{REG16[b1 & 3]}],{REG8[r]}")
        if fam == F_INR:
            return Instr(addr, 2, f"IN {REG8[r]},({REG16[b1 & 3]})")
        return Instr(addr, 2, f"OUT ({REG16[b1 & 3]}),{REG8[r]}")
    if fam == F_PUSH:
        return Instr(addr, 1, f"PUSH {REG8[r]}")
    if fam == F_POP:
        return Instr(addr, 1, f"POP {REG8[r]}")
    if fam in (F_JMP, F_CALL):
        # r = condicion (0-6 documentadas, ver isa.h JumpCond); r==7 no
        # tiene sufijo valido para casm.py (su tabla COND no lo tiene).
        if r == 7:
            return Instr(addr, 3, None, raw=[op, b1, b2])
        mnem = "JMP" if fam == F_JMP else "CALL"
        return Instr(addr, 3, f"{mnem}{COND[r]} 0x{a16:04X}", target=a16)
    if fam == F_EXT:
        # r = AluOp (0-6 documentados, ver isa.h). r==7 no tiene mnemonico, y
        # los 2 bits altos de b1 estan fuera de "dst:3|src:3" (siempre 0 al
        # reensamblar) -- en cualquiera de los dos casos se deja en crudo.
        if r in ALU_NAMES and not (b1 & 0xC0):
            dst, src = (b1 >> 3) & 7, b1 & 7
            return Instr(addr, 2, f"{ALU_NAMES[r]} {REG8[dst]},{REG8[src]}")
        return Instr(addr, 2, None, raw=[op, b1])
    if fam == F_ALUI:
        # r==0 (MOV) reensamblaria mas corto via LDI (casm.py siempre prefiere
        # esa forma para "MOV reg,#imm"), r==7 no tiene mnemonico, y b1 solo
        # lleva el registro en los 3 bits bajos (el resto siempre 0 al
        # reensamblar) -- cualquiera de los tres casos se deja en crudo.
        if r in ALU_NAMES and r != 0 and not (b1 & 0xF8):
            dst = b1 & 7
            return Instr(addr, 3, f"{ALU_NAMES[r]} {REG8[dst]},#0x{b2:02X}")
        return Instr(addr, 3, None, raw=[op, b1, b2])
    # Familias reservadas (27..30): sin mnemonico, longitud 1 (igual que las
    # ejecuta el aparato: como un NOP, pero conservando el byte real).
    return Instr(addr, 1, None, raw=[op])


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
