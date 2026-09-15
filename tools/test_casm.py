#!/usr/bin/env python3
"""Comprueba casm.py con los ejemplos de docs/isa.md (bytes verificados en el
emulador). Ejecuta:  python3 tools/test_casm.py
"""
import sys

from casm import Assembler, AsmError


def asm(src):
    a = Assembler()
    img = a.assemble(src)
    return img[: a.max_addr], a


CASES = [
    # docs/isa.md §9
    ("LED sigue al pulsador", """
        IN  AL,(0x0503)
        OUT (0x0510),AL
        JMP 0x0000
    """, "68 03 05 70 10 05 88 00 00"),
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
    """, "10 48 70 00 04 10 4F 70 01 04 10 4C 70 02 04 10 41 70 03 04 08"),
    ("suma 5+3 (EXT)", """
        MOV AL,#0x05
        MOV BL,#0x03
        ADD AL,BL
        HALT
    """, "10 05 12 03 F9 02 08"),
    ("suma 5+3 (ALUI)", """
        MOV AL,#5
        ADD AL,#3
        HALT
    """, "10 05 A1 00 03 08"),
    ("tres puntos", """
        MOV AL,#0x80
        OUT (0x0000),AL
        OUT (0x0010),AL
        OUT (0x0020),AL
        HALT
    """, "10 80 70 00 00 70 10 00 70 20 00 08"),
    ("cuenta atras", """
            MOV AL,#0x03
        bucle:
            SUB AL,#0x01
            JMPNZ bucle
            HALT
    """, "10 03 A2 00 01 8A 02 00 08"),
    ("espera con temporizador", """
            MOV AL,#0x0A
            OUT (0x0525),AL
        espera:
            IN  AL,(0x0525)
            CMP AL,#0x00
            JMPNZ espera
            MOV AL,#0x01
            OUT (0x0510),AL
            HALT
    """, "10 0A 70 25 05 68 25 05 A3 00 00 8A 05 00 10 01 70 10 05 08"),
    ("EXT variados", """
        MOV CL,AL
        ADD AL,BL
        XOR AL,BL
    """, "F8 20 F9 02 FE 02"),
    ("ALUI variados", """
        ADD AL,#0x05
        OR BL,#0x80
        CMP CL,#0x0A
    """, "A1 00 05 A5 02 80 A3 04 0A"),
    ("LDA/STA/JMP con etiqueta", """
        .org 0
            LDA AL,[dato]
            STA [dato+1],AL
            JMP  fin
        dato:  .db 0x11, 0x22
        fin:   HALT
    """, "18 09 00 20 0A 00 88 0B 00 11 22 08"),
    ("CALL/RET", """
            CALLZ sub
            HALT
        sub: RET
    """, "91 04 00 08 98"),
    (".dw y .ascii", """
        .dw 0x1234
        .ascii "Hi"
        .asciiz "Yo"
    """, "34 12 48 69 59 6F 00"),
    ("expresiones lo/hi", """
        addr .equ 0xBEEF
        MOV AL,#lo(addr)
        MOV AH,#hi(addr)
    """, "10 EF 11 BE"),
    ("LDA/STA/IN/OUT indirecto por registro", """
        LDA AL,[DX]
        STA [DX],AL
        IN  CH,(BX)
        OUT (BX),CH
        HALT
    """, "A8 03 B0 03 BD 01 C5 01 08"),
]

ERROR_CASES = [
    ("CMP con memoria", "CMP AL,[0x10]"),
    ("MOV con memoria", "MOV AL,[0x10]"),
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
