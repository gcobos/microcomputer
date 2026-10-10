; ============================================================================
;  sisop.asm  -  "sistema operativo" del slot 0: menu de carpetas para
;  arrancar el resto de programas sin pasar por EDITAR + Cargar + cambiar a
;  EJECUTAR cada vez.
;
;  El slot 0 se carga solo al encender el aparato (ver setup() en
;  src/main.cpp) -- basta con dejarlo en EJECUTAR + CONTINUO para que este
;  menu aparezca directamente.
;
;  Los menus se montan SOLOS al arrancar: se consulta cada slot de la flash
;  (PORT_SLOT_QUERY/PORT_SLOT_INFO, ver iomap.h) y cada programa va a la
;  carpeta de su categoria (GAMES, PROGRAMS, UTILITIES, DEMOS,
;  DOCUMENTATION), con el nombre que lleva en la cabecera del slot -- los
;  pone el ensamblador con las directivas .name/.category y llegan al
;  aparato con compi_send.py. Los slots sin categoria (grabados antes de
;  existir los metadatos) van a OTHER, como "SLOT nn". Solo se ven las
;  carpetas que tienen algo, mas SETTINGS. No hay ninguna tabla que
;  mantener a mano: basta con enviar un programa para que aparezca.
;
;  Los DOS encoders mueven la seleccion (mismo sentido) -- asi se puede
;  elegir y pulsar con una sola mano: gira DATOS y pulsa DATOS para entrar
;  en una carpeta o arrancar el programa marcado (OUT a PORT_PROG_LOAD), o
;  pulsa DIRECCION para volver a las carpetas. Una carpeta con un solo
;  programa lo arranca directamente. Las listas largas se desplazan.
;
;  Ensamblar y enviar al slot 0:
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/sisop.asm
;
;  Probar sin el aparato (ver tools/slots.py para poblar la flash simulada):
;     python3 tools/slots.py --slots-dir mi_flash put programs/pong.asm
;     python3 tools/slots.py --slots-dir mi_flash put programs/sisop.asm
;     python3 tools/sim.py mi_flash/00.bin --slots-dir mi_flash --steps 2000000
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 0

    .name "SISOP"

    .category SYSTEM
    .org 0x0000

    .include "ports.asm"

; carpetas posibles (indice de carpeta "real"): 0 GAMES .. 4 DOCUMENTATION
; = categoria - 2; 5 OTHER (sin categoria); 6 SETTINGS -- esta ultima es
; especial (ver on_select/os_settings): no lista programas, entra directo
; en la vista SETTINGS (view=2).
FOLDER_OTHER    = 5
SETTINGS_FOLDER = 6
SLOTS_PER_FOLDER = 60     ; hueco de cada carpeta en fslots
LIST_ROWS        = 7      ; filas visibles de una lista (filas 1-7)
BRIGHT_STEP = 16      ; paso de brillo por detente de DATOS (0..255, 16 pasos)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL txt_clear
    MOV AL,#0
    STA [view],AL              ; 0 = carpetas, 1 = programas de una carpeta
    STA [cur_folder],AL
    STA [cur_prog],AL
    STA [list_top],AL
    CALL build_menus

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
    ; pulsa=zumbador/Bluetooth) -- ver ml_settings, mas abajo, que comparte con el resto
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
    CALL settings_sound
    CALL settings_battery

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
    CALL tm_wait
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
    LDA BL,[num_vis]
    CMP AL,BL
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

    CALL cur_fid
    CMP AL,#SETTINGS_FOLDER
    JMPZ os_settings

    MOV BX,#fcount
    ADD BX,AL
    LDA AL,[BX]
    STA [cur_folder_count],AL
    CMP AL,#1
    JMPZ os_direct          ; carpeta de un solo elemento -> saltar directo

    MOV AL,#1
    STA [view],AL
    MOV AL,#0
    STA [cur_prog],AL
    STA [list_top],AL
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
    CMP AL,#2
    JMPNZ ob_folders
    OUT (P_CFG_SAVE),AL     ; sale de SETTINGS: graba brillo/salida del sonido
                             ; (una sola vez, no en cada detente del dial)
ob_folders:
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
    LDA AL,[bv_pv]
    PUSH AH
    MOV AH,#0
    MOV DL,#100
    DIV DL                  ; DL = cociente, resto -> [bv_pv]
    STA [bv_pv],AH
    MOV DL,AL
    POP AH
bv_hd:
    MOV AL,DL
    ADD AL,#'0'
    STA [bv_buf+7],AL
    LDA AL,[bv_pv]
    PUSH AH
    MOV AH,#0
    MOV DL,#10
    DIV DL                  ; DL = cociente, resto -> [bv_pv]
    STA [bv_pv],AH
    MOV DL,AL
    POP AH
bv_td:
    MOV AL,DL
    ADD AL,#'0'
    STA [bv_buf+8],AL
    LDA AL,[bv_pv]
    ADD AL,#'0'
    STA [bv_buf+9],AL
    MOV BX,#bv_buf
    MOV CX,#0x0401
    CALL txt_puts
    RET

; --- settings_press_dat: pulsa DATOS -> alterna PORT_CFG_SOUND_EN (salida
; del sonido: 1 = zumbador, 0 = Bluetooth MIDI). Igual que arriba,
; PORT_CFG_SOUND_EN ya guarda el estado; solo hace falta invertirlo y
; redibujar la palabra BUZZER/BLUETOOTH en pantalla.
settings_press_dat:
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ spd_ret
    CMP BL,#0
    JMPNZ spd_ret           ; ya estaba pulsado -- no es un flanco nuevo

    IN  AL,(P_CFG_SOUND_EN)
    CMP AL,#1
    JMPNZ spd_on            ; Bluetooth o silencio -> zumbador (como BOOT)
    MOV AL,#0               ; zumbador -> Bluetooth
    JMP spd_apply
spd_on:
    MOV AL,#1
spd_apply:
    OUT (P_CFG_SOUND_EN),AL
    CALL redraw_settings    ; solo cambia BUZZER/BLUETOOTH -- sin parpadeo
spd_ret:
    RET

; --- get_selected_slot: sale AL = numero de slot del programa marcado
; (cur_folder/cur_prog). Solo tiene sentido en view=1.
get_selected_slot:
    CALL cur_fid
    MOV BL,#SLOTS_PER_FOLDER
    MUL BL                   ; AX = carpeta * 60
    MOV BX,#fslots
    ADD BX,AL
    ADD BH,AH
    LDA CL,[cur_prog]
    ADD BX,CL
    LDA AL,[BX]
    RET

; --- cur_fid: AL = carpeta "real" (0..6) de la marcada en la lista ------
cur_fid:
    MOV BX,#vis
    LDA CL,[cur_folder]
    ADD BX,CL
    LDA AL,[BX]
    RET

; ============================================================================
;  MONTAJE DE LOS MENUS: consulta los slots 1..59 y reparte cada programa en
;  la carpeta de su categoria (sisop, categoria SYSTEM, no sale en ninguna)
; ============================================================================
build_menus:
    MOV AL,#0
    MOV BX,#fcount
    MOV CL,#6
bm_clr:
    STA [BX],AL
    INC BX
    SUB CL,#1
    JMPNZ bm_clr
    MOV AL,#1
    STA [bm_slot],AL
bm_l:
    LDA AL,[bm_slot]
    OUT (P_SLOT_QUERY),AL
    IN  AL,(P_SLOT_QUERY)
    CMP AL,#0
    JMPZ bm_next             ; slot vacio
    IN  AL,(P_SLOT_INFO)     ; categoria
    CMP AL,#CAT_SYSTEM
    JMPZ bm_next
    CMP AL,#CAT_GAME
    JMPC bm_other            ; 0 o desconocida
    CMP AL,#(CAT_DOCS+1)
    JMPNC bm_other           ; 0xFF (sin categoria) o desconocida
    SUB AL,#CAT_GAME         ; 0..4
    JMP bm_put
bm_other:
    MOV AL,#FOLDER_OTHER
bm_put:
    STA [bm_fid],AL
    MOV BX,#fcount
    ADD BX,AL
    LDA AL,[BX]              ; posicion libre en esa carpeta
    PUSH AL
    ADD AL,#1
    STA [BX],AL
    LDA AL,[bm_fid]
    MOV BL,#SLOTS_PER_FOLDER
    MUL BL
    MOV BX,#fslots
    ADD BX,AL
    ADD BH,AH
    POP AL
    ADD BX,AL
    LDA AL,[bm_slot]
    STA [BX],AL
bm_next:
    LDA AL,[bm_slot]
    ADD AL,#1
    STA [bm_slot],AL
    CMP AL,#60
    JMPNZ bm_l
    ; carpetas visibles: las que tienen algo, en orden, y SETTINGS al final
    MOV AL,#0
    STA [num_vis],AL
    STA [bm_fid],AL
bm_v:
    MOV BX,#fcount
    LDA CL,[bm_fid]
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ bm_vnext
    LDA AL,[bm_fid]
    CALL vis_add
bm_vnext:
    LDA AL,[bm_fid]
    ADD AL,#1
    STA [bm_fid],AL
    CMP AL,#SETTINGS_FOLDER
    JMPNZ bm_v
    MOV AL,#SETTINGS_FOLDER
    CALL vis_add
    RET

vis_add:
    MOV BX,#vis
    LDA CL,[num_vis]
    ADD BX,CL
    STA [BX],AL
    LDA AL,[num_vis]
    ADD AL,#1
    STA [num_vis],AL
    RET

; ============================================================================
;  DIBUJO
; ============================================================================
redraw:
    CALL txt_clear
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
    MOV BX,#s_title
    MOV CX,#0x0008
    CALL txt_puts

    MOV AL,#0
    STA [i],AL
rdf_l:
    LDA AL,[i]
    ADD AL,#1
    MOV CH,AL                ; fila i+1
    MOV CL,#2
    LDA AL,[i]
    LDA BL,[cur_folder]
    CMP AL,BL
    JMPNZ rdf_nomark
    MOV BX,#s_mark
    JMP rdf_domark
rdf_nomark:
    MOV BX,#s_nomark
rdf_domark:
    CALL txt_puts
    PUSH CL
    PUSH CH
    MOV BX,#vis
    LDA CL,[i]
    ADD BX,CL
    LDA AL,[BX]
    SHL AL,#1
    MOV CL,AL
    MOV BX,#FOLDER_NAMES
    CALL read_ptr16
    POP CH
    POP CL
    CALL txt_puts

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    LDA BL,[num_vis]
    CMP AL,BL
    JMPNZ rdf_l
    RET

; --- redraw_programs: titulo de la carpeta y su lista, con desplazamiento
; (LIST_ROWS filas visibles); el nombre de cada programa se lee de la
; cabecera de su slot (PORT_SLOT_QUERY/PORT_SLOT_INFO) ----------------------
redraw_programs:
    CALL cur_fid
    SHL AL,#1
    MOV CL,AL
    MOV BX,#FOLDER_NAMES
    CALL read_ptr16
    MOV CX,#0x0004
    CALL txt_puts

    ; ventana: que cur_prog quede dentro de [list_top, list_top+ROWS)
    LDA AL,[cur_prog]
    LDA BL,[list_top]
    CMP AL,BL
    JMPNC rdp_t1
    STA [list_top],AL
    JMP rdp_t2
rdp_t1:
    SUB AL,BL
    CMP AL,#LIST_ROWS
    JMPC rdp_t2
    LDA AL,[cur_prog]
    SUB AL,#(LIST_ROWS-1)
    STA [list_top],AL
rdp_t2:
    MOV AL,#0
    STA [i],AL
rdp_l:
    LDA AL,[list_top]
    LDA BL,[i]
    ADD AL,BL
    STA [rd_k],AL            ; elemento de la lista
    LDA BL,[cur_folder_count]
    CMP AL,BL
    JMPNC rdp_done
    LDA AL,[i]
    ADD AL,#1
    MOV CH,AL
    MOV CL,#2
    LDA AL,[rd_k]
    LDA BL,[cur_prog]
    CMP AL,BL
    JMPNZ rdp_nomark
    MOV BX,#s_mark
    JMP rdp_domark
rdp_nomark:
    MOV BX,#s_nomark
rdp_domark:
    CALL txt_puts
    PUSH CL
    PUSH CH
    LDA AL,[cur_prog]
    PUSH AL
    LDA AL,[rd_k]
    STA [cur_prog],AL        ; get_selected_slot mira cur_prog
    CALL get_selected_slot
    STA [rd_slot],AL
    POP AL
    STA [cur_prog],AL
    POP CH
    POP CL
    LDA AL,[rd_slot]
    CALL put_slot_name
    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#LIST_ROWS
    JMPNZ rdp_l
rdp_done:
    RET

; --- put_slot_name: AL = slot -> su nombre en CH/CL ("SLOT nn" si no
; tiene) ----------------------------------------------------------------
put_slot_name:
    STA [rd_slot],AL
    OUT (P_SLOT_QUERY),AL
    MOV BX,#name_buf
    MOV DX,#(P_SLOT_INFO+1)
    PUSH CL
    MOV CL,#14
psn_l:
    IN  AL,(DX)
    STA [BX],AL
    INC BX
    INC DX
    SUB CL,#1
    JMPNZ psn_l
    POP CL
    LDA AL,[name_buf]
    CMP AL,#0
    JMPZ psn_noname
    MOV BX,#name_buf
    CALL txt_puts
    RET
psn_noname:
    MOV BX,#s_slot
    CALL txt_puts
    LDA AL,[rd_slot]
    CALL txt_put2
    RET

; --- redraw_settings: brillo (se ve/oye en la propia pantalla, sin numero
; ni barra) y el estado ON/OFF del sonido, con los controles a mano.
redraw_settings:
    MOV BX,#s_settings_title
    MOV CX,#0x0006
    CALL txt_puts

    MOV BX,#s_set_help1
    MOV CX,#0x0201
    CALL txt_puts

    MOV BX,#s_set_help2
    MOV CX,#0x0301
    CALL txt_puts

    MOV AL,#255             ; ningun valor real -> fuerza pintar el sonido
    STA [snd_shown],AL
    CALL settings_sound

    MOV BX,#s_set_back
    MOV CX,#0x0701
    CALL txt_puts
    CALL redraw_bright
    MOV AL,#253             ; ningun valor real -> fuerza pintar la bateria
    STA [bat_shown],AL
    CALL settings_battery
    RET

; --- settings_sound: "SOUND: BUZZER/BLUETOOTH" en la fila 5. Se llama en
; cada vuelta y solo repinta si cambia: asi tambien se ve el cambio hecho con
; el boton BOOT del ESP32, no solo el de pulsar DATOS aqui.
settings_sound:
    IN  AL,(P_CFG_SOUND_EN)
    LDA BL,[snd_shown]
    CMP AL,BL
    JMPZ ss_ret
    STA [snd_shown],AL
    MOV BX,#s_sound_off     ; 0 = Bluetooth
    CMP AL,#0
    JMPZ ss_puts
    MOV BX,#s_sound_mute    ; 2 = silencio
    CMP AL,#2
    JMPZ ss_puts
    MOV BX,#s_sound_on      ; 1 = zumbador
ss_puts:
    MOV CX,#0x0501
    CALL txt_puts
ss_ret:
    RET

; --- settings_battery: "BATTERY nnn%" (o USB / ---) en la fila 6 de
; SETTINGS. Se llama en cada vuelta, pero solo repinta si el valor cambia
; (el firmware lo mide cada 2 s). bat_shown: 0..100 = %, 254 = USB,
; 255 = aun sin medir.
settings_battery:
    IN  AL,(P_BAT_V)
    CMP AL,#220
    JMPC sb_pct             ; < 220 (4,40 V): bateria
    MOV AL,#254             ; red de 5 V con USB
    JMP sb_cmp
sb_pct:
    IN  AL,(P_BAT_PCT)
sb_cmp:
    LDA BL,[bat_shown]
    CMP AL,BL
    JMPZ sb_ret
    STA [bat_shown],AL
    MOV CX,#0x0601
    CMP AL,#254
    JMPZ sb_usb
    CMP AL,#255
    JMPZ sb_none
    MOV BX,#s_bat
    CALL txt_puts
    LDA AL,[bat_shown]
    CALL txt_putn
    MOV BX,#s_bat_pct
    CALL txt_puts
    RET
sb_usb:
    MOV BX,#s_bat_usb
    CALL txt_puts
    RET
sb_none:
    MOV BX,#s_bat_none
    CALL txt_puts
sb_ret:
    RET

; --- read_ptr16: BX = base de una tabla de punteros de 16 bits; CL = indice
; ya multiplicado x2 por quien llama; sale BX = el puntero de 16 bits leido
; de tabla[CL].
read_ptr16:
    ADD BX,CL
    LDA AL,[BX]
    STA [rp_lo],AL
    INC BX
    LDA AL,[BX]
    STA [rp_hi],AL
    LDA BL,[rp_lo]
    LDA BH,[rp_hi]
    RET

    .include "text.asm"
    .include "time.asm"

; ============================================================================
;  DATOS: carpetas y programas
; ============================================================================
s_title:  .asciiz "COMPI"
s_mark:   .asciiz "> "
s_nomark: .asciiz "  "

; --- textos de la vista SETTINGS (view=2) -----------------------------------
s_settings_title: .asciiz "SETTINGS"
s_set_help1:      .asciiz "TURN: BRIGHTNESS"
s_set_help2:      .asciiz "PRESS: BUZZER/BT"
s_sound_on:       .asciiz "SOUND: BUZZER   "
s_sound_off:      .asciiz "SOUND: BLUETOOTH"
s_sound_mute:     .asciiz "SOUND: OFF      "
s_set_back:       .asciiz "DIR: BACK"
s_bat:            .asciiz "BATTERY "
s_bat_pct:        .asciiz "%  "     ; borra lo que sobre de un valor mas largo
s_bat_usb:        .asciiz "BATTERY USB "
s_bat_none:       .asciiz "BATTERY --- "

; --- carpetas (indice "real" 0..6, ver FOLDER_OTHER/SETTINGS_FOLDER) ------
f0_name: .asciiz "GAMES"
f1_name: .asciiz "PROGRAMS"
f2_name: .asciiz "UTILITIES"
f3_name: .asciiz "DEMOS"
f4_name: .asciiz "DOCUMENTATION"
f5_name: .asciiz "OTHER"
f6_name: .asciiz "SETTINGS"
FOLDER_NAMES: .dw f0_name, f1_name, f2_name, f3_name, f4_name, f5_name, f6_name
s_slot:   .asciiz "SLOT "

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
bat_shown:        .space 1
snd_shown:        .space 1     ; lo que muestra la fila SOUND (ver settings_sound)     ; lo que muestra la fila BATTERY (ver settings_battery)
i:                .space 1
nb_lo:            .space 1
nb_hi:            .space 1
rp_lo:            .space 1
rp_hi:            .space 1
list_top:         .space 1     ; primera fila visible de la lista de programas
num_vis:          .space 1     ; carpetas visibles (con algo, + SETTINGS)
vis:              .space 7     ; carpeta "real" de cada fila del menu
fcount:           .space 6     ; programas en cada carpeta
bm_slot:          .space 1
bm_fid:           .space 1
rd_k:             .space 1
rd_slot:          .space 1
name_buf:         .space 15    ; nombre leido de PORT_SLOT_INFO (+ 0 final)
fslots:           .space 360   ; slots de cada carpeta: 6 x SLOTS_PER_FOLDER
