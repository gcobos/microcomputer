; ============================================================================
;  raycast.asm  -  escena 3D en primera persona estilo Doom/Wolfenstein (compi)
;
;  Motor de "raycasting" clasico: mapa de 16x16 baldosas, se lanzan 32 rayos
;  (uno cada ~2,8 grados, campo de vision de 90 grados) desde la posicion del
;  jugador, cada uno "marcha" en pasos fijos hasta chocar con una pared; la
;  distancia recorrida (en pasos, no en pixeles) da la altura de la franja
;  vertical de pared que se dibuja para ese rayo (mas cerca = mas alta).
;
;  El motor de paredes no multiplica ni divide, ni hace trigonometria en
;  tiempo de ejecucion -- todo son tablas, calculadas una vez con Python (ver el
;  comentario de cada tabla mas abajo) y trucos de potencia de 2:
;    - Posicion del jugador de 8 bits, "baldosa" = 16 unidades (potencia de
;      2): la baldosa de una posicion es solo un SHR x4, no una division.
;    - Mapa de 16x16 (2 bytes/fila): la fila de una baldosa es su indice
;      multiplicado por 2, o sea SHL x1.
;    - Direccion de cada rayo/movimiento: tabla de (dx,dy) por angulo (128
;      angulos posibles = potencia de 2, para que "girar" sea sumar y
;      enmascarar con AND 0x7F, sin comprobar desbordamiento a mano).
;    - Altura de pared segun distancia: tabla, no division.
;  Verificado en Python antes de escribir esto: con el mapa y el limite de
;  pasos de marcha de aqui, NINGUN rayo se queda sin chocar contra una pared
;  en ninguna de las 196.992 combinaciones de baldosa/subposicion/angulo
;  probadas (el mapa esta bordeado de pared por todos lados) -- importante,
;  porque con una posicion de solo 8 bits un rayo que marchara demasiado
;  lejos sin chocar "daria la vuelta" al mapa en vez de seguir alejandose.
;
;  Las paredes se rellenan segun su distancia con una de 5 tramas -- desde
;  completamente negra (la mas lejana, se funde con el fondo) hasta
;  completamente blanca (pegada al jugador), pasando por tres tramas de
;  puntos cada vez mas densas -- para simular escala de grises en una
;  pantalla monocroma (dithering ordenado de 4 niveles dentro del nibble
;  de cada franja). Los rayos siguen dibujandose en el orden habitual
;  (izquierda a derecha) porque las franjas de columnas distintas nunca se
;  solapan entre si -- el unico elemento que SI puede solaparse con una
;  pared es el proyectil (ver mas abajo), y a ese se le hace la prueba de
;  profundidad explicita justo donde importa.
;
;  Pulsar CUALQUIERA de los dos pulsadores (DIRECCION o DATOS) lanza un
;  proyectil que sale en linea recta hacia donde mira el jugador, despacio
;  (1/4 de baldosa por fotograma, move_tbl) para que se le vea alejarse, con
;  un silbido descendente al salir y un golpe grave al chocar contra una
;  pared (o al llegar a MAX_STEPS baldosas). Hasta PROJ_COUNT=4 a la vez.
;
;  DOT_COUNT=10 bolitas por nivel, en posiciones fijas; se recogen
;  acercandose (DOT_TOUCH_DIST px por eje), con un "ding" agudo, y arriba
;  se ve cuantas quedan ("DOTS LEFT n"). Al recoger la ultima aparece
;  "LEVEL PASSED!" y se pasa al siguiente de MAP_COUNT=3 mapas prehechos,
;  en bucle. Es una demo: no hay puntos ni record.
;
;  Bolitas y proyectiles se dibujan como DIANAS: circulos concentricos de
;  2 px que alternan encendido/apagado, de radio segun la distancia (tabla
;  OBJ_R, en medias baldosas) -- un patron de anillos se distingue sobre las
;  paredes blancas, sobre las tramadas y sobre el fondo, cosa que un relleno
;  plano no conseguia. Las bolitas se apoyan en el suelo y los proyectiles
;  van a la altura de los ojos. Su posicion en pantalla sale del angulo de
;  verdad respecto al jugador (atan(menor/mayor) con MUL/DIV y la tabla
;  ATAN32, ver obj_project), y se dibujan tras paredes y nubes recortadas
;  pixel a pixel contra la pared de cada columna (dist4_tbl): una pared mas
;  cercana tapa la parte de la diana que quede detras.
;
;  El cielo lleva CLOUD_COUNT=8 nubes grandes, huecas y de lineas curvas
;  (el contorno de la union de varios circulos, con el interior vacio --
;  calculado una vez con Python, ver el comentario de cloud_shape_a/
;  cloud_shape_b mas abajo), de dos formas distintas alternadas por
;  paridad de indice: rechoncha (cloud_shape_a, mas ancha que alta) y
;  alargada (cloud_shape_b, mucho mas ancha que alta) -- las alargadas se
;  mueven mas rapido, con su propia deriva (cloud_drift_b, que avanza el
;  doble por paso que cloud_drift_a). Cada una lleva su angulo de mundo
;  fijo (cloud_angle_tbl) mas la deriva de su tipo, que decrece un poco
;  cada varios fotogramas -- asi que, aunque el jugador no toque los
;  mandos, las nubes se deslizan solas hacia la izquierda, cada tipo a su
;  propio ritmo. Al ser mucho mas anchas que la
;  franja de 4 px de un solo rayo, no se dibujan columna a columna dentro
;  de ray_loop como las paredes/proyectiles, sino en un unico paso aparte
;  (dibuja_nubes) tras terminar el bucle de rayos, estampando cada pixel
;  del contorno con calc_pix/shadow_set_pix (direccionamiento de pixel
;  exacto, no por nibble). Se dibujan con la MISMA formula de visibilidad
;  que los proyectiles (angulo de la nube menos `facing`, dentro de la
;  ventana de 32 rayos), asi que el desplazamiento de `facing` al girar se
;  SUMA directamente al de la deriva: girar a la derecha empuja las nubes
;  hacia la izquierda en la misma direccion que su deriva (se ven mas
;  rapidas), girar a la izquierda empuja en la direccion contraria (se ven
;  mas lentas, o incluso van hacia la derecha si el giro es mas rapido que
;  la deriva). Solo se dibujan si la pared de su columna central queda por
;  debajo de ellas (mismo criterio de profundidad que el proyectil, pero
;  comparando contra una tabla [y0_tbl] con el techo libre de las 32
;  columnas, guardada durante el bucle de rayos, en vez de un solo [y0]
;  escalar -- la nube ya no se dibuja DENTRO de ese bucle, asi que para
;  cuando le toca comprobarlo el [y0] de su columna ya se ha perdido).
;
;  Controles:
;     encoder DIRECCION gira -> gira la vista (izquierda/derecha)
;     encoder DATOS gira     -> avanza/retrocede (no atraviesa paredes)
;     pulsador DIRECCION o DATOS -> dispara un proyectil
;
;  No hay boton de salida (los dos pulsadores son para disparar): se sale
;  cambiando el interruptor SW_MODE a EDIT, igual que roto_debug.asm.
;
;  Si el giro de vista o el avance salen invertidos en el aparato real,
;  cambia el signo en `gira_der`/`gira_izq` o en `mueve_adelante` (justo
;  donde se explica, mas abajo) -- es solo un convenio de que numero de
;  angulo/tabla es "hacia donde", no un fallo de calculo.
;
;  Ensamblar y enviar al slot 9:
;     python3 tools/casm.py programs/raycast.asm -o programs/raycast.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 9 programs/raycast.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 9

    .name "RAYCAST"

    .category DEMO
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_TEXT     = 0x0400
P_DIR_POS  = 0x0600
P_DIR_BTN  = 0x0601
P_DAT_POS  = 0x0602
P_DAT_BTN  = 0x0603
P_T3       = 0x0623
P_SND_FREQ_LO = 0x0630
P_SND_FREQ_HI = 0x0631
P_SND_NOTE    = 0x0632
P_SND_DUR     = 0x0633

; --- geometria / constantes --------------------------------------------------
FOV_RAYS   = 32          ; rayos por fotograma = franjas de 4 px (32*4=128)
MAX_STEPS  = 20          ; limite de pasos de marcha (ver el aviso de arriba)
TURN_STEP  = 4           ; cuanto gira `facing` por detente (de 128, ~11 grados)

; --- proyectiles ("bolas de fuego"): hasta PROJ_COUNT a la vez, cada uno
; con su propio angulo de disparo y su propia distancia recorrida ------------
PROJ_COUNT      = 4      ; proyectiles simultaneos como maximo
PROJ_ROW        = 31     ; fila central donde se dibujan (altura de "los ojos")

; --- sonido del disparo: silbido descendente (un solo canal, monofonico;
; cada disparo nuevo lo reinicia aunque ya haya otros proyectiles en vuelo) --
SND_FREQ_START  = 900    ; Hz al disparar
SND_FREQ_STEP   = 90     ; Hz que baja cada fotograma
SND_SWEEP_FRAMES = 9     ; fotogramas que dura el silbido

; --- bolitas recolectables: DOT_COUNT posiciones fijas por nivel (ver la
; cabecera de arriba). Se ven/dibujan con el mismo mecanismo de "angulo
; relativo a facing -> columna de pantalla" que los proyectiles (ver
; apr_vis), pero su angulo se RECALCULA cada fotograma a partir de la
; posicion relativa jugador/bolita con calc_dot_angle -- la misma
; clasificacion en 8 octantes sin multiplicacion ni trigonometria que usaba
; el enemigo de la version anterior de este programa.
DOT_COUNT           = 10    ; bolitas por nivel
DOT_TOUCH_DIST      = 10    ; distancia (px, por eje) para recogerla -- NO
                             ; la misma baldosa (16x16): igual criterio que
                             ; usaba el contacto del enemigo, mas generoso
MAP_COUNT           = 3     ; niveles prehechos, en bucle (ver load_level)
; pitido corto al recoger una bolita (mismo mecanismo de silbido que
; dispara, reutilizando snd_timer/snd_freq_* -- un solo canal):
DOT_PICK_FREQ_START   = 1500
DOT_PICK_SWEEP_FRAMES = 4

; --- cielo: nubes grandes, huecas y curvas, con deriva propia ----------------
CLOUD_COUNT        = 8   ; numero de nubes
CLOUD_TOP_ROW      = 1   ; fila donde cae dy=0 del contorno de cualquiera
                          ; de las dos formas (cloud_shape_a/cloud_shape_b)
CLOUD_MIN_Y0       = 15  ; si [y0] de la columna central es menor que esto,
                          ; la pared ya tapa la nube (no se dibuja)
; dos formas de nube, alternadas por paridad de [cloud_i] (ver dibuja_nubes):
CLOUD_SHAPE_A_LEN  = 52  ; rechoncha (cloud_shape_a): mas ancha que alta
CLOUD_SHAPE_B_LEN  = 68  ; alargada  (cloud_shape_b): mucho mas ancha que alta
CLOUD_DRIFT_PERIOD = 6   ; fotogramas entre cada paso de deriva (mas alto = mas lento)
CLOUD_DRIFT_STEP_A = 1   ; cuanto avanza la deriva de las rechonchas cada paso
CLOUD_DRIFT_STEP_B = 2   ; idem para las alargadas -- el doble, se ven mas rapidas

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV BX,#h_title
    MOV CX,#0x0304
    CALL puts
    MOV AL,#8
    CALL frame_wait
    CALL clst

    MOV AL,#0
    STA [map_idx],AL
    CALL load_level         ; posiciona al jugador y puebla mapa/bolitas
                              ; del nivel 0 (ver load_level)
    CALL show_hud

    MOV AL,#0
    STA [proj_active],AL
    STA [proj_active+1],AL
    STA [proj_active+2],AL
    STA [proj_active+3],AL
    STA [snd_timer],AL
    STA [cloud_drift_a],AL
    STA [cloud_drift_b],AL
    MOV AL,#CLOUD_DRIFT_PERIOD
    STA [cloud_drift_cnt],AL

    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL

; ============================================================================
;  BUCLE PRINCIPAL
; ============================================================================
main_l:
    CALL leer_giro
    CALL leer_avance
    CALL leer_disparo
    CALL actualiza_proyectil
    CALL actualiza_dots
    CALL actualiza_sonido
    CALL actualiza_nubes

    CALL clr_shadow
    MOV AL,#0
    STA [ray_i],AL
ray_loop:
    LDA AL,[facing]
    LDA BL,[ray_i]
    ADD AL,BL
    SUB AL,#16              ; centra el abanico de 32 rayos en `facing`
    AND AL,#0x7F
    STA [ray_ang],AL

    CALL march_ray
    CALL render_column

    ; guarda el techo libre de esta columna (para la oclusion de las
    ; nubes, que se dibujan aparte tras el bucle -- ver dibuja_nubes)
    LDA AL,[y0]
    MOV BX,#y0_tbl
    LDA CL,[ray_i]
    ADD BX,CL
    STA [BX],AL

    ; distancia de la pared de esta columna, x4 (en cuartos de baldosa, la
    ; escala de [ov_q]): dibuja_objetos la usa DESPUES del bucle para
    ; recortar bolitas y proyectiles pixel a pixel tras las paredes
    LDA AL,[dist]
    SHL AL,#2
    MOV BX,#dist4_tbl
    LDA CL,[ray_i]
    ADD BX,CL
    STA [BX],AL

    LDA AL,[ray_i]
    ADD AL,#1
    STA [ray_i],AL
    CMP AL,#FOV_RAYS
    JMPNZ ray_loop

    CALL dibuja_nubes
    CALL dibuja_objetos
    CALL blit
    MOV AL,#2
    CALL frame_wait
    JMP main_l

; ============================================================================
;  CONTROL: giro (DIRECCION) y avance (DATOS)
; ============================================================================

; --- leer_giro: gira `facing` segun el sentido del encoder DIRECCION -------
leer_giro:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_prev],CL
    CMP AL,#0
    JMPZ lg_d
    AND AL,#0x80
    JMPNZ gira_izq
gira_der:
    LDA AL,[facing]
    ADD AL,#TURN_STEP
    AND AL,#0x7F
    STA [facing],AL
    JMP lg_d
gira_izq:
    LDA AL,[facing]
    SUB AL,#TURN_STEP
    AND AL,#0x7F
    STA [facing],AL
lg_d:
    RET

; --- leer_avance: mueve al jugador segun el sentido del encoder DATOS,
; sin atravesar paredes (si la baldosa de destino es pared, no se mueve) ---
leer_avance:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_prev],CL
    CMP AL,#0
    JMPZ la_d
    AND AL,#0x80
    JMPNZ mueve_atras
mueve_adelante:
    CALL buscar_mov
    JMP la_aplica
mueve_atras:
    CALL buscar_mov
    LDA AL,[mv_dx]
    NOT AL
    ADD AL,#1
    STA [mv_dx],AL
    LDA AL,[mv_dy]
    NOT AL
    ADD AL,#1
    STA [mv_dy],AL
la_aplica:
    LDA AL,[player_x]
    LDA BL,[mv_dx]
    ADD AL,BL
    STA [try_x],AL
    LDA AL,[player_y]
    LDA BL,[mv_dy]
    ADD AL,BL
    STA [try_y],AL

    LDA AL,[try_x]
    SHR AL,#4
    MOV CL,AL
    LDA AL,[try_y]
    SHR AL,#4
    MOV CH,AL
    CALL es_pared
    CMP AL,#0
    JMPNZ la_d              ; pared en destino -> no mover

    LDA AL,[try_x]
    STA [player_x],AL
    LDA AL,[try_y]
    STA [player_y],AL
la_d:
    RET

; --- buscar_mov: [facing] -> [mv_dx],[mv_dy] (tabla move_tbl, escala 4) ----
buscar_mov:
    LDA AL,[facing]
    SHL AL                  ; offset = facing*2 (2 bytes/entrada)
    MOV CL,AL
    MOV BX,#move_tbl
    ADD BX,CL
    LDA AL,[BX]
    STA [mv_dx],AL
    INC BX
    LDA AL,[BX]
    STA [mv_dy],AL
    RET

; ============================================================================
;  PROYECTIL: "bola de fuego" disparada con cualquiera de los dos
;  pulsadores. Viaja en linea recta con la MISMA tabla/escala que los rayos
;  (ray_tbl), asi que su distancia recorrida (`proj_steps`) se puede
;  comparar directamente contra la distancia de pared de cualquier columna
;  ([dist], puesta por march_ray) sin conversion de unidades.
; ============================================================================

; --- leer_disparo: cualquiera de los dos pulsadores, con flanco (para que
; mantenerlo pulsado no dispare a cada vuelta del bucle) -------------------
leer_disparo:
    IN  AL,(P_DIR_BTN)
    STA [tmp1],AL
    LDA BL,[dir_btn_prev]
    LDA CL,[tmp1]
    STA [dir_btn_prev],CL
    CMP CL,#0
    JMPZ ld2_dat
    CMP BL,#0
    JMPNZ ld2_dat
    CALL dispara
ld2_dat:
    IN  AL,(P_DAT_BTN)
    STA [tmp1],AL
    LDA BL,[dat_btn_prev]
    LDA CL,[tmp1]
    STA [dat_btn_prev],CL
    CMP CL,#0
    JMPZ ld2_d
    CMP BL,#0
    JMPNZ ld2_d
    CALL dispara
ld2_d:
    RET

; --- dispara: busca el primer slot libre (proj_active[i]=0, i=0..3) y arma
; ahi el proyectil, desde (player_x,player_y) hacia [facing]; si los
; PROJ_COUNT estan ocupados, ignora la pulsacion ---------------------------
dispara:
    MOV AL,#0
    STA [proj_i],AL
dsp_find:
    MOV BX,#proj_active
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ dsp_found
    LDA AL,[proj_i]
    ADD AL,#1
    STA [proj_i],AL
    CMP AL,#PROJ_COUNT
    JMPNZ dsp_find
    RET                      ; los PROJ_COUNT estan ocupados
dsp_found:
    MOV AL,#1
    STA [BX],AL              ; proj_active[proj_i] = 1 (BX ya apunta ahi)

    LDA AL,[facing]
    MOV BX,#proj_launch_facing
    CALL proj_field_addr
    STA [BX],AL

    MOV AL,#0
    MOV BX,#proj_steps
    CALL proj_field_addr
    STA [BX],AL

    LDA AL,[facing]
    SHL AL                  ; offset = facing*2 (move_tbl, 2 bytes/entrada:
                              ; 1/4 de baldosa por fotograma, para que se
                              ; vea volar en vez de cruzar el mapa de golpe)
    MOV CL,AL
    MOV BX,#move_tbl
    ADD BX,CL
    LDA AL,[BX]
    STA [dsp_dx],AL
    INC BX
    LDA AL,[BX]
    STA [dsp_dy],AL

    LDA AL,[dsp_dx]
    MOV BX,#proj_dx
    CALL proj_field_addr
    STA [BX],AL
    LDA AL,[dsp_dy]
    MOV BX,#proj_dy
    CALL proj_field_addr
    STA [BX],AL

    LDA AL,[player_x]
    MOV BX,#proj_rx
    CALL proj_field_addr
    STA [BX],AL
    LDA AL,[player_y]
    MOV BX,#proj_ry
    CALL proj_field_addr
    STA [BX],AL

    MOV AL,#SND_SWEEP_FRAMES
    STA [snd_timer],AL
    MOV AL,#lo(SND_FREQ_START)
    STA [snd_freq_lo],AL
    MOV AL,#hi(SND_FREQ_START)
    STA [snd_freq_hi],AL
    RET

; --- proj_field_addr: BX debe traer ya la base de un array proj_* (uno de
; PROJ_COUNT bytes, uno por proyectil); a la vuelta, BX = esa base +
; [proj_i]. Usada por dispara/actualiza_proyectil/ray_loop para acceder al
; slot "actual" sin repetir la aritmetica de puntero cada vez --------------
proj_field_addr:
    LDA CL,[proj_i]
    ADD BX,CL
    RET

; --- actualiza_proyectil: recorre los PROJ_COUNT slots; el que este activo
; avanza un paso (misma escala que march_ray), comprueba si choco con una
; pared y calcula en que columna de pantalla (si alguna) le toca aparecer
; este fotograma segun hacia donde mire ahora el jugador --------------------
actualiza_proyectil:
    MOV AL,#0
    STA [proj_i],AL
apr_loop:
    MOV BX,#proj_active
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ apr_next

    MOV BX,#proj_dx
    CALL proj_field_addr
    LDA AL,[BX]
    STA [apr_dx],AL
    MOV BX,#proj_dy
    CALL proj_field_addr
    LDA AL,[BX]
    STA [apr_dy],AL

    MOV BX,#proj_rx
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,[apr_dx]
    STA [BX],AL
    MOV BX,#proj_ry
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,[apr_dy]
    STA [BX],AL

    MOV BX,#proj_steps
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,#1
    STA [BX],AL
    STA [apr_steps],AL

    MOV BX,#proj_rx
    CALL proj_field_addr
    LDA AL,[BX]
    SHR AL,#4
    STA [apr_tx],AL          ; tile x en memoria: proj_field_addr usa CL,
                              ; no se puede dejar ahi entre dos llamadas
    MOV BX,#proj_ry
    CALL proj_field_addr
    LDA AL,[BX]
    SHR AL,#4
    MOV CH,AL
    LDA CL,[apr_tx]

apr_chk_wall:
    CALL es_pared
    CMP AL,#0
    JMPNZ apr_stop
    LDA AL,[apr_steps]
    CMP AL,#(MAX_STEPS*4)
    JMPNC apr_stop
    JMP apr_next
apr_stop:
    MOV AL,#0
    MOV BX,#proj_active
    CALL proj_field_addr
    STA [BX],AL
    ; golpe grave al chocar: que se oiga DONDE acaba el disparo
    MOV AL,#0
    STA [snd_timer],AL       ; corta el silbido del disparo si seguia
    MOV AL,#8
    OUT (P_SND_DUR),AL
    MOV AL,#36
    OUT (P_SND_NOTE),AL
    JMP apr_next

apr_next:
    LDA AL,[proj_i]
    ADD AL,#1
    STA [proj_i],AL
    CMP AL,#PROJ_COUNT
    JMPNZ apr_loop
    RET

; ============================================================================
;  BOLITAS RECOLECTABLES; ============================================================================
;  BOLITAS RECOLECTABLES: DOT_COUNT posiciones fijas por nivel (ver la
;  cabecera de constantes). Cada fotograma se recalcula su angulo/
;  visibilidad/distancia respecto al jugador (calc_dot_angle, igual
;  clasificacion en 8 octantes que usaba el enemigo de la version anterior
;  de este programa) y se comprueba si el jugador la ha recogido.
; ============================================================================

; --- actualiza_dots: punto de entrada, llamado una vez por fotograma desde
; main_l -- para cada bolita activa: calcula su angulo/distancia respecto
; al jugador, la recoge si esta lo bastante cerca (y arranca level_passed
; si era la ultima) y, si no, guarda su visibilidad/columna/distancia de
; este fotograma en los arrays dot_vis/dot_rayi/dot_steps_arr para que
; ray_loop (mas arriba) sepa si dibujarla en cada columna -----------------
actualiza_dots:
    MOV AL,#0
    STA [dot_i],AL
ad_loop:
    MOV BX,#dot_active
    LDA CL,[dot_i]
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ad_mark_invis      ; inactiva (ya recogida) -- no se dibuja

    MOV BX,#dot_x
    LDA CL,[dot_i]
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_x],AL
    MOV BX,#dot_y
    LDA CL,[dot_i]
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_y],AL

    CALL calc_dot_deltas     ; -> dot_adx/dot_ady/dot_xneg/dot_yneg

    ; recogida: menos de DOT_TOUCH_DIST px en los DOS ejes (distancia real,
    ; no "misma baldosa" -- igual criterio que usaba el enemigo antes)
    LDA AL,[dot_adx]
    CMP AL,#DOT_TOUCH_DIST
    JMPNC ad_no_pick
    LDA AL,[dot_ady]
    CMP AL,#DOT_TOUCH_DIST
    JMPNC ad_no_pick
    CALL dot_pickup
    JMP ad_mark_invis        ; recogida este mismo fotograma -> no se dibuja

ad_no_pick:
ad_mark_invis:
ad_next:
    LDA AL,[dot_i]
    ADD AL,#1
    STA [dot_i],AL
    CMP AL,#DOT_COUNT
    JMPNZ ad_loop
    RET

; --- calc_dot_deltas: (cur_dot_x,cur_dot_y) vs (player_x,player_y) ->
; magnitudes [dot_adx]/[dot_ady] (0-255, siempre correctas) y flags
; [dot_xneg]/[dot_yneg] (1 = la bolita esta al oeste/norte del jugador) --
; mismo truco de comparar con CMP antes de restar (en vez del atajo de
; mirar el bit alto de una resta) que usaba calc_ska_deltas del enemigo,
; necesario porque el mapa mide 256 unidades de lado en cada eje -----------
calc_dot_deltas:
    LDA AL,[cur_dot_x]
    LDA BL,[player_x]
    CMP AL,BL
    JMPC cdd_xneg          ; cur_dot_x < player_x
    MOV AL,#0
    STA [dot_xneg],AL
    LDA AL,[cur_dot_x]
    LDA BL,[player_x]
    SUB AL,BL
    STA [dot_adx],AL
    JMP cdd_y
cdd_xneg:
    MOV AL,#1
    STA [dot_xneg],AL
    LDA AL,[player_x]
    LDA BL,[cur_dot_x]
    SUB AL,BL
    STA [dot_adx],AL
cdd_y:
    LDA AL,[cur_dot_y]
    LDA BL,[player_y]
    CMP AL,BL
    JMPC cdd_yneg          ; cur_dot_y < player_y
    MOV AL,#0
    STA [dot_yneg],AL
    LDA AL,[cur_dot_y]
    LDA BL,[player_y]
    SUB AL,BL
    STA [dot_ady],AL
    RET
cdd_yneg:
    MOV AL,#1
    STA [dot_yneg],AL
    LDA AL,[player_y]
    LDA BL,[cur_dot_y]
    SUB AL,BL
    STA [dot_ady],AL
    RET

; --- dot_pickup:; --- dot_pickup: el jugador ha recogido la bolita [dot_i] -- la desactiva,
; resta 1 de [dot_remaining], y suena un pitido corto (reutiliza el mismo
; mecanismo de silbido que dispara). Si era la ultima, arranca level_passed
dot_pickup:
    MOV AL,#0
    MOV BX,#dot_active
    LDA CL,[dot_i]
    ADD BX,CL
    STA [BX],AL

    LDA AL,[dot_remaining]
    SUB AL,#1
    STA [dot_remaining],AL

    ; "ding": una nota aguda corta, bien distinta del silbido descendente
    ; del disparo y del golpe grave del choque
    MOV AL,#0
    STA [snd_timer],AL
    MOV AL,#12
    OUT (P_SND_DUR),AL
    MOV AL,#88               ; MI6
    OUT (P_SND_NOTE),AL
    CALL show_hud

    LDA AL,[dot_remaining]
    CMP AL,#0
    JMPNZ dp_d
    CALL level_passed
dp_d:
    RET

; --- level_passed: se han recogido todas las bolitas del nivel -- mensaje
; en pantalla + un jingle corto de 3 notas ascendentes (bloqueante, igual
; patron que el "dos notas" de docs/isa.md), y carga el SIGUIENTE de los
; MAP_COUNT mapas prehechos (en bucle, ver load_level) ---------------------
level_passed:
    CALL clst
    MOV BX,#h_level_passed
    MOV CX,#0x0303
    CALL puts

    MOV AL,#8
    OUT (P_SND_DUR),AL
    MOV AL,#72             ; DO5
    OUT (P_SND_NOTE),AL
    MOV AL,#12
    CALL frame_wait
    MOV AL,#8
    OUT (P_SND_DUR),AL
    MOV AL,#76             ; MI5
    OUT (P_SND_NOTE),AL
    MOV AL,#12
    CALL frame_wait
    MOV AL,#8
    OUT (P_SND_DUR),AL
    MOV AL,#79             ; SOL5
    OUT (P_SND_NOTE),AL
    MOV AL,#40
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL     ; silencio

    LDA AL,[map_idx]
    ADD AL,#1
    CMP AL,#MAP_COUNT
    JMPNZ lp_store
    MOV AL,#0
lp_store:
    STA [map_idx],AL
    CALL load_level
    CALL clst
    CALL show_hud
    RET

; --- load_level:; --- load_level: copia el mapa ROM de [map_idx] al buffer en RAM `mapa`,
; puebla dot_x/dot_y/dot_active desde la tabla de bolitas de ese mismo
; nivel, reinicia [dot_remaining] y coloca al jugador (posicion y facing)
; en el punto de partida de ese mapa -- llamada al arrancar y de nuevo al
; final de level_passed cuando se agotan las bolitas de un nivel ----------
load_level:
    LDA AL,[map_idx]
    SHL AL                  ; offset = map_idx*2 (2 bytes/puntero)
    MOV CL,AL
    MOV BX,#MAP_PTRS
    ADD BX,CL
    LDA AL,[BX]
    STA [lvl_lo],AL
    INC BX
    LDA AL,[BX]
    STA [lvl_hi],AL

    LDA BL,[lvl_lo]
    LDA BH,[lvl_hi]          ; BX = mapa ROM de este nivel (32 bytes)
    MOV DX,#mapa
    MOV CX,#32
    MOVB                     ; copia los 32 bytes del mapa de una vez

    LDA AL,[map_idx]
    SHL AL
    MOV CL,AL
    MOV BX,#DOT_DATA_PTRS
    ADD BX,CL
    LDA AL,[BX]
    STA [lvl_lo],AL
    INC BX
    LDA AL,[BX]
    STA [lvl_hi],AL

    LDA BL,[lvl_lo]
    LDA BH,[lvl_hi]           ; BX = tabla de bolitas de este nivel (x,y...)
    MOV DX,#dot_x
    MOV CX,#dot_y
    MOV AL,#0
    STA [ll_cnt],AL
ll_dot_copy:
    LDA AL,[BX]              ; x
    STA [DX],AL
    INC BX
    LDA AL,[BX]              ; y
    STA [CX],AL
    INC BX
    INC DX
    INC CX
    LDA AL,[ll_cnt]
    ADD AL,#1
    STA [ll_cnt],AL
    CMP AL,#DOT_COUNT
    JMPNZ ll_dot_copy

    MOV AL,#1
    MOV BX,#dot_active
    MOV CL,#0
ll_dot_act:
    STA [BX],AL
    INC BX
    ADD CL,#1
    CMP CL,#DOT_COUNT
    JMPNZ ll_dot_act

    MOV AL,#DOT_COUNT
    STA [dot_remaining],AL

    MOV BX,#MAP_SPAWN_X
    LDA CL,[map_idx]
    ADD BX,CL
    LDA AL,[BX]
    STA [player_x],AL
    MOV BX,#MAP_SPAWN_Y
    LDA CL,[map_idx]
    ADD BX,CL
    LDA AL,[BX]
    STA [player_y],AL
    MOV AL,#0
    STA [facing],AL
    RET


; ============================================================================
;  CIELO: CLOUD_COUNT nubes huecas, cada una con angulo de mundo fijo mas
;  una deriva compartida que se mueve sola con el tiempo (ver la cabecera).
; ============================================================================

; --- actualiza_nubes: cada CLOUD_DRIFT_PERIOD fotogramas, adelanta un paso
; la deriva de cada tipo de nube (resta CLOUD_DRIFT_STEP_A/B, con envoltura
; de angulo) -- las alargadas (B) avanzan mas por paso que las rechonchas
; (A), asi que se ven mas rapidas aunque ambas actualicen al mismo ritmo --
actualiza_nubes:
    LDA AL,[cloud_drift_cnt]
    CMP AL,#0
    JMPZ an_reset
    SUB AL,#1
    STA [cloud_drift_cnt],AL
    RET
an_reset:
    MOV AL,#CLOUD_DRIFT_PERIOD
    STA [cloud_drift_cnt],AL
    LDA AL,[cloud_drift_a]
    SUB AL,#CLOUD_DRIFT_STEP_A
    AND AL,#0x7F
    STA [cloud_drift_a],AL
    LDA AL,[cloud_drift_b]
    SUB AL,#CLOUD_DRIFT_STEP_B
    AND AL,#0x7F
    STA [cloud_drift_b],AL
    RET

; --- dibuja_nubes: recorre las CLOUD_COUNT nubes; para cada una, calcula
; su columna central (misma formula de angulo que los proyectiles) y
; comprueba [y0_tbl] de esa columna para decidir si la pared la tapa. Se
; llama UNA vez por fotograma, despues de terminar ray_loop (no columna a
; columna: cada nube es mucho mas ancha que una franja de 4 px) ------------
dibuja_nubes:
    MOV AL,#0
    STA [cloud_i],AL
dn_loop:
    ; deriva segun el tipo (par=rechoncha=lenta, impar=alargada=rapida) --
    ; se necesita ANTES de calcular el angulo, no solo para elegir la
    ; forma mas abajo, porque la deriva afecta a la visibilidad misma
    LDA AL,[cloud_i]
    AND AL,#1
    CMP AL,#0
    JMPNZ dn_drift_b
    LDA AL,[cloud_drift_a]
    JMP dn_drift_have
dn_drift_b:
    LDA AL,[cloud_drift_b]
dn_drift_have:
    STA [cloud_drift_cur],AL

    LDA CL,[cloud_i]
    MOV BX,#cloud_angle_tbl
    ADD BX,CL
    LDA AL,[BX]
    LDA BL,[cloud_drift_cur]
    ADD AL,BL
    AND AL,#0x7F
    LDA BL,[facing]
    SUB AL,BL
    AND AL,#0x7F
    CMP AL,#16
    JMPC dn_lo
    CMP AL,#112
    JMPNC dn_hi
    JMP dn_next             ; fuera de la ventana de 32 rayos: no se dibuja
dn_lo:
    ADD AL,#16
    JMP dn_have
dn_hi:
    SUB AL,#112
dn_have:
    STA [cloud_ray_i],AL

    MOV BX,#y0_tbl
    LDA CL,[cloud_ray_i]
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#CLOUD_MIN_Y0
    JMPC dn_next            ; la pared de la columna central ya la tapa

    LDA AL,[cloud_ray_i]
    SHL AL,#2                ; ancla en pixeles: x = ray_i*4
    STA [cloud_anchor_x],AL

    ; forma segun la paridad del indice: rechoncha (par) / alargada (impar)
    LDA AL,[cloud_i]
    AND AL,#1
    CMP AL,#0
    JMPNZ dn_shape_b
    MOV AL,#lo(cloud_shape_a)
    STA [cloud_shape_lo],AL
    MOV AL,#hi(cloud_shape_a)
    STA [cloud_shape_hi],AL
    MOV AL,#CLOUD_SHAPE_A_LEN
    STA [cloud_shape_len],AL
    JMP dn_shape_done
dn_shape_b:
    MOV AL,#lo(cloud_shape_b)
    STA [cloud_shape_lo],AL
    MOV AL,#hi(cloud_shape_b)
    STA [cloud_shape_hi],AL
    MOV AL,#CLOUD_SHAPE_B_LEN
    STA [cloud_shape_len],AL
dn_shape_done:
    CALL dibuja_nube_grande
dn_next:
    LDA AL,[cloud_i]
    ADD AL,#1
    STA [cloud_i],AL
    CMP AL,#CLOUD_COUNT
    JMPNZ dn_loop
    RET

; --- dibuja_nube_grande: estampa cada punto de la forma elegida por el
; llamador ([cloud_shape_lo]/[cloud_shape_hi], [cloud_shape_len] pares
; dx,dy) en ([cloud_anchor_x]+dx, CLOUD_TOP_ROW+dy), saltando los que
; caigan fuera de las 128 columnas de pantalla (la nube es mucho mas ancha
; que la franja de 4 px de un solo rayo, asi que su lado derecho puede
; salirse si la columna central esta cerca del borde) -----------------------
dibuja_nube_grande:
    MOV AL,#0
    STA [cloud_pi],AL
dng_l:
    LDA CL,[cloud_pi]
    SHL CL                    ; offset = indice*2 (2 bytes/punto)
    LDA BL,[cloud_shape_lo]
    LDA BH,[cloud_shape_hi]
    ADD BX,CL
    LDA AL,[BX]
    STA [cloud_dx],AL
    INC BX
    LDA AL,[BX]
    STA [cloud_dy],AL

    LDA AL,[cloud_anchor_x]
    LDA BL,[cloud_dx]
    ADD AL,BL
    CMP AL,#128
    JMPNC dng_next           ; fuera de pantalla por la derecha: saltar
    STA [px_x],AL

    MOV AL,#CLOUD_TOP_ROW
    LDA BL,[cloud_dy]
    ADD AL,BL
    STA [px_y],AL

    CALL calc_pix
    CALL shadow_set_pix
dng_next:
    LDA AL,[cloud_pi]
    ADD AL,#1
    STA [cloud_pi],AL
    LDA AL,[cloud_pi]
    LDA BL,[cloud_shape_len]
    CMP AL,BL
    JMPNZ dng_l
    RET

; --- calc_pix: de (px_x,px_y) saca en pix_lo/pix_hi el offset dentro de
; `shadow` (mismo formato que calc_shadow_addr, pagina+fila*16+bytecol) y
; en pix_mask la mascara del bit EXACTO (no medio nibble como el proyectil
; ni un nibble entero como la pared) -- igual patron que cubo.asm/demo.asm -
calc_pix:
    LDA AL,[px_y]
    AND AL,#0x0F
    SHL AL,#4
    LDA BL,[px_x]
    SHR BL,#3
    ADD AL,BL
    STA [pix_lo],AL
    LDA AL,[px_y]
    SHR AL,#4
    STA [pix_hi],AL
    LDA BL,[px_x]
    AND BL,#0x07
    MOV DH,#0x80
cpx_m:
    CMP BL,#0
    JMPZ cpx_d
    SHR DH
    SUB BL,#1
    JMP cpx_m
cpx_d:
    STA [pix_mask],DH
    RET

; --- shadow_set_pix: enciende en `shadow` el bit de pix_lo/pix_hi/pix_mask -
shadow_set_pix:
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

; --- actualiza_sonido: silbido descendente mientras dura [snd_timer] -----
actualiza_sonido:
    LDA AL,[snd_timer]
    CMP AL,#0
    JMPZ as_d
    SUB AL,#1
    STA [snd_timer],AL

    LDA AL,[snd_freq_lo]
    OUT (P_SND_FREQ_LO),AL
    LDA AL,[snd_freq_hi]
    OUT (P_SND_FREQ_HI),AL

    LDA AL,[snd_freq_lo]
    SUB AL,#SND_FREQ_STEP
    STA [snd_freq_lo],AL
    JMPNC as_freq_ok
    LDA AL,[snd_freq_hi]
    SUB AL,#1
    STA [snd_freq_hi],AL
as_freq_ok:
    LDA AL,[snd_timer]
    CMP AL,#0
    JMPNZ as_d
    MOV AL,#0
    OUT (P_SND_NOTE),AL     ; se acabo el silbido -> silencio
as_d:
    RET

; ============================================================================
;  MAPA: 16x16 baldosas, 1=pared 0=libre, 2 bytes/fila (bit7=columna 0)
; ============================================================================

; --- es_pared: CL=baldosa x (0-15), CH=baldosa y (0-15) -> AL=1 si pared ---
es_pared:
    MOV AL,CH
    SHL AL                  ; fila*2 = byte0 de esa fila dentro de `mapa`
    MOV BX,#mapa
    ADD BX,AL
    CMP CL,#8
    JMPNC ep_hi
    LDA AL,[BX]             ; columna 0-7 -> byte0
    MOV DL,CL               ; bit = 7-x
    JMP ep_bit
ep_hi:
    INC BX
    LDA AL,[BX]             ; columna 8-15 -> byte1
    MOV DL,CL
    SUB DL,#8               ; bit = 7-(x-8)
ep_bit:
    MOV DH,#0x80
ep_shf:
    CMP DL,#0
    JMPZ ep_test
    SHR DH
    SUB DL,#1
    JMP ep_shf
ep_test:
    AND AL,DH
    CMP AL,#0
    JMPZ ep_libre
    MOV AL,#1
    RET
ep_libre:
    MOV AL,#0
    RET

; ============================================================================
;  MARCHA DE RAYOS
; ============================================================================

; --- march_ray: desde (player_x,player_y) en direccion [ray_ang], hasta
; chocar con una pared o agotar MAX_STEPS -> [dist] = pasos dados ----------
march_ray:
    LDA CL,[ray_ang]
    SHL CL                  ; offset = ang*2
    MOV BX,#ray_tbl
    ADD BX,CL
    LDA AL,[BX]
    STA [rdx],AL
    INC BX
    LDA AL,[BX]
    STA [rdy],AL

    LDA AL,[player_x]
    STA [rx],AL
    LDA AL,[player_y]
    STA [ry],AL
    MOV AL,#0
    STA [step_cnt],AL
mr_loop:
    LDA AL,[rx]
    LDA BL,[rdx]
    ADD AL,BL
    STA [rx],AL
    LDA AL,[ry]
    LDA BL,[rdy]
    ADD AL,BL
    STA [ry],AL

    LDA AL,[step_cnt]
    ADD AL,#1
    STA [step_cnt],AL

    LDA AL,[rx]
    SHR AL,#4
    MOV CL,AL
    LDA AL,[ry]
    SHR AL,#4
    MOV CH,AL
    CALL es_pared
    CMP AL,#0
    JMPNZ mr_hit

    LDA AL,[step_cnt]
    CMP AL,#MAX_STEPS
    JMPNC mr_hit
    JMP mr_loop
mr_hit:
    LDA AL,[step_cnt]
    STA [dist],AL
    RET

; ============================================================================
;  DIBUJO: una franja vertical de 4 px por rayo, altura segun [dist]
; ============================================================================

; --- render_column: usa [ray_i] y [dist] -> dibuja en `shadow` ------------
render_column:
    LDA AL,[ray_i]
    SHR AL
    STA [byte_col],AL
    LDA AL,[ray_i]
    AND AL,#1
    CMP AL,#0
    JMPZ rc_hi
    MOV AL,#0x0F
    STA [nibble],AL
    JMP rc_have
rc_hi:
    MOV AL,#0xF0
    STA [nibble],AL
rc_have:
    LDA CL,[dist]
    MOV BX,#height_tbl
    ADD BX,CL
    LDA AL,[BX]
    STA [wall_h],AL

    LDA CL,[dist]
    MOV BX,#shade_by_dist
    ADD BX,CL
    LDA AL,[BX]
    STA [shade_level],AL

    LDA AL,[wall_h]
    SHR AL
    MOV BL,AL
    MOV AL,#32
    SUB AL,BL
    STA [y0],AL
    LDA BL,[wall_h]
    ADD AL,BL
    SUB AL,#1
    STA [y1],AL

    CALL wall_row_fill
    RET

; --- wall_row_fill: rellena en `shadow` las filas [y0]..[y1] en la columna-
; byte [byte_col], con la trama de [shade_level] (0=negro completo .. 4=
; blanco completo, ver calc_shade_mask) recortada al lado [nibble] (0xF0
; alta / 0x0F baja) de esta columna -----------------------------------------
wall_row_fill:
    LDA AL,[y0]
    STA [rowy],AL
wrf_l:
    CALL calc_shade_mask
    CALL calc_shadow_addr

    LDA AL,[BX]
    LDA DL,[shade_mask]
    OR  AL,DL
    STA [BX],AL

    LDA AL,[rowy]
    LDA BL,[y1]
    CMP AL,BL
    JMPZ wrf_d
    LDA AL,[rowy]
    ADD AL,#1
    STA [rowy],AL
    JMP wrf_l
wrf_d:
    RET

; --- calc_shadow_addr: usando [rowy] y [byte_col], deja en BX el puntero
; al byte de `shadow` correspondiente (compartido por paredes y proyectil) -
calc_shadow_addr:
    LDA AL,[rowy]
    AND AL,#0x0F
    SHL AL,#4
    LDA BL,[byte_col]
    ADD AL,BL
    STA [wrf_off],AL
    LDA AL,[rowy]
    SHR AL,#4
    STA [wrf_pag],AL

    MOV BX,#shadow
    LDA CL,[wrf_off]
    ADD BX,CL
    LDA AL,[wrf_pag]
    ADD BH,AL
    RET

; --- calc_shade_mask: la mascara de esta fila segun [shade_level] (0-4),
; la paridad de [rowy] y el lado de columna en [nibble] -- alterna el
; patron de puntos fila a fila para que se note como una trama, no una
; franja lisa mas tenue (la pantalla es de 1 bit, no hay grises de verdad:
; esto es "dithering" ordenado con 4 niveles de densidad entre negro y
; blanco) -------------------------------------------------------------------
calc_shade_mask:
    LDA AL,[shade_level]
    SHL AL,#2                ; offset = nivel*4
    MOV CL,AL
    LDA AL,[rowy]
    AND AL,#1
    SHL AL                  ; +0 (fila par) o +2 (fila impar)
    ADD CL,AL
    LDA AL,[nibble]
    CMP AL,#0xF0
    JMPZ csm_hi
    ADD CL,#1                ; +1 si es el nibble bajo
csm_hi:
    MOV BX,#shade_tbl
    ADD BX,CL
    LDA AL,[BX]
    STA [shade_mask],AL
    RET

; ============================================================================
;  DOBLE BUFFER (igual patron que cubo.asm/fzero.asm/roto_debug.asm)
; ============================================================================

; --- idx_ptr:  BX = (BX inicial) + CL, propagando el acarreo a mano --------
idx_ptr:
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
; clr_shadow: antes un bucle de 1024 pasadas (STA+acarreo+cuenta), ahora
; solo pone a 0 el PRIMER byte y usa MOVB con origen/destino solapados en
; 1 (BX=shadow, DX=shadow+1) para que ese unico 0 se propague en cascada
; a los 1023 bytes restantes -- MOVB copia [BX+i]->[DX+i] con i creciente,
; asi que cada byte lee el que acaba de escribir el paso anterior (ver
; docs/isa.md SS4d: MOVB no es memmove-seguro con origen<destino
; solapados, y aqui es EXACTAMENTE eso lo que se aprovecha a proposito).
clr_shadow:
    MOV AL,#0
    STA [shadow],AL
    MOV BX,#shadow
    MOV DX,#shadow+1
    MOV CX,#0x03FF ; CX = 1023 (el resto del buffer de 1024)
    MOVB
    RET

; --- blit:  copia `shadow` al framebuffer real, solo lo que cambie --------
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
;  BOLITAS Y PROYECTILES EN PANTALLA: "dianas" de circulos concentricos
;  (anillos de 2 px que alternan encendido/apagado), con el tamano segun la
;  distancia. Se dibujan DESPUES de paredes y nubes, recortadas pixel a
;  pixel contra la pared de cada columna (dist4_tbl): si una pared esta mas
;  cerca, tapa esa parte de la diana. Un patron de anillos se distingue a la
;  vez sobre paredes blancas, tramadas y sobre el fondo negro.
; ============================================================================

; --- dibuja_objetos: todas las bolitas activas (apoyadas en el suelo) y
; todos los proyectiles en vuelo (a la altura de los ojos) -----------------
dibuja_objetos:
    MOV AL,#0
    STA [ob_i],AL
do_dot_l:
    MOV BX,#dot_active
    LDA CL,[ob_i]
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ do_dot_next
    MOV BX,#dot_x
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_x],AL
    MOV BX,#dot_y
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_y],AL
    CALL obj_project
    LDA AL,[ov_vis]
    CMP AL,#0
    JMPZ do_dot_next
    ; centro: apoyada en el suelo -- el borde de abajo de la pared a esa
    ; distancia (32 + alto/2 - 1) menos el radio
    LDA AL,[ov_q]
    SHR AL,#2               ; baldosas
    CMP AL,#21
    JMPC do_dot_d
    MOV AL,#20
do_dot_d:
    MOV CL,AL
    MOV BX,#height_tbl
    ADD BX,CL
    LDA AL,[BX]
    SHR AL
    ADD AL,#31
    LDA BL,[be_r]
    SUB AL,BL
    STA [be_cy],AL
    CALL draw_bullseye
do_dot_next:
    LDA AL,[ob_i]
    ADD AL,#1
    STA [ob_i],AL
    CMP AL,#DOT_COUNT
    JMPNZ do_dot_l

    MOV AL,#0
    STA [ob_i],AL
do_pr_l:
    MOV BX,#proj_active
    LDA CL,[ob_i]
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ do_pr_next
    MOV BX,#proj_rx
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_x],AL
    MOV BX,#proj_ry
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_dot_y],AL
    CALL obj_project
    LDA AL,[ov_vis]
    CMP AL,#0
    JMPZ do_pr_next
    MOV AL,#PROJ_ROW
    STA [be_cy],AL
    CALL draw_bullseye
do_pr_next:
    LDA AL,[ob_i]
    ADD AL,#1
    STA [ob_i],AL
    CMP AL,#PROJ_COUNT
    JMPNZ do_pr_l
    RET

; --- obj_project: objeto en (cur_dot_x,cur_dot_y) visto desde el jugador.
; Sale [ov_vis] (1 = dentro de los 90 grados de vista), [be_cx] (columna de
; pantalla 0..127), [ov_q] (distancia en cuartos de baldosa, misma escala
; que dist4_tbl) y [be_r] (radio de la diana segun esa distancia).
; Angulo de verdad (no por octantes): atan(menor/mayor) con MUL/DIV y la
; tabla ATAN32, en unidades de 256 por vuelta (2 px de pantalla por unidad,
; el doble de fino que la rejilla de 4 px de los rayos). --------------------
obj_project:
    CALL calc_dot_deltas     ; -> dot_adx/dot_ady/dot_xneg/dot_yneg
    LDA AL,[dot_adx]
    LDA BL,[dot_ady]
    MOV AH,#1                ; 1 = domina X
    CMP AL,BL
    JMPNC op_ord
    MOV AH,#0
    MOV CL,AL                ; intercambia: AL = mayor, BL = menor
    MOV AL,BL
    MOV BL,CL
op_ord:
    STA [ov_mx],AL
    STA [ov_mn],BL
    STA [ov_xdom],AH
    ; distancia ~ mayor + 3/8 menor, en cuartos de baldosa (/4)
    MOV AL,BL
    MOV BL,#3
    MUL BL
    SHR AL,#3
    SHL AH,#5
    OR  AL,AH                ; (menor*3) >> 3
    SHR AL,#2
    STA [ov_q],AL
    LDA AL,[ov_mx]
    SHR AL,#2
    LDA BL,[ov_q]
    ADD AL,BL
    STA [ov_q],AL
    ; radio segun las medias baldosas de distancia
    SHR AL
    CMP AL,#41
    JMPC op_rd
    MOV AL,#40
op_rd:
    MOV CL,AL
    MOV BX,#OBJ_R
    ADD BX,CL
    LDA AL,[BX]
    STA [be_r],AL
    ; angulo dentro del cuadrante (0..64 = 0..90 grados)
    LDA AL,[ov_mx]
    CMP AL,#0
    JMPZ op_a0
    LDA AL,[ov_mn]
    MOV BL,#32
    MUL BL                   ; AX = menor*32 (<= 8160)
    LDA BL,[ov_mx]
    DIV BL                   ; AL = menor*32/mayor, 0..32 (cabe siempre)
    MOV CL,AL
    MOV BX,#ATAN32
    ADD BX,CL
    LDA AL,[BX]
    LDA BL,[ov_xdom]
    CMP BL,#0
    JMPNZ op_quad
    MOV BL,AL
    MOV AL,#64
    SUB AL,BL                ; domina Y: 90 grados menos el angulo
    JMP op_quad
op_a0:
    MOV AL,#0
op_quad:
    ; cuadrante: x hacia el este, y hacia el sur (igual que ray_tbl)
    MOV BL,AL
    LDA AL,[dot_xneg]
    CMP AL,#0
    JMPZ op_xpos
    LDA AL,[dot_yneg]
    CMP AL,#0
    JMPNZ op_q3
    MOV AL,#128              ; oeste-sur: 180 - a
    SUB AL,BL
    JMP op_have
op_q3:
    MOV AL,#128              ; oeste-norte: 180 + a
    ADD AL,BL
    JMP op_have
op_xpos:
    LDA AL,[dot_yneg]
    CMP AL,#0
    JMPZ op_q1
    MOV AL,#0                ; este-norte: -a
    SUB AL,BL
    JMP op_have
op_q1:
    MOV AL,BL                ; este-sur: a
op_have:
    ; relativo a donde mira el jugador ([facing] va en 128 por vuelta)
    LDA BL,[facing]
    SHL BL
    SUB AL,BL
    ADD AL,#32               ; -32..31 -> 0..63 si esta dentro de la vista
    CMP AL,#64
    JMPC op_vis
    MOV AL,#0
    STA [ov_vis],AL
    RET
op_vis:
    SHL AL
    ADD AL,#1
    STA [be_cx],AL
    MOV AL,#1
    STA [ov_vis],AL
    RET

; --- draw_bullseye: diana de radio [be_r] (<= 15, OBJ_R llega a 12) centrada en ([be_cx],
; [be_cy]) en `shadow`; anillos de 2 px desde el centro, encendido/apagado
; alternos. Solo pinta los pixeles cuya columna tenga la pared MAS LEJOS
; que el objeto ([ov_q] < dist4_tbl[x/4]) ---------------------------------
draw_bullseye:
    LDA AL,[be_cy]
    LDA BL,[be_r]
    SUB AL,BL
    STA [be_y],AL
    MOV AL,BL
    SHL AL
    ADD AL,#1
    STA [be_n],AL            ; 2r+1 filas (y columnas)
    STA [be_rows],AL
be_row:
    LDA AL,[be_y]
    CMP AL,#64
    JMPNC be_row_next        ; fuera de pantalla (o "negativa", da la vuelta)
    ; |y - cy|
    LDA BL,[be_cy]
    SUB AL,BL
    JMPNN be_ady_ok
    NOT AL
    ADD AL,#1
be_ady_ok:
    SHL AL,#4
    STA [be_ady16],AL        ; fila de la tabla DIST16
    ; base de la fila en shadow: shadow + y*16
    LDA AL,[be_y]
    MOV BL,#16
    MUL BL
    STA [be_rb_lo],AL
    MOV AL,AH
    STA [be_rb_hi],AL
    ; columnas cx-r .. cx+r
    LDA AL,[be_cx]
    LDA BL,[be_r]
    SUB AL,BL
    STA [be_x],AL
    LDA AL,[be_n]
    STA [be_cols],AL
be_px:
    LDA AL,[be_x]
    CMP AL,#128
    JMPNC be_px_next
    ; recorte contra la pared de esta columna
    SHR AL,#2
    MOV CL,AL
    MOV BX,#dist4_tbl
    ADD BX,CL
    LDA BL,[BX]
    LDA AL,[ov_q]
    CMP AL,BL
    JMPNC be_px_next         ; la pared esta delante
    ; distancia al centro (tabla) -> dentro del circulo y en que anillo
    LDA AL,[be_x]
    LDA BL,[be_cx]
    SUB AL,BL
    JMPNN be_adx_ok
    NOT AL
    ADD AL,#1
be_adx_ok:
    LDA BL,[be_ady16]
    ADD AL,BL
    MOV CL,AL
    MOV BX,#DIST16
    ADD BX,CL
    LDA AL,[BX]
    LDA BL,[be_r]
    CMP BL,AL
    JMPC be_px_next          ; d > r: fuera del circulo
    SHR AL
    AND AL,#1
    STA [be_col],AL          ; 0 = anillo encendido, 1 = apagado
    ; byte y mascara del pixel
    MOV BX,#shadow
    LDA CL,[be_rb_lo]
    ADD BX,CL
    LDA CL,[be_rb_hi]
    ADD BH,CL
    LDA AL,[be_x]
    SHR AL,#3
    ADD BX,AL
    LDA AL,[be_x]
    AND AL,#7
    MOV CL,AL
    MOV DX,#MASK8
    ADD DX,CL
    LDA CL,[DX]
    LDA AL,[BX]
    LDA DL,[be_col]
    CMP DL,#0
    JMPNZ be_off
    OR  AL,CL
    STA [BX],AL
    JMP be_px_next
be_off:
    NOT CL
    AND AL,CL
    STA [BX],AL
be_px_next:
    LDA AL,[be_x]
    ADD AL,#1
    STA [be_x],AL
    LDA AL,[be_cols]
    SUB AL,#1
    STA [be_cols],AL
    JMPNZ be_px
be_row_next:
    LDA AL,[be_y]
    ADD AL,#1
    STA [be_y],AL
    LDA AL,[be_rows]
    SUB AL,#1
    STA [be_rows],AL
    JMPNZ be_row
    RET

; --- show_hud: "DOTS LEFT nn" en la fila 0 de texto ------------------------
show_hud:
    MOV BX,#h_dots
    MOV CX,#0x0000
    CALL puts
    LDA AL,[dot_remaining]
    MOV AH,#0
    MOV BL,#10
    DIV BL
    ADD AL,#'0'
    OUT (0x040A),AL
    MOV AL,AH
    ADD AL,#'0'
    OUT (0x040B),AL
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

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

; --- clst:  borra la capa de texto (0x0400..0x04FF) -------------------------
clst:
    MOV BX,#0x0400
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

; ============================================================================
;  DATOS  (justo despues del codigo -- ver programs/README.md)
; ============================================================================
dir_prev:   .space 1
dat_prev:   .space 1
dir_btn_prev: .space 1
dat_btn_prev: .space 1
facing:     .space 1    ; angulo del jugador, 0..127 (128 = vuelta completa)
player_x:   .space 1    ; posicion del jugador (0..255; baldosa = pos>>4)
player_y:   .space 1
try_x:      .space 1
try_y:      .space 1
mv_dx:      .space 1
mv_dy:      .space 1
tmp0:       .space 1
tmp1:       .space 1

ray_i:      .space 1    ; indice de rayo en curso (0..31)
ray_ang:    .space 1
rdx:        .space 1
rdy:        .space 1
rx:         .space 1
ry:         .space 1
step_cnt:   .space 1
dist:       .space 1

byte_col:   .space 1
nibble:     .space 1
wall_h:     .space 1
shade_level: .space 1
shade_mask:  .space 1
y0:         .space 1
y1:         .space 1
rowy:       .space 1
wrf_off:    .space 1
wrf_pag:    .space 1

; proyectiles: PROJ_COUNT slots, un byte por slot en cada tabla (indexado
; por [proj_i], ver proj_field_addr) -- angulo y distancia de cada uno se
; llevan por separado (proj_launch_facing[i] / proj_steps[i])
proj_i:       .space 1    ; slot "actual" durante los bucles per-proyectil
proj_active:  .space 4
proj_rx:      .space 4
proj_ry:      .space 4
proj_dx:      .space 4
proj_dy:      .space 4
proj_steps:   .space 4
proj_launch_facing: .space 4
proj_mask:    .space 1    ; escalar: buffer de dibujo transitorio (proyectil y nube)

; escalares de trabajo de dispara/actualiza_proyectil (no pueden vivir en
; CL/BL/BH: esos los usa proj_field_addr/idx_ptr entre un acceso y el
; siguiente al mismo slot)
dsp_dx:       .space 1
dsp_dy:       .space 1
apr_dx:       .space 1
apr_dy:       .space 1
apr_steps:    .space 1
apr_tx:       .space 1
apr_rayi:     .space 1

snd_timer:    .space 1
snd_freq_lo:  .space 1
snd_freq_hi:  .space 1

; bolitas recolectables: DOT_COUNT slots, un byte por slot en cada tabla
; (indexado por [dot_i], mismo patron que los proyectiles) -- posicion fija
; por nivel (dot_x/dot_y, copiadas de la ROM por load_level), y visibilidad/
; columna/distancia recalculadas cada fotograma por actualiza_dots para que
; ray_loop sepa si dibujar cada una en la columna que le toque
dot_x:        .space 10    ; DOT_COUNT -- literal, .space no admite constantes
dot_y:        .space 10
dot_active:   .space 10
dot_remaining: .space 1
dot_i:        .space 1    ; slot "actual" durante los bucles per-bolita

; escalares de trabajo de actualiza_dots/calc_dot_deltas/calc_dot_angle (no
; pueden vivir en CL/BL/BH: los usan idx_ptr/es_pared entre un acceso y el
; siguiente)
cur_dot_x: .space 1
cur_dot_y: .space 1
dot_xneg: .space 1   ; 1 = la bolita esta al oeste del jugador
dot_yneg: .space 1   ; 1 = la bolita esta al norte del jugador
dot_adx: .space 1
dot_ady: .space 1

; nivel actual: que mapa/bolitas hay cargados en RAM (ver load_level)
map_idx: .space 1
lvl_lo:  .space 1   ; escalares de trabajo de load_level
lvl_hi:  .space 1
ll_cnt:  .space 1   ; contador de bytes de sus bucles de copia -- NUNCA
                     ; [dot_i]: load_level puede llamarse desde dentro del
                     ; bucle de actualiza_dots (via dot_pickup/level_passed,
                     ; al recoger la ultima bolita de un nivel), que
                     ; necesita [dot_i] intacto al volver para seguir por
                     ; el siguiente slot -- bug real que hubo aqui: al
                     ; reusar [dot_i] como contador generico, el hueco que
                     ; se estaba procesando (dot_i=5, p.ej.) volvia con
                     ; dot_i=10 (el ultimo valor del bucle de copia de
                     ; load_level), lo que desbordaba dot_vis/dot_rayi/
                     ; dot_steps_arr (solo 10 bytes) y dejaba el bucle de
                     ; actualiza_dots sin poder volver a valer DOT_COUNT
                     ; nunca (arrancaba ya por encima), en bucle infinito

; nubes: angulo de mundo fijo por nube (cloud_angle_tbl) + una deriva por
; tipo que decrece con el tiempo (cloud_drift_a/cloud_drift_b -- la B, de
; las alargadas, decrece mas por paso, asi que se ven mas rapidas)
cloud_i:          .space 1
cloud_ray_i:      .space 1
cloud_anchor_x:   .space 1
cloud_pi:         .space 1   ; indice de punto (0..[cloud_shape_len]-1) en dibuja_nube_grande
cloud_dx:         .space 1
cloud_dy:         .space 1
cloud_shape_lo:   .space 1   ; forma elegida para la nube actual (rechoncha/alargada)
cloud_shape_hi:   .space 1
cloud_shape_len:  .space 1
cloud_drift_cur:  .space 1   ; deriva elegida para la nube actual (A o B)
cloud_drift_a:    .space 1   ; deriva de las nubes rechonchas (pares)
cloud_drift_b:    .space 1   ; deriva de las nubes alargadas (impares) -- mas rapida
cloud_drift_cnt:  .space 1

; direccionamiento de pixel exacto (nubes) -- px_x/px_y son la entrada de
; calc_pix, pix_lo/pix_hi/pix_mask su salida (igual patron que cubo.asm)
px_x:       .space 1
px_y:       .space 1
pix_lo:     .space 1
pix_hi:     .space 1
pix_mask:   .space 1

; techo libre (y0) de cada una de las 32 columnas de este fotograma,
; guardado durante ray_loop para que dibuja_nubes (que corre DESPUES de
; ese bucle) pueda decidir la oclusion de la columna central de cada nube
y0_tbl:     .space 32
dist4_tbl:  .space 32   ; distancia de pared de cada columna x4 (ver ray_loop)

; --- dianas (dibuja_objetos/obj_project/draw_bullseye) -----------------------
ob_i:       .space 1
ov_vis:     .space 1
ov_q:       .space 1
ov_mx:      .space 1
ov_mn:      .space 1
ov_xdom:    .space 1
be_cx:      .space 1
be_cy:      .space 1
be_r:       .space 1
be_y:       .space 1
be_x:       .space 1
be_n:       .space 1
be_rows:    .space 1
be_cols:    .space 1
be_ady16:   .space 1
be_rb_lo:   .space 1
be_rb_hi:   .space 1
be_col:     .space 1
h_dots:     .asciiz "DOTS LEFT "

; radio de la diana segun la distancia en MEDIAS baldosas (0..40, para que
; encoja de forma continua al alejarse, no a saltos): bastante mas
; grande que la proporcion de las paredes, para que se vea bien de lejos
OBJ_R:      .db 12, 12, 12, 12, 11, 10, 10, 10, 9, 8, 8, 8, 7, 6, 6, 6, 5, 5, 5, 4, 4
            .db 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2
; atan(t/32) en unidades de 256 por vuelta, t = 0..32 (0..45 grados)
ATAN32:     .db 0, 1, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19
            .db 20, 21, 22, 23, 24, 25, 25, 26, 27, 28, 29, 29, 30, 31, 31, 32
MASK8:      .db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
; DIST16[dy*16+dx] = round(sqrt(dx*dx+dy*dy)), dx,dy = 0..15
DIST16:
    .db 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    .db 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    .db 2, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    .db 3, 3, 4, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 15
    .db 4, 4, 4, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
    .db 5, 5, 5, 6, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 15, 16
    .db 6, 6, 6, 7, 7, 8, 8, 9, 10, 11, 12, 13, 13, 14, 15, 16
    .db 7, 7, 7, 8, 8, 9, 9, 10, 11, 11, 12, 13, 14, 15, 16, 17
    .db 8, 8, 8, 9, 9, 9, 10, 11, 11, 12, 13, 14, 14, 15, 16, 17
    .db 9, 9, 9, 9, 10, 10, 11, 11, 12, 13, 13, 14, 15, 16, 17, 17
    .db 10, 10, 10, 10, 11, 11, 12, 12, 13, 13, 14, 15, 16, 16, 17, 18
    .db 11, 11, 11, 11, 12, 12, 13, 13, 14, 14, 15, 16, 16, 17, 18, 19
    .db 12, 12, 12, 12, 13, 13, 13, 14, 14, 15, 16, 16, 17, 18, 18, 19
    .db 13, 13, 13, 13, 14, 14, 14, 15, 15, 16, 16, 17, 18, 18, 19, 20
    .db 14, 14, 14, 14, 15, 15, 15, 16, 16, 17, 17, 18, 18, 19, 20, 21
    .db 15, 15, 15, 15, 16, 16, 16, 17, 17, 17, 18, 19, 19, 20, 21, 21

h_title:    .asciiz "RAYCAST 3D"
h_level_passed: .asciiz "LEVEL PASSED!"

; --- cloud_angle_tbl: angulo de mundo fijo de cada nube (repartidas a
; partes iguales en los 128 angulos posibles, 16 = 45 grados entre ellas) --
cloud_angle_tbl:
    .db 0, 16, 32, 48, 64, 80, 96, 112

; --- cloud_shape_a/cloud_shape_b: contorno de cada una de las dos formas
; de nube (dx,dy), CLOUD_SHAPE_A_LEN/CLOUD_SHAPE_B_LEN pares. Calculadas
; una vez con Python: se solapan varios circulos a lo largo de una linea
; (simulando los "bultos" redondeados de una nube), se toma el borde
; exterior de esa union (cada pixel relleno con al menos un vecino fuera
; de la union) y se descarta el interior -- de ahi que salgan huecas y de
; lineas curvas en vez de un rectangulo. anchor: dx=0 es la columna mas a
; la izquierda, dy=0 la fila mas arriba (CLOUD_TOP_ROW en pantalla).

; --- cloud_shape_a ("rechoncha"): 22x15 px, 3 circulos grandes y muy
; solapados, casi a la misma altura --------------------------------------
;
;   ........#######.......
;   .......#       #......
;   ....###         ###...
;   ...#               #..
;   ..#                 #.
;   .#                   #
;   .#                   #
;   .#                   #
;   #                    #
;   .#                   #
;   .#                   #
;   .#                   #
;   ..#                 #.
;   ...#       #       #..
;   ....#######.#######...
cloud_shape_a:
    .db 8,0,  9,0,  10,0, 11,0, 12,0, 13,0, 14,0
    .db 7,1,  15,1
    .db 4,2,  5,2,  6,2,  16,2, 17,2, 18,2
    .db 3,3,  19,3
    .db 2,4,  20,4
    .db 1,5,  21,5
    .db 1,6,  21,6
    .db 1,7,  21,7
    .db 0,8,  21,8
    .db 1,9,  21,9
    .db 1,10, 21,10
    .db 1,11, 21,11
    .db 2,12, 20,12
    .db 3,13, 11,13, 19,13
    .db 4,14, 5,14, 6,14, 7,14, 8,14, 9,14, 10,14, 12,14
    .db 13,14,14,14,15,14,16,14,17,14,18,14

; --- cloud_shape_b ("alargada"): 30x12 px, 5 circulos mas pequenos
; repartidos en una linea mas larga, mucho mas ancha que alta -------------
;
;   ..........#..#####..#........
;   .......### ##     ## ###.....
;   ...####                 ####.
;   ..#                         #
;   .#                           #
;   #                            #
;   #                            #
;   #                            #
;   #                            #
;   #                            #
;   .#       # ######### #       #
;   ..#######.#.........#.#######.
cloud_shape_b:
    .db 10,0, 13,0, 14,0, 15,0, 16,0, 17,0, 20,0
    .db 7,1,  8,1,  9,1,  11,1, 12,1, 18,1, 19,1, 21,1, 22,1, 23,1
    .db 3,2,  4,2,  5,2,  6,2,  24,2, 25,2, 26,2, 27,2
    .db 2,3,  28,3
    .db 1,4,  29,4
    .db 0,5,  29,5
    .db 0,6,  29,6
    .db 0,7,  29,7
    .db 0,8,  29,8
    .db 0,9,  29,9
    .db 1,10, 9,10, 11,10,12,10,13,10,14,10,15,10,16,10,17,10
    .db 18,10,19,10,21,10,29,10
    .db 2,11, 3,11, 4,11, 5,11, 6,11, 7,11, 8,11, 10,11
    .db 20,11,22,11,23,11,24,11,25,11,26,11,27,11,28,11

; --- mapa: 16 filas x 16 columnas, 1=pared 0=libre, 2 bytes/fila (bit7 =
; columna 0). Bordeado de pared por completo (ver el aviso de la cabecera:
; con eso ningun rayo se queda sin chocar dentro de MAX_STEPS). Buffer en
; RAM: se rellena copiando desde map_data0/1/2 (ROM) al cargar cada nivel,
; ver load_level -- es_pared/march_ray no cambian nada, siguen leyendo
; siempre de aqui.
mapa: .space 32

; --- map_data0/1/2: los MAP_COUNT mapas prehechos, en ROM (mismo formato
; que `mapa`). map_data0 es el mapa original de este programa; map_data1 y
; map_data2 son nuevos, cada uno verificado en Python con el mismo criterio
; de "ningun rayo se queda sin chocar dentro de MAX_STEPS" que el original
; (sondeo de 5 subposiciones por baldosa libre x los 128 angulos posibles).
map_data0:
    .db 0xFF,0xFF
    .db 0x80,0x01
    .db 0xBE,0x01
    .db 0xA0,0x01
    .db 0xA0,0x01
    .db 0xA3,0xC1
    .db 0x82,0x01
    .db 0x82,0x01
    .db 0x82,0x31
    .db 0x80,0x11
    .db 0x80,0x11
    .db 0xBC,0x01
    .db 0x84,0x01
    .db 0x84,0x01
    .db 0x80,0x01
    .db 0xFF,0xFF

; map_data1: pasillo en zigzag horizontal (divisores con un unico hueco,
; alternando lado, para que el recorrido serpentee de arriba a abajo).
map_data1:
    .db 0xFF,0xFF
    .db 0x80,0x01
    .db 0xFF,0xFD
    .db 0x80,0x01
    .db 0xBF,0xFF
    .db 0x80,0x01
    .db 0xFF,0xFD
    .db 0x80,0x01
    .db 0xBF,0xFF
    .db 0x80,0x01
    .db 0xFF,0xFD
    .db 0x80,0x01
    .db 0xBF,0xFF
    .db 0x80,0x01
    .db 0xFF,0xFD
    .db 0xFF,0xFF

; map_data2: mismo zigzag que map_data1 pero en vertical (columnas en vez
; de filas), para que se sienta como un mapa distinto de verdad.
map_data2:
    .db 0xFF,0xFF
    .db 0xA2,0x23
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0xAA,0xAB
    .db 0x88,0x89
    .db 0xFF,0xFF

MAP_PTRS: .dw map_data0, map_data1, map_data2

; --- dot_data0/1/2: posiciones (x,y en pixeles, centro de baldosa) de las
; DOT_COUNT bolitas de cada nivel -- una por baldosa libre, bien repartidas
; y lejos de la posicion de partida del jugador en ese mapa (elegidas con
; Python, ver tools/ -- no hay proceso para regenerarlas en el repo, son
; solo datos).
dot_data0:
    .db 120,40, 168,232, 88,232, 216,136, 200,72, 168,120, 72,88, 88,152, 184,200, 232,56
dot_data1:
    .db 136,216, 56,184, 200,56, 152,56, 56,56, 120,184, 104,152, 184,152, 120,24, 184,120
dot_data2:
    .db 104,232, 88,24, 184,200, 184,120, 216,216, 152,88, 152,56, 56,104, 216,152, 56,152

DOT_DATA_PTRS: .dw dot_data0, dot_data1, dot_data2

; --- MAP_SPAWN_X/Y: posicion inicial del jugador en cada mapa (en una
; baldosa libre, ver load_level).
MAP_SPAWN_X: .db 136, 40, 24
MAP_SPAWN_Y: .db 40, 24, 24

; --- height_tbl: altura de pared (px) segun distancia en pasos (0..20),
; formula K/d con techo 63 (pantalla entera) y suelo 1 -- calculada con
; Python, no en tiempo de ejecucion (esta CPU no tiene division).
height_tbl:
    .db 63, 63, 45, 30, 22, 18, 15, 13, 11, 10, 9, 8
    .db 8, 7, 6, 6, 6, 5, 5, 5, 4

; --- shade_by_dist: nivel de trama (0=negro..4=blanco) segun distancia en
; pasos (0..20, igual indexacion que height_tbl) -- mas cerca = mas claro --
shade_by_dist:
    .db 4,4,4,4, 3,3,3,3, 2,2,2,2, 1,1,1,1, 0,0,0,0,0

; --- shade_tbl: mascara de nibble por (nivel*4 + paridad_fila*2 + lado),
; lado 0=nibble alto(0xF0) 1=nibble bajo(0x0F). Los niveles intermedios
; alternan el patron entre fila par/impar para que se vea como trama de
; puntos (dithering), no como una franja solida mas tenue.
;   nivel 0: negro completo (0 bits)
;   nivel 1: trama fina      (~1 de 4 bits)
;   nivel 2: trama media     (~2 de 4 bits, a cuadros)
;   nivel 3: trama densa     (~3 de 4 bits)
;   nivel 4: blanco completo (4 de 4 bits)
shade_tbl:
    .db 0x00,0x00, 0x00,0x00
    .db 0x80,0x08, 0x20,0x02
    .db 0xA0,0x0A, 0x50,0x05
    .db 0xE0,0x0E, 0xD0,0x0D
    .db 0xF0,0x0F, 0xF0,0x0F

; --- ray_tbl: 128 entradas (dx,dy) por angulo, escala 16 (para que marchar
; un paso avance ~1 baldosa), calculada con Python (round(16*cos/sin)).
ray_tbl:
    .db 16,0, 16,1, 16,2, 16,2, 16,3, 16,4, 15,5, 15,5
    .db 15,6, 14,7, 14,8, 14,8, 13,9, 13,10, 12,10, 12,11
    .db 11,11, 11,12, 10,12, 10,13, 9,13, 8,14, 8,14, 7,14
    .db 6,15, 5,15, 5,15, 4,16, 3,16, 2,16, 2,16, 1,16
    .db 0,16, 255,16, 254,16, 254,16, 253,16, 252,16, 251,15, 251,15
    .db 250,15, 249,14, 248,14, 248,14, 247,13, 246,13, 246,12, 245,12
    .db 245,11, 244,11, 244,10, 243,10, 243,9, 242,8, 242,8, 242,7
    .db 241,6, 241,5, 241,5, 240,4, 240,3, 240,2, 240,2, 240,1
    .db 240,0, 240,255, 240,254, 240,254, 240,253, 240,252, 241,251, 241,251
    .db 241,250, 242,249, 242,248, 242,248, 243,247, 243,246, 244,246, 244,245
    .db 245,245, 245,244, 246,244, 246,243, 247,243, 248,242, 248,242, 249,242
    .db 250,241, 251,241, 251,241, 252,240, 253,240, 254,240, 254,240, 255,240
    .db 0,240, 1,240, 2,240, 2,240, 3,240, 4,240, 5,241, 5,241
    .db 6,241, 7,242, 8,242, 8,242, 9,243, 10,243, 10,244, 11,244
    .db 11,245, 12,245, 12,246, 13,246, 13,247, 14,248, 14,248, 14,249
    .db 15,250, 15,251, 15,251, 16,252, 16,253, 16,254, 16,254, 16,255

; --- move_tbl: igual que ray_tbl pero escala 4 (paso de avance del jugador
; por detente, mas fino que el de marcha de rayos).
move_tbl:
    .db 4,0, 4,0, 4,0, 4,1, 4,1, 4,1, 4,1, 4,1
    .db 4,2, 4,2, 4,2, 3,2, 3,2, 3,2, 3,3, 3,3
    .db 3,3, 3,3, 3,3, 2,3, 2,3, 2,3, 2,4, 2,4
    .db 2,4, 1,4, 1,4, 1,4, 1,4, 1,4, 0,4, 0,4
    .db 0,4, 0,4, 0,4, 255,4, 255,4, 255,4, 255,4, 255,4
    .db 254,4, 254,4, 254,4, 254,3, 254,3, 254,3, 253,3, 253,3
    .db 253,3, 253,3, 253,3, 253,2, 253,2, 253,2, 252,2, 252,2
    .db 252,2, 252,1, 252,1, 252,1, 252,1, 252,1, 252,0, 252,0
    .db 252,0, 252,0, 252,0, 252,255, 252,255, 252,255, 252,255, 252,255
    .db 252,254, 252,254, 252,254, 253,254, 253,254, 253,254, 253,253, 253,253
    .db 253,253, 253,253, 253,253, 254,253, 254,253, 254,253, 254,252, 254,252
    .db 254,252, 255,252, 255,252, 255,252, 255,252, 255,252, 0,252, 0,252
    .db 0,252, 0,252, 0,252, 1,252, 1,252, 1,252, 1,252, 1,252
    .db 2,252, 2,252, 2,252, 2,253, 2,253, 2,253, 3,253, 3,253
    .db 3,253, 3,253, 3,253, 3,254, 3,254, 3,254, 4,254, 4,254
    .db 4,254, 4,255, 4,255, 4,255, 4,255, 4,255, 4,0, 4,0

    .org 0xF400
shadow:     .space 1024
