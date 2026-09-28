; ============================================================================
;  cubo.asm  -  cubo de wireframe en 3D, o toro con sombreado, a eleccion
;  (compi)
;
;  Dos figuras en el mismo programa, alternables en caliente con el pulsador
;  de DATOS (ver poll_toggle) sin perder ninguna de las dos a medio girar:
;
;  CUBO (modo 0, el de siempre): 8 vertices, 12 aristas, inclinado 28 grados
;  sobre el eje X, girando sin parar sobre el eje Y (proyeccion ortografica --
;  sin perspectiva: no hace falta dividir, solo multiplicar), con el centro
;  moviendose y rebotando en los bordes de la pantalla (estilo "logo de DVD").
;  Cada fotograma: se mueve el centro, se calcula la posicion en pantalla de
;  los 8 vertices con la rotacion y el centro actuales, y se trazan las 12
;  aristas con Bresenham.
;
;  Rebote del cubo: el margen usa el extremo ya conocido de cada eje sin
;  escalar: |Rx| <= 27 en cualquier angulo (ver mas abajo) y |Ty| <= 22
;  siempre (el eje Y no rota). Eso fija cuanto se puede acercar el centro a
;  cada borde sin que ningun vertice se salga -- pero ESE limite tambien
;  tiene que escalar con [scale] (ver mas abajo), o un cubo agrandado se
;  saldria de pantalla antes de que move_center creyera que toco el borde:
;  compute_margins recalcula el margen efectivo cada fotograma.
;
;  TORO (modo 1): un donut SOLIDO, no de alambre -- 20 "costillas" (un trozo
;  de tubo cada una), cada una un disco de radio DISK_R=6 (a escala normal;
;  ver mas abajo) relleno con una trama segun lo de cara que este a la
;  pantalla. Gira sin parar sobre Y con la misma formula que el cubo
;  (Rx = Lx*cos(a) - Tz*sin(a)), reutilizando smul64 y la tabla `sine` tal
;  cual. Rebota en los bordes de la pantalla igual que el cubo (ver
;  toro_cx/toro_cy, move_toro_center/compute_toro_margins), con su propia
;  velocidad independiente para que no se mueva identico al alternar con
;  DATOS (poll_toggle).
;
;  Pintor de atras hacia adelante (main.cpp NO tiene z-buffer, y a 128x64x1
;  bit tampoco compensa montar uno): cada fotograma, torus_compute calcula
;  la posicion en pantalla Y la profundidad ya rotada (rzu_arr) de las 20
;  costillas; sort_spokes las ordena de mas lejos a mas cerca (order[], un
;  insertion sort de 20 elementos); draw_torus las dibuja en ESE orden. Como
;  draw_disk pinta con shadow_put_px (que SOBREESCRIBE, no solo enciende
;  como shadow_set_px), un disco mas cercano tapa del todo a uno mas lejano
;  donde se solapen -- oclusion correcta sin calcular ninguna interseccion,
;  solo por el orden de dibujado. Los discos (radio 6, costillas cada ~5-6
;  pixeles de arco a lo largo del anillo mayor) se solapan de sobra entre
;  si: por eso el resultado se ve como una superficie continua y no como 20
;  manchas sueltas.
;
;  Sombreado y "textura cambiante": la profundidad rotada de cada costilla
;  (rzu_arr, pidiendo la otra componente de la misma rotacion: Rz = Lx*sin(a)
;  + Tz*cos(a) en vez de Rx) se cuantiza a 4 niveles, 1..4 (level_from_rz --
;  a proposito SIN nivel 0, ver la nota de esa rutina: una trama del todo
;  vacia es indistinguible del fondo negro, y la mitad de atras del toro
;  parecia que faltaba en vez de estar ahi pero de espaldas). Cada disco se
;  rellena pixel a pixel con dither_on, que compara ese nivel contra una
;  matriz de Bayer 2x2 (BAYER2): nivel 1 enciende solo 1 de cada 4 pixeles
;  (la costilla mas de espaldas, floja pero visible), nivel 4 los enciende
;  los 4 (de cara del todo), y 2-3 quedan de por medio. El indice de Bayer
;  sale de la posicion en PANTALLA (bits bajos de x e y), no de la posicion
;  dentro del disco, para
;  que la trama de discos solapados case entre si en vez de verse cada uno
;  con su propio patron descuadrado.
;
;  La CPU no tiene MUL ni DIV en hardware, asi que hacen falta dos rutinas
;  propias:
;    - smul64: multiplicacion con signo de 8x8 bits (desplazar-y-sumar) que
;      de paso reescala /64, para deshacer la coma fija del seno/coseno
;      (ver "punto fijo" mas abajo).
;    - line_draw: Bresenham entero de proposito general (con signo via el bit
;      N, sin necesitar comparaciones con signo de rango completo -- los
;      deltas de este cubo son pequenos y no desbordan un byte). Solo la usa
;      el cubo: el toro rellena discos, no traza aristas.
;
;  Punto fijo: la tabla `sine` guarda seno*64 (64 = 2^6, para poder "dividir"
;  con un desplazamiento en vez de con una division de verdad). coseno(a) se
;  saca de la misma tabla con un cuarto de vuelta de desfase: sine[(a+16)&63].
;
;  Geometria: los vertices/ejes se guardan ya inclinados (calculado una vez,
;  en Python, no en tiempo de ejecucion -- es un giro fijo, no animado). De
;  ahi solo hacen falta Lx y Tz por vertice/costilla para la rotacion animada
;  sobre Y (Rx = Lx*cos(a) - Tz*sin(a)); la componente Y de pantalla (`sy`)
;  no rota nunca y esta precalculada.
;
;  Tamano ajustable con DATOS: [scale] (poll_scale, 64 = tamano normal, mismo
;  punto fijo que el seno/coseno) se aplica DESPUES de rotar, con una
;  multiplicacion mas de smul64 sobre el desplazamiento ya rotado -- ni Lx/Tz
;  ni LxU/TzU/SyU hacen falta reescalarlos aparte. Comparten [scale] los dos
;  modos (no se reinicia al alternar con el pulsador). El toro SI escala su
;  radio de tubo ([eff_disk_r] = DISK_R*escala/64, recalculado una vez por
;  fotograma en draw_torus): como DISK_R ya no es un literal de compilacion
;  sino un radio que cambia, HW2D/HW_ROW_OFF reemplazan a la HW de un solo
;  radio de antes -- ver su nota junto a la tabla. Rango: SCALE_MIN..
;  SCALE_MAX, elegido para que ni el cubo (con el margen de rebote ya
;  escalado, ver compute_margins) ni el toro (con TORO_MARGIN, que YA
;  incluye el radio del disco -- ver su nota) se salgan nunca de pantalla.
;
;  Controles en EJECUTAR + CONTINUO:
;     encoder DIRECCION pulsa -> termina (apaga pantalla y vuelve al slot 0)
;     encoder DIRECCION gira   -> inclina el modelo sobre el eje X ([xangle],
;                                compute_x_tilt/compute_x_tilt_torus)
;     encoder DATOS     pulsa -> alterna cubo <-> toro (poll_toggle, por
;                                flanco: una pulsacion, un cambio)
;     encoder DATOS     gira   -> cambia el tamano (poll_scale)
;
;  Inclinacion en X ([xangle], 0..63, ver "punto fijo" mas abajo): antes el
;  cubo/toro tenian una inclinacion FIJA de 28 grados sobre X, calculada una
;  vez en Python y horneada directamente en las tablas Tz/sy_rel (cubo) y
;  TzU/SyU (toro) -- nunca cambiaba. Ahora esas tablas guardan la geometria
;  SIN inclinar (Y0/Z0 y Y0U/Z0U: un cubo recto de +-16 en los 3 ejes, y el
;  anillo del toro sin tilt), y compute_x_tilt/compute_x_tilt_torus recalculan
;  cada fotograma, con la MISMA formula de rotacion que ya usaba rot_x para
;  el eje Y (Rx = Lx*cos-Tz*sin), pero sobre el eje X y con [xangle] en vez
;  de un 28 grados fijo:
;     tyx = Y0*cos(xangle) - Z0*sin(xangle)   (nueva altura en pantalla)
;     tzx = Y0*sin(xangle) + Z0*cos(xangle)   (nueva "profundidad" pre-giro Y)
;  tyx sustituye a la sy_rel estatica; tzx sustituye a la Tz estatica y sigue
;  alimentando igual que antes la rotacion animada sobre Y ([angle]). Girar
;  DIRECCION hasta el indice mas cercano a 28 grados (indice ~5 de 64)
;  reproduce el aspecto de siempre; el resto del rango son grados de
;  libertad nuevos. [xangle] sale de la posicion cruda de DIRECCION
;  enmascarada a 6 bits (AND #0x3F): a diferencia del "mod 20" de
;  roto_debug.asm, aqui 256 SI es multiplo de 64 (256/64=4 exacto), asi que
;  no hace falta ningun truco de posicion virtual -- la mascara ya envuelve
;  sin salto alguno.
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
; BX_MARGIN/BY_MARGIN: |Rx|/|Ty| maximos posibles en CUALQUIER combinacion de
; [angle] (giro automatico en Y) y [xangle] (inclinacion en X, DIRECCION) --
; medido por fuerza bruta sobre las 64x64 combinaciones posibles (ver el
; historial de esta sesion), no solo estimado a ojo: desde que la
; inclinacion en X paso de fija (28 grados) a variable, Ty/Tz ya no estan
; acotados por el caso concreto de 28 grados (|Ty|<=22 antes), sino por el
; radio de cada vertice sin inclinar (Y0/Z0), que puede llegar a 23-24 segun
; el angulo. OJO: si algun dia cambian Y0/Z0/Lx/Tz hay que recalcular esto
; (o el cubo se sale de pantalla justo al rebotar, con lineas deformadas --
; el bug que motivo subir estos dos valores de 27/22 a 28/23).
BX_MARGIN = 28
BY_MARGIN = 23

NSPOKE = 20      ; costillas del toro (pasos alrededor del eje mayor)
DISK_R = 6       ; radio NOMINAL (a escala 64=normal) del "trozo de tubo" que
                 ; dibuja cada costilla -- SI escala con [scale] igual que la
                 ; posicion (ver eff_disk_r/HW2D mas abajo): a cada fotograma
                 ; se recalcula el radio real y se rellena con la fila de
                 ; HW2D que le toca, en vez de una tabla fija de un solo
                 ; radio (ver draw_disk).
TORO_MAX_DISK_R = 8  ; radio mayor que soporta la tabla HW2D (techo de
                 ; seguridad: a SCALE_MAX=84 el radio real llega a 7)
TORO_CX_DEFAULT = 64 ; posicion inicial del toro (rebota desde aqui, ver
TORO_CY_DEFAULT = 32 ; toro_cx/toro_cy y move_toro_center)
; TORO_MARGIN: cuanto puede acercarse toro_cx/cy a un borde antes de rebotar
; a escala 64 (normal) -- ver compute_toro_margins, que lo escala con
; [scale] igual que BX_MARGIN/BY_MARGIN del cubo. Es la suma de dos cosas
; independientes: 18 (TORO_RING_MARGIN, el maximo desplazamiento posible de
; CUALQUIER costilla respecto al centro del toro, en cualquier angulo de
; giro Y o inclinacion X -- medido por fuerza bruta sobre las 64x64
; combinaciones, ver el historial de esta sesion) mas DISK_R (6, el propio
; radio del disco que dibuja cada costilla, que se suma sin mas porque
; ambos terminos escalan igual con [scale]).
TORO_RING_MARGIN = 18
TORO_MARGIN = (TORO_RING_MARGIN + DISK_R)

; SCALE_*: rango de [scale] (64 = tamano normal, ver "punto fijo" de la
; cabecera). Los limites estan elegidos para que, en todo el rango, ni el
; cubo (rebotando, margen BX_MARGIN/BY_MARGIN escalado) ni el toro (fijo en
; el centro, SyU escalado) se salgan de la pantalla en ningun angulo:
;   - SCALE_MAX=84: BY_MARGIN*84/64 ~ 30, deja hueco de rebote vertical
;     (cen_y en [30,33]); muy por debajo del limite de signo de
;     smul64 (128) que haria que [scale] se leyera como negativo.
;   - SCALE_MIN=24: bastante mas pequeno sin llegar a un punto sin tamano.
SCALE_DEFAULT = 64
SCALE_MIN = 24
SCALE_MAX = 84

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000
P_DIR_BTN = 0x0601
P_DIR_POS = 0x0600
P_DAT_BTN = 0x0603
P_DAT_POS = 0x0602
P_PROG_LOAD = 0x0640     ; cargar slot (OUT nº de slot): salto a otro programa
P_T3      = 0x0623

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
;
;  El hardware no tiene un segundo framebuffer de verdad (un solo puerto,
;  P_FB, y la OLED lo lee cada FB_FLUSH_MS = 50 ms sin avisar ni esperar).
;  Dibujar directamente sobre ese unico framebuffer (borrar y redibujar cada
;  arista) deja una ventana en la que un pixel pasa por "apagado" antes de
;  llegar a su valor bueno -- eso es el parpadeo, lo vea o no la OLED en un
;  refresco concreto.
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
    STA [mode],AL               ; arranca en cubo (0)
    STA [dat_btn_prev],AL
    MOV AL,#SCALE_DEFAULT
    STA [scale],AL               ; tamano normal al arrancar
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL        ; lo que marque DATOS ya de entrada, no 0 --
                                  ; si no, el primer poll_scale podria leer un
                                  ; salto grande de golpe si el encoder no
                                  ; estaba a 0
    MOV AL,#64
    STA [cen_x],AL             ; el cubo arranca centrado...
    MOV AL,#32
    STA [cen_y],AL
    MOV AL,#2
    STA [vel_x],AL           ; ...y enseguida empieza a moverse
    MOV AL,#1
    STA [vel_y],AL

    MOV AL,#TORO_CX_DEFAULT
    STA [toro_cx],AL           ; el toro tambien arranca centrado y rebota,
    MOV AL,#TORO_CY_DEFAULT    ; con su propia velocidad -- independiente de
    STA [toro_cy],AL           ; la del cubo, para que no se muevan identicos
    MOV AL,#0xFF               ; al alternar con DATOS (ver poll_toggle)
    STA [toro_vel_x],AL        ; -1
    MOV AL,#1
    STA [toro_vel_y],AL        ; +1

    CALL clsg                  ; parte en blanco (defensivo; el firmware ya
                                ; limpia el framebuffer real al entrar en
                                ; CONTINUO, pero no cuesta nada asegurarlo)

main_l:
    CALL poll_exit
    LDA AL,[g_exit]
    CMP AL,#0
    JMPNZ main_x

    CALL poll_toggle            ; DATOS por flanco -> alterna [mode]
    CALL poll_scale             ; DATOS al girar -> [scale] (los dos modos)

    ; avanza el angulo de giro (0..63); lo usan los dos modos por igual
    LDA AL,[angle]
    ADD AL,#2
    AND AL,#0x3F
    STA [angle],AL

    ; inclinacion sobre X: directa de la posicion de DIRECCION, sin flanco ni
    ; delta -- ver la nota de cabecera sobre por que la mascara de 6 bits no
    ; da ningun salto (256 SI es multiplo de 64, a diferencia del mod 20 de
    ; roto_debug.asm)
    IN  AL,(P_DIR_POS)
    AND AL,#0x3F
    STA [xangle],AL

    CALL clr_shadow

    LDA AL,[mode]
    CMP AL,#0
    JMPNZ main_toro

    CALL compute_margins        ; BX_MARGIN/BY_MARGIN escalados (solo cubo:
                                 ; el toro no rebota, no le hacen falta)
    CALL move_center
    CALL compute_vertices
    CALL draw_all_edges         ; dibuja en `shadow`, no en el framebuffer real
    JMP main_blit

main_toro:
    CALL compute_toro_margins   ; TORO_MARGIN escalado (equivalente a
                                 ; compute_margins, pero para el toro)
    CALL move_toro_center       ; rebota toro_cx/toro_cy, igual que move_center
    CALL draw_torus             ; tambien dibuja en `shadow`

main_blit:
    CALL blit                   ; copia al framebuffer real solo lo que cambio

    MOV AL,#10              ; pausa entre fotogramas: 10 * 8 ms = 80 ms
    CALL frame_wait
    JMP main_l

main_x:
    CALL clsg
    CALL wait_dir_release
    MOV AL,#0
    OUT (P_PROG_LOAD),AL       ; vuelve al sistema (sisop, slot 0)
    HALT                       ; solo si el slot 0 estuviera vacio (la carga no hace nada)

; ============================================================================
;  compute_margins:  eff_bx_margin/eff_by_margin = BX_MARGIN/BY_MARGIN
;  escalados por [scale] (y sus complementos a 127/63) -- move_center los usa
;  en vez de las constantes de compilacion, para que el margen de rebote
;  siga cubriendo justo |Rx|/|Ty| del cubo YA ESCALADO (rot_x aplica la misma
;  escala a los vertices). Sin esto, un cubo agrandado con DATOS se saldria
;  de pantalla antes de que move_center creyera que toco el borde.
; ============================================================================
compute_margins:
    MOV AL,#BX_MARGIN
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    STA [eff_bx_margin],AL
    MOV BL,#127
    SUB BL,AL
    STA [eff_bx_hi],BL

    MOV AL,#BY_MARGIN
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    STA [eff_by_margin],AL
    MOV BL,#63
    SUB BL,AL
    STA [eff_by_hi],BL
    RET

; ============================================================================
;  move_center:  mueve (cen_x,cen_y) segun (vel_x,vel_y) y rebota en los bordes
;  (invierte la velocidad y recorta la posicion al margen, para no pasarse) --
;  margenes en eff_bx_margin/eff_bx_hi/eff_by_margin/eff_by_hi (compute_margins),
;  no en las constantes BX_MARGIN/BY_MARGIN a secas: tienen que seguir a
;  [scale] para que el recorte sea el correcto al tamano actual.
; ============================================================================
move_center:
    LDA AL,[cen_x]
    LDA BL,[vel_x]
    ADD AL,BL
    STA [cen_x],AL
    LDA BL,[eff_bx_margin]
    CMP AL,BL
    JMPNC mc_xhi                ; cen_x >= margen bajo -> no ha tocado el borde izquierdo
    LDA AL,[eff_bx_margin]
    STA [cen_x],AL
    LDA AL,[vel_x]
    NOT AL
    ADD AL,#1
    STA [vel_x],AL
    JMP mc_y
mc_xhi:
    ; la columna valida mas alta es 127, no 128 -- si no, con cen_x en el
    ; limite y Rx en su maximo (+eff_bx_margin) se pintaria en la columna
    ; 128, que no existe (se desborda a la fila de abajo, o peor).
    LDA BL,[eff_bx_hi]
    CMP AL,BL
    JMPC mc_y                   ; cen_x < margen alto -> no ha tocado el borde derecho
    LDA AL,[eff_bx_hi]
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
    LDA BL,[eff_by_margin]
    CMP AL,BL
    JMPNC mc_yhi
    LDA AL,[eff_by_margin]
    STA [cen_y],AL
    LDA AL,[vel_y]
    NOT AL
    ADD AL,#1
    STA [vel_y],AL
    RET
mc_yhi:
    ; la fila valida mas alta es 63, no 64 -- mismo motivo que en X: con
    ; cen_y=64-eff_by_margin y Ty en +eff_by_margin, sy_cur daba 64 (fila
    ; inexistente, que via calc_pix cae en la pagina 4 -- fuera del
    ; framebuffer grafico, dentro de la capa de texto 0x0400+). Se vio con
    ; el simulador: faltaban pixeles enteros de dos aristas justo al llegar
    ; a ese borde.
    LDA BL,[eff_by_hi]
    CMP AL,BL
    JMPC mc_done
    LDA AL,[eff_by_hi]
    STA [cen_y],AL
    LDA AL,[vel_y]
    NOT AL
    ADD AL,#1
    STA [vel_y],AL
mc_done:
    RET

; ============================================================================
;  compute_toro_margins: igual que compute_margins, pero para el toro (que
;  ahora SI rebota, ver move_toro_center) -- un solo margen (TORO_MARGIN)
;  escalado sirve para los dos ejes, a diferencia del cubo (BX_MARGIN/
;  BY_MARGIN distintos porque su geometria no es simetrica): la "sombra" del
;  toro es igual de ancha en X que en Y en cualquier angulo -- ver la nota
;  de TORO_MARGIN mas arriba.
; ============================================================================
compute_toro_margins:
    MOV AL,#TORO_MARGIN
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    STA [eff_toro_margin],AL
    MOV BL,#127
    SUB BL,AL
    STA [eff_toro_hi_x],BL
    LDA AL,[eff_toro_margin]
    MOV BL,#63
    SUB BL,AL
    STA [eff_toro_hi_y],BL
    RET

; ============================================================================
;  move_toro_center: igual que move_center, pero para (toro_cx,toro_cy)/
;  (toro_vel_x,toro_vel_y), con los margenes de compute_toro_margins.
; ============================================================================
move_toro_center:
    LDA AL,[toro_cx]
    LDA BL,[toro_vel_x]
    ADD AL,BL
    STA [toro_cx],AL
    LDA BL,[eff_toro_margin]
    CMP AL,BL
    JMPNC mtc_xhi
    LDA AL,[eff_toro_margin]
    STA [toro_cx],AL
    LDA AL,[toro_vel_x]
    NOT AL
    ADD AL,#1
    STA [toro_vel_x],AL
    JMP mtc_y
mtc_xhi:
    LDA BL,[eff_toro_hi_x]
    CMP AL,BL
    JMPC mtc_y
    LDA AL,[eff_toro_hi_x]
    STA [toro_cx],AL
    LDA AL,[toro_vel_x]
    NOT AL
    ADD AL,#1
    STA [toro_vel_x],AL
mtc_y:
    LDA AL,[toro_cy]
    LDA BL,[toro_vel_y]
    ADD AL,BL
    STA [toro_cy],AL
    LDA BL,[eff_toro_margin]
    CMP AL,BL
    JMPNC mtc_yhi
    LDA AL,[eff_toro_margin]
    STA [toro_cy],AL
    LDA AL,[toro_vel_y]
    NOT AL
    ADD AL,#1
    STA [toro_vel_y],AL
    RET
mtc_yhi:
    LDA BL,[eff_toro_hi_y]
    CMP AL,BL
    JMPC mtc_done
    LDA AL,[eff_toro_hi_y]
    STA [toro_cy],AL
    LDA AL,[toro_vel_y]
    NOT AL
    ADD AL,#1
    STA [toro_vel_y],AL
mtc_done:
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
;  rot_x:  calcula sx_cur[vi] = (Lx[vi]*cos(angulo) - Tz[vi]*sin(angulo))
;  *escala + cen_x, y de paso sy_cur[vi] = sy_rel[vi]*escala + cen_y (el eje Y
;  no rota, solo se escala y se traslada). [scale] la controla poll_scale
;  girando DATOS (64 = tamaño normal, ver "punto fijo" de la cabecera) -- se
;  aplica DESPUES de rotar, con una multiplicacion mas de smul64, para no
;  tener que rehacer Lx/Tz escalados en cada paso intermedio.
; ============================================================================
rot_x:
    CALL compute_x_tilt          ; [tyx]/[tzx] = Y0[vi]/Z0[vi] inclinados por
                                  ; [xangle] -- sustituyen a la sy_rel/Tz
                                  ; estaticas de antes (ver nota de cabecera)

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

    LDA AL,[tzx]
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
    SUB AL,BL                    ; AL = dx sin escalar (ya rotado)
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64                  ; AL = dx*escala/64
    LDA BL,[cen_x]
    ADD AL,BL

    LDA CL,[vi]
    MOV BL,#lo(sx_cur)
    MOV BH,#hi(sx_cur)
    CALL idx_ptr
    STA [BX],AL

    ; sy_cur[vi] = tyx*escala + cen_y (tyx = Y0[vi] ya inclinado, ver arriba)
    LDA AL,[tyx]
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    LDA BL,[cen_y]
    ADD AL,BL

    LDA CL,[vi]
    MOV BL,#lo(sy_cur)
    MOV BH,#hi(sy_cur)
    CALL idx_ptr
    STA [BX],AL
    RET

; ============================================================================
;  compute_x_tilt: para el vertice [vi], inclina (Y0[vi],Z0[vi]) -- el cubo
;  SIN inclinar, +-16 en los 3 ejes -- por [xangle] (DIRECCION), con la misma
;  formula de rotacion 2D que ya usa rot_x para el eje Y:
;     tyx = Y0*cos(xangle) - Z0*sin(xangle)
;     tzx = Y0*sin(xangle) + Z0*cos(xangle)
;  Sale: [tyx] (sustituye a la sy_rel estatica de antes), [tzx] (sustituye a
;  la Tz estatica, sigue alimentando la rotacion animada sobre Y de rot_x).
; ============================================================================
compute_x_tilt:
    LDA CL,[vi]
    MOV BL,#lo(Y0)
    MOV BH,#hi(Y0)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[xangle]
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
    STA [xt_t1],AL                ; Y0*cos(xangle)

    LDA CL,[vi]
    MOV BL,#lo(Z0)
    MOV BH,#hi(Z0)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA CL,[xangle]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [xt_t2],AL                ; Z0*sin(xangle)

    LDA AL,[xt_t1]
    LDA BL,[xt_t2]
    SUB AL,BL
    STA [tyx],AL                  ; tyx = Y0*cos - Z0*sin

    LDA CL,[vi]
    MOV BL,#lo(Y0)
    MOV BH,#hi(Y0)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA CL,[xangle]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [xt_t1],AL                ; Y0*sin(xangle)

    LDA CL,[vi]
    MOV BL,#lo(Z0)
    MOV BH,#hi(Z0)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[xangle]
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
    STA [xt_t2],AL                ; Z0*cos(xangle)

    LDA AL,[xt_t1]
    LDA BL,[xt_t2]
    ADD AL,BL
    STA [tzx],AL                  ; tzx = Y0*sin + Z0*cos
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

; --- shadow_put_px:  pinta el pixel (px_x,px_y) al valor de [pix_val] (0 o
; 1), SOBRESCRIBIENDO lo que hubiera -- a diferencia de shadow_set_px, que
; solo enciende (OR), esta tambien apaga (AND con la mascara invertida). La
; usa el toro para pintar de atras hacia adelante: un disco mas cercano tiene
; que poder tapar del todo (tambien los pixeles ya encendidos) a uno mas
; lejano, no solo sumarse encima.
shadow_put_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_val]
    CMP DL,#0
    JMPZ spp_clear
    LDA DL,[pix_mask]
    OR  AL,DL
    JMP spp_store
spp_clear:
    LDA DL,[pix_mask]
    NOT DL
    AND AL,DL
spp_store:
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

; --- poll_toggle:  alterna [mode] (0=cubo,1=toro) al flanco de subida de
; DATOS -- una pulsacion, un cambio, sueltes cuando sueltes (mismo patron de
; deteccion de flanco que pong.asm/fzero.asm: comparar contra el nivel de la
; vuelta anterior, no solo el nivel actual).
poll_toggle:
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ pt_d
    CMP BL,#0
    JMPNZ pt_d                  ; ya estaba pulsado -> no es flanco, ignora
    LDA AL,[mode]
    XOR AL,#1
    STA [mode],AL
pt_d:
    RET

; --- poll_scale: [scale] += 2*(detentes de DATOS desde la ultima vez),
; recortado a [SCALE_MIN,SCALE_MAX] -- igual patron que update_pad_r de
; pong.asm para leer un encoder como cantidad continua: posicion absoluta
; (0..255, envuelve), resta la anterior para sacar el delta con signo. El
; *2 (un SHL) es solo para que se note el zoom sin tener que girar tanto;
; no hace falta un smul64 entero para multiplicar por una constante tan
; pequena. Comparte el mismo pulsador que poll_toggle (P_DAT_BTN) pero lee
; el encoder por la posicion (P_DAT_POS), asi que no interfieren entre si.
poll_scale:
    IN  AL,(P_DAT_POS)
    STA [tmpv],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL                    ; AL = delta con signo desde la ultima vez
    LDA CL,[tmpv]
    STA [dat_pos_prev],CL
    CMP AL,#0
    JMPZ ps_d                    ; nada que hacer si no giro nada
    SHL AL                       ; delta*2 (con signo; los deltas de un giro
                                  ; real caben de sobra sin desbordar)
    LDA BL,[scale]
    ADD BL,AL
    STA [scale],BL

    LDA AL,[scale]
    CMP AL,#SCALE_MIN
    JMPNC ps_hi                  ; scale >= SCALE_MIN -> dentro de rango
    MOV AL,#SCALE_MIN
    STA [scale],AL
    JMP ps_d
ps_hi:
    CMP AL,#(SCALE_MAX+1)
    JMPC ps_d                    ; scale <= SCALE_MAX -> dentro de rango
    MOV AL,#SCALE_MAX
    STA [scale],AL
ps_d:
    RET

; ============================================================================
;  TORO (modo 1): NSPOKE=20 costillas, cada una un "trozo de tubo" solido
;  (un disco de radio DISK_R con trama, no un contorno). Tres pasos:
;    1. torus_compute: para cada costilla, su posicion en pantalla (scr_x/
;       scr_y, misma formula Rx = Lx*cos(a) - Tz*sin(a) que rot_x del cubo)
;       y su profundidad ya rotada (rzu_arr, pidiendo la otra componente:
;       Rz = Lx*sin(a) + Tz*cos(a)).
;    2. sort_spokes: ordena los indices 0..19 por rzu_arr ascendente (order[]:
;       de mas lejos a mas cerca) -- un insertion sort de toda la vida, 20
;       elementos no dan para mas.
;    3. draw_torus recorre order[] en ESE orden y llama draw_disk costilla a
;       costilla: como se pinta de atras hacia adelante y draw_disk
;       SOBREESCRIBE (shadow_put_px, no shadow_set_px), el disco de una
;       costilla mas cercana tapa del todo al de una mas lejana donde se
;       solapen -- oclusion correcta sin tener que calcular ninguna
;       interseccion, solo por el orden en que se dibuja.
;  La trama de cada disco (level_from_rz + dither_on, mas abajo) es la
;  "textura cambiante": de floja del todo (costilla de espaldas, pero SIN
;  llegar a desaparecer del todo -- ver la nota de level_from_rz) a solida
;  del todo (costilla de cara), pasando por 2 densidades intermedias de un
;  dithering ordenado de matriz de Bayer 2x2 -- igual idea que el dithering
;  por nibble de raycast.asm, pero pixel a pixel en vez de por columna.
; ============================================================================
draw_torus:
    ; radio EFECTIVO del disco de cada costilla este fotograma -- escala con
    ; [scale] igual que la posicion (ver TORO_MARGIN/HW2D mas abajo). Se
    ; calcula UNA sola vez aqui, no costilla a costilla: [scale] es el mismo
    ; para las 20. Recortado a [1,TORO_MAX_DISK_R] por seguridad (el rango
    ; real con SCALE_MIN..SCALE_MAX es 2..7, de sobra dentro del recorte).
    MOV AL,#DISK_R
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    CMP AL,#1
    JMPNC edr_min_ok
    MOV AL,#1
edr_min_ok:
    CMP AL,#TORO_MAX_DISK_R
    JMPC edr_max_ok
    MOV AL,#TORO_MAX_DISK_R
edr_max_ok:
    STA [eff_disk_r],AL

    ; hw_base = HW_ROW_OFF[eff_disk_r-1] -- fila de HW2D que le toca a este
    ; radio (ver draw_disk/draw_disk_row, que ya no usan la HW de un radio
    ; fijo sino HW2D[hw_base+dyv]).
    SUB AL,#1
    MOV CL,AL
    MOV BL,#lo(HW_ROW_OFF)
    MOV BH,#hi(HW_ROW_OFF)
    CALL idx_ptr
    LDA AL,[BX]
    STA [hw_base],AL

    CALL torus_compute
    CALL sort_spokes

    MOV AL,#0
    STA [i],AL
dt_l:
    LDA CL,[i]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[BX]
    STA [key],AL                 ; key = indice de costilla en este puesto

    LDA CL,[key]
    MOV BL,#lo(rzu_arr)
    MOV BH,#hi(rzu_arr)
    CALL idx_ptr
    LDA AL,[BX]
    STA [rzu],AL
    CALL level_from_rz
    STA [level],AL

    LDA CL,[key]
    MOV BL,#lo(scr_x)
    MOV BH,#hi(scr_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [disk_cx],AL

    LDA CL,[key]
    MOV BL,#lo(scr_y)
    MOV BH,#hi(scr_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [disk_cy],AL

    CALL draw_disk

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NSPOKE
    JMPNZ dt_l
    RET

; --- torus_compute: llena rzu_arr[su]/scr_x[su]/scr_y[su] para las 20
; costillas (sin dibujar nada todavia -- hace falta tenerlas TODAS calculadas
; antes de poder ordenarlas). scr_x/scr_y llevan tambien la escala de
; [scale] (girando DATOS, ver poll_scale), igual truco de una multiplicacion
; mas que rot_x del cubo. rzu_arr NO escala a proposito: es solo para
; sombreado (level_from_rz, calibrado al rango SIN escalar de LxU/TzU), no
; para la posicion en pantalla -- si escalara, el toro se veria todo gris a
; tamano pequeno y todo saturado a tamano grande. Reutiliza sm_a/sm_b/rx_t1/
; rx_t2 de rot_x: son variables de trabajo sin estado entre llamadas.
torus_compute:
    MOV AL,#0
    STA [su],AL
tc_l:
    CALL compute_x_tilt_torus     ; [tyux]/[tzux] = Y0U[su]/Z0U[su] inclinados
                                   ; por [xangle] -- sustituyen a la SyU/TzU
                                   ; estaticas de antes (ver compute_x_tilt)

    ; --- scr_x[su] = LxU[su]*cos(a) - tzux*sin(a) + TORO_CX -----------------
    LDA CL,[su]
    MOV BL,#lo(LxU)
    MOV BH,#hi(LxU)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[angle]
    ADD AL,#16
    AND AL,#0x3F
    STA [tmp_idx],AL             ; (angle+16)&0x3F -- se reutiliza mas abajo
    LDA CL,[tmp_idx]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [rx_t1],AL

    LDA AL,[tzux]
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
    SUB AL,BL                    ; AL = dx sin escalar (ya rotado)
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64                  ; AL = dx*escala/64
    LDA BL,[toro_cx]
    ADD AL,BL
    STA [tmpv],AL                ; guardado antes de pisar BX con scr_x
    LDA CL,[su]
    MOV BL,#lo(scr_x)
    MOV BH,#hi(scr_x)
    CALL idx_ptr
    LDA AL,[tmpv]
    STA [BX],AL

    ; --- rzu_arr[su] = LxU[su]*sin(a) + tzux*cos(a) -------------------------
    LDA CL,[su]
    MOV BL,#lo(LxU)
    MOV BH,#hi(LxU)
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
    STA [rx_t1],AL

    LDA AL,[tzux]
    STA [sm_a],AL

    LDA CL,[tmp_idx]             ; (angle+16)&0x3F, ya calculado arriba
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [rx_t2],AL

    LDA AL,[rx_t1]
    LDA BL,[rx_t2]
    ADD AL,BL
    STA [tmpv],AL
    LDA CL,[su]
    MOV BL,#lo(rzu_arr)
    MOV BH,#hi(rzu_arr)
    CALL idx_ptr
    LDA AL,[tmpv]
    STA [BX],AL

    ; --- scr_y[su] = tyux*escala + toro_cy (tyux ya lleva la inclinacion) ---
    LDA AL,[tyux]
    STA [sm_a],AL
    LDA AL,[scale]
    STA [sm_b],AL
    CALL smul64
    LDA BL,[toro_cy]
    ADD AL,BL
    STA [tmpv],AL
    LDA CL,[su]
    MOV BL,#lo(scr_y)
    MOV BH,#hi(scr_y)
    CALL idx_ptr
    LDA AL,[tmpv]
    STA [BX],AL

    LDA AL,[su]
    ADD AL,#1
    STA [su],AL
    CMP AL,#NSPOKE
    JMPNZ tc_l
    RET

; ============================================================================
;  compute_x_tilt_torus: igual que compute_x_tilt del cubo, pero para la
;  costilla [su] del toro (Y0U/Z0U en vez de Y0/Z0). Sale: [tyux] (sustituye
;  a la SyU estatica de antes), [tzux] (sustituye a la TzU estatica).
; ============================================================================
compute_x_tilt_torus:
    LDA CL,[su]
    MOV BL,#lo(Y0U)
    MOV BH,#hi(Y0U)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[xangle]
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
    STA [xt_t1],AL                ; Y0U*cos(xangle)

    LDA CL,[su]
    MOV BL,#lo(Z0U)
    MOV BH,#hi(Z0U)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA CL,[xangle]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [xt_t2],AL                ; Z0U*sin(xangle)

    LDA AL,[xt_t1]
    LDA BL,[xt_t2]
    SUB AL,BL
    STA [tyux],AL                 ; tyux = Y0U*cos - Z0U*sin

    LDA CL,[su]
    MOV BL,#lo(Y0U)
    MOV BH,#hi(Y0U)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA CL,[xangle]
    MOV BL,#lo(sine)
    MOV BH,#hi(sine)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_b],AL
    CALL smul64
    STA [xt_t1],AL                ; Y0U*sin(xangle)

    LDA CL,[su]
    MOV BL,#lo(Z0U)
    MOV BH,#hi(Z0U)
    CALL idx_ptr
    LDA AL,[BX]
    STA [sm_a],AL

    LDA AL,[xangle]
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
    STA [xt_t2],AL                ; Z0U*cos(xangle)

    LDA AL,[xt_t1]
    LDA BL,[xt_t2]
    ADD AL,BL
    STA [tzux],AL                 ; tzux = Y0U*sin + Z0U*cos
    RET

; --- sort_spokes: ordena order[0..19] (indices de costilla) por rzu_arr
; ascendente -- insertion sort clasico. order[i]=i al empezar; luego, para
; cada i, desplaza hacia la derecha los ya colocados que sean mas grandes
; que el que se esta insertando (comparacion con signo via el bit N, igual
; tecnica que level_from_rz/line_draw). j "por debajo de 0" se detecta
; comparando contra 0xFF (j es un byte sin signo: 0-1 envuelve ahi).
sort_spokes:
    MOV AL,#0
    STA [i],AL
ss_init_l:
    LDA CL,[i]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[i]
    STA [BX],AL
    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NSPOKE
    JMPNZ ss_init_l

    MOV AL,#1
    STA [i],AL
ss_outer_l:
    LDA CL,[i]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[BX]
    STA [key],AL

    LDA CL,[key]
    MOV BL,#lo(rzu_arr)
    MOV BH,#hi(rzu_arr)
    CALL idx_ptr
    LDA AL,[BX]
    STA [keyval],AL

    LDA AL,[i]
    SUB AL,#1
    STA [j],AL

ss_inner_l:
    LDA AL,[j]
    CMP AL,#0xFF
    JMPZ ss_place

    LDA CL,[j]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[BX]
    STA [oj],AL

    LDA CL,[oj]
    MOV BL,#lo(rzu_arr)
    MOV BH,#hi(rzu_arr)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[keyval]
    SUB AL,BL                    ; rzu_arr[order[j]] - keyval
    JMPN ss_place                ; < 0 -> ya no hay que desplazar mas
    JMPZ ss_place                ; = 0 -> tampoco (estable de sobra con 20)

    LDA AL,[j]
    ADD AL,#1
    STA [jp1],AL
    LDA CL,[jp1]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[oj]
    STA [BX],AL

    LDA AL,[j]
    SUB AL,#1
    STA [j],AL
    JMP ss_inner_l

ss_place:
    LDA AL,[j]
    ADD AL,#1
    STA [jp1],AL
    LDA CL,[jp1]
    MOV BL,#lo(order)
    MOV BH,#hi(order)
    CALL idx_ptr
    LDA AL,[key]
    STA [BX],AL

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NSPOKE
    JMPNZ ss_outer_l
    RET

; --- level_from_rz: cuantiza [rzu] (con signo) a un nivel 1..4 (1=costilla
; de espaldas, 4=de cara al espectador) con 3 umbrales (-1,7,15) repartidos
; en el rango de rzu (+-18, ver LxU/TzU) -- comparaciones con signo via el
; bit N, igual tecnica que line_draw/move_center (SUB o ADD y mirar JMPN, sin
; necesitar un CMP con signo de rango completo). Entra: [rzu]. Sale: AL.
;
; OJO: no hay nivel 0 (trama vacia del todo) a proposito -- lo hubo en un
; intento anterior, y la mitad de atras del toro (la que no queda tapada por
; la de delante, que esa si desaparece del todo y con razon) se leia como
; "falta", no como "esta ahi pero de espaldas", porque una trama del todo
; vacia es indistinguible del fondo negro. El nivel mas oscuro (1) sigue
; siendo la trama mas floja (1 de cada 4 pixeles, ver dither_on/BAYER2), pero
; nunca cero: la costilla mas de espaldas se ve floja, no invisible.
level_from_rz:
    LDA AL,[rzu]
    ADD AL,#1                    ; rzu < -1 ?
    JMPN lv_1
    LDA AL,[rzu]
    SUB AL,#7                    ; rzu < 7 ?
    JMPN lv_2
    LDA AL,[rzu]
    SUB AL,#15                   ; rzu < 15 ?
    JMPN lv_3
    MOV AL,#4
    RET
lv_1:
    MOV AL,#1
    RET
lv_2:
    MOV AL,#2
    RET
lv_3:
    MOV AL,#3
    RET

; --- draw_disk: rellena, con trama segun [level], un disco del radio
; EFECTIVO de este fotograma ([eff_disk_r], ver draw_torus) centrado en
; (disk_cx,disk_cy) -- fila a fila, con la semianchura de cada fila en
; HW2D[hw_base+|dy|] (la fila de la tabla 2D que le toca a este radio,
; precalculada en Python -- ver la tabla mas abajo). La fila central (dy=0)
; se pinta una vez; las demas, por parejas simetricas arriba/abajo (dyv y
; -dyv).
draw_disk:
    MOV AL,#0
    STA [dyv],AL
dd_row_l:
    LDA AL,[hw_base]
    LDA CL,[dyv]
    ADD AL,CL
    MOV CL,AL
    MOV BL,#lo(HW2D)
    MOV BH,#hi(HW2D)
    CALL idx_ptr
    LDA AL,[BX]
    STA [hwv],AL

    LDA AL,[disk_cy]
    LDA BL,[dyv]
    ADD AL,BL
    STA [scan_y],AL
    CALL draw_disk_row

    LDA AL,[dyv]
    CMP AL,#0
    JMPZ dd_no_mirror
    LDA AL,[disk_cy]
    LDA BL,[dyv]
    SUB AL,BL
    STA [scan_y],AL
    CALL draw_disk_row
dd_no_mirror:

    LDA AL,[dyv]
    ADD AL,#1
    STA [dyv],AL
    LDA BL,[eff_disk_r]
    ADD BL,#1
    CMP AL,BL
    JMPNZ dd_row_l
    RET

; --- draw_disk_row: pinta la fila [scan_y], columnas
; disk_cx-hwv .. disk_cx+hwv, cada pixel a su valor de dither_on.
draw_disk_row:
    LDA AL,[disk_cx]
    LDA BL,[hwv]
    SUB AL,BL
    STA [scan_x],AL

    LDA AL,[hwv]
    SHL AL                       ; ancho = hwv*2 + 1
    ADD AL,#1
    STA [span_cnt],AL

ddr_l:
    CALL dither_on
    STA [pix_val],AL
    LDA AL,[scan_x]
    STA [px_x],AL
    LDA AL,[scan_y]
    STA [px_y],AL
    CALL shadow_put_px

    LDA AL,[scan_x]
    ADD AL,#1
    STA [scan_x],AL
    LDA AL,[span_cnt]
    SUB AL,#1
    STA [span_cnt],AL
    JMPNZ ddr_l
    RET

; --- dither_on: AL=1 si el pixel (scan_x,scan_y) va encendido con [level]
; (1..4, level_from_rz nunca da 0) segun una matriz de Bayer 2x2 (BAYER2):
; nivel 1 -> 1 de cada 4 pixeles, subiendo hasta nivel 4 -> los 4 (solido).
; El indice de la matriz sale de los bits bajos de x e y, asi que el patron
; queda fijo en la
; PANTALLA (no se mueve con el disco): es lo que hace que el relleno de
; varios discos solapados se vea como una trama continua y no como cada
; disco con su propio patron descuadrado con el vecino.
dither_on:
    LDA AL,[scan_y]
    AND AL,#1
    SHL AL
    STA [tmp_idx],AL
    LDA AL,[scan_x]
    AND AL,#1
    LDA BL,[tmp_idx]
    ADD AL,BL
    STA [tmp_idx],AL

    LDA CL,[tmp_idx]
    MOV BL,#lo(BAYER2)
    MOV BH,#hi(BAYER2)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmpv],AL

    LDA AL,[level]
    LDA BL,[tmpv]
    SUB AL,BL                    ; level - bayer
    JMPN don_off                 ; level < bayer  -> apagado
    JMPZ don_off                 ; level == bayer -> tambien apagado
    MOV AL,#1
    RET
don_off:
    MOV AL,#0
    RET

; ============================================================================
;  DATOS  (justo despues del codigo -- ver programs/README.md, "Tamano del
;  .bin"). Los vertices ya vienen inclinados 28 grados sobre X (calculado una
;  vez con Python, no en tiempo de ejecucion): Lx y Tz alimentan la rotacion
;  animada sobre Y en cada fotograma; sy es la Y de pantalla, fija.
; ============================================================================
angle:    .space 1    ; 0..63, un giro completo son 64 pasos (eje Y, animado)
xangle:   .space 1    ; 0..63, inclinacion sobre el eje X (DIRECCION, manual)
xt_t1:    .space 1    ; escalones de compute_x_tilt/compute_x_tilt_torus
xt_t2:    .space 1
tyx:      .space 1    ; Y0[vi] ya inclinado por xangle (sustituye a sy_rel)
tzx:      .space 1    ; Z0[vi] ya inclinado por xangle (sustituye a Tz)
tyux:     .space 1    ; version toro de tyx (Y0U[su], sustituye a SyU)
tzux:     .space 1    ; version toro de tzx (Z0U[su], sustituye a TzU)
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
mode:     .space 1    ; 0=cubo, 1=toro (poll_toggle)
dat_btn_prev: .space 1
scale:    .space 1    ; tamano actual, 64=normal (poll_scale, gira DATOS)
dat_pos_prev: .space 1  ; ultima posicion cruda leida de DATOS (para el
                       ; delta de poll_scale -- ver update_pad_r de pong.asm,
                       ; mismo patron: posicion absoluta, resta la anterior)
eff_bx_margin: .space 1  ; BX_MARGIN*escala/64 (compute_margins, solo cubo)
eff_bx_hi:     .space 1  ; 127 - eff_bx_margin
eff_by_margin: .space 1  ; BY_MARGIN*escala/64
eff_by_hi:     .space 1  ; 63 - eff_by_margin

toro_cx:  .space 1    ; centro del toro en pantalla -- AHORA rebota, con su
toro_cy:  .space 1    ; propia velocidad, independiente de la del cubo (ver
toro_vel_x: .space 1  ; move_toro_center/compute_toro_margins)
toro_vel_y: .space 1
eff_toro_margin: .space 1  ; TORO_MARGIN*escala/64 (compute_toro_margins)
eff_toro_hi_x:   .space 1  ; 127 - eff_toro_margin
eff_toro_hi_y:   .space 1  ; 63 - eff_toro_margin
eff_disk_r: .space 1   ; radio EFECTIVO del disco de cada costilla este
                       ; fotograma (DISK_R*escala/64, recortado a
                       ; [1,TORO_MAX_DISK_R] -- ver draw_torus)
hw_base:  .space 1     ; HW_ROW_OFF[eff_disk_r-1] -- fila de HW2D que le
                       ; toca a eff_disk_r (ver draw_disk)

su:       .space 1    ; indice de costilla en curso al calcular (0..NSPOKE-1)
rzu:      .space 1    ; profundidad ya rotada de la costilla EN CURSO (con
                       ; signo) -- copia de trabajo de rzu_arr[key] para
                       ; level_from_rz, ver draw_torus
level:    .space 1    ; nivel de sombra de la costilla en curso (1..4)
tmpv:     .space 1    ; valor de paso al guardar en scr_x/scr_y/rzu_arr

; --- pintor de atras hacia adelante: 20 costillas, 20 bytes cada tabla
; (NSPOKE=20 en crudo, no ".space NSPOKE": casm.py resuelve "NOMBRE = EXPR"
; en un pase aparte, DESPUES del que calcula el tamano de cada ".space", asi
; que en ese momento la constante todavia no esta definida).
rzu_arr:  .space 20   ; profundidad rotada de cada costilla, sin ordenar
scr_x:    .space 20   ; posicion en pantalla (x) de cada costilla
scr_y:    .space 20   ; posicion en pantalla (y) de cada costilla
order:    .space 20   ; indices 0..19 ordenados por rzu_arr ascendente
                       ; (de mas lejos a mas cerca) -- sort_spokes

; --- variables de sort_spokes (insertion sort de order[] por rzu_arr) ------
i:        .space 1
j:        .space 1
key:      .space 1
keyval:   .space 1
oj:       .space 1
jp1:      .space 1

; --- variables de draw_disk/draw_disk_row/dither_on (relleno con trama de
; una costilla, ver mas abajo) -----------------------------------------
disk_cx:  .space 1
disk_cy:  .space 1
dyv:      .space 1
hwv:      .space 1
scan_x:   .space 1
scan_y:   .space 1
span_cnt: .space 1
pix_val:  .space 1    ; 0/1 para shadow_put_px (a diferencia de shadow_set_px,
                       ; SOBREESCRIBE el pixel en vez de solo encenderlo --
                       ; hace falta para que el pintor de atras hacia
                       ; adelante tape de verdad lo que hubiera detras)

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

; Lx: coordenada X base (con signo) -- el eje X nunca se inclina (ver
; compute_x_tilt), asi que no le hace falta tabla "sin inclinar" aparte.
Lx:  .db 240, 240, 240, 240, 16, 16, 16, 16

; Y0, Z0: coordenadas Y/Z base SIN INCLINAR (un cubo recto de +-16 en los 3
; ejes -- antes esta tabla ya venia horneada con 28 grados de inclinacion
; fija; ahora la inclina compute_x_tilt cada fotograma segun [xangle], ver
; la nota de cabecera). Calculadas invirtiendo exactamente esos 28 grados de
; las Tz/sy_rel originales (por eso no son un +-16 redondo perfecto: cargan
; el mismo redondeo de un byte que ya tenian esas tablas).
Y0:  .db 239, 240, 16, 17, 239, 240, 16, 17
Z0:  .db 240, 17, 239, 16, 240, 17, 239, 16

; aristas del cubo: pares de indices de vertice (0..7)
edge_a: .db 0, 2, 4, 6, 0, 1, 2, 3, 0, 1, 4, 5
edge_b: .db 1, 3, 5, 7, 4, 5, 6, 7, 2, 3, 6, 7

; seno*64 con signo, 64 pasos (indice de coseno = (indice+16) & 63)
sine: .db 0, 6, 12, 19, 24, 30, 36, 41, 45, 49, 53, 56, 59, 61, 63, 64
      .db 64, 64, 63, 61, 59, 56, 53, 49, 45, 41, 36, 30, 24, 19, 12, 6
      .db 0, 250, 244, 237, 232, 226, 220, 215, 211, 207, 203, 200, 197, 195, 193, 192
      .db 192, 192, 193, 195, 197, 200, 203, 207, 211, 215, 220, 226, 232, 237, 244, 250

; LxU/Y0U/Z0U: eje central de cada una de las 20 costillas, SIN inclinar
; (calculado en Python igual que Y0/Z0 del cubo: invirtiendo los 28 grados
; que las TzU/SyU originales traian ya horneados -- ver la nota de cabecera
; sobre compute_x_tilt_torus). LxU no se inclina nunca (el eje X no rota);
; Y0U/Z0U los inclina compute_x_tilt_torus cada fotograma segun [xangle], y
; el resultado (tyux/tzux) alimenta tanto la posicion en pantalla como el
; sombreado (rotacion Y animada, ver torus_compute), igual que antes SyU/TzU.
LxU: .db 18, 17, 15, 11, 6, 0, 250, 245, 241, 239, 238, 239, 241, 245, 250, 0, 6, 11, 15, 17
Y0U: .db 0, 5, 10, 13, 15, 16, 15, 13, 10, 5, 0, 251, 246, 243, 241, 240, 241, 243, 246, 251
Z0U: .db 0, 3, 5, 7, 8, 9, 8, 7, 5, 3, 0, 253, 251, 249, 248, 247, 248, 249, 251, 253

; HW2D/HW_ROW_OFF: semianchura (en pixeles) de cada fila de un disco, para
; CUALQUIER radio entero 1..TORO_MAX_DISK_R (antes solo habia una tabla para
; el unico radio fijo DISK_R=6 -- ahora el radio real cambia cada fotograma
; con [scale], ver eff_disk_r en draw_torus). HW2D es una tabla 2D aplanada
; de paso fijo 9 (dy 0..8, de sobra para el radio mas grande soportado);
; HW_ROW_OFF[r-1] da el desplazamiento de la fila del radio r dentro de
; HW2D. Cada fila es round(sqrt(r^2-dy^2)) para dy<=r, 0 en el resto (nunca
; se llega a leer, draw_disk para en dy=r) -- calculada en Python. La fila
; r=6 es exactamente la HW de siempre (6,6,6,5,4,3), para que a escala 64
; (normal) el toro se vea igual que antes de este cambio.
HW2D: .db 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 3, 3, 2, 0, 0, 0, 0, 0, 0, 4, 4, 3, 3, 0, 0, 0, 0, 0, 5, 5, 5, 4, 3, 0, 0, 0, 0, 6, 6, 6, 5, 4, 3, 0, 0, 0, 7, 7, 7, 6, 6, 5, 4, 0, 0, 8, 8, 8, 7, 7, 6, 5, 4, 0
HW_ROW_OFF: .db 0, 9, 18, 27, 36, 45, 54, 63

; BAYER2: matriz de Bayer 2x2 clasica (orden de dithering), indexada por
; (y&1)*2 + (x&1) -- la usa dither_on para decidir 1, 2, 3 o 4 de cada 4
; pixeles segun el nivel de sombra (1..4, nunca 0 -- ver level_from_rz).
BAYER2: .db 0, 2, 3, 1

; shadow: copia del framebuffer en RAM ("doble buffer" software, ver main_l).
; TIENE que ir la ultima de todo el fichero: al ser un .space sin datos reales
; nunca se le hace un .db/.asciiz, no cuenta para el recorte del .bin (ver
; "Tamano del .bin" en programs/README.md) -- solo cuesta bytes si algo con
; datos de verdad va DESPUES de ella en el fichero.
shadow: .space 1024
