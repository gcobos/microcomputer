; ============================================================================
;  roto_debug.asm  -  depuracion visual de los dos rotoencoders (compi)
;
;  Un circulo sin rellenar por encoder (izquierda = DIRECCION, derecha =
;  DATOS), con una aguja que apunta a una de 20 posiciones alrededor del
;  circulo (el encoder tiene 20 detentes por vuelta: posicion_cruda mod 20).
;  El circulo se rellena mientras el pulsador de ese encoder este pulsado.
;  Debajo de cada circulo, la posicion cruda (0..255) en decimal, para
;  depurar sentido de giro/inversion sin ambiguedad.
;
;  No hay salida por boton (los dos pulsadores son justo lo que se esta
;  depurando): se sale cambiando el interruptor SW_MODE a EDIT, como
;  cualquier programa en ExecCont.
;
;  Ensamblar y enviar al slot 0:
;     python3 tools/casm.py programs/roto_debug.asm -o programs/roto_debug.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 0 programs/roto_debug.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 0
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_TEXT    = 0x0400
P_DIR_POS = 0x0600
P_DIR_BTN = 0x0601
P_DAT_POS = 0x0602
P_DAT_BTN = 0x0603
P_T3      = 0x0623      ; temporizador 3 (8 ms/paso)

; --- geometria ---------------------------------------------------------------
DIR_CX    = 32           ; centro del circulo izquierdo (DIRECCION)
DAT_CX    = 96           ; centro del circulo derecho (DATOS)
CIRC_CY   = 36           ; misma fila para los dos
CIRC_R    = 17           ; radio
NEEDLE_TBL_STEP = 2       ; 2 bytes por entrada (dx,dy) en needle_off

; ============================================================================
;  ARRANQUE: rotulos fijos (no se vuelven a tocar en el bucle)
; ============================================================================
start:
    CALL clst
    MOV BL,#lo(h_dir)
    MOV BH,#hi(h_dir)
    MOV CL,#1
    MOV CH,#0
    CALL puts
    MOV BL,#lo(h_dat)
    MOV BH,#hi(h_dat)
    MOV CL,#15
    MOV CH,#0
    CALL puts

; ============================================================================
;  BUCLE PRINCIPAL: lee los dos encoders, redibuja los dos circulos+aguja,
;  actualiza las dos cifras -- sin condicion de salida (ver cabecera).
; ============================================================================
main_l:
    IN  AL,(P_DIR_POS)
    STA [dir_pos],AL
    CALL mod20
    STA [dir_slot],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn],AL

    IN  AL,(P_DAT_POS)
    STA [dat_pos],AL
    CALL mod20
    STA [dat_slot],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn],AL

    CALL clr_shadow

    ; --- circulo + aguja: DIRECCION (izquierda) -----------------------------
    MOV AL,#DIR_CX
    STA [circ_cx],AL
    MOV AL,#CIRC_CY
    STA [circ_cy],AL
    MOV AL,#CIRC_R
    STA [circ_r],AL
    LDA AL,[dir_btn]
    STA [circ_fill],AL
    CALL circle

    MOV AL,#DIR_CX
    STA [ln_x0],AL
    MOV AL,#CIRC_CY
    STA [ln_y0],AL
    LDA AL,[dir_slot]
    STA [nd_slot],AL
    CALL needle_lookup
    MOV AL,#DIR_CX
    LDA BL,[nd_dx]
    ADD AL,BL
    STA [ln_x1],AL
    MOV AL,#CIRC_CY
    LDA BL,[nd_dy]
    ADD AL,BL
    STA [ln_y1],AL
    CALL line_draw

    ; --- circulo + aguja: DATOS (derecha) -----------------------------------
    MOV AL,#DAT_CX
    STA [circ_cx],AL
    MOV AL,#CIRC_CY
    STA [circ_cy],AL
    MOV AL,#CIRC_R
    STA [circ_r],AL
    LDA AL,[dat_btn]
    STA [circ_fill],AL
    CALL circle

    MOV AL,#DAT_CX
    STA [ln_x0],AL
    MOV AL,#CIRC_CY
    STA [ln_y0],AL
    LDA AL,[dat_slot]
    STA [nd_slot],AL
    CALL needle_lookup
    MOV AL,#DAT_CX
    LDA BL,[nd_dx]
    ADD AL,BL
    STA [ln_x1],AL
    MOV AL,#CIRC_CY
    LDA BL,[nd_dy]
    ADD AL,BL
    STA [ln_y1],AL
    CALL line_draw

    CALL blit

    ; --- cifras de posicion cruda (0..255), fila 7 --------------------------
    LDA AL,[dir_pos]
    MOV CL,#3
    MOV CH,#7
    CALL put_dec3
    LDA AL,[dat_pos]
    MOV CL,#14
    MOV CH,#7
    CALL put_dec3

    MOV AL,#2
    CALL frame_wait
    JMP main_l

; ============================================================================
;  mod20:  AL = AL mod 20 (resta repetida; AL entra 0..255, max 12 vueltas)
; ============================================================================
mod20:
m20_l:
    CMP AL,#20
    JMPC m20_d
    SUB AL,#20
    JMP m20_l
m20_d:
    RET

; ============================================================================
;  needle_lookup:  [nd_slot] (0..19) -> [nd_dx],[nd_dy] desde needle_off
; ============================================================================
needle_lookup:
    LDA CL,[nd_slot]
    SHL CL                     ; offset en bytes = slot*2
    MOV BL,#lo(needle_off)
    MOV BH,#hi(needle_off)
    CALL idx_ptr                ; BX = needle_off + slot*2 (con acarreo)
    LDA AL,[BX]
    STA [nd_dx],AL
    ADD BL,#1
    JMPNC ndl_ok
    ADD BH,#1
ndl_ok:
    LDA AL,[BX]
    STA [nd_dy],AL
    RET

; ============================================================================
;  CIRCULO: algoritmo del punto medio, sin multiplicacion (solo suma/resta/
;  desplazamiento). Dibuja en `shadow`, nunca en el framebuffer real
;  directamente -- ver el aviso de doble buffer mas abajo.
;
;  Con [circ_fill]=0 solo el contorno (8 puntos simetricos por paso).
;  Con [circ_fill]!=0, ademas 4 franjas horizontales por paso (mismas
;  coordenadas simetricas, pero de extremo a extremo): es la forma barata de
;  rellenar sin comprobar "dentro del circulo" pixel a pixel, que aqui
;  costaria una multiplicacion (x*x+y*y) que esta CPU no tiene.
;  Verificado en Python antes de escribirlo (ver el historial de esta sesion).
; ============================================================================
circle:
    LDA AL,[circ_r]
    STA [cir_x],AL
    MOV AL,#0
    STA [cir_y],AL
    STA [cir_err],AL
circ_loop:
    LDA AL,[cir_x]
    LDA BL,[cir_y]
    CMP AL,BL
    JMPC circ_done              ; x < y (acarreo/prestamo) -> fin

    CALL circ_plot8

    LDA AL,[circ_fill]
    CMP AL,#0
    JMPZ circ_nofill
    CALL circ_fillspans
circ_nofill:

    LDA AL,[cir_y]
    ADD AL,#1
    STA [cir_y],AL

    LDA AL,[cir_err]
    CMP AL,#0
    JMPZ circ_le0
    JMPN circ_le0
    JMP circ_gt0
circ_le0:
    LDA AL,[cir_y]
    SHL AL
    ADD AL,#1
    LDA BL,[cir_err]
    ADD BL,AL
    STA [cir_err],BL
    JMP circ_loop
circ_gt0:
    LDA AL,[cir_x]
    SUB AL,#1
    STA [cir_x],AL
    LDA AL,[cir_y]
    LDA BL,[cir_x]
    SUB AL,BL
    SHL AL
    ADD AL,#1
    LDA BL,[cir_err]
    ADD BL,AL
    STA [cir_err],BL
    JMP circ_loop
circ_done:
    RET

; --- circ_plot8: los 8 puntos simetricos de (cir_x,cir_y) alrededor de
; (circ_cx,circ_cy). Recarga circ_cx/circ_cy/cir_x/cir_y de memoria en CADA
; combinacion (nunca deja el resultado de una suma anterior en un registro
; para la siguiente): shadow_set_px llama a calc_pix, que destruye CL/CH/
; DL/DH -- el mismo tipo de fallo que ya se dio varias veces esta sesion en
; fzero.asm.
circ_plot8:
    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[circ_cy]
    LDA BL,[cir_y]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    SUB AL,BL
    STA [px_x],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[circ_cy]
    LDA BL,[cir_y]
    SUB AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    SUB AL,BL
    STA [px_x],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[circ_cy]
    LDA BL,[cir_x]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    SUB AL,BL
    STA [px_x],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[circ_cy]
    LDA BL,[cir_x]
    SUB AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    SUB AL,BL
    STA [px_x],AL
    CALL shadow_set_px
    RET

; --- circ_fillspans: 4 franjas horizontales del paso actual (cir_x,cir_y) --
circ_fillspans:
    LDA AL,[circ_cy]
    LDA BL,[cir_y]
    ADD AL,BL
    STA [hl_y],AL
    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    SUB AL,BL
    STA [hl_x1],AL
    LDA AL,[circ_cx]
    LDA BL,[cir_x]
    ADD AL,BL
    STA [hl_x2],AL
    CALL hline_shadow

    LDA AL,[circ_cy]
    LDA BL,[cir_y]
    SUB AL,BL
    STA [hl_y],AL
    CALL hline_shadow

    LDA AL,[circ_cy]
    LDA BL,[cir_x]
    ADD AL,BL
    STA [hl_y],AL
    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    SUB AL,BL
    STA [hl_x1],AL
    LDA AL,[circ_cx]
    LDA BL,[cir_y]
    ADD AL,BL
    STA [hl_x2],AL
    CALL hline_shadow

    LDA AL,[circ_cy]
    LDA BL,[cir_x]
    SUB AL,BL
    STA [hl_y],AL
    CALL hline_shadow
    RET

; --- hline_shadow: rellena en `shadow` la fila [hl_y] desde [hl_x1] hasta
; [hl_x2] (pixel a pixel; [hl_x1] <= [hl_x2] siempre, por construccion) -----
hline_shadow:
    LDA AL,[hl_y]
    STA [px_y],AL
    LDA AL,[hl_x1]
    STA [hl_cur],AL
hls_l:
    LDA AL,[hl_cur]
    STA [px_x],AL
    CALL shadow_set_px
    LDA AL,[hl_cur]
    LDA BL,[hl_x2]
    CMP AL,BL
    JMPZ hls_d
    LDA AL,[hl_cur]
    ADD AL,#1
    STA [hl_cur],AL
    JMP hls_l
hls_d:
    RET

; ============================================================================
;  LINEA (Bresenham general, igual algoritmo que cubo.asm/reloj.asm) --------
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
    CALL shadow_set_px

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
;  DOBLE BUFFER (igual patron que cubo.asm/pong.asm/fzero.asm): se dibuja
;  entero en `shadow` (RAM) cada vuelta y se compara contra el framebuffer
;  real byte a byte (`blit`), para no dejar ver un fotograma a medias si el
;  volcado a la OLED cae a mitad del redibujado.
; ============================================================================

; --- idx_ptr:  BX = (BX inicial) + CL, propagando el acarreo a mano --------
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4
    MOV DL,CL
    SHR DL,#3
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL,#4
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

; --- shadow_set_px:  enciende el pixel (px_x,px_y) en `shadow` -------------
shadow_set_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` (contador de 16 bits
; explicito: `shadow` no cae en un limite de pagina, ver cubo.asm) ---------
clr_shadow:
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    MOV AL,#0
    MOV CL,#0
    MOV CH,#4
csh_l:
    STA [BX],AL
    ADD BL,#1
    JMPNC csh_addr_ok
    ADD BH,#1
csh_addr_ok:
    SUB CL,#1
    JMPNC csh_cnt_ok
    SUB CH,#1
csh_cnt_ok:
    MOV DL,CH
    OR  DL,CL
    JMPNZ csh_l
    RET

; --- blit:  copia `shadow` al framebuffer real, solo lo que cambie --------
blit:
    MOV BL,#0
    MOV BH,#0
    MOV DL,#lo(shadow)
    MOV DH,#hi(shadow)
bl_l:
    IN  AL,(BX)
    LDA CL,[DX]
    CMP AL,CL
    JMPZ bl_same
    MOV AL,CL
    OUT (BX),AL
bl_same:
    ADD DL,#1
    JMPNC bl_dnc
    ADD DH,#1
bl_dnc:
    ADD BL,#1
    JMPNC bl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ bl_l
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
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

; --- put_dec3:  AL = valor (0..255), CL = col, CH = fila -> 3 digitos ------
put_dec3:
    STA [pd_v],AL
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04

    MOV AL,#0
pd3_h:
    LDA BL,[pd_v]
    CMP BL,#100
    JMPC pd3_hd
    SUB BL,#100
    STA [pd_v],BL
    ADD AL,#1
    JMP pd3_h
pd3_hd:
    ADD AL,#0x30
    OUT (DX),AL
    ADD DL,#1
    JMPNC pd3_t1
    ADD DH,#1
pd3_t1:
    MOV AL,#0
pd3_t:
    LDA BL,[pd_v]
    CMP BL,#10
    JMPC pd3_td
    SUB BL,#10
    STA [pd_v],BL
    ADD AL,#1
    JMP pd3_t
pd3_td:
    ADD AL,#0x30
    OUT (DX),AL
    ADD DL,#1
    JMPNC pd3_u1
    ADD DH,#1
pd3_u1:
    LDA AL,[pd_v]
    ADD AL,#0x30
    OUT (DX),AL
    RET

; --- clst:  borra la capa de texto (0x0400..0x04FF) -------------------------
clst:
    MOV BL,#0
    MOV BH,#4
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
    RET

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) -----------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; ============================================================================
;  DATOS  (justo despues del codigo -- ver programs/README.md)
; ============================================================================
dir_pos:    .space 1
dir_slot:   .space 1
dir_btn:    .space 1
dat_pos:    .space 1
dat_slot:   .space 1
dat_btn:    .space 1

circ_cx:    .space 1
circ_cy:    .space 1
circ_r:     .space 1
circ_fill:  .space 1
cir_x:      .space 1
cir_y:      .space 1
cir_err:    .space 1

hl_y:       .space 1
hl_x1:      .space 1
hl_x2:      .space 1
hl_cur:     .space 1

nd_slot:    .space 1
nd_dx:      .space 1
nd_dy:      .space 1

px_x:       .space 1
px_y:       .space 1
pix_lo:     .space 1
pix_hi:     .space 1
pix_mask:   .space 1

ln_x0:      .space 1
ln_y0:      .space 1
ln_x1:      .space 1
ln_y1:      .space 1
ln_dx:      .space 1
ln_dy:      .space 1
ln_sx:      .space 1
ln_sy:      .space 1
ln_n:       .space 1
ln_err:     .space 1
ln_xmaj:    .space 1

pd_v:       .space 1

h_dir:      .asciiz "DIRECCION"
h_dat:      .asciiz "DATOS"

; --- needle_off: 20 pares (dx,dy), uno por detente (18 grados cada uno),
; con longitud de aguja 14 px. La posicion 0 apunta "arriba" (12 en punto) y
; gira en el sentido de las agujas del reloj segun aumenta el detente (igual
; convencion que el resto del panel: ver src/panel.cpp). Calculado una vez
; con Python (seno/coseno), no en tiempo de ejecucion -- esta CPU no tiene
; multiplicacion ni son/cos, y 20 valores fijos salen mas baratos que
; cualquier cuenta en marcha.
needle_off:
    .db 0,   242   ; slot  0 (  0 grados)
    .db 4,   243   ; slot  1 ( 18 grados)
    .db 8,   245   ; slot  2 ( 36 grados)
    .db 11,  248   ; slot  3 ( 54 grados)
    .db 13,  252   ; slot  4 ( 72 grados)
    .db 14,  0     ; slot  5 ( 90 grados)
    .db 13,  4     ; slot  6 (108 grados)
    .db 11,  8     ; slot  7 (126 grados)
    .db 8,   11    ; slot  8 (144 grados)
    .db 4,   13    ; slot  9 (162 grados)
    .db 0,   14    ; slot 10 (180 grados)
    .db 252, 13    ; slot 11 (198 grados)
    .db 248, 11    ; slot 12 (216 grados)
    .db 245, 8     ; slot 13 (234 grados)
    .db 243, 4     ; slot 14 (252 grados)
    .db 242, 0     ; slot 15 (270 grados)
    .db 243, 252   ; slot 16 (288 grados)
    .db 245, 248   ; slot 17 (306 grados)
    .db 248, 245   ; slot 18 (324 grados)
    .db 252, 243   ; slot 19 (342 grados)

    .org 0xF400
shadow:     .space 1024
