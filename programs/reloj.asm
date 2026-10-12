; ============================================================================
;  reloj.asm  -  reloj analogico de agujas, con numeros romanos (compi)
;
;  Horas, minutos y segundos de verdad: el latido lo da el temporizador T2
;  armado a 250 pasos de 4 ms (250*4 = 1000 ms exactos), no un contador de
;  "fotogramas" aproximado -- mientras el aparato este en EJECUTAR+CONTINUO,
;  el segundero avanza al ritmo real del reloj del aparato.
;
;  Se pone en hora SOLO si el aparato tiene la hora real (puertos 0x0670..,
;  que da el Wi-Fi o el PC: ver docs/isa.md), y se vuelve a ajustar a ella
;  cada minuto. Si no la tiene, arranca en 12:00:00. A mano:
;     encoder DIRECCION (el de la izquierda, "ADDR") gira -> horas
;     encoder DATOS      (el de la derecha,  "DATA") gira -> minutos
;  (los segundos no se pueden ajustar a mano; siguen corriendo desde 0).
;  Tocar la hora a mano deja de seguir la hora real hasta la siguiente
;  ejecucion.
;
;  Numeros romanos: I, V, X son trazos rectos, perfectos para Bresenham. Cada
;  numeral es una lista de hasta 5 segmentos en coordenadas LOCALES (relativas
;  a su propio centro, calculadas una vez en Python -- ver NUM_SEG mas abajo),
;  que se trasladan al punto de la esfera que le toque en cada momento. No
;  giran nunca (los numeros de un reloj de verdad tampoco).
;
;  Reutiliza tal cual de programs/cubo.asm: smul64 (multiplicacion con signo;
;  por dentro usa la instruccion MUL, ver docs/isa.md SS4d), idx_ptr,
;  calc_pix/pix_on, line_draw (Bresenham) y clsg. La geometria (agujas y
;  numeros) usa el mismo truco de tabla de seno
;  con "cuarto de vuelta de desfase" para el coseno, pero con una tabla de
;  60 pasos (no 64): asi los segundos y minutos (0..59) y las horas (de 5 en
;  5) caen exactos en la tabla, sin necesitar multiplicar por nada raro en
;  tiempo de ejecucion.
;
;  Controles en EJECUTAR + CONTINUO:
;     encoder DIRECCION gira  -> +-1 hora
;     encoder DATOS gira      -> +-1 minuto
;     pulsar CUALQUIERA de los dos pulsadores -> segundero a 0 (como el
;       "hack-set" de un reloj de verdad: sirve para sincronizar el segundero
;       con una señal horaria exacta sin tocar hora/minutos)
;
;  Esta version ya no tiene una tecla para "salir" del programa -- para eso
;  esta el interruptor SW_MODE del panel (vuelve a MOD), que corta la
;  ejecucion pase lo que pase el programa, sin que este tenga que hacer nada
;  especial.
;
;  Ensamblar y enviar al slot 1:
;     python3 tools/casm.py programs/reloj.asm -o programs/reloj.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 1 programs/reloj.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 1

    .name "CLOCK"

    .category PROGRAM
    .org 0x0000

CX = 64          ; centro de la esfera
CY = 32          ; sin titulo, la esfera usa toda la altura -> centro real
LEN_HOUR = 14    ; longitud de las agujas
LEN_MIN  = 21
LEN_SEC  = 26
LEN_NUM  = 28    ; radio al que se colocan los numeros romanos (ver nota abajo)

; nota sobre LEN_NUM: el trazo de un numeral se extiende +-3 en vertical desde
; su centro (ver NUM_SEG). Con CY=32 y radio 28, el numeral de las 6 queda
; centrado en fila 60 y su trazo baja hasta la fila 63 -- justo el limite de
; la pantalla (0..63); el de las 12 sube hasta la fila 1. Es el maximo radio
; que cabe entero: subir LEN_NUM haria que esos trazos se salieran por arriba
; o por abajo.

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000
P_DIR_POS = 0x0600   ; encoder izquierdo (ADDR/DIRECCION): posicion -> horas
P_DIR_BTN = 0x0601   ; encoder izquierdo: pulsador -> segundero a 0
P_DAT_POS = 0x0602   ; encoder derecho (DATA/DATOS): posicion -> minutos
P_DAT_BTN = 0x0603   ; encoder derecho: pulsador -> segundero a 0 (igual)
P_T2      = 0x0622   ; latido de 1 s (armado a 250 pasos de 4 ms)
P_T3      = 0x0623   ; ritmo de sondeo del bucle principal
P_TIME    = 0x0670   ; hora real: OUT congela, IN bit 0 = hay hora
P_T_SEC   = 0x0675   ; segundo, minuto, hora (locales)
P_T_MIN   = 0x0676
P_T_HOUR  = 0x0677

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    MOV AL,#0
    MOV [hh],AL
    MOV [mm],AL
    MOV [ss],AL

    IN  AL,(P_DIR_POS)
    MOV [dir_prev],AL
    IN  AL,(P_DAT_POS)
    MOV [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    MOV [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    MOV [dat_btn_prev],AL

    MOV [manual],AL         ; (AL = 0)
    MOV AL,#250
    OUT (P_T2),AL           ; arma el latido de 1 s
    CALL sync_rtc           ; la hora real, si el aparato la tiene

    CALL clsg
    CALL draw_numerals
    CALL draw_hands

main_l:
    MOV AL,#0
    MOV [redraw],AL

    ; --- pulsador de cualquiera de los dos encoders -> segundero a 0 -------
    ; flanco de subida (estaba suelto, ahora esta pulsado), no "esta pulsado"
    ; a secas -- si no, mientras se mantiene pulsado lo pondria a 0 sin parar.
    IN  AL,(P_DIR_BTN)
    MOV BL,[dir_btn_prev]
    MOV [dir_btn_prev],AL
    CMP AL,#0
    JMPZ dbtn_done
    CMP BL,#0
    JMPNZ dbtn_done          ; ya estaba pulsado -> no es flanco
    MOV AL,#1
    MOV [ss_reset],AL
dbtn_done:

    IN  AL,(P_DAT_BTN)
    MOV BL,[dat_btn_prev]
    MOV [dat_btn_prev],AL
    CMP AL,#0
    JMPZ abtn_done
    CMP BL,#0
    JMPNZ abtn_done
    MOV AL,#1
    MOV [ss_reset],AL
abtn_done:

    MOV AL,[ss_reset]
    CMP AL,#0
    JMPZ ssr_done
    MOV AL,#0
    MOV [ss_reset],AL
    MOV [ss],AL
    MOV AL,#250
    OUT (P_T2),AL            ; reinicia tambien el latido: el segundo "0" dura
                              ; el segundo entero, no lo que quedara del viejo
    MOV AL,#1
    MOV [redraw],AL
ssr_done:

    ; --- encoder izquierdo (DIRECCION) -> horas -----------------------------
    IN  AL,(P_DIR_POS)
    MOV [tmp0],AL
    MOV BL,[dir_prev]
    SUB AL,BL
    MOV CL,[tmp0]
    MOV [dir_prev],CL
    JMPZ hr_done
    AND AL,#0x80
    JMPZ hr_up
    MOV AL,[hh]
    CMP AL,#0
    JMPNZ hr_decok
    MOV AL,#12
hr_decok:
    SUB AL,#1
    MOV [hh],AL
    JMP hr_mark
hr_up:
    MOV AL,[hh]
    ADD AL,#1
    CMP AL,#12
    JMPNZ hr_upok
    MOV AL,#0
hr_upok:
    MOV [hh],AL
hr_mark:
    MOV AL,#1
    MOV [redraw],AL
    MOV [manual],AL
hr_done:

    ; --- encoder derecho (DATOS) -> minutos ---------------------------------
    IN  AL,(P_DAT_POS)
    MOV [tmp0],AL
    MOV BL,[dat_prev]
    SUB AL,BL
    MOV CL,[tmp0]
    MOV [dat_prev],CL
    JMPZ mn_done
    AND AL,#0x80
    JMPZ mn_up
    MOV AL,[mm]
    CMP AL,#0
    JMPNZ mn_decok
    MOV AL,#60
mn_decok:
    SUB AL,#1
    MOV [mm],AL
    JMP mn_mark
mn_up:
    MOV AL,[mm]
    ADD AL,#1
    CMP AL,#60
    JMPNZ mn_upok
    MOV AL,#0
mn_upok:
    MOV [mm],AL
mn_mark:
    MOV AL,#1
    MOV [redraw],AL
    MOV [manual],AL
mn_done:

    ; --- latido de 1 s (T2): avanza el segundero, con acarreo a min/hora ----
    IN  AL,(P_T2)
    CMP AL,#0
    JMPNZ sec_done
    MOV AL,#250
    OUT (P_T2),AL

    MOV AL,[ss]
    ADD AL,#1
    CMP AL,#60
    JMPNZ st_ss_ok
    MOV AL,#0
    MOV BL,[mm]
    ADD BL,#1
    CMP BL,#60
    JMPNZ st_mm_ok
    MOV BL,#0
    MOV CL,[hh]
    ADD CL,#1
    CMP CL,#12
    JMPNZ st_hh_ok
    MOV CL,#0
st_hh_ok:
    MOV [hh],CL
st_mm_ok:
    MOV [mm],BL
st_ss_ok:
    MOV [ss],AL
    MOV AL,#1
    MOV [redraw],AL
    MOV AL,[ss]
    CMP AL,#0
    JMPNZ sec_done
    CALL sync_rtc            ; cada minuto, a la hora real (si no se toco a mano)
sec_done:

    MOV AL,[redraw]
    CMP AL,#0
    JMPZ nr_done
    CALL clsg
    CALL draw_numerals
    CALL draw_hands
nr_done:

    MOV AL,#1
    CALL frame_wait
    JMP main_l

; ============================================================================
;  sync_rtc: si el aparato tiene la hora real y no se ha tocado a mano, la
;  copia (hora de 12) y reinicia el latido para que el segundo cuadre
; ============================================================================
sync_rtc:
    MOV AL,[manual]
    CMP AL,#0
    JMPNZ sr_done
    OUT (P_TIME),AL          ; congela la hora de ahora
    IN  AL,(P_TIME)
    AND AL,#1
    JMPZ sr_done             ; sin hora real: sigue la suya
    IN  AL,(P_T_HOUR)
    MOV AH,#0
    MOV DL,#12
    DIV DL                   ; AH = hora mod 12
    MOV [hh],AH
    IN  AL,(P_T_MIN)
    MOV [mm],AL
    IN  AL,(P_T_SEC)
    MOV [ss],AL
    MOV AL,#250
    OUT (P_T2),AL
    MOV AL,#1
    MOV [redraw],AL
sr_done:
    RET

; ============================================================================
;  div12:  AL = AL / 12  (entrada 0..59, division entera por resta repetida)
; ============================================================================
div12:
    ; DIV por hardware (docs/isa.md SS4d) en vez de restar 12 en bucle --
    ; DL sigue saliendo con el cociente, como antes.
    MOV AH,#0
    MOV DL,#12
    DIV DL
    MOV DL,AL
    RET

; ============================================================================
;  draw_hands:  traza las 3 agujas desde (CX,CY) hasta su punta
; ============================================================================
draw_hands:
    ; hora: indice = HOUR5[hh] + mm/12
    MOV CL,[hh]
    MOV BX,#HOUR5
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp_idx],AL
    MOV AL,[mm]
    CALL div12
    MOV BL,[tmp_idx]
    ADD AL,BL
    MOV [hp_idx],AL
    MOV AL,#LEN_HOUR
    MOV [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg

    ; minutero: indice = mm
    MOV AL,[mm]
    MOV [hp_idx],AL
    MOV AL,#LEN_MIN
    MOV [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg

    ; segundero: indice = ss
    MOV AL,[ss]
    MOV [hp_idx],AL
    MOV AL,#LEN_SEC
    MOV [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg
    RET

; --- draw_hand_seg: traza de (CX,CY) a (hp_x,hp_y) --------------------------
draw_hand_seg:
    MOV AL,#CX
    MOV [ln_x0],AL
    MOV AL,#CY
    MOV [ln_y0],AL
    MOV AL,[hp_x]
    MOV [ln_x1],AL
    MOV AL,[hp_y]
    MOV [ln_y1],AL
    CALL line_draw
    RET

; ============================================================================
;  hand_point:  con hp_idx (0..59) y hp_len, calcula la punta (hp_x,hp_y)
;  0 = 12 en punto (arriba); el indice avanza en el sentido horario.
;     hp_x = CX + hp_len*sin(hp_idx)/64
;     hp_y = CY - hp_len*cos(hp_idx)/64      cos(i) = sin((i+15) mod 60)
; ============================================================================
hand_point:
    MOV AL,[hp_len]
    MOV [sm_a],AL
    MOV CL,[hp_idx]
    MOV BX,#sine60
    ADD BX,CL
    MOV AL,[BX]
    MOV [sm_b],AL
    CALL smul64
    MOV [hp_t1],AL              ; hp_t1 = len*sin(idx)/64

    MOV AL,[hp_idx]
    ADD AL,#15
    CMP AL,#60
    JMPC hp_cos_ok
    SUB AL,#60
hp_cos_ok:
    MOV [tmp_idx],AL
    MOV AL,[hp_len]
    MOV [sm_a],AL
    MOV CL,[tmp_idx]
    MOV BX,#sine60
    ADD BX,CL
    MOV AL,[BX]
    MOV [sm_b],AL
    CALL smul64
    MOV [hp_t2],AL              ; hp_t2 = len*cos(idx)/64

    MOV AL,[hp_t1]
    ADD AL,#CX
    MOV [hp_x],AL

    MOV AL,#CY
    MOV BL,[hp_t2]
    SUB AL,BL
    MOV [hp_y],AL
    RET

; ============================================================================
;  draw_numerals:  traza los 12 numeros romanos alrededor de la esfera
; ============================================================================
draw_numerals:
    MOV AL,#0
    MOV [ni],AL
dn_l:
    ; centro del numeral = hand_point(NUM_IDX[ni], LEN_NUM)
    MOV CL,[ni]
    MOV BX,#NUM_IDX
    ADD BX,CL
    MOV AL,[BX]
    MOV [hp_idx],AL
    MOV AL,#LEN_NUM
    MOV [hp_len],AL
    CALL hand_point
    MOV AL,[hp_x]
    MOV [anchor_x],AL
    MOV AL,[hp_y]
    MOV [anchor_y],AL

    ; cuantos segmentos tiene este numeral
    MOV CL,[ni]
    MOV BX,#NUM_CNT
    ADD BX,CL
    MOV AL,[BX]
    MOV [seg_cnt],AL

    ; puntero al primer segmento: NUM_SEG + NUM_OFF[ni]
    MOV CL,[ni]
    MOV BX,#NUM_OFF
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp_idx],AL
    MOV CL,[tmp_idx]
    MOV BX,#NUM_SEG
    ADD BX,CL
    MOV AL,BL
    MOV [seg_ptr_lo],AL
    MOV AL,BH
    MOV [seg_ptr_hi],AL

    MOV AL,#0
    MOV [seg_i],AL
dn_seg_l:
    MOV AL,[seg_i]
    MOV BL,[seg_cnt]
    CMP AL,BL
    JMPNC dn_seg_done        ; seg_i >= seg_cnt -> no quedan segmentos

    MOV BL,[seg_ptr_lo]
    MOV BH,[seg_ptr_hi]
    MOV AL,[BX]              ; x0 local
    MOV CL,[anchor_x]
    ADD AL,CL
    MOV [ln_x0],AL

    MOV BL,[seg_ptr_lo]
    MOV BH,[seg_ptr_hi]
    INC BX
    MOV AL,[BX]              ; y0 local
    MOV CL,[anchor_y]
    ADD AL,CL
    MOV [ln_y0],AL

    MOV BL,[seg_ptr_lo]
    MOV BH,[seg_ptr_hi]
    MOV CL,#2
    ADD BX,CL
    MOV AL,[BX]              ; x1 local
    MOV CL,[anchor_x]
    ADD AL,CL
    MOV [ln_x1],AL

    MOV BL,[seg_ptr_lo]
    MOV BH,[seg_ptr_hi]
    MOV CL,#3
    ADD BX,CL
    MOV AL,[BX]              ; y1 local
    MOV CL,[anchor_y]
    ADD AL,CL
    MOV [ln_y1],AL

    CALL line_draw

    MOV BL,[seg_ptr_lo]
    MOV BH,[seg_ptr_hi]
    MOV CL,#4
    ADD BX,CL
    MOV AL,BL
    MOV [seg_ptr_lo],AL
    MOV AL,BH
    MOV [seg_ptr_hi],AL

    MOV AL,[seg_i]
    ADD AL,#1
    MOV [seg_i],AL
    JMP dn_seg_l
dn_seg_done:

    MOV AL,[ni]
    ADD AL,#1
    MOV [ni],AL
    CMP AL,#12
    JMPNZ dn_l
    RET

; ============================================================================
;  smul64:  sm_a (con signo) * sm_b (con signo) / 64, redondeado hacia 0
;  (identica a la de programs/cubo.asm)
; ============================================================================
smul64:
    MOV AL,#0
    MOV [sm_neg],AL

    MOV AL,[sm_a]
    AND AL,#0x80
    JMPZ sm_apos
    MOV AL,[sm_a]
    NOT AL
    ADD AL,#1
    MOV [sm_a],AL
    MOV AL,[sm_neg]
    XOR AL,#1
    MOV [sm_neg],AL
sm_apos:
    MOV AL,[sm_b]
    AND AL,#0x80
    JMPZ sm_bpos
    MOV AL,[sm_b]
    NOT AL
    ADD AL,#1
    MOV [sm_b],AL
    MOV AL,[sm_neg]
    XOR AL,#1
    MOV [sm_neg],AL
sm_bpos:
    ; Multiplicacion sin signo de verdad: antes un bucle de 8 pasos de
    ; "desplaza y suma condicional"; ahora una sola instruccion hardware --
    ; ver MUL en docs/isa.md SS4d. Mismo cuerpo que cubo.asm (de donde se
    ; copio esta rutina).
    MOV AL,[sm_a]
    MOV BL,[sm_b]
    MUL BL
    ; /64 de AX sin bucle: (AX >> 6) & 0xFF = (AL >> 6) | (AH << 2). Antes
    ; eran 6 vueltas desplazando sm_hi/sm_lo bit a bit con acarreo a mano
    ; (~80 instrucciones por llamada); ahora 3 con SHR/SHL reg,#N.
    SHR AL,#6
    SHL AH,#2
    OR  AL,AH
    MOV [sm_lo],AL

    MOV AL,[sm_neg]
    CMP AL,#0
    JMPZ sm_done
    MOV AL,[sm_lo]
    NOT AL
    ADD AL,#1
    MOV [sm_lo],AL
sm_done:
    MOV AL,[sm_lo]
    RET

; ============================================================================
;  line_draw:  Bresenham entero (con signo via el bit N), pinta con pix_on
;  (identica a la de programs/cubo.asm)
; ============================================================================
line_draw:
    MOV AL,[ln_x1]
    MOV BL,[ln_x0]
    CMP AL,BL
    JMPC ldx_neg
    SUB AL,BL
    MOV [ln_dx],AL
    MOV AL,#1
    MOV [ln_sx],AL
    JMP ldx_done
ldx_neg:
    MOV AL,BL
    MOV BL,[ln_x1]
    SUB AL,BL
    MOV [ln_dx],AL
    MOV AL,#0xFF
    MOV [ln_sx],AL
ldx_done:
    MOV AL,[ln_y1]
    MOV BL,[ln_y0]
    CMP AL,BL
    JMPC ldy_neg
    SUB AL,BL
    MOV [ln_dy],AL
    MOV AL,#1
    MOV [ln_sy],AL
    JMP ldy_done
ldy_neg:
    MOV AL,BL
    MOV BL,[ln_y1]
    SUB AL,BL
    MOV [ln_dy],AL
    MOV AL,#0xFF
    MOV [ln_sy],AL
ldy_done:
    MOV AL,[ln_dx]
    MOV BL,[ln_dy]
    CMP AL,BL
    JMPC ln_ymajor_init
    MOV AL,[ln_dx]
    MOV [ln_n],AL
    SHR AL
    MOV [ln_err],AL
    MOV AL,#1
    MOV [ln_xmaj],AL
    JMP ln_loop
ln_ymajor_init:
    MOV AL,[ln_dy]
    MOV [ln_n],AL
    SHR AL
    MOV [ln_err],AL
    MOV AL,#0
    MOV [ln_xmaj],AL
ln_loop:
    MOV AL,[ln_x0]
    MOV [px_x],AL
    MOV AL,[ln_y0]
    MOV [px_y],AL
    CALL pix_on

    MOV AL,[ln_n]
    CMP AL,#0
    JMPZ ln_done
    SUB AL,#1
    MOV [ln_n],AL

    MOV AL,[ln_xmaj]
    CMP AL,#0
    JMPZ ln_do_ymajor

    MOV AL,[ln_err]
    MOV BL,[ln_dy]
    SUB AL,BL
    MOV [ln_err],AL
    JMPN ln_xmaj_neg
    JMP ln_xmaj_stepx
ln_xmaj_neg:
    MOV AL,[ln_y0]
    MOV BL,[ln_sy]
    ADD AL,BL
    MOV [ln_y0],AL
    MOV AL,[ln_err]
    MOV BL,[ln_dx]
    ADD AL,BL
    MOV [ln_err],AL
ln_xmaj_stepx:
    MOV AL,[ln_x0]
    MOV BL,[ln_sx]
    ADD AL,BL
    MOV [ln_x0],AL
    JMP ln_loop

ln_do_ymajor:
    MOV AL,[ln_err]
    MOV BL,[ln_dx]
    SUB AL,BL
    MOV [ln_err],AL
    JMPN ln_ymaj_neg
    JMP ln_ymaj_stepy
ln_ymaj_neg:
    MOV AL,[ln_x0]
    MOV BL,[ln_sx]
    ADD AL,BL
    MOV [ln_x0],AL
    MOV AL,[ln_err]
    MOV BL,[ln_dy]
    ADD AL,BL
    MOV [ln_err],AL
ln_ymaj_stepy:
    MOV AL,[ln_y0]
    MOV BL,[ln_sy]
    ADD AL,BL
    MOV [ln_y0],AL
    JMP ln_loop
ln_done:
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- idx_ptr:  BX = (BL/BH iniciales) + CL, propagando el acarreo a mano ---
idx_ptr:
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
    RET

; --- pix_on:  enciende el pixel (px_x,px_y) --------------------------------
pix_on:
    CALL calc_pix
    MOV BL,[pix_lo]
    MOV BH,[pix_hi]
    IN  AL,(BX)
    MOV DL,[pix_mask]
    OR  AL,DL
    OUT (BX),AL
    RET

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
calc_pix:
    MOV CH,[px_y]
    MOV CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4
    MOV DL,CL
    SHR DL,#3
    OR  AL,DL
    MOV [pix_lo],AL
    MOV AL,CH
    SHR AL,#4
    MOV [pix_hi],AL
    MOV DL,CL
    AND DL,#0x07
    MOV DH,#0x80
cpx_m:
    CMP DL,#0
    JMPZ cpx_d
    SHR DH
    SUB DL,#1
    JMP cpx_m
cpx_d:
    MOV [pix_mask],DH
    RET

; --- clsg:  apaga el framebuffer completo (0x0000..0x03FF) -----------------
clsg:
    MOV BX,#0x0000
    MOV AL,#0
cg_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC cg_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ cg_l
    RET

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) ----------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; ============================================================================
;  DATOS  (justo despues del codigo -- ver programs/README.md, "Tamano del
;  .bin")
; ============================================================================
hh:         .space 1    ; 0..11
mm:         .space 1    ; 0..59
ss:         .space 1    ; 0..59
dir_prev:     .space 1
dat_prev:     .space 1
dir_btn_prev: .space 1
dat_btn_prev: .space 1
ss_reset:     .space 1    ; 1 = algun pulsador tuvo flanco este ciclo -> ss=0
redraw:       .space 1
manual:       .space 1    ; 1 = se ha puesto la hora a mano: no seguir la real
tmp0:         .space 1
tmp_idx:      .space 1

ni:         .space 1    ; indice de numeral en curso (0..11)
seg_i:      .space 1    ; indice de segmento en curso (0..4)
seg_cnt:    .space 1
seg_ptr_lo: .space 1
seg_ptr_hi: .space 1
anchor_x:   .space 1
anchor_y:   .space 1

hp_idx:     .space 1    ; hand_point: entrada/salida
hp_len:     .space 1
hp_x:       .space 1
hp_y:       .space 1
hp_t1:      .space 1
hp_t2:      .space 1

sm_a:       .space 1
sm_b:       .space 1
sm_neg:     .space 1
sm_hi:      .space 1
sm_lo:      .space 1

ln_x0:      .space 1
ln_y0:      .space 1
ln_x1:      .space 1
ln_y1:      .space 1
ln_dx:      .space 1
ln_dy:      .space 1
ln_sx:      .space 1
ln_sy:      .space 1
ln_err:     .space 1
ln_n:       .space 1
ln_xmaj:    .space 1

px_x:       .space 1
px_y:       .space 1
pix_lo:     .space 1
pix_hi:     .space 1
pix_mask:   .space 1

; HOUR5[h] = h*5 (indice base en la tabla de 60 pasos para cada hora en punto)
HOUR5:   .db 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55

; seno x64 con signo, 60 pasos (coseno = mismo seno con +15 de desfase)
sine60:
    .db 0, 7, 13, 20, 26, 32, 38, 43, 48, 52, 55, 58, 61, 63, 64
    .db 64, 64, 63, 61, 58, 55, 52, 48, 43, 38, 32, 26, 20, 13, 7
    .db 0, 249, 243, 236, 230, 224, 218, 213, 208, 204, 201, 198, 195, 193, 192
    .db 192, 192, 193, 195, 198, 201, 204, 208, 213, 218, 224, 230, 236, 243, 249

; NUM_IDX[n] = indice angular (0..59) del numero romano n (0=I ... 11=XII)
NUM_IDX: .db 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 0

; NUM_CNT[n] = cuantos de los 5 segmentos de NUM_SEG usa el numero romano n
NUM_CNT: .db 1, 2, 3, 3, 2, 3, 4, 5, 3, 2, 3, 4

; NUM_OFF[n] = byte de arranque de ese numero dentro de NUM_SEG (5 segmentos
; de 4 bytes cada uno = 20 bytes por numero, aunque no los use todos)
NUM_OFF: .db 0, 20, 40, 60, 80, 100, 120, 140, 160, 180, 200, 220

; NUM_SEG: 12 numeros x 5 segmentos x (x0,y0,x1,y1) locales con signo,
; centrados en (0,0) -- calculados en Python, ver el mensaje de la sesion.
; Relleno a 0,0,0,0 en los segmentos que un numero no usa (NUM_CNT dice
; cuantos leer de verdad).
NUM_SEG:
    .db 0, 253, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0            ; I
    .db 0, 253, 0, 3, 1, 253, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0          ; II
    .db 255, 253, 255, 3, 0, 253, 0, 3, 1, 253, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0    ; III
    .db 255, 253, 255, 3, 0, 253, 1, 3, 1, 3, 2, 253, 0, 0, 0, 0, 0, 0, 0, 0    ; IV
    .db 255, 253, 0, 3, 0, 3, 1, 253, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0        ; V
    .db 255, 253, 0, 3, 0, 3, 1, 253, 2, 253, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0      ; VI
    .db 254, 253, 255, 3, 255, 3, 0, 253, 1, 253, 1, 3, 2, 253, 2, 3, 0, 0, 0, 0 ; VII
    .db 254, 253, 255, 3, 255, 3, 0, 253, 1, 253, 1, 3, 2, 253, 2, 3, 3, 253, 3, 3 ; VIII
    .db 255, 253, 255, 3, 0, 253, 2, 3, 0, 3, 2, 253, 0, 0, 0, 0, 0, 0, 0, 0    ; IX
    .db 255, 253, 1, 3, 255, 3, 1, 253, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0      ; X
    .db 255, 253, 1, 3, 255, 3, 1, 253, 2, 253, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0    ; XI
    .db 254, 253, 0, 3, 254, 3, 0, 253, 1, 253, 1, 3, 2, 253, 2, 3, 0, 0, 0, 0  ; XII
