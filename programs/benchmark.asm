; ============================================================================
;  benchmark.asm  -  mide la velocidad real del interprete de compi (compi)
;
;  Cuenta cuantas veces completa un bucle muy apretado (16 bits, via BX) en
;  una ventana de tiempo FIJA y exacta: el temporizador mas lento (t7, 128
;  ms/paso) armado a 250 pasos = 250*128 = 32.000 ms exactos. No hace falta
;  reloj de pared: el propio aparato mide el tiempo.
;
;  El bucle interior es:
;       ADD BL,#1
;       JMPNC bucle          ; 2 instrucciones, 65536 veces por "bloque"
;  cada vez que BX completa una vuelta entera (65536 iteraciones) se cuenta
;  un "bloque" en CX (16 bits). El resultado que se ve en pantalla es CX en
;  hexadecimal (4 digitos): N = numero de bloques de 65536 iteraciones que
;  cupieron en los 32 segundos.
;
;  Para sacar instrucciones/segundo a partir de lo que se ve en pantalla:
;       iteraciones  = N * 65536
;       instrucciones ~= iteraciones * 2.008        (el 0.008 de mas es el
;                        coste, ya contado, de la comprobacion de acarreo de
;                        BH/CX y de leer el temporizador una vez por bloque)
;       IPS          = instrucciones / 32
;
;  Ejemplo: si la pantalla muestra "N=0x004A" (N=74 en decimal),
;       IPS ~= 74 * 65536 * 2.008 / 32 ~= 305 000 instrucciones/segundo
;
;  No hay entrada de usuario ni salida por boton: se deja correr, se lee el
;  resultado y se vuelve a EDITAR con el interruptor SW_MODE del panel.
;
;  Ensamblar y enviar al slot 57:
;     python3 tools/casm.py programs/benchmark.asm -o programs/benchmark.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/benchmark.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 57
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_T7 = 0x0627      ; temporizador 7: el mas lento, 128 ms/paso

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    MOV BL,#lo(s_title)
    MOV BH,#hi(s_title)
    MOV CL,#1
    MOV CH,#0
    CALL puts

    MOV BL,#lo(s_wait)
    MOV BH,#hi(s_wait)
    MOV CL,#1
    MOV CH,#2
    CALL puts

    ; --- arma el temporizador mas lento: 250*128 ms = 32.000 s exactos -----
    MOV BL,#0
    MOV BH,#0
    MOV CL,#0
    MOV CH,#0
    MOV AL,#250
    OUT (P_T7),AL

; ============================================================================
;  BUCLE DE MEDIDA: cuenta vueltas completas de BX (16 bits) en CX
; ============================================================================
bench_l:
    ADD BL,#1
    JMPNC bench_l
    ADD BH,#1
    JMPNC bench_l
    ; BX acaba de dar una vuelta completa (65536 iteraciones) -> CX++
    ADD CL,#1
    JMPNC bench_chk
    ADD CH,#1
bench_chk:
    IN  AL,(P_T7)
    CMP AL,#0
    JMPNZ bench_l

    ; --- fin de la medida: guarda CX antes de que puts/etc. la toquen ------
    STA [res_hi],CH
    STA [res_lo],CL

    MOV BL,#lo(s_done)
    MOV BH,#hi(s_done)
    MOV CL,#1
    MOV CH,#4
    CALL puts

    ; N=0x + 4 digitos hex, justo despues de "N=0x" (que ocupa col 1..4)
    LDA AL,[res_hi]
    SHR AL,#4
    CALL hex_digit
    MOV BL,AL
    MOV CL,#5
    MOV CH,#4
    CALL putc

    LDA AL,[res_hi]
    AND AL,#0x0F
    CALL hex_digit
    MOV BL,AL
    MOV CL,#6
    MOV CH,#4
    CALL putc

    LDA AL,[res_lo]
    SHR AL,#4
    CALL hex_digit
    MOV BL,AL
    MOV CL,#7
    MOV CH,#4
    CALL putc

    LDA AL,[res_lo]
    AND AL,#0x0F
    CALL hex_digit
    MOV BL,AL
    MOV CL,#8
    MOV CH,#4
    CALL putc

    HALT

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- hex_digit: AL(0..15) -> AL = caracter ASCII hex (mayuscula) -----------
hex_digit:
    CMP AL,#10
    JMPC hd_num          ; AL < 10 -> digito '0'..'9'
    SUB AL,#10
    ADD AL,#'A'
    RET
hd_num:
    ADD AL,#'0'
    RET

; --- putc:  BL = caracter,  CL = col,  CH = fila ---------------------------
putc:
    MOV AL,CH
    SHL AL,#5                   ; fila*32
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila ------------------
puts:
    MOV AL,CH
    SHL AL,#5                   ; fila*32
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

; ============================================================================
;  DATOS
; ============================================================================
res_hi: .space 1
res_lo: .space 1

s_title: .asciiz "BENCHMARK COMPI"
s_wait:  .asciiz "MIDIENDO 32s..."
s_done:  .asciiz "N=0x"
