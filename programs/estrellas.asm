; ============================================================================
;  estrellas.asm  -  cielo estrellado con parpadeo (compi)
;
;  16 estrellas en posiciones fijas, cada una con su propio ciclo (asincrono,
;  gracias al LFSR): permanece apagada un rato al azar, aparece como un punto,
;  crece a una cruz de 5 pixeles (brillo maximo), vuelve a punto y se apaga.
;  Como el framebuffer es 1 bit por pixel (sin niveles de gris), "brillar mas
;  fuerte" se simula agrandando la estrella en vez de aclararla.
;
;  El LED azul de a bordo (puerto 0x0510) tambien es todo/nada (sin PWM), asi
;  que hace "lo mismo que la pantalla" del modo que puede: se enciende siempre
;  que al menos una estrella esta en su fase de brillo maximo, y se apaga si
;  ninguna lo esta -> parpadea al ritmo del cielo.
;
;  Controles en EJECUTAR + CONTINUO:
;     encoder DIRECCION pulsa -> termina (apaga pantalla y LED, HALT)
;
;  Ensamblar y enviar al slot 5:
;     python3 tools/casm.py programs/estrellas.asm -o programs/estrellas.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 5 programs/estrellas.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 5
    .org 0x0000

NSTARS   = 16

; Las variables y las tablas van DESPUES del codigo (seccion DATOS, al final
; de este fichero), no en direcciones altas fijas tipo 0xFE00: casm.py recorta
; el .bin justo tras el ultimo byte usado, asi que dejar hueco antes solo
; infla el fichero y lo que se manda por el cable sin necesidad (ver el
; comentario de cabecera de tools/casm.py).

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000      ; framebuffer
P_TEXT    = 0x0400      ; rejilla de texto
P_DAT_POS = 0x0502      ; encoder DATOS: posicion (solo para sembrar el LFSR)
P_DIR_BTN = 0x0501      ; encoder DIRECCION: pulsado
P_LED     = 0x0510      ; LED azul de a bordo
P_T3      = 0x0523      ; temporizador 3 (8 ms/paso)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    IN  AL,(P_DAT_POS)         ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    JMPNZ init
    MOV AL,#0x5D
    STA [seed],AL

init:
    CALL clsg
    CALL clst
    MOV BL,#lo(h_title)
    MOV BH,#hi(h_title)
    MOV CL,#2
    MOV CH,#0
    CALL puts
    MOV AL,#0
    STA [g_exit],AL

    MOV AL,#0
    STA [idx],AL
init_l:
    LDA CL,[idx]

    ; x al azar en [4,123]
    CALL rnd
    AND AL,#0x7F
    CMP AL,#124
    JMPC ix_uok
    MOV AL,#123
ix_uok:
    CMP AL,#4
    JMPNC ix_lok
    MOV AL,#4
ix_lok:
    MOV BL,#lo(star_x)
    MOV BH,#hi(star_x)
    CALL star_ptr
    STA [BX],AL

    ; y al azar en [10,58]  (deja libre la fila de texto del titulo)
    CALL rnd
    AND AL,#0x3F
    CMP AL,#59
    JMPC iy_uok
    MOV AL,#58
iy_uok:
    CMP AL,#10
    JMPNC iy_lok
    MOV AL,#10
iy_lok:
    MOV BL,#lo(star_y)
    MOV BH,#hi(star_y)
    CALL star_ptr
    STA [BX],AL

    ; estado inicial = 0 (apagada)
    MOV BL,#lo(star_state)
    MOV BH,#hi(star_state)
    CALL star_ptr
    MOV AL,#0
    STA [BX],AL

    ; espera inicial al azar (desincroniza las estrellas entre si)
    CALL rnd
    AND AL,#0x3F
    ADD AL,#4
    MOV BL,#lo(star_timer)
    MOV BH,#hi(star_timer)
    CALL star_ptr
    STA [BX],AL

    LDA AL,[idx]
    ADD AL,#1
    STA [idx],AL
    CMP AL,#NSTARS
    JMPNZ init_l

; ============================================================================
;  BUCLE PRINCIPAL
; ============================================================================
main_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ main_x

    MOV AL,#0
    STA [idx],AL
    STA [led_cnt],AL
star_l:
    CALL do_star
    LDA AL,[idx]
    ADD AL,#1
    STA [idx],AL
    CMP AL,#NSTARS
    JMPNZ star_l

    LDA AL,[led_cnt]
    CMP AL,#0
    JMPZ ml_ledoff
    MOV AL,#1
    OUT (P_LED),AL
    JMP ml_leddone
ml_ledoff:
    MOV AL,#0
    OUT (P_LED),AL
ml_leddone:
    MOV AL,#2
    CALL frame_wait
    JMP main_l

main_x:
    MOV AL,#0
    OUT (P_LED),AL
    CALL clsg
    CALL clst
    CALL wait_dir_release
    HALT

; ============================================================================
;  do_star:  avanza y dibuja la estrella [idx]
;
;  Ciclo por estrella:  0 apagada -> 1 punto -> 2 cruz (brillo max) ->
;                        3 punto -> 0 apagada -> ...
;  Cada estado tiene su propio temporizador (en ticks de main_l, ~16 ms);
;  al llegar a 0 se borra la forma vieja, se avanza el estado y se dibuja
;  la forma nueva con un temporizador nuevo (algo al azar, para que titilen
;  sin sincronizarse).
; ============================================================================
do_star:
    LDA CL,[idx]
    MOV BL,#lo(star_state)
    MOV BH,#hi(star_state)
    CALL star_ptr
    LDA AL,[BX]
    STA [st_state],AL

    LDA CL,[idx]
    MOV BL,#lo(star_timer)
    MOV BH,#hi(star_timer)
    CALL star_ptr
    LDA AL,[BX]
    STA [st_timer],AL

    LDA AL,[st_timer]
    CMP AL,#0
    JMPZ ds_transition
    SUB AL,#1
    STA [st_timer],AL
    LDA CL,[idx]
    MOV BL,#lo(star_timer)
    MOV BH,#hi(star_timer)
    CALL star_ptr
    STA [BX],AL
    LDA AL,[st_state]
    CMP AL,#2
    JMPNZ ds_ret
    LDA AL,[led_cnt]
    ADD AL,#1
    STA [led_cnt],AL
ds_ret:
    RET

ds_transition:
    ; carga x,y de la estrella (para borrar/dibujar)
    LDA CL,[idx]
    MOV BL,#lo(star_x)
    MOV BH,#hi(star_x)
    CALL star_ptr
    LDA AL,[BX]
    STA [px_x],AL

    LDA CL,[idx]
    MOV BL,#lo(star_y)
    MOV BH,#hi(star_y)
    CALL star_ptr
    LDA AL,[BX]
    STA [px_y],AL

    ; borra la forma del estado viejo
    LDA AL,[st_state]
    CMP AL,#0
    JMPZ ds_adv                ; 0 = apagada, nada que borrar
    CMP AL,#2
    JMPZ ds_erbig
    CALL pix_off               ; 1,3 = punto
    JMP ds_adv
ds_erbig:
    CALL clr_plus              ; 2 = cruz

ds_adv:
    ; avanza el estado: 0->1->2->3->0
    LDA AL,[st_state]
    ADD AL,#1
    CMP AL,#4
    JMPNZ ds_newst
    MOV AL,#0
ds_newst:
    STA [st_state],AL

    ; dibuja la forma nueva y calcula el temporizador nuevo
    CMP AL,#0
    JMPZ ds_hidden
    CMP AL,#2
    JMPZ ds_big
    ; estados 1,3: punto suelto
    CALL pix_on
    CALL rnd
    AND AL,#0x07
    ADD AL,#3                  ; 3..10 ticks
    JMP ds_settimer
ds_big:
    CALL set_plus
    LDA AL,[led_cnt]
    ADD AL,#1
    STA [led_cnt],AL
    CALL rnd
    AND AL,#0x0F
    ADD AL,#6                  ; 6..21 ticks de brillo maximo
    JMP ds_settimer
ds_hidden:
    CALL rnd
    AND AL,#0x3F
    ADD AL,#10                 ; 10..73 ticks apagada
ds_settimer:
    STA [st_timer],AL

    LDA CL,[idx]
    MOV BL,#lo(star_state)
    MOV BH,#hi(star_state)
    CALL star_ptr
    LDA AL,[st_state]
    STA [BX],AL

    LDA CL,[idx]
    MOV BL,#lo(star_timer)
    MOV BH,#hi(star_timer)
    CALL star_ptr
    LDA AL,[st_timer]
    STA [BX],AL
    RET

; --- star_ptr:  BX = (BX inicial) + CL, propagando el acarreo a mano -------
; entra: BL/BH = direccion base de una tabla de estrellas, CL = indice
; sale:  BL/BH = direccion base + indice (BH+1 si BL desbordo)
star_ptr:
    ADD BL,CL
    JMPNC sp_d
    ADD BH,#1
sp_d:
    RET

; ============================================================================
;  RUTINAS DE DIBUJO
; ============================================================================

; --- set_plus / clr_plus:  cruz de 5 pixeles centrada en (px_x,px_y) --------
set_plus:
    MOV AL,#1
    JMP mode_plus
clr_plus:
    MOV AL,#0
    ; cae en mode_plus

mode_plus:
    STA [tmp2],AL              ; tmp2 = modo (1 enciende, 0 apaga)
    LDA AL,[px_x]
    STA [tmp0],AL               ; tmp0 = cx
    LDA AL,[px_y]
    STA [tmp1],AL               ; tmp1 = cy

    CALL mp_dot                 ; centro

    LDA AL,[tmp1]
    SUB AL,#1
    STA [px_y],AL
    LDA AL,[tmp0]
    STA [px_x],AL
    CALL mp_dot                 ; arriba

    LDA AL,[tmp1]
    ADD AL,#1
    STA [px_y],AL
    LDA AL,[tmp0]
    STA [px_x],AL
    CALL mp_dot                 ; abajo

    LDA AL,[tmp1]
    STA [px_y],AL
    LDA AL,[tmp0]
    SUB AL,#1
    STA [px_x],AL
    CALL mp_dot                 ; izquierda

    LDA AL,[tmp1]
    STA [px_y],AL
    LDA AL,[tmp0]
    ADD AL,#1
    STA [px_x],AL
    CALL mp_dot                 ; derecha

    LDA AL,[tmp0]
    STA [px_x],AL
    LDA AL,[tmp1]
    STA [px_y],AL
    RET

mp_dot:
    LDA AL,[tmp2]
    CMP AL,#0
    JMPZ mp_off
    CALL pix_on
    RET
mp_off:
    CALL pix_off
    RET

; --- pix_on / pix_off:  enciende/apaga el pixel (px_x,px_y) -----------------
pix_on:
    CALL calc_pix
    LDA BL,[pix_lo]
    LDA BH,[pix_hi]
    IN  AL,(BX)
    LDA DL,[pix_mask]
    OR  AL,DL
    OUT (BX),AL
    RET

pix_off:
    CALL calc_pix
    LDA BL,[pix_lo]
    LDA BH,[pix_hi]
    IN  AL,(BX)
    LDA DL,[pix_mask]
    NOT DL
    AND AL,DL
    OUT (BX),AL
    RET

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara --------
calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL
    SHL AL
    SHL AL
    SHL AL                      ; AL = (y&15)<<4
    MOV DL,CL
    SHR DL
    SHR DL
    SHR DL                      ; DL = x>>3 (xbyte)
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL
    SHR AL
    SHR AL
    SHR AL                      ; AL = y>>4
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
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
puts:
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL                      ; fila*32
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

; --- clsg:  apaga el framebuffer completo (0x0000..0x03FF) -----------------
clsg:
    MOV BL,#0
    MOV BH,#0
    MOV AL,#0
cg_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC cg_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ cg_l
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

; --- rnd:  numero al azar en AL --------------------------------------------
; combina 3 pasos del LFSR (XOR) en vez de usar pasos consecutivos sueltos:
; pasos vecinos de un LFSR estan muy correlados (uno es casi un desplazamiento
; del otro), y eso se notaba en el cielo -- las estrellas salian casi en
; linea en vez de esparcidas. Mezclando 3 pasos se disimula esa correlacion.
rnd:
    CALL rnd_raw
    MOV DL,AL
    CALL rnd_raw
    XOR DL,AL
    CALL rnd_raw
    XOR DL,AL
    MOV AL,DL
    RET

; --- rnd_raw:  un paso de LFSR de 8 bits (taps 0xB8) ------------------------
rnd_raw:
    LDA AL,[seed]
    SHR AL
    JMPNC rr_n
    XOR AL,#0xB8
rr_n:
    STA [seed],AL
    RET

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) -----------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- poll_exit:  marca g_exit si DIRECCION esta pulsado --------------------
poll_exit:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ pe_d
    MOV AL,#1
    STA [g_exit],AL
pe_d:
    RET

; --- wait_dir_release:  espera a que se suelte DIRECCION -------------------
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
seed:       .space 1    ; semilla del LFSR (nunca 0)
idx:        .space 1    ; indice de estrella en curso (0..NSTARS-1)
tmp0:       .space 1
tmp1:       .space 1
tmp2:       .space 1
px_x:       .space 1    ; argumentos de pix_on/pix_off
px_y:       .space 1
pix_lo:     .space 1    ; puerto calculado (bajo/alto) + mascara de bit
pix_hi:     .space 1
pix_mask:   .space 1
st_state:   .space 1    ; copia de trabajo: estado de la estrella en curso
st_timer:   .space 1    ; copia de trabajo: temporizador de la estrella en curso
led_cnt:    .space 1    ; cuantas estrellas estan al maximo este ciclo
g_exit:     .space 1    ; 1 = DIRECCION pulsado -> salir

star_x:     .space 16   ; x de cada estrella (0..127) -- NSTARS
star_y:     .space 16   ; y de cada estrella (0..63)  -- NSTARS
star_state: .space 16   ; 0 apagada / 1 punto / 2 cruz / 3 punto
star_timer: .space 16   ; ticks que faltan para el proximo cambio

h_title:    .asciiz "CIELO ESTRELLADO"
