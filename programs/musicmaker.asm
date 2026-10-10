; ============================================================================
;  musicmaker.asm  -  teclado musical: tocar, grabar, ensayar el ritmo, reproducir
;               y guardar canciones (compi)
;
;  Notas de DO3 a DO8 (61, cinco octavas). Abajo se dibuja un teclado de
;  dos octavas (25 teclas) con un punto en la nota activa; cuando la nota
;  sale por arriba o por abajo, el teclado se desplaza una octava (la
;  escala sube o baja). Arriba, el modo actual y la cancion.
;
;  Todo se hace en una sola pantalla (EDIT), con un modo REC para marcar
;  el ritmo; aparte solo esta FILES. El cursor de la cancion es como el
;  cabezal de una cinta: la reproduccion lo arrastra.
;
;  EDIT:
;     DATOS gira       -> elige la nota (se para en DO3 y en DO8); cada nota
;                         suena un momento al pasar por ella (por Bluetooth
;                         MIDI, a 1/3 de la fuerza normal)
;     DATOS corta      -> al soltar, inserta la nota marcada en el cursor
;                         (con el cursor al final, la anade) y suena corta
;     DATOS larga      -> borra la nota seleccionada (la del cursor, en
;                         inverso; la seleccion pasa a la siguiente). Con el
;                         cursor al final, la ultima. Mientras se mantiene no
;                         suena nada; al borrar, un pitido grave. El teclado
;                         se queda en la nota borrada (para cambiarla: larga,
;                         girar DATOS, corta)
;     DIRECCION gira   -> mueve el cursor (la nota del cursor va en inverso;
;                         puede quedar "detras de la ultima")
;     DIRECCION corta  -> reproduce desde el cursor hasta el final, con su
;                         ritmo; al acabar el cursor queda al final, listo
;                         para seguir anadiendo. Con el cursor ya al final,
;                         la cancion entera. Otra pulsacion (de DIRECCION o
;                         de DATOS) la para: el cursor se queda en esa nota.
;     DIRECCION larga  -> (~0,6 s, actua sin soltar) entra en REC.
;     LOS DOS a la vez -> SONGS (y desde SONGS, vuelta a EDIT).
;  Arriba a la derecha, el instrumento de la cancion (ver SONGS).
;
;  REC ("REC" en inverso arriba): marcar el ritmo de las notas que ya hay,
;  desde el cursor (si estaba al final, desde el principio). CADA CAMBIO
;  del pulsador DATOS (al pulsar Y al soltar) termina la nota que sonaba y
;  empieza la siguiente: la duracion de cada nota es el tiempo entre dos
;  cambios, y las notas quedan seguidas (silencio 0; la primera conserva el
;  suyo, el tiempo antes del primer cambio no se mide). Suena la nota en
;  curso hasta el cambio siguiente; el cambio que cierra la ultima calla y
;  se queda en REC (sin volver solo a EDIT, para no anadir notas sin
;  querer): los cambios siguientes ya no hacen nada. Se vuelve a EDIT con
;  DIRECCION (corta o larga), que tambien CIERRA la nota que estuviera
;  sonando: dura hasta ahi (asi se marca la ultima, que con REPEAT es lo que
;  pasa hasta volver a empezar). DIRECCION gira mueve el
;  cursor, como en EDIT (y corta lo que se estuviera marcando). Se mide al
;  ms (T1/T2/T4, ver meas_read).
;  CUANTIZAR (QUANT en SONGS: OFF de fabrica, 50% o 100%). Al 100 %, cada
;  duracion se ajusta a la
;  figura mas cercana del pulso: 1/4, 1/2, 1, 1 1/2, 2, 3 o 4 pulsos (QSET). El pulso sale de la primera nota marcada al entrar en REC (que
;  sea una nota "normal") y se va corrigiendo con cada una (1/8 de lo que
;  diga la nota nueva), asi sigue un tempo que se mueve un poco sin que un
;  fallo suelto lo descoloque. Una nota de mas de ~4 1/2 pulsos se guarda
;  tal cual y no cuenta para el pulso (ver rq_*). Al 50 %, se queda a medio
;  camino entre lo marcado y esa figura: corrige los fallos grandes y
;  conserva el matiz. (Con el formato de 4 ms, sin cuantizar ya se reproduce
;  casi tal cual lo marcado: por eso viene en OFF.)
;  Con QUANT OFF, se guarda lo medido (a 4 ms) y lo que se pierde al
;  redondear pasa a la nota siguiente.
;
;  SONGS: INSTR + REPEAT + QUANT + NEW SONG + 32 canciones. DATOS gira cambia de fila; un
;  CLIC en cualquiera de los dos pulsadores hace lo de la fila, y DIRECCION
;  gira el valor de la fila (INSTR, REPEAT, QUANT: siguiente / anterior;
;  cancion: la accion):
;     INSTR     el instrumento siguiente de la cancion de trabajo
;               (PORT_SND_INSTR: ORGAN, PIANO, GUITAR, BELL); suena la nota
;               marcada con el. Se aplica al momento a todo (reproducir, REC,
;               la muestra al girar DATOS), se guarda con SAVE y vuelve con
;               LOAD; NEW SONG lo conserva.
;     REPEAT    NO / YES: al acabar de reproducirse, vuelve a empezar (sin
;               hueco: el tiempo sigue). Como INSTR, va con la cancion (SAVE
;               lo guarda, LOAD lo recupera, NEW SONG lo conserva). En EDIT,
;               "REP" arriba a la izquierda.
;     QUANT     OFF -> 50% -> 100%: cuantizar el ritmo en REC (ver REC).
;               Para todas las canciones (se conserva al reenviar).
;     NEW SONG  DATOS LARGA (no un clic, para no perder la cancion sin
;               querer): vacia la cancion y vuelve a EDIT.
;     S01..S32  titulo = las 3 primeras notas + la longitud. La accion es
;               LOAD; DIRECCION gira la cambia (LOAD -> SAVE -> DEL, se ve en
;               la fila de estado; solo sobre una cancion). Al cambiar de fila
;               o tras hacerla, vuelve a LOAD. LOAD vuelve solo a EDIT, con
;               el cursor al final.
;  DIRECCION larga (o los dos pulsadores a la vez) vuelve a EDIT sin hacer
;  nada.
;
;  No hay salida al sistema desde el programa: se sale cambiando el
;  interruptor SW_MODE a EDIT (como pong.asm o calc.asm).
;
;  DONDE SE GUARDAN LAS CANCIONES: en la propia RAM del programa, y de ahi a
;  la flash grabando el programa ENTERO en su slot (PORT_PROG_SAVE):
;     0x4000-0xBFFF  banco: 32 canciones de 1 KiB = 512 notas x 2 bytes
;     0xC000-0xC03F  longitud de cada cancion del banco (16 bits, bajo/alto)
;     0xC040-0xC05F  instrumento de cada cancion del banco (0..3)
;     0xC060-0xC07F  1 = repetir, de cada cancion del banco
;     0xC080-0xC081  longitud de la cancion de trabajo
;     0xC082         instrumento de la cancion de trabajo
;     0xC083         QUANT: 0 = OFF (de fabrica), 1 = 50 %, 2 = 100 %
;     0xC084         formato de las canciones (1 = el actual; ver arriba)
;     0xC085         1 = repetir la cancion de trabajo
;     0xC400-0xC7FF  la cancion de trabajo (la que se toca/graba/reproduce)
;  Cada entrada ocupa 2 bytes (16 bits): nota (6 bits: 0..60 = DO3..DO8,
;  63 = SILENCIO) + duracion (10 bits, en pasos de 4 ms: hasta ~4 s):
;     byte 0 = nota (bits 0-5) + duracion bits 0-1 (en los bits 6-7)
;     byte 1 = duracion bits 2-9
;  Los silencios son entradas propias (nota 63, "--" en la lista; se elige
;  girando DATOS por debajo de DO3), como en una partitura. Las notas van
;  seguidas; dos iguales seguidas se separan al sonar con un corte de 16 ms
;  quitado al final de la primera (ver pl_start). Longitud 0 = cancion
;  vacia; hasta MAX_NOTES=512 entradas.
;  FORMATO ANTERIOR (hasta 2026-10): duracion y silencio previo de 5 bits
;  cada uno, indices de una tabla de 32 tiempos (OLD_TT) con saltos de hasta
;  50 ms en lo largo. Al arrancar, si [song_fmt] != 1, convert_all pasa
;  todas las canciones al formato nuevo (un silencio previo pasa a ser una
;  entrada de silencio delante): suenan igual.
;  Solo SAVE y DEL (en SONGS) escriben la flash (~1 s, "SAVING..."); LOAD y
;  NEW SONG solo tocan la RAM. Como se graba la RAM entera, al volver a
;  arrancar el programa tambien se recupera la cancion de trabajo que habia
;  en ese momento.
;  Reenviar el programa desde el ordenador NO borra las canciones: la
;  directiva .persist marca su zona (0x4000-0xC7FF) y tools/compi.py send la
;  copia del slot antes de grabar (con --no-persist, se borran).
;  Se graba en su propio slot, sea cual sea (PORT_CUR_SLOT): se puede mover.
;
;  Ensamblar y enviar al slot 22:
;     python3 tools/casm.py programs/musicmaker.asm -o programs/musicmaker.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 22 programs/musicmaker.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 22

    .name "MUSICMAKER"

    .category PROGRAM
    .persist 0x4000, 0xC800   ; banco, longitudes y cancion de trabajo: reenviar
                              ; el programa con tools/compi.py send los conserva
    .org 0x0000

; --- puertos ---------------------------------------------------------------
P_TEXT     = 0x0400
P_ATTR     = 0x0500
P_DIR_POS  = 0x0600
P_DIR_BTN  = 0x0601
P_DAT_POS  = 0x0602
P_DAT_BTN  = 0x0603
P_T1       = 0x0621      ; 2 ms/paso  } REC: medir duraciones y silencios
P_T2       = 0x0622      ; 4 ms/paso  } con mas finura que T4 (ver meas_read)
P_T3       = 0x0623      ; 8 ms/paso (ritmo del bucle)
P_T4       = 0x0624      ; 16 ms/paso (duracion de nota y silencio: nunca a la vez)
P_T5       = 0x0625      ; 32 ms/paso (pasos del menu de DIRECCION mantenido)
P_SND_NOTE = 0x0632      ; nota MIDI (0 = silencio)
P_SND_DUR  = 0x0633      ; duracion automatica x10 ms (0 = sostenida)
P_SND_VEL  = 0x0634      ; velocidad MIDI (solo por Bluetooth; pegajosa)
P_SND_INSTR = 0x0635     ; instrumento (0 ORGAN, 1 PIANO, 2 GUITAR, 3 BELL)
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
ROW_REPEAT  = 1          ; SONGS: fila 0 = INSTR, 1 = REPEAT, 2 = QUANT,
ROW_QUANT   = 2          ; 3 = NEW SONG, 4.. = S01..S32
ROW_NEW     = 3
FIRST_FILE  = 4
Q_MIN_BEAT  = 13         ; pulso minimo (unidades de 4 ms: 52 ms)
Q_MAX_R     = 19         ; >= 19 cuartos de pulso: nota libre, sin ajustar
INSTR_COUNT = 4
BANK_HI     = 0x40       ; banco de canciones: 0x4000, 1 KiB cada una
LENTAB      = 0xC000     ; longitudes del banco (32 x 16 bits)
INSTTAB     = 0xC040     ; instrumento de cada cancion del banco (32 bytes)
REPTAB      = 0xC060     ; 1 = repetir, de cada cancion del banco (32 bytes)
len_lo      = 0xC080     ; longitud de la cancion de trabajo
len_hi      = 0xC081
work_instr  = 0xC082     ; instrumento de la cancion de trabajo (0..3)
quant_mode  = 0xC083     ; QUANT: 0 OFF, 1 50 %, 2 100 %
song_fmt    = 0xC084     ; 1 = formato actual (si no, convert_all al arrancar)
work_rep    = 0xC085     ; 1 = la cancion de trabajo se repite al acabar
TMPBUF      = 0x2000     ; 1 KiB de paso para convert_song
WORK        = 0xC400     ; notas de la cancion de trabajo
DEF_DUR     = 64         ; insertar: 64 x 4 ms = 256 ms
REST        = 63         ; "nota" silencio
CUT_MS      = 16         ; corte entre dos notas iguales seguidas
LONG_FRAMES = 70         ; pulsacion larga: ~70 fotogramas de ~8 ms
HOLD_STEP   = 19         ; DIRECCION larga: 19 x 32 ms (~0,6 s)
LIST_ROWS   = 6          ; filas visibles de la lista de SONGS (1-6; la 7, el estado)
ATTR_INVERSE = 0x01

MODE_EDIT   = 0          ; la pantalla principal (con o sin grabacion, [rec])
MODE_FILES  = 1
PREVIEW_DUR = 12         ; nota de muestra al girar DATOS / al insertar: 120 ms
VEL_FULL    = 100        ; velocidad MIDI normal (por Bluetooth)
VEL_PREVIEW = 33         ; la muestra al girar DATOS: 1/3 (solo MIDI)

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
    STA [abtn_down],AL
    STA [rec],AL
    STA [chord],AL
    MOV AL,#24               ; empieza en DO5, con el teclado en DO4..DO6
    STA [cur_note],AL
    MOV AL,#12
    STA [kb_base],AL
    CALL convert_all         ; canciones del formato anterior, si las hay
    ; la cancion de trabajo se conserva: viene de la ultima grabacion del
    ; programa (SAVE/DEL de FILES graban la RAM entera). Solo se valida.
    LDA BL,[len_lo]
    LDA BH,[len_hi]
    CALL len_valid
    STA [len_lo],BL
    STA [len_hi],BH
    CALL rpos_set            ; EDIT empieza con el cursor al final
    LDA AL,[work_instr]
    CALL instr_set
    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    MOV AL,#0
    OUT (P_SND_DUR),AL       ; notas sostenidas (la duracion es "pegajosa")
    CALL redraw_all

main_l:
    CALL poll_chord
    CALL poll_addr_btn
    CALL poll_addr_rot
    CALL poll_dat_rot
    CALL poll_dat_btn
    CALL tick_play
    ; grabando el ritmo o reproduciendo, sin espera: la pulsacion y el final
    ; de cada nota se atienden en cuanto pasan (con la espera de 8 ms, cada
    ; nota se medía o arrancaba hasta 8 ms tarde, y en la reproduccion ese
    ; retraso se acumulaba nota a nota)
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ main_l
    LDA AL,[rec]
    CMP AL,#0
    JMPNZ main_l
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

; --- note_unpack: BX = entrada -> [un_note], [un_dur_lo/hi] (duracion en
; pasos de 4 ms, 10 bits) ---------------------------------------------------
note_unpack:
    LDA AL,[BX]
    MOV CL,AL
    AND AL,#0x3F
    STA [un_note],AL
    MOV AL,CL
    SHR AL,#6
    STA [un_dur_lo],AL       ; bits 0-1
    INC BX
    LDA AL,[BX]
    MOV CL,AL
    SHL AL,#2
    OR  AL,[un_dur_lo]
    STA [un_dur_lo],AL       ; + bits 2-7
    MOV AL,CL
    SHR AL,#6
    STA [un_dur_hi],AL       ; bits 8-9
    RET

; --- note_pack: [un_note], [un_dur_lo/hi] -> entrada BX --------------------
note_pack:
    LDA AL,[un_dur_lo]
    AND AL,#0x03
    SHL AL,#6
    OR  AL,[un_note]
    STA [BX],AL
    INC BX
    LDA AL,[un_dur_lo]
    SHR AL,#2
    MOV CL,AL
    LDA AL,[un_dur_hi]
    AND AL,#0x03
    SHL AL,#6
    OR  AL,CL
    STA [BX],AL
    RET

; --- ms_to_units: BX = ms -> BX = pasos de 4 ms, redondeado, entre 1 y
; 1023 (no hay desplazamientos de 16 bits: a mano con los dos bytes) -------
ms_to_units:
    ADD BX,#2
    MOV AL,BH
    SHL AL,#6
    MOV CL,BL
    SHR CL,#2
    OR  CL,AL                ; byte bajo
    MOV AL,BH
    SHR AL,#2                ; byte alto
    CMP AL,#4
    JMPC mtu_hi
    MOV AL,#3                ; tope: 1023
    MOV CL,#0xFF
mtu_hi:
    MOV BH,AL
    MOV BL,CL
    MOV AL,BL
    OR  AL,BH
    JMPNZ mtu_ret
    MOV BL,#1                ; nunca 0
mtu_ret:
    RET

; --- units_to_ms: BX = pasos de 4 ms -> BX = ms (x 4) --------------------
units_to_ms:
    MOV AL,BH
    SHL AL,#2
    MOV CL,BL
    SHR CL,#6
    OR  AL,CL
    MOV BH,AL
    SHL BL,#2
    RET

; --- dur_ms: la duracion de [un_dur_lo/hi] -> BX, en ms ------------------
dur_ms:
    LDA BL,[un_dur_lo]
    LDA BH,[un_dur_hi]
    JMP units_to_ms

; --- meas_arm / meas_read: cronometro de la grabacion. meas_arm arranca T1, T2
; y T4 a la vez; meas_read da en BX lo que ha pasado desde entonces, en ms:
; con T1 (2 ms) hasta ~0,5 s, con T2 (4 ms) hasta ~1 s, y despues con T4
; (16 ms, hasta ~4 s). Un temporizador solo dice cuantos pasos ENTEROS han
; pasado: se toma el centro del paso en curso (pasos x 2 + 1 ms con T1...),
; si no cada medida sale de media medio paso corta y, al sumarse, la cancion
; grabada se adelanta (con solo T4, 8 ms por medida). Usan AX, BX y CL. ---
meas_arm:
    MOV AL,#255
    OUT (P_T1),AL
    OUT (P_T2),AL
    OUT (P_T4),AL
    RET
meas_read:
    IN  AL,(P_T1)
    MOV CL,#2
    CMP AL,#0
    JMPNZ mr_mul
    IN  AL,(P_T2)
    MOV CL,#4
    CMP AL,#0
    JMPNZ mr_mul
    IN  AL,(P_T4)
    MOV CL,#16
mr_mul:
    MOV BL,AL
    MOV AL,#255
    SUB AL,BL                ; pasos enteros
    MUL CL                   ; -> ms
    MOV BX,AX
    SHR CL                   ; + medio paso
    ADD BX,CL
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
; --- poll_chord: los DOS pulsadores a la vez -> EDIT <-> FILES. Una vez
; por pulsacion: no se repite hasta soltar los dos. Las pulsaciones que
; forman parte de ella no hacen lo suyo al soltarse ([abtn_long],
; [long_done]; ver tambien los flancos de bajada de cada pulsador) --------
poll_chord:
    IN  AL,(P_DIR_BTN)
    MOV BL,AL
    IN  AL,(P_DAT_BTN)
    CMP AL,#0
    JMPZ pc_one_up
    CMP BL,#0
    JMPZ pc_ret              ; solo DATOS
    LDA AL,[chord]
    CMP AL,#0
    JMPNZ pc_ret             ; ya se hizo en esta pulsacion
    MOV AL,#1
    STA [chord],AL
    STA [abtn_long],AL
    STA [long_done],AL
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pc_edit
    MOV AL,#MODE_FILES
    CALL set_mode
    RET
pc_edit:
    MOV AL,#MODE_EDIT
    CALL set_mode
    RET
pc_one_up:
    CMP BL,#0
    JMPNZ pc_ret
    MOV AL,#0                ; los dos sueltos
    STA [chord],AL
pc_ret:
    RET

; --- poll_addr_btn: pulsador DIRECCION. Corta (al soltar): reproduce /
; para. Larga (~0,6 s, T5): en cuanto se cumple, entra en REC; en FILES,
; vuelve a EDIT. En REC, corta o larga, vuelve a EDIT ----------------------
poll_addr_btn:
    IN  AL,(P_DIR_BTN)
    LDA BL,[abtn_down]
    CMP AL,#0
    JMPZ pab_up
    CMP BL,#0
    JMPNZ pab_held
    MOV AL,#1                ; flanco de bajada
    STA [abtn_down],AL
    MOV AL,#HOLD_STEP
    OUT (P_T5),AL
    LDA AL,[chord]           ; con los dos botones, esta no cuenta
    STA [abtn_long],AL
    LDA AL,[rh_timing]       ; REC: la nota que suena acaba AL PULSAR (no al
    CMP AL,#0                ; soltar, que sumaria lo que dura la pulsacion);
    JMPZ pab_ret             ; al soltar, rec_exit
    CALL rec_close
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    CALL show_song
    CALL show_note_line
    RET
pab_held:
    LDA AL,[abtn_long]
    CMP AL,#0
    JMPNZ pab_ret
    IN  AL,(P_T5)
    CMP AL,#0
    JMPNZ pab_ret
    MOV AL,#1                ; se acaba de cumplir la pulsacion larga
    STA [abtn_long],AL
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pab_files
    LDA AL,[rec]
    CMP AL,#0
    JMPZ rec_enter
    JMP rec_exit
pab_files:
    MOV AL,#MODE_EDIT
    CALL set_mode
    RET
pab_up:
    CMP BL,#0
    JMPZ pab_ret
    MOV AL,#0                ; flanco de subida
    STA [abtn_down],AL
    LDA AL,[abtn_long]
    CMP AL,#0
    JMPNZ pab_ret            ; era larga (o de los dos): ya hizo lo suyo
    LDA AL,[mode]
    CMP AL,#MODE_EDIT
    JMPNZ files_execute      ; SONGS: el clic hace la accion de la fila
    LDA AL,[rec]
    CMP AL,#0
    JMPZ play_toggle
    JMP rec_exit
pab_ret:
    RET

; --- rec_enter: entra en REC desde el cursor (al final: desde el
; principio). Para la reproduccion. Cancion vacia: un pitido y nada --------
rec_enter:
    CALL len_zero
    JMPNZ re_go
    CALL beep_low
    RET
re_go:
    MOV AL,#0
    STA [play_state],AL
    OUT (P_SND_NOTE),AL
    CALL rpos_lt_len
    JMPC re_pos
    MOV BX,#0
    CALL rpos_set
re_pos:
    MOV AL,#0
    STA [rh_timing],AL
    STA [q_beat],AL          ; el pulso sale de la primera nota marcada
    MOV AL,#1
    STA [rec],AL
    STA [rh_fresh],AL
    STA [long_done],AL       ; si DATOS estaba pulsado, al soltar no hace nada
    CALL show_mode
    CALL replay_show_pos
    RET

; --- rec_exit: de REC a EDIT. Si sonaba una nota, la cierra (rec_close);
; si DATOS sigue pulsado, al soltarlo ya no hace nada -----------------------
rec_exit:
    LDA AL,[rh_timing]
    CMP AL,#0
    JMPZ rx_off
    CALL rec_close           ; la nota que sonaba dura hasta aqui
rx_off:
    MOV AL,#0
    STA [rec],AL
    STA [rh_timing],AL
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    STA [long_done],AL
    CALL show_mode
    CALL show_note_line
    RET

; --- play_toggle: reproduce desde el cursor hasta el final, con el cursor
; detras (al acabar queda al final, listo para seguir anadiendo); con el
; cursor ya al final, la cancion entera. Si ya sonaba, la para: el cursor
; se queda en la nota donde paro ---------------------------------------------
play_toggle:
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ play_stop
    CALL len_zero
    JMPZ pt_ret
    CALL rpos_lt_len
    JMPC pt_go
    MOV BX,#0
    CALL rpos_set
pt_go:
    MOV AL,#0
    STA [pl_late_lo],AL
    STA [pl_late_hi],AL
    CALL pl_start
pt_ret:
    RET
play_stop:
    MOV AL,#0
    STA [play_state],AL
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    STA [rh_fresh],AL        ; REC: la siguiente no mide su silencio
    CALL replay_show_pos
    RET

; --- set_mode: AL = modo nuevo (EDIT o FILES). Para el sonido, la
; reproduccion y la grabacion -----------------------------------------------
set_mode:
    STA [mode],AL
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    STA [files_act],AL
    STA [play_state],AL      ; para una reproduccion en marcha
    STA [rec],AL
    MOV AL,#1
    STA [rh_fresh],AL
    STA [long_done],AL       ; si DATOS sigue pulsado, al soltarlo no hace nada
    CALL redraw_all
    RET

; --- poll_addr_rot: DIRECCION gira -> el cursor (EDIT) o la fila
; (FILES), un paso por detente ----------------------------------------------
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
    JMPZ act_next
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ au_ret             ; mientras suena, el cursor lo lleva la cancion
    CALL rpos_lt_len         ; hasta "detras de la ultima", sin vuelta
    JMPNC au_ret
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL rec_moved
    CALL replay_show_pos
au_ret:
    RET

addr_down:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ act_prev
    LDA AL,[play_state]
    CMP AL,#0
    JMPNZ ad_ret
    LDA AL,[rpos_lo]         ; hasta la primera, sin vuelta
    OR  AL,[rpos_hi]
    JMPZ ad_ret
    CALL rpos_get
    DEC BX
    CALL rpos_set
    CALL rec_moved
    CALL replay_show_pos
ad_ret:
    RET

; --- act_next / act_prev: SONGS, DIRECCION gira -> el valor de la fila:
; INSTR, REPEAT y QUANT, el siguiente / anterior (como el clic); en una
; cancion, la accion (LOAD, SAVE, DEL, con vuelta). En NEW SONG, nada -----
act_next:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPZ instr_next
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_toggle
    CMP AL,#FIRST_FILE
    JMPC act_ret
    LDA AL,[files_act]
    ADD AL,#1
    CMP AL,#3
    JMPNZ act_set
    MOV AL,#0
    JMP act_set
act_prev:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPZ instr_prev
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_prev
    CMP AL,#FIRST_FILE
    JMPC act_ret
    LDA AL,[files_act]
    CMP AL,#0
    JMPNZ act_dec
    MOV AL,#3
act_dec:
    SUB AL,#1
act_set:
    STA [files_act],AL
    CALL draw_files
act_ret:
    RET

; --- poll_dat_rot: DATOS gira -> nota (o fila en FILES), un paso por
; detente --------------------------------------------------------------------
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
    CMP AL,#REST
    JMPNZ su_n
    MOV AL,#0                ; del silencio, a DO3
    JMP su_set
su_n:
    ADD AL,#1
    CMP AL,#NOTE_COUNT
    JMPZ su_ret              ; ya en DO8: se queda
su_set:
    CALL set_note
    CALL preview_note
su_ret:
    RET
su_files:
    LDA AL,[files_sel]
    ADD AL,#1
    CMP AL,#(FILE_COUNT+FIRST_FILE)
    JMPNZ su_fset
    MOV AL,#0
su_fset:
    STA [files_sel],AL
    MOV AL,#0
    STA [files_act],AL
    CALL draw_files
    RET
step_down:
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sd_files
    LDA AL,[cur_note]
    CMP AL,#REST
    JMPZ sd_ret              ; ya en el silencio: se queda
    CMP AL,#0
    JMPNZ sd_dec
    MOV AL,#REST             ; por debajo de DO3: el silencio
    JMP sd_set
sd_dec:
    SUB AL,#1
sd_set:
    CALL set_note
    CALL preview_note
sd_ret:
    RET
sd_files:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPNZ sd_fdec
    MOV AL,#(FILE_COUNT+FIRST_FILE)
sd_fdec:
    SUB AL,#1
    STA [files_sel],AL
    MOV AL,#0
    STA [files_act],AL
    CALL draw_files
    RET
; --- preview_note: EDIT, DATOS girado -> la nota marcada suena un momento
; (no mientras se reproduce la cancion ni con DATOS pulsado); por Bluetooth
; MIDI, con la mitad de velocidad que al insertarla --------------------------
preview_note:
    LDA AL,[mode]
    CMP AL,#MODE_EDIT
    JMPNZ pv_ret
    LDA AL,[play_state]
    OR  AL,[btn_down]
    JMPNZ pv_ret
    MOV AL,#VEL_PREVIEW      ; por Bluetooth MIDI, a la mitad de fuerza que
    OUT (P_SND_VEL),AL       ; al insertarla (el zumbador suena igual)
    CALL sound_short
    MOV AL,#VEL_FULL         ; la velocidad es pegajosa: el resto, normal
    OUT (P_SND_VEL),AL
pv_ret:
    RET

; --- set_note: AL = nota nueva (0..24): mueve el punto y actualiza la
; linea de la nota
set_note:
    PUSH AL
    MOV AL,#0
    STA [dot_on],AL
    CALL draw_dot            ; borra el punto de la nota anterior
    POP AL
    STA [cur_note],AL
    CMP AL,#REST
    JMPZ sn_rest             ; el silencio no tiene tecla ni punto
    CALL kb_follow           ; la escala sube/baja si la nota se sale
    MOV AL,#1
    STA [dot_on],AL
    CALL draw_dot
sn_rest:
    CALL show_note_line
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
    LDA AL,[chord]           ; parte de "los dos a la vez": no cuenta
    STA [long_done],AL
    CMP AL,#0
    JMPNZ pdb_ret
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_ret
    LDA AL,[rec]
    CMP AL,#0
    JMPNZ rec_edge
    ; EDIT: no suena nada al pulsar (ni durante la larga, que borra). Si se
    ; esta reproduciendo, esta pulsacion solo la para.
    LDA AL,[play_state]
    CMP AL,#0
    JMPZ pdb_ret
    CALL play_stop
    MOV AL,#1
    STA [long_done],AL       ; al soltar no inserta, y no cuenta como larga
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
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPNZ pdb_edit_long
    ; SONGS: solo NEW SONG tiene larga (vaciar); en el resto, la pulsacion
    ; cuenta como clic al soltar
    LDA AL,[files_sel]
    CMP AL,#ROW_NEW
    JMPNZ pdb_ret
    MOV AL,#1
    STA [long_done],AL
    JMP fe_new
pdb_edit_long:
    MOV AL,#1
    STA [long_done],AL
    LDA AL,[rec]
    CMP AL,#0
    JMPZ edit_delete
    MOV AL,#0                ; en REC, una nota larga es solo eso
    STA [long_done],AL
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
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret            ; era larga (o se cancelo): ya hizo lo suyo
    LDA AL,[rec]
    CMP AL,#0
    JMPNZ rec_edge
    JMP edit_insert

; --- rec_moved: el cursor se ha movido a mano. En REC, deja de marcar
; (la nota en curso se queda como estaba) y la siguiente conserva su
; silencio ----------------------------------------------------------------
rec_moved:
    MOV AL,#1
    STA [rh_fresh],AL
    LDA AL,[rec]
    CMP AL,#0
    JMPZ rm_ret
    MOV AL,#0
    STA [rh_timing],AL
    OUT (P_SND_NOTE),AL
rm_ret:
    RET

; --- rq_clamp: AL = pulso; como minimo Q_MIN_BEAT ----------------------
rq_clamp:
    CMP AL,#Q_MIN_BEAT
    JMPNC rqc_ok
    MOV AL,#Q_MIN_BEAT
rqc_ok:
    RET

; --- rec_edge: REC, un cambio del pulsador DATOS (pulsado o soltado).
; Si sonaba una nota ([rh_timing]), su duracion es lo medido desde el
; cambio anterior: cuantizada (ver la cabecera) o, con QUANT OFF, mas el
; error que arrastran las anteriores ([rh_e_*]), a 4 ms. Luego empieza la
; siguiente (un silencio tambien se marca: suena nada); si no quedan, calla
; y sigue en REC (a EDIT solo con DIRECCION).
rec_edge:
    LDA AL,[rh_timing]
    CMP AL,#0
    JMPZ re_first
    CALL rec_close
    JMP re_next
re_first:
    CALL meas_arm            ; primer cambio: empieza a medir, sin error
    MOV AL,#0
    STA [rh_e_lo],AL
    STA [rh_e_hi],AL
    MOV AL,#0xFF
    STA [prev_pitch],AL      ; no hay nota anterior sonando
    JMP re_next

; --- rec_close: cierra la nota que suena ([rh_timing]): su duracion es lo
; medido desde el cambio anterior (cuantizada o con el error arrastrado,
; ver rec_edge), se guarda y el cursor pasa a la siguiente. Tambien al
; salir de REC con DIRECCION (rec_exit): asi la ultima nota de la cancion
; (lo que dura antes de volver a empezar con REPEAT) se guarda sin otro
; cambio de DATOS -----------------------------------------------------------
rec_close:
    MOV AL,#0
    STA [rh_timing],AL
    CALL meas_read
    STA [rh_m_lo],BL         ; duracion medida (ms)
    STA [rh_m_hi],BH
    CALL meas_arm            ; ya mide la siguiente
    LDA AL,[rh_m_lo]
    STA [q_ms_lo],AL         ; lo medido, para el 50 %
    LDA AL,[rh_m_hi]
    STA [q_ms_hi],AL
    LDA AL,[quant_mode]
    CMP AL,#0
    JMPZ rc_raw
    ; --- cuantizar. [q_beat] = pulso en unidades de 4 ms (0 = aun no hay);
    ; r = duracion en CUARTOS de pulso = ms / q_beat (redondeado)
    LDA AL,[q_beat]
    CMP AL,#0
    JMPNZ rq_have
    LDA BL,[rh_m_lo]         ; primera nota: ella marca el pulso, tal cual
    LDA BH,[rh_m_hi]
    ADD BX,#2
    MOV AX,BX
    MOV CL,#4
    DIV CL                   ; ms / 4 (satura en 255: pulso maximo ~1 s)
    CALL rq_clamp
    STA [q_beat],AL
    JMP rq_store
rq_have:
    SHR AL                   ; ms + pulso/2, para redondear
    LDA BL,[rh_m_lo]
    LDA BH,[rh_m_hi]
    ADD BX,AL
    MOV AX,BX
    LDA CL,[q_beat]
    DIV CL                   ; AL = r (satura en 255)
    CMP AL,#Q_MAX_R
    JMPNC rq_store           ; muy larga: libre, tal cual
    STA [q_r],AL
    ; la figura de QSET mas cercana a r (empate: la mas corta) -> [q_k]
    MOV AL,#0xFF
    STA [q_best],AL
    MOV BX,#QSET
    MOV CH,#7
rq_l:
    LDA CL,[BX]
    LDA AL,[q_r]
    SUB AL,CL
    JMPNC rq_abs
    NOT AL                   ; r < figura: |r - figura|
    ADD AL,#1
rq_abs:
    LDA DL,[q_best]
    CMP AL,DL
    JMPNC rq_next
    STA [q_best],AL
    STA [q_k],CL
rq_next:
    INC BX
    SUB CH,#1
    JMPNZ rq_l
    ; el pulso que dice esta nota = ms / figura; pulso = (7 pulso + ese) / 8
    LDA BL,[rh_m_lo]
    LDA BH,[rh_m_hi]
    MOV AX,BX
    LDA CL,[q_k]
    DIV CL
    STA [q_r],AL
    LDA AL,[q_beat]
    MOV CL,#7
    MUL CL
    MOV BX,AX
    LDA AL,[q_r]
    ADD BX,AL
    MOV AX,BX
    MOV CL,#8
    DIV CL
    CALL rq_clamp
    STA [q_beat],AL
    ; duracion guardada = pulso x figura (en ms: unidades de 4 ms x cuartos)
    LDA CL,[q_k]
    MUL CL
    STA [rh_m_lo],AL
    STA [rh_m_hi],AH
rq_store:
    ; [rh_m] -> pasos de 4 ms; sin arrastrar error (las iguales, iguales).
    ; Al 50 %: (lo medido + la figura) / 2
    LDA BL,[rh_m_lo]
    LDA BH,[rh_m_hi]
    LDA AL,[quant_mode]
    CMP AL,#1
    JMPNZ rq_full
    LDA CL,[q_ms_lo]
    LDA CH,[q_ms_hi]
    ADD BX,CX
    MOV AL,BH                ; / 2, a mano (no hay SHR de 16 bits)
    SHL AL,#7
    SHR BL,#1
    OR  BL,AL
    SHR BH,#1
rq_full:
    CALL ms_to_units
    STA [q_u_lo],BL
    STA [q_u_hi],BH
    MOV AL,#0
    STA [rh_e_lo],AL
    STA [rh_e_hi],AL
    JMP rc_entry
rc_raw:
    LDA BL,[rh_m_lo]
    LDA BH,[rh_m_hi]
    LDA CL,[rh_e_lo]
    LDA CH,[rh_e_hi]
    ADD BX,CX                ; objetivo = medido + error (con signo)
    MOV AL,BH
    AND AL,#0x80
    JMPZ rc_pos
    MOV BX,#0                ; negativo: 0
rc_pos:
    STA [rh_m_lo],BL
    STA [rh_m_hi],BH
    CALL ms_to_units
    STA [q_u_lo],BL
    STA [q_u_hi],BH
    CALL units_to_ms         ; error = objetivo - guardado (+-2 ms)
    LDA CL,[rh_m_lo]
    LDA CH,[rh_m_hi]
    SUB CX,BX
    STA [rh_e_lo],CL
    STA [rh_e_hi],CH
rc_entry:
    CALL rpos_entry          ; [un_*] = la nota que se cierra
    LDA AL,[un_note]
    STA [prev_pitch],AL
    LDA AL,[q_u_lo]
    STA [un_dur_lo],AL
    LDA AL,[q_u_hi]
    STA [un_dur_hi],AL
    CALL rpos_get
    CALL note_ptr
    CALL note_pack
    MOV AL,#0
    STA [rh_fresh],AL
    CALL rpos_get
    INC BX
    CALL rpos_set
    RET
re_next:
    CALL rpos_lt_len
    JMPC rn_go
    MOV AL,#0                ; no quedan notas: calla, sigue en REC
    STA [rh_timing],AL
    OUT (P_SND_NOTE),AL
    RET
rn_go:
    CALL rpos_entry
    LDA AL,[un_note]
    CMP AL,#REST
    JMPZ rn_snd              ; un silencio: no hay nada que re-atacar
    LDA BL,[prev_pitch]
    CMP AL,BL
    JMPNZ rn_snd
    ; la misma nota que la que se acaba de cerrar: sin un corte, el tono
    ; seguiria sin mas y no se oiria la nota nueva. ~20 ms de silencio (solo
    ; se oye: el tiempo ya se mide desde el cambio del pulsador)
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV AL,#3
    CALL frame_wait
    LDA AL,[un_note]
rn_snd:
    CALL sound_note          ; suena ya: la pantalla, despues
    MOV AL,#1
    STA [rh_timing],AL
    CALL replay_show_pos
    RET

pdb_files_short:
    LDA AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret            ; parte de los dos a la vez
    JMP files_execute
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
    LDA AL,[cur_note]
    STA [un_note],AL
    MOV AL,#DEF_DUR
    STA [un_dur_lo],AL
    MOV AL,#0
    STA [un_dur_hi],AL
    CALL note_insert
    CALL show_song
    CALL show_note_line
    CALL sound_short         ; se oye la que se acaba de poner
    RET

; --- note_insert: mete la nota [un_*] DELANTE de la del cursor, alarga la
; cancion y avanza el cursor (quien llama comprueba que cabe) ---------------
note_insert:
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
    RET

; --- edit_delete: pulsacion larga -> borra la nota SELECCIONADA (la del
; cursor, en inverso), y la seleccion pasa a la siguiente. Con el cursor
; al final (nada seleccionado), la ultima, como un retroceso. El teclado se
; queda en la nota borrada: para cambiarla, girar DATOS y pulsar (la nueva
; entra delante de la seleccionada, justo en su sitio). Cancion vacia: nada.
edit_delete:
    CALL rpos_lt_len
    JMPC ed_sel              ; sobre una nota: esa
    LDA AL,[rpos_lo]
    OR  AL,[rpos_hi]
    JMPZ eb_ret
    CALL rpos_get            ; al final: la ultima
    DEC BX
    CALL rpos_set
ed_sel:
    CALL rpos_entry
    LDA AL,[un_note]
    STA [gap_val],AL         ; la nota que se va (para dejarla marcada)
    ; las notas de detras se corren una posicion hacia delante (MOVW,
    ; destino antes que el origen: la copia hacia adelante es segura)
    CALL len_minus_rpos
    DEC CX                   ; notas detras de la borrada
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
    DEC DX                   ; destino: la borrada
    MOVW
    CALL len_get
    DEC BX
    STA [len_lo],BL
    STA [len_hi],BH
    LDA AL,[gap_val]
    CALL set_note
    CALL show_song
    CALL beep_low
eb_ret:
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

; --- tick_play: avanza la reproduccion (EDIT; una vez por vuelta del
; bucle principal, sin bloquear: se sigue pudiendo parar). Cada entrada se
; cronometra con meas_read (2-4 ms de resolucion hasta ~1 s) contra su
; duracion; lo que se pasa al notar el final ([pl_late]) se le quita a la
; siguiente, asi el retraso no se acumula. [play_state]: 0 parado, 1
; sonando, 2 ya cortada (dos iguales seguidas: CUT_MS de silencio) --------
tick_play:
    LDA AL,[play_state]
    CMP AL,#0
    JMPZ tp_ret
    CALL meas_read           ; BX = ms desde que empezo esta entrada
    LDA AL,[play_state]
    CMP AL,#1
    JMPNZ tp_end
    LDA DL,[pl_c_lo]
    LDA DH,[pl_c_hi]
    CMP BX,DX
    JMPC tp_ret              ; aun no toca cortar
    MOV AL,#0
    OUT (P_SND_NOTE),AL      ; corte (o el final, si no hay corte)
    MOV AL,#2
    STA [play_state],AL
tp_end:
    LDA DL,[pl_t_lo]
    LDA DH,[pl_t_hi]
    CMP BX,DX
    JMPC tp_ret              ; aun no acaba
    SUB BX,DX                ; lo que se ha pasado
    STA [pl_late_lo],BL
    STA [pl_late_hi],BH
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL rpos_lt_len
    JMPC pl_start
    LDA AL,[work_rep]
    CMP AL,#0
    JMPZ tp_stop
    MOV BX,#0                ; REPEAT: otra vez desde la primera
    CALL rpos_set
    JMP pl_start
tp_stop:
    MOV AL,#0                ; final de la cancion
    STA [play_state],AL
    OUT (P_SND_NOTE),AL
    CALL show_song
    CALL show_note_line
tp_ret:
    RET

; --- pl_start: empieza la entrada [rpos] (suena ya; la pantalla, despues).
; Dura su duracion menos [pl_late]; si la siguiente es la misma nota, se
; corta CUT_MS antes para que se oigan dos ----------------------------------
pl_start:
    CALL rpos_entry
    LDA AL,[un_note]
    CALL sound_note
    CALL meas_arm
    MOV AL,#1
    STA [play_state],AL
    CALL dur_ms
    LDA CL,[pl_late_lo]
    LDA CH,[pl_late_hi]
    SUB BX,CX
    MOV AL,BH
    AND AL,#0x80
    JMPZ ps_t
    MOV BX,#0                ; ya se paso de toda ella
ps_t:
    STA [pl_t_lo],BL
    STA [pl_t_hi],BH
    STA [pl_c_lo],BL         ; sin corte: cortar = acabar
    STA [pl_c_hi],BH
    CALL next_same
    CMP AL,#0
    JMPZ ps_show
    LDA BL,[pl_t_lo]
    LDA BH,[pl_t_hi]
    MOV DX,#(2*CUT_MS)
    CMP BX,DX
    JMPC ps_show             ; demasiado corta para cortarla
    MOV DX,#CUT_MS
    SUB BX,DX
    STA [pl_c_lo],BL
    STA [pl_c_hi],BH
ps_show:
    CALL rpos_entry
    LDA AL,[un_note]
    CALL set_note            ; el punto y la linea siguen a la nota
    CALL show_song
    RET

; --- next_same: con [un_*] = la nota [rpos], AL = 1 si la siguiente
; existe y es la MISMA nota (no silencio): seguidas, sin un corte entre
; las dos sonarian como una sola. Pisa [un_*] -----------------------------
next_same:
    LDA AL,[un_note]
    STA [ns_note],AL
    CMP AL,#REST
    JMPZ ns_no
    CALL rpos_get
    INC BX
    LDA DL,[len_lo]
    LDA DH,[len_hi]
    CMP BX,DX
    JMPNC ns_no              ; no hay siguiente
    CALL note_ptr
    CALL note_unpack
    LDA AL,[un_note]
    LDA BL,[ns_note]
    CMP AL,BL
    JMPNZ ns_no
    MOV AL,#1
    RET
ns_no:
    MOV AL,#0
    RET

; ============================================================================
;  SONIDO
; ============================================================================
sound_cur:
    LDA AL,[cur_note]
; AL = nota (0..60, o REST = calla): suena sostenida (REC y la
; reproduccion, que la hacen sonar antes de mover el punto y redibujar)
sound_note:
    CMP AL,#REST
    JMPNZ snd_n
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    RET
snd_n:
    ADD AL,#BASE_MIDI
    PUSH AL
    MOV AL,#0
    OUT (P_SND_DUR),AL
    POP AL
    OUT (P_SND_NOTE),AL
    RET

; la nota marcada, corta (muestra al girar DATOS, y al insertarla)
sound_short:
    MOV AL,#PREVIEW_DUR
sound_for:                   ; AL = duracion (x 10 ms) de la nota marcada
    PUSH AL
    LDA AL,[cur_note]
    CMP AL,#REST
    JMPNZ ssh_n
    POP AL
    RET                      ; un silencio no suena
ssh_n:
    POP AL
    OUT (P_SND_DUR),AL
    LDA AL,[cur_note]
    ADD AL,#BASE_MIDI
    OUT (P_SND_NOTE),AL
    MOV AL,#0
    OUT (P_SND_DUR),AL       ; el resto, sostenidas como siempre
    RET

; pitido corto y grave de "hecho" (borrar, lleno, accion de FILES)
beep_low:
    MOV AL,#6
    OUT (P_SND_DUR),AL
    MOV AL,#48
    OUT (P_SND_NOTE),AL
    RET

; ============================================================================
;  CONVERSION DEL FORMATO ANTERIOR (ver la cabecera). Una vez: luego
;  [song_fmt] = 1 (se queda en la flash con el proximo SAVE/DEL; hasta
;  entonces, cada arranque convierte otra vez lo que hay en la flash).
; ============================================================================
convert_all:
    LDA AL,[song_fmt]
    CMP AL,#1
    JMPZ ca_ret
    MOV AL,#0
    STA [cv_f],AL
ca_l:
    LDA AL,[cv_f]
    CALL file_len
    MOV AL,BL
    OR  AL,BH
    JMPZ ca_next             ; vacia
    STA [cv_len_lo],BL
    STA [cv_len_hi],BH
    LDA AL,[cv_f]
    CALL file_base
    CALL convert_song
    LDA AL,[cv_f]
    CALL file_len_ptr
    LDA AL,[cv_n_lo]
    STA [DX],AL
    INC DX
    LDA AL,[cv_n_hi]
    STA [DX],AL
ca_next:
    LDA AL,[cv_f]
    ADD AL,#1
    STA [cv_f],AL
    CMP AL,#FILE_COUNT
    JMPNZ ca_l
    CALL len_get             ; y la cancion de trabajo
    CALL len_valid
    STA [cv_len_lo],BL
    STA [cv_len_hi],BH
    MOV BX,#WORK
    CALL convert_song
    LDA AL,[cv_n_lo]
    STA [len_lo],AL
    LDA AL,[cv_n_hi]
    STA [len_hi],AL
    MOV AL,#1
    STA [song_fmt],AL
ca_ret:
    RET

; --- convert_song: BX = sus notas, [cv_len] = cuantas (formato anterior)
; -> las mismas en el formato actual, en el mismo sitio; [cv_n] = cuantas
; entradas quedan (un silencio previo pasa a ser una entrada; tope 512) ---
convert_song:
    STA [cv_src_lo],BL
    STA [cv_src_hi],BH
    STA [cv_base_lo],BL
    STA [cv_base_hi],BH
    MOV BX,#TMPBUF
    STA [cv_dst_lo],BL
    STA [cv_dst_hi],BH
    MOV AL,#0
    STA [cv_n_lo],AL
    STA [cv_n_hi],AL
cs_l:
    LDA AL,[cv_len_lo]
    OR  AL,[cv_len_hi]
    JMPZ cs_done
    LDA BL,[cv_src_lo]
    LDA BH,[cv_src_hi]
    LDA AL,[BX]
    STA [cv_b0],AL
    INC BX
    LDA AL,[BX]
    STA [cv_b1],AL
    INC BX
    STA [cv_src_lo],BL
    STA [cv_src_hi],BH
    LDA AL,[cv_b1]           ; silencio previo (indice de 5 bits)
    SHR AL,#3
    CMP AL,#0
    JMPZ cs_note
    CALL old_units
    MOV AL,#REST
    CALL cs_emit
cs_note:
    LDA AL,[cv_b1]           ; duracion: bits 0-1 en el byte 0, 2-4 en el 1
    AND AL,#0x07
    SHL AL,#2
    MOV CL,AL
    LDA AL,[cv_b0]
    SHR AL,#6
    OR  AL,CL
    CALL old_units
    LDA AL,[cv_b0]
    AND AL,#0x3F
    CALL cs_emit
    LDA BL,[cv_len_lo]
    LDA BH,[cv_len_hi]
    DEC BX
    STA [cv_len_lo],BL
    STA [cv_len_hi],BH
    JMP cs_l
cs_done:
    LDA CL,[cv_n_lo]         ; de vuelta a su sitio
    LDA CH,[cv_n_hi]
    LDA DL,[cv_base_lo]
    LDA DH,[cv_base_hi]
    MOV BX,#TMPBUF
    MOVW
    RET

; --- cs_emit: AL = nota, BX = duracion (pasos de 4 ms) -> una entrada mas
cs_emit:
    STA [un_note],AL
    MOV AL,BL
    OR  AL,BH
    JMPNZ ce_nz
    MOV BL,#1                ; nunca 0
ce_nz:
    STA [un_dur_lo],BL
    STA [un_dur_hi],BH
    LDA AL,[cv_n_hi]
    CMP AL,#MAX_HI
    JMPZ ce_ret              ; 512: no cabe mas
    LDA BL,[cv_dst_lo]
    LDA BH,[cv_dst_hi]
    CALL note_pack
    INC BX
    STA [cv_dst_lo],BL
    STA [cv_dst_hi],BH
    LDA BL,[cv_n_lo]
    LDA BH,[cv_n_hi]
    INC BX
    STA [cv_n_lo],BL
    STA [cv_n_hi],BH
ce_ret:
    RET

; --- old_units: AL = indice de la tabla anterior -> BX = pasos de 4 ms ---
old_units:
    MOV CL,AL
    MOV BX,#OLD_TT
    ADD BX,CL
    LDA AL,[BX]
    MOV CL,#4                ; pasos de 16 ms -> de 4 ms
    MUL CL
    MOV BX,AX
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

; --- file_instr_ptr: AL = fichero -> BX = su instrumento en INSTTAB -----
file_instr_ptr:
    MOV BX,#INSTTAB
    ADD BX,AL
    RET

; --- file_rep_ptr: AL = fichero -> BX = su "repetir" en REPTAB ----------
file_rep_ptr:
    MOV BX,#REPTAB
    ADD BX,AL
    RET

; --- file_len: AL = fichero -> BX = su longitud (validada) ---------------
file_len:
    CALL file_len_ptr
    LDA BL,[DX]
    INC DX
    LDA BH,[DX]
    CALL len_valid
    RET

; --- instr_set: AL = instrumento -> [work_instr] y PORT_SND_INSTR -------
instr_set:
    AND AL,#(INSTR_COUNT-1)
    STA [work_instr],AL
    OUT (P_SND_INSTR),AL
    RET

; --- instr_next: SONGS, corta en INSTR -> el instrumento siguiente; suena
; la nota marcada con el ------------------------------------------------------
instr_prev:
    LDA AL,[work_instr]
    SUB AL,#1                ; de 0 a 255: instr_set se queda con 2 bits = 3
    JMP instr_show
instr_next:
    LDA AL,[work_instr]
    ADD AL,#1
instr_show:
    CALL instr_set
    CALL draw_files
    MOV AL,#30               ; 300 ms: que se oiga la caida
    JMP sound_for

; --- repeat_toggle: SONGS, clic en REPEAT -> NO <-> YES ----------------
repeat_toggle:
    LDA AL,[work_rep]
    XOR AL,#1
    AND AL,#1
    STA [work_rep],AL
    CALL draw_files
    RET

; --- quant_toggle / quant_prev: SONGS, QUANT -> el siguiente / anterior
; de OFF -> 50% -> 100% (con vuelta) ----------------------------------------
quant_prev:
    LDA AL,[quant_mode]
    ADD AL,#2                ; -1 en modulo 3
    CMP AL,#3
    JMPC qt_set
    SUB AL,#3
    JMP qt_set
quant_toggle:
    LDA AL,[quant_mode]
    ADD AL,#1
    CMP AL,#3
    JMPC qt_set
    MOV AL,#0
qt_set:
    STA [quant_mode],AL
    CALL draw_files
    RET

; --- files_execute: clic en SONGS -> lo de la fila (INSTR: el siguiente;
; NEW SONG: vaciar; cancion: su accion, que despues vuelve a LOAD) ----------
files_execute:
    LDA AL,[files_sel]
    CMP AL,#0
    JMPZ instr_next
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_toggle
    CMP AL,#ROW_NEW
    JMPZ fe_hold             ; NEW SONG: solo con DATOS larga
    LDA AL,[files_act]
    CMP AL,#0
    JMPZ fe_load
    CMP AL,#1
    JMPZ fe_save
    ; --- DEL: longitud 0 y graba el programa
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
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
    JMP fe_to_edit
fe_load:
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_len
    MOV AL,BL
    OR  AL,BH
    JMPZ fe_empty
    STA [len_lo],BL
    STA [len_hi],BH
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_instr_ptr
    LDA AL,[BX]
    CALL instr_set           ; su instrumento
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_rep_ptr
    LDA AL,[BX]
    AND AL,#1
    STA [work_rep],AL        ; y si se repite
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_base
    MOV DX,#WORK
    MOV CX,#512              ; 1 KiB de notas (MOVW: palabras)
    MOVW
fe_to_edit:
    ; LOAD / NEW SONG: a EDIT, con el cursor al final de la cancion
    CALL len_get
    CALL rpos_set
    MOV AL,#MODE_EDIT
    CALL set_mode            ; (para el sonido: el pitido, despues)
    CALL beep_low
    RET
fe_hold:
    MOV BX,#s_holdnew
    JMP fe_status
fe_empty:
    MOV BX,#s_empty
    JMP fe_status
fe_save:
    CALL len_zero
    JMPZ fe_nothing
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_instr_ptr
    LDA AL,[work_instr]
    STA [BX],AL              ; con su instrumento
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_rep_ptr
    LDA AL,[work_rep]
    STA [BX],AL              ; y si se repite
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_len_ptr
    LDA AL,[len_lo]
    STA [DX],AL
    INC DX
    LDA AL,[len_hi]
    STA [DX],AL
    LDA AL,[files_sel]
    SUB AL,#FIRST_FILE
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
    MOV AL,#0
    STA [files_act],AL       ; tras hacerla, otra vez LOAD
    CALL beep_low
    CALL draw_files
    MOV CH,#7
    CALL clear_row           ; el mensaje sustituye a "ACTION: ..."
    POP BH
    POP BL
    MOV CX,#0x0701
    CALL puts
    RET

; --- save_self: graba la RAM entera (programa + canciones) en su slot.
; Tarda ~1 s (borra 17 sectores): se avisa antes en pantalla. Si falla,
; deja el aviso de error en la fila de estado y vuelve igual. ---------------
save_self:
    MOV CH,#7
    CALL clear_row
    MOV BX,#s_saving
    MOV CX,#0x0701
    CALL puts
    IN  AL,(P_CUR_SLOT)      ; el slot del que se cargo este programa
    OUT (P_PROG_SAVE),AL
    IN  AL,(P_PROG_SAVE)
    CMP AL,#0
    JMPNZ ss_ok
    MOV BX,#s_savefail
    MOV CX,#0x0701
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

; --- show_mode: fila 0, el nombre centrado: EDIT, REC (en inverso) o FILES
show_mode:
    MOV CH,#0
    CALL clear_row
    LDA AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sm_files
    MOV CX,#0x000F           ; el instrumento, arriba a la derecha
    LDA AL,[work_instr]
    CALL put_instr
    LDA AL,[work_rep]
    CMP AL,#0
    JMPZ sm_norep
    MOV BX,#s_rep            ; "REP", arriba a la izquierda
    MOV CX,#0x0000
    CALL puts
sm_norep:
    LDA AL,[rec]
    CMP AL,#0
    JMPNZ sm_rec
    MOV BX,#s_m_edit
    JMP sm_put
sm_files:
    MOV BX,#s_m_files
sm_put:
    MOV CX,#0x0005
    CALL puts
    RET
sm_rec:
    MOV BX,#s_m_rec
    MOV CX,#0x0005
    CALL puts
    MOV CX,#0x0005
    MOV AL,#ATTR_INVERSE
    STA [attr_val],AL
    MOV AL,#10
    STA [attr_n],AL
    CALL set_attr
    RET

; --- show_song: filas 1-2: la "pagina" de 10 notas que contiene [rpos],
; con esa nota en inverso (con el cursor al final, la pagina de la ultima)
show_song:
    MOV CH,#1
    CALL clear_row
    MOV CH,#2
    CALL clear_row
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

; --- show_note_line: fila 3, "NOTE C#5" + sobre una nota, su posicion
; ("POS n/longitud"); al final, la longitud ("LEN n/512", donde se anade) --
show_note_line:
    MOV CH,#3
    CALL clear_row
    MOV BX,#s_note
    MOV CX,#0x0300
    CALL puts
    LDA AL,[cur_note]
    MOV CX,#0x0305
    CALL put_note
    CALL rpos_lt_len
    JMPC snl_pos
    JMP snl_rec
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
; desplazamiento: LIST_ROWS filas visibles (1-6), la marcada siempre
; dentro; fila 7 = estado ("ACTION: LOAD", "SAVED"...) ----------------------
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
    STA [df_i],AL            ; entrada de la lista (0 INSTR, 1 REPEAT, 2 QUANT, 3 NEW)
    LDA AL,[df_k]
    ADD AL,#1
    MOV CH,AL                ; fila de pantalla
    MOV CL,#0
    LDA AL,[df_i]
    CMP AL,#0
    JMPNZ df_not_instr
    MOV BX,#s_instr          ; "INSTR: PIANO"
    CALL puts
    LDA AL,[work_instr]
    CALL put_instr
    JMP df_mark
df_not_instr:
    CMP AL,#ROW_REPEAT
    JMPNZ df_not_rep
    MOV BX,#s_repeat         ; "REPEAT: YES"
    CALL puts
    MOV BX,#s_no
    LDA AL,[work_rep]
    CMP AL,#0
    JMPZ df_r
    MOV BX,#s_yes
df_r:
    CALL puts
    JMP df_mark
df_not_rep:
    CMP AL,#ROW_QUANT
    JMPNZ df_not_quant
    MOV BX,#s_quant          ; "QUANT: 50%"
    CALL puts
    MOV BX,#s_off
    LDA AL,[quant_mode]
    CMP AL,#0
    JMPZ df_q
    MOV BX,#s_q50
    CMP AL,#1
    JMPZ df_q
    MOV BX,#s_q100
df_q:
    CALL puts
    JMP df_mark
df_not_quant:
    CMP AL,#ROW_NEW
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
    SUB AL,#(FIRST_FILE-1)
    CALL put2                ; S01..S32
    ADD CL,#1
    PUSH CL
    PUSH CH
    LDA AL,[df_i]
    SUB AL,#FIRST_FILE
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
    SUB AL,#FIRST_FILE
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
    CMP AL,#FIRST_FILE
    JMPC df_next             ; INSTR / NEW SONG: sin accion que elegir
    PUSH CH
    MOV BX,#s_action         ; fila de estado: "ACTION: LOAD"
    MOV CX,#0x0701
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
    MOV CX,#0x0709
    CALL puts
    POP CH
df_next:
    LDA AL,[df_k]
    ADD AL,#1
    STA [df_k],AL
    CMP AL,#LIST_ROWS
    JMPNZ df_l

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

; --- put_instr: AL = instrumento (0..3) -> su nombre en CH/CL ------------
put_instr:
    AND AL,#(INSTR_COUNT-1)
    SHL AL,#1
    MOV DL,AL
    MOV BX,#INSTR_NAMES
    ADD BX,DL
    LDA AL,[BX]
    INC BX
    LDA BH,[BX]
    MOV BL,AL
    CALL puts
    RET

; --- put_note: AL = nota (0..24) como 3 caracteres ("C4 ", "C#4") en
; CH/CL; avanza CL 3 ---------------------------------------------------------
put_note:
    CMP AL,#REST
    JMPNZ pn_go
    MOV AL,#'-'              ; el silencio: "-- "
    CALL putc
    MOV AL,#'-'
    CALL putc
    MOV AL,#0x20
    CALL putc
    RET
pn_go:
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
; OLD_TT: la tabla de tiempos del formato ANTERIOR (pasos de 16 ms, indice
; de 5 bits); solo para convertir (convert_song)
OLD_TT:   .db 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20
            .db 23, 26, 30, 34, 38, 43, 48, 54, 61, 69, 78, 88, 100, 120, 150, 200
MASK8:      .db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
NOTE_NAMES: .ascii "C C#D D#E F F#G G#A A#B "

s_m_edit:   .asciiz "   EDIT   "
s_m_rec:    .asciiz "   REC    "
s_m_files:  .asciiz "  SONGS   "
INSTR_NAMES: .dw s_i_organ, s_i_piano, s_i_guitar, s_i_bell
s_i_organ:  .asciiz "ORGAN"
s_i_piano:  .asciiz "PIANO"
s_i_guitar: .asciiz "GUITAR"
s_i_bell:   .asciiz "BELL"
s_instr:    .asciiz "INSTR: "
s_quant:    .asciiz "QUANT: "
s_off:      .asciiz "OFF"
s_repeat:   .asciiz "REPEAT: "
s_no:       .asciiz "NO"
s_yes:      .asciiz "YES"
s_rep:      .asciiz "REP"
s_q50:      .asciiz "50%"
s_q100:     .asciiz "100%"
; figuras a las que se ajusta el ritmo en REC, en cuartos de pulso
; (sin 3/4: entre 1 y 3/4 el margen era 1/8 de pulso, y una negra algo
; corta se guardaba como 3/4)
QSET:       .db 1, 2, 4, 6, 8, 12, 16

ACT_NAMES:  .dw s_a_load, s_a_save, s_a_del
s_a_load:   .asciiz "LOAD"
s_a_save:   .asciiz "SAVE"
s_a_del:    .asciiz "DEL "

s_nosong:   .asciiz "(NO NOTES)"
s_note:     .asciiz "NOTE"
s_len:      .asciiz "LEN"
s_pos:      .asciiz "POS"
s_newsong:  .asciiz "NEW SONG (LONG PRESS)"
s_holdnew:  .asciiz "LONG PRESS TO CLEAR"
s_dashes:   .asciiz "-- EMPTY"
s_action:   .asciiz "ACTION:"
s_saving:   .asciiz "SAVING..."
s_savefail: .asciiz "SAVE FAILED!"
s_saved:    .asciiz "SAVED"
s_deleted:  .asciiz "DELETED"
s_empty:    .asciiz "THAT FILE IS EMPTY"
s_nothing:  .asciiz "NOTHING TO SAVE"

; --- variables (el banco, las longitudes y la cancion de trabajo van en
; 0x4000-0xC7FF, ver la cabecera -- fuera del .bin) ---------------------------
mode:         .space 1
rec:          .space 1    ; 1 = REC (marcar el ritmo)
chord:        .space 1    ; 1 = los dos pulsadores ya hicieron lo suyo
rh_fresh:     .space 1    ; 1 = REC: la siguiente nota no mide su silencio
rh_m_lo:      .space 1    ; REC: duracion objetivo (ms, 16 bits)
rh_m_hi:      .space 1
rh_timing:    .space 1    ; REC: 1 = suena la nota [rpos] y se esta midiendo
q_beat:       .space 1    ; REC: pulso (unidades de 4 ms; 0 = aun no hay)
q_r:          .space 1
q_k:          .space 1    ; figura elegida (cuartos de pulso)
q_best:       .space 1
q_ms_lo:      .space 1    ; REC: lo medido (ms), para QUANT 50 %
q_ms_hi:      .space 1
prev_pitch:   .space 1    ; REC: la nota que se acaba de cerrar (0xFF = ninguna)
ns_note:      .space 1
rh_e_lo:      .space 1    ; REC: error de redondeo arrastrado (ms, con signo)
rh_e_hi:      .space 1
kb_base:      .space 1    ; primera nota del teclado dibujado (0, 12, 24, 36)
kf_old:       .space 1
abtn_down:    .space 1    ; pulsador DIRECCION: 1 = pulsado
abtn_long:    .space 1    ; 1 = esta pulsacion de DIRECCION ya no es corta
cur_note:     .space 1
dir_prev:     .space 1
dat_prev:     .space 1
rot_n:        .space 1
btn_down:     .space 1
press_frames: .space 1
long_done:    .space 1
rpos_lo:      .space 1    ; cursor de la cancion (16 bits)
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
un_dur_lo:    .space 1    ; duracion en pasos de 4 ms (10 bits)
un_dur_hi:    .space 1
q_u_lo:       .space 1    ; REC: la duracion a guardar (pasos de 4 ms)
q_u_hi:       .space 1
pl_t_lo:      .space 1    ; reproduccion: ms en que acaba la entrada
pl_t_hi:      .space 1
pl_c_lo:      .space 1    ; reproduccion: ms en que se corta (<= pl_t)
pl_c_hi:      .space 1
pl_late_lo:   .space 1    ; reproduccion: lo que se paso la anterior (ms)
pl_late_hi:   .space 1
cv_f:         .space 1    ; convert_all / convert_song
cv_len_lo:    .space 1
cv_len_hi:    .space 1
cv_n_lo:      .space 1
cv_n_hi:      .space 1
cv_src_lo:    .space 1
cv_src_hi:    .space 1
cv_dst_lo:    .space 1
cv_dst_hi:    .space 1
cv_base_lo:   .space 1
cv_base_hi:   .space 1
cv_b0:        .space 1
cv_b1:        .space 1
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
