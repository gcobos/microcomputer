; ============================================================================
;  lib/gfx.asm  -  framebuffer (128x64, 1 bit, 0x0000-0x03FF)
;  Uso:  .include "gfx.asm"
; ============================================================================

; --- gfx_clear: apaga toda la pantalla grafica. Altera AL, BX. -------------
gfx_clear:
    MOV BX,#0x0000
    MOV AL,#0
gfx_clear_l:
    OUT (BX),AL
    INC BX
    CMP BH,#0x04
    JMPNZ gfx_clear_l
    RET

; --- gfx_pixel: pixel (AL = x 0..127, AH = y 0..63) a CL (1 = encendido,
; 0 = apagado), leyendo y reescribiendo su byte. Altera AX, BX, DX. --------
gfx_pixel:
    PUSH AL
    MOV AL,AH
    MOV BL,#16
    MUL BL                   ; AX = y*16
    MOV BL,AL
    MOV BH,AH
    POP AL
    PUSH AL
    SHR AL,#3
    ADD BX,AL                ; BX = puerto del byte
    POP AL
    AND AL,#7
    MOV DX,#gfx_mask8
    ADD DX,AL
    LDA DL,[DX]              ; DL = mascara del bit
    IN  AL,(BX)
    CMP CL,#0
    JMPZ gfx_px_off
    OR  AL,DL
    OUT (BX),AL
    RET
gfx_px_off:
    NOT DL
    AND AL,DL
    OUT (BX),AL
    RET

gfx_mask8: .db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
