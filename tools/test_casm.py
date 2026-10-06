#!/usr/bin/env python3
"""Comprueba casm.py con los ejemplos de docs/isa.md (ISA version 2). Ejecuta:  python3 tools/test_casm.py
"""
import sys

from casm import Assembler, AsmError


def asm(src):
    a = Assembler()
    img = a.assemble(src)
    return img[: a.max_addr], a


# Bytes calculados a mano a partir de la tabla de codificacion de docs/isa.md
# (ISA version 2), no copiados de la salida de casm.py.
CASES = [
    # docs/isa.md, ejemplos
    ("LED sigue al pulsador", """
        IN  AL,(0x0603)
        OUT (0x0610),AL
        JMP 0x0000
    """, "30 03 06 38 10 06 B8 00 00"),
    ("HOLA", """
        MOV AL,#0x48
        OUT (0x0400),AL
        MOV AL,#0x4F
        OUT (0x0401),AL
        MOV AL,#0x4C
        OUT (0x0402),AL
        MOV AL,#0x41
        OUT (0x0403),AL
        HALT
    """, "08 48 38 00 04 08 4F 38 01 04 08 4C 38 02 04 08 41 38 03 04 01"),
    ("suma 5+3 (reg,reg)", """
        MOV AL,#0x05
        MOV BL,#0x03
        ADD AL,BL
        HALT
    """, "08 05 0A 03 50 0A 01"),
    ("suma 5+3 (reg,#imm)", """
        MOV AL,#5
        ADD AL,#3
        HALT
    """, "08 05 58 01 03 01"),
    ("tres puntos", """
        MOV AL,#0x80
        OUT (0x0000),AL
        OUT (0x0010),AL
        OUT (0x0020),AL
        HALT
    """, "08 80 38 00 00 38 10 00 38 20 00 01"),
    ("cuenta atras", """
            MOV AL,#0x03
        bucle:
            SUB AL,#0x01
            JMPNZ bucle
            HALT
    """, "08 03 58 03 01 BA 02 00 01"),
    ("espera con temporizador", """
            MOV AL,#0x0A
            OUT (0x0625),AL
        espera:
            IN  AL,(0x0625)
            CMP AL,#0x00
            JMPNZ espera
            MOV AL,#0x01
            OUT (0x0610),AL
            HALT
    """, "08 0A 38 25 06 30 25 06 58 05 00 BA 05 00 08 01 38 10 06 01"),
    ("ALU reg,reg variados", """
        MOV CL,AL
        ADD AL,BL
        XOR AL,BL
    """, "54 00 50 0A 50 42"),
    ("ALU reg,#imm variados", """
        ADD AL,#0x05
        OR BL,#0x80
        CMP CL,#0x0A
    """, "58 01 05 5A 07 80 5C 05 0A"),
    ("LDA/STA/JMP con etiqueta", """
        .org 0
            LDA AL,[dato]
            STA [dato+1],AL
            JMP  fin
        dato:  .db 0x11, 0x22
        fin:   HALT
    """, "10 09 00 18 0A 00 B8 0B 00 11 22 01"),
    ("CALL/RET", """
            CALLZ sub
            HALT
        sub: RET
    """, "C1 04 00 01 02"),
    (".dw y .ascii", """
        .dw 0x1234
        .ascii "Hi"
        .asciiz "Yo"
    """, "34 12 48 69 59 6F 00"),
    ("expresiones lo/hi", """
        addr .equ 0xBEEF
        MOV AL,#lo(addr)
        MOV AH,#hi(addr)
    """, "08 EF 09 BE"),
    ("LDA/STA/IN/OUT indirecto por registro", """
        LDA AL,[DX]
        STA [DX],AL
        IN  CH,(BX)
        OUT (BX),CH
        HALT
    """, "20 03 28 03 45 01 4D 01 01"),
    # ISA 2: instrucciones nuevas
    ("ADC/SBC, ALU con memoria y [reg16], INC/DEC 8 bits, SHR/SHL", """
        ADC AL,BL
        SBC AL,#1
        CMP AL,[0x1234]
        ADD AL,[BX]
        INC AL
        DEC CL
        SHR AL
        SHL BL,#3
    """, "50 12 58 04 01 60 05 34 12 68 05 98 A4 78 00 82 02"),
    ("MOV con memoria = LDA", """
        MOV AL,[0x1234]
        MOV AL,[BX]
    """, "10 34 12 20 01"),
    ("16 bits", """
        MOV BX,DX
        ADD BX,CL
        MOV BX,#0x1234
        ADD DX,#5
        CMP CX,#0x0100
        SUB AX,BX
        CMP BX,DX
        INC BX
        DEC DX
        PUSH BX
        POP AX
    """, "D0 0B D4 0C D8 01 34 12 D9 03 05 DB 02 00 01 D2 01 D3 0B E1 E7 E9 EC"),
    ("saltos por registro, NV y copias de bloque", """
        JMP BX
        CALL DX
        JMPNV 0x0010
        CALLNV 0x0020
        JMPV 0x0030
        MOVB
        MOVW
        MOVBR
    """, "CA 01 CB 03 C8 10 00 C9 20 00 BF 30 00 03 04 05"),
]

ERROR_CASES = [
    ("ADC no tiene forma de 16 bits", "ADC BX,CL"),
    ("CMP reg16,reg8 no existe", "CMP BX,CL"),
    ("salto por registro con condicion", "JMPZ BX"),
    ("SHR con N fuera de 1..8", "SHR AL,#9"),
    ("simbolo indefinido", "JMP noexiste"),
    ("instruccion basura", "FOO AL,BL"),
]


def run():
    fails = 0
    for name, src, expect in CASES:
        want = bytes(int(b, 16) for b in expect.split())
        try:
            got, _ = asm(src)
        except AsmError as e:
            print(f"FALLO  {name}: excepcion {e}")
            fails += 1
            continue
        if got != want:
            print(f"FALLO  {name}")
            print(f"   esperado: {want.hex(' ')}")
            print(f"   obtenido: {got.hex(' ')}")
            fails += 1
        else:
            print(f"ok     {name}")

    for name, src in ERROR_CASES:
        try:
            asm(src)
            print(f"FALLO  {name}: deberia haber dado error")
            fails += 1
        except AsmError:
            print(f"ok     {name} (error esperado)")

    print()
    if fails:
        print(f"{fails} fallo(s)")
        return 1
    print("todo correcto")
    return 0


if __name__ == "__main__":
    sys.exit(run())
