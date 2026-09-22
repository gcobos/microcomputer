.org 0x0000
.slot 11

L0000:
    MOV AL,#0x01             ; 0000
    OUT (0x0610),AL          ; 0002
    CALL WAIT                ; 0005
    MOV AL,#0x00             ; 0012
    OUT (0x0610),AL          ; 0014
    CALL WAIT                ; 0021
    JMP L0000                ; 0024
    NOP                      ; 0027

WAIT:
    MOV AH,#0x02             ;
    OUT (0x0629),AH          ;
L000A:
    IN AH,(0x0629)           ;
    CMP AH,#0x00             ;
    JMPNZ L000A              ;
    RET