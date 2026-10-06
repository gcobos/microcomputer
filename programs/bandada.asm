; ============================================================================
;  bandada.asm  -  bandada de particulas en 3D cruzando el cielo a toda
;  velocidad, como un tunel de estrellas pero con "aves" (compi)
;
;  NPART particulas en el espacio (wx,wy,wz): wx/wy son su posicion lateral
;  (mundo, con signo), wz su profundidad (mundo, sin signo, mas alto = mas
;  lejos). Cada fotograma [wz] baja -- se ACERCA a la camara -- a su propia
;  velocidad ([zspeed], distinta por particula para que no viajen todas
;  sincronizadas); al proyectar en pantalla con perspectiva DE VERDAD
;  (pantalla = centro +- (offset*FOCAL)/z, ver proj_axis) su tamano y su
;  separacion del centro crecen cuanto mas cerca esta -- el efecto clasico
;  de "volar a traves de un enjambre a toda leche". En cuanto una particula
;  se sale de la pantalla (proyeccion invalida) o llega demasiado cerca, se
;  reaparece lejos con una posicion lateral nueva al azar -- asi el ciclo
;  no para nunca: cada particula se ve "alejarse" (reaparece chiquita y
;  lejos) y "acercarse" (crece y cruza la pantalla a toda velocidad) una y
;  otra vez, sin que dos vuelvan a repetir exactamente el mismo camino.
;
;  PROYECCION EN PERSPECTIVA CON DIVISION DE HARDWARE: esta CPU SI tiene
;  MUL y DIV de verdad (familias 27/28, ver ../docs/isa.md SS4d) -- a
;  diferencia de cubo.asm (solo MUL, proyeccion ORTOGRAFICA, sin dividir)
;  aqui se usa DIV de hardware para la division por profundidad de cada
;  particula, cada fotograma. MUL/DIV son sin signo, asi que el signo del
;  desplazamiento lateral se extrae a mano antes (igual que smul64 en
;  cubo.asm) y se reaplica despues. DIV satura AL=AH=0xFF con C=V=1 si el
;  cociente no cabe en 8 bits (o si z fuera 0, lo que nunca deberia pasar
;  gracias al margen de seguridad de update_and_draw_particle) --
;  proj_axis usa exactamente ese acarreo para decidir "esto se sale de
;  pantalla" sin tener que comprobar ningun rango aparte.
;
;  DOS TAMANOS segun la distancia real (no un temporizador, a diferencia
;  de estrellas.asm): un solo pixel de lejos, una "V" de 3 pixeles (silueta
;  de ave, alas hacia atras) por debajo de Z_BIG_THRESH -- crecen de verdad
;  segun se acercan, no solo se mueven.
;
;  LA CAMARA VIAJA EN UN "8" (update_camera): en vez de mirar siempre recto
;  al frente, la camara se desplaza lateralmente trazando una curva de
;  Lissajous 1:2 -- cam_x=A*sin(t), cam_y=B*sin(2t) -- que es exactamente
;  la forma de "8" que traza el borde de una cinta de Moebius vista de
;  canto (o el típico "ocho" que hace un avión acrobático). [cam_t] (fase,
;  0..63) recorre dos tablas precalculadas en Python (CAM_SINE_X/_Y, un
;  seno normal, la segunda muestreada al DOBLE de velocidad de fase para
;  el segundo lóbulo del 8 -- sin tabla aparte ni ninguna trigonometria en
;  tiempo real, solo SHL+AND para la fase doble) y avanza un paso cada
;  CAM_T_DIV fotogramas (si avanzara cada fotograma el bucle de 64 pasos
;  se notaria demasiado corto y repetitivo). El desplazamiento resultante
;  (cam_x,cam_y) se RESTA del wx/wy de cada particula antes de proyectar
;  (ver update_and_draw_particle) -- desplazar el mundo al reves de la
;  camara es el truco clasico para simular que es la camara la que se
;  mueve, sin tener que re-proyectar nada mas: las aves que antes estaban
;  centradas ahora cruzan la pantalla siguiendo el "8" en sentido
;  contrario, como si de verdad se estuviera volando a traves de ellas
;  haciendo esa figura.
;
;  Doble buffer por software (shadow/clr_shadow/blit), igual que cubo.asm:
;  cada fotograma se limpia `shadow`, se proyectan y dibujan ahi las NPART
;  particulas, y `blit` copia al framebuffer real solo lo que cambio (sin
;  parpadeo).
;
;  Controles (en EJECUTAR + CONTINUO):
;     encoder DIRECCION pulsa -> termina (vuelve al sistema, slot 0)
;
;  Ensamblar y enviar al slot 19:
;     python3 tools/casm.py programs/bandada.asm -o programs/bandada.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 19 programs/bandada.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 19

    .name "BIRD FLOCK"

    .category DEMO
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DAT_POS   = 0x0602     ; encoder DATOS: posicion (solo para sembrar el LFSR)
P_DIR_BTN   = 0x0601     ; encoder DIRECCION: pulsado -> salir
P_PROG_LOAD = 0x0640     ; cargar slot (OUT nº de slot): salto a otro programa
P_T3        = 0x0623     ; temporizador 3 (8 ms/paso)

NPART = 26

CENTER_X = 64
CENTER_Y = 32
LIMIT_X  = 62            ; proyeccion valida si desplazamiento en pantalla < 62
LIMIT_Y  = 31            ; proyeccion valida si desplazamiento en pantalla < 31
FOCAL    = 50             ; "distancia focal" fija -- ver proj_axis

Z_FAR         = 160      ; profundidad de reaparicion (lejos)
Z_JITTER      = 32       ; +0..31 al azar, para que no reaparezcan sincronizadas
Z_NEAR_MARGIN = 6        ; margen de seguridad antes de forzar reaparicion
Z_BIG_THRESH  = 50       ; por debajo de esta distancia, silueta de 3 pixeles

CAM_T_DIV = 4             ; fotogramas por paso de fase de la camara (ver
                           ; update_camera) -- un ciclo completo del "8" dura
                           ; 64*CAM_T_DIV fotogramas

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    IN  AL,(P_DAT_POS)      ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    JMPNZ init
    MOV AL,#0x5D            ; salvaguarda: un seed=0 dejaria el LFSR degenerado
    STA [seed],AL

init:
    CALL clsg
    CALL clst
    MOV BX,#h_title
    MOV CX,#0x030B
    CALL puts
    MOV AL,#0
    STA [g_exit],AL
    STA [cam_t],AL
    STA [cam_div],AL
    STA [cam_x],AL
    STA [cam_y],AL

    ; splash breve antes de arrancar la animacion de verdad
    MOV AL,#60
    STA [splash_cnt],AL
splash_l:
    MOV AL,#2
    CALL frame_wait
    LDA AL,[splash_cnt]
    SUB AL,#1
    STA [splash_cnt],AL
    JMPNZ splash_l
    CALL clst

    ; siembra inicial: cada particula con una profundidad al azar entre
    ; "cerca" y "lejos" -- si no, las NPART empezarian todas pegadas a
    ; Z_FAR y se verian llegar de golpe, "en oleada", en vez de repartidas
    ; por todo el cielo desde el primer fotograma
    MOV AL,#0
    STA [p_i],AL
init_l:
    CALL randomize_xy_speed
    CALL rnd
    AND AL,#0x7F
    ADD AL,#(Z_NEAR_MARGIN+20)
    STA [tmp_v],AL
    LDA CL,[p_i]
    MOV BX,#wz
    ADD BX,CL
    LDA AL,[tmp_v]
    STA [BX],AL

    LDA AL,[p_i]
    ADD AL,#1
    STA [p_i],AL
    CMP AL,#NPART
    JMPNZ init_l

; ============================================================================
;  BUCLE PRINCIPAL
; ============================================================================
main_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ main_x

    CALL clr_shadow
    CALL update_camera

    MOV AL,#0
    STA [p_i],AL
part_l:
    CALL update_and_draw_particle
    LDA AL,[p_i]
    ADD AL,#1
    STA [p_i],AL
    CMP AL,#NPART
    JMPNZ part_l

    CALL blit
    MOV AL,#2
    CALL frame_wait
    JMP main_l

main_x:
    CALL clsg
    CALL clst
    CALL wait_dir_release
    MOV AL,#0
    OUT (P_PROG_LOAD),AL       ; vuelve al sistema (sisop, slot 0)
    HALT                        ; solo si el slot 0 estuviera vacio

; ============================================================================
;  update_and_draw_particle: procesa la particula [p_i] -- avanza su
;  profundidad (o la reaparece lejos si ya toca), proyecta su X/Y con
;  perspectiva real y dibuja su silueta en `shadow` si el resultado cae
;  dentro de pantalla; si no, tambien la reaparece lejos (se salio del
;  cuadro -- "curva tras haber cruzado", no hace falta esperar a que
;  llegue a la camara para empezar de nuevo).
; ============================================================================
update_and_draw_particle:
    LDA CL,[p_i]
    MOV BX,#wz
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_wz],AL

    LDA CL,[p_i]
    MOV BX,#zspeed
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_speed],AL

    ; si avanzar la dejaria por debajo de Z_NEAR_MARGIN (o ya esta ahi),
    ; reaparece lejos esta misma vuelta en vez de arriesgarse a restar de
    ; mas (wz es sin signo: por debajo de 0 daria la vuelta a ~255, que se
    ; veria como "larguisimos lejos" en vez de "demasiado cerca")
    LDA AL,[cur_speed]
    ADD AL,#Z_NEAR_MARGIN
    STA [tmp_lim],AL
    LDA AL,[cur_wz]
    LDA BL,[tmp_lim]
    CMP AL,BL
    JMPC uadp_respawn           ; cur_wz < cur_speed+margen -> reaparece

    LDA AL,[cur_wz]
    LDA BL,[cur_speed]
    SUB AL,BL
    STA [cur_wz],AL
    LDA CL,[p_i]
    MOV BX,#wz
    ADD BX,CL
    LDA AL,[cur_wz]
    STA [BX],AL
    JMP uadp_project

uadp_respawn:
    CALL respawn_far
    RET                          ; no dibuja esta vuelta -- reaparece ya lejos

uadp_project:
    ; --- eje X: proyecta (wx[p_i]-cam_x) contra CENTER_X/LIMIT_X ------------
    ; restar el desplazamiento de la camara ANTES de proyectar es lo que
    ; hace que sea "la camara" la que se mueve en el 8 -- ver update_camera
    ; y la nota de cabecera.
    LDA CL,[p_i]
    MOV BX,#wx
    ADD BX,CL
    LDA AL,[BX]
    LDA BL,[cam_x]
    SUB AL,BL
    STA [pa_off],AL
    MOV AL,#CENTER_X
    STA [pa_center],AL
    MOV AL,#LIMIT_X
    STA [pa_limit],AL
    CALL proj_axis
    LDA AL,[pa_ok]
    CMP AL,#0
    JMPZ uadp_offscreen
    LDA AL,[pa_result]
    STA [dp_sx],AL

    ; --- eje Y: proyecta (wy[p_i]-cam_y) contra CENTER_Y/LIMIT_Y ------------
    LDA CL,[p_i]
    MOV BX,#wy
    ADD BX,CL
    LDA AL,[BX]
    LDA BL,[cam_y]
    SUB AL,BL
    STA [pa_off],AL
    MOV AL,#CENTER_Y
    STA [pa_center],AL
    MOV AL,#LIMIT_Y
    STA [pa_limit],AL
    CALL proj_axis
    LDA AL,[pa_ok]
    CMP AL,#0
    JMPZ uadp_offscreen
    LDA AL,[pa_result]
    STA [dp_sy],AL

    ; --- dibuja: punto si lejos, "V" de 3 pixeles si cerca ------------------
    LDA AL,[cur_wz]
    CMP AL,#Z_BIG_THRESH
    JMPC uadp_big                ; cur_wz < Z_BIG_THRESH -> cerca, silueta grande

    LDA AL,[dp_sx]
    STA [px_x],AL
    LDA AL,[dp_sy]
    STA [px_y],AL
    CALL shadow_set_px
    RET

uadp_big:
    LDA AL,[dp_sx]
    STA [px_x],AL
    LDA AL,[dp_sy]
    STA [px_y],AL
    CALL shadow_set_px           ; centro

    LDA AL,[dp_sx]
    SUB AL,#2
    STA [px_x],AL
    LDA AL,[dp_sy]
    SUB AL,#1
    STA [px_y],AL
    CALL shadow_set_px           ; ala izquierda (arriba)

    LDA AL,[dp_sx]
    ADD AL,#2
    STA [px_x],AL
    LDA AL,[dp_sy]
    SUB AL,#1
    STA [px_y],AL
    CALL shadow_set_px           ; ala derecha (arriba)
    RET

uadp_offscreen:
    CALL respawn_far
    RET

; ============================================================================
;  proj_axis:  pantalla = [pa_center] +- ([pa_off]*FOCAL)/[cur_wz]
;  entra: [pa_off] (con signo), [pa_center], [pa_limit], [cur_wz] (>0)
;  sale:  [pa_ok] (0 fuera de pantalla, 1 valido), [pa_result] si pa_ok=1
;
;  MUL/DIV son sin signo (ver docs/isa.md SS4d) -- se extrae el signo de
;  [pa_off] a mano (igual que smul64 en cubo.asm), se multiplica y divide
;  la MAGNITUD, y se reaplica el signo al sumar/restar del centro. DIV
;  satura AL=AH=0xFF con C=V=1 si el cociente no cabe en 8 bits: ese mismo
;  acarreo es la comprobacion de "esto se sale de pantalla", sin tener que
;  repetirla a mano.
; ============================================================================
proj_axis:
    MOV AL,#0
    STA [pa_sign],AL
    LDA AL,[pa_off]
    AND AL,#0x80
    JMPZ pax_pos
    MOV AL,#1
    STA [pa_sign],AL
    LDA AL,[pa_off]
    NOT AL
    ADD AL,#1
    STA [pa_off],AL
pax_pos:
    LDA AL,[pa_off]
    MOV BL,#FOCAL
    MUL BL                       ; AX = |pa_off| * FOCAL (nunca desborda 16
                                  ; bits: como mucho 127*50=6350)
    LDA BL,[cur_wz]
    DIV BL                       ; AL = AX / cur_wz -- satura si no cupo
    JMPC pax_invalid
    STA [pa_mag],AL
    LDA BL,[pa_limit]
    CMP AL,BL
    JMPC pax_inrange             ; pa_mag < pa_limit -> dentro de pantalla
pax_invalid:
    MOV AL,#0
    STA [pa_ok],AL
    RET
pax_inrange:
    LDA AL,[pa_sign]
    CMP AL,#0
    JMPNZ pax_neg
    LDA AL,[pa_center]
    LDA BL,[pa_mag]
    ADD AL,BL
    STA [pa_result],AL
    MOV AL,#1
    STA [pa_ok],AL
    RET
pax_neg:
    LDA AL,[pa_center]
    LDA BL,[pa_mag]
    SUB AL,BL
    STA [pa_result],AL
    MOV AL,#1
    STA [pa_ok],AL
    RET

; ============================================================================
;  randomize_xy_speed: nueva posicion lateral (wx,wy) y velocidad de avance
;  (zspeed) al azar para la particula [p_i] -- nunca toca wz (eso decide
;  quien llama: lejos fijo para las que se salen de pantalla/pasan de
;  largo, o repartido por todo el rango solo en la siembra inicial).
; ============================================================================
randomize_xy_speed:
    CALL rnd
    AND AL,#0x7F
    SUB AL,#64                   ; wx: -64..63
    STA [tmp_v],AL
    LDA CL,[p_i]
    MOV BX,#wx
    ADD BX,CL
    LDA AL,[tmp_v]
    STA [BX],AL

    CALL rnd
    AND AL,#0x3F
    SUB AL,#32                   ; wy: -32..31
    STA [tmp_v],AL
    LDA CL,[p_i]
    MOV BX,#wy
    ADD BX,CL
    LDA AL,[tmp_v]
    STA [BX],AL

    CALL rnd
    AND AL,#3
    ADD AL,#2                    ; zspeed: 2..5
    STA [tmp_v],AL
    LDA CL,[p_i]
    MOV BX,#zspeed
    ADD BX,CL
    LDA AL,[tmp_v]
    STA [BX],AL
    RET

; ============================================================================
;  respawn_far: reaparece la particula [p_i] lejos (Z_FAR + 0..31 al azar,
;  ver Z_JITTER) con una posicion lateral y velocidad nuevas.
; ============================================================================
respawn_far:
    CALL randomize_xy_speed
    CALL rnd
    AND AL,#(Z_JITTER-1)
    ADD AL,#Z_FAR
    STA [tmp_v],AL
    LDA CL,[p_i]
    MOV BX,#wz
    ADD BX,CL
    LDA AL,[tmp_v]
    STA [BX],AL
    RET

; ============================================================================
;  update_camera: hace avanzar la camara por un "8" (Lissajous 1:2) y deja
;  el desplazamiento actual en [cam_x]/[cam_y] -- ver la nota de cabecera.
;  [cam_t] (fase, 0..63) solo avanza un paso cada CAM_T_DIV fotogramas
;  ([cam_div] cuenta hasta ahi); cam_x sale de CAM_SINE_X[cam_t] tal cual,
;  cam_y de CAM_SINE_Y[(cam_t*2) mod 64] -- la fase DOBLE es lo que dibuja
;  el segundo lobulo del 8, y sale con un SHL+AND, sin tabla aparte ni
;  ninguna multiplicacion ni trigonometria en tiempo real.
; ============================================================================
update_camera:
    LDA AL,[cam_div]
    ADD AL,#1
    STA [cam_div],AL
    CMP AL,#CAM_T_DIV
    JMPNZ uc_recompute
    MOV AL,#0
    STA [cam_div],AL
    LDA AL,[cam_t]
    ADD AL,#1
    AND AL,#0x3F
    STA [cam_t],AL

uc_recompute:
    LDA CL,[cam_t]
    MOV BX,#CAM_SINE_X
    ADD BX,CL
    LDA AL,[BX]
    STA [cam_x],AL

    LDA AL,[cam_t]
    SHL AL,#1
    AND AL,#0x3F              ; fase doble (2*cam_t mod 64) -- segundo lobulo
    MOV CL,AL
    MOV BX,#CAM_SINE_Y
    ADD BX,CL
    LDA AL,[BX]
    STA [cam_y],AL
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS (mismo patron que estrellas.asm/cubo.asm)
; ============================================================================

; --- idx_ptr:  BX += CL (con acarreo, instruccion de hardware) -------------
idx_ptr:
    ADD BX,CL
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
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
    INC BX
    INC DX
    JMP ps_l
ps_d:
    RET

; --- clsg:  apaga el framebuffer real completo (0x0000..0x03FF) ------------
clsg:
    MOV BX,#0x0000
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
    MOV BX,#0x0400
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
    RET

; --- rnd:  numero al azar en AL (3 pasos de LFSR combinados, ver estrellas.asm
; para el porque: pasos vecinos de un LFSR solo estan muy correlados) -------
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

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4                    ; AL = (y&15)<<4
    MOV DL,CL
    SHR DL,#3                    ; DL = x>>3 (xbyte)
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL,#4                    ; AL = y>>4
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

; --- shadow_set_px:  enciende el pixel (px_x,px_y) en `shadow` (RAM), no en
; el framebuffer real -- `blit` lo copia de verdad al terminar el fotograma.
shadow_set_px:
    CALL calc_pix
    MOV BX,#shadow
    LDA CL,[pix_lo]
    ADD BX,CL
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
; pone a 0 el PRIMER byte y usa MOVB con origen/destino solapados en 1 para
; que ese unico 0 se propague en cascada al resto -- ver la nota de cubo.asm
; (MOVB no es memmove-seguro con origen<destino solapados asi, y aqui es
; exactamente eso lo que se aprovecha a proposito).
clr_shadow:
    MOV AL,#0
    STA [shadow],AL
    MOV BX,#shadow
    MOV DX,#shadow+1
    MOV CX,#0x03FF ; CX = 1023 (el resto del buffer de 1024)
    MOVB
    RET

; --- blit:  copia `shadow` al framebuffer real, solo lo que haya cambiado --
blit:
    MOV BX,#0x0000
    MOV DX,#shadow
bl_l:
    IN  AL,(BX)
    LDA CL,[DX]
    CMP AL,CL
    JMPZ bl_same
    MOV AL,CL
    OUT (BX),AL
bl_same:
    INC DX
    ADD BL,#1
    JMPNC bl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ bl_l
    RET

; ============================================================================
;  VARIABLES
; ============================================================================
seed:        .space 1
g_exit:      .space 1
splash_cnt:  .space 1
p_i:         .space 1
tmp_v:       .space 1
tmp_lim:     .space 1
cur_wz:      .space 1
cur_speed:   .space 1
dp_sx:       .space 1
dp_sy:       .space 1

; -- camara (update_camera) ------------------------------------------------
cam_t:       .space 1          ; fase del "8", 0..63
cam_div:     .space 1          ; cuenta fotogramas hasta el siguiente paso de fase
cam_x:       .space 1          ; desplazamiento lateral actual de la camara
cam_y:       .space 1          ; desplazamiento vertical actual de la camara

; -- proj_axis: entrada/salida ------------------------------------------
pa_off:      .space 1
pa_center:   .space 1
pa_limit:    .space 1
pa_sign:     .space 1
pa_mag:      .space 1
pa_ok:       .space 1
pa_result:   .space 1

; -- calc_pix/shadow_set_px ------------------------------------------------
px_x:        .space 1
px_y:        .space 1
pix_lo:      .space 1
pix_hi:      .space 1
pix_mask:    .space 1

; -- arrays de particulas (NPART=26 cada una -- .space no admite constantes,
; ver la misma nota en shamus.asm junto a NCELLS) --------------------------
wx:          .space 26           ; posicion lateral X (mundo, con signo)
wy:          .space 26           ; posicion lateral Y (mundo, con signo)
wz:          .space 26           ; profundidad (mundo, sin signo, 0=encima)
zspeed:      .space 26           ; avance de wz por fotograma (2..5)

h_title:     .asciiz "BIRD FLOCK"

; -- CAM_SINE_X/_Y: seno precalculado en Python (64 muestras, un periodo
; completo), ya escalado a la amplitud de cada eje -- ver update_camera.
; CAM_SINE_X a fase cam_t, CAM_SINE_Y a fase (cam_t*2 mod 64): la MISMA
; forma de onda, pero muestreada al doble de velocidad de fase, es
; exactamente lo que traza el segundo lobulo de una curva de Lissajous 1:2
; (figura en "8") -- no hace falta una segunda forma ni tabla de cosenos.
CAM_SINE_X:                      ; amplitud 40
    .db 0, 4, 8, 12, 15, 19, 22, 25, 28, 31, 33, 35, 37, 38, 39, 40
    .db 40, 40, 39, 38, 37, 35, 33, 31, 28, 25, 22, 19, 15, 12, 8, 4
    .db 0, 252, 248, 244, 241, 237, 234, 231, 228, 225, 223, 221, 219, 218, 217, 216
    .db 216, 216, 217, 218, 219, 221, 223, 225, 228, 231, 234, 237, 241, 244, 248, 252
CAM_SINE_Y:                      ; amplitud 20
    .db 0, 2, 4, 6, 8, 9, 11, 13, 14, 15, 17, 18, 18, 19, 20, 20
    .db 20, 20, 20, 19, 18, 18, 17, 15, 14, 13, 11, 9, 8, 6, 4, 2
    .db 0, 254, 252, 250, 248, 247, 245, 243, 242, 241, 239, 238, 238, 237, 236, 236
    .db 236, 236, 236, 237, 238, 238, 239, 241, 242, 243, 245, 247, 248, 250, 252, 254

shadow:      .space 1024
