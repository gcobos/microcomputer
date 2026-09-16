; ============================================================================
;  reloj.asm  -  reloj analogico de agujas, con numeros romanos (compi)
;
;  Horas, minutos y segundos de verdad: el latido lo da el temporizador T2
;  armado a 250 pasos de 4 ms (250*4 = 1000 ms exactos), no un contador de
;  "fotogramas" aproximado -- mientras el aparato este en EJECUTAR+CONTINUO,
;  el segundero avanza al ritmo real del reloj del aparato.
;
;  Como no hay pila ni bateria de respaldo, el reloj SIEMPRE arranca en
;  12:00:00 -- no "recuerda" la hora entre ejecuciones. Para ponerlo en hora:
;     encoder DIRECCION (el de la izquierda, "ADDR") gira -> horas
;     encoder DATOS      (el de la derecha,  "DATA") gira -> minutos
;  (los segundos no se pueden ajustar a mano; siguen corriendo desde 0)
;
;  Numeros romanos: I, V, X son trazos rectos, perfectos para Bresenham. Cada
;  numeral es una lista de hasta 5 segmentos en coordenadas LOCALES (relativas
;  a su propio centro, calculadas una vez en Python -- ver NUM_SEG mas abajo),
;  que se trasladan al punto de la esfera que le toque en cada momento. No
;  giran nunca (los numeros de un reloj de verdad tampoco).
;
;  Reutiliza tal cual de programs/cubo.asm: smul64 (multiplicacion con signo,
;  la CPU no tiene MUL), idx_ptr, calc_pix/pix_on, line_draw (Bresenham) y
;  clsg. La geometria (agujas y numeros) usa el mismo truco de tabla de seno
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
;  esta el interruptor SW_MODE del panel (vuelve a EDIT), que corta la
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

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    MOV AL,#0
    STA [hh],AL
    STA [mm],AL
    STA [ss],AL

    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL

    MOV AL,#250
    OUT (P_T2),AL           ; arma el latido de 1 s

    CALL clsg
    CALL draw_numerals
    CALL draw_hands

main_l:
    MOV AL,#0
    STA [redraw],AL

    ; --- pulsador de cualquiera de los dos encoders -> segundero a 0 -------
    ; flanco de subida (estaba suelto, ahora esta pulsado), no "esta pulsado"
    ; a secas -- si no, mientras se mantiene pulsado lo pondria a 0 sin parar.
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ dbtn_done
    CMP BL,#0
    JMPNZ dbtn_done          ; ya estaba pulsado -> no es flanco
    MOV AL,#1
    STA [ss_reset],AL
dbtn_done:

    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ abtn_done
    CMP BL,#0
    JMPNZ abtn_done
    MOV AL,#1
    STA [ss_reset],AL
abtn_done:

    LDA AL,[ss_reset]
    CMP AL,#0
    JMPZ ssr_done
    MOV AL,#0
    STA [ss_reset],AL
    STA [ss],AL
    MOV AL,#250
    OUT (P_T2),AL            ; reinicia tambien el latido: el segundo "0" dura
                              ; el segundo entero, no lo que quedara del viejo
    MOV AL,#1
    STA [redraw],AL
ssr_done:

    ; --- encoder izquierdo (DIRECCION) -> horas -----------------------------
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_prev],CL
    JMPZ hr_done
    AND AL,#0x80
    JMPZ hr_up
    LDA AL,[hh]
    CMP AL,#0
    JMPNZ hr_decok
    MOV AL,#12
hr_decok:
    SUB AL,#1
    STA [hh],AL
    JMP hr_mark
hr_up:
    LDA AL,[hh]
    ADD AL,#1
    CMP AL,#12
    JMPNZ hr_upok
    MOV AL,#0
hr_upok:
    STA [hh],AL
hr_mark:
    MOV AL,#1
    STA [redraw],AL
hr_done:

    ; --- encoder derecho (DATOS) -> minutos ---------------------------------
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_prev],CL
    JMPZ mn_done
    AND AL,#0x80
    JMPZ mn_up
    LDA AL,[mm]
    CMP AL,#0
    JMPNZ mn_decok
    MOV AL,#60
mn_decok:
    SUB AL,#1
    STA [mm],AL
    JMP mn_mark
mn_up:
    LDA AL,[mm]
    ADD AL,#1
    CMP AL,#60
    JMPNZ mn_upok
    MOV AL,#0
mn_upok:
    STA [mm],AL
mn_mark:
    MOV AL,#1
    STA [redraw],AL
mn_done:

    ; --- latido de 1 s (T2): avanza el segundero, con acarreo a min/hora ----
    IN  AL,(P_T2)
    CMP AL,#0
    JMPNZ sec_done
    MOV AL,#250
    OUT (P_T2),AL

    LDA AL,[ss]
    ADD AL,#1
    CMP AL,#60
    JMPNZ st_ss_ok
    MOV AL,#0
    LDA BL,[mm]
    ADD BL,#1
    CMP BL,#60
    JMPNZ st_mm_ok
    MOV BL,#0
    LDA CL,[hh]
    ADD CL,#1
    CMP CL,#12
    JMPNZ st_hh_ok
    MOV CL,#0
st_hh_ok:
    STA [hh],CL
st_mm_ok:
    STA [mm],BL
st_ss_ok:
    STA [ss],AL
    MOV AL,#1
    STA [redraw],AL
sec_done:

    LDA AL,[redraw]
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
;  div12:  AL = AL / 12  (entrada 0..59, division entera por resta repetida)
; ============================================================================
div12:
    MOV DL,#0
d12_l:
    CMP AL,#12
    JMPC d12_d
    SUB AL,#12
    ADD DL,#1
    JMP d12_l
d12_d:
    MOV AL,DL
    RET

; ============================================================================
;  draw_hands:  traza las 3 agujas desde (CX,CY) hasta su punta
; ============================================================================
draw_hands:
    ; hora: indice = HOUR5[hh] + mm/12
    LDA CL,[hh]
    MOV BL,#lo(HOUR5)
    MOV BH,#hi(HOUR5)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp_idx],AL
    LDA AL,[mm]
    CALL div12
    LDA BL,[tmp_idx]
    ADD AL,BL
    STA [hp_idx],AL
    MOV AL,#LEN_HOUR
    STA [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg

    ; minutero: indice = mm
    LDA AL,[mm]
    STA [hp_idx],AL
    MOV AL,#LEN_MIN
    STA [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg

    ; segundero: indice = ss
    LDA AL,[ss]
    STA [hp_idx],AL
    MOV AL,#LEN_SEC
    STA [hp_len],AL
    CALL hand_point
    CALL draw_hand_seg
    RET

; --- draw_hand_seg: traza de (CX,CY) a (hp_x,hp_y) --------------------------
draw_hand_seg:
    MOV AL,#CX
    STA [ln_x0],AL
    MOV AL,#CY
    STA [ln_y0],AL
    LDA AL,[hp_x]
    STA [ln_x1],AL
    LDA AL,[hp_y]
    STA [ln_y1],AL
    CALL line_draw
    RET

; ============================================================================
;  hand_point:  con hp_idx (0..59) y hp_len, calcula la punta (hp_x,hp_y)
;  0 = 12 en punto (arriba); el indice avanza en el sentido horario.
;     hp_x = CX + hp_len*sin(hp_idx)/64
;     hp_y = CY - hp_len*cos(hp_idx)/64      cos(i) = sin((i+15) mod 60)
; ============================================================================
hand_point:
    LDA AL,[hp_len]
    STA [sm_a],AL
    LDA CL,[hp_idx]
    MOV BL,#lo(sine60)
    MOV BH,#hi(sine60)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [hp_t1],AL              ; hp_t1 = len*sin(idx)/64

    LDA AL,[hp_idx]
    ADD AL,#15
    CMP AL,#60
    JMPC hp_cos_ok
    SUB AL,#60
hp_cos_ok:
    STA [tmp_idx],AL
    LDA AL,[hp_len]
    STA [sm_a],AL
    LDA CL,[tmp_idx]
    MOV BL,#lo(sine60)
    MOV BH,#hi(sine60)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [hp_t2],AL              ; hp_t2 = len*cos(idx)/64

    LDA AL,[hp_t1]
    ADD AL,#CX
    STA [hp_x],AL

    MOV AL,#CY
    LDA BL,[hp_t2]
    SUB AL,BL
    STA [hp_y],AL
    RET

; ============================================================================
;  draw_numerals:  traza los 12 numeros romanos alrededor de la esfera
; ============================================================================
draw_numerals:
    MOV AL,#0
    STA [ni],AL
dn_l:
    ; centro del numeral = hand_point(NUM_IDX[ni], LEN_NUM)
    LDA CL,[ni]
    MOV BL,#lo(NUM_IDX)
    MOV BH,#hi(NUM_IDX)
    CALL idx_ptr
    LDA AL,[BX]
    STA [hp_idx],AL
    MOV AL,#LEN_NUM
    STA [hp_len],AL
    CALL hand_point
    LDA AL,[hp_x]
    STA [anchor_x],AL
    LDA AL,[hp_y]
    STA [anchor_y],AL

    ; cuantos segmentos tiene este numeral
    LDA CL,[ni]
    MOV BL,#lo(NUM_CNT)
    MOV BH,#hi(NUM_CNT)
    CALL idx_ptr
    LDA AL,[BX]
    STA [seg_cnt],AL

    ; puntero al primer segmento: NUM_SEG + NUM_OFF[ni]
    LDA CL,[ni]
    MOV BL,#lo(NUM_OFF)
    MOV BH,#hi(NUM_OFF)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp_idx],AL
    LDA CL,[tmp_idx]
    MOV BL,#lo(NUM_SEG)
    MOV BH,#hi(NUM_SEG)
    CALL idx_ptr
    MOV AL,BL
    STA [seg_ptr_lo],AL
    MOV AL,BH
    STA [seg_ptr_hi],AL

    MOV AL,#0
    STA [seg_i],AL
dn_seg_l:
    LDA AL,[seg_i]
    LDA BL,[seg_cnt]
    CMP AL,BL
    JMPNC dn_seg_done        ; seg_i >= seg_cnt -> no quedan segmentos

    LDA BL,[seg_ptr_lo]
    LDA BH,[seg_ptr_hi]
    LDA AL,[BX]              ; x0 local
    LDA CL,[anchor_x]
    ADD AL,CL
    STA [ln_x0],AL

    LDA BL,[seg_ptr_lo]
    LDA BH,[seg_ptr_hi]
    MOV CL,#1
    CALL idx_ptr
    LDA AL,[BX]              ; y0 local
    LDA CL,[anchor_y]
    ADD AL,CL
    STA [ln_y0],AL

    LDA BL,[seg_ptr_lo]
    LDA BH,[seg_ptr_hi]
    MOV CL,#2
    CALL idx_ptr
    LDA AL,[BX]              ; x1 local
    LDA CL,[anchor_x]
    ADD AL,CL
    STA [ln_x1],AL

    LDA BL,[seg_ptr_lo]
    LDA BH,[seg_ptr_hi]
    MOV CL,#3
    CALL idx_ptr
    LDA AL,[BX]              ; y1 local
    LDA CL,[anchor_y]
    ADD AL,CL
    STA [ln_y1],AL

    CALL line_draw

    LDA BL,[seg_ptr_lo]
    LDA BH,[seg_ptr_hi]
    MOV CL,#4
    CALL idx_ptr
    MOV AL,BL
    STA [seg_ptr_lo],AL
    MOV AL,BH
    STA [seg_ptr_hi],AL

    LDA AL,[seg_i]
    ADD AL,#1
    STA [seg_i],AL
    JMP dn_seg_l
dn_seg_done:

    LDA AL,[ni]
    ADD AL,#1
    STA [ni],AL
    CMP AL,#12
    JMPNZ dn_l
    RET

; ============================================================================
;  smul64:  sm_a (con signo) * sm_b (con signo) / 64, redondeado hacia 0
;  (identica a la de programs/cubo.asm)
; ============================================================================
smul64:
    MOV AL,#0
    STA [sm_neg],AL

    LDA AL,[sm_a]
    AND AL,#0x80
    JMPZ sm_apos
    LDA AL,[sm_a]
    NOT AL
    ADD AL,#1
    STA [sm_a],AL
    LDA AL,[sm_neg]
    XOR AL,#1
    STA [sm_neg],AL
sm_apos:
    LDA AL,[sm_b]
    AND AL,#0x80
    JMPZ sm_bpos
    LDA AL,[sm_b]
    NOT AL
    ADD AL,#1
    STA [sm_b],AL
    LDA AL,[sm_neg]
    XOR AL,#1
    STA [sm_neg],AL
sm_bpos:
    MOV AL,#0
    STA [sm_hi],AL
    STA [sm_lo],AL
    LDA AL,[sm_a]
    STA [sm_m_lo],AL
    MOV AL,#0
    STA [sm_m_hi],AL
    MOV AL,#8
    STA [sm_cnt],AL
sm_loop:
    LDA AL,[sm_b]
    AND AL,#1
    JMPZ sm_noadd
    LDA AL,[sm_lo]
    LDA BL,[sm_m_lo]
    ADD AL,BL
    STA [sm_lo],AL
    LDA AL,[sm_hi]
    LDA BL,[sm_m_hi]
    JMPNC sm_addhi
    ADD AL,#1
sm_addhi:
    ADD AL,BL
    STA [sm_hi],AL
sm_noadd:
    LDA AL,[sm_m_lo]
    SHL AL
    STA [sm_m_lo],AL
    JMPNC sm_mnocarry
    MOV AL,#1
    STA [sm_carry],AL
    JMP sm_mcarrydone
sm_mnocarry:
    MOV AL,#0
    STA [sm_carry],AL
sm_mcarrydone:
    LDA AL,[sm_m_hi]
    SHL AL
    LDA BL,[sm_carry]
    OR AL,BL
    STA [sm_m_hi],AL

    LDA AL,[sm_b]
    SHR AL
    STA [sm_b],AL

    LDA AL,[sm_cnt]
    SUB AL,#1
    STA [sm_cnt],AL
    JMPNZ sm_loop

    MOV AL,#6
    STA [sm_cnt],AL
sm_shr_loop:
    LDA AL,[sm_hi]
    SHR AL
    STA [sm_hi],AL
    JMPNC sm_shr_nocarry
    MOV AL,#0x80
    STA [sm_carry],AL
    JMP sm_shr_carrydone
sm_shr_nocarry:
    MOV AL,#0
    STA [sm_carry],AL
sm_shr_carrydone:
    LDA AL,[sm_lo]
    SHR AL
    LDA BL,[sm_carry]
    OR AL,BL
    STA [sm_lo],AL

    LDA AL,[sm_cnt]
    SUB AL,#1
    STA [sm_cnt],AL
    JMPNZ sm_shr_loop

    LDA AL,[sm_neg]
    CMP AL,#0
    JMPZ sm_done
    LDA AL,[sm_lo]
    NOT AL
    ADD AL,#1
    STA [sm_lo],AL
sm_done:
    LDA AL,[sm_lo]
    RET

; ============================================================================
;  line_draw:  Bresenham entero (con signo via el bit N), pinta con pix_on
;  (identica a la de programs/cubo.asm)
; ============================================================================
line_draw:
    LDA AL,[ln_x1]
    LDA BL,[ln_x0]
    CMP AL,BL
    JMPC ldx_neg
    SUB AL,BL
    STA [ln_dx],AL
    MOV AL,#1
    STA [ln_sx],AL
    JMP ldx_done
ldx_neg:
    MOV AL,BL
    LDA BL,[ln_x1]
    SUB AL,BL
    STA [ln_dx],AL
    MOV AL,#0xFF
    STA [ln_sx],AL
ldx_done:
    LDA AL,[ln_y1]
    LDA BL,[ln_y0]
    CMP AL,BL
    JMPC ldy_neg
    SUB AL,BL
    STA [ln_dy],AL
    MOV AL,#1
    STA [ln_sy],AL
    JMP ldy_done
ldy_neg:
    MOV AL,BL
    LDA BL,[ln_y1]
    SUB AL,BL
    STA [ln_dy],AL
    MOV AL,#0xFF
    STA [ln_sy],AL
ldy_done:
    LDA AL,[ln_dx]
    LDA BL,[ln_dy]
    CMP AL,BL
    JMPC ln_ymajor_init
    LDA AL,[ln_dx]
    STA [ln_n],AL
    SHR AL
    STA [ln_err],AL
    MOV AL,#1
    STA [ln_xmaj],AL
    JMP ln_loop
ln_ymajor_init:
    LDA AL,[ln_dy]
    STA [ln_n],AL
    SHR AL
    STA [ln_err],AL
    MOV AL,#0
    STA [ln_xmaj],AL
ln_loop:
    LDA AL,[ln_x0]
    STA [px_x],AL
    LDA AL,[ln_y0]
    STA [px_y],AL
    CALL pix_on

    LDA AL,[ln_n]
    CMP AL,#0
    JMPZ ln_done
    SUB AL,#1
    STA [ln_n],AL

    LDA AL,[ln_xmaj]
    CMP AL,#0
    JMPZ ln_do_ymajor

    LDA AL,[ln_err]
    LDA BL,[ln_dy]
    SUB AL,BL
    STA [ln_err],AL
    JMPN ln_xmaj_neg
    JMP ln_xmaj_stepx
ln_xmaj_neg:
    LDA AL,[ln_y0]
    LDA BL,[ln_sy]
    ADD AL,BL
    STA [ln_y0],AL
    LDA AL,[ln_err]
    LDA BL,[ln_dx]
    ADD AL,BL
    STA [ln_err],AL
ln_xmaj_stepx:
    LDA AL,[ln_x0]
    LDA BL,[ln_sx]
    ADD AL,BL
    STA [ln_x0],AL
    JMP ln_loop

ln_do_ymajor:
    LDA AL,[ln_err]
    LDA BL,[ln_dx]
    SUB AL,BL
    STA [ln_err],AL
    JMPN ln_ymaj_neg
    JMP ln_ymaj_stepy
ln_ymaj_neg:
    LDA AL,[ln_x0]
    LDA BL,[ln_sx]
    ADD AL,BL
    STA [ln_x0],AL
    LDA AL,[ln_err]
    LDA BL,[ln_dy]
    ADD AL,BL
    STA [ln_err],AL
ln_ymaj_stepy:
    LDA AL,[ln_y0]
    LDA BL,[ln_sy]
    ADD AL,BL
    STA [ln_y0],AL
    JMP ln_loop
ln_done:
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- idx_ptr:  BX = (BL/BH iniciales) + CL, propagando el acarreo a mano ---
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- pix_on:  enciende el pixel (px_x,px_y) --------------------------------
pix_on:
    CALL calc_pix
    LDA BL,[pix_lo]
    LDA BH,[pix_hi]
    IN  AL,(BX)
    LDA DL,[pix_mask]
    OR  AL,DL
    OUT (BX),AL
    RET

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    MOV DL,CL
    SHR DL
    SHR DL
    SHR DL
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [pix_hi],AL
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
    STA [pix_mask],DH
    RET

; --- clsg:  apaga el framebuffer completo (0x0000..0x03FF) -----------------
clsg:
    MOV BL,#0
    MOV BH,#0
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
sm_m_lo:    .space 1
sm_m_hi:    .space 1
sm_carry:   .space 1
sm_cnt:     .space 1

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
