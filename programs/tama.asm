; ============================================================================
;  tama.asm  -  mascota virtual al estilo del Tamagotchi original (compi)
;
;  Un huevo que eclosiona y va creciendo: BEBE (1 h) -> NIÑO (1 dia) ->
;  ADOLESCENTE (2 dias) -> ADULTO, y al final de su vida vuelve a su planeta
;  en un platillo (y queda un huevo nuevo). Cada etapa tiene su cuerpo, su
;  ritmo de hambre/aburrimiento/cacas, su hora de dormir y su voz. COMO
;  EVOLUCIONA depende de como se le cuide: los "fallos de cuidado" (no
;  atenderle cuando llama con hambre o triste, dejarle la luz encendida
;  durmiendo) y la disciplina deciden en que adolescente y en que adulto se
;  convierte (6 adultos posibles, que viven mas cuanto mejor se le cuido).
;
;  Los dibujos (cuerpos, caras, efectos, iconos) estan en tama_art.py, que
;  genera tama_art.asm: los cuerpos, caras y efectos, ampliados al doble y
;  con el borde suavizado (Scale2x).
;
;  Pantalla: iconos arriba y abajo (como el original) y la mascota en medio.
;  Con la luz apagada, la zona de en medio queda rellena (no se ve la
;  mascota); si duerme, se ven sus Z.
;     COMER  LUZ  JUGAR  MEDICINA
;     BAÑO   ESTADO  REÑIR  (aviso: se enciende cuando llama)
;
;  Mandos:
;     DATOS gira / DIRECCION gira  -> elegir icono
;     DATOS pulsa                  -> hacer lo del icono (sin icono: mimarle:
;                                    lanza un corazon o guiña un ojo)
;     DIRECCION pulsa              -> volver / quitar la seleccion
;     (las pulsaciones cuentan al soltar)
;     Pulsacion LARGA de cualquiera -> quitar / poner la musica de los menus
;     En los juegos: DIRECCION = izquierda / menor, DATOS = derecha / mayor.
;     Los DOS pulsadores 8 s      -> empezar de cero con un huevo nuevo (a
;                                    los 5 s sale la cuenta atras 3, 2, 1;
;                                    soltar antes la cancela)
;
;  Juegos (JUGAR): IZQUIERDA O DERECHA (adivina adonde mirara), MAYOR O MENOR
;  (el siguiente numero) y ATRAPA (girando DATOS, coge los corazones que
;  caen). Ganar 3 de 5 (o 6 de 10 corazones) le alegra; jugar le adelgaza.
;
;  TIEMPO REAL: con la hora del aparato (Wi-Fi o el PC, puertos 0x0670..),
;  la mascota vive aunque el aparato este apagado: al volver, se simula
;  minuto a minuto lo que ha pasado (hasta 3 dias), y duerme de noche segun
;  la hora de verdad. Sin hora, solo vive mientras el programa corre.
;
;  GUARDADO: el estado (48 bytes) va a la EEPROM del slot (flash). Se mira
;  cada minuto y se graba si ha cambiado algo que importa (no los
;  contadores que corren solos, que se recalculan al cargar): asi la flash
;  no se gasta grabando cada minuto lo mismo. SIN hora real no se pueden
;  recalcular: entonces se graba el progreso cada minuto (si no, al apagar
;  el aparato el huevo volveria a empezar su cuenta).
;
;  BATERIA: pide el modo ahorro (PORT_POWER): la pantalla se apaga a los
;  10 s sin tocar nada, y espera con PORT_SLEEP en vez de dar vueltas. Si
;  llama (hambre, sueño...), enciende la pantalla y pita. Con la pantalla
;  apagada, el primer giro o pulsacion solo la enciende.
;
;  Ensamblar y enviar (slot 24):
;     python3 programs/tama_art.py           (si se tocan los dibujos)
;     python3 tools/compi.py send programs/tama.asm
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 24
    .name "TAMACOMPI"
    .category GAME
    .org 0x0000

    .include "ports.asm"

; GALERIA (temporal, para retocar los dibujos): con GALLERY = 1 el programa
; no es la mascota sino un visor de todos los cuerpos y caras. DATOS (girar
; o pulsar) = otro cuerpo, DIRECCION = otra cara. No lee ni graba el estado
; guardado. Con 0, el juego normal.
GALLERY = 0

; --- memoria -----------------------------------------------------------------
BB      = 0x6000         ; copia de la pantalla en RAM (1024 bytes)
TMP     = 0x6400         ; cuerpo + cara de la mascota (32x32, 128 bytes)

; --- etapas, modos, llamadas ---------------------------------------------------
ST_EGG   = 0
ST_BABY  = 1
ST_CHILD = 2
ST_TEEN  = 3
ST_ADULT = 4
ST_GONE  = 5

M_MAIN   = 0             ; la mascota y los iconos
M_FEED   = 1             ; menu COMIDA / CHUCHE
M_PLAY   = 2             ; menu de juegos
M_STAT   = 3             ; paginas de estado
M_LR     = 4             ; juego izquierda/derecha
M_HL     = 5             ; juego mayor/menor
M_CATCH  = 6             ; juego atrapar
M_ANIM   = 7             ; una animacion de accion
M_GONE   = 8             ; se ha ido: esperar a un huevo nuevo

CALL_HUNGER = 0x01
CALL_HAPPY  = 0x02
CALL_LIGHT  = 0x04
CALL_FAKE   = 0x08       ; capricho: reñirle ahora le disciplina
CALL_SICK   = 0x10

; animaciones (anim_kind)
A_EAT    = 0
A_SNACK  = 1
A_NO     = 2
A_FLUSH  = 3
A_MED    = 4
A_SCOLDY = 5             ; reñido con razon
A_SCOLDN = 6             ; reñido sin razon
A_HAPPY  = 7
A_EVOLVE = 8
A_HATCH  = 9
A_GONE   = 10
A_PET    = 11            ; mimos
A_SAD    = 12

; eventos que la simulacion deja a la interfaz (ev_flags)
EV_CALL   = 0x01
EV_EVOLVE = 0x02
EV_HATCH  = 0x04
EV_GONE   = 0x08
EV_SLEEP  = 0x10

PET_Y    = 22            ; fila de arriba de la mascota (32 px de alto)
CALL_MIN = 15            ; minutos de llamada antes de contar un fallo
CATCH_N  = 10            ; corazones en ATRAPA
MAX_GAP  = 4320          ; como mucho 3 dias de simulacion al volver
NORTC_SAVE = 1           ; sin hora real, guardar el progreso cada minuto
LONG_FR  = 3             ; pulsacion larga: 3 fotogramas (~0,5 - 0,8 s)
CHIRP_GAP = 255          ; fotogramas (~65 s) como minimo entre canturreos
TENSE_LO = 76             ; juegos: las dos notas de la espera (Mi5, Fa5)
TENSE_HI = 77
SNACK_MAX  = 4           ; chuches sin digerir: con 4, ya no quiere mas
SNACK_SICK = 3           ; con 3 o mas, puede dolerle la tripa despues
REACT_FR = 5             ; fotogramas de reaccion en los juegos (1 - 1,3 s)
SIG_LEN  = 24            ; bytes "importantes" del estado (ver st_begin)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    MOV AL,#GALLERY
    CMP AL,#0
    JMPNZ gallery
    MOV AL,#1
    OUT (P_POWER),AL         ; modo ahorro: pantalla fuera a los 10 s
    MOV AL,#0
    STA [mode],AL
    STA [sel],AL
    STA [snd_lo],AL
    STA [snd_hi],AL
    STA [ev_flags],AL
    STA [sec_cnt],AL
    MOV AL,#0xFF
    STA [sel],AL             ; ningun icono
    MOV AL,#4
    STA [pet_x],AL
    MOV AL,#1
    STA [scr_prev],AL
    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [lpr],AL             ; (un pulsador ya pulsado al arrancar no cuenta)
    IN  AL,(P_DAT_BTN)
    STA [lpd],AL
    CALL txt_clear
    MOV BX,#s_loading
    MOV CX,#0x0306
    CALL txt_puts
    CALL bb_clear
    CALL blit

    CALL load_state          ; o un huevo nuevo
    MOV AL,#1
    STA [quiet],AL           ; ponerse al dia sin animaciones ni sonido
    CALL clock_boot
    MOV AL,#0
    STA [quiet],AL
    STA [ev_flags],AL
    CALL save_if_changed
    CALL txt_clear

    MOV AL,#8
    OUT (P_T5),AL            ; fotograma (~256 ms)
    MOV AL,#8
    OUT (P_T7),AL            ; reloj (~1 s)
    MOV AL,#117
    OUT (P_T9),AL            ; minuto sin hora real (117 x 512 ms)
    LDA AL,[s_stage]
    CMP AL,#ST_GONE
    JMPNZ st_ok
    MOV AL,#M_GONE
    STA [mode],AL
st_ok:
    MOV BX,#ph_hello
    CALL snd_play
    MOV AL,#1
    STA [dirty],AL

; ============================================================================
;  BUCLE PRINCIPAL: dormir un poco, mandos, sonido, reloj, dibujo
; ============================================================================
main_l:
    ; esperar sin gastar: poco si hay algo en marcha, mas con la pantalla
    ; apagada y en silencio
    MOV AL,#3
    LDA BL,[snd_hi]
    OR  BL,[snd_lo]
    JMPNZ ml_sleep
    LDA BL,[mode]
    CMP BL,#M_CATCH
    JMPZ ml_sleep
    MOV AL,#5
    LDA BL,[scr_on]
    CMP BL,#0
    JMPNZ ml_sleep
    MOV AL,#25
ml_sleep:
    OUT (P_SLEEP),AL

    CALL read_input
    CALL reset_check
    CALL handle_input
    CALL snd_tick
    CALL clock_tick
    CALL handle_events

    IN  AL,(P_T5)
    CMP AL,#0
    JMPNZ ml_draw
    LDA AL,[frame_per]
    CMP AL,#0
    JMPNZ ml_fp
    MOV AL,#8
ml_fp:
    OUT (P_T5),AL
    CALL frame_tick          ; animacion: un paso
    MOV AL,#1
    STA [dirty],AL
ml_draw:
    LDA AL,[dirty]
    CMP AL,#0
    JMPZ main_l
    LDA AL,[scr_on]
    CMP AL,#0
    JMPZ main_l              ; pantalla apagada: no se dibuja
    MOV AL,#0
    STA [dirty],AL
    CALL render
    JMP main_l

; ============================================================================
;  GALERIA (GALLERY = 1): todos los cuerpos y caras, para retocarlos
; ============================================================================
gallery:
    MOV AL,#0
    OUT (P_POWER),AL         ; sin ahorro: la pantalla no se apaga
    STA [gal_form],AL
    STA [mode],AL
    MOV AL,#FACE_NORMAL
    STA [gal_face],AL
    MOV AL,#1
    STA [scr_on],AL
    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [lpr],AL
    IN  AL,(P_DAT_BTN)
    STA [lpd],AL
    MOV AL,#8
    OUT (P_T5),AL
gal_l:
    MOV AL,#3
    OUT (P_SLEEP),AL
    CALL read_input
    ; DATOS: cuerpo +-1 (pulsar = +1)
    LDA AL,[in_dat]
    LDA BL,[in_datp]
    ADD AL,BL
    LDA CL,[gal_form]
    MOV DL,#FORM_COUNT
    CALL gal_step
    STA [gal_form],CL
    ; DIRECCION: cara +-1
    LDA AL,[in_dir]
    LDA BL,[in_dirp]
    ADD AL,BL
    LDA CL,[gal_face]
    MOV DL,#FACE_COUNT
    CALL gal_step
    STA [gal_face],CL
    ; un fotograma cada ~256 ms (botecito), o al cambiar algo
    IN  AL,(P_T5)
    CMP AL,#0
    JMPNZ gal_chk
    MOV AL,#8
    OUT (P_T5),AL
    LDA AL,[tick]
    ADD AL,#1
    STA [tick],AL
    MOV AL,#1
    STA [dirty],AL
gal_chk:
    LDA AL,[dirty]
    CMP AL,#0
    JMPZ gal_l
    MOV AL,#0
    STA [dirty],AL
    CALL bb_clear
    LDA AL,[gal_form]
    STA [cur_form],AL
    LDA AL,[gal_face]
    LDA BL,[tick]
    AND BL,#1
    MOV CL,#6
    MOV CH,#18
    CALL draw_body
    CALL blit
    CALL txt_clear
    LDA AL,[gal_form]
    MOV BX,#BODY_NAMES
    CALL gal_name
    MOV CX,#0x0000
    CALL txt_puts
    LDA AL,[gal_form]
    ADD AL,#1
    MOV CX,#0x0012
    CALL txt_put2
    LDA AL,[gal_face]
    MOV BX,#FACE_NAMES
    CALL gal_name
    MOV CX,#0x0700
    CALL txt_puts
    LDA AL,[gal_face]
    ADD AL,#1
    MOV CX,#0x0712
    CALL txt_put2
    JMP gal_l

; AL = cuanto mover (con signo), CL = valor, DL = cuantos hay -> CL, con
; vuelta; si AL /= 0, marca para repintar
gal_step:
    CMP AL,#0
    JMPZ gst_ret
    PUSH AL
    MOV AL,#1
    STA [dirty],AL
    POP AL
    JMPN gst_dn
gst_up:
    ADD CL,#1
    CMP CL,DL
    JMPNZ gst_u2
    MOV CL,#0
gst_u2:
    SUB AL,#1
    JMPNZ gst_up
    RET
gst_dn:
    CMP CL,#0
    JMPNZ gst_d2
    MOV CL,DL
gst_d2:
    SUB CL,#1
    ADD AL,#1
    JMPNZ gst_dn
gst_ret:
    RET

; AL = indice, BX = tabla de cadenas (.dw) -> BX = la cadena
gal_name:
    SHL AL
    ADD BX,AL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    RET

; ============================================================================
;  ENTRADA
; ============================================================================
; --- read_input: deja in_dat/in_dir (giro con signo) e in_datp/in_dirp
; (1 = se acaba de pulsar). Si la pantalla estaba apagada, ese toque solo
; la enciende: se descarta. -------------------------------------------------
read_input:
    IN  AL,(P_DAT_POS)
    LDA BL,[dat_prev]
    STA [dat_prev],AL
    SUB AL,BL
    STA [in_dat],AL
    IN  AL,(P_DIR_POS)
    LDA BL,[dir_prev]
    STA [dir_prev],AL
    SUB AL,BL
    STA [in_dir],AL
    ; pulsadores: la pulsacion CORTA cuenta al SOLTAR (si no llego a larga);
    ; la LARGA (LONG_FR fotogramas, ver long_check) alterna la musica del menu
    IN  AL,(P_DAT_BTN)
    MOV BX,#lpd
    CALL btn_read
    STA [in_datp],CL
    IN  AL,(P_DIR_BTN)
    MOV BX,#lpr
    CALL btn_read
    STA [in_dirp],CL
    ; pantalla: encendida ahora? (bit 1 de PORT_POWER)
    IN  AL,(P_POWER)
    SHR AL
    AND AL,#1
    LDA BL,[scr_on]
    STA [scr_on],AL
    CMP AL,#0
    JMPNZ ri_on
    ; apagada: si se acaba de apagar, la cancion de los iconos vuelve al
    ; principio y se quita la seleccion (al volver se empieza de cero)
    CMP BL,#0
    JMPZ ri_ret
    MOV AL,#0
    STA [song_i],AL
    MOV AL,#0xFF
    STA [sel],AL
    RET
ri_on:
    CMP BL,#0
    JMPNZ ri_ret
    ; se acaba de encender: el toque no cuenta (ni como larga), y a repintar
    MOV AL,#0
    STA [in_dat],AL
    STA [in_dir],AL
    STA [in_datp],AL
    STA [in_dirp],AL
    CALL btn_cancel
    MOV AL,#1
    STA [dirty],AL
ri_ret:
    RET

; --- reset_check: los dos pulsadores a la vez 8 s -> huevo nuevo. Cuenta con
; T8 (256 ms/paso: 32 pasos = 8,2 s); solo los 3 ultimos segundos enseña la
; cuenta atras (3, 2, 1) en la fila 3
reset_check:
    LDA AL,[lpd]             ; (nivel actual de los dos pulsadores)
    LDA BL,[lpr]
    CMP AL,#0
    JMPZ rs_off
    CMP BL,#0
    JMPZ rs_off
    LDA AL,[rst_on]
    CMP AL,#0
    JMPNZ rs_held
    MOV AL,#1                ; acaban de pulsarse los dos
    STA [rst_on],AL
    MOV AL,#0
    STA [rst_num],AL
    MOV AL,#32
    OUT (P_T8),AL
    RET
rs_held:
    PUSH AL
    CALL btn_cancel          ; los dos a la vez: ni corta ni larga
    POP AL
    CMP AL,#2
    JMPZ rs_ret              ; ya hecho: esperar a que se suelten
    ; mientras se mantienen, ningun otro mando cuenta
    MOV AL,#0
    STA [in_dat],AL
    STA [in_dir],AL
    STA [in_datp],AL
    STA [in_dirp],AL
    IN  AL,(P_T8)
    CMP AL,#0
    JMPZ rs_do
    CMP AL,#13
    JMPNC rs_ret             ; los primeros 5 s, ninguna señal (quedan 13 x 256 ms)
    ; "RESET IN n" (segundos que quedan, redondeando hacia arriba)
    ADD AL,#3
    SHR AL,#2
    LDA BL,[rst_num]
    CMP AL,BL
    JMPZ rs_ret              ; el mismo numero: no reescribir (sin parpadeo)
    STA [rst_num],AL
    PUSH AL
    MOV CH,#3
    CALL txt_clear_row
    MOV BX,#s_reset
    MOV CX,#0x0305
    CALL txt_puts
    POP AL
    ADD AL,#'0'
    CALL txt_putc
    MOV AL,#1
    MOV CH,#3
    CALL txt_attr_row        ; en inverso
rs_ret:
    RET
rs_do:
    MOV AL,#2
    STA [rst_on],AL
    CALL new_pet             ; generacion + 1
    CALL clock_now_reset
    CALL save_state
    CALL txt_clear
    MOV AL,#M_MAIN
    STA [mode],AL
    MOV AL,#8
    STA [frame_per],AL
    MOV AL,#0xFF
    STA [sel],AL
    MOV AL,#1
    STA [dirty],AL
    MOV BX,#ph_hatch
    JMP snd_play
rs_off:
    LDA AL,[rst_on]
    CMP AL,#0
    JMPZ rs_ret
    MOV AL,#0                ; soltados: se cancela (o ya se hizo)
    STA [rst_on],AL
    CALL txt_clear
    MOV AL,#1
    STA [dirty],AL
    RET

; --- btn_read: AL = nivel del pulsador, BX = su estado (lp*: anterior,
; fase, fotogramas). Devuelve CL = 1 si se acaba de soltar tras una pulsacion
; corta. Fase: 0 suelto, 1 pulsado (contando), 2 ya fue larga o se anulo.
btn_read:
    MOV CL,#0
    LDA AH,[BX]              ; nivel anterior
    STA [BX],AL
    INC BX                   ; -> fase
    CMP AL,#0
    JMPZ br_up
    CMP AH,#0
    JMPNZ br_ret             ; sigue pulsado
    MOV AL,#1                ; se acaba de pulsar: a contar
    STA [BX],AL
    INC BX
    MOV AL,#0
    STA [BX],AL
    RET
br_up:
    CMP AH,#0
    JMPZ br_ret              ; sigue suelto
    LDA AL,[BX]
    CMP AL,#1
    JMPNZ br_clr
    MOV CL,#1                ; soltado antes de ser larga: pulsacion corta
br_clr:
    MOV AL,#0
    STA [BX],AL
br_ret:
    RET

; --- btn_cancel: lo que se este pulsando ya no cuenta (ni corta ni larga)
btn_cancel:
    LDA AL,[lpd_st]
    CMP AL,#0
    JMPZ bc_r
    MOV AL,#2
    STA [lpd_st],AL
bc_r:
    LDA AL,[lpr_st]
    CMP AL,#0
    JMPZ bc_ret
    MOV AL,#2
    STA [lpr_st],AL
bc_ret:
    RET

; --- long_check (cada fotograma): un pulsador mantenido LONG_FR fotogramas
; es una pulsacion larga: musica del menu si / no ----------------------------
long_check:
    MOV BX,#lpd_st
    CALL lc_one
    MOV BX,#lpr_st
lc_one:
    LDA AL,[BX]
    CMP AL,#1
    JMPNZ lc_ret
    INC BX
    LDA AL,[BX]
    ADD AL,#1
    STA [BX],AL
    CMP AL,#LONG_FR
    JMPNZ lc_ret
    DEC BX
    MOV AL,#2
    STA [BX],AL
    JMP music_toggle
lc_ret:
    RET

; --- music_toggle: quita / pone la musica de los menus (se guarda) --------
music_toggle:
    LDA AL,[s_music]
    CMP AL,#0
    MOV AL,#1                ; estaba puesta -> quitarla
    JMPZ mt_set
    MOV AL,#0
mt_set:
    STA [s_music],AL
    MOV BX,#ph_moff
    MOV DX,#s_moff
    CMP AL,#0
    JMPNZ mt_s
    MOV BX,#ph_mon
    MOV DX,#s_mon
mt_s:
    PUSH DL
    PUSH DH
    CALL snd_play
    POP DH
    POP DL
    ; el aviso, un momento, en la vista normal
    LDA AL,[mode]
    CMP AL,#M_MAIN
    JMPNZ mt_ret
    MOV BL,DL
    MOV BH,DH
    PUSH BL
    PUSH BH
    MOV CH,#3
    CALL txt_clear_row
    POP BH
    POP BL
    MOV CX,#0x0306
    CALL txt_puts
    MOV AL,#1
    MOV CH,#3
    CALL txt_attr_row
    MOV AL,#6                ; ~1,5 s
    STA [msg_t],AL
mt_ret:
    RET

; --- handle_input: segun el modo ---------------------------------------------
handle_input:
    LDA AL,[in_dat]
    OR  AL,[in_dir]
    OR  AL,[in_datp]
    OR  AL,[in_dirp]
    JMPZ hi_ret
    MOV AL,#1
    STA [dirty],AL
    LDA AL,[mode]
    CMP AL,#M_MAIN
    JMPZ in_main
    CMP AL,#M_FEED
    JMPZ in_menu
    CMP AL,#M_PLAY
    JMPZ in_menu
    CMP AL,#M_STAT
    JMPZ in_stat
    CMP AL,#M_LR
    JMPZ in_lr
    CMP AL,#M_HL
    JMPZ in_hl
    CMP AL,#M_CATCH
    JMPZ in_catch
    CMP AL,#M_GONE
    JMPZ in_gone
hi_ret:
    RET

; --- MAIN: elegir icono / hacer / mimar ---------------------------------------
in_main:
    LDA AL,[in_dat]
    ADD AL,[in_dir]
    CMP AL,#0
    JMPZ im_btn
    JMPN im_back
    ; un icono por detente (si se gira rapido, llegan varios a la vez)
im_fwd:
    PUSH AL
    CALL sel_next
    POP AL
    SUB AL,#1
    JMPNZ im_fwd
    JMP im_click
im_back:
    PUSH AL
    CALL sel_prev
    POP AL
    ADD AL,#1
    JMPNZ im_back
im_click:
    CALL menu_note
im_btn:
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPZ im_dat
    MOV AL,#0xFF
    STA [sel],AL
im_dat:
    LDA AL,[in_datp]
    CMP AL,#0
    JMPZ im_ret
    LDA AL,[sel]
    CMP AL,#0xFF
    JMPZ im_pet
    JMP do_action
im_pet:
    LDA AL,[s_stage]
    CMP AL,#ST_EGG
    JMPZ im_ret
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPNZ im_ret
    ; mimos: a veces lanza un corazon y a veces guiña un ojo (al azar)
    IN  AL,(P_RANDOM)
    AND AL,#1
    STA [pet_wink],AL
    MOV AL,#A_PET
    JMP anim_start
im_ret:
    RET

; seleccion: 0xFF (ninguno) -> 0 -> ... -> 6 -> 0xFF
sel_next:
    LDA AL,[sel]
    ADD AL,#1
    CMP AL,#7
    JMPNZ sn_set
    MOV AL,#0xFF
sn_set:
    STA [sel],AL
    RET
sel_prev:
    LDA AL,[sel]
    CMP AL,#0xFF
    JMPNZ sp_dec
    MOV AL,#7
sp_dec:
    SUB AL,#1
    CMP AL,#0xFF
    JMPNZ sn_set
    MOV AL,#0xFF
    JMP sn_set

; --- menus (COMIDA, JUEGOS): girar elige, DATOS confirma, DIRECCION vuelve -
in_menu:
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPNZ to_main
    LDA AL,[in_dat]
    ADD AL,[in_dir]
    CMP AL,#0
    JMPZ imn_btn
    LDA BL,[menu_n]
    LDA CL,[menu_i]
    JMPN imn_up
imn_fwd:
    ADD CL,#1
    CMP CL,BL
    JMPNZ imn_f2
    MOV CL,#0
imn_f2:
    SUB AL,#1
    JMPNZ imn_fwd
    JMP imn_set
imn_up:
    CMP CL,#0
    JMPNZ imn_dec
    MOV CL,BL
imn_dec:
    SUB CL,#1
    ADD AL,#1
    JMPNZ imn_up
imn_set:
    STA [menu_i],CL
    CALL ui_click            ; (la cancion, solo en los iconos)
imn_btn:
    LDA AL,[in_datp]
    CMP AL,#0
    JMPZ imn_ret
    LDA AL,[mode]
    CMP AL,#M_FEED
    JMPZ feed_go
    JMP play_go
imn_ret:
    RET

to_main:
    CALL txt_clear
    MOV AL,#8
    STA [frame_per],AL
    MOV AL,#M_MAIN
    LDA BL,[s_stage]
    CMP BL,#ST_GONE
    JMPNZ tm_set
    MOV AL,#M_GONE           ; se fue mientras jugaba
tm_set:
    STA [mode],AL
    RET

; --- ESTADO: cualquier giro o DATOS pasa de pagina; DIRECCION sale ---------
in_stat:
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPNZ to_main
    LDA AL,[in_dat]
    OR  AL,[in_dir]
    OR  AL,[in_datp]
    JMPZ ist_ret
    LDA AL,[page]
    ADD AL,#1
    CMP AL,#4
    JMPZ to_main
    STA [page],AL
    CALL ui_click
    CALL txt_clear
ist_ret:
    RET

; --- SE HA IDO: DATOS = huevo nuevo ---------------------------------------
in_gone:
    LDA AL,[in_datp]
    CMP AL,#0
    JMPZ ig_ret
    CALL new_pet
    CALL clock_now_reset
    CALL save_state
    CALL txt_clear
    MOV AL,#M_MAIN
    STA [mode],AL
    MOV BX,#ph_hello
    CALL snd_play
ig_ret:
    RET

; ============================================================================
;  ACCIONES (iconos)
; ============================================================================
do_action:
    ; huevo: solo ESTADO. Durmiendo: solo LUZ y ESTADO
    LDA BL,[s_stage]
    CMP BL,#ST_EGG
    JMPNZ da_awake
    CMP AL,#5
    JMPZ act_stat
    JMP act_no
da_awake:
    LDA BL,[s_sleep]
    CMP BL,#0
    JMPZ da_go
    CMP AL,#1
    JMPZ act_light
    CMP AL,#5
    JMPZ act_stat
    JMP act_no
da_go:
    CMP AL,#0
    JMPZ act_feed
    CMP AL,#1
    JMPZ act_light
    CMP AL,#2
    JMPZ act_play
    CMP AL,#3
    JMPZ act_med
    CMP AL,#4
    JMPZ act_bath
    CMP AL,#5
    JMPZ act_stat
    JMP act_scold

act_no:
    MOV BX,#ph_no
    CALL snd_play
    RET

act_feed:
    MOV AL,#M_FEED
    STA [mode],AL
    MOV AL,#0
    STA [menu_i],AL
    MOV AL,#2
    STA [menu_n],AL
    CALL txt_clear
    RET

act_play:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPZ ap_ok
    MOV AL,#A_NO             ; malito: no quiere jugar
    JMP anim_start
ap_ok:
    MOV AL,#M_PLAY
    STA [mode],AL
    MOV AL,#0
    STA [menu_i],AL
    MOV AL,#3
    STA [menu_n],AL
    CALL txt_clear
    RET

act_light:
    LDA AL,[s_lights]
    XOR AL,#1
    STA [s_lights],AL
    LDA BL,[s_call]
    AND BL,#(~CALL_LIGHT & 0xFF)
    STA [s_call],BL
    JMP ui_click

act_med:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPZ act_nosick
    SUB AL,#1
    STA [s_sick],AL
    JMPNZ am_more
    MOV AL,#0
    STA [s_sickt_lo],AL
    STA [s_sickt_hi],AL
    LDA AL,[s_call]
    AND AL,#(~CALL_SICK & 0xFF)
    STA [s_call],AL
am_more:
    MOV AL,#A_MED
    JMP anim_start
act_nosick:
    MOV AL,#A_NO
    JMP anim_start

act_bath:
    ; como en el original: se puede duchar siempre, haya caca o no (sin
    ; cacas no pasa nada: se queda impasible, ver an_flush)
    LDA AL,[s_poops]
    STA [flush_had],AL
    MOV AL,#A_FLUSH
    JMP anim_start

act_stat:
    MOV AL,#M_STAT
    STA [mode],AL
    MOV AL,#0
    STA [page],AL
    CALL txt_clear
    RET

act_scold:
    LDA AL,[s_call]
    AND AL,#CALL_FAKE
    JMPZ as_bad
    LDA AL,[s_call]
    AND AL,#(~CALL_FAKE & 0xFF)
    STA [s_call],AL
    LDA AL,[s_disc]
    CMP AL,#4
    JMPZ as_y
    ADD AL,#1
    STA [s_disc],AL
as_y:
    MOV AL,#A_SCOLDY
    JMP anim_start
as_bad:
    CALL happy_down
    MOV AL,#A_SCOLDN
    JMP anim_start

; --- COMIDA: 0 = comida (hambre +1), 1 = chuche (alegria +1, engorda) -----
feed_go:
    CALL to_main
    LDA AL,[menu_i]
    CMP AL,#0
    JMPNZ fg_snack
    LDA AL,[s_hunger]
    CMP AL,#4
    JMPZ fg_refuse           ; lleno
    ; caprichoso si tiene poca disciplina: a veces no quiere (y entonces
    ; reñirle si le disciplina)
    LDA AL,[s_disc]
    CMP AL,#2
    JMPNC fg_eat
    IN  AL,(P_RANDOM)
    AND AL,#3
    JMPNZ fg_eat
    CALL set_fake
fg_refuse:
    MOV AL,#A_NO
    JMP anim_start
fg_eat:
    LDA AL,[s_hunger]
    ADD AL,#1
    STA [s_hunger],AL
    LDA AL,[s_call]
    AND AL,#(~CALL_HUNGER & 0xFF)
    STA [s_call],AL
    MOV AL,#1
    CALL weight_add
    MOV AL,#A_EAT
    JMP anim_start
fg_snack:
    ; con SNACK_MAX chuches sin digerir, ya no quiere mas (es el aviso). Darle
    ; chuches nunca le pone malo en el acto: el dolor de tripa, si llega,
    ; llega despues (ver sm_awake)
    LDA AL,[s_snacks]
    CMP AL,#SNACK_MAX
    JMPNC fg_refuse
    ADD AL,#1
    STA [s_snacks],AL
    CALL happy_up
    MOV AL,#2
    CALL weight_add
    MOV AL,#A_SNACK
    JMP anim_start

set_fake:
    LDA AL,[s_call]
    OR  AL,#CALL_FAKE
    STA [s_call],AL
    LDA AL,[s_callt]
    CMP AL,#0
    JMPNZ sf_ret
    MOV AL,#CALL_MIN
    STA [s_callt],AL
sf_ret:
    RET

happy_up:
    LDA AL,[s_happy]
    CMP AL,#4
    JMPZ hu_ret
    ADD AL,#1
    STA [s_happy],AL
    LDA AL,[s_call]
    AND AL,#(~CALL_HAPPY & 0xFF)
    STA [s_call],AL
hu_ret:
    RET

happy_down:
    LDA AL,[s_happy]
    CMP AL,#0
    JMPZ hd_ret
    SUB AL,#1
    STA [s_happy],AL
hd_ret:
    RET

; AL = gramos a sumar (con tope 99)
weight_add:
    LDA BL,[s_weight]
    ADD AL,BL
    CMP AL,#100
    JMPC wa_set
    MOV AL,#99
wa_set:
    STA [s_weight],AL
    RET

weight_sub1:
    LDA AL,[s_weight]
    CMP AL,#2
    JMPC ws_ret
    SUB AL,#1
    STA [s_weight],AL
ws_ret:
    RET

get_sick:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPNZ gs_ret
    MOV AL,#2                ; dos medicinas
    STA [s_sick],AL
    LDA AL,[s_call]
    OR  AL,#CALL_SICK
    STA [s_call],AL
    LDA AL,[ev_flags]
    OR  AL,#EV_CALL
    STA [ev_flags],AL
gs_ret:
    RET

; --- JUEGOS: 0 = izq/der, 1 = mayor/menor, 2 = atrapa ---------------------
play_go:
    CALL txt_clear
    MOV AL,#0
    STA [g_round],AL
    STA [g_wins],AL
    STA [g_phase],AL
    LDA AL,[menu_i]
    CMP AL,#1
    JMPZ pg_hl
    CMP AL,#2
    JMPZ pg_catch
    MOV AL,#M_LR
    STA [mode],AL
    RET
pg_hl:
    MOV AL,#M_HL
    STA [mode],AL
    CALL rnd19
    STA [g_num],AL
    RET
pg_catch:
    MOV AL,#M_CATCH
    STA [mode],AL
    MOV AL,#4
    STA [frame_per],AL       ; mas rapido
    MOV AL,#6
    STA [g_px],AL
    CALL catch_new
    RET

; ============================================================================
;  JUEGOS
; ============================================================================
; --- IZQUIERDA O DERECHA: fase 0 pregunta; fase 1 enseña (frame_tick) -------
in_lr:
    LDA AL,[g_phase]
    CMP AL,#0
    JMPNZ ilr_ret
    MOV CL,#0xFF
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPZ ilr_r
    MOV CL,#0                ; izquierda
ilr_r:
    LDA AL,[in_datp]
    CMP AL,#0
    JMPZ ilr_chk
    MOV CL,#1                ; derecha
ilr_chk:
    CMP CL,#0xFF
    JMPZ ilr_ret
    STA [g_guess],CL
    IN  AL,(P_RANDOM)
    AND AL,#1
    STA [g_num],AL           ; adonde mira
    CMP AL,CL
    CALL game_round_result   ; Z = acierto
    MOV AL,#1
    STA [g_phase],AL
    ; 4 fotogramas mirando a su lado, y REACT_FR (~1 s) de reaccion (ver rd_lr)
    MOV AL,#(4 + REACT_FR)
    STA [g_wait],AL
ilr_ret:
    RET

; --- MAYOR O MENOR ------------------------------------------------------------
in_hl:
    LDA AL,[g_phase]
    CMP AL,#0
    JMPNZ ihl_ret
    MOV CL,#0xFF
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPZ ihl_h
    MOV CL,#0                ; menor
ihl_h:
    LDA AL,[in_datp]
    CMP AL,#0
    JMPZ ihl_chk
    MOV CL,#1                ; mayor
ihl_chk:
    CMP CL,#0xFF
    JMPZ ihl_ret
    STA [g_guess],CL
ihl_new:
    CALL rnd19               ; el siguiente, distinto del actual
    LDA BL,[g_num]
    CMP AL,BL
    JMPZ ihl_new
    STA [g_next],AL
    MOV CL,#0
    CMP BL,AL                ; C = actual < siguiente: mayor
    JMPNC ihl_lo
    MOV CL,#1
ihl_lo:
    LDA AL,[g_guess]
    CMP AL,CL
    CALL game_round_result
    CALL round_sound         ; reacciona ya, con el numero a la vista
    MOV AL,#1
    STA [g_phase],AL
    MOV AL,#REACT_FR
    STA [g_wait],AL
ihl_ret:
    RET

; flags del CMP de antes: Z = acierto. Lo cuenta (g_ok, g_wins).
game_round_result:
    JMPNZ grr_lose
    LDA AL,[g_wins]
    ADD AL,#1
    STA [g_wins],AL
    MOV AL,#1
    STA [g_ok],AL
    RET
grr_lose:
    MOV AL,#0
    STA [g_ok],AL
    RET

; el sonido de la reaccion: alegre si acerto, de "no" si fallo
round_sound:
    MOV BX,#ph_yes
    LDA AL,[g_ok]
    CMP AL,#0
    JMPNZ snd_play
    MOV BX,#ph_no
    JMP snd_play

; la cara de la reaccion: sonrie si acerto; si fallo, niega con la cabeza
react_face:
    MOV AL,#FACE_HAPPY
    LDA BL,[g_ok]
    CMP BL,#0
    JMPNZ rf_ret
    LDA BL,[tick]
    AND BL,#1
    MOV AL,#FACE_LOOK_L
    JMPZ rf_ret
    MOV AL,#FACE_LOOK_R
rf_ret:
    RET

; --- ATRAPA: DATOS / DIRECCION mueven la mascota -----------------------------
in_catch:
    LDA AL,[in_dirp]
    CMP AL,#0
    JMPNZ catch_end
    LDA AL,[in_dat]
    ADD AL,[in_dir]
    CMP AL,#0
    JMPZ icc_ret
    LDA CL,[g_px]
    JMPN icc_l
    CMP CL,#12
    JMPZ icc_ret
    ADD CL,#1
    JMP icc_set
icc_l:
    CMP CL,#0
    JMPZ icc_ret
    SUB CL,#1
icc_set:
    STA [g_px],CL
icc_ret:
    RET

catch_new:
    IN  AL,(P_RANDOM)
    MOV AH,#0
    MOV BL,#15
    DIV BL
    STA [g_ix],AH            ; columna 0..14 (16 px de ancho)
    MOV AL,#8
    STA [g_iy],AL
    RET

; un paso de ATRAPA (desde frame_tick)
catch_step:
    LDA AL,[g_iy]
    ADD AL,#4
    STA [g_iy],AL
    CMP AL,#36               ; a la altura de la cabeza?
    JMPNZ cs_fall
    ; columnas del corazon: ix..ix+1; mascota: px..px+3
    LDA AL,[g_ix]
    LDA BL,[g_px]
    ADD AL,#1
    CMP AL,BL
    JMPC cs_miss             ; ix+1 < px
    SUB AL,#1
    ADD BL,#3
    CMP BL,AL
    JMPC cs_miss             ; px+3 < ix
    LDA AL,[g_wins]
    ADD AL,#1
    STA [g_wins],AL
    MOV BX,#ph_catch
    CALL snd_play
    JMP cs_next
cs_miss:
    RET
cs_fall:
    CMP AL,#48
    JMPC cs_ret
    MOV BX,#ph_drop
    CALL snd_play
cs_next:
    LDA AL,[g_round]
    ADD AL,#1
    STA [g_round],AL
    CMP AL,#CATCH_N
    JMPZ catch_end
    CALL catch_new
cs_ret:
    RET

catch_end:
    LDA AL,[g_wins]
    CMP AL,#6
    MOV AL,#0
    JMPC ce_res
    MOV AL,#1
ce_res:
    JMP game_finish

; AL = 1 si gano. Alegria +1 si gano, siempre adelgaza.
game_finish:
    PUSH AL
    CALL to_main
    CALL weight_sub1
    POP AL
    CMP AL,#0
    JMPZ gf_lose
    CALL happy_up
    MOV AL,#A_HAPPY
    JMP anim_start
gf_lose:
    MOV AL,#A_SAD
    JMP anim_start

rnd19:
    IN  AL,(P_RANDOM)
    MOV AH,#0
    MOV BL,#9
    DIV BL
    MOV AL,AH
    ADD AL,#1
    RET

; ============================================================================
;  ANIMACIONES Y FOTOGRAMAS
; ============================================================================
; AL = tipo: la arranca (modo M_ANIM) con su sonido
anim_start:
    STA [anim_kind],AL
    MOV BL,#0
    STA [anim_step],BL
    MOV BL,#M_ANIM
    STA [mode],BL
    CALL txt_clear
    LDA AL,[anim_kind]
    SHL AL
    MOV CL,AL
    MOV BX,#ANIM_SND
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    LDA AL,[anim_kind]
    CMP AL,#A_PET
    JMPNZ as_snd
    LDA AL,[pet_wink]
    CMP AL,#0
    JMPZ as_snd
    MOV BX,#ph_wink
as_snd:
    CALL snd_play
    MOV AL,#1
    STA [dirty],AL
    RET

; duracion (fotogramas) de cada animacion
ANIM_LEN: .db 10, 8, 6, 9, 6, 6, 6, 8, 14, 10, 16, 5, 6
ANIM_SND: .dw ph_eat, ph_eat, ph_no, ph_flush, ph_med, ph_sorry, ph_cry
          .dw ph_win, ph_evolve, ph_hatch, ph_gone, ph_pet, ph_sad

; --- frame_tick: un paso de animacion (cada ~256 ms; ATRAPA, ~128 ms) -----
frame_tick:
    LDA AL,[tick]
    ADD AL,#1
    STA [tick],AL
    CALL long_check
    ; el aviso de la musica se borra solo
    LDA AL,[msg_t]
    CMP AL,#0
    JMPZ ft_nomsg
    SUB AL,#1
    STA [msg_t],AL
    JMPNZ ft_nomsg
    LDA AL,[mode]
    CMP AL,#M_MAIN
    JMPNZ ft_nomsg
    MOV CH,#3
    CALL txt_clear_row
ft_nomsg:
    LDA AL,[mode]
    CMP AL,#M_ANIM
    JMPZ ft_anim
    CMP AL,#M_CATCH
    JMPZ catch_step
    CMP AL,#M_LR
    JMPZ ft_game
    CMP AL,#M_HL
    JMPZ ft_game
    CMP AL,#M_MAIN
    JMPZ idle_step
    RET

ft_game:
    LDA AL,[g_phase]
    CMP AL,#0
    JMPZ ftg_tense
    LDA AL,[g_wait]
    SUB AL,#1
    STA [g_wait],AL
    JMPZ ftg_end
    ; izq/der: tras ver adonde mira, empieza la reaccion (con su sonido)
    CMP AL,#REACT_FR
    JMPNZ ftg_ret
    LDA AL,[mode]
    CMP AL,#M_LR
    JMPZ round_sound
    RET
ftg_end:
    ; fin del enseñar: siguiente ronda, o el resultado
    MOV AL,#0
    STA [g_phase],AL
    LDA AL,[mode]
    CMP AL,#M_HL
    JMPNZ ftg_r
    LDA AL,[g_next]
    STA [g_num],AL
ftg_r:
    CALL txt_clear
    LDA AL,[g_round]
    ADD AL,#1
    STA [g_round],AL
    CMP AL,#5
    JMPNZ ftg_ret
    LDA AL,[g_wins]
    CMP AL,#3
    MOV AL,#0
    JMPC game_finish
    MOV AL,#1
    JMP game_finish
ftg_ret:
    RET
ftg_tense:
    ; esperando la eleccion: dos notas alternadas, a medio tono, de suspense
    MOV AL,#6                ; 60 ms
    OUT (P_SND_DUR),AL
    MOV AL,#TENSE_LO
    LDA BL,[tick]
    AND BL,#1
    JMPZ ftt_n
    MOV AL,#TENSE_HI
ftt_n:
    OUT (P_SND_NOTE),AL
    RET

ft_anim:
    LDA AL,[anim_step]
    ADD AL,#1
    STA [anim_step],AL
    ; a mitad de la evolucion / eclosion, cambia de verdad de cuerpo
    LDA BL,[anim_kind]
    CMP BL,#A_FLUSH
    JMPNZ fta_len
    CMP AL,#6
    JMPNZ fta_len
    MOV BL,#0
    STA [s_poops],BL
fta_len:
    MOV CL,AL
    LDA AL,[anim_kind]
    MOV BX,#ANIM_LEN
    ADD BX,AL
    LDA AL,[BX]
    CMP CL,AL
    JMPC fta_ret
    ; terminada
    LDA AL,[anim_kind]
    CMP AL,#A_GONE
    JMPZ fta_gone
    CALL to_main
fta_ret:
    RET
fta_gone:
    CALL txt_clear
    MOV AL,#M_GONE
    STA [mode],AL
    RET

; --- idle_step: la mascota a su aire (modo MAIN) --------------------------------
idle_step:
    MOV AL,#FACE_NORMAL
    STA [face],AL
    MOV AL,#0
    STA [bob],AL
    STA [jump],AL
    STA [sing],AL
    LDA AL,[chirp_cd]        ; pausa entre canturreos
    CMP AL,#0
    JMPZ is_cd
    SUB AL,#1
    STA [chirp_cd],AL
is_cd:
    LDA AL,[s_stage]
    CMP AL,#ST_EGG
    JMPZ is_egg
    CMP AL,#ST_GONE
    JMPZ is_ret
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPZ is_awake
    MOV AL,#FACE_SLEEP
    STA [face],AL
    RET
is_egg:
    LDA AL,[tick]
    AND AL,#2
    STA [bob],AL             ; se tambalea
    MOV AL,#FACE_NONE
    STA [face],AL
    RET
is_awake:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPZ is_nosick
    MOV AL,#FACE_SICK
    STA [face],AL
    LDA AL,[tick]
    AND AL,#1
    STA [bob],AL
    RET
is_nosick:
    LDA AL,[s_hunger]
    CMP AL,#0
    JMPZ is_sad
    LDA AL,[s_happy]
    CMP AL,#0
    JMPNZ is_ok
is_sad:
    MOV AL,#FACE_SAD
    STA [face],AL
    LDA AL,[tick]
    SHR AL
    AND AL,#1
    STA [bob],AL
    RET
is_ok:
    ; botecito al andar
    LDA AL,[tick]
    AND AL,#1
    STA [bob],AL
    ; parpadeo de vez en cuando
    IN  AL,(P_RANDOM)
    AND AL,#15
    JMPNZ is_nb
    MOV AL,#FACE_BLINK
    STA [face],AL
is_nb:
    ; salto de alegria de vez en cuando (si esta contento), canturreando:
    ; solo con la pantalla encendida (a oscuras, el silbido molesta)
    LDA AL,[scr_on]
    CMP AL,#0
    JMPZ is_walk
    LDA AL,[s_happy]
    CMP AL,#3
    JMPC is_walk
    IN  AL,(P_RANDOM)
    CMP AL,#12
    JMPNC is_walk
    MOV AL,#FACE_HAPPY
    STA [face],AL
    MOV AL,#6
    STA [jump],AL
    ; y, muy de vez en cuando, canturrea (con su nota): nunca antes de
    ; CHIRP_GAP fotogramas desde la ultima vez
    LDA AL,[chirp_cd]
    CMP AL,#0
    JMPNZ is_ret
    IN  AL,(P_RANDOM)
    CMP AL,#10
    JMPNC is_ret
    MOV AL,#CHIRP_GAP
    STA [chirp_cd],AL
    MOV AL,#1
    STA [sing],AL
    MOV BX,#ph_chirp
    CALL snd_play
    RET
is_walk:
    ; cada 2 fotogramas, un paso a un lado (o se queda)
    LDA AL,[tick]
    AND AL,#1
    JMPNZ is_ret
    LDA CL,[pet_x]
    IN  AL,(P_RANDOM)
    AND AL,#3
    JMPZ is_left
    CMP AL,#1
    JMPNZ is_ret
    ; derecha, sin pisar las cacas
    MOV BL,#12
    LDA AL,[s_poops]
    CMP AL,#0
    JMPZ is_rmax
    MOV BL,#8
is_rmax:
    CMP CL,BL
    JMPNC is_ret
    ADD CL,#1
    STA [pet_x],CL
    RET
is_left:
    CMP CL,#0
    JMPZ is_ret
    SUB CL,#1
    STA [pet_x],CL
is_ret:
    RET

; ============================================================================
;  DIBUJO: todo a BB (RAM) y de ahi de golpe a la pantalla, sin parpadeos
; ============================================================================
render:
    CALL bb_clear
    LDA AL,[mode]
    CMP AL,#M_MAIN
    JMPZ rn_icons
    CMP AL,#M_ANIM
    JMPNZ rn_go
rn_icons:
    CALL draw_icons          ; (en menus y juegos, filas 0 y 7 para el texto)
rn_go:
    LDA AL,[mode]
    CMP AL,#M_MAIN
    JMPZ rd_main
    CMP AL,#M_ANIM
    JMPZ rd_anim
    CMP AL,#M_FEED
    JMPZ rd_feed
    CMP AL,#M_PLAY
    JMPZ rd_play
    CMP AL,#M_STAT
    JMPZ rd_stat
    CMP AL,#M_LR
    JMPZ rd_lr
    CMP AL,#M_HL
    JMPZ rd_hl
    CMP AL,#M_CATCH
    JMPZ rd_catch
    JMP rd_gone

; dibuja BB y vuelve
rd_done:
    CALL blit
    RET

; --- MAIN -------------------------------------------------------------------
rd_main:
    ; luz apagada: la zona de en medio rellena, sin mascota ni cacas. Solo
    ; si duerme, sus Z (recortadas en oscuro sobre el relleno)
    LDA AL,[s_lights]
    CMP AL,#0
    JMPNZ rdm_light
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPZ rdm_dark
    LDA AL,[tick]
    AND AL,#2
    JMPZ rdm_dark
    MOV AL,#FX_ZZ
    MOV CL,#7
    MOV CH,#24
    CALL draw_fx
rdm_dark:
    CALL bb_invert_area
    JMP rd_done
rdm_light:
    CALL draw_poops
    CALL draw_pet_std
    ; adornos
    LDA AL,[s_stage]
    CMP AL,#ST_EGG
    JMPZ rd_done
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPZ rdm_nz
    LDA AL,[tick]
    AND AL,#2
    JMPZ rd_done
    MOV AL,#FX_ZZ
    CALL fx_above
    JMP rd_done
rdm_nz:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPZ rdm_ns
    MOV AL,#FX_SKULL
    CALL fx_above
    JMP rd_done
rdm_ns:
    LDA AL,[s_call]
    CMP AL,#0
    JMPZ rdm_j
    LDA AL,[tick]
    AND AL,#1
    JMPZ rd_done
    MOV AL,#FX_BANG
    CALL fx_above
    JMP rd_done
rdm_j:
    LDA AL,[sing]            ; la nota, solo si canturrea (no en cada salto)
    CMP AL,#0
    JMPZ rd_done
    MOV AL,#FX_NOTE
    CALL fx_above
    JMP rd_done

; AL = efecto (corazon, nota, "!", Zz...): al lado de la cabeza de la
; mascota, a la derecha (o a la izquierda si no cabe), separado de la barra
; de iconos y sobre un fondo borrado, para que se lea aunque haya algo detras
fx_above:
    LDA CL,[pet_x]
; CL = columna de la mascota
fx_beside:
    PUSH AL
    MOV AL,CL
    ADD CL,#4
    CMP CL,#15
    JMPC fa_ok
    MOV CL,AL
    SUB CL,#2
fa_ok:
    MOV CH,#12
    PUSH CL
    PUSH CH
    CALL bb_clear16
    POP CH
    POP CL
    POP AL
    JMP draw_fx

; --- bb_clear16: CL = columna, CH = fila: borra 16x16 (2 bytes x 16 filas)
bb_clear16:
    CALL bb_addr
    MOV CL,#16
    MOV AL,#0
bcl_l:
    STA [DX],AL
    INC DX
    STA [DX],AL
    ADD DX,#15
    SUB CL,#1
    JMPNZ bcl_l
    RET

; la mascota en su sitio, con su cara, botecito y salto
draw_pet_std:
    LDA AL,[face]
    LDA BL,[bob]
    AND BL,#1
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    LDA DL,[jump]
    SUB CH,DL
    JMP draw_pet

draw_poops:
    LDA AL,[s_poops]
    CMP AL,#0
    JMPZ dpo_ret
    STA [cnt],AL
    MOV AL,#0
    STA [cnt2],AL
dpo_l:
    LDA AL,[cnt2]
    SHL AL
    MOV BX,#POOP_POS
    ADD BX,AL
    LDA CL,[BX]
    INC BX
    LDA CH,[BX]
    LDA AL,[tick]
    AND AL,#2
    MOV AL,#FX_POOP
    JMPZ dpo_f
    MOV AL,#FX_POOP2
dpo_f:
    CALL draw_fx
    LDA AL,[cnt2]
    ADD AL,#1
    STA [cnt2],AL
    LDA AL,[cnt]
    SUB AL,#1
    STA [cnt],AL
    JMPNZ dpo_l
dpo_ret:
    RET
POOP_POS: .db 14, 38, 12, 38, 14, 22, 12, 22   ; (columna, fila) de cada caca

; --- animaciones de accion ----------------------------------------------------
rd_anim:
    LDA AL,[anim_kind]
    SHL AL
    MOV CL,AL
    MOV BX,#ANIM_DRAW
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    CALL BX
    JMP rd_done
ANIM_DRAW: .dw an_eat, an_snack, an_no, an_flush, an_med, an_scoldy, an_scoldn
           .dw an_happy, an_evolve, an_hatch, an_gone, an_pet, an_sad

; comer: la comida al lado, mordisco a mordisco
an_eat:
    MOV DL,#FX_MEAL
    JMP an_food
an_snack:
    MOV DL,#FX_SNACK
an_food:
    MOV AL,#3
    STA [pet_x],AL
    LDA AL,[anim_step]
    AND AL,#1
    MOV AL,#FACE_EAT
    JMPZ anf_f
    MOV AL,#FACE_NORMAL
anf_f:
    MOV BL,#0
    MOV CL,#3
    MOV CH,#PET_Y
    PUSH DL
    CALL draw_pet
    POP DL
    ; la comida mengua: entera, mordida (2 pasos), nada
    LDA AL,[anim_step]
    CMP AL,#7
    JMPNC anf_ret
    MOV AL,DL
    LDA BL,[anim_step]
    CMP BL,#3
    JMPC anf_draw
    ADD AL,#1                ; FX_MEAL2 / FX_SNACK2: mordida
anf_draw:
    MOV CL,#8
    MOV CH,#38
    CALL draw_fx
anf_ret:
    RET

; no: mira a un lado y a otro
an_no:
    LDA AL,[anim_step]
    AND AL,#1
    MOV AL,#FACE_LOOK_L
    JMPZ ann_f
    MOV AL,#FACE_LOOK_R
ann_f:
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    JMP draw_pet

; baño: una ola que barre de izquierda a derecha
an_flush:
    MOV AL,#FACE_NORMAL      ; sin cacas, impasible
    LDA BL,[flush_had]
    CMP BL,#0
    JMPZ anfl_f
    MOV AL,#FACE_HAPPY       ; con cacas, contento de verse limpio
anfl_f:
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    LDA AL,[anim_step]
    CMP AL,#6
    JMPNC anfl_w
    CALL draw_poops
anfl_w:
    LDA AL,[anim_step]
    SHL AL,#1
    MOV CL,AL
    CMP CL,#15
    JMPNC anfl_ret
    MOV CH,#22
    MOV AL,#FX_WAVE
    PUSH CL
    CALL draw_fx
    POP CL
    MOV CH,#38
    MOV AL,#FX_WAVE
    JMP draw_fx
anfl_ret:
    RET

an_med:
    MOV AL,#FACE_SICK
    LDA BL,[anim_step]
    CMP BL,#4
    JMPC anm_f
    MOV AL,#FACE_HAPPY
anm_f:
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_SYRINGE
    JMP fx_above

an_scoldy:
    MOV AL,#FACE_SAD
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_ANGER
    JMP fx_above

an_scoldn:
    MOV AL,#FACE_ANGRY
    LDA BL,[anim_step]
    AND BL,#1
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_SWEAT
    JMP fx_above

an_sad:
    MOV AL,#FACE_SAD
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_SWEAT
    JMP fx_above

; contento: salta, con corazones
an_happy:
    LDA AL,[anim_step]
    AND AL,#1
    MOV CH,#PET_Y
    JMPZ anh_up
    SUB CH,#6
anh_up:
    MOV AL,#FACE_HAPPY
    MOV BL,#0
    LDA CL,[pet_x]
    CALL draw_pet
    LDA AL,[anim_step]
    AND AL,#1
    JMPZ anh_ret
    MOV AL,#FX_HEART
    CALL fx_above
anh_ret:
    RET

an_pet:
    LDA AL,[pet_wink]
    CMP AL,#0
    JMPNZ anp_wink
    MOV AL,#FACE_HAPPY
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_HEART
    JMP fx_above
anp_wink:
    MOV AL,#FACE_WINK        ; guiño con sonrisa, y un destello
    MOV BL,#0
    LDA CL,[pet_x]
    MOV CH,#PET_Y
    CALL draw_pet
    LDA AL,[anim_step]
    AND AL,#1
    JMPNZ anp_ret
    MOV AL,#FX_SPARK
    JMP fx_above
anp_ret:
    RET

; evolucion: destellos y la pantalla parpadea
an_evolve:
an_hatch:
    LDA AL,[anim_step]
    AND AL,#1
    STA [inv],AL
    MOV AL,#FACE_HAPPY
    LDA BL,[s_stage]
    CMP BL,#ST_EGG
    JMPNZ ane_f
    MOV AL,#FACE_NONE
ane_f:
    MOV BL,#0
    MOV CL,#6
    MOV CH,#PET_Y
    CALL draw_pet
    MOV AL,#FX_SPARK
    MOV CL,#2
    LDA BL,[anim_step]
    AND BL,#2
    JMPZ ane_s
    MOV CL,#12
ane_s:
    MOV CH,#12
    CALL draw_fx
    LDA AL,[inv]
    CMP AL,#0
    JMPZ ane_ret
    CALL bb_invert_area
ane_ret:
    RET

; se va: el platillo sube
an_gone:
    LDA AL,[anim_step]
    SHL AL
    MOV BL,AL
    MOV CH,#30
    SUB CH,BL
    JMPNC ang_y
    MOV CH,#0
ang_y:
    CMP CH,#8
    JMPNC ang_d
    MOV CH,#8
ang_d:
    MOV AL,#FORM_UFO
    STA [cur_form],AL
    MOV AL,#FACE_NONE
    MOV BL,#0
    MOV CL,#6
    CALL draw_body
    RET

; --- menus ---------------------------------------------------------------------
rd_feed:
    MOV BX,#MENU_FEED
    JMP rd_menu
rd_play:
    MOV BX,#MENU_PLAY
rd_menu:
    ; BX = lista de cadenas (.dw), menu_n entradas, menu_i elegida
    STA [ptr_lo],BL
    STA [ptr_hi],BH
    MOV AL,#0
    STA [cnt],AL
rmn_l:
    LDA AL,[cnt]
    LDA BL,[menu_n]
    CMP AL,BL
    JMPNC rmn_end
    ; fila 2 + 2*i, columna 4
    SHL AL
    ADD AL,#2
    MOV CH,AL
    PUSH CH
    CALL txt_clear_row
    POP CH
    LDA AL,[cnt]
    SHL AL
    LDA BL,[ptr_lo]
    LDA BH,[ptr_hi]
    ADD BX,AL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    MOV CL,#4
    PUSH CH
    CALL txt_puts
    POP CH
    MOV AL,#0
    LDA BL,[cnt]
    LDA DL,[menu_i]
    CMP BL,DL
    JMPNZ rmn_attr
    MOV AL,#1                ; inverso
rmn_attr:
    CALL txt_attr_row
    LDA AL,[cnt]
    ADD AL,#1
    STA [cnt],AL
    JMP rmn_l
rmn_end:
    JMP rd_done
MENU_FEED: .dw s_meal, s_snack
MENU_PLAY: .dw s_g_lr, s_g_hl, s_g_catch

; --- ESTADO --------------------------------------------------------------------
rd_stat:
    LDA AL,[page]
    CMP AL,#1
    JMPZ rs_hunger
    CMP AL,#2
    JMPZ rs_happy
    CMP AL,#3
    JMPZ rs_disc
    ; pagina 0: nombre, edad, peso, generacion y la hora
    MOV BX,#s_name
    MOV CX,#0x0101
    CALL txt_puts
    LDA AL,[s_form]
    SHL AL
    MOV CL,AL
    MOV BX,#NAMES
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    MOV CX,#0x0108
    CALL txt_puts
    MOV BX,#t_age
    MOV CX,#0x0201
    CALL txt_puts
    LDA AL,[s_age]
    MOV CX,#0x0208
    CALL txt_put3
    MOV BX,#s_days
    CALL txt_puts
    MOV BX,#t_weight
    MOV CX,#0x0301
    CALL txt_puts
    LDA AL,[s_weight]
    MOV CX,#0x0308
    CALL txt_put2
    MOV BX,#s_grams
    CALL txt_puts
    MOV BX,#t_gen
    MOV CX,#0x0401
    CALL txt_puts
    LDA AL,[s_gen]
    MOV CX,#0x0408
    CALL txt_put3
    ; la hora (si el aparato la tiene)
    OUT (P_TIME),AL
    IN  AL,(P_TIME)
    AND AL,#1
    JMPZ rd_done
    MOV CX,#0x0501
    MOV BX,#s_time
    CALL txt_puts
    MOV CX,#0x0508
    IN  AL,(P_T_HOUR)
    CALL txt_put2
    MOV AL,#':'
    CALL txt_putc
    IN  AL,(P_T_MIN)
    CALL txt_put2
    JMP rd_done
rs_hunger:
    MOV BX,#s_hungry
    LDA AL,[s_hunger]
    JMP rs_hearts
rs_happy:
    MOV BX,#s_happyt
    LDA AL,[s_happy]
rs_hearts:
    PUSH AL
    MOV CX,#0x0201
    CALL txt_puts
    POP AL
    MOV DL,#FX_HEART
    MOV DH,#FX_HEART_E
    JMP rs_row
rs_disc:
    MOV BX,#s_disct
    MOV CX,#0x0201
    CALL txt_puts
    LDA AL,[s_disc]
    MOV DL,#FX_STAR
    MOV DH,#FX_HEART_E
rs_row:
    ; AL llenos de 4: DL lleno, DH vacio; en la fila de 32 px, columnas 4..10
    STA [cnt],AL
    STA [fx_full],DL
    STA [fx_empty],DH
    MOV AL,#0
    STA [cnt2],AL
rsr_l:
    LDA AL,[cnt2]
    LDA BL,[cnt]
    CMP AL,BL
    LDA AL,[fx_full]
    JMPC rsr_d
    LDA AL,[fx_empty]
rsr_d:
    LDA CL,[cnt2]
    SHL CL,#1
    ADD CL,#4
    MOV CH,#32
    CALL draw_fx
    LDA AL,[cnt2]
    ADD AL,#1
    STA [cnt2],AL
    CMP AL,#4
    JMPNZ rsr_l
    JMP rd_done

; --- juegos ----------------------------------------------------------------------
rd_lr:
    MOV BX,#s_lr_q
    MOV CX,#0x0001
    CALL txt_puts
    CALL rd_score
    LDA AL,[g_phase]
    CMP AL,#0
    JMPNZ rlr_show
    MOV BX,#s_lr_k
    MOV CX,#0x0701
    CALL txt_puts
    MOV CL,#6
    JMP game_wait_pet
rlr_show:
    ; primero adonde mira; los ultimos REACT_FR fotogramas, la reaccion
    LDA AL,[g_wait]
    CMP AL,#(REACT_FR + 1)
    JMPNC rlr_look
    CALL react_face
    JMP rlr_pet
rlr_look:
    LDA AL,[g_num]
    CMP AL,#0
    MOV AL,#FACE_LOOK_L
    JMPZ rlr_pet
    MOV AL,#FACE_LOOK_R
rlr_pet:
    MOV BL,#0
    MOV CL,#6
    MOV CH,#PET_Y
    CALL draw_pet
    CALL rd_verdict
    JMP rd_done

rd_hl:
    MOV BX,#s_hl_q
    MOV CX,#0x0001
    CALL txt_puts
    CALL rd_score
    MOV BX,#s_number
    MOV CX,#0x0201
    CALL txt_puts
    LDA AL,[g_num]
    ADD AL,#'0'
    CALL txt_putc
    LDA AL,[g_phase]
    CMP AL,#0
    JMPNZ rhl_show
    MOV BX,#s_hl_k
    MOV CX,#0x0704
    CALL txt_puts
    MOV CL,#11
    JMP game_wait_pet
rhl_show:
    MOV BX,#s_next
    MOV CX,#0x0401
    CALL txt_puts
    LDA AL,[g_next]
    ADD AL,#'0'
    CALL txt_putc
    CALL react_face
rhl_pet:
    MOV BL,#0
    MOV CL,#11
    MOV CH,#PET_Y
    CALL draw_pet
    CALL rd_verdict
    JMP rd_done

; esperando la eleccion: CL = columna. Botecitos, algun parpadeo y un "?"
; que se enciende y se apaga
game_wait_pet:
    STA [gw_col],CL
    MOV AL,#FACE_NORMAL
    LDA BL,[tick]
    AND BL,#7
    JMPNZ gwp_f
    MOV AL,#FACE_BLINK
gwp_f:
    LDA BL,[tick]
    AND BL,#1
    MOV CH,#PET_Y
    CALL draw_pet
    LDA AL,[tick]
    AND AL,#2
    JMPZ rd_done
    MOV AL,#FX_QUESTION
    LDA CL,[gw_col]
    CALL fx_beside
    JMP rd_done

; "YES!" / "NO..." mientras se enseña el resultado de la ronda
rd_verdict:
    LDA AL,[g_phase]
    CMP AL,#0
    JMPZ rv_ret
    LDA AL,[g_wait]          ; (izq/der: solo con la reaccion, no al mirar)
    CMP AL,#(REACT_FR + 1)
    JMPNC rv_ret
    MOV BX,#s_no
    LDA AL,[g_ok]
    CMP AL,#0
    JMPZ rv_put
    MOV BX,#s_yes
rv_put:
    MOV CX,#0x0708
    CALL txt_clear_row
    MOV CX,#0x0708
    CALL txt_puts
rv_ret:
    RET

; ronda y aciertos, arriba a la derecha
rd_score:
    MOV CX,#0x0010
    LDA AL,[g_wins]
    ADD AL,#'0'
    CALL txt_putc
    MOV AL,#'/'
    CALL txt_putc
    LDA AL,[mode]
    CMP AL,#M_CATCH
    MOV AL,#'5'
    JMPNZ rsc_t
    MOV AL,#'#'
rsc_t:
    JMP txt_putc

rd_catch:
    MOV BX,#s_catch_q
    MOV CX,#0x0001
    CALL txt_puts
    MOV CX,#0x0010
    LDA AL,[g_wins]
    CALL txt_put2
    ; el corazon que cae
    MOV AL,#FX_HEART
    LDA CL,[g_ix]
    LDA CH,[g_iy]
    CALL draw_fx
    ; la mascota, abajo
    MOV AL,#FACE_HAPPY
    MOV BL,#0
    LDA CL,[g_px]
    MOV CH,#PET_Y
    CALL draw_pet
    JMP rd_done

rd_gone:
    MOV BX,#s_gone1
    MOV CX,#0x0501
    CALL txt_puts
    MOV BX,#s_gone2
    MOV CX,#0x0601
    CALL txt_puts
    MOV AL,#FORM_UFO
    STA [cur_form],AL
    MOV AL,#FACE_NONE
    LDA BL,[tick]
    AND BL,#1
    MOV CL,#6
    MOV CH,#8
    CALL draw_body
    JMP rd_done

; --- iconos: 4 arriba (fila 0) y 4 abajo (fila 56); el elegido en inverso;
; el de aviso (el 8º) solo se ve si llama -----------------------------------
draw_icons:
    MOV AL,#0
    STA [cnt],AL
di_l:
    LDA AL,[cnt]
    CMP AL,#7
    JMPNZ di_draw
    LDA BL,[s_call]
    CMP BL,#0
    JMPZ di_next
di_draw:
    ; posicion: columna (i mod 4)*4 + 1; fila 0 o 56
    MOV BL,AL
    AND BL,#3
    SHL BL,#2
    ADD BL,#1
    MOV CL,BL
    MOV CH,#0
    CMP AL,#4
    JMPC di_row
    MOV CH,#56
di_row:
    SHL AL,#4
    MOV BX,#ICON_TBL
    ADD BX,AL
    CALL draw_icon
    ; elegido: invertir su celda de 32 px
    LDA AL,[cnt]
    LDA BL,[sel]
    CMP AL,BL
    JMPNZ di_next
    MOV CL,AL
    AND CL,#3
    SHL CL,#2
    MOV CH,#0
    CMP AL,#4
    JMPC di_inv
    MOV CH,#56
di_inv:
    CALL bb_invert_cell
di_next:
    LDA AL,[cnt]
    ADD AL,#1
    STA [cnt],AL
    CMP AL,#8
    JMPNZ di_l
    RET

; ============================================================================
;  PRIMITIVAS DE DIBUJO (sobre BB)
; ============================================================================
; --- bb_addr: CL = columna (byte), CH = fila -> DX = BB + fila*16 + columna
bb_addr:
    MOV AL,CH
    MOV DL,#16
    MUL DL                   ; AX = fila*16
    ADD AL,CL
    JMPNC ba_nc
    INC AH
ba_nc:
    MOV DX,AX
    ADD DH,#(BB >> 8)
    RET

; --- bb_clear: borra BB entera (o la llena de luz si [lights_bg]) ----------
bb_clear:
    MOV BX,#BB
    MOV AL,#0
bc_l:
    STA [BX],AL
    INC BX
    CMP BH,#((BB >> 8) + 4)
    JMPNZ bc_l
    RET

; --- blit: BB -> pantalla (1024 OUT) -------------------------------------------
blit:
    MOV BX,#0
    MOV DX,#BB
bl_l:
    LDA AL,[DX]
    OUT (BX),AL
    INC BX
    INC DX
    CMP BH,#4
    JMPNZ bl_l
    RET

; --- bb_invert_cell: CL = columna, CH = fila: 4 bytes x 8 filas en inverso -
bb_invert_cell:
    CALL bb_addr
    MOV CL,#8
bic_r:
    MOV CH,#4
bic_c:
    LDA AL,[DX]
    XOR AL,#0xFF
    STA [DX],AL
    INC DX
    SUB CH,#1
    JMPNZ bic_c
    ADD DX,#12
    SUB CL,#1
    JMPNZ bic_r
    RET

; --- bb_invert_area: la zona de en medio (filas 8..55) en inverso -----------
bb_invert_area:
    MOV DX,#(BB + 8*16)
biv_l:
    LDA AL,[DX]
    XOR AL,#0xFF
    STA [DX],AL
    INC DX
    CMP DX,#(BB + 56*16)
    JMPNZ biv_l
    RET

; --- draw_icon: BX = icono 16x8 (2 bytes por fila), CL = columna, CH = fila
draw_icon:
    PUSH BL
    PUSH BH
    CALL bb_addr
    POP BH
    POP BL
    MOV CL,#8
dic_l:
    LDA AL,[BX]
    STA [DX],AL
    INC BX
    INC DX
    LDA AL,[BX]
    STA [DX],AL
    INC BX
    ADD DX,#15
    SUB CL,#1
    JMPNZ dic_l
    RET

; --- draw_fx: AL = efecto (FX_*), CL = columna, CH = fila: 16x16 (ya al
; doble y suavizado por tama_art.py), OR sobre BB ----------------------------
draw_fx:
    MOV BL,#32
    MUL BL                   ; AX = efecto * 32
    MOV BX,#FX_TBL
    ADD BX,AX
    PUSH BL
    PUSH BH
    CALL bb_addr
    POP BH
    POP BL
    MOV CL,#16
dfx_l:
    LDA AL,[BX]
    STA [q0],AL
    INC BX
    LDA AL,[BX]
    STA [q1],AL
    INC BX
    CALL put2_or
    ADD DX,#14
    SUB CL,#1
    JMPNZ dfx_l
    RET

; [DX], [DX+1] |= q0, q1; DX avanza 2
put2_or:
    LDA AL,[DX]
    OR  AL,[q0]
    STA [DX],AL
    INC DX
    LDA AL,[DX]
    OR  AL,[q1]
    STA [DX],AL
    INC DX
    RET

; --- draw_pet: AL = cara, BL = fotograma (0/1: botecito), CL = columna,
; CH = fila. Con la forma actual (s_form). ---------------------------------
draw_pet:
    PUSH AL
    LDA AL,[s_form]
    STA [cur_form],AL
    POP AL
; draw_body: igual pero con la forma de [cur_form]. Los cuerpos ya vienen a
; 32x32 (al doble y suavizados por tama_art.py): se copian tal cual.
draw_body:
    STA [d_face],AL
    STA [d_frame],BL
    STA [d_col],CL
    STA [d_row],CH
    ; cuerpo -> TMP (2 filas mas abajo en el fotograma 1)
    MOV BX,#TMP
    MOV CL,#8
    MOV AL,#0
dp_z:
    STA [BX],AL
    INC BX
    SUB CL,#1
    JMPNZ dp_z
    LDA AL,[cur_form]
    SHL AL
    MOV CL,AL
    MOV BX,#BODY_TBL
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    MOV DX,#TMP
    MOV CX,#128
    LDA AL,[d_frame]
    CMP AL,#0
    JMPZ dp_copy
    MOV DX,#(TMP+8)
    MOV CX,#120
dp_copy:
    MOVB
    ; la cara: 10 filas desde BODY_FY (+2 en el fotograma 1), columnas 8..23
    ; (los bytes 1 y 2 de cada fila de 4)
    LDA AL,[cur_form]
    MOV BX,#BODY_FY
    ADD BX,AL
    LDA AL,[BX]
    LDA BL,[d_frame]
    SHL BL
    ADD AL,BL
    MOV BL,#4
    MUL BL                   ; AX = fila * 4
    MOV DX,#(TMP+1)
    ADD DX,AX
    LDA AL,[d_face]
    MOV BL,#20
    MUL BL                   ; AX = cara * 20
    MOV BX,#FACES
    ADD BX,AX
    MOV CL,#10
dpf_l:
    LDA AL,[BX]
    LDA AH,[DX]
    XOR AH,AL
    STA [DX],AH
    INC BX
    INC DX
    LDA AL,[BX]
    LDA AH,[DX]
    XOR AH,AL
    STA [DX],AH
    INC BX
    ADD DX,#3
    SUB CL,#1
    JMPNZ dpf_l
    ; TMP (32x32) a BB
    LDA CL,[d_col]
    LDA CH,[d_row]
    CALL bb_addr
    MOV BX,#TMP
    MOV CL,#32
dps_l:
    LDA AL,[BX]
    STA [q0],AL
    INC BX
    LDA AL,[BX]
    STA [q1],AL
    INC BX
    LDA AL,[BX]
    STA [q2],AL
    INC BX
    LDA AL,[BX]
    STA [q3],AL
    INC BX
    CALL put4_or
    ADD DX,#12
    SUB CL,#1
    JMPNZ dps_l
    RET

; [DX..DX+3] |= q0..q3 (sin pasarse de la columna 15); DX avanza 4
put4_or:
    LDA AL,[d_col]
    STA [cnt3],AL
    LDA AL,[q0]
    CALL p4_one
    LDA AL,[q1]
    CALL p4_one
    LDA AL,[q2]
    CALL p4_one
    LDA AL,[q3]
p4_one:
    PUSH AL
    LDA AL,[cnt3]
    CMP AL,#16
    POP AL
    JMPNC p4_skip
    PUSH BL
    LDA BL,[DX]
    OR  BL,AL
    STA [DX],BL
    POP BL
p4_skip:
    INC DX
    LDA AL,[cnt3]
    ADD AL,#1
    STA [cnt3],AL
    RET

; ============================================================================
;  EVENTOS DE LA SIMULACION -> interfaz (sonido, animaciones, pantalla)
; ============================================================================
handle_events:
    LDA AL,[ev_flags]
    CMP AL,#0
    JMPZ he_ret
    MOV BL,#0
    STA [ev_flags],BL
    STA [ev_tmp],AL
    ; avisar: encender la pantalla
    MOV AL,#3
    OUT (P_POWER),AL
    MOV AL,#1
    STA [dirty],AL
    LDA AL,[ev_tmp]
    AND AL,#EV_GONE
    JMPZ he_evo
    MOV AL,#A_GONE
    JMP he_anim
he_evo:
    LDA AL,[ev_tmp]
    AND AL,#EV_HATCH
    JMPZ he_evo2
    MOV AL,#A_HATCH
    JMP he_anim
he_evo2:
    LDA AL,[ev_tmp]
    AND AL,#EV_EVOLVE
    JMPZ he_call
    MOV AL,#A_EVOLVE
he_anim:
    ; solo si no esta en un juego / menu: si no, se ve al volver
    LDA BL,[mode]
    CMP BL,#M_MAIN
    JMPZ anim_start
    CMP BL,#M_ANIM
    JMPZ anim_start
    RET
he_call:
    LDA AL,[ev_tmp]
    AND AL,#EV_SLEEP
    JMPZ he_c2
    MOV BX,#ph_sleep
    JMP snd_play
he_c2:
    MOV BX,#ph_call
    JMP snd_play
he_ret:
    RET

; ============================================================================
;  RELOJ: minutos de verdad (hora del aparato) o contados (sin hora)
; ============================================================================
; --- clock_boot: al arrancar, ponerse al dia con lo que ha pasado ----------
clock_boot:
    CALL time_now            ; C = 0 si hay hora: now24, now_mod
    JMPC cb_ret              ; sin hora: sigue donde lo dejo
    LDA AL,[s_tvalid]
    CMP AL,#0
    JMPZ clock_now_reset     ; nunca tuvo hora: empezar ahora
    JMP catch_up
cb_ret:
    RET

; --- clock_now_reset: la "ultima vez" = ahora (sin simular nada) --------------
clock_now_reset:
    CALL time_now
    JMPC cnr_ret
    CALL set_last_now
cnr_ret:
    RET

set_last_now:
    LDA AL,[now0]
    STA [s_last0],AL
    LDA AL,[now1]
    STA [s_last1],AL
    LDA AL,[now2]
    STA [s_last2],AL
    LDA AL,[now_mlo]
    STA [s_mod_lo],AL
    LDA AL,[now_mhi]
    STA [s_mod_hi],AL
    MOV AL,#1
    STA [s_tvalid],AL
    RET

; --- time_now: C = 1 si el aparato no tiene hora. Si la tiene: now0..2 =
; minutos locales, now_mlo/hi = minuto del dia ----------------------------------
time_now:
    OUT (P_TIME),AL
    IN  AL,(P_TIME)
    AND AL,#1
    JMPNZ tn_ok
    MOV AL,#1
    SHR AL                   ; C = 1
    RET
tn_ok:
    IN  AL,(P_T_LMIN)
    STA [now0],AL
    IN  AL,(P_T_LMIN+1)
    STA [now1],AL
    IN  AL,(P_T_LMIN+2)
    STA [now2],AL
    IN  AL,(P_T_HOUR)
    MOV BL,#60
    MUL BL
    MOV BL,AL
    IN  AL,(P_T_MIN)
    ADD BL,AL
    JMPNC tn_nc
    INC AH
tn_nc:
    STA [now_mlo],BL
    STA [now_mhi],AH
    MOV AL,#0
    SHR AL                   ; C = 0
    RET

; --- catch_up: simula los minutos de s_last a now (como mucho MAX_GAP) y
; deja s_last = now ------------------------------------------------------------
catch_up:
    ; hueco = now - last (24 bits)
    LDA AL,[now0]
    LDA BL,[s_last0]
    SUB AL,BL
    STA [gap_lo],AL
    LDA AL,[now1]
    LDA BL,[s_last1]
    SBC AL,BL
    STA [gap_hi],AL
    LDA AL,[now2]
    LDA BL,[s_last2]
    SBC AL,BL
    JMPC cu_reset            ; el reloj fue hacia atras: empezar de ahora
    CMP AL,#0
    JMPNZ cu_cap
    LDA BL,[gap_lo]
    LDA BH,[gap_hi]
    CMP BX,#MAX_GAP
    JMPC cu_run
cu_cap:
    MOV BX,#MAX_GAP
cu_run:
    MOV AL,BL
    OR  AL,BH
    JMPZ cu_reset
    PUSH BL
    PUSH BH
    CALL sim_minute
    CALL mod_inc
    POP BH
    POP BL
    DEC BX
    JMP cu_run
cu_reset:
    JMP set_last_now

; minuto del dia + 1 (vuelta a 0 a las 24:00)
mod_inc:
    LDA BL,[s_mod_lo]
    LDA BH,[s_mod_hi]
    INC BX
    CMP BX,#1440
    JMPNZ mi_set
    MOV BX,#0
mi_set:
    STA [s_mod_lo],BL
    STA [s_mod_hi],BH
    RET

; --- clock_tick: cada ~1 s, mira si ha pasado un minuto ----------------------
clock_tick:
    IN  AL,(P_T7)
    CMP AL,#0
    JMPNZ ct_ret
    MOV AL,#8
    OUT (P_T7),AL
    CALL time_now
    JMPC ct_nortc
    LDA AL,[s_tvalid]
    CMP AL,#0
    JMPZ ct_first
    ; con hora: si el minuto local ha cambiado, simular lo que falte
    LDA AL,[now0]
    LDA BL,[s_last0]
    CMP AL,BL
    JMPNZ ct_run
    LDA AL,[now1]
    LDA BL,[s_last1]
    CMP AL,BL
    JMPNZ ct_run
    LDA AL,[now2]
    LDA BL,[s_last2]
    CMP AL,BL
    JMPZ ct_ret
ct_run:
    CALL catch_up
    JMP save_if_changed
ct_first:
    CALL set_last_now        ; acaba de llegar la hora: desde ahora
    JMP save_if_changed
ct_nortc:
    ; sin hora: un minuto cada 117 x 512 ms (T9)
    IN  AL,(P_T9)
    CMP AL,#0
    JMPNZ ct_ret
    MOV AL,#117
    OUT (P_T9),AL
    CALL sim_minute
    CALL mod_inc
    ; la "ultima vez" tambien avanza (si luego llega la hora, se compara)
    LDA AL,[s_last0]
    ADD AL,#1
    STA [s_last0],AL
    LDA AL,[s_last1]
    ADC AL,#0
    STA [s_last1],AL
    LDA AL,[s_last2]
    ADC AL,#0
    STA [s_last2],AL
    ; sin hora no hay forma de recalcular al volver lo que ha pasado: los
    ; contadores (lo que le falta al huevo, al hambre...) se perderian al
    ; apagar. Se guarda el progreso cada NORTC_SAVE minutos.
    LDA AL,[nortc_cnt]
    ADD AL,#1
    STA [nortc_cnt],AL
    CMP AL,#NORTC_SAVE
    JMPC save_if_changed
    MOV AL,#0
    STA [nortc_cnt],AL
    JMP save_state
ct_ret:
    RET

; ============================================================================
;  SIMULACION: un minuto de vida
; ============================================================================
sim_minute:
    LDA AL,[s_stage]
    CMP AL,#ST_GONE
    JMPZ sm_ret
    CMP AL,#ST_EGG
    JMPNZ sm_alive
    ; huevo: solo cuenta hasta eclosionar
    CALL stage_dec
    JMPNZ sm_ret
    JMP hatch
sm_ret:
    RET
sm_alive:
    ; edad: un dia cada 1440 minutos
    LDA BL,[s_day_lo]
    LDA BH,[s_day_hi]
    INC BX
    CMP BX,#1440
    JMPNZ sm_dayset
    MOV BX,#0
    LDA AL,[s_age]
    ADD AL,#1
    STA [s_age],AL
    ; adulto al final de su vida: se va (contento)
    LDA AL,[s_stage]
    CMP AL,#ST_ADULT
    JMPNZ sm_dayset
    LDA AL,[s_age]
    LDA CL,[s_life]
    CMP AL,CL
    JMPC sm_dayset
    STA [s_day_lo],BL
    STA [s_day_hi],BH
    JMP go_away
sm_dayset:
    STA [s_day_lo],BL
    STA [s_day_hi],BH

    CALL sleep_check
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPZ sm_awake
    ; dormido: la luz encendida molesta (fallo a los 15 min)
    LDA AL,[s_lights]
    CMP AL,#0
    JMPZ sm_evo
    LDA AL,[s_call]
    AND AL,#CALL_LIGHT
    JMPZ sm_evo
    LDA AL,[s_lightt]
    ADD AL,#1
    STA [s_lightt],AL
    CMP AL,#CALL_MIN
    JMPNZ sm_evo
    CALL mistake
    LDA AL,[s_call]
    AND AL,#(~CALL_LIGHT & 0xFF)
    STA [s_call],AL
    JMP sm_evo
sm_awake:
    ; hambre
    LDA AL,[s_hungt]
    SUB AL,#1
    STA [s_hungt],AL
    JMPNZ sm_happy
    MOV CL,#0
    CALL rate_get
    STA [s_hungt],AL
    ; las chuches se van digiriendo (una por bajada de hambre); con muchas
    ; sin digerir, 1 de cada 4 veces le duele la tripa (se pone malo)
    LDA AL,[s_snacks]
    CMP AL,#0
    JMPZ sm_h2
    CMP AL,#SNACK_SICK
    JMPC sm_dig
    IN  AL,(P_RANDOM)
    AND AL,#3
    JMPNZ sm_dig
    CALL get_sick
sm_dig:
    LDA AL,[s_snacks]
    SUB AL,#1
    STA [s_snacks],AL
sm_h2:
    ; baja un corazon; si llega a 0 (o ya estaba), llama. Mientras siga
    ; a 0, vuelve a llamar cada periodo: cada llamada sin atender es un
    ; fallo de cuidado mas
    LDA AL,[s_hunger]
    CMP AL,#0
    JMPZ sm_hcall
    SUB AL,#1
    STA [s_hunger],AL
    JMPNZ sm_happy
sm_hcall:
    LDA AL,[s_call]
    AND AL,#CALL_HUNGER
    JMPNZ sm_happy
    MOV AL,#CALL_HUNGER
    CALL raise_call
sm_happy:
    LDA AL,[s_happt]
    SUB AL,#1
    STA [s_happt],AL
    JMPNZ sm_poop
    MOV CL,#1
    CALL rate_get
    STA [s_happt],AL
    LDA AL,[s_happy]
    CMP AL,#0
    JMPZ sm_pcall
    SUB AL,#1
    STA [s_happy],AL
    JMPNZ sm_poop
sm_pcall:
    LDA AL,[s_call]
    AND AL,#CALL_HAPPY
    JMPNZ sm_poop
    MOV AL,#CALL_HAPPY
    CALL raise_call
sm_poop:
    LDA AL,[s_poopt]
    SUB AL,#1
    STA [s_poopt],AL
    JMPNZ sm_sick
    MOV CL,#2
    CALL rate_get
    MOV BL,AL
    IN  AL,(P_RANDOM)
    AND AL,#15
    ADD AL,BL
    STA [s_poopt],AL
    LDA AL,[s_poops]
    CMP AL,#4
    JMPZ sm_sick
    ADD AL,#1
    STA [s_poops],AL
sm_sick:
    ; con 3 cacas o mas, puede ponerse malo (1/128 por minuto)
    LDA AL,[s_poops]
    CMP AL,#3
    JMPC sm_sk2
    IN  AL,(P_RANDOM)
    CMP AL,#2
    JMPNC sm_sk2
    CALL get_sick
sm_sk2:
    LDA AL,[s_sick]
    CMP AL,#0
    JMPZ sm_calls
    ; malo sin curar un dia: se va
    LDA BL,[s_sickt_lo]
    LDA BH,[s_sickt_hi]
    INC BX
    STA [s_sickt_lo],BL
    STA [s_sickt_hi],BH
    CMP BX,#1440
    JMPZ go_away
sm_calls:
    ; llamadas sin atender: a los 15 min, fallo de cuidado
    LDA AL,[s_call]
    AND AL,#(CALL_HUNGER | CALL_HAPPY | CALL_FAKE)
    JMPZ sm_fake
    LDA AL,[s_callt]
    CMP AL,#0
    JMPZ sm_fake
    SUB AL,#1
    STA [s_callt],AL
    JMPNZ sm_fake
    LDA AL,[s_call]
    AND AL,#(CALL_HUNGER | CALL_HAPPY)
    JMPZ sm_cl
    CALL mistake
sm_cl:
    LDA AL,[s_call]
    AND AL,#(~(CALL_HUNGER | CALL_HAPPY | CALL_FAKE) & 0xFF)
    STA [s_call],AL
sm_fake:
    ; caprichos (niño y adolescente): de vez en cuando llama sin motivo
    LDA AL,[s_stage]
    CMP AL,#ST_CHILD
    JMPZ sm_fk
    CMP AL,#ST_TEEN
    JMPNZ sm_negl
sm_fk:
    LDA AL,[s_faket]
    SUB AL,#1
    STA [s_faket],AL
    JMPNZ sm_negl
    IN  AL,(P_RANDOM)
    AND AL,#63
    ADD AL,#60
    STA [s_faket],AL
    LDA AL,[s_call]
    CMP AL,#0
    JMPNZ sm_negl
    CALL set_fake
    LDA AL,[ev_flags]
    OR  AL,#EV_CALL
    STA [ev_flags],AL
sm_negl:
    ; muerto de hambre y triste 12 h: se va
    LDA AL,[s_hunger]
    OR  AL,[s_happy]
    JMPZ sm_ng
    MOV AL,#0
    STA [s_negl_lo],AL
    STA [s_negl_hi],AL
    JMP sm_evo
sm_ng:
    LDA BL,[s_negl_lo]
    LDA BH,[s_negl_hi]
    INC BX
    STA [s_negl_lo],BL
    STA [s_negl_hi],BH
    CMP BX,#720
    JMPZ go_away
sm_evo:
    LDA AL,[s_stage]
    CMP AL,#ST_ADULT
    JMPZ sm_end
    CALL stage_dec
    JMPZ evolve
sm_end:
    RET

; --- stage_dec: s_stg - 1; Z = 1 si ha llegado a 0 ------------------------------
stage_dec:
    LDA BL,[s_stg_lo]
    LDA BH,[s_stg_hi]
    DEC BX
    STA [s_stg_lo],BL
    STA [s_stg_hi],BH
    MOV AL,BL
    OR  AL,BH
    RET

; --- raise_call: AL = motivo. Empieza a llamar (y cuenta 15 min) -----------------
raise_call:
    LDA BL,[s_call]
    OR  BL,AL
    STA [s_call],BL
    LDA AL,[s_callt]
    CMP AL,#0
    JMPNZ rc_ev
    MOV AL,#CALL_MIN
    STA [s_callt],AL
rc_ev:
    LDA AL,[ev_flags]
    OR  AL,#EV_CALL
    STA [ev_flags],AL
    RET

mistake:
    LDA AL,[s_mist]
    CMP AL,#99
    JMPZ mk_ret
    ADD AL,#1
    STA [s_mist],AL
mk_ret:
    RET

; --- rate_get: CL = 0 hambre, 1 alegria, 2 cacas -> AL = minutos (de RATES) --
rate_get:
    LDA AL,[s_form]
    MOV BL,#3
    MUL BL
    ADD AL,CL
    MOV BX,#RATES
    ADD BX,AL
    LDA AL,[BX]
    RET

; --- sleep_check: a su hora se duerme (y llama por la luz), a su hora despierta
sleep_check:
    LDA AL,[s_form]
    SHL AL,#2
    MOV BX,#SLEEP_TBL
    ADD BX,AL
    LDA CL,[BX]              ; hora de dormir (minuto del dia)
    INC BX
    LDA CH,[BX]
    INC BX
    LDA DL,[BX]              ; hora de despertar
    INC BX
    LDA DH,[BX]
    CMP CH,#0xFF
    JMPZ sc_ret              ; esta forma no duerme
    LDA BL,[s_mod_lo]
    LDA BH,[s_mod_hi]
    CMP BX,CX
    JMPNZ sc_wake
    LDA AL,[s_sleep]
    CMP AL,#0
    JMPNZ sc_ret
    MOV AL,#1
    STA [s_sleep],AL
    MOV AL,#0
    STA [s_lightt],AL
    LDA AL,[ev_flags]
    OR  AL,#EV_SLEEP
    STA [ev_flags],AL
    LDA AL,[s_lights]
    CMP AL,#0
    JMPZ sc_ret
    MOV AL,#CALL_LIGHT       ; que le apaguen la luz
    JMP raise_call
sc_wake:
    CMP BX,DX
    JMPNZ sc_ret
    MOV AL,#0
    STA [s_sleep],AL
    MOV AL,#1
    STA [s_lights],AL
    LDA AL,[s_call]
    AND AL,#(~CALL_LIGHT & 0xFF)
    STA [s_call],AL
sc_ret:
    RET

; --- hatch: el huevo eclosiona en bebe ------------------------------------------
hatch:
    MOV AL,#ST_BABY
    STA [s_stage],AL
    MOV AL,#FORM_BABY
    STA [s_form],AL
    MOV BX,#60
    CALL set_stage_t
    MOV AL,#1
    STA [s_hunger],AL
    STA [s_happy],AL
    MOV AL,#5
    STA [s_weight],AL
    CALL reset_rates
    LDA AL,[ev_flags]
    OR  AL,#EV_HATCH
    STA [ev_flags],AL
    RET

set_stage_t:
    STA [s_stg_lo],BL
    STA [s_stg_hi],BH
    RET

reset_rates:
    MOV CL,#0
    CALL rate_get
    STA [s_hungt],AL
    MOV CL,#1
    CALL rate_get
    STA [s_happt],AL
    MOV CL,#2
    CALL rate_get
    STA [s_poopt],AL
    MOV AL,#90
    STA [s_faket],AL
    RET

; --- evolve: a la siguiente etapa, segun como se le ha cuidado -------------------
evolve:
    LDA AL,[s_stage]
    CMP AL,#ST_BABY
    JMPNZ ev_child
    ; bebe -> niño
    MOV AL,#ST_CHILD
    STA [s_stage],AL
    MOV AL,#FORM_CHILD
    STA [s_form],AL
    MOV BX,#1440
    JMP ev_done
ev_child:
    CMP AL,#ST_CHILD
    JMPNZ ev_teen
    ; niño -> adolescente: bueno con 0-2 fallos
    MOV AL,#ST_TEEN
    STA [s_stage],AL
    MOV CL,#FORM_TEEN_A
    LDA AL,[s_mist]
    CMP AL,#3
    JMPC ev_t
    MOV CL,#FORM_TEEN_B
ev_t:
    STA [s_form],CL
    MOV BX,#2880
    JMP ev_done
ev_teen:
    ; adolescente -> adulto
    MOV AL,#ST_ADULT
    STA [s_stage],AL
    LDA AL,[s_mist]
    LDA BL,[s_disc]
    LDA CL,[s_form]
    CMP CL,#FORM_TEEN_A
    JMPNZ ev_b
    MOV CL,#FORM_MOCHI
    CMP AL,#6
    JMPNC ev_a
    MOV CL,#FORM_NEKO
    CMP AL,#3
    JMPNC ev_a
    MOV CL,#FORM_KUMO
    CMP BL,#4
    JMPNZ ev_a
    MOV CL,#FORM_LUMI
    JMP ev_a
ev_b:
    MOV CL,#FORM_BUBU
    CMP AL,#6
    JMPNC ev_a
    MOV CL,#FORM_PUNI
    CMP AL,#3
    JMPNC ev_a
    CMP BL,#3
    JMPC ev_a
    MOV CL,#FORM_NEKO
ev_a:
    STA [s_form],CL
    ; vida de adulto: segun la forma
    MOV BX,#LIFE_TBL
    MOV AL,CL
    SUB AL,#FORM_LUMI
    ADD BX,AL
    LDA AL,[BX]
    LDA BL,[s_age]
    ADD AL,BL
    STA [s_life],AL
    MOV BX,#0
ev_done:
    CALL set_stage_t
    MOV AL,#0
    STA [s_mist],AL
    MOV AL,#5
    CALL weight_add
    CALL reset_rates
    LDA AL,[ev_flags]
    OR  AL,#EV_EVOLVE
    STA [ev_flags],AL
    RET

; --- go_away: se va a su planeta ---------------------------------------------
go_away:
    MOV AL,#ST_GONE
    STA [s_stage],AL
    MOV AL,#0
    STA [s_call],AL
    STA [s_sleep],AL
    STA [s_poops],AL
    STA [s_sick],AL
    LDA AL,[ev_flags]
    OR  AL,#EV_GONE
    STA [ev_flags],AL
    RET

; ============================================================================
;  ESTADO: nuevo, cargar, grabar
; ============================================================================
new_pet:
    LDA AL,[s_music]
    PUSH AL
    LDA AL,[s_gen]
    PUSH AL
    MOV BX,#st_begin
    MOV AL,#0
np_l:
    STA [BX],AL
    INC BX
    CMP BX,#st_end
    JMPNZ np_l
    POP AL
    ADD AL,#1
    STA [s_gen],AL
    POP AL
    STA [s_music],AL         ; (la preferencia de musica se conserva)
    MOV AL,#'T'
    STA [s_magic],AL
    MOV AL,#1
    STA [s_ver],AL
    STA [s_lights],AL
    MOV AL,#ST_EGG
    STA [s_stage],AL
    MOV AL,#FORM_EGG
    STA [s_form],AL
    MOV BX,#5                ; 5 minutos de huevo
    CALL set_stage_t
    RET

load_state:
    OUT (P_EEP_LOAD),AL
    IN  AL,(P_EEP_LOAD)
    CMP AL,#0
    JMPNZ ls_new             ; no se pudo leer
    MOV BX,#st_begin
    MOV DX,#P_EEP_BASE
    MOV CL,#0                ; suma
ls_l:
    IN  AL,(DX)
    STA [BX],AL
    CMP BX,#(st_end - 1)
    JMPZ ls_sum
    ADD CL,AL
    INC BX
    INC DX
    JMP ls_l
ls_sum:
    CMP AL,CL
    JMPNZ ls_new
    LDA AL,[s_magic]
    CMP AL,#'T'
    JMPNZ ls_new
    LDA AL,[s_ver]
    CMP AL,#1
    JMPNZ ls_new
    RET
ls_new:
    MOV AL,#0                ; (lo leido no vale: ni generacion ni preferencias)
    STA [s_gen],AL
    STA [s_music],AL
    JMP new_pet

; --- save_if_changed: graba solo si cambio algo de la parte "importante" -------
save_if_changed:
    MOV BX,#st_begin
    MOV DX,#sig_copy
    MOV CL,#SIG_LEN
sic_l:
    LDA AL,[BX]
    LDA AH,[DX]
    CMP AL,AH
    JMPNZ save_state
    INC BX
    INC DX
    SUB CL,#1
    JMPNZ sic_l
    RET

save_state:
    ; suma de comprobacion en el ultimo byte
    MOV BX,#st_begin
    MOV CL,#0
ss_sum:
    LDA AL,[BX]
    ADD CL,AL
    INC BX
    CMP BX,#(st_end - 1)
    JMPNZ ss_sum
    STA [BX],CL
    ; a la EEPROM del slot y a la flash
    MOV BX,#st_begin
    MOV DX,#P_EEP_BASE
ss_cp:
    LDA AL,[BX]
    OUT (DX),AL
    INC BX
    INC DX
    CMP BX,#st_end
    JMPNZ ss_cp
    OUT (P_EEP_SAVE),AL
    ; copia de la parte importante, para comparar
    MOV BX,#st_begin
    MOV DX,#sig_copy
    MOV CX,#SIG_LEN
    MOVB
    RET

; ============================================================================
;  SONIDO: frases (nota, pasos de 16 ms), la voz va mas aguda de pequeño
; ============================================================================
; --- menu_note: al moverse por los iconos de arriba y abajo, la siguiente
; nota de "Debajo un boton" (MENU_SONG), en su tono (sin la voz de la
; mascota). Los submenus y las paginas de ESTADO hacen un clic normal. ------
menu_note:
    LDA AL,[s_music]
    CMP AL,#0
    JMPNZ mnn_ret            ; musica de menus quitada (pulsacion larga)
    MOV AL,#0                ; corta la frase que sonara
    STA [snd_lo],AL
    STA [snd_hi],AL
    LDA AL,[song_i]
    MOV BX,#MENU_SONG
    ADD BX,AL
    ADD AL,#1
    CMP AL,#MENU_SONG_LEN
    JMPNZ mnn_i
    MOV AL,#0
mnn_i:
    STA [song_i],AL
    MOV AL,#12               ; 120 ms
    OUT (P_SND_DUR),AL
    LDA AL,[BX]
    OUT (P_SND_NOTE),AL
mnn_ret:
    RET

; --- ui_click: pitido corto y agudo (Do7, sin la voz de la mascota) de los
; submenus, las paginas de ESTADO y la luz. Calla con la musica quitada. ----
ui_click:
    LDA AL,[s_music]
    CMP AL,#0
    JMPNZ uic_ret
    MOV AL,#0                ; corta la frase que sonara
    STA [snd_lo],AL
    STA [snd_hi],AL
    MOV AL,#4                ; 40 ms
    OUT (P_SND_DUR),AL
    MOV AL,#96
    OUT (P_SND_NOTE),AL
uic_ret:
    RET

; BX = frase
snd_play:
    STA [snd_lo],BL
    STA [snd_hi],BH
    MOV AL,#0
    OUT (P_T4),AL
    RET

snd_tick:
    LDA BL,[snd_lo]
    LDA BH,[snd_hi]
    MOV AL,BL
    OR  AL,BH
    JMPZ snt_ret
    IN  AL,(P_T4)
    CMP AL,#0
    JMPNZ snt_ret
    LDA AL,[BX]              ; nota (0 = silencio, 0xFF = fin)
    CMP AL,#0xFF
    JMPZ snt_end
    INC BX
    LDA CL,[BX]              ; duracion
    INC BX
    STA [snd_lo],BL
    STA [snd_hi],BH
    CMP AL,#0
    JMPZ snt_note
    ; voz de esta forma
    PUSH CL
    PUSH AL
    LDA AL,[s_form]
    MOV BX,#VOICE
    ADD BX,AL
    LDA BL,[BX]
    POP AL
    ADD AL,BL
    POP CL
snt_note:
    PUSH AL
    MOV AL,#0
    OUT (P_SND_DUR),AL
    POP AL
    OUT (P_SND_NOTE),AL
    OUT (P_T4),CL
    RET
snt_end:
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    STA [snd_lo],AL
    STA [snd_hi],AL
snt_ret:
    RET

; frases (nota MIDI sin la voz, duracion en pasos de 16 ms), fin = 0xFF
ph_hello:  .db 72, 6, 76, 6, 79, 10, 0, 2, 0xFF
ph_chirp:  .db 79, 4, 84, 6, 0, 2, 0xFF
ph_call:   .db 84, 8, 0, 6, 84, 8, 0, 6, 84, 8, 0, 2, 0xFF
ph_sad:    .db 76, 12, 74, 12, 71, 22, 0, 2, 0xFF
ph_cry:    .db 79, 8, 76, 8, 79, 8, 76, 14, 0, 2, 0xFF
ph_eat:    .db 67, 5, 0, 4, 67, 5, 0, 10, 67, 5, 0, 4, 67, 5, 0, 2, 0xFF
ph_no:     .db 74, 8, 0, 2, 70, 14, 0, 2, 0xFF
ph_yes:    .db 79, 4, 84, 8, 0, 2, 0xFF
ph_lose:   .db 60, 10, 55, 16, 0, 2, 0xFF
ph_win:    .db 72, 5, 76, 5, 79, 5, 84, 14, 0, 2, 0xFF
ph_evolve: .db 72, 4, 74, 4, 76, 4, 77, 4, 79, 4, 81, 4, 83, 4, 84, 18, 0, 2, 0xFF
ph_hatch:  .db 79, 4, 0, 6, 79, 4, 0, 6, 84, 4, 88, 12, 0, 2, 0xFF
ph_sleep:  .db 76, 10, 72, 10, 67, 22, 0, 2, 0xFF
ph_flush:  .db 60, 3, 62, 3, 64, 3, 65, 3, 67, 3, 69, 3, 71, 3, 72, 8, 0, 2, 0xFF
ph_med:    .db 84, 3, 0, 3, 84, 3, 0, 8, 79, 6, 84, 8, 0, 2, 0xFF
ph_sorry:  .db 72, 10, 71, 10, 69, 16, 0, 2, 0xFF
ph_pet:    .db 84, 4, 88, 4, 91, 8, 0, 2, 0xFF
ph_moff:   .db 88, 4, 0, 2, 76, 8, 0, 2, 0xFF
ph_mon:    .db 76, 4, 0, 2, 88, 8, 0, 2, 0xFF
ph_wink:   .db 91, 3, 0, 2, 96, 7, 0, 2, 0xFF
ph_catch:  .db 88, 3, 91, 4, 0, 1, 0xFF
ph_drop:   .db 55, 4, 0, 1, 0xFF
ph_gone:   .db 72, 12, 76, 12, 79, 12, 84, 12, 79, 8, 84, 8, 88, 24, 0, 2, 0xFF

; ============================================================================
;  TABLAS
; ============================================================================
; "Debajo un boton, ton, ton..." en Fa mayor, aguda como los pitidos (Fa6 =
; 89, Sol6 = 91, La6 = 93, Sib6 = 94, Do7 = 96, Re7 = 98, Mi7 = 100, Fa7 =
; 101): cada verso, 4 notas y la ultima repetida tres veces; los versos 2,
; 3 y 4 son el mismo dibujo, cada uno mas abajo. Una nota por movimiento en
; los menus.
MENU_SONG:
    .db 89, 91, 93, 94, 96, 96, 96   ; de-ba-jo un bo-ton, ton, ton    (do re mi fa sol sol sol)
    .db 98, 100, 101, 98, 96, 96, 96 ; que en-con-tro Mar-tin, tin, tin (la si do la sol sol sol)
    .db 94, 96, 98, 94, 93, 93, 93   ; ha-bi-a un ra-ton, ton, ton      (fa sol la fa mi mi mi)
    .db 91, 93, 94, 91, 89, 89, 89   ; ay, que chi-qui-tin, tin, tin    (re mi fa re do do do)
MENU_SONG_LEN = 28
; (hambre, alegria, cacas) en minutos, por forma (FORM_*)
RATES:  .db 9, 9, 9          ; huevo (no se usa)
        .db 3, 4, 8          ; bebe
        .db 30, 35, 45       ; niño
        .db 45, 50, 60       ; adolescente bueno
        .db 40, 45, 60       ; adolescente travieso
        .db 70, 75, 120      ; LUMI
        .db 65, 70, 120      ; KUMO
        .db 60, 60, 100      ; NEKO
        .db 50, 55, 90       ; MOCHI
        .db 45, 50, 90       ; PUNI
        .db 40, 40, 80       ; BUBU
        .db 9, 9, 9          ; platillo

; dias de vida de adulto, de LUMI a BUBU
LIFE_TBL: .db 16, 14, 12, 10, 9, 7

; hora de dormir y de despertar (minuto del dia; 0xFFFF = no duerme)
SLEEP_TBL:
        .dw 0xFFFF, 0xFFFF   ; huevo
        .dw 0xFFFF, 0xFFFF   ; bebe
        .dw 1200, 540        ; niño: 20:00 - 9:00
        .dw 1260, 540        ; adolescentes: 21:00 - 9:00
        .dw 1260, 540
        .dw 1320, 480        ; adultos: 22:00 - 8:00
        .dw 1320, 480
        .dw 1320, 480
        .dw 1320, 480
        .dw 1380, 540        ; PUNI y BUBU, mas trasnochadores
        .dw 1380, 540
        .dw 0xFFFF, 0xFFFF

; voz: semitonos sobre la frase, por forma
VOICE:  .db 0, 12, 7, 5, 3, 2, 0, 4, 0xFD, 1, 0xFB, 0

NAMES:  .dw n_egg, n_baby, n_child, n_teena, n_teenb, n_lumi, n_kumo, n_neko
        .dw n_mochi, n_puni, n_bubu, n_egg
n_egg:   .asciiz "EGG"
n_baby:  .asciiz "PICHI"
n_child: .asciiz "POMU"
n_teena: .asciiz "TOBI"
n_teenb: .asciiz "GUMO"
n_lumi:  .asciiz "LUMI"
n_kumo:  .asciiz "KUMO"
n_neko:  .asciiz "NEKO"
n_mochi: .asciiz "MOCHI"
n_puni:  .asciiz "PUNI"
n_bubu:  .asciiz "BUBU"

s_loading: .asciiz "LOADING..."
s_reset:   .asciiz "RESET IN "
s_moff:    .asciiz "MUSIC OFF"
s_mon:     .asciiz "MUSIC ON"
s_meal:    .asciiz "MEAL"
s_snack:   .asciiz "SNACK"
s_g_lr:    .asciiz "LEFT/RIGHT"
s_g_hl:    .asciiz "HIGH/LOW"
s_g_catch: .asciiz "CATCH"
s_name:    .asciiz "NAME"
t_age:     .asciiz "AGE"
s_days:    .asciiz " DAYS"
t_weight:  .asciiz "WEIGHT"
s_grams:   .asciiz " G"
t_gen:     .asciiz "GEN"
s_time:    .asciiz "TIME"
s_hungry:  .asciiz "HUNGRY"
s_happyt:  .asciiz "HAPPY"
s_disct:   .asciiz "DISCIPLINE"
s_lr_q:    .asciiz "WHICH WAY?"
s_lr_k:    .asciiz "<<<             >>>"   ; izquierda = DIRECCION, derecha = DATOS
s_hl_q:    .asciiz "HIGH OR LOW?"
s_hl_k:    .asciiz "<LOW    HIGH>"
s_number:  .asciiz "NUMBER "
s_next:    .asciiz "NEXT   "
s_catch_q: .asciiz "CATCH!"
s_yes:     .asciiz "YES!"
s_no:      .asciiz "NO..."
s_gone1:   .asciiz "WENT HOME..."
s_gone2:   .asciiz "DATA: NEW EGG"

    .include "text.asm"
    .include "tama_art.asm"

; ============================================================================
;  VARIABLES
; ============================================================================
; --- estado guardado (48 bytes, en este orden: la EEPROM es una copia) -----
st_begin:
s_magic:    .space 1
s_ver:      .space 1
s_stage:    .space 1
s_form:     .space 1
s_hunger:   .space 1     ; 0..4
s_happy:    .space 1     ; 0..4
s_disc:     .space 1     ; disciplina 0..4
s_weight:   .space 1
s_poops:    .space 1     ; 0..4
s_sick:     .space 1     ; medicinas que faltan
s_sleep:    .space 1
s_lights:   .space 1
s_mist:     .space 1     ; fallos de cuidado en esta etapa
s_call:     .space 1     ; CALL_*
s_gen:      .space 1     ; generacion (cuantas mascotas)
s_age:      .space 1     ; dias
s_snacks:   .space 1
s_life:     .space 1     ; adulto: se va al cumplir estos dias
s_tvalid:   .space 1     ; s_last es hora de verdad
s_music:    .space 1     ; 1 = musica de los menus quitada
s_pad:      .space 4
                         ; (SIG_LEN: hasta aqui se compara para decidir si grabar)
s_callt:    .space 1     ; minutos de llamada que quedan
s_hungt:    .space 1     ; minutos para el siguiente corazon de hambre
s_happt:    .space 1
s_poopt:    .space 1
s_stg_lo:   .space 1     ; minutos para la siguiente etapa
s_stg_hi:   .space 1
s_day_lo:   .space 1     ; minutos del dia de edad en curso
s_day_hi:   .space 1
s_sickt_lo: .space 1     ; minutos malo
s_sickt_hi: .space 1
s_negl_lo:  .space 1     ; minutos con hambre y triste del todo
s_negl_hi:  .space 1
s_faket:    .space 1     ; minutos para el siguiente capricho
s_lightt:   .space 1     ; minutos dormido con la luz encendida
s_last0:    .space 1     ; ultimo minuto simulado (minutos locales, 24 bits)
s_last1:    .space 1
s_last2:    .space 1
s_mod_lo:   .space 1     ; su minuto del dia
s_mod_hi:   .space 1
s_pad2:     .space 4
s_sum:      .space 1
st_end:

sig_copy:   .space 24       ; = SIG_LEN (.space necesita un numero: casm resuelve los = al final)

; --- interfaz ---------------------------------------------------------------
mode:       .space 1
sel:        .space 1
menu_i:     .space 1
menu_n:     .space 1
page:       .space 1
dirty:      .space 1
quiet:      .space 1
tick:       .space 1
frame_per:  .space 1
scr_on:     .space 1
scr_prev:   .space 1
ev_flags:   .space 1
ev_tmp:     .space 1
sec_cnt:    .space 1
rst_on:     .space 1     ; reset: 0 no, 1 contando, 2 hecho (esperar a soltar)
rst_num:    .space 1
nortc_cnt:  .space 1
msg_t:      .space 1     ; fotogramas que le quedan al aviso de la musica
lpd:        .space 1     ; pulsador DATOS: nivel anterior, fase, fotogramas
lpd_st:     .space 1
lpd_cnt:    .space 1
lpr:        .space 1     ; pulsador DIRECCION: igual
lpr_st:     .space 1
lpr_cnt:    .space 1     ; minutos sin hora real desde la ultima grabacion     ; segundo que se esta enseñando en la cuenta atras
pet_x:      .space 1
face:       .space 1
bob:        .space 1
jump:       .space 1
sing:       .space 1     ; 1 = canturrea en este fotograma (se ve la nota)
chirp_cd:   .space 1     ; fotogramas que faltan para poder volver a canturrear
inv:        .space 1
anim_kind:  .space 1
anim_step:  .space 1
; juegos
g_round:    .space 1
g_wins:     .space 1
g_phase:    .space 1
g_wait:     .space 1
g_guess:    .space 1
g_num:      .space 1
g_next:     .space 1
g_ok:       .space 1
g_px:       .space 1
g_ix:       .space 1
g_iy:       .space 1
; mandos
dir_prev:   .space 1
dat_prev:   .space 1
in_dat:     .space 1
in_dir:     .space 1
in_datp:    .space 1
in_dirp:    .space 1
; reloj
now0:       .space 1
now1:       .space 1
now2:       .space 1
now_mlo:    .space 1
now_mhi:    .space 1
gap_lo:     .space 1
gap_hi:     .space 1
; sonido
snd_lo:     .space 1
snd_hi:     .space 1
song_i:     .space 1     ; nota siguiente de MENU_SONG
; dibujo
cur_form:   .space 1
d_face:     .space 1
d_frame:    .space 1
d_col:      .space 1
d_row:      .space 1
q0:         .space 1
q1:         .space 1
q2:         .space 1
q3:         .space 1
cnt:        .space 1
cnt2:       .space 1
cnt3:       .space 1
pet_wink:   .space 1     ; mimos: 0 = corazon, 1 = guiño
flush_had:  .space 1
gal_form:   .space 1     ; galeria: cuerpo y cara que se ven
gal_face:   .space 1     ; cacas que habia al empezar la ducha
gw_col:     .space 1     ; columna de la mascota en los juegos (game_wait_pet)
fx_full:    .space 1
fx_empty:   .space 1
ptr_lo:     .space 1
ptr_hi:     .space 1
