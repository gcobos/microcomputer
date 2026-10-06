; ============================================================================
;  lib/time.asm  -  esperas con el temporizador T3 (8 ms/paso)
;  Uso:  .include "time.asm"
; ============================================================================

; --- tm_wait: espera AL x 8 ms. Altera AL. ----------------------------------
tm_wait:
    OUT (0x0623),AL
tm_wait_l:
    IN  AL,(0x0623)
    CMP AL,#0
    JMPNZ tm_wait_l
    RET
