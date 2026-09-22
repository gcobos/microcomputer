; ============================================================================
;  raycast.asm  -  escena 3D en primera persona estilo Doom/Wolfenstein (compi)
;
;  Motor de "raycasting" clasico: mapa de 16x16 baldosas, se lanzan 32 rayos
;  (uno cada ~2,8 grados, campo de vision de 90 grados) desde la posicion del
;  jugador, cada uno "marcha" en pasos fijos hasta chocar con una pared; la
;  distancia recorrida (en pasos, no en pixeles) da la altura de la franja
;  vertical de pared que se dibuja para ese rayo (mas cerca = mas alta).
;
;  Sin multiplicacion ni division real, ni trigonometria en tiempo de
;  ejecucion -- todo son tablas, calculadas una vez con Python (ver el
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
;  proyectil redondo ("bola de fuego") que sale disparado en linea recta
;  hacia donde mira el jugador en ese instante, con un sonido descendente
;  (silbido tipo "fwoosh"). Puede haber hasta PROJ_COUNT=4 en vuelo a la
;  vez -- cada uno lleva su PROPIO angulo de disparo (proj_launch_facing)
;  y su PROPIA distancia recorrida (proj_steps), en tablas de 4 bytes
;  (una celda por proyectil) en vez de una sola variable; al disparar se
;  usa el primer hueco libre, y si los 4 estan ocupados la pulsacion se
;  ignora. El proyectil viaja usando la misma tabla de direcciones que
;  los rayos (ray_tbl), asi que su distancia recorrida se puede comparar
;  directamente contra la distancia de la pared de la columna en pantalla
;  donde le toque aparecer: solo se dibuja cuando esta mas cerca que esa
;  pared (si no, "se pierde" tras ella, exactamente el mismo criterio de
;  mas-lejos-primero que las paredes, aplicado al unico tipo de objeto que
;  lo necesita). Se dibuja RELLENO DE NEGRO (apaga pixeles, no los
;  enciende) para que se distinga como una silueta oscura tanto sobre una
;  pared cercana solida y blanca como sobre una con trama de puntos; su
;  tamano se reduce en 4 escalones segun se aleja (grande, mediano,
;  pequeno, punto). Cada proyectil se apaga solo al chocar contra una
;  pared o al llegar al limite de MAX_STEPS (la garantia de la cabecera
;  de arriba asegura que eso pasa siempre, dentro de ese limite).
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

; --- geometria / constantes --------------------------------------------------
FOV_RAYS   = 32          ; rayos por fotograma = franjas de 4 px (32*4=128)
MAX_STEPS  = 20          ; limite de pasos de marcha (ver el aviso de arriba)
TURN_STEP  = 4           ; cuanto gira `facing` por detente (de 128, ~11 grados)

; --- proyectiles ("bolas de fuego"): hasta PROJ_COUNT a la vez, cada uno
; con su propio angulo de disparo y su propia distancia recorrida ------------
PROJ_COUNT      = 4      ; proyectiles simultaneos como maximo
PROJ_ROW        = 31     ; fila central donde se dibujan (altura de "los ojos")
; tamano segun pasos recorridos (mas pasos = mas lejos = mas pequeno):
PROJ_SIZE_T1    = 5      ; pasos < T1  -> el mas grande  (5 filas)
PROJ_SIZE_T2    = 10     ; pasos < T2  -> mediano        (3 filas)
PROJ_SIZE_T3    = 15     ; pasos < T3  -> pequeno        (1 fila, nibble entero)
                          ; pasos >= T3 -> punto          (1 fila, medio nibble)

; --- sonido del disparo: silbido descendente (un solo canal, monofonico;
; cada disparo nuevo lo reinicia aunque ya haya otros proyectiles en vuelo) --
SND_FREQ_START  = 900    ; Hz al disparar
SND_FREQ_STEP   = 90     ; Hz que baja cada fotograma
SND_SWEEP_FRAMES = 9     ; fotogramas que dura el silbido

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
    MOV BL,#lo(h_title)
    MOV BH,#hi(h_title)
    MOV CL,#4
    MOV CH,#3
    CALL puts
    MOV AL,#8
    CALL frame_wait
    CALL clst

    MOV AL,#136            ; jugador: baldosa (8,2), zona abierta del mapa
    STA [player_x],AL
    MOV AL,#40
    STA [player_y],AL
    MOV AL,#0
    STA [facing],AL
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
    MOV BL,#lo(y0_tbl)
    MOV BH,#hi(y0_tbl)
    LDA CL,[ray_i]
    CALL idx_ptr
    STA [BX],AL

    ; cada proyectil activo y visible cae en una unica columna (su propio
    ; [proj_ray_i]) -- solo se dibuja ahi, y solo si esta mas cerca que la
    ; pared que se acaba de dibujar en esa misma columna ([dist], recien
    ; calculado por march_ray): "mas lejos primero, mas cerca despues",
    ; igual que las paredes, pero aplicado a lo unico que puede solaparse
    ; con ellas. Se recorren los PROJ_COUNT slots porque cada uno puede
    ; estar en una columna distinta.
    MOV AL,#0
    STA [proj_i],AL
ray_proj_loop:
    MOV BL,#lo(proj_active)
    MOV BH,#hi(proj_active)
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ray_proj_next
    MOV BL,#lo(proj_visible)
    MOV BH,#hi(proj_visible)
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ray_proj_next
    MOV BL,#lo(proj_ray_i)
    MOV BH,#hi(proj_ray_i)
    CALL proj_field_addr
    LDA AL,[BX]
    LDA BL,[ray_i]
    CMP AL,BL
    JMPNZ ray_proj_next
    MOV BL,#lo(proj_steps)
    MOV BH,#hi(proj_steps)
    CALL proj_field_addr
    LDA AL,[BX]
    LDA BL,[dist]
    CMP AL,BL
    JMPNC ray_proj_next     ; proj_steps >= dist -> la pared esta delante
    CALL dibuja_proyectil
ray_proj_next:
    LDA AL,[proj_i]
    ADD AL,#1
    STA [proj_i],AL
    CMP AL,#PROJ_COUNT
    JMPNZ ray_proj_loop

    LDA AL,[ray_i]
    ADD AL,#1
    STA [ray_i],AL
    CMP AL,#FOV_RAYS
    JMPNZ ray_loop

    CALL dibuja_nubes
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
    MOV BL,#lo(move_tbl)
    MOV BH,#hi(move_tbl)
    CALL idx_ptr
    LDA AL,[BX]
    STA [mv_dx],AL
    ADD BL,#1
    JMPNC bm_ok
    ADD BH,#1
bm_ok:
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
    MOV BL,#lo(proj_active)
    MOV BH,#hi(proj_active)
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
    MOV BL,#lo(proj_launch_facing)
    MOV BH,#hi(proj_launch_facing)
    CALL proj_field_addr
    STA [BX],AL

    MOV AL,#0
    MOV BL,#lo(proj_steps)
    MOV BH,#hi(proj_steps)
    CALL proj_field_addr
    STA [BX],AL

    LDA AL,[facing]
    SHL AL                  ; offset = facing*2 (ray_tbl, 2 bytes/entrada)
    MOV CL,AL
    MOV BL,#lo(ray_tbl)
    MOV BH,#hi(ray_tbl)
    CALL idx_ptr
    LDA AL,[BX]
    STA [dsp_dx],AL
    ADD BL,#1
    JMPNC dsp_ok
    ADD BH,#1
dsp_ok:
    LDA AL,[BX]
    STA [dsp_dy],AL

    LDA AL,[dsp_dx]
    MOV BL,#lo(proj_dx)
    MOV BH,#hi(proj_dx)
    CALL proj_field_addr
    STA [BX],AL
    LDA AL,[dsp_dy]
    MOV BL,#lo(proj_dy)
    MOV BH,#hi(proj_dy)
    CALL proj_field_addr
    STA [BX],AL

    LDA AL,[player_x]
    MOV BL,#lo(proj_rx)
    MOV BH,#hi(proj_rx)
    CALL proj_field_addr
    STA [BX],AL
    LDA AL,[player_y]
    MOV BL,#lo(proj_ry)
    MOV BH,#hi(proj_ry)
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
    CALL idx_ptr
    RET

; --- actualiza_proyectil: recorre los PROJ_COUNT slots; el que este activo
; avanza un paso (misma escala que march_ray), comprueba si choco con una
; pared y calcula en que columna de pantalla (si alguna) le toca aparecer
; este fotograma segun hacia donde mire ahora el jugador --------------------
actualiza_proyectil:
    MOV AL,#0
    STA [proj_i],AL
apr_loop:
    MOV BL,#lo(proj_active)
    MOV BH,#hi(proj_active)
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ apr_next

    MOV BL,#lo(proj_dx)
    MOV BH,#hi(proj_dx)
    CALL proj_field_addr
    LDA AL,[BX]
    STA [apr_dx],AL
    MOV BL,#lo(proj_dy)
    MOV BH,#hi(proj_dy)
    CALL proj_field_addr
    LDA AL,[BX]
    STA [apr_dy],AL

    MOV BL,#lo(proj_rx)
    MOV BH,#hi(proj_rx)
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,[apr_dx]
    STA [BX],AL
    MOV BL,#lo(proj_ry)
    MOV BH,#hi(proj_ry)
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,[apr_dy]
    STA [BX],AL

    MOV BL,#lo(proj_steps)
    MOV BH,#hi(proj_steps)
    CALL proj_field_addr
    LDA AL,[BX]
    ADD AL,#1
    STA [BX],AL
    STA [apr_steps],AL

    MOV BL,#lo(proj_rx)
    MOV BH,#hi(proj_rx)
    CALL proj_field_addr
    LDA AL,[BX]
    SHR AL,#4
    STA [apr_tx],AL          ; tile x en memoria: proj_field_addr usa CL,
                              ; no se puede dejar ahi entre dos llamadas
    MOV BL,#lo(proj_ry)
    MOV BH,#hi(proj_ry)
    CALL proj_field_addr
    LDA AL,[BX]
    SHR AL,#4
    MOV CH,AL
    LDA CL,[apr_tx]
    CALL es_pared
    CMP AL,#0
    JMPNZ apr_stop
    LDA AL,[apr_steps]
    CMP AL,#MAX_STEPS
    JMPNC apr_stop
    JMP apr_vis
apr_stop:
    MOV AL,#0
    MOV BL,#lo(proj_active)
    MOV BH,#hi(proj_active)
    CALL proj_field_addr
    STA [BX],AL
    JMP apr_next

; visible cuando la diferencia entre el angulo de disparo de ESTE slot y
; `facing` actual cae dentro del abanico de 32 rayos (facing-16..facing+15)
apr_vis:
    MOV BL,#lo(proj_launch_facing)
    MOV BH,#hi(proj_launch_facing)
    CALL proj_field_addr
    LDA AL,[BX]
    LDA BL,[facing]
    SUB AL,BL
    AND AL,#0x7F
    CMP AL,#16
    JMPC apr_lo
    CMP AL,#112
    JMPNC apr_hi
    MOV AL,#0
    MOV BL,#lo(proj_visible)
    MOV BH,#hi(proj_visible)
    CALL proj_field_addr
    STA [BX],AL
    JMP apr_next
apr_lo:
    ADD AL,#16
    STA [apr_rayi],AL
    MOV BL,#lo(proj_ray_i)
    MOV BH,#hi(proj_ray_i)
    CALL proj_field_addr
    LDA AL,[apr_rayi]
    STA [BX],AL
    MOV AL,#1
    MOV BL,#lo(proj_visible)
    MOV BH,#hi(proj_visible)
    CALL proj_field_addr
    STA [BX],AL
    JMP apr_next
apr_hi:
    SUB AL,#112
    STA [apr_rayi],AL
    MOV BL,#lo(proj_ray_i)
    MOV BH,#hi(proj_ray_i)
    CALL proj_field_addr
    LDA AL,[apr_rayi]
    STA [BX],AL
    MOV AL,#1
    MOV BL,#lo(proj_visible)
    MOV BH,#hi(proj_visible)
    CALL proj_field_addr
    STA [BX],AL
apr_next:
    LDA AL,[proj_i]
    ADD AL,#1
    STA [proj_i],AL
    CMP AL,#PROJ_COUNT
    JMPNZ apr_loop
    RET

; --- dibuja_proyectil: estampa el proyectil del slot [proj_i] en la columna
; actual (usa [byte_col]/[nibble], ya calculados por render_column para
; este ray_i). RELLENO DE NEGRO (apaga pixeles, no los enciende) para que
; se distinga como silueta oscura tanto sobre una pared blanca solida como
; sobre una con trama de puntos. Tamano en 4 escalones segun los pasos
; recorridos de ESTE slot (mas pasos = mas lejos = mas pequeno): 5 filas ->
; 3 filas -> 1 fila entera -> 1 fila a medias (el mas pequeno) -------------
dibuja_proyectil:
    MOV BL,#lo(proj_steps)
    MOV BH,#hi(proj_steps)
    CALL proj_field_addr
    LDA AL,[BX]
    CMP AL,#PROJ_SIZE_T1
    JMPNC dpr_t2
    MOV AL,#PROJ_ROW-2
    STA [rowy],AL
    CALL proj_row_half
    MOV AL,#PROJ_ROW-1
    STA [rowy],AL
    CALL proj_row_full
    MOV AL,#PROJ_ROW
    STA [rowy],AL
    CALL proj_row_full
    MOV AL,#PROJ_ROW+1
    STA [rowy],AL
    CALL proj_row_full
    MOV AL,#PROJ_ROW+2
    STA [rowy],AL
    CALL proj_row_half
    RET
dpr_t2:
    CMP AL,#PROJ_SIZE_T2
    JMPNC dpr_t3
    MOV AL,#PROJ_ROW-1
    STA [rowy],AL
    CALL proj_row_half
    MOV AL,#PROJ_ROW
    STA [rowy],AL
    CALL proj_row_full
    MOV AL,#PROJ_ROW+1
    STA [rowy],AL
    CALL proj_row_half
    RET
dpr_t3:
    CMP AL,#PROJ_SIZE_T3
    JMPNC dpr_t4
    MOV AL,#PROJ_ROW
    STA [rowy],AL
    CALL proj_row_full
    RET
dpr_t4:
    MOV AL,#PROJ_ROW
    STA [rowy],AL
    CALL proj_row_half
    RET

; --- proj_row_full/proj_row_half: APAGAN (negro), en la fila [rowy] de la
; columna [byte_col], todo el nibble [nibble] o solo los 2 bits centrales
; (para un contorno mas redondeado que un bloque macizo) -------------------
proj_row_full:
    LDA AL,[nibble]
    STA [proj_mask],AL
    JMP proj_row_common
proj_row_half:
    LDA AL,[nibble]
    CMP AL,#0xF0
    JMPZ prh_hi
    MOV AL,#0x06
    JMP prh_set
prh_hi:
    MOV AL,#0x60
prh_set:
    STA [proj_mask],AL
proj_row_common:
    CALL calc_shadow_addr
    LDA AL,[BX]
    LDA DL,[proj_mask]
    NOT DL
    AND AL,DL
    STA [BX],AL
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
    MOV BL,#lo(cloud_angle_tbl)
    MOV BH,#hi(cloud_angle_tbl)
    CALL idx_ptr
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

    MOV BL,#lo(y0_tbl)
    MOV BH,#hi(y0_tbl)
    LDA CL,[cloud_ray_i]
    CALL idx_ptr
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
    CALL idx_ptr
    LDA AL,[BX]
    STA [cloud_dx],AL
    ADD BL,#1
    JMPNC dng_ok
    ADD BH,#1
dng_ok:
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
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
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
    MOV BL,#lo(mapa)
    MOV BH,#hi(mapa)
    ADD BL,AL
    JMPNC ep_ok
    ADD BH,#1
ep_ok:
    CMP CL,#8
    JMPNC ep_hi
    LDA AL,[BX]             ; columna 0-7 -> byte0
    MOV DL,CL               ; bit = 7-x
    JMP ep_bit
ep_hi:
    ADD BL,#1
    JMPNC ep_hi2
    ADD BH,#1
ep_hi2:
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
    MOV BL,#lo(ray_tbl)
    MOV BH,#hi(ray_tbl)
    CALL idx_ptr
    LDA AL,[BX]
    STA [rdx],AL
    ADD BL,#1
    JMPNC mr_ok
    ADD BH,#1
mr_ok:
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
    MOV BL,#lo(height_tbl)
    MOV BH,#hi(height_tbl)
    CALL idx_ptr
    LDA AL,[BX]
    STA [wall_h],AL

    LDA CL,[dist]
    MOV BL,#lo(shade_by_dist)
    MOV BH,#hi(shade_by_dist)
    CALL idx_ptr
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

    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[wrf_off]
    CALL idx_ptr
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
    MOV BL,#lo(shade_tbl)
    MOV BH,#hi(shade_tbl)
    CALL idx_ptr
    LDA AL,[BX]
    STA [shade_mask],AL
    RET

; ============================================================================
;  DOBLE BUFFER (igual patron que cubo.asm/fzero.asm/roto_debug.asm)
; ============================================================================

; --- idx_ptr:  BX = (BX inicial) + CL, propagando el acarreo a mano --------
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` -----------------------
clr_shadow:
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    MOV AL,#0
    MOV CL,#0
    MOV CH,#4
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

; --- blit:  copia `shadow` al framebuffer real, solo lo que cambie --------
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
proj_visible: .space 4
proj_ray_i:   .space 4
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

h_title:    .asciiz "RAYCAST 3D"

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
; con eso ningun rayo se queda sin chocar dentro de MAX_STEPS).
mapa:
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
