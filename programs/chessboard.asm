.org 0x0000
.slot 12
.name "CHESSBOARD"
.category DEMO

L0000:
    MOV AX,#0x00FF ; Blanco
                            ; Negro
    MOV DL,#64          ; Lineas en blanco -> negro
    MOV CX,#0x0000 ; CX Puntero a la pantalla
L0006:
    OUT (CX),AL         ; Dibuja una linea de la casilla
    ADD CL,#0x01        ; Incrementa el puntero
    OUT (CX),AH         ; Dibuja una linea de la casilla
    ADD CL,#0x01        ; Incrementa el puntero
    SUB DL,#0x01        ; Casilla terminada?
    JMPNZ DRAWING       ; No, pues sigue dibujando
    MOV BL, AH          ; Intercambia AH por AL
    MOV AH, AL
    MOV AL, BL
    MOV DL, #64         ; Reinicia el contador de lineas
DRAWING:
    CMP CL,#0           ; 0 = 256
    JMPNZ L0006
    MOV CL,#0
    ADD CH,#1
    CMP CH,#4
    JMPNZ L0006
WAIT_FOR_KEY:               ; Espera a que se pulse,
wk_p:                       ; Y luego se suelten las teclas
    IN  AL,(0x601)
    CMP AL,#0
    JMPNZ wk_r
    IN  AL,(0x603)
    CMP AL,#0
    JMPZ wk_p
wk_r:
    IN  AL,(0x601)
    CMP AL,#0
    JMPNZ wk_r
    IN  AL,(0x603)
    CMP AL,#0
    JMPNZ wk_r
    MOV AL,#0           ; Vuelve al sistema
    OUT (0x640),AL
