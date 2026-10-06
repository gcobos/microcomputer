; ============================================================================
;  lib/text.asm  -  rejilla de texto (21 columnas x 8 filas, 0x0400+)
;  Uso:  .include "text.asm"
;  Convencion: CH = fila, CL = columna. Las rutinas que escriben dejan CL
;  justo detras de lo escrito, para poder encadenar.
; ============================================================================

; --- txt_puts: BX = cadena asciiz -> en CH/CL; avanza CL --------------------
; Altera AL, BX, DX.
txt_puts:
    LDA AL,[BX]
    CMP AL,#0
    JMPZ txt_puts_d
    CALL txt_putc
    INC BX
    JMP txt_puts
txt_puts_d:
    RET

; --- txt_putc: AL = caracter -> en CH/CL; avanza CL. Altera DX. -------------
txt_putc:
    PUSH AL
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    POP AL
    OUT (DX),AL
    ADD CL,#1
    RET

; --- txt_put2: AL (0..99) en 2 cifras; avanza CL. Altera AH, DX. -----------
txt_put2:
    MOV AH,#0
    MOV DL,#10
    DIV DL
    PUSH AH
    ADD AL,#'0'
    CALL txt_putc
    POP AL
    ADD AL,#'0'
    CALL txt_putc
    RET

; --- txt_put3: AL (0..255) en 3 cifras; avanza CL. Altera AH, DX. ----------
txt_put3:
    MOV AH,#0
    MOV DL,#100
    DIV DL
    PUSH AH
    ADD AL,#'0'
    CALL txt_putc
    POP AL
    CALL txt_put2
    RET

; --- txt_clear: borra todo el texto y sus atributos (0x0400-0x05FF) --------
; Altera AL, BX.
txt_clear:
    MOV BX,#0x0400
    MOV AL,#0
txt_clear_l:
    OUT (BX),AL
    INC BX
    CMP BH,#0x06
    JMPNZ txt_clear_l
    RET

; --- txt_clear_row: borra la fila CH (texto y atributos). Altera AL, DX. ---
txt_clear_row:
    PUSH CL
    MOV AL,CH
    SHL AL,#5
    MOV DL,AL
    MOV DH,#0x04
    MOV CL,#21
    MOV AL,#0
txt_cr_l:
    OUT (DX),AL
    ADD DH,#1
    OUT (DX),AL              ; atributo de la misma celda (0x0500+)
    SUB DH,#1
    INC DX
    SUB CL,#1
    JMPNZ txt_cr_l
    POP CL
    RET

; --- txt_attr_row: pone el atributo AL a toda la fila CH. Altera DX. -------
txt_attr_row:
    PUSH CL
    PUSH AL
    MOV AL,CH
    SHL AL,#5
    MOV DL,AL
    MOV DH,#0x05
    POP AL
    MOV CL,#21
txt_ar_l:
    OUT (DX),AL
    INC DX
    SUB CL,#1
    JMPNZ txt_ar_l
    POP CL
    RET
