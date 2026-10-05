; ============================================================================
;  brillo_cal.asm  -  CALIBRACION del brillo (PORT_CFG_BRIGHTNESS, 0..255)
;
;  Pinta toda la pantalla de blanco y deja el brillo en 255. Cada detente
;  de DATOS sube o baja el valor CAL_STEP=16 unidades (saturando en 0 y 255), y el valor
;  actual se muestra en texto. Sirve para anotar a OJO en que valores del
;  mando el brillo de la pantalla cambia de verdad (y en cuales no cambia
;  nada) -- la pantalla entera es el "medidor", no hace falta nada mas.
;
;  Se usa para medir el rango visible antes de tocar BRIGHT_FLOOR/BRIGHT_STEP
;  en sisop.asm (ver el aviso alli): en el panel real, un suelo de 160 no
;  dio ningun cambio perceptible.
;
;  MANEJO:
;     encoder DATOS gira  -> sube/baja el brillo 16 unidades por detente
;     encoder DIRECCION pulsa -> sale al sistema (slot 0)
;
;  Para probarlo: no se añade al menu de sisop. Se graba en el slot 21 y se
;  arranca desde el panel (o desde sisop.asm cargando el slot 21 a mano).
;     python3 tools/casm.py programs/brillo_cal.asm -o programs/brillo_cal.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 21 programs/brillo_cal.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 21
    .org 0x0000

; --- paso del brillo por detente de DATOS (unidades de PORT_CFG_BRIGHTNESS) -
CAL_STEP         = 16

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_BTN        = 0x0601
P_DAT_POS        = 0x0602
P_T3             = 0x0623
P_CFG_BRIGHTNESS = 0x0650
P_PROG_LOAD      = 0x0640

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    IN  AL,(P_CFG_BRIGHTNESS)    ; brillo que habia ANTES de calibrar: se restaura al salir
    STA [orig],AL
    IN  AL,(P_DAT_POS)
    STA [gp_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_prev],AL

    CALL fill_white              ; pantalla entera encendida = el medidor
    CALL clst
    MOV BL,#lo(s_title)
    MOV BH,#hi(s_title)
    MOV CL,#2
    MOV CH,#0
    CALL puts
    MOV BL,#lo(s_help1)
    MOV BH,#hi(s_help1)
    MOV CL,#1
    MOV CH,#5
    CALL puts
    MOV BL,#lo(s_help2)
    MOV BH,#hi(s_help2)
    MOV CL,#1
    MOV CH,#6
    CALL puts

    MOV AL,#255
    STA [val],AL
    OUT (P_CFG_BRIGHTNESS),AL
    CALL show_val

; ============================================================================
;  BUCLE: lee DATOS, aplica el giro al brillo y sale con DIRECCION
; ============================================================================
main_l:
    IN  AL,(P_DAT_POS)
    STA [tmp],AL
    LDA BL,[gp_prev]
    SUB AL,BL                    ; AL = giro de este fotograma (con signo)
    STA [dl],AL
    LDA CL,[tmp]
    STA [gp_prev],CL

    LDA AL,[dl]
    CMP AL,#0
    JMPZ btn_check
    AND AL,#0x80
    JMPNZ vdown

    ; giro a la derecha: un paso de CAL_STEP por cada detente
    LDA AL,[dl]
    STA [cnt],AL
vup_l:
    CALL step_up
    LDA AL,[cnt]
    SUB AL,#1
    STA [cnt],AL
    JMPNZ vup_l
    JMP vapply

vdown:
    ; giro a la izquierda: un paso de CAL_STEP hacia abajo por detente
    LDA AL,[dl]
    NOT AL
    ADD AL,#1                    ; AL = numero de detentes (positivo)
    STA [cnt],AL
vdn_l:
    CALL step_down
    LDA AL,[cnt]
    SUB AL,#1
    STA [cnt],AL
    JMPNZ vdn_l

vapply:
    LDA AL,[val]
    OUT (P_CFG_BRIGHTNESS),AL
    CALL show_val

btn_check:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPNZ do_exit
    MOV AL,#2
    CALL frame_wait
    JMP main_l

do_exit:
    LDA AL,[orig]
    OUT (P_CFG_BRIGHTNESS),AL   ; el brillo es global y persiste entre programas -- dejarlo como estaba
    MOV AL,#0
    OUT (P_PROG_LOAD),AL         ; vuelve al sistema (sisop, slot 0)
    HALT

; ============================================================================
;  RUTINAS
; ============================================================================

; --- step_up / step_down: un paso de CAL_STEP sobre [val], saturando en 255/0
step_up:
    LDA AL,[val]
    ADD AL,#CAL_STEP
    JMPC su_sat
    STA [val],AL
    RET
su_sat:
    MOV AL,#255
    STA [val],AL
    RET

step_down:
    LDA AL,[val]
    CMP AL,#CAL_STEP
    JMPC sd_sat                  ; val < CAL_STEP -> no cabe la resta entera
    SUB AL,#CAL_STEP
    STA [val],AL
    RET
sd_sat:
    MOV AL,#0
    STA [val],AL
    RET

; --- show_val: escribe "VALUE nnn" en la fila 3 con el valor de [val] ------
show_val:
    MOV BL,#lo(s_val)
    MOV BH,#hi(s_val)
    MOV CL,#3
    MOV CH,#3
    CALL puts

    LDA AL,[val]
    STA [pv],AL
    MOV DL,#0
sv_h:
    LDA AL,[pv]
    CMP AL,#100
    JMPC sv_hd
    SUB AL,#100
    STA [pv],AL
    ADD DL,#1
    JMP sv_h
sv_hd:
    MOV AL,DL
    ADD AL,#'0'
    MOV BL,AL
    MOV CL,#9
    MOV CH,#3
    CALL putc

    MOV DL,#0
sv_t:
    LDA AL,[pv]
    CMP AL,#10
    JMPC sv_td
    SUB AL,#10
    STA [pv],AL
    ADD DL,#1
    JMP sv_t
sv_td:
    MOV AL,DL
    ADD AL,#'0'
    MOV BL,AL
    MOV CL,#10
    MOV CH,#3
    CALL putc

    LDA AL,[pv]
    ADD AL,#'0'
    MOV BL,AL
    MOV CL,#11
    MOV CH,#3
    CALL putc
    RET

; --- fill_white: pone a 1 los 1024 bytes del framebuffer (pantalla blanca) -
fill_white:
    MOV BL,#0
    MOV BH,#0
    MOV AL,#0xFF
fw_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC fw_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ fw_l
    RET

; --- clst: borra la capa de texto (0x0400..0x04FF) -------------------------
clst:
    MOV DL,#0
    MOV DH,#0x04
    MOV AL,#0
clst_l:
    OUT (DX),AL
    ADD DL,#1
    JMPNZ clst_l
    RET

; --- putc: BL = caracter, CL = col, CH = fila -------------------------------
putc:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
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

; --- frame_wait: AL = pasos del temporizador 3 (8 ms/paso) -------------------
frame_wait:
    OUT (P_T3),AL
fw2_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw2_l
    RET

; ============================================================================
;  DATOS
; ============================================================================
s_title: .asciiz "BRIGHTNESS CAL"
s_help1: .asciiz "TURN: 16 PER DETENT"
s_help2: .asciiz "DIR: EXIT"
s_val:   .asciiz "VALUE"

orig:     .space 1     ; brillo al entrar (se restaura al salir)
gp_prev:  .space 1     ; posicion de DATOS en el fotograma anterior
dir_prev: .space 1     ; (sin uso real; se deja como referencia del patron)
tmp:      .space 1
dl:       .space 1     ; giro del fotograma (y luego su magnitud)
val:      .space 1     ; brillo actual 0..255
cnt:      .space 1     ; detentes pendientes de aplicar en este fotograma
pv:       .space 1     ; trabajo de show_val (valor a descomponer)
