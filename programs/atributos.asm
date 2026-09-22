; ============================================================================
;  atributos.asm  -  muestra de atributos de texto (compi)
;
;  Pantalla estatica que enseña, una fila por atributo, lo que hace cada bit
;  del banco de atributos de texto (0x0500..0x05FF, pegado a la rejilla de
;  texto en 0x0400..0x04FF -- ver docs/isa.md §8). El programa dibuja una vez
;  y hace HALT: el parpadeo (bit ATTR_BLINK) lo sigue animando el firmware al
;  refrescar la OLED (renderFramebuffer se llama igual con la CPU parada), asi
;  que no hace falta ningun bucle.
;
;  Filas:
;     0  titulo
;     1  INVERSO      (video inverso)
;     2  PARPADEA      (parpadea solo, sin ayuda de la CPU)
;     3  SUBRAYADO
;     4  TACHADO
;     5  H2O / X2      (subindice / superindice: solo el "2" se desplaza)
;     6  R normal, 90, 180 y 270 grados (rotacion del glifo, sentido horario)
;
;  Como el puerto de atributos de una celda es el mismo que el de texto mas
;  0x0100 (attrPort = textPort + 0x0100, ver include/iomap.h), basta con
;  escribir el caracter en (DX) y el atributo en (DX+0x0100): ver puts_attr y
;  set_cell mas abajo.
;
;  Sin controles: se queda en pantalla hasta que se vuelva a EDITAR.
;
;  Ensamblar y enviar al slot 6:
;     python3 tools/casm.py programs/atributos.asm -o programs/atributos.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/atributos.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 6
    .org 0x0000

; --- atributos (ver include/iomap.h) ----------------------------------------
ATTR_INVERSE     = 0x01
ATTR_BLINK       = 0x02
ATTR_UNDERLINE   = 0x04
ATTR_STRIKE      = 0x08
ATTR_SUBSCRIPT   = 0x10
ATTR_SUPERSCRIPT = 0x20
ATTR_ROT90       = 0x40
ATTR_ROT180      = 0x80
ATTR_ROT270      = 0xC0

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL draw
    HALT

; ============================================================================
;  DIBUJO (una sola vez)
; ============================================================================
draw:
    MOV BL,#lo(s_title)
    MOV BH,#hi(s_title)
    MOV CL,#1
    MOV CH,#0
    MOV AH,#0
    CALL puts_attr

    MOV BL,#lo(s_inv)
    MOV BH,#hi(s_inv)
    MOV CL,#1
    MOV CH,#1
    MOV AH,#ATTR_INVERSE
    CALL puts_attr

    MOV BL,#lo(s_blk)
    MOV BH,#hi(s_blk)
    MOV CL,#1
    MOV CH,#2
    MOV AH,#ATTR_BLINK
    CALL puts_attr

    MOV BL,#lo(s_und)
    MOV BH,#hi(s_und)
    MOV CL,#1
    MOV CH,#3
    MOV AH,#ATTR_UNDERLINE
    CALL puts_attr

    MOV BL,#lo(s_str)
    MOV BH,#hi(s_str)
    MOV CL,#1
    MOV CH,#4
    MOV AH,#ATTR_STRIKE
    CALL puts_attr

    ; --- fila 5: H(2)O   X(2) -- solo el "2" lleva sub/superindice ---------
    MOV BL,#'H'
    MOV BH,#0
    MOV CL,#1
    MOV CH,#5
    CALL set_cell
    MOV BL,#'2'
    MOV BH,#ATTR_SUBSCRIPT
    MOV CL,#2
    MOV CH,#5
    CALL set_cell
    MOV BL,#'O'
    MOV BH,#0
    MOV CL,#3
    MOV CH,#5
    CALL set_cell
    MOV BL,#'X'
    MOV BH,#0
    MOV CL,#8
    MOV CH,#5
    CALL set_cell
    MOV BL,#'2'
    MOV BH,#ATTR_SUPERSCRIPT
    MOV CL,#9
    MOV CH,#5
    CALL set_cell

    ; --- fila 6: una "R" en cada rotacion, con su angulo al lado -----------
    MOV BL,#'R'
    MOV BH,#0
    MOV CL,#0
    MOV CH,#6
    CALL set_cell
    MOV BL,#lo(s_r0)
    MOV BH,#hi(s_r0)
    MOV CL,#2
    MOV CH,#6
    MOV AH,#0
    CALL puts_attr

    MOV BL,#'R'
    MOV BH,#ATTR_ROT90
    MOV CL,#4
    MOV CH,#6
    CALL set_cell
    MOV BL,#lo(s_r90)
    MOV BH,#hi(s_r90)
    MOV CL,#6
    MOV CH,#6
    MOV AH,#0
    CALL puts_attr

    MOV BL,#'R'
    MOV BH,#ATTR_ROT180
    MOV CL,#9
    MOV CH,#6
    CALL set_cell
    MOV BL,#lo(s_r180)
    MOV BH,#hi(s_r180)
    MOV CL,#11
    MOV CH,#6
    MOV AH,#0
    CALL puts_attr

    MOV BL,#'R'
    MOV BH,#ATTR_ROT270
    MOV CL,#15
    MOV CH,#6
    CALL set_cell
    MOV BL,#lo(s_r270)
    MOV BH,#hi(s_r270)
    MOV CL,#17
    MOV CH,#6
    MOV AH,#0
    CALL puts_attr

    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================

; --- puts_attr:  BL/BH = puntero asciiz,  CL = col,  CH = fila,  AH = atr --
;     Escribe la cadena en el texto y aplica AH como atributo a cada una de
;     sus celdas (mismo valor para toda la cadena). No hay salto de linea:
;     la cadena debe caber desde CL hasta el final de la fila (col < 21).
puts_attr:
    MOV AL,CH
    SHL AL,#5                   ; fila*32
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04                ; puerto texto = 0x0400 + fila*32 + col
pa_l:
    LDA AL,[BX]
    CMP AL,#0
    JMPZ pa_d
    OUT (DX),AL                 ; celda de texto
    ADD DH,#1
    OUT (DX),AH                 ; celda de atributos (mismo puerto + 0x0100)
    SUB DH,#1
    ADD BL,#1
    JMPNC pa_nb
    ADD BH,#1
pa_nb:
    ADD DL,#1
    JMPNC pa_l
    ADD DH,#1
    JMP pa_l
pa_d:
    RET

; --- set_cell:  BL = caracter,  BH = atributo,  CL = col,  CH = fila ------
;     Escribe un unico caracter y su atributo en una celda.
set_cell:
    MOV AL,CH
    SHL AL,#5                   ; fila*32
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
    ADD DH,#1
    OUT (DX),BH
    RET

; ============================================================================
;  DATOS
; ============================================================================
s_title: .asciiz "ATRIBUTOS DE TEXTO"
s_inv:   .asciiz "INVERSO"
s_blk:   .asciiz "PARPADEA"
s_und:   .asciiz "SUBRAYADO"
s_str:   .asciiz "TACHADO"
s_r0:    .asciiz "0"
s_r90:   .asciiz "90"
s_r180:  .asciiz "180"
s_r270:  .asciiz "270"
