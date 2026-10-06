; ============================================================================
;  play.asm  -  teclado musical: tocar, grabar, ensayar el ritmo, reproducir
;               y guardar canciones (compi)
;
;  Notas de DO3 a DO8 (61, cinco octavas). Abajo se dibuja un teclado de
;  dos octavas (25 teclas) con un punto en la nota activa; cuando la nota
;  sale por arriba o por abajo, el teclado se desplaza una octava (la
;  escala sube o baja). Arriba, el modo actual y la cancion.
;
;  Mandos:
;     DIRECCION pulsa  -> siguiente modo: PIANO -> EDIT -> RHYTHM -> PLAY ->
;                         FILES -> PIANO ...
;     DIRECCION gira   -> posicion: el cursor en EDIT, la nota de partida en
;                         RHYTHM/PLAY, la fila en FILES
;     DATOS gira       -> nota del teclado (se para en DO3 y en DO8); en
;                         FILES, tambien la fila
;     DATOS pulsa      -> tocar / insertar / accion, segun el modo
;
;  No hay salida al sistema desde el programa: se sale cambiando el
;  interruptor SW_MODE a EDIT (como pong.asm o calc.asm).
;
;  Modos:
;     PIANO     pulsar DATOS toca la nota marcada mientras se mantiene.
;     EDIT      componer. La lista de arriba muestra la pagina de 10 notas
;               del cursor, con la nota bajo el cursor en inverso; el cursor
;               puede quedar "detras de la ultima" para seguir anadiendo.
;               Al poner el cursor sobre una nota, el teclado salta a ella.
;               Pulsacion CORTA de DATOS: inserta la nota marcada DELANTE de
;               la del cursor (con el ritmo por defecto) y avanza el cursor.
;               Pulsacion LARGA con el cursor sobre una nota: si la marcada
;               en el teclado es la misma, la BORRA; si es otra, la
;               SUSTITUYE (conservando su ritmo).
;     RHYTHM    cada pulsacion de DATOS toca la nota de la posicion mientras
;               se mantenga pulsado, y GRABA ese ritmo (duracion y silencio
;               previo); avanza a la siguiente. Al final vuelve a empezar.
;               Tras mover la posicion a mano, la primera nota conserva su
;               silencio (no se mide desde la ultima pulsacion).
;     PLAY      pulsar DATOS reproduce la cancion sola desde la posicion
;               elegida, con su ritmo; otra pulsacion la para.
;     FILES     NEW SONG + 32 canciones: cada fila lleva como titulo las 3
;               primeras notas y la longitud. Pulsacion CORTA cambia la
;               accion (LOAD -> SAVE -> DEL, se ve en la fila de estado),
;               LARGA la ejecuta. En NEW SONG la larga vacia la cancion.
;
;  DONDE SE GUARDAN LAS CANCIONES: en la propia RAM del programa, y de ahi a
;  la flash grabando el programa ENTERO en su slot (PORT_PROG_SAVE):
;     0x4000-0xBFFF  banco: 32 canciones de 1 KiB = 512 notas x 2 bytes
;     0xC000-0xC03F  longitud de cada cancion del banco (16 bits, bajo/alto)
;     0xC080-0xC081  longitud de la cancion de trabajo
;     0xC400-0xC7FF  la cancion de trabajo (la que se toca/graba/reproduce)
;  Cada nota ocupa 2 bytes (16 bits): nota (6 bits, 0..60 = DO3..DO8) +
;  duracion (5 bits) + silencio previo (5 bits):
;     byte 0 = nota (bits 0-5) + duracion bits 0-1 (en los bits 6-7)
;     byte 1 = duracion bits 2-4 (bits 0-2) + silencio (bits 3-7)
;  Duracion y silencio son un INDICE (0..31) en TIME_TBL, tiempos en pasos
;  de 16 ms de 0 a 3,2 s, finos para lo corto y gruesos para lo largo (ver
;  la tabla y note_unpack/note_pack). Longitud 0 = cancion vacia; hasta
;  MAX_NOTES=512.
;  Solo SAVE y DEL (en FILES) escriben la flash (~1 s, "SAVING..."); LOAD y
;  NEW SONG solo tocan la RAM. Como se graba la RAM entera, al volver a
;  arrancar el programa tambien se recupera la cancion de trabajo que habia
;  en ese momento.
;  OJO: volver a ENVIAR play.bin desde el ordenador (compi_send) sustituye
;  el slot entero y las canciones se pierden. Para conservarlas, antes:
;     python3 tools/compi_recv.py --port /dev/ttyACM0 --slot 22 -o copia.bin
;  Se graba en su propio slot, sea cual sea (PORT_CUR_SLOT): se puede mover.
;
;  Ensamblar y enviar al slot 22:
;     python3 tools/casm.py programs/play.asm -o programs/play.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 22 programs/play.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 22

    .name "PLAY"

    .category PROGRAM
    .org 0x0000

; --- puertos ---------------------------------------------------------------
P_TEXT     = 0x0400
P_ATTR     = 0x0500
P_DIR_POS  = 0x0600
P_DIR_BTN  = 0x0601
P_DAT_POS  = 0x0602
P_DAT_BTN  = 0x0603
P_T3       = 0x0623      ; 8 ms/paso (ritmo del bucle)
P_T4       = 0x0624      ; 16 ms/paso (duracion de nota y silencio: nunca a la vez)
P_SND_NOTE = 0x0632      ; nota MIDI (0 = silencio)
P_SND_DUR  = 0x0633      ; duracion automatica x10 ms (0 = sostenida)
P_PROG_SAVE = 0x0641     ; OUT slot: graba la RAM entera ahi; IN = 1 si bien
P_CUR_SLOT  = 0x0643     ; IN: el slot de este programa (donde se graba)

; --- constantes --------------------------------------------------------------
NOTE_COUNT  = 61         ; DO3..DO8: 5 octavas exactas (nota 0..60, 6 bits)
BASE_MIDI   = 48         ; DO3 (la octava 2 se oia mal en el piezo)
KB_SPAN     = 24         ; el teclado dibujado: 2 octavas (25 teclas) desde [kb_base]
KB_TOP_BASE = 36         ; base mas alta (DO6..DO8)
MAX_NOTES   = 512        ; notas por cancion (2 bytes cada una = 1 KiB)
MAX_HI      = 2          ; byte alto de MAX_NOTES (512 = 0x0200)
FILE_COUNT  = 32
BANK_HI     = 0x40       ; banco de canciones: 0x4000, 1 KiB cada una
LENTAB      = 0xC000     ; longitudes del banco (32 x 16 bits)
len_lo      = 0xC080     ; longitud de la cancion de trabajo
len_hi      = 0xC081
WORK        = 0xC400     ; notas de la cancion de trabajo
DEF_DUR     = 13         ; RECORD: TIME_TBL[13] = 16 x 16 ms = 256 ms por nota
DEF_GAP     = 8          ; RECORD: TIME_TBL[8]  =  8 x 16 ms = 128 ms de silencio
LONG_FRAMES = 70         ; pulsacion larga: ~70 fotogramas de ~8 ms
LIST_ROWS   = 5          ; filas visibles de la lista de FILES (filas 1-5)
ATTR_INVERSE = 0x01

MODE_PIANO  = 0
MODE_EDIT   = 1
MODE_RHYTHM = 2
MODE_PLAY   = 3
MODE_FILES  = 4
MODE_COUNT  = 5

KB_X0   = 4              ; teclado: 15 blancas de 8 px desde x=4
KB_Y0   = 34             ; borde de arriba
KB_Y1   = 63             ; borde de abajo
BK_H    = 18             ; alto de las negras
DOT_WY  = 57             ; punto en tecla blanca (3x3, encendido)
DOT_BY  = 46             ; punto en tecla negra (3x3, apagado sobre la negra)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    MOV AL,#0
    STA [mode],AL
    STA [rpos_lo],AL
    STA [rpos_hi],AL
    STA [btn_down],AL
    STA [files_sel],AL
    STA [files_top],AL
    STA [files_act],AL
    STA [play_state],AL
    MOV AL,#24               ; empieza en DO5, con el teclado en DO4..DO6
    STA [cur_note],AL
    MOV AL,#12
    STA [kb_base],AL
    ; la cancion de trabajo se conserva: viene de la ultima grabacion del
    ; programa (SAVE/DEL de FILES graban la RAM entera). Solo se valida.
    LDA BL,[len_lo]
    LDA BH,[len_hi]
    CALL len_valid
    STA [len_lo],BL
    STA [len_hi],BH
    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    MOV AL,#0
    OUT (P_SND_DUR),AL       ; notas sostenidas (la duracion es "pegajosa")
    CALL redraw_all

main_l:
    ; pulsador DIRECCION, con flanco: siguiente modo
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ ml_dir_done
    CMP BL,#0
    JMPNZ ml_dir_done        ; sigue pulsado: no es una pulsacion nueva
    CALL next_mode
ml_dir_done:
    CALL poll_addr_rot
    CALL poll_dat_rot
    CALL poll_dat_btn
    CALL tick_play
    MOV AL,#1
    CALL frame_wait
    JMP main_l

; ============================================================================
;  ARITMETICA DE 16 BITS (posiciones y longitudes llegan a 512)
; ============================================================================
; --- len_valid: BX = una longitud leida de la RAM; si pasa de MAX_NOTES
; (dato raro), sale BX = 0 ------------------------------------------------
len_valid:
    MOV AL,BH
    CMP AL,#MAX_HI
    JMPC lv_ok               ; alto < 2: <= 511
    JMPNZ lv_bad             ; alto > 2
    MOV AL,BL
    CMP AL,#0
    JMPZ lv_ok               ; justo 512
lv_bad:
    MOV BX,#0
lv_ok:
    RET

; --- len_zero: Z=1 si la cancion de trabajo esta vacia ---------------------
len_zero:
    LDA AL,[len_lo]
    OR  AL,[len_hi]
    RET

; --- rpos_lt_len: C=1 si [rpos] < longitud (hay nota en esa posicion) ----
rpos_lt_len:
    LDA BL,[rpos_lo]
    LDA BH,[rpos_hi]
    LDA DL,[len_lo]
    LDA DH,[len_hi]
    CMP BX,DX                ; CMP de 16 bits (ISA 2): C = rpos < longitud
    RET

; --- rpos_set: BX -> [rpos] ------------------------------------------------
rpos_set:
    STA [rpos_lo],BL
    STA [rpos_hi],BH
    RET

; --- rpos_get / len_get: [rpos] / longitud -> BX --------------------------
rpos_get:
    LDA BL,[rpos_lo]
    LDA BH,[rpos_hi]
    RET
len_get:
    LDA BL,[len_lo]
    LDA BH,[len_hi]
    RET

; --- put_n16: BX (0..999) en 3 cifras en CH/CL; avanza CL ----------------
put_n16:
    MOV AL,BL
    MOV AH,BH
    MOV DL,#100
    DIV DL                   ; AL = centenas (<= 9), AH = resto
    PUSH AH
    ADD AL,#'0'
    CALL putc
    POP AL
    CALL put2
    RET

; ============================================================================
;  CANCION DE TRABAJO: entradas de 2 bytes por nota
; ============================================================================
; --- note_ptr: BX = indice de nota -> BX = su entrada (WORK + 2*indice) ---
note_ptr:
    MOV AL,BL
    MOV AH,BH
    MOV BX,#WORK
    ADD BX,AL
    ADD BX,AL
    SHL AH
    ADD BH,AH
    RET

; --- note_unpack: BX = entrada -> [un_note], [un_dur], [un_gap] (indices
; de TIME_TBL para duracion y silencio) -------------------------------------
note_unpack:
    LDA AL,[BX]
    MOV CL,AL
    AND AL,#0x3F
    STA [un_note],AL
    MOV AL,CL
    SHR AL,#6
    STA [un_dur],AL          ; bits 0-1 de la duracion
    INC BX
    LDA AL,[BX]
    MOV CL,AL
    AND AL,#0x07
    SHL AL,#2
    OR  AL,[un_dur]
    STA [un_dur],AL          ; + bits 2-4
    MOV AL,CL
    SHR AL,#3
    STA [un_gap],AL
    RET

; --- note_pack: [un_note], [un_dur], [un_gap] -> entrada BX ----------------
note_pack:
    LDA AL,[un_dur]
    AND AL,#0x03
    SHL AL,#6
    OR  AL,[un_note]
    STA [BX],AL
    INC BX
    LDA AL,[un_gap]
    SHL AL,#3
    MOV CL,AL
    LDA AL,[un_dur]
    SHR AL,#2
    OR  AL,CL
    STA [BX],AL
    RET

; --- time_idx: AL = tiempo medido (pasos de 16 ms) -> AL = indice de
; TIME_TBL (el primero que llega a ese tiempo; 31 si se pasa de todo) ----
time_idx:
    MOV CL,AL
    MOV BX,#TIME_TBL
    MOV DL,#0
ti_l:
    LDA AL,[BX]
    CMP AL,CL
    JMPNC ti_d               ; TIME_TBL[i] >= medido
    INC BX
    ADD DL,#1
    CMP DL,#31
    JMPNZ ti_l
ti_d:
    MOV AL,DL
    RET

; --- time_val: AL = indice -> AL = pasos de 16 ms (TIME_TBL[AL]) ----------
time_val:
    MOV CL,AL
    MOV BX,#TIME_TBL
    ADD BX,CL
    LDA AL,[BX]
    RET

; --- rpos_entry: entrada de la nota [rpos] -> [un_*], y BX = esa entrada --
rpos_entry:
    CALL rpos_get
    CALL note_ptr
    PUSH BL
    PUSH BH
    CALL note_unpack
    POP BH
    POP BL
    RET

; ============================================================================
;  ENTRADA
; ============================================================================
; --- next_mode: DIRECCION pulsado -> el modo siguiente (con vuelta). EDIT
; empieza con el cursor al final (para seguir anadiendo); RHYTHM y PLAY,
; en la primera nota ---------------------------------------------------------
next_mode:
    LDA AL,[mode]
    ADD AL,#1
    CMP AL,#MODE_COUNT
    JMPNZ nm_set
    MOV AL,#0
nm_set:
    STA [mode],AL
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    STA [btn_down],AL        ; una pulsacion a medias no sigue en otro modo
    STA [rpos_lo],AL
    STA [rpos_hi],AL
    STA [files_act],AL
    STA [play_state],AL      ; para una reproduccion en marcha
    MOV AL,#1
    STA [rh_fresh],AL
    LDA AL,[mode]
    CMP AL,#MODE_EDIT
    JMPNZ nm_draw
    CALL len_get
    CALL rpos_set
nm_draw:
    CALL redraw_all
    RET

; --- poll_addr_rot: DIRECCION gira -> posicion (cursor en EDIT, nota de
; partida en RHYTHM/PLAY, fila en FILES), un paso por detente -------------
poll_addr_rot:
    IN  AL,(P_DIR_POS)
    LDA BL,[dir_prev]
    STA [dir_prev],AL
    SUB AL,BL
    JMPZ par_done
    JMPN par_neg
    STA [rot_n],AL
par_up_l:
    CALL addr_up
    LDA AL,[rot_n]
    SUB AL,#1
    STA [rot_n],AL
    JMPNZ par_up_l
    RET
par_neg:
    NOT AL
    ADD AL,#1
    STA [rot_n],AL
par_dn_l:
    CALL addr_down
    LDA AL,[rot_n]
    SUB AL,#1
    STA [rot_n],AL
    JMPNZ par_dn_l
par_done:
    RET

addr_up:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ su_files
    CMP AL,#MODE_PIANO
    JMPZ au_ret
    CMP AL,#MODE_EDIT
    JMPNZ su_pos
    CALL rpos_lt_len         ; EDIT: hasta "detras de la ultima", sin vuelta
    JMPNC au_ret
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL replay_show_pos
au_ret:
    RET

addr_down:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sd_files
    CMP AL,#MODE_PIANO
    JMPZ ad_ret
    CMP AL,#MODE_EDIT
    JMPNZ sd_pos
    LDA AL,[rpos_lo]         ; EDIT: hasta la primera, sin vuelta
    OR  AL,[rpos_hi]
    JMPZ ad_ret
    CALL rpos_get
    DEC BX
    CALL rpos_set
    CALL replay_show_pos
ad_ret:
    RET

; --- poll_dat_rot: DATOS gira -> nota (o fila en FILES, o posicion en
; REPLAY/PLAY), un paso por detente --------------------------------------
poll_dat_rot:
    IN  AL,(P_DAT_POS)
    LDA BL,[dat_prev]
    STA [dat_prev],AL
    SUB AL,BL
    JMPZ pdr_done
    JMPN pdr_neg
    STA [rot_n],AL
pdr_up_l:
    CALL step_up
    LDA AL,[rot_n]
    SUB AL,#1
    STA [rot_n],AL
    JMPNZ pdr_up_l
    RET
pdr_neg:
    NOT AL
    ADD AL,#1
    STA [rot_n],AL
pdr_dn_l:
    CALL step_down
    LDA AL,[rot_n]
    SUB AL,#1
    STA [rot_n],AL
    JMPNZ pdr_dn_l
pdr_done:
    RET

step_up:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ su_files
    LDA AL,[cur_note]
    ADD AL,#1
    CMP AL,#NOTE_COUNT
    JMPZ su_ret              ; ya en DO8: se queda
    CALL set_note
su_ret:
    RET
su_files:
    LDA AL,[files_sel]
    ADD AL,#1
    CMP AL,#(FILE_COUNT+1)
    JMPNZ su_fset
    MOV AL,#0
su_fset:
    STA [files_sel],AL
    MOV AL,#0
    STA [files_act],AL
    CALL draw_files
    RET
su_pos:
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ su_r_done          ; durante PLAY no se mueve la posicion a mano
    CALL len_zero
    JMPZ su_r_done
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL rpos_lt_len
    JMPC su_r_show
    MOV BX,#0                ; pasada la ultima -> la primera
    CALL rpos_set
su_r_show:
    MOV AL,#1
    STA [rh_fresh],AL        ; posicion movida a mano (ver pdb_replay_start)
    CALL replay_show_pos
su_r_done:
    RET

step_down:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sd_files
    LDA AL,[cur_note]
    CMP AL,#0
    JMPZ sd_ret              ; ya en DO3: se queda
    SUB AL,#1
    CALL set_note
sd_ret:
    RET
sd_files:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPNZ sd_fdec
    MOV AL,#(FILE_COUNT+1)
sd_fdec:
    SUB AL,#1
    STA [files_sel],AL
    MOV AL,#0
    STA [files_act],AL
    CALL draw_files
    RET
sd_pos:
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ sd_r_done
    CALL len_zero
    JMPZ sd_r_done
    LDA AL,[rpos_lo]
    OR  AL,[rpos_hi]
    JMPNZ sd_r_dec
    CALL len_get             ; antes de la primera -> la ultima
    JMP sd_r_set
sd_r_dec:
    CALL rpos_get
sd_r_set:
    DEC BX
    CALL rpos_set
    MOV AL,#1
    STA [rh_fresh],AL
    CALL replay_show_pos
sd_r_done:
    RET

; --- set_note: AL = nota nueva (0..24): mueve el punto, actualiza la linea
; de la nota y, si esta sonando por una pulsacion, cambia el tono --------
set_note:
    PUSH AL
    MOV AL,#0
    STA [dot_on],AL
    CALL draw_dot            ; borra el punto de la nota anterior
    POP AL
    STA [cur_note],AL
    CALL kb_follow           ; la escala sube/baja si la nota se sale
    MOV AL,#1
    STA [dot_on],AL
    CALL draw_dot
    CALL show_note_line
    LDA AL,[btn_down]
    CMP AL,#0
    JMPZ sn_done
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ sn_done
    CALL sound_cur
sn_done:
    RET

; --- kb_follow: si [cur_note] queda fuera del teclado dibujado
; ([kb_base]..[kb_base]+KB_SPAN), lo desplaza de octava en octava hasta
; que entre y lo vuelve a dibujar -- "la escala sube o baja" ------------
kb_follow:
    LDA AL,[kb_base]
    STA [kf_old],AL
kf_l:
    LDA AL,[cur_note]
    LDA BL,[kb_base]
    CMP AL,BL
    JMPNC kf_not_below
    MOV AL,BL                ; por debajo: una octava abajo
    SUB AL,#12
    STA [kb_base],AL
    JMP kf_l
kf_not_below:
    SUB AL,BL
    CMP AL,#(KB_SPAN+1)
    JMPC kf_in
    MOV AL,BL                ; por encima: una octava arriba
    ADD AL,#12
    STA [kb_base],AL
    JMP kf_l
kf_in:
    LDA AL,[kb_base]
    LDA BL,[kf_old]
    CMP AL,BL
    JMPZ kf_ret
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ kf_ret              ; en FILES no hay teclado que redibujar
    CALL clsg
    CALL draw_keyboard
kf_ret:
    RET

; --- poll_dat_btn: maquina de estados del pulsador de DATOS ---------------
poll_dat_btn:
    IN  AL,(P_DAT_BTN)
    LDA BL,[btn_down]
    CMP AL,#0
    JMPZ pdb_up
    CMP BL,#0
    JMPNZ pdb_held
    ; --- flanco de bajada: empieza una pulsacion
    MOV AL,#1
    STA [btn_down],AL
    MOV AL,#0
    STA [press_frames],AL
    STA [long_done],AL
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_ret
    CMP AL,#MODE_PLAY
    JMPZ pdb_play_toggle
    CMP AL,#MODE_RHYTHM
    JMPZ pdb_replay_start
    CALL sound_cur           ; PIANO / EDIT: suena la nota marcada
    RET
pdb_play_toggle:
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ pdb_play_stop
    CALL len_zero
    JMPZ pdb_ret
    CALL rpos_lt_len         ; desde la posicion elegida (o el principio)
    JMPC pdb_pt_go
    MOV BX,#0
    CALL rpos_set
pdb_pt_go:
    MOV AL,#0
    OUT (P_T4),AL            ; sin silencio delante de la primera nota
    MOV AL,#1
    STA [play_state],AL      ; 1 = esperando el silencio antes de una nota
    RET
pdb_play_stop:
    MOV AL,#0
    STA [play_state],AL
    OUT (P_SND_NOTE),AL
    CALL show_song
    CALL show_note_line
    RET
pdb_replay_start:
    CALL len_zero
    JMPZ pdb_ret             ; nada que reproducir
    CALL rpos_lt_len
    JMPC pdb_rs_ok
    MOV BX,#0                ; ya se habia llegado al final: vuelve a empezar
    CALL rpos_set
pdb_rs_ok:
    ; silencio antes de esta nota: lo que ha pasado desde que se solto la
    ; anterior (T4, armado a 255 al soltar), pasado a indice de TIME_TBL.
    ; La primera de la cancion, 0; la primera tras mover la posicion a mano
    ; (o al entrar en el modo, [rh_fresh]), conserva el que tenia.
    CALL rpos_entry
    LDA AL,[rpos_lo]
    OR  AL,[rpos_hi]
    JMPNZ pdb_rs_nz
    MOV AL,#0
    STA [un_gap],AL
    JMP pdb_rs_pack
pdb_rs_nz:
    LDA AL,[rh_fresh]
    CMP AL,#0
    JMPNZ pdb_rs_pack
    IN  AL,(P_T4)
    MOV BL,AL
    MOV AL,#255
    SUB AL,BL
    CALL time_idx
    STA [un_gap],AL
pdb_rs_pack:
    CALL rpos_get
    CALL note_ptr
    CALL note_pack
    MOV AL,#0
    STA [rh_fresh],AL
    MOV AL,#255
    OUT (P_T4),AL            ; empieza a medir la duracion de la nota
    CALL replay_show_pos     ; mueve el punto a la nota que toca
    CALL sound_cur
    RET

pdb_held:
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret
    LDA AL,[press_frames]
    ADD AL,#1
    STA [press_frames],AL
    CMP AL,#LONG_FRAMES
    JMPNZ pdb_ret
    ; --- se acaba de cumplir la pulsacion larga
    MOV AL,#1
    STA [long_done],AL
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_files_do
    CMP AL,#MODE_EDIT
    JMPZ edit_long
    MOV AL,#0                ; en los demas modos una nota larga es solo eso
    STA [long_done],AL
    RET

pdb_files_do:
    CALL files_execute
    RET

pdb_up:
    CMP BL,#0
    JMPZ pdb_ret             ; sigue suelto: nada
    ; --- flanco de subida: termina la pulsacion
    MOV AL,#0
    STA [btn_down],AL
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_files_short
    CMP AL,#MODE_PLAY
    JMPZ pdb_ret             ; en PLAY la pulsacion solo arranca/para
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret            ; era una pulsacion larga: ya hizo lo suyo
    LDA AL,[mode]
    CMP AL,#MODE_EDIT
    JMPZ edit_insert
    CMP AL,#MODE_RHYTHM
    JMPZ pdb_replay_next
    RET
pdb_replay_next:
    CALL len_zero
    JMPZ pdb_ret
    CALL rpos_lt_len
    JMPNC pdb_ret
    ; duracion de esta nota: lo que ha bajado T4 desde 255 (pasos de
    ; 16 ms), pasado a indice de TIME_TBL (minimo 1: una nota nunca dura 0)
    IN  AL,(P_T4)
    MOV BL,AL
    MOV AL,#255
    SUB AL,BL
    CALL time_idx
    CMP AL,#0
    JMPNZ pdb_rn_d1
    MOV AL,#1
pdb_rn_d1:
    STA [gap_val],AL
    CALL rpos_entry
    LDA AL,[gap_val]
    STA [un_dur],AL
    CALL note_pack
    MOV AL,#255
    OUT (P_T4),AL            ; empieza a medir el silencio hasta la siguiente
    CALL rpos_get
    INC BX
    CALL rpos_set            ; puede quedar == longitud: "final"
    CALL show_song
    CALL show_note_line
    RET
pdb_files_short:
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret
    LDA AL,[files_sel]
    CMP AL,#0
    JMPZ pdb_ret             ; "NEW SONG" solo tiene una accion
    LDA AL,[files_act]
    ADD AL,#1
    CMP AL,#3
    JMPNZ pdb_fa_set
    MOV AL,#0
pdb_fa_set:
    STA [files_act],AL
    CALL draw_files
pdb_ret:
    RET

; ============================================================================
;  EDIT: insertar, sustituir y borrar en la posicion del cursor ([rpos],
;  0..longitud; "longitud" = detras de la ultima nota)
; ============================================================================
; --- len_minus_rpos: CX = longitud - [rpos] (notas desde el cursor al final)
len_minus_rpos:
    LDA CL,[len_lo]
    LDA CH,[len_hi]
    LDA BL,[rpos_lo]
    LDA BH,[rpos_hi]
    SUB CX,BX                ; resta de 16 bits (ISA 2)
    RET

; --- edit_insert: pulsacion corta -> inserta la nota marcada DELANTE de la
; del cursor (con el ritmo por defecto) y avanza el cursor -----------------
edit_insert:
    LDA AL,[len_hi]
    CMP AL,#MAX_HI
    JMPNZ ei_room            ; 512 notas (alto = 2 solo en el tope)
    CALL beep_low
    RET
ei_room:
    ; hace hueco: las notas [rpos..longitud-1] se corren una posicion hacia
    ; el final con MOVBR (copia hacia ATRAS, ISA 2): origen y destino se
    ; solapan con el destino detras, justo lo que MOVB no puede hacer
    CALL len_minus_rpos
    ADD CX,CX                ; notas -> bytes (2 por nota)
    PUSH CX
    CALL len_get
    CALL note_ptr            ; BX = detras de la ultima nota
    POP CX
    DEC BX                   ; ultimo byte de la ultima nota
    MOV DX,BX
    INC DX
    INC DX                   ; dos bytes mas alla
    MOVBR                    ; con CX = 0 no copia nada (cursor al final)
ei_put:
    LDA AL,[cur_note]
    STA [un_note],AL
    MOV AL,#DEF_DUR
    STA [un_dur],AL
    MOV AL,#DEF_GAP
    STA [un_gap],AL
    CALL rpos_get
    CALL note_ptr
    CALL note_pack
    CALL len_get
    INC BX
    STA [len_lo],BL
    STA [len_hi],BH
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL show_song
    CALL show_note_line
    RET

; --- edit_long: pulsacion larga con el cursor sobre una nota -> si la nota
; marcada en el teclado es la misma, la BORRA; si es otra, la SUSTITUYE
; (conservando su ritmo). Con el cursor al final no hace nada. ------------
edit_long:
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    CALL rpos_lt_len
    JMPNC el_ret
    CALL rpos_entry
    LDA AL,[un_note]
    LDA BL,[cur_note]
    CMP AL,BL
    JMPZ el_delete
    MOV AL,BL                ; sustituir
    STA [un_note],AL
    CALL rpos_get
    CALL note_ptr
    CALL note_pack
    JMP el_done
el_delete:
    ; las notas de detras se corren una posicion hacia delante (MOVW,
    ; destino antes que el origen: la copia hacia adelante es segura)
    CALL len_minus_rpos
    DEC CX                   ; notas detras de la del cursor
    PUSH CL
    PUSH CH
    CALL rpos_get
    INC BX
    CALL note_ptr            ; origen: la nota siguiente
    POP CH
    POP CL
    MOV DL,BL
    MOV DH,BH
    DEC DX
    DEC DX                   ; destino: la del cursor
    MOVW
    CALL len_get
    DEC BX
    STA [len_lo],BL
    STA [len_hi],BH
el_done:
    CALL beep_low
    CALL replay_show_pos     ; el cursor queda sobre la nota siguiente
el_ret:
    RET

; --- replay_show_pos: el punto y la lista siguen a [rpos] -----------------
replay_show_pos:
    CALL rpos_lt_len
    JMPNC rsp_end            ; en el final no hay nota que marcar
    CALL rpos_entry
    LDA AL,[un_note]
    CALL set_note
rsp_end:
    CALL show_song
    CALL show_note_line
    RET

; --- tick_play: avanza la reproduccion automatica de PLAY (una vez por
; vuelta del bucle principal, sin bloquear: se sigue pudiendo parar).
; [play_state]: 0 parado, 1 esperando el silencio antes de la nota [rpos],
; 2 sonando; las dos esperas con T4 (nunca a la vez) -----------------------
tick_play:
    LDA AL,[play_state]
    CMP AL,#0
    JMPZ tp_ret
    CMP AL,#2
    JMPZ tp_sounding
    IN  AL,(P_T4)
    CMP AL,#0
    JMPNZ tp_ret             ; sigue el silencio
    CALL rpos_entry
    LDA AL,[un_dur]
    CALL time_val
    OUT (P_T4),AL            ; duracion grabada
    LDA AL,[un_note]
    CALL set_note            ; el punto y la linea siguen a la nota
    CALL sound_cur
    CALL show_song
    MOV AL,#2
    STA [play_state],AL
tp_ret:
    RET
tp_sounding:
    IN  AL,(P_T4)
    CMP AL,#0
    JMPNZ tp_ret
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL rpos_lt_len
    JMPC tp_next
    MOV AL,#0                ; final de la cancion
    STA [play_state],AL
    CALL show_song
    CALL show_note_line
    RET
tp_next:
    CALL rpos_entry
    LDA AL,[un_gap]
    CALL time_val
    OUT (P_T4),AL            ; silencio grabado antes de la siguiente
    MOV AL,#1
    STA [play_state],AL
    RET

; ============================================================================
;  SONIDO
; ============================================================================
sound_cur:
    MOV AL,#0
    OUT (P_SND_DUR),AL       ; sostenida hasta soltar
    LDA AL,[cur_note]
    ADD AL,#BASE_MIDI
    OUT (P_SND_NOTE),AL
    RET

; pitido corto y grave de "hecho" (borrar, lleno, accion de FILES)
beep_low:
    MOV AL,#6
    OUT (P_SND_DUR),AL
    MOV AL,#48
    OUT (P_SND_NOTE),AL
    RET

; ============================================================================
;  FICHEROS: banco de FILE_COUNT canciones de 1 KiB desde 0x4000, con sus
;  longitudes en LENTAB; SAVE/DEL graban el programa ENTERO en su slot
; ============================================================================
; --- file_base: AL = fichero (0..31) -> BX = sus notas (0x4000 + AL*1024) -
file_base:
    SHL AL,#2
    ADD AL,#BANK_HI
    MOV BH,AL
    MOV BL,#0
    RET

; --- file_len_ptr: AL = fichero -> DX = su longitud en LENTAB ------------
file_len_ptr:
    SHL AL
    MOV DX,#LENTAB
    ADD DX,AL
    RET

; --- file_len: AL = fichero -> BX = su longitud (validada) ---------------
file_len:
    CALL file_len_ptr
    LDA BL,[DX]
    INC DX
    LDA BH,[DX]
    CALL len_valid
    RET

; --- files_execute: pulsacion larga en FILES -> la accion de la fila ------
files_execute:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPZ fe_new
    LDA AL,[files_act]
    CMP AL,#0
    JMPZ fe_load
    CMP AL,#1
    JMPZ fe_save
    ; --- DEL: longitud 0 y graba el programa
    LDA AL,[files_sel]
    SUB AL,#1
    CALL file_len_ptr
    MOV AL,#0
    STA [DX],AL
    INC DX
    STA [DX],AL
    CALL save_self
    MOV BX,#s_deleted
    JMP fe_status
fe_new:
    MOV AL,#0
    STA [len_lo],AL
    STA [len_hi],AL
    STA [rpos_lo],AL
    STA [rpos_hi],AL
    MOV BX,#s_cleared
    JMP fe_status
fe_load:
    LDA AL,[files_sel]
    SUB AL,#1
    CALL file_len
    MOV AL,BL
    OR  AL,BH
    JMPZ fe_empty
    STA [len_lo],BL
    STA [len_hi],BH
    LDA AL,[files_sel]
    SUB AL,#1
    CALL file_base
    MOV DX,#WORK
    MOV CX,#512              ; 1 KiB de notas (MOVW: palabras)
    MOVW
    MOV AL,#0
    STA [rpos_lo],AL
    STA [rpos_hi],AL
    MOV BX,#s_loaded
    JMP fe_status
fe_empty:
    MOV BX,#s_empty
    JMP fe_status
fe_save:
    CALL len_zero
    JMPZ fe_nothing
    LDA AL,[files_sel]
    SUB AL,#1
    CALL file_len_ptr
    LDA AL,[len_lo]
    STA [DX],AL
    INC DX
    LDA AL,[len_hi]
    STA [DX],AL
    LDA AL,[files_sel]
    SUB AL,#1
    CALL file_base
    MOV DL,BL                ; destino: el hueco del fichero
    MOV DH,BH
    MOV BX,#WORK
    MOV CX,#512
    MOVW
    CALL save_self
    MOV BX,#s_saved
    JMP fe_status
fe_nothing:
    MOV BX,#s_nothing
fe_status:
    PUSH BL
    PUSH BH
    CALL beep_low
    CALL draw_files
    MOV CH,#6
    CALL clear_row           ; el mensaje sustituye a "ACTION: ..."
    POP BH
    POP BL
    MOV CX,#0x0601
    CALL puts
    RET

; --- save_self: graba la RAM entera (programa + canciones) en su slot.
; Tarda ~1 s (borra 17 sectores): se avisa antes en pantalla. Si falla,
; deja el aviso de error en la fila de estado y vuelve igual. ---------------
save_self:
    MOV CH,#6
    CALL clear_row
    MOV BX,#s_saving
    MOV CX,#0x0601
    CALL puts
    IN  AL,(P_CUR_SLOT)      ; el slot del que se cargo este programa
    OUT (P_PROG_SAVE),AL
    IN  AL,(P_PROG_SAVE)
    CMP AL,#0
    JMPNZ ss_ok
    MOV BX,#s_savefail
    MOV CX,#0x0601
    CALL puts
    MOV AL,#120
    CALL frame_wait
ss_ok:
    RET

; ============================================================================
;  PANTALLA
; ============================================================================
redraw_all:
    CALL clst
    CALL clsg
    CALL show_mode
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ ra_files
    CALL draw_keyboard
    MOV AL,#1
    STA [dot_on],AL
    CALL draw_dot
    CALL show_song
    CALL show_note_line
    RET
ra_files:
    CALL draw_files
    RET

; --- show_mode: fila 0, "< NOMBRE >" centrado (10 columnas de nombre) -----
show_mode:
    LDA AL,[mode]
    SHL AL,#1
    MOV CL,AL
    MOV BX,#MODE_NAMES
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    MOV CX,#0x0005
    CALL puts
    RET

; --- show_song: filas 1-2. EDIT/RHYTHM/PLAY: la "pagina" de 10 notas que
; contiene [rpos], con esa nota en inverso (con el cursor al final, la
; pagina de la ultima). PIANO: ayuda. --------------------------------------
show_song:
    MOV CH,#1
    CALL clear_row
    MOV CH,#2
    CALL clear_row
    LDA AL,[mode]
    CMP AL,#MODE_PIANO
    JMPNZ ss_list
    MOV BX,#s_help1
    MOV CX,#0x0100
    CALL puts
    MOV BX,#s_help2
    MOV CX,#0x0200
    CALL puts
    RET
ss_list:
    CALL len_zero
    JMPNZ ss_has
    MOV BX,#s_nosong
    MOV CX,#0x0100
    CALL puts
    RET
ss_has:
    ; primera nota de la ventana -> BX
ss_page:
    CALL rpos_lt_len
    JMPC ss_pg_r
    CALL len_get             ; en el final: la pagina de la ultima nota
    DEC BX
    JMP ss_pg
ss_pg_r:
    CALL rpos_get
ss_pg:
    MOV AL,BL
    MOV AH,BH
    MOV CL,#10
    DIV CL                   ; AL = pagina (<= 51)
    MUL CL                   ; AX = pagina * 10
    MOV BL,AL
    MOV BH,AH
ss_first:
    STA [ss_lo],BL
    STA [ss_hi],BH
    MOV AL,#0
    STA [ss_k],AL
ss_l:
    ; ss < longitud?
    LDA AL,[ss_hi]
    LDA BL,[len_hi]
    CMP AL,BL
    JMPNZ ss_cmp
    LDA AL,[ss_lo]
    LDA BL,[len_lo]
    CMP AL,BL
ss_cmp:
    JMPNC ss_done
    ; posicion en pantalla: k<5 fila 1, si no fila 2; columna (k mod 5)*4
    LDA AL,[ss_k]
    MOV AH,#0
    MOV BL,#5
    DIV BL                   ; AL = fila-1, AH = columna/4
    ADD AL,#1
    MOV CH,AL
    MOV AL,AH
    SHL AL,#2
    MOV CL,AL
    PUSH CL
    PUSH CH
    LDA BL,[ss_lo]
    LDA BH,[ss_hi]
    CALL note_ptr
    CALL note_unpack
    LDA AL,[un_note]
    POP CH
    POP CL
    PUSH CL
    PUSH CH
    CALL put_note
    POP CH
    POP CL
    ; la nota de [rpos] (cursor / la que toca) va en inverso
    LDA AL,[ss_lo]
    LDA BL,[rpos_lo]
    CMP AL,BL
    JMPNZ ss_next
    LDA AL,[ss_hi]
    LDA BL,[rpos_hi]
    CMP AL,BL
    JMPNZ ss_next
    MOV AL,#ATTR_INVERSE
    STA [attr_val],AL
    MOV AL,#3
    STA [attr_n],AL
    CALL set_attr
ss_next:
    LDA BL,[ss_lo]
    LDA BH,[ss_hi]
    INC BX
    STA [ss_lo],BL
    STA [ss_hi],BH
    LDA AL,[ss_k]
    ADD AL,#1
    STA [ss_k],AL
    CMP AL,#10
    JMPNZ ss_l
ss_done:
    RET

; --- show_note_line: fila 3, "NOTE C#5" + contador segun el modo ----------
show_note_line:
    MOV CH,#3
    CALL clear_row
    MOV BX,#s_note
    MOV CX,#0x0300
    CALL puts
    LDA AL,[cur_note]
    MOV CX,#0x0305
    CALL put_note
    LDA AL,[mode]
    CMP AL,#MODE_PIANO
    JMPZ snl_ret
    CMP AL,#MODE_EDIT
    JMPNZ snl_rp
    CALL rpos_lt_len         ; EDIT: sobre una nota, su posicion; al final,
    JMPC snl_pos             ; la longitud ("LEN n/512", donde se anade)
    JMP snl_rec
snl_rp:
    ; RHYTHM / PLAY: posicion
    CALL len_zero
    JMPZ snl_ret
    CALL rpos_lt_len
    JMPC snl_pos
    MOV BX,#s_end
    MOV CX,#0x030A
    CALL puts
    RET
snl_pos:
    MOV BX,#s_pos
    MOV CX,#0x030A
    CALL puts
    CALL rpos_get
    INC BX
    MOV CX,#0x030E
    CALL put_n16
    MOV AL,#'/'
    CALL putc
    CALL len_get
    CALL put_n16
    RET
snl_rec:
    MOV BX,#s_len
    MOV CX,#0x030A
    CALL puts
    CALL len_get
    MOV CX,#0x030E
    CALL put_n16
    MOV AL,#'/'
    CALL putc
    MOV BX,#MAX_NOTES
    CALL put_n16
snl_ret:
    RET

; --- draw_files: lista de FILES (NEW SONG + 32 canciones) con
; desplazamiento: LIST_ROWS filas visibles (1-5), la marcada siempre
; dentro; fila 7 = ayuda ----------------------------------------------------
draw_files:
    ; ajusta la ventana para que [files_sel] quede visible
    LDA AL,[files_sel]
    LDA BL,[files_top]
    CMP AL,BL
    JMPNC df_t1
    STA [files_top],AL       ; sel < top: la ventana sube
    JMP df_t2
df_t1:
    SUB AL,BL
    CMP AL,#LIST_ROWS
    JMPC df_t2
    LDA AL,[files_sel]       ; sel >= top+ROWS: la ventana baja
    SUB AL,#(LIST_ROWS-1)
    STA [files_top],AL
df_t2:
    MOV CH,#1
df_clr:
    PUSH CH
    CALL clear_row
    POP CH
    ADD CH,#1
    CMP CH,#8
    JMPNZ df_clr

    MOV AL,#0
    STA [df_k],AL
df_l:
    LDA AL,[files_top]
    LDA BL,[df_k]
    ADD AL,BL
    STA [df_i],AL            ; entrada de la lista (0 = NEW SONG)
    LDA AL,[df_k]
    ADD AL,#1
    MOV CH,AL                ; fila de pantalla
    MOV CL,#0
    LDA AL,[df_i]
    CMP AL,#0
    JMPNZ df_file
    MOV BX,#s_newsong
    CALL puts
    JMP df_mark
df_file:
    ; "S01 C5  D#5 E5  123": las 3 primeras notas como titulo + longitud
    MOV CL,#0
    MOV AL,#'S'
    CALL putc
    LDA AL,[df_i]
    CALL put2                ; S01..S32
    ADD CL,#1
    PUSH CL
    PUSH CH
    LDA AL,[df_i]
    SUB AL,#1
    CALL file_len
    POP CH
    POP CL
    STA [df_len_lo],BL
    STA [df_len_hi],BH
    MOV AL,BL
    OR  AL,BH
    JMPZ df_empty
    MOV AL,#0
    STA [df_n],AL
df_nl:
    LDA AL,[df_len_hi]       ; quedan notas? (n < longitud)
    CMP AL,#0
    JMPNZ df_has
    LDA AL,[df_n]
    LDA BL,[df_len_lo]
    CMP AL,BL
    JMPNC df_len
df_has:
    PUSH CL
    PUSH CH
    LDA AL,[df_i]
    SUB AL,#1
    CALL file_base
    LDA AL,[df_n]
    SHL AL
    ADD BX,AL                ; entrada n de ese fichero
    CALL note_unpack
    LDA AL,[un_note]
    POP CH
    POP CL
    CALL put_note
    ADD CL,#1
    LDA AL,[df_n]
    ADD AL,#1
    STA [df_n],AL
    CMP AL,#3
    JMPNZ df_nl
df_len:
    MOV CL,#16
    LDA BL,[df_len_lo]
    LDA BH,[df_len_hi]
    CALL put_n16
    JMP df_mark
df_empty:
    MOV BX,#s_dashes
    CALL puts
df_mark:
    ; la fila marcada: inverso entero + la accion elegida
    LDA AL,[df_i]
    LDA BL,[files_sel]
    CMP AL,BL
    JMPNZ df_next
    MOV CL,#0
    MOV AL,#ATTR_INVERSE
    STA [attr_val],AL
    MOV AL,#21
    STA [attr_n],AL
    PUSH CH
    CALL set_attr
    POP CH
    LDA AL,[df_i]
    CMP AL,#0
    JMPZ df_next
    PUSH CH
    MOV BX,#s_action         ; fila de estado: "ACTION: LOAD"
    MOV CX,#0x0601
    CALL puts
    LDA AL,[files_act]
    SHL AL,#1
    MOV CL,AL
    MOV BX,#ACT_NAMES
    ADD BX,CL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    MOV CX,#0x0609
    CALL puts
    POP CH
df_next:
    LDA AL,[df_k]
    ADD AL,#1
    STA [df_k],AL
    CMP AL,#LIST_ROWS
    JMPNZ df_l

    MOV BX,#s_fhelp
    MOV CX,#0x0700
    CALL puts
    RET

; ============================================================================
;  TECLADO (framebuffer directo, sin doble bufer: solo cambia el punto)
; ============================================================================
draw_keyboard:
    ; teclas blancas = bloques ENCENDIDOS (azules en la OLED): primero se
    ; enciende todo el rectangulo del teclado (x 4..124, filas KB_Y0..KB_Y1)
    ; byte a byte, directo al framebuffer -- mucho mas rapido que pixel a
    ; pixel --, y luego se apagan los separadores y las negras
    MOV AL,#KB_Y0
    STA [fr_y],AL
dk_row:
    LDA AL,[fr_y]
    MOV BL,#16
    MUL BL
    MOV BL,AL
    MOV BH,AH                ; BX = puerto del primer byte de la fila
    MOV AL,#0x0F             ; x 4..7
    OUT (BX),AL
    INC BX
    MOV CL,#14
    MOV AL,#0xFF             ; x 8..119
dk_byte:
    OUT (BX),AL
    INC BX
    SUB CL,#1
    JMPNZ dk_byte
    MOV AL,#0xF8             ; x 120..124
    OUT (BX),AL
    LDA AL,[fr_y]
    ADD AL,#1
    STA [fr_y],AL
    CMP AL,#(KB_Y1+1)
    JMPNZ dk_row
    ; separadores entre las 15 blancas (14 lineas apagadas)
    MOV AL,#0
    STA [fr_val],AL
    MOV AL,#KB_Y0
    STA [fr_y],AL
    MOV AL,#1
    STA [fr_w],AL
    MOV AL,#(KB_Y1-KB_Y0+1)
    STA [fr_h],AL
    MOV AL,#(KB_X0+8)
    STA [fr_x],AL
dk_v:
    CALL fill_rect
    LDA AL,[fr_x]
    ADD AL,#8
    STA [fr_x],AL
    CMP AL,#(KB_X0+8*15)
    JMPNZ dk_v
    ; negras: APAGADAS, 5 px de ancho centradas en su separador
    MOV AL,#0
    STA [dk_n],AL
dk_b:
    LDA CL,[dk_n]
    MOV BX,#NOTE_KEY
    ADD BX,CL
    LDA AL,[BX]
    AND AL,#0x80
    JMPZ dk_bnext
    LDA AL,[BX]
    AND AL,#0x1F
    ADD AL,#1
    SHL AL,#3
    ADD AL,#(KB_X0-2)
    STA [fr_x],AL
    MOV AL,#KB_Y0
    STA [fr_y],AL
    MOV AL,#5
    STA [fr_w],AL
    MOV AL,#BK_H
    STA [fr_h],AL
    CALL fill_rect
dk_bnext:
    LDA AL,[dk_n]
    ADD AL,#1
    STA [dk_n],AL
    CMP AL,#(KB_SPAN+1)
    JMPNZ dk_b
    RET

; --- draw_dot: punto de [cur_note]; [dot_on]=1 lo pinta, 0 lo borra. En
; blanca (encendida), 3x3 APAGADO abajo; en negra (apagada), 3x3 ENCENDIDO.
draw_dot:
    LDA AL,[cur_note]
    LDA BL,[kb_base]
    SUB AL,BL
    CMP AL,#(KB_SPAN+1)
    JMPC dd_in
    RET                      ; fuera del teclado dibujado (no deberia pasar)
dd_in:
    MOV CL,AL
    MOV BX,#NOTE_KEY
    ADD BX,CL
    LDA AL,[BX]
    MOV DL,AL
    MOV AL,#3
    STA [fr_w],AL
    STA [fr_h],AL
    MOV AL,DL
    AND AL,#0x80
    JMPNZ dd_black
    MOV AL,DL
    SHL AL,#3
    ADD AL,#(KB_X0+3)
    STA [fr_x],AL
    MOV AL,#DOT_WY
    STA [fr_y],AL
    LDA AL,[dot_on]
    XOR AL,#1
    STA [fr_val],AL
    CALL fill_rect
    RET
dd_black:
    MOV AL,DL
    AND AL,#0x1F
    ADD AL,#1
    SHL AL,#3
    ADD AL,#(KB_X0-1)
    STA [fr_x],AL
    MOV AL,#DOT_BY
    STA [fr_y],AL
    LDA AL,[dot_on]
    STA [fr_val],AL
    CALL fill_rect
    RET

; --- fill_rect: rectangulo [fr_x],[fr_y],[fr_w],[fr_h] a [fr_val] (1/0) ----
fill_rect:
    LDA AL,[fr_y]
    STA [px_y],AL
    LDA AL,[fr_h]
    STA [fr_rows],AL
fr_row:
    LDA AL,[fr_x]
    STA [px_x],AL
    LDA AL,[fr_w]
    STA [fr_cols],AL
fr_col:
    CALL put_px
    LDA AL,[px_x]
    ADD AL,#1
    STA [px_x],AL
    LDA AL,[fr_cols]
    SUB AL,#1
    STA [fr_cols],AL
    JMPNZ fr_col
    LDA AL,[px_y]
    ADD AL,#1
    STA [px_y],AL
    LDA AL,[fr_rows]
    SUB AL,#1
    STA [fr_rows],AL
    JMPNZ fr_row
    RET

; --- put_px: pixel ([px_x],[px_y]) a [fr_val], leyendo y reescribiendo el
; byte del framebuffer (puerto = y*16 + x/8, bit 7 = el de la izquierda) --
put_px:
    LDA AL,[px_y]
    MOV BL,#16
    MUL BL                   ; AX = y*16
    MOV BL,AL
    MOV BH,AH
    LDA AL,[px_x]
    SHR AL,#3
    ADD BX,AL
    LDA AL,[px_x]
    AND AL,#7
    MOV CL,AL
    MOV DX,#MASK8
    ADD DX,CL
    LDA CL,[DX]
    IN  AL,(BX)
    LDA AH,[fr_val]
    CMP AH,#0
    JMPZ pp_clr
    OR  AL,CL
    OUT (BX),AL
    RET
pp_clr:
    NOT CL
    AND AL,CL
    OUT (BX),AL
    RET

; ============================================================================
;  TEXTO
; ============================================================================
; --- puts: BX = cadena asciiz, CH = fila, CL = col; sale CL tras el ultimo -
puts:
ps_l:
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ps_d
    CALL putc
    INC BX
    JMP ps_l
ps_d:
    RET

; --- putc: AL = caracter en CH = fila, CL = col; avanza CL ---------------
putc:
    PUSH AL
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    POP AL
    OUT (DX),AL
    ADD CL,#1
    RET

; --- put2: AL (0..99) en 2 cifras en CH/CL; avanza CL ---------------------
put2:
    MOV AH,#0
    MOV DL,#10
    DIV DL
    PUSH AH
    ADD AL,#'0'
    CALL putc
    POP AL
    ADD AL,#'0'
    CALL putc
    RET

; --- put_note: AL = nota (0..24) como 3 caracteres ("C4 ", "C#4") en
; CH/CL; avanza CL 3 ---------------------------------------------------------
put_note:
    MOV AH,#0
    MOV DL,#12
    DIV DL                   ; AL = octava sobre la 3, AH = semitono
    ADD AL,#'3'
    STA [pn_oct],AL
    MOV AL,AH
    SHL AL,#1
    PUSH CL
    MOV CL,AL
    MOV BX,#NOTE_NAMES
    ADD BX,CL
    POP CL
    LDA AL,[BX]
    CALL putc
    INC BX
    LDA AL,[BX]
    CMP AL,#0x20
    JMPZ pn_nat
    CALL putc                ; '#'
    LDA AL,[pn_oct]
    CALL putc
    RET
pn_nat:
    LDA AL,[pn_oct]
    CALL putc
    MOV AL,#0x20
    CALL putc
    RET

; --- set_attr: [attr_n] celdas desde CH/CL a [attr_val] -----------------
set_attr:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x05
    LDA AL,[attr_n]
    STA [sa_n],AL
sa_l:
    LDA AL,[attr_val]
    OUT (DX),AL
    INC DX
    LDA AL,[sa_n]
    SUB AL,#1
    STA [sa_n],AL
    JMPNZ sa_l
    RET

; --- clear_row: borra texto y atributos de la fila CH ---------------------
clear_row:
    MOV AL,CH
    SHL AL,#5
    MOV DL,AL
    MOV DH,#0x04
    MOV CL,#21
    MOV AL,#0
cr_l:
    OUT (DX),AL
    ADD DH,#1
    OUT (DX),AL              ; el atributo de la misma celda (0x0500+)
    SUB DH,#1
    INC DX
    SUB CL,#1
    JMPNZ cr_l
    RET

; --- clst: borra toda la capa de texto y de atributos ---------------------
clst:
    MOV BX,#P_TEXT
    MOV AL,#0
ct_l:
    OUT (BX),AL
    INC BX
    CMP BH,#0x06
    JMPNZ ct_l
    RET

; --- clsg: borra el framebuffer -------------------------------------------
clsg:
    MOV BX,#0x0000
    MOV AL,#0
cg_l:
    OUT (BX),AL
    INC BX
    CMP BH,#0x04
    JMPNZ cg_l
    RET

; --- frame_wait: AL pasos de 8 ms ----------------------------------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; ============================================================================
;  DATOS
; ============================================================================
; tecla de cada nota (DO4..DO6): bit 7 = negra (va sobre el separador que
; hay DESPUES de la blanca indicada), bits 0-4 = indice de tecla blanca
NOTE_KEY:   .db 0x00, 0x80, 0x01, 0x81, 0x02, 0x03, 0x83, 0x04, 0x84, 0x05, 0x85, 0x06
            .db 0x07, 0x87, 0x08, 0x88, 0x09, 0x0A, 0x8A, 0x0B, 0x8B, 0x0C, 0x8C, 0x0D
            .db 0x0E
; TIME_TBL: tiempos de nota/silencio en pasos de 16 ms (0..3,2 s), indice
; de 5 bits: finos para lo corto, gruesos para lo largo
TIME_TBL:   .db 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20
            .db 23, 26, 30, 34, 38, 43, 48, 54, 61, 69, 78, 88, 100, 120, 150, 200
MASK8:      .db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
NOTE_NAMES: .ascii "C C#D D#E F F#G G#A A#B "

MODE_NAMES: .dw s_m_piano, s_m_edit, s_m_rhythm, s_m_play, s_m_files
s_m_piano:  .asciiz "< PIANO  >"
s_m_edit:   .asciiz "<  EDIT  >"
s_m_rhythm: .asciiz "< RHYTHM >"
s_m_play:   .asciiz "<  PLAY  >"
s_m_files:  .asciiz "< FILES  >"

ACT_NAMES:  .dw s_a_load, s_a_save, s_a_del
s_a_load:   .asciiz "LOAD"
s_a_save:   .asciiz "SAVE"
s_a_del:    .asciiz "DEL "

s_help1:    .asciiz "DATA:NOTE  PRESS:PLAY"
s_help2:    .asciiz "ADDR PRESS: NEXT MODE"
s_nosong:   .asciiz "(NO NOTES)"
s_note:     .asciiz "NOTE"
s_len:      .asciiz "LEN"
s_pos:      .asciiz "POS"
s_end:      .asciiz "END - AGAIN"
s_newsong:  .asciiz "NEW SONG (CLEAR)"
s_dashes:   .asciiz "-- EMPTY"
s_action:   .asciiz "ACTION:"
s_fhelp:    .asciiz "SHORT:ACTION LONG:DO"
s_saving:   .asciiz "SAVING..."
s_savefail: .asciiz "SAVE FAILED!"
s_saved:    .asciiz "SAVED"
s_loaded:   .asciiz "LOADED"
s_deleted:  .asciiz "DELETED"
s_cleared:  .asciiz "SONG CLEARED"
s_empty:    .asciiz "THAT FILE IS EMPTY"
s_nothing:  .asciiz "NOTHING TO SAVE"

; --- variables (el banco, las longitudes y la cancion de trabajo van en
; 0x4000-0xC7FF, ver la cabecera -- fuera del .bin) ---------------------------
mode:         .space 1
rh_fresh:     .space 1    ; 1 = RHYTHM: la siguiente nota no mide su silencio
kb_base:      .space 1    ; primera nota del teclado dibujado (0, 12, 24, 36)
kf_old:       .space 1
dir_btn_prev: .space 1
cur_note:     .space 1
dir_prev:     .space 1
dat_prev:     .space 1
rot_n:        .space 1
btn_down:     .space 1
press_frames: .space 1
long_done:    .space 1
rpos_lo:      .space 1    ; posicion en REPLAY/PLAY (16 bits)
rpos_hi:      .space 1
play_state:   .space 1
gap_val:      .space 1
files_sel:    .space 1
files_top:    .space 1
files_act:    .space 1
df_i:         .space 1
df_k:         .space 1
df_n:         .space 1
df_len_lo:    .space 1
df_len_hi:    .space 1
dk_n:         .space 1
dot_on:       .space 1
ss_lo:        .space 1    ; indice de nota en show_song (16 bits)
ss_hi:        .space 1
un_note:      .space 1    ; nota desempaquetada (note_unpack/note_pack)
un_dur:       .space 1
un_gap:       .space 1
ss_k:         .space 1
pn_oct:       .space 1
attr_val:     .space 1
attr_n:       .space 1
sa_n:         .space 1
fr_x:         .space 1
fr_y:         .space 1
fr_w:         .space 1
fr_h:         .space 1
fr_val:       .space 1
fr_rows:      .space 1
fr_cols:      .space 1
px_x:         .space 1
px_y:         .space 1
