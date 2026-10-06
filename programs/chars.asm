; ============================================================================
;  chars.asm  -  mapa de caracteres (compi)
;
;  Muestra el juego de caracteres completo (0x20-0x7F, los imprimibles) en
;  la rejilla de texto, 21 por fila. Extraido del antiguo demo.asm (ahi
;  vivia dentro de la opcion "2 TEXTO", tras el efecto de maquina de
;  escribir) como utilidad independiente.
;
;  La ultima fila (7, la unica que sobra tras la rejilla) muestra ademas
;  una "A" con cada uno de los 4 atributos de formato aplicado -- inverso,
;  parpadeo, subrayado y tachado (ver programs/atributos.asm para la lista
;  completa de atributos, incluidos subindice/superindice y rotacion, con
;  mas sitio para explicarlos).
;
;  Dibuja una vez y se queda en pantalla hasta que se pulse DIRECCION o
;  DATOS, y entonces vuelve al sistema (carga el slot 0, ver
;  programs/sisop.asm).
;
;  Ensamblar y enviar al slot 15:
;     python3 tools/casm.py programs/chars.asm -o programs/chars.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 15 programs/chars.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 15

    .name "CHARACTER MAP"

    .category UTILITY
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_TEXT = 0x0400      ; rejilla de texto
P_PROG_LOAD = 0x0640     ; cargar slot (OUT nº de slot): salto a otro programa
P_DIR_BTN  = 0x0601     ; encoder DIRECCION: pulsado
P_DAT_BTN  = 0x0603     ; encoder DATOS: pulsado

; --- atributos (ver include/iomap.h) ----------------------------------------
ATTR_INVERSE   = 0x01
ATTR_BLINK     = 0x02
ATTR_UNDERLINE = 0x04
ATTR_STRIKE    = 0x08

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV BX,#s_title
    MOV CX,#0x0001
    CALL puts
    CALL show_charset
    CALL show_attrs
    JMP wait_key_exit

; --- show_attrs: fila 7, una "A" con cada atributo de formato aplicado,
; con su etiqueta de 1 letra delante ("I:A B:A U:A S:A").
show_attrs:
    MOV BX,#s_i
    MOV CX,#0x0700
    CALL puts
    MOV BX,#ATTR_INVERSE*256+('A')
    MOV CX,#0x0702
    CALL set_cell

    MOV BX,#s_b
    MOV CX,#0x0704
    CALL puts
    MOV BX,#ATTR_BLINK*256+('A')
    MOV CX,#0x0706
    CALL set_cell

    MOV BX,#s_u
    MOV CX,#0x0708
    CALL puts
    MOV BX,#ATTR_UNDERLINE*256+('A')
    MOV CX,#0x070A
    CALL set_cell

    MOV BX,#s_s
    MOV CX,#0x070C
    CALL puts
    MOV BX,#ATTR_STRIKE*256+('A')
    MOV CX,#0x070E
    CALL set_cell
    RET

; --- set_cell: BL = caracter, BH = atributo, CL = col, CH = fila -----------
; escribe un unico caracter y su atributo (mismo puerto + 0x0100, ver
; include/iomap.h) en una celda.
set_cell:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    OUT (DX),BL
    ADD DH,#1
    OUT (DX),BH
    RET

; --- show_charset: vuelca 0x20..0x7F en la rejilla, 21 por fila, empezando
; en la fila 2 (deja la 0 para el titulo y la 1 en blanco de separacion) --
; 96 caracteres / 21 por fila = 5 filas (2..6), la 7 queda libre.
show_charset:
    MOV AL,#0x20
    STA [cs_ch],AL
    MOV AL,#0
    STA [cs_col],AL
    MOV AL,#2
    STA [cs_row],AL
sc_l:
    LDA AL,[cs_row]
    SHL AL,#5                 ; fila*32
    LDA BL,[cs_col]
    ADD AL,BL
    MOV DL,AL
    MOV DH,#0x04               ; puerto texto = 0x0400 + fila*32 + col
    LDA AL,[cs_ch]
    OUT (DX),AL
    LDA AL,[cs_ch]
    ADD AL,#1
    STA [cs_ch],AL
    CMP AL,#0x80
    JMPZ sc_d
    LDA AL,[cs_col]
    ADD AL,#1
    STA [cs_col],AL
    CMP AL,#21
    JMPNZ sc_l
    MOV AL,#0
    STA [cs_col],AL
    LDA AL,[cs_row]
    ADD AL,#1
    STA [cs_row],AL
    JMP sc_l
sc_d:
    RET

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

; --- clst: limpia la rejilla de texto entera (0x0400-0x04FF) ---------------
clst:
    MOV DX,#0x0400
    MOV AL,#0
clst_l:
    OUT (DX),AL
    ADD DL,#1
    JMPNZ clst_l
    RET

; --- wait_key_exit: espera a que se pulse DIRECCION o DATOS, espera a que se
; suelten los dos (para que el sistema no vea la pulsacion como suya) y
; vuelve al sistema (sisop, slot 0). ------------------------------------------
wait_key_exit:
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
;  DATOS
; ============================================================================
s_title: .asciiz "CHARACTER SET"
s_i:     .asciiz "I:"
s_b:     .asciiz "B:"
s_u:     .asciiz "U:"
s_s:     .asciiz "S:"

cs_ch:  .space 1
cs_col: .space 1
cs_row: .space 1
