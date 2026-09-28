; ============================================================================
;  shamus.asm  -  laberinto de accion al estilo Shamus (compi)
;
;  Cada "sala" es un laberinto perfecto (un arbol de expansion: hay
;  EXACTAMENTE un camino entre dos celdas cualesquiera, generado al azar cada
;  vez) que ocupa la pantalla entera, con una entrada y una salida en dos de
;  los cuatro lados de la pantalla (norte/este/sur/oeste), siempre distintos
;  entre si. Cruzar la salida lleva a la sala siguiente, entrando por el lado
;  opuesto al que se salio (salir por el sur -> entrar por el norte, etc).
;  Las dos primeras salas no tienen enemigos, para aprender a moverse; a
;  partir de ahi van apareciendo (hasta 3) y corriendo mas rapido sala a
;  sala. 3 vidas; perder las tres es GAME OVER.
;
;  CONTROLES: los dos encoders MUEVEN -- DIRECCION arriba/abajo, DATOS
;  izquierda/derecha (posicion absoluta del encoder, restando la lectura
;  anterior para sacar el desplazamiento de este fotograma, igual patron
;  que la paleta de pong.asm). Los dos PULSADORES disparan por igual, hacia
;  la ultima de las 4 cardinales (N/E/S/O, nunca diagonal) en que se movio
;  el jugador (ver update_fire) -- no hay boton de salir del programa.
;
;  LABERINTO: cell_walls[fila*8+col] guarda, en sus 4 bits bajos, que lados
;  de esa celda estan ABIERTOS (bit0=N,bit1=E,bit2=S,bit3=O; 1=paso, 0=pared).
;  Se genera con "backtracking" recursivo iterativo (gen_maze): un camino
;  aleatorio que nunca repite celda, marcando cada paso, y retrocediendo
;  (con la propia pila de CALL/RET del hardware, PUSH/POP) cuando ya no
;  quedan vecinas sin visitar -- termina cuando las 32 celdas estan
;  visitadas (mas facil de comprobar que "la pila esta vacia"). El resultado
;  es SIEMPRE un arbol que cubre las 32 celdas, asi que entrada y salida
;  quedan conectadas por construccion, sin tener que comprobarlo aparte.
;
;  Las paredes se PINTAN una sola vez por sala (draw_maze) en `walls`, un
;  buffer de 1024 bytes AL MARGEN de `shadow` (mismo formato que el
;  framebuffer real) -- de "linea doble" (dos trazos de 1 px a 2 px de
;  distancia) en cada borde de celda CERRADO. Cada fotograma se COPIA
;  `walls` sobre `shadow` (el laberinto no cambia dentro de una sala) y
;  ENCIMA se pintan jugador y enemigos -- evita recalcular ninguna pared
;  cada fotograma, solo copiarlas. `walls` sirve ADEMAS de mapa de colisión:
;  antes de mover a nadie se mira si el sitio de destino ya tiene un pixel
;  de pared encendido ahi (wall_test), sin necesitar guardar la geometria
;  del laberinto de ninguna otra forma.
;
;  SPRITES: jugador y enemigos son listas de (dx,dy) -- un puñado de pixeles
;  sueltos guardados en una tabla, no un mapa de bits recortado a mano -- que
;  se copian con OR sobre `shadow` cada fotograma (shadow_set_px), igual
;  tecnica que las naves/obstaculos de fzero.asm: "dibujados en memoria,
;  copiados a pantalla" sin tener que trazar lineas nuevas cada vez.
;
;  ENEMIGOS: se mueven en linea recta (1 px cada [move_delay] fotogramas,
;  mas lento al principio) hasta el CENTRO de la siguiente celda (detectado
;  mirando los 4 bits bajos de su posicion: x&15==8 e y&15==8, ya que las
;  celdas son de 16x16), y alli deciden hacia donde seguir: de las salidas
;  abiertas de esa celda, la que mas acerque en distancia Manhattan a la
;  celda del jugador, evitando dar media vuelta salvo que sea la unica
;  salida (callejon sin salida). No es un buscador de caminos de verdad (no
;  hay memoria de haber estado ya en un sitio), pero como el laberinto es un
;  arbol -- un solo camino posible entre dos celdas -- este criterio local
;  basta para perseguir bien la mayoria de las veces.
;
;  HUD: puntuacion arriba a la izquierda, vidas arriba a la derecha, en la
;  capa de TEXTO (0x0400+), independiente del framebuffer grafico -- se
;  vuelve a escribir solo cuando cambian, no cada fotograma.
;
;  SALAS PERSISTENTES Y CON VARIAS SALIDAS: cada sala tiene una entrada
;  (siempre abierta) y de 0 a 3 huecos extra en sus otros lados (sorteados
;  independientemente, mitad y mitad -- una sala puede quedarse sin ningun
;  hueco extra, forzando a retroceder). room_link[sala*4+lado] guarda, para
;  cada lado, 254 ("hueco sin cruzar todavia") o el numero de sala al que ya
;  lleva -- asi el mapa es un arbol que se construye sobre la marcha segun
;  se explora, no una simple cadena lineal. Cada sala, una vez generada, se
;  guarda entera (persist_walls/persist_doors/persist_key_*/persist_door_*,
;  indexados por numero de sala hasta MAX_ROOMS=50) para que volver a ella
;  la deje EXACTAMENTE igual -- asi el jugador puede escapar de un enemigo
;  dando marcha atras. Solo se puntua la PRIMERA vez que se cruza un hueco
;  sin explorar (se le asigna sala nueva); volver a un hueco ya cruzado no
;  da puntos. Los enemigos SI se regeneran de cero cada vez que se entra a
;  una sala (persistida o no), la unica pieza que no persiste.
;
;  LLAVES Y PUERTAS: al sortear los huecos extra de una sala, como mucho
;  uno de ellos puede salir CANDADO en vez de abierto: se ve (linea sencilla
;  en vez de doble) pero no se puede cruzar hasta abrirla con una llave. La
;  llave NUNCA esta en la propia sala de la puerta -- vive en la sala de la
;  que se VINO para llegar a esta ([prev_room_num]), colocada en una celda
;  cualquiera de SU laberinto interno: abrir la puerta exige haber
;  explorado (o vuelto sobre los pasos) a otra sala, no solo cruzar esta de
;  camino. Llavero COMPARTIDO: cualquier llave abre cualquier puerta (basta
;  con llevar al menos una encima, [keys_held], ver door_check) -- no hay
;  emparejamiento llave-puerta especifico, porque el HUD no distingue una
;  llave de otra (solo un icono + una cifra) y exigir la exacta resultaba
;  confuso: se podia tener una llave encima y aun asi no poder abrir la
;  puerta de delante, porque era la de otra en otra parte del laberinto. Lo
;  que si se conserva es la regla de una llave por sala donante (si una
;  sala ya le dio su llave a un hijo, otro hijo suyo con puerta se abre sin
;  candado en su lugar -- ver gsc_maybe_lock, sigue haciendo falta porque
;  cada sala solo tiene sitio para una llave propia); ADEMAS, una sala que
;  ella misma tenga su propia entrada con candado nunca aloja una llave
;  (mismo gsc_maybe_lock) -- sin esto podia darse una sala con llave Y
;  puerta a la vez (la suya propia, de otro candado mas adentro), que es
;  justo lo que no se quiere ver nunca aunque no fuera explotable (la llave
;  alojada no sirve para la propia entrada: esa ya se cruzo para poder
;  estar ahi). Ni la sala 0 ni
;  la del jefe (BOSS_ROOM_NUM) sacan puerta nunca. Cogerla es automatico al
;  pisar su celda; acercarse a cualquier puerta con candado llevando al
;  menos una llave la abre sola (gastando una del contador), y el cambio se
;  persiste igual que el resto de la sala.
;
;  JEFE FINAL (sala BOSS_ROOM_NUM = MAX_ROOMS-1 = 49, "nivel 50"): en cuanto
;  next_room_id se satura (se han generado ya MAX_ROOMS salas distintas),
;  CUALQUIER hueco nuevo sin explorar lleva directamente aqui (mismo
;  mecanismo que antes reciclaba la ultima sala como degradacion; ahora esa
;  sala reciclada ES la del jefe a proposito). setup_enemies coloca ahi un
;  unico enemigo de tipo ENEMY_TYPE_BOSS: persigue igual que cualquier
;  enemigo (choose_enemy_dir/step_enemy, sin cambios) y ADEMAS dispara
;  (update_enemy_fire ya dispara con cualquier enemy_type != 0, no hizo
;  falta tocarlo), pero con sprite mas grande (BOSS_SPRITE_*) y BOSS_HP_MAX
;  impactos del disparo del jugador en vez de uno solo (ver update_shots).
;  Al caer, en vez del jingle de siempre se ve la pantalla de victoria
;  (show_victory) y la partida se reinicia.
;
;  Al estar saturado, MUCHOS huecos distintos (de cualquier sala/direccion)
;  acaban apuntando los 4 al jefe, cada uno "nuevo" desde su propio punto de
;  vista -- pero el jefe solo se genera y se enlaza "hacia atras" la
;  PRIMERA vez ([boss_room_ready], ver cross_room_gap); las siguientes
;  veces solo se enlaza "hacia el" (sala_actual-->jefe) y se restaura el
;  jefe ya existente, sin tocar nada mas. Ademas, el jefe nunca saca
;  salidas propias (gen_and_save_current_room las salta si room_num es el
;  suyo): sin estas dos guardas, cada hueco nuevo saturado volvia a
;  regenerar el laberinto del jefe entero (pisando su entrada) y/o
;  reescribia su enlace de vuelta (solo hay 4 direcciones posibles, asi que
;  dos huecos cualesquiera acababan chocando). Y aunque el jefe ya no se
;  regenera, un hueco saturado desde una direccion DISTINTA a la de su
;  primera llegada seguia calculando un entry_side propio (el de ESE hueco,
;  no el real) -- [boss_entry_side] guarda la entrada real UNA vez, y
;  crg_boss_existing la restaura siempre sobre [entry_side] antes de
;  colocar al jugador, sea cual sea el hueco por el que se llegue esta vez.
;
;  CAUSA RAIZ real de "morir sin mas entrando y saliendo de una sala" (bug
;  reportado): ROOM_OFF_LO/HI (la tabla de room_off, que traduce room_num a
;  su desplazamiento en persist_walls/persist_doors, ya que NCELLS=18 no es
;  potencia de 2) se habia quedado con solo 24 entradas de cuando MAX_ROOMS
;  paso a ser 50 para el jefe final -- para CUALQUIER sala 24..49, room_off
;  leia bytes cualquiera fuera de la tabla como desplazamiento, pudiendo
;  pisar (al guardar) o leer mal (al restaurar) los datos de OTRA sala
;  cualquiera sin relacion aparente. Las guardas del jefe de arriba son
;  necesarias pero no habrian bastado sin este arreglo de raiz.
;
;  Ensamblar y enviar al slot 13:
;     python3 tools/casm.py programs/shamus.asm -o programs/shamus.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 13 programs/shamus.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 13
    .org 0x0000

; 6x3 celdas de 21x21 (126x63, con 2/1 px de margen sin usar a la derecha y
; abajo): pasillos anchos (~15 px interiores libres de pared), para que
; quepan dos personajes uno al lado del otro sin tocar el muro y el jugador
; pueda esquivar a un enemigo si es rapido. OJO: ni MAZE_COLS(6) ni
; MAZE_ROWS(3) son potencias de 2 -- cualquier "fila*MAZE_COLS+col" o
; "indice -> fila,col" no puede hacerse con SHL/SHR/AND (esos atajos solo
; valen para potencias de 2), hace falta la tabla ROW_MUL o las
; CELL_TO_ROW/CELL_TO_COL (ver mas abajo, junto a BIT_OF_DIR).
MAZE_COLS = 6
MAZE_ROWS = 3
NCELLS    = 18          ; MAZE_COLS*MAZE_ROWS
CELL_W    = 21
CELL_H    = 21

DIR_N = 0
DIR_E = 1
DIR_S = 2
DIR_W = 3

PLAYER_W = 5
PLAYER_H = 6
ENEMY_W  = 5             ; caja de colision del enemigo (esta centrado, ver
ENEMY_H  = 5              ; ENEMY_HALF): de centro-2 a centro+2 son 5 pixeles
ENEMY_HALF = 2

MAX_ENEMIES = 3
FIRST_ENEMY_ROOM = 2      ; salas 0 y 1 sin enemigos, para aprender
START_DELAY = 7           ; fotogramas por paso de enemigo, al principio
MIN_DELAY   = 2           ; tope de velocidad maxima
MAX_LIVES   = 3

; --- salas persistentes / jefe final --------------------------------------
MAX_ROOMS       = 50      ; salas distintas que se pueden llegar a generar
                          ; (antes 24 "a secas"); persist_*/room_link se
                          ; dimensionan a partir de esta misma constante
BOSS_ROOM_NUM   = MAX_ROOMS-1  ; la ultima -- "nivel 50". Al saturarse
                          ; next_room_id, CUALQUIER hueco sin explorar
                          ; nuevo lleva aqui (mismo mecanismo de reciclado
                          ; que ya tenia la sala de saturacion, ver
                          ; cross_room_gap): no hace falta enrutar nada
                          ; aparte para garantizar que se llega al jefe.
ENEMY_TYPE_BOSS = 2       ; enemy_type: 0=persegidor, 1=tirador, 2=JEFE
                          ; (persigue Y dispara -- ver update_enemy_fire,
                          ; que ya dispara con cualquier tipo != 0)
BOSS_HP_MAX     = 5       ; impactos del disparo del jugador para matarlo
MIN_ENEMY_SPAWN_DIST = 32 ; 1/4 de los 128px de ancho de pantalla -- ningun
                          ; enemigo puede aparecer (setup_enemies) mas cerca
                          ; que esto del punto de entrada del jugador
WALK_ANIM_FRAMES = 3     ; fotogramas entre cada cambio de pie al andar
WALK_IDLE_FRAMES = 8     ; fotogramas SEGUIDOS sin detente antes de darlo
                         ; por parado (tolera los huecos normales entre
                         ; detentes de un giro real, no instantaneo)
DOOR_OPEN_DIST = 13     ; umbral de door_check para abrir la puerta (escala
                         ; con CELL_W/CELL_H=21)
DOOR_SAFE_DIST = 18     ; margen extra sobre ese umbral (near_door) para no
                         ; morir justo al llegar a una puerta candada

; marcador de esquina superior derecha: corazon+numero de vidas seguido de
; llave+numero de llaves cogidas. HEART_AREA_* es el recuadro que se limpia
; en negro antes de dibujar los dos iconos graficos (por si una pared de la
; sala pasara justo por ahi) -- cubre desde el corazon hasta la llave.
; el contador de llaves es de 1 sola cifra (en la practica es rarisimo
; acumular 10 sin abrir ninguna puerta antes: como mucho una llave por sala
; donante, ver gsc_maybe_lock) -- el hueco que deja el segundo digito se usa
; para pegar todo el marcador (corazon+vidas+llave+contador) mas junto y
; mas cerca de la esquina.
HEART_ICON_X = 96        ; esquina superior izquierda del sprite (5x5)
HEART_ICON_Y = 1
LIVES_DIGIT_COL = 17     ; columna de texto, justo despues del corazon
KEY_ICON_CX = 115        ; centro del sprite de la llave (7x5, tumbada de
                         ; lado -- ver KEY_SPRITE_DX/DY -- para que no
                         ; sobresalga mas que el corazon ni se confunda con
                         ; una pared vertical)
KEY_ICON_CY = 4
KEYS_DIGIT_COL = 20      ; 1 sola columna de texto (la ultima, 0-20) -- nunca
                         ; pasa de 9 llaves

HEART_AREA_X0 = 94       ; 2px de margen a cada lado sobre el hueco real de
HEART_AREA_Y0 = 1        ; los sprites, para que una pared de la sala que
HEART_AREA_W  = 27       ; pase justo al lado quede tambien tapada y no se
HEART_AREA_H  = 7        ; confunda visualmente con el corazon/la llave

; titulo grande de la pantalla de bienvenida (letras de pixel art, ver
; draw_big_letter): cada letra es una rejilla de 5x7 escalada x3 = 15x21
; px, con 3 px de hueco entre letras (paso de 18 px); 6 letras * 18 - 3 =
; 105 px, centradas en 128 -> arrancan en (128-105)/2 = 11
LETTER_SCALE = 3
TITLE_X0 = 11
TITLE_Y  = 6
TITLE_STEP = 18          ; 5*LETTER_SCALE + 3 de hueco

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_FB      = 0x0000
P_DIR_POS = 0x0600
P_DIR_BTN = 0x0601
P_DAT_POS = 0x0602
P_DAT_BTN = 0x0603
P_LED     = 0x0610
P_T3      = 0x0623
P_SND_NOTE = 0x0632
P_SND_DUR  = 0x0633

SHOT_SPEED   = 2       ; px por eje y fotograma (mas rapido que el jugador)
MAX_SHOTS    = 2

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    IN  AL,(P_DAT_POS)          ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    STA [seed],AL
    JMPNZ init
    MOV AL,#0x5D
    STA [seed],AL
init:
    IN  AL,(P_DIR_POS)
    STA [dir_pos_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    CALL title_screen
    CALL clsg
    CALL clst
    CALL new_game

main_l:
    CALL update_player
    LDA AL,[room_transition_pending]
    CMP AL,#0
    JMPZ main_no_transition
    MOV AL,#0
    STA [room_transition_pending],AL
    CALL cross_room_gap
    JMP main_draw

main_no_transition:
    CALL check_key_pickup
    CALL check_heart_pickup
    CALL door_check
    CALL update_fire
    CALL update_shots
    CALL update_enemies
    CALL update_enemy_fire
    CALL update_enemy_shots
    CALL check_collisions

main_draw:
    CALL draw_frame
    MOV AL,#3                  ; ritmo: 3*8 = 24 ms por fotograma
    CALL frame_wait
    JMP main_l

; ============================================================================
;  new_game:  reinicia puntuacion/vidas/sala y arranca la primera habitacion
;  (siempre nueva -- una partida nueva no hereda las salas de la anterior).
; ============================================================================
new_game:
    MOV AL,#0
    STA [room_num],AL
    STA [score_lo],AL
    STA [score_hi],AL
    STA [room_transition_pending],AL
    STA [keys_held],AL
    STA [low_life_rooms],AL
    MOV AL,#1
    STA [next_room_id],AL   ; la sala 0 ya esta "asignada" (la inicial)
    MOV AL,#MAX_LIVES
    STA [lives],AL
    MOV AL,#255
    STA [prev_room_num],AL  ; la sala 0 no tiene sala anterior -- nunca
                             ; sacara puerta (ver la guarda en gsc_maybe_lock)
    MOV AL,#0
    STA [room0_entered],AL  ; ver la guarda de "centro de pantalla" en
                             ; place_player_spawn (cross_room_gap lo pone a 1
                             ; al salir de la sala 0 por primera vez)
    STA [boss_room_ready],AL ; ver la guarda de cross_room_gap: el jefe solo
                             ; se genera una vez, aunque varios huecos
                             ; distintos acaben apuntando ahi por saturacion
    CALL clear_room_link

    CALL rnd
    AND AL,#3
    STA [entry_side],AL
    MOV AL,#0
    STA [award_points],AL
    CALL gen_and_save_current_room
    CALL draw_maze
    CALL place_player_spawn
    CALL setup_enemies
    CALL update_score_hud
    CALL update_lives_hud
    CALL update_keys_hud
    RET

; --- clear_room_link: pone room_link[] (MAX_ROOMS*4 bytes) entero a 254
; ("hueco sin explorar todavia") antes de una partida nueva.
clear_room_link:
    MOV AL,#0
    STA [i],AL
crl_l:
    LDA CL,[i]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    MOV AL,#254
    STA [BX],AL
    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    ; OJO: 200 = MAX_ROOMS*4 = 50*4 (literal, misma razon que el resto de
    ; .space de este fichero). Bug real que hubo: se quedo en 96 (24*4) de
    ; cuando MAX_ROOMS era 24 -- para CUALQUIER sala 24..49, sus 4 huecos
    ; (room_link) arrancaban con basura sin inicializar en vez de 254 ("sin
    ; explorar"), en vez de vacios de verdad: cross_room_gap podia leer
    ; cualquier numero de sala al azar ahi y tratar un hueco nunca cruzado
    ; como si ya llevase a una sala real (con su propio entry_side,
    ; normalmente distinto), colocando al jugador contra una pared sin
    ; ninguna apertura real -- la causa raiz mas gorda del bug de "morir
    ; sin mas entrando y saliendo de una sala".
    CMP AL,#200
    JMPNZ crl_l
    RET

; ============================================================================
;  cross_room_gap:  [exit_dir_taken] indica el lado por el que se acaba de
;  cruzar. Cada sala puede tener de 1 a 4 huecos (no solo una entrada y una
;  salida) -- room_link[sala*4+lado] guarda, para cada uno, o 254 ("hueco,
;  todavia sin cruzar") o el numero de la sala a la que ya lleva. Si el
;  hueco cruzado ya tiene sala asignada, se va alli (restaurada tal cual);
;  si no, se asigna una sala nueva (next_room_id, saturado a MAX_ROOMS-1),
;  enlazando los dos lados entre si, se genera y se puntua -- los enemigos
;  siempre se recolocan de cero en los dos casos.
; ============================================================================
cross_room_gap:
    LDA AL,[room_num]
    SHL AL,#2
    LDA BL,[exit_dir_taken]
    ADD AL,BL
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp0],AL             ; tmp0 = sala destino ya asignada, o 254

    LDA CL,[exit_dir_taken]
    MOV BL,#lo(OPP_OF_DIR)
    MOV BH,#hi(OPP_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [entry_side],AL       ; lado de entrada en la sala destino

    ; si se esta CRUZANDO fuera de la sala 0 (todavia con su valor viejo
    ; aqui, antes de pisarlo mas abajo con el destino), marca que ya se ha
    ; dejado atras al menos una vez -- a partir de ahora, cualquier vuelta a
    ; la sala 0 tiene un lado de entrada real que respetar (ver la guarda de
    ; place_player_spawn); antes de esto, todavia no hay "de donde viene".
    LDA AL,[room_num]
    CMP AL,#0
    JMPNZ crg_not_leaving_room0
    MOV AL,#1
    STA [room0_entered],AL
crg_not_leaving_room0:

    LDA AL,[tmp0]
    CMP AL,#254
    JMPNZ crg_known

    ; primera vez por este hueco: asigna una sala nueva -- o, si ya se
    ; llego a MAX_ROOMS, SIEMPRE la sala del jefe (BOSS_ROOM_NUM =
    ; MAX_ROOMS-1): asi cualquier hueco sin explorar mas alla del limite
    ; lleva a la batalla final, sin enrutar nada aparte
    LDA AL,[next_room_id]
    CMP AL,#MAX_ROOMS
    JMPC crg_alloc_ok
    MOV AL,#BOSS_ROOM_NUM
crg_alloc_ok:
    STA [tmp0],AL

    ; enlaza sala_actual --exit_dir_taken--> tmp0 (siempre: sale bien igual
    ; para una sala nueva de verdad que para un alias mas hacia el jefe ya
    ; existente -- ver la nota de abajo).
    LDA AL,[room_num]
    SHL AL,#2
    LDA BL,[exit_dir_taken]
    ADD AL,BL
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    LDA AL,[tmp0]
    STA [BX],AL

    ; el jefe (BOSS_ROOM_NUM) es un caso especial: por saturacion
    ; (next_room_id>=MAX_ROOMS), CUALQUIER hueco nuevo de CUALQUIER sala o
    ; direccion puede acabar apuntando aqui, y cada uno es "nuevo" desde su
    ; propio punto de vista (su room_link seguia a 254) aunque el destino
    ; sea siempre el mismo. Si el jefe YA EXISTE ([boss_room_ready]), no se
    ; regenera su laberinto (pisaria su entrada ya guardada) NI se reescribe
    ; su enlace "hacia atras" (tmp0-->sala_actual, mas abajo): ese enlace
    ; solo tiene sentido para SU sala de origen ORIGINAL, y solo hay 4
    ; direcciones posibles -- con mas de 4 huecos distintos saturando hacia
    ; el jefe (algo normal ya entrada la partida), dos de ellos acaban
    ; calculando el MISMO entry_side por pura aritmetica modular, y el
    ; segundo pisaba el enlace de vuelta del primero: el jugador podia
    ; entonces aparecer en una sala (jefe o cualquier otra reenlazada de
    ; rebote) por un lado que ya no tenia ninguna apertura real -- bug real:
    ; "morir sin mas entrando y saliendo de una sala".
    LDA AL,[tmp0]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ crg_link_back
    LDA AL,[boss_room_ready]
    CMP AL,#0
    JMPNZ crg_boss_existing
    MOV AL,#1
    STA [boss_room_ready],AL
    LDA AL,[entry_side]
    STA [boss_entry_side],AL  ; unica entrada real del jefe -- ver
                               ; crg_boss_existing, que la restaura en vez de
                               ; usar el entry_side de un hueco distinto

crg_link_back:
    ; enlaza tmp0 --entry_side--> sala_actual (primera vez de verdad: sala
    ; normal, o la primerisima llegada al jefe)
    LDA AL,[tmp0]
    SHL AL,#2
    LDA BL,[entry_side]
    ADD AL,BL
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    LDA AL,[room_num]
    STA [BX],AL

    LDA AL,[next_room_id]
    CMP AL,#MAX_ROOMS
    JMPNC crg_no_bump         ; ya saturado -- no crece mas
    ADD AL,#1
    STA [next_room_id],AL
crg_no_bump:

    ; guarda de que sala se viene ANTES de pisarla con la nueva: ahi es
    ; donde gen_and_save_current_room coloca la llave si a la sala nueva le
    ; toca puerta (ver su comentario)
    LDA AL,[room_num]
    STA [prev_room_num],AL

    LDA AL,[tmp0]
    STA [room_num],AL

    MOV AL,#1
    STA [award_points],AL
    CALL gen_and_save_current_room
    JMP crg_common

crg_boss_existing:
    ; el jefe ya existia (otro hueco lo genero antes) -- solo se restaura,
    ; sin regenerar ni reescribir su enlace de vuelta; SI puntua (este hueco
    ; concreto es la primera vez que se cruza, aunque el destino no sea
    ; nuevo -- mismo criterio de puntos que gen_and_save_current_room,
    ; duplicado aqui porque esa rutina no llega a llamarse en esta rama).
    ;
    ; [entry_side] AQUI es el de ESTE hueco concreto (puede ser cualquiera
    ; de las 4 direcciones, segun desde donde se sature) -- NO tiene por que
    ; coincidir con la unica entrada real y permanente del jefe
    ; ([boss_entry_side], fijada la primera vez). Se sobreescribe antes de
    ; seguir: place_player_spawn (en crg_common) coloca al jugador segun
    ; [entry_side], y solo hay una pared realmente abierta en el jefe.
    LDA AL,[boss_entry_side]
    STA [entry_side],AL

    LDA AL,[tmp0]
    STA [room_num],AL
    CALL restore_room_state
    MOV AL,#10
    CALL score_add
    CALL update_score_hud
    MOV BL,#lo(JINGLE_TUNE)
    MOV BH,#hi(JINGLE_TUNE)
    CALL play_tune
    JMP crg_common

crg_known:
    LDA AL,[tmp0]
    STA [room_num],AL
    CALL restore_room_state

    ; si el destino (ya conocido) es el jefe, [entry_side] sigue siendo el
    ; de ESTE hueco concreto (OPP_OF_DIR de por donde se ha cruzado esta
    ; vez) -- que puede ser cualquiera de los alias hacia el jefe, no
    ; necesariamente su unica entrada real. Mismo arreglo que
    ; crg_boss_existing, aqui tambien hace falta: una vez que un hueco
    ; alias concreto queda enlazado (tras su primer uso), TODAS las veces
    ; siguientes que se cruza pasan por aqui, no por crg_boss_existing.
    LDA AL,[tmp0]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ crg_common
    LDA AL,[boss_entry_side]
    STA [entry_side],AL

crg_common:
    CALL draw_maze
    CALL place_player_spawn
    CALL setup_enemies
    RET

; ============================================================================
;  gen_and_save_current_room:  genera la sala [room_num] desde cero. El
;  hueco de [entry_side] ya esta enlazado (por quien llama, apuntando a la
;  sala anterior -- o sin explorar, 254, si es la sala 0) y se fuerza
;  abierto de todas formas; los otros 3 lados se sortean UNO A UNO (mitad y
;  mitad) para que salga con 1 a 4 huecos en total, no solo entrada+salida.
;  Como mucho uno de esos huecos extra puede salir CANDADO en vez de
;  abierto (1 de cada 8 tiradas, y solo si esta sala no tenia ya uno): se ve
;  como una puerta (linea sencilla) pero cell_walls se queda CERRADO ahi
;  hasta usar una llave, que se coloca en una celda cualquiera de esta misma
;  sala (siempre alcanzable por el arbol de expansion, nunca en otra sala,
;  para que abrirla nunca dependa de haber visitado nada mas). Una sala
;  puede quedarse asi con 0 salidas utilizables ademas de la entrada --
;  fuerza a retroceder, a proposito. Cada hueco (abierto o, tras abrirse,
;  antes candado) deja su room_link en 254 (se asignara sala real la
;  primera vez que se cruce, en cross_room_gap). Guarda todo en
;  persist_*[room_num]; si [award_points] no es 0, suma puntos.
; ============================================================================
gen_and_save_current_room:
    LDA AL,[entry_side]
    ADD AL,#1
    AND AL,#3
    STA [cand0],AL
    ADD AL,#1
    AND AL,#3
    STA [cand1],AL
    ADD AL,#1
    AND AL,#3
    STA [cand2],AL

    MOV AL,#255
    STA [door_dir],AL        ; sin puerta todavia en esta sala

    LDA AL,[entry_side]
    CALL side_to_rc
    LDA AL,[rc_row]
    STA [entry_row],AL
    LDA AL,[rc_col]
    STA [entry_col],AL

    CALL gen_maze

    LDA CL,[entry_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[entry_col]
    ADD AL,BL
    STA [od_cell],AL
    LDA AL,[entry_side]
    STA [od_dir],AL
    CALL open_dir

    ; la sala del jefe NUNCA saca salidas propias ademas de su entrada --
    ; es la sala final, no hace falta que seguir explorando desde ahi de
    ; verdad, y cada salida extra suya seria OTRO hueco que, saturado
    ; next_room_id, volveria a apuntar al jefe (ver la nota de
    ; cross_room_gap sobre por que eso corrompia enlaces).
    LDA AL,[room_num]
    CMP AL,#BOSS_ROOM_NUM
    JMPZ gsc_no_extra_exits

    LDA AL,[cand0]
    CALL gsc_roll_side
    LDA AL,[cand1]
    CALL gsc_roll_side
    LDA AL,[cand2]
    CALL gsc_roll_side
gsc_no_extra_exits:

    LDA AL,[door_dir]
    CMP AL,#255
    JMPZ gsc_no_key

    ; la llave de la puerta de ESTA sala NUNCA esta en esta misma sala --
    ; vive en [prev_room_num] (la sala de la que se vino, ver la nota de
    ; cabecera): asi abrirla exige de verdad haber ido a buscarla a otra
    ; sala (incluso volviendo atras), no solo cruzar esta de camino a la
    ; puerta. Esta sala se queda sin llave propia (key_cell=255) -- si mas
    ; adelante uno de SUS hijos saca puerta a su vez, sera esa generacion la
    ; que escriba una llave aqui (gsc_maybe_lock ya comprueba antes que el
    ; padre no tenga ya una puesta, ver mas abajo). Cualquier llave abre
    ; cualquier puerta (ver door_check) -- lo unico que importa de DONDE
    ; viene esta llave concreta es que nunca coincida con la sala de su
    ; propia puerta.
    MOV AL,#255
    STA [key_cell],AL
    MOV AL,#0
    STA [key_taken],AL

    ; celda al azar 0..NCELLS-1 DENTRO DE prev_room_num -- NCELLS(18) no es
    ; potencia de 2, asi que "rnd() & 31" ya no vale tal cual (daria hasta
    ; 31); se descarta y se vuelve a tirar cuando salga fuera de rango (con
    ; 18 de 32 posibles, toca repetir menos de 2 veces de media)
gsc_key_roll:
    CALL rnd
    AND AL,#31
    CMP AL,#NCELLS
    JMPNC gsc_key_roll
    STA [tmp1],AL                 ; celda elegida para la llave

    LDA CL,[prev_room_num]
    MOV BL,#lo(persist_key_cell)
    MOV BH,#hi(persist_key_cell)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL
    LDA CL,[prev_room_num]
    MOV BL,#lo(persist_key_taken)
    MOV BH,#hi(persist_key_taken)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    JMP gsc_key_done
gsc_no_key:
    MOV AL,#255
    STA [key_cell],AL        ; celda imposible -- nunca coincide
    MOV AL,#0
    STA [key_taken],AL
gsc_key_done:

    ; --- corazon de repuesto: de vez en cuando (mas a menudo si esta sala
    ; ya tiene enemigos, es decir es "dificil" -- las dos primeras nunca los
    ; tienen), o siempre si el jugador lleva 3 salas nuevas seguidas con una
    ; sola vida; nunca si ya esta a vidas maximas (no serviria de nada).
    LDA AL,[lives]
    CMP AL,#1
    JMPNZ gsc_life_reset
    LDA AL,[low_life_rooms]
    ADD AL,#1
    STA [low_life_rooms],AL
    JMP gsc_life_done
gsc_life_reset:
    MOV AL,#0
    STA [low_life_rooms],AL
gsc_life_done:

    LDA AL,[lives]
    CMP AL,#MAX_LIVES
    JMPNC gsc_no_heart        ; ya a tope -- no coloca corazon

    LDA AL,[low_life_rooms]
    CMP AL,#3
    JMPNC gsc_heart_yes       ; 3 salas nuevas seguidas a 1 vida -- lo fuerza

    LDA AL,[room_num]
    CMP AL,#2
    JMPC gsc_heart_easy       ; room_num<2: todavia sin enemigos
    MOV AL,#3                 ; sala "dificil": 1 de cada 4
    JMP gsc_heart_mask
gsc_heart_easy:
    MOV AL,#7                 ; sala facil: 1 de cada 8
gsc_heart_mask:
    STA [tmp1],AL
    CALL rnd
    LDA BL,[tmp1]
    AND AL,BL
    CMP AL,#0
    JMPNZ gsc_no_heart

gsc_heart_yes:
    MOV AL,#0
    STA [low_life_rooms],AL
    ; celda al azar, distinta de la de la llave (para no amontonar las dos
    ; en el mismo sitio); mismo descarte-y-repite que key_cell, NCELLS(18)
    ; no es potencia de 2
gsc_heart_roll:
    CALL rnd
    AND AL,#31
    CMP AL,#NCELLS
    JMPNC gsc_heart_roll
    LDA BL,[key_cell]
    CMP AL,BL
    JMPZ gsc_heart_roll
    STA [heart_cell],AL
    MOV AL,#0
    STA [heart_taken],AL
    JMP gsc_heart_done
gsc_no_heart:
    MOV AL,#255
    STA [heart_cell],AL       ; celda imposible -- nunca coincide
    MOV AL,#0
    STA [heart_taken],AL
gsc_heart_done:

    CALL save_room_state

    LDA AL,[award_points]
    CMP AL,#0
    JMPZ gsc_noscore
    MOV AL,#10
    CALL score_add
    CALL update_score_hud
    MOV BL,#lo(JINGLE_TUNE)
    MOV BH,#hi(JINGLE_TUNE)
    CALL play_tune
gsc_noscore:
    RET

; --- gsc_roll_side: entra AL = lado candidato (uno de los 3 distintos de
; entry_side). La mitad de las veces se queda cerrado (pared normal, no
; hace nada). La otra mitad es un hueco -- y de esa mitad, 1 de cada 4 sale
; CANDADO en vez de abierto de entrada (solo si esta sala no tenia ya una
; puerta: como mucho una por sala, para no complicar el seguimiento de
; llaves). Un hueco candado NO se fuerza abierto todavia (se queda cerrado
; en cell_walls hasta abrirse con la llave); solo se marca en door_bits
; (dibujo de linea sencilla en vez de doble) y se guarda [door_cell]/
; [door_dir] para door_check.
gsc_roll_side:
    STA [tmp3],AL
    CALL rnd
    AND AL,#7
    CMP AL,#4
    JMPNC gsc_maybe_lock      ; 4-7 (mitad): hueco (abierto o candado)
    RET                       ; 0-3 (mitad): cerrado

gsc_maybe_lock:
    CMP AL,#7
    JMPNZ gsc_side_open       ; 4-6: hueco abierto normal
    LDA AL,[door_dir]
    CMP AL,#255
    JMPNZ gsc_side_open       ; ya habia puerta en esta sala -> abierto normal

    ; la llave de esta puerta viviria en prev_room_num (ver gen_and_save_
    ; current_room) -- dos guardas antes de comprometerse a la puerta:
    LDA AL,[room_num]
    CMP AL,#0
    JMPZ gsc_side_open        ; sala 0 no tiene sala anterior: sin puerta
    CMP AL,#BOSS_ROOM_NUM
    JMPZ gsc_side_open        ; la sala del jefe tampoco saca puerta/llave

    LDA CL,[prev_room_num]
    MOV BL,#lo(persist_key_cell)
    MOV BH,#hi(persist_key_cell)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#255
    JMPNZ gsc_side_open        ; prev_room_num ya le dio su llave a un
                               ; hermano -- como mucho una llave por sala
                               ; donante; esta se abre normal en vez de
                               ; bloquear con una llave que no cabria

    ; prev_room_num TIENE a su vez su propia entrada con candado (su
    ; persist_door_dir, fijado para siempre al generarla, ya != 255):
    ; alojar aqui TAMBIEN una llave dejaria una sala con llave y puerta a la
    ; vez (no explotable -- no se puede usar la llave alojada para abrir la
    ; propia entrada, ya cruzada para poder estar aqui -- pero es justo la
    ; combinacion que no se quiere ver nunca). Se abre normal en su lugar.
    LDA CL,[prev_room_num]
    MOV BL,#lo(persist_door_dir)
    MOV BH,#hi(persist_door_dir)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#255
    JMPNZ gsc_side_open

    LDA AL,[tmp3]
    STA [door_dir],AL
    CALL side_to_rc
    LDA CL,[rc_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[rc_col]
    ADD AL,BL
    STA [door_cell],AL

    LDA CL,[tmp3]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[door_cell]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    LDA AL,[room_num]
    SHL AL,#2
    LDA BL,[tmp3]
    ADD AL,BL
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    MOV AL,#254
    STA [BX],AL
    RET

gsc_side_open:
    LDA AL,[tmp3]
    CALL gsc_open_extra
    RET

; --- gsc_open_extra: entra AL = lado extra a abrir. Fuerza su hueco de
; borde abierto en cell_walls y deja su room_link[room_num][lado] en 254
; (hueco sin explorar todavia).
gsc_open_extra:
    STA [tmp3],AL
    CALL side_to_rc
    LDA CL,[rc_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[rc_col]
    ADD AL,BL
    STA [od_cell],AL
    LDA AL,[tmp3]
    STA [od_dir],AL
    CALL open_dir

    LDA AL,[room_num]
    SHL AL,#2
    LDA BL,[tmp3]
    ADD AL,BL
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(room_link)
    MOV BH,#hi(room_link)
    CALL idx_ptr
    MOV AL,#254
    STA [BX],AL
    RET

; --- side_to_rc: entra AL=lado (DIR_N..DIR_W) ; sale [rc_row],[rc_col] --
; entrada/salida siempre en el MEDIO de su lado (columna 4 para N/S, fila 2
; para E/O): mas sencillo que sortear tambien la posicion a lo largo del
; borde, y de sobra para que la entrada pueda estar en cualquiera de los
; 4 lados como pide el enunciado.
side_to_rc:
    CMP AL,#DIR_N
    JMPNZ s2rc_e
    MOV AL,#0
    STA [rc_row],AL
    MOV AL,#3
    STA [rc_col],AL
    RET
s2rc_e:
    CMP AL,#DIR_E
    JMPNZ s2rc_s
    MOV AL,#1
    STA [rc_row],AL
    MOV AL,#(MAZE_COLS-1)
    STA [rc_col],AL
    RET
s2rc_s:
    CMP AL,#DIR_S
    JMPNZ s2rc_w
    MOV AL,#(MAZE_ROWS-1)
    STA [rc_row],AL
    MOV AL,#3
    STA [rc_col],AL
    RET
s2rc_w:
    MOV AL,#1
    STA [rc_row],AL
    MOV AL,#0
    STA [rc_col],AL
    RET

; --- place_player_spawn: coloca (player_x,player_y) justo dentro del hueco
; de entrada -- como entrada/salida estan siempre en el mismo sitio fijo de
; su lado (side_to_rc), las coordenadas de aparicion tambien lo estan.
place_player_spawn:
    MOV AL,#DIR_S
    STA [last_fire_dir],AL   ; mirando "hacia abajo" por defecto al aparecer
    MOV AL,#0
    STA [i],AL
pps_clr_shots:
    LDA CL,[i]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#MAX_SHOTS
    JMPNZ pps_clr_shots

    MOV AL,#0
    STA [walk_phase],AL      ; que no aparezca con un pie ya levantado
    STA [walk_timer],AL
    STA [walk_idle],AL

    ; la sala 0 (la primera) no tiene "entrada" de verdad mientras el
    ; jugador no la haya dejado atras ni una sola vez -- aparece cerca del
    ; centro en vez de pegado a un lado, que no tendria sentido para la sala
    ; de partida (ni para un respawn por chocar con una pared ahi mismo
    ; antes de encontrar ninguna salida: sigue sin haber "de donde viene").
    ; [room0_entered] lo pone a 1 cross_room_gap, no aqui, justo al CRUZAR
    ; hacia afuera de la sala 0 por primera vez -- a partir de ahi, si el
    ; jugador vuelve a la 0 mas tarde (retrocediendo, o al respawnear si la
    ; muerte fue alli), si que hay un lado de entrada real que respetar,
    ; igual que en cualquier otra sala. Antes esto NO distinguia nunca la
    ; primera vez de las siguientes: siempre aparecia en el centro sin
    ; importar el lado, perdiendo la referencia de por donde se habia
    ; vuelto a entrar.
    ;
    ; Cuando SI toca el centro: tiene que caer bien DENTRO del interior de
    ; una celda (lejos de sus 4 bordes, donde puede haber pared -- ahora
    ; mortal), no en las coordenadas de pantalla "61,29" a secas: esas caen
    ; justo en el desplazamiento local 13 de su celda, que es exactamente
    ; donde puede haber una linea de pared (ver wall_hline_bottom/right,
    ; CELL_H-3). Celda central (fila 1, columna 3), desplazamiento local
    ; (5,5): bien lejos de los bordes (0,2 y 13,15) sea cual sea el
    ; laberinto que le toque a esta partida.
    LDA AL,[room_num]
    CMP AL,#0
    JMPNZ pps_not_room0
    LDA AL,[room0_entered]
    CMP AL,#0
    JMPNZ pps_not_room0      ; ya se ha DEJADO la sala 0 alguna vez (marcado
                             ; por cross_room_gap al salir, no aqui) -- como
                             ; cualquier sala
    MOV AL,#(3*CELL_W+5)
    STA [player_x],AL
    MOV AL,#(1*CELL_H+5)
    STA [player_y],AL
    RET
pps_not_room0:

    ; posiciones para la rejilla de 6x3 celdas de 21x21: columna/fila
    ; central (side_to_rc) mas un margen de seguridad de ~5-8 px hacia
    ; dentro, lejos de cualquier borde de celda
    LDA AL,[entry_side]
    CMP AL,#DIR_N
    JMPNZ pps_e
    MOV AL,#(3*CELL_W+8)
    STA [player_x],AL
    MOV AL,#5
    STA [player_y],AL
    RET
pps_e:
    CMP AL,#DIR_E
    JMPNZ pps_s
    MOV AL,#(MAZE_COLS*CELL_W-PLAYER_W-5)
    STA [player_x],AL
    MOV AL,#(1*CELL_H+7)
    STA [player_y],AL
    RET
pps_s:
    CMP AL,#DIR_S
    JMPNZ pps_w
    MOV AL,#(3*CELL_W+8)
    STA [player_x],AL
    MOV AL,#(MAZE_ROWS*CELL_H-PLAYER_H-5)
    STA [player_y],AL
    RET
pps_w:
    MOV AL,#5
    STA [player_x],AL
    MOV AL,#(1*CELL_H+7)
    STA [player_y],AL
    RET

; --- open_dir: pone a 1 (abierto) el bit de direccion [od_dir] en
; cell_walls[[od_cell]] -- usado por new_room para forzar el hueco de
; entrada/salida en el borde de la pantalla.
open_dir:
    LDA CL,[od_dir]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL

    LDA CL,[od_cell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[tmp1]
    OR  AL,DL
    STA [BX],AL
    RET

; --- room_off: entra BX ya cargado con la base de un array de NCELLS(18)
; bytes por sala (persist_walls/persist_doors); suma room_num*18 -- no hay
; MUL, y 18 no es potencia de 2 (no vale partirlo en SHR/SHL como cuando
; era 32), asi que sale de la tabla ROOM_OFF_LO/HI precalculada. Usa SUS
; PROPIAS variables de escritorio (ro_lo/ro_hi/ro_off/ro_offhi), nunca
; tmp1/tmp2/tmp3/k -- sus dos unicas llamadoras (save_room_state/
; restore_room_state) guardan en tmp1 el byte que estan copiando
; precisamente ALREDEDOR de la llamada a room_off, asi que si esta rutina
; tocara tmp1 lo pisaria a medio copiar (bug real que se dio: el byte
; copiado siempre salia como lo(base), por ejemplo 251 = lo(persist_walls),
; en vez del dato real).
room_off:
    MOV AL,BL
    STA [ro_lo],AL
    MOV AL,BH
    STA [ro_hi],AL

    LDA CL,[room_num]
    MOV BL,#lo(ROOM_OFF_LO)
    MOV BH,#hi(ROOM_OFF_LO)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ro_off],AL
    LDA CL,[room_num]
    MOV BL,#lo(ROOM_OFF_HI)
    MOV BH,#hi(ROOM_OFF_HI)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ro_offhi],AL

    LDA BL,[ro_lo]
    LDA BH,[ro_hi]
    LDA AL,[ro_off]
    ADD BL,AL
    JMPNC ro_c1
    ADD BH,#1
ro_c1:
    LDA AL,[ro_offhi]
    ADD BH,AL
    RET

; --- save_room_state / restore_room_state: copian cell_walls/door_bits (32
; bytes cada uno) y los campos sueltos de la sala actual (key_taken/
; key_cell/door_cell/door_dir) hacia/desde persist_*[room_num]. room_link NO
; se toca aqui -- vive en su propio array indexado por sala*4+lado y se lee/
; escribe directamente donde hace falta (cross_room_gap/gen_and_save).
save_room_state:
    MOV AL,#0
    STA [i],AL
srs_l:
    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    MOV BL,#lo(persist_walls)
    MOV BH,#hi(persist_walls)
    CALL room_off
    LDA CL,[i]
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    MOV BL,#lo(persist_doors)
    MOV BH,#hi(persist_doors)
    CALL room_off
    LDA CL,[i]
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NCELLS
    JMPNZ srs_l

    LDA CL,[room_num]
    MOV BL,#lo(persist_key_taken)
    MOV BH,#hi(persist_key_taken)
    CALL idx_ptr
    LDA AL,[key_taken]
    STA [BX],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_key_cell)
    MOV BH,#hi(persist_key_cell)
    CALL idx_ptr
    LDA AL,[key_cell]
    STA [BX],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_door_cell)
    MOV BH,#hi(persist_door_cell)
    CALL idx_ptr
    LDA AL,[door_cell]
    STA [BX],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_door_dir)
    MOV BH,#hi(persist_door_dir)
    CALL idx_ptr
    LDA AL,[door_dir]
    STA [BX],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_heart_taken)
    MOV BH,#hi(persist_heart_taken)
    CALL idx_ptr
    LDA AL,[heart_taken]
    STA [BX],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_heart_cell)
    MOV BH,#hi(persist_heart_cell)
    CALL idx_ptr
    LDA AL,[heart_cell]
    STA [BX],AL
    RET

restore_room_state:
    MOV AL,#0
    STA [i],AL
rrs_l:
    MOV BL,#lo(persist_walls)
    MOV BH,#hi(persist_walls)
    CALL room_off
    LDA CL,[i]
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    MOV BL,#lo(persist_doors)
    MOV BH,#hi(persist_doors)
    CALL room_off
    LDA CL,[i]
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NCELLS
    JMPNZ rrs_l

    LDA CL,[room_num]
    MOV BL,#lo(persist_key_taken)
    MOV BH,#hi(persist_key_taken)
    CALL idx_ptr
    LDA AL,[BX]
    STA [key_taken],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_key_cell)
    MOV BH,#hi(persist_key_cell)
    CALL idx_ptr
    LDA AL,[BX]
    STA [key_cell],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_door_cell)
    MOV BH,#hi(persist_door_cell)
    CALL idx_ptr
    LDA AL,[BX]
    STA [door_cell],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_door_dir)
    MOV BH,#hi(persist_door_dir)
    CALL idx_ptr
    LDA AL,[BX]
    STA [door_dir],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_heart_taken)
    MOV BH,#hi(persist_heart_taken)
    CALL idx_ptr
    LDA AL,[BX]
    STA [heart_taken],AL

    LDA CL,[room_num]
    MOV BL,#lo(persist_heart_cell)
    MOV BH,#hi(persist_heart_cell)
    CALL idx_ptr
    LDA AL,[BX]
    STA [heart_cell],AL
    RET

; ============================================================================
;  gen_maze: rellena cell_walls[0..31] con un laberinto perfecto nuevo
;  (backtracking recursivo iterativo -- ver la nota de cabecera). Arranca en
;  la celda de entrada; el camino recorrido se guarda con PUSH/POP de
;  verdad (la propia pila del hardware): al retroceder, POP devuelve la
;  celda anterior, y [stack_depth] lleva la cuenta de cuantos PUSH quedan
;  sin sacar. Termina cuando, sin vecina libre donde seguir, stack_depth ya
;  esta a 0 (vuelto del todo al principio) -- NO cuando se han visitado las
;  32 celdas: eso puede pasar con celdas todavia sin "deshacer" en la pila,
;  y como esta pila es la misma que usan CALL/RET, salir dejando alguna sin
;  sacar corrompe el siguiente RET (se descubrio asi: saltaba a PC=0xFFF1).
; ============================================================================
gen_maze:
    MOV AL,#0
    STA [i],AL
gm_clr_l:
    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    LDA CL,[i]
    MOV BL,#lo(visited)
    MOV BH,#hi(visited)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NCELLS
    JMPNZ gm_clr_l

    LDA CL,[entry_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[entry_col]
    ADD AL,BL
    STA [cur_cell],AL
    LDA CL,[cur_cell]
    MOV BL,#lo(visited)
    MOV BH,#hi(visited)
    CALL idx_ptr
    MOV AL,#1
    STA [BX],AL
    MOV AL,#0
    STA [stack_depth],AL

gm_loop:
    LDA CL,[cur_cell]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cur_row],AL
    LDA CL,[cur_cell]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cur_col],AL

    CALL rnd
    AND AL,#3
    STA [start_dir],AL
    MOV AL,#0
    STA [k],AL
    MOV AL,#0
    STA [found],AL

gm_scan_l:
    LDA AL,[start_dir]
    LDA BL,[k]
    ADD AL,BL
    AND AL,#3
    STA [d],AL

    LDA CL,[d]
    MOV BL,#lo(DR_OF_DIR)
    MOV BH,#hi(DR_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cur_row]
    ADD AL,BL
    STA [mz_row],AL

    LDA CL,[d]
    MOV BL,#lo(DC_OF_DIR)
    MOV BH,#hi(DC_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cur_col]
    ADD AL,BL
    STA [mz_col],AL

    LDA AL,[mz_row]
    CMP AL,#MAZE_ROWS
    JMPNC gm_scan_next
    LDA AL,[mz_col]
    CMP AL,#MAZE_COLS
    JMPNC gm_scan_next

    LDA CL,[mz_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[mz_col]
    ADD AL,BL
    STA [try_cell],AL

    LDA CL,[try_cell]
    MOV BL,#lo(visited)
    MOV BH,#hi(visited)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPNZ gm_scan_next

    ; abre cur->d y try->opuesta(d)
    LDA CL,[d]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[cur_cell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[tmp1]
    OR  AL,DL
    STA [BX],AL

    LDA CL,[d]
    MOV BL,#lo(OPP_OF_DIR)
    MOV BH,#hi(OPP_OF_DIR)
    CALL idx_ptr
    LDA CL,[BX]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[try_cell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[tmp1]
    OR  AL,DL
    STA [BX],AL

    LDA CL,[try_cell]
    MOV BL,#lo(visited)
    MOV BH,#hi(visited)
    CALL idx_ptr
    MOV AL,#1
    STA [BX],AL

    LDA AL,[cur_cell]
    PUSH AL
    LDA AL,[stack_depth]
    ADD AL,#1
    STA [stack_depth],AL
    LDA AL,[try_cell]
    STA [cur_cell],AL

    MOV AL,#1
    STA [found],AL
    JMP gm_after_scan

gm_scan_next:
    LDA AL,[k]
    ADD AL,#1
    STA [k],AL
    CMP AL,#4
    JMPNZ gm_scan_l

gm_after_scan:
    LDA AL,[found]
    CMP AL,#0
    JMPNZ gm_loop

    ; sin vecina sin visitar: retrocede, o termina si ya no queda camino
    ; que deshacer (stack_depth==0) -- IMPORTANTE: esto DEBE quedar en 0
    ; antes del RET, porque estos PUSH comparten la misma pila que usan
    ; CALL/RET; terminar con alguno sin sacar dejaria un byte de mas ahi
    ; y el siguiente RET saltaria a basura en vez de volver bien.
    LDA AL,[stack_depth]
    CMP AL,#0
    JMPZ gm_done
    POP AL
    STA [cur_cell],AL
    LDA AL,[stack_depth]
    SUB AL,#1
    STA [stack_depth],AL
    JMP gm_loop

gm_done:
    RET

; ============================================================================
;  draw_maze: pinta en `walls` (limpio antes) las paredes de cell_walls[] --
;  cada celda dibuja su lado N y O si estan cerrados (asi cada pared interior
;  se dibuja una sola vez, desde uno de los dos lados que la comparten);
;  aparte, la fila de abajo dibuja su lado S y la columna de la derecha su
;  lado E (los dos bordes exteriores que ninguna celda cubre por N/O).
; ============================================================================
draw_maze:
    CALL clr_walls
    MOV AL,#0
    STA [i],AL
dm_l:
    LDA CL,[i]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cur_row],AL
    LDA CL,[i]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cur_col],AL

    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cwv],AL
    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[BX]
    STA [dbv],AL

    LDA AL,[cwv]
    AND AL,#1               ; bit0 = N
    JMPNZ dm_skip_n
    LDA AL,[dbv]
    AND AL,#1
    JMPZ dm_n_wall
    CALL wall_hline_top_door
    JMP dm_skip_n
dm_n_wall:
    CALL wall_hline_top
dm_skip_n:
    LDA AL,[cwv]
    AND AL,#8               ; bit3 = O
    JMPNZ dm_skip_w
    LDA AL,[dbv]
    AND AL,#8
    JMPZ dm_w_wall
    CALL wall_vline_left_door
    JMP dm_skip_w
dm_w_wall:
    CALL wall_vline_left
dm_skip_w:

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NCELLS
    JMPNZ dm_l

    MOV AL,#0
    STA [cur_col],AL
dm_s_l:
    MOV AL,#(MAZE_ROWS-1)
    STA [cur_row],AL
    LDA CL,[cur_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cur_col]
    ADD AL,BL
    STA [i],AL
    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    AND AL,#4               ; bit2 = S
    JMPNZ dm_s_skip
    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[BX]
    AND AL,#4
    JMPZ dm_s_wall
    CALL wall_hline_bottom_door
    JMP dm_s_skip
dm_s_wall:
    CALL wall_hline_bottom
dm_s_skip:
    LDA AL,[cur_col]
    ADD AL,#1
    STA [cur_col],AL
    CMP AL,#MAZE_COLS
    JMPNZ dm_s_l

    MOV AL,#0
    STA [cur_row],AL
dm_e_l:
    MOV AL,#(MAZE_COLS-1)
    STA [cur_col],AL
    LDA CL,[cur_row]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cur_col]
    ADD AL,BL
    STA [i],AL
    LDA CL,[i]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    AND AL,#2               ; bit1 = E
    JMPNZ dm_e_skip
    LDA CL,[i]
    MOV BL,#lo(door_bits)
    MOV BH,#hi(door_bits)
    CALL idx_ptr
    LDA AL,[BX]
    AND AL,#2
    JMPZ dm_e_wall
    CALL wall_vline_right_door
    JMP dm_e_skip
dm_e_wall:
    CALL wall_vline_right
dm_e_skip:
    LDA AL,[cur_row]
    ADD AL,#1
    STA [cur_row],AL
    CMP AL,#MAZE_ROWS
    JMPNZ dm_e_l
    RET

; --- wall_hline_top/bottom, wall_vline_left/right: la "linea doble" de una
; pared, usando (cur_row,cur_col) como celda -- dos trazos de 1 px, 2 px de
; distancia (0 y 2 desde el borde exterior de la celda).
wall_hline_top:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
whl_top_l:
    LDA AL,[wx0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[wy0]
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wy0]
    ADD AL,#2
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_W
    JMPNZ whl_top_l
    RET

wall_hline_bottom:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
whl_bot_l:
    LDA AL,[wx0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[wy0]
    ADD AL,#(CELL_H-1)
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wy0]
    ADD AL,#(CELL_H-3)
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_W
    JMPNZ whl_bot_l
    RET

wall_vline_left:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
wvl_left_l:
    LDA AL,[wy0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    LDA AL,[wx0]
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wx0]
    ADD AL,#2
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvl_left_l
    RET

wall_vline_right:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
wvl_right_l:
    LDA AL,[wy0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    LDA AL,[wx0]
    ADD AL,#(CELL_W-1)
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wx0]
    ADD AL,#(CELL_W-3)
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvl_right_l
    RET

; --- wall_*_door: version de un solo trazo (en vez de doble) de las cuatro
; anteriores, para la puerta con llave de la sala (siempre en un borde
; exterior, nunca interior -- por eso hacen falta las 4, no solo top/left).
wall_hline_top_door:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
whtd_l:
    LDA AL,[wx0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[wy0]
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_W
    JMPNZ whtd_l
    RET

wall_hline_bottom_door:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
whbd_l:
    LDA AL,[wx0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[wy0]
    ADD AL,#(CELL_H-1)
    STA [px_y],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_W
    JMPNZ whbd_l
    RET

wall_vline_left_door:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
wvld_l:
    LDA AL,[wy0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    LDA AL,[wx0]
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvld_l
    RET

wall_vline_right_door:
    LDA AL,[cur_row]
    CALL row_to_px
    STA [wy0],AL
    LDA AL,[cur_col]
    CALL col_to_px
    STA [wx0],AL
    MOV AL,#0
    STA [wk],AL
wvrd_l:
    LDA AL,[wy0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    LDA AL,[wx0]
    ADD AL,#(CELL_W-1)
    STA [px_x],AL
    CALL walls_set_px
    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvrd_l
    RET

; ============================================================================
;  JUGADOR: lectura de encoders, movimiento y colision con paredes
; ============================================================================
update_player:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_pos_prev],CL
    CALL clamp_delta
    STA [dy],AL

    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_pos_prev],CL
    CALL clamp_delta
    STA [pdx],AL

    ; animacion de andar: alterna que pie queda levantado (1px) mientras se
    ; mueve por cualquiera de los dos ejes; parado, los dos pies vuelven a
    ; la misma altura (walk_phase=0 -- ver draw_frame, indices 10/11 de
    ; PLAYER_SPRITE_DX/DY, los dos unicos puntos del pie). Un encoder real
    ; no manda un detente en CADA fotograma ni girando despacio pero sin
    ; parar (pdx/dy valen 0 la mayoria de fotogramas entre un "clic" y el
    ; siguiente): resetear la animacion en el primer fotograma sin detente
    ; nuevo la dejaba practicamente invisible. walk_idle cuenta fotogramas
    ; SEGUIDOS sin ningun detente; solo se resetea a quieto tras
    ; WALK_IDLE_FRAMES de esos, no al primero.
    LDA AL,[pdx]
    CMP AL,#0
    JMPNZ uwa_moving
    LDA AL,[dy]
    CMP AL,#0
    JMPNZ uwa_moving

    LDA AL,[walk_idle]
    ADD AL,#1
    STA [walk_idle],AL
    CMP AL,#WALK_IDLE_FRAMES
    JMPC uwa_done            ; todavia no lleva bastante quieto
    MOV AL,#0
    STA [walk_phase],AL
    STA [walk_timer],AL
    JMP uwa_done
uwa_moving:
    MOV AL,#0
    STA [walk_idle],AL
    LDA AL,[walk_timer]
    ADD AL,#1
    STA [walk_timer],AL
    CMP AL,#WALK_ANIM_FRAMES
    JMPC uwa_done            ; todavia no toca cambiar de pie
    MOV AL,#0
    STA [walk_timer],AL
    LDA AL,[walk_phase]
    CMP AL,#1
    JMPZ uwa_right
    MOV AL,#1
    STA [walk_phase],AL
    JMP uwa_done
uwa_right:
    MOV AL,#2
    STA [walk_phase],AL
uwa_done:

    ; direccion de cara (para apuntar al disparar, ver update_fire) -- SOLO
    ; una de las 4 cardinales, nunca diagonal (igual regla que los
    ; enemigos tiradores, que tambien disparan en linea recta N/E/S/O). Se
    ; actualiza con cualquier eje que se haya movido de verdad este
    ; fotograma; si se movieron los dos a la vez, gana el eje Y por
    ; procesarse despues (sencillo, y en la practica rara vez se giran los
    ; dos encoders exactamente en el mismo fotograma). El resto del tiempo
    ; se queda con la ultima conocida, para poder disparar quieto.
    LDA AL,[pdx]
    CMP AL,#0
    JMPZ upd_facex_done
    AND AL,#0x80
    JMPZ upd_facex_pos
    MOV AL,#DIR_W
    STA [last_fire_dir],AL
    JMP upd_facex_done
upd_facex_pos:
    MOV AL,#DIR_E
    STA [last_fire_dir],AL
upd_facex_done:

    LDA AL,[dy]
    CMP AL,#0
    JMPZ upd_facey_done
    AND AL,#0x80
    JMPZ upd_facey_pos
    MOV AL,#DIR_N
    STA [last_fire_dir],AL
    JMP upd_facey_done
upd_facey_pos:
    MOV AL,#DIR_S
    STA [last_fire_dir],AL
upd_facey_done:

    ; --- eje X ---
    LDA AL,[player_x]
    LDA BL,[pdx]
    ADD AL,BL
    STA [try_x],AL

    ; ¿hay cruce de hueco de verdad? ESTE (pdx>=0) nunca necesita cuidado
    ; especial: 127+3 cabe de sobra en un byte, try_x nunca "envuelve", asi
    ; que basta un umbral fijo (128) sobre el propio try_x. OESTE (pdx<0) es
    ; el caso delicado: NO basta con mirar si try_x "parece" un numero alto
    ; (eso es tambien lo que pasa, por pura coincidencia, cuando el jugador
    ; YA esta cerca del borde ESTE y se mueve un poco hacia el oeste, sin
    ; haber envuelto en absoluto) -- hay que comprobar la UNICA condicion
    ; que de verdad significa "esto se va a ir por debajo de cero":
    ; |pdx| > player_x. Bug real (reportado: "me mata moviendo rapido
    ; norte/sur en el borde"): con el umbral viejo, moverse hacia el oeste
    ; estando ya cerca del borde ESTE (p.ej. saliendo de un cruce hacia el
    ; SUR momentos antes) se trataba como si hubiera cruzado un hueco que
    ; no estaba ahi, matando al jugador contra el interior normal de la
    ; sala.
    LDA AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east_chk2        ; pdx>=0 (ESTE): nunca hay envoltura real

    LDA AL,[pdx]
    NOT AL
    ADD AL,#1                  ; AL = |pdx|
    LDA BL,[player_x]
    CMP BL,AL                  ; player_x - |pdx|
    JMPC upx_oob                ; hubo prestamo (player_x < |pdx|) -> cruce real
    JMP upx_normal               ; si no, es solo movimiento normal

upx_east_chk2:
    LDA AL,[try_x]
    CMP AL,#128
    JMPNC upx_oob
upx_normal:
    LDA AL,[try_x]
    STA [test_x],AL
    LDA AL,[player_y]
    STA [test_y],AL
    CALL player_fits
    CMP AL,#0
    JMPZ upx_move
    CALL near_door
    CMP AL,#0
    JMPNZ upx_done          ; cerca de la puerta -- solo bloquea, no mata
    CALL play_zap
    CALL on_player_hit
    RET                     ; la posicion ya cambio (respawn), no seguir
upx_move:
    LDA AL,[try_x]
    STA [player_x],AL
    JMP upx_done
upx_oob:
    ; Los CUATRO lados se validan aqui igual, con un ULTIMO player_fits en
    ; su columna/fila extrema real (0 o 127) justo antes de cruzar -- antes
    ; solo OESTE/NORTE lo hacian (ver la nota de mas abajo, el motivo por el
    ; que ESOS dos lo necesitaban de verdad); ESTE/SUR se fiaban de que el
    ; player_fits normal, incremental, ya hubiera cubierto la ultima
    ; columna/fila antes de llegar a OOB -- valido en general, PERO
    ; clamp_delta permite hasta 3px de golpe: partiendo ya muy cerca del
    ; borde (try_x/y de un fotograma anterior pudo quedarse a 1-2px sin
    ; validar exactamente esa fila/columna extrema si el siguiente empujon
    ; salta directo a OOB), asi que se comprueba aqui tambien, sin excepcion,
    ; en vez de asumirlo.
    LDA AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east_chk

    ; OESTE: try_x envolvio (queria ir a negativo) -- columna extrema real: 0
    MOV AL,#0
    STA [test_x],AL
    JMP upx_edge_common
upx_east_chk:
    ; ESTE: columna extrema real: 127
    MOV AL,#127
    STA [test_x],AL
upx_edge_common:
    LDA AL,[player_y]
    STA [test_y],AL
    CALL player_fits
    CMP AL,#0
    JMPZ upx_edge_ok
    CALL near_door
    CMP AL,#0
    JMPNZ upx_done            ; cerca de la puerta -- solo bloquea, no mata
    CALL play_zap
    CALL on_player_hit
    RET                       ; la posicion ya cambio (respawn), no seguir
upx_edge_ok:
    LDA AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east
    MOV AL,#DIR_W
    JMP upx_trigger
upx_east:
    MOV AL,#DIR_E
upx_trigger:
    STA [exit_dir_taken],AL
    MOV AL,#1
    STA [room_transition_pending],AL
upx_done:
    LDA AL,[room_transition_pending]
    CMP AL,#0
    JMPNZ up_ret            ; ya se cruzo un hueco -- no hace falta seguir

    ; --- eje Y --- (mismo razonamiento corregido que el eje X -- ver su
    ; nota: SUR nunca envuelve, umbral fijo 64 sobre try_y; NORTE solo
    ; cruza de verdad si |dy| > player_y, nunca por un try_y que "parezca"
    ; alto por coincidencia)
    LDA AL,[player_y]
    LDA BL,[dy]
    ADD AL,BL
    STA [try_y],AL

    LDA AL,[dy]
    AND AL,#0x80
    JMPZ upy_south_chk2       ; dy>=0 (SUR): nunca hay envoltura real

    LDA AL,[dy]
    NOT AL
    ADD AL,#1                  ; AL = |dy|
    LDA BL,[player_y]
    CMP BL,AL                  ; player_y - |dy|
    JMPC upy_oob                ; hubo prestamo (player_y < |dy|) -> cruce real
    JMP upy_normal                ; si no, es solo movimiento normal

upy_south_chk2:
    LDA AL,[try_y]
    CMP AL,#64
    JMPNC upy_oob
upy_normal:
    LDA AL,[player_x]
    STA [test_x],AL
    LDA AL,[try_y]
    STA [test_y],AL
    CALL player_fits
    CMP AL,#0
    JMPZ upy_move
    CALL near_door
    CMP AL,#0
    JMPNZ up_ret            ; cerca de la puerta -- solo bloquea, no mata
    CALL play_zap
    CALL on_player_hit
    RET
upy_move:
    LDA AL,[try_y]
    STA [player_y],AL
    JMP up_ret
upy_oob:
    ; mismo refuerzo simetrico que upx_oob: SIEMPRE un ultimo player_fits en
    ; la fila extrema real (0 o 63) antes de cruzar, tambien para SUR (antes
    ; solo NORTE lo hacia) -- ver la nota de upx_oob.
    LDA AL,[dy]
    AND AL,#0x80
    JMPZ upy_south_chk

    ; NORTE: fila extrema real: 0
    MOV AL,#0
    STA [test_y],AL
    JMP upy_edge_common
upy_south_chk:
    ; SUR: fila extrema real: 63
    MOV AL,#63
    STA [test_y],AL
upy_edge_common:
    LDA AL,[player_x]
    STA [test_x],AL
    CALL player_fits
    CMP AL,#0
    JMPZ upy_edge_ok
    CALL near_door
    CMP AL,#0
    JMPNZ up_ret              ; cerca de la puerta -- solo bloquea, no mata
    CALL play_zap
    CALL on_player_hit
    RET
upy_edge_ok:
    LDA AL,[dy]
    AND AL,#0x80
    JMPZ upy_south
    MOV AL,#DIR_N
    JMP upy_trigger
upy_south:
    MOV AL,#DIR_S
upy_trigger:
    STA [exit_dir_taken],AL
    MOV AL,#1
    STA [room_transition_pending],AL
up_ret:
    RET

; --- clamp_delta: recorta AL (con signo) a [-3,+3] -- limite de velocidad
; del jugador, para que nunca pueda saltarse una pared de un solo fotograma
; (el trazo mas fino de pared mide 1 px, pero conviene margen de sobra).
clamp_delta:
    STA [tmp1],AL
    AND AL,#0x80
    JMPZ cd_pos
    LDA AL,[tmp1]
    ADD AL,#3
    JMPN cd_neg_clamp
    LDA AL,[tmp1]
    RET
cd_neg_clamp:
    MOV AL,#0xFD
    RET
cd_pos:
    LDA AL,[tmp1]
    CMP AL,#4
    JMPC cd_ok
    MOV AL,#3
    RET
cd_ok:
    LDA AL,[tmp1]
    RET

; --- update_fire: DATOS o DIRECCION pulsados (flanco 0->1, igual patron
; que pong.asm/serve_check) disparan un proyectil hacia [last_fire_dir] --
; SOLO una de las 4 cardinales (N/E/S/O), nunca diagonal, igual regla que
; los enemigos tiradores -- si hay un hueco libre en shot_active[MAX_SHOTS].
update_fire:
    MOV AL,#0
    STA [tmp3],AL            ; ¿algun boton con flanco nuevo este fotograma?

    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ uf_chk_dir
    CMP BL,#0
    JMPNZ uf_chk_dir         ; ya estaba pulsado -- no es un flanco nuevo
    MOV AL,#1
    STA [tmp3],AL

uf_chk_dir:
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ uf_check_go
    CMP BL,#0
    JMPNZ uf_check_go
    MOV AL,#1
    STA [tmp3],AL

uf_check_go:
    LDA AL,[tmp3]
    CMP AL,#0
    JMPZ uf_ret

    MOV AL,#0
    STA [e],AL
uf_find_l:
    LDA CL,[e]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uf_fire
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ uf_find_l
    JMP uf_ret              ; sin hueco libre -- no dispara

uf_fire:
    LDA CL,[e]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    MOV AL,#1
    STA [BX],AL

    LDA CL,[e]
    MOV BL,#lo(shot_x)
    MOV BH,#hi(shot_x)
    CALL idx_ptr
    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    STA [BX],AL

    LDA CL,[e]
    MOV BL,#lo(shot_y)
    MOV BH,#hi(shot_y)
    CALL idx_ptr
    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    STA [BX],AL

    ; velocidad del disparo: SOLO una de las 4 cardinales (nunca diagonal
    ; -- misma regla que los enemigos tiradores) segun [last_fire_dir]
    LDA AL,[last_fire_dir]
    CMP AL,#DIR_N
    JMPNZ uf_dir_e
    MOV AL,#0
    STA [tmp1],AL
    MOV AL,#(0-SHOT_SPEED)
    STA [tmp2],AL
    JMP uf_dir_done
uf_dir_e:
    CMP AL,#DIR_E
    JMPNZ uf_dir_s
    MOV AL,#SHOT_SPEED
    STA [tmp1],AL
    MOV AL,#0
    STA [tmp2],AL
    JMP uf_dir_done
uf_dir_s:
    CMP AL,#DIR_S
    JMPNZ uf_dir_w
    MOV AL,#0
    STA [tmp1],AL
    MOV AL,#SHOT_SPEED
    STA [tmp2],AL
    JMP uf_dir_done
uf_dir_w:
    MOV AL,#(0-SHOT_SPEED)
    STA [tmp1],AL
    MOV AL,#0
    STA [tmp2],AL
uf_dir_done:

    LDA CL,[e]
    MOV BL,#lo(shot_vx)
    MOV BH,#hi(shot_vx)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL

    LDA CL,[e]
    MOV BL,#lo(shot_vy)
    MOV BH,#hi(shot_vy)
    CALL idx_ptr
    LDA AL,[tmp2]
    STA [BX],AL

    ; P_SND_DUR antes que P_SND_NOTE: al reves, el disparo sonaria con la
    ; duracion que quedara armada de antes (p.ej. de la melodia del titulo)
    ; en vez de 4.
    MOV AL,#4
    OUT (P_SND_DUR),AL
    MOV AL,#88
    OUT (P_SND_NOTE),AL
uf_ret:
    RET

; --- update_shots: mueve cada disparo activo SHOT_SPEED px/eje; lo apaga
; si sale de pantalla o choca con una pared; si alcanza a un enemigo activo
; (mismo AABB que check_collisions), lo mata, puntua y toca el jingle.
update_shots:
    MOV AL,#0
    STA [e],AL
us_l:
    LDA CL,[e]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ us_next

    LDA CL,[e]
    MOV BL,#lo(shot_x)
    MOV BH,#hi(shot_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ex],AL
    LDA CL,[e]
    MOV BL,#lo(shot_y)
    MOV BH,#hi(shot_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ey],AL

    ; barre el recorrido px a px (paso unitario segun el signo de vx/vy) en
    ; vez de saltar los SHOT_SPEED(2) de un salto y probar solo el destino
    ; -- si no, el disparo puede saltar por encima de una pared o puerta de
    ; 1-2px sin llegar a tocarla nunca (mismo fallo que tenia player_fits).
    ; [ex]/[ey] ya valen shot_x/shot_y (la posicion ANTES de moverse).
    LDA CL,[e]
    MOV BL,#lo(shot_vx)
    MOV BH,#hi(shot_vx)
    CALL idx_ptr
    LDA AL,[BX]
    CALL sign_of
    STA [stepx],AL

    LDA CL,[e]
    MOV BL,#lo(shot_vy)
    MOV BH,#hi(shot_vy)
    CALL idx_ptr
    LDA AL,[BX]
    CALL sign_of
    STA [stepy],AL

    MOV AL,#0
    STA [k],AL
us_sweep_l:
    LDA AL,[ex]
    LDA BL,[stepx]
    ADD AL,BL
    STA [ex],AL
    LDA AL,[ey]
    LDA BL,[stepy]
    ADD AL,BL
    STA [ey],AL

    LDA AL,[ex]
    CMP AL,#124
    JMPNC us_kill
    LDA AL,[ey]
    CMP AL,#60
    JMPNC us_kill

    LDA AL,[ex]
    STA [px_x],AL
    LDA AL,[ey]
    STA [px_y],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ us_kill

    LDA AL,[k]
    ADD AL,#1
    STA [k],AL
    CMP AL,#SHOT_SPEED
    JMPNZ us_sweep_l

    LDA CL,[e]
    MOV BL,#lo(shot_x)
    MOV BH,#hi(shot_x)
    CALL idx_ptr
    LDA AL,[ex]
    STA [BX],AL
    LDA CL,[e]
    MOV BL,#lo(shot_y)
    MOV BH,#hi(shot_y)
    CALL idx_ptr
    LDA AL,[ey]
    STA [BX],AL

    MOV AL,#0
    STA [j],AL
us_enemy_l:
    LDA CL,[j]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ us_enemy_next

    LDA CL,[j]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    SUB AL,#ENEMY_HALF
    STA [tmp1],AL
    LDA CL,[j]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    SUB AL,#ENEMY_HALF
    STA [tmp2],AL

    LDA AL,[ex]
    LDA BL,[tmp1]
    CMP AL,BL
    JMPC us_enemy_next
    LDA AL,[tmp1]
    ADD AL,#ENEMY_W
    LDA BL,[ex]
    CMP BL,AL
    JMPNC us_enemy_next
    LDA AL,[ey]
    LDA BL,[tmp2]
    CMP AL,BL
    JMPC us_enemy_next
    LDA AL,[tmp2]
    ADD AL,#ENEMY_H
    LDA BL,[ey]
    CMP BL,AL
    JMPNC us_enemy_next

    ; overlap confirmado -- el JEFE aguanta BOSS_HP_MAX impactos en vez de
    ; morir del primero: si le queda vida, solo se apaga el disparo (pitido
    ; de impacto, sigue persiguiendo y disparando); al ultimo, pantalla de
    ; victoria en vez del jingle normal de siempre.
    LDA CL,[j]
    MOV BL,#lo(enemy_type)
    MOV BH,#hi(enemy_type)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#ENEMY_TYPE_BOSS
    JMPNZ us_normal_kill

    LDA AL,[boss_hp]
    SUB AL,#1
    STA [boss_hp],AL
    CMP AL,#0
    JMPZ us_boss_dead
    MOV AL,#3                 ; DUR antes que NOTE (ver el aviso en update_fire)
    OUT (P_SND_DUR),AL
    MOV AL,#48
    OUT (P_SND_NOTE),AL
    JMP us_kill

us_boss_dead:
    LDA CL,[j]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
    MOV AL,#100
    CALL score_add
    CALL update_score_hud
    CALL show_victory
    CALL new_game
    RET

us_normal_kill:
    LDA CL,[j]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL

    MOV AL,#25
    CALL score_add
    CALL update_score_hud
    MOV BL,#lo(JINGLE_TUNE)
    MOV BH,#hi(JINGLE_TUNE)
    CALL play_tune

    JMP us_kill
us_enemy_next:
    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ us_enemy_l
    JMP us_next

us_kill:
    LDA CL,[e]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL

us_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ us_l
    RET

; --- update_enemy_fire: como mucho un disparo enemigo a la vez (variables
; sueltas, no un array -- basta con eso). Cada enemigo tirador (enemy_type
; == 1) activo que este alineado con el jugador en su fila o columna de
; celda dispara en esa direccion cardinal, con un tiempo de espera entre
; disparos (enemy_shot_cooldown) para que no ametralle.
update_enemy_fire:
    LDA AL,[enemy_shot_cooldown]
    CMP AL,#0
    JMPZ uef_ready
    SUB AL,#1
    STA [enemy_shot_cooldown],AL
    RET
uef_ready:
    LDA AL,[enemy_shot_active]
    CMP AL,#0
    JMPNZ uef_ret

    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    STA [pcol],AL
    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    STA [prow],AL

    MOV AL,#0
    STA [e],AL
uef_l:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uef_next
    LDA CL,[e]
    MOV BL,#lo(enemy_type)
    MOV BH,#hi(enemy_type)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ uef_next

    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ex],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ey],AL

    LDA AL,[ex]
    CALL px_to_col
    STA [ecol],AL
    LDA AL,[ey]
    CALL px_to_row
    STA [erow],AL

    LDA AL,[ecol]
    LDA BL,[pcol]
    CMP AL,BL
    JMPZ uef_fire_col
    LDA AL,[erow]
    LDA BL,[prow]
    CMP AL,BL
    JMPNZ uef_next

    ; misma fila -- dispara horizontal
    LDA AL,[player_x]
    LDA BL,[ex]
    CMP AL,BL
    JMPC uef_h_left
    MOV AL,#1
    JMP uef_h_sign
uef_h_left:
    MOV AL,#0xFF
uef_h_sign:
    SHL AL,#1
    STA [tmp1],AL
    MOV AL,#0
    STA [tmp2],AL
    JMP uef_do_fire

uef_fire_col:
    ; misma columna -- dispara vertical
    LDA AL,[player_y]
    LDA BL,[ey]
    CMP AL,BL
    JMPC uef_v_up
    MOV AL,#1
    JMP uef_v_sign
uef_v_up:
    MOV AL,#0xFF
uef_v_sign:
    SHL AL,#1
    STA [tmp2],AL
    MOV AL,#0
    STA [tmp1],AL

uef_do_fire:
    MOV AL,#1
    STA [enemy_shot_active],AL
    LDA AL,[ex]
    STA [enemy_shot_x],AL
    LDA AL,[ey]
    STA [enemy_shot_y],AL
    LDA AL,[tmp1]
    STA [enemy_shot_vx],AL
    LDA AL,[tmp2]
    STA [enemy_shot_vy],AL
    MOV AL,#60
    STA [enemy_shot_cooldown],AL
    ; P_SND_DUR antes que P_SND_NOTE (ver la nota en update_fire)
    MOV AL,#4
    OUT (P_SND_DUR),AL
    MOV AL,#50
    OUT (P_SND_NOTE),AL
    RET

uef_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ uef_l
uef_ret:
    RET

; --- update_enemy_shots: mueve el disparo enemigo (si hay); lo apaga si
; sale de pantalla o choca con una pared; si alcanza al jugador, cuenta
; como golpe (on_player_hit) igual que tocar a un enemigo.
update_enemy_shots:
    LDA AL,[enemy_shot_active]
    CMP AL,#0
    JMPZ ues_ret

    ; barre px a px, igual razon y mismo patron que update_shots (ver su
    ; comentario) -- si no, un disparo enemigo tambien puede saltar por
    ; encima de una pared o puerta sin tocarla.
    LDA AL,[enemy_shot_x]
    STA [ex],AL
    LDA AL,[enemy_shot_y]
    STA [ey],AL

    LDA AL,[enemy_shot_vx]
    CALL sign_of
    STA [stepx],AL
    LDA AL,[enemy_shot_vy]
    CALL sign_of
    STA [stepy],AL

    MOV AL,#0
    STA [k],AL
ues_sweep_l:
    LDA AL,[ex]
    LDA BL,[stepx]
    ADD AL,BL
    STA [ex],AL
    LDA AL,[ey]
    LDA BL,[stepy]
    ADD AL,BL
    STA [ey],AL

    LDA AL,[ex]
    CMP AL,#124
    JMPNC ues_kill
    LDA AL,[ey]
    CMP AL,#60
    JMPNC ues_kill

    LDA AL,[ex]
    STA [px_x],AL
    LDA AL,[ey]
    STA [px_y],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ ues_kill

    LDA AL,[k]
    ADD AL,#1
    STA [k],AL
    CMP AL,#SHOT_SPEED
    JMPNZ ues_sweep_l

    LDA AL,[ex]
    STA [enemy_shot_x],AL
    LDA AL,[ey]
    STA [enemy_shot_y],AL

    LDA AL,[ex]
    LDA BL,[player_x]
    CMP AL,BL
    JMPC ues_ret
    LDA AL,[player_x]
    ADD AL,#PLAYER_W
    LDA BL,[ex]
    CMP BL,AL
    JMPNC ues_ret
    LDA AL,[ey]
    LDA BL,[player_y]
    CMP AL,BL
    JMPC ues_ret
    LDA AL,[player_y]
    ADD AL,#PLAYER_H
    LDA BL,[ey]
    CMP BL,AL
    JMPNC ues_ret

    MOV AL,#0
    STA [enemy_shot_active],AL
    CALL on_player_hit
    RET

ues_kill:
    MOV AL,#0
    STA [enemy_shot_active],AL
ues_ret:
    RET

; --- player_fits: entra [test_x],[test_y] (esquina superior izquierda) ;
; sale AL=0 si ninguna de las 4 esquinas de la caja PLAYER_W x PLAYER_H cae
; en una pared, distinto de 0 si alguna choca.
; --- player_fits: escanea TODA la caja del jugador (PLAYER_W x PLAYER_H),
; no solo sus 4 esquinas -- con esquinas nada mas, una pared/puerta de 1-2px
; de grosor puede caer en el interior de la caja sin tocar ninguna esquina
; exacta (el giro del encoder avanza hasta 3px de golpe, ver clamp_delta) y
; el jugador la atraviesa sin ser detectado. Esto se noto con las puertas
; con llave (un solo trazo, sin la redundancia del trazo doble de una pared
; normal) pero es el mismo riesgo para cualquier pared.
player_fits:
    MOV AL,#0
    STA [pfy],AL
pf_row:
    LDA AL,[test_y]
    LDA BL,[pfy]
    ADD AL,BL
    ; recorta a la ultima fila real (0-63): test_y puede pedirse por encima
    ; de eso a proposito (ver update_player, umbral de 64 a secas para el
    ; borde SUR) para no perderse una pared/puerta pegada ahi -- sin este
    ; recorte, una fila >=64 leeria memoria de otra fila de `walls`.
    CMP AL,#64
    JMPC pf_y_ok
    MOV AL,#63
pf_y_ok:
    STA [px_y],AL
    MOV AL,#0
    STA [pfx],AL
pf_col:
    LDA AL,[test_x]
    LDA BL,[pfx]
    ADD AL,BL
    ; mismo recorte para la columna (0-127), borde ESTE
    CMP AL,#128
    JMPC pf_x_ok
    MOV AL,#127
pf_x_ok:
    STA [px_x],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ pf_hit

    LDA AL,[pfx]
    ADD AL,#1
    STA [pfx],AL
    CMP AL,#PLAYER_W
    JMPNZ pf_col

    LDA AL,[pfy]
    ADD AL,#1
    STA [pfy],AL
    CMP AL,#PLAYER_H
    JMPNZ pf_row

    MOV AL,#0
    RET
pf_hit:
    MOV AL,#1
    RET

; --- check_key_pickup: si el jugador esta sobre la celda de la llave de
; esta sala (y no esta ya cogida -- si la sala no tiene puerta, [key_cell]
; vale 255 y nunca coincide con una celda real, asi que esto no hace nada),
; la coge.
check_key_pickup:
    LDA AL,[key_taken]
    CMP AL,#0
    JMPNZ ckp_ret

    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    STA [tmp1],AL
    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[tmp1]
    ADD AL,BL
    LDA BL,[key_cell]
    CMP AL,BL
    JMPNZ ckp_ret

    MOV AL,#1
    STA [key_taken],AL
    LDA AL,[keys_held]
    ADD AL,#1
    STA [keys_held],AL
    CALL update_keys_hud
    CALL save_room_state      ; si no, al salir y volver la llave reaparece
                               ; (restore_room_state recargaria key_taken=0)

    ; sonido de coger llave: Do4-Re5, el Re con el triple de duracion
    MOV AL,#60
    OUT (P_SND_NOTE),AL
    MOV AL,#4
    CALL frame_wait
    MOV AL,#74
    OUT (P_SND_NOTE),AL
    MOV AL,#12
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL
ckp_ret:
    RET

; --- check_heart_pickup: igual patron que check_key_pickup, pero para el
; corazon de repuesto (si esta sala tiene uno colocado por
; gen_and_save_current_room). Sube una vida (sin pasar de MAX_LIVES -- una
; sala restaurada puede conservar un corazon puesto cuando el jugador
; todavia tenia pocas vidas, y para cuando vuelve puede que ya no le haga
; falta) y suena un arpegio corto y alegre (Do4-Mi4-Sol4).
check_heart_pickup:
    LDA AL,[heart_taken]
    CMP AL,#0
    JMPNZ chp_ret
    LDA AL,[heart_cell]
    CMP AL,#255
    JMPZ chp_ret

    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    STA [tmp1],AL
    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    STA [tmp2],AL
    LDA CL,[tmp2]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[tmp1]
    ADD AL,BL
    LDA BL,[heart_cell]
    CMP AL,BL
    JMPNZ chp_ret

    MOV AL,#1
    STA [heart_taken],AL
    CALL save_room_state       ; que no reaparezca al salir y volver
    LDA AL,[lives]
    CMP AL,#MAX_LIVES
    JMPNC chp_sound
    ADD AL,#1
    STA [lives],AL
    CALL update_lives_hud
chp_sound:
    ; sonido: Do4-Mi4-Sol4 ascendente
    MOV AL,#60
    OUT (P_SND_NOTE),AL
    MOV AL,#4
    CALL frame_wait
    MOV AL,#64
    OUT (P_SND_NOTE),AL
    MOV AL,#4
    CALL frame_wait
    MOV AL,#67
    OUT (P_SND_NOTE),AL
    MOV AL,#8
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL
chp_ret:
    RET

; --- door_check: si esta sala tiene puerta ([door_dir]!=255), ya se tiene
; la llave y todavia no esta abierta, y el jugador esta cerca de su punto
; medio (distancia Manhattan <=10 px), la abre: fuerza el bit en
; cell_walls (basta con eso -- el otro lado esta en una sala que ni
; siquiera existe todavia, se generara su propio hueco de entrada la
; primera vez que se cruce), redibuja `walls` y persiste el cambio.
door_check:
    LDA AL,[door_dir]
    CMP AL,#255
    JMPZ dc_ret
    ; llavero compartido: CUALQUIER llave abre CUALQUIER puerta -- basta con
    ; llevar al menos una encima ([keys_held], el mismo contador del
    ; marcador). No hay forma de distinguir visualmente una llave de otra en
    ; el HUD (solo un icono + una cifra), así que exigir la llave EXACTA de
    ; cada puerta (como antes) resultaba confuso: se podía llevar una llave
    ; encima y aun así no poder abrir la puerta que se tenía delante, porque
    ; era la de otra puerta en otra parte del laberinto. Lo que SIGUE en pie
    ; es que la llave de esta puerta nunca esta en esta misma sala (ver
    ; gen_and_save_current_room) -- eso es justo lo que se pidio conservar.
    LDA AL,[keys_held]
    CMP AL,#0
    JMPZ dc_ret

    LDA CL,[door_dir]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[door_cell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[tmp1]
    AND AL,BL
    CMP AL,#0
    JMPNZ dc_ret            ; bit ya puesto -> ya estaba abierta

    LDA CL,[door_cell]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    STA [drow],AL
    LDA CL,[door_cell]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    STA [dcol],AL
    LDA AL,[drow]
    CALL row_to_px
    STA [tmp1],AL           ; fila*CELL_H
    LDA AL,[dcol]
    CALL col_to_px
    STA [tmp2],AL           ; columna*CELL_W

    LDA AL,[door_dir]
    CMP AL,#DIR_N
    JMPNZ dc_e
    LDA AL,[tmp2]
    ADD AL,#(CELL_W/2)
    STA [dx_pt],AL
    LDA AL,[tmp1]
    STA [dy_pt],AL
    JMP dc_dist
dc_e:
    CMP AL,#DIR_E
    JMPNZ dc_s
    LDA AL,[tmp2]
    ADD AL,#CELL_W
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#(CELL_H/2)
    STA [dy_pt],AL
    JMP dc_dist
dc_s:
    CMP AL,#DIR_S
    JMPNZ dc_w
    LDA AL,[tmp2]
    ADD AL,#(CELL_W/2)
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#CELL_H
    STA [dy_pt],AL
    JMP dc_dist
dc_w:
    LDA AL,[tmp2]
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#(CELL_H/2)
    STA [dy_pt],AL

dc_dist:
    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    LDA BL,[dx_pt]
    SUB AL,BL
    JMPN dc_xneg
    JMP dc_xdone
dc_xneg:
    NOT AL
    ADD AL,#1
dc_xdone:
    STA [tmp1],AL

    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    LDA BL,[dy_pt]
    SUB AL,BL
    JMPN dc_yneg
    JMP dc_ydone
dc_yneg:
    NOT AL
    ADD AL,#1
dc_ydone:
    LDA BL,[tmp1]
    ADD AL,BL
    CMP AL,#DOOR_OPEN_DIST
    JMPNC dc_ret            ; demasiado lejos todavia

    LDA CL,[door_dir]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[door_cell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    LDA DL,[tmp1]
    OR  AL,DL
    STA [BX],AL

    ; la llave se gasta al abrir la puerta: desaparece del contador del
    ; marcador
    LDA AL,[keys_held]
    CMP AL,#0
    JMPZ dc_no_dec
    SUB AL,#1
    STA [keys_held],AL
    CALL update_keys_hud
dc_no_dec:

    CALL draw_maze
    CALL save_room_state
dc_ret:
    RET

; --- near_door: sale AL=1 si esta sala tiene puerta (door_dir!=255) y el
; jugador esta a DOOR_SAFE_DIST o menos de su punto medio -- para que
; acercarse a abrirla (con o sin llave todavia) no cuente como "tocar una
; pared" y mate (ver update_player); si no, AL=0 (pared normal, mortal).
near_door:
    LDA AL,[door_dir]
    CMP AL,#255
    JMPZ nd_no

    LDA CL,[door_cell]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    STA [drow],AL
    LDA CL,[door_cell]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    STA [dcol],AL
    LDA AL,[drow]
    CALL row_to_px
    STA [tmp1],AL
    LDA AL,[dcol]
    CALL col_to_px
    STA [tmp2],AL

    LDA AL,[door_dir]
    CMP AL,#DIR_N
    JMPNZ nd_e
    LDA AL,[tmp2]
    ADD AL,#(CELL_W/2)
    STA [dx_pt],AL
    LDA AL,[tmp1]
    STA [dy_pt],AL
    JMP nd_dist
nd_e:
    CMP AL,#DIR_E
    JMPNZ nd_s
    LDA AL,[tmp2]
    ADD AL,#CELL_W
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#(CELL_H/2)
    STA [dy_pt],AL
    JMP nd_dist
nd_s:
    CMP AL,#DIR_S
    JMPNZ nd_w
    LDA AL,[tmp2]
    ADD AL,#(CELL_W/2)
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#CELL_H
    STA [dy_pt],AL
    JMP nd_dist
nd_w:
    LDA AL,[tmp2]
    STA [dx_pt],AL
    LDA AL,[tmp1]
    ADD AL,#(CELL_H/2)
    STA [dy_pt],AL

nd_dist:
    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    LDA BL,[dx_pt]
    SUB AL,BL
    JMPN nd_xneg
    JMP nd_xdone
nd_xneg:
    NOT AL
    ADD AL,#1
nd_xdone:
    STA [tmp1],AL

    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    LDA BL,[dy_pt]
    SUB AL,BL
    JMPN nd_yneg
    JMP nd_ydone
nd_yneg:
    NOT AL
    ADD AL,#1
nd_ydone:
    LDA BL,[tmp1]
    ADD AL,BL
    CMP AL,#DOOR_SAFE_DIST
    JMPNC nd_no

    MOV AL,#1
    RET
nd_no:
    MOV AL,#0
    RET

; --- play_zap: "ZAP" corto y aspero (barrido descendente de notas) para
; cuando tocar una pared mata al jugador, asi se nota claramente que ha
; pasado algo -- bloqueante, coincide con el parpadeo de LED que hace
; on_player_hit justo despues.
play_zap:
    MOV AL,#96
    OUT (P_SND_NOTE),AL
    MOV AL,#2
    CALL frame_wait
    MOV AL,#84
    OUT (P_SND_NOTE),AL
    MOV AL,#2
    CALL frame_wait
    MOV AL,#72
    OUT (P_SND_NOTE),AL
    MOV AL,#2
    CALL frame_wait
    MOV AL,#55
    OUT (P_SND_NOTE),AL
    MOV AL,#3
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    RET

; ============================================================================
;  ENEMIGOS
; ============================================================================

; --- setup_enemies: activa (y coloca en una esquina) tantos enemigos como
; toquen segun [room_num]; el resto se desactivan. La velocidad ([move_delay]
; = fotogramas por paso) baja 1 por sala hasta MIN_DELAY.
setup_enemies:
    LDA AL,[room_num]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ se_not_boss
    ; sala del jefe: UN unico enemigo (slot 0), nada de la cuenta/tipo
    ; normal -- se_type_store mas abajo lo convierte en ENEMY_TYPE_BOSS
    ; en cuanto ve que esta en esta sala
    MOV AL,#1
    STA [enemy_count],AL
    MOV AL,#BOSS_HP_MAX
    STA [boss_hp],AL
    JMP se_speed
se_not_boss:
    CMP AL,#FIRST_ENEMY_ROOM
    JMPNC se_have
    MOV AL,#0
    STA [enemy_count],AL
    JMP se_speed
se_have:
    SUB AL,#(FIRST_ENEMY_ROOM-1)
    CMP AL,#MAX_ENEMIES
    JMPC se_cnt_ok
    MOV AL,#MAX_ENEMIES
se_cnt_ok:
    STA [enemy_count],AL

se_speed:
    ; move_delay = max(START_DELAY - room_num, MIN_DELAY) -- OJO: para
    ; room_num >= START_DELAY (la mayoria de las salas: START_DELAY=7 de
    ; MAX_ROOMS=50) "START_DELAY - room_num" es negativo, y como AL es un
    ; byte sin signo eso ENVUELVE a un numero grande (p.ej. room_num=8 ->
    ; 255) en vez de dar un valor pequeno -- el CMP de abajo lo veia como
    ; "ya es mayor que MIN_DELAY" y lo dejaba pasar SIN acotar, dejando
    ; [move_delay] en 200+ fotogramas por paso (varios segundos por cada
    ; paso de TODOS los enemigos de la sala a la vez, ya que move_delay/
    ; move_counter son globales, no por enemigo). Bug real: "no se mueve
    ; ningun enemigo" en la mayoria de las salas de una partida (todas las
    ; que pasan de la sala 7). Por eso primero se comprueba el underflow
    ; ANTES de restar, en vez de fiarse del resultado ya envuelto.
    LDA AL,[room_num]
    CMP AL,#START_DELAY
    JMPNC se_delay_floor
    MOV AL,#START_DELAY
    LDA BL,[room_num]
    SUB AL,BL
    CMP AL,#MIN_DELAY
    JMPNC se_delay_ok
se_delay_floor:
    MOV AL,#MIN_DELAY
se_delay_ok:
    STA [move_delay],AL
    MOV AL,#0
    STA [enemy_shot_active],AL
    STA [enemy_shot_cooldown],AL
    MOV AL,#0
    STA [move_counter],AL

    MOV AL,#0
    STA [e],AL
se_l:
    LDA AL,[e]
    LDA BL,[enemy_count]
    CMP AL,BL
    JMPNC se_inactive

    ; celda candidata (esquina fija de ENEMY_SPAWN_ROW/COL) -- si cae a
    ; menos de MIN_ENEMY_SPAWN_DIST (Manhattan) del punto donde va a
    ; aparecer el jugador, se usa la celda simetrica opuesta en su lugar
    ; (mismo laberinto, la esquina contraria) en vez de dejar que un enemigo
    ; salga pegado a la entrada -- sin esto, entrar por el lado ESTE u OESTE
    ; podia aparecer a menos de 20px de un enemigo ya puesto ahi, matando al
    ; jugador casi al instante, y otra vez igual al respawnear en la misma
    ; entrada (ver on_player_hit).
    LDA CL,[e]
    MOV BL,#lo(ENEMY_SPAWN_ROW)
    MOV BH,#hi(ENEMY_SPAWN_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    STA [erow],AL
    LDA CL,[e]
    MOV BL,#lo(ENEMY_SPAWN_COL)
    MOV BH,#hi(ENEMY_SPAWN_COL)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ecol],AL

    LDA AL,[erow]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    STA [tmp1],AL           ; y candidata
    LDA AL,[ecol]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    STA [tmp2],AL           ; x candidata

    LDA AL,[tmp2]
    LDA BL,[player_x]
    SUB AL,BL
    JMPN se_xneg
    JMP se_xdone
se_xneg:
    NOT AL
    ADD AL,#1
se_xdone:
    STA [tmp3],AL
    LDA AL,[tmp1]
    LDA BL,[player_y]
    SUB AL,BL
    JMPN se_yneg
    JMP se_ydone
se_yneg:
    NOT AL
    ADD AL,#1
se_ydone:
    LDA BL,[tmp3]
    ADD AL,BL
    CMP AL,#MIN_ENEMY_SPAWN_DIST
    JMPNC se_pos_ok         ; ya suficientemente lejos del jugador

    MOV AL,#(MAZE_ROWS-1)
    LDA BL,[erow]
    SUB AL,BL
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    STA [tmp1],AL
    MOV AL,#(MAZE_COLS-1)
    LDA BL,[ecol]
    SUB AL,BL
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    STA [tmp2],AL
se_pos_ok:
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[tmp2]
    STA [BX],AL

    LDA CL,[e]
    MOV BL,#lo(enemy_dir)
    MOV BH,#hi(enemy_dir)
    CALL idx_ptr
    MOV AL,#DIR_N
    STA [BX],AL

    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    MOV AL,#1
    STA [BX],AL

    ; tipo: a partir de la SEGUNDA sala con enemigos, 1 de cada 4 nace
    ; tirador; en la primera son todos persegidores, para una entrada mas
    ; suave (ver update_enemy_fire para el comportamiento del tirador)
    LDA CL,[e]
    MOV BL,#lo(enemy_type)
    MOV BH,#hi(enemy_type)
    CALL idx_ptr
    LDA AL,[room_num]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ se_type_normal
    MOV AL,#ENEMY_TYPE_BOSS
    JMP se_type_store
se_type_normal:
    CMP AL,#(FIRST_ENEMY_ROOM+1)
    JMPC se_type_chaser
    CALL rnd
    AND AL,#3
    CMP AL,#0
    JMPNZ se_type_chaser
    MOV AL,#1
    JMP se_type_store
se_type_chaser:
    MOV AL,#0
se_type_store:
    STA [BX],AL
    JMP se_next
se_inactive:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    MOV AL,#0
    STA [BX],AL
se_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ se_l
    RET

; --- update_enemies: cada [move_delay] fotogramas, adelanta 1 px a cada
; enemigo activo en su direccion actual (step_enemy decide una nueva
; direccion si acaba de llegar al centro de una celda).
update_enemies:
    LDA AL,[move_counter]
    ADD AL,#1
    STA [move_counter],AL
    LDA BL,[move_delay]
    CMP AL,BL
    JMPC ue_done
    MOV AL,#0
    STA [move_counter],AL

    MOV AL,#0
    STA [e],AL
ue_l:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ ue_next
    CALL step_enemy
ue_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ ue_l
ue_done:
    RET

; --- step_enemy: entra [e]. Si esta centrado en una celda, decide direccion
; nueva (choose_enemy_dir); luego avanza 1 px en enemy_dir[e].
step_enemy:
    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ex],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ey],AL

    ; ¿esta exactamente en el centro de su celda? -- 21 no es potencia de 2,
    ; asi que no vale una mascara de bits: se recalcula el centro de SU
    ; columna/fila (col_to_px[px_to_col[ex]]+mitad) y se compara con la
    ; posicion real
    LDA AL,[ex]
    CALL px_to_col
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    LDA BL,[ex]
    CMP AL,BL
    JMPNZ se_step_move
    LDA AL,[ey]
    CALL px_to_row
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    LDA BL,[ey]
    CMP AL,BL
    JMPNZ se_step_move
    CALL choose_enemy_dir

se_step_move:
    LDA CL,[e]
    MOV BL,#lo(enemy_dir)
    MOV BH,#hi(enemy_dir)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#DIR_N
    JMPNZ sm_e
    LDA AL,[ey]
    SUB AL,#1
    STA [ey],AL
    JMP sm_store
sm_e:
    CMP AL,#DIR_E
    JMPNZ sm_s
    LDA AL,[ex]
    ADD AL,#1
    STA [ex],AL
    JMP sm_store
sm_s:
    CMP AL,#DIR_S
    JMPNZ sm_w
    LDA AL,[ey]
    ADD AL,#1
    STA [ey],AL
    JMP sm_store
sm_w:
    LDA AL,[ex]
    SUB AL,#1
    STA [ex],AL
sm_store:
    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[ex]
    STA [BX],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[ey]
    STA [BX],AL
    RET

; --- choose_enemy_dir: entra [e],[ex],[ey] (centro, YA alineado a celda).
; Elige, de las direcciones ABIERTAS de esa celda, la que mas acerque a la
; celda del jugador (distancia Manhattan); evita dar media vuelta salvo que
; sea la unica salida.
choose_enemy_dir:
    LDA AL,[ex]
    CALL px_to_col
    STA [ecol],AL
    LDA AL,[ey]
    CALL px_to_row
    STA [erow],AL
    LDA CL,[erow]
    MOV BL,#lo(ROW_MUL)
    MOV BH,#hi(ROW_MUL)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ecol]
    ADD AL,BL
    STA [ecell],AL

    LDA AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    STA [pcol],AL
    LDA AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    STA [prow],AL

    LDA CL,[ecell]
    MOV BL,#lo(cell_walls)
    MOV BH,#hi(cell_walls)
    CALL idx_ptr
    LDA AL,[BX]
    STA [cwv],AL

    LDA CL,[e]
    MOV BL,#lo(enemy_dir)
    MOV BH,#hi(enemy_dir)
    CALL idx_ptr
    LDA CL,[BX]
    MOV BL,#lo(OPP_OF_DIR)
    MOV BH,#hi(OPP_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    STA [banned_dir],AL

    MOV AL,#255
    STA [best_dist],AL
    STA [best_dir],AL
    MOV AL,#0
    STA [d],AL
ced_l1:
    LDA CL,[d]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cwv]
    AND BL,AL
    CMP BL,#0
    JMPZ ced_next1
    LDA AL,[d]
    LDA BL,[banned_dir]
    CMP AL,BL
    JMPZ ced_next1
    CALL ced_consider
ced_next1:
    LDA AL,[d]
    ADD AL,#1
    STA [d],AL
    CMP AL,#4
    JMPNZ ced_l1

    LDA AL,[best_dir]
    CMP AL,#255
    JMPNZ ced_store

    MOV AL,#0
    STA [d],AL
ced_l2:
    LDA CL,[d]
    MOV BL,#lo(BIT_OF_DIR)
    MOV BH,#hi(BIT_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[cwv]
    AND BL,AL
    CMP BL,#0
    JMPZ ced_next2
    CALL ced_consider
ced_next2:
    LDA AL,[d]
    ADD AL,#1
    STA [d],AL
    CMP AL,#4
    JMPNZ ced_l2

ced_store:
    LDA CL,[e]
    MOV BL,#lo(enemy_dir)
    MOV BH,#hi(enemy_dir)
    CALL idx_ptr
    LDA AL,[best_dir]
    STA [BX],AL
    RET

; --- ced_consider: para la direccion [d] (ya sabida abierta), mira su celda
; vecina (a partir de erow/ecol) y, si su distancia Manhattan a (prow,pcol)
; mejora [best_dist], actualiza [best_dist]/[best_dir].
ced_consider:
    LDA CL,[d]
    MOV BL,#lo(DR_OF_DIR)
    MOV BH,#hi(DR_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[erow]
    ADD AL,BL
    STA [trow],AL

    LDA CL,[d]
    MOV BL,#lo(DC_OF_DIR)
    MOV BH,#hi(DC_OF_DIR)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ecol]
    ADD AL,BL
    STA [tcol],AL

    LDA AL,[trow]
    LDA BL,[prow]
    SUB AL,BL
    JMPN cc_rowneg
    JMP cc_rowdone
cc_rowneg:
    NOT AL
    ADD AL,#1
cc_rowdone:
    STA [dist],AL

    LDA AL,[tcol]
    LDA BL,[pcol]
    SUB AL,BL
    JMPN cc_colneg
    JMP cc_coldone
cc_colneg:
    NOT AL
    ADD AL,#1
cc_coldone:
    LDA BL,[dist]
    ADD AL,BL
    STA [dist],AL

    LDA AL,[dist]
    LDA BL,[best_dist]
    CMP AL,BL
    JMPNC ccd_no
    STA [best_dist],AL
    LDA AL,[d]
    STA [best_dir],AL
ccd_no:
    RET

; ============================================================================
;  check_collisions: jugador contra cada enemigo activo (cajas PLAYER_W x
;  PLAYER_H y ENEMY_W x ENEMY_H, la del enemigo centrada en (ex,ey)).
; ============================================================================
check_collisions:
    MOV AL,#0
    STA [e],AL
cc_l:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ cc_next

    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    SUB AL,#ENEMY_HALF
    STA [ex],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    SUB AL,#ENEMY_HALF
    STA [ey],AL

    LDA AL,[ex]
    ADD AL,#ENEMY_W
    LDA BL,[player_x]
    CMP BL,AL
    JMPNC cc_next
    LDA AL,[player_x]
    ADD AL,#PLAYER_W
    LDA BL,[ex]
    CMP BL,AL
    JMPNC cc_next
    LDA AL,[ey]
    ADD AL,#ENEMY_H
    LDA BL,[player_y]
    CMP BL,AL
    JMPNC cc_next
    LDA AL,[player_y]
    ADD AL,#PLAYER_H
    LDA BL,[ey]
    CMP BL,AL
    JMPNC cc_next

    CALL on_player_hit
    RET                     ; una colision basta este fotograma
cc_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ cc_l
    RET

; --- on_player_hit: pierde una vida, parpadea el LED, y si quedan vidas
; vuelve a colocar al jugador en la entrada de la sala actual; si no,
; pantalla de fin de partida y reinicio.
on_player_hit:
    MOV AL,#1
    OUT (P_LED),AL
    MOV AL,#6
    CALL frame_wait
    MOV AL,#0
    OUT (P_LED),AL

    LDA AL,[lives]
    SUB AL,#1
    STA [lives],AL          ; el icono se redibuja solo cada fotograma en
    CALL update_lives_hud   ; draw_frame, pero el NUMERO (texto) hay que
    LDA AL,[lives]          ; actualizarlo aparte, igual que la puntuacion
    CMP AL,#0
    JMPNZ oph_respawn
    CALL show_game_over
    CALL new_game
    RET
oph_respawn:
    CALL place_player_spawn
    CALL enforce_enemy_safe_dist
    RET

; --- enforce_enemy_safe_dist: para cada enemigo activo a menos de
; MIN_ENEMY_SPAWN_DIST (Manhattan) del jugador, lo refleja al punto opuesto
; del laberinto (espejado por su centro). Se llama justo despues de
; place_player_spawn al respawnear (ver oph_respawn) -- si no, un enemigo
; que ya estaba pegado a la entrada cuando mato al jugador seguia ahi
; mismo al reaparecer este, matandolo otra vez casi seguro. setup_enemies
; ya evita esto en la posicion INICIAL (ver su comentario); esto cubre la
; misma regla para cuando ya llevan un rato movidos por la sala.
enforce_enemy_safe_dist:
    MOV AL,#0
    STA [e],AL
eesd_l:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ eesd_next

    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp2],AL

    LDA AL,[tmp1]
    LDA BL,[player_x]
    SUB AL,BL
    JMPN eesd_xneg
    JMP eesd_xdone
eesd_xneg:
    NOT AL
    ADD AL,#1
eesd_xdone:
    STA [tmp3],AL
    LDA AL,[tmp2]
    LDA BL,[player_y]
    SUB AL,BL
    JMPN eesd_yneg
    JMP eesd_ydone
eesd_yneg:
    NOT AL
    ADD AL,#1
eesd_ydone:
    LDA BL,[tmp3]
    ADD AL,BL
    CMP AL,#MIN_ENEMY_SPAWN_DIST
    JMPNC eesd_next          ; ya bastante lejos

    ; espeja por INDICE de columna/fila (igual que setup_enemies mas abajo),
    ; no por aritmetica de pixeles: (MAZE_COLS*CELL_W)-x cae 1 px fuera del
    ; centro real de la baldosa espejada (los centros son col*CELL_W+CELL_W/2,
    ; no multiplos exactos de CELL_W), y ese enemigo nunca vuelve a quedar
    ; "centrado" para step_enemy -- se queda caminando en linea recta para
    ; siempre en la ultima direccion que tuviera, atravesando paredes, que es
    ; lo que se veia como "el enemigo se para/se pierde"
    LDA AL,[tmp1]
    CALL px_to_col
    MOV BL,AL
    MOV AL,#(MAZE_COLS-1)
    SUB AL,BL
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    STA [tmp1],AL

    LDA AL,[tmp2]
    CALL px_to_row
    MOV BL,AL
    MOV AL,#(MAZE_ROWS-1)
    SUB AL,BL
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    STA [tmp2],AL

    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[tmp1]
    STA [BX],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[tmp2]
    STA [BX],AL

eesd_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ eesd_l
    RET

; ============================================================================
;  DIBUJO DEL FOTOGRAMA: `walls` -> `shadow`, jugador y enemigos encima
; ============================================================================
draw_frame:
    CALL copy_walls_to_shadow
    MOV AL,#0
    STA [i],AL
df_pl_l:
    LDA CL,[i]
    MOV BL,#lo(PLAYER_SPRITE_DX)
    MOV BH,#hi(PLAYER_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[player_x]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[i]
    MOV BL,#lo(PLAYER_SPRITE_DY)
    MOV BH,#hi(PLAYER_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]

    ; pie izquierdo (indice 10) o derecho (11) de PLAYER_SPRITE_DX/DY: sube
    ; 1px si le toca levantarse en esta fase de la animacion de andar (ver
    ; update_player) -- el otro pie, y el resto del cuerpo, se quedan tal
    ; cual dice la tabla.
    LDA CL,[i]
    CMP CL,#10
    JMPNZ dfp_foot_r
    LDA CL,[walk_phase]
    CMP CL,#1
    JMPNZ dfp_dy_done
    SUB AL,#1
    JMP dfp_dy_done
dfp_foot_r:
    CMP CL,#11
    JMPNZ dfp_dy_done
    LDA CL,[walk_phase]
    CMP CL,#2
    JMPNZ dfp_dy_done
    SUB AL,#1
dfp_dy_done:
    LDA BL,[player_y]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#PLAYER_SPRITE_N
    JMPNZ df_pl_l

    ; disparos del jugador: un solo pixel basta (son pequeños y rapidos)
    MOV AL,#0
    STA [e],AL
df_shot_l:
    LDA CL,[e]
    MOV BL,#lo(shot_active)
    MOV BH,#hi(shot_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ df_shot_next

    LDA CL,[e]
    MOV BL,#lo(shot_x)
    MOV BH,#hi(shot_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [px_x],AL
    LDA CL,[e]
    MOV BL,#lo(shot_y)
    MOV BH,#hi(shot_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [px_y],AL
    CALL shadow_set_px
df_shot_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ df_shot_l

    ; disparo enemigo (uno solo, tambien un pixel)
    LDA AL,[enemy_shot_active]
    CMP AL,#0
    JMPZ df_no_eshot
    LDA AL,[enemy_shot_x]
    STA [px_x],AL
    LDA AL,[enemy_shot_y]
    STA [px_y],AL
    CALL shadow_set_px
df_no_eshot:

    MOV AL,#0
    STA [e],AL
df_en_l:
    LDA CL,[e]
    MOV BL,#lo(enemy_active)
    MOV BH,#hi(enemy_active)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#0
    JMPZ df_en_next

    LDA CL,[e]
    MOV BL,#lo(enemy_x)
    MOV BH,#hi(enemy_x)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ex],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_y)
    MOV BH,#hi(enemy_y)
    CALL idx_ptr
    LDA AL,[BX]
    STA [ey],AL

    MOV AL,#0
    STA [j],AL
    LDA CL,[e]
    MOV BL,#lo(enemy_type)
    MOV BH,#hi(enemy_type)
    CALL idx_ptr
    LDA AL,[BX]
    CMP AL,#ENEMY_TYPE_BOSS
    JMPZ df_boss_es_l
df_es_l:
    LDA CL,[j]
    MOV BL,#lo(ENEMY_SPRITE_DX)
    MOV BH,#hi(ENEMY_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(ENEMY_SPRITE_DY)
    MOV BH,#hi(ENEMY_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#ENEMY_SPRITE_N
    JMPNZ df_es_l
    JMP df_en_next

; --- jefe: mismo bucle, pero con BOSS_SPRITE_* (ver su comentario) --------
df_boss_es_l:
    LDA CL,[j]
    MOV BL,#lo(BOSS_SPRITE_DX)
    MOV BH,#hi(BOSS_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(BOSS_SPRITE_DY)
    MOV BH,#hi(BOSS_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#BOSS_SPRITE_N
    JMPNZ df_boss_es_l

df_en_next:
    LDA AL,[e]
    ADD AL,#1
    STA [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ df_en_l

    ; llave (si esta sala GUARDA una -- puede que ni siquiera tenga puerta
    ; propia, si la llave es para la puerta de un hijo suyo -- y todavia no
    ; se ha cogido). Antes se miraba [door_dir] aqui, pero eso ya no vale:
    ; la llave puede vivir en una sala que no tiene puerta propia.
    LDA AL,[key_cell]
    CMP AL,#255
    JMPZ df_no_key
    LDA AL,[key_taken]
    CMP AL,#0
    JMPNZ df_no_key

    LDA CL,[key_cell]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    STA [ey],AL              ; centro Y de la celda de la llave
    LDA CL,[key_cell]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    STA [ex],AL              ; centro X

    MOV AL,#0
    STA [j],AL
df_key_l:
    LDA CL,[j]
    MOV BL,#lo(KEY_SPRITE_DX)
    MOV BH,#hi(KEY_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(KEY_SPRITE_DY)
    MOV BH,#hi(KEY_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#KEY_SPRITE_N
    JMPNZ df_key_l
df_no_key:

    ; corazon de repuesto en el suelo (si esta sala tiene uno y todavia no
    ; se ha cogido) -- mismo patron que la llave, reutilizando el sprite del
    ; marcador (HEART_SPRITE_DX/DY es top-left, no centrado, asi que se resta
    ; medio sprite para centrarlo en la celda)
    LDA AL,[heart_cell]
    CMP AL,#255
    JMPZ df_no_heart
    LDA AL,[heart_taken]
    CMP AL,#0
    JMPNZ df_no_heart

    LDA CL,[heart_cell]
    MOV BL,#lo(CELL_TO_ROW)
    MOV BH,#hi(CELL_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    SUB AL,#2
    STA [ey],AL              ; esquina superior izq. del corazon (5x5)
    LDA CL,[heart_cell]
    MOV BL,#lo(CELL_TO_COL)
    MOV BH,#hi(CELL_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    SUB AL,#2
    STA [ex],AL

    MOV AL,#0
    STA [j],AL
df_heart_floor_l:
    LDA CL,[j]
    MOV BL,#lo(HEART_SPRITE_DX)
    MOV BH,#hi(HEART_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(HEART_SPRITE_DY)
    MOV BH,#hi(HEART_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#HEART_SPRITE_N
    JMPNZ df_heart_floor_l
df_no_heart:

    ; marcador de esquina superior derecha: un corazon + numero de vidas,
    ; luego una llave + numero de llaves cogidas en total -- los NUMEROS
    ; (texto) se actualizan aparte, solo cuando cambian, con
    ; update_lives_hud/update_keys_hud (igual que la puntuacion); los
    ; ICONOS (capa grafica) se redibujan solos cada fotograma aqui. Primero
    ; un recuadro negro solido debajo de los dos (por si una pared de la
    ; sala pasara justo por esa zona).
    MOV AL,#0
    STA [wk],AL
df_hud_clr_row:
    MOV AL,#0
    STA [k],AL
df_hud_clr_col:
    MOV AL,#HEART_AREA_X0
    LDA BL,[k]
    ADD AL,BL
    STA [px_x],AL
    MOV AL,#HEART_AREA_Y0
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_clear_px

    LDA AL,[k]
    ADD AL,#1
    STA [k],AL
    CMP AL,#HEART_AREA_W
    JMPNZ df_hud_clr_col

    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#HEART_AREA_H
    JMPNZ df_hud_clr_row

    ; icono de corazon (uno solo, tamaño fijo -- el numero de al lado dice
    ; cuantas vidas quedan)
    MOV AL,#HEART_ICON_X
    STA [ex],AL
    MOV AL,#HEART_ICON_Y
    STA [ey],AL
    MOV AL,#0
    STA [j],AL
df_heart_pt:
    LDA CL,[j]
    MOV BL,#lo(HEART_SPRITE_DX)
    MOV BH,#hi(HEART_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(HEART_SPRITE_DY)
    MOV BH,#hi(HEART_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#HEART_SPRITE_N
    JMPNZ df_heart_pt

    ; icono de llave (siempre visible, es solo el contador -- no depende
    ; de si esta sala tiene llave o no)
    MOV AL,#KEY_ICON_CX
    STA [ex],AL
    MOV AL,#KEY_ICON_CY
    STA [ey],AL
    MOV AL,#0
    STA [j],AL
df_hudkey_pt:
    LDA CL,[j]
    MOV BL,#lo(KEY_SPRITE_DX)
    MOV BH,#hi(KEY_SPRITE_DX)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ex]
    ADD AL,BL
    STA [px_x],AL

    LDA CL,[j]
    MOV BL,#lo(KEY_SPRITE_DY)
    MOV BH,#hi(KEY_SPRITE_DY)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[ey]
    ADD AL,BL
    STA [px_y],AL
    CALL shadow_set_px

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    CMP AL,#KEY_SPRITE_N
    JMPNZ df_hudkey_pt

    CALL blit
    RET

; ============================================================================
;  HUD: puntuacion (arriba-izquierda) y vidas (arriba-derecha), en texto
; ============================================================================

; --- score_add: suma AL (0..255) a la puntuacion de 16 bits (score_lo/hi),
; propagando el acarreo. Sin esto (un solo byte, como estaba antes) el
; marcador desbordaba en silencio y "se quedaba pequeño": los enemigos se
; regeneran sin limite cada vez que se reentra a una sala (persistida o no),
; asi que no hay techo real de puntos posibles en una partida larga.
score_add:
    LDA BL,[score_lo]
    ADD BL,AL
    STA [score_lo],BL
    JMPNC sca_done
    LDA AL,[score_hi]
    ADD AL,#1
    STA [score_hi],AL
sca_done:
    RET

; --- update_score_hud: puntuacion de 16 bits (0..65535) en 5 cifras,
; columnas 0-4 de la fila 0 (antes 3 cifras para un solo byte -- de sobra
; hueco libre hasta la columna 17 del corazon, ver LIVES_DIGIT_COL).
update_score_hud:
    LDA AL,[score_lo]
    STA [nd_val_lo],AL
    LDA AL,[score_hi]
    STA [nd_val_hi],AL

    MOV AL,#lo(10000)
    STA [nd_place_lo],AL
    MOV AL,#hi(10000)
    STA [nd_place_hi],AL
    CALL nd16_digit
    STA [dig10000],AL

    MOV AL,#lo(1000)
    STA [nd_place_lo],AL
    MOV AL,#hi(1000)
    STA [nd_place_hi],AL
    CALL nd16_digit
    STA [dig1000],AL

    MOV AL,#100
    STA [nd_place_lo],AL
    MOV AL,#0
    STA [nd_place_hi],AL
    CALL nd16_digit
    STA [dig100],AL

    MOV AL,#10
    STA [nd_place_lo],AL
    MOV AL,#0
    STA [nd_place_hi],AL
    CALL nd16_digit
    STA [dig10],AL

    LDA AL,[nd_val_lo]      ; lo que queda ya es 0..9 (nd_val_hi ya es 0)
    STA [dig1],AL

    MOV DH,#0x04
    LDA AL,[dig10000]
    ADD AL,#0x30
    MOV DL,#0
    OUT (DX),AL
    LDA AL,[dig1000]
    ADD AL,#0x30
    MOV DL,#1
    OUT (DX),AL
    LDA AL,[dig100]
    ADD AL,#0x30
    MOV DL,#2
    OUT (DX),AL
    LDA AL,[dig10]
    ADD AL,#0x30
    MOV DL,#3
    OUT (DX),AL
    LDA AL,[dig1]
    ADD AL,#0x30
    MOV DL,#4
    OUT (DX),AL
    RET

; --- update_lives_hud: numero de vidas, justo al lado del icono de
; corazon (0-3, siempre cabe en 1 digito -- MAX_LIVES)
update_lives_hud:
    LDA AL,[lives]
    ADD AL,#0x30
    MOV DL,#LIVES_DIGIT_COL
    MOV DH,#0x04
    OUT (DX),AL
    RET

; --- update_keys_hud: numero de llaves cogidas en total, justo al lado
; del icono de llave (1 sola cifra -- nunca llega a 10, ver comentario junto
; a KEYS_DIGIT_COL)
update_keys_hud:
    LDA AL,[keys_held]
    ADD AL,#0x30
    MOV DL,#KEYS_DIGIT_COL
    MOV DH,#0x04
    OUT (DX),AL
    RET

; --- nd16_digit: extrae UN digito (0-9, o hasta 6 para el de decenas de
; millar) de [nd_val_lo]/[nd_val_hi] (16 bits) segun el lugar en
; [nd_place_lo]/[nd_place_hi] (una potencia de 10), restando repetidamente
; -- no hay DIV. Deja [nd_val_lo]/[nd_val_hi] con el resto, listos para la
; siguiente llamada con el lugar mas pequeño. Comparacion de 16 bits: primero
; los bytes altos: distintos deciden solos; iguales, deciden los bajos.
nd16_digit:
    MOV AL,#0
    STA [nd_digit],AL
nd16_loop:
    LDA AL,[nd_val_hi]
    LDA BL,[nd_place_hi]
    CMP AL,BL
    JMPC nd16_done          ; val_hi < place_hi -> resto ya mas pequeno
    JMPNZ nd16_sub          ; val_hi > place_hi -> claramente mayor, resta
    LDA AL,[nd_val_lo]
    LDA BL,[nd_place_lo]
    CMP AL,BL
    JMPC nd16_done          ; hi iguales, val_lo < place_lo -> mas pequeno
nd16_sub:
    LDA AL,[nd_val_lo]
    LDA BL,[nd_place_lo]
    SUB AL,BL
    STA [nd_val_lo],AL
    JMPNC nd16_sub_nb       ; sin prestamo del byte bajo
    LDA AL,[nd_val_hi]
    LDA BL,[nd_place_hi]
    SUB AL,BL
    SUB AL,#1               ; el prestamo del byte bajo se paga aqui
    STA [nd_val_hi],AL
    JMP nd16_sub_done
nd16_sub_nb:
    LDA AL,[nd_val_hi]
    LDA BL,[nd_place_hi]
    SUB AL,BL
    STA [nd_val_hi],AL
nd16_sub_done:
    LDA AL,[nd_digit]
    ADD AL,#1
    STA [nd_digit],AL
    JMP nd16_loop
nd16_done:
    LDA AL,[nd_digit]
    RET

; --- show_game_over: mensaje simple en texto, espera a soltar y a pulsar
; DIRECCION antes de seguir (para no reiniciar de un solo toque sin querer)
show_game_over:
    CALL clst
    MOV BL,#lo(msg_over)
    MOV BH,#hi(msg_over)
    MOV CL,#6
    MOV CH,#3
    CALL puts
    MOV BL,#lo(GAMEOVER_TUNE)
    MOV BH,#hi(GAMEOVER_TUNE)
    CALL play_tune
    CALL wait_dir_release
sgo_wait:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ sgo_wait
    CALL wait_dir_release
    CALL clst
    RET

; --- show_victory: pantalla final tras matar al jefe -- mismo patron que
; show_game_over (mensaje + melodia + esperar DIRECCION), pero con la
; puntuacion final debajo tambien (igual formato que game over, digitos ya
; calculados por score_digits/put_num en otras pantallas de este fichero).
show_victory:
    CALL clst
    MOV BL,#lo(msg_win1)
    MOV BH,#hi(msg_win1)
    MOV CL,#4
    MOV CH,#2
    CALL puts
    MOV BL,#lo(msg_win2)
    MOV BH,#hi(msg_win2)
    MOV CL,#3
    MOV CH,#4
    CALL puts
    MOV BL,#lo(VICTORY_TUNE)
    MOV BH,#hi(VICTORY_TUNE)
    CALL play_tune
    CALL wait_dir_release
sv_wait:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPZ sv_wait
    CALL wait_dir_release
    CALL clst
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS (doble buffer, igual patron que cubo.asm/fzero.asm)
; ============================================================================

; --- idx_ptr: BX = (BX inicial) + CL, propagando el acarreo a mano --------
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

; --- sign_of: entra AL = numero con signo; sale AL = -1/0/+1 segun su
; signo -- convierte una velocidad de varios px/fotograma (SHOT_SPEED) en el
; paso unitario para barrer el recorrido px a px (ver update_shots/
; update_enemy_shots: probar solo el punto de destino dejaba saltar un
; disparo por encima de una pared o puerta de 1-2px sin llegar a tocarla).
sign_of:
    CMP AL,#0
    JMPZ sgn_zero
    AND AL,#0x80
    JMPZ sgn_pos
    MOV AL,#0xFF
    RET
sgn_pos:
    MOV AL,#1
    RET
sgn_zero:
    MOV AL,#0
    RET

; --- px_to_row/px_to_col: entra AL = coordenada Y (0-63) o X (0-127) en
; pixeles ; sale AL = fila (0..MAZE_ROWS-1) o columna (0..MAZE_COLS-1) --
; con CELL_H/CELL_W=21 (no potencia de 2) no hay division real, de ahi la
; tabla.
px_to_row:
    STA [tmp3],AL
    LDA CL,[tmp3]
    MOV BL,#lo(PX_TO_ROW)
    MOV BH,#hi(PX_TO_ROW)
    CALL idx_ptr
    LDA AL,[BX]
    RET

px_to_col:
    STA [tmp3],AL
    LDA CL,[tmp3]
    MOV BL,#lo(PX_TO_COL)
    MOV BH,#hi(PX_TO_COL)
    CALL idx_ptr
    LDA AL,[BX]
    RET

; --- row_to_px/col_to_px: entra AL = fila o columna ; sale AL =
; fila*CELL_H o columna*CELL_W -- igual razon, tabla en vez de un SHL.
row_to_px:
    STA [tmp3],AL
    LDA CL,[tmp3]
    MOV BL,#lo(ROW_PX)
    MOV BH,#hi(ROW_PX)
    CALL idx_ptr
    LDA AL,[BX]
    RET

col_to_px:
    STA [tmp3],AL
    LDA CL,[tmp3]
    MOV BL,#lo(COL_PX)
    MOV BH,#hi(COL_PX)
    CALL idx_ptr
    LDA AL,[BX]
    RET

; --- calc_pix: de (px_x,px_y) saca puerto/offset (pix_lo/pix_hi) + mascara -
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

; --- shadow_set_px: enciende (px_x,px_y) en `shadow` --------------------
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

; --- shadow_clear_px: apaga (px_x,px_y) en `shadow` (lo contrario de
; shadow_set_px) -- para dejar un fondo solido negro antes de dibujar algo
; encima (el marcador de corazones), por si una pared de la sala pasara
; justo por ahi.
shadow_clear_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    NOT DL
    AND AL,DL
    STA [BX],AL
    RET

; --- walls_set_px: enciende (px_x,px_y) en `walls` (draw_maze) ----------
walls_set_px:
    CALL calc_pix
    MOV BL,#lo(walls)
    MOV BH,#hi(walls)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

; --- fb_set_px: enciende (px_x,px_y) DIRECTO en el framebuffer real (no en
; `shadow`) -- para dibujos estaticos que no se repiten cada fotograma
; (la pantalla de titulo), sin necesitar todo el pipeline de doble buffer.
fb_set_px:
    CALL calc_pix
    MOV BL,#0
    MOV BH,#0
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    IN  AL,(BX)
    LDA DL,[pix_mask]
    OR  AL,DL
    OUT (BX),AL
    RET

; --- wall_test: entra (px_x,px_y) ; sale AL=0 si libre, !=0 si pared -----
wall_test:
    CALL calc_pix
    MOV BL,#lo(walls)
    MOV BH,#hi(walls)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    AND AL,DL
    RET

; --- clr_walls: pone a 0 los 1024 bytes de `walls` (ver la nota de
; clr_shadow: no vale el truco de contar paginas por BH, `walls` no empieza
; en un limite de pagina) -------------------------------------------------
clr_walls:
    MOV BL,#lo(walls)
    MOV BH,#hi(walls)
    MOV AL,#0
    MOV CL,#0
    MOV CH,#4
cw_l:
    STA [BX],AL
    ADD BL,#1
    JMPNC cw_addr_ok
    ADD BH,#1
cw_addr_ok:
    SUB CL,#1
    JMPNC cw_cnt_ok
    SUB CH,#1
cw_cnt_ok:
    MOV DL,CH
    OR  DL,CL
    JMPNZ cw_l
    RET

; --- copy_walls_to_shadow: `shadow` = `walls` (1024 bytes) --------------
copy_walls_to_shadow:
    MOV BL,#lo(walls)
    MOV BH,#hi(walls)
    MOV DL,#lo(shadow)
    MOV DH,#hi(shadow)
    MOV CL,#0
    MOV CH,#4
cws_l:
    LDA AL,[BX]
    STA [DX],AL
    ADD BL,#1
    JMPNC cws_b_ok
    ADD BH,#1
cws_b_ok:
    ADD DL,#1
    JMPNC cws_d_ok
    ADD DH,#1
cws_d_ok:
    SUB CL,#1
    JMPNC cws_cnt_ok
    SUB CH,#1
cws_cnt_ok:
    MOV AL,CH
    OR  AL,CL
    JMPNZ cws_l
    RET

; --- blit: copia `shadow` al framebuffer real, solo lo que cambie -------
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

; --- clsg: apaga el framebuffer grafico completo ------------------------
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

; --- clst: borra la capa de texto (0x0400..0x04FF) ----------------------
clst:
    MOV DL,#0
    MOV DH,#0x04
    MOV AL,#0
clst_l:
    OUT (DX),AL
    ADD DL,#1
    JMPNZ clst_l
    RET

; --- puts: BL/BH = puntero asciiz, CL = col, CH = fila -------------------
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

; --- rnd / rnd_raw: LFSR de 8 bits (taps 0xB8), mezclando 3 pasos --------
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

; --- frame_wait: AL = pasos del temporizador 3 (8 ms/paso) --------------
frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- play_tune: entra BL/BH = puntero a una tabla .db nota,duracion,...,
; 0xFF (duracion en pasos de frame_wait, ~8 ms cada uno) -- bloqueante,
; igual patron que musica.asm: reutilizable para el jingle de puntos, el
; aviso de temor y la melodia de la pantalla de titulo, cada una con su
; propia tabla.
play_tune:
    MOV AL,BL
    STA [pt_lo],AL
    MOV AL,BH
    STA [pt_hi],AL
pt_nx:
    LDA BL,[pt_lo]
    LDA BH,[pt_hi]
    LDA AL,[BX]
    CMP AL,#0xFF
    JMPZ pt_done
    STA [pt_note],AL
    CALL pt_inc

    LDA BL,[pt_lo]
    LDA BH,[pt_hi]
    LDA AL,[BX]
    STA [pt_dur],AL
    CALL pt_inc

    LDA AL,[pt_note]
    OUT (P_SND_NOTE),AL
    LDA AL,[pt_dur]
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    CALL frame_wait          ; corte breve para que se oigan separadas
    JMP pt_nx
pt_done:
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    RET

pt_inc:
    LDA AL,[pt_lo]
    ADD AL,#1
    STA [pt_lo],AL
    JMPNC pt_inc_d
    LDA AL,[pt_hi]
    ADD AL,#1
    STA [pt_hi],AL
pt_inc_d:
    RET

; --- draw_big_letter: dibuja una letra grande a partir de dos tablas de
; puntos (dx,dy en una rejilla de 5x7), cada punto ampliado a un bloque
; relleno de LETTER_SCALE x LETTER_SCALE con fb_set_px. Entra: BL/BH =
; tabla DX, DL/DH = tabla DY, y ya puestos [lp_n] (numero de puntos),
; [lp_x0]/[lp_y0] (esquina superior izquierda en pantalla).
draw_big_letter:
    MOV AL,BL
    STA [lp_dx_lo],AL
    MOV AL,BH
    STA [lp_dx_hi],AL
    MOV AL,DL
    STA [lp_dy_lo],AL
    MOV AL,DH
    STA [lp_dy_hi],AL

    MOV AL,#0
    STA [j],AL
dbl_l:
    LDA CL,[j]
    LDA BL,[lp_dx_lo]
    LDA BH,[lp_dx_hi]
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp1],AL            ; dx (0-4)

    LDA CL,[j]
    LDA BL,[lp_dy_lo]
    LDA BH,[lp_dy_hi]
    CALL idx_ptr
    LDA AL,[BX]
    STA [tmp2],AL            ; dy (0-6)

    LDA CL,[tmp1]
    MOV BL,#lo(MUL3)
    MOV BH,#hi(MUL3)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[lp_x0]
    ADD AL,BL
    STA [wx0],AL              ; x0 + dx*LETTER_SCALE

    LDA CL,[tmp2]
    MOV BL,#lo(MUL3)
    MOV BH,#hi(MUL3)
    CALL idx_ptr
    LDA AL,[BX]
    LDA BL,[lp_y0]
    ADD AL,BL
    STA [wy0],AL              ; y0 + dy*LETTER_SCALE

    MOV AL,#0
    STA [wk],AL
dbl_row:
    MOV AL,#0
    STA [k],AL
dbl_col:
    LDA AL,[wx0]
    LDA BL,[k]
    ADD AL,BL
    STA [px_x],AL
    LDA AL,[wy0]
    LDA BL,[wk]
    ADD AL,BL
    STA [px_y],AL
    CALL fb_set_px

    LDA AL,[k]
    ADD AL,#1
    STA [k],AL
    CMP AL,#LETTER_SCALE
    JMPNZ dbl_col

    LDA AL,[wk]
    ADD AL,#1
    STA [wk],AL
    CMP AL,#LETTER_SCALE
    JMPNZ dbl_row

    LDA AL,[j]
    ADD AL,#1
    STA [j],AL
    LDA BL,[lp_n]
    CMP AL,BL
    JMPNZ dbl_l
    RET

; --- title_screen: titulo "SHAMUS" grande, en pixel art (draw_big_letter),
; con una melodia corta en bucle hasta que se pulse DATOS o DIRECCION
; (edge-detected, patron de pong.asm/serve_check -- igual que el "pulsa
; para empezar" de fzero.asm).
title_screen:
    CALL clsg
    CALL clst

    MOV AL,#TITLE_Y
    STA [lp_y0],AL           ; misma fila (y) para las 6 letras

    MOV AL,#TITLE_X0
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_S_DX)
    MOV BH,#hi(LETTER_S_DX)
    MOV DL,#lo(LETTER_S_DY)
    MOV DH,#hi(LETTER_S_DY)
    MOV AL,#LETTER_S_N
    STA [lp_n],AL
    CALL draw_big_letter

    LDA AL,[lp_x0]
    ADD AL,#TITLE_STEP
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_H_DX)
    MOV BH,#hi(LETTER_H_DX)
    MOV DL,#lo(LETTER_H_DY)
    MOV DH,#hi(LETTER_H_DY)
    MOV AL,#LETTER_H_N
    STA [lp_n],AL
    CALL draw_big_letter

    LDA AL,[lp_x0]
    ADD AL,#TITLE_STEP
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_A_DX)
    MOV BH,#hi(LETTER_A_DX)
    MOV DL,#lo(LETTER_A_DY)
    MOV DH,#hi(LETTER_A_DY)
    MOV AL,#LETTER_A_N
    STA [lp_n],AL
    CALL draw_big_letter

    LDA AL,[lp_x0]
    ADD AL,#TITLE_STEP
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_M_DX)
    MOV BH,#hi(LETTER_M_DX)
    MOV DL,#lo(LETTER_M_DY)
    MOV DH,#hi(LETTER_M_DY)
    MOV AL,#LETTER_M_N
    STA [lp_n],AL
    CALL draw_big_letter

    LDA AL,[lp_x0]
    ADD AL,#TITLE_STEP
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_U_DX)
    MOV BH,#hi(LETTER_U_DX)
    MOV DL,#lo(LETTER_U_DY)
    MOV DH,#hi(LETTER_U_DY)
    MOV AL,#LETTER_U_N
    STA [lp_n],AL
    CALL draw_big_letter

    LDA AL,[lp_x0]
    ADD AL,#TITLE_STEP
    STA [lp_x0],AL
    MOV BL,#lo(LETTER_S_DX)
    MOV BH,#hi(LETTER_S_DX)
    MOV DL,#lo(LETTER_S_DY)
    MOV DH,#hi(LETTER_S_DY)
    MOV AL,#LETTER_S_N
    STA [lp_n],AL
    CALL draw_big_letter

    MOV BL,#lo(title_sub)
    MOV BH,#hi(title_sub)
    MOV CL,#4                ; centrado: (21-13)/2, "PRESS TO PLAY" son 13
    MOV CH,#4
    CALL puts

    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL

    ; la melodia suena UNA sola vez (con salida anticipada si se pulsa
    ; durante ella); si termina sin pulsar nada, se espera en silencio --
    ; nada de repetirla en bucle sin parar.
    MOV BL,#lo(TITLE_TUNE)
    MOV BH,#hi(TITLE_TUNE)
    CALL play_tune_check
    CMP AL,#0
    JMPNZ ts_done

ts_wait:
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ts_wait_dir
    CMP BL,#0
    JMPZ ts_done
ts_wait_dir:
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ ts_wait_gap
    CMP BL,#0
    JMPZ ts_done
ts_wait_gap:
    MOV AL,#2
    CALL frame_wait
    JMP ts_wait

ts_done:
    CALL clsg
    CALL clst
    RET

; --- play_tune_check: igual que play_tune, pero comprueba flancos de
; DAT_BTN/DIR_BTN tras cada nota; si detecta alguno, corta ya y sale con
; AL=1; si termina la tabla entera sin pulsar nada, sale con AL=0 (para que
; quien llama la repita).
play_tune_check:
    MOV AL,BL
    STA [pt_lo],AL
    MOV AL,BH
    STA [pt_hi],AL
ptc_nx:
    LDA BL,[pt_lo]
    LDA BH,[pt_hi]
    LDA AL,[BX]
    CMP AL,#0xFF
    JMPZ ptc_done_noplay
    STA [pt_note],AL
    CALL pt_inc

    LDA BL,[pt_lo]
    LDA BH,[pt_hi]
    LDA AL,[BX]
    STA [pt_dur],AL
    CALL pt_inc

    LDA AL,[pt_note]
    OUT (P_SND_NOTE),AL
    LDA AL,[pt_dur]
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL

    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ptc_chk_dir
    CMP BL,#0
    JMPZ ptc_pressed
ptc_chk_dir:
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ ptc_gap
    CMP BL,#0
    JMPZ ptc_pressed

ptc_gap:
    MOV AL,#1
    CALL frame_wait
    JMP ptc_nx

ptc_done_noplay:
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV AL,#0
    RET
ptc_pressed:
    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    RET

; --- wait_dir_release: espera a que se suelte DIRECCION -----------------
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
;  DATOS
; ============================================================================
BIT_OF_DIR: .db 1, 2, 4, 8            ; N,E,S,W
OPP_OF_DIR: .db 2, 3, 0, 1            ; opuesta de N,E,S,W
DR_OF_DIR:  .db 255, 0, 1, 0          ; delta de fila de N,E,S,W (-1,0,1,0)
DC_OF_DIR:  .db 0, 1, 0, 255          ; delta de columna de N,E,S,W (0,1,0,-1)

; MAZE_COLS(6)/MAZE_ROWS(3) no son potencias de 2, asi que fila*MAZE_COLS+col
; (ROW_MUL) y el camino inverso, indice->fila/columna (CELL_TO_ROW/COL), no
; se pueden calcular con SHL/SHR/AND -- de ahi estas tres tablas.
ROW_MUL:     .db 0, 6, 12                                  ; fila*MAZE_COLS
CELL_TO_ROW: .db 0,0,0,0,0,0, 1,1,1,1,1,1, 2,2,2,2,2,2
CELL_TO_COL: .db 0,1,2,3,4,5, 0,1,2,3,4,5, 0,1,2,3,4,5

; sala*NCELLS(18) para persist_walls/persist_doors -- tampoco es potencia
; de 2, asi que room_off usa esta tabla en vez de partir el desplazamiento
; en SHR/SHL como cuando NCELLS era 32
; OJO: MAX_ROOMS es 50 (ver mas arriba) -- esta tabla necesita 50 entradas,
; una por sala (bug real que hubo: se quedo con solo 24 desde que MAX_ROOMS
; paso de 24 a 50 para el jefe final, y room_off leia basura fuera de la
; tabla para cualquier sala 24..49, calculando un desplazamiento cualquiera
; en persist_walls/persist_doors -- podia corromper o leer los datos
; persistidos de OTRA sala completamente distinta sin relacion aparente).
ROOM_OFF_LO: .db 0, 18, 36, 54, 72, 90, 108, 126, 144, 162, 180, 198, 216, 234, 252, 14, 32, 50, 68, 86, 104, 122, 140, 158, 176, 194, 212, 230, 248, 10, 28, 46, 64, 82, 100, 118, 136, 154, 172, 190, 208, 226, 244, 6, 24, 42, 60, 78, 96, 114
ROOM_OFF_HI: .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3

; fila/columna <-> pixeles (CELL_H/CELL_W = 21, no potencia de 2 -- ver
; px_to_row/px_to_col/row_to_px/col_to_px)
ROW_PX: .db 0, 21, 42
COL_PX: .db 0, 21, 42, 63, 84, 105
PX_TO_ROW: .db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
PX_TO_COL: .db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5

ENEMY_SPAWN_ROW: .db 0, 2, 2
ENEMY_SPAWN_COL: .db 5, 0, 5

; muñeco de palo, 5x6, esquina superior izquierda como referencia
PLAYER_SPRITE_N = 12
PLAYER_SPRITE_DX: .db 2, 2, 0, 1, 2, 3, 4, 2, 1, 3, 0, 4
PLAYER_SPRITE_DY: .db 0, 1, 2, 2, 2, 2, 2, 3, 4, 4, 5, 5

; enemigo: rombo relleno de 5x5, centrado en (0,0)
ENEMY_SPRITE_N = 13
ENEMY_SPRITE_DX: .db 0, 255, 0, 1, 254, 255, 0, 1, 2, 255, 0, 1, 0
ENEMY_SPRITE_DY: .db 254, 255, 255, 255, 0, 0, 0, 0, 0, 1, 1, 1, 2

; jefe final: mismo rombo que el enemigo normal, pero de radio 3 en vez de
; radio 2 (25 puntos en vez de 13) para que se vea claramente mas grande --
; ver ENEMY_TYPE_BOSS en draw_frame/setup_enemies.
BOSS_SPRITE_N = 25
BOSS_SPRITE_DX: .db 253, 254,254,254, 255,255,255,255,255, 0,0,0,0,0,0,0, 1,1,1,1,1, 2,2,2, 3
BOSS_SPRITE_DY: .db 0, 255,0,1, 254,255,0,1,2, 253,254,255,0,1,2,3, 254,255,0,1,2, 255,0,1, 0

; llave: aro + varilla + un diente, 7x5, centrada en (0,0) -- tumbada de
; lado (aro a la izquierda, varilla hacia la derecha) para que mida lo
; mismo de alto que el corazon (5px) y no sobresalga ni se confunda con
; una pared
KEY_SPRITE_N = 13
KEY_SPRITE_DX: .db 253,253,253, 254,254, 255,255,255, 0, 1, 2, 3,3
KEY_SPRITE_DY: .db 255,0,1, 254,2, 255,0,1, 0, 0, 0, 255,0

; corazon: un solo icono fijo (HEART_ICON_X/Y), el numero de al lado dice
; cuantas vidas quedan
HEART_SPRITE_N = 16
HEART_SPRITE_DX: .db 1,3, 0,1,2,3,4, 0,1,2,3,4, 1,2,3, 2
HEART_SPRITE_DY: .db 0,0, 1,1,1,1,1, 2,2,2,2,2, 3,3,3, 4

msg_over: .asciiz "GAME OVER"

msg_win1: .asciiz "YOU WIN!"
msg_win2: .asciiz "LEVEL 50 CLEAR"

title_sub: .asciiz "PRESS TO PLAY"

; melodia de la pantalla de titulo: suena UNA sola vez, con una cadencia
; final de verdad en vez de cortarse en seco -- llamada de aventura (galope
; corto-corto-largo, como el tema de musica.asm), sube hasta el climax y
; luego baja resolviendo hasta la tonica grave, sostenida.
TITLE_TUNE: .db 67,6, 72,6, 76,10, 74,4, 72,4, 71,4, 69,8, 67,4, 71,4, 74,4, 79,10, 84,8, 79,8, 76,8, 72,10, 67,8, 60,28, 0xFF

; --- MUL3: tabla de multiplos de LETTER_SCALE(3), para 0..6 -- no hay MUL,
; y 3 no es potencia de 2 (no vale un SHL) ------------------------------
MUL3: .db 0, 3, 6, 9, 12, 15, 18

; --- letras grandes de la pantalla de titulo, rejilla de 5 (x) por 7 (y) --
LETTER_H_N = 17
LETTER_H_DX: .db 0,4,0,4,0,4,0,1,2,3,4,0,4,0,4,0,4
LETTER_H_DY: .db 0,0,1,1,2,2,3,3,3,3,3,4,4,5,5,6,6

LETTER_A_N = 18
LETTER_A_DX: .db 1,2,3,0,4,0,4,0,1,2,3,4,0,4,0,4,0,4
LETTER_A_DY: .db 0,0,0,1,1,2,2,3,3,3,3,3,4,4,5,5,6,6

LETTER_M_N = 17
LETTER_M_DX: .db 0,4,0,1,3,4,0,2,4,0,4,0,4,0,4,0,4
LETTER_M_DY: .db 0,0,1,1,1,1,2,2,2,3,3,4,4,5,5,6,6

LETTER_S_N = 15
LETTER_S_DX: .db 1,2,3,4,0,0,1,2,3,4,4,0,1,2,3
LETTER_S_DY: .db 0,0,0,0,1,2,3,3,3,4,5,6,6,6,6

LETTER_U_N = 15
LETTER_U_DX: .db 0,4,0,4,0,4,0,4,0,4,0,4,1,2,3
LETTER_U_DY: .db 0,0,1,1,2,2,3,3,4,4,5,5,6,6,6

; jingle de puntos: 5 notas alegres y cortas (DO-MI-SOL-DO-SOL, la ultima
; mas larga para que se note el final)
JINGLE_TUNE: .db 72,6, 76,6, 79,6, 84,10, 79,8, 0xFF

; game over: descenso lento y grave, tipo "trombon triste"
GAMEOVER_TUNE: .db 65,8, 62,8, 58,8, 53,8, 48,32, 0xFF

; victoria: arpegio ascendente de dos octavas, la ultima nota mas larga
VICTORY_TUNE: .db 60,6, 64,6, 67,6, 72,6, 76,6, 79,6, 84,20, 0xFF

; ============================================================================
;  VARIABLES
; ============================================================================
room_num: .space 1
score_lo: .space 1     ; puntuacion de 16 bits (0..65535) -- ver score_add
score_hi: .space 1
lives:    .space 1
keys_held: .space 1
seed:     .space 1

dir_pos_prev: .space 1
dat_pos_prev: .space 1

entry_side: .space 1
entry_row:  .space 1
entry_col:  .space 1
rc_row:     .space 1
rc_col:     .space 1
cand0:      .space 1
cand1:      .space 1
cand2:      .space 1

; --- salas persistentes (ver la nota de cabecera) ---
next_room_id: .space 1
award_points: .space 1
door_bits: .space 18    ; NCELLS -- literal, .space no admite constantes
key_cell:  .space 1
key_taken: .space 1
prev_room_num: .space 1 ; sala de la que se viene, puesta por cross_room_gap
                         ; justo antes de generar una sala nueva -- ahi es
                         ; donde gen_and_save_current_room coloca la llave
                         ; de la puerta de la sala nueva, si le toca una
room0_entered: .space 1 ; puesto a 0 en new_game; a 1 por cross_room_gap justo
                         ; al CRUZAR hacia afuera de la sala 0 la primera vez
                         ; (ver la guarda de place_player_spawn: "centro de
                         ; pantalla" SOLO mientras esto siga a 0 -- en cuanto
                         ; se ha salido una vez, la sala 0 usa entry_side
                         ; como cualquier otra)
boss_room_ready: .space 1 ; puesto a 0 en new_game; a 1 la primera vez que se
                         ; genera de verdad la sala del jefe (ver la guarda de
                         ; cross_room_gap: solo se genera una vez, por muchos
                         ; huecos distintos que acaben apuntando ahi tras
                         ; saturar next_room_id)
boss_entry_side: .space 1 ; la UNICA entrada real del jefe, fijada junto con
                         ; boss_room_ready -- crg_boss_existing la restaura
                         ; sobre [entry_side] antes de colocar al jugador,
                         ; sin importar desde que direccion se saturo esta
                         ; vez hacia el jefe
door_cell: .space 1
door_dir:  .space 1
heart_cell:  .space 1
heart_taken: .space 1
low_life_rooms: .space 1
dbv:  .space 1
drow: .space 1
dcol: .space 1
dx_pt: .space 1
dy_pt: .space 1
tmp3: .space 1

player_x: .space 1
player_y: .space 1
pdx:      .space 1
dy:       .space 1
walk_phase: .space 1    ; 0=quieto, 1=pie izq. levantado, 2=pie der. levantado
walk_timer: .space 1
walk_idle:  .space 1
try_x:    .space 1
try_y:    .space 1
test_x:   .space 1
test_y:   .space 1
room_transition_pending: .space 1
exit_dir_taken: .space 1

; --- disparo del jugador (ver update_fire/update_shots) ---
last_fire_dir: .space 1
dat_btn_prev: .space 1
dir_btn_prev: .space 1
shot_active: .space 2
shot_x:      .space 2
shot_y:      .space 2
shot_vx:     .space 2
shot_vy:     .space 2

; --- play_tune ---
pt_lo:   .space 1
pt_hi:   .space 1
pt_note: .space 1
pt_dur:  .space 1

; --- draw_big_letter ---
lp_dx_lo: .space 1
lp_dx_hi: .space 1
lp_dy_lo: .space 1
lp_dy_hi: .space 1
lp_x0: .space 1
lp_y0: .space 1
lp_n:  .space 1

enemy_count: .space 1
move_delay:  .space 1
move_counter: .space 1
enemy_active: .space 3
enemy_x:      .space 3
enemy_y:      .space 3
enemy_dir:    .space 3
enemy_type:   .space 3
boss_hp:      .space 1     ; solo tiene sentido en BOSS_ROOM_NUM (slot 0)

; --- disparo enemigo (uno solo a la vez, ver update_enemy_fire/shots) ---
enemy_shot_active:   .space 1
enemy_shot_x:        .space 1
enemy_shot_y:        .space 1
enemy_shot_vx:       .space 1
enemy_shot_vy:       .space 1
enemy_shot_cooldown: .space 1
e:  .space 1
ex: .space 1
ey: .space 1
ecol: .space 1
erow: .space 1
ecell: .space 1
cwv:  .space 1
banned_dir: .space 1
best_dist: .space 1
best_dir:  .space 1
d:    .space 1
trow: .space 1
tcol: .space 1
dist: .space 1
pcol: .space 1
prow: .space 1

cell_walls: .space 18   ; NCELLS -- literal, .space no admite constantes
visited:    .space 18
i:    .space 1
j:    .space 1
cur_cell: .space 1
cur_row:  .space 1
cur_col:  .space 1
start_dir: .space 1
k:    .space 1
found: .space 1
stack_depth: .space 1
mz_row: .space 1
mz_col: .space 1
try_cell: .space 1
od_cell: .space 1
od_dir:  .space 1
tmp0: .space 1
tmp1: .space 1
tmp2: .space 1

ro_lo: .space 1
ro_hi: .space 1
ro_off: .space 1
ro_offhi: .space 1

stepx: .space 1
stepy: .space 1

wx0: .space 1
wy0: .space 1
wk:  .space 1

px_x: .space 1
px_y: .space 1
pix_lo: .space 1
pix_hi: .space 1
pfx: .space 1
pfy: .space 1
pix_mask: .space 1

dig10000: .space 1
dig1000:  .space 1
dig100: .space 1
dig10:  .space 1
dig1:   .space 1

; --- escritorio de nd16_digit (extraccion de digitos de 16 bits) ----------
nd_val_lo:   .space 1
nd_val_hi:   .space 1
nd_place_lo: .space 1
nd_place_hi: .space 1
nd_digit:    .space 1

; --- estado persistente de hasta 50 salas (MAX_ROOMS -- literal, no una
; constante simbolica, por la misma razon que NCELLS en otros .space: casm.py
; resuelve los "NAME = EXPR" en una pasada posterior a calcular los .space)
room_link: .space 200           ; 50*4: por sala y lado, 254=sin explorar,
                                 ; 0-49=sala ya asignada por ese lado
persist_walls: .space 900       ; 50*18 (MAX_ROOMS*NCELLS)
persist_doors: .space 900       ; 50*18
persist_key_taken: .space 50
persist_key_cell:  .space 50
persist_door_cell: .space 50
persist_door_dir:  .space 50
persist_heart_taken: .space 50
persist_heart_cell:  .space 50

; walls/shadow: TIENEN que ir las ultimas de todo el fichero (ver la nota de
; cubo.asm, "Tamano del .bin" en programs/README.md): al ser .space sin
; datos reales despues, no cuentan para el recorte del .bin.
walls:  .space 1024
shadow: .space 1024
