; ============================================================================
;  esquiva.asm  -  DODGE: esquiva los bloques que caen (compi)
;
;  Extraido del antiguo demo.asm (ahi era la opcion "6 JUEGO") como programa
;  independiente. Una plataforma horizontal se mueve con CUALQUIERA de los
;  dos encoders (girar el otro con la misma mano que ya esta sobre el
;  mando de salida, sin tener que soltarlo, o alternar entre los dos) para
;  esquivar los bloques que caen desde arriba; cada uno esquivado suma un
;  punto y hace que el resto caiga un poco mas rapido (hasta un tope).
;  Tocar uno acaba la partida -- pulsar DATOS o girar cualquiera de los dos
;  empieza otra en el acto; pulsar DIRECCION sale al sistema (carga el
;  slot 0). Al arrancar, una pantalla de bienvenida muestra el record
;  (EEPROM del slot); al acabar una partida que lo supera, se graba.
;
;  Controles:
;     encoder DATOS o DIRECCION gira -> mueve la plataforma: cada detente
;                                 la desplaza 4 px (con x1 esquivar a
;                                 tiempo exigia girarlo muchisimo). Se
;                                 queda quieta al llegar a un borde de la
;                                 pantalla (no reaparece por el contrario).
;                                 Los dos encoders mueven la MISMA
;                                 plataforma (no hay dos jugadores): sus
;                                 giros se aplican por separado, uno tras
;                                 otro, cada fotograma (ver apply_move).
;     encoder DIRECCION pulsa -> vuelve al sistema (slot 0)
;
;  Ensamblar y enviar al slot 4:
;     python3 tools/casm.py programs/esquiva.asm -o programs/esquiva.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 4 programs/esquiva.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 4

    .name "DODGE"

    .category GAME
    .org 0x0000

; --- variables (RAM alta, lejos del codigo) ----------------------------------
seed      = 0xFE00      ; semilla del LFSR (nunca 0)
g_exit    = 0xFE04      ; 1 = DIRECCION pulsado -> salir del todo
tmp0      = 0xFE05
fwn_n     = 0xFE0F      ; contador de frame_wait_n
hd_n      = 0xFE10      ; contador de hold
gb_x      = 0xFE12      ; caja: x (multiplo de 8)
gb_y      = 0xFE13      ; caja: y
gb_wb     = 0xFE18      ; caja: ancho en bytes
gb_ht     = 0xFE19      ; caja: alto en filas
fs_h      = 0xFE1A      ; shadow_fillbox: filas que quedan
fs_row    = 0xFE1B      ; shadow_fillbox: fila actual
gpx       = 0xFE29      ; x del jugador (pixel)
dir_prev  = 0xFE35      ; posicion del encoder DIRECCION en el frame anterior
am_cur    = 0xFE36      ; apply_move: valor crudo leido este frame
g_score   = 0xFE2A      ; puntos
g_over    = 0xFE2B      ; 1 = fin de partida
g_speed   = 0xFE2C      ; velocidad de caida
ob_i      = 0xFE2D      ; offset del obstaculo en curso (0/2/4)
ob_newy   = 0xFE2E
go_i      = 0xFE2F      ; game_over: contador de destellos
pn_v      = 0xFE30      ; put_num: valor en curso
sf_val    = 0xFE31      ; shadow_fill: byte de relleno
sfb_off   = 0xFE32      ; shadow_fillbox: offset dentro de la pagina
sfb_pag   = 0xFE33      ; shadow_fillbox: pagina (0..3)
gp_prev   = 0xFE34      ; posicion del encoder DATOS en el frame anterior
record    = 0xFE37      ; record cargado de la EEPROM (ver load_record)

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000      ; framebuffer
P_TEXT    = 0x0400      ; rejilla de texto
P_DIR_POS = 0x0600      ; encoder DIRECCION: posicion
P_DAT_POS = 0x0602      ; encoder DATOS: posicion
P_DIR_BTN = 0x0601      ; encoder DIRECCION: pulsado
P_LED     = 0x0610
P_T3      = 0x0623      ; temporizador 3 (8 ms/paso)
P_SND_N   = 0x0632      ; nota MIDI
P_SND_D   = 0x0633      ; duracion automatica (x10 ms)
P_PROG_LOAD = 0x0640     ; cargar slot (OUT nº de slot): salto a otro programa
P_DAT_BTN = 0x0603      ; encoder DATOS: pulsado

; --- record en la EEPROM del slot (iomap.h, 0x0700-0x0801) -----------------
; byte 0 = REC_MAGIC si hay un record grabado (una flash sin estrenar se lee
; 0xFF -> record 0), byte 1 = el record. Se graba SOLO al batirlo, al llegar
; al GAME OVER, para no gastar la flash en cada partida.
P_EEP_BASE = 0x0700
P_EEP_LOAD = 0x0800
P_EEP_SAVE = 0x0801
REC_MAGIC  = 0xC5

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    IN  AL,(P_DAT_POS)
    MOV [gp_prev],AL
    IN  AL,(P_DIR_POS)
    MOV [dir_prev],AL
    MOV AL,#56                 ; plataforma centrada al empezar
    MOV [gpx],AL
    IN  AL,(P_DAT_POS)         ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    MOV [seed],AL
    CMP AL,#0
    JMPNZ title
    MOV AL,#0x5D
    MOV [seed],AL

; ============================================================================
;  PANTALLA DE BIENVENIDA: nombre, record y "PRESS DATA TO START". Pulsar
;  DATOS empieza; pulsar DIRECCION vuelve al sistema, como en la partida.
; ============================================================================
title:
    MOV AL,#0
    CALL shadow_fill
    CALL shadow_blit
    CALL clst
    MOV BX,#str_title
    MOV CX,#0x0208
    CALL puts
    MOV CX,#0x0405
    CALL show_record
    MOV BX,#str_start
    MOV CX,#0x0601
    CALL puts
tl_l:
    CALL poll_exit
    MOV AL,[g_exit]
    CMP AL,#0
    JMPNZ game_ret
    IN  AL,(P_DAT_BTN)
    CMP AL,#0
    JMPNZ tl_rel
    MOV AL,#2
    CALL frame_wait
    JMP tl_l
tl_rel:                       ; espera a que se suelte DATOS antes de jugar
    IN  AL,(P_DAT_BTN)
    CMP AL,#0
    JMPZ tl_go
    MOV AL,#2
    CALL frame_wait
    JMP tl_rel
tl_go:
    IN  AL,(P_DAT_POS)         ; que el giro de la espera no mueva la plataforma
    MOV [gp_prev],AL
    IN  AL,(P_DIR_POS)
    MOV [dir_prev],AL

; ============================================================================
;  UNA PARTIDA
; ============================================================================
game_rs:
    MOV AL,#0
    MOV [g_over],AL
    MOV [g_score],AL
    MOV AL,#0
    CALL shadow_fill
    CALL shadow_blit
    CALL clst
    MOV AL,#1
    MOV [g_speed],AL
    MOV AL,#40            ; obstaculo 0: x, y
    MOV [0xF300],AL
    MOV AL,#3
    MOV [0xF301],AL
    MOV AL,#72            ; obstaculo 1
    MOV [0xF302],AL
    MOV AL,#20
    MOV [0xF303],AL
    MOV AL,#104           ; obstaculo 2
    MOV [0xF304],AL
    MOV AL,#40
    MOV [0xF305],AL
game_l:
    CALL poll_exit
    MOV AL,[g_exit]
    CMP AL,#0
    JMPNZ game_ret
    ; jugador = posicion acumulada: cada frame se suma el giro de CADA
    ; encoder (DATOS y DIRECCION, por separado, uno tras otro) desde el
    ; frame anterior x4 (ver el aviso de arriba sobre la velocidad), con
    ; TOPE en 0 y 112 -- al llegar a un borde se queda ahi en vez de
    ; reaparecer por el lado contrario. Misma cuenta para los dos
    ; encoders, ver apply_move.
    IN  AL,(P_DAT_POS)
    MOV DX,#gp_prev
    CALL apply_move
    IN  AL,(P_DIR_POS)
    MOV DX,#dir_prev
    CALL apply_move

    MOV AL,[g_score]         ; sube la velocidad con los puntos
    CMP AL,#20
    JMPC g_s1
    MOV AL,#3
    MOV [g_speed],AL
    JMP g_obs
g_s1:
    MOV AL,[g_score]
    CMP AL,#8
    JMPC g_s0
    MOV AL,#2
    MOV [g_speed],AL
    JMP g_obs
g_s0:
    MOV AL,#1
    MOV [g_speed],AL
g_obs:
    MOV AL,#0
    MOV [ob_i],AL
    CALL obstacle
    MOV AL,[g_over]
    CMP AL,#0
    JMPNZ g_go
    MOV AL,#2
    MOV [ob_i],AL
    CALL obstacle
    MOV AL,[g_over]
    CMP AL,#0
    JMPNZ g_go
    MOV AL,#4
    MOV [ob_i],AL
    CALL obstacle
    MOV AL,[g_over]
    CMP AL,#0
    JMPNZ g_go
    CALL game_draw
    MOV AL,#3
    CALL frame_wait
    JMP game_l
g_go:
    CALL game_over
    MOV AL,[g_exit]
    CMP AL,#0
    JMPNZ game_ret
    JMP game_rs              ; otra pulsacion/giro tras GAME OVER: otra partida
game_ret:
    CALL wait_dir_release
    MOV AL,#0
    OUT (P_PROG_LOAD),AL       ; vuelve al sistema (sisop, slot 0)
    HALT                       ; solo si el slot 0 estuviera vacio (la carga no hace nada)

; ============================================================================
;  LOGICA DEL JUEGO
; ============================================================================

; un obstaculo:  [ob_i] = 0 | 2 | 4  (offset x,y en la pagina 0xF300)
obstacle:
    MOV AL,[ob_i]
    MOV [ob_rx+1],AL
    MOV [ob_wx+1],AL
    ADD AL,#1
    MOV [ob_ry+1],AL
    MOV [ob_wy+1],AL
    MOV [ob_wy2+1],AL
ob_ry:
    MOV AL,[0xF301]         ; y actual
    MOV BL,[g_speed]
    ADD AL,BL
    MOV [ob_newy],AL
    CMP AL,#59
    JMPC ob_store           ; sigue cayendo
    ; ha llegado abajo: ¿colision con el jugador?
ob_rx:
    MOV DL,[0xF300]         ; x del obstaculo
    MOV AL,DL
    ADD AL,#8
    MOV BL,[gpx]
    SUB AL,BL               ; AL = obs_x + 8 - jugador_x
    CMP AL,#25
    JMPNC ob_recy           ; > 24  -> no toca
    CMP AL,#1
    JMPC ob_recy            ; == 0  -> no toca
    MOV AL,#1               ; 1..24 -> IMPACTO
    MOV [g_over],AL
    RET
ob_recy:
    CALL rnd
    AND AL,#0x78            ; nueva x (multiplo de 8, 0..120)
ob_wx:
    MOV [0xF300],AL
    MOV AL,#0
ob_wy2:
    MOV [0xF301],AL         ; y = 0 (arriba otra vez)
    MOV AL,[g_score]
    ADD AL,#1
    MOV [g_score],AL
    MOV AL,#1
    OUT (P_SND_D),AL
    MOV AL,#88
    OUT (P_SND_N),AL        ; blip de punto
    RET
ob_store:
    MOV AL,[ob_newy]
ob_wy:
    MOV [0xF301],AL
    RET

game_draw:
    MOV AL,#0
    CALL shadow_fill
    MOV AL,[gpx]            ; jugador (alineado a byte)
    SHR AL,#3
    SHL AL,#3
    MOV [gb_x],AL
    MOV AL,#58
    MOV [gb_y],AL
    MOV AL,#2
    MOV [gb_wb],AL
    MOV AL,#5
    MOV [gb_ht],AL
    CALL shadow_fillbox
    MOV AL,#0
    MOV [ob_i],AL
    CALL draw_ob
    MOV AL,#2
    MOV [ob_i],AL
    CALL draw_ob
    MOV AL,#4
    MOV [ob_i],AL
    CALL draw_ob
    CALL shadow_blit
    CALL clst
    MOV BX,#h_game
    MOV CX,#0x0000
    CALL puts
    MOV AL,[g_score]
    MOV CX,#0x000C
    CALL put_num
    RET

draw_ob:
    MOV AL,[ob_i]
    MOV [dob_rx+1],AL
    ADD AL,#1
    MOV [dob_ry+1],AL
dob_rx:
    MOV AL,[0xF300]
    SHR AL,#3
    SHL AL,#3
    MOV [gb_x],AL
dob_ry:
    MOV AL,[0xF301]
    CMP AL,#59
    JMPC dob_yok
    MOV AL,#58
dob_yok:
    MOV [gb_y],AL
    MOV AL,#1
    MOV [gb_wb],AL
    MOV AL,#4
    MOV [gb_ht],AL
    CALL shadow_fillbox
    RET

game_over:
    MOV AL,#0
    MOV [go_i],AL
go_l:
    MOV AL,#0xFF
    CALL shadow_fill
    CALL shadow_blit
    MOV AL,#1
    OUT (P_LED),AL
    MOV AL,[go_i]           ; tono descendente 64, 60, 56...
    MOV BL,AL
    SHL BL,#2
    MOV AL,#64
    SUB AL,BL
    MOV [tmp0],AL
    MOV AL,#3
    OUT (P_SND_D),AL
    MOV AL,[tmp0]
    OUT (P_SND_N),AL
    MOV AL,#4
    CALL frame_wait
    MOV AL,#0
    CALL shadow_fill
    CALL shadow_blit
    MOV AL,#0
    OUT (P_LED),AL
    MOV AL,#3
    CALL frame_wait
    MOV AL,[go_i]
    ADD AL,#1
    MOV [go_i],AL
    CMP AL,#10
    JMPNZ go_l
    MOV AL,#0
    OUT (P_SND_N),AL
    MOV AL,#0
    CALL shadow_fill
    CALL shadow_blit
    CALL clst
    MOV BX,#str_over
    MOV CX,#0x0306
    CALL puts
    MOV BX,#str_score
    MOV CX,#0x0505
    CALL puts
    MOV AL,[g_score]
    MOV CX,#0x050D
    CALL put_num
    CALL save_record        ; graba el record si se ha batido
    CMP AL,#0
    JMPZ go_norec
    MOV BX,#s_newrec
    MOV CX,#0x0705
    CALL puts
go_norec:
    MOV AL,#120
    CALL hold
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS (identicas a las que tenia demo.asm)
; ============================================================================

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila --------------------
puts:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV [ps_o+1],AL
    MOV AL,#0x04
    MOV [ps_o+2],AL
    MOV AL,BL
    MOV [ps_rd+1],AL
    MOV AL,BH
    MOV [ps_rd+2],AL
ps_l:
ps_rd:
    MOV AL,[0x0000]
    CMP AL,#0
    JMPZ ps_d
ps_o:
    OUT (P_TEXT),AL
    MOV AL,[ps_rd+1]
    ADD AL,#1
    MOV [ps_rd+1],AL
    JMPNZ ps_nh
    MOV AL,[ps_rd+2]
    ADD AL,#1
    MOV [ps_rd+2],AL
ps_nh:
    MOV AL,[ps_o+1]
    ADD AL,#1
    MOV [ps_o+1],AL
    JMP ps_l
ps_d:
    RET

; --- put_num:  AL = valor (0..255),  CL = col,  CH = fila ------------------
put_num:
    MOV [pn_v],AL
    MOV AL,[pn_v]
    PUSH AH
    MOV AH,#0
    MOV DL,#100
    DIV DL                  ; DL = cociente, resto -> [pn_v]
    MOV [pn_v],AH
    MOV DL,AL
    POP AH
pn_hd:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    MOV AL,[pn_v]
    PUSH AH
    MOV AH,#0
    MOV DL,#10
    DIV DL                  ; DL = cociente, resto -> [pn_v]
    MOV [pn_v],AH
    MOV DL,AL
    POP AH
pn_td:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    MOV AL,[pn_v]
    ADD AL,#0x30
    CALL putc
    RET

; --- putc:  AL = caracter,  CL = col,  CH = fila --------------------------
putc:
    MOV [tmp0],AL
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV [pc_o+1],AL
    MOV AL,#0x04
    MOV [pc_o+2],AL
    MOV AL,[tmp0]
pc_o:
    OUT (P_TEXT),AL
    RET

; --- clst:  borra la capa de texto (0x0400..0x04FF) ----------------------
clst:
    MOV BL,#0
    MOV AL,#0
ct_lp:
    MOV [ct_io+1],BL
ct_io:
    OUT (P_TEXT),AL
    ADD BL,#1
    JMPNZ ct_lp
    RET

; --- idx_ptr:  BX = (BL/BH iniciales) + CL, propagando el acarreo a mano ---
idx_ptr:
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
    RET

; --- shadow_fill:  rellena los 1024 bytes de `shadow` con AL --------------
shadow_fill:
    ; escribe AL en el primer byte y MOVB lo propaga por los 1023 restantes
    ; (origen/destino solapados a 1 byte, copia hacia adelante -- docs/isa.md
    ; SS4d): antes un bucle de 1024 vueltas
    MOV [sf_val],AL
    MOV [shadow],AL
    MOV BX,#shadow
    MOV DX,#shadow+1
    MOV CX,#0x03FF
    MOVB
    RET

; --- shadow_fillbox:  caja llena de 0xFF en gb_x,gb_y (gb_wb x gb_ht),
; escribe en `shadow` en vez de en el framebuffer real.
shadow_fillbox:
    MOV AL,[gb_ht]
    MOV [fs_h],AL
    MOV AL,[gb_y]
    MOV [fs_row],AL
sfb_l:
    MOV AL,[fs_row]
    MOV [tmp0],AL
    AND AL,#0x0F
    SHL AL,#4
    MOV BL,[gb_x]
    SHR BL,#3
    ADD AL,BL
    MOV [sfb_off],AL
    MOV AL,[tmp0]
    SHR AL,#4
    MOV [sfb_pag],AL

    MOV BX,#shadow
    MOV CL,[sfb_off]
    ADD BX,CL
    MOV AL,[sfb_pag]
    ADD BH,AL

    MOV CL,[gb_wb]
    MOV AL,#0xFF
sfb_cl:
    MOV [BX],AL
    INC BX
    SUB CL,#1
    JMPNZ sfb_cl

    MOV AL,[fs_row]
    ADD AL,#1
    MOV [fs_row],AL
    MOV AL,[fs_h]
    SUB AL,#1
    MOV [fs_h],AL
    JMPNZ sfb_l
    RET

; --- shadow_blit:  copia `shadow` al framebuffer real, solo lo que cambie --
shadow_blit:
    MOV BX,#0x0000
    MOV DX,#shadow
sbl_l:
    IN  AL,(BX)
    MOV CL,[DX]
    CMP AL,CL
    JMPZ sbl_same
    MOV AL,CL
    OUT (BX),AL
sbl_same:
    INC DX
    ADD BL,#1
    JMPNC sbl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ sbl_l
    RET

; --- rnd:  LFSR de 8 bits (taps 0xB8), deja el nuevo valor en AL ----------
rnd:
    MOV AL,[seed]
    SHR AL
    JMPNC rnd_n
    XOR AL,#0xB8
rnd_n:
    MOV [seed],AL
    RET

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) --------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- frame_wait_n:  AL = numero de frames de ~24 ms ---------------------
frame_wait_n:
    MOV [fwn_n],AL
fwn_l:
    MOV AL,[fwn_n]
    CMP AL,#0
    JMPZ fwn_d
    SUB AL,#1
    MOV [fwn_n],AL
    MOV AL,#3
    CALL frame_wait
    JMP fwn_l
fwn_d:
    RET

; --- hold:  AL = frames, pero sale antes si se pulsa DIRECCION o se toca
; el encoder DATOS (girarlo o pulsarlo) -- asi no hace falta esperar los
; 120 fotogramas enteros de GAME OVER para arrancar la partida siguiente.
hold:
    MOV [hd_n],AL
    IN  AL,(P_DAT_POS)
    MOV [hold_dp],AL
hd_l:
    CALL poll_exit
    MOV AL,[g_exit]
    CMP AL,#0
    JMPNZ hd_d
    IN  AL,(P_DAT_POS)
    MOV BL,[hold_dp]
    CMP AL,BL
    JMPNZ hd_d              ; giro DATOS -> siguiente partida ya
    IN  AL,(0x0603)         ; pulsador de DATOS
    CMP AL,#0
    JMPNZ hd_d
    MOV AL,[hd_n]
    CMP AL,#0
    JMPZ hd_d
    SUB AL,#1
    MOV [hd_n],AL
    MOV AL,#2
    CALL frame_wait
    JMP hd_l
hd_d:
    RET

; --- apply_move: aplica el giro de UN encoder a [gpx]. Entrada: AL = valor
; crudo leido de ese puerto este fotograma, DX = puntero a la variable
; "prev" de ESE encoder (gp_prev para DATOS, dir_prev para DIRECCION --
; cada uno necesita la suya, para no confundir el giro de uno con el del
; otro de un fotograma al siguiente). Mismo tope de 28 detentes de golpe
; (evita desbordar el x4) y de [gpx] en [0,112] que antes; los dos
; encoders mueven la MISMA plataforma, asi que esto se llama una vez por
; cada uno, en el orden que sea, sumando su efecto por separado.
apply_move:
    MOV [am_cur],AL
    MOV BL,[DX]               ; BL = prev anterior de este encoder
    MOV AL,[am_cur]
    MOV [DX],AL                ; guarda el nuevo prev
    SUB AL,BL                  ; AL = giro con signo (complemento a 2)
    MOV CL,AL
    AND AL,#0x80
    JMPNZ am_neg
    MOV AL,CL                  ; giro a la derecha: m = d
    CMP AL,#28
    JMPC am_pm
    MOV AL,#28                 ; tope por si gira muy rapido (evita desbordar x4)
am_pm:
    SHL AL,#2
    MOV BL,[gpx]
    ADD AL,BL
    CMP AL,#113
    JMPC am_store
    MOV AL,#112
    JMP am_store
am_neg:
    MOV AL,CL
    NOT AL
    ADD AL,#1                  ; m = -d
    CMP AL,#28
    JMPC am_nm
    MOV AL,#28
am_nm:
    SHL AL,#2
    MOV BL,AL
    MOV AL,[gpx]
    CMP AL,BL
    JMPC am_zero               ; pos < m*4 -> tope en 0
    SUB AL,BL
    JMP am_store
am_zero:
    MOV AL,#0
am_store:
    MOV [gpx],AL
    RET

; --- poll_exit:  marca g_exit si DIRECCION esta pulsado ----------------
poll_exit:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ pe_d
    MOV AL,#1
    MOV [g_exit],AL
pe_d:
    RET

; --- wait_dir_release:  espera a que se suelte DIRECCION ---------------
wait_dir_release:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ wdr_d
    MOV AL,#2
    CALL frame_wait
    JMP wait_dir_release
wdr_d:
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
    JMPNZ lr_set
    IN  AL,(P_EEP_BASE+1)
lr_set:
    MOV [record],AL
    RET

; --- show_record: carga el record y escribe "RECORD nnn" en CH=fila, CL=col --
show_record:
    CALL load_record
    MOV AL,[record]
    MOV AH,#0
    MOV BL,#100
    DIV BL
    ADD AL,#'0'
    MOV [rec_d],AL
    MOV AL,AH
    MOV AH,#0
    MOV BL,#10
    DIV BL
    ADD AL,#'0'
    MOV [rec_d+1],AL
    MOV AL,AH
    ADD AL,#'0'
    MOV [rec_d+2],AL
    MOV BX,#s_record
    CALL puts
    RET

; --- save_record: si [g_score] supera el record, lo graba en la flash.
; Sale AL = 1 si es record nuevo, 0 si no. ----------------------------------
save_record:
    MOV AL,[g_score]
    MOV BL,[record]
    CMP BL,AL
    MOV AL,#0
    JMPNC svr_done          ; record >= puntos: nada que grabar
    MOV AL,[g_score]
    MOV [record],AL
    OUT (P_EEP_LOAD),AL     ; parte del contenido real de la EEPROM
    OUT (P_EEP_BASE+1),AL
    MOV AL,#REC_MAGIC
    OUT (P_EEP_BASE),AL
    OUT (P_EEP_SAVE),AL
    MOV AL,#1
svr_done:
    RET

; ============================================================================
;  DATOS
; ============================================================================
h_game:    .asciiz "DODGE  S:"
str_over:  .asciiz "GAME OVER"
str_score: .asciiz "SCORE:"
str_title: .asciiz "DODGE"
str_start: .asciiz "PRESS DATA TO START"
s_record: .ascii "RECORD "
rec_d:    .asciiz "000"
s_newrec: .asciiz "NEW RECORD!"
hold_dp:   .space 1    ; posicion de DATOS al entrar en hold() (ver arriba)

    .org 0xF300
obarr:     .space 6

; shadow: copia del framebuffer en RAM (ver shadow_fill/game_draw/game_over).
; Va aparte con su propio .org, igual que obarr: es un .space sin datos
; reales, asi que no cuenta para el recorte del .bin.
    .org 0xF400
shadow:    .space 1024
