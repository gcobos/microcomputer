; ============================================================================
;  skate.asm  -  "SKATE OH MY!": monopatin visto desde arriba, 3 carriles
;                (compi) -- primer programa que usa a fondo MOV reg16,#imm16,
;                MOVB/MOVW y MUL/DIV (ver docs/isa.md SS4d) en vez de las
;                rutinas de software que usaban los juegos mas antiguos.
;
;  Carretera vertical vista desde arriba (como fzero.asm, pero sin curvas ni
;  perspectiva: tres carriles paralelos de ancho fijo, con el borde de la
;  carretera recto a los lados, lineas discontinuas separando los carriles y
;  arcenes con arbustos y farolas) que "avanza" hacia la camara: todo se
;  desplaza hacia abajo de la pantalla a la vez (lineas de carril, arcenes,
;  obstaculos), dando sensacion de velocidad sin tener que mover la carretera
;  en si. El jugador patina SIEMPRE a la misma altura, cerca de abajo.
;
;  MANEJO (en EJECUTAR + CONTINUO):
;     CUALQUIER giro de CUALQUIERA de los dos encoders (DIRECCION o DATOS,
;     para cualquier lado) -> cambia de carril un paso (izquierda o derecha
;     segun el sentido del giro) -- no hace falta girar mucho, cualquier
;     movimiento ya cambia de carril (ver control_player). El sprite se
;     inclina hacia el carril de destino mientras se desplaza hasta el (unos
;     pocos fotogramas) y vuelve a quedar recto en cuanto llega.
;     CUALQUIER pulsador (DIRECCION o DATOS) -> SALTA: un segundo con el
;     sprite de salto (un poco mas grande) y cualquier obstaculo de ese
;     carril durante ese tiempo se esquiva automaticamente, sin importar si
;     el carril coincide o no.
;
;  Nota: igual que fzero.asm/pong.asm/raycast.asm, este programa usa los 4
;  gestos de los dos encoders (giro y pulsacion de cada uno) para jugar, asi
;  que no le queda ningun control libre para "volver al sistema" -- se sale
;  por el panel fisico (cambiar a EDITAR), igual que en esos otros.
;
;  OBSTACULOS: bicicleta, coche, camion, platano, perro y un grupo de
;  peatones cruzando, uno al azar por hueco, en uno de los 3 carriles al
;  azar (obst_active/_row/_lane/_type, igual esquema de "ranuras" que
;  fzero.asm). Cada uno que se esquiva (cambiando de carril o saltando) suma
;  PUNTOS = VELOCIDAD ACTUAL (1..4) -- calculado con la instruccion `MUL` de
;  verdad (`award_dodge`: AX = 1 x velocidad), para que ir mas rapido
;  tambien compense mas. Cada SPAWN_PERIOD vueltas puede aparecer uno nuevo
;  en una ranura libre.
;
;  PASOS DE CEBRA: cada ZEBRA_PERIOD vueltas aproximadamente cruza una
;  franja de paso de cebra (tres bandas discontinuas que atraviesan los 3
;  carriles) -- solo decorativo, no choca con nada, para dar mas realismo a
;  la carretera.
;
;  VIDAS: 3 corazones arriba a la derecha (ver draw_hud) -- cada choque (sin
;  saltar, en el carril del obstaculo, sin estar ya invulnerable) quita uno
;  y da un breve respiro de invulnerabilidad (INVULN_TICKS). GAME OVER al
;  perder el ultimo. Los corazones se dibujan sobre una caja negra que se
;  vuelve a limpiar cada fotograma (shadow_box con relleno 0) para que se
;  vean siempre nitidos aunque algun obstaculo o decoracion del arcen pase
;  por debajo de esa esquina. La puntuacion va arriba a la izquierda, en la
;  capa de TEXTO (celda opaca: siempre se lee bien encima de los graficos).
;
;  SPRITES: todos (jugador normal/inclinado/saltando, cada tipo de
;  obstaculo, arbusto, farola, corazon) se dibujan con el MISMO motor
;  generico `draw_filled_sprite`: una tabla de filas (dy,xoff,hw) con signo,
;  cada una una franja horizontal rellena de 2*hw+1 pixeles, centrada en
;  (cx+xoff, cy+dy) -- "inclinar" un sprite es tan simple como mover el xoff
;  de las filas de arriba (cabeza/hombros) respecto a las de abajo (tabla),
;  sin ningun codigo especial de rotacion. El indice de fila dentro de la
;  tabla se multiplica por 3 (bytes por fila) con la instruccion `MUL` de
;  verdad en vez de un bucle de sumas. Deliberadamente sencillos (formas
;  rellenas, nada de detalle) -- la idea es que sean grandes y rapidos de
;  dibujar, se pueden refinar mas adelante sin tocar el motor.
;
;  SIN PARPADEO: doble buffer por software de toda la vida (`shadow`/
;  `clr_shadow`/`blit`), igual que cubo.asm/fzero.asm/esquiva.asm -- se
;  dibuja la vuelta entera en RAM y solo se manda a la pantalla real lo que
;  haya cambiado.
;
;  MUSICA: todavia no tiene (vendra en forma de tabla RTTTL tipo
;  musica.asm/imagen.asm, con una melodia distinta) -- de momento solo
;  pitidos cortos puntuales (salto, esquivar, choque), igual que fzero.asm.
;
;  NUEVAS INSTRUCCIONES DE 16 BITS USADAS (ver docs/isa.md SS4d):
;     - `MOV BX,#tabla` / `MOV DX,#tabla+2` / `MOV CX,#imm`: cargar un
;       puntero/contador de 16 bits de un tiron en vez de dos MOV de 8 bits.
;     - `MOVB`/`MOVW`: limpiar de golpe el buffer de pantalla (`clr_shadow`,
;       1 byte real + 1023 en cascada) y el bloque de 16 bytes de estado de
;       los 4 obstaculos (`game_init`: 2 bytes a mano + 7 palabras en
;       cascada con MOVW) -- ver el comentario de cada rutina.
;     - `MUL`: `draw_filled_sprite` (indice de fila x3 bytes) y
;       `award_dodge` (puntos = 1 x velocidad).
;     - `DIV`: `score_digits`, centenas/decenas/unidades de la puntuacion
;       con dos divisiones de hardware en vez del bucle de restas de
;       fzero.asm/esquiva.asm.
;
;  Ensamblar y enviar al slot 20:
;     python3 tools/casm.py programs/skate.asm -o programs/skate.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 20 programs/skate.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 20

    .name "SKATE"

    .category GAME
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_POS = 0x0600
P_DIR_BTN = 0x0601
P_DAT_POS = 0x0602
P_DAT_BTN = 0x0603
P_T3      = 0x0623      ; ritmo del bucle de juego (8 ms/paso)
P_SND_NOTE = 0x0632
P_SND_DUR  = 0x0633

; --- record en la EEPROM del slot (iomap.h, 0x0700-0x0801) -----------------
; byte 0 = REC_MAGIC si hay un record grabado (una flash sin estrenar se lee
; 0xFF -> record 0), byte 1 = el record. Se graba SOLO al batirlo, al llegar
; al GAME OVER, para no gastar la flash en cada partida.
P_EEP_BASE = 0x0700
P_EEP_LOAD = 0x0800
P_EEP_SAVE = 0x0801
REC_MAGIC  = 0xC5
P_PROG_LOAD = 0x0640

; --- constantes de juego -----------------------------------------------------
N_OBST        = 4        ; obstaculos activos como maximo a la vez
LIVES_START   = 3
TICK_STEPS    = 6        ; pasos de P_T3 (8 ms) por vuelta -> ~48 ms/vuelta
SPEED_MIN     = 1
SPEED_MAX     = 4
SPAWN_PERIOD  = 16        ; vueltas entre intentos de aparicion de obstaculo
JUMP_TICKS    = 20        ; vueltas que dura un salto (~1 s a 48 ms/vuelta)
INVULN_TICKS  = 12
LANE_STEP_PX  = 8        ; paso de interpolacion del sprite al cambiar de carril
PLAYER_ROW    = 54        ; fila fija (pantalla) donde patina el jugador
ROAD_L        = 16        ; borde izquierdo de la carretera
ROAD_R        = 112       ; borde derecho de la carretera
DIVX1         = 48        ; separador discontinuo carril izq/centro
DIVX2         = 80        ; separador discontinuo carril centro/dcha
SIDE_LX       = 8         ; centro del arcen izquierdo (arbustos/farolas)
SIDE_RX       = 120       ; centro del arcen derecho
ZEBRA_PERIOD  = 110        ; vueltas entre pasos de cebra
PLAYER_LEN    = 8
BIKE_LEN      = 5
CAR_LEN       = 6
TRUCK_LEN     = 8
BANANA_LEN    = 3
DOG_LEN       = 4
PEOPLE_LEN    = 3
BUSH_LEN      = 3
LIGHT_LEN     = 4
HEART_LEN     = 8

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    IN  AL,(P_DAT_POS)          ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    JMPNZ title_init
    MOV AL,#0x5D
    STA [seed],AL

title_init:
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    CALL clsg
    CALL clst

    MOV BX,#s_title
    MOV CX,#0x0204
    CALL puts

    MOV BX,#s_help1
    MOV CX,#0x0401
    CALL puts

    MOV BX,#s_help2
    MOV CX,#0x0501
    CALL puts

    MOV BX,#s_help3
    MOV CX,#0x0601
    CALL puts

    MOV CX,#0x0705
    CALL show_record

title_l:
    CALL read_start_press
    CMP AL,#0
    JMPNZ game_init
    MOV AL,#1
    CALL frame_wait
    JMP title_l

; ============================================================================
;  INICIALIZA UNA PARTIDA NUEVA
; ============================================================================
game_init:
    CALL clsg
    CALL clst
    CALL clr_shadow

    MOV AL,#0
    STA [score],AL
    MOV AL,#LIVES_START
    STA [lives],AL
    MOV AL,#SPEED_MIN
    STA [speed],AL

    MOV AL,#1
    STA [cur_lane],AL          ; carril central
    MOV BX,#LANE_X+1           ; LANE_X[1], el carril central
    LDA AL,[BX]
    STA [player_x],AL
    STA [target_x],AL

    MOV AL,#0
    STA [tilt_state],AL
    STA [jump_active],AL
    STA [invuln],AL
    STA [scroll_y],AL
    STA [spawn_timer],AL
    STA [zebra_active],AL
    STA [zebra_row],AL
    MOV AL,#1
    STA [zebra_timer],AL
    STA [score_dirty],AL

    ; limpia los 16 bytes de estado de los 4 obstaculos (obst_active/_row/
    ; _lane/_type, 4 bytes cada uno y contiguos en memoria, ver DATOS) de
    ; una sola vez con MOVW en vez de 16 STA sueltos: el primer PAR se pone
    ; a 0 a mano y los otros 7 pares se propagan en cascada -- mismo truco
    ; que clr_shadow (ver su comentario), pero de 2 en 2 bytes porque aqui
    ; ya pensamos el tamaño en palabras, no en bytes sueltos.
    MOV AL,#0
    STA [obst_active],AL
    STA [obst_active+1],AL
    MOV BX,#obst_active
    MOV DX,#obst_active+2
    MOV CX,#7                  ; 7 palabras = 14 bytes (quedan 14 de los 16)
    MOVW

    IN  AL,(P_DIR_POS)
    STA [dir_pos_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL

    CALL update_score_text

; ============================================================================
;  BUCLE PRINCIPAL DE JUEGO
; ============================================================================
game_l:
    CALL control_player
    CALL try_spawn
    CALL update_zebra
    CALL tick_jump
    CALL tick_invuln
    CALL update_player_anim

    CALL clr_shadow
    CALL draw_scene
    CALL draw_zebra
    CALL update_obstacles       ; mueve, esquiva/choca y DIBUJA los activos
    CALL draw_player
    CALL draw_hud
    CALL blit
    CALL update_score_text

    LDA AL,[lives]
    CMP AL,#0
    JMPZ game_over

    LDA AL,[scroll_y]
    LDA BL,[speed]
    ADD AL,BL
    STA [scroll_y],AL

    ; velocidad progresiva con la puntuacion (igual que esquiva.asm/fzero.asm)
    LDA AL,[score]
    CMP AL,#60
    JMPC gl_s2
    MOV AL,#SPEED_MAX
    STA [speed],AL
    JMP gl_wait
gl_s2:
    LDA AL,[score]
    CMP AL,#30
    JMPC gl_s1
    MOV AL,#3
    STA [speed],AL
    JMP gl_wait
gl_s1:
    LDA AL,[score]
    CMP AL,#10
    JMPC gl_s0
    MOV AL,#2
    STA [speed],AL
    JMP gl_wait
gl_s0:
    MOV AL,#SPEED_MIN
    STA [speed],AL
gl_wait:
    MOV AL,#TICK_STEPS
    CALL frame_wait
    JMP game_l

; ============================================================================
;  PANTALLA DE FIN DE PARTIDA
; ============================================================================
game_over:
    CALL clst
    CALL clsg
    MOV BX,#s_over
    MOV CX,#0x0205
    CALL puts

    MOV BX,#s_score
    MOV CX,#0x0403
    CALL puts
    CALL score_digits
    LDA BL,[digit_h]
    MOV CX,#0x040C
    CALL putc
    LDA BL,[digit_t]
    MOV CX,#0x040D
    CALL putc
    LDA BL,[digit_u]
    MOV CX,#0x040E
    CALL putc

    MOV BX,#s_help3
    MOV CX,#0x0601
    CALL puts

    CALL save_record        ; graba el record si se ha batido
    CMP AL,#0
    JMPZ go_norec
    MOV BX,#s_newrec
    MOV CX,#0x0505
    CALL puts
go_norec:

    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
go_l:
    CALL read_start_press
    CMP AL,#0
    JMPNZ game_init
    MOV AL,#1
    CALL frame_wait
    JMP go_l

; ============================================================================
;  read_start_press:  AL=1 si algun pulsador tuvo flanco de subida, si no 0
; ============================================================================
read_start_press:
    MOV AL,#0
    STA [start_hit],AL

    IN  AL,(P_DIR_BTN)
    STA [tmp0],AL
    LDA BL,[dir_btn_prev]
    LDA CL,[tmp0]
    STA [dir_btn_prev],CL
    CMP CL,#0
    JMPZ rsp_dir_done
    CMP BL,#0
    JMPNZ rsp_dir_done
    MOV AL,#1
    STA [start_hit],AL
rsp_dir_done:

    IN  AL,(P_DAT_BTN)
    STA [tmp0],AL
    LDA BL,[dat_btn_prev]
    LDA CL,[tmp0]
    STA [dat_btn_prev],CL
    CMP CL,#0
    JMPZ rsp_dat_done
    CMP BL,#0
    JMPNZ rsp_dat_done
    MOV AL,#1
    STA [start_hit],AL
rsp_dat_done:
    LDA AL,[start_hit]
    RET

; ============================================================================
;  control_player: CUALQUIER giro de CUALQUIER encoder cambia un carril (no
;  hace falta mirar cuanto se ha girado, un solo detente ya mueve un
;  carril); CUALQUIER pulsador (flanco de subida) salta. Las 4 lecturas son
;  independientes entre si (como en esquiva.asm, los dos encoders se
;  comprueban uno tras otro, por separado).
; ============================================================================
control_player:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_pos_prev],CL
    CMP AL,#0
    JMPZ cp_dat_pos
    AND AL,#0x80
    JMPZ cp_dir_right
    CALL lane_left
    JMP cp_dat_pos
cp_dir_right:
    CALL lane_right

cp_dat_pos:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_pos_prev],CL
    CMP AL,#0
    JMPZ cp_dir_btn
    AND AL,#0x80
    JMPZ cp_dat_right
    CALL lane_left
    JMP cp_dir_btn
cp_dat_right:
    CALL lane_right

cp_dir_btn:
    IN  AL,(P_DIR_BTN)
    STA [tmp1],AL
    LDA BL,[dir_btn_prev]
    LDA CL,[tmp1]
    STA [dir_btn_prev],CL
    CMP CL,#0
    JMPZ cp_dat_btn
    CMP BL,#0
    JMPNZ cp_dat_btn
    CALL do_jump

cp_dat_btn:
    IN  AL,(P_DAT_BTN)
    STA [tmp1],AL
    LDA BL,[dat_btn_prev]
    LDA CL,[tmp1]
    STA [dat_btn_prev],CL
    CMP CL,#0
    JMPZ cp_ret
    CMP BL,#0
    JMPNZ cp_ret
    CALL do_jump
cp_ret:
    RET

; --- lane_left/lane_right: cur_lane -= 1 / += 1 con tope en 0/2 (sin dar la
; vuelta), y fija target_x para que update_player_anim empiece a deslizar
; el sprite -------------------------------------------------------------
lane_left:
    LDA AL,[cur_lane]
    CMP AL,#0
    JMPZ ll_ret
    SUB AL,#1
    STA [cur_lane],AL
    CALL set_target_x
ll_ret:
    RET

lane_right:
    LDA AL,[cur_lane]
    CMP AL,#2
    JMPZ lr_ret
    ADD AL,#1
    STA [cur_lane],AL
    CALL set_target_x
lr_ret:
    RET

set_target_x:
    MOV BX,#LANE_X
    LDA CL,[cur_lane]
    ADD BX,CL
    LDA AL,[BX]
    STA [target_x],AL
    RET

; --- do_jump: si no se esta saltando ya, arranca el salto y pita --------
do_jump:
    LDA AL,[jump_active]
    CMP AL,#0
    JMPNZ dj_ret
    MOV AL,#JUMP_TICKS
    STA [jump_active],AL
    MOV AL,#5                  ; duracion primero (PORT_SND_DUR es pegajoso
    OUT (P_SND_DUR),AL         ; pero no retroactivo -- ver docs/isa.md SS8)
    MOV AL,#76
    OUT (P_SND_NOTE),AL
dj_ret:
    RET

; ============================================================================
;  update_player_anim: desliza player_x hacia target_x LANE_STEP_PX por
;  vuelta (sin pasarse de largo) y deja tilt_state (0 recto, 1 inclinado a
;  la izquierda, 2 a la derecha) para que draw_player elija el sprite.
;  Mientras player_x == target_x se queda recto -- "el angulo vuelve a
;  apuntar hacia arriba en cuanto llega", como se pidio.
; ============================================================================
update_player_anim:
    LDA AL,[player_x]
    LDA BL,[target_x]
    CMP AL,BL
    JMPZ upa_center
    JMPC upa_inc                ; player_x < target_x -> avanza a la derecha

    LDA AL,[player_x]
    SUB AL,#LANE_STEP_PX
    LDA BL,[target_x]
    CMP AL,BL
    JMPC upa_clamp_dec           ; se paso de largo (AL<target) -> clamp
    JMP upa_store_dec
upa_clamp_dec:
    MOV AL,BL
upa_store_dec:
    STA [player_x],AL
    MOV AL,#1
    STA [tilt_state],AL
    RET

upa_inc:
    LDA AL,[player_x]
    ADD AL,#LANE_STEP_PX
    LDA BL,[target_x]
    CMP AL,BL
    JMPNC upa_clamp_inc          ; AL >= target_x -> ya llego o se paso, clamp
    JMP upa_store_inc
upa_clamp_inc:
    MOV AL,BL
upa_store_inc:
    STA [player_x],AL
    MOV AL,#2
    STA [tilt_state],AL
    RET

upa_center:
    MOV AL,#0
    STA [tilt_state],AL
    RET

; ============================================================================
;  try_spawn: cada SPAWN_PERIOD vueltas, busca una ranura libre y crea un
;  obstaculo nuevo en la fila 0, carril y tipo al azar (igual esquema de
;  "ranuras" que fzero.asm, con dos sorteos mas: carril 0..2 y tipo 0..5).
; ============================================================================
try_spawn:
    LDA AL,[spawn_timer]
    CMP AL,#0
    JMPNZ ts_dec
    MOV AL,#SPAWN_PERIOD
    STA [spawn_timer],AL

    MOV AL,#0
    STA [spawn_slot],AL
ts_find:
    LDA CL,[spawn_slot]
    MOV BX,#obst_active
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ts_spawn
    LDA AL,[spawn_slot]
    ADD AL,#1
    STA [spawn_slot],AL
    CMP AL,#N_OBST
    JMPNZ ts_find
    RET                          ; sin ranuras libres -- se intenta otra vuelta

ts_spawn:
    MOV AL,#1
    STA [BX],AL

    LDA CL,[spawn_slot]
    MOV BX,#obst_row
    ADD BX,CL
    MOV AL,#0
    STA [BX],AL

ts_lane_roll:
    CALL rnd
    AND AL,#0x03
    CMP AL,#3
    JMPZ ts_lane_roll
    STA [tmp2],AL
    LDA CL,[spawn_slot]
    MOV BX,#obst_lane
    ADD BX,CL
    LDA AL,[tmp2]
    STA [BX],AL

ts_type_roll:
    CALL rnd
    AND AL,#0x07
    CMP AL,#6
    JMPNC ts_type_roll
    STA [tmp2],AL
    LDA CL,[spawn_slot]
    MOV BX,#obst_type
    ADD BX,CL
    LDA AL,[tmp2]
    STA [BX],AL
    RET
ts_dec:
    SUB AL,#1
    STA [spawn_timer],AL
    RET

; ============================================================================
;  update_zebra / draw_zebra: un paso de cebra puramente decorativo que
;  cruza cada ZEBRA_PERIOD vueltas -- tres bandas discontinuas (dy=0,3,6)
;  de lado a lado de la carretera, sin comprobacion de choque ninguna.
; ============================================================================
update_zebra:
    LDA AL,[zebra_active]
    CMP AL,#0
    JMPNZ uz_move
    LDA AL,[zebra_timer]
    CMP AL,#0
    JMPNZ uz_dec
    MOV AL,#ZEBRA_PERIOD
    STA [zebra_timer],AL
    MOV AL,#1
    STA [zebra_active],AL
    MOV AL,#0
    STA [zebra_row],AL
    RET
uz_dec:
    SUB AL,#1
    STA [zebra_timer],AL
    RET
uz_move:
    LDA AL,[zebra_row]
    LDA BL,[speed]
    ADD AL,BL
    STA [zebra_row],AL
    CMP AL,#70
    JMPC uz_ret
    MOV AL,#0
    STA [zebra_active],AL
uz_ret:
    RET

draw_zebra:
    LDA AL,[zebra_active]
    CMP AL,#0
    JMPZ dz_ret

    MOV AL,#0
    STA [tmp3],AL                ; tmp3 = banda actual (0, 3 o 6)
dz_band:
    LDA AL,[zebra_row]
    LDA BL,[tmp3]
    ADD AL,BL
    STA [px_y],AL
    CMP AL,#64
    JMPNC dz_band_next

    MOV AL,#ROAD_L
    STA [tmp0],AL
dz_col:
    LDA AL,[tmp0]
    STA [px_x],AL
    CALL plot
    LDA AL,[tmp0]
    ADD AL,#4
    STA [tmp0],AL
    CMP AL,#ROAD_R
    JMPC dz_col

dz_band_next:
    LDA AL,[tmp3]
    ADD AL,#3
    STA [tmp3],AL
    CMP AL,#9
    JMPNZ dz_band
dz_ret:
    RET

; ============================================================================
;  update_obstacles: mueve cada obstaculo activo `speed` filas; en cuanto
;  cruza la fila del jugador comprueba el choque UNA sola vez (saltando o
;  en otro carril -> esquiva, mismo carril sin saltar y sin invulnerabilidad
;  -> choque) y lo desactiva; si todavia no ha llegado, lo dibuja con la
;  figura que le toque segun obst_type (OBST_TABLES/OBST_LENS).
; ============================================================================
update_obstacles:
    MOV AL,#0
    STA [obst_i],AL
uo_l:
    LDA CL,[obst_i]
    MOV BX,#obst_active
    ADD BX,CL
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uo_next

    LDA CL,[obst_i]
    MOV BX,#obst_row
    ADD BX,CL
    LDA AL,[BX]
    LDA DL,[speed]
    ADD AL,DL
    STA [BX],AL
    STA [tmp0],AL               ; tmp0 = fila nueva de este obstaculo

    CMP AL,#PLAYER_ROW
    JMPC uo_draw                 ; todavia no llega a la fila del jugador

    LDA AL,[jump_active]
    CMP AL,#0
    JMPNZ uo_dodge                ; saltando -> esquiva automatica

    LDA CL,[obst_i]
    MOV BX,#obst_lane
    ADD BX,CL
    LDA AL,[BX]
    LDA DL,[cur_lane]
    CMP AL,DL
    JMPNZ uo_dodge                ; carril distinto -> no choca

    CALL on_collision
    JMP uo_deactivate
uo_dodge:
    CALL award_dodge
uo_deactivate:
    LDA CL,[obst_i]
    MOV BX,#obst_active
    ADD BX,CL
    MOV AL,#0
    STA [BX],AL
    JMP uo_next

uo_draw:
    LDA CL,[obst_i]
    MOV BX,#obst_type
    ADD BX,CL
    LDA AL,[BX]
    STA [tmp1],AL                ; tmp1 = tipo de este obstaculo

    LDA CL,[tmp1]
    MOV BX,#OBST_LENS
    ADD BX,CL
    LDA AL,[BX]
    STA [spr_n],AL

    LDA AL,[tmp1]
    SHL AL                         ; x2: tabla de punteros de 16 bits
    MOV CL,AL
    MOV BX,#OBST_TABLES
    CALL read_ptr16
    MOV AL,BL
    STA [spr_lo],AL
    MOV AL,BH
    STA [spr_hi],AL

    LDA CL,[obst_i]
    MOV BX,#obst_lane
    ADD BX,CL
    LDA AL,[BX]
    MOV CL,AL
    MOV BX,#LANE_X
    ADD BX,CL
    LDA AL,[BX]
    STA [spr_cx],AL

    LDA AL,[tmp0]
    STA [spr_cy],AL
    CALL draw_filled_sprite

uo_next:
    LDA AL,[obst_i]
    ADD AL,#1
    STA [obst_i],AL
    CMP AL,#N_OBST
    JMPNZ uo_l
    RET

; --- award_dodge: puntos += velocidad actual (1..4), calculado con MUL de
; verdad (AX = 1 x velocidad) en vez de un simple +1 -- ir mas rapido
; tambien da mas puntos por cada obstaculo esquivado. Satura en 255. ------
award_dodge:
    MOV AL,#1
    LDA BL,[speed]
    MUL BL                        ; AX = 1 * velocidad = velocidad (AH=0,
                                   ; nunca desborda: velocidad <= 4)
    LDA BL,[score]
    ADD BL,AL
    JMPC ad_sat
    STA [score],BL
    MOV AL,#1
    STA [score_dirty],AL
    RET
ad_sat:
    MOV AL,#255
    STA [score],AL
    MOV AL,#1
    STA [score_dirty],AL
    RET

; --- on_collision: si no hay invulnerabilidad en curso, resta una vida,
; pita y arma un respiro de invulnerabilidad -----------------------------
on_collision:
    LDA AL,[invuln]
    CMP AL,#0
    JMPNZ oc_ret
    LDA AL,[lives]
    CMP AL,#0
    JMPZ oc_ret
    SUB AL,#1
    STA [lives],AL
    MOV AL,#INVULN_TICKS
    STA [invuln],AL
    MOV AL,#20                     ; duracion primero (ver aviso en do_jump)
    OUT (P_SND_DUR),AL
    MOV AL,#32
    OUT (P_SND_NOTE),AL
oc_ret:
    RET

tick_jump:
    LDA AL,[jump_active]
    CMP AL,#0
    JMPZ tj_ret
    SUB AL,#1
    STA [jump_active],AL
tj_ret:
    RET

tick_invuln:
    LDA AL,[invuln]
    CMP AL,#0
    JMPZ ti_ret
    SUB AL,#1
    STA [invuln],AL
ti_ret:
    RET

; ============================================================================
;  draw_scene: bordes de la carretera (rectos, sin curvas), separadores de
;  carril discontinuos y decoracion de los arcenes (arbusto/farola cada 32
;  filas), todo en un unico recorrido de las 64 filas de pantalla -- las
;  tres cosas se desplazan hacia abajo restando `scroll_y` antes del modulo,
;  igual truco que los pinos de fzero.asm.
; ============================================================================
draw_scene:
    MOV AL,#0
    STA [row_i],AL
ds_l:
    LDA AL,[row_i]
    STA [px_y],AL

    MOV AL,#ROAD_L
    STA [px_x],AL
    CALL plot
    MOV AL,#ROAD_R
    STA [px_x],AL
    CALL plot

    LDA AL,[row_i]
    LDA BL,[scroll_y]
    SUB AL,BL
    AND AL,#0x08
    JMPNZ ds_nodiv
    MOV AL,#DIVX1
    STA [px_x],AL
    CALL plot
    MOV AL,#DIVX2
    STA [px_x],AL
    CALL plot
ds_nodiv:

    LDA AL,[row_i]
    LDA BL,[scroll_y]
    SUB AL,BL
    AND AL,#0x1F
    STA [tmp0],AL
    CMP AL,#0
    JMPZ ds_bush
    CMP AL,#16
    JMPNZ ds_side_done

    LDA AL,[row_i]
    STA [spr_cy],AL
    MOV BX,#light_spr
    MOV AL,BL
    STA [spr_lo],AL
    MOV AL,BH
    STA [spr_hi],AL
    MOV AL,#LIGHT_LEN
    STA [spr_n],AL
    MOV AL,#SIDE_LX
    STA [spr_cx],AL
    CALL draw_filled_sprite
    MOV AL,#SIDE_RX
    STA [spr_cx],AL
    CALL draw_filled_sprite
    JMP ds_side_done

ds_bush:
    LDA AL,[row_i]
    STA [spr_cy],AL
    MOV BX,#bush_spr
    MOV AL,BL
    STA [spr_lo],AL
    MOV AL,BH
    STA [spr_hi],AL
    MOV AL,#BUSH_LEN
    STA [spr_n],AL
    MOV AL,#SIDE_LX
    STA [spr_cx],AL
    CALL draw_filled_sprite
    MOV AL,#SIDE_RX
    STA [spr_cx],AL
    CALL draw_filled_sprite

ds_side_done:
    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#64
    JMPNZ ds_l
    RET

; ============================================================================
;  draw_player: elige la tabla de sprite segun el estado (saltando siempre
;  gana; si no, recto/inclinado segun tilt_state) y la dibuja en
;  (player_x, PLAYER_ROW).
; ============================================================================
draw_player:
    LDA AL,[jump_active]
    CMP AL,#0
    JMPZ dp_ground
    MOV BX,#player_jump
    JMP dp_go
dp_ground:
    LDA AL,[tilt_state]
    CMP AL,#1
    JMPZ dp_left
    CMP AL,#2
    JMPZ dp_right
    MOV BX,#player_normal
    JMP dp_go
dp_left:
    MOV BX,#player_tilt_l
    JMP dp_go
dp_right:
    MOV BX,#player_tilt_r
dp_go:
    MOV AL,BL
    STA [spr_lo],AL
    MOV AL,BH
    STA [spr_hi],AL
    MOV AL,#PLAYER_LEN
    STA [spr_n],AL
    LDA AL,[player_x]
    STA [spr_cx],AL
    MOV AL,#PLAYER_ROW
    STA [spr_cy],AL
    CALL draw_filled_sprite
    RET

; ============================================================================
;  draw_hud: vidas como corazones grandes (altura de un caracter, ~8 px)
;  arriba a la derecha, sobre una caja negra que se limpia cada fotograma
;  (shadow_box con relleno 0) para que no se mezclen con nada que pase por
;  debajo de esa esquina. La puntuacion (texto, celda opaca) va aparte, ver
;  update_score_text.
; ============================================================================
draw_hud:
    MOV AL,#96
    STA [gb_x],AL
    MOV AL,#0
    STA [gb_y],AL
    MOV AL,#4
    STA [gb_wb],AL
    MOV AL,#10
    STA [gb_ht],AL
    MOV AL,#0
    CALL shadow_box             ; AL = valor de relleno -> 0 = negro

    MOV AL,#100
    STA [hx],AL
    MOV AL,#0
    STA [tmp0],AL
dh_l:
    LDA AL,[tmp0]
    LDA BL,[lives]
    CMP AL,BL
    JMPNC dh_done

    MOV BX,#heart_spr
    MOV AL,BL
    STA [spr_lo],AL
    MOV AL,BH
    STA [spr_hi],AL
    MOV AL,#HEART_LEN
    STA [spr_n],AL
    MOV AL,#6
    STA [spr_cy],AL
    LDA AL,[hx]
    STA [spr_cx],AL
    CALL draw_filled_sprite

    LDA AL,[hx]
    ADD AL,#12
    STA [hx],AL
    LDA AL,[tmp0]
    ADD AL,#1
    STA [tmp0],AL
    JMP dh_l
dh_done:
    RET

; ============================================================================
;  draw_filled_sprite: motor generico de dibujo -- lee spr_n filas de 3
;  bytes (dy,xoff,hw con signo) desde la tabla spr_lo/spr_hi y rellena, para
;  cada una que caiga dentro de pantalla, una franja horizontal de
;  2*hw+1 pixeles centrada en (spr_cx+xoff, spr_cy+dy). El offset de cada
;  fila dentro de la tabla (indice*3) se calcula con `MUL` de verdad en vez
;  de una tabla indexada byte a byte -- ver la nota de cabecera.
; ============================================================================
draw_filled_sprite:
    MOV AL,#0
    STA [spr_idx],AL
dfs_l:
    LDA AL,[spr_idx]
    LDA BL,[spr_n]
    CMP AL,BL
    JMPNC dfs_done

    LDA AL,[spr_idx]
    MOV BL,#3
    MUL BL                       ; AX = indice*3 (AH siempre 0: indice chico)
    MOV CL,AL
    LDA BL,[spr_lo]
    LDA BH,[spr_hi]
    ADD BX,CL   ; BX = tabla + indice*3

    LDA AL,[BX]
    STA [tmp_dy],AL
    INC BX
    LDA AL,[BX]
    STA [tmp_xoff],AL
    INC BX
    LDA AL,[BX]
    STA [tmp_hw],AL

    LDA AL,[spr_cy]
    LDA BL,[tmp_dy]
    ADD AL,BL
    STA [px_y],AL
    CMP AL,#64
    JMPNC dfs_next                ; se sale por arriba/abajo -- no dibuja esta fila

    LDA AL,[spr_cx]
    LDA BL,[tmp_xoff]
    ADD AL,BL
    LDA BL,[tmp_hw]
    SUB AL,BL
    STA [tmp_xi],AL
    LDA AL,[tmp_hw]
    SHL AL
    ADD AL,#1
    STA [tmp_cnt],AL
dfs_row:
    LDA AL,[tmp_xi]
    STA [px_x],AL
    CALL plot
    LDA AL,[tmp_xi]
    ADD AL,#1
    STA [tmp_xi],AL
    LDA AL,[tmp_cnt]
    SUB AL,#1
    STA [tmp_cnt],AL
    JMPNZ dfs_row

dfs_next:
    LDA AL,[spr_idx]
    ADD AL,#1
    STA [spr_idx],AL
    JMP dfs_l
dfs_done:
    RET

; ============================================================================
;  score_digits: separa [score] (0..255) en digit_h/digit_t/digit_u con DOS
;  divisiones de hardware (`DIV`, familia 28) en vez del bucle de restas de
;  fzero.asm/esquiva.asm -- ver la nota de cabecera.
; ============================================================================
score_digits:
    MOV AH,#0
    LDA AL,[score]
    MOV BL,#100
    DIV BL                      ; AL = centenas (0-2), AH = resto (0-99)
    MOV CL,AL
    MOV AL,AH
    MOV AH,#0
    MOV BL,#10
    DIV BL                      ; AL = decenas (0-9), AH = unidades (0-9)
    MOV DL,AL
    MOV DH,AH

    MOV AL,CL
    ADD AL,#'0'
    STA [digit_h],AL
    MOV AL,DL
    ADD AL,#'0'
    STA [digit_t],AL
    MOV AL,DH
    ADD AL,#'0'
    STA [digit_u],AL
    RET

; --- update_score_text: "PTS:nnn" arriba a la izquierda (capa de texto,
; celda opaca -- siempre se lee encima de los graficos), solo se reescribe
; si [score_dirty] esta puesto (igual que fzero.asm) -----------------------
update_score_text:
    LDA AL,[score_dirty]
    CMP AL,#0
    JMPZ ust_ret
    MOV AL,#0
    STA [score_dirty],AL

    MOV BX,#s_pts
    MOV CX,#0x0000
    CALL puts

    CALL score_digits
    LDA BL,[digit_h]
    MOV CX,#0x0004
    CALL putc
    LDA BL,[digit_t]
    MOV CX,#0x0005
    CALL putc
    LDA BL,[digit_u]
    MOV CX,#0x0006
    CALL putc
ust_ret:
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- plot: dibuja (px_x,px_y) en `shadow`, salvo que px_x tenga el bit 7
; puesto (fuera de 0..127 -- tanto por desbordar como por envolver en
; negativo, ver fzero.asm) --------------------------------------------------
plot:
    LDA AL,[px_x]
    AND AL,#0x80
    JMPNZ plot_skip
    CALL shadow_set_px
plot_skip:
    RET

; --- idx_ptr: BX = (BL/BH iniciales) + CL, con acarreo -------------------
idx_ptr:
    ADD BX,CL
    RET

; --- read_ptr16: BX = base de una tabla de punteros de 16 bits; CL = indice
; ya multiplicado x2 por quien llama; sale BX = puntero leido de tabla[CL].
read_ptr16:
    ADD BX,CL
    LDA AL,[BX]
    STA [rp_lo],AL
    INC BX
    LDA AL,[BX]
    STA [rp_hi],AL
    LDA BL,[rp_lo]
    LDA BH,[rp_hi]
    RET

; --- shadow_set_px: enciende el pixel (px_x,px_y) en `shadow` (RAM) -------
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

; --- calc_pix: de (px_x,px_y) saca puerto (pix_lo/pix_hi) + mascara -------
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

; --- shadow_box: rellena con AL una caja byte-alineada (gb_x,gb_y,gb_wb en
; bytes, gb_ht en filas) directamente en `shadow` -- mismo calculo de
; direccion que shadow_fillbox de esquiva.asm, pero con el valor de relleno
; como parametro en vez de 0xFF fijo (aqui se usa con 0 para la caja negra
; de los corazones, ver draw_hud). ----------------------------------------
shadow_box:
    STA [sf_boxval],AL
    LDA AL,[gb_ht]
    STA [fs_h],AL
    LDA AL,[gb_y]
    STA [fs_row],AL
sbx_l:
    LDA AL,[fs_row]
    STA [tmp0],AL
    AND AL,#0x0F
    SHL AL,#4
    LDA BL,[gb_x]
    SHR BL,#3
    ADD AL,BL
    STA [sfb_off],AL
    LDA AL,[tmp0]
    SHR AL,#4
    STA [sfb_pag],AL

    MOV BX,#shadow
    LDA CL,[sfb_off]
    ADD BX,CL
    LDA AL,[sfb_pag]
    ADD BH,AL

    LDA CL,[gb_wb]
    LDA AL,[sf_boxval]
sbx_cl:
    STA [BX],AL
    INC BX
    SUB CL,#1
    JMPNZ sbx_cl

    LDA AL,[fs_row]
    ADD AL,#1
    STA [fs_row],AL
    LDA AL,[fs_h]
    SUB AL,#1
    STA [fs_h],AL
    JMPNZ sbx_l
    RET

; --- clr_shadow: pone a 0 los 1024 bytes de `shadow` -- el PRIMER byte se
; pone a 0 a mano y MOVB propaga ese 0 en cascada a los 1023 restantes
; (origen/destino solapados en 1, ver docs/isa.md SS4d y fzero.asm) --------
clr_shadow:
    MOV AL,#0
    STA [shadow],AL
    MOV BX,#shadow
    MOV DX,#shadow+1
    MOV CX,#0x03FF              ; 1023 bytes
    MOVB
    RET

; --- blit: copia `shadow` al framebuffer real, solo lo que haya cambiado -
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

; --- clsg: apaga el framebuffer real completo (0x0000..0x03FF) -----------
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

; --- clst: borra la capa de texto (0x0400..0x04FF) -------------------------
clst:
    MOV BX,#0x0400
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
    RET


; ============================================================================
;  RECORD (EEPROM del slot) -- ver P_EEP_* arriba
; ============================================================================
; --- load_record: [record] = el grabado en la flash (0 si no hay ninguno) ---
load_record:
    OUT (P_EEP_LOAD),AL
    IN  AL,(P_EEP_BASE)
    CMP AL,#REC_MAGIC
    MOV AL,#0
    JMPNZ lr_set
    IN  AL,(P_EEP_BASE+1)
lr_set:
    STA [record],AL
    RET

; --- show_record: carga el record y escribe "RECORD nnn" en CH=fila, CL=col --
show_record:
    CALL load_record
    LDA AL,[record]
    MOV AH,#0
    MOV BL,#100
    DIV BL
    ADD AL,#'0'
    STA [rec_d],AL
    MOV AL,AH
    MOV AH,#0
    MOV BL,#10
    DIV BL
    ADD AL,#'0'
    STA [rec_d+1],AL
    MOV AL,AH
    ADD AL,#'0'
    STA [rec_d+2],AL
    MOV BX,#s_record
    CALL puts
    RET

; --- save_record: si [score] supera el record, lo graba en la flash.
; Sale AL = 1 si es record nuevo, 0 si no. ----------------------------------
save_record:
    LDA AL,[score]
    LDA BL,[record]
    CMP BL,AL
    MOV AL,#0
    JMPNC svr_done          ; record >= puntos: nada que grabar
    LDA AL,[score]
    STA [record],AL
    OUT (P_EEP_LOAD),AL     ; parte del contenido real de la EEPROM
    OUT (P_EEP_BASE+1),AL
    MOV AL,#REC_MAGIC
    OUT (P_EEP_BASE),AL
    OUT (P_EEP_SAVE),AL
    MOV AL,#1
svr_done:
    RET

; --- putc: BL = caracter, CL = col, CH = fila ------------------------------
putc:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
    RET

; --- puts: BL/BH = puntero asciiz, CL = col, CH = fila ---------------------
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

; --- rnd: combina 3 pasos de LFSR (mismo truco que fzero.asm, para que el
; carril/tipo al azar no se note periodico) --------------------------------
rnd:
    CALL rnd_raw
    MOV DL,AL
    CALL rnd_raw
    XOR DL,AL
    CALL rnd_raw
    XOR DL,AL
    MOV AL,DL
    RET

rnd_raw:
    LDA AL,[seed]
    SHR AL
    JMPNC rr_n
    XOR AL,#0xB8
rr_n:
    STA [seed],AL
    RET

; --- frame_wait: AL = pasos del temporizador 3 (8 ms/paso) -----------------
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
s_title: .asciiz "SKATE OH MY!"
s_record: .ascii "RECORD "
rec_d:    .asciiz "000"
s_newrec: .asciiz "NEW RECORD!"
s_help1: .asciiz "TURN: CHANGE LANE"
s_help2: .asciiz "PRESS: JUMP"
s_help3: .asciiz "PRESS TO START"
s_over:  .asciiz "GAME OVER"
s_score: .asciiz "SCORE:"
s_pts:   .asciiz "PTS:"

LANE_X: .db 32, 64, 96

; --- tablas de sprite: cada fila = (dy, xoff, hw) con signo, ver la nota de
; cabecera y draw_filled_sprite. ---------------------------------------------
player_normal:
    .db 252,0,1
    .db 253,0,2
    .db 254,0,1
    .db 255,0,1
    .db 0,0,1
    .db 1,0,2
    .db 2,0,3
    .db 3,0,3

player_tilt_l:
    .db 252,254,1
    .db 253,254,2
    .db 254,255,1
    .db 255,255,1
    .db 0,0,1
    .db 1,0,2
    .db 2,0,3
    .db 3,0,3

player_tilt_r:
    .db 252,2,1
    .db 253,2,2
    .db 254,1,1
    .db 255,1,1
    .db 0,0,1
    .db 1,0,2
    .db 2,0,3
    .db 3,0,3

player_jump:
    .db 251,0,2
    .db 252,0,3
    .db 253,0,2
    .db 254,0,2
    .db 255,0,2
    .db 0,0,3
    .db 1,0,4
    .db 2,0,4

bike_spr:
    .db 253,0,1
    .db 254,0,2
    .db 255,0,1
    .db 0,0,2
    .db 1,0,1

car_spr:
    .db 253,0,2
    .db 254,0,3
    .db 255,0,3
    .db 0,0,3
    .db 1,0,3
    .db 2,0,2

truck_spr:
    .db 254,0,3
    .db 255,0,4
    .db 0,0,4
    .db 1,0,4
    .db 2,0,4
    .db 3,0,4
    .db 4,0,4
    .db 5,0,3

banana_spr:
    .db 255,254,1
    .db 0,0,1
    .db 1,2,1

dog_spr:
    .db 254,0,1
    .db 255,1,1
    .db 0,0,2
    .db 1,255,1

people_spr:
    .db 255,250,1
    .db 0,0,1
    .db 1,6,1

bush_spr:
    .db 255,0,1
    .db 0,0,2
    .db 1,0,1

light_spr:
    .db 253,0,1
    .db 254,0,0
    .db 255,0,0
    .db 0,0,0

; corazon: dos "orejas" arriba (mismo dy, dos entradas con xoff distinto) y
; un cuerpo que se va estrechando hasta un pico abajo.
heart_spr:
    .db 253,254,1
    .db 253,2,1
    .db 254,0,3
    .db 255,0,3
    .db 0,0,2
    .db 1,0,2
    .db 2,0,1
    .db 3,0,0

; --- tablas de obstaculo, indexadas por obst_type (0..5) -------------------
OBST_TABLES: .dw bike_spr, car_spr, truck_spr, banana_spr, dog_spr, people_spr
OBST_LENS:   .db BIKE_LEN, CAR_LEN, TRUCK_LEN, BANANA_LEN, DOG_LEN, PEOPLE_LEN

; ============================================================================
;  VARIABLES
; ============================================================================
score:          .space 1
record:   .space 1      ; record cargado de la EEPROM (ver load_record)
lives:          .space 1
speed:          .space 1
cur_lane:       .space 1
player_x:       .space 1
target_x:       .space 1
tilt_state:     .space 1
jump_active:    .space 1
invuln:         .space 1
scroll_y:       .space 1
spawn_timer:    .space 1
spawn_slot:     .space 1
zebra_active:   .space 1
zebra_row:      .space 1
zebra_timer:    .space 1
seed:           .space 1
dir_pos_prev:   .space 1
dat_pos_prev:   .space 1
dir_btn_prev:   .space 1
dat_btn_prev:   .space 1
start_hit:      .space 1
score_dirty:    .space 1
row_i:          .space 1
obst_i:         .space 1
hx:             .space 1

tmp0:           .space 1
tmp1:           .space 1
tmp2:           .space 1
tmp3:           .space 1
digit_h:        .space 1
digit_t:        .space 1
digit_u:        .space 1
rp_lo:          .space 1
rp_hi:          .space 1

px_x:           .space 1
px_y:           .space 1
pix_lo:         .space 1
pix_hi:         .space 1
pix_mask:       .space 1

gb_x:           .space 1
gb_y:           .space 1
gb_wb:          .space 1
gb_ht:          .space 1
fs_h:           .space 1
fs_row:         .space 1
sfb_off:        .space 1
sfb_pag:        .space 1
sf_boxval:      .space 1

spr_lo:         .space 1
spr_hi:         .space 1
spr_n:          .space 1
spr_idx:        .space 1
spr_cx:         .space 1
spr_cy:         .space 1
tmp_dy:         .space 1
tmp_xoff:       .space 1
tmp_hw:         .space 1
tmp_xi:         .space 1
tmp_cnt:        .space 1

; --- estado de los 4 obstaculos: 4 arrays de 4 bytes, CONTIGUOS y en este
; orden a proposito -- game_init los limpia de un tiron con MOVW (16 bytes
; = 2 a mano + 7 palabras en cascada, ver su comentario). No insertar nada
; entre ellos. ---------------------------------------------------------------
obst_active:    .space 4
obst_row:       .space 4
obst_lane:      .space 4
obst_type:      .space 4

; shadow: copia del framebuffer en RAM ("doble buffer" software). Va la
; ultima de todo: es un .space sin datos reales, asi que no cuenta para el
; recorte del .bin (ver cabecera de tools/casm.py).
shadow: .space 1024
