; ============================================================================
;  atributos.asm  -  muestra de atributos de texto (compi)
;
;  Pantalla estatica que enseña, una fila por atributo, lo que hace cada bit
;  del banco de atributos de texto (0x0500..0x05FF, pegado a la rejilla de
;  texto en 0x0400..0x04FF -- ver docs/isa.md §8). El programa dibuja una vez
;  y espera una pulsacion (DIRECCION o DATOS) para volver al sistema (slot
;  0). El parpadeo (bit ATTR_BLINK) lo anima el firmware al refrescar la
;  OLED, asi que no hace falta ningun bucle de dibujo.
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

    .name "TEXT ATTRIBS"

    .category UTILITY
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_BTN  = 0x0601     ; encoder DIRECCION: pulsado
P_DAT_BTN  = 0x0603     ; encoder DATOS: pulsado
P_PROG_LOAD = 0x0640    ; cargar slot (OUT nº de slot): salto a otro programa

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
    ; fin: espera a que se pulse DIRECCION o DATOS, espera a que se suelten
    ; los dos (para que el sistema no vea la pulsacion como suya) y vuelve al
    ; sistema (sisop, slot 0)
wk_p:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPNZ wk_r
    IN  AL,(P_DAT_BTN)
    CMP AL,#0
    JMPZ wk_p
wk_r:
    IN  AL,(P_DIR_BTN)
    CMP AL,#0
    JMPNZ wk_r
    IN  AL,(P_DAT_BTN)
    CMP AL,#0
    JMPNZ wk_r
    MOV AL,#0
    OUT (P_PROG_LOAD),AL       ; vuelve al sistema (sisop, slot 0)
    HALT                       ; solo si el slot 0 estuviera vacio (la carga no hace nada)

; ============================================================================
;  DIBUJO (una sola vez)
; ============================================================================
draw:
    MOV BX,#s_title
    MOV CX,#0x0001
    MOV AH,#0
    CALL puts_attr

    MOV BX,#s_inv
    MOV CX,#0x0101
    MOV AH,#ATTR_INVERSE
    CALL puts_attr

    MOV BX,#s_blk
    MOV CX,#0x0201
    MOV AH,#ATTR_BLINK
    CALL puts_attr

    MOV BX,#s_und
    MOV CX,#0x0301
    MOV AH,#ATTR_UNDERLINE
    CALL puts_attr

    MOV BX,#s_str
    MOV CX,#0x0401
    MOV AH,#ATTR_STRIKE
    CALL puts_attr

    ; --- fila 5: H(2)O   X(2) -- solo el "2" lleva sub/superindice ---------
    MOV BX,#'H'
    MOV CX,#0x0501
    CALL set_cell
    MOV BX,#ATTR_SUBSCRIPT*256+('2')
    MOV CX,#0x0502
    CALL set_cell
    MOV BX,#'O'
    MOV CX,#0x0503
    CALL set_cell
    MOV BX,#'X'
    MOV CX,#0x0508
    CALL set_cell
    MOV BX,#ATTR_SUPERSCRIPT*256+('2')
    MOV CX,#0x0509
    CALL set_cell

    ; --- fila 6: una "R" en cada rotacion, con su angulo al lado -----------
    MOV BX,#'R'
    MOV CX,#0x0600
    CALL set_cell
    MOV BX,#s_r0
    MOV CX,#0x0602
    MOV AH,#0
    CALL puts_attr

    MOV BX,#ATTR_ROT90*256+('R')
    MOV CX,#0x0604
    CALL set_cell
    MOV BX,#s_r90
    MOV CX,#0x0606
    MOV AH,#0
    CALL puts_attr

    MOV BX,#ATTR_ROT180*256+('R')
    MOV CX,#0x0609
    CALL set_cell
    MOV BX,#s_r180
    MOV CX,#0x060B
    MOV AH,#0
    CALL puts_attr

    MOV BX,#ATTR_ROT270*256+('R')
    MOV CX,#0x060F
    CALL set_cell
    MOV BX,#s_r270
    MOV CX,#0x0611
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
    INC BX
    INC DX
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
s_title: .asciiz "TEXT ATTRIBUTES"
s_inv:   .asciiz "INVERSE"
s_blk:   .asciiz "BLINK"
s_und:   .asciiz "UNDERLINE"
s_str:   .asciiz "STRIKE"
s_r0:    .asciiz "0"
s_r90:   .asciiz "90"
s_r180:  .asciiz "180"
s_r270:  .asciiz "270"
