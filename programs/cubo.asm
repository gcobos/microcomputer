; ============================================================================
;  cubo.asm  -  cubo de wireframe en 3D girando y rebotando (compi)
;
;  Un cubo (8 vertices, 12 aristas) visto con una inclinacion fija de 28 grados
;  sobre el eje X, girando sin parar sobre el eje Y (proyeccion ortografica --
;  sin perspectiva: no hace falta dividir, solo multiplicar), y con el centro
;  de la esfera moviendose y rebotando en los bordes de la pantalla (estilo
;  "logo de DVD"). Cada fotograma: se mueve el centro, se calcula la posicion
;  en pantalla de los 8 vertices con la rotacion y el centro actuales, y se
;  trazan las 12 aristas con Bresenham.
;
;  Rebote: el cubo mantiene su tamano en pantalla pase lo que pase con el
;  centro (X,Y) -- solo se traslada, no se escala. El margen de rebote usa el
;  extremo ya conocido de cada eje: |Rx| <= 27 en cualquier angulo (ver mas
;  abajo) y |Ty| <= 22 siempre (el eje Y no rota). Eso fija cuanto se puede
;  acercar el centro a cada borde sin que ningun vertice se salga.
;
;  La CPU no tiene MUL ni DIV en hardware, asi que hacen falta dos rutinas
;  propias:
;    - smul64: multiplicacion con signo de 8x8 bits (desplazar-y-sumar) que
;      de paso reescala /64, para deshacer la coma fija del seno/coseno
;      (ver "punto fijo" mas abajo).
;    - line_draw: Bresenham entero de proposito general (con signo via el bit
;      N, sin necesitar comparaciones con signo de rango completo -- los
;      deltas de este cubo son pequenos y no desbordan un byte).
;
;  Punto fijo: la tabla `sine` guarda seno*64 (64 = 2^6, para poder "dividir"
;  con un desplazamiento en vez de con una division de verdad). coseno(a) se
;  saca de la misma tabla con un cuarto de vuelta de desfase: sine[(a+16)&63].
;
;  Geometria: los vertices se guardan ya inclinados 28 grados (calculado una
;  vez, en Python, no en tiempo de ejecucion -- es un giro fijo, no animado).
;  De ahi solo hacen falta Lx y Tz por vertice para la rotacion animada sobre
;  Y (Rx = Lx*cos(a) - Tz*sin(a)); la componente Y de pantalla (`sy`) no rota
;  nunca y esta precalculada.
;
;  Controles en EJECUTAR + CONTINUO:
;     encoder DIRECCION pulsa -> termina (apaga pantalla, HALT)
;
;  Ensamblar y enviar al slot 3:
;     python3 tools/casm.py programs/cubo.asm -o programs/cubo.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 3 programs/cubo.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 3
    .org 0x0000

NVERT = 8
NEDGE = 12
BX_MARGIN = 27   ; |Rx| maximo posible en cualquier angulo (ver rot_x)
BY_MARGIN = 22   ; |Ty| maximo posible (el eje Y no rota, es fijo por vertice)

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000
P_DIR_BTN = 0x0601
P_T3      = 0x0623

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
;
;  El hardware no tiene un segundo framebuffer de verdad (un solo puerto,
;  P_FB, y la OLED lo lee cada FB_FLUSH_MS = 50 ms sin avisar ni esperar).
;  Las dos versiones anteriores tocaban ese unico framebuffer DIRECTAMENTE
;  mientras se iba dibujando (borrar todo + redibujar; luego borrar solo las
;  aristas viejas + dibujar las nuevas), y en ambos casos habia una ventana
;  en la que un pixel pasaba por "apagado" antes de llegar a su valor bueno
;  -- eso es el parpadeo, lo vea o no la OLED en un refresco concreto.
;
;  Aqui se emula un doble buffer con lo que hay: se construye el fotograma
;  ENTERO en una copia en RAM (`shadow`, 1024 bytes) sin tocar el framebuffer
;  real para nada, y al terminar (`blit`) se compara byte a byte contra lo
;  que hay puesto de verdad, escribiendo SOLO los que cambiaron. Cada byte
;  que sí cambia pasa de su valor viejo-correcto al nuevo-correcto en una
;  unica escritura -- nunca pasa por "apagado" a medias. Y los bytes que no
;  cambian (la mayoria, girando solo 2 pasos de 64 por fotograma) ni se
;  tocan, así que tambien hay menos parpadeo por pura cantidad de E/S.
;
;  `shadow` no gasta ni un byte del .bin: al ir al final del todo y ser un
;  `.space` (nunca se le hace un `.db`/`.asciiz` de verdad), casm.py no lo
;  cuenta al recortar el fichero -- ver "Tamano del .bin" en el README.
; ============================================================================
start:
    MOV AL,#0
    STA [angle],AL
    STA [g_exit],AL
    MOV AL,#64
    STA [cen_x],AL             ; el cubo arranca centrado...
    MOV AL,#32
    STA [cen_y],AL
    MOV AL,#2
    STA [vel_x],AL           ; ...y enseguida empieza a moverse
    MOV AL,#1
    STA [vel_y],AL
    CALL clsg                  ; parte en blanco (defensivo; el firmware ya
                                ; limpia el framebuffer real al entrar en
                                ; CONTINUO, pero no cuesta nada asegurarlo)

main_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ main_x

    CALL move_center

    ; avanza el angulo de giro (0..63) y calcula la posicion nueva
    LDA AL,[angle]
    ADD AL,#2
    AND AL,#0x3F
    STA [angle],AL
    CALL compute_vertices

    CALL clr_shadow
    CALL draw_all_edges         ; dibuja en `shadow`, no en el framebuffer real
    CALL blit                   ; copia al framebuffer real solo lo que cambio

    MOV AL,#10              ; pausa entre fotogramas: 10 * 8 ms = 80 ms
    CALL frame_wait
    JMP main_l

main_x:
    CALL clsg
    CALL wait_dir_release
    HALT

; ============================================================================
;  move_center:  mueve (cen_x,cen_y) segun (vel_x,vel_y) y rebota en los bordes
;  (invierte la velocidad y recorta la posicion al margen, para no pasarse)
; ============================================================================
move_center:
    LDA AL,[cen_x]
    LDA BL,[vel_x]
    ADD AL,BL
    STA [cen_x],AL
    CMP AL,#BX_MARGIN
    JMPNC mc_xhi                ; cen_x >= margen bajo -> no ha tocado el borde izquierdo
    MOV AL,#BX_MARGIN
    STA [cen_x],AL
    LDA AL,[vel_x]
    NOT AL
    ADD AL,#1
    STA [vel_x],AL
    JMP mc_y
mc_xhi:
    ; la columna valida mas alta es 127, no 128 -- si no, con cen_x en el
    ; limite y Rx en su maximo (+BX_MARGIN) se pintaria en la columna 128,
    ; que no existe (se desborda a la fila de abajo, o peor).
    CMP AL,#(127-BX_MARGIN)
    JMPC mc_y                   ; cen_x < margen alto -> no ha tocado el borde derecho
    MOV AL,#(127-BX_MARGIN)
    STA [cen_x],AL
    LDA AL,[vel_x]
    NOT AL
    ADD AL,#1
    STA [vel_x],AL
mc_y:
    LDA AL,[cen_y]
    LDA BL,[vel_y]
    ADD AL,BL
    STA [cen_y],AL
    CMP AL,#BY_MARGIN
    JMPNC mc_yhi
    MOV AL,#BY_MARGIN
    STA [cen_y],AL
    LDA AL,[vel_y]
    NOT AL
    ADD AL,#1
    STA [vel_y],AL
    RET
mc_yhi:
    ; la fila valida mas alta es 63, no 64 -- mismo motivo que en X: con
    ; cen_y=64-BY_MARGIN y Ty en +BY_MARGIN, sy_cur daba 64 (fila inexistente,
    ; que via calc_pix cae en la pagina 4 -- fuera del framebuffer grafico,
    ; dentro de la capa de texto 0x0400+). Se vio con el simulador: faltaban
    ; pixeles enteros de dos aristas justo al llegar a ese borde.
    CMP AL,#(63-BY_MARGIN)
    JMPC mc_done
    MOV AL,#(63-BY_MARGIN)
    STA [cen_y],AL
    LDA AL,[vel_y]
    NOT AL
    ADD AL,#1
    STA [vel_y],AL
mc_done:
    RET

; ============================================================================
;  compute_vertices:  rellena sx_cur[0..7]/sy_cur[0..7] con el angulo y el
;  centro (cen_x,cen_y) actuales
; ============================================================================
compute_vertices:
    MOV AL,#0
    STA [vi],AL
cv_l:
    CALL rot_x
    LDA AL,[vi]
    ADD AL,#1
    STA [vi],AL
    CMP AL,#NVERT
    JMPNZ cv_l
    RET

; ============================================================================
;  draw_all_edges:  traza (en `shadow`, via shadow_set_px) las 12 aristas de
;  sx_cur/sy_cur
; ============================================================================
draw_all_edges:
    MOV AL,#0
    STA [ei],AL
dae_l:
    LDA CL,[ei]
    MOV BL,#lo(edge_a)
    MOV BH,#hi(edge_a)
    CALL idx_ptr
    LDA AL,[BX]
    STA [v0],AL

    LDA CL,[ei]
    MOV BL,#lo(edge_b)
    MOV BH,#hi(edge_b)
    CALL idx_ptr
    LDA AL,[BX]
    STA [v1],AL

    LDA CL,[v0]
    MOV BL,#lo(sx_cur)
    MOV BH,#hi(sx_cur)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ln_x0],AL

    LDA CL,[v0]
    MOV BL,#lo(sy_cur)
    MOV BH,#hi(sy_cur)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ln_y0],AL

    LDA CL,[v1]
    MOV BL,#lo(sx_cur)
    MOV BH,#hi(sx_cur)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ln_x1],AL

    LDA CL,[v1]
    MOV BL,#lo(sy_cur)
    MOV BH,#hi(sy_cur)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ln_y1],AL

    CALL line_draw

    LDA AL,[ei]
    ADD AL,#1
    STA [ei],AL
    CMP AL,#NEDGE
    JMPNZ dae_l
    RET

; ============================================================================
;  rot_x:  calcula sx_cur[vi] = Lx[vi]*cos(angulo) - Tz[vi]*sin(angulo) + cen_x,
;  y de paso sy_cur[vi] = sy_rel[vi] + cen_y (el eje Y no rota, solo se traslada)
; ============================================================================
rot_x:
    LDA CL,[vi]
    MOV BL,#lo(Lx)
    MOV BH,#hi(Lx)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[angle]
    ADD AL,#16
    AND AL,#0x3F
    STA [tmp_idx],AL
    LDA CL,[tmp_idx]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL

    CALL smul64
    STA [rx_t1],AL

    LDA CL,[vi]
    MOV BL,#lo(Tz)
    MOV BH,#hi(Tz)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA CL,[angle]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL

    CALL smul64
    STA [rx_t2],AL

    LDA AL,[rx_t1]
    LDA BL,[rx_t2]
    SUB AL,BL
    LDA BL,[cen_x]
    ADD AL,BL

    LDA CL,[vi]
    MOV BL,#lo(sx_cur)
    MOV BH,#hi(sx_cur)
    CALL idx_ptr
    STA [BX],AL

    ; sy_cur[vi] = sy_rel[vi] + cen_y
    LDA CL,[vi]
    MOV BL,#lo(sy_rel)
    MOV BH,#hi(sy_rel)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cen_y]
    ADD AL,BL

    LDA CL,[vi]
    MOV BL,#lo(sy_cur)
    MOV BH,#hi(sy_cur)
    CALL idx_ptr
    STA [BX],AL
    RET

; ============================================================================
;  smul64:  sm_a (con signo) * sm_b (con signo) / 64, redondeado hacia 0
;  entra: [sm_a],[sm_b]      sale: AL = resultado con signo
; ============================================================================
smul64:
    MOV AL,#0
    STA [sm_neg],AL

    LDA AL,[sm_a]
    AND AL,#0x80
    JMPZ sm_apos
    LDA AL,[sm_a]
    NOT AL
    ADD AL,#1
    STA [sm_a],AL
    LDA AL,[sm_neg]
    XOR AL,#1
    STA [sm_neg],AL
sm_apos:
    LDA AL,[sm_b]
    AND AL,#0x80
    JMPZ sm_bpos
    LDA AL,[sm_b]
    NOT AL
    ADD AL,#1
    STA [sm_b],AL
    LDA AL,[sm_neg]
    XOR AL,#1
    STA [sm_neg],AL
sm_bpos:
    MOV AL,#0
    STA [sm_hi],AL
    STA [sm_lo],AL
    LDA AL,[sm_a]
    STA [sm_m_lo],AL
    MOV AL,#0
    STA [sm_m_hi],AL
    MOV AL,#8
    STA [sm_cnt],AL
sm_loop:
    LDA AL,[sm_b]
    AND AL,#1
    JMPZ sm_noadd
    LDA AL,[sm_lo]
    LDA BL,[sm_m_lo]
    ADD AL,BL
    STA [sm_lo],AL
    LDA AL,[sm_hi]
    LDA BL,[sm_m_hi]
    JMPNC sm_addhi
    ADD AL,#1
sm_addhi:
    ADD AL,BL
    STA [sm_hi],AL
sm_noadd:
    LDA AL,[sm_m_lo]
    SHL AL
    STA [sm_m_lo],AL
    JMPNC sm_mnocarry
    MOV AL,#1
    STA [sm_carry],AL
    JMP sm_mcarrydone
sm_mnocarry:
    MOV AL,#0
    STA [sm_carry],AL
sm_mcarrydone:
    LDA AL,[sm_m_hi]
    SHL AL
    LDA BL,[sm_carry]
    OR AL,BL
    STA [sm_m_hi],AL

    LDA AL,[sm_b]
    SHR AL
    STA [sm_b],AL

    LDA AL,[sm_cnt]
    SUB AL,#1
    STA [sm_cnt],AL
    JMPNZ sm_loop

    MOV AL,#6
    STA [sm_cnt],AL
sm_shr_loop:
    LDA AL,[sm_hi]
    SHR AL
    STA [sm_hi],AL
    JMPNC sm_shr_nocarry
    MOV AL,#0x80
    STA [sm_carry],AL
    JMP sm_shr_carrydone
sm_shr_nocarry:
    MOV AL,#0
    STA [sm_carry],AL
sm_shr_carrydone:
    LDA AL,[sm_lo]
    SHR AL
    LDA BL,[sm_carry]
    OR AL,BL
    STA [sm_lo],AL

    LDA AL,[sm_cnt]
    SUB AL,#1
    STA [sm_cnt],AL
    JMPNZ sm_shr_loop

    LDA AL,[sm_neg]
    CMP AL,#0
    JMPZ sm_done
    LDA AL,[sm_lo]
    NOT AL
    ADD AL,#1
    STA [sm_lo],AL
sm_done:
    LDA AL,[sm_lo]
    RET

; ============================================================================
;  line_draw:  Bresenham entero (con signo via el bit N), pinta con shadow_set_px
;  entra: ln_x0,ln_y0,ln_x1,ln_y1 (coordenadas de pantalla, sin signo 0..127/63)
; ============================================================================
line_draw:
    LDA AL,[ln_x1]
    LDA BL,[ln_x0]
    CMP AL,BL
    JMPC ldx_neg
    SUB AL,BL
    STA [ln_dx],AL
    MOV AL,#1
    STA [ln_sx],AL
    JMP ldx_done
ldx_neg:
    MOV AL,BL
    LDA BL,[ln_x1]
    SUB AL,BL
    STA [ln_dx],AL
    MOV AL,#0xFF
    STA [ln_sx],AL
ldx_done:
    LDA AL,[ln_y1]
    LDA BL,[ln_y0]
    CMP AL,BL
    JMPC ldy_neg
    SUB AL,BL
    STA [ln_dy],AL
    MOV AL,#1
    STA [ln_sy],AL
    JMP ldy_done
ldy_neg:
    MOV AL,BL
    LDA BL,[ln_y1]
    SUB AL,BL
    STA [ln_dy],AL
    MOV AL,#0xFF
    STA [ln_sy],AL
ldy_done:
    LDA AL,[ln_dx]
    LDA BL,[ln_dy]
    CMP AL,BL
    JMPC ln_ymajor_init
    LDA AL,[ln_dx]
    STA [ln_n],AL
    SHR AL
    STA [ln_err],AL
    MOV AL,#1
    STA [ln_xmaj],AL
    JMP ln_loop
ln_ymajor_init:
    LDA AL,[ln_dy]
    STA [ln_n],AL
    SHR AL
    STA [ln_err],AL
    MOV AL,#0
    STA [ln_xmaj],AL
ln_loop:
    LDA AL,[ln_x0]
    STA [px_x],AL
    LDA AL,[ln_y0]
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[ln_n]
    CMP AL,#0
    JMPZ ln_done
    SUB AL,#1
    STA [ln_n],AL

    LDA AL,[ln_xmaj]
    CMP AL,#0
    JMPZ ln_do_ymajor

    LDA AL,[ln_err]
    LDA BL,[ln_dy]
    SUB AL,BL
    STA [ln_err],AL
    JMPN ln_xmaj_neg
    JMP ln_xmaj_stepx
ln_xmaj_neg:
    LDA AL,[ln_y0]
    LDA BL,[ln_sy]
    ADD AL,BL
    STA [ln_y0],AL
    LDA AL,[ln_err]
    LDA BL,[ln_dx]
    ADD AL,BL
    STA [ln_err],AL
ln_xmaj_stepx:
    LDA AL,[ln_x0]
    LDA BL,[ln_sx]
    ADD AL,BL
    STA [ln_x0],AL
    JMP ln_loop

ln_do_ymajor:
    LDA AL,[ln_err]
    LDA BL,[ln_dx]
    SUB AL,BL
    STA [ln_err],AL
    JMPN ln_ymaj_neg
    JMP ln_ymaj_stepy
ln_ymaj_neg:
    LDA AL,[ln_x0]
    LDA BL,[ln_sx]
    ADD AL,BL
    STA [ln_x0],AL
    LDA AL,[ln_err]
    LDA BL,[ln_dy]
    ADD AL,BL
    STA [ln_err],AL
ln_ymaj_stepy:
    LDA AL,[ln_y0]
    LDA BL,[ln_sy]
    ADD AL,BL
    STA [ln_y0],AL
    JMP ln_loop
ln_done:
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- idx_ptr:  BX = (BL/BH iniciales) + CL, propagando el acarreo a mano ---
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- shadow_set_px:  enciende el pixel (px_x,px_y) en `shadow` (RAM), no en
; el framebuffer real -- eso lo hace `blit` al terminar el fotograma.
shadow_set_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr            ; BX = shadow + pix_lo, con acarreo a BH
    LDA AL,[pix_hi]
    ADD BH,AL                ; BX += pix_hi * 256 (la pagina dentro de shadow)
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
; ojo: NO se puede copiar el truco de clsg de contar "4 paginas" mirando BH
; -- eso solo funciona porque el framebuffer real empieza justo en un limite
; de pagina (puerto 0x0000). `shadow` cae en mitad de una pagina (su byte
; bajo no es 0), asi que contar vueltas de BH cuenta una primera "pagina"
; mas corta que las demas y el bucle para 192 bytes antes de tiempo. En su
; lugar se cuenta con un contador de 16 bits explicito (CH:CL, de 1024 a 0),
; que no depende de en que direccion caiga `shadow`.
clr_shadow:
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    MOV AL,#0
    MOV CL,#0
    MOV CH,#4            ; CH:CL = 1024
csh_l:
    STA [BX],AL
    ADD BL,#1
    JMPNC csh_addr_ok
    ADD BH,#1
csh_addr_ok:
    SUB CL,#1
    JMPNC csh_cnt_ok
    SUB CH,#1
csh_cnt_ok:
    MOV DL,CH
    OR  DL,CL
    JMPNZ csh_l
    RET

; --- blit:  copia `shadow` al framebuffer real, solo lo que haya cambiado -
blit:
    MOV BL,#0
    MOV BH,#0
    MOV DL,#lo(shadow)
    MOV DH,#hi(shadow)
bl_l:
    IN  AL,(BX)
    LDA CL,[DX]
    CMP AL,CL
    JMPZ bl_same
    MOV AL,CL
    OUT (BX),AL
bl_same:
    ADD DL,#1
    JMPNC bl_dnc
    ADD DH,#1
bl_dnc:
    ADD BL,#1
    JMPNC bl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ bl_l
    RET

; --- calc_pix:  de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4
    MOV DL,CL
    SHR DL,#3
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL,#4
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

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) ----------------
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
;  DATOS  (justo despues del codigo -- ver programs/README.md, "Tamano del
;  .bin"). Los vertices ya vienen inclinados 28 grados sobre X (calculado una
;  vez con Python, no en tiempo de ejecucion): Lx y Tz alimentan la rotacion
;  animada sobre Y en cada fotograma; sy es la Y de pantalla, fija.
; ============================================================================
angle:    .space 1    ; 0..63, un giro completo son 64 pasos
cen_x:       .space 1    ; centro de la esfera en pantalla (rebota, ver move_center)
cen_y:       .space 1
vel_x:    .space 1    ; velocidad del centro, con signo (0x01=+1, 0xFF=-1, etc.)
vel_y:    .space 1
vi:       .space 1    ; indice de vertice en curso (0..7)
ei:       .space 1    ; indice de arista en curso (0..11)
v0:       .space 1
v1:       .space 1
tmp_idx:  .space 1
rx_t1:    .space 1
rx_t2:    .space 1
g_exit:   .space 1

sm_a:      .space 1
sm_b:      .space 1
sm_neg:    .space 1
sm_hi:     .space 1
sm_lo:     .space 1
sm_m_lo:   .space 1
sm_m_hi:   .space 1
sm_carry:  .space 1
sm_cnt:    .space 1

ln_x0:    .space 1
ln_y0:    .space 1
ln_x1:    .space 1
ln_y1:    .space 1
ln_dx:    .space 1
ln_dy:    .space 1
ln_sx:    .space 1
ln_sy:    .space 1
ln_err:   .space 1
ln_n:     .space 1
ln_xmaj:  .space 1

px_x:     .space 1
px_y:     .space 1
pix_lo:   .space 1
pix_hi:   .space 1
pix_mask: .space 1

sx_cur:   .space 8    ; posicion en pantalla (x) de cada vertice, este fotograma
sy_cur:   .space 8    ; posicion en pantalla (y) de cada vertice, este fotograma

; Lx, Tz: coordenadas base (con signo) tras la inclinacion fija de 28 grados
Lx:  .db 240, 240, 240, 240, 16, 16, 16, 16
Tz:  .db 234, 7, 249, 22, 234, 7, 249, 22

; sy_rel: Ty (con signo, sin el +32 del centro fijo de antes -- ahora el
; centro es movil, se suma en rot_x). Valores: -7,-22,22,7 repetidos.
sy_rel: .db 249, 234, 22, 7, 249, 234, 22, 7

; aristas del cubo: pares de indices de vertice (0..7)
edge_a: .db 0, 2, 4, 6, 0, 1, 2, 3, 0, 1, 4, 5
edge_b: .db 1, 3, 5, 7, 4, 5, 6, 7, 2, 3, 6, 7

; seno*64 con signo, 64 pasos (indice de coseno = (indice+16) & 63)
sine: .db 0, 6, 12, 19, 24, 30, 36, 41, 45, 49, 53, 56, 59, 61, 63, 64
      .db 64, 64, 63, 61, 59, 56, 53, 49, 45, 41, 36, 30, 24, 19, 12, 6
      .db 0, 250, 244, 237, 232, 226, 220, 215, 211, 207, 203, 200, 197, 195, 193, 192
      .db 192, 192, 193, 195, 197, 200, 203, 207, 211, 215, 220, 226, 232, 237, 244, 250

; shadow: copia del framebuffer en RAM ("doble buffer" software, ver main_l).
; TIENE que ir la ultima de todo el fichero: al ser un .space sin datos reales
; nunca se le hace un .db/.asciiz, no cuenta para el recorte del .bin (ver
; "Tamano del .bin" en programs/README.md) -- solo cuesta bytes si algo con
; datos de verdad va DESPUES de ella en el fichero.
shadow: .space 1024
