; ============================================================================
;  sisop.asm  -  "sistema operativo" del slot 0: menu de carpetas para
;  arrancar el resto de programas sin pasar por EDITAR + Cargar + cambiar a
;  EJECUTAR cada vez.
;
;  El slot 0 se carga solo al encender el aparato (ver setup() en
;  src/main.cpp) -- basta con dejarlo en EJECUTAR + CONTINUO para que este
;  menu aparezca directamente.
;
;  Cuatro carpetas (JUEGOS, PROGRAMAS, UTILIDADES, DEMOS), cada una con sus
;  programas. Los DOS encoders mueven la seleccion (mismo sentido) -- asi se
;  puede elegir y pulsar con una sola mano, sin ir de un mando al otro: gira
;  DATOS y pulsa DATOS para entrar en una carpeta o arrancar el programa
;  marcado (OUT a PORT_PROG_LOAD, 0x0640 -- ver iomap.h: carga el slot
;  entero en la RAM y reinicia la CPU, asi que este programa deja de existir
;  en cuanto el otro arranca), o gira DIRECCION y pulsa DIRECCION para volver
;  de la lista de programas a las carpetas.
;
;  Los nombres y numeros de slot de cada programa estan fijos aqui (no hay
;  forma de leer "metadatos" de un slot en la flash real, solo si esta
;  usado o no -- ver slotUsed() en spi_flash_storage.cpp): si se cambia un
;  programa de slot hay que actualizar las tablas de mas abajo a mano.
;
;  Ensamblar y enviar al slot 0:
;     python3 tools/casm.py programs/sisop.asm -o programs/sisop.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 0 programs/sisop.bin
;
;  Probar sin el aparato (ver tools/slots.py para poblar la flash simulada):
;     python3 tools/slots.py --slots-dir mi_flash put programs/pong.asm
;     python3 tools/slots.py --slots-dir mi_flash put --slot 0 programs/sisop.asm
;     python3 tools/sim.py mi_flash/00.bin --slots-dir mi_flash --steps 2000000
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 0
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_POS  = 0x0600
P_DIR_BTN  = 0x0601
P_DAT_POS  = 0x0602
P_DAT_BTN  = 0x0603
P_PROG_LOAD = 0x0640
P_CFG_BRIGHTNESS = 0x0650
P_CFG_SOUND_EN   = 0x0651

NUM_FOLDERS = 6
; "Carpeta" especial (ver on_select/os_settings): no lista programas, entra
; directo en la vista SETTINGS (view=2) -- brillo de pantalla y silenciar/
; activar el sonido, en caliente, sin salir de este menu ni cargar otro slot.
SETTINGS_FOLDER = 5
BRIGHT_STEP = 16      ; paso de brillo por detente de DATOS (0..255, 16 pasos)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV AL,#0
    STA [view],AL              ; 0 = carpetas, 1 = programas de una carpeta
    STA [cur_folder],AL
    STA [cur_prog],AL

    IN  AL,(P_DIR_POS)
    STA [dir_pos_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL

    CALL redraw

main_l:
    ; SETTINGS (view=2) tiene su propio manejo de DATOS (gira=brillo,
    ; pulsa=mute) -- ver ml_settings, mas abajo, que comparte con el resto
    ; de vistas el pulsador de DIRECCION (volver) y la espera del final.
    LDA AL,[view]
    CMP AL,#2
    JMPZ ml_settings

    ; --- encoder DIRECCION: mueve la seleccion --------------------------
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_pos_prev],CL
    CMP AL,#0
    JMPZ ml_datpos

    AND AL,#0x80
    JMPZ ml_down
    CALL move_up
    JMP ml_datpos
ml_down:
    CALL move_down

ml_datpos:
    ; --- encoder DATOS: TAMBIEN mueve la seleccion (mismo sentido que
    ; DIRECCION) -- asi se puede elegir y pulsar con una sola mano, sin
    ; tener que ir de un mando al otro para entrar/arrancar un programa ---
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_pos_prev],CL
    CMP AL,#0
    JMPZ ml_datbtn

    AND AL,#0x80
    JMPZ ml_datdown
    CALL move_up
    JMP ml_datbtn
ml_datdown:
    CALL move_down

ml_datbtn:
    ; --- pulsador DATOS: entra en la carpeta / arranca el programa ------
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ml_dirbtn
    CMP BL,#0
    JMPNZ ml_dirbtn         ; ya estaba pulsado -- no es un flanco nuevo
    CALL on_select
    JMP ml_dirbtn

ml_settings:
    CALL settings_dial_dat
    CALL settings_press_dat

ml_dirbtn:
    ; --- pulsador DIRECCION: vuelve a la lista de carpetas --------------
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ ml_wait
    CMP BL,#0
    JMPNZ ml_wait
    CALL on_back

ml_wait:
    MOV AL,#2
    CALL frame_wait
    JMP main_l

; --- move_up/move_down: cambian cur_folder (view=0) o cur_prog (view=1),
; con tope en 0 y en el numero de elementos de la lista actual (nunca dan la
; vuelta -- mas sencillo de seguir con solo 4-5 elementos por lista).
move_up:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ mu_prog
    LDA AL,[cur_folder]
    CMP AL,#0
    JMPZ mu_ret
    SUB AL,#1
    STA [cur_folder],AL
    JMP mu_redraw
mu_prog:
    LDA AL,[cur_prog]
    CMP AL,#0
    JMPZ mu_ret
    SUB AL,#1
    STA [cur_prog],AL
mu_redraw:
    CALL redraw
mu_ret:
    RET

move_down:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ md_prog
    LDA AL,[cur_folder]
    ADD AL,#1
    CMP AL,#NUM_FOLDERS
    JMPC md_store_f
    RET                     ; ya en la ultima carpeta -- sin cambios
md_store_f:
    STA [cur_folder],AL
    JMP md_redraw
md_prog:
    LDA AL,[cur_prog]
    ADD AL,#1
    LDA BL,[cur_folder_count]
    CMP AL,BL
    JMPC md_store_p
    RET                     ; ya en el ultimo programa de la carpeta
md_store_p:
    STA [cur_prog],AL
md_redraw:
    CALL redraw
    RET

; --- on_select: en carpetas, entra en la marcada -- salvo que tenga un
; unico programa (p.ej. DOCUMENTATION), en cuyo caso lo arranca de un
; tiron, sin pasar por la lista de un solo elemento (paso de mas que no
; aporta nada al ser un solo programa). En programas, arranca el marcado
; (y no vuelve -- PORT_PROG_LOAD reinicia la CPU con otro programa).
on_select:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ os_launch

    LDA AL,[cur_folder]
    CMP AL,#SETTINGS_FOLDER
    JMPZ os_settings

    MOV BL,#lo(FOLDER_COUNTS)
    MOV BH,#hi(FOLDER_COUNTS)
    LDA CL,[cur_folder]
    CALL idx_ptr
    LDA AL,[BX]
    STA [cur_folder_count],AL
    CMP AL,#1
    JMPZ os_direct          ; carpeta de un solo elemento -> saltar directo

    MOV AL,#1
    STA [view],AL
    MOV AL,#0
    STA [cur_prog],AL
    CALL redraw
    RET

os_direct:
    MOV AL,#0
    STA [cur_prog],AL

os_launch:
    CALL get_selected_slot
    OUT (P_PROG_LOAD),AL
    ; si sigue aqui, el slot estaba vacio -- no hacer nada mas (se queda en
    ; el menu tal cual, se puede seguir navegando o probar otro)
    RET

; --- os_settings: entra en la vista SETTINGS (view=2). Resincroniza los
; "prev" de DATOS a la posicion/pulsador actuales -- si no, el primer giro/
; pulsacion dentro de settings interpretaria como "delta" todo lo que el
; usuario hubiera tocado el mando mientras estaba en la lista de carpetas.
os_settings:
    MOV AL,#2
    STA [view],AL
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    CALL redraw
    RET

; --- on_back: de programas o de settings, vuelve a carpetas; de carpetas,
; no hace nada. Resincroniza dir_pos_prev al volver: en SETTINGS no se lee
; el encoder DIRECCION para nada (ver ml_settings), asi que si giro mientras
; tanto, sin esto la vuelta a la lista de carpetas interpretaria ese giro
; acumulado como un salto brusco de seleccion.
on_back:
    LDA AL,[view]
    CMP AL,#0
    JMPZ ob_ret
    MOV AL,#0
    STA [view],AL
    IN  AL,(P_DIR_POS)
    STA [dir_pos_prev],AL
    CALL redraw
ob_ret:
    RET

; --- settings_dial_dat: gira DATOS -> sube/baja PORT_CFG_BRIGHTNESS. Un paso
; de BRIGHT_STEP por CADA detente girado (igual que brillo_cal.asm), saturando
; en 0/255: antes solo se aplicaba un paso por fotograma aunque el encoder
; hubiera dado varios detentes. No guarda brillo aparte: PORT_CFG_BRIGHTNESS ya
; hace de "memoria" (IN devuelve el ultimo valor escrito, ver iomap.h).
settings_dial_dat:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL                   ; AL = giro de este fotograma (con signo)
    LDA CL,[tmp0]
    STA [dat_pos_prev],CL
    CMP AL,#0
    JMPZ sdd_ret

    STA [sdd_cnt],AL            ; se guarda ANTES del AND de signo (que lo destruye)
    AND AL,#0x80
    JMPNZ sdd_neg
sdd_up_l:
    CALL bright_up
    LDA AL,[sdd_cnt]
    SUB AL,#1
    STA [sdd_cnt],AL
    JMPNZ sdd_up_l
    CALL redraw_bright
    JMP sdd_ret

sdd_neg:
    LDA AL,[sdd_cnt]
    NOT AL
    ADD AL,#1                   ; AL = numero de detentes hacia abajo
    STA [sdd_cnt],AL
sdd_dn_l:
    CALL bright_down
    LDA AL,[sdd_cnt]
    SUB AL,#1
    STA [sdd_cnt],AL
    JMPNZ sdd_dn_l
    CALL redraw_bright
sdd_ret:
    RET

; --- bright_up / bright_down: un paso de BRIGHT_STEP, saturando en 255 / 0 --
bright_up:
    IN  AL,(P_CFG_BRIGHTNESS)
    ADD AL,#BRIGHT_STEP
    JMPC bu_sat
    JMP bu_apply
bu_sat:
    MOV AL,#255
bu_apply:
    OUT (P_CFG_BRIGHTNESS),AL
    RET

bright_down:
    IN  AL,(P_CFG_BRIGHTNESS)
    CMP AL,#BRIGHT_STEP
    JMPC bd_sat                 ; AL < BRIGHT_STEP -> no cabe la resta
    SUB AL,#BRIGHT_STEP
    JMP bd_apply
bd_sat:
    MOV AL,#0
bd_apply:
    OUT (P_CFG_BRIGHTNESS),AL
    RET

; --- redraw_bright: "BRIGHT nnn" en la fila 4 de SETTINGS, con el valor REAL
; leido de PORT_CFG_BRIGHTNESS -- se ve si el valor cambia aunque la pantalla
; apenas lo refleje.
redraw_bright:
    IN  AL,(P_CFG_BRIGHTNESS)
    STA [bv_pv],AL
    MOV DL,#0
bv_h:
    LDA AL,[bv_pv]
    CMP AL,#100
    JMPC bv_hd
    SUB AL,#100
    STA [bv_pv],AL
    ADD DL,#1
    JMP bv_h
bv_hd:
    MOV AL,DL
    ADD AL,#'0'
    STA [bv_buf+7],AL
    MOV DL,#0
bv_t:
    LDA AL,[bv_pv]
    CMP AL,#10
    JMPC bv_td
    SUB AL,#10
    STA [bv_pv],AL
    ADD DL,#1
    JMP bv_t
bv_td:
    MOV AL,DL
    ADD AL,#'0'
    STA [bv_buf+8],AL
    LDA AL,[bv_pv]
    ADD AL,#'0'
    STA [bv_buf+9],AL
    MOV BL,#lo(bv_buf)
    MOV BH,#hi(bv_buf)
    MOV CL,#1
    MOV CH,#4
    CALL puts
    RET

; --- settings_press_dat: pulsa DATOS -> alterna PORT_CFG_SOUND_EN (activa/
; silencia). Igual que arriba, PORT_CFG_SOUND_EN ya guarda el estado; solo
; hace falta invertirlo y redibujar la palabra ON/OFF en pantalla.
settings_press_dat:
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ spd_ret
    CMP BL,#0
    JMPNZ spd_ret           ; ya estaba pulsado -- no es un flanco nuevo

    IN  AL,(P_CFG_SOUND_EN)
    CMP AL,#0
    JMPZ spd_on
    MOV AL,#0
    JMP spd_apply
spd_on:
    MOV AL,#1
spd_apply:
    OUT (P_CFG_SOUND_EN),AL
    CALL redraw_settings    ; solo la palabra ON/OFF cambia -- sin parpadeo
spd_ret:
    RET

; --- get_selected_slot: sale AL = numero de slot del programa marcado
; (cur_folder/cur_prog). Solo tiene sentido en view=1.
get_selected_slot:
    MOV BL,#lo(FOLDER_SLOT_TABLES)
    MOV BH,#hi(FOLDER_SLOT_TABLES)
    LDA AL,[cur_folder]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16         ; BX = tabla de slots de esta carpeta
    LDA CL,[cur_prog]
    CALL idx_ptr            ; BX += cur_prog (1 byte por slot)
    LDA AL,[BX]
    RET

; ============================================================================
;  DIBUJO
; ============================================================================
redraw:
    CALL clst
    LDA AL,[view]
    CMP AL,#0
    JMPNZ rd_1
    CALL redraw_folders
    RET
rd_1:
    CMP AL,#1
    JMPNZ rd_settings
    CALL redraw_programs
    RET
rd_settings:
    CALL redraw_settings
    RET

redraw_folders:
    MOV BL,#lo(s_title)
    MOV BH,#hi(s_title)
    MOV CL,#5
    MOV CH,#0
    CALL puts

    MOV AL,#0
    STA [i],AL
rdf_l:
    LDA AL,[i]
    LDA BL,[cur_folder]
    CMP AL,BL
    JMPNZ rdf_nomark
    MOV BL,#lo(s_mark)
    MOV BH,#hi(s_mark)
    JMP rdf_domark
rdf_nomark:
    MOV BL,#lo(s_nomark)
    MOV BH,#hi(s_nomark)
rdf_domark:
    MOV CL,#2
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    MOV BL,#lo(FOLDER_NAMES)
    MOV BH,#hi(FOLDER_NAMES)
    LDA AL,[i]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16
    MOV CL,#4
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NUM_FOLDERS
    JMPNZ rdf_l
    RET

redraw_programs:
    MOV BL,#lo(FOLDER_NAMES)
    MOV BH,#hi(FOLDER_NAMES)
    LDA AL,[cur_folder]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16
    MOV CL,#5
    MOV CH,#0
    CALL puts

    MOV BL,#lo(FOLDER_NAME_TABLES)
    MOV BH,#hi(FOLDER_NAME_TABLES)
    LDA AL,[cur_folder]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16
    MOV AL,BL
    STA [nb_lo],AL
    MOV AL,BH
    STA [nb_hi],AL

    MOV AL,#0
    STA [i],AL
rdp_l:
    LDA AL,[i]
    LDA BL,[cur_folder_count]
    CMP AL,BL
    JMPNC rdp_done

    LDA AL,[i]
    LDA BL,[cur_prog]
    CMP AL,BL
    JMPNZ rdp_nomark
    MOV BL,#lo(s_mark)
    MOV BH,#hi(s_mark)
    JMP rdp_domark
rdp_nomark:
    MOV BL,#lo(s_nomark)
    MOV BH,#hi(s_nomark)
rdp_domark:
    MOV CL,#2
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    LDA AL,[i]
    SHL AL,#1
    MOV CL,AL
    LDA BL,[nb_lo]
    LDA BH,[nb_hi]
    CALL read_ptr16
    MOV CL,#4
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    JMP rdp_l
rdp_done:
    RET

; --- redraw_settings: brillo (se ve/oye en la propia pantalla, sin numero
; ni barra) y el estado ON/OFF del sonido, con los controles a mano.
redraw_settings:
    MOV BL,#lo(s_settings_title)
    MOV BH,#hi(s_settings_title)
    MOV CL,#6
    MOV CH,#0
    CALL puts

    MOV BL,#lo(s_set_help1)
    MOV BH,#hi(s_set_help1)
    MOV CL,#1
    MOV CH,#2
    CALL puts

    MOV BL,#lo(s_set_help2)
    MOV BH,#hi(s_set_help2)
    MOV CL,#1
    MOV CH,#3
    CALL puts

    IN  AL,(P_CFG_SOUND_EN)
    CMP AL,#0
    JMPZ rs_snd_off
    MOV BL,#lo(s_sound_on)
    MOV BH,#hi(s_sound_on)
    JMP rs_snd_puts
rs_snd_off:
    MOV BL,#lo(s_sound_off)
    MOV BH,#hi(s_sound_off)
rs_snd_puts:
    MOV CL,#1
    MOV CH,#5
    CALL puts

    MOV BL,#lo(s_set_back)
    MOV BH,#hi(s_set_back)
    MOV CL,#1
    MOV CH,#7
    CALL puts
    CALL redraw_bright
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
; solo altera AL/DL/DH (y BL/BH, que ya no hacen falta al terminar).
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

; --- idx_ptr: BX += CL (con acarreo a BH) -----------------------------------
idx_ptr:
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
    RET

; --- read_ptr16: BX = base de una tabla de punteros de 16 bits; CL = indice
; ya multiplicado x2 por quien llama; sale BX = el puntero de 16 bits leido
; de tabla[CL].
read_ptr16:
    CALL idx_ptr
    LDA AL,[BX]
    STA [rp_lo],AL
    ADD BL,#1
    JMPNC rp_c1
    ADD BH,#1
rp_c1:
    LDA AL,[BX]
    STA [rp_hi],AL
    LDA BL,[rp_lo]
    LDA BH,[rp_hi]
    RET

; --- frame_wait: espera N*8 ms con el temporizador 3 -------------------------
frame_wait:
    OUT (0x0623),AL
fw_l:
    IN  AL,(0x0623)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- clst: limpia la rejilla de texto entera (0x0400-0x04FF, DL envuelve) ---
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
;  DATOS: carpetas y programas
; ============================================================================
s_title:  .asciiz "COMPI"
s_mark:   .asciiz "> "
s_nomark: .asciiz "  "

; --- textos de la vista SETTINGS (view=2) -----------------------------------
s_settings_title: .asciiz "SETTINGS"
s_set_help1:      .asciiz "TURN: BRIGHTNESS"
s_set_help2:      .asciiz "PRESS: MUTE SOUND"
s_sound_on:       .asciiz "SOUND: ON "
s_sound_off:      .asciiz "SOUND: OFF"
s_set_back:       .asciiz "DIR: BACK"

; --- carpeta 0: JUEGOS ------------------------------------------------------
f0_name: .asciiz "GAMES"
f0_n0:   .asciiz "PONG"
f0_n1:   .asciiz "F-ZERO"
f0_n2:   .asciiz "RAYCAST"
f0_n3:   .asciiz "SHAMUS"
f0_n4:   .asciiz "DODGE"
f0_n5:   .asciiz "SKATE"
F0_SLOTS: .db 2, 7, 9, 13, 4, 20
F0_NAMES: .dw f0_n0, f0_n1, f0_n2, f0_n3, f0_n4, f0_n5

; --- carpeta 1: PROGRAMAS ---------------------------------------------------
f1_name: .asciiz "PROGRAMS"
f1_n0:   .asciiz "CALCULATOR"
f1_n1:   .asciiz "CLOCK"
F1_SLOTS: .db 10, 1
F1_NAMES: .dw f1_n0, f1_n1

; --- carpeta 2: UTILIDADES --------------------------------------------------
; TEXT ATTRIBUTES (atributos.asm, slot 6) se quito de aqui: sus atributos de
; formato ahora se ven tambien en CHARACTER MAP (chars.asm, mas completo en
; el propio atributos.asm si hiciera falta, pero ya no esta en este menu).
f2_name: .asciiz "UTILITIES"
f2_n0:   .asciiz "BENCHMARK"
f2_n1:   .asciiz "ROTARY ENCODERS"
f2_n2:   .asciiz "BLINK LED"
f2_n3:   .asciiz "CHARACTER MAP"
F2_SLOTS: .db 57, 14, 11, 15
F2_NAMES: .dw f2_n0, f2_n1, f2_n2, f2_n3

; --- carpeta 3: DEMOS --------------------------------------------------------
; DEMO MENU (demo.asm, slot 4) se quito de aqui: se dividio en DODGE
; (carpeta GAMES) y CHARACTER MAP (carpeta UTILITIES).
f3_name: .asciiz "DEMOS"
f3_n0:   .asciiz "CUBE 3D"
f3_n1:   .asciiz "STARS"
f3_n2:   .asciiz "MUSIC"
f3_n3:   .asciiz "CHESSBOARD"
f3_n4:   .asciiz "IMAGE"
f3_n5:   .asciiz "BIRD FLOCK"
F3_SLOTS: .db 3, 5, 8, 12, 18, 19
F3_NAMES: .dw f3_n0, f3_n1, f3_n2, f3_n3, f3_n4, f3_n5

; --- carpeta 4: DOCUMENTATION -------------------------------------------------
; Un solo programa (docs.asm, slot 16 -- visor de la documentacion del
; aparato con su propia navegacion interna por temas/paginas). Carpeta de
; un unico elemento a proposito, para que "DOCUMENTATION" sea visible
; directamente en el menu principal en vez de quedar escondida dentro de
; UTILIDADES.
f4_name: .asciiz "DOCUMENTATION"
f4_n0:   .asciiz "OPEN"
F4_SLOTS: .db 16
F4_NAMES: .dw f4_n0

; --- carpeta 5: SETTINGS -----------------------------------------------------
; Especial: on_select la intercepta ANTES de llegar aqui (ver SETTINGS_FOLDER/
; os_settings) y entra directo en la vista view=2 en vez de listar programas,
; asi que estas 3 tablas nunca se leen de verdad -- se rellenan igual para
; que FOLDER_NAMES (que si se usa, en redraw_folders) tenga sus NUM_FOLDERS
; entradas parejas con el resto.
f5_name: .asciiz "SETTINGS"
f5_n0:   .asciiz "OPEN"
F5_SLOTS: .db 0
F5_NAMES: .dw f5_n0

; --- tablas de nivel superior (indexadas por numero de carpeta 0..5) --------
FOLDER_NAMES:       .dw f0_name, f1_name, f2_name, f3_name, f4_name, f5_name
FOLDER_COUNTS:      .db 6, 2, 4, 6, 1, 1
FOLDER_SLOT_TABLES: .dw F0_SLOTS, F1_SLOTS, F2_SLOTS, F3_SLOTS, F4_SLOTS, F5_SLOTS
FOLDER_NAME_TABLES: .dw F0_NAMES, F1_NAMES, F2_NAMES, F3_NAMES, F4_NAMES, F5_NAMES

; ============================================================================
;  VARIABLES
; ============================================================================
view:             .space 1
cur_folder:       .space 1
cur_prog:         .space 1
cur_folder_count: .space 1
dir_pos_prev:     .space 1
dat_pos_prev:     .space 1
dat_btn_prev:     .space 1
dir_btn_prev:     .space 1
tmp0:             .space 1
sdd_cnt:          .space 1     ; detentes pendientes de settings_dial_dat
bv_pv:            .space 1
bv_buf:           .asciiz "BRIGHT 000"
i:                .space 1
nb_lo:            .space 1
nb_hi:            .space 1
rp_lo:            .space 1
rp_hi:            .space 1
