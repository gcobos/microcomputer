; ============================================================================
;  demo.asm  -  demostracion de las capacidades de compi
;
;  Un menu principal que llama a rutinas independientes, cada una enseñando
;  una faceta del aparato:
;     1 GRAFICOS   - framebuffer: caja rebotando + marco
;     2 TEXTO      - capa de texto: efecto maquina de escribir + juego de chars
;     3 SONIDO     - piezo: escala ascendente/descendente + barra + LED
;     4 ANIMACION  - curva de Lissajous trazada con estela
;     5 LUCES      - LED estroboscopico + destellos de pantalla + barras
;     6 JUEGO      - "ESQUIVA": esquiva los bloques que caen (usa todo junto)
;
;  Controles en EJECUTAR + CONTINUO:
;     encoder DATOS gira  -> mueve la seleccion del menu / al jugador
;     encoder DATOS pulsa -> entra en la opcion
;     encoder DIRECCION pulsa -> vuelve al menu
;
;  Ensamblar y enviar al slot 4:
;     python3 tools/casm.py programs/demo.asm -o programs/demo.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 4 programs/demo.bin
;
;  La ISA y los puertos: ../specs.txt  y  ../docs/isa.md
; ============================================================================

    .slot 4
    .org 0x0000

; --- variables (RAM alta, lejos del codigo) ----------------------------------
seed      = 0xFE00      ; semilla del LFSR (nunca 0)
sel       = 0xFE01      ; opcion del menu seleccionada (0..5)
dat_prev  = 0xFE02      ; ultima posicion del encoder DATOS
btn_prev  = 0xFE03      ; ultimo nivel del pulsador DATOS
g_exit    = 0xFE04      ; 1 = el usuario ha pulsado DIRECCION -> salir
tmp0      = 0xFE05
tmp1      = 0xFE06
tmp2      = 0xFE07
px_x      = 0xFE08      ; argumentos de plot
px_y      = 0xFE09
cg_val    = 0xFE0A      ; byte de relleno de clsg/fillg
cg_lo     = 0xFE0B
cg_hi     = 0xFE0C
ct_lo     = 0xFE0D
hs_val    = 0xFE0E      ; byte de relleno de hspan
fwn_n     = 0xFE0F      ; contador de frame_wait_n
hd_n      = 0xFE10      ; contador de hold
gb_x      = 0xFE12      ; caja: x (multiplo de 8)
gb_y      = 0xFE13      ; caja: y
gb_wb     = 0xFE18      ; caja: ancho en bytes
gb_ht     = 0xFE19      ; caja: alto en filas
gx_dx     = 0xFE16      ; caja: velocidad x
gx_dy     = 0xFE17      ; caja: velocidad y
fs_h      = 0xFE1A      ; fillbox_solid: filas que quedan
fs_row    = 0xFE1B      ; fillbox_solid: fila actual
tw_col    = 0xFE1C      ; maquina de escribir: columna
tw_row    = 0xFE1D      ; maquina de escribir: fila
tw_p      = 0xFE1E      ; maquina de escribir: puntero (2 bytes: 0xFE1E/0xFE1F)
cs_ch     = 0xFE20      ; juego de caracteres: codigo
cs_col    = 0xFE21
cs_row    = 0xFE22
ds_i      = 0xFE23      ; sonido: indice en la tabla de melodia
ds_note   = 0xFE24
ds_dur    = 0xFE25
an_t      = 0xFE26      ; animacion: parametro t
an_fc     = 0xFE27      ; animacion: cuenta de frames para limpiar la estela
li_ph     = 0xFE28      ; luces: fase
gpx       = 0xFE29      ; juego: x del jugador (pixel)
g_score   = 0xFE2A      ; juego: puntos
g_over    = 0xFE2B      ; juego: 1 = fin de partida
g_speed   = 0xFE2C      ; juego: velocidad de caida
ob_i      = 0xFE2D      ; juego: offset del obstaculo en curso (0/2/4)
ob_newy   = 0xFE2E
go_i      = 0xFE2F      ; game_over: contador de destellos
pn_v      = 0xFE30      ; put_num: valor en curso

; --- puertos (ver ../docs/isa.md) ------------------------------------------
P_FB      = 0x0000      ; framebuffer
P_TEXT    = 0x0400      ; rejilla de texto
P_DAT_POS = 0x0502      ; encoder DATOS: posicion
P_DIR_BTN = 0x0501      ; encoder DIRECCION: pulsado
P_LED     = 0x0510
P_T3      = 0x0523      ; temporizador 3 (8 ms/paso)
P_SND_N   = 0x0532      ; nota MIDI
P_SND_D   = 0x0533      ; duracion automatica (x10 ms)

; ============================================================================
;  ARRANQUE  +  MENU
; ============================================================================
start:
    MOV AL,#0
    STA [sel],AL
    IN  AL,(P_DAT_POS)         ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    CMP AL,#0
    JMPNZ menu
    MOV AL,#0x5D
    STA [seed],AL
    ; cae en menu

menu:
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [btn_prev],AL
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL draw_menu
menu_l:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL                  ; AL = delta del encoder (con signo)
    LDA CL,[tmp0]
    STA [dat_prev],CL
    JMPZ mn_btn                ; sin movimiento -> mira el pulsador
    AND AL,#0x80
    JMPZ mn_up
    ; giro negativo -> sel--
    LDA AL,[sel]
    CMP AL,#0
    JMPZ mn_wrhi
    SUB AL,#1
    STA [sel],AL
    JMP mn_rd
mn_wrhi:
    MOV AL,#5
    STA [sel],AL
    JMP mn_rd
mn_up:
    ; giro positivo -> sel++
    LDA AL,[sel]
    CMP AL,#5
    JMPZ mn_wrlo
    ADD AL,#1
    STA [sel],AL
    JMP mn_rd
mn_wrlo:
    MOV AL,#0
    STA [sel],AL
mn_rd:
    CALL draw_menu
    MOV AL,#1
    CALL frame_wait
    JMP menu_l
mn_btn:
    IN  AL,(0x0503)            ; pulsador del encoder DATOS
    LDA BL,[btn_prev]
    STA [btn_prev],AL
    CMP AL,#0
    JMPZ mn_wait               ; no pulsado
    CMP BL,#0
    JMPNZ mn_wait              ; ya estaba pulsado -> no es flanco
    JMP menu_sel
mn_wait:
    MOV AL,#1
    CALL frame_wait
    JMP menu_l

menu_sel:
    LDA AL,[sel]
    CMP AL,#0
    JMPZ ms0
    CMP AL,#1
    JMPZ ms1
    CMP AL,#2
    JMPZ ms2
    CMP AL,#3
    JMPZ ms3
    CMP AL,#4
    JMPZ ms4
    JMP ms5
ms0:
    CALL do_gfx
    JMP menu
ms1:
    CALL do_txt
    JMP menu
ms2:
    CALL do_snd
    JMP menu
ms3:
    CALL do_anim
    JMP menu
ms4:
    CALL do_lights
    JMP menu
ms5:
    CALL do_game
    JMP menu

; ============================================================================
;  1 GRAFICOS  -  caja solida rebotando dentro de un marco
; ============================================================================
do_gfx:
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL clst
    MOV AL,#0
    STA [tmp0],AL
    CALL hline_full           ; marco: borde superior (y=0)
    MOV AL,#62
    STA [tmp0],AL
    CALL hline_full           ; marco: borde inferior (y=62)
    MOV BL,#lo(h_gfx)
    MOV BH,#hi(h_gfx)
    MOV CL,#7
    MOV CH,#0
    CALL puts
    MOV AL,#0
    STA [gb_x],AL
    MOV AL,#20
    STA [gb_y],AL
    MOV AL,#8
    STA [gx_dx],AL
    MOV AL,#2
    STA [gx_dy],AL
    MOV AL,#2
    STA [gb_wb],AL
    MOV AL,#10
    STA [gb_ht],AL
    CALL fillbox_xor         ; pinta la caja
dg_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ dg_x
    CALL fillbox_xor         ; borra la caja (XOR) en la posicion vieja
    ; mover en x  (paso 8, rango 0..112)
    LDA AL,[gb_x]
    LDA BL,[gx_dx]
    ADD AL,BL
    STA [gb_x],AL
    MOV BL,AL
    AND BL,#0x80
    JMPNZ dg_xlo             ; se paso por abajo
    CMP AL,#113
    JMPC dg_xok              ; 0..112 -> vale
    MOV AL,#112
    STA [gb_x],AL
    JMP dg_xrev
dg_xlo:
    MOV AL,#0
    STA [gb_x],AL
dg_xrev:
    LDA AL,[gx_dx]
    NOT AL
    ADD AL,#1
    STA [gx_dx],AL
dg_xok:
    ; mover en y  (paso 2, rango 9..50; deja libre la fila de texto y=0..7)
    LDA AL,[gb_y]
    LDA BL,[gx_dy]
    ADD AL,BL
    STA [gb_y],AL
    CMP AL,#9
    JMPC dg_ylo
    CMP AL,#51
    JMPC dg_yok             ; 9..50 -> vale
    MOV AL,#50
    STA [gb_y],AL
    JMP dg_yrev
dg_ylo:
    MOV AL,#9
    STA [gb_y],AL
dg_yrev:
    LDA AL,[gx_dy]
    NOT AL
    ADD AL,#1
    STA [gx_dy],AL
dg_yok:
    CALL fillbox_xor        ; redibuja en la posicion nueva
    MOV AL,#3
    CALL frame_wait
    JMP dg_l
dg_x:
    CALL wait_dir_release
    RET

; ============================================================================
;  2 TEXTO  -  maquina de escribir + juego de caracteres
; ============================================================================
do_txt:
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL clst
    MOV AL,#0
    STA [tw_col],AL
    STA [tw_row],AL
    MOV AL,#lo(txt_msg)
    STA [tw_p],AL
    MOV AL,#hi(txt_msg)
    STA [tw_p+1],AL
dt_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ dt_x
    LDA AL,[tw_p]
    STA [dt_rd+1],AL
    LDA AL,[tw_p+1]
    STA [dt_rd+2],AL
dt_rd:
    LDA AL,[0x0000]           ; AL = *tw_p  (operando parcheado)
    CMP AL,#0
    JMPZ dt_hold
    CMP AL,#10
    JMPZ dt_nl
    STA [tmp0],AL             ; guarda el caracter
    LDA AL,[tw_row]
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL                    ; fila * 32
    LDA BL,[tw_col]
    ADD AL,BL
    STA [dt_o+1],AL
    MOV AL,#0x04
    STA [dt_o+2],AL
    LDA AL,[tmp0]
dt_o:
    OUT (P_TEXT),AL           ; escribe la celda (operando parcheado)
    MOV AL,#1
    OUT (P_SND_D),AL
    MOV AL,#84
    OUT (P_SND_N),AL          ; blip por tecla
    LDA AL,[tw_col]
    ADD AL,#1
    STA [tw_col],AL
    CMP AL,#21
    JMPNZ dt_adv
    MOV AL,#0
    STA [tw_col],AL
    LDA AL,[tw_row]
    ADD AL,#1
    STA [tw_row],AL
dt_adv:
    CALL dt_ptr_inc
    MOV AL,#2
    CALL frame_wait
    JMP dt_l
dt_nl:
    MOV AL,#0
    STA [tw_col],AL
    LDA AL,[tw_row]
    ADD AL,#1
    STA [tw_row],AL
    CALL dt_ptr_inc
    JMP dt_l
dt_hold:
    MOV AL,#40
    CALL hold
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ dt_x
    CALL show_charset
    MOV AL,#120
    CALL hold
    JMP do_txt
dt_x:
    CALL wait_dir_release
    RET

dt_ptr_inc:
    LDA AL,[tw_p]
    ADD AL,#1
    STA [tw_p],AL
    JMPNZ dpi_d
    LDA AL,[tw_p+1]
    ADD AL,#1
    STA [tw_p+1],AL
dpi_d:
    RET

show_charset:
    CALL clst
    MOV AL,#0x20
    STA [cs_ch],AL
    MOV AL,#0
    STA [cs_col],AL
    STA [cs_row],AL
sc_l:
    LDA AL,[cs_row]
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    LDA BL,[cs_col]
    ADD AL,BL
    STA [sc_io+1],AL
    MOV AL,#0x04
    STA [sc_io+2],AL
    LDA AL,[cs_ch]
sc_io:
    OUT (P_TEXT),AL
    LDA AL,[cs_ch]
    ADD AL,#1
    STA [cs_ch],AL
    CMP AL,#0x80
    JMPZ sc_d
    LDA AL,[cs_col]
    ADD AL,#1
    STA [cs_col],AL
    CMP AL,#21
    JMPNZ sc_l
    MOV AL,#0
    STA [cs_col],AL
    LDA AL,[cs_row]
    ADD AL,#1
    STA [cs_row],AL
    JMP sc_l
sc_d:
    RET

; ============================================================================
;  3 SONIDO  -  escala ascendente + descendente, barra de tono y LED
; ============================================================================
do_snd:
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL clst
    MOV BL,#lo(h_snd)
    MOV BH,#hi(h_snd)
    MOV CL,#7
    MOV CH,#0
    CALL puts
ds_rs:
    MOV AL,#0
    STA [ds_i],AL
ds_nx:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ ds_x
    LDA AL,[ds_i]
    STA [dsr_n+1],AL
dsr_n:
    LDA AL,[0xF100]          ; nota (operando parcheado, pagina 0xF1)
    CMP AL,#0xFF
    JMPZ ds_rs
    STA [ds_note],AL
    LDA AL,[ds_i]
    ADD AL,#1
    STA [dsr_d+1],AL
dsr_d:
    LDA AL,[0xF100]          ; duracion
    STA [ds_dur],AL
    LDA AL,[ds_i]
    ADD AL,#2
    STA [ds_i],AL
    LDA AL,[ds_note]
    CMP AL,#0
    JMPZ ds_rest
    OUT (P_SND_N),AL
    MOV AL,#1
    OUT (P_LED),AL
    ; barra: borra la fila 40 y dibuja longitud (nota-40)/2
    MOV AL,#40
    STA [tmp0],AL
    MOV AL,#0
    STA [tmp1],AL
    MOV AL,#15
    STA [tmp2],AL
    MOV AL,#0
    STA [hs_val],AL
    CALL hspan
    MOV AL,#40
    STA [tmp0],AL
    MOV AL,#0
    STA [tmp1],AL
    LDA AL,[ds_note]
    SUB AL,#40
    SHR AL
    CMP AL,#16
    JMPC ds_bok
    MOV AL,#15
ds_bok:
    STA [tmp2],AL
    MOV AL,#0xFF
    STA [hs_val],AL
    CALL hspan
    JMP ds_wt
ds_rest:
    MOV AL,#0
    OUT (P_SND_N),AL
    OUT (P_LED),AL
ds_wt:
    LDA AL,[ds_dur]
    CALL frame_wait_n
    MOV AL,#0
    OUT (P_SND_N),AL
    OUT (P_LED),AL
    MOV AL,#1
    CALL frame_wait_n
    JMP ds_nx
ds_x:
    MOV AL,#0
    OUT (P_SND_N),AL
    OUT (P_LED),AL
    CALL wait_dir_release
    RET

; ============================================================================
;  4 ANIMACION  -  curva de Lissajous con estela
; ============================================================================
do_anim:
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL clst
    MOV AL,#0
    STA [an_t],AL
    STA [an_fc],AL
    CALL da_label
da_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ da_x
    LDA AL,[an_t]            ; indice x = (t*3) & 63
    MOV BL,AL
    ADD AL,AL
    ADD AL,BL
    AND AL,#0x3F
    STA [dax_rd+1],AL
dax_rd:
    LDA AL,[0xF000]          ; seno (pagina 0xF0)
    SHL AL                   ; x = seno * 2  (0..124)
    STA [px_x],AL
    LDA AL,[an_t]            ; indice y = (t*2 + 16) & 63
    ADD AL,AL
    ADD AL,#16
    AND AL,#0x3F
    STA [day_rd+1],AL
day_rd:
    LDA AL,[0xF000]
    STA [px_y],AL
    CALL plot
    LDA AL,[an_t]
    ADD AL,#1
    STA [an_t],AL
    LDA AL,[an_fc]
    ADD AL,#1
    STA [an_fc],AL
    CMP AL,#120
    JMPNZ da_nc
    CALL clsg               ; limpia la estela cada 120 puntos
    CALL da_label
    MOV AL,#0
    STA [an_fc],AL
da_nc:
    MOV AL,#1
    CALL frame_wait_n
    JMP da_l
da_x:
    CALL wait_dir_release
    RET

da_label:
    MOV BL,#lo(h_anim)
    MOV BH,#hi(h_anim)
    MOV CL,#6
    MOV CH,#0
    CALL puts
    RET

; ============================================================================
;  5 LUCES  -  LED estroboscopico + destellos de pantalla + barras al azar
; ============================================================================
do_lights:
    MOV AL,#0
    STA [g_exit],AL
    CALL clsg
    CALL clst
    MOV AL,#0
    STA [li_ph],AL
dl_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ dl_x
    LDA AL,[li_ph]
    AND AL,#1
    STA [tmp0],AL
    OUT (P_LED),AL
    CMP AL,#0
    JMPZ dl_blk
    CALL fillg
    JMP dl_bars
dl_blk:
    CALL clsg
dl_bars:
    CALL rnd
    AND AL,#0x3F
    STA [tmp0],AL
    CALL rnd
    AND AL,#0x0C
    STA [tmp1],AL
    ADD AL,#3
    STA [tmp2],AL
    MOV AL,#0xFF
    STA [hs_val],AL
    CALL hspan
    CALL clst
    MOV BL,#lo(h_light)
    MOV BH,#hi(h_light)
    MOV CL,#8
    MOV CH,#3
    CALL puts
    LDA AL,[li_ph]
    AND AL,#1
    CMP AL,#0
    JMPZ dl_nb
    MOV AL,#2
    OUT (P_SND_D),AL
    MOV AL,#45
    OUT (P_SND_N),AL
dl_nb:
    LDA AL,[li_ph]
    ADD AL,#1
    STA [li_ph],AL
    MOV AL,#4
    CALL frame_wait
    JMP dl_l
dl_x:
    MOV AL,#0
    OUT (P_LED),AL
    OUT (P_SND_N),AL
    CALL wait_dir_release
    RET

; ============================================================================
;  6 JUEGO  -  "ESQUIVA": mueve al jugador con DATOS, esquiva los bloques
; ============================================================================
do_game:
    MOV AL,#0
    STA [g_exit],AL
    STA [g_over],AL
    STA [g_score],AL
    CALL clsg
    CALL clst
    MOV AL,#1
    STA [g_speed],AL
    MOV AL,#40            ; obstaculo 0: x, y
    STA [0xF300],AL
    MOV AL,#3
    STA [0xF301],AL
    MOV AL,#72            ; obstaculo 1
    STA [0xF302],AL
    MOV AL,#20
    STA [0xF303],AL
    MOV AL,#104           ; obstaculo 2
    STA [0xF304],AL
    MOV AL,#40
    STA [0xF305],AL
dg2_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ dg2_ret
    IN  AL,(P_DAT_POS)       ; jugador = posicion del encoder DATOS
    AND AL,#0x7F
    CMP AL,#113
    JMPC dg2_pok
    MOV AL,#112
dg2_pok:
    STA [gpx],AL
    LDA AL,[g_score]         ; sube la velocidad con los puntos
    CMP AL,#20
    JMPC dg2_s1
    MOV AL,#3
    STA [g_speed],AL
    JMP dg2_obs
dg2_s1:
    LDA AL,[g_score]
    CMP AL,#8
    JMPC dg2_s0
    MOV AL,#2
    STA [g_speed],AL
    JMP dg2_obs
dg2_s0:
    MOV AL,#1
    STA [g_speed],AL
dg2_obs:
    MOV AL,#0
    STA [ob_i],AL
    CALL obstacle
    LDA AL,[g_over]
    CMP AL,#0
    JMPNZ dg2_go
    MOV AL,#2
    STA [ob_i],AL
    CALL obstacle
    LDA AL,[g_over]
    CMP AL,#0
    JMPNZ dg2_go
    MOV AL,#4
    STA [ob_i],AL
    CALL obstacle
    LDA AL,[g_over]
    CMP AL,#0
    JMPNZ dg2_go
    CALL game_draw
    MOV AL,#3
    CALL frame_wait
    JMP dg2_l
dg2_go:
    CALL game_over
dg2_ret:
    CALL wait_dir_release
    RET

; un obstaculo:  [ob_i] = 0 | 2 | 4  (offset x,y en la pagina 0xF300)
obstacle:
    LDA AL,[ob_i]
    STA [ob_rx+1],AL
    STA [ob_wx+1],AL
    ADD AL,#1
    STA [ob_ry+1],AL
    STA [ob_wy+1],AL
    STA [ob_wy2+1],AL
ob_ry:
    LDA AL,[0xF301]         ; y actual
    LDA BL,[g_speed]
    ADD AL,BL
    STA [ob_newy],AL
    CMP AL,#59
    JMPC ob_store           ; sigue cayendo
    ; ha llegado abajo: ¿colision con el jugador?
ob_rx:
    LDA DL,[0xF300]         ; x del obstaculo
    MOV AL,DL
    ADD AL,#8
    LDA BL,[gpx]
    SUB AL,BL               ; AL = obs_x + 8 - jugador_x
    CMP AL,#25
    JMPNC ob_recy           ; > 24  -> no toca
    CMP AL,#1
    JMPC ob_recy            ; == 0  -> no toca
    MOV AL,#1               ; 1..24 -> IMPACTO
    STA [g_over],AL
    RET
ob_recy:
    CALL rnd
    AND AL,#0x78            ; nueva x (multiplo de 8, 0..120)
ob_wx:
    STA [0xF300],AL
    MOV AL,#0
ob_wy2:
    STA [0xF301],AL         ; y = 0 (arriba otra vez)
    LDA AL,[g_score]
    ADD AL,#1
    STA [g_score],AL
    MOV AL,#1
    OUT (P_SND_D),AL
    MOV AL,#88
    OUT (P_SND_N),AL        ; blip de punto
    RET
ob_store:
    LDA AL,[ob_newy]
ob_wy:
    STA [0xF301],AL
    RET

game_draw:
    CALL clsg
    LDA AL,[gpx]            ; jugador (alineado a byte)
    SHR AL
    SHR AL
    SHR AL
    SHL AL
    SHL AL
    SHL AL
    STA [gb_x],AL
    MOV AL,#58
    STA [gb_y],AL
    MOV AL,#2
    STA [gb_wb],AL
    MOV AL,#5
    STA [gb_ht],AL
    CALL fillbox_solid
    MOV AL,#0
    STA [ob_i],AL
    CALL draw_ob
    MOV AL,#2
    STA [ob_i],AL
    CALL draw_ob
    MOV AL,#4
    STA [ob_i],AL
    CALL draw_ob
    CALL clst
    MOV BL,#lo(h_game)
    MOV BH,#hi(h_game)
    MOV CL,#0
    MOV CH,#0
    CALL puts
    LDA AL,[g_score]
    MOV CL,#12
    MOV CH,#0
    CALL put_num
    RET

draw_ob:
    LDA AL,[ob_i]
    STA [dob_rx+1],AL
    ADD AL,#1
    STA [dob_ry+1],AL
dob_rx:
    LDA AL,[0xF300]
    SHR AL
    SHR AL
    SHR AL
    SHL AL
    SHL AL
    SHL AL
    STA [gb_x],AL
dob_ry:
    LDA AL,[0xF301]
    CMP AL,#59
    JMPC dob_yok
    MOV AL,#58
dob_yok:
    STA [gb_y],AL
    MOV AL,#1
    STA [gb_wb],AL
    MOV AL,#4
    STA [gb_ht],AL
    CALL fillbox_solid
    RET

game_over:
    MOV AL,#0
    STA [go_i],AL
go_l:
    CALL fillg
    MOV AL,#1
    OUT (P_LED),AL
    LDA AL,[go_i]           ; tono descendente 64, 60, 56...
    MOV BL,AL
    SHL BL
    SHL BL
    MOV AL,#64
    SUB AL,BL
    STA [tmp0],AL
    MOV AL,#3
    OUT (P_SND_D),AL
    LDA AL,[tmp0]
    OUT (P_SND_N),AL
    MOV AL,#4
    CALL frame_wait
    CALL clsg
    MOV AL,#0
    OUT (P_LED),AL
    MOV AL,#3
    CALL frame_wait
    LDA AL,[go_i]
    ADD AL,#1
    STA [go_i],AL
    CMP AL,#10
    JMPNZ go_l
    MOV AL,#0
    OUT (P_SND_N),AL
    CALL clsg
    CALL clst
    MOV BL,#lo(str_over)
    MOV BH,#hi(str_over)
    MOV CL,#6
    MOV CH,#3
    CALL puts
    MOV BL,#lo(str_score)
    MOV BH,#hi(str_score)
    MOV CL,#5
    MOV CH,#5
    CALL puts
    LDA AL,[g_score]
    MOV CL,#13
    MOV CH,#5
    CALL put_num
    MOV AL,#120
    CALL hold
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- menu ------------------------------------------------------------------
draw_menu:
    CALL clst
    MOV BL,#lo(h_title)
    MOV BH,#hi(h_title)
    MOV CL,#5
    MOV CH,#0
    CALL puts
    MOV BL,#lo(m_i1)
    MOV BH,#hi(m_i1)
    MOV CL,#4
    MOV CH,#2
    CALL puts
    MOV BL,#lo(m_i2)
    MOV BH,#hi(m_i2)
    MOV CL,#4
    MOV CH,#3
    CALL puts
    MOV BL,#lo(m_i3)
    MOV BH,#hi(m_i3)
    MOV CL,#4
    MOV CH,#4
    CALL puts
    MOV BL,#lo(m_i4)
    MOV BH,#hi(m_i4)
    MOV CL,#4
    MOV CH,#5
    CALL puts
    MOV BL,#lo(m_i5)
    MOV BH,#hi(m_i5)
    MOV CL,#4
    MOV CH,#6
    CALL puts
    MOV BL,#lo(m_i6)
    MOV BH,#hi(m_i6)
    MOV CL,#4
    MOV CH,#7
    CALL puts
    LDA AL,[sel]
    ADD AL,#2
    STA [tmp0],AL
    MOV BL,#lo(m_mark)
    MOV BH,#hi(m_mark)
    MOV CL,#2
    LDA CH,[tmp0]
    CALL puts
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila --------------------
; solo altera AL.
puts:
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    ADD AL,CL
    STA [ps_o+1],AL
    MOV AL,#0x04
    STA [ps_o+2],AL
    MOV AL,BL
    STA [ps_rd+1],AL
    MOV AL,BH
    STA [ps_rd+2],AL
ps_l:
ps_rd:
    LDA AL,[0x0000]
    CMP AL,#0
    JMPZ ps_d
ps_o:
    OUT (P_TEXT),AL
    LDA AL,[ps_rd+1]
    ADD AL,#1
    STA [ps_rd+1],AL
    JMPNZ ps_nh
    LDA AL,[ps_rd+2]
    ADD AL,#1
    STA [ps_rd+2],AL
ps_nh:
    LDA AL,[ps_o+1]
    ADD AL,#1
    STA [ps_o+1],AL
    JMP ps_l
ps_d:
    RET

; --- put_num:  AL = valor (0..255),  CL = col,  CH = fila ------------------
put_num:
    STA [pn_v],AL
    MOV DL,#0
pn_h:
    LDA AL,[pn_v]
    CMP AL,#100
    JMPC pn_hd
    SUB AL,#100
    STA [pn_v],AL
    ADD DL,#1
    JMP pn_h
pn_hd:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    MOV DL,#0
pn_t:
    LDA AL,[pn_v]
    CMP AL,#10
    JMPC pn_td
    SUB AL,#10
    STA [pn_v],AL
    ADD DL,#1
    JMP pn_t
pn_td:
    MOV AL,DL
    ADD AL,#0x30
    CALL putc
    ADD CL,#1
    LDA AL,[pn_v]
    ADD AL,#0x30
    CALL putc
    RET

; --- putc:  AL = caracter,  CL = col,  CH = fila --------------------------
putc:
    STA [tmp0],AL
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    ADD AL,CL
    STA [pc_o+1],AL
    MOV AL,#0x04
    STA [pc_o+2],AL
    LDA AL,[tmp0]
pc_o:
    OUT (P_TEXT),AL
    RET

; --- clsg / fillg:  rellena el framebuffer (0x0000..0x03FF) ---------------
; AL = byte de relleno, BL = contador bajo, CL = pagina alta (0..3).
fillg:
    MOV AL,#0xFF
    JMP cg_v
clsg:
    MOV AL,#0
cg_v:
    STA [cg_val],AL
    MOV CL,#0
cg_hp:
    MOV AL,CL
    STA [cg_io+2],AL
    MOV BL,#0
    LDA AL,[cg_val]
cg_lp:
    STA [cg_io+1],BL
cg_io:
    OUT (P_FB),AL
    ADD BL,#1
    JMPNZ cg_lp
    ADD CL,#1
    CMP CL,#4
    JMPNZ cg_hp
    RET

; --- clst:  borra la capa de texto (0x0400..0x04FF) ----------------------
clst:
    MOV BL,#0
    MOV AL,#0
ct_lp:
    STA [ct_io+1],BL
ct_io:
    OUT (P_TEXT),AL
    ADD BL,#1
    JMPNZ ct_lp
    RET

; --- hspan:  fila tmp0, bytes-x tmp1..tmp2, valor hs_val ------------------
hspan:
    LDA AL,[tmp0]
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    LDA BL,[tmp1]
    ADD AL,BL
    STA [hp_io+1],AL
    LDA AL,[tmp0]
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [hp_io+2],AL
    LDA CL,[tmp2]
    LDA BL,[tmp1]
    SUB CL,BL
    ADD CL,#1
    LDA AL,[hs_val]
hp_l:
hp_io:
    OUT (P_FB),AL
    LDA BL,[hp_io+1]
    ADD BL,#1
    STA [hp_io+1],BL
    SUB CL,#1
    JMPNZ hp_l
    RET

; --- hline_full:  fila tmp0 entera a 0xFF --------------------------------
hline_full:
    LDA AL,[tmp0]
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    STA [hf_io+1],AL
    LDA AL,[tmp0]
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [hf_io+2],AL
    MOV CL,#16
    MOV AL,#0xFF
hf_l:
hf_io:
    OUT (P_FB),AL
    LDA BL,[hf_io+1]
    ADD BL,#1
    STA [hf_io+1],BL
    SUB CL,#1
    JMPNZ hf_l
    RET

; --- fillbox_solid:  caja llena de 0xFF en gb_x,gb_y (gb_wb x gb_ht) ------
fillbox_solid:
    LDA AL,[gb_ht]
    STA [fs_h],AL
    LDA AL,[gb_y]
    STA [fs_row],AL
fs_l:
    LDA AL,[fs_row]
    STA [tmp0],AL
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    LDA BL,[gb_x]
    SHR BL
    SHR BL
    SHR BL
    ADD AL,BL
    STA [fb_io+1],AL
    LDA AL,[tmp0]
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [fb_io+2],AL
    LDA CL,[gb_wb]
    MOV AL,#0xFF
fb_cl:
fb_io:
    OUT (P_FB),AL
    LDA BL,[fb_io+1]
    ADD BL,#1
    STA [fb_io+1],BL
    SUB CL,#1
    JMPNZ fb_cl
    LDA AL,[fs_row]
    ADD AL,#1
    STA [fs_row],AL
    LDA AL,[fs_h]
    SUB AL,#1
    STA [fs_h],AL
    JMPNZ fs_l
    RET

; --- fillbox_xor:  invierte (XOR 0xFF) una caja gb_wb x gb_ht en gb_x,gb_y -
; dibujarla dos veces en el mismo sitio la borra sin tocar el fondo.
fillbox_xor:
    LDA AL,[gb_ht]
    STA [fs_h],AL
    LDA AL,[gb_y]
    STA [fs_row],AL
fxb_l:
    LDA AL,[fs_row]
    STA [tmp0],AL
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    LDA BL,[gb_x]
    SHR BL
    SHR BL
    SHR BL
    ADD AL,BL
    STA [fxb_i+1],AL
    STA [fxb_o+1],AL
    LDA AL,[tmp0]
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [fxb_i+2],AL
    STA [fxb_o+2],AL
    LDA CL,[gb_wb]
fxb_cl:
fxb_i:
    IN  DL,(P_FB)
    XOR DL,#0xFF
fxb_o:
    OUT (P_FB),DL
    LDA AL,[fxb_i+1]
    ADD AL,#1
    STA [fxb_i+1],AL
    STA [fxb_o+1],AL
    SUB CL,#1
    JMPNZ fxb_cl
    LDA AL,[fs_row]
    ADD AL,#1
    STA [fs_row],AL
    LDA AL,[fs_h]
    SUB AL,#1
    STA [fs_h],AL
    JMPNZ fxb_l
    RET

; --- plot:  enciende el pixel (px_x, px_y), conservando el resto ----------
plot:
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
    OR AL,DL
    STA [pl_i+1],AL
    STA [pl_o+1],AL
    MOV AL,CH
    SHR AL
    SHR AL
    SHR AL
    SHR AL
    STA [pl_i+2],AL
    STA [pl_o+2],AL
    MOV DL,CL
    AND DL,#0x07
    MOV DH,#0x80
pl_m:
    CMP DL,#0
    JMPZ pl_d
    SHR DH
    SUB DL,#1
    JMP pl_m
pl_d:
pl_i:
    IN  CL,(P_FB)
    OR  CL,DH
pl_o:
    OUT (P_FB),CL
    RET

; --- rnd:  LFSR de 8 bits (taps 0xB8), deja el nuevo valor en AL ----------
rnd:
    LDA AL,[seed]
    SHR AL
    JMPNC rnd_n
    XOR AL,#0xB8
rnd_n:
    STA [seed],AL
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
    STA [fwn_n],AL
fwn_l:
    LDA AL,[fwn_n]
    CMP AL,#0
    JMPZ fwn_d
    SUB AL,#1
    STA [fwn_n],AL
    MOV AL,#3
    CALL frame_wait
    JMP fwn_l
fwn_d:
    RET

; --- hold:  AL = frames, pero sale antes si se pulsa DIRECCION -----------
hold:
    STA [hd_n],AL
hd_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ hd_d
    LDA AL,[hd_n]
    CMP AL,#0
    JMPZ hd_d
    SUB AL,#1
    STA [hd_n],AL
    MOV AL,#2
    CALL frame_wait
    JMP hd_l
hd_d:
    RET

; --- poll_exit:  marca g_exit si DIRECCION esta pulsado ----------------
poll_exit:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ pe_d
    MOV AL,#1
    STA [g_exit],AL
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
;  DATOS
; ============================================================================
    .org 0xF000
sine:
    .db 32, 35, 38, 41, 43, 46, 49, 51, 53, 55, 57, 58, 60, 61, 61, 62
    .db 62, 62, 61, 61, 60, 58, 57, 55, 53, 51, 49, 46, 43, 41, 38, 35
    .db 32, 29, 26, 23, 21, 18, 15, 13, 11, 9, 7, 6, 4, 3, 3, 2
    .db 2, 2, 3, 3, 4, 6, 7, 9, 11, 13, 15, 18, 21, 23, 26, 29

    .org 0xF100
melody:
    .db 60,6, 62,6, 64,6, 65,6, 67,6, 69,6, 71,6, 72,12
    .db 0,3
    .db 72,6, 71,6, 69,6, 67,6, 65,6, 64,6, 62,6, 60,12
    .db 0,6
    .db 0xFF

    .org 0xF200
h_title:   .asciiz "COMPI  DEMO"
m_i1:      .asciiz "1 GRAFICOS"
m_i2:      .asciiz "2 TEXTO"
m_i3:      .asciiz "3 SONIDO"
m_i4:      .asciiz "4 ANIMACION"
m_i5:      .asciiz "5 LUCES"
m_i6:      .asciiz "6 JUEGO"
m_mark:    .asciiz ">"
h_gfx:     .asciiz "GRAFICOS"
h_snd:     .asciiz "SONIDO"
h_anim:    .asciiz "ANIMACION"
h_light:   .asciiz "LUCES"
h_game:    .asciiz "ESQUIVA  S:"
str_over:  .asciiz "GAME OVER"
str_score: .asciiz "PUNTOS:"
txt_msg:
    .db "COMPI ES UN MICRO", 10
    .db "DE 8 BITS CON ISA", 10
    .db "PROPIA. 64 KB DE", 10
    .db "RAM, OLED 128X64", 10
    .db "Y SONIDO PIEZO.", 10
    .db 10
    .db "HECHO EN ENSAMBLADOR", 0

    .org 0xF300
obarr:     .space 6
