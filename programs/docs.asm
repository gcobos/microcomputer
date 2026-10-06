; ============================================================================
;  docs.asm  -  Documentacion de compi para programar, navegable desde el
;  propio panel: temas (PORTS, ISA, PANEL) con varias paginas de texto cada
;  uno, condensadas de docs/isa.md, include/iomap.h y specs.txt. (FIRMWARE y
;  HARDWARE se quitaron: no hacen falta para usar el aparato.)
;
;  Mismo esquema de navegacion que sisop.asm (menu de carpetas), pero con dos
;  niveles fijos -- tema y pagina -- en vez de carpeta y programa:
;    - Girar CUALQUIERA de los dos encoders mueve a la pagina anterior o
;      siguiente del nivel actual (lista de temas, o paginas dentro de un
;      tema), sin dar la vuelta en los extremos.
;    - Pulsar DATOS entra en el nivel siguiente: desde la lista de temas,
;      abre ese tema en su primera pagina; dentro de un tema no hay mas
;      niveles (las paginas son hojas), asi que no hace nada.
;    - Pulsar DIRECCION vuelve al nivel padre: desde una pagina, a la lista
;      de temas; desde la lista de temas, sale de este programa y vuelve al
;      sistema (slot 0, sisop.asm).
;
;  Ensamblar y enviar (numero de slot en la propia ".slot" de abajo):
;     python3 tools/casm.py programs/docs.asm -o programs/docs.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 programs/docs.asm
;
;  Probar sin el aparato:
;     python3 tools/sim.py programs/docs.bin --steps 500000
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 16

    .name "DOCUMENTATION"

    .category DOCS
    .org 0x0000

; --- puertos (ver ../docs/isa.md) -------------------------------------------
P_DIR_POS   = 0x0600
P_DIR_BTN   = 0x0601
P_DAT_POS   = 0x0602
P_DAT_BTN   = 0x0603
P_PROG_LOAD = 0x0640

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    CALL clst
    MOV AL,#0
    STA [view],AL               ; 0 = lista de temas, 1 = pagina de un tema
    STA [cur_topic],AL
    STA [cur_page],AL

    IN  AL,(P_DIR_POS)
    STA [dir_pos_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_pos_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL

    CALL redraw

main_l:
    ; --- encoder DIRECCION: pagina anterior/siguiente --------------------
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_pos_prev],CL
    CMP AL,#0
    JMPZ ml_datpos

    AND AL,#0x80
    JMPZ ml_down
    CALL move_prev
    JMP ml_datpos
ml_down:
    CALL move_next

ml_datpos:
    ; --- encoder DATOS: TAMBIEN pagina anterior/siguiente (mismo sentido
    ; que DIRECCION -- se puede hojear con cualquiera de los dos) ---------
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_pos_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_pos_prev],CL
    CMP AL,#0
    JMPZ ml_datbtn

    AND AL,#0x80
    JMPZ ml_datdown
    CALL move_prev
    JMP ml_datbtn
ml_datdown:
    CALL move_next

ml_datbtn:
    ; --- pulsador DATOS: entra en el nivel siguiente ----------------------
    IN  AL,(P_DAT_BTN)
    LDA BL,[dat_btn_prev]
    STA [dat_btn_prev],AL
    CMP AL,#0
    JMPZ ml_dirbtn
    CMP BL,#0
    JMPNZ ml_dirbtn         ; ya estaba pulsado -- no es un flanco nuevo
    CALL on_select

ml_dirbtn:
    ; --- pulsador DIRECCION: vuelve al nivel padre ------------------------
    IN  AL,(P_DIR_BTN)
    LDA BL,[dir_btn_prev]
    STA [dir_btn_prev],AL
    CMP AL,#0
    JMPZ ml_wait
    CMP BL,#0
    JMPNZ ml_wait
    CALL on_back

ml_wait:
    MOV AL,#2
    CALL frame_wait
    JMP main_l

; --- move_prev/move_next: cambian cur_topic (view=0) o cur_page (view=1),
; con tope en 0 y en el numero de elementos del nivel actual (nunca dan la
; vuelta -- igual que sisop.asm).
move_prev:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ mp_page
    LDA AL,[cur_topic]
    CMP AL,#0
    JMPZ mp_ret
    SUB AL,#1
    STA [cur_topic],AL
    JMP mp_redraw
mp_page:
    LDA AL,[cur_page]
    CMP AL,#0
    JMPZ mp_ret
    SUB AL,#1
    STA [cur_page],AL
mp_redraw:
    CALL redraw
mp_ret:
    RET

move_next:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ mn_page
    LDA AL,[cur_topic]
    ADD AL,#1
    CMP AL,#NUM_TOPICS
    JMPC mn_store_t
    RET                     ; ya en el ultimo tema -- sin cambios
mn_store_t:
    STA [cur_topic],AL
    JMP mn_redraw
mn_page:
    LDA AL,[cur_page]
    ADD AL,#1
    LDA BL,[cur_topic_pages]
    CMP AL,BL
    JMPC mn_store_p
    RET                     ; ya en la ultima pagina del tema
mn_store_p:
    STA [cur_page],AL
mn_redraw:
    CALL redraw
    RET

; --- on_select: en la lista de temas, entra en el marcado (primera pagina).
; Dentro de un tema no hay mas niveles -- no hace nada (las paginas son hojas).
on_select:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ os_ret

    MOV AL,#1
    STA [view],AL
    MOV AL,#0
    STA [cur_page],AL
    MOV BX,#TOPIC_PAGE_COUNTS
    LDA CL,[cur_topic]
    ADD BX,CL
    LDA AL,[BX]
    STA [cur_topic_pages],AL
    CALL redraw
os_ret:
    RET

; --- on_back: de una pagina, vuelve a la lista de temas; de la lista de
; temas, sale de este programa y vuelve al sistema (slot 0).
on_back:
    LDA AL,[view]
    CMP AL,#0
    JMPZ ob_exit
    MOV AL,#0
    STA [view],AL
    CALL redraw
    RET
ob_exit:
    MOV AL,#0
    OUT (P_PROG_LOAD),AL
    ; si sigue aqui, el slot 0 estaba vacio -- se queda tal cual
    RET

; ============================================================================
;  DIBUJO
; ============================================================================
redraw:
    LDA AL,[view]
    CMP AL,#0
    JMPNZ rd_page
    CALL redraw_topics
    RET
rd_page:
    CALL draw_page
    RET

redraw_topics:
    CALL clst
    MOV BX,#s_title
    MOV CX,#0x0000
    CALL puts

    MOV AL,#0
    STA [i],AL
rdt_l:
    LDA AL,[i]
    LDA BL,[cur_topic]
    CMP AL,BL
    JMPNZ rdt_nomark
    MOV BX,#s_mark
    JMP rdt_domark
rdt_nomark:
    MOV BX,#s_nomark
rdt_domark:
    MOV CL,#2
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    MOV BX,#TOPIC_NAMES
    LDA AL,[i]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16
    MOV CL,#4
    LDA AL,[i]
    ADD AL,#2
    MOV CH,AL
    CALL puts

    LDA AL,[i]
    ADD AL,#1
    STA [i],AL
    CMP AL,#NUM_TOPICS
    JMPNZ rdt_l
    RET

; --- draw_page: cabecera en fila 0 (nombre del tema + pagina/total) y
; contenido en filas 1-7 (la pagina lleva su propio subtitulo como primera
; linea del contenido).
draw_page:
    CALL clst
    MOV BX,#TOPIC_NAMES
    LDA AL,[cur_topic]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16          ; BX = puntero al nombre del tema
    CALL draw_header

    MOV BX,#TOPIC_PAGE_TABLES
    LDA AL,[cur_topic]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16          ; BX = tabla de paginas de este tema
    LDA AL,[cur_page]
    SHL AL,#1
    MOV CL,AL
    CALL read_ptr16          ; BX = puntero al contenido de esta pagina
    CALL draw_content
    RET

; --- draw_header: BX = puntero al nombre del tema (asciiz). Escribe en la
; fila 0: "NOMBRE P/N" (P = pagina actual 1-indexada, N = total de paginas;
; put_dec2 escribe cada una en 1 o 2 cifras segun haga falta -- ver su
; comentario, ningun tema por encima de 9 paginas se comia ya la segunda
; cifra, "PORTS" fue el primero en llegar a 10).
draw_header:
    MOV DX,#0x0400
dh_l:
    LDA AL,[BX]
    CMP AL,#0
    JMPZ dh_name_done
    OUT (DX),AL
    INC BX
    ADD DL,#1
    JMP dh_l
dh_name_done:
    MOV AL,#0x20            ; espacio
    OUT (DX),AL
    ADD DL,#1
    LDA AL,[cur_page]
    ADD AL,#1
    CALL put_dec2            ; pagina actual (1-indexada), 1 o 2 cifras
    MOV AL,#0x2F              ; '/'
    OUT (DX),AL
    ADD DL,#1
    LDA AL,[cur_topic_pages]
    CALL put_dec2            ; total de paginas del tema, 1 o 2 cifras
    RET

; --- put_dec2: AL = valor 0-99 a escribir en decimal; DX = puerto de texto
; de la celda donde va la primera cifra. Sin cero a la izquierda: un solo
; digito si AL<10, decenas+unidades si AL>=10 (nunca un "10" partido en dos
; celdas de golpe con un simbolo raro en medio, que es justo lo que pasaba
; antes con "ADD AL,#0x30" a secas para un valor de dos cifras: 10+0x30 =
; 0x3A = ':', no "10"). Deja DL avanzado a la celda siguiente a la ultima
; cifra escrita, listo para seguir escribiendo detras (p.ej. el "/" o lo que
; venga despues en draw_header).
put_dec2:
    CMP AL,#10
    JMPC pd2_one              ; AL<10: una sola cifra
    MOV AH,#0
    MOV BL,#10
    DIV BL                    ; AL=decenas (1-9), AH=unidades (0-9)
    ADD AL,#0x30
    OUT (DX),AL
    ADD DL,#1
    MOV AL,AH
    ADD AL,#0x30
    OUT (DX),AL
    ADD DL,#1
    RET
pd2_one:
    ADD AL,#0x30
    OUT (DX),AL
    ADD DL,#1
    RET

; --- draw_content: BX = puntero a texto con "\n" (0x0A) como salto de
; linea, terminado en 0. Empieza en fila 1 columna 0 (fila 0 es la
; cabecera); cada tema tiene como mucho 7 lineas de contenido, asi que
; nunca se sale de la rejilla de 8 filas.
draw_content:
    MOV AL,#1
    STA [content_row],AL
    MOV AL,#0
    STA [content_col],AL
dc_l:
    LDA AL,[BX]
    CMP AL,#0
    JMPZ dc_done
    CMP AL,#0x0A
    JMPZ dc_newline

    LDA CL,[content_row]
    MOV AL,CL
    SHL AL,#5
    LDA CL,[content_col]
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    LDA AL,[BX]
    OUT (DX),AL
    LDA AL,[content_col]
    ADD AL,#1
    STA [content_col],AL
    JMP dc_adv

dc_newline:
    LDA AL,[content_row]
    ADD AL,#1
    STA [content_row],AL
    MOV AL,#0
    STA [content_col],AL

dc_adv:
    INC BX
    JMP dc_l
dc_done:
    RET

; --- puts:  BL/BH = puntero asciiz,  CL = col,  CH = fila -------------------
; solo altera AL/DL/DH (y BL/BH, que ya no hacen falta al terminar).
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

; --- idx_ptr: BX += CL (con acarreo a BH) -----------------------------------
idx_ptr:
    ADD BX,CL               ; antes: ADD BL,CL / JMPNC / ADD BH,#1 --
                              ; ahora 1 instruccion (dst16+=src8 sin
                              ; signo, ver docs/isa.md SS4d)
    RET

; --- read_ptr16: BX = base de una tabla de punteros de 16 bits; CL = indice
; ya multiplicado x2 por quien llama; sale BX = el puntero de 16 bits leido
; de tabla[CL].
read_ptr16:
    ADD BX,CL
    LDA AL,[BX]
    STA [rp_lo],AL
    INC BX
    LDA AL,[BX]
    STA [rp_hi],AL
    LDA BL,[rp_lo]
    LDA BH,[rp_hi]
    RET

; --- frame_wait: espera N*8 ms con el temporizador 3 -------------------------
frame_wait:
    OUT (0x0623),AL
fw_l:
    IN  AL,(0x0623)
    CMP AL,#0
    JMPNZ fw_l
    RET

; --- clst: limpia la rejilla de texto entera (0x0400-0x04FF, DL envuelve) ---
clst:
    MOV DX,#0x0400
    MOV AL,#0
clst_l:
    OUT (DX),AL
    ADD DL,#1
    JMPNZ clst_l
    RET

; ============================================================================
;  DATOS
; ============================================================================
s_title:  .asciiz "DOCUMENTATION"
s_mark:   .asciiz "> "
s_nomark: .asciiz "  "

; ==== auto-generado por gen_docs_content.py -- no editar a mano lo de abajo ====

; --- nombres de los temas ----------------------------------------------------
tn2_name: .asciiz "PORTS"
tn3_name: .asciiz "ISA"
tn4_name: .asciiz "PANEL"

; --- contenido de cada pagina (un asciiz por pagina, "\n" entre lineas) ------
t2p0: .asciiz "PORT MAP OVERVIEW\n65536 ports, apart\nfrom RAM. Screen\n(gfx+text+attrs) at\n0000-05FF; other\nperipherals at\n0600-08FF"
t2p1: .asciiz "GRAPHICS 0000-03FF\nFramebuffer, 128x64.\n1 port = 8 h.pixels.\nbit7=leftmost px,\n1=lit. port(x,y) =\ny*16 + xbyte\n(xbyte 0-15)"
t2p2: .asciiz "TEXT 0400-04FF\n21 cols x 8 rows,\n6x8 font. port =\n0400 + row*32 + col.\nbyte=ASCII code.\n0=transparent cell,\n0x20=blank cell"
t2p3: .asciiz "ATTRS 0500-05FF\nSame layout as text,\n1 byte/cell. bit0\ninverse, 1 blink,\n2 underline, 3\nstrike, 4/5 sub/\nsuperscript, 6-7 rot"
t2p4: .asciiz "ENCODERS 0600-0603\n0600 IN: ADDR pos\n(0-255, wraps)\n0601 IN: ADDR button\n0602 IN: DATA pos\n0603 IN: DATA button\nbit0 = pressed"
t2p5: .asciiz "LED & RANDOM\n0610 IO: onboard LED\nbit0=1 lights it,\nIN reads it back.\n0611 IN: a new\nrandom byte on each\nread (hardware RNG)"
t2pg: .asciiz "TIMERS 0620-0629\n10 countdown timers\nOUT sets 0-255.\nt_i: -1 every 1<<i\nms, stops at 0.\nIN reads the value\n(doesn't set Z)"
t2p6: .asciiz "SOUND 0630-0633\n0630/31: freq lo/hi\n(16-bit, hi triggers)\n0632: MIDI note\n0-127 (69=440Hz)\n0633: auto-off in\n10ms steps, sticky"
t2p7: .asciiz "SOUND ORDER WARNING\nAlways write 0633\n(duration) BEFORE\n0632/0631 (note or\nfreq): duration is\nsticky but not\nretroactive"
t2p8: .asciiz "PROGRAM LOAD/SAVE\n0640 OUT slot: load\n+reset CPU & outputs\nIN=1: last load fail\n0641 OUT slot: save\nRAM, keep running\nIN=1: last save ok"
t2p9: .asciiz "CONFIG 0650-0652\n0650 bright. 0-255\n0651 sound: !0=on\n0652 OUT: save both\nto flash. OUT only\nfrom slot 0 (sisop\nSETTINGS). IN=value"
t2pa: .asciiz "PORT TABLE (1/2)\n0000-03FF graphics\n0400-04FF text\n0500-05FF text attrs\n0600-0603 encoders\n0610/11 LED, random\n0620-0629 timers"
t2pb: .asciiz "PORT TABLE (2/2)\n0630-0633 sound\n0640-0643 programs\n0650-0652 config\n0660-066E slot info\n0700-0801 EEPROM\nothers: IN=0, OUT -"
t2pc: .asciiz "EEPROM 0700-07FF\n256 bytes per slot\nthat survive power\noff. 0700+i: byte i\nof a RAM buffer,\ninstant. Never-saved\nbytes read as 0xFF"
t2pd: .asciiz "EEPROM 0800/0801\n0800 OUT: buffer <-\nflash (this slot)\n0801 OUT: buffer ->\nflash (ms, erases)\nIN 0800=1: failed\nIN 0801=1: saved ok"
t2pe: .asciiz "SLOT INFO 0642-066E\n0642 OUT slot: read\nits name+category\nIN=1: slot is used\n0643 IN: own slot\n0660 IN: category\n0661-066E IN: name"
t2pf: .asciiz "CATEGORIES (0660)\n1 SYSTEM  2 GAME\n3 PROGRAM 4 UTILITY\n5 DEMO    6 DOCS\nFF: none. Set with\n.category & .name\nin the .asm source"
t3p0: .asciiz "REGISTERS\nAX BX CX DX, each\n16 bit, split into\n8-bit halves: AL/AH\nBL/BH CL/CH DL/DH.\nPlus PC, SP (starts\n0xFFFF), FLAGS:NVZC"
t3p1: .asciiz "OPCODE BYTE (ISA 2)\nopcode=family*8+low3\nlow3 = reg8, jump\ncondition, reg16 or\nsub-op. ALU op goes\nin a 2nd byte: MOV\nADD ADC SUB SBC CMP"
t3p2: .asciiz "CORE INSTRUCTIONS 1\nNOP HALT RET (1B)\nMOV reg,#imm8 (2B)\nLDA reg,[addr16](3)\nSTA [addr16],reg(3)\nLDA/STA via [AX..DX]\n(2B): mem[pair]"
t3p3: .asciiz "ALU: 4 FORMS\nop reg,reg     (2B)\nop reg,#imm8   (3B)\nop reg,[addr16](4B)\nop reg,[r16]   (2B)\nop: MOV ADD ADC SUB\nSBC CMP AND OR XOR"
t3p4: .asciiz "ADC / SBC\nADC: a=a+b+C\nSBC: a=a-b-C\nCarry/borrow from\nthe previous op, to\nadd/sub numbers of\nseveral bytes"
t3p5: .asciiz "NOT/SHIFT/MUL/DIV\nNOT reg (1B)\nSHR/SHL reg,#N (2B)\nN=1..8. MUL reg:\nAX=AL*reg. DIV reg:\nAL=AX/r AH=rem\nINC/DEC reg8: C kept"
t3p6: .asciiz "16-BIT (AX..DX)\nMOV/ADD/SUB/CMP\nr16,r16 (2B); ADD/\nSUB r16,reg8 or #8\nCMP/MOV r16,#16(4B)\nINC/DEC/PUSH/POP r16\n(1B). CMP16: flags"
t3p7: .asciiz "STACK, JUMPS, COPY\nPUSH/POP reg (1B)\nJMP/CALL<cc> addr(3)\nJMP/CALL r16 (2B)\ncc:Z NZ C NC N NN V\nNV. MOVB/MOVW/MOVBR\ncopy CX: BX -> DX"
t3p8: .asciiz "FLAGS SUMMARY\nZ=result 0, N=bit7\nADD/ADC: C=carry\nSUB/SBC/CMP: C =\nborrow. Logic: C=V=0\nINC/DEC 8-bit keep C\n16-bit: only CMP"
t3p9: .asciiz "ASSEMBLER (casm)\n.org .db .dw .space\n.asciiz .equ .slot\n.name \"TEXT\" (<=14)\n.category GAME etc.\n.include \"text.asm\"\n(from programs/lib)"
t4p0: .asciiz "TWO SLIDE SWITCHES\nEDIT<-SW_MODE->RUN\nabove ADDR. SINGLE\n<-SW_STEP->CONT.\nabove DATA. EDIT:\nSINGLE=memory,\nCONT.=programs"
t4p1: .asciiz "THE FOUR VIEWS\nEDIT+SINGLE: memory\n(disasm + edit)\nEDIT+CONT: programs\n(slot browser)\nRUN+SINGLE: step\nRUN+CONT: continuous"
t4p2: .asciiz "EditMem CONTROLS\nADDR turn: move by\nwhole instruction.\nADDR short: insert\nNOP. ADDR long:\ndelete byte. DATA\nturn: change field"
t4p3: .asciiz "EditMem FIELDS\nDATA press confirms\nfield, advances.\nOn last field, also\nmoves to next addr.\nVerb field cycles\n30 verbs A-Z order"
t4p4: .asciiz "EditPrg CONTROLS\nADDR turn: pick\nslot 0-59. DATA\nturn: cycle action\nLOAD/SAVE/NEW.\nEither button press\nruns chosen action"
t4p5: .asciiz "ExecPaso CONTROLS\nADDR turn: pick a\ntarget addr (no\nrun yet). ADDR short\npress: run to there.\nADDR long: reset.\nDATA: step 1 instr"
t4p6: .asciiz "ExecCont\nBoth encoders and\nboth buttons pass\nstraight through to\nthe running program\nvia IN on their\nports (0600-0603)"
t4p7: .asciiz "RUN/RESET RULES\nStart of RUN or\nADDR-long in STEP:\nfull reset (PC,SP,\nscreen,snd,timers).\nSTEP<->CONT and\nEDIT keep the PC"

; --- tablas de paginas por tema ----------------------------------------------
T2_PAGES: .dw t2p0, t2pa, t2pb, t2p1, t2p2, t2p3, t2p4, t2p5, t2pg, t2p6, t2p7, t2p8, t2pe, t2pf, t2p9, t2pc, t2pd
T3_PAGES: .dw t3p0, t3p1, t3p2, t3p3, t3p4, t3p5, t3p6, t3p7, t3p8, t3p9
T4_PAGES: .dw t4p0, t4p1, t4p2, t4p3, t4p4, t4p5, t4p6, t4p7

; --- tablas de nivel superior (indexadas por numero de tema 0..NUM_TOPICS-1) -
NUM_TOPICS = 3
TOPIC_NAMES:       .dw tn2_name, tn3_name, tn4_name
TOPIC_PAGE_COUNTS: .db 17, 10, 8
TOPIC_PAGE_TABLES: .dw T2_PAGES, T3_PAGES, T4_PAGES

; ============================================================================
;  VARIABLES
; ============================================================================
view:             .space 1
cur_topic:        .space 1
cur_page:         .space 1
cur_topic_pages:  .space 1
dir_pos_prev:     .space 1
dat_pos_prev:     .space 1
dat_btn_prev:     .space 1
dir_btn_prev:     .space 1
tmp0:             .space 1
i:                .space 1
rp_lo:            .space 1
rp_hi:            .space 1
content_row:      .space 1
content_col:      .space 1
