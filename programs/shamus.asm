;============================================================================
;  CHANGELOG -- indice de cambios de shamus.asm, el mas reciente primero.
;  Mirar aqui antes de tocar generacion de salas, llaves/candados, corazones
;  o enemigos: varios arreglos rompieron sin querer algo que dependia del
;  mismo sitio. El porque detallado de cada uno sigue en el comentario de la
;  seccion que toca.
;
;  - LLAVES Y CANDADOS rediseñados: 20 candados en la SALIDA de las salas del
;    camino 4..23, y cada llave en su propia sala RAMAL (25..44), lejos de la
;    entrada de esa sala (MIN_KEY_DIST). El ramal puede colgar de una sala
;    anterior al candado (hasta 3, MAX_KEY_OFFSET), mas a menudo en los
;    niveles avanzados. Sustituye al esquema par/impar 0..19 (10+10) --
;    pedido real: "las llaves deberian encontrarse en salas adyacentes al
;    camino" y "no siempre en la sala justo al lado de la puerta cerrada".
;  - Candado movido de la ENTRADA a la SALIDA de su sala: cruzar de sala es
;    un teletransporte al punto de aparicion, asi que un candado en la
;    entrada se abria solo e invisible nada mas aparecer con una llave (bug
;    real reportado, "se han perdido las puertas; las llaves se pierden").
;  - cross_room_gap: el lado de entrada en la sala destino es siempre el
;    opuesto del lado realmente cruzado, no el room_entry_side[] fijo (bug
;    real reportado: al volver de un ramal se aparecia en el lado contrario).
;  - FANTASMA recuperado (se habia perdido del .asm aunque seguia en el .bin
;    del aparato): aparece si el jugador pasa mas de (50 - llaves usadas) s en
;    la misma sala, atraviesa paredes, persigue y mata al tocar; el contador
;    se reinicia al cambiar de sala y nunca aparece en la sala del jefe.
;    Re-Mi en bucle, mas rapido cuanto mas cerca (on_room_entered/update_ghost).
;    Avanza 1 px por eje cada GHOST_MOVE_DELAY(5) fotogramas, no en cada uno:
;    a esa velocidad no daba tiempo a escapar (pedido real).
;============================================================================

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
;  SALAS PERSISTENTES: cada sala, una vez generada, se guarda entera
;  (persist_walls/persist_doors/persist_key_*/persist_door_*, indexados por
;  numero de sala hasta MAX_ROOMS=50) para que volver a ella la deje
;  EXACTAMENTE igual -- asi el jugador puede escapar de un enemigo dando
;  marcha atras. Solo se puntua la PRIMERA vez que se entra a cada sala
;  (room_visited[], ver cross_room_gap); volver a una ya visitada no da
;  puntos. Los enemigos SI se regeneran de cero cada vez que se entra a una
;  sala (persistida o no), la unica pieza que no persiste.
;
;  TOPOLOGIA PLANIFICADA DE ANTEMANO: a diferencia de un diseño anterior que
;  decidia cada sala AL EXPLORARLA (sorteando sus huecos extra sobre la
;  marcha, con las 50 salas como un arbol que crecia segun se avanzaba),
;  ahora plan_dungeon decide las 50 salas ENTERAS -- su conexion con las
;  demas (room_link[]) y por que lado se entra a cada una (room_entry_side[])
;  -- antes de generar ninguna, y new_game genera las 50 de un tiron antes de
;  que el jugador de un solo paso. Motivo: un esquema de llaves/candados
;  fijo (ver mas abajo) necesita saber de antemano exactamente cuantas salas
;  van a llevar una llave o un candado, cosa que un arbol construido al azar
;  sobre la marcha no puede garantizar.
;
;  Hay un CAMINO DIRECTO de PATH_ROOMS(25) salas: 0->1->2->...->24->49 (el
;  jefe), cada una conectada con la siguiente por un lado al azar (sin
;  repetir lado dentro de la misma sala). Las EXTRA_ROOMS(24) restantes
;  (25..48) cuelgan, cada una, de UNA sala del camino por uno de sus lados
;  libres -- ninguna cuelga de otra rama, pero eso no quiere decir que la
;  llave de un candado este siempre al lado: 20 de ellas (25..44) son los
;  ramales de llave y pueden colgar de una sala ANTERIOR a la de su candado
;  (ver LLAVES Y CANDADOS), asi que una llave puede quedar a mas de una sala
;  de distancia de donde hay que usarla. Las 4 restantes (45..48) son ramales
;  al azar, sin llave ni candado.
;
;  LLAVES Y CANDADOS: las llaves NO estan en el propio camino -- viven en
;  salas RAMAL. gen_and_save_current_room lo deduce del numero de sala:
;    - Salas 0..3 del camino: nunca llevan candado (rodaje).
;    - ZONA DE CANDADOS (LOCK_ZONE_START=4 .. +LOCK_ZONE_LEN(20), salas
;      4..23): cada una sale con CANDADO en su SALIDA hacia la sala siguiente
;      del camino (N+1) -- linea sencilla, cell_walls cerrado hasta abrirse
;      con una llave, ver door_check. NUNCA en la entrada: cruzar de sala es un
;      teletransporte al punto de aparicion, ya a menos de DOOR_OPEN_DIST del
;      punto medio de la entrada, asi que un candado ahi se abria solo e
;      invisible al aparecer con una llave encima.
;    - RAMALES DE LLAVE (KEYBRANCH_START=25 .. +KEYBRANCH_LEN(20)): la sala
;      25+k aloja la llave del candado LOCK_ZONE_START+k, en una celda a
;      distancia Manhattan >= MIN_KEY_DIST de su propia entrada (en medio o en
;      el lado opuesto, nunca pegada a la puerta). plan_dungeon la cuelga de
;      la sala del candado o de una ANTERIOR del camino, hasta
;      MAX_KEY_OFFSET[k] salas por delante: 0 en los primeros candados, hasta
;      3 en los mas avanzados -- en los niveles avanzados hay que acordarse de
;      coger la llave al pasar, no basta con mirar la sala del candado. Como
;      el ramal cuelga siempre de una sala ya cruzada (<= la del candado), la
;      partida siempre se puede terminar.
;  20 llaves y 20 candados, GARANTIZADO por construccion (no por probabilidad).
;  La sala 24 y las 45..48 no llevan ni llave ni candado.
;
;  Llavero COMPARTIDO: cualquier llave abre cualquier puerta (basta con
;  llevar al menos una encima, [keys_held], ver door_check) -- no hay
;  emparejamiento llave-puerta especifico, porque el HUD no distingue una
;  llave de otra (solo un icono + una cifra) y exigir la exacta resultaba
;  confuso. Con un ramal por candado colgando de una sala ya cruzada, la
;  llave necesaria siempre esta disponible antes de llegar al candado.
;  Cogerla es automatico al pisar su celda; acercarse a cualquier puerta con
;  candado llevando al menos una llave la abre sola (gastando una del
;  contador), y el cambio se persiste igual que el resto de la sala.
;
;  JEFE FINAL (sala BOSS_ROOM_NUM = MAX_ROOMS-1 = 49, "nivel 50"): enlazada
;  de forma FIJA desde la sala 24 (la ultima del camino) por plan_dungeon --
;  a diferencia de un diseño anterior que la alcanzaba "reciclando" CUALQUIER
;  hueco nuevo una vez saturado el limite de salas generadas (con las
;  guardas que eso necesitaba para no regenerarla ni corromper su enlace de
;  vuelta cada vez que un hueco distinto volvia a apuntar ahi), ahora tiene
;  una unica entrada real, sabida de antemano, igual que cualquier otra
;  sala -- no hace falta ninguna guarda especial. setup_enemies coloca ahi
;  un unico enemigo de tipo ENEMY_TYPE_BOSS: persigue igual que cualquier
;  enemigo (choose_enemy_dir/step_enemy, sin cambios) y ADEMAS dispara
;  (update_enemy_fire ya dispara con cualquier enemy_type != 0, no hizo
;  falta tocarlo), pero con sprite mas grande (BOSS_SPRITE_*) y BOSS_HP_MAX
;  impactos del disparo del jugador en vez de uno solo (ver update_shots).
;  Al caer, en vez del jingle de siempre se ve la pantalla de victoria
;  (show_victory) y la partida se reinicia.
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
;  CAUSA RAIZ real de "un sprite en forma de bola que cruza la pantalla muy
;  despacio, atraviesa paredes y no interactua con nada" (bug reportado):
;  choose_enemy_dir elegia, de los bits abiertos de cell_walls en la celda
;  del enemigo, cualquiera de ellos -- sin distinguir un paso INTERNO normal
;  de la propia ENTRADA de la sala o uno de sus huecos extra (comparten el
;  mismo bit, cell_walls no guarda esa diferencia). Un enemigo que llegaba a
;  la celda de un borde podia "salir" por ahi igual que el jugador, pero
;  para el jugador eso dispara cross_room_gap (genera/enlaza la sala
;  siguiente); para un enemigo no dispara nada -- se quedaba vagando en
;  "fuera de mapa", con cell_walls/PX_TO_ROW/PX_TO_COL leyendo memoria
;  ajena como si fuera terreno valido (de ahi que ignorase las paredes), sin
;  poder tocar ni ser tocado por el jugador (que se quedaba atras, dentro de
;  la sala), hasta desaparecer por el lado opuesto de la pantalla. Ademas,
;  el calculo de distancia Manhattan de ced_consider ni siquiera necesitaba
;  que la sala estuviera realmente en ese borde por casualidad de layout:
;  al salirse de la rejilla (fila o columna -1, envuelve a 255 en un byte
;  sin signo) la resta con la fila/columna del jugador se recalculaba con
;  el mismo truco de negar-si-negativo que un paso valido, dando una
;  distancia PEQUEÑA y plausible en vez de "invalida" -- asi que ese hueco
;  de borde competia de igual a igual, y en un empate el orden de barrido
;  (N antes que E) lo hacia ganar (verificado a mano: celda esquina con N=
;  borde y E=interna abiertas, jugador alineado, ambas dan distancia 1).
;  Arreglo: ced_consider descarta cualquier direccion cuya celda destino
;  caiga fuera de MAZE_ROWSxMAZE_COLS, antes de calcular ninguna distancia
;  -- un enemigo ya no puede tomar la entrada ni ningun hueco extra de la
;  sala, solo los caminos internos del laberinto (garantizado por
;  construccion: el arbol de expansion de gen_maze conecta cada celda por
;  DENTRO de la rejilla, la entrada/huecos extra se añaden aparte, asi que
;  siempre queda al menos una direccion interna valida).
;
;  Ensamblar y enviar al slot 13:
;     python3 tools/casm.py programs/shamus.asm -o programs/shamus.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 13 programs/shamus.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 13

    .name "SHAMUS"

    .category GAME
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

; --- FANTASMA: aparece si el jugador lleva demasiado tiempo parado en la
; misma sala (ver on_room_entered/update_ghost) --
GHOST_W   = 5
GHOST_H   = 5
GHOST_HALF = 2
GHOST_BASE_SECONDS = 50   ; espera del fantasma: 50 s menos las llaves usadas
GHOST_FPS = 42            ; fotogramas por segundo, aprox.: 24 ms por vuelta
GHOST_NOTE_A = 74          ; "Re5"
GHOST_NOTE_B = 76          ; "Mi5"
GHOST_TONE_MAX = 20        ; fotogramas entre notas, lejos (~0.5 s)
GHOST_TONE_MIN = 3         ; fotogramas entre notas, pegado (trino rapido)
GHOST_MOVE_DELAY = 5       ; fotogramas por paso del fantasma (1 px por eje
                          ; cada GHOST_MOVE_DELAY fotogramas) -- a 1 por
                          ; fotograma era imposible escaparse
GHOST_DIST_CAP = 160       ; distancia Manhattan a partir de la cual el tono
                          ; ya no se hace mas lento

; --- salas persistentes / jefe final --------------------------------------
MAX_ROOMS       = 50      ; salas distintas que se pueden llegar a generar
                          ; (antes 24 "a secas"); persist_*/room_link se
                          ; dimensionan a partir de esta misma constante
BOSS_ROOM_NUM   = MAX_ROOMS-1  ; la ultima -- "nivel 50". Enlazada de forma
                          ; fija desde la sala PATH_ROOMS-1 (24) por
                          ; plan_dungeon -- ya no hace falta "saturar" nada,
                          ; las 50 salas se planifican todas de antemano.
PATH_ROOMS      = 25     ; salas 0..24: camino directo 0->1->...->24->jefe
LOCK_ZONE_START = 4       ; 0..3 nunca llevan candado (rodaje) -- CANDADOS
                          ; en la SALIDA de 4..23 (ver "LLAVES Y CANDADOS")
LOCK_ZONE_LEN   = 20      ; 4..23 -- la 24 (ultima del camino) queda lisa
EXTRA_ROOMS     = MAX_ROOMS - PATH_ROOMS - 1  ; 24: salas 25..48, ramales
                          ; colgando del camino (ver plan_dungeon)
KEYBRANCH_START = PATH_ROOMS               ; = 25: las salas extra 25..44 son
                          ; los ramales de llave, uno por candado: la 25+k
                          ; aloja la llave del candado LOCK_ZONE_START+k
KEYBRANCH_LEN   = LOCK_ZONE_LEN             ; = 20
; Las 4 salas extra restantes (45..48) cuelgan al azar, sin llave ni candado.
MIN_KEY_DIST    = 3       ; distancia Manhattan minima de la llave a la
                          ; entrada de su propia sala (ver gsc_key_roll)
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

; --- record en la EEPROM del slot (iomap.h, 0x0700-0x0801) -----------------
; byte 0 = REC_MAGIC si hay un record grabado (una flash sin estrenar se lee
; 0xFF -> record 0), bytes 1/2 = el record (16 bits, bajo/alto). Se graba SOLO al batirlo, al llegar
; al GAME OVER, para no gastar la flash en cada partida.
P_EEP_BASE = 0x0700
P_EEP_LOAD = 0x0800
P_EEP_SAVE = 0x0801
REC_MAGIC  = 0xC5

SHOT_SPEED   = 2       ; px por eje y fotograma (mas rapido que el jugador)
MAX_SHOTS    = 2

; ============================================================================
;  ARRANQUE + BUCLE PRINCIPAL
; ============================================================================
start:
    IN  AL,(P_DAT_POS)          ; siembra el LFSR con algo poco predecible
    ADD AL,#0x5D
    MOV [seed],AL
    JMPNZ init
    MOV AL,#0x5D
    MOV [seed],AL
init:
    IN  AL,(P_DIR_POS)
    MOV [dir_pos_prev],AL
    IN  AL,(P_DAT_POS)
    MOV [dat_pos_prev],AL
    IN  AL,(P_DAT_BTN)
    MOV [dat_btn_prev],AL
    CALL title_screen
    CALL clsg
    CALL clst
    CALL new_game

main_l:
    CALL update_player
    MOV AL,[room_transition_pending]
    CMP AL,#0
    JMPZ main_no_transition
    MOV AL,#0
    MOV [room_transition_pending],AL
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
    CALL update_ghost

main_draw:
    CALL draw_frame
    MOV AL,#3                  ; ritmo: 3*8 = 24 ms por fotograma
    CALL frame_wait
    JMP main_l

; ============================================================================
;  new_game:  reinicia puntuacion/vidas/sala, PLANIFICA las 50 salas enteras
;  de antemano (plan_dungeon) y las GENERA todas de un tiron -- antes de que
;  el jugador de un solo paso -- para que la topologia (y con ella, que
;  salas llevan llave o candado) quede fija desde el principio, nunca
;  decidida sala a sala segun se explora (ver la nota de cabecera "LLAVES Y
;  PUERTAS").
; ============================================================================
new_game:
    MOV AL,#0
    MOV [room_num],AL
    MOV [score_lo],AL
    MOV [score_hi],AL
    MOV [room_transition_pending],AL
    MOV [keys_held],AL
    MOV [keys_used],AL
    MOV [low_life_rooms],AL
    MOV AL,#MAX_LIVES
    MOV [lives],AL
    MOV AL,#0
    MOV [room0_entered],AL  ; ver la guarda de "centro de pantalla" en
                             ; place_player_spawn (cross_room_gap lo pone a 1
                             ; al salir de la sala 0 por primera vez)

    ; room_visited[] a 0 (para puntuar solo la primera vez que se cruza a
    ; cada sala, ver cross_room_gap) salvo la propia 0, que se marca ya
    ; visitada aqui mismo (cross_room_gap nunca se llama para llegar a ella,
    ; es el punto de partida).
    MOV AL,#0
    MOV [i],AL
ng_clr_l:
    MOV CL,[i]
    MOV BX,#room_visited
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#MAX_ROOMS
    JMPNZ ng_clr_l
    MOV BX,#room_visited
    MOV AL,#1
    MOV [BX],AL              ; room_visited[0] = 1 (indice 0 = la base misma)

    CALL plan_dungeon

    ; entrada de la sala 0: no existe de verdad (es el punto de partida) --
    ; se sortea solo para orientar su laberinto interno (gen_maze), nunca
    ; lleva candado (la zona de candados empieza en LOCK_ZONE_START=4).
    CALL rnd
    AND AL,#3
    MOV BX,#room_entry_side
    MOV [BX],AL

    ; genera las 50 salas de un tiron, en orden -- gen_and_save_current_room
    ; ya lee su propio entry_side de room_entry_side[] y decide llave/
    ; candado por su propio numero, sin necesitar nada de la sala anterior.
    MOV AL,#0
    MOV [room_num],AL
ng_gen_l:
    CALL gen_and_save_current_room
    MOV AL,[room_num]
    ADD AL,#1
    MOV [room_num],AL
    CMP AL,#MAX_ROOMS
    JMPNZ ng_gen_l

    ; el bucle deja room_num en MAX_ROOMS y las variables de trabajo con los
    ; datos de la ULTIMA sala generada (el jefe) -- se restaura la 0 para
    ; arrancar la partida de verdad ahi.
    MOV AL,#0
    MOV [room_num],AL
    CALL restore_room_state

    CALL draw_maze
    CALL place_player_spawn
    CALL setup_enemies
    CALL on_room_entered
    CALL update_score_hud
    CALL update_lives_hud
    CALL update_keys_hud
    RET

; ============================================================================
;  plan_dungeon: decide POR ADELANTADO la topologia completa de las 50 salas
;  (room_link[]/room_entry_side[]), antes de generar ninguna. Camino directo
;  0->1->2->...->24->49 (el jefe): entrada/salida de cada una elegidas al
;  azar entre las 4 direcciones, sin repetir lado dentro de la misma sala.
;  Las salas 25..48 ("extra") cuelgan cada una de UNA sala del camino
;  (0..24): las 25..44 son los ramales de llave (cada uno cuelga de la sala
;  de su candado o de una anterior, ver MAX_KEY_OFFSET) y las 45..48 cuelgan
;  de una sala elegida al azar. Que sala lleva llave o candado NO se decide
;  aqui: gen_and_save_current_room lo deduce del propio numero de sala, ver
;  su comentario y la nota de cabecera "LLAVES Y CANDADOS".
; ============================================================================
plan_dungeon:
    ; room_link[] entero a 254 ("lado libre, todavia sin decidir") -- es
    ; solo una marca DURANTE esta planificacion; al terminar, cualquier lado
    ; que se quede en 254 sigue significando "pared cerrada, no hay sala
    ; ahi" para gen_and_save_current_room, exactamente igual que antes.
    MOV AL,#0
    MOV [i],AL
pd_clear_l:
    MOV CL,[i]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,#254
    MOV [BX],AL
    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#200
    JMPNZ pd_clear_l

    ; --- camino directo: 0->1->2->...->24->49(jefe) -------------------------
    MOV AL,#0
    MOV [pd_i],AL
pd_path_l:
    ; lado de SALIDA de la sala pd_i hacia la siguiente -- al azar, pero
    ; nunca el mismo que su propio lado de ENTRADA (ya fijado en
    ; room_entry_side[pd_i] por la vuelta anterior de este mismo bucle,
    ; salvo la primerisima vuelta, pd_i=0, que todavia no tiene entrada real
    ; -- new_game la fija aparte DESPUES de llamar aqui, asi que cualquier
    ; lado vale para su salida sin comprobar nada).
pd_pick_side:
    CALL rnd
    AND AL,#3
    MOV [pd_side],AL
    MOV AL,[pd_i]
    CMP AL,#0
    JMPZ pd_side_ok
    MOV CL,[pd_i]
    MOV BX,#room_entry_side
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[pd_side]
    CMP AL,BL
    JMPZ pd_pick_side          ; coincide con la entrada -- vuelve a tirar
pd_side_ok:

    ; vecino: pd_i+1, o el jefe si pd_i es la ultima del camino
    MOV AL,[pd_i]
    CMP AL,#(PATH_ROOMS-1)
    JMPNZ pd_next_is_room
    MOV AL,#BOSS_ROOM_NUM
    JMP pd_have_next
pd_next_is_room:
    MOV AL,[pd_i]
    ADD AL,#1
pd_have_next:
    MOV [pd_nxt],AL

    ; enlaza pd_i --pd_side--> pd_nxt
    MOV AL,[pd_i]
    SHL AL,#2
    MOV BL,[pd_side]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[pd_nxt]
    MOV [BX],AL

    ; el vecino entra por el lado opuesto -- fija su room_entry_side y el
    ; enlace de vuelta pd_nxt --tmp3--> pd_i
    MOV CL,[pd_side]
    MOV BX,#OPP_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp3],AL

    MOV CL,[pd_nxt]
    MOV BX,#room_entry_side
    ADD BX,CL
    MOV AL,[tmp3]
    MOV [BX],AL

    MOV AL,[pd_nxt]
    SHL AL,#2
    MOV BL,[tmp3]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[pd_i]
    MOV [BX],AL

    MOV AL,[pd_i]
    ADD AL,#1
    MOV [pd_i],AL
    CMP AL,#PATH_ROOMS
    JMPNZ pd_path_l

    ; --- salas extra 25..48: cada una cuelga de una sala del camino ---------
    MOV AL,#PATH_ROOMS
    MOV [pd_i],AL
pd_extra_l:
    ; Las salas 25..44 NO cuelgan al azar: la 25+k es el ramal de la llave del
    ; candado LOCK_ZONE_START+k, y cuelga de esa sala o de una ANTERIOR del
    ; camino (hasta MAX_KEY_OFFSET[k] salas por delante; 0 en los primeros
    ; candados, hasta 3 en los mas avanzados). Si la sala candidata no tiene
    ; lado libre se prueba con un desplazamiento menor: con d=0 SIEMPRE hay
    ; hueco (ningun ramal anterior puede haber usado esa sala, porque su
    ; candidata LOCK_ZONE_START+k'-d' es siempre < LOCK_ZONE_START+k), asi que
    ; esto termina siempre y nunca deja una llave sin colocar.
    MOV AL,[pd_i]
    CMP AL,#(KEYBRANCH_START+KEYBRANCH_LEN)
    JMPNC pd_extra_random

    MOV AL,[pd_i]
    SUB AL,#KEYBRANCH_START
    MOV [pd_k],AL
    MOV BX,#MAX_KEY_OFFSET
    MOV CL,[pd_k]
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ pd_d_zero
    ADD AL,#1
    MOV [pd_dmod],AL
pd_d_roll:
    CALL rnd
    AND AL,#3
    MOV BL,[pd_dmod]
    CMP AL,BL
    JMPNC pd_d_roll              ; AL >= max+1 -- reintenta
    MOV [pd_d],AL
    JMP pd_d_try
pd_d_zero:
    MOV AL,#0
    MOV [pd_d],AL
pd_d_try:
    MOV AL,[pd_k]
    ADD AL,#LOCK_ZONE_START
    MOV BL,[pd_d]
    SUB AL,BL
    MOV [pd_room],AL             ; candidata = LOCK_ZONE_START + k - d
    MOV AL,#0
    MOV [pd_side],AL
pd_forced_scan_s:
    MOV AL,[pd_room]
    SHL AL,#2
    MOV BL,[pd_side]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#254
    JMPZ pd_extra_have_slot
    MOV AL,[pd_side]
    ADD AL,#1
    MOV [pd_side],AL
    CMP AL,#4
    JMPNZ pd_forced_scan_s
    MOV AL,[pd_d]                ; sin hueco aqui -- desplazamiento menor
    CMP AL,#0
    JMPZ pd_extra_next           ; (no deberia pasar nunca con d=0)
    SUB AL,#1
    MOV [pd_d],AL
    JMP pd_d_try

pd_extra_random:
    MOV AL,#0
    MOV [pd_tries],AL
pd_extra_pick:
    ; sala candidata del camino, 0..24 -- descarte-y-repite de siempre
    ; (PATH_ROOMS=25 no es potencia de 2)
    CALL rnd
    AND AL,#31
    CMP AL,#PATH_ROOMS
    JMPNC pd_extra_pick
    MOV [pd_room],AL
    CALL rnd
    AND AL,#3
    MOV [pd_side],AL

    MOV AL,[pd_room]
    SHL AL,#2
    MOV BL,[pd_side]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#254
    JMPZ pd_extra_have_slot    ; libre -- se usa

    ; ocupado -- reintenta con tope de seguridad (25 salas de camino, hasta
    ; 3 lados libres cada una, dan de sobra para 24 extras: esto no deberia
    ; llegar a hacer falta nunca, pero un barrido determinista de repuesto
    ; evita colgarse para siempre si la mala suerte del azar lo agotara)
    MOV AL,[pd_tries]
    ADD AL,#1
    MOV [pd_tries],AL
    CMP AL,#100
    JMPNZ pd_extra_pick

pd_extra_scan_r:
    MOV AL,#0
    MOV [pd_room],AL
pd_extra_scan_r_l:
    MOV AL,#0
    MOV [pd_side],AL
pd_extra_scan_s_l:
    MOV AL,[pd_room]
    SHL AL,#2
    MOV BL,[pd_side]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#254
    JMPZ pd_extra_have_slot
    MOV AL,[pd_side]
    ADD AL,#1
    MOV [pd_side],AL
    CMP AL,#4
    JMPNZ pd_extra_scan_s_l
    MOV AL,[pd_room]
    ADD AL,#1
    MOV [pd_room],AL
    CMP AL,#PATH_ROOMS
    JMPNZ pd_extra_scan_r_l
    JMP pd_extra_next          ; inalcanzable en la practica -- ver la nota de arriba

pd_extra_have_slot:
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[pd_i]
    MOV [BX],AL

    MOV CL,[pd_side]
    MOV BX,#OPP_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp3],AL              ; tmp3 = lado de entrada de la sala extra

    MOV CL,[pd_i]
    MOV BX,#room_entry_side
    ADD BX,CL
    MOV AL,[tmp3]
    MOV [BX],AL

    MOV AL,[pd_i]
    SHL AL,#2
    MOV BL,[tmp3]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[pd_room]
    MOV [BX],AL

pd_extra_next:
    MOV AL,[pd_i]
    ADD AL,#1
    MOV [pd_i],AL
    CMP AL,#BOSS_ROOM_NUM     ; 25..48 son las EXTRA_ROOMS(24) -- la 49 es el
                              ; jefe, ya enlazada aparte desde la 24, nunca
                              ; una "extra" mas (si el bucle llegara hasta
                              ; incluirla, se le daria un segundo enlace al
                              ; azar, dejando el jefe con dos entradas)
    JMPNZ pd_extra_l
    RET

; ============================================================================
;  cross_room_gap:  [exit_dir_taken] indica el lado por el que se acaba de
;  cruzar. Con las 50 salas planificadas y generadas de antemano
;  (plan_dungeon/new_game), room_link[sala*4+lado] YA tiene siempre la sala
;  real al otro lado -- esta rutina solo restaura esa sala (nunca hace falta
;  generar nada aqui) y puntua la primera vez que se entra a cada una
;  (room_visited[], ver new_game).
; ============================================================================
cross_room_gap:
    MOV AL,[room_num]
    SHL AL,#2
    MOV BL,[exit_dir_taken]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp0],AL             ; tmp0 = sala destino (siempre real)

    MOV CL,[exit_dir_taken]
    MOV BX,#OPP_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [entry_side],AL       ; lado de entrada en la sala destino: SIEMPRE el
                               ; opuesto del lado por el que se acaba de salir,
                               ; no el room_entry_side[] fijo de plan_dungeon
                               ; (que solo describe la arista del camino: al
                               ; volver de un ramal, el jugador aparecia en el
                               ; lado contrario de la sala -- bug real reportado)

    ; si se esta CRUZANDO fuera de la sala 0, marca que ya se ha dejado
    ; atras al menos una vez -- a partir de ahora, cualquier vuelta a la
    ; sala 0 tiene un lado de entrada real que respetar (ver la guarda de
    ; place_player_spawn); antes de esto, todavia no hay "de donde viene".
    MOV AL,[room_num]
    CMP AL,#0
    JMPNZ crg_not_leaving_room0
    MOV AL,#1
    MOV [room0_entered],AL
crg_not_leaving_room0:

    ; puntua solo la primera vez que se entra a la sala destino
    MOV CL,[tmp0]
    MOV BX,#room_visited
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPNZ crg_no_score
    MOV AL,#1
    MOV [BX],AL
    MOV AL,#10
    CALL score_add
    CALL update_score_hud
    MOV BX,#JINGLE_TUNE
    CALL play_tune
crg_no_score:

    MOV AL,[tmp0]
    MOV [room_num],AL
    CALL restore_room_state

    CALL draw_maze
    CALL place_player_spawn
    CALL setup_enemies
    CALL on_room_entered
    RET

; ============================================================================
;  on_room_entered: corre en CADA entrada real a una sala (desde new_game,
;  para la sala 0, y al final de cross_room_gap para cualquier otra):
;    - reinicia el contador de fotogramas de la sala a 0 y calcula el umbral
;      (segundos_permitidos * GHOST_FPS, con segundos_permitidos =
;      GHOST_BASE_SECONDS(50) - keys_used: llaves gastadas en candados en la
;      partida, de 0 a 20, asi que la espera baja de 50 s a 30 s segun se
;      avanza). Antes dependia de room_num, pero los ramales (25..48) no
;      siguen el orden de avance y el fantasma salia muy pronto en ramales
;      del principio -- pedido real.
;      Guarda donde esta el jugador ahora mismo (ghost_origin_x/y): si el
;      fantasma aparece mas tarde, lo hace ahi. La sala del jefe nunca tiene
;      fantasma (umbral 0xFFFF, "infinito").
; ============================================================================
on_room_entered:
    MOV AL,#0
    MOV [room_timer_lo],AL
    MOV [room_timer_hi],AL
    MOV [ghost_active],AL
    OUT (P_SND_NOTE),AL          ; por si sonaba el tono del fantasma al salir

    MOV AL,[player_x]
    MOV [ghost_origin_x],AL
    MOV AL,[player_y]
    MOV [ghost_origin_y],AL

    MOV AL,[room_num]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ ore_ghost_calc
    MOV AL,#0xFF
    MOV [ghost_threshold_lo],AL
    MOV [ghost_threshold_hi],AL
    RET
ore_ghost_calc:
    MOV AL,#GHOST_BASE_SECONDS
    MOV BL,[keys_used]
    SUB AL,BL                    ; AL = segundos permitidos (50 - llaves usadas)
    MOV BL,#GHOST_FPS
    MUL BL                       ; AX = segundos * GHOST_FPS
    MOV [ghost_threshold_lo],AL
    MOV AL,AH
    MOV [ghost_threshold_hi],AL
    RET

; ============================================================================
;  update_ghost: cuenta fotogramas en la sala actual; al superar el umbral
;  activa el fantasma en ghost_origin_x/y. Activo, persigue al jugador en
;  linea recta UN PIXEL POR EJE CADA GHOST_MOVE_DELAY FOTOGRAMAS, sin mirar cell_walls (atraviesa
;  paredes a proposito), y si toca al jugador lo mata igual que un enemigo
;  (on_player_hit). Tras matar se desvanece y el contador vuelve a 0, para
;  no encadenar muertes en el mismo sitio. Suena Re-Mi-Re-Mi en bucle,
;  mas rapido cuanto mas cerca este (distancia Manhattan, escalada con MUL/DIV).
; ============================================================================
update_ghost:
    MOV AL,[room_timer_lo]
    ADD AL,#1
    MOV [room_timer_lo],AL
    JMPNC ug_no_carry
    MOV AL,[room_timer_hi]
    ADD AL,#1
    MOV [room_timer_hi],AL
ug_no_carry:

    MOV AL,[ghost_active]
    CMP AL,#0
    JMPNZ ug_move

    ; ¿se ha superado el umbral? comparacion de 16 bits (alto primero, bajo
    ; solo si empata)
    MOV AL,[room_timer_hi]
    MOV BL,[ghost_threshold_hi]
    CMP AL,BL
    JMPC ug_ret                 ; timer_hi < threshold_hi -- todavia no
    JMPNZ ug_activate           ; timer_hi > threshold_hi -- ya se paso
    MOV AL,[room_timer_lo]
    MOV BL,[ghost_threshold_lo]
    CMP AL,BL
    JMPC ug_ret                 ; timer_lo < threshold_lo -- todavia no

ug_activate:
    MOV AL,#1
    MOV [ghost_active],AL
    MOV AL,[ghost_origin_x]
    MOV [ghost_x],AL
    MOV AL,[ghost_origin_y]
    MOV [ghost_y],AL
    MOV AL,#GHOST_TONE_MAX
    MOV [ghost_tone_timer],AL
    MOV AL,#0
    MOV [ghost_tone_phase],AL
    MOV [ghost_move_cnt],AL
    RET

ug_move:
    ; solo avanza 1 de cada GHOST_MOVE_DELAY fotogramas (el choque y el
    ; sonido se siguen comprobando todos)
    MOV AL,[ghost_move_cnt]
    CMP AL,#0
    JMPZ ug_step
    SUB AL,#1
    MOV [ghost_move_cnt],AL
    JMP ug_y_done
ug_step:
    MOV AL,#(GHOST_MOVE_DELAY-1)
    MOV [ghost_move_cnt],AL
    MOV AL,[ghost_x]
    MOV BL,[player_x]
    CMP AL,BL
    JMPZ ug_x_done
    JMPC ug_x_inc
    SUB AL,#1
    JMP ug_x_store
ug_x_inc:
    ADD AL,#1
ug_x_store:
    MOV [ghost_x],AL
ug_x_done:

    MOV AL,[ghost_y]
    MOV BL,[player_y]
    CMP AL,BL
    JMPZ ug_y_done
    JMPC ug_y_inc
    SUB AL,#1
    JMP ug_y_store
ug_y_inc:
    ADD AL,#1
ug_y_store:
    MOV [ghost_y],AL
ug_y_done:

    ; choque con el jugador -- mismo criterio de cajas que check_collisions
    MOV AL,[ghost_x]
    SUB AL,#GHOST_HALF
    MOV [ex],AL
    MOV AL,[ghost_y]
    SUB AL,#GHOST_HALF
    MOV [ey],AL

    MOV AL,[ex]
    ADD AL,#GHOST_W
    MOV BL,[player_x]
    CMP BL,AL
    JMPNC ug_tone
    MOV AL,[player_x]
    ADD AL,#PLAYER_W
    MOV BL,[ex]
    CMP BL,AL
    JMPNC ug_tone
    MOV AL,[ey]
    ADD AL,#GHOST_H
    MOV BL,[player_y]
    CMP BL,AL
    JMPNC ug_tone
    MOV AL,[player_y]
    ADD AL,#PLAYER_H
    MOV BL,[ey]
    CMP BL,AL
    JMPNC ug_tone

    MOV AL,#0
    OUT (P_SND_NOTE),AL
    MOV [ghost_active],AL
    MOV [room_timer_lo],AL
    MOV [room_timer_hi],AL
    CALL on_player_hit
    RET

ug_tone:
    MOV AL,[ghost_tone_timer]
    CMP AL,#0
    JMPZ ug_tone_toggle
    SUB AL,#1
    MOV [ghost_tone_timer],AL
    RET

ug_tone_toggle:
    MOV AL,[ghost_x]
    MOV BL,[player_x]
    SUB AL,BL
    JMPN ugt_xneg
    JMP ugt_xdone
ugt_xneg:
    NOT AL
    ADD AL,#1
ugt_xdone:
    MOV [tmp1],AL

    MOV AL,[ghost_y]
    MOV BL,[player_y]
    SUB AL,BL
    JMPN ugt_yneg
    JMP ugt_ydone
ugt_yneg:
    NOT AL
    ADD AL,#1
ugt_ydone:
    MOV BL,[tmp1]
    ADD AL,BL                    ; distancia Manhattan (nunca pasa de 255)
    CMP AL,#GHOST_DIST_CAP
    JMPC ugt_dist_capped
    MOV AL,#GHOST_DIST_CAP
ugt_dist_capped:
    MOV BL,#(GHOST_TONE_MAX-GHOST_TONE_MIN)
    MUL BL                       ; AX = distancia_limitada * rango
    MOV BL,#GHOST_DIST_CAP
    DIV BL                       ; AL = AX / GHOST_DIST_CAP (0..rango)
    ADD AL,#GHOST_TONE_MIN       ; periodo final (MIN..MAX fotogramas/nota)
    MOV [ghost_tone_timer],AL

    MOV AL,[ghost_tone_phase]
    CMP AL,#0
    JMPNZ ugt_mi
    MOV AL,#GHOST_NOTE_A
    OUT (P_SND_NOTE),AL
    MOV AL,#1
    MOV [ghost_tone_phase],AL
    RET
ugt_mi:
    MOV AL,#GHOST_NOTE_B
    OUT (P_SND_NOTE),AL
    MOV AL,#0
    MOV [ghost_tone_phase],AL
ug_ret:
    RET

; ============================================================================
;  gen_and_save_current_room: genera la sala [room_num] ENTERA, siguiendo la
;  topologia ya decidida por plan_dungeon (room_link[]/room_entry_side[]) --
;  aqui no se sortea NINGUNA conexion. Por cada uno de los 4 lados, si
;  room_link[room_num*4+lado] apunta a una sala real (no 254), se abre ese
;  hueco -- EXCEPTO si room_num esta en la ZONA DE CANDADOS (4..23) y el
;  lado es la SALIDA hacia room_num+1, en cuyo caso sale con CANDADO (linea
;  sencilla, cell_walls cerrado hasta abrirse con una llave, ver
;  door_check). Los ramales de llave (25..44) alojan una llave, lejos de su
;  entrada -- 20 llaves y 20 candados en total, garantizado por construccion
;  (ver la nota de cabecera "LLAVES Y CANDADOS"). Guarda
;  todo en persist_*[room_num]; no puntua nunca (eso es cosa de
;  cross_room_gap, solo al CRUZAR, nunca al generar).
; ============================================================================
gen_and_save_current_room:
    MOV CL,[room_num]
    MOV BX,#room_entry_side
    ADD BX,CL
    MOV AL,[BX]
    MOV [entry_side],AL

    MOV AL,#255
    MOV [door_dir],AL        ; sin candado todavia en esta sala
    MOV AL,#255
    MOV [key_cell],AL        ; sin llave propia todavia
    MOV AL,#0
    MOV [key_taken],AL

    MOV AL,[entry_side]
    CALL side_to_rc
    MOV AL,[rc_row]
    MOV [entry_row],AL
    MOV AL,[rc_col]
    MOV [entry_col],AL

    CALL gen_maze

    ; --- los 4 lados, uno a uno: abre, o candado si toca -------------------
    MOV AL,#0
    MOV [d],AL
gsc_side_l:
    MOV AL,[room_num]
    SHL AL,#2
    MOV BL,[d]
    ADD AL,BL
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#room_link
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#254
    JMPZ gsc_side_next          ; nada por este lado -- pared, no hace falta nada
    MOV [tmp4],AL               ; tmp4 = sala vecina por este lado

    ; candado SOLO en la ZONA DE CANDADOS (4..23) y en la SALIDA hacia la sala
    ; siguiente del camino (room_num+1) -- NUNCA en la entrada: cruzar de sala
    ; es un teletransporte al punto de aparicion, a menos de DOOR_OPEN_DIST
    ; del punto medio de la entrada, asi que un candado ahi se abria solo e
    ; invisible al aparecer con una llave encima (bug real reportado, "se han
    ; perdido las puertas; las llaves se pierden al cruzar").
    MOV AL,[room_num]
    CMP AL,#LOCK_ZONE_START
    JMPC gsc_side_open
    MOV AL,[room_num]
    CMP AL,#(LOCK_ZONE_START+LOCK_ZONE_LEN)
    JMPNC gsc_side_open
    MOV AL,[tmp4]
    MOV BL,[room_num]
    ADD BL,#1
    CMP AL,BL
    JMPNZ gsc_side_open         ; no es la salida hacia la siguiente

    ; --- candado en la salida -----------------------------------------------
    MOV AL,[d]
    MOV [door_dir],AL
    CALL side_to_rc              ; AL=[d] -> rc_row/rc_col
    MOV CL,[rc_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[rc_col]
    ADD AL,BL
    MOV [door_cell],AL

    MOV CL,[d]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp3],AL

    MOV CL,[door_cell]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[tmp3]
    MOV [BX],AL                 ; marca la puerta (linea sencilla)
    ; cell_walls se deja CERRADO aqui (nunca se llama a open_dir para este
    ; lado) -- door_check lo abrira al usar una llave.
    JMP gsc_side_next

gsc_side_open:
    MOV AL,[d]
    CALL side_to_rc
    MOV CL,[rc_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[rc_col]
    ADD AL,BL
    MOV [od_cell],AL
    MOV AL,[d]
    MOV [od_dir],AL
    CALL open_dir

gsc_side_next:
    MOV AL,[d]
    ADD AL,#1
    MOV [d],AL
    CMP AL,#4
    JMPNZ gsc_side_l

    ; --- llave: solo en los ramales 25..44 (ver plan_dungeon), en una celda
    ; al azar a distancia Manhattan >= MIN_KEY_DIST de la entrada de la sala
    ; (nunca pegada a la puerta por la que se entra). Si tras 20 intentos no
    ; sale ninguna (no deberia: en 3x6 la mas lejana esta a 7), vale la ultima.
    MOV AL,[room_num]
    CMP AL,#KEYBRANCH_START
    JMPC gsc_no_key
    MOV AL,[room_num]
    CMP AL,#(KEYBRANCH_START+KEYBRANCH_LEN)
    JMPNC gsc_no_key
gsc_key_roll:
    CALL rnd
    AND AL,#31
    CMP AL,#NCELLS
    JMPNC gsc_key_roll
    MOV [tmp5],AL
    MOV CL,[tmp5]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[entry_row]
    SUB AL,BL
    JMPN gkd_row_neg
    JMP gkd_row_abs
gkd_row_neg:
    NOT AL
    ADD AL,#1
gkd_row_abs:
    MOV [tmp6],AL
    MOV CL,[tmp5]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[entry_col]
    SUB AL,BL
    JMPN gkd_col_neg
    JMP gkd_col_abs
gkd_col_neg:
    NOT AL
    ADD AL,#1
gkd_col_abs:
    MOV BL,[tmp6]
    ADD AL,BL
    CMP AL,#MIN_KEY_DIST
    JMPNC gsc_key_have
    MOV AL,[key_retry]
    ADD AL,#1
    MOV [key_retry],AL
    CMP AL,#20
    JMPNZ gsc_key_roll
gsc_key_have:
    MOV AL,#0
    MOV [key_retry],AL
    MOV AL,[tmp5]
    MOV [key_cell],AL
    MOV AL,#0
    MOV [key_taken],AL
gsc_no_key:

    ; --- corazon de repuesto: de vez en cuando (mas a menudo si esta sala
    ; ya tiene enemigos, es decir es "dificil" -- las dos primeras nunca los
    ; tienen), o siempre si el jugador lleva 3 salas nuevas seguidas con una
    ; sola vida; nunca si ya esta a vidas maximas (no serviria de nada).
    ; Sin cambios respecto a antes -- ortogonal al esquema de llave/candado.
    MOV AL,[lives]
    CMP AL,#1
    JMPNZ gsc_life_reset
    MOV AL,[low_life_rooms]
    ADD AL,#1
    MOV [low_life_rooms],AL
    JMP gsc_life_done
gsc_life_reset:
    MOV AL,#0
    MOV [low_life_rooms],AL
gsc_life_done:

    MOV AL,[lives]
    CMP AL,#MAX_LIVES
    JMPNC gsc_no_heart        ; ya a tope -- no coloca corazon

    MOV AL,[low_life_rooms]
    CMP AL,#3
    JMPNC gsc_heart_yes       ; 3 salas nuevas seguidas a 1 vida -- lo fuerza

    MOV AL,[room_num]
    CMP AL,#2
    JMPC gsc_heart_easy       ; room_num<2: todavia sin enemigos
    MOV AL,#3                 ; sala "dificil": 1 de cada 4
    JMP gsc_heart_mask
gsc_heart_easy:
    MOV AL,#7                 ; sala facil: 1 de cada 8
gsc_heart_mask:
    MOV [tmp1],AL
    CALL rnd
    MOV BL,[tmp1]
    AND AL,BL
    CMP AL,#0
    JMPNZ gsc_no_heart

gsc_heart_yes:
    MOV AL,#0
    MOV [low_life_rooms],AL
    ; celda al azar, distinta de la de la llave (para no amontonar las dos
    ; en el mismo sitio); mismo descarte-y-repite que key_cell, NCELLS(18)
    ; no es potencia de 2
gsc_heart_roll:
    CALL rnd
    AND AL,#31
    CMP AL,#NCELLS
    JMPNC gsc_heart_roll
    MOV BL,[key_cell]
    CMP AL,BL
    JMPZ gsc_heart_roll
    MOV [heart_cell],AL
    MOV AL,#0
    MOV [heart_taken],AL
    JMP gsc_heart_done
gsc_no_heart:
    MOV AL,#255
    MOV [heart_cell],AL       ; celda imposible -- nunca coincide
    MOV AL,#0
    MOV [heart_taken],AL
gsc_heart_done:

    CALL save_room_state
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
    MOV [rc_row],AL
    MOV AL,#3
    MOV [rc_col],AL
    RET
s2rc_e:
    CMP AL,#DIR_E
    JMPNZ s2rc_s
    MOV AL,#1
    MOV [rc_row],AL
    MOV AL,#(MAZE_COLS-1)
    MOV [rc_col],AL
    RET
s2rc_s:
    CMP AL,#DIR_S
    JMPNZ s2rc_w
    MOV AL,#(MAZE_ROWS-1)
    MOV [rc_row],AL
    MOV AL,#3
    MOV [rc_col],AL
    RET
s2rc_w:
    MOV AL,#1
    MOV [rc_row],AL
    MOV AL,#0
    MOV [rc_col],AL
    RET

; --- place_player_spawn: coloca (player_x,player_y) justo dentro del hueco
; de entrada -- como entrada/salida estan siempre en el mismo sitio fijo de
; su lado (side_to_rc), las coordenadas de aparicion tambien lo estan.
place_player_spawn:
    MOV AL,#DIR_S
    MOV [last_fire_dir],AL   ; mirando "hacia abajo" por defecto al aparecer
    MOV AL,#0
    MOV [i],AL
pps_clr_shots:
    MOV CL,[i]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#MAX_SHOTS
    JMPNZ pps_clr_shots

    MOV AL,#0
    MOV [walk_phase],AL      ; que no aparezca con un pie ya levantado
    MOV [walk_timer],AL
    MOV [walk_idle],AL

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
    MOV AL,[room_num]
    CMP AL,#0
    JMPNZ pps_not_room0
    MOV AL,[room0_entered]
    CMP AL,#0
    JMPNZ pps_not_room0      ; ya se ha DEJADO la sala 0 alguna vez (marcado
                             ; por cross_room_gap al salir, no aqui) -- como
                             ; cualquier sala
    MOV AL,#(3*CELL_W+5)
    MOV [player_x],AL
    MOV AL,#(1*CELL_H+5)
    MOV [player_y],AL
    RET
pps_not_room0:

    ; posiciones para la rejilla de 6x3 celdas de 21x21: columna/fila
    ; central (side_to_rc) mas un margen de seguridad de ~5-8 px hacia
    ; dentro, lejos de cualquier borde de celda
    MOV AL,[entry_side]
    CMP AL,#DIR_N
    JMPNZ pps_e
    MOV AL,#(3*CELL_W+8)
    MOV [player_x],AL
    MOV AL,#5
    MOV [player_y],AL
    RET
pps_e:
    CMP AL,#DIR_E
    JMPNZ pps_s
    MOV AL,#(MAZE_COLS*CELL_W-PLAYER_W-5)
    MOV [player_x],AL
    MOV AL,#(1*CELL_H+7)
    MOV [player_y],AL
    RET
pps_s:
    CMP AL,#DIR_S
    JMPNZ pps_w
    MOV AL,#(3*CELL_W+8)
    MOV [player_x],AL
    MOV AL,#(MAZE_ROWS*CELL_H-PLAYER_H-5)
    MOV [player_y],AL
    RET
pps_w:
    MOV AL,#5
    MOV [player_x],AL
    MOV AL,#(1*CELL_H+7)
    MOV [player_y],AL
    RET

; --- open_dir: pone a 1 (abierto) el bit de direccion [od_dir] en
; cell_walls[[od_cell]] -- usado por new_room para forzar el hueco de
; entrada/salida en el borde de la pantalla.
open_dir:
    MOV CL,[od_dir]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL

    MOV CL,[od_cell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV DL,[tmp1]
    OR  AL,DL
    MOV [BX],AL
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
    MOV [ro_lo],AL
    MOV AL,BH
    MOV [ro_hi],AL

    MOV CL,[room_num]
    MOV BX,#ROOM_OFF_LO
    ADD BX,CL
    MOV AL,[BX]
    MOV [ro_off],AL
    MOV CL,[room_num]
    MOV BX,#ROOM_OFF_HI
    ADD BX,CL
    MOV AL,[BX]
    MOV [ro_offhi],AL

    MOV BL,[ro_lo]
    MOV BH,[ro_hi]
    MOV AL,[ro_off]
    ADD BX,AL
    MOV AL,[ro_offhi]
    ADD BH,AL
    RET

; --- save_room_state / restore_room_state: copian cell_walls/door_bits (32
; bytes cada uno) y los campos sueltos de la sala actual (key_taken/
; key_cell/door_cell/door_dir) hacia/desde persist_*[room_num]. room_link NO
; se toca aqui -- vive en su propio array indexado por sala*4+lado y se lee/
; escribe directamente donde hace falta (cross_room_gap/gen_and_save).
save_room_state:
    MOV AL,#0
    MOV [i],AL
srs_l:
    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV BX,#persist_walls
    CALL room_off
    MOV CL,[i]
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL

    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV BX,#persist_doors
    CALL room_off
    MOV CL,[i]
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL

    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#NCELLS
    JMPNZ srs_l

    MOV CL,[room_num]
    MOV BX,#persist_key_taken
    ADD BX,CL
    MOV AL,[key_taken]
    MOV [BX],AL

    MOV CL,[room_num]
    MOV BX,#persist_key_cell
    ADD BX,CL
    MOV AL,[key_cell]
    MOV [BX],AL

    MOV CL,[room_num]
    MOV BX,#persist_door_cell
    ADD BX,CL
    MOV AL,[door_cell]
    MOV [BX],AL

    MOV CL,[room_num]
    MOV BX,#persist_door_dir
    ADD BX,CL
    MOV AL,[door_dir]
    MOV [BX],AL

    MOV CL,[room_num]
    MOV BX,#persist_heart_taken
    ADD BX,CL
    MOV AL,[heart_taken]
    MOV [BX],AL

    MOV CL,[room_num]
    MOV BX,#persist_heart_cell
    ADD BX,CL
    MOV AL,[heart_cell]
    MOV [BX],AL
    RET

restore_room_state:
    MOV AL,#0
    MOV [i],AL
rrs_l:
    MOV BX,#persist_walls
    CALL room_off
    MOV CL,[i]
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL

    MOV BX,#persist_doors
    CALL room_off
    MOV CL,[i]
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL

    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#NCELLS
    JMPNZ rrs_l

    MOV CL,[room_num]
    MOV BX,#persist_key_taken
    ADD BX,CL
    MOV AL,[BX]
    MOV [key_taken],AL

    MOV CL,[room_num]
    MOV BX,#persist_key_cell
    ADD BX,CL
    MOV AL,[BX]
    MOV [key_cell],AL

    MOV CL,[room_num]
    MOV BX,#persist_door_cell
    ADD BX,CL
    MOV AL,[BX]
    MOV [door_cell],AL

    MOV CL,[room_num]
    MOV BX,#persist_door_dir
    ADD BX,CL
    MOV AL,[BX]
    MOV [door_dir],AL

    MOV CL,[room_num]
    MOV BX,#persist_heart_taken
    ADD BX,CL
    MOV AL,[BX]
    MOV [heart_taken],AL

    MOV CL,[room_num]
    MOV BX,#persist_heart_cell
    ADD BX,CL
    MOV AL,[BX]
    MOV [heart_cell],AL
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
    MOV [i],AL
gm_clr_l:
    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV CL,[i]
    MOV BX,#visited
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#NCELLS
    JMPNZ gm_clr_l

    MOV CL,[entry_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[entry_col]
    ADD AL,BL
    MOV [cur_cell],AL
    MOV CL,[cur_cell]
    MOV BX,#visited
    ADD BX,CL
    MOV AL,#1
    MOV [BX],AL
    MOV AL,#0
    MOV [stack_depth],AL

gm_loop:
    MOV CL,[cur_cell]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV [cur_row],AL
    MOV CL,[cur_cell]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV [cur_col],AL

    CALL rnd
    AND AL,#3
    MOV [start_dir],AL
    MOV AL,#0
    MOV [k],AL
    MOV AL,#0
    MOV [found],AL

gm_scan_l:
    MOV AL,[start_dir]
    MOV BL,[k]
    ADD AL,BL
    AND AL,#3
    MOV [d],AL

    MOV CL,[d]
    MOV BX,#DR_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cur_row]
    ADD AL,BL
    MOV [mz_row],AL

    MOV CL,[d]
    MOV BX,#DC_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cur_col]
    ADD AL,BL
    MOV [mz_col],AL

    MOV AL,[mz_row]
    CMP AL,#MAZE_ROWS
    JMPNC gm_scan_next
    MOV AL,[mz_col]
    CMP AL,#MAZE_COLS
    JMPNC gm_scan_next

    MOV CL,[mz_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[mz_col]
    ADD AL,BL
    MOV [try_cell],AL

    MOV CL,[try_cell]
    MOV BX,#visited
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPNZ gm_scan_next

    ; abre cur->d y try->opuesta(d)
    MOV CL,[d]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[cur_cell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV DL,[tmp1]
    OR  AL,DL
    MOV [BX],AL

    MOV CL,[d]
    MOV BX,#OPP_OF_DIR
    ADD BX,CL
    MOV CL,[BX]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[try_cell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV DL,[tmp1]
    OR  AL,DL
    MOV [BX],AL

    MOV CL,[try_cell]
    MOV BX,#visited
    ADD BX,CL
    MOV AL,#1
    MOV [BX],AL

    MOV AL,[cur_cell]
    PUSH AL
    MOV AL,[stack_depth]
    ADD AL,#1
    MOV [stack_depth],AL
    MOV AL,[try_cell]
    MOV [cur_cell],AL

    MOV AL,#1
    MOV [found],AL
    JMP gm_after_scan

gm_scan_next:
    MOV AL,[k]
    ADD AL,#1
    MOV [k],AL
    CMP AL,#4
    JMPNZ gm_scan_l

gm_after_scan:
    MOV AL,[found]
    CMP AL,#0
    JMPNZ gm_loop

    ; sin vecina sin visitar: retrocede, o termina si ya no queda camino
    ; que deshacer (stack_depth==0) -- IMPORTANTE: esto DEBE quedar en 0
    ; antes del RET, porque estos PUSH comparten la misma pila que usan
    ; CALL/RET; terminar con alguno sin sacar dejaria un byte de mas ahi
    ; y el siguiente RET saltaria a basura en vez de volver bien.
    MOV AL,[stack_depth]
    CMP AL,#0
    JMPZ gm_done
    POP AL
    MOV [cur_cell],AL
    MOV AL,[stack_depth]
    SUB AL,#1
    MOV [stack_depth],AL
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
    MOV [i],AL
dm_l:
    MOV CL,[i]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV [cur_row],AL
    MOV CL,[i]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV [cur_col],AL

    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV [cwv],AL
    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[BX]
    MOV [dbv],AL

    MOV AL,[cwv]
    AND AL,#1               ; bit0 = N
    JMPNZ dm_skip_n
    MOV AL,[dbv]
    AND AL,#1
    JMPZ dm_n_wall
    CALL wall_hline_top_door
    JMP dm_skip_n
dm_n_wall:
    CALL wall_hline_top
dm_skip_n:
    MOV AL,[cwv]
    AND AL,#8               ; bit3 = O
    JMPNZ dm_skip_w
    MOV AL,[dbv]
    AND AL,#8
    JMPZ dm_w_wall
    CALL wall_vline_left_door
    JMP dm_skip_w
dm_w_wall:
    CALL wall_vline_left
dm_skip_w:

    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#NCELLS
    JMPNZ dm_l

    MOV AL,#0
    MOV [cur_col],AL
dm_s_l:
    MOV AL,#(MAZE_ROWS-1)
    MOV [cur_row],AL
    MOV CL,[cur_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cur_col]
    ADD AL,BL
    MOV [i],AL
    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    AND AL,#4               ; bit2 = S
    JMPNZ dm_s_skip
    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[BX]
    AND AL,#4
    JMPZ dm_s_wall
    CALL wall_hline_bottom_door
    JMP dm_s_skip
dm_s_wall:
    CALL wall_hline_bottom
dm_s_skip:
    MOV AL,[cur_col]
    ADD AL,#1
    MOV [cur_col],AL
    CMP AL,#MAZE_COLS
    JMPNZ dm_s_l

    MOV AL,#0
    MOV [cur_row],AL
dm_e_l:
    MOV AL,#(MAZE_COLS-1)
    MOV [cur_col],AL
    MOV CL,[cur_row]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cur_col]
    ADD AL,BL
    MOV [i],AL
    MOV CL,[i]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    AND AL,#2               ; bit1 = E
    JMPNZ dm_e_skip
    MOV CL,[i]
    MOV BX,#door_bits
    ADD BX,CL
    MOV AL,[BX]
    AND AL,#2
    JMPZ dm_e_wall
    CALL wall_vline_right_door
    JMP dm_e_skip
dm_e_wall:
    CALL wall_vline_right
dm_e_skip:
    MOV AL,[cur_row]
    ADD AL,#1
    MOV [cur_row],AL
    CMP AL,#MAZE_ROWS
    JMPNZ dm_e_l
    RET

; --- wall_hline_top/bottom, wall_vline_left/right: la "linea doble" de una
; pared, usando (cur_row,cur_col) como celda -- dos trazos de 1 px, 2 px de
; distancia (0 y 2 desde el borde exterior de la celda).
wall_hline_top:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
whl_top_l:
    MOV AL,[wx0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,[wy0]
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wy0]
    ADD AL,#2
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_W
    JMPNZ whl_top_l
    RET

wall_hline_bottom:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
whl_bot_l:
    MOV AL,[wx0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,[wy0]
    ADD AL,#(CELL_H-1)
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wy0]
    ADD AL,#(CELL_H-3)
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_W
    JMPNZ whl_bot_l
    RET

wall_vline_left:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
wvl_left_l:
    MOV AL,[wy0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    MOV AL,[wx0]
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wx0]
    ADD AL,#2
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvl_left_l
    RET

wall_vline_right:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
wvl_right_l:
    MOV AL,[wy0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    MOV AL,[wx0]
    ADD AL,#(CELL_W-1)
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wx0]
    ADD AL,#(CELL_W-3)
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvl_right_l
    RET

; --- wall_*_door: version de un solo trazo (en vez de doble) de las cuatro
; anteriores, para la puerta con llave de la sala (siempre en un borde
; exterior, nunca interior -- por eso hacen falta las 4, no solo top/left).
wall_hline_top_door:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
whtd_l:
    MOV AL,[wx0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,[wy0]
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_W
    JMPNZ whtd_l
    RET

wall_hline_bottom_door:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
whbd_l:
    MOV AL,[wx0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,[wy0]
    ADD AL,#(CELL_H-1)
    MOV [px_y],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_W
    JMPNZ whbd_l
    RET

wall_vline_left_door:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
wvld_l:
    MOV AL,[wy0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    MOV AL,[wx0]
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvld_l
    RET

wall_vline_right_door:
    MOV AL,[cur_row]
    CALL row_to_px
    MOV [wy0],AL
    MOV AL,[cur_col]
    CALL col_to_px
    MOV [wx0],AL
    MOV AL,#0
    MOV [wk],AL
wvrd_l:
    MOV AL,[wy0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    MOV AL,[wx0]
    ADD AL,#(CELL_W-1)
    MOV [px_x],AL
    CALL walls_set_px
    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#CELL_H
    JMPNZ wvrd_l
    RET

; ============================================================================
;  JUGADOR: lectura de encoders, movimiento y colision con paredes
; ============================================================================
update_player:
    IN  AL,(P_DIR_POS)
    MOV [tmp0],AL
    MOV BL,[dir_pos_prev]
    SUB AL,BL
    MOV CL,[tmp0]
    MOV [dir_pos_prev],CL
    CALL clamp_delta
    MOV [dy],AL

    IN  AL,(P_DAT_POS)
    MOV [tmp0],AL
    MOV BL,[dat_pos_prev]
    SUB AL,BL
    MOV CL,[tmp0]
    MOV [dat_pos_prev],CL
    CALL clamp_delta
    MOV [pdx],AL

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
    MOV AL,[pdx]
    CMP AL,#0
    JMPNZ uwa_moving
    MOV AL,[dy]
    CMP AL,#0
    JMPNZ uwa_moving

    MOV AL,[walk_idle]
    ADD AL,#1
    MOV [walk_idle],AL
    CMP AL,#WALK_IDLE_FRAMES
    JMPC uwa_done            ; todavia no lleva bastante quieto
    MOV AL,#0
    MOV [walk_phase],AL
    MOV [walk_timer],AL
    JMP uwa_done
uwa_moving:
    MOV AL,#0
    MOV [walk_idle],AL
    MOV AL,[walk_timer]
    ADD AL,#1
    MOV [walk_timer],AL
    CMP AL,#WALK_ANIM_FRAMES
    JMPC uwa_done            ; todavia no toca cambiar de pie
    MOV AL,#0
    MOV [walk_timer],AL
    MOV AL,[walk_phase]
    CMP AL,#1
    JMPZ uwa_right
    MOV AL,#1
    MOV [walk_phase],AL
    JMP uwa_done
uwa_right:
    MOV AL,#2
    MOV [walk_phase],AL
uwa_done:

    ; direccion de cara (para apuntar al disparar, ver update_fire) -- SOLO
    ; una de las 4 cardinales, nunca diagonal (igual regla que los
    ; enemigos tiradores, que tambien disparan en linea recta N/E/S/O). Se
    ; actualiza con cualquier eje que se haya movido de verdad este
    ; fotograma; si se movieron los dos a la vez, gana el eje Y por
    ; procesarse despues (sencillo, y en la practica rara vez se giran los
    ; dos encoders exactamente en el mismo fotograma). El resto del tiempo
    ; se queda con la ultima conocida, para poder disparar quieto.
    MOV AL,[pdx]
    CMP AL,#0
    JMPZ upd_facex_done
    AND AL,#0x80
    JMPZ upd_facex_pos
    MOV AL,#DIR_W
    MOV [last_fire_dir],AL
    JMP upd_facex_done
upd_facex_pos:
    MOV AL,#DIR_E
    MOV [last_fire_dir],AL
upd_facex_done:

    MOV AL,[dy]
    CMP AL,#0
    JMPZ upd_facey_done
    AND AL,#0x80
    JMPZ upd_facey_pos
    MOV AL,#DIR_N
    MOV [last_fire_dir],AL
    JMP upd_facey_done
upd_facey_pos:
    MOV AL,#DIR_S
    MOV [last_fire_dir],AL
upd_facey_done:

    ; --- eje X ---
    MOV AL,[player_x]
    MOV BL,[pdx]
    ADD AL,BL
    MOV [try_x],AL

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
    MOV AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east_chk2        ; pdx>=0 (ESTE): nunca hay envoltura real

    MOV AL,[pdx]
    NOT AL
    ADD AL,#1                  ; AL = |pdx|
    MOV BL,[player_x]
    CMP BL,AL                  ; player_x - |pdx|
    JMPC upx_oob                ; hubo prestamo (player_x < |pdx|) -> cruce real
    JMP upx_normal               ; si no, es solo movimiento normal

upx_east_chk2:
    MOV AL,[try_x]
    CMP AL,#128
    JMPNC upx_oob
upx_normal:
    MOV AL,[try_x]
    MOV [test_x],AL
    MOV AL,[player_y]
    MOV [test_y],AL
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
    MOV AL,[try_x]
    MOV [player_x],AL
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
    MOV AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east_chk

    ; OESTE: try_x envolvio (queria ir a negativo) -- columna extrema real: 0
    MOV AL,#0
    MOV [test_x],AL
    JMP upx_edge_common
upx_east_chk:
    ; ESTE: columna extrema real: 127
    MOV AL,#127
    MOV [test_x],AL
upx_edge_common:
    MOV AL,[player_y]
    MOV [test_y],AL
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
    MOV AL,[pdx]
    AND AL,#0x80
    JMPZ upx_east
    MOV AL,#DIR_W
    JMP upx_trigger
upx_east:
    MOV AL,#DIR_E
upx_trigger:
    MOV [exit_dir_taken],AL
    MOV AL,#1
    MOV [room_transition_pending],AL
upx_done:
    MOV AL,[room_transition_pending]
    CMP AL,#0
    JMPNZ up_ret            ; ya se cruzo un hueco -- no hace falta seguir

    ; --- eje Y --- (mismo razonamiento corregido que el eje X -- ver su
    ; nota: SUR nunca envuelve, umbral fijo 64 sobre try_y; NORTE solo
    ; cruza de verdad si |dy| > player_y, nunca por un try_y que "parezca"
    ; alto por coincidencia)
    MOV AL,[player_y]
    MOV BL,[dy]
    ADD AL,BL
    MOV [try_y],AL

    MOV AL,[dy]
    AND AL,#0x80
    JMPZ upy_south_chk2       ; dy>=0 (SUR): nunca hay envoltura real

    MOV AL,[dy]
    NOT AL
    ADD AL,#1                  ; AL = |dy|
    MOV BL,[player_y]
    CMP BL,AL                  ; player_y - |dy|
    JMPC upy_oob                ; hubo prestamo (player_y < |dy|) -> cruce real
    JMP upy_normal                ; si no, es solo movimiento normal

upy_south_chk2:
    MOV AL,[try_y]
    CMP AL,#64
    JMPNC upy_oob
upy_normal:
    MOV AL,[player_x]
    MOV [test_x],AL
    MOV AL,[try_y]
    MOV [test_y],AL
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
    MOV AL,[try_y]
    MOV [player_y],AL
    JMP up_ret
upy_oob:
    ; mismo refuerzo simetrico que upx_oob: SIEMPRE un ultimo player_fits en
    ; la fila extrema real (0 o 63) antes de cruzar, tambien para SUR (antes
    ; solo NORTE lo hacia) -- ver la nota de upx_oob.
    MOV AL,[dy]
    AND AL,#0x80
    JMPZ upy_south_chk

    ; NORTE: fila extrema real: 0
    MOV AL,#0
    MOV [test_y],AL
    JMP upy_edge_common
upy_south_chk:
    ; SUR: fila extrema real: 63
    MOV AL,#63
    MOV [test_y],AL
upy_edge_common:
    MOV AL,[player_x]
    MOV [test_x],AL
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
    MOV AL,[dy]
    AND AL,#0x80
    JMPZ upy_south
    MOV AL,#DIR_N
    JMP upy_trigger
upy_south:
    MOV AL,#DIR_S
upy_trigger:
    MOV [exit_dir_taken],AL
    MOV AL,#1
    MOV [room_transition_pending],AL
up_ret:
    RET

; --- clamp_delta: recorta AL (con signo) a [-3,+3] -- limite de velocidad
; del jugador, para que nunca pueda saltarse una pared de un solo fotograma
; (el trazo mas fino de pared mide 1 px, pero conviene margen de sobra).
clamp_delta:
    MOV [tmp1],AL
    AND AL,#0x80
    JMPZ cd_pos
    MOV AL,[tmp1]
    ADD AL,#3
    JMPN cd_neg_clamp
    MOV AL,[tmp1]
    RET
cd_neg_clamp:
    MOV AL,#0xFD
    RET
cd_pos:
    MOV AL,[tmp1]
    CMP AL,#4
    JMPC cd_ok
    MOV AL,#3
    RET
cd_ok:
    MOV AL,[tmp1]
    RET

; --- update_fire: DATOS o DIRECCION pulsados (flanco 0->1, igual patron
; que pong.asm/serve_check) disparan un proyectil hacia [last_fire_dir] --
; SOLO una de las 4 cardinales (N/E/S/O), nunca diagonal, igual regla que
; los enemigos tiradores -- si hay un hueco libre en shot_active[MAX_SHOTS].
update_fire:
    MOV AL,#0
    MOV [tmp3],AL            ; ¿algun boton con flanco nuevo este fotograma?

    IN  AL,(P_DAT_BTN)
    MOV BL,[dat_btn_prev]
    MOV [dat_btn_prev],AL
    CMP AL,#0
    JMPZ uf_chk_dir
    CMP BL,#0
    JMPNZ uf_chk_dir         ; ya estaba pulsado -- no es un flanco nuevo
    MOV AL,#1
    MOV [tmp3],AL

uf_chk_dir:
    IN  AL,(P_DIR_BTN)
    MOV BL,[dir_btn_prev]
    MOV [dir_btn_prev],AL
    CMP AL,#0
    JMPZ uf_check_go
    CMP BL,#0
    JMPNZ uf_check_go
    MOV AL,#1
    MOV [tmp3],AL

uf_check_go:
    MOV AL,[tmp3]
    CMP AL,#0
    JMPZ uf_ret

    MOV AL,#0
    MOV [e],AL
uf_find_l:
    MOV CL,[e]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ uf_fire
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ uf_find_l
    JMP uf_ret              ; sin hueco libre -- no dispara

uf_fire:
    MOV CL,[e]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,#1
    MOV [BX],AL

    MOV CL,[e]
    MOV BX,#shot_x
    ADD BX,CL
    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    MOV [BX],AL

    MOV CL,[e]
    MOV BX,#shot_y
    ADD BX,CL
    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    MOV [BX],AL

    ; velocidad del disparo: SOLO una de las 4 cardinales (nunca diagonal
    ; -- misma regla que los enemigos tiradores) segun [last_fire_dir]
    MOV AL,[last_fire_dir]
    CMP AL,#DIR_N
    JMPNZ uf_dir_e
    MOV AL,#0
    MOV [tmp1],AL
    MOV AL,#(0-SHOT_SPEED)
    MOV [tmp2],AL
    JMP uf_dir_done
uf_dir_e:
    CMP AL,#DIR_E
    JMPNZ uf_dir_s
    MOV AL,#SHOT_SPEED
    MOV [tmp1],AL
    MOV AL,#0
    MOV [tmp2],AL
    JMP uf_dir_done
uf_dir_s:
    CMP AL,#DIR_S
    JMPNZ uf_dir_w
    MOV AL,#0
    MOV [tmp1],AL
    MOV AL,#SHOT_SPEED
    MOV [tmp2],AL
    JMP uf_dir_done
uf_dir_w:
    MOV AL,#(0-SHOT_SPEED)
    MOV [tmp1],AL
    MOV AL,#0
    MOV [tmp2],AL
uf_dir_done:

    MOV CL,[e]
    MOV BX,#shot_vx
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL

    MOV CL,[e]
    MOV BX,#shot_vy
    ADD BX,CL
    MOV AL,[tmp2]
    MOV [BX],AL

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
    MOV [e],AL
us_l:
    MOV CL,[e]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ us_next

    MOV CL,[e]
    MOV BX,#shot_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [ex],AL
    MOV CL,[e]
    MOV BX,#shot_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [ey],AL

    ; barre el recorrido px a px (paso unitario segun el signo de vx/vy) en
    ; vez de saltar los SHOT_SPEED(2) de un salto y probar solo el destino
    ; -- si no, el disparo puede saltar por encima de una pared o puerta de
    ; 1-2px sin llegar a tocarla nunca (mismo fallo que tenia player_fits).
    ; [ex]/[ey] ya valen shot_x/shot_y (la posicion ANTES de moverse).
    MOV CL,[e]
    MOV BX,#shot_vx
    ADD BX,CL
    MOV AL,[BX]
    CALL sign_of
    MOV [stepx],AL

    MOV CL,[e]
    MOV BX,#shot_vy
    ADD BX,CL
    MOV AL,[BX]
    CALL sign_of
    MOV [stepy],AL

    MOV AL,#0
    MOV [k],AL
us_sweep_l:
    MOV AL,[ex]
    MOV BL,[stepx]
    ADD AL,BL
    MOV [ex],AL
    MOV AL,[ey]
    MOV BL,[stepy]
    ADD AL,BL
    MOV [ey],AL

    MOV AL,[ex]
    CMP AL,#124
    JMPNC us_kill
    MOV AL,[ey]
    CMP AL,#60
    JMPNC us_kill

    MOV AL,[ex]
    MOV [px_x],AL
    MOV AL,[ey]
    MOV [px_y],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ us_kill

    MOV AL,[k]
    ADD AL,#1
    MOV [k],AL
    CMP AL,#SHOT_SPEED
    JMPNZ us_sweep_l

    MOV CL,[e]
    MOV BX,#shot_x
    ADD BX,CL
    MOV AL,[ex]
    MOV [BX],AL
    MOV CL,[e]
    MOV BX,#shot_y
    ADD BX,CL
    MOV AL,[ey]
    MOV [BX],AL

    MOV AL,#0
    MOV [j],AL
us_enemy_l:
    MOV CL,[j]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ us_enemy_next

    MOV CL,[j]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    SUB AL,#ENEMY_HALF
    MOV [tmp1],AL
    MOV CL,[j]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    SUB AL,#ENEMY_HALF
    MOV [tmp2],AL

    MOV AL,[ex]
    MOV BL,[tmp1]
    CMP AL,BL
    JMPC us_enemy_next
    MOV AL,[tmp1]
    ADD AL,#ENEMY_W
    MOV BL,[ex]
    CMP BL,AL
    JMPNC us_enemy_next
    MOV AL,[ey]
    MOV BL,[tmp2]
    CMP AL,BL
    JMPC us_enemy_next
    MOV AL,[tmp2]
    ADD AL,#ENEMY_H
    MOV BL,[ey]
    CMP BL,AL
    JMPNC us_enemy_next

    ; overlap confirmado -- el JEFE aguanta BOSS_HP_MAX impactos en vez de
    ; morir del primero: si le queda vida, solo se apaga el disparo (pitido
    ; de impacto, sigue persiguiendo y disparando); al ultimo, pantalla de
    ; victoria en vez del jingle normal de siempre.
    MOV CL,[j]
    MOV BX,#enemy_type
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#ENEMY_TYPE_BOSS
    JMPNZ us_normal_kill

    MOV AL,[boss_hp]
    SUB AL,#1
    MOV [boss_hp],AL
    CMP AL,#0
    JMPZ us_boss_dead
    MOV AL,#3                 ; DUR antes que NOTE (ver el aviso en update_fire)
    OUT (P_SND_DUR),AL
    MOV AL,#48
    OUT (P_SND_NOTE),AL
    JMP us_kill

us_boss_dead:
    MOV CL,[j]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
    MOV AL,#100
    CALL score_add
    CALL update_score_hud
    CALL show_victory
    CALL new_game
    RET

us_normal_kill:
    MOV CL,[j]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL

    MOV AL,#25
    CALL score_add
    CALL update_score_hud
    MOV BX,#JINGLE_TUNE
    CALL play_tune

    JMP us_kill
us_enemy_next:
    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ us_enemy_l
    JMP us_next

us_kill:
    MOV CL,[e]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL

us_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ us_l
    RET

; --- update_enemy_fire: como mucho un disparo enemigo a la vez (variables
; sueltas, no un array -- basta con eso). Cada enemigo tirador (enemy_type
; == 1) activo que este alineado con el jugador en su fila o columna de
; celda dispara en esa direccion cardinal, con un tiempo de espera entre
; disparos (enemy_shot_cooldown) para que no ametralle.
update_enemy_fire:
    MOV AL,[enemy_shot_cooldown]
    CMP AL,#0
    JMPZ uef_ready
    SUB AL,#1
    MOV [enemy_shot_cooldown],AL
    RET
uef_ready:
    MOV AL,[enemy_shot_active]
    CMP AL,#0
    JMPNZ uef_ret

    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    MOV [pcol],AL
    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    MOV [prow],AL

    MOV AL,#0
    MOV [e],AL
uef_l:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ uef_next
    MOV CL,[e]
    MOV BX,#enemy_type
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ uef_next

    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [ex],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [ey],AL

    MOV AL,[ex]
    CALL px_to_col
    MOV [ecol],AL
    MOV AL,[ey]
    CALL px_to_row
    MOV [erow],AL

    MOV AL,[ecol]
    MOV BL,[pcol]
    CMP AL,BL
    JMPZ uef_fire_col
    MOV AL,[erow]
    MOV BL,[prow]
    CMP AL,BL
    JMPNZ uef_next

    ; misma fila -- dispara horizontal
    MOV AL,[player_x]
    MOV BL,[ex]
    CMP AL,BL
    JMPC uef_h_left
    MOV AL,#1
    JMP uef_h_sign
uef_h_left:
    MOV AL,#0xFF
uef_h_sign:
    SHL AL,#1
    MOV [tmp1],AL
    MOV AL,#0
    MOV [tmp2],AL
    JMP uef_do_fire

uef_fire_col:
    ; misma columna -- dispara vertical
    MOV AL,[player_y]
    MOV BL,[ey]
    CMP AL,BL
    JMPC uef_v_up
    MOV AL,#1
    JMP uef_v_sign
uef_v_up:
    MOV AL,#0xFF
uef_v_sign:
    SHL AL,#1
    MOV [tmp2],AL
    MOV AL,#0
    MOV [tmp1],AL

uef_do_fire:
    MOV AL,#1
    MOV [enemy_shot_active],AL
    MOV AL,[ex]
    MOV [enemy_shot_x],AL
    MOV AL,[ey]
    MOV [enemy_shot_y],AL
    MOV AL,[tmp1]
    MOV [enemy_shot_vx],AL
    MOV AL,[tmp2]
    MOV [enemy_shot_vy],AL
    MOV AL,#60
    MOV [enemy_shot_cooldown],AL
    ; P_SND_DUR antes que P_SND_NOTE (ver la nota en update_fire)
    MOV AL,#4
    OUT (P_SND_DUR),AL
    MOV AL,#50
    OUT (P_SND_NOTE),AL
    RET

uef_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ uef_l
uef_ret:
    RET

; --- update_enemy_shots: mueve el disparo enemigo (si hay); lo apaga si
; sale de pantalla o choca con una pared; si alcanza al jugador, cuenta
; como golpe (on_player_hit) igual que tocar a un enemigo.
update_enemy_shots:
    MOV AL,[enemy_shot_active]
    CMP AL,#0
    JMPZ ues_ret

    ; barre px a px, igual razon y mismo patron que update_shots (ver su
    ; comentario) -- si no, un disparo enemigo tambien puede saltar por
    ; encima de una pared o puerta sin tocarla.
    MOV AL,[enemy_shot_x]
    MOV [ex],AL
    MOV AL,[enemy_shot_y]
    MOV [ey],AL

    MOV AL,[enemy_shot_vx]
    CALL sign_of
    MOV [stepx],AL
    MOV AL,[enemy_shot_vy]
    CALL sign_of
    MOV [stepy],AL

    MOV AL,#0
    MOV [k],AL
ues_sweep_l:
    MOV AL,[ex]
    MOV BL,[stepx]
    ADD AL,BL
    MOV [ex],AL
    MOV AL,[ey]
    MOV BL,[stepy]
    ADD AL,BL
    MOV [ey],AL

    MOV AL,[ex]
    CMP AL,#124
    JMPNC ues_kill
    MOV AL,[ey]
    CMP AL,#60
    JMPNC ues_kill

    MOV AL,[ex]
    MOV [px_x],AL
    MOV AL,[ey]
    MOV [px_y],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ ues_kill

    MOV AL,[k]
    ADD AL,#1
    MOV [k],AL
    CMP AL,#SHOT_SPEED
    JMPNZ ues_sweep_l

    MOV AL,[ex]
    MOV [enemy_shot_x],AL
    MOV AL,[ey]
    MOV [enemy_shot_y],AL

    MOV AL,[ex]
    MOV BL,[player_x]
    CMP AL,BL
    JMPC ues_ret
    MOV AL,[player_x]
    ADD AL,#PLAYER_W
    MOV BL,[ex]
    CMP BL,AL
    JMPNC ues_ret
    MOV AL,[ey]
    MOV BL,[player_y]
    CMP AL,BL
    JMPC ues_ret
    MOV AL,[player_y]
    ADD AL,#PLAYER_H
    MOV BL,[ey]
    CMP BL,AL
    JMPNC ues_ret

    MOV AL,#0
    MOV [enemy_shot_active],AL
    CALL on_player_hit
    RET

ues_kill:
    MOV AL,#0
    MOV [enemy_shot_active],AL
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
    MOV [pfy],AL
pf_row:
    MOV AL,[test_y]
    MOV BL,[pfy]
    ADD AL,BL
    ; recorta a la ultima fila real (0-63): test_y puede pedirse por encima
    ; de eso a proposito (ver update_player, umbral de 64 a secas para el
    ; borde SUR) para no perderse una pared/puerta pegada ahi -- sin este
    ; recorte, una fila >=64 leeria memoria de otra fila de `walls`.
    CMP AL,#64
    JMPC pf_y_ok
    MOV AL,#63
pf_y_ok:
    MOV [px_y],AL
    MOV AL,#0
    MOV [pfx],AL
pf_col:
    MOV AL,[test_x]
    MOV BL,[pfx]
    ADD AL,BL
    ; mismo recorte para la columna (0-127), borde ESTE
    CMP AL,#128
    JMPC pf_x_ok
    MOV AL,#127
pf_x_ok:
    MOV [px_x],AL
    CALL wall_test
    CMP AL,#0
    JMPNZ pf_hit

    MOV AL,[pfx]
    ADD AL,#1
    MOV [pfx],AL
    CMP AL,#PLAYER_W
    JMPNZ pf_col

    MOV AL,[pfy]
    ADD AL,#1
    MOV [pfy],AL
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
    MOV AL,[key_taken]
    CMP AL,#0
    JMPNZ ckp_ret

    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    MOV [tmp1],AL
    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[tmp1]
    ADD AL,BL
    MOV BL,[key_cell]
    CMP AL,BL
    JMPNZ ckp_ret

    MOV AL,#1
    MOV [key_taken],AL
    MOV AL,[keys_held]
    ADD AL,#1
    MOV [keys_held],AL
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
    MOV AL,[heart_taken]
    CMP AL,#0
    JMPNZ chp_ret
    MOV AL,[heart_cell]
    CMP AL,#255
    JMPZ chp_ret

    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    MOV [tmp1],AL
    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    MOV [tmp2],AL
    MOV CL,[tmp2]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[tmp1]
    ADD AL,BL
    MOV BL,[heart_cell]
    CMP AL,BL
    JMPNZ chp_ret

    MOV AL,#1
    MOV [heart_taken],AL
    CALL save_room_state       ; que no reaparezca al salir y volver
    MOV AL,[lives]
    CMP AL,#MAX_LIVES
    JMPNC chp_sound
    ADD AL,#1
    MOV [lives],AL
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
    MOV AL,[door_dir]
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
    MOV AL,[keys_held]
    CMP AL,#0
    JMPZ dc_ret

    MOV CL,[door_dir]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[door_cell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[tmp1]
    AND AL,BL
    CMP AL,#0
    JMPNZ dc_ret            ; bit ya puesto -> ya estaba abierta

    MOV CL,[door_cell]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV [drow],AL
    MOV CL,[door_cell]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV [dcol],AL
    MOV AL,[drow]
    CALL row_to_px
    MOV [tmp1],AL           ; fila*CELL_H
    MOV AL,[dcol]
    CALL col_to_px
    MOV [tmp2],AL           ; columna*CELL_W

    MOV AL,[door_dir]
    CMP AL,#DIR_N
    JMPNZ dc_e
    MOV AL,[tmp2]
    ADD AL,#(CELL_W/2)
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    MOV [dy_pt],AL
    JMP dc_dist
dc_e:
    CMP AL,#DIR_E
    JMPNZ dc_s
    MOV AL,[tmp2]
    ADD AL,#CELL_W
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#(CELL_H/2)
    MOV [dy_pt],AL
    JMP dc_dist
dc_s:
    CMP AL,#DIR_S
    JMPNZ dc_w
    MOV AL,[tmp2]
    ADD AL,#(CELL_W/2)
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#CELL_H
    MOV [dy_pt],AL
    JMP dc_dist
dc_w:
    MOV AL,[tmp2]
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#(CELL_H/2)
    MOV [dy_pt],AL

dc_dist:
    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    MOV BL,[dx_pt]
    SUB AL,BL
    JMPN dc_xneg
    JMP dc_xdone
dc_xneg:
    NOT AL
    ADD AL,#1
dc_xdone:
    MOV [tmp1],AL

    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    MOV BL,[dy_pt]
    SUB AL,BL
    JMPN dc_yneg
    JMP dc_ydone
dc_yneg:
    NOT AL
    ADD AL,#1
dc_ydone:
    MOV BL,[tmp1]
    ADD AL,BL
    CMP AL,#DOOR_OPEN_DIST
    JMPNC dc_ret            ; demasiado lejos todavia

    MOV CL,[door_dir]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[door_cell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV DL,[tmp1]
    OR  AL,DL
    MOV [BX],AL

    ; la llave se gasta al abrir la puerta: desaparece del contador del
    ; marcador
    MOV AL,[keys_held]
    CMP AL,#0
    JMPZ dc_no_dec
    SUB AL,#1
    MOV [keys_held],AL
    CALL update_keys_hud
    MOV AL,[keys_used]           ; llaves gastadas en la partida (ver
    ADD AL,#1                    ; on_room_entered: acorta la espera del fantasma)
    MOV [keys_used],AL
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
    MOV AL,[door_dir]
    CMP AL,#255
    JMPZ nd_no

    MOV CL,[door_cell]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV [drow],AL
    MOV CL,[door_cell]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV [dcol],AL
    MOV AL,[drow]
    CALL row_to_px
    MOV [tmp1],AL
    MOV AL,[dcol]
    CALL col_to_px
    MOV [tmp2],AL

    MOV AL,[door_dir]
    CMP AL,#DIR_N
    JMPNZ nd_e
    MOV AL,[tmp2]
    ADD AL,#(CELL_W/2)
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    MOV [dy_pt],AL
    JMP nd_dist
nd_e:
    CMP AL,#DIR_E
    JMPNZ nd_s
    MOV AL,[tmp2]
    ADD AL,#CELL_W
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#(CELL_H/2)
    MOV [dy_pt],AL
    JMP nd_dist
nd_s:
    CMP AL,#DIR_S
    JMPNZ nd_w
    MOV AL,[tmp2]
    ADD AL,#(CELL_W/2)
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#CELL_H
    MOV [dy_pt],AL
    JMP nd_dist
nd_w:
    MOV AL,[tmp2]
    MOV [dx_pt],AL
    MOV AL,[tmp1]
    ADD AL,#(CELL_H/2)
    MOV [dy_pt],AL

nd_dist:
    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    MOV BL,[dx_pt]
    SUB AL,BL
    JMPN nd_xneg
    JMP nd_xdone
nd_xneg:
    NOT AL
    ADD AL,#1
nd_xdone:
    MOV [tmp1],AL

    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    MOV BL,[dy_pt]
    SUB AL,BL
    JMPN nd_yneg
    JMP nd_ydone
nd_yneg:
    NOT AL
    ADD AL,#1
nd_ydone:
    MOV BL,[tmp1]
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
    MOV AL,[room_num]
    CMP AL,#BOSS_ROOM_NUM
    JMPNZ se_not_boss
    ; sala del jefe: UN unico enemigo (slot 0), nada de la cuenta/tipo
    ; normal -- se_type_store mas abajo lo convierte en ENEMY_TYPE_BOSS
    ; en cuanto ve que esta en esta sala
    MOV AL,#1
    MOV [enemy_count],AL
    MOV AL,#BOSS_HP_MAX
    MOV [boss_hp],AL
    JMP se_speed
se_not_boss:
    CMP AL,#FIRST_ENEMY_ROOM
    JMPNC se_have
    MOV AL,#0
    MOV [enemy_count],AL
    JMP se_speed
se_have:
    SUB AL,#(FIRST_ENEMY_ROOM-1)
    CMP AL,#MAX_ENEMIES
    JMPC se_cnt_ok
    MOV AL,#MAX_ENEMIES
se_cnt_ok:
    MOV [enemy_count],AL

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
    MOV AL,[room_num]
    CMP AL,#START_DELAY
    JMPNC se_delay_floor
    MOV AL,#START_DELAY
    MOV BL,[room_num]
    SUB AL,BL
    CMP AL,#MIN_DELAY
    JMPNC se_delay_ok
se_delay_floor:
    MOV AL,#MIN_DELAY
se_delay_ok:
    MOV [move_delay],AL
    MOV AL,#0
    MOV [enemy_shot_active],AL
    MOV [enemy_shot_cooldown],AL
    MOV AL,#0
    MOV [move_counter],AL

    MOV AL,#0
    MOV [e],AL
se_l:
    MOV AL,[e]
    MOV BL,[enemy_count]
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
    MOV CL,[e]
    MOV BX,#ENEMY_SPAWN_ROW
    ADD BX,CL
    MOV AL,[BX]
    MOV [erow],AL
    MOV CL,[e]
    MOV BX,#ENEMY_SPAWN_COL
    ADD BX,CL
    MOV AL,[BX]
    MOV [ecol],AL

    MOV AL,[erow]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    MOV [tmp1],AL           ; y candidata
    MOV AL,[ecol]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    MOV [tmp2],AL           ; x candidata

    MOV AL,[tmp2]
    MOV BL,[player_x]
    SUB AL,BL
    JMPN se_xneg
    JMP se_xdone
se_xneg:
    NOT AL
    ADD AL,#1
se_xdone:
    MOV [tmp3],AL
    MOV AL,[tmp1]
    MOV BL,[player_y]
    SUB AL,BL
    JMPN se_yneg
    JMP se_ydone
se_yneg:
    NOT AL
    ADD AL,#1
se_ydone:
    MOV BL,[tmp3]
    ADD AL,BL
    CMP AL,#MIN_ENEMY_SPAWN_DIST
    JMPNC se_pos_ok         ; ya suficientemente lejos del jugador

    MOV AL,#(MAZE_ROWS-1)
    MOV BL,[erow]
    SUB AL,BL
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    MOV [tmp1],AL
    MOV AL,#(MAZE_COLS-1)
    MOV BL,[ecol]
    SUB AL,BL
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    MOV [tmp2],AL
se_pos_ok:
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL
    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[tmp2]
    MOV [BX],AL

    MOV CL,[e]
    MOV BX,#enemy_dir
    ADD BX,CL
    MOV AL,#DIR_N
    MOV [BX],AL

    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,#1
    MOV [BX],AL

    ; tipo: a partir de la SEGUNDA sala con enemigos, 1 de cada 4 nace
    ; tirador; en la primera son todos persegidores, para una entrada mas
    ; suave (ver update_enemy_fire para el comportamiento del tirador)
    MOV CL,[e]
    MOV BX,#enemy_type
    ADD BX,CL
    MOV AL,[room_num]
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
    MOV [BX],AL
    JMP se_next
se_inactive:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,#0
    MOV [BX],AL
se_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ se_l
    RET

; --- update_enemies: cada [move_delay] fotogramas, adelanta 1 px a cada
; enemigo activo en su direccion actual (step_enemy decide una nueva
; direccion si acaba de llegar al centro de una celda).
update_enemies:
    MOV AL,[move_counter]
    ADD AL,#1
    MOV [move_counter],AL
    MOV BL,[move_delay]
    CMP AL,BL
    JMPC ue_done
    MOV AL,#0
    MOV [move_counter],AL

    MOV AL,#0
    MOV [e],AL
ue_l:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ ue_next
    CALL step_enemy
ue_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ ue_l
ue_done:
    RET

; --- step_enemy: entra [e]. Si esta centrado en una celda, decide direccion
; nueva (choose_enemy_dir); luego avanza 1 px en enemy_dir[e].
step_enemy:
    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [ex],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [ey],AL

    ; ¿esta exactamente en el centro de su celda? -- 21 no es potencia de 2,
    ; asi que no vale una mascara de bits: se recalcula el centro de SU
    ; columna/fila (col_to_px[px_to_col[ex]]+mitad) y se compara con la
    ; posicion real
    MOV AL,[ex]
    CALL px_to_col
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    MOV BL,[ex]
    CMP AL,BL
    JMPNZ se_step_move
    MOV AL,[ey]
    CALL px_to_row
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    MOV BL,[ey]
    CMP AL,BL
    JMPNZ se_step_move
    CALL choose_enemy_dir

se_step_move:
    MOV CL,[e]
    MOV BX,#enemy_dir
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#DIR_N
    JMPNZ sm_e
    MOV AL,[ey]
    SUB AL,#1
    MOV [ey],AL
    JMP sm_store
sm_e:
    CMP AL,#DIR_E
    JMPNZ sm_s
    MOV AL,[ex]
    ADD AL,#1
    MOV [ex],AL
    JMP sm_store
sm_s:
    CMP AL,#DIR_S
    JMPNZ sm_w
    MOV AL,[ey]
    ADD AL,#1
    MOV [ey],AL
    JMP sm_store
sm_w:
    MOV AL,[ex]
    SUB AL,#1
    MOV [ex],AL
sm_store:
    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[ex]
    MOV [BX],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[ey]
    MOV [BX],AL
    RET

; --- choose_enemy_dir: entra [e],[ex],[ey] (centro, YA alineado a celda).
; Elige, de las direcciones ABIERTAS de esa celda, la que mas acerque a la
; celda del jugador (distancia Manhattan); evita dar media vuelta salvo que
; sea la unica salida.
choose_enemy_dir:
    MOV AL,[ex]
    CALL px_to_col
    MOV [ecol],AL
    MOV AL,[ey]
    CALL px_to_row
    MOV [erow],AL
    MOV CL,[erow]
    MOV BX,#ROW_MUL
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ecol]
    ADD AL,BL
    MOV [ecell],AL

    MOV AL,[player_x]
    ADD AL,#(PLAYER_W/2)
    CALL px_to_col
    MOV [pcol],AL
    MOV AL,[player_y]
    ADD AL,#(PLAYER_H/2)
    CALL px_to_row
    MOV [prow],AL

    MOV CL,[ecell]
    MOV BX,#cell_walls
    ADD BX,CL
    MOV AL,[BX]
    MOV [cwv],AL

    MOV CL,[e]
    MOV BX,#enemy_dir
    ADD BX,CL
    MOV CL,[BX]
    MOV BX,#OPP_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV [banned_dir],AL

    MOV AL,#255
    MOV [best_dist],AL
    MOV [best_dir],AL
    MOV AL,#0
    MOV [d],AL
ced_l1:
    MOV CL,[d]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cwv]
    AND BL,AL
    CMP BL,#0
    JMPZ ced_next1
    MOV AL,[d]
    MOV BL,[banned_dir]
    CMP AL,BL
    JMPZ ced_next1
    CALL ced_consider
ced_next1:
    MOV AL,[d]
    ADD AL,#1
    MOV [d],AL
    CMP AL,#4
    JMPNZ ced_l1

    MOV AL,[best_dir]
    CMP AL,#255
    JMPNZ ced_store

    MOV AL,#0
    MOV [d],AL
ced_l2:
    MOV CL,[d]
    MOV BX,#BIT_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[cwv]
    AND BL,AL
    CMP BL,#0
    JMPZ ced_next2
    CALL ced_consider
ced_next2:
    MOV AL,[d]
    ADD AL,#1
    MOV [d],AL
    CMP AL,#4
    JMPNZ ced_l2

ced_store:
    MOV CL,[e]
    MOV BX,#enemy_dir
    ADD BX,CL
    MOV AL,[best_dir]
    MOV [BX],AL
    RET

; --- ced_consider: para la direccion [d] (ya sabida abierta), mira su celda
; vecina (a partir de erow/ecol) y, si su distancia Manhattan a (prow,pcol)
; mejora [best_dist], actualiza [best_dist]/[best_dir].
ced_consider:
    MOV CL,[d]
    MOV BX,#DR_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[erow]
    ADD AL,BL
    MOV [trow],AL

    MOV CL,[d]
    MOV BX,#DC_OF_DIR
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ecol]
    ADD AL,BL
    MOV [tcol],AL

    ; si (trow,tcol) cae FUERA de la rejilla de MAZE_ROWSxMAZE_COLS, esta
    ; direccion es la entrada de la sala o uno de sus huecos extra (abierto
    ; o ya abierto con llave) -- cell_walls guarda ese bit exactamente igual
    ; que un paso interno normal, no hay forma de distinguirlos mirando solo
    ; el bit. Un enemigo NUNCA debe poder tomar esa salida: a diferencia del
    ; jugador (cross_room_gap le genera/enlaza la sala siguiente al cruzar),
    ; para un enemigo eso significa salir del mapa sin que nada lo detenga
    ; -- ni pared (cell_walls fuera de la sala son datos de otras variables,
    ; leidos como si fueran validos), ni el jugador (que se queda atras) --
    ; y vagar en linea recta hasta desaparecer por el otro lado de la
    ; pantalla. Bug real reportado: "un sprite en forma de bola que cruza la
    ; pantalla despacio, no se puede matar ni te mata, atraviesa paredes".
    MOV AL,[trow]
    CMP AL,#MAZE_ROWS
    JMPNC ccd_no             ; trow >= MAZE_ROWS (incluye el envoltorio de -1 a 255)
    MOV AL,[tcol]
    CMP AL,#MAZE_COLS
    JMPNC ccd_no             ; tcol >= MAZE_COLS (idem)

    MOV AL,[trow]
    MOV BL,[prow]
    SUB AL,BL
    JMPN cc_rowneg
    JMP cc_rowdone
cc_rowneg:
    NOT AL
    ADD AL,#1
cc_rowdone:
    MOV [dist],AL

    MOV AL,[tcol]
    MOV BL,[pcol]
    SUB AL,BL
    JMPN cc_colneg
    JMP cc_coldone
cc_colneg:
    NOT AL
    ADD AL,#1
cc_coldone:
    MOV BL,[dist]
    ADD AL,BL
    MOV [dist],AL

    MOV AL,[dist]
    MOV BL,[best_dist]
    CMP AL,BL
    JMPNC ccd_no
    MOV [best_dist],AL
    MOV AL,[d]
    MOV [best_dir],AL
ccd_no:
    RET

; ============================================================================
;  check_collisions: jugador contra cada enemigo activo (cajas PLAYER_W x
;  PLAYER_H y ENEMY_W x ENEMY_H, la del enemigo centrada en (ex,ey)).
; ============================================================================
check_collisions:
    MOV AL,#0
    MOV [e],AL
cc_l:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ cc_next

    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    SUB AL,#ENEMY_HALF
    MOV [ex],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    SUB AL,#ENEMY_HALF
    MOV [ey],AL

    MOV AL,[ex]
    ADD AL,#ENEMY_W
    MOV BL,[player_x]
    CMP BL,AL
    JMPNC cc_next
    MOV AL,[player_x]
    ADD AL,#PLAYER_W
    MOV BL,[ex]
    CMP BL,AL
    JMPNC cc_next
    MOV AL,[ey]
    ADD AL,#ENEMY_H
    MOV BL,[player_y]
    CMP BL,AL
    JMPNC cc_next
    MOV AL,[player_y]
    ADD AL,#PLAYER_H
    MOV BL,[ey]
    CMP BL,AL
    JMPNC cc_next

    CALL on_player_hit
    RET                     ; una colision basta este fotograma
cc_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
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

    MOV AL,[lives]
    SUB AL,#1
    MOV [lives],AL          ; el icono se redibuja solo cada fotograma en
    CALL update_lives_hud   ; draw_frame, pero el NUMERO (texto) hay que
    MOV AL,[lives]          ; actualizarlo aparte, igual que la puntuacion
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
    MOV [e],AL
eesd_l:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ eesd_next

    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp2],AL

    MOV AL,[tmp1]
    MOV BL,[player_x]
    SUB AL,BL
    JMPN eesd_xneg
    JMP eesd_xdone
eesd_xneg:
    NOT AL
    ADD AL,#1
eesd_xdone:
    MOV [tmp3],AL
    MOV AL,[tmp2]
    MOV BL,[player_y]
    SUB AL,BL
    JMPN eesd_yneg
    JMP eesd_ydone
eesd_yneg:
    NOT AL
    ADD AL,#1
eesd_ydone:
    MOV BL,[tmp3]
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
    MOV AL,[tmp1]
    CALL px_to_col
    MOV BL,AL
    MOV AL,#(MAZE_COLS-1)
    SUB AL,BL
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    MOV [tmp1],AL

    MOV AL,[tmp2]
    CALL px_to_row
    MOV BL,AL
    MOV AL,#(MAZE_ROWS-1)
    SUB AL,BL
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    MOV [tmp2],AL

    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[tmp1]
    MOV [BX],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[tmp2]
    MOV [BX],AL

eesd_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ eesd_l
    RET

; ============================================================================
;  DIBUJO DEL FOTOGRAMA: `walls` -> `shadow`, jugador y enemigos encima
; ============================================================================
draw_frame:
    CALL copy_walls_to_shadow
    MOV AL,#0
    MOV [i],AL
df_pl_l:
    MOV CL,[i]
    MOV BX,#PLAYER_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[player_x]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[i]
    MOV BX,#PLAYER_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]

    ; pie izquierdo (indice 10) o derecho (11) de PLAYER_SPRITE_DX/DY: sube
    ; 1px si le toca levantarse en esta fase de la animacion de andar (ver
    ; update_player) -- el otro pie, y el resto del cuerpo, se quedan tal
    ; cual dice la tabla.
    MOV CL,[i]
    CMP CL,#10
    JMPNZ dfp_foot_r
    MOV CL,[walk_phase]
    CMP CL,#1
    JMPNZ dfp_dy_done
    SUB AL,#1
    JMP dfp_dy_done
dfp_foot_r:
    CMP CL,#11
    JMPNZ dfp_dy_done
    MOV CL,[walk_phase]
    CMP CL,#2
    JMPNZ dfp_dy_done
    SUB AL,#1
dfp_dy_done:
    MOV BL,[player_y]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[i]
    ADD AL,#1
    MOV [i],AL
    CMP AL,#PLAYER_SPRITE_N
    JMPNZ df_pl_l

    ; disparos del jugador: un solo pixel basta (son pequeños y rapidos)
    MOV AL,#0
    MOV [e],AL
df_shot_l:
    MOV CL,[e]
    MOV BX,#shot_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ df_shot_next

    MOV CL,[e]
    MOV BX,#shot_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [px_x],AL
    MOV CL,[e]
    MOV BX,#shot_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [px_y],AL
    CALL shadow_set_px
df_shot_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_SHOTS
    JMPNZ df_shot_l

    ; disparo enemigo (uno solo, tambien un pixel)
    MOV AL,[enemy_shot_active]
    CMP AL,#0
    JMPZ df_no_eshot
    MOV AL,[enemy_shot_x]
    MOV [px_x],AL
    MOV AL,[enemy_shot_y]
    MOV [px_y],AL
    CALL shadow_set_px
df_no_eshot:

    MOV AL,#0
    MOV [e],AL
df_en_l:
    MOV CL,[e]
    MOV BX,#enemy_active
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#0
    JMPZ df_en_next

    MOV CL,[e]
    MOV BX,#enemy_x
    ADD BX,CL
    MOV AL,[BX]
    MOV [ex],AL
    MOV CL,[e]
    MOV BX,#enemy_y
    ADD BX,CL
    MOV AL,[BX]
    MOV [ey],AL

    MOV AL,#0
    MOV [j],AL
    MOV CL,[e]
    MOV BX,#enemy_type
    ADD BX,CL
    MOV AL,[BX]
    CMP AL,#ENEMY_TYPE_BOSS
    JMPZ df_boss_es_l
df_es_l:
    MOV CL,[j]
    MOV BX,#ENEMY_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#ENEMY_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#ENEMY_SPRITE_N
    JMPNZ df_es_l
    JMP df_en_next

; --- jefe: mismo bucle, pero con BOSS_SPRITE_* (ver su comentario) --------
df_boss_es_l:
    MOV CL,[j]
    MOV BX,#BOSS_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#BOSS_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#BOSS_SPRITE_N
    JMPNZ df_boss_es_l

df_en_next:
    MOV AL,[e]
    ADD AL,#1
    MOV [e],AL
    CMP AL,#MAX_ENEMIES
    JMPNZ df_en_l

    ; fantasma (si esta activo en esta sala, ver update_ghost)
    MOV AL,[ghost_active]
    CMP AL,#0
    JMPZ df_no_ghost
    MOV AL,#0
    MOV [j],AL
df_ghost_l:
    MOV CL,[j]
    MOV BX,#GHOST_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ghost_x]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#GHOST_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ghost_y]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#GHOST_SPRITE_N
    JMPNZ df_ghost_l
df_no_ghost:

    ; llave (si esta sala GUARDA una -- puede que ni siquiera tenga puerta
    ; propia, si la llave es para la puerta de un hijo suyo -- y todavia no
    ; se ha cogido). Antes se miraba [door_dir] aqui, pero eso ya no vale:
    ; la llave puede vivir en una sala que no tiene puerta propia.
    MOV AL,[key_cell]
    CMP AL,#255
    JMPZ df_no_key
    MOV AL,[key_taken]
    CMP AL,#0
    JMPNZ df_no_key

    MOV CL,[key_cell]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    MOV [ey],AL              ; centro Y de la celda de la llave
    MOV CL,[key_cell]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    MOV [ex],AL              ; centro X

    MOV AL,#0
    MOV [j],AL
df_key_l:
    MOV CL,[j]
    MOV BX,#KEY_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#KEY_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#KEY_SPRITE_N
    JMPNZ df_key_l
df_no_key:

    ; corazon de repuesto en el suelo (si esta sala tiene uno y todavia no
    ; se ha cogido) -- mismo patron que la llave, reutilizando el sprite del
    ; marcador (HEART_SPRITE_DX/DY es top-left, no centrado, asi que se resta
    ; medio sprite para centrarlo en la celda)
    MOV AL,[heart_cell]
    CMP AL,#255
    JMPZ df_no_heart
    MOV AL,[heart_taken]
    CMP AL,#0
    JMPNZ df_no_heart

    MOV CL,[heart_cell]
    MOV BX,#CELL_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    CALL row_to_px
    ADD AL,#(CELL_H/2)
    SUB AL,#2
    MOV [ey],AL              ; esquina superior izq. del corazon (5x5)
    MOV CL,[heart_cell]
    MOV BX,#CELL_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    CALL col_to_px
    ADD AL,#(CELL_W/2)
    SUB AL,#2
    MOV [ex],AL

    MOV AL,#0
    MOV [j],AL
df_heart_floor_l:
    MOV CL,[j]
    MOV BX,#HEART_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#HEART_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
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
    MOV [wk],AL
df_hud_clr_row:
    MOV AL,#0
    MOV [k],AL
df_hud_clr_col:
    MOV AL,#HEART_AREA_X0
    MOV BL,[k]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,#HEART_AREA_Y0
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_clear_px

    MOV AL,[k]
    ADD AL,#1
    MOV [k],AL
    CMP AL,#HEART_AREA_W
    JMPNZ df_hud_clr_col

    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#HEART_AREA_H
    JMPNZ df_hud_clr_row

    ; icono de corazon (uno solo, tamaño fijo -- el numero de al lado dice
    ; cuantas vidas quedan)
    MOV AL,#HEART_ICON_X
    MOV [ex],AL
    MOV AL,#HEART_ICON_Y
    MOV [ey],AL
    MOV AL,#0
    MOV [j],AL
df_heart_pt:
    MOV CL,[j]
    MOV BX,#HEART_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#HEART_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    CMP AL,#HEART_SPRITE_N
    JMPNZ df_heart_pt

    ; icono de llave (siempre visible, es solo el contador -- no depende
    ; de si esta sala tiene llave o no)
    MOV AL,#KEY_ICON_CX
    MOV [ex],AL
    MOV AL,#KEY_ICON_CY
    MOV [ey],AL
    MOV AL,#0
    MOV [j],AL
df_hudkey_pt:
    MOV CL,[j]
    MOV BX,#KEY_SPRITE_DX
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ex]
    ADD AL,BL
    MOV [px_x],AL

    MOV CL,[j]
    MOV BX,#KEY_SPRITE_DY
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[ey]
    ADD AL,BL
    MOV [px_y],AL
    CALL shadow_set_px

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
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
    MOV BL,[score_lo]
    ADD BL,AL
    MOV [score_lo],BL
    JMPNC sca_done
    MOV AL,[score_hi]
    ADD AL,#1
    MOV [score_hi],AL
sca_done:
    RET

; --- update_score_hud: puntuacion de 16 bits (0..65535) en 5 cifras,
; columnas 0-4 de la fila 0 (antes 3 cifras para un solo byte -- de sobra
; hueco libre hasta la columna 17 del corazon, ver LIVES_DIGIT_COL).
update_score_hud:
    MOV AL,[score_lo]
    MOV [nd_val_lo],AL
    MOV AL,[score_hi]
    MOV [nd_val_hi],AL
    CALL u16_digits

    MOV DH,#0x04
    MOV AL,[dig10000]
    ADD AL,#0x30
    MOV DL,#0
    OUT (DX),AL
    MOV AL,[dig1000]
    ADD AL,#0x30
    MOV DL,#1
    OUT (DX),AL
    MOV AL,[dig100]
    ADD AL,#0x30
    MOV DL,#2
    OUT (DX),AL
    MOV AL,[dig10]
    ADD AL,#0x30
    MOV DL,#3
    OUT (DX),AL
    MOV AL,[dig1]
    ADD AL,#0x30
    MOV DL,#4
    OUT (DX),AL
    RET

; --- update_lives_hud: numero de vidas, justo al lado del icono de
; corazon (0-3, siempre cabe en 1 digito -- MAX_LIVES)
update_lives_hud:
    MOV AL,[lives]
    ADD AL,#0x30
    MOV DX,#0x04*256+LIVES_DIGIT_COL
    OUT (DX),AL
    RET

; --- update_keys_hud: numero de llaves cogidas en total, justo al lado
; del icono de llave (1 sola cifra -- nunca llega a 10, ver comentario junto
; a KEYS_DIGIT_COL)
update_keys_hud:
    MOV AL,[keys_held]
    ADD AL,#0x30
    MOV DX,#0x04*256+KEYS_DIGIT_COL
    OUT (DX),AL
    RET

; --- u16_digits: las 5 cifras decimales de [nd_val_lo]/[nd_val_hi] (16
; bits) en dig10000..dig1, con DIV (docs/isa.md SS4d): 5 divisiones de 16
; bits entre 10, cada una hecha con 2 DIV de 8 bits (byte alto y luego
; resto*256 + byte bajo, que siempre cabe: resto < 10). Antes eran restas
; repetidas de 10000, 1000, 100 y 10 (hasta 9 vueltas por cifra). Deja
; [nd_val_*] a 0. Respeta AH.
u16_digits:
    PUSH AH
    CALL div10_16
    MOV [dig1],AL
    CALL div10_16
    MOV [dig10],AL
    CALL div10_16
    MOV [dig100],AL
    CALL div10_16
    MOV [dig1000],AL
    CALL div10_16
    MOV [dig10000],AL
    POP AH
    RET

; --- div10_16: [nd_val_lo/hi] /= 10; sale AL = el resto (la cifra) --------
div10_16:
    MOV BL,#10
    MOV AH,#0
    MOV AL,[nd_val_hi]
    DIV BL
    MOV [nd_val_hi],AL
    MOV AL,[nd_val_lo]      ; AH = resto del byte alto
    DIV BL
    MOV [nd_val_lo],AL
    MOV AL,AH
    RET

; ============================================================================
;  RECORD (EEPROM del slot) -- ver P_EEP_* arriba
; ============================================================================
; --- load_record: [record_lo/hi] = el grabado (0 si no hay ninguno) -------
load_record:
    OUT (P_EEP_LOAD),AL
    MOV AL,#0
    MOV [record_lo],AL
    MOV [record_hi],AL
    IN  AL,(P_EEP_BASE)
    CMP AL,#REC_MAGIC
    JMPNZ lr_done
    IN  AL,(P_EEP_BASE+1)
    MOV [record_lo],AL
    IN  AL,(P_EEP_BASE+2)
    MOV [record_hi],AL
lr_done:
    RET

; --- show_record: carga el record y escribe "RECORD nnnnn" en CH=fila, CL=col
show_record:
    PUSH CL
    PUSH CH
    CALL load_record
    MOV AL,[record_lo]
    MOV [nd_val_lo],AL
    MOV AL,[record_hi]
    MOV [nd_val_hi],AL
    CALL u16_digits
    MOV AL,[dig10000]
    ADD AL,#'0'
    MOV [rec_d],AL
    MOV AL,[dig1000]
    ADD AL,#'0'
    MOV [rec_d+1],AL
    MOV AL,[dig100]
    ADD AL,#'0'
    MOV [rec_d+2],AL
    MOV AL,[dig10]
    ADD AL,#'0'
    MOV [rec_d+3],AL
    MOV AL,[dig1]
    ADD AL,#'0'
    MOV [rec_d+4],AL
    POP CH
    POP CL
    MOV BX,#s_record
    CALL puts
    RET

; --- save_record: si la puntuacion (16 bits) supera el record, lo graba en
; la flash. Sale AL = 1 si es record nuevo, 0 si no. -----------------------
save_record:
    MOV AL,[score_hi]
    MOV BL,[record_hi]
    CMP BL,AL
    JMPC svr_new            ; record_hi < score_hi
    JMPNZ svr_no            ; record_hi > score_hi
    MOV AL,[score_lo]
    MOV BL,[record_lo]
    CMP BL,AL
    JMPC svr_new            ; mismos altos, record_lo < score_lo
svr_no:
    MOV AL,#0
    RET
svr_new:
    OUT (P_EEP_LOAD),AL     ; parte del contenido real de la EEPROM
    MOV AL,[score_lo]
    MOV [record_lo],AL
    OUT (P_EEP_BASE+1),AL
    MOV AL,[score_hi]
    MOV [record_hi],AL
    OUT (P_EEP_BASE+2),AL
    MOV AL,#REC_MAGIC
    OUT (P_EEP_BASE),AL
    OUT (P_EEP_SAVE),AL
    MOV AL,#1
    RET

; --- show_new_record: graba el record si se ha batido y, si es asi, lo
; anuncia en CH=fila, CL=col ------------------------------------------------
show_new_record:
    PUSH CL
    PUSH CH
    CALL save_record
    POP CH
    POP CL
    CMP AL,#0
    JMPZ snr_done
    MOV BX,#s_newrec
    CALL puts
snr_done:
    RET

; --- show_game_over: mensaje simple en texto, espera a soltar y a pulsar
; DIRECCION antes de seguir (para no reiniciar de un solo toque sin querer)
show_game_over:
    CALL clst
    MOV BX,#msg_over
    MOV CX,#0x0306
    CALL puts
    MOV CX,#0x0505
    CALL show_new_record
    MOV BX,#GAMEOVER_TUNE
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
    MOV BX,#msg_win1
    MOV CX,#0x0204
    CALL puts
    MOV BX,#msg_win2
    MOV CX,#0x0403
    CALL puts
    MOV CX,#0x0605
    CALL show_new_record
    MOV BX,#VICTORY_TUNE
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
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
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
    MOV [tmp3],AL
    MOV CL,[tmp3]
    MOV BX,#PX_TO_ROW
    ADD BX,CL
    MOV AL,[BX]
    RET

px_to_col:
    MOV [tmp3],AL
    MOV CL,[tmp3]
    MOV BX,#PX_TO_COL
    ADD BX,CL
    MOV AL,[BX]
    RET

; --- row_to_px/col_to_px: entra AL = fila o columna ; sale AL =
; fila*CELL_H o columna*CELL_W -- igual razon, tabla en vez de un SHL.
row_to_px:
    MOV [tmp3],AL
    MOV CL,[tmp3]
    MOV BX,#ROW_PX
    ADD BX,CL
    MOV AL,[BX]
    RET

col_to_px:
    MOV [tmp3],AL
    MOV CL,[tmp3]
    MOV BX,#COL_PX
    ADD BX,CL
    MOV AL,[BX]
    RET

; --- calc_pix: de (px_x,px_y) saca puerto/offset (pix_lo/pix_hi) + mascara -
calc_pix:
    MOV CH,[px_y]
    MOV CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4
    MOV DL,CL
    SHR DL,#3
    OR  AL,DL
    MOV [pix_lo],AL
    MOV AL,CH
    SHR AL,#4
    MOV [pix_hi],AL
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
    MOV [pix_mask],DH
    RET

; --- shadow_set_px: enciende (px_x,px_y) en `shadow` --------------------
shadow_set_px:
    CALL calc_pix
    MOV BX,#shadow
    MOV CL,[pix_lo]
    ADD BX,CL
    MOV AL,[pix_hi]
    ADD BH,AL
    MOV AL,[BX]
    MOV DL,[pix_mask]
    OR  AL,DL
    MOV [BX],AL
    RET

; --- shadow_clear_px: apaga (px_x,px_y) en `shadow` (lo contrario de
; shadow_set_px) -- para dejar un fondo solido negro antes de dibujar algo
; encima (el marcador de corazones), por si una pared de la sala pasara
; justo por ahi.
shadow_clear_px:
    CALL calc_pix
    MOV BX,#shadow
    MOV CL,[pix_lo]
    ADD BX,CL
    MOV AL,[pix_hi]
    ADD BH,AL
    MOV AL,[BX]
    MOV DL,[pix_mask]
    NOT DL
    AND AL,DL
    MOV [BX],AL
    RET

; --- walls_set_px: enciende (px_x,px_y) en `walls` (draw_maze) ----------
walls_set_px:
    CALL calc_pix
    MOV BX,#walls
    MOV CL,[pix_lo]
    ADD BX,CL
    MOV AL,[pix_hi]
    ADD BH,AL
    MOV AL,[BX]
    MOV DL,[pix_mask]
    OR  AL,DL
    MOV [BX],AL
    RET

; --- fb_set_px: enciende (px_x,px_y) DIRECTO en el framebuffer real (no en
; `shadow`) -- para dibujos estaticos que no se repiten cada fotograma
; (la pantalla de titulo), sin necesitar todo el pipeline de doble buffer.
fb_set_px:
    CALL calc_pix
    MOV BX,#0x0000
    MOV CL,[pix_lo]
    ADD BX,CL
    MOV AL,[pix_hi]
    ADD BH,AL
    IN  AL,(BX)
    MOV DL,[pix_mask]
    OR  AL,DL
    OUT (BX),AL
    RET

; --- wall_test: entra (px_x,px_y) ; sale AL=0 si libre, !=0 si pared -----
wall_test:
    CALL calc_pix
    MOV BX,#walls
    MOV CL,[pix_lo]
    ADD BX,CL
    MOV AL,[pix_hi]
    ADD BH,AL
    MOV AL,[BX]
    MOV DL,[pix_mask]
    AND AL,DL
    RET

; --- clr_walls: pone a 0 los 1024 bytes de `walls` (ver la nota de
; clr_shadow: no vale el truco de contar paginas por BH, `walls` no empieza
; en un limite de pagina) -------------------------------------------------
clr_walls:
    ; pone a 0 el primer byte y deja que MOVB lo propague hacia delante
    ; (origen y destino solapados a 1 byte de distancia, copia siempre
    ; hacia adelante -- docs/isa.md SS4d): 1023 copias en una instruccion
    MOV AL,#0
    MOV [walls],AL
    MOV BX,#walls
    MOV DX,#walls+1
    MOV CX,#0x03FF
    MOVB
    RET

; --- copy_walls_to_shadow: `shadow` = `walls` (1024 bytes) --------------
copy_walls_to_shadow:
    MOV BX,#walls
    MOV DX,#shadow
    MOV CX,#0x0200          ; 512 palabras = 1024 bytes
    MOVW                    ; antes un bucle de 1024 vueltas (~8000 instr.)
    RET

; --- blit: copia `shadow` al framebuffer real, solo lo que cambie -------
blit:
    MOV BX,#0x0000
    MOV DX,#shadow
bl_l:
    IN  AL,(BX)
    MOV CL,[DX]
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

; --- clsg: apaga el framebuffer grafico completo ------------------------
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

; --- clst: borra la capa de texto (0x0400..0x04FF) ----------------------
clst:
    MOV DX,#0x0400
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
    MOV AL,[BX]
    CMP AL,#0
    JMPZ ps_d
    OUT (DX),AL
    INC BX
    INC DX
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
    MOV AL,[seed]
    SHR AL
    JMPNC rr_n
    XOR AL,#0xB8
rr_n:
    MOV [seed],AL
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
    MOV [pt_lo],AL
    MOV AL,BH
    MOV [pt_hi],AL
pt_nx:
    MOV BL,[pt_lo]
    MOV BH,[pt_hi]
    MOV AL,[BX]
    CMP AL,#0xFF
    JMPZ pt_done
    MOV [pt_note],AL
    CALL pt_inc

    MOV BL,[pt_lo]
    MOV BH,[pt_hi]
    MOV AL,[BX]
    MOV [pt_dur],AL
    CALL pt_inc

    MOV AL,[pt_note]
    OUT (P_SND_NOTE),AL
    MOV AL,[pt_dur]
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
    MOV AL,[pt_lo]
    ADD AL,#1
    MOV [pt_lo],AL
    JMPNC pt_inc_d
    MOV AL,[pt_hi]
    ADD AL,#1
    MOV [pt_hi],AL
pt_inc_d:
    RET

; --- draw_big_letter: dibuja una letra grande a partir de dos tablas de
; puntos (dx,dy en una rejilla de 5x7), cada punto ampliado a un bloque
; relleno de LETTER_SCALE x LETTER_SCALE con fb_set_px. Entra: BL/BH =
; tabla DX, DL/DH = tabla DY, y ya puestos [lp_n] (numero de puntos),
; [lp_x0]/[lp_y0] (esquina superior izquierda en pantalla).
draw_big_letter:
    MOV AL,BL
    MOV [lp_dx_lo],AL
    MOV AL,BH
    MOV [lp_dx_hi],AL
    MOV AL,DL
    MOV [lp_dy_lo],AL
    MOV AL,DH
    MOV [lp_dy_hi],AL

    MOV AL,#0
    MOV [j],AL
dbl_l:
    MOV CL,[j]
    MOV BL,[lp_dx_lo]
    MOV BH,[lp_dx_hi]
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp1],AL            ; dx (0-4)

    MOV CL,[j]
    MOV BL,[lp_dy_lo]
    MOV BH,[lp_dy_hi]
    ADD BX,CL
    MOV AL,[BX]
    MOV [tmp2],AL            ; dy (0-6)

    MOV CL,[tmp1]
    MOV BX,#MUL3
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[lp_x0]
    ADD AL,BL
    MOV [wx0],AL              ; x0 + dx*LETTER_SCALE

    MOV CL,[tmp2]
    MOV BX,#MUL3
    ADD BX,CL
    MOV AL,[BX]
    MOV BL,[lp_y0]
    ADD AL,BL
    MOV [wy0],AL              ; y0 + dy*LETTER_SCALE

    MOV AL,#0
    MOV [wk],AL
dbl_row:
    MOV AL,#0
    MOV [k],AL
dbl_col:
    MOV AL,[wx0]
    MOV BL,[k]
    ADD AL,BL
    MOV [px_x],AL
    MOV AL,[wy0]
    MOV BL,[wk]
    ADD AL,BL
    MOV [px_y],AL
    CALL fb_set_px

    MOV AL,[k]
    ADD AL,#1
    MOV [k],AL
    CMP AL,#LETTER_SCALE
    JMPNZ dbl_col

    MOV AL,[wk]
    ADD AL,#1
    MOV [wk],AL
    CMP AL,#LETTER_SCALE
    JMPNZ dbl_row

    MOV AL,[j]
    ADD AL,#1
    MOV [j],AL
    MOV BL,[lp_n]
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
    MOV [lp_y0],AL           ; misma fila (y) para las 6 letras

    MOV AL,#TITLE_X0
    MOV [lp_x0],AL
    MOV BX,#LETTER_S_DX
    MOV DX,#LETTER_S_DY
    MOV AL,#LETTER_S_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV AL,[lp_x0]
    ADD AL,#TITLE_STEP
    MOV [lp_x0],AL
    MOV BX,#LETTER_H_DX
    MOV DX,#LETTER_H_DY
    MOV AL,#LETTER_H_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV AL,[lp_x0]
    ADD AL,#TITLE_STEP
    MOV [lp_x0],AL
    MOV BX,#LETTER_A_DX
    MOV DX,#LETTER_A_DY
    MOV AL,#LETTER_A_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV AL,[lp_x0]
    ADD AL,#TITLE_STEP
    MOV [lp_x0],AL
    MOV BX,#LETTER_M_DX
    MOV DX,#LETTER_M_DY
    MOV AL,#LETTER_M_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV AL,[lp_x0]
    ADD AL,#TITLE_STEP
    MOV [lp_x0],AL
    MOV BX,#LETTER_U_DX
    MOV DX,#LETTER_U_DY
    MOV AL,#LETTER_U_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV AL,[lp_x0]
    ADD AL,#TITLE_STEP
    MOV [lp_x0],AL
    MOV BX,#LETTER_S_DX
    MOV DX,#LETTER_S_DY
    MOV AL,#LETTER_S_N
    MOV [lp_n],AL
    CALL draw_big_letter

    MOV BX,#title_sub
    MOV CX,#0x0404 ; centrado: (21-13)/2, "PRESS TO PLAY" son 13
    CALL puts
    MOV CX,#0x0604          ; "RECORD nnnnn" son 12: (21-12)/2 = 4
    CALL show_record

    IN  AL,(P_DAT_BTN)
    MOV [dat_btn_prev],AL
    IN  AL,(P_DIR_BTN)
    MOV [dir_btn_prev],AL

    ; la melodia suena UNA sola vez (con salida anticipada si se pulsa
    ; durante ella); si termina sin pulsar nada, se espera en silencio --
    ; nada de repetirla en bucle sin parar.
    MOV BX,#TITLE_TUNE
    CALL play_tune_check
    CMP AL,#0
    JMPNZ ts_done

ts_wait:
    IN  AL,(P_DAT_BTN)
    MOV BL,[dat_btn_prev]
    MOV [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ts_wait_dir
    CMP BL,#0
    JMPZ ts_done
ts_wait_dir:
    IN  AL,(P_DIR_BTN)
    MOV BL,[dir_btn_prev]
    MOV [dir_btn_prev],AL
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
    MOV [pt_lo],AL
    MOV AL,BH
    MOV [pt_hi],AL
ptc_nx:
    MOV BL,[pt_lo]
    MOV BH,[pt_hi]
    MOV AL,[BX]
    CMP AL,#0xFF
    JMPZ ptc_done_noplay
    MOV [pt_note],AL
    CALL pt_inc

    MOV BL,[pt_lo]
    MOV BH,[pt_hi]
    MOV AL,[BX]
    MOV [pt_dur],AL
    CALL pt_inc

    MOV AL,[pt_note]
    OUT (P_SND_NOTE),AL
    MOV AL,[pt_dur]
    CALL frame_wait
    MOV AL,#0
    OUT (P_SND_NOTE),AL

    IN  AL,(P_DAT_BTN)
    MOV BL,[dat_btn_prev]
    MOV [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ptc_chk_dir
    CMP BL,#0
    JMPZ ptc_pressed
ptc_chk_dir:
    IN  AL,(P_DIR_BTN)
    MOV BL,[dir_btn_prev]
    MOV [dir_btn_prev],AL
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

; MAX_KEY_OFFSET[k]: cuantas salas como mucho por delante de su candado
; (LOCK_ZONE_START+k) puede colgar el ramal de la llave k -- 0 en los primeros
; candados (aprendizaje), hasta 3 en los mas avanzados (ver plan_dungeon).
MAX_KEY_OFFSET: .db 0,0,0,0, 1,1,1,1,1, 2,2,2,2,2, 3,3,3,3,3,3
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

; GHOST_SPRITE: cabeza redondeada (3 px) + cuerpo ancho (2 filas de 5) +
; falda ondulada (3 puntos sueltos abajo)
GHOST_SPRITE_N = 16
GHOST_SPRITE_DX: .db 255,0,1, 254,255,0,1,2, 254,255,0,1,2, 254,0,2
GHOST_SPRITE_DY: .db 254,254,254, 255,255,255,255,255, 0,0,0,0,0, 1,1,1

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
s_record: .ascii "RECORD "
rec_d:    .asciiz "00000"
s_newrec: .asciiz "NEW RECORD!"

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
keys_used: .space 1     ; llaves gastadas en candados en esta partida (0..20)
seed:     .space 1

dir_pos_prev: .space 1
dat_pos_prev: .space 1

entry_side: .space 1
entry_row:  .space 1
entry_col:  .space 1
rc_row:     .space 1
rc_col:     .space 1

; --- planificacion de la mazmorra (plan_dungeon, ver la nota de cabecera
; "LLAVES Y PUERTAS") -- variables de escritorio propias, no compartidas ---
pd_i:     .space 1
pd_side:  .space 1
pd_nxt:   .space 1
pd_room:  .space 1
pd_tries: .space 1
pd_k:     .space 1     ; indice 0..19 del ramal forzado (pd_i-KEYBRANCH_START)
pd_dmod:  .space 1     ; MAX_KEY_OFFSET[pd_k]+1 (tope exclusivo del sorteo)
pd_d:     .space 1     ; salas por delante de su candado de las que cuelga el ramal

; --- salas persistentes (ver la nota de cabecera) ---
door_bits: .space 18    ; NCELLS -- literal, .space no admite constantes
key_cell:  .space 1
key_taken: .space 1
room0_entered: .space 1 ; puesto a 0 en new_game; a 1 por cross_room_gap justo
                         ; al CRUZAR hacia afuera de la sala 0 la primera vez
                         ; (ver la guarda de place_player_spawn: "centro de
                         ; pantalla" SOLO mientras esto siga a 0 -- en cuanto
                         ; se ha salido una vez, la sala 0 usa entry_side
                         ; como cualquier otra)
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
tmp5: .space 1
tmp6: .space 1
key_retry: .space 1    ; intentos de alejar la llave de la entrada

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
d:    .space 1          ; direccion 0..3 de trabajo -- reutilizada tal cual
                         ; por gen_and_save_current_room (bucle de los 4
                         ; lados de una sala) y choose_enemy_dir/ced_l1/
                         ; ced_l2 (bucle de las 4 direcciones de un
                         ; enemigo): nunca se solapan en el tiempo (una es
                         ; parte de generar una sala, la otra de jugar)
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
tmp4: .space 1
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

; --- escritorio de u16_digits (extraccion de digitos de 16 bits) ----------
nd_val_lo:   .space 1
nd_val_hi:   .space 1
record_lo:   .space 1     ; record cargado de la EEPROM (ver load_record)
record_hi:   .space 1

; --- estado persistente de hasta 50 salas (MAX_ROOMS -- literal, no una
; constante simbolica, por la misma razon que NCELLS en otros .space: casm.py
; resuelve los "NAME = EXPR" en una pasada posterior a calcular los .space)
room_link: .space 200           ; 50*4: por sala y lado, fijado ENTERO por
                                 ; plan_dungeon antes de generar ninguna sala
                                 ; -- 254=pared cerrada, sin sala; 0-49=sala
                                 ; real conectada por ese lado (ver la nota
                                 ; de cabecera "LLAVES Y PUERTAS")
room_entry_side: .space 50      ; lado (DIR_N..DIR_W) por el que se entra a
                                 ; cada sala, fijado por plan_dungeon (salvo
                                 ; la 0, que no tiene entrada real -- new_game
                                 ; le pone un valor al azar aparte, solo para
                                 ; orientar su laberinto interno)
room_timer_lo:  .space 1   ; fotogramas seguidos en la sala actual (16 bits)
room_timer_hi:  .space 1
ghost_threshold_lo: .space 1  ; = segundos_permitidos * GHOST_FPS (16 bits)
ghost_threshold_hi: .space 1
ghost_active:   .space 1
ghost_x:        .space 1
ghost_y:        .space 1
ghost_origin_x: .space 1   ; punto de aparicion: donde estaba el jugador al entrar
ghost_origin_y: .space 1
ghost_tone_timer: .space 1
ghost_tone_phase: .space 1 ; 0=Re, 1=Mi
ghost_move_cnt: .space 1   ; fotogramas hasta el siguiente paso
room_visited: .space 50         ; 0/1 por sala -- puesta a 1 la primera vez
                                 ; que se entra (cross_room_gap), para
                                 ; puntuar solo esa primera vez
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
