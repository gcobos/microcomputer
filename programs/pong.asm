; ============================================================================
;  pong.asm  -  Pong de dos jugadores (compi)
;
;  Cada jugador maneja una paleta vertical en su lateral con su encoder:
;     encoder DIRECCION (izquierdo, "ADDR") -> paleta izquierda
;     encoder DATOS      (derecho,  "DATA") -> paleta derecha
;
;  Mientras no hay pelota en juego, pulsar el pulsador de tu propio encoder
;  saca una pelotita desde tu paleta hacia el otro lado:
;     - sale a la altura en la que este tu paleta en ese momento (posicion)
;     - sale angulada hacia arriba o hacia abajo segun hacia donde estuvieras
;       girando el encoder justo antes de pulsar (direccion); si la paleta
;       estaba quieta, sale recta.
;  Si el otro jugador no llega con su paleta a tiempo, la pelota sale por su
;  lado y el que saco se apunta un punto.
;
;  Quien gana el punto saca en la ronda siguiente (el pulsador del otro no
;  hace nada mientras tanto) -- salvo al principio de la partida, antes del
;  primer punto, que puede sacar cualquiera de los dos.
;
;  Los marcadores de las esquinas superiores van en la capa de TEXTO
;  (0x0400+), separada del framebuffer grafico (0x0000-0x03FF) donde estan
;  paletas y pelota -- por eso "no interactuan": ni se comprueba colision con
;  ellos ni podrian, son capas distintas que la OLED simplemente superpone.
;
;  Como en programs/cubo.asm, el dibujo usa un "doble buffer" por software:
;  se construye el fotograma en `shadow` (RAM) y solo se copian al
;  framebuffer real los bytes que cambiaron (clr_shadow/blit), para que
;  paletas y pelota se muevan sin parpadeo.
;
;  Sin tecla de salida (los dos pulsadores estan ocupados sacando la
;  pelota) -- para parar, el interruptor SW_MODE del panel (vuelve a EDIT).
;
;  Ensamblar y enviar al slot 2:
;     python3 tools/casm.py programs/pong.asm -o programs/pong.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 2 programs/pong.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 2
    .org 0x0000

; --- geometria ---------------------------------------------------------------
PAD_W        = 2      ; paletas: 2 px de ancho, 14 de alto
PAD_H        = 14
PAD_MAXY     = 50     ; 64 - PAD_H: maxima Y valida de la esquina superior
PAD_L_X      = 4      ; columna de la paleta izquierda (4..5)
PAD_R_X      = 122    ; columna de la paleta derecha (122..123)

BALL_W       = 2      ; pelota: cuadrado de 2x2
BALL_H       = 2
BALL_MAXY    = 62     ; 64 - BALL_H
BALL_SPEED   = 2       ; velocidad horizontal (vx = +-BALL_SPEED)

; umbrales de colision (ver ball_phys): igual que en cubo.asm, "+1"/"-1" para
; convertir un "<=" o ">=" en la comparacion sin signo que entiende la CPU
LEFT_PADDLE_X  = (PAD_L_X+PAD_W)      ; = 6: bola a esta columna o menos -> a
                                       ; la altura de la paleta izquierda
LEFT_WALL_X    = 2                    ; bola a esta columna o menos -> fuera
RIGHT_PADDLE_X = (PAD_R_X-BALL_W)     ; = 120
RIGHT_WALL_X   = 125

LEFT_SERVE_X  = (LEFT_PADDLE_X+1)     ; 7: justo fuera del alcance de rebote
RIGHT_SERVE_X = (RIGHT_PADDLE_X-1)    ; 119

SCORE_L_COL = 1
SCORE_R_COL = 17

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000
P_TEXT    = 0x0400
P_DIR_POS = 0x0600   ; encoder izquierdo: posicion -> paleta izquierda
P_DIR_BTN = 0x0601   ; encoder izquierdo: pulsador -> saque desde la izquierda
P_DAT_POS = 0x0602   ; encoder derecho: posicion -> paleta derecha
P_DAT_BTN = 0x0603   ; encoder derecho: pulsador -> saque desde la derecha
P_T3      = 0x0623   ; ritmo del bucle principal

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    MOV AL,#25
    STA [pad_l_y],AL        ; paletas centradas ((64-14)/2 = 25)
    STA [pad_r_y],AL
    MOV AL,#0
    STA [score_l],AL
    STA [score_r],AL
    STA [ball_active],AL
    STA [serve_turn],AL     ; 0 = puede sacar cualquiera (solo al empezar)

    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL

    CALL clsg
    CALL clst
    CALL draw_scores

main_l:
    CALL update_pad_l
    CALL update_pad_r
    CALL serve_check
    CALL ball_phys

    CALL clr_shadow
    CALL draw_paddles_ball
    CALL blit

    MOV AL,#3               ; ritmo: 3*8 = 24 ms por fotograma
    CALL frame_wait
    JMP main_l

; ============================================================================
;  update_pad_l / update_pad_r:  mueve una paleta segun el delta de su
;  encoder (el paso es el doble del numero de detentes: mas sensible que
;  1 px por detente) y recuerda hacia donde se movio por ultima vez, para
;  el angulo del saque (last_dir_l/last_dir_r).
; ============================================================================
update_pad_l:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_prev]
    SUB AL,BL                ; AL = delta con signo
    LDA CL,[tmp0]
    STA [dir_prev],CL
    CMP AL,#0
    JMPZ upl_done
    STA [tmp1],AL
    AND AL,#0x80
    JMPZ upl_pos
    ; delta negativo: paleta sube (Y menor)
    MOV AL,#0xFF
    STA [last_dir_l],AL
    LDA AL,[tmp1]
    NOT AL
    ADD AL,#1                ; AL = |delta|
    SHL AL                   ; paso = |delta|*2
    STA [tmp1],AL
    LDA AL,[pad_l_y]
    LDA BL,[tmp1]
    CMP AL,BL
    JMPNC upl_subok           ; pad_l_y >= paso -> resta sin problema
    MOV AL,#0
    STA [pad_l_y],AL
    JMP upl_done
upl_subok:
    SUB AL,BL
    STA [pad_l_y],AL
    JMP upl_done
upl_pos:
    MOV AL,#1
    STA [last_dir_l],AL
    LDA AL,[tmp1]
    SHL AL
    STA [tmp1],AL
    LDA AL,[pad_l_y]
    LDA BL,[tmp1]
    ADD AL,BL
    CMP AL,#(PAD_MAXY+1)
    JMPC upl_storeok          ; AL <= PAD_MAXY -> vale tal cual
    MOV AL,#PAD_MAXY
upl_storeok:
    STA [pad_l_y],AL
upl_done:
    RET

update_pad_r:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_prev],CL
    CMP AL,#0
    JMPZ upr_done
    STA [tmp1],AL
    AND AL,#0x80
    JMPZ upr_pos
    MOV AL,#0xFF
    STA [last_dir_r],AL
    LDA AL,[tmp1]
    NOT AL
    ADD AL,#1
    SHL AL
    STA [tmp1],AL
    LDA AL,[pad_r_y]
    LDA BL,[tmp1]
    CMP AL,BL
    JMPNC upr_subok
    MOV AL,#0
    STA [pad_r_y],AL
    JMP upr_done
upr_subok:
    SUB AL,BL
    STA [pad_r_y],AL
    JMP upr_done
upr_pos:
    MOV AL,#1
    STA [last_dir_r],AL
    LDA AL,[tmp1]
    SHL AL
    STA [tmp1],AL
    LDA AL,[pad_r_y]
    LDA BL,[tmp1]
    ADD AL,BL
    CMP AL,#(PAD_MAXY+1)
    JMPC upr_storeok
    MOV AL,#PAD_MAXY
upr_storeok:
    STA [pad_r_y],AL
upr_done:
    RET

; ============================================================================
;  serve_check:  si un pulsador acaba de bajar (flanco), no hay pelota en
;  juego, Y le toca sacar a ese lado (serve_turn), la saca desde su paleta.
; ============================================================================
serve_check:
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ svl_done
    CMP BL,#0
    JMPNZ svl_done             ; ya estaba pulsado -> no es flanco
    LDA AL,[ball_active]
    CMP AL,#0
    JMPNZ svl_done             ; ya hay una pelota en juego
    LDA AL,[serve_turn]
    CMP AL,#2
    JMPZ svl_done              ; le toca sacar a la derecha -- ignora este pulsador
    MOV AL,#LEFT_SERVE_X
    STA [ball_x],AL
    LDA AL,[pad_l_y]
    ADD AL,#6                 ; centra la pelota en la paleta (PAD_H/2 - BALL_H/2)
    STA [ball_y],AL
    MOV AL,#BALL_SPEED
    STA [ball_vx],AL
    LDA AL,[last_dir_l]
    STA [ball_vy],AL
    MOV AL,#1
    STA [ball_active],AL
svl_done:

    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ svr_done
    CMP BL,#0
    JMPNZ svr_done
    LDA AL,[ball_active]
    CMP AL,#0
    JMPNZ svr_done
    LDA AL,[serve_turn]
    CMP AL,#1
    JMPZ svr_done              ; le toca sacar a la izquierda -- ignora este pulsador
    MOV AL,#RIGHT_SERVE_X
    STA [ball_x],AL
    LDA AL,[pad_r_y]
    ADD AL,#6
    STA [ball_y],AL
    MOV AL,#(0-BALL_SPEED)
    STA [ball_vx],AL
    LDA AL,[last_dir_r]
    STA [ball_vy],AL
    MOV AL,#1
    STA [ball_active],AL
svr_done:
    RET

; ============================================================================
;  ball_phys:  mueve la pelota, rebota arriba/abajo y en las paletas, y
;  detecta cuando se sale por un lado (punto para el contrario).
; ============================================================================
ball_phys:
    LDA AL,[ball_active]
    CMP AL,#0
    JMPZ bp_done

    LDA AL,[ball_x]
    LDA BL,[ball_vx]
    ADD AL,BL
    STA [ball_x],AL
    LDA AL,[ball_y]
    LDA BL,[ball_vy]
    ADD AL,BL
    STA [ball_y],AL

    ; --- rebote arriba/abajo ---
    LDA AL,[ball_y]
    AND AL,#0x80
    JMPNZ bp_ywrap             ; el bit de signo puesto = se ha ido negativo (por arriba)
    LDA AL,[ball_y]
    CMP AL,#(BALL_MAXY+1)
    JMPC bp_yok                ; ball_y <= BALL_MAXY -> dentro de rango
    MOV AL,#BALL_MAXY
    STA [ball_y],AL
    LDA AL,[ball_vy]
    NOT AL
    ADD AL,#1
    STA [ball_vy],AL
    JMP bp_yok
bp_ywrap:
    MOV AL,#0
    STA [ball_y],AL
    LDA AL,[ball_vy]
    NOT AL
    ADD AL,#1
    STA [ball_vy],AL
bp_yok:

    ; --- lado segun el signo de vx ---
    LDA AL,[ball_vx]
    AND AL,#0x80
    JMPZ bp_right

    ; --- vx<0: hacia la paleta/pared izquierda ---
    LDA AL,[ball_x]
    CMP AL,#(LEFT_PADDLE_X+1)
    JMPNC bp_done               ; ball_x > LEFT_PADDLE_X -> aun lejos
    LDA AL,[ball_y]
    ADD AL,#(BALL_H-1)
    LDA BL,[pad_l_y]
    CMP AL,BL
    JMPC bp_l_miss              ; ball_y+1 < pad_l_y -> por encima, no solapa
    LDA AL,[pad_l_y]
    ADD AL,#PAD_H
    LDA BL,[ball_y]
    CMP BL,AL
    JMPNC bp_l_miss              ; ball_y >= pad_l_y+PAD_H -> por debajo, no solapa
    ; SOLAPA: rebota
    LDA AL,[ball_vx]
    NOT AL
    ADD AL,#1
    STA [ball_vx],AL
    MOV AL,#LEFT_SERVE_X
    STA [ball_x],AL
    JMP bp_done
bp_l_miss:
    LDA AL,[ball_x]
    CMP AL,#(LEFT_WALL_X+1)
    JMPNC bp_done                ; ball_x > LEFT_WALL_X -> aun no ha llegado del todo
    LDA AL,[score_r]
    ADD AL,#1
    STA [score_r],AL
    MOV AL,#0
    STA [ball_active],AL
    MOV AL,#2
    STA [serve_turn],AL      ; punto de la derecha -> saca la derecha
    CALL draw_scores
    JMP bp_done

bp_right:
    LDA AL,[ball_x]
    CMP AL,#RIGHT_PADDLE_X
    JMPC bp_done                 ; ball_x < RIGHT_PADDLE_X -> aun lejos
    LDA AL,[ball_y]
    ADD AL,#(BALL_H-1)
    LDA BL,[pad_r_y]
    CMP AL,BL
    JMPC bp_r_miss
    LDA AL,[pad_r_y]
    ADD AL,#PAD_H
    LDA BL,[ball_y]
    CMP BL,AL
    JMPNC bp_r_miss
    LDA AL,[ball_vx]
    NOT AL
    ADD AL,#1
    STA [ball_vx],AL
    MOV AL,#RIGHT_SERVE_X
    STA [ball_x],AL
    JMP bp_done
bp_r_miss:
    LDA AL,[ball_x]
    CMP AL,#RIGHT_WALL_X
    JMPC bp_done
    LDA AL,[score_l]
    ADD AL,#1
    STA [score_l],AL
    MOV AL,#0
    STA [ball_active],AL
    MOV AL,#1
    STA [serve_turn],AL      ; punto de la izquierda -> saca la izquierda
    CALL draw_scores
bp_done:
    RET

; ============================================================================
;  draw_paddles_ball:  dibuja (en `shadow`) las dos paletas y, si esta en
;  juego, la pelota.
; ============================================================================
draw_paddles_ball:
    MOV AL,#PAD_L_X
    STA [rect_x],AL
    LDA AL,[pad_l_y]
    STA [rect_y],AL
    MOV AL,#PAD_W
    STA [rect_w],AL
    MOV AL,#PAD_H
    STA [rect_h],AL
    CALL fill_shadow_rect

    MOV AL,#PAD_R_X
    STA [rect_x],AL
    LDA AL,[pad_r_y]
    STA [rect_y],AL
    MOV AL,#PAD_W
    STA [rect_w],AL
    MOV AL,#PAD_H
    STA [rect_h],AL
    CALL fill_shadow_rect

    LDA AL,[ball_active]
    CMP AL,#0
    JMPZ dpb_done
    LDA AL,[ball_x]
    STA [rect_x],AL
    LDA AL,[ball_y]
    STA [rect_y],AL
    MOV AL,#BALL_W
    STA [rect_w],AL
    MOV AL,#BALL_H
    STA [rect_h],AL
    CALL fill_shadow_rect
dpb_done:
    RET

; --- fill_shadow_rect: rellena rect_w x rect_h en `shadow`, esquina arriba
; a la izquierda en (rect_x,rect_y) --------------------------------------
fill_shadow_rect:
    MOV AL,#0
    STA [rect_dy],AL
frr_row:
    MOV AL,#0
    STA [rect_dx],AL
frr_col:
    LDA AL,[rect_x]
    LDA BL,[rect_dx]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[rect_y]
    LDA BL,[rect_dy]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[rect_dx]
    ADD AL,#1
    STA [rect_dx],AL
    LDA BL,[rect_w]
    CMP AL,BL
    JMPNZ frr_col

    LDA AL,[rect_dy]
    ADD AL,#1
    STA [rect_dy],AL
    LDA BL,[rect_h]
    CMP AL,BL
    JMPNZ frr_row
    RET

; ============================================================================
;  draw_scores:  escribe score_l/score_r (0..99) en la fila 0 de la capa de
;  texto -- no toca el framebuffer grafico para nada.
; ============================================================================
draw_scores:
    LDA AL,[score_l]
    MOV CL,#SCORE_L_COL
    MOV CH,#0
    CALL put_num2
    LDA AL,[score_r]
    MOV CL,#SCORE_R_COL
    MOV CH,#0
    CALL put_num2
    RET

; --- put_num2:  AL=valor (0..99), CL=col, CH=fila -- escribe 2 digitos ----
put_num2:
    STA [pn_v],AL
    MOV DL,#0
pn2_t:
    LDA AL,[pn_v]
    CMP AL,#10
    JMPC pn2_td
    SUB AL,#10
    STA [pn_v],AL
    ADD DL,#1
    JMP pn2_t
pn2_td:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    LDA AL,[pn_v]
    ADD AL,#0x30
    CALL putc
    RET

; --- putc:  AL=caracter, CL=col, CH=fila -----------------------------------
putc:
    STA [tmp2],AL
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    LDA AL,[tmp2]
    OUT (DX),AL
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS (calc_pix/shadow_set_px/clr_shadow/blit identicas a
;  las de programs/cubo.asm)
; ============================================================================

; --- shadow_set_px:  enciende el pixel (px_x,px_y) en `shadow` (RAM) ------
; calc_pix ya deja BX apuntando dentro de shadow -- OJO: no volver a cargar
; BL/BH desde pix_lo/pix_hi aqui (eso deshace la suma de la base `shadow` y
; deja BX en una direccion baja, DENTRO DEL PROPIO CODIGO -- paso por esto
; exactamente: cada vez que se dibujaba una paleta corrompia instrucciones).
shadow_set_px:
    CALL calc_pix
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

; --- calc_pix:  de (px_x,px_y) saca BX = shadow+puerto, y pix_mask --------
; (a diferencia de cubo.asm, aqui calc_pix ya deja BX apuntando dentro de
; `shadow` en vez de dejar pix_lo/pix_hi sueltos -- un pixel menos de
; indireccion porque aqui no hace falta separar el calculo del uso)
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
    ; BX = shadow + pix_lo + pix_hi*256
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    ADD BL,CL
    JMPNC cpx_nc
    ADD BH,#1
cpx_nc:
    LDA AL,[pix_hi]
    ADD BH,AL
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
; ojo (ver cubo.asm): no vale contar "4 paginas" mirando BH como en clsg --
; eso solo funciona porque el framebuffer real empieza en un limite de
; pagina; `shadow` no. Contador de 16 bits explicito (CH:CL, de 1024 a 0).
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

; --- blit:  copia `shadow` al framebuffer real, solo lo que haya cambiado -
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

; --- clst:  borra la capa de texto (0x0400..0x04FF) ------------------------
clst:
    MOV BL,#0
    MOV BH,#4
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
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
pad_l_y:      .space 1
pad_r_y:      .space 1
dir_prev:     .space 1
dat_prev:     .space 1
dir_btn_prev: .space 1
dat_btn_prev: .space 1
last_dir_l:   .space 1    ; 0x01/0xFF/0x00: hacia donde se movio por ultimo
last_dir_r:   .space 1    ; la paleta -- se copia tal cual a ball_vy al sacar

ball_x:       .space 1
ball_y:       .space 1
ball_vx:      .space 1
ball_vy:      .space 1
ball_active:  .space 1

score_l:      .space 1
score_r:      .space 1
serve_turn:   .space 1    ; 0=cualquiera (solo al empezar), 1=izquierda, 2=derecha

tmp0:         .space 1
tmp1:         .space 1
tmp2:         .space 1
pn_v:         .space 1

rect_x:       .space 1
rect_y:       .space 1
rect_w:       .space 1
rect_h:       .space 1
rect_dx:      .space 1
rect_dy:      .space 1

px_x:         .space 1
px_y:         .space 1
pix_lo:       .space 1
pix_hi:       .space 1
pix_mask:     .space 1

; shadow: copia del framebuffer en RAM ("doble buffer" software). TIENE que
; ir la ultima de todo el fichero: al ser un .space sin datos reales, casm.py
; no la cuenta al recortar el .bin (ver "Tamano del .bin" en el README).
shadow: .space 1024
