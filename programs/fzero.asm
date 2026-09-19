; ============================================================================
;  fzero.asm  -  "EXPRESS X-1", esquiva-obstaculos pseudo-3D estilo F-Zero
;                (compi) -- pensado para poner a prueba la CPU emulada
;
;  Una carretera que se ve en perspectiva (fila 32..63 de la pantalla: cuanto
;  mas abajo, mas cerca y mas ancha) con curvas que van cambiando solas, una
;  nave que el jugador dirige, y obstaculos que bajan por la carretera y hay
;  que esquivar. Musica de fondo por el zumbador. Doble buffer por software
;  (como cubo.asm/pong.asm) para que no parpadee.
;
;  MANEJO (en EJECUTAR + CONTINUO):
;     encoder DIRECCION (izquierdo) gira  -> dirige la nave (izq/dcha)
;     encoder DATOS      (derecho)  gira  -> acelerador (1..4, mas obstaculos
;                                            por segundo cuanto mas alto)
;     encoder DIRECCION pulsa -> dispara (mata el obstaculo que alcance)
;     encoder DATOS     pulsa -> salta (esquiva automaticamente el obstaculo
;                                        que llegue mientras dura el salto)
;     cualquier pulsador, en la pantalla de titulo o de "GAME OVER" -> empieza
;
;  COMO FUNCIONA LA CARRETERA (sin multiplicacion real, la CPU no tiene MUL):
;     - road_width[fila]: tabla fija (32 bytes), el ancho de la carretera en
;       cada una de las 32 filas (0=horizonte, 31=mas cerca). Se calculo una
;       vez en Python (progresion lineal) y se guarda como datos.
;     - row_center_cache[fila]: el centro (X) de cada fila, pero esta vez es
;       una tabla PERSISTENTE (no se recalcula desde cero cada fotograma):
;       cada vuelta del bucle, `scroll_road` la desplaza una posicion hacia
;       la camara (fila[i] = fila[i-1], de la 31 a la 1) e inyecta un valor
;       nuevo en la fila 0 (el horizonte), moviendolo `curve_slope` (con
;       signo, -2..+2) respecto al que tenia. Como ese valor tarda ~31
;       vueltas en "llegar" hasta la fila del jugador, una curva se ve venir
;       desde lejos en vez de aparecer de golpe -- igual que en un juego de
;       coches de verdad. `curve_slope` en si cambia muy despacio (un paso
;       hacia un objetivo elegido al azar cada rato).
;     - draw_road solo LEE row_center_cache fila a fila para dibujar los dos
;       bordes; los obstaculos (que "viven" en una fila concreta) la usan
;       igual para saber donde esta el centro de SU fila sin recalcular nada.
;     - Los obstaculos van en uno de 3 carriles (izquierda/centro/derecha),
;       como offset de +-ancho/4 respecto al centro de su fila -- de nuevo,
;       ancho/4 es un simple SHR SHR, no una multiplicacion.
;     - Fuera de los bordes, cada 4 filas, se dibuja un arbolito (alterna
;       bajo/alto). Esas filas se calculan como (fila - tree_scroll) mod 4,
;       y `tree_scroll` avanza `speed` unidades cada vuelta -- los arbolitos
;       "fluyen" hacia la camara igual que la carretera, dando sensacion de
;       movimiento (antes eran siempre las mismas 8 filas fijas).
;     - Si la nave llega a tocar un borde (el "clamping" de control_ship
;       tiene que corregirla), `speed` se resetea a SPEED_MIN de golpe: no
;       pierdes una vida, pero vas lento hasta que aceleras otra vez a mano
;       con el encoder DATOS.
;     - Los obstaculos persiguen a la nave MUY despacio: cada CHASE_PERIOD
;       vueltas, cada obstaculo activo se acerca un carril hacia el carril
;       actual de la nave (calculado comparando ship_x con el centro/ancho de
;       la fila 31) -- lo bastante lento para que moverse siempre baste para
;       escapar.
;     - Al fondo, por encima de la carretera (filas 0..31 de la pantalla), se
;       dibuja una silueta de montañas (mountain_h, tabla fija de 32 alturas)
;       muestreada cada 4 columnas. Se desplaza lateralmente con
;       `row_center_cache[0] - 64` (cuanto se ha desviado el horizonte de la
;       carretera): cuando la carretera gira, las montañas se mueven con
;       ella, como en un juego de coches de verdad.
;
;  ARMAS:
;     - Disparo (boton DIRECCION): sale de la nave y viaja hacia el horizonte
;       (SHOT_SPEED filas por vuelta, mas rapido que cualquier obstaculo).
;       Si pasa cerca de un obstaculo activo (misma comprobacion de distancia
;       que un choque), lo destruye y suma un punto. Solo un disparo a la vez
;       (hay que esperar a que acierte o llegue al horizonte para poder
;       disparar otra vez).
;     - Salto (boton DATOS): `jump_active` cuenta atras JUMP_TICKS vueltas;
;       mientras dura, cualquier obstaculo que llegue a la fila de la nave se
;       esquiva automaticamente (sin comprobar carril) y la nave se dibuja
;       JUMP_RISE pixeles mas arriba, para que se note que esta en el aire.
;
;  SEGURIDAD DE RANGO: cualquier coordenada X que se salga de 0..127 (por
;  ejemplo si la curva es muy pronunciada varias filas seguidas) tiene el bit
;  7 puesto; `plot` comprueba ese bit y simplemente no dibuja ese pixel en vez
;  de arriesgarse a que `calc_pix` calcule un puerto invalido (ver el aviso de
;  calc_pix en programs/cubo.asm). Ademas, `row_center_cache[0]` (el horizonte,
;  el unico sitio donde se inyectan valores nuevos) se mantiene siempre dentro
;  de [35,92] en `scroll_road`, asi que en la practica nunca hace falta.
;
;  SONIDO: la mayor parte del tiempo suena un zumbido de motor cuya frecuencia
;  depende de `speed` (mas rapido = mas agudo), con un ligero temblor de
;  +-8 Hz cada vuelta para que no sea un pitido plano. Cada MUSIC_PERIOD
;  vueltas ese zumbido se interrumpe un instante para tocar una nota de un
;  riff corto y energico (PORT_SND_NOTE), y a la vuelta siguiente el motor
;  retoma el canal -- el zumbador es monofonico, asi que no pueden sonar los
;  dos a la vez, pero turnandose se nota tanto el motor como la musica.
;
;  Ensamblar y enviar al slot 7:
;     python3 tools/casm.py programs/fzero.asm -o programs/fzero.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/fzero.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 7
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_POS = 0x0600
P_DIR_BTN = 0x0601
P_DAT_POS = 0x0602
P_DAT_BTN = 0x0603
P_T3      = 0x0623      ; ritmo del bucle de juego (8 ms/paso)
P_SND_FREQ_LO = 0x0630
P_SND_FREQ_HI = 0x0631
P_SND_NOTE = 0x0632
P_SND_DUR  = 0x0633

; --- constantes de juego -----------------------------------------------------
N_OBST      = 4          ; obstaculos activos como maximo a la vez
COLLIDE_DIST = 6         ; distancia (px) por debajo de la cual hay choque
SHIP_HALF_W  = 4
SPEED_MIN    = 1
SPEED_MAX    = 4
LIVES_START  = 3
INVULN_TICKS = 15
SPAWN_PERIOD = 12
CURVE_PERIOD = 45
MUSIC_PERIOD = 10        ; vueltas de zumbido de motor entre cada nota del riff
TICK_STEPS   = 15        ; pasos de P_T3 (8 ms) por vuelta del bucle -> 120 ms/vuelta
MELODY_LEN   = 8
SHIP_PIX_LEN = 21
OBST_PIX_LEN = 5
SHIP_BASE_Y  = 61        ; fila de referencia (dy=0) de SHIP_PIX
CHASE_PERIOD = 10        ; vueltas entre cada paso de persecucion de los obstaculos
SHOT_SPEED   = 6         ; filas por vuelta que avanza un disparo
SHOT_START_ROW = 28      ; fila donde nace el disparo (justo delante de la nave)
JUMP_TICKS   = 10        ; vueltas que dura un salto
JUMP_RISE    = 5         ; pixeles que sube la nave al dibujarse mientras salta
MOUNTAIN_LEN = 32        ; muestras de la silueta de montañas (cada 4 columnas)

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

    MOV BL,#lo(s_title)
    MOV BH,#hi(s_title)
    MOV CL,#4
    MOV CH,#2
    CALL puts

    MOV BL,#lo(s_help1)
    MOV BH,#hi(s_help1)
    MOV CL,#1
    MOV CH,#4
    CALL puts

    MOV BL,#lo(s_help2)
    MOV BH,#hi(s_help2)
    MOV CL,#1
    MOV CH,#5
    CALL puts

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
    MOV AL,#1
    STA [speed],AL
    MOV AL,#64
    STA [ship_x],AL
    MOV AL,#0
    STA [curve_slope],AL
    STA [curve_target],AL
    STA [invuln],AL
    STA [melody_i],AL
    STA [music_countdown],AL
    STA [engine_phase],AL
    STA [tree_scroll],AL
    STA [ship_lane],AL
    STA [shot_active],AL
    STA [jump_active],AL
    MOV AL,#CURVE_PERIOD
    STA [curve_timer],AL
    MOV AL,#SPAWN_PERIOD
    STA [spawn_timer],AL
    MOV AL,#CHASE_PERIOD
    STA [chase_timer],AL

    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL

    MOV DL,#0
gi_clr_obst:
    MOV CL,DL
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    ADD DL,#1
    CMP DL,#N_OBST
    JMPNZ gi_clr_obst

    ; row_center_cache empieza plana (todas las filas centradas en 64):
    ; scroll_road ya se encarga de irla curvando vuelta a vuelta.
    MOV AL,#0
    STA [row_i],AL
gi_ric_l:
    LDA CL,[row_i]
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    MOV AL,#64
    STA [BX],AL
    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#32
    JMPNZ gi_ric_l

    MOV AL,#1
    STA [score_dirty],AL
    STA [lives_dirty],AL
    CALL update_hud

; ============================================================================
;  BUCLE PRINCIPAL DE JUEGO
; ============================================================================
game_l:
    CALL control_ship
    CALL control_weapons
    CALL update_curve
    CALL update_sound
    CALL try_spawn
    CALL tick_invuln
    CALL tick_jump
    CALL update_shot
    CALL clr_shadow
    CALL scroll_road
    CALL draw_mountains
    CALL draw_road
    CALL draw_shot
    CALL update_obstacles
    CALL draw_ship
    CALL blit
    CALL update_hud

    LDA AL,[lives]
    CMP AL,#0
    JMPZ game_over

    MOV AL,#TICK_STEPS
    CALL frame_wait
    JMP game_l

; ============================================================================
;  PANTALLA DE FIN DE PARTIDA
; ============================================================================
game_over:
    CALL clst
    MOV BL,#lo(s_over)
    MOV BH,#hi(s_over)
    MOV CL,#5
    MOV CH,#2
    CALL puts

    MOV BL,#lo(s_score)
    MOV BH,#hi(s_score)
    MOV CL,#3
    MOV CH,#4
    CALL puts
    CALL score_digits
    LDA BL,[digit_h]
    MOV CL,#12
    MOV CH,#4
    CALL putc
    LDA BL,[digit_t]
    MOV CL,#13
    MOV CH,#4
    CALL putc
    LDA BL,[digit_u]
    MOV CL,#14
    MOV CH,#4
    CALL putc

    MOV BL,#lo(s_help2)
    MOV BH,#hi(s_help2)
    MOV CL,#1
    MOV CH,#6
    CALL puts

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
;  control_ship: encoder DIRECCION dirige, encoder DATOS ajusta la velocidad;
;  luego acota ship_x a los bordes de la carretera en la fila mas cercana.
; ============================================================================
control_ship:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_prev],CL
    MOV BL,AL
    LDA AL,[ship_x]
    ADD AL,BL
    ADD AL,BL
    STA [ship_x],AL

    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_prev],CL
    CMP AL,#0
    JMPZ cs_speed_done
    AND AL,#0x80
    JMPZ cs_speed_up
    LDA AL,[speed]
    CMP AL,#SPEED_MIN
    JMPZ cs_speed_done
    SUB AL,#1
    STA [speed],AL
    JMP cs_speed_done
cs_speed_up:
    LDA AL,[speed]
    CMP AL,#SPEED_MAX
    JMPZ cs_speed_done
    ADD AL,#1
    STA [speed],AL
cs_speed_done:

    MOV AL,#0
    STA [wall_hit],AL

    LDA AL,[left31]
    AND AL,#0x80
    JMPNZ cs_no_left
    LDA AL,[ship_x]
    LDA BL,[left31]
    ADD BL,#SHIP_HALF_W
    CMP AL,BL
    JMPNC cs_no_left
    MOV AL,BL
    STA [ship_x],AL
    MOV AL,#1
    STA [wall_hit],AL
cs_no_left:

    LDA AL,[right31]
    AND AL,#0x80
    JMPNZ cs_no_right
    LDA AL,[ship_x]
    LDA BL,[right31]
    SUB BL,#SHIP_HALF_W
    CMP AL,BL
    JMPC cs_no_right
    MOV AL,BL
    STA [ship_x],AL
    MOV AL,#1
    STA [wall_hit],AL
cs_no_right:

    ; tocar un borde resetea la velocidad de golpe -- hay que acelerar otra
    ; vez a mano con el encoder DATOS (no quita vidas, solo frena)
    LDA AL,[wall_hit]
    CMP AL,#0
    JMPZ cs_done
    MOV AL,#SPEED_MIN
    STA [speed],AL
cs_done:
    RET

; ============================================================================
;  control_weapons: flanco de subida del boton DIRECCION -> dispara (si no
;  hay ya un disparo en el aire); flanco de subida del boton DATOS -> salta
;  (si no se esta saltando ya). Reutiliza dir_btn_prev/dat_btn_prev, las
;  mismas variables que read_start_press usa en las pantallas de titulo/fin
;  de partida -- no hace falta reiniciarlas al entrar en game_init, siguen
;  reflejando el ultimo estado real leido de los pulsadores.
; ============================================================================
control_weapons:
    IN  AL,(P_DIR_BTN)
    STA [tmp0],AL
    LDA BL,[dir_btn_prev]
    LDA CL,[tmp0]
    STA [dir_btn_prev],CL
    CMP CL,#0
    JMPZ cw_fire_done
    CMP BL,#0
    JMPNZ cw_fire_done           ; ya estaba pulsado -> no es flanco
    LDA AL,[shot_active]
    CMP AL,#0
    JMPNZ cw_fire_done           ; ya hay un disparo en el aire
    MOV AL,#1
    STA [shot_active],AL
    MOV AL,#SHOT_START_ROW
    STA [shot_row],AL
    LDA AL,[ship_x]
    STA [shot_x],AL
    MOV AL,#69
    OUT (P_SND_NOTE),AL
    MOV AL,#4
    OUT (P_SND_DUR),AL
cw_fire_done:

    IN  AL,(P_DAT_BTN)
    STA [tmp0],AL
    LDA BL,[dat_btn_prev]
    LDA CL,[tmp0]
    STA [dat_btn_prev],CL
    CMP CL,#0
    JMPZ cw_jump_done
    CMP BL,#0
    JMPNZ cw_jump_done
    LDA AL,[jump_active]
    CMP AL,#0
    JMPNZ cw_jump_done           ; ya esta saltando
    MOV AL,#JUMP_TICKS
    STA [jump_active],AL
cw_jump_done:
    RET

; ============================================================================
;  update_curve: cada CURVE_PERIOD vueltas elige un nuevo objetivo (-2 o +2)
;  y cada vuelta mueve curve_slope un paso hacia el objetivo. El valor en si
;  se aplica en `scroll_road`, no aqui (ver la nota de la cabecera).
; ============================================================================
update_curve:
    LDA AL,[curve_timer]
    CMP AL,#0
    JMPNZ uc_dec
    MOV AL,#CURVE_PERIOD
    STA [curve_timer],AL

    CALL rnd
    AND AL,#0x01
    MOV CL,AL
    MOV BL,#lo(curve_options)
    MOV BH,#hi(curve_options)
    CALL idx_ptr
    LDA AL,[BX]
    STA [curve_target],AL
    JMP uc_move
uc_dec:
    SUB AL,#1
    STA [curve_timer],AL
uc_move:
    LDA AL,[curve_slope]
    LDA BL,[curve_target]
    CMP AL,BL
    JMPZ uc_done
    SUB AL,BL
    JMPN uc_inc
    LDA AL,[curve_slope]
    SUB AL,#1
    STA [curve_slope],AL
    JMP uc_done
uc_inc:
    LDA AL,[curve_slope]
    ADD AL,#1
    STA [curve_slope],AL
uc_done:
    RET

; ============================================================================
;  update_sound: casi siempre alimenta un zumbido de motor cuya frecuencia
;  depende de `speed` (engine_freq_lo/hi, indexadas por speed); cada
;  MUSIC_PERIOD vueltas lo interrumpe un instante para tocar la siguiente
;  nota de un riff corto (PORT_SND_NOTE) -- el zumbador es monofonico, asi
;  que turnan el mismo canal en vez de sonar a la vez.
; ============================================================================
update_sound:
    LDA AL,[music_countdown]
    CMP AL,#0
    JMPNZ us_engine

    MOV AL,#MUSIC_PERIOD
    STA [music_countdown],AL

    LDA AL,[melody_i]
    ADD AL,#1
    CMP AL,#MELODY_LEN
    JMPNZ us_idx_ok
    MOV AL,#0
us_idx_ok:
    STA [melody_i],AL

    MOV CL,AL
    MOV BL,#lo(melody_notes)
    MOV BH,#hi(melody_notes)
    CALL idx_ptr
    LDA AL,[BX]
    OUT (P_SND_NOTE),AL

    LDA CL,[melody_i]
    MOV BL,#lo(melody_durs)
    MOV BH,#hi(melody_durs)
    CALL idx_ptr
    LDA AL,[BX]
    OUT (P_SND_DUR),AL
    RET

us_engine:
    SUB AL,#1
    STA [music_countdown],AL

    LDA CL,[speed]
    MOV BL,#lo(engine_freq_lo)
    MOV BH,#hi(engine_freq_lo)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp0],AL

    ; tiembla +-8 Hz cada vuelta (alterna) para que suene a motor, no a pitido
    LDA AL,[engine_phase]
    XOR AL,#1
    STA [engine_phase],AL
    CMP AL,#0
    JMPZ us_no_jitter
    LDA AL,[tmp0]
    ADD AL,#8
    STA [tmp0],AL
us_no_jitter:
    LDA AL,[tmp0]
    OUT (P_SND_FREQ_LO),AL

    LDA CL,[speed]
    MOV BL,#lo(engine_freq_hi)
    MOV BH,#hi(engine_freq_hi)
    CALL idx_ptr
    LDA AL,[BX]
    OUT (P_SND_FREQ_HI),AL
    RET

; ============================================================================
;  try_spawn: cada SPAWN_PERIOD vueltas, busca un hueco libre y crea un
;  obstaculo nuevo en la fila 0 con un carril al azar.
; ============================================================================
; NOTA: `rnd` usa DL como acumulador interno y lo destruye -- el indice de la
; ranura libre no puede vivir en DL a traves de un CALL rnd, asi que se
; guarda en `spawn_slot` y se recarga en CL justo antes de cada idx_ptr.
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
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ts_spawn
    LDA AL,[spawn_slot]
    ADD AL,#1
    STA [spawn_slot],AL
    CMP AL,#N_OBST
    JMPNZ ts_find
    RET

ts_spawn:
    MOV AL,#1
    STA [BX],AL

    LDA CL,[spawn_slot]
    MOV BL,#lo(obst_row)
    MOV BH,#hi(obst_row)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL

    CALL rnd
    AND AL,#0x03
    CMP AL,#3
    JMPNZ ts_lane_ok
    MOV AL,#0
ts_lane_ok:
    STA [tmp1],AL
    LDA CL,[spawn_slot]
    MOV BL,#lo(obst_lane)
    MOV BH,#hi(obst_lane)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL
    RET
ts_dec:
    SUB AL,#1
    STA [spawn_timer],AL
    RET

; ============================================================================
;  tick_invuln: cuenta atras los fotogramas de invulnerabilidad tras un choque
; ============================================================================
tick_invuln:
    LDA AL,[invuln]
    CMP AL,#0
    JMPZ ti_done
    SUB AL,#1
    STA [invuln],AL
ti_done:
    RET

; ============================================================================
;  tick_jump: cuenta atras los fotogramas que quedan de salto
; ============================================================================
tick_jump:
    LDA AL,[jump_active]
    CMP AL,#0
    JMPZ tj_done
    SUB AL,#1
    STA [jump_active],AL
tj_done:
    RET

; ============================================================================
;  update_shot: si hay un disparo activo, lo adelanta SHOT_SPEED filas hacia
;  el horizonte; si con eso pasaria de la fila 0 sin haber acertado, se
;  apaga (fallado). El choque contra un obstaculo se comprueba en
;  update_obstacles (ahi ya se recorre cada obstaculo activo).
; ============================================================================
update_shot:
    LDA AL,[shot_active]
    CMP AL,#0
    JMPZ us2_done
    LDA AL,[shot_row]
    CMP AL,#SHOT_SPEED
    JMPNC us2_advance             ; shot_row >= SHOT_SPEED -> no hay problema
    MOV AL,#0
    STA [shot_active],AL          ; ha llegado al horizonte sin acertar
    RET
us2_advance:
    SUB AL,#SHOT_SPEED
    STA [shot_row],AL
us2_done:
    RET

; ============================================================================
;  scroll_road: desplaza row_center_cache[31..1] = row_center_cache[30..0] (la
;  carretera "avanza" hacia la camara) e inyecta un valor nuevo en la fila 0
;  (el horizonte), moviendolo curve_slope respecto al que tenia -- ver la nota
;  de la cabecera. Se llama una vez por vuelta, antes de draw_road.
; ============================================================================
scroll_road:
    MOV AL,#31
    STA [row_i],AL
sr_l:
    LDA AL,[row_i]
    SUB AL,#1
    MOV CL,AL
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp0],AL                ; tmp0 = row_center_cache[i-1]

    LDA CL,[row_i]
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    LDA AL,[tmp0]
    STA [BX],AL                  ; row_center_cache[i] = row_center_cache[i-1]

    LDA AL,[row_i]
    SUB AL,#1
    STA [row_i],AL
    JMPZ sr_done                  ; row_i llego a 0 -> ya copiamos [0]->[1]
    JMP sr_l
sr_done:
    LDA AL,[row_center_cache]
    LDA BL,[curve_slope]
    ADD AL,BL
    CMP AL,#35
    JMPNC sr_min_ok
    MOV AL,#35
sr_min_ok:
    CMP AL,#92
    JMPC sr_max_ok
    MOV AL,#92
sr_max_ok:
    STA [row_center_cache],AL

    ; los arbustos del arcen "fluyen" al mismo ritmo que se avanza
    LDA AL,[tree_scroll]
    LDA BL,[speed]
    ADD AL,BL
    STA [tree_scroll],AL
    RET

; ============================================================================
;  draw_road: dibuja los dos bordes de la carretera (y arbolitos en el arcen,
;  cada 4 filas) fila a fila, leyendo row_center_cache[]. Deja left31/right31
;  para el clamping de la nave y la comprobacion de choque.
; ============================================================================
; NOTA: calc_pix (llamada via plot/shadow_set_px) usa CL/CH como registros de
; trabajo y los destruye -- el indice de fila de este bucle NO puede vivir en
; CL como en otros bucles simples (idx_ptr no lo toca, pero calc_pix si), asi
; que se guarda en la variable `row_i` y se recarga en CL solo justo antes de
; cada CALL idx_ptr (nunca se espera que sobreviva a un CALL plot).
draw_road:
    MOV AL,#0
    STA [row_i],AL
dr_l:
    LDA AL,[row_i]
    ADD AL,#32
    STA [px_y],AL

    LDA CL,[row_i]
    MOV BL,#lo(road_width)
    MOV BH,#hi(road_width)
    CALL idx_ptr
    LDA AL,[BX]
    SHR AL
    STA [half_w],AL

    LDA CL,[row_i]
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL                 ; tmp1 = centro de esta fila

    LDA AL,[tmp1]
    LDA BL,[half_w]
    SUB AL,BL
    STA [edge_l],AL
    STA [px_x],AL
    CALL plot

    LDA AL,[tmp1]
    LDA BL,[half_w]
    ADD AL,BL
    STA [edge_r],AL
    STA [px_x],AL
    CALL plot

    ; arbolitos en el arcen: (fila - tree_scroll) mod 4 == 0 -- tree_scroll
    ; avanza `speed` unidades cada vuelta (ver scroll_road), asi que el
    ; patron "fluye" hacia la camara para dar sensacion de movimiento.
    ; Ademas alterna alto/bajo segun el numero de arbusto, para que se note
    ; que son arbustos distintos y no una raya continua.
    LDA AL,[row_i]
    LDA BL,[tree_scroll]
    SUB AL,BL
    STA [tmp3],AL
    AND AL,#0x03
    JMPNZ dr_no_tree

    LDA AL,[tmp3]
    SHR AL
    SHR AL
    AND AL,#0x01
    STA [tmp3],AL                 ; tmp3: 0 = arbusto bajo, 1 = arbusto alto

    LDA AL,[edge_l]
    SUB AL,#4
    STA [tree_x],AL
    LDA AL,[row_i]
    ADD AL,#32
    STA [tree_y],AL
    CALL draw_tree

    LDA AL,[edge_r]
    ADD AL,#4
    STA [tree_x],AL
    CALL draw_tree
dr_no_tree:

    LDA AL,[row_i]
    CMP AL,#31
    JMPNZ dr_next
    LDA AL,[edge_l]
    STA [left31],AL
    LDA AL,[edge_r]
    STA [right31],AL
dr_next:
    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#32
    JMPNZ dr_l
    RET

; --- draw_tree: dibuja un arbusto en (tree_x,tree_y); tmp3=1 lo hace de 3 px
; de alto en vez de 1 (ver draw_road) ----------------------------------------
draw_tree:
    LDA AL,[tree_x]
    STA [px_x],AL
    LDA AL,[tree_y]
    STA [px_y],AL
    CALL plot

    LDA AL,[tmp3]
    CMP AL,#0
    JMPZ dt_done
    LDA AL,[tree_y]
    SUB AL,#1
    STA [px_y],AL
    CALL plot
    LDA AL,[tree_y]
    ADD AL,#1
    STA [px_y],AL
    CALL plot
dt_done:
    RET

; ============================================================================
;  draw_mountains: silueta de montañas al fondo (filas 0..31), muestreada
;  cada 4 columnas contra `mountain_h`. Se desplaza lateralmente segun
;  cuanto se ha desviado el horizonte de la carretera (row_center_cache[0])
;  -- ver la nota de la cabecera.
; ============================================================================
draw_mountains:
    LDA AL,[row_center_cache]
    SUB AL,#64
    STA [mtn_shift],AL            ; con signo; el AND 0x1F de abajo lo
                                   ; envuelve bien tanto en positivo como en
                                   ; negativo (256 es multiplo de 32)
    MOV AL,#0
    STA [row_i],AL
dm_l:
    LDA AL,[row_i]
    LDA BL,[mtn_shift]
    ADD AL,BL
    AND AL,#0x1F
    MOV CL,AL
    MOV BL,#lo(mountain_h)
    MOV BH,#hi(mountain_h)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp2],AL                 ; tmp2 = altura de esta columna

    LDA AL,[row_i]
    SHL AL
    SHL AL                         ; x = row_i*4 (0,4,8..124)
    STA [px_x],AL

    LDA AL,[tmp2]
    CALL draw_mtn_col

    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#MOUNTAIN_LEN
    JMPNZ dm_l
    RET

; --- draw_mtn_col: columna vertical de AL pixeles de alto, subiendo desde la
; fila 31 en la columna px_x (px_x ya puesto) ------------------------------
draw_mtn_col:
    STA [tmp3],AL
    MOV AL,#31
    STA [px_y],AL
dmc_l:
    LDA AL,[tmp3]
    CMP AL,#0
    JMPZ dmc_done
    CALL plot
    LDA AL,[px_y]
    SUB AL,#1
    STA [px_y],AL
    LDA AL,[tmp3]
    SUB AL,#1
    STA [tmp3],AL
    JMP dmc_l
dmc_done:
    RET

; ============================================================================
;  draw_shot: dibuja el disparo activo (si lo hay) como una raya vertical de
;  3 pixeles en (shot_x, 32+shot_row).
; ============================================================================
draw_shot:
    LDA AL,[shot_active]
    CMP AL,#0
    JMPZ dsh_done
    LDA AL,[shot_x]
    STA [px_x],AL
    LDA AL,[shot_row]
    ADD AL,#32
    STA [px_y],AL
    CALL plot
    LDA AL,[px_y]
    SUB AL,#1
    STA [px_y],AL
    CALL plot
    LDA AL,[px_y]
    ADD AL,#2
    STA [px_y],AL
    CALL plot
dsh_done:
    RET

; ============================================================================
;  compute_ship_lane: en que carril (0 izq / 1 centro / 2 dcha) esta la nave
;  ahora mismo, comparando ship_x con el centro y el ancho de la fila 31 --
;  la misma formula que usan los obstaculos para su propio carril.
; ============================================================================
compute_ship_lane:
    MOV CL,#31
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp0],AL                 ; tmp0 = centro de la fila 31

    MOV CL,#31
    MOV BL,#lo(road_width)
    MOV BH,#hi(road_width)
    CALL idx_ptr
    LDA AL,[BX]
    SHR AL
    SHR AL
    STA [tmp1],AL                 ; tmp1 = umbral (ancho31/4)

    LDA AL,[ship_x]
    LDA BL,[tmp0]
    SUB AL,BL                     ; AL = ship_x - centro31 (con signo)
    JMPNN csl_pos

    NOT AL
    ADD AL,#1                     ; AL = |ship_x - centro31|
    LDA BL,[tmp1]
    CMP AL,BL
    JMPC csl_center                ; distancia < umbral -> centro
    MOV AL,#0                      ; a la izquierda del centro
    STA [ship_lane],AL
    RET
csl_pos:
    LDA BL,[tmp1]
    CMP AL,BL
    JMPC csl_center
    MOV AL,#2                      ; a la derecha del centro
    STA [ship_lane],AL
    RET
csl_center:
    MOV AL,#1
    STA [ship_lane],AL
    RET

; ============================================================================
;  update_obstacles: mueve cada obstaculo activo, lo dibuja o (si ha llegado
;  al final) comprueba el choque contra la nave y lo desactiva.
; ============================================================================
; NOTA: igual que en draw_road, calc_pix (via plot) destruye CL/CH/DL/DH, asi
; que el indice de obstaculo NO puede vivir en un registro a traves de un
; CALL plot -- se guarda en `obst_i` y se copia a CL solo justo antes de cada
; CALL idx_ptr.
update_obstacles:
    ; persecucion horizontal lenta: cada CHASE_PERIOD vueltas, cada obstaculo
    ; activo se acerca un carril hacia el carril actual de la nave
    LDA AL,[chase_timer]
    CMP AL,#0
    JMPNZ uo_chase_dec
    MOV AL,#CHASE_PERIOD
    STA [chase_timer],AL
    CALL compute_ship_lane

    MOV AL,#0
    STA [row_i],AL
uo_chase_l:
    LDA CL,[row_i]
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uo_chase_next

    LDA CL,[row_i]
    MOV BL,#lo(obst_lane)
    MOV BH,#hi(obst_lane)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[ship_lane]      ; DL, no BL: BX sigue apuntando a obst_lane[row_i]
    CMP AL,DL
    JMPZ uo_chase_next
    JMPC uo_chase_inc            ; obst_lane < ship_lane -> subir un carril
    SUB AL,#1
    JMP uo_chase_store
uo_chase_inc:
    ADD AL,#1
uo_chase_store:
    STA [BX],AL
uo_chase_next:
    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#N_OBST
    JMPNZ uo_chase_l
    JMP uo_chase_done
uo_chase_dec:
    SUB AL,#1
    STA [chase_timer],AL
uo_chase_done:

    MOV AL,#0
    STA [obst_i],AL
uo_l:
    LDA CL,[obst_i]
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uo_next

    LDA CL,[obst_i]
    MOV BL,#lo(obst_row)
    MOV BH,#hi(obst_row)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[speed]          ; DL, no BL: BX sigue apuntando a obst_row[obst_i]
    ADD AL,DL
    STA [BX],AL
    STA [row_raw],AL

    CMP AL,#31
    JMPC uo_clamp_ok
    MOV AL,#31
uo_clamp_ok:
    STA [tmp0],AL

    LDA CL,[tmp0]
    MOV BL,#lo(row_center_cache)
    MOV BH,#hi(row_center_cache)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL

    LDA CL,[tmp0]
    MOV BL,#lo(road_width)
    MOV BH,#hi(road_width)
    CALL idx_ptr
    LDA AL,[BX]
    SHR AL
    SHR AL
    STA [tmp2],AL

    LDA CL,[obst_i]
    MOV BL,#lo(obst_lane)
    MOV BH,#hi(obst_lane)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#1
    JMPZ uo_lane_c
    JMPC uo_lane_l
    LDA AL,[tmp1]
    LDA BL,[tmp2]
    ADD AL,BL
    JMP uo_lane_done
uo_lane_l:
    LDA AL,[tmp1]
    LDA BL,[tmp2]
    SUB AL,BL
    JMP uo_lane_done
uo_lane_c:
    LDA AL,[tmp1]
uo_lane_done:
    STA [obst_x],AL

    ; --- disparo: si hay uno activo cerca de este obstaculo, lo destruye ---
    LDA AL,[shot_active]
    CMP AL,#0
    JMPZ uo_no_shot
    LDA AL,[tmp0]
    LDA BL,[shot_row]
    SUB AL,BL
    JMPNN uo_shot_rowabs
    NOT AL
    ADD AL,#1
uo_shot_rowabs:
    CMP AL,#2
    JMPNC uo_no_shot             ; distancia de fila >= 2 -> no hay impacto
    LDA AL,[obst_x]
    AND AL,#0x80
    JMPNZ uo_no_shot
    LDA AL,[obst_x]
    LDA BL,[shot_x]
    SUB AL,BL
    JMPNN uo_shot_xabs
    NOT AL
    ADD AL,#1
uo_shot_xabs:
    CMP AL,#COLLIDE_DIST
    JMPNC uo_no_shot             ; distancia en X >= COLLIDE_DIST -> no hay impacto

    MOV AL,#0
    STA [shot_active],AL
    LDA AL,[score]
    CMP AL,#255
    JMPZ uo_shot_score_ok
    ADD AL,#1
    STA [score],AL
    MOV AL,#1
    STA [score_dirty],AL
uo_shot_score_ok:
    MOV AL,#81
    OUT (P_SND_NOTE),AL
    MOV AL,#6
    OUT (P_SND_DUR),AL
    LDA CL,[obst_i]
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    JMP uo_next
uo_no_shot:

    LDA AL,[row_raw]
    CMP AL,#31
    JMPC uo_draw_now

    LDA AL,[jump_active]
    CMP AL,#0
    JMPNZ uo_dodge               ; saltando -> esquiva automatica, sin carril

    ; ha llegado a la fila de la nave: comprobar choque
    LDA AL,[obst_x]
    AND AL,#0x80
    JMPNZ uo_dodge          ; posicion invalida (fuera de rango) -> no choca
    LDA AL,[obst_x]
    LDA BL,[ship_x]
    SUB AL,BL
    JMPNN uo_dist_pos
    NOT AL
    ADD AL,#1
uo_dist_pos:
    CMP AL,#COLLIDE_DIST
    JMPC uo_hit
uo_dodge:
    LDA AL,[score]
    CMP AL,#255
    JMPZ uo_deactivate
    ADD AL,#1
    STA [score],AL
    MOV AL,#1
    STA [score_dirty],AL
    JMP uo_deactivate
uo_hit:
    CALL on_collision
uo_deactivate:
    LDA CL,[obst_i]
    MOV BL,#lo(obst_active)
    MOV BH,#hi(obst_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    JMP uo_next

uo_draw_now:
    ; dibuja el obstaculo como una cruz de 5 pixeles (OBST_PIX), no solo uno
    LDA AL,[tmp0]
    ADD AL,#32
    STA [obst_y],AL

    MOV AL,#0
    STA [row_i],AL
od_l:
    LDA AL,[row_i]
    SHL AL
    MOV CL,AL
    MOV BL,#lo(obst_pix)
    MOV BH,#hi(obst_pix)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[obst_x]
    ADD AL,DL
    STA [px_x],AL

    ADD BL,#1
    JMPNC od_dy_ok
    ADD BH,#1
od_dy_ok:
    LDA AL,[BX]
    LDA DL,[obst_y]
    ADD AL,DL
    STA [px_y],AL
    CALL plot

    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#OBST_PIX_LEN
    JMPNZ od_l

uo_next:
    LDA AL,[obst_i]
    ADD AL,#1
    STA [obst_i],AL
    CMP AL,#N_OBST
    JMPNZ uo_l
    RET

; ============================================================================
;  on_collision: pita, y si no hay invulnerabilidad en curso resta una vida
; ============================================================================
on_collision:
    MOV AL,#36
    OUT (P_SND_NOTE),AL
    MOV AL,#18
    OUT (P_SND_DUR),AL

    LDA AL,[invuln]
    CMP AL,#0
    JMPNZ oc_done
    LDA AL,[lives]
    CMP AL,#0
    JMPZ oc_done
    SUB AL,#1
    STA [lives],AL
    MOV AL,#1
    STA [lives_dirty],AL
    MOV AL,#INVULN_TICKS
    STA [invuln],AL
oc_done:
    RET

; ============================================================================
;  draw_ship: triangulo pequeno en las 3 ultimas filas, centrado en ship_x
; ============================================================================
; NOTA: mismo patron que scroll_road/draw_road -- el indice del pixel vive en
; `row_i` (memoria), nunca en un registro, porque calc_pix (via plot) lo
; destruiria.
draw_ship:
    MOV AL,#SHIP_BASE_Y
    LDA BL,[jump_active]
    CMP BL,#0
    JMPZ ds_base_ok
    SUB AL,#JUMP_RISE
ds_base_ok:
    STA [ship_draw_y],AL

    MOV AL,#0
    STA [row_i],AL
ds_l:
    LDA AL,[row_i]
    SHL AL
    MOV CL,AL
    MOV BL,#lo(ship_pix)
    MOV BH,#hi(ship_pix)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[ship_x]
    ADD AL,DL
    STA [px_x],AL

    ADD BL,#1
    JMPNC ds_dy_ok
    ADD BH,#1
ds_dy_ok:
    LDA AL,[BX]
    LDA DL,[ship_draw_y]
    ADD AL,DL
    STA [px_y],AL
    CALL plot

    LDA AL,[row_i]
    ADD AL,#1
    STA [row_i],AL
    CMP AL,#SHIP_PIX_LEN
    JMPNZ ds_l
    RET

; ============================================================================
;  update_hud: reescribe puntuacion/vidas en la fila 0 solo si han cambiado
; ============================================================================
update_hud:
    LDA AL,[score_dirty]
    CMP AL,#0
    JMPZ uh_lives
    MOV AL,#0
    STA [score_dirty],AL

    MOV BL,#lo(s_pts)
    MOV BH,#hi(s_pts)
    MOV CL,#0
    MOV CH,#0
    CALL puts
    CALL score_digits
    LDA BL,[digit_h]
    MOV CL,#4
    MOV CH,#0
    CALL putc
    LDA BL,[digit_t]
    MOV CL,#5
    MOV CH,#0
    CALL putc
    LDA BL,[digit_u]
    MOV CL,#6
    MOV CH,#0
    CALL putc
uh_lives:
    LDA AL,[lives_dirty]
    CMP AL,#0
    JMPZ uh_done
    MOV AL,#0
    STA [lives_dirty],AL

    MOV BL,#lo(s_vidas)
    MOV BH,#hi(s_vidas)
    MOV CL,#10
    MOV CH,#0
    CALL puts
    LDA BL,[lives]
    ADD BL,#'0'
    MOV CL,#16
    MOV CH,#0
    CALL putc
uh_done:
    RET

; --- score_digits: separa [score] (0..255) en digit_h/digit_t/digit_u ------
score_digits:
    LDA AL,[score]
    CALL div10
    LDA CL,[tmp_rem]
    ADD CL,#'0'
    STA [digit_u],CL

    CALL div10
    LDA CL,[tmp_rem]
    ADD CL,#'0'
    STA [digit_t],CL

    ADD AL,#'0'
    STA [digit_h],AL
    RET

; --- div10:  entrada AL (0..255) -> AL = AL/10, [tmp_rem] = AL mod 10 -------
div10:
    MOV DL,#0
d10_l:
    CMP AL,#10
    JMPC d10_d
    SUB AL,#10
    ADD DL,#1
    JMP d10_l
d10_d:
    STA [tmp_rem],AL
    MOV AL,DL
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- plot: dibuja (px_x,px_y) en `shadow`, salvo que px_x este fuera de
; 0..127 (bit 7 puesto) -- ver la nota de seguridad de rango en la cabecera.
plot:
    LDA AL,[px_x]
    AND AL,#0x80
    JMPNZ plot_skip
    CALL shadow_set_px
plot_skip:
    RET

; --- idx_ptr:  BX = (BL/BH iniciales) + CL, propagando el acarreo a mano ---
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- shadow_set_px:  enciende el pixel (px_x,px_y) en `shadow` (RAM) -------
shadow_set_px:
    CALL calc_pix
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

; --- clr_shadow:  pone a 0 los 1024 bytes de `shadow` (contador de 16 bits
; explicito: `shadow` no cae en un limite de pagina, ver programs/cubo.asm) -
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
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    MOV DL,CL
    SHR DL
    SHR DL
    SHR DL
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL
    SHR AL
    SHR AL
    SHR AL
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

; --- putc:  BL = caracter,  CL = col,  CH = fila ---------------------------
putc:
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila ------------------
puts:
    MOV AL,CH
    SHL AL
    SHL AL
    SHL AL
    SHL AL
    SHL AL
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

; --- rnd:  numero al azar en AL (combina 3 pasos de LFSR, ver estrellas.asm)
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

; --- frame_wait:  AL = pasos del temporizador 3 (8 ms/paso) ----------------
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
score:          .space 1
lives:          .space 1
speed:          .space 1
ship_x:         .space 1
curve_slope:    .space 1
curve_target:   .space 1
curve_timer:    .space 1
spawn_timer:    .space 1
invuln:         .space 1
melody_i:       .space 1
music_countdown:.space 1
dir_prev:       .space 1
dat_prev:       .space 1
dir_btn_prev:   .space 1
dat_btn_prev:   .space 1
seed:           .space 1
left31:         .space 1
right31:        .space 1
row_i:          .space 1
obst_i:         .space 1
spawn_slot:     .space 1
half_w:         .space 1
edge_l:         .space 1
edge_r:         .space 1
row_raw:        .space 1
obst_x:         .space 1
obst_y:         .space 1
wall_hit:       .space 1
chase_timer:    .space 1
ship_lane:      .space 1
tree_scroll:    .space 1
tree_x:         .space 1
tree_y:         .space 1
engine_phase:   .space 1
shot_active:    .space 1
shot_row:       .space 1
shot_x:         .space 1
jump_active:    .space 1
ship_draw_y:    .space 1
mtn_shift:      .space 1
score_dirty:    .space 1
lives_dirty:    .space 1
start_hit:      .space 1

tmp0:           .space 1
tmp1:           .space 1
tmp2:           .space 1
tmp3:           .space 1
tmp_rem:        .space 1
digit_h:        .space 1
digit_t:        .space 1
digit_u:        .space 1

px_x:           .space 1
px_y:           .space 1
pix_lo:         .space 1
pix_hi:         .space 1
pix_mask:       .space 1

obst_active:    .space 4
obst_row:       .space 4
obst_lane:      .space 4

row_center_cache: .space 32

curve_options: .db 254, 2                    ; -2, +2

; mountain_h[0..31]: altura (px) de la silueta de montañas de fondo, una
; muestra cada 4 columnas -- calculada una vez en Python (dos senos sumados)
mountain_h:
    .db 5, 8, 9, 8, 7, 6, 6, 7, 7, 5, 2, 1, 1, 3, 5, 6
    .db 5, 4, 5, 7, 9, 9, 8, 5, 3, 3, 4, 4, 3, 2, 1, 2

; road_width[fila 0..31]: calculado en Python, 6 + fila*2
road_width:
    .db 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36
    .db 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 66, 68

; riff corto y energico (se repite cada MELODY_LEN notas): notas MIDI y
; duracion de PORT_SND_DUR (x10ms), cortas y con saltos para que suene vivo
melody_notes: .db 76, 84, 79, 72, 76, 84, 79, 88
melody_durs:  .db 4,  4,  4,  4,  4,  4,  4,  6

; zumbido de motor: frecuencia (Hz, 16 bits) segun `speed` (1..4; el indice 0
; no se usa nunca, SPEED_MIN=1) -- mas rapido = mas agudo
engine_freq_lo: .db 0, 0x64, 0xA0, 0xF0, 0x54     ; 100, 160, 240, 340 Hz
engine_freq_hi: .db 0, 0x00, 0x00, 0x00, 0x01

; SHIP_PIX: 21 pares (dx,dy) con signo, relativos a (ship_x, SHIP_BASE_Y) --
; una navecita en flecha con alas y llamas de motor
ship_pix:
    .db 0,253
    .db 255,254, 0,254, 1,254
    .db 254,255, 255,255, 0,255, 1,255, 2,255
    .db 253,0, 254,0, 255,0, 1,0, 2,0, 3,0
    .db 252,1, 253,1, 3,1, 4,1
    .db 255,2, 1,2

; OBST_PIX: 5 pares (dx,dy) con signo -- una cruz, mas visible que un pixel
obst_pix:
    .db 0,0, 0,255, 0,1, 255,0, 1,0

s_title: .asciiz "EXPRESS X-1"
s_help1: .asciiz "ADDR GIRA, DATA GAS"
s_help2: .asciiz "PULSA PARA EMPEZAR"
s_over:  .asciiz "GAME OVER"
s_score: .asciiz "PUNTOS:"
s_pts:   .asciiz "PTS:"
s_vidas: .asciiz "VIDAS:"

; shadow: copia del framebuffer en RAM ("doble buffer" software, ver game_l).
; Va la ultima de todo: es un .space, nunca se le hace un .db/.asciiz de
; verdad, asi que no cuenta para el recorte del .bin (ver cabecera de
; tools/casm.py y programs/README.md, "Tamano del .bin").
shadow: .space 1024
