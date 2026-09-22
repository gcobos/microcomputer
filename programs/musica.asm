; ============================================================================
;  musica.asm  -  Obertura de Guillermo Tell (Rossini, 1829), galope final
;
;  Arreglo monofonico (un solo canal de onda cuadrada, sin acompañamiento)
;  del tema mas conocido de la obertura -- el "galope" con el que termina y
;  que todo el mundo reconoce (el tema del Llanero Solitario). Suena en
;  bucle indefinidamente; el LED late con cada nota. Sin animacion en
;  pantalla (solo un titulo estatico): no hace falta para que suene bien.
;
;  Estructura (ver la tabla `melody` al final, con la partitura comentada):
;     - tema A en registro grave, dos veces (como una repeticion de partitura)
;     - tema A una octava mas arriba, dos veces
;     - tema A "en eco": cada frase suena grave y enseguida su octava aguda
;     - floreo final: escala de dos octavas subiendo y bajando
;  El ritmo del tema (largo-corto-corto, repetido) es el "galope" que hace
;  reconocible la pieza -- sin el, con notas de igual duracion, suena a
;  marcha generica en vez de a esto.
;
;  Controles:
;     encoder DIRECCION pulsa -> termina (apaga pantalla, LED y sonido, HALT)
;
;  Ensamblar y enviar al slot 8:
;     python3 tools/casm.py programs/musica.asm -o programs/musica.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 8 programs/musica.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 8
    .org 0x0000

; Las variables y la tabla de la melodia van DESPUES del codigo (seccion
; DATOS, al final de este fichero): casm.py recorta el .bin justo tras el
; ultimo byte usado, asi que dejar hueco antes solo infla el fichero (ver
; "Tamano del .bin" en programs/README.md).

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_TEXT    = 0x0400      ; rejilla de texto
P_DIR_BTN = 0x0601      ; encoder DIRECCION: pulsado
P_LED     = 0x0610      ; LED azul de a bordo
P_T3      = 0x0623      ; temporizador 3 (8 ms/paso)
P_SND_N   = 0x0632      ; nota MIDI a sonar (0 = silencio)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV BL,#lo(h_t1)
    MOV BH,#hi(h_t1)
    MOV CL,#6
    MOV CH,#1
    CALL puts
    MOV BL,#lo(h_t2)
    MOV BH,#hi(h_t2)
    MOV CL,#3
    MOV CH,#2
    CALL puts
    MOV AL,#0
    STA [g_exit],AL

; ============================================================================
;  BUCLE PRINCIPAL: reproduce la melodia, en bucle, hasta DIRECCION
; ============================================================================
ms_rs:
    MOV AL,#lo(melody)
    STA [mel_lo],AL
    MOV AL,#hi(melody)
    STA [mel_hi],AL
ms_nx:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ ms_x

    LDA BL,[mel_lo]
    LDA BH,[mel_hi]
    LDA AL,[BX]               ; nota
    CMP AL,#0xFF
    JMPZ ms_rs                ; fin de la tabla -> repite desde el principio
    STA [cur_note],AL
    CALL mel_inc

    LDA BL,[mel_lo]
    LDA BH,[mel_hi]
    LDA AL,[BX]               ; duracion (en ticks de ~24 ms)
    STA [cur_dur],AL
    CALL mel_inc

    LDA AL,[cur_note]
    CMP AL,#0
    JMPZ ms_rest
    OUT (P_SND_N),AL
    MOV AL,#1
    OUT (P_LED),AL
    JMP ms_wt
ms_rest:
    MOV AL,#0
    OUT (P_SND_N),AL
    OUT (P_LED),AL
ms_wt:
    LDA AL,[cur_dur]
    CALL frame_wait_n          ; nota sonando
    MOV AL,#0
    OUT (P_SND_N),AL           ; corte breve entre notas (se oyen separadas
    OUT (P_LED),AL              ; aunque se repita el mismo tono)
    MOV AL,#1
    CALL frame_wait_n
    JMP ms_nx

ms_x:
    MOV AL,#0
    OUT (P_SND_N),AL
    OUT (P_LED),AL
    CALL clst
    CALL wait_dir_release
    HALT

; --- mel_inc:  suma 1 a mel_lo/mel_hi propagando el acarreo a mano ---------
mel_inc:
    LDA AL,[mel_lo]
    ADD AL,#1
    STA [mel_lo],AL
    JMPNC mel_inc_d
    LDA AL,[mel_hi]
    ADD AL,#1
    STA [mel_hi],AL
mel_inc_d:
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS (identicas a estrellas.asm/demo.asm)
; ============================================================================

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
puts:
    MOV AL,CH
    SHL AL,#5                   ; fila*32
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04                ; puerto texto = 0x0400 + fila*32 + col
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

; --- clst:  borra la capa de texto (0x0400..0x04FF) -------------------------
clst:
    MOV BL,#0
    MOV BH,#4
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
    RET

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) -----------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- frame_wait_n:  AL = numero de frames de ~24 ms -------------------------
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

; --- poll_exit:  marca g_exit si DIRECCION esta pulsado ---------------------
poll_exit:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ pe_d
    MOV AL,#1
    STA [g_exit],AL
pe_d:
    RET

; --- wait_dir_release:  espera a que se suelte DIRECCION --------------------
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
;  DATOS  (justo despues del codigo -- ver el comentario del principio)
; ============================================================================
g_exit:     .space 1    ; 1 = DIRECCION pulsado -> salir
mel_lo:     .space 1    ; puntero (bajo/alto) a la entrada en curso de `melody`
mel_hi:     .space 1
cur_note:   .space 1    ; nota MIDI de la entrada en curso (0 = silencio)
cur_dur:    .space 1    ; duracion de la entrada en curso (ticks de ~24 ms)
fwn_n:      .space 1    ; contador de frame_wait_n

h_t1:       .asciiz "OBERTURA"
h_t2:       .asciiz "GUILLERMO TELL"

; --- melody:  pares (nota MIDI, duracion en ticks de ~24 ms); nota 0 =
; silencio, nota 0xFF = fin de la tabla (vuelve a sonar desde el principio).
;
; El tema, en Do mayor: Do Do Do | Mi Do Do | Re Si Si | Do Sol Sol  (donde
; Si/Sol son los de LA OCTAVA GRAVE, justo por debajo del Do central). El
; ritmo por grupo de tres es SIEMPRE largo-corto-corto (6 ticks, 3, 3): es
; ese "dum, da-da dum, da-da..." el que se reconoce como "galope", no las
; notas por si solas.
;
; Ojo: esto NO cubre todo el finale nota a nota. La llamada de trompetas de
; abajo es un gesto generico de fanfarria (arpegio de la tonica, ritmo de
; llamada -- no galope) inspirado en la que abre el finale real, pero no una
; transcripcion literal: no tengo memorizada esa llamada con precision nota
; a nota. El tema principal que sigue si es el que todo el mundo reconoce y
; esta transcrito con confianza. El finale real tiene ademas un segundo tema
; (mas ligado, menos percutido) entre las repeticiones del principal que no
; esta incluido aqui por la misma razon: mejor omitirlo que inventarlo y
; presentarlo como si fuera nota por nota el original.
melody:
    ; --- fanfarria de apertura (gesto generico, ver aviso de arriba) --------
    .db 67,5, 67,5, 67,5, 72,10
    .db 0,4
    .db 60,5, 64,5, 67,5, 72,10
    .db 0,6
    ; --- tema A, grave, x2 (como una repeticion de partitura) --------------
    .db 60,6, 60,3, 60,3,  64,6, 60,3, 60,3,  62,6, 59,3, 59,3,  60,6, 55,3, 55,3
    .db 0,4
    .db 60,6, 60,3, 60,3,  64,6, 60,3, 60,3,  62,6, 59,3, 59,3,  60,6, 55,3, 55,3
    .db 0,4
    ; --- tema A, una octava mas arriba, x2 (mas intenso) --------------------
    .db 72,6, 72,3, 72,3,  76,6, 72,3, 72,3,  74,6, 71,3, 71,3,  72,6, 67,3, 67,3
    .db 0,4
    .db 72,6, 72,3, 72,3,  76,6, 72,3, 72,3,  74,6, 71,3, 71,3,  72,6, 67,3, 67,3
    .db 0,4
    ; --- tema A "en eco": cada grupo suena grave y responde en la octava
    ; aguda de inmediato, mas vivo (largo=4, corto=2) --------------------
    .db 60,4, 60,2, 60,2,  72,4, 72,2, 72,2
    .db 64,4, 60,2, 60,2,  76,4, 72,2, 72,2
    .db 62,4, 59,2, 59,2,  74,4, 71,2, 71,2
    .db 60,4, 55,2, 55,2,  72,4, 67,2, 67,2
    .db 0,4
    ; --- floreo final: escala de Sol3 a Sol5 subiendo y bajando otra vez
    ; hasta Do4, para cerrar sobre la tonica ---------------------------------
    .db 55,2, 57,2, 59,2, 60,2, 62,2, 64,2, 65,2, 67,2, 69,2, 71,2, 72,2, 74,2, 76,2, 77,2
    .db 79,8
    .db 77,2, 76,2, 74,2, 72,2, 71,2, 69,2, 67,2, 65,2, 64,2, 62,2, 60,8
    ; silencio antes de repetir desde el principio
    .db 0,10
    .db 0xFF
