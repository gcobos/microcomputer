; ============================================================================
;  isa_ext_test.asm  -  prueba de MUL, DIV, INC/DEC, ADD/SUB de 16 bits,
;  MOVB/MOVW, JMPV/JMPNV y MOV reg16,#imm16; de la ISA 2: ADC/SBC, INC/DEC
;  de 8 bits, MOV/ADD/SUB/CMP de 16 bits, PUSH/POP reg16, MOVBR y JMP/CALL
;  por registro; y de la ISA 3 (casos 22, 27, 28 y 39-68): MOV [mem],#imm,
;  SAR/ROL/ROR/RCL/RCR, NEG, IMUL, saltos con signo, JMPA/JMPBE (sin signo)
;  y SHL/SHR/SAR/NEG/MUL/DIV de 16 bits (compi)
;
;  Ejercita cada instruccion nueva del ISA con los mismos casos limite ya
;  verificados aparte contra el nucleo de cpu.cpp (g++ standalone) y contra
;  tools/sim.py (ver la sesion que introdujo estas instrucciones): AL sube
;  un contador de casos y otro de fallos; al final muestra "PASS n/N" y,
;  si hay fallos, "FAIL #k" con el numero del primer caso que fallo (1..N).
;  Pensado como prueba de regresion permanente, no como demo -- no hace
;  nada mas que esto.
;
;  Ensamblar y enviar (numero de slot en la propia ".slot" de abajo):
;     python3 tools/casm.py programs/isa_ext_test.asm -o programs/isa_ext_test.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/isa_ext_test.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 17

    .name "ISA TEST"

    .category UTILITY
    .org 0x0000

P_TEXT = 0x0400

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV AL,#0
    MOV [test_cnt],AL
    MOV [fail_cnt],AL
    MOV [first_fail],AL

    ; --- MUL 255*255 -> AX=0xFE01, C=V=1 (no cupo en 8 bits) --------------
    ; OJO de orden: check8/check16 usan CMP por dentro, que PISA los flags
    ; -- hay que leer C/V con cflag_to_al/vflag_to_al justo despues del
    ; MUL/DIV, y guardarlos en variables, ANTES de llamar a check8/check16.
    MOV AL,#0xFF
    MOV BL,#0xFF
    MUL BL
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    CALL cflag_to_al
    MOV [c_result],AL
    CALL vflag_to_al
    MOV [v_result],AL

    MOV AL,#0x01
    MOV BL,#0xFE
    CALL check16                 ; caso 1: AX == 0xFE01
    MOV AL,[c_result]
    MOV BL,#1
    CALL check8                  ; caso 2: C=1 (no cupo en 8 bits)
    MOV AL,[v_result]
    MOV BL,#1
    CALL check8                  ; caso 3: V=1 (igual que C aqui)

    ; --- MUL 5*3 -> AX=15, C=V=0 (si cupo) ---------------------------------
    MOV AL,#5
    MOV BL,#3
    MUL BL
    MOV [got_lo],AL
    CALL cflag_to_al
    MOV [c_result],AL

    MOV AL,[got_lo]
    MOV BL,#15
    CALL check8                  ; caso 4: AL == 15 (AH ya es 0, cabe en un byte)
    MOV AL,[c_result]
    MOV BL,#0
    CALL check8                  ; caso 5: C=0 (cupo en 8 bits)

    ; --- DIV entre 0 -> satura AL=AH=0xFF, C=V=1 ---------------------------
    MOV AL,#100
    MOV AH,#0
    MOV BL,#0
    DIV BL
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    CALL vflag_to_al
    MOV [v_result],AL

    MOV AL,#0xFF
    MOV BL,#0xFF
    CALL check16                 ; caso 6: AX == 0xFFFF
    MOV AL,[v_result]
    MOV BL,#1
    CALL check8                  ; caso 7: V=1

    ; --- DIV con cociente que no cabe (1000/2=500) -> tambien satura ------
    MOV AL,#0xE8
    MOV AH,#0x03                 ; AX = 1000
    MOV BL,#2
    DIV BL
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,#0xFF
    MOV BL,#0xFF
    CALL check16                 ; caso 8: AX == 0xFFFF (satura)

    ; --- DIV normal: 100/3 = 33 resto 1, C=V=0 -----------------------------
    MOV AL,#100
    MOV AH,#0
    MOV BL,#3
    DIV BL
    MOV BL,#33
    CALL check8                  ; caso 9: AL == 33 (cociente)
    MOV AL,AH
    MOV BL,#1
    CALL check8                  ; caso 10: AH == 1 (resto)

    ; --- INC/DEC BX con vuelta 0xFFFF<->0 ----------------------------------
    MOV BL,#0xFF
    MOV BH,#0xFF
    INC BX
    MOV AL,BL
    MOV BL,#0
    CALL check8                  ; caso 11: BL == 0 (INC 0xFFFF -> 0x0000)
    MOV BL,#0
    MOV BH,#0
    DEC BX
    MOV AL,BH
    MOV BL,#0xFF
    CALL check8                  ; caso 12: BH == 0xFF (DEC 0x0000 -> 0xFFFF)

    ; --- ADD BX,CL / SUB BX,CL: reemplazo de idx_ptr, con acarreo/prestamo -
    ; OJO de orden (igual aviso que arriba): "MOV BL,#esperado" para el
    ; check8 de BH clobberia el BL real antes de poder leerlo para el
    ; siguiente caso -- hay que guardarlo en memoria primero.
    MOV BL,#0xFE
    MOV BH,#0x00
    MOV CL,#5
    ADD BX,CL                    ; BX = 0x00FE + 5 = 0x0103
    MOV AL,BL
    MOV [got_lo],AL
    MOV AL,BH
    MOV BL,#1
    CALL check8                  ; caso 13: BH == 1 (hubo acarreo de verdad)
    MOV AL,[got_lo]
    MOV BL,#3
    CALL check8                  ; caso 14: BL == 3

    MOV BL,#0x02
    MOV BH,#0x01
    MOV CL,#5
    SUB BX,CL                    ; BX = 0x0102 - 5 = 0x00FD
    MOV AL,BL
    MOV [got_lo],AL
    MOV AL,BH
    MOV BL,#0
    CALL check8                  ; caso 15: BH == 0 (hubo prestamo de verdad)
    MOV AL,[got_lo]
    MOV BL,#0xFD
    CALL check8                  ; caso 16: BL == 0xFD

    ; --- MOVB: copia un bloque conocido y deja BX/DX avanzados, CX a 0 -----
    MOV AL,#0xA5
    MOV [0x1000],AL
    MOV AL,#0x5A
    MOV [0x1001],AL
    MOV BL,#0x00
    MOV BH,#0x10                 ; BX = 0x1000 (origen)
    MOV DL,#0x00
    MOV DH,#0x20                 ; DX = 0x2000 (destino)
    MOV CL,#2
    MOV CH,#0                    ; CX = 2 (bytes)
    MOVB
    ; check8 usa CL por dentro (contador de casos) -- hay que guardar el CL
    ; real (deberia ser 0 tras MOVB) antes de que lo pise.
    MOV AL,CL
    MOV [got_lo],AL
    MOV AL,[0x2000]
    MOV BL,#0xA5
    CALL check8                  ; caso 17: primer byte copiado
    MOV AL,[0x2001]
    MOV BL,#0x5A
    CALL check8                  ; caso 18: segundo byte copiado
    MOV AL,[got_lo]
    MOV BL,#0
    CALL check8                  ; caso 19: CX == 0 tras MOVB

    ; --- JMPV/JMPNV: mismo mecanismo que arriba, pero
    ; comprobados con las instrucciones de salto de verdad (no solo el
    ; flag) -- MUL 255*255 deja V=1 -----------------------------------------
    MOV AL,#0xFF
    MOV BL,#0xFF
    MUL BL                       ; V=1
    MOV AL,#0
    JMPNV jnv_skip                ; V=1 -> NO deberia saltar
    MOV AL,#1
jnv_skip:
    MOV BL,#1
    CALL check8                  ; caso 20: JMPNV con V=1 no salto (AL quedo en 1)

    MOV AL,#5
    MOV BL,#3
    MUL BL                       ; V=0 (5*3=15 cabe en 8 bits)
    MOV AL,#0
    JMPV jv_skip                  ; V=0 -> NO deberia saltar
    MOV AL,#1
jv_skip:
    MOV BL,#1
    CALL check8                  ; caso 21: JMPV con V=0 no salto (AL quedo en 1)

    ; (ISA 3: CALL ya no lleva condicion; el caso 22 pasa a ser MOV [dir],#imm)
    MOV [tmp_v],#0x5A
    MOV AL,[tmp_v]
    MOV BL,#0x5A
    CALL check8                  ; caso 22: MOV [dir],#imm escribe 0x5A

    ; --- MOV reg16,#imm16: una instruccion en vez de dos MOV de 8 bits -----
    MOV BX,#0x1234
    MOV AL,BL
    MOV [got_lo],AL
    MOV AL,BH
    MOV [got_hi],AL
    MOV AL,#0x34
    MOV BL,#0x12
    CALL check16                 ; caso 23: MOV BX,#0x1234 -> BX == 0x1234

    ; no toca flags: deja C=1 a mano (CMP AL,#10 con AL=5) y comprueba que
    ; sigue igual tras un MOV reg16,#imm16
    MOV AL,#5
    CMP AL,#10
    MOV DX,#0x0000
    CALL cflag_to_al
    MOV BL,#1
    CALL check8                  ; caso 24: MOV reg16,#imm16 no toca flags

    ; ======================================================================
    ;  ISA 2: ADC/SBC, INC/DEC de 8 bits (y los casos 27-28, ya de la ISA 3),
    ;  16 bits reg16,reg16 y reg16,#imm, PUSH/POP reg16, MOVBR, saltos por
    ;  registro
    ; ======================================================================
    ; --- ADC: suma de 16 bits a trozos 0x01F0 + 0x0020 = 0x0210 -----------
    MOV AL,#0xF0
    ADD AL,#0x20             ; AL=0x10, C=1
    MOV BL,#0x01
    ADC BL,#0x00             ; BL = 1 + 0 + C = 2
    MOV [got_lo],AL
    MOV AL,BL
    MOV [got_hi],AL
    MOV AL,#0x10
    MOV BL,#0x02
    CALL check16                 ; caso 25: ADC recoge el acarreo

    ; --- SBC: resta de 16 bits 0x0200 - 0x0001 = 0x01FF ---------------------
    MOV AL,#0x00
    SUB AL,#0x01             ; AL=0xFF, C=1 (prestamo)
    MOV BL,#0x02
    SBC BL,#0x00             ; BL = 2 - 0 - C = 1
    MOV [got_lo],AL
    MOV AL,BL
    MOV [got_hi],AL
    MOV AL,#0xFF
    MOV BL,#0x01
    CALL check16                 ; caso 26: SBC paga el prestamo

    ; --- (ISA 3: sin ALU con memoria) MOV [r16],#imm y MOV reg,[r16] --------
    MOV BX,#tmp_v
    MOV [BX],#7
    MOV AL,[tmp_v]
    MOV BL,#7
    CALL check8                  ; caso 27: MOV [BX],#7 escribe 7

    MOV BX,#tmp_v                ; tmp_v = 7
    MOV CL,[BX]
    MOV AL,#5
    ADD AL,CL
    MOV BL,#12
    CALL check8                  ; caso 28: MOV CL,[BX] + ADD = 12

    ; --- INC/DEC de 8 bits: no tocan C ---------------------------------------
    MOV AL,#0xFF
    ADD AL,#1                    ; C=1
    MOV AL,#0xFF
    INC AL                       ; AL=0, Z=1, C sigue a 1
    CALL cflag_to_al
    MOV BL,#1
    CALL check8                  ; caso 29: INC AL no toca C
    MOV CL,#1
    DEC CL
    MOV AL,#0
    JMPNZ t30
    MOV AL,#1
t30:
    MOV BL,#1
    CALL check8                  ; caso 30: DEC CL deja Z=1

    ; --- 16 bits reg16,reg16 / reg16,#imm8 / CMP reg16 -----------------------
    MOV BX,#0x1234
    MOV DX,#0x0FFF
    ADD BX,DX                    ; 0x2233
    SUB BX,#0x33                 ; 0x2200
    ADD BX,#0x10                 ; 0x2210
    MOV CX,BX
    MOV AL,CL
    MOV [got_lo],AL
    MOV AL,CH
    MOV [got_hi],AL
    MOV AL,#0x10
    MOV BL,#0x22
    CALL check16                 ; caso 31: ADD/SUB/MOV de 16 bits
    MOV BX,#0x0100
    CMP BX,#0x00FF               ; 0x100 > 0xFF: C=0, Z=0
    CALL cflag_to_al
    MOV BL,#0
    CALL check8                  ; caso 32: CMP BX,#imm16 sin prestamo
    MOV BX,#0x00FF
    MOV DX,#0x0100
    CMP BX,DX                    ; 0xFF < 0x100: C=1
    CALL cflag_to_al
    MOV BL,#1
    CALL check8                  ; caso 33: CMP BX,DX con prestamo

    ; --- PUSH/POP reg16 -------------------------------------------------------
    MOV BX,#0xBEEF
    PUSH BX
    MOV BX,#0
    POP DX
    MOV AL,DL
    MOV [got_lo],AL
    MOV AL,DH
    MOV [got_hi],AL
    MOV AL,#0xEF
    MOV BL,#0xBE
    CALL check16                 ; caso 34: PUSH BX / POP DX

    ; --- MOVBR: abre hueco de 1 byte en "ABC" (copia solapada hacia atras) --
    MOV BX,#mvb_buf+2            ; ultimo byte de origen ('C')
    MOV DX,#mvb_buf+3            ; ultimo byte de destino
    MOV CX,#3
    MOVBR                        ; "AABC"
    MOV AL,[mvb_buf+3]
    MOV BL,#'C'
    CALL check8                  ; caso 35: MOVBR movio el ultimo
    MOV AL,[mvb_buf+1]
    MOV BL,#'A'
    CALL check8                  ; caso 36: MOVBR sin pisarse (memmove)

    ; --- JMP/CALL por registro ------------------------------------------------
    MOV AL,#0
    MOV BX,#t37_dst
    JMP BX
    MOV AL,#9                    ; no debe ejecutarse
t37_dst:
    MOV BL,#0
    CALL check8                  ; caso 37: JMP BX salto
    MOV AL,#0
    MOV DX,#t38_sub
    CALL DX                      ; t38_sub pone AL=1 y vuelve
    MOV BL,#1
    CALL check8                  ; caso 38: CALL DX llamo y volvio


    ; ===================== ISA 3 =============================================
    ; --- SAR: desplazamiento con signo ---------------------------------------
    MOV AL,#0x84                 ; -124
    SAR AL,#2
    MOV BL,#0xE1                 ; -31
    CALL check8                  ; caso 39: SAR 0x84,#2 = 0xE1
    MOV AL,#0x81
    SAR AL                       ; -> 0xC0, sale un 1
    CALL cflag_to_al
    MOV BL,#1
    CALL check8                  ; caso 40: SAR deja en C el bit que sale

    ; --- ROL / ROR -------------------------------------------------------------
    MOV BL,#0xB1
    ROL BL,#3
    MOV AL,BL
    MOV BL,#0x8D
    CALL check8                  ; caso 41: ROL 0xB1,#3 = 0x8D
    MOV CL,#0x01
    ROR CL
    MOV AL,CL
    MOV BL,#0x80
    CALL check8                  ; caso 42: ROR 0x01 = 0x80

    ; --- RCL / RCR: a traves de C --------------------------------------------
    MOV AL,#0xFF
    ADD AL,#1                    ; C=1
    MOV DL,#0x40
    RCL DL,#2                    ; 0x40 -> 0x81 (C=0) -> 0x02 (C=1)
    CALL cflag_to_al
    MOV [c_result],AL
    MOV AL,DL
    MOV BL,#0x02
    CALL check8                  ; caso 43: RCL 0x40,#2 con C=1 = 0x02
    MOV AL,[c_result]
    MOV BL,#1
    CALL check8                  ; caso 44: y deja C=1
    MOV AL,#1
    ADD AL,#1                    ; C=0
    MOV AH,#0x03
    RCR AH                       ; -> 0x01, C=1
    MOV AL,AH
    MOV BL,#0x01
    CALL check8                  ; caso 45: RCR 0x03 con C=0 = 0x01

    ; --- NEG -------------------------------------------------------------------
    MOV AL,#5
    NEG AL
    PUSH AL
    CALL cflag_to_al
    MOV [c_result],AL
    POP AL
    MOV BL,#0xFB
    CALL check8                  ; caso 46: NEG 5 = 0xFB
    MOV AL,[c_result]
    MOV BL,#1
    CALL check8                  ; caso 47: NEG de un no-cero deja C=1
    MOV AL,#0x80
    NEG AL                       ; -128 no tiene opuesto: V=1
    CALL vflag_to_al
    MOV BL,#1
    CALL check8                  ; caso 48: NEG 0x80 da V=1

    ; --- IMUL ------------------------------------------------------------------
    MOV AL,#0xFD                 ; -3
    MOV BL,#7
    IMUL BL                      ; -21 = 0xFFEB
    PUSH AL
    CALL cflag_to_al
    MOV [c_result],AL
    POP AL
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,#0xEB
    MOV BL,#0xFF
    CALL check16                 ; caso 49: IMUL -3*7 = 0xFFEB
    MOV AL,[c_result]
    MOV BL,#0
    CALL check8                  ; caso 50: -21 cabe en 8 bits: C=0
    MOV AL,#0x80
    MOV BL,#0x80
    IMUL BL                      ; -128*-128 = 16384 = 0x4000
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,#0x00
    MOV BL,#0x40
    CALL check16                 ; caso 51: IMUL -128*-128 = 0x4000

    ; --- saltos con signo ------------------------------------------------------
    MOV AL,#0xFE                 ; -2 (sin signo seria 254, mayor que 3)
    CMP AL,#3
    MOV AL,#0
    JMPLT t52
    MOV AL,#1
t52:
    MOV BL,#0
    CALL check8                  ; caso 52: -2 < 3 con signo: JMPLT salta
    MOV AL,#3
    CMP AL,#0xFE
    MOV AL,#0
    JMPGE t53
    MOV AL,#1
t53:
    MOV BL,#0
    CALL check8                  ; caso 53: 3 >= -2: JMPGE salta
    MOV AL,#5
    CMP AL,#5
    MOV AL,#0
    JMPLE t54
    MOV AL,#1
t54:
    MOV BL,#0
    CALL check8                  ; caso 54: 5 <= 5: JMPLE salta
    MOV AL,#0x80                 ; -128
    CMP AL,#0x7F
    MOV AL,#0
    JMPGT t55
    MOV AL,#1
t55:
    MOV BL,#1
    CALL check8                  ; caso 55: -128 > 127 es falso: JMPGT no salta

    ; --- 16 bits: SHL / SHR / SAR / NEG --------------------------------------
    MOV AX,#0x1234
    SHL AX,#4
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,#0x40
    MOV BL,#0x23
    CALL check16                 ; caso 56: SHL 0x1234,#4 = 0x2340
    MOV BX,#0xF234
    SHR BX,#12
    MOV AL,BL
    MOV [got_lo],AL
    MOV AL,BH
    MOV [got_hi],AL
    MOV AL,#0x0F
    MOV BL,#0x00
    CALL check16                 ; caso 57: SHR 0xF234,#12 = 0x000F
    MOV CX,#0x8001
    SAR CX,#4
    MOV AL,CL
    MOV [got_lo],AL
    MOV AL,CH
    MOV [got_hi],AL
    MOV AL,#0x00
    MOV BL,#0xF8
    CALL check16                 ; caso 58: SAR 0x8001,#4 = 0xF800
    MOV DX,#0x0001
    NEG DX
    MOV AL,DL
    MOV [got_lo],AL
    MOV AL,DH
    MOV [got_hi],AL
    MOV AL,#0xFF
    MOV BL,#0xFF
    CALL check16                 ; caso 59: NEG 1 = 0xFFFF

    ; --- MUL / DIV de 16 bits ------------------------------------------------
    MOV AX,#0x1234
    MOV BX,#0x0100
    MUL BX                       ; DX:AX = 0x00123400
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,DL
    MOV [tmp_v],AL
    MOV AL,DH
    MOV [exp_lo_tmp],AL          ; (variable de paso)
    MOV AL,#0x00
    MOV BL,#0x34
    CALL check16                 ; caso 60: MUL AX = 0x3400 (parte baja)
    MOV AL,[tmp_v]
    MOV [got_lo],AL
    MOV AL,[exp_lo_tmp]
    MOV [got_hi],AL
    MOV AL,#0x12
    MOV BL,#0x00
    CALL check16                 ; caso 61: MUL DX = 0x0012 (parte alta)
    MOV DX,#0x0001
    MOV AX,#0x0000               ; DX:AX = 65536
    MOV CX,#3
    DIV CX                       ; AX = 21845 = 0x5555, DX = 1
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,DL
    MOV [tmp_v],AL
    MOV AL,#0x55
    MOV BL,#0x55
    CALL check16                 ; caso 62: DIV 65536/3 = 0x5555
    MOV AL,[tmp_v]
    MOV BL,#1
    CALL check8                  ; caso 63: resto 1
    MOV DX,#0x0003
    MOV AX,#0x0000               ; 196608 / 2 = 98304: no cabe en 16 bits
    MOV CX,#2
    DIV CX
    MOV [got_lo],AL
    MOV AL,AH
    MOV [got_hi],AL
    MOV AL,#0xFF
    MOV BL,#0xFF
    CALL check16                 ; caso 64: DIV que no cabe satura en 0xFFFF

    ; --- saltos sin signo JMPA / JMPBE (tras CMP) ------------------------------
    MOV AL,#0xFE                 ; 254 sin signo
    CMP AL,#3
    MOV AL,#0
    JMPA t65
    MOV AL,#1
t65:
    MOV BL,#0
    CALL check8                  ; caso 65: 254 > 3 sin signo: JMPA salta
    MOV AL,#5
    CMP AL,#5
    MOV AL,#0
    JMPA t66
    MOV AL,#1
t66:
    MOV BL,#1
    CALL check8                  ; caso 66: 5 > 5 es falso: JMPA no salta
    MOV AL,#5
    CMP AL,#5
    MOV AL,#0
    JMPBE t67
    MOV AL,#1
t67:
    MOV BL,#0
    CALL check8                  ; caso 67: 5 <= 5: JMPBE salta
    MOV AL,#0xFE
    CMP AL,#3
    MOV AL,#0
    JMPBE t68
    MOV AL,#1
t68:
    MOV BL,#1
    CALL check8                  ; caso 68: 254 <= 3 es falso: JMPBE no salta

    ; --- resumen: PASS n/N, y FAIL #k si hubo algun fallo ------------------
    CALL show_summary
    HALT

t38_sub:
    MOV AL,#1
    RET

; --- check8: AL=valor obtenido, BL=valor esperado -- suma 1 a [test_cnt];
; si no coinciden, suma 1 a [fail_cnt] y, si es el primer fallo, guarda el
; numero de caso (test_cnt, ya incrementado) en [first_fail] ----------------
check8:
    MOV CL,[test_cnt]
    ADD CL,#1
    MOV [test_cnt],CL
    CMP AL,BL
    JMPZ ck8_ok
    MOV CL,[fail_cnt]
    ADD CL,#1
    MOV [fail_cnt],CL
    MOV CL,[first_fail]
    CMP CL,#0
    JMPNZ ck8_ok
    MOV CL,[test_cnt]
    MOV [first_fail],CL
ck8_ok:
    RET

; --- check16: AL=byte bajo esperado, BL=byte alto esperado, [got_lo]/
; [got_hi] = lo obtenido -- combina los dos check8 en un solo "caso" para
; no inflar el contador (compara los dos bytes, cuenta como 1 fallo si
; cualquiera de los dos no coincide) -----------------------------------------
check16:
    MOV [exp_lo_tmp],AL     ; AL trae el byte bajo esperado
    MOV AL,BL
    MOV [exp_hi_tmp],AL     ; BL trae el byte alto esperado

    MOV CL,[test_cnt]
    ADD CL,#1
    MOV [test_cnt],CL

    MOV AL,[got_lo]
    MOV BL,[exp_lo_tmp]
    CMP AL,BL
    JMPNZ c16_fail
    MOV AL,[got_hi]
    MOV BL,[exp_hi_tmp]
    CMP AL,BL
    JMPZ c16_ok
c16_fail:
    MOV CL,[fail_cnt]
    ADD CL,#1
    MOV [fail_cnt],CL
    MOV CL,[first_fail]
    CMP CL,#0
    JMPNZ c16_ok
    MOV CL,[test_cnt]
    MOV [first_fail],CL
c16_ok:
    RET

; --- cflag_to_al / vflag_to_al: AL = 1 si C/V esta puesto, 0 si no. Usan
; las propias JMPC/JMPV (para que la prueba tambien ejercite esos saltos,
; no solo lea el flag como dato) --------------------------------------------
cflag_to_al:
    JMPC cf_set
    MOV AL,#0
    RET
cf_set:
    MOV AL,#1
    RET

vflag_to_al:
    JMPV vf_set
    MOV AL,#0
    RET
vf_set:
    MOV AL,#1
    RET

; --- show_summary: "PASS n/N" en la fila 0; si hubo fallos, "FAIL #k" en
; la fila 1 con el numero del primer caso que fallo -------------------------
show_summary:
    MOV BL,#lo(s_pass)
    MOV BH,#hi(s_pass)
    MOV CL,#0
    MOV CH,#0
    CALL puts

    MOV AL,[test_cnt]
    MOV BL,[fail_cnt]
    SUB AL,BL                ; AL = aciertos = test_cnt - fail_cnt
    CALL put_dec2
    MOV CL,#5
    MOV CH,#0
    CALL puts2

    MOV BL,#lo(s_slash)
    MOV BH,#hi(s_slash)
    MOV CL,#7
    MOV CH,#0
    CALL puts

    MOV AL,[test_cnt]
    CALL put_dec2
    MOV CL,#8
    MOV CH,#0
    CALL puts2

    MOV AL,[fail_cnt]
    CMP AL,#0
    JMPZ ss_done

    MOV BL,#lo(s_fail)
    MOV BH,#hi(s_fail)
    MOV CL,#0
    MOV CH,#1
    CALL puts

    MOV AL,[first_fail]
    CALL put_dec2
    MOV CL,#6
    MOV CH,#1
    CALL puts2
ss_done:
    RET

; --- put_dec2: AL (0-99) -> [dec_buf]/[dec_buf+1] como dos digitos ASCII
; (decenas y unidades; sin ceros suprimidos, para que puts2 siempre escriba
; exactamente 2 caracteres) --------------------------------------------------
put_dec2:
    MOV BL,#0
pd2_tens:
    CMP AL,#10
    JMPC pd2_have_tens
    SUB AL,#10
    ADD BL,#1
    JMP pd2_tens
pd2_have_tens:
    MOV CL,AL                ; unidades
    MOV AL,BL
    ADD AL,#0x30
    MOV [dec_buf],AL
    MOV AL,CL
    ADD AL,#0x30
    MOV [dec_buf+1],AL
    RET

; --- puts2: como puts, pero para [dec_buf] (2 caracteres, sin NUL) ---------
puts2:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    MOV AL,[dec_buf]
    OUT (DX),AL
    ADD DL,#1
    MOV AL,[dec_buf+1]
    OUT (DX),AL
    RET

; --- puts: BL/BH = puntero asciiz, CL = col, CH = fila ----------------------
puts:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
ps_l:
    MOV AL,[BX]
    CMP AL,#0
    JMPZ ps_d
    OUT (DX),AL
    ADD BL,#1
    JMPNC ps_nb
    ADD BH,#1
ps_nb:
    ADD DL,#1
    JMPNC ps_l
    ADD DH,#1
    JMP ps_l
ps_d:
    RET

; --- clst: limpia la rejilla de texto entera --------------------------------
clst:
    MOV DL,#0
    MOV DH,#0x04
    MOV AL,#0
clst_l:
    OUT (DX),AL
    ADD DL,#1
    JMPNZ clst_l
    RET

; ============================================================================
;  DATOS
; ============================================================================
s_pass:  .asciiz "PASS"
s_slash: .asciiz "/"
s_fail:  .asciiz "FAIL #"

test_cnt:    .space 1
fail_cnt:    .space 1
first_fail:  .space 1
got_lo:      .space 1
got_hi:      .space 1
exp_lo_tmp:  .space 1
exp_hi_tmp:  .space 1
c_result:    .space 1
v_result:    .space 1
dec_buf:     .space 2
tmp_v:      .space 1
mvb_buf:    .ascii "ABC"
            .db 0
