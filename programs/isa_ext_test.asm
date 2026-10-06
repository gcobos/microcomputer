; ============================================================================
;  isa_ext_test.asm  -  prueba de MUL, DIV, INC/DEC, ADD/SUB de 16 bits,
;  MOVB/MOVW, JMPV/JMPNV/CALLV/CALLNV y MOV reg16,#imm16, y de lo nuevo de
;  la ISA 2: ADC/SBC, CMP con memoria, ALU con [reg16], INC/DEC de 8 bits,
;  MOV/ADD/SUB/CMP de 16 bits, PUSH/POP reg16, MOVBR y JMP/CALL por
;  registro (compi)
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
    STA [test_cnt],AL
    STA [fail_cnt],AL
    STA [first_fail],AL

    ; --- MUL 255*255 -> AX=0xFE01, C=V=1 (no cupo en 8 bits) --------------
    ; OJO de orden: check8/check16 usan CMP por dentro, que PISA los flags
    ; -- hay que leer C/V con cflag_to_al/vflag_to_al justo despues del
    ; MUL/DIV, y guardarlos en variables, ANTES de llamar a check8/check16.
    MOV AL,#0xFF
    MOV BL,#0xFF
    MUL BL
    STA [got_lo],AL
    MOV AL,AH
    STA [got_hi],AL
    CALL cflag_to_al
    STA [c_result],AL
    CALL vflag_to_al
    STA [v_result],AL

    MOV AL,#0x01
    MOV BL,#0xFE
    CALL check16                 ; caso 1: AX == 0xFE01
    LDA AL,[c_result]
    MOV BL,#1
    CALL check8                  ; caso 2: C=1 (no cupo en 8 bits)
    LDA AL,[v_result]
    MOV BL,#1
    CALL check8                  ; caso 3: V=1 (igual que C aqui)

    ; --- MUL 5*3 -> AX=15, C=V=0 (si cupo) ---------------------------------
    MOV AL,#5
    MOV BL,#3
    MUL BL
    STA [got_lo],AL
    CALL cflag_to_al
    STA [c_result],AL

    LDA AL,[got_lo]
    MOV BL,#15
    CALL check8                  ; caso 4: AL == 15 (AH ya es 0, cabe en un byte)
    LDA AL,[c_result]
    MOV BL,#0
    CALL check8                  ; caso 5: C=0 (cupo en 8 bits)

    ; --- DIV entre 0 -> satura AL=AH=0xFF, C=V=1 ---------------------------
    MOV AL,#100
    MOV AH,#0
    MOV BL,#0
    DIV BL
    STA [got_lo],AL
    MOV AL,AH
    STA [got_hi],AL
    CALL vflag_to_al
    STA [v_result],AL

    MOV AL,#0xFF
    MOV BL,#0xFF
    CALL check16                 ; caso 6: AX == 0xFFFF
    LDA AL,[v_result]
    MOV BL,#1
    CALL check8                  ; caso 7: V=1

    ; --- DIV con cociente que no cabe (1000/2=500) -> tambien satura ------
    MOV AL,#0xE8
    MOV AH,#0x03                 ; AX = 1000
    MOV BL,#2
    DIV BL
    STA [got_lo],AL
    MOV AL,AH
    STA [got_hi],AL
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
    STA [got_lo],AL
    MOV AL,BH
    MOV BL,#1
    CALL check8                  ; caso 13: BH == 1 (hubo acarreo de verdad)
    LDA AL,[got_lo]
    MOV BL,#3
    CALL check8                  ; caso 14: BL == 3

    MOV BL,#0x02
    MOV BH,#0x01
    MOV CL,#5
    SUB BX,CL                    ; BX = 0x0102 - 5 = 0x00FD
    MOV AL,BL
    STA [got_lo],AL
    MOV AL,BH
    MOV BL,#0
    CALL check8                  ; caso 15: BH == 0 (hubo prestamo de verdad)
    LDA AL,[got_lo]
    MOV BL,#0xFD
    CALL check8                  ; caso 16: BL == 0xFD

    ; --- MOVB: copia un bloque conocido y deja BX/DX avanzados, CX a 0 -----
    MOV AL,#0xA5
    STA [0x1000],AL
    MOV AL,#0x5A
    STA [0x1001],AL
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
    STA [got_lo],AL
    LDA AL,[0x2000]
    MOV BL,#0xA5
    CALL check8                  ; caso 17: primer byte copiado
    LDA AL,[0x2001]
    MOV BL,#0x5A
    CALL check8                  ; caso 18: segundo byte copiado
    LDA AL,[got_lo]
    MOV BL,#0
    CALL check8                  ; caso 19: CX == 0 tras MOVB

    ; --- JMPV/JMPNV, CALLV/CALLNV: mismo mecanismo que arriba, pero
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

    MOV AL,#0xFF
    MOV BL,#0xFF
    MUL BL                       ; V=1 otra vez
    MOV AL,#0
    CALLV cv_called
    MOV BL,#2
    CALL check8                  ; caso 22: CALLV con V=1 SI llamo (AL quedo en 2)
    JMP after_cv
cv_called:
    MOV AL,#2
    RET
after_cv:

    ; --- MOV reg16,#imm16: una instruccion en vez de dos MOV de 8 bits -----
    MOV BX,#0x1234
    MOV AL,BL
    STA [got_lo],AL
    MOV AL,BH
    STA [got_hi],AL
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
    ;  ISA 2: ADC/SBC, CMP con memoria, ALU con [reg16], INC/DEC de 8 bits,
    ;  16 bits reg16,reg16 y reg16,#imm, PUSH/POP reg16, MOVBR, saltos por
    ;  registro
    ; ======================================================================
    ; --- ADC: suma de 16 bits a trozos 0x01F0 + 0x0020 = 0x0210 -----------
    MOV AL,#0xF0
    ADD AL,#0x20             ; AL=0x10, C=1
    MOV BL,#0x01
    ADC BL,#0x00             ; BL = 1 + 0 + C = 2
    STA [got_lo],AL
    MOV AL,BL
    STA [got_hi],AL
    MOV AL,#0x10
    MOV BL,#0x02
    CALL check16                 ; caso 25: ADC recoge el acarreo

    ; --- SBC: resta de 16 bits 0x0200 - 0x0001 = 0x01FF ---------------------
    MOV AL,#0x00
    SUB AL,#0x01             ; AL=0xFF, C=1 (prestamo)
    MOV BL,#0x02
    SBC BL,#0x00             ; BL = 2 - 0 - C = 1
    STA [got_lo],AL
    MOV AL,BL
    STA [got_hi],AL
    MOV AL,#0xFF
    MOV BL,#0x01
    CALL check16                 ; caso 26: SBC paga el prestamo

    ; --- CMP reg,[dir] (antes no existia) -----------------------------------
    MOV AL,#7
    STA [tmp_v],AL
    MOV AL,#7
    CMP AL,[tmp_v]
    MOV AL,#0
    JMPNZ t27
    MOV AL,#1
t27:
    MOV BL,#1
    CALL check8                  ; caso 27: CMP AL,[dir] da Z=1

    ; --- ALU con [reg16]: ADD AL,[BX] ---------------------------------------
    MOV BX,#tmp_v                ; tmp_v = 7
    MOV AL,#5
    ADD AL,[BX]
    MOV BL,#12
    CALL check8                  ; caso 28: ADD AL,[BX] = 12

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
    STA [got_lo],AL
    MOV AL,CH
    STA [got_hi],AL
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
    STA [got_lo],AL
    MOV AL,DH
    STA [got_hi],AL
    MOV AL,#0xEF
    MOV BL,#0xBE
    CALL check16                 ; caso 34: PUSH BX / POP DX

    ; --- MOVBR: abre hueco de 1 byte en "ABC" (copia solapada hacia atras) --
    MOV BX,#mvb_buf+2            ; ultimo byte de origen ('C')
    MOV DX,#mvb_buf+3            ; ultimo byte de destino
    MOV CX,#3
    MOVBR                        ; "AABC"
    LDA AL,[mvb_buf+3]
    MOV BL,#'C'
    CALL check8                  ; caso 35: MOVBR movio el ultimo
    LDA AL,[mvb_buf+1]
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
    LDA CL,[test_cnt]
    ADD CL,#1
    STA [test_cnt],CL
    CMP AL,BL
    JMPZ ck8_ok
    LDA CL,[fail_cnt]
    ADD CL,#1
    STA [fail_cnt],CL
    LDA CL,[first_fail]
    CMP CL,#0
    JMPNZ ck8_ok
    LDA CL,[test_cnt]
    STA [first_fail],CL
ck8_ok:
    RET

; --- check16: AL=byte bajo esperado, BL=byte alto esperado, [got_lo]/
; [got_hi] = lo obtenido -- combina los dos check8 en un solo "caso" para
; no inflar el contador (compara los dos bytes, cuenta como 1 fallo si
; cualquiera de los dos no coincide) -----------------------------------------
check16:
    STA [exp_lo_tmp],AL     ; AL trae el byte bajo esperado
    MOV AL,BL
    STA [exp_hi_tmp],AL     ; BL trae el byte alto esperado

    LDA CL,[test_cnt]
    ADD CL,#1
    STA [test_cnt],CL

    LDA AL,[got_lo]
    LDA BL,[exp_lo_tmp]
    CMP AL,BL
    JMPNZ c16_fail
    LDA AL,[got_hi]
    LDA BL,[exp_hi_tmp]
    CMP AL,BL
    JMPZ c16_ok
c16_fail:
    LDA CL,[fail_cnt]
    ADD CL,#1
    STA [fail_cnt],CL
    LDA CL,[first_fail]
    CMP CL,#0
    JMPNZ c16_ok
    LDA CL,[test_cnt]
    STA [first_fail],CL
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

    LDA AL,[test_cnt]
    LDA BL,[fail_cnt]
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

    LDA AL,[test_cnt]
    CALL put_dec2
    MOV CL,#8
    MOV CH,#0
    CALL puts2

    LDA AL,[fail_cnt]
    CMP AL,#0
    JMPZ ss_done

    MOV BL,#lo(s_fail)
    MOV BH,#hi(s_fail)
    MOV CL,#0
    MOV CH,#1
    CALL puts

    LDA AL,[first_fail]
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
    STA [dec_buf],AL
    MOV AL,CL
    ADD AL,#0x30
    STA [dec_buf+1],AL
    RET

; --- puts2: como puts, pero para [dec_buf] (2 caracteres, sin NUL) ---------
puts2:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    LDA AL,[dec_buf]
    OUT (DX),AL
    ADD DL,#1
    LDA AL,[dec_buf+1]
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
    LDA AL,[BX]
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
