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
;  La partida acaba cuando uno de los dos llega a WIN_SCORE=11 puntos. El
;  record (EEPROM del slot) es el PELOTEO mas largo -- golpes de pala
;  seguidos sin fallar --, que tiene sentido en un juego de dos jugadores:
;  se ve en la pantalla de bienvenida y se graba al acabar la partida si se
;  ha batido.
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

    .name "PONG"

    .category GAME
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
P_SND_NOTE = 0x0632  ; nota MIDI (pitido corto) -- rebote en pala vs. punto
P_SND_DUR  = 0x0633  ; duracion automatica (x10 ms)

WIN_SCORE  = 11      ; la partida acaba al llegar uno de los dos a 11 puntos

; --- record en la EEPROM del slot (iomap.h, 0x0700-0x0801) -----------------
; byte 0 = REC_MAGIC si hay un record grabado (una flash sin estrenar se lee
; 0xFF -> record 0), byte 1 = el record
; (el peloteo mas largo: golpes de pala seguidos sin que nadie falle). Se graba SOLO al batirlo, al llegar
; al GAME OVER, para no gastar la flash en cada partida.
P_EEP_BASE = 0x0700
P_EEP_LOAD = 0x0800
P_EEP_SAVE = 0x0801
REC_MAGIC  = 0xC5

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    CALL title_screen

match_init:
    MOV AL,#0
    STA [rally],AL
    STA [best_rally],AL
    MOV AL,#25
    STA [pad_l_y],AL        ; paletas centradas ((64-14)/2 = 25)
    STA [pad_r_y],AL
    MOV AL,#0
    STA [score_l],AL
    STA [score_r],AL
    STA [ball_active],AL
    STA [serve_turn],AL     ; 0 = puede sacar cualquiera (solo al empezar)

    IN  AL,(P_DIR_POS)          ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    JMPNZ seed_ok
    MOV AL,#0x5D
    STA [seed],AL
seed_ok:

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

    LDA AL,[score_l]        ; fin de partida: el primero a WIN_SCORE
    CMP AL,#WIN_SCORE
    JMPZ match_end
    LDA AL,[score_r]
    CMP AL,#WIN_SCORE
    JMPZ match_end

    CALL clr_shadow
    CALL draw_paddles_ball
    CALL blit

    MOV AL,#3               ; ritmo: 3*8 = 24 ms por fotograma
    CALL frame_wait
    JMP main_l

match_end:
    CALL show_match_over
    JMP start

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
    JMPNZ upl_moved
    MOV AL,#0
    STA [pad_l_spd],AL       ; quieta este fotograma -> velocidad 0 (ver
    JMP upl_done             ; calc_bounce_vy)
upl_moved:
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
    NOT AL
    ADD AL,#1
    STA [pad_l_spd],AL       ; velocidad con signo (negativa = sube)
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
    STA [pad_l_spd],AL       ; velocidad con signo (positiva = baja)
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
    ; la paleta derecha queda mas natural invirtiendo el sentido del encoder
    ; DATOS respecto al de DIRECCION (no es un problema del firmware: los dos
    ; mandos ya son consistentes ahi, es solo como se siente mejor este juego
    ; en concreto con jugadores enfrentados a los lados)
    NOT AL
    ADD AL,#1
    CMP AL,#0
    JMPNZ upr_moved
    MOV AL,#0
    STA [pad_r_spd],AL       ; quieta este fotograma -> velocidad 0
    JMP upr_done
upr_moved:
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
    NOT AL
    ADD AL,#1
    STA [pad_r_spd],AL       ; velocidad con signo (negativa = sube)
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
    STA [pad_r_spd],AL       ; velocidad con signo (positiva = baja)
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
    ; SOLAPA: rebota -- angulo segun donde golpeo en la paleta y hacia donde
    ; se estaba moviendo (calc_bounce_vy), para que no sea siempre el mismo
    ; rebote sosote
    LDA AL,[ball_vx]
    NOT AL
    ADD AL,#1
    STA [ball_vx],AL
    MOV AL,#LEFT_SERVE_X
    STA [ball_x],AL
    LDA AL,[pad_l_y]
    STA [bp_pad_y],AL
    LDA AL,[pad_l_spd]
    STA [bp_pad_spd],AL
    CALL calc_bounce_vy
    STA [ball_vy],AL
    CALL rally_hit
    CALL snd_bounce
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
    MOV AL,#0
    STA [rally],AL          ; punto: se acaba el peloteo
    CALL snd_point
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
    LDA AL,[pad_r_y]
    STA [bp_pad_y],AL
    LDA AL,[pad_r_spd]
    STA [bp_pad_spd],AL
    CALL calc_bounce_vy
    STA [ball_vy],AL
    CALL rally_hit
    CALL snd_bounce
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
    MOV AL,#0
    STA [rally],AL          ; punto: se acaba el peloteo
    CALL snd_point
bp_done:
    RET

; --- snd_bounce/snd_point: pitidos cortos para distinguir un rebote normal
; en una pala (agudo y muy corto) de anotar un punto (mas grave y largo).
; La duracion se escribe SIEMPRE antes que la nota: PORT_SND_DUR es
; "pegajoso" (arma la duracion de la SIGUIENTE nota que suene, no la que
; se acaba de escribir) -- al reves, el primer pitido de la partida sonaria
; sostenido hasta el segundo, sin respetar ninguna duracion. --------------
snd_bounce:
    MOV AL,#3            ; ~30 ms
    OUT (P_SND_DUR),AL
    MOV AL,#76           ; nota alta
    OUT (P_SND_NOTE),AL
    RET
snd_point:
    MOV AL,#18           ; ~180 ms
    OUT (P_SND_DUR),AL
    MOV AL,#50           ; nota mas grave
    OUT (P_SND_NOTE),AL
    RET

; ============================================================================
;  calc_bounce_vy: nuevo angulo de la bola al rebotar en una paleta. Entra
;  con [bp_pad_y] (la Y de esa paleta) y [bp_pad_spd] (su velocidad de ESTE
;  fotograma, con signo -- ver pad_l_spd/pad_r_spd) ya puestos por el
;  llamador; usa tambien [ball_y]. Sale con AL = nuevo ball_vy.
;
;  Combina dos componentes (sin multiplicacion: solo comparaciones de
;  magnitud, como el resto del programa):
;    - offset: donde golpeo la bola respecto al CENTRO de la paleta (arriba
;      del centro = negativo = rebota hacia arriba, abajo = positivo).
;      Recortado a -1..1 (a proposito mas suave que el empuje: un golpe
;      descentrado con la paleta quieta no debe desviar mucho la bola, o
;      el rebote se siente exagerado).
;    - empuje: hacia donde se estaba moviendo la paleta en el momento del
;      golpe (quieta = no empuja). Recortado a -2..2: el jugador puede
;      buscarlo a proposito moviendo la paleta al ritmo de la bola.
;  La suma (-3..3) no hace falta recortarla mas: ya cae dentro de lo que
;  cabe en un byte con signo pequeño.
; ============================================================================
calc_bounce_vy:
    ; offset = ball_y - pad_y - 6 (centro pelota - centro paleta: PAD_H/2 -
    ; BALL_H/2 = 7-1 = 6)
    LDA AL,[ball_y]
    LDA BL,[bp_pad_y]
    SUB AL,BL
    SUB AL,#6
    AND AL,#0x80
    STA [bp_offsign],AL
    LDA AL,[ball_y]
    LDA BL,[bp_pad_y]
    SUB AL,BL
    SUB AL,#6
    STA [bp_tmp],AL
    LDA BL,[bp_offsign]
    CMP BL,#0
    JMPZ cbv_off_abs
    LDA AL,[bp_tmp]
    NOT AL
    ADD AL,#1
    STA [bp_tmp],AL
cbv_off_abs:
    LDA AL,[bp_tmp]           ; |offset|
    CMP AL,#4
    JMPNC cbv_off_1
    MOV AL,#0
    JMP cbv_off_signed
cbv_off_1:
    MOV AL,#1
cbv_off_signed:
    LDA BL,[bp_offsign]
    CMP BL,#0
    JMPZ cbv_off_done
    NOT AL
    ADD AL,#1
cbv_off_done:
    STA [bp_offc],AL

    ; empuje = velocidad de la paleta (misma idea: magnitud -> -2..2 con
    ; el mismo signo que el movimiento)
    LDA AL,[bp_pad_spd]
    AND AL,#0x80
    STA [bp_velsign],AL
    LDA AL,[bp_pad_spd]
    STA [bp_tmp],AL
    LDA BL,[bp_velsign]
    CMP BL,#0
    JMPZ cbv_vel_abs
    LDA AL,[bp_tmp]
    NOT AL
    ADD AL,#1
    STA [bp_tmp],AL
cbv_vel_abs:
    LDA AL,[bp_tmp]           ; |velocidad|
    CMP AL,#8
    JMPNC cbv_vel_2
    CMP AL,#2
    JMPNC cbv_vel_1
    MOV AL,#0
    JMP cbv_vel_signed
cbv_vel_1:
    MOV AL,#1
    JMP cbv_vel_signed
cbv_vel_2:
    MOV AL,#2
cbv_vel_signed:
    LDA BL,[bp_velsign]
    CMP BL,#0
    JMPZ cbv_vel_done
    NOT AL
    ADD AL,#1
cbv_vel_done:
    STA [bp_velc],AL

    ; total = offc (-1..1) + velc (-2..2) + un empujon al azar (-1..1, ver
    ; rnd/rnd_raw): sin esto, la misma pareja offset/velocidad da SIEMPRE el
    ; mismo angulo exacto, y un jugador aprende enseguida a "programar" el
    ; rebote con precision -- demasiado predecible. El azar es pequeño (no
    ; ahoga el control del offset/velocidad, solo evita que sea 100% exacto)
    LDA AL,[bp_offc]
    LDA BL,[bp_velc]
    ADD AL,BL
    STA [bp_tmp],AL

    CALL rnd
    AND AL,#0x03
    CMP AL,#0
    JMPNZ cbv_rnd_1
    MOV AL,#0xFF               ; -1
    JMP cbv_rnd_apply
cbv_rnd_1:
    CMP AL,#3
    JMPNZ cbv_rnd_0
    MOV AL,#1
    JMP cbv_rnd_apply
cbv_rnd_0:
    MOV AL,#0
cbv_rnd_apply:
    LDA BL,[bp_tmp]
    ADD AL,BL

    ; recorte a -3..3 (offc+velc ya cabia ahi; el empujon de +-1 puede sacarlo
    ; a +-4 como mucho, los unicos casos que hace falta mirar)
    CMP AL,#4
    JMPNZ cbv_notmax
    MOV AL,#3
    RET
cbv_notmax:
    CMP AL,#0xFC               ; -4 en complemento a 2
    JMPNZ cbv_ret
    MOV AL,#0xFD               ; -3
cbv_ret:
    RET

; --- rnd/rnd_raw: LFSR de 8 bits (mismo patron que shamus.asm/raycast.asm:
; taps 0xB8, 3 pasos mezclados con XOR) -- solo para el empujon al azar de
; calc_bounce_vy, nada mas en este programa lo necesita ---------------------
rnd:
    CALL rnd_raw
    MOV DL,AL
    CALL rnd_raw
    XOR DL,AL
    CALL rnd_raw
    XOR DL,AL
    MOV AL,DL
    RET
rnd_raw:
    LDA AL,[seed]
    SHR AL
    JMPNC rr_n
    XOR AL,#0xB8
rr_n:
    STA [seed],AL
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
    MOV CX,#SCORE_L_COL
    CALL put_num2
    LDA AL,[score_r]
    MOV CX,#SCORE_R_COL
    CALL put_num2
    RET

; --- put_num2:  AL=valor (0..99), CL=col, CH=fila -- escribe 2 digitos ----
put_num2:
    STA [pn_v],AL
    LDA AL,[pn_v]
    PUSH AH
    MOV AH,#0
    MOV DL,#10
    DIV DL                  ; DL = cociente, resto -> [pn_v]
    STA [pn_v],AH
    MOV DL,AL
    POP AH
pn2_td:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    LDA AL,[pn_v]
    ADD AL,#0x30
    CALL putc
    RET


; ============================================================================
;  RECORD (EEPROM del slot) -- ver P_EEP_* arriba
; ============================================================================
; --- load_record: [record] = el grabado en la flash (0 si no hay ninguno) ---
load_record:
    OUT (P_EEP_LOAD),AL
    IN  AL,(P_EEP_BASE)
    CMP AL,#REC_MAGIC
    MOV AL,#0
    JMPNZ rec_lr_set
    IN  AL,(P_EEP_BASE+1)
rec_lr_set:
    STA [record],AL
    RET

; --- show_record: carga el record y escribe "RECORD nnn" en CH=fila, CL=col --
show_record:
    CALL load_record
    LDA AL,[record]
    MOV AH,#0
    MOV BL,#100
    DIV BL
    ADD AL,#'0'
    STA [rec_d],AL
    MOV AL,AH
    MOV AH,#0
    MOV BL,#10
    DIV BL
    ADD AL,#'0'
    STA [rec_d+1],AL
    MOV AL,AH
    ADD AL,#'0'
    STA [rec_d+2],AL
    MOV BX,#s_record
    CALL puts
    RET

; --- save_record: si [best_rally] supera el record, lo graba en la flash.
; Sale AL = 1 si es record nuevo, 0 si no. ----------------------------------
save_record:
    LDA AL,[best_rally]
    LDA BL,[record]
    CMP BL,AL
    MOV AL,#0
    JMPNC rec_sv_done          ; record >= puntos: nada que grabar
    LDA AL,[best_rally]
    STA [record],AL
    OUT (P_EEP_LOAD),AL     ; parte del contenido real de la EEPROM
    OUT (P_EEP_BASE+1),AL
    MOV AL,#REC_MAGIC
    OUT (P_EEP_BASE),AL
    OUT (P_EEP_SAVE),AL
    MOV AL,#1
rec_sv_done:
    RET

; ============================================================================
;  PANTALLAS DE BIENVENIDA Y FIN DE PARTIDA
; ============================================================================
; --- rally_hit: un golpe de pala mas en el peloteo en curso ---------------
rally_hit:
    LDA AL,[rally]
    CMP AL,#255
    JMPZ rh_done            ; tope de 8 bits
    ADD AL,#1
    STA [rally],AL
    LDA BL,[best_rally]
    CMP BL,AL
    JMPNC rh_done
    STA [best_rally],AL
rh_done:
    RET

; --- title_screen: nombre, regla, record y espera a pulsar ----------------
title_screen:
    CALL clr_shadow
    CALL blit
    CALL clst
    MOV BX,#s_title
    MOV CX,#0x0108
    CALL puts
    MOV BX,#s_rule
    MOV CX,#0x0302
    CALL puts
    MOV CX,#0x0502
    CALL show_record
    MOV BX,#s_start
    MOV CX,#0x0703
    CALL puts
    CALL wait_press_release
    RET

; --- show_match_over: ganador, peloteo mas largo, record -----------------
show_match_over:
    CALL clr_shadow
    CALL blit
    CALL clst
    MOV BX,#s_left_wins
    LDA AL,[score_l]
    CMP AL,#WIN_SCORE
    JMPZ smo_w
    MOV BX,#s_right_wins
smo_w:
    MOV CX,#0x0105
    CALL puts
    MOV BX,#s_rally
    MOV CX,#0x0302
    CALL puts
    LDA AL,[best_rally]
    MOV CX,#0x0310
    CALL put3
    CALL save_record        ; graba el record si se ha batido
    CMP AL,#0
    JMPZ smo_norec
    MOV BX,#s_newrec
    MOV CX,#0x0405
    CALL puts
smo_norec:
    MOV BX,#s_again
    MOV CX,#0x0604
    CALL puts
    CALL wait_press_release
    RET

; --- wait_press_release: espera a que se suelten los dos pulsadores, a que
; se pulse uno y a que se vuelva a soltar (para no sacar sin querer) -------
wait_press_release:
wpr_1:
    CALL any_btn
    CMP AL,#0
    JMPZ wpr_2
    MOV AL,#2
    CALL frame_wait
    JMP wpr_1
wpr_2:
    CALL any_btn
    CMP AL,#0
    JMPNZ wpr_3
    MOV AL,#2
    CALL frame_wait
    JMP wpr_2
wpr_3:
    CALL any_btn
    CMP AL,#0
    JMPZ wpr_d
    MOV AL,#2
    CALL frame_wait
    JMP wpr_3
wpr_d:
    RET

any_btn:
    IN  AL,(P_DIR_BTN)
    MOV BL,AL
    IN  AL,(P_DAT_BTN)
    OR  AL,BL
    RET

; --- put3: AL = valor (0..255), CL = col, CH = fila -- 3 digitos ----------
put3:
    PUSH AH
    MOV AH,#0
    MOV DL,#100
    DIV DL
    STA [pn_v],AH
    POP AH
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    LDA AL,[pn_v]
    CALL put_num2
    RET

; --- puts: BX = cadena asciiz, CL = col, CH = fila ------------------------
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
    INC BX
    INC DX
    JMP ps_l
ps_d:
    RET

; --- putc:  AL=caracter, CL=col, CH=fila -----------------------------------
putc:
    STA [tmp2],AL
    MOV AL,CH
    SHL AL,#5
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
    ; BX = shadow + pix_lo + pix_hi*256
    MOV BX,#shadow
    LDA CL,[pix_lo]
    ADD BX,CL
    LDA AL,[pix_hi]
    ADD BH,AL
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
; ojo (ver cubo.asm): no vale contar "4 paginas" mirando BH como en clsg --
; eso solo funciona porque el framebuffer real empieza en un limite de
; pagina; `shadow` no. Contador de 16 bits explicito (CH:CL, de 1024 a 0).
; clr_shadow: antes un bucle de 1024 pasadas (STA+acarreo+cuenta), ahora
; solo pone a 0 el PRIMER byte y usa MOVB con origen/destino solapados en
; 1 (BX=shadow, DX=shadow+1) para que ese unico 0 se propague en cascada
; a los 1023 bytes restantes -- MOVB copia [BX+i]->[DX+i] con i creciente,
; asi que cada byte lee el que acaba de escribir el paso anterior (ver
; docs/isa.md SS4d: MOVB no es memmove-seguro con origen<destino
; solapados, y aqui es EXACTAMENTE eso lo que se aprovecha a proposito).
clr_shadow:
    MOV AL,#0
    STA [shadow],AL
    MOV BX,#shadow
    MOV DX,#shadow+1
    MOV CX,#0x03FF ; CX = 1023 (el resto del buffer de 1024)
    MOVB
    RET

; --- blit:  copia `shadow` al framebuffer real, solo lo que haya cambiado -
blit:
    MOV BX,#0x0000
    MOV DX,#shadow
bl_l:
    IN  AL,(BX)
    LDA CL,[DX]
    CMP AL,CL
    JMPZ bl_same
    MOV AL,CL
    OUT (BX),AL
bl_same:
    INC DX
    ADD BL,#1
    JMPNC bl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ bl_l
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

; --- clst:  borra la capa de texto (0x0400..0x04FF) ------------------------
clst:
    MOV BX,#0x0400
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

s_title:      .asciiz "PONG"
s_rule:       .asciiz "FIRST TO 11 WINS"
s_start:      .asciiz "PRESS TO START"
s_left_wins:  .asciiz "LEFT WINS!"
s_right_wins: .asciiz "RIGHT WINS!"
s_rally:      .asciiz "LONGEST RALLY"
s_again:      .asciiz "PRESS TO PLAY"
s_record:     .ascii "RALLY RECORD "
rec_d:        .asciiz "000"
s_newrec:     .asciiz "NEW RECORD!"

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
pad_l_spd:    .space 1    ; delta con signo de ESTE fotograma (0 si no se
pad_r_spd:    .space 1    ; movio) -- ver calc_bounce_vy, el "empuje" del rebote

; --- calc_bounce_vy: escalares de trabajo (ver el comentario de la rutina) --
bp_pad_y:     .space 1
bp_pad_spd:   .space 1
bp_off:       .space 1
bp_offsign:   .space 1
bp_offc:      .space 1
bp_velsign:   .space 1
bp_velc:      .space 1
bp_tmp:       .space 1
seed:         .space 1    ; semilla del LFSR (ver rnd/rnd_raw), nunca 0

ball_x:       .space 1
ball_y:       .space 1
ball_vx:      .space 1
ball_vy:      .space 1
ball_active:  .space 1

score_l:      .space 1
score_r:      .space 1
serve_turn:   .space 1    ; 0=cualquiera (solo al empezar), 1=izquierda, 2=derecha
rally:        .space 1    ; golpes de pala seguidos en el punto en curso
best_rally:   .space 1    ; el peloteo mas largo de esta partida
record:       .space 1    ; record (peloteo mas largo) cargado de la EEPROM

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

