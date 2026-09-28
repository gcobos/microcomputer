.org 0x0000
.slot 11

L0000:
    MOV AL,#0x01  
    OUT (0x0610),AL          ;
    CALL WAIT                ; 
    MOV AL,#0x00             ; 
    OUT (0x0610),AL          ; 
    CALL WAIT                ; 
    JMP L0000                ; 
    NOP                      ; 

WAIT:
    MOV AH,#0x02             ;
    OUT (0x0629),AH          ;
L000A:
    IN AH,(0x0629)           ;
    CMP AH,#0x00             ;
    JMPNZ L000A              ;
    RET