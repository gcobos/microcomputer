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
;  Al abrir el programa, la cancion de trabajo esta vacia (como tras NEW
;  SONG); las guardadas se cargan desde SONGS.
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
;  ms (ver meas_read). Lo marcado se guarda tal cual, sin
;  TEMPO: el TEMPO de la cancion solo cambia la velocidad al reproducir.
;  REC guarda lo medido (a 4 ms) y lo que se pierde al redondear pasa a la
;  nota siguiente.
;  CUANTIZAR (QUANT en SONGS: OFF de fabrica / ON). Con QUANT en ON, al
;  salir de REC (si se ha marcado alguna nota) la cancion ENTERA pasa a una
;  rejilla comun, sacada de la propia cancion: cada duracion queda en un
;  multiplo exacto de la rejilla, y la cancion dura lo mismo que lo
;  marcado. Si el ritmo es demasiado libre para ninguna rejilla, se queda
;  como estaba. Mientras calcula (hasta ~2 s con 512 notas), "QUANTIZING..."
;  en la linea de la nota. Ver quantize.
;
;  SONGS: INSTR + TEMPO + REPEAT + QUANT + NEW SONG + 32 canciones. DATOS gira cambia de fila; un
;  CLIC en cualquiera de los dos pulsadores hace lo de la fila, y DIRECCION
;  gira el valor de la fila (INSTR, TEMPO, REPEAT, QUANT: siguiente /
;  anterior;
;  cancion: la accion):
;     INSTR     el instrumento siguiente de la cancion de trabajo
;               (PORT_SND_INSTR: ORGAN, PIANO, GUITAR, BELL); suena la nota
;               marcada con el. Se aplica al momento a todo (reproducir, REC,
;               la muestra al girar DATOS), se guarda con SAVE y vuelve con
;               LOAD; NEW SONG lo conserva.
;     TEMPO     60..240 BPM, de 5 en 5 (de fabrica 120 = tal cual se grabo):
;               la velocidad al reproducir. A 240 suena al doble de rapido y
;               a 60 a la mitad; no cambia las notas guardadas, cada duracion
;               se escala al sonar (tempo_scale). DIRECCION gira: +-5 (sin
;               pasar de los limites); clic: +5 (de 240, vuelve a 60). Como
;               INSTR, va con la cancion (SAVE lo guarda, LOAD lo recupera,
;               NEW SONG lo conserva).
;     REPEAT    NO / YES: al acabar de reproducirse, vuelve a empezar (sin
;               hueco: el tiempo sigue). Como INSTR, va con la cancion (SAVE
;               lo guarda, LOAD lo recupera, NEW SONG lo conserva). En EDIT,
;               "REP" arriba a la izquierda.
;     QUANT     OFF / ON: cuantizar la cancion al salir de REC (ver REC).
;               Para todas las canciones (se conserva al reenviar).
;     NEW SONG  DATOS LARGA (no un clic, para no perder la cancion sin
;               querer): vacia la cancion y vuelve a EDIT.
;     S01..S32  titulo = las 3 primeras notas + la longitud; la que se
;               cargo (o donde se guardo) la ultima, con "<" a la derecha
;               (al abrir el programa, ninguna; NEW SONG y DEL la quitan). La accion es
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
;     0xC083         QUANT: 0 = OFF (de fabrica), otro = ON
;     0xC084         formato de las canciones (2 = el actual; ver abajo)
;     0xC085         1 = repetir la cancion de trabajo
;     0xC086         TEMPO de la cancion de trabajo (BPM; 0 o fuera de rango = 120)
;     0xC0A0-0xC0BF  TEMPO de cada cancion del banco (igual)
;     0xC400-0xC7FF  la cancion de trabajo (la que se toca/graba/reproduce)
;  Cada entrada ocupa 2 bytes (16 bits): nota (6 bits: 0..60 = DO3..DO8,
;  63 = SILENCIO) + duracion (10 bits, escalonada: 0..511 en pasos de 4 ms,
;  hasta 2044 ms; 512..1023 = 2048 ms + pasos de 12 ms, hasta 8180 ms; ver
;  ms_to_units):
;     byte 0 = nota (bits 0-5) + duracion bits 0-1 (en los bits 6-7)
;     byte 1 = duracion bits 2-9
;  Los silencios son entradas propias (nota 63, "--" en la lista; se elige
;  girando DATOS por debajo de DO3), como en una partitura. Las notas van
;  seguidas; dos iguales seguidas se separan al sonar con un corte de 16 ms
;  quitado al final de la primera (ver pl_start). Longitud 0 = cancion
;  vacia; hasta MAX_NOTES=512 entradas.
;  FORMATO ANTERIOR (hasta 2026-10): duracion y silencio previo de 5 bits
;  cada uno, indices de una tabla de 32 tiempos (OLD_TT) con saltos de hasta
;  50 ms en lo largo. Al arrancar, si [song_fmt] es 0, convert_all pasa
;  todas las canciones al formato de 4 ms (un silencio previo pasa a ser una
;  entrada de silencio delante): suenan igual. Despues (formato 1, hasta
;  2026-10) la duracion iba siempre en pasos de 4 ms, hasta 4092 ms: si
;  [song_fmt] es 1, convert_long pasa al formato 2 las notas de mas de 2 s
;  (las demas son iguales en los dos).
;  Solo SAVE y DEL (en SONGS) escriben la flash (~1 s, "SAVING..."); LOAD y
;  NEW SONG solo tocan la RAM. Se graba la RAM entera, pero la cancion de
;  trabajo no se recupera al volver a arrancar: empieza vacia.
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
P_T6       = 0x0626      ; 64 ms/paso (medir notas de mas de ~4 s)
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
ROW_TEMPO   = 1          ; SONGS: fila 0 = INSTR, 1 = TEMPO, 2 = REPEAT,
ROW_REPEAT  = 2          ; 3 = QUANT, 4 = NEW SONG, 5.. = S01..S32
ROW_QUANT   = 3
ROW_NEW     = 4
FIRST_FILE  = 5
TEMPO_DEF   = 120        ; TEMPO: BPM con los que suena tal cual se grabo
TEMPO_MIN   = 60         ; (a 60, a la mitad de velocidad; a 240, al doble)
TEMPO_MAX   = 240
TEMPO_STEP  = 5
QZ_MAX_TRY  = 16         ; quantize: rejillas candidatas como mucho
QZ_MIN_G    = 20         ; rejilla minima (ms)
QZ_MAX_D    = 8180       ; duracion maxima de una nota (ms)
INSTR_COUNT = 4
BANK_HI     = 0x40       ; banco de canciones: 0x4000, 1 KiB cada una
LENTAB      = 0xC000     ; longitudes del banco (32 x 16 bits)
INSTTAB     = 0xC040     ; instrumento de cada cancion del banco (32 bytes)
REPTAB      = 0xC060     ; 1 = repetir, de cada cancion del banco (32 bytes)
len_lo      = 0xC080     ; longitud de la cancion de trabajo
len_hi      = 0xC081
work_instr  = 0xC082     ; instrumento de la cancion de trabajo (0..3)
quant_mode  = 0xC083     ; QUANT: 0 OFF, otro = ON (cuantizar al salir de REC)
song_fmt    = 0xC084     ; 2 = formato actual (si no, convert_all al arrancar)
work_rep    = 0xC085     ; 1 = la cancion de trabajo se repite al acabar
work_tempo  = 0xC086     ; TEMPO de la cancion de trabajo (BPM; ver tempo_get)
TEMPOTAB    = 0xC0A0     ; TEMPO de cada cancion del banco (32 bytes)
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
    MOV [mode],AL
    MOV [rpos_lo],AL
    MOV [rpos_hi],AL
    MOV [btn_down],AL
    MOV [files_sel],AL
    MOV [files_top],AL
    MOV [files_act],AL
    MOV [play_state],AL
    MOV [abtn_down],AL
    MOV [rec],AL
    MOV [chord],AL
    MOV AL,#0xFF
    MOV [cur_file],AL        ; ninguna cancion cargada
    MOV AL,#24               ; empieza en DO5, con el teclado en DO4..DO6
    MOV [cur_note],AL
    MOV AL,#12
    MOV [kb_base],AL
    CALL convert_all         ; canciones del formato anterior, si las hay
    ; la cancion de trabajo empieza vacia (como tras NEW SONG): SAVE/DEL
    ; graban la RAM entera, y si no se abriria con la que hubiera entonces
    MOV AL,#0
    MOV [len_lo],AL
    MOV [len_hi],AL
    MOV BX,#0
    CALL rpos_set
    MOV AL,[work_instr]
    CALL instr_set
    CALL tempo_get           ; (las de antes del TEMPO: 0 -> 120)
    MOV [work_tempo],AL
    IN  AL,(P_DIR_POS)
    MOV [dir_prev],AL
    IN  AL,(P_DAT_POS)
    MOV [dat_prev],AL
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
    CALL meas_tick
    ; grabando el ritmo o reproduciendo, sin espera: la pulsacion y el final
    ; de cada nota se atienden en cuanto pasan (con la espera de 8 ms, cada
    ; nota se medía o arrancaba hasta 8 ms tarde, y en la reproduccion ese
    ; retraso se acumulaba nota a nota)
    MOV AL,[play_state]
    CMP AL,#0
    JMPNZ main_l
    MOV AL,[rec]
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
    MOV AL,[len_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[len_hi]
    OR  AL,CL
    POP CL
    RET

; --- rpos_lt_len: C=1 si [rpos] < longitud (hay nota en esa posicion) ----
rpos_lt_len:
    MOV BL,[rpos_lo]
    MOV BH,[rpos_hi]
    MOV DL,[len_lo]
    MOV DH,[len_hi]
    CMP BX,DX                ; CMP de 16 bits (ISA 2): C = rpos < longitud
    RET

; --- rpos_set: BX -> [rpos] ------------------------------------------------
rpos_set:
    MOV [rpos_lo],BL
    MOV [rpos_hi],BH
    RET

; --- rpos_get / len_get: [rpos] / longitud -> BX --------------------------
rpos_get:
    MOV BL,[rpos_lo]
    MOV BH,[rpos_hi]
    RET
len_get:
    MOV BL,[len_lo]
    MOV BH,[len_hi]
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
    MOV AL,[BX]
    MOV CL,AL
    AND AL,#0x3F
    MOV [un_note],AL
    MOV AL,CL
    SHR AL,#6
    MOV [un_dur_lo],AL       ; bits 0-1
    INC BX
    MOV AL,[BX]
    MOV CL,AL
    SHL AL,#2
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[un_dur_lo]
    OR  AL,CL
    POP CL
    MOV [un_dur_lo],AL       ; + bits 2-7
    MOV AL,CL
    SHR AL,#6
    MOV [un_dur_hi],AL       ; bits 8-9
    RET

; --- note_pack: [un_note], [un_dur_lo/hi] -> entrada BX --------------------
note_pack:
    MOV AL,[un_dur_lo]
    AND AL,#0x03
    SHL AL,#6
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[un_note]
    OR  AL,CL
    POP CL
    MOV [BX],AL
    INC BX
    MOV AL,[un_dur_lo]
    SHR AL,#2
    MOV CL,AL
    MOV AL,[un_dur_hi]
    AND AL,#0x03
    SHL AL,#6
    OR  AL,CL
    MOV [BX],AL
    RET

; --- ms_to_units: BX = ms -> BX = duracion guardada (10 bits, 1..1023),
; redondeada. Escalonada: 0..511 = pasos de 4 ms (hasta 2044 ms), 512..1023 =
; 2048 ms + pasos de 12 ms (hasta 8180 ms; en una nota tan larga, 12 ms no se
; notan). No hay desplazamientos de 16 bits: a mano con los dos bytes ------
ms_to_units:
    MOV DX,#2046
    CMP BX,DX
    JMPNC mtu_long
    ADD BX,#2                ; corta: (ms + 2) / 4
    MOV AL,BH
    SHL AL,#6
    MOV CL,BL
    SHR CL,#2
    OR  CL,AL                ; byte bajo
    MOV AL,BH
    SHR AL,#2                ; byte alto (0 o 1)
    MOV BH,AL
    MOV BL,CL
    MOV AL,BL
    OR  AL,BH
    JMPNZ mtu_ret
    MOV BL,#1                ; nunca 0
mtu_ret:
    RET
mtu_long:                    ; larga: 512 + (ms - 2048 + 6) / 12
    MOV DX,#2042
    SUB BX,DX
    MOV CH,#2                ; 512..767
    MOV DX,#3072             ; 256 x 12
    CMP BX,DX
    JMPC mtu_div
    SUB BX,DX
    MOV CH,#3                ; 768..1023
    CMP BX,DX
    JMPC mtu_div
    MOV BX,#1023             ; tope: 8180 ms
    RET
mtu_div:
    MOV AX,BX
    MOV CL,#12
    DIV CL                   ; < 3072: cabe en 8 bits
    MOV BL,AL
    MOV BH,CH
    RET

; --- units_to_ms: BX = duracion guardada -> BX = ms (ver ms_to_units) ----
units_to_ms:
    MOV AL,BH
    CMP AL,#2
    JMPNC utm_long
    SHL AL,#2                ; corta: x 4
    MOV CL,BL
    SHR CL,#6
    OR  AL,CL
    MOV BH,AL
    SHL BL,#2
    RET
utm_long:                    ; larga: 2048 + (u - 512) x 12
    PUSH BH
    MOV AL,BL
    MOV CL,#12
    MUL CL
    MOV BX,AX
    MOV DX,#2048
    ADD BX,DX
    POP AL
    CMP AL,#3
    JMPNZ utm_ret
    MOV DX,#3072             ; 768..1023: + 256 x 12
    ADD BX,DX
utm_ret:
    RET

; --- dur_ms: la duracion de [un_dur_lo/hi] -> BX, en ms ------------------
dur_ms:
    MOV BL,[un_dur_lo]
    MOV BH,[un_dur_hi]
    JMP units_to_ms

; --- meas_arm / meas_read: cronometro de la grabacion y la reproduccion.
; meas_arm lo pone a 0; meas_read da en BX lo que ha pasado desde entonces,
; en ms. Debajo, T1, T2, T4 y T6 arrancados a la vez (meas_raw): con T1 (2
; ms) hasta ~0,5 s, con T2 (4 ms) hasta ~1 s, con T4 (16 ms) hasta ~4 s y
; con T6 (64 ms) hasta ~16 s. Un temporizador solo dice cuantos pasos
; ENTEROS han pasado: se toma el centro del paso en curso (pasos x 2 + 1 ms
; con T1...), si no cada medida sale de media medio paso corta y, al
; sumarse, la cancion grabada se adelanta (con solo T4, 8 ms por medida).
; Para que las notas largas (hasta 8 s, o 16 a 60 BPM) se midan tambien al
; ms, meas_tick (en cada vuelta del bucle principal) pasa lo medido a
; [ms_base] cada ~0,4 s y vuelve a arrancar los temporizadores: lo hace en
; cuanto T1 cambia de paso, asi que el error es de lo que tarda una vuelta
; del bucle, en vez de los +-32 ms de T6 (que queda solo
; por si el bucle se parase). Usan AX, BX, CX (y meas_tick, DX). -----------
meas_arm:
    MOV AL,#0
    MOV [ms_base_lo],AL
    MOV [ms_base_hi],AL
meas_rearm:
    MOV AL,#255
    OUT (P_T1),AL
    OUT (P_T2),AL
    OUT (P_T4),AL
    OUT (P_T6),AL
    RET
meas_read:
    CALL meas_raw
    MOV CL,[ms_base_lo]
    MOV CH,[ms_base_hi]
    ADD BX,CX
    RET
meas_tick:
    CALL meas_raw
    MOV DX,#400
    CMP BX,DX
    JMPC mt_ret
    SUB BX,CL                ; sin el medio paso: se pasa justo al cambiar
    MOV CL,[ms_base_lo]       ; de paso, asi que lo medido es lo entero
    MOV CH,[ms_base_hi]
    ADD BX,CX
    MOV [ms_base_lo],BL
    MOV [ms_base_hi],BH
    JMP meas_rearm
mt_ret:
    RET
meas_raw:
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
    CMP AL,#0
    JMPNZ mr_mul
    IN  AL,(P_T6)
    MOV CL,#64
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
    MOV AL,[chord]
    CMP AL,#0
    JMPNZ pc_ret             ; ya se hizo en esta pulsacion
    MOV AL,#1
    MOV [chord],AL
    MOV [abtn_long],AL
    MOV [long_done],AL
    MOV AL,[mode]
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
    MOV [chord],AL
pc_ret:
    RET

; --- poll_addr_btn: pulsador DIRECCION. Corta (al soltar): reproduce /
; para. Larga (~0,6 s, T5): en cuanto se cumple, entra en REC; en FILES,
; vuelve a EDIT. En REC, corta o larga, vuelve a EDIT ----------------------
poll_addr_btn:
    IN  AL,(P_DIR_BTN)
    MOV BL,[abtn_down]
    CMP AL,#0
    JMPZ pab_up
    CMP BL,#0
    JMPNZ pab_held
    MOV AL,#1                ; flanco de bajada
    MOV [abtn_down],AL
    MOV AL,#HOLD_STEP
    OUT (P_T5),AL
    MOV AL,[chord]           ; con los dos botones, esta no cuenta
    MOV [abtn_long],AL
    MOV AL,[rh_timing]       ; REC: la nota que suena acaba AL PULSAR (no al
    CMP AL,#0                ; soltar, que sumaria lo que dura la pulsacion);
    JMPZ pab_ret             ; al soltar, rec_exit
    CALL rec_close
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    CALL show_song
    CALL show_note_line
    RET
pab_held:
    MOV AL,[abtn_long]
    CMP AL,#0
    JMPNZ pab_ret
    IN  AL,(P_T5)
    CMP AL,#0
    JMPNZ pab_ret
    MOV AL,#1                ; se acaba de cumplir la pulsacion larga
    MOV [abtn_long],AL
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pab_files
    MOV AL,[rec]
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
    MOV [abtn_down],AL
    MOV AL,[abtn_long]
    CMP AL,#0
    JMPNZ pab_ret            ; era larga (o de los dos): ya hizo lo suyo
    MOV AL,[mode]
    CMP AL,#MODE_EDIT
    JMPNZ files_execute      ; SONGS: el clic hace la accion de la fila
    MOV AL,[rec]
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
    MOV [play_state],AL
    OUT (P_SND_NOTE),AL
    CALL rpos_lt_len
    JMPC re_pos
    MOV BX,#0
    CALL rpos_set
re_pos:
    MOV AL,#0
    MOV [rh_timing],AL
    MOV [rec_dirty],AL
    MOV AL,#1
    MOV [rec],AL
    MOV [rh_fresh],AL
    MOV [long_done],AL       ; si DATOS estaba pulsado, al soltar no hace nada
    CALL show_mode
    CALL replay_show_pos
    RET

; --- rec_exit: de REC a EDIT. Si sonaba una nota, la cierra (rec_close);
; si DATOS sigue pulsado, al soltarlo ya no hace nada -----------------------
rec_exit:
    MOV AL,[rh_timing]
    CMP AL,#0
    JMPZ rx_off
    CALL rec_close           ; la nota que sonaba dura hasta aqui
rx_off:
    MOV AL,#0
    MOV [rec],AL
    MOV [rh_timing],AL
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    MOV [long_done],AL
    MOV AL,[quant_mode]
    CMP AL,#0
    JMPZ rx_show
    MOV AL,[rec_dirty]
    CMP AL,#0
    JMPZ rx_show
    CALL quantize            ; QUANT ON y se ha marcado algo
rx_show:
    CALL show_mode
    CALL show_song
    CALL show_note_line
    RET

; ============================================================================
;  QUANTIZE: al salir de REC con QUANT en ON, la cancion de trabajo entera
;  pasa a una rejilla comun. Cada duracion queda en k x G ms (k entero):
;   1. Rejillas candidatas: las duraciones mas cortas de la cancion, de
;      menor a mayor (saltando las que estan a menos de un 6 % de la anterior
;      probada; como mucho QZ_MAX_TRY), y la mitad de cada una (para que
;      quepan notas de 1 1/2, con puntillo). Con la nota entera, k >= 1; con
;      la mitad, k >= 2: lo que quede por debajo era un fallo y se alarga.
;   2. De cada candidata, el error medio: lo que se aleja cada nota de su
;      multiplo, en rejillas (como mucho 1). Se queda la de menor error, si
;      no pasa de 0,15 rejillas por nota (a la mitad se le suman 0,03, para
;      no partir el pulso sin necesidad). Si ninguna llega, el ritmo es
;      demasiado libre: no se toca nada.
;   3. G = suma de las duraciones / suma de las k: la cancion dura lo mismo
;      que lo marcado (redondeado; hasta 8180 ms por nota).
;  Probado en Python antes (ritmos con +-15 ms de temblor y una nota fallida:
;  acierta las proporciones; con temblor de +-25 ms, casi siempre deja la
;  cancion como estaba). Duraciones en ms en TMPBUF (2 bytes por entrada).
; ============================================================================
quantize:
    CALL len_get
    MOV [qz_n_lo],BL
    MOV [qz_n_hi],BH
    MOV DX,#2
    CMP BX,DX
    JMPNC qz_go
    RET                      ; menos de 2 entradas: nada que comparar
qz_go:
    MOV CH,#3                ; "QUANTIZING..." en la linea de la nota (lo
    CALL clear_row           ; tapa show_note_line al acabar)
    MOV BX,#s_quantizing
    MOV CX,#0x0300
    CALL puts
    ; duraciones en ms -> TMPBUF
    MOV AL,#0
    MOV [qz_i_lo],AL
    MOV [qz_i_hi],AL
qz_ld:
    MOV BL,[qz_i_lo]
    MOV BH,[qz_i_hi]
    CALL note_ptr
    CALL note_unpack
    CALL dur_ms
    CALL qz_put
    CALL qz_next
    JMPC qz_ld
    MOV BL,[qz_n_lo]         ; fin de TMPBUF = TMPBUF + 2 n
    MOV BH,[qz_n_hi]
    ADD BX,BX
    MOV CX,#TMPBUF
    ADD BX,CX
    MOV [qz_end_lo],BL
    MOV [qz_end_hi],BH
    ; limite = n x 19,25 ; penalizacion = n x 4 (en 1/128 de rejilla)
    MOV BL,[qz_n_lo]
    MOV BH,[qz_n_hi]
    MOV CX,BX
    ADD CX,CX
    ADD CX,CX                ; x 4
    MOV [qz_pen_lo],CL
    MOV [qz_pen_hi],CH
    MOV DX,CX
    ADD DX,DX
    ADD DX,DX                ; x 16
    ADD DX,BX
    ADD DX,BX
    ADD DX,BX                ; x 19
    MOV AL,BH                ; + n / 4
    SHL AL,#6
    SHR BL,#2
    OR  BL,AL
    SHR BH,#2
    ADD DX,BX
    MOV [qz_lim_lo],DL
    MOV [qz_lim_hi],DH
    ; candidatas
    MOV AL,#0
    MOV [qz_last_lo],AL
    MOV [qz_last_hi],AL
    MOV [qz_tried],AL
    MOV [qz_bg_lo],AL
    MOV [qz_bg_hi],AL
qz_cand:
    ; umbral = ultima + ultima / 16 (la primera vez, QZ_MIN_G x 2)
    MOV BL,[qz_last_lo]
    MOV BH,[qz_last_hi]
    MOV AL,BL
    OR  AL,BH
    JMPNZ qz_thr
    MOV CX,#(QZ_MIN_G*2)
    JMP qz_scan
qz_thr:
    MOV AL,BH
    SHL AL,#4
    MOV CL,BL
    SHR CL,#4
    OR  CL,AL
    MOV CH,BH
    SHR CH,#4
    ADD CX,BX                ; CX = umbral
qz_scan:
    ; s = la duracion mas corta >= umbral (0xFFFF = ninguna). Sin llamadas:
    ; BX recorre TMPBUF hasta [qz_end], AX = la duracion
    MOV DX,#0xFFFF
    MOV BX,#TMPBUF
qz_sl:
    MOV AL,[BX]
    INC BX
    MOV AH,[BX]
    INC BX
    CMP AX,CX
    JMPC qz_sn               ; < umbral
    CMP AX,DX
    JMPNC qz_sn              ; no es mas corta
    MOV DX,AX
qz_sn:
    MOV AL,[qz_end_lo]
    MOV AH,[qz_end_hi]
    CMP BX,AX
    JMPC qz_sl
    MOV BX,#0xFFFF
    CMP DX,BX
    JMPZ qz_chosen           ; no quedan candidatas
    MOV [qz_last_lo],DL
    MOV [qz_last_hi],DH
    MOV AL,[qz_tried]
    ADD AL,#1
    MOV [qz_tried],AL
    CMP AL,#(QZ_MAX_TRY+1)
    JMPZ qz_chosen
    ; rejilla = la nota entera (k >= 1), sin penalizacion
    MOV [qz_g_lo],DL
    MOV [qz_g_hi],DH
    MOV AL,#1
    MOV [qz_kmin],AL
    MOV BX,#0
    CALL qz_try
    ; rejilla = su mitad (k >= 2), con penalizacion
    MOV BL,[qz_last_lo]
    MOV BH,[qz_last_hi]
    MOV AL,BH
    SHL AL,#7
    SHR BL,#1
    OR  BL,AL
    SHR BH,#1
    MOV DX,#QZ_MIN_G
    CMP BX,DX
    JMPC qz_cand             ; demasiado fina
    MOV [qz_g_lo],BL
    MOV [qz_g_hi],BH
    MOV AL,#2
    MOV [qz_kmin],AL
    MOV BL,[qz_pen_lo]
    MOV BH,[qz_pen_hi]
    CALL qz_try
    JMP qz_cand

qz_chosen:
    MOV AL,[qz_bg_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[qz_bg_hi]
    OR  AL,CL
    POP CL
    JMPNZ qz_apply
    RET                      ; ninguna encaja: se queda como estaba
qz_apply:
    MOV AL,[qz_bg_lo]
    MOV [qz_g_lo],AL
    MOV AL,[qz_bg_hi]
    MOV [qz_g_hi],AL
    MOV AL,[qz_bk]
    MOV [qz_kmin],AL
    ; k de cada entrada (en TMPBUF, en lugar de su duracion), y las sumas
    MOV AL,#0
    MOV [qz_t0],AL
    MOV [qz_t1],AL
    MOV [qz_t2],AL
    MOV [qz_s0],AL
    MOV [qz_s1],AL
    MOV [qz_s2],AL
    MOV [qz_i_lo],AL
    MOV [qz_i_hi],AL
qz_kl:
    CALL qz_get
    MOV AL,[qz_t0]           ; suma de duraciones += BX
    ADD AL,BL
    MOV [qz_t0],AL
    MOV AL,[qz_t1]
    ADC AL,BH
    MOV [qz_t1],AL
    MOV AL,[qz_t2]
    ADC AL,#0
    MOV [qz_t2],AL
    CALL qz_round            ; [qz_k]
    MOV BL,[qz_k_lo]
    MOV BH,[qz_k_hi]
    MOV AL,[qz_s0]           ; suma de k += k
    ADD AL,BL
    MOV [qz_s0],AL
    MOV AL,[qz_s1]
    ADC AL,BH
    MOV [qz_s1],AL
    MOV AL,[qz_s2]
    ADC AL,#0
    MOV [qz_s2],AL
    CALL qz_put
    CALL qz_next
    JMPC qz_kl
    MOV AL,[qz_s2]
    CMP AL,#0
    JMPZ qz_div
    RET                      ; mas de 65535 rejillas: no deberia pasar
qz_div:
    ; G = (suma duraciones + suma k / 2) / suma k
    MOV CL,[qz_s0]
    MOV CH,[qz_s1]
    MOV AL,CH
    SHL AL,#7
    SHR CL,#1
    OR  CL,AL
    SHR CH,#1
    MOV AL,[qz_t0]
    ADD AL,CL
    MOV [qz_t0],AL
    MOV AL,[qz_t1]
    ADC AL,CH
    MOV [qz_t1],AL
    MOV AL,[qz_t2]
    ADC AL,#0
    MOV [qz_t2],AL
    CALL qz_div24
    MOV [qz_G_lo],BL
    MOV [qz_G_hi],BH
    ; cada entrada = k x G
    MOV AL,#0
    MOV [qz_i_lo],AL
    MOV [qz_i_hi],AL
qz_wl:
    CALL qz_get              ; BX = k
    MOV CX,BX
    MOV BX,#0
    MOV DL,[qz_G_lo]
    MOV DH,[qz_G_hi]
qz_ml:
    MOV AL,CL
    OR  AL,CH
    JMPZ qz_md
    ADD BX,DX
    PUSH DL
    PUSH DH
    MOV DX,#QZ_MAX_D
    CMP BX,DX
    POP DH
    POP DL
    JMPNC qz_mcap
    DEC CX
    JMP qz_ml
qz_mcap:
    MOV BX,#QZ_MAX_D
qz_md:
    CALL ms_to_units
    PUSH BL
    PUSH BH
    MOV BL,[qz_i_lo]
    MOV BH,[qz_i_hi]
    CALL note_ptr
    PUSH BL
    PUSH BH
    CALL note_unpack         ; [un_note]
    POP BH
    POP BL
    POP AH
    POP AL
    MOV [un_dur_lo],AL
    MOV [un_dur_hi],AH
    CALL note_pack
    CALL qz_next
    JMPC qz_wl
    RET

; --- qz_try: con [qz_g], [qz_kmin] y BX = penalizacion, el error de esa
; rejilla; si no pasa del limite y es el mejor hasta ahora, se apunta. Es el
; bucle que mas se repite (n entradas x hasta 32 rejillas): recorre TMPBUF
; con un puntero, y con rejilla de hasta 255 ms el error sale con un DIV ----
qz_try:
    MOV [qz_e_lo],BL
    MOV [qz_e_hi],BH
    MOV BX,#TMPBUF
    MOV [qz_p_lo],BL
    MOV [qz_p_hi],BH
    MOV BL,[qz_n_lo]
    MOV BH,[qz_n_hi]
    MOV [qz_c_lo],BL
    MOV [qz_c_hi],BH
qt_l:
    MOV DL,[qz_p_lo]
    MOV DH,[qz_p_hi]
    MOV AL,[DX]
    MOV BL,AL
    INC DX
    MOV AL,[DX]
    MOV BH,AL
    INC DX
    MOV [qz_p_lo],DL
    MOV [qz_p_hi],DH
    ; atajo (lo normal): rejilla <= 255 y cociente <= 255 -> un DIV basta
    MOV CL,[qz_g_lo]
    MOV CH,[qz_g_hi]
    MOV AL,CH
    CMP AL,#0
    JMPNZ qt_full
    MOV AX,BX
    DIV CL                   ; AL = cociente, AH = resto
    JMPC qt_full
    MOV DH,#0
    MOV DL,CL
    SUB DL,AH                ; rejilla - resto
    CMP AH,DL
    JMPC qt_down             ; resto < rejilla - resto: hacia abajo
    ADD AL,#1                ; hacia arriba: k + 1, error = rejilla - resto
    JMP qt_kchk
qt_down:
    MOV DL,AH                ; error = resto
qt_kchk:
    MOV AH,[qz_kmin]
    CMP AL,AH
    JMPNC qt_frac            ; k >= kmin: error ya en DX
    MOV AX,BX                ; (BX sigue siendo la duracion)
qt_full:
    CALL qz_round            ; DX = error (ms), CX = rejilla
qt_frac:
    ; error en 1/128 de rejilla (como mucho 127)
    MOV AL,#127
    CMP DX,CX
    JMPNC qt_add             ; una rejilla o mas
    MOV AL,CH
    CMP AL,#0
    JMPNZ qt_slow
    MOV AL,DL                ; error < rejilla <= 255: (error x 128) / rejilla
    MOV AH,#128
    MUL AH
    DIV CL
    JMP qt_add
qt_slow:
    ; rejilla de mas de 255 ms: error y rejilla a la mitad hasta que la
    ; rejilla quepa en un byte (se pierden solo bits bajos), y el DIV
    MOV AL,CH
    SHL AL,#7
    SHR CL,#1
    OR  CL,AL
    SHR CH,#1
    MOV AL,DH
    SHL AL,#7
    SHR DL,#1
    OR  DL,AL
    SHR DH,#1
    MOV AL,CH
    CMP AL,#0
    JMPNZ qt_slow
    MOV AL,DL
    MOV AH,#128
    MUL AH
    DIV CL
    CMP AL,#128
    JMPC qt_add
    MOV AL,#127
qt_add:
    MOV BL,[qz_e_lo]
    MOV BH,[qz_e_hi]
    ADD BX,AL
    MOV [qz_e_lo],BL
    MOV [qz_e_hi],BH
    MOV DL,[qz_lim_lo]
    MOV DH,[qz_lim_hi]
    CMP DX,BX
    JMPC qt_ret              ; ya pasa del limite: descartada
    MOV BL,[qz_c_lo]
    MOV BH,[qz_c_hi]
    DEC BX
    MOV [qz_c_lo],BL
    MOV [qz_c_hi],BH
    MOV AL,BL
    OR  AL,BH
    JMPNZ qt_l
    ; cabe: la mejor si no hay otra o si tiene menos error
    MOV AL,[qz_bg_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[qz_bg_hi]
    OR  AL,CL
    POP CL
    JMPZ qt_best
    MOV BL,[qz_e_lo]
    MOV BH,[qz_e_hi]
    MOV DL,[qz_be_lo]
    MOV DH,[qz_be_hi]
    CMP BX,DX
    JMPNC qt_ret
qt_best:
    MOV AL,[qz_e_lo]
    MOV [qz_be_lo],AL
    MOV AL,[qz_e_hi]
    MOV [qz_be_hi],AL
    MOV AL,[qz_g_lo]
    MOV [qz_bg_lo],AL
    MOV AL,[qz_g_hi]
    MOV [qz_bg_hi],AL
    MOV AL,[qz_kmin]
    MOV [qz_bk],AL
qt_ret:
    RET

; --- qz_round: BX = duracion (ms) -> [qz_k] = BX / [qz_g] redondeado (como
; poco [qz_kmin]) y DX = lo que se aleja de k x rejilla (ms) ---------------
qz_round:
    MOV CL,[qz_g_lo]
    MOV CH,[qz_g_hi]
    PUSH BL
    PUSH BH
    MOV AL,CH
    CMP AL,#0
    JMPNZ qr_slow            ; rejilla de mas de 255 ms: k es pequeno
    MOV AX,BX
    DIV CL
    JMPC qr_slow0            ; cociente de mas de 255
    MOV [qz_k_lo],AL
    MOV AL,#0
    MOV [qz_k_hi],AL
    MOV DL,AH                ; resto
    MOV DH,#0
    JMP qr_rnd
qr_slow0:
    POP BH
    POP BL
    PUSH BL
    PUSH BH
qr_slow:
    MOV DX,BX                ; resto = duracion; k = 0
    MOV AL,#0
    MOV [qz_k_lo],AL
    MOV [qz_k_hi],AL
qr_sl:
    CMP DX,CX
    JMPC qr_rnd
    SUB DX,CX
    MOV BL,[qz_k_lo]
    MOV BH,[qz_k_hi]
    INC BX
    MOV [qz_k_lo],BL
    MOV [qz_k_hi],BH
    JMP qr_sl
qr_rnd:
    ; DX = resto (< rejilla). Si resto x 2 >= rejilla, k + 1
    MOV BX,DX
    ADD BX,BX
    CMP BX,CX
    JMPC qr_min
    MOV BL,[qz_k_lo]
    MOV BH,[qz_k_hi]
    INC BX
    MOV [qz_k_lo],BL
    MOV [qz_k_hi],BH
    MOV BX,CX
    SUB BX,DX
    MOV DX,BX                ; error = rejilla - resto
qr_min:
    POP BH                   ; BX = duracion
    POP BL
    MOV AL,[qz_k_hi]
    CMP AL,#0
    JMPNZ qr_ret
    MOV AL,[qz_k_lo]
    MOV AH,[qz_kmin]
    CMP AL,AH
    JMPNC qr_ret
    ; k < kmin: un fallo; k = kmin, error = kmin x rejilla - duracion
    MOV [qz_k_lo],AH
    MOV DX,CX
    CMP AH,#1
    JMPZ qr_m1
    ADD DX,CX
qr_m1:
    SUB DX,BX
qr_ret:
    RET

; --- qz_get / qz_put: la palabra i de TMPBUF -> BX / BX -> la palabra i
qz_get:
    CALL qz_ptr
    MOV AL,[DX]
    MOV BL,AL
    INC DX
    MOV AL,[DX]
    MOV BH,AL
    RET
qz_put:
    CALL qz_ptr
    MOV AL,BL
    MOV [DX],AL
    INC DX
    MOV AL,BH
    MOV [DX],AL
    RET
qz_ptr:
    MOV DL,[qz_i_lo]
    MOV DH,[qz_i_hi]
    ADD DX,DX
    PUSH BL
    PUSH BH
    MOV BX,#TMPBUF
    ADD DX,BX
    POP BH
    POP BL
    RET

; --- qz_next: i + 1; C = 1 si aun quedan (i < n) --------------------------
qz_next:
    MOV BL,[qz_i_lo]
    MOV BH,[qz_i_hi]
    INC BX
    MOV [qz_i_lo],BL
    MOV [qz_i_hi],BH
    MOV DL,[qz_n_lo]
    MOV DH,[qz_n_hi]
    CMP BX,DX
    RET

; --- qz_div24: [qz_t2:t1:t0] / [qz_s1:s0] -> BX (el cociente cabe en 16
; bits). Division larga bit a bit: no hay desplazamientos de 16 bits ni
; division de 24, asi que el dividendo (BX + CL) y el resto (DX) se
; desplazan byte a byte con ADD/ADC ----------------------------------------
qz_div24:
    MOV BL,[qz_t0]
    MOV BH,[qz_t1]
    MOV CL,[qz_t2]
    MOV AL,[qz_s0]
    MOV AH,[qz_s1]
    MOV DX,#0
    MOV CH,#24
qd_l:
    ADD BL,BL
    ADC BH,BH
    ADC CL,CL
    ADC DL,DL
    ADC DH,DH
    JMPC qd_sub              ; el resto paso de 16 bits: seguro que cabe
    CMP DX,AX
    JMPC qd_n
qd_sub:
    SUB DX,AX
    OR  BL,#1
qd_n:
    DEC CH
    JMPNZ qd_l
    RET

; --- play_toggle: reproduce desde el cursor hasta el final, con el cursor
; detras (al acabar queda al final, listo para seguir anadiendo); con el
; cursor ya al final, la cancion entera. Si ya sonaba, la para: el cursor
; se queda en la nota donde paro ---------------------------------------------
play_toggle:
    MOV AL,[play_state]
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
    MOV [pl_late_lo],AL
    MOV [pl_late_hi],AL
    CALL pl_start
pt_ret:
    RET
play_stop:
    MOV AL,#0
    MOV [play_state],AL
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    MOV [rh_fresh],AL        ; REC: la siguiente no mide su silencio
    CALL replay_show_pos
    RET

; --- set_mode: AL = modo nuevo (EDIT o FILES). Para el sonido, la
; reproduccion y la grabacion -----------------------------------------------
set_mode:
    MOV [mode],AL
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV [files_act],AL
    MOV [play_state],AL      ; para una reproduccion en marcha
    MOV [rec],AL
    MOV AL,#1
    MOV [rh_fresh],AL
    MOV [long_done],AL       ; si DATOS sigue pulsado, al soltarlo no hace nada
    CALL redraw_all
    RET

; --- poll_addr_rot: DIRECCION gira -> el cursor (EDIT) o la fila
; (FILES), un paso por detente ----------------------------------------------
poll_addr_rot:
    IN  AL,(P_DIR_POS)
    MOV BL,[dir_prev]
    MOV [dir_prev],AL
    SUB AL,BL
    JMPZ par_done
    JMPN par_neg
    MOV [rot_n],AL
par_up_l:
    CALL addr_up
    MOV AL,[rot_n]
    SUB AL,#1
    MOV [rot_n],AL
    JMPNZ par_up_l
    RET
par_neg:
    NOT AL
    ADD AL,#1
    MOV [rot_n],AL
par_dn_l:
    CALL addr_down
    MOV AL,[rot_n]
    SUB AL,#1
    MOV [rot_n],AL
    JMPNZ par_dn_l
par_done:
    RET

addr_up:
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ act_next
    MOV AL,[play_state]
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
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ act_prev
    MOV AL,[play_state]
    CMP AL,#0
    JMPNZ ad_ret
    MOV AL,[rpos_lo]         ; hasta la primera, sin vuelta
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[rpos_hi]
    OR  AL,CL
    POP CL
    JMPZ ad_ret
    CALL rpos_get
    DEC BX
    CALL rpos_set
    CALL rec_moved
    CALL replay_show_pos
ad_ret:
    RET

; --- act_next / act_prev: SONGS, DIRECCION gira -> el valor de la fila:
; INSTR, TEMPO, REPEAT y QUANT, el siguiente / anterior (como el clic); en una
; cancion, la accion (LOAD, SAVE, DEL, con vuelta). En NEW SONG, nada -----
act_next:
    MOV AL,[files_sel]
    CMP AL,#0
    JMPZ instr_next
    CMP AL,#ROW_TEMPO
    JMPZ tempo_up
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_toggle
    CMP AL,#FIRST_FILE
    JMPC act_ret
    MOV AL,[files_act]
    ADD AL,#1
    CMP AL,#3
    JMPNZ act_set
    MOV AL,#0
    JMP act_set
act_prev:
    MOV AL,[files_sel]
    CMP AL,#0
    JMPZ instr_prev
    CMP AL,#ROW_TEMPO
    JMPZ tempo_down
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_prev
    CMP AL,#FIRST_FILE
    JMPC act_ret
    MOV AL,[files_act]
    CMP AL,#0
    JMPNZ act_dec
    MOV AL,#3
act_dec:
    SUB AL,#1
act_set:
    MOV [files_act],AL
    CALL draw_files
act_ret:
    RET

; --- poll_dat_rot: DATOS gira -> nota (o fila en FILES), un paso por
; detente --------------------------------------------------------------------
poll_dat_rot:
    IN  AL,(P_DAT_POS)
    MOV BL,[dat_prev]
    MOV [dat_prev],AL
    SUB AL,BL
    JMPZ pdr_done
    JMPN pdr_neg
    MOV [rot_n],AL
pdr_up_l:
    CALL step_up
    MOV AL,[rot_n]
    SUB AL,#1
    MOV [rot_n],AL
    JMPNZ pdr_up_l
    RET
pdr_neg:
    NOT AL
    ADD AL,#1
    MOV [rot_n],AL
pdr_dn_l:
    CALL step_down
    MOV AL,[rot_n]
    SUB AL,#1
    MOV [rot_n],AL
    JMPNZ pdr_dn_l
pdr_done:
    RET

step_up:
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ su_files
    MOV AL,[cur_note]
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
    MOV AL,[files_sel]
    ADD AL,#1
    CMP AL,#(FILE_COUNT+FIRST_FILE)
    JMPNZ su_fset
    MOV AL,#0
su_fset:
    MOV [files_sel],AL
    MOV AL,#0
    MOV [files_act],AL
    CALL draw_files
    RET
step_down:
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sd_files
    MOV AL,[cur_note]
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
    MOV AL,[files_sel]
    CMP AL,#0
    JMPNZ sd_fdec
    MOV AL,#(FILE_COUNT+FIRST_FILE)
sd_fdec:
    SUB AL,#1
    MOV [files_sel],AL
    MOV AL,#0
    MOV [files_act],AL
    CALL draw_files
    RET
; --- preview_note: EDIT, DATOS girado -> la nota marcada suena un momento
; (no mientras se reproduce la cancion ni con DATOS pulsado); por Bluetooth
; MIDI, con la mitad de velocidad que al insertarla --------------------------
preview_note:
    MOV AL,[mode]
    CMP AL,#MODE_EDIT
    JMPNZ pv_ret
    MOV AL,[play_state]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[btn_down]
    OR  AL,CL
    POP CL
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
    MOV [dot_on],AL
    CALL draw_dot            ; borra el punto de la nota anterior
    POP AL
    MOV [cur_note],AL
    CMP AL,#REST
    JMPZ sn_rest             ; el silencio no tiene tecla ni punto
    CALL kb_follow           ; la escala sube/baja si la nota se sale
    MOV AL,#1
    MOV [dot_on],AL
    CALL draw_dot
sn_rest:
    CALL show_note_line
    RET

; --- kb_follow: si [cur_note] queda fuera del teclado dibujado
; ([kb_base]..[kb_base]+KB_SPAN), lo desplaza de octava en octava hasta
; que entre y lo vuelve a dibujar -- "la escala sube o baja" ------------
kb_follow:
    MOV AL,[kb_base]
    MOV [kf_old],AL
kf_l:
    MOV AL,[cur_note]
    MOV BL,[kb_base]
    CMP AL,BL
    JMPNC kf_not_below
    MOV AL,BL                ; por debajo: una octava abajo
    SUB AL,#12
    MOV [kb_base],AL
    JMP kf_l
kf_not_below:
    SUB AL,BL
    CMP AL,#(KB_SPAN+1)
    JMPC kf_in
    MOV AL,BL                ; por encima: una octava arriba
    ADD AL,#12
    MOV [kb_base],AL
    JMP kf_l
kf_in:
    MOV AL,[kb_base]
    MOV BL,[kf_old]
    CMP AL,BL
    JMPZ kf_ret
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ kf_ret              ; en FILES no hay teclado que redibujar
    CALL clsg
    CALL draw_keyboard
kf_ret:
    RET

; --- poll_dat_btn: maquina de estados del pulsador de DATOS ---------------
poll_dat_btn:
    IN  AL,(P_DAT_BTN)
    MOV BL,[btn_down]
    CMP AL,#0
    JMPZ pdb_up
    CMP BL,#0
    JMPNZ pdb_held
    ; --- flanco de bajada: empieza una pulsacion
    MOV AL,#1
    MOV [btn_down],AL
    MOV AL,#0
    MOV [press_frames],AL
    MOV AL,[chord]           ; parte de "los dos a la vez": no cuenta
    MOV [long_done],AL
    CMP AL,#0
    JMPNZ pdb_ret
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_ret
    MOV AL,[rec]
    CMP AL,#0
    JMPNZ rec_edge
    ; EDIT: no suena nada al pulsar (ni durante la larga, que borra). Si se
    ; esta reproduciendo, esta pulsacion solo la para.
    MOV AL,[play_state]
    CMP AL,#0
    JMPZ pdb_ret
    CALL play_stop
    MOV AL,#1
    MOV [long_done],AL       ; al soltar no inserta, y no cuenta como larga
    RET

pdb_held:
    MOV AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret
    MOV AL,[press_frames]
    ADD AL,#1
    MOV [press_frames],AL
    CMP AL,#LONG_FRAMES
    JMPNZ pdb_ret
    ; --- se acaba de cumplir la pulsacion larga
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPNZ pdb_edit_long
    ; SONGS: solo NEW SONG tiene larga (vaciar); en el resto, la pulsacion
    ; cuenta como clic al soltar
    MOV AL,[files_sel]
    CMP AL,#ROW_NEW
    JMPNZ pdb_ret
    MOV AL,#1
    MOV [long_done],AL
    JMP fe_new
pdb_edit_long:
    MOV AL,#1
    MOV [long_done],AL
    MOV AL,[rec]
    CMP AL,#0
    JMPZ edit_delete
    MOV AL,#0                ; en REC, una nota larga es solo eso
    MOV [long_done],AL
    RET

pdb_up:
    CMP BL,#0
    JMPZ pdb_ret             ; sigue suelto: nada
    ; --- flanco de subida: termina la pulsacion
    MOV AL,#0
    MOV [btn_down],AL
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ pdb_files_short
    MOV AL,[long_done]
    CMP AL,#0
    JMPNZ pdb_ret            ; era larga (o se cancelo): ya hizo lo suyo
    MOV AL,[rec]
    CMP AL,#0
    JMPNZ rec_edge
    JMP edit_insert

; --- rec_moved: el cursor se ha movido a mano. En REC, deja de marcar
; (la nota en curso se queda como estaba) y la siguiente conserva su
; silencio ----------------------------------------------------------------
rec_moved:
    MOV AL,#1
    MOV [rh_fresh],AL
    MOV AL,[rec]
    CMP AL,#0
    JMPZ rm_ret
    MOV AL,#0
    MOV [rh_timing],AL
    OUT (P_SND_NOTE),AL
rm_ret:
    RET

; --- rec_edge: REC, un cambio del pulsador DATOS (pulsado o soltado).
; Si sonaba una nota ([rh_timing]), su duracion es lo medido desde el
; cambio anterior, mas el error que arrastran las anteriores ([rh_e_*]),
; a 4 ms (la cuantizacion, si la hay, es al salir de REC: quantize). Luego empieza la
; siguiente (un silencio tambien se marca: suena nada); si no quedan, calla
; y sigue en REC (a EDIT solo con DIRECCION).
rec_edge:
    MOV AL,[rh_timing]
    CMP AL,#0
    JMPZ re_first
    CALL rec_close
    JMP re_next
re_first:
    CALL meas_arm            ; primer cambio: empieza a medir, sin error
    MOV AL,#0
    MOV [rh_e_lo],AL
    MOV [rh_e_hi],AL
    MOV AL,#0xFF
    MOV [prev_pitch],AL      ; no hay nota anterior sonando
    JMP re_next

; --- rec_close: cierra la nota que suena ([rh_timing]): su duracion es lo
; medido desde el cambio anterior (con el error arrastrado, ver
; rec_edge), se guarda y el cursor pasa a la siguiente. Tambien al
; salir de REC con DIRECCION (rec_exit): asi la ultima nota de la cancion
; (lo que dura antes de volver a empezar con REPEAT) se guarda sin otro
; cambio de DATOS -----------------------------------------------------------
rec_close:
    MOV AL,#0
    MOV [rh_timing],AL
    MOV AL,#1
    MOV [rec_dirty],AL       ; algo marcado: al salir, QUANT (si esta en ON)
    CALL meas_read
    MOV [rh_m_lo],BL         ; duracion medida (ms)
    MOV [rh_m_hi],BH
    CALL meas_arm            ; ya mide la siguiente
rc_raw:
    MOV BL,[rh_m_lo]
    MOV BH,[rh_m_hi]
    MOV CL,[rh_e_lo]
    MOV CH,[rh_e_hi]
    ADD BX,CX                ; objetivo = medido + error (con signo)
    MOV AL,BH
    AND AL,#0x80
    JMPZ rc_pos
    MOV BX,#0                ; negativo: 0
rc_pos:
    MOV [rh_m_lo],BL
    MOV [rh_m_hi],BH
    CALL ms_to_units
    MOV [q_u_lo],BL
    MOV [q_u_hi],BH
    CALL units_to_ms         ; error = objetivo - guardado (+-2 ms)
    MOV CL,[rh_m_lo]
    MOV CH,[rh_m_hi]
    SUB CX,BX
    MOV [rh_e_lo],CL
    MOV [rh_e_hi],CH
rc_entry:
    CALL rpos_entry          ; [un_*] = la nota que se cierra
    MOV AL,[un_note]
    MOV [prev_pitch],AL
    MOV AL,[q_u_lo]
    MOV [un_dur_lo],AL
    MOV AL,[q_u_hi]
    MOV [un_dur_hi],AL
    CALL rpos_get
    CALL note_ptr
    CALL note_pack
    MOV AL,#0
    MOV [rh_fresh],AL
    CALL rpos_get
    INC BX
    CALL rpos_set
    RET
re_next:
    CALL rpos_lt_len
    JMPC rn_go
    MOV AL,#0                ; no quedan notas: calla, sigue en REC
    MOV [rh_timing],AL
    OUT (P_SND_NOTE),AL
    RET
rn_go:
    CALL rpos_entry
    MOV AL,[un_note]
    CMP AL,#REST
    JMPZ rn_snd              ; un silencio: no hay nada que re-atacar
    MOV BL,[prev_pitch]
    CMP AL,BL
    JMPNZ rn_snd
    ; la misma nota que la que se acaba de cerrar: sin un corte, el tono
    ; seguiria sin mas y no se oiria la nota nueva. ~20 ms de silencio (solo
    ; se oye: el tiempo ya se mide desde el cambio del pulsador)
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV AL,#3
    CALL frame_wait
    MOV AL,[un_note]
rn_snd:
    CALL sound_note          ; suena ya: la pantalla, despues
    MOV AL,#1
    MOV [rh_timing],AL
    CALL replay_show_pos
    RET

pdb_files_short:
    MOV AL,[long_done]
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
    MOV CL,[len_lo]
    MOV CH,[len_hi]
    MOV BL,[rpos_lo]
    MOV BH,[rpos_hi]
    SUB CX,BX                ; resta de 16 bits (ISA 2)
    RET

; --- edit_insert: pulsacion corta -> inserta la nota marcada DELANTE de la
; del cursor (con el ritmo por defecto) y avanza el cursor -----------------
edit_insert:
    MOV AL,[len_hi]
    CMP AL,#MAX_HI
    JMPNZ ei_room            ; 512 notas (alto = 2 solo en el tope)
    CALL beep_low
    RET
ei_room:
    MOV AL,[cur_note]
    MOV [un_note],AL
    MOV AL,#DEF_DUR
    MOV [un_dur_lo],AL
    MOV AL,#0
    MOV [un_dur_hi],AL
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
    MOV [len_lo],BL
    MOV [len_hi],BH
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
    MOV AL,[rpos_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[rpos_hi]
    OR  AL,CL
    POP CL
    JMPZ eb_ret
    CALL rpos_get            ; al final: la ultima
    DEC BX
    CALL rpos_set
ed_sel:
    CALL rpos_entry
    MOV AL,[un_note]
    MOV [gap_val],AL         ; la nota que se va (para dejarla marcada)
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
    MOV [len_lo],BL
    MOV [len_hi],BH
    MOV AL,[gap_val]
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
    MOV AL,[un_note]
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
    MOV AL,[play_state]
    CMP AL,#0
    JMPZ tp_ret
    CALL meas_read           ; BX = ms desde que empezo esta entrada
    MOV AL,[play_state]
    CMP AL,#1
    JMPNZ tp_end
    MOV DL,[pl_c_lo]
    MOV DH,[pl_c_hi]
    CMP BX,DX
    JMPC tp_ret              ; aun no toca cortar
    MOV AL,#0
    OUT (P_SND_NOTE),AL      ; corte (o el final, si no hay corte)
    MOV AL,#2
    MOV [play_state],AL
tp_end:
    MOV DL,[pl_t_lo]
    MOV DH,[pl_t_hi]
    CMP BX,DX
    JMPC tp_ret              ; aun no acaba
    SUB BX,DX                ; lo que se ha pasado
    MOV [pl_late_lo],BL
    MOV [pl_late_hi],BH
    CALL rpos_get
    INC BX
    CALL rpos_set
    CALL rpos_lt_len
    JMPC pl_start
    MOV AL,[work_rep]
    CMP AL,#0
    JMPZ tp_stop
    MOV BX,#0                ; REPEAT: otra vez desde la primera
    CALL rpos_set
    JMP pl_start
tp_stop:
    MOV AL,#0                ; final de la cancion
    MOV [play_state],AL
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
    MOV AL,[un_note]
    CALL sound_note
    CALL meas_arm
    MOV AL,#1
    MOV [play_state],AL
    CALL dur_ms
    CALL tempo_scale         ; al TEMPO de la cancion
    MOV CL,[pl_late_lo]
    MOV CH,[pl_late_hi]
    SUB BX,CX
    MOV AL,BH
    AND AL,#0x80
    JMPZ ps_t
    MOV BX,#0                ; ya se paso de toda ella
ps_t:
    MOV [pl_t_lo],BL
    MOV [pl_t_hi],BH
    MOV [pl_c_lo],BL         ; sin corte: cortar = acabar
    MOV [pl_c_hi],BH
    CALL next_same
    CMP AL,#0
    JMPZ ps_show
    MOV BL,[pl_t_lo]
    MOV BH,[pl_t_hi]
    MOV DX,#(2*CUT_MS)
    CMP BX,DX
    JMPC ps_show             ; demasiado corta para cortarla
    MOV DX,#CUT_MS
    SUB BX,DX
    MOV [pl_c_lo],BL
    MOV [pl_c_hi],BH
ps_show:
    CALL rpos_entry
    MOV AL,[un_note]
    CALL set_note            ; el punto y la linea siguen a la nota
    CALL show_song
    RET

; --- next_same: con [un_*] = la nota [rpos], AL = 1 si la siguiente
; existe y es la MISMA nota (no silencio): seguidas, sin un corte entre
; las dos sonarian como una sola. Pisa [un_*] -----------------------------
next_same:
    MOV AL,[un_note]
    MOV [ns_note],AL
    CMP AL,#REST
    JMPZ ns_no
    CALL rpos_get
    INC BX
    MOV DL,[len_lo]
    MOV DH,[len_hi]
    CMP BX,DX
    JMPNC ns_no              ; no hay siguiente
    CALL note_ptr
    CALL note_unpack
    MOV AL,[un_note]
    MOV BL,[ns_note]
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
    MOV AL,[cur_note]
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
    MOV AL,[cur_note]
    CMP AL,#REST
    JMPNZ ssh_n
    POP AL
    RET                      ; un silencio no suena
ssh_n:
    POP AL
    OUT (P_SND_DUR),AL
    MOV AL,[cur_note]
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
;  CONVERSION DE LOS FORMATOS ANTERIORES (ver la cabecera). Una vez: luego
;  [song_fmt] = 2 (se queda en la flash con el proximo SAVE/DEL; hasta
;  entonces, cada arranque convierte otra vez lo que hay en la flash).
; ============================================================================
convert_all:
    MOV AL,[song_fmt]
    CMP AL,#2
    JMPZ ca_ret
    CMP AL,#1
    JMPZ convert_long        ; formato 1: solo las notas largas
    MOV AL,#0
    MOV [cv_f],AL
ca_l:
    MOV AL,[cv_f]
    CALL file_len
    MOV AL,BL
    OR  AL,BH
    JMPZ ca_next             ; vacia
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    MOV AL,[cv_f]
    CALL file_base
    CALL convert_song
    MOV AL,[cv_f]
    CALL file_len_ptr
    MOV AL,[cv_n_lo]
    MOV [DX],AL
    INC DX
    MOV AL,[cv_n_hi]
    MOV [DX],AL
ca_next:
    MOV AL,[cv_f]
    ADD AL,#1
    MOV [cv_f],AL
    CMP AL,#FILE_COUNT
    JMPNZ ca_l
    CALL len_get             ; y la cancion de trabajo
    CALL len_valid
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    MOV BX,#WORK
    CALL convert_song
    MOV AL,[cv_n_lo]
    MOV [len_lo],AL
    MOV AL,[cv_n_hi]
    MOV [len_hi],AL
    MOV AL,#1
    MOV [song_fmt],AL
    JMP convert_long         ; y de ahi, al 2
ca_ret:
    RET

; --- convert_long: formato 1 -> 2. En el 1, la duracion era siempre en
; pasos de 4 ms (hasta 4092 ms); en el 2, desde 512 va en pasos de 12 ms
; (ver ms_to_units). Solo cambian las entradas de 512 o mas (> 2 s) -------
convert_long:
    MOV AL,#0
    MOV [cv_f],AL
cl_l:
    MOV AL,[cv_f]
    CALL file_len
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    MOV AL,[cv_f]
    CALL file_base
    CALL long_song
    MOV AL,[cv_f]
    ADD AL,#1
    MOV [cv_f],AL
    CMP AL,#FILE_COUNT
    JMPNZ cl_l
    CALL len_get             ; y la cancion de trabajo
    CALL len_valid
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    MOV BX,#WORK
    CALL long_song
    MOV AL,#2
    MOV [song_fmt],AL
    RET

; --- long_song: BX = sus notas, [cv_len] = cuantas -> las de 512 o mas,
; pasadas al formato 2, en su sitio --------------------------------------
long_song:
    MOV [cv_src_lo],BL
    MOV [cv_src_hi],BH
ls_l:
    MOV AL,[cv_len_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[cv_len_hi]
    OR  AL,CL
    POP CL
    JMPZ ls_ret
    MOV BL,[cv_src_lo]
    MOV BH,[cv_src_hi]
    CALL note_unpack
    MOV AL,[un_dur_hi]
    CMP AL,#2
    JMPC ls_next             ; < 512: igual en los dos formatos
    MOV BL,[un_dur_lo]       ; formato 1: x 4 ms
    MOV BH,[un_dur_hi]
    MOV AL,BH
    SHL AL,#2
    MOV CL,BL
    SHR CL,#6
    OR  AL,CL
    MOV BH,AL
    SHL BL,#2
    CALL ms_to_units
    MOV [un_dur_lo],BL
    MOV [un_dur_hi],BH
    MOV BL,[cv_src_lo]
    MOV BH,[cv_src_hi]
    CALL note_pack
ls_next:
    MOV BL,[cv_src_lo]
    MOV BH,[cv_src_hi]
    INC BX
    INC BX
    MOV [cv_src_lo],BL
    MOV [cv_src_hi],BH
    MOV BL,[cv_len_lo]
    MOV BH,[cv_len_hi]
    DEC BX
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    JMP ls_l
ls_ret:
    RET

; --- convert_song: BX = sus notas, [cv_len] = cuantas (formato anterior)
; -> las mismas en el formato actual, en el mismo sitio; [cv_n] = cuantas
; entradas quedan (un silencio previo pasa a ser una entrada; tope 512) ---
convert_song:
    MOV [cv_src_lo],BL
    MOV [cv_src_hi],BH
    MOV [cv_base_lo],BL
    MOV [cv_base_hi],BH
    MOV BX,#TMPBUF
    MOV [cv_dst_lo],BL
    MOV [cv_dst_hi],BH
    MOV AL,#0
    MOV [cv_n_lo],AL
    MOV [cv_n_hi],AL
cs_l:
    MOV AL,[cv_len_lo]
    PUSH CL                  ; (ISA 3: sin ALU con memoria; POP no toca flags)
    MOV CL,[cv_len_hi]
    OR  AL,CL
    POP CL
    JMPZ cs_done
    MOV BL,[cv_src_lo]
    MOV BH,[cv_src_hi]
    MOV AL,[BX]
    MOV [cv_b0],AL
    INC BX
    MOV AL,[BX]
    MOV [cv_b1],AL
    INC BX
    MOV [cv_src_lo],BL
    MOV [cv_src_hi],BH
    MOV AL,[cv_b1]           ; silencio previo (indice de 5 bits)
    SHR AL,#3
    CMP AL,#0
    JMPZ cs_note
    CALL old_units
    MOV AL,#REST
    CALL cs_emit
cs_note:
    MOV AL,[cv_b1]           ; duracion: bits 0-1 en el byte 0, 2-4 en el 1
    AND AL,#0x07
    SHL AL,#2
    MOV CL,AL
    MOV AL,[cv_b0]
    SHR AL,#6
    OR  AL,CL
    CALL old_units
    MOV AL,[cv_b0]
    AND AL,#0x3F
    CALL cs_emit
    MOV BL,[cv_len_lo]
    MOV BH,[cv_len_hi]
    DEC BX
    MOV [cv_len_lo],BL
    MOV [cv_len_hi],BH
    JMP cs_l
cs_done:
    MOV CL,[cv_n_lo]         ; de vuelta a su sitio
    MOV CH,[cv_n_hi]
    MOV DL,[cv_base_lo]
    MOV DH,[cv_base_hi]
    MOV BX,#TMPBUF
    MOVW
    RET

; --- cs_emit: AL = nota, BX = duracion (pasos de 4 ms) -> una entrada mas
cs_emit:
    MOV [un_note],AL
    MOV AL,BL
    OR  AL,BH
    JMPNZ ce_nz
    MOV BL,#1                ; nunca 0
ce_nz:
    MOV [un_dur_lo],BL
    MOV [un_dur_hi],BH
    MOV AL,[cv_n_hi]
    CMP AL,#MAX_HI
    JMPZ ce_ret              ; 512: no cabe mas
    MOV BL,[cv_dst_lo]
    MOV BH,[cv_dst_hi]
    CALL note_pack
    INC BX
    MOV [cv_dst_lo],BL
    MOV [cv_dst_hi],BH
    MOV BL,[cv_n_lo]
    MOV BH,[cv_n_hi]
    INC BX
    MOV [cv_n_lo],BL
    MOV [cv_n_hi],BH
ce_ret:
    RET

; --- old_units: AL = indice de la tabla anterior -> BX = pasos de 4 ms ---
old_units:
    MOV CL,AL
    MOV BX,#OLD_TT
    ADD BX,CL
    MOV AL,[BX]
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
    MOV BL,[DX]
    INC DX
    MOV BH,[DX]
    CALL len_valid
    RET

; --- instr_set: AL = instrumento -> [work_instr] y PORT_SND_INSTR -------
instr_set:
    AND AL,#(INSTR_COUNT-1)
    MOV [work_instr],AL
    OUT (P_SND_INSTR),AL
    RET

; --- instr_next: SONGS, corta en INSTR -> el instrumento siguiente; suena
; la nota marcada con el ------------------------------------------------------
instr_prev:
    MOV AL,[work_instr]
    SUB AL,#1                ; de 0 a 255: instr_set se queda con 2 bits = 3
    JMP instr_show
instr_next:
    MOV AL,[work_instr]
    ADD AL,#1
instr_show:
    CALL instr_set
    CALL draw_files
    MOV AL,#30               ; 300 ms: que se oiga la caida
    JMP sound_for

; --- file_tempo_ptr: AL = fichero -> BX = su TEMPO en TEMPOTAB ----------
file_tempo_ptr:
    MOV BX,#TEMPOTAB
    ADD BX,AL
    RET

; --- tempo_get: AL = el TEMPO de la cancion de trabajo, TEMPO_MIN..MAX
; (fuera de rango -- p. ej. 0, el de las canciones de antes -- = 120) -------
tempo_get:
    MOV AL,[work_tempo]
tempo_valid:                 ; AL = TEMPO guardado -> AL = TEMPO valido
    CMP AL,#TEMPO_MIN
    JMPC tg_def
    CMP AL,#(TEMPO_MAX+1)
    JMPC tg_ret
tg_def:
    MOV AL,#TEMPO_DEF
tg_ret:
    RET

; --- tempo_up / tempo_down / tempo_click: SONGS, TEMPO. DIRECCION gira:
; +-5 BPM, sin pasar de los limites; clic: +5, y de 240 vuelve a 60 ---------
tempo_click:
    CALL tempo_get
    CMP AL,#TEMPO_MAX
    JMPNZ tu_add
    MOV AL,#TEMPO_MIN
    JMP tempo_set
tempo_up:
    CALL tempo_get
    CMP AL,#TEMPO_MAX
    JMPZ tempo_set
tu_add:
    ADD AL,#TEMPO_STEP
    CMP AL,#(TEMPO_MAX+1)
    JMPC tempo_set
    MOV AL,#TEMPO_MAX
    JMP tempo_set
tempo_down:
    CALL tempo_get
    SUB AL,#TEMPO_STEP
    CMP AL,#TEMPO_MIN
    JMPNC tempo_set
    MOV AL,#TEMPO_MIN
tempo_set:
    MOV [work_tempo],AL
    CALL draw_files
    RET

; --- tempo_scale: BX = ms de la cancion -> BX = ms al TEMPO de la cancion
; = (ms x 120 + TEMPO/2) / TEMPO, exacto. ms <= 8180, asi que ms x 120 llega
; a 3 bytes: dos MUL de 8x8 (byte bajo y alto de ms) y una division larga
; de dos DIV (el byte alto del producto, < 15, siempre es menor que TEMPO)
tempo_scale:
    CALL tempo_get
    CMP AL,#TEMPO_DEF
    JMPZ tsc_ret             ; a 120, tal cual
    MOV CL,AL                ; CL = TEMPO
    MOV DL,BH
    MOV AL,BL
    MOV CH,#120
    MUL CH                   ; ms_bajo x 120
    MOV DH,CL
    SHR DH
    ADD AX,DH                ; + TEMPO/2: redondear
    MOV DH,AL                ; byte 0 del producto
    PUSH AH
    MOV AL,DL
    MUL CH                   ; ms_alto x 120 (va 8 bits a la izquierda)
    POP DL
    ADD AX,DL                ; AX = bytes 1-2 del producto
    DIV CL                   ; cociente alto (< 256: AX < 4000), AH = resto
    MOV BH,AL
    MOV AL,DH                ; resto:byte 0
    DIV CL
    MOV BL,AL
tsc_ret:
    RET

; --- repeat_toggle: SONGS, clic en REPEAT -> NO <-> YES ----------------
repeat_toggle:
    MOV AL,[work_rep]
    XOR AL,#1
    AND AL,#1
    MOV [work_rep],AL
    CALL draw_files
    RET

; --- quant_toggle: SONGS, QUANT -> OFF <-> ON (DIRECCION gira en los dos
; sentidos y el clic hacen lo mismo) -----------------------------------------
quant_prev:
quant_toggle:
    MOV AL,[quant_mode]
    CMP AL,#0
    MOV AL,#1
    JMPZ qt_set
    MOV AL,#0
qt_set:
    MOV [quant_mode],AL
    CALL draw_files
    RET

; --- files_execute: clic en SONGS -> lo de la fila (INSTR: el siguiente;
; NEW SONG: vaciar; cancion: su accion, que despues vuelve a LOAD) ----------
files_execute:
    MOV AL,[files_sel]
    CMP AL,#0
    JMPZ instr_next
    CMP AL,#ROW_TEMPO
    JMPZ tempo_click
    CMP AL,#ROW_REPEAT
    JMPZ repeat_toggle
    CMP AL,#ROW_QUANT
    JMPZ quant_toggle
    CMP AL,#ROW_NEW
    JMPZ fe_hold             ; NEW SONG: solo con DATOS larga
    MOV AL,[files_act]
    CMP AL,#0
    JMPZ fe_load
    CMP AL,#1
    JMPZ fe_save
    ; --- DEL: longitud 0 y graba el programa
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_len_ptr
    MOV AL,#0
    MOV [DX],AL
    INC DX
    MOV [DX],AL
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    MOV BL,[cur_file]
    CMP AL,BL
    JMPNZ fe_del_go
    MOV AL,#0xFF
    MOV [cur_file],AL        ; borrada la cargada: ya no hay
fe_del_go:
    CALL save_self
    MOV BX,#s_deleted
    JMP fe_status
fe_new:
    MOV AL,#0
    MOV [len_lo],AL
    MOV [len_hi],AL
    MOV AL,#0xFF
    MOV [cur_file],AL        ; cancion nueva: no viene de ninguna
    JMP fe_to_edit
fe_load:
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_len
    MOV AL,BL
    OR  AL,BH
    JMPZ fe_empty
    MOV [len_lo],BL
    MOV [len_hi],BH
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    MOV [cur_file],AL        ; la cargada (la "<" de SONGS)
    CALL file_instr_ptr
    MOV AL,[BX]
    CALL instr_set           ; su instrumento
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_rep_ptr
    MOV AL,[BX]
    AND AL,#1
    MOV [work_rep],AL        ; y si se repite
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_tempo_ptr
    MOV AL,[BX]
    CALL tempo_valid
    MOV [work_tempo],AL      ; y su TEMPO
    MOV AL,[files_sel]
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
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_instr_ptr
    MOV AL,[work_instr]
    MOV [BX],AL              ; con su instrumento
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_rep_ptr
    MOV AL,[work_rep]
    MOV [BX],AL              ; y si se repite
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_tempo_ptr
    MOV AL,[work_tempo]
    MOV [BX],AL              ; y su TEMPO
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_len_ptr
    MOV AL,[len_lo]
    MOV [DX],AL
    INC DX
    MOV AL,[len_hi]
    MOV [DX],AL
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    CALL file_base
    MOV DL,BL                ; destino: el hueco del fichero
    MOV DH,BH
    MOV BX,#WORK
    MOV CX,#512
    MOVW
    MOV AL,[files_sel]
    SUB AL,#FIRST_FILE
    MOV [cur_file],AL        ; la cancion de trabajo esta ahora en esta
    CALL save_self
    MOV BX,#s_saved
    JMP fe_status
fe_nothing:
    MOV BX,#s_nothing
fe_status:
    PUSH BL
    PUSH BH
    MOV AL,#0
    MOV [files_act],AL       ; tras hacerla, otra vez LOAD
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
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ ra_files
    CALL draw_keyboard
    MOV AL,#1
    MOV [dot_on],AL
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
    MOV AL,[mode]
    CMP AL,#MODE_FILES
    JMPZ sm_files
    MOV CX,#0x000F           ; el instrumento, arriba a la derecha
    MOV AL,[work_instr]
    CALL put_instr
    MOV AL,[work_rep]
    CMP AL,#0
    JMPZ sm_norep
    MOV BX,#s_rep            ; "REP", arriba a la izquierda
    MOV CX,#0x0000
    CALL puts
sm_norep:
    MOV AL,[rec]
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
    MOV [attr_val],AL
    MOV AL,#10
    MOV [attr_n],AL
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
    MOV [ss_lo],BL
    MOV [ss_hi],BH
    MOV AL,#0
    MOV [ss_k],AL
ss_l:
    ; ss < longitud?
    MOV AL,[ss_hi]
    MOV BL,[len_hi]
    CMP AL,BL
    JMPNZ ss_cmp
    MOV AL,[ss_lo]
    MOV BL,[len_lo]
    CMP AL,BL
ss_cmp:
    JMPNC ss_done
    ; posicion en pantalla: k<5 fila 1, si no fila 2; columna (k mod 5)*4
    MOV AL,[ss_k]
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
    MOV BL,[ss_lo]
    MOV BH,[ss_hi]
    CALL note_ptr
    CALL note_unpack
    MOV AL,[un_note]
    POP CH
    POP CL
    PUSH CL
    PUSH CH
    CALL put_note
    POP CH
    POP CL
    ; la nota de [rpos] (cursor / la que toca) va en inverso
    MOV AL,[ss_lo]
    MOV BL,[rpos_lo]
    CMP AL,BL
    JMPNZ ss_next
    MOV AL,[ss_hi]
    MOV BL,[rpos_hi]
    CMP AL,BL
    JMPNZ ss_next
    MOV AL,#ATTR_INVERSE
    MOV [attr_val],AL
    MOV AL,#3
    MOV [attr_n],AL
    CALL set_attr
ss_next:
    MOV BL,[ss_lo]
    MOV BH,[ss_hi]
    INC BX
    MOV [ss_lo],BL
    MOV [ss_hi],BH
    MOV AL,[ss_k]
    ADD AL,#1
    MOV [ss_k],AL
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
    MOV AL,[cur_note]
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
    MOV AL,[files_sel]
    MOV BL,[files_top]
    CMP AL,BL
    JMPNC df_t1
    MOV [files_top],AL       ; sel < top: la ventana sube
    JMP df_t2
df_t1:
    SUB AL,BL
    CMP AL,#LIST_ROWS
    JMPC df_t2
    MOV AL,[files_sel]       ; sel >= top+ROWS: la ventana baja
    SUB AL,#(LIST_ROWS-1)
    MOV [files_top],AL
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
    MOV [df_k],AL
df_l:
    MOV AL,[files_top]
    MOV BL,[df_k]
    ADD AL,BL
    MOV [df_i],AL            ; entrada de la lista (0 INSTR, 1 TEMPO, 2 REPEAT, 3 QUANT, 4 NEW)
    MOV AL,[df_k]
    ADD AL,#1
    MOV CH,AL                ; fila de pantalla
    MOV CL,#0
    MOV AL,[df_i]
    CMP AL,#0
    JMPNZ df_not_instr
    MOV BX,#s_instr          ; "INSTR: PIANO"
    CALL puts
    MOV AL,[work_instr]
    CALL put_instr
    JMP df_mark
df_not_instr:
    CMP AL,#ROW_TEMPO
    JMPNZ df_not_tempo
    MOV BX,#s_tempo          ; "TEMPO: 120 BPM"
    CALL puts
    CALL tempo_get
    CMP AL,#100
    JMPNC df_t3
    CALL put2                ; 60..95: sin cero delante
    JMP df_bpm
df_t3:
    MOV BL,AL
    MOV BH,#0
    CALL put_n16
df_bpm:
    MOV BX,#s_bpm
    CALL puts
    JMP df_mark
df_not_tempo:
    CMP AL,#ROW_REPEAT
    JMPNZ df_not_rep
    MOV BX,#s_repeat         ; "REPEAT: YES"
    CALL puts
    MOV BX,#s_no
    MOV AL,[work_rep]
    CMP AL,#0
    JMPZ df_r
    MOV BX,#s_yes
df_r:
    CALL puts
    JMP df_mark
df_not_rep:
    CMP AL,#ROW_QUANT
    JMPNZ df_not_quant
    MOV BX,#s_quant          ; "QUANT: ON"
    CALL puts
    MOV BX,#s_off
    MOV AL,[quant_mode]
    CMP AL,#0
    JMPZ df_q
    MOV BX,#s_on
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
    MOV AL,[df_i]
    SUB AL,#(FIRST_FILE-1)
    CALL put2                ; S01..S32
    ADD CL,#1
    PUSH CL
    PUSH CH
    MOV AL,[df_i]
    SUB AL,#FIRST_FILE
    CALL file_len
    POP CH
    POP CL
    MOV [df_len_lo],BL
    MOV [df_len_hi],BH
    MOV AL,BL
    OR  AL,BH
    JMPZ df_empty
    MOV AL,#0
    MOV [df_n],AL
df_nl:
    MOV AL,[df_len_hi]       ; quedan notas? (n < longitud)
    CMP AL,#0
    JMPNZ df_has
    MOV AL,[df_n]
    MOV BL,[df_len_lo]
    CMP AL,BL
    JMPNC df_len
df_has:
    PUSH CL
    PUSH CH
    MOV AL,[df_i]
    SUB AL,#FIRST_FILE
    CALL file_base
    MOV AL,[df_n]
    SHL AL
    ADD BX,AL                ; entrada n de ese fichero
    CALL note_unpack
    MOV AL,[un_note]
    POP CH
    POP CL
    CALL put_note
    ADD CL,#1
    MOV AL,[df_n]
    ADD AL,#1
    MOV [df_n],AL
    CMP AL,#3
    JMPNZ df_nl
df_len:
    MOV CL,#16
    MOV BL,[df_len_lo]
    MOV BH,[df_len_hi]
    CALL put_n16
    MOV AL,[df_i]            ; la cargada (o la ultima guardada): "<" al final
    SUB AL,#FIRST_FILE
    MOV BL,[cur_file]
    CMP AL,BL
    JMPNZ df_mark
    MOV CL,#20
    MOV AL,#'<'
    CALL putc
    JMP df_mark
df_empty:
    MOV BX,#s_dashes
    CALL puts
df_mark:
    ; la fila marcada: inverso entero + la accion elegida
    MOV AL,[df_i]
    MOV BL,[files_sel]
    CMP AL,BL
    JMPNZ df_next
    MOV CL,#0
    MOV AL,#ATTR_INVERSE
    MOV [attr_val],AL
    MOV AL,#21
    MOV [attr_n],AL
    PUSH CH
    CALL set_attr
    POP CH
    MOV AL,[df_i]
    CMP AL,#FIRST_FILE
    JMPC df_next             ; INSTR / NEW SONG: sin accion que elegir
    PUSH CH
    MOV BX,#s_action         ; fila de estado: "ACTION: LOAD"
    MOV CX,#0x0701
    CALL puts
    MOV AL,[files_act]
    SHL AL,#1
    MOV CL,AL
    MOV BX,#ACT_NAMES
    ADD BX,CL
    MOV AL,[BX]
    INC BX
    MOV BH,[BX]
    MOV BL,AL
    MOV CX,#0x0709
    CALL puts
    POP CH
df_next:
    MOV AL,[df_k]
    ADD AL,#1
    MOV [df_k],AL
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
    MOV [fr_y],AL
dk_row:
    MOV AL,[fr_y]
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
    MOV AL,[fr_y]
    ADD AL,#1
    MOV [fr_y],AL
    CMP AL,#(KB_Y1+1)
    JMPNZ dk_row
    ; separadores entre las 15 blancas (14 lineas apagadas)
    MOV AL,#0
    MOV [fr_val],AL
    MOV AL,#KB_Y0
    MOV [fr_y],AL
    MOV AL,#1
    MOV [fr_w],AL
    MOV AL,#(KB_Y1-KB_Y0+1)
    MOV [fr_h],AL
    MOV AL,#(KB_X0+8)
    MOV [fr_x],AL
dk_v:
    CALL fill_rect
    MOV AL,[fr_x]
    ADD AL,#8
    MOV [fr_x],AL
    CMP AL,#(KB_X0+8*15)
    JMPNZ dk_v
    ; negras: APAGADAS, 5 px de ancho centradas en su separador
    MOV AL,#0
    MOV [dk_n],AL
dk_b:
    MOV CL,[dk_n]
    MOV BX,#NOTE_KEY
    ADD BX,CL
    MOV AL,[BX]
    AND AL,#0x80
    JMPZ dk_bnext
    MOV AL,[BX]
    AND AL,#0x1F
    ADD AL,#1
    SHL AL,#3
    ADD AL,#(KB_X0-2)
    MOV [fr_x],AL
    MOV AL,#KB_Y0
    MOV [fr_y],AL
    MOV AL,#5
    MOV [fr_w],AL
    MOV AL,#BK_H
    MOV [fr_h],AL
    CALL fill_rect
dk_bnext:
    MOV AL,[dk_n]
    ADD AL,#1
    MOV [dk_n],AL
    CMP AL,#(KB_SPAN+1)
    JMPNZ dk_b
    RET

; --- draw_dot: punto de [cur_note]; [dot_on]=1 lo pinta, 0 lo borra. En
; blanca (encendida), 3x3 APAGADO abajo; en negra (apagada), 3x3 ENCENDIDO.
draw_dot:
    MOV AL,[cur_note]
    MOV BL,[kb_base]
    SUB AL,BL
    CMP AL,#(KB_SPAN+1)
    JMPC dd_in
    RET                      ; fuera del teclado dibujado (no deberia pasar)
dd_in:
    MOV CL,AL
    MOV BX,#NOTE_KEY
    ADD BX,CL
    MOV AL,[BX]
    MOV DL,AL
    MOV AL,#3
    MOV [fr_w],AL
    MOV [fr_h],AL
    MOV AL,DL
    AND AL,#0x80
    JMPNZ dd_black
    MOV AL,DL
    SHL AL,#3
    ADD AL,#(KB_X0+3)
    MOV [fr_x],AL
    MOV AL,#DOT_WY
    MOV [fr_y],AL
    MOV AL,[dot_on]
    XOR AL,#1
    MOV [fr_val],AL
    CALL fill_rect
    RET
dd_black:
    MOV AL,DL
    AND AL,#0x1F
    ADD AL,#1
    SHL AL,#3
    ADD AL,#(KB_X0-1)
    MOV [fr_x],AL
    MOV AL,#DOT_BY
    MOV [fr_y],AL
    MOV AL,[dot_on]
    MOV [fr_val],AL
    CALL fill_rect
    RET

; --- fill_rect: rectangulo [fr_x],[fr_y],[fr_w],[fr_h] a [fr_val] (1/0) ----
fill_rect:
    MOV AL,[fr_y]
    MOV [px_y],AL
    MOV AL,[fr_h]
    MOV [fr_rows],AL
fr_row:
    MOV AL,[fr_x]
    MOV [px_x],AL
    MOV AL,[fr_w]
    MOV [fr_cols],AL
fr_col:
    CALL put_px
    MOV AL,[px_x]
    ADD AL,#1
    MOV [px_x],AL
    MOV AL,[fr_cols]
    SUB AL,#1
    MOV [fr_cols],AL
    JMPNZ fr_col
    MOV AL,[px_y]
    ADD AL,#1
    MOV [px_y],AL
    MOV AL,[fr_rows]
    SUB AL,#1
    MOV [fr_rows],AL
    JMPNZ fr_row
    RET

; --- put_px: pixel ([px_x],[px_y]) a [fr_val], leyendo y reescribiendo el
; byte del framebuffer (puerto = y*16 + x/8, bit 7 = el de la izquierda) --
put_px:
    MOV AL,[px_y]
    MOV BL,#16
    MUL BL                   ; AX = y*16
    MOV BL,AL
    MOV BH,AH
    MOV AL,[px_x]
    SHR AL,#3
    ADD BX,AL
    MOV AL,[px_x]
    AND AL,#7
    MOV CL,AL
    MOV DX,#MASK8
    ADD DX,CL
    MOV CL,[DX]
    IN  AL,(BX)
    MOV AH,[fr_val]
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
    MOV AL,[BX]
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
    MOV AL,[BX]
    INC BX
    MOV BH,[BX]
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
    MOV [pn_oct],AL
    MOV AL,AH
    SHL AL,#1
    PUSH CL
    MOV CL,AL
    MOV BX,#NOTE_NAMES
    ADD BX,CL
    POP CL
    MOV AL,[BX]
    CALL putc
    INC BX
    MOV AL,[BX]
    CMP AL,#0x20
    JMPZ pn_nat
    CALL putc                ; '#'
    MOV AL,[pn_oct]
    CALL putc
    RET
pn_nat:
    MOV AL,[pn_oct]
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
    MOV AL,[attr_n]
    MOV [sa_n],AL
sa_l:
    MOV AL,[attr_val]
    OUT (DX),AL
    INC DX
    MOV AL,[sa_n]
    SUB AL,#1
    MOV [sa_n],AL
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
s_tempo:    .asciiz "TEMPO: "
s_bpm:      .asciiz " BPM"
s_no:       .asciiz "NO"
s_yes:      .asciiz "YES"
s_rep:      .asciiz "REP"
s_on:       .asciiz "ON"
s_quantizing: .asciiz "QUANTIZING..."
; figuras a las que se ajusta el ritmo en REC, en cuartos de pulso
; (sin 3/4: entre 1 y 3/4 el margen era 1/8 de pulso, y una negra algo
; corta se guardaba como 3/4)

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
cur_file:     .space 1    ; cancion cargada o guardada la ultima (0xFF = ninguna)
rec_dirty:    .space 1    ; 1 = en este REC se ha marcado alguna nota
qz_n_lo:      .space 1    ; quantize: entradas de la cancion
qz_n_hi:      .space 1
qz_i_lo:      .space 1    ; indice de la entrada en curso
qz_i_hi:      .space 1
qz_last_lo:   .space 1    ; la ultima duracion probada como rejilla
qz_last_hi:   .space 1
qz_tried:     .space 1
qz_g_lo:      .space 1    ; rejilla que se prueba (ms)
qz_g_hi:      .space 1
qz_kmin:      .space 1    ; 1 (rejilla = la nota) o 2 (su mitad)
qz_k_lo:      .space 1    ; k = duracion / rejilla, redondeado (qz_round)
qz_k_hi:      .space 1
qz_e_lo:      .space 1    ; error sumado (128 = una rejilla entera)
qz_e_hi:      .space 1
qz_lim_lo:    .space 1    ; error maximo admitido (0,15 rejillas por nota)
qz_lim_hi:    .space 1
qz_pen_lo:    .space 1    ; penalizacion de la media rejilla (0,03 por nota)
qz_pen_hi:    .space 1
qz_bg_lo:     .space 1    ; la mejor hasta ahora (rejilla, kmin, error)
qz_bg_hi:     .space 1
qz_bk:        .space 1
qz_be_lo:     .space 1
qz_be_hi:     .space 1
qz_t0:        .space 1    ; suma de las duraciones (24 bits)
qz_t1:        .space 1
qz_t2:        .space 1
qz_s0:        .space 1    ; suma de las k (24 bits)
qz_s1:        .space 1
qz_s2:        .space 1
qz_end_lo:    .space 1    ; fin de las duraciones en TMPBUF
qz_end_hi:    .space 1
qz_p_lo:      .space 1    ; qz_try: puntero en TMPBUF y entradas que quedan
qz_p_hi:      .space 1
qz_c_lo:      .space 1
qz_c_hi:      .space 1
qz_G_lo:      .space 1    ; rejilla final = suma duraciones / suma k
qz_G_hi:      .space 1
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
ms_base_lo:   .space 1    ; meas_*: lo ya medido antes del ultimo rearranque
ms_base_hi:   .space 1
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
