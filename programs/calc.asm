; ============================================================================
;  calc.asm  -  calculadora clasica, estilo acumulador (compi)
;
;  Caja arriba con UN numero (el que se esta tecleando, o el ultimo
;  resultado), sin recuadro -- solo el texto, para no recargar la pantalla.
;  Debajo, 6 botones cuadrados de operacion (+ - * / = C) y, debajo de esos,
;  10 botones cuadrados de digito (0-9) -- todos dibujados UNA SOLA VEZ al
;  arrancar. A partir de ahi, mover el resaltado con un encoder NUNCA vuelve
;  a dibujar el teclado: solo apaga el marco interior del boton que deja de
;  estar resaltado y enciende el del nuevo, sobre lo ya dibujado.
;
;  Encoder DATOS (derecha) gira -> mueve el resaltado entre los 10 botones
;  de numero (con envoltura). Pulsa DATOS -> añade ese digito al numero que
;  se este tecleando (maximo 6 digitos = 0..999999).
;
;  Encoder DIRECCION (izquierda) gira -> mueve el resaltado entre los 6
;  botones de operacion (con envoltura). Pulsa DIRECCION -> aplica esa
;  operacion AHORA MISMO y muestra el resultado (modelo de acumulador, como
;  una calculadora de bolsillo real): con + - * / se calcula
;  acumulador = acumulador <op> numero_tecleado (o, si es la primera
;  operacion, el acumulador pasa a ser el numero tecleado sin calcular
;  nada), se muestra, y esa operacion queda pendiente para la proxima vez
;  que se pulse una operacion. Con "=" se calcula y se muestra igual, pero
;  no deja ninguna operacion pendiente nueva. Con "C" se borra todo.
;
;  Sin multiplicacion ni division de la CPU: la multiplicacion es suma-y-
;  desplaza sobre un intermedio de 48 bits (para detectar el desbordamiento
;  antes de truncar), y la division es division binaria larga con resto (24
;  iteraciones de "desplaza y compara" -- con numeros de hasta 6 cifras,
;  restar de uno en uno como antes tardaria demasiado: dividir por 1 podria
;  necesitar casi un millon de restas). El acumulador es de 24 bits (hasta
;  999999 -- por encima de eso, "Err", igual que al dividir por 0, para no
;  mostrar digitos sin sentido).
;
;  No hay boton de salida (los dos pulsadores son parte de la calculadora):
;  se sale cambiando el interruptor SW_MODE a EDIT, igual que roto_debug.asm.
;
;  Ensamblar y enviar al slot 10:
;     python3 tools/casm.py programs/calc.asm -o programs/calc.bin
;     python3 tools/compi_send.py --port /dev/ttyACM0 --slot 10 programs/calc.bin
;
;  La ISA y los puertos: ../docs/isa.md
; ============================================================================

    .slot 10
    .org 0x0000

; --- puertos ------------------------------------------------------------
P_TEXT    = 0x0400
P_DIR_POS = 0x0600
P_DIR_BTN = 0x0601
P_DAT_POS = 0x0602
P_DAT_BTN = 0x0603
P_T3      = 0x0623

; --- geometria -------------------------------------------------------------
KEY_W     = 23     ; botones de numero
KEY_H     = 15
KEY_W_OP  = 19     ; botones de operacion
KEY_H_OP  = 15

DISP_END  = 19      ; ultima columna de texto usable en la fila 0 (de 21)
DISP_COL  = 14      ; columna donde empieza el campo de 6 digitos del
                    ; resultado (alineado a la derecha, termina en DISP_END)
ERR_COL   = 17      ; columna donde empieza "Err" (tambien pegado a DISP_END)

; ============================================================================
;  ARRANQUE
; ============================================================================
start:
    MOV AL,#0
    STA [entry0],AL
    STA [entry1],AL
    STA [entry2],AL
    STA [acc0],AL
    STA [acc1],AL
    STA [acc2],AL
    STA [err_flag],AL
    STA [dsel],AL
    STA [osel],AL
    STA [fresh],AL
    STA [pd4_0],AL
    STA [pd4_1],AL
    STA [pd4_2],AL
    MOV AL,#0xFF
    STA [pending_op],AL

    IN  AL,(P_DIR_POS)
    STA [dir_prev],AL
    IN  AL,(P_DAT_POS)
    STA [dat_prev],AL
    IN  AL,(P_DIR_BTN)
    STA [dir_btn_prev],AL
    IN  AL,(P_DAT_BTN)
    STA [dat_btn_prev],AL

    CALL dibuja_teclado_completo

    MOV AL,#0
    STA [bi],AL
    MOV AL,#1
    STA [box_mode],AL
    CALL resalta_num
    CALL resalta_op
    CALL blit

    CALL actualiza_display

; ============================================================================
;  BUCLE PRINCIPAL -- nunca redibuja el teclado, solo lee y actualiza lo
;  minimo (resaltado y/o el numero de la caja de arriba)
; ============================================================================
main_l:
    CALL leer_datos
    CALL leer_direccion
    MOV AL,#2
    CALL frame_wait
    JMP main_l

; ============================================================================
;  ENTRADA: DATOS (mueve el resaltado de numero / aprieta el digito)
; ============================================================================
leer_datos:
    IN  AL,(P_DAT_POS)
    STA [tmp0],AL
    LDA BL,[dat_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dat_prev],CL
    CMP AL,#0
    JMPZ ld_btn
    AND AL,#0x80
    JMPNZ ld_left
ld_right:
    LDA AL,[dsel]
    CMP AL,#9
    JMPZ ld_wraplo
    ADD AL,#1
    JMP ld_apply
ld_wraplo:
    MOV AL,#0
    JMP ld_apply
ld_left:
    LDA AL,[dsel]
    CMP AL,#0
    JMPZ ld_wraphi
    SUB AL,#1
    JMP ld_apply
ld_wraphi:
    MOV AL,#9
ld_apply:
    STA [nuevo_dsel],AL
    CALL selecciona_num
ld_btn:
    IN  AL,(P_DAT_BTN)
    STA [tmp1],AL
    LDA BL,[dat_btn_prev]
    LDA CL,[tmp1]
    STA [dat_btn_prev],CL
    CMP CL,#0
    JMPZ ld_d
    CMP BL,#0
    JMPNZ ld_d
    CALL aplica_digito
ld_d:
    RET

; --- aplica_digito: añade [dsel] al numero que se esta tecleando (24 bits,
; maximo 6 digitos: si ya vale >=100000 el siguiente digito se ignora) -----
aplica_digito:
    LDA AL,[fresh]
    CMP AL,#0
    JMPZ ad_normal
    MOV AL,#0
    STA [fresh],AL
    LDA AL,[dsel]
    STA [entry0],AL
    MOV AL,#0
    STA [entry1],AL
    STA [entry2],AL
    JMP ad_show
ad_normal:
    MOV BL,#lo(entry2)
    MOV BH,#hi(entry2)
    MOV DL,#lo(CAP5+2)
    MOV DH,#hi(CAP5+2)
    MOV AL,#3
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPNZ ad_ignore
    CALL mul10add_entry
ad_show:
    MOV AL,#0
    STA [err_flag],AL
    LDA AL,[entry0]
    STA [pd4_0],AL
    LDA AL,[entry1]
    STA [pd4_1],AL
    LDA AL,[entry2]
    STA [pd4_2],AL
    CALL actualiza_display
ad_ignore:
    RET

; --- mul10add_entry: entry = entry*10 + [dsel]  (24 bits: entry<<3 sumado
; a entry_original<<1, mas el digito -- entry ya se comprobo <100000) ------
mul10add_entry:
    LDA AL,[entry0]
    STA [mx0],AL
    LDA AL,[entry1]
    STA [mx1],AL
    LDA AL,[entry2]
    STA [mx2],AL

    MOV AL,#3
    STA [cnt_n],AL
    MOV BL,#lo(entry0)
    MOV BH,#hi(entry0)
    CALL shl_n
    MOV BL,#lo(entry0)
    MOV BH,#hi(entry0)
    CALL shl_n
    MOV BL,#lo(entry0)
    MOV BH,#hi(entry0)
    CALL shl_n
    MOV BL,#lo(mx0)
    MOV BH,#hi(mx0)
    CALL shl_n

    MOV BL,#lo(entry0)
    MOV BH,#hi(entry0)
    MOV DL,#lo(mx0)
    MOV DH,#hi(mx0)
    CALL add_n

    MOV AL,#0
    STA [dig3_1],AL
    STA [dig3_2],AL
    LDA AL,[dsel]
    STA [dig3_0],AL
    MOV BL,#lo(entry0)
    MOV BH,#hi(entry0)
    MOV DL,#lo(dig3_0)
    MOV DH,#hi(dig3_0)
    CALL add_n
    RET

; ============================================================================
;  ENTRADA: DIRECCION (mueve el resaltado de operacion / la aplica)
; ============================================================================
leer_direccion:
    IN  AL,(P_DIR_POS)
    STA [tmp0],AL
    LDA BL,[dir_prev]
    SUB AL,BL
    LDA CL,[tmp0]
    STA [dir_prev],CL
    CMP AL,#0
    JMPZ lr_btn
    AND AL,#0x80
    JMPNZ lr_left
lr_right:
    LDA AL,[osel]
    CMP AL,#5
    JMPZ lr_wraplo
    ADD AL,#1
    JMP lr_apply
lr_wraplo:
    MOV AL,#0
    JMP lr_apply
lr_left:
    LDA AL,[osel]
    CMP AL,#0
    JMPZ lr_wraphi
    SUB AL,#1
    JMP lr_apply
lr_wraphi:
    MOV AL,#5
lr_apply:
    STA [nuevo_osel],AL
    CALL selecciona_op
lr_btn:
    IN  AL,(P_DIR_BTN)
    STA [tmp1],AL
    LDA BL,[dir_btn_prev]
    LDA CL,[tmp1]
    STA [dir_btn_prev],CL
    CMP CL,#0
    JMPZ lr_d
    CMP BL,#0
    JMPNZ lr_d
    CALL aplica_operacion
lr_d:
    RET

; --- aplica_operacion: [osel] (0..3=+-*/  4="="  5="C") ------------------
aplica_operacion:
    LDA AL,[osel]
    CMP AL,#5
    JMPZ ao_clear
    LDA AL,[pending_op]
    CMP AL,#0xFF
    JMPZ ao_first
    CALL calcular_pendiente
    JMP ao_after
ao_first:
    LDA AL,[entry0]
    STA [acc0],AL
    LDA AL,[entry1]
    STA [acc1],AL
    LDA AL,[entry2]
    STA [acc2],AL
    MOV AL,#0
    STA [err_flag],AL
ao_after:
    CALL check_overflow
    LDA AL,[osel]
    CMP AL,#4
    JMPZ ao_show
    STA [pending_op],AL
ao_show:
    LDA AL,[err_flag]
    CMP AL,#0
    JMPNZ ao_reset
    LDA AL,[acc0]
    STA [pd4_0],AL
    LDA AL,[acc1]
    STA [pd4_1],AL
    LDA AL,[acc2]
    STA [pd4_2],AL
ao_reset:
    MOV AL,#0
    STA [entry0],AL
    STA [entry1],AL
    STA [entry2],AL
    MOV AL,#1
    STA [fresh],AL
    CALL actualiza_display
    RET
ao_clear:
    MOV AL,#0
    STA [entry0],AL
    STA [entry1],AL
    STA [entry2],AL
    STA [acc0],AL
    STA [acc1],AL
    STA [acc2],AL
    STA [err_flag],AL
    STA [pd4_0],AL
    STA [pd4_1],AL
    STA [pd4_2],AL
    MOV AL,#0xFF
    STA [pending_op],AL
    MOV AL,#1
    STA [fresh],AL
    CALL actualiza_display
    RET

; --- check_overflow: si acc > 999999, err_flag=1 (para no imprimir
; digitos sin sentido -- put_dec6 solo esta pensado para 0..999999) --------
check_overflow:
    MOV BL,#lo(LIMIT24+2)
    MOV BH,#hi(LIMIT24+2)
    MOV DL,#lo(acc2)
    MOV DH,#hi(acc2)
    MOV AL,#3
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPNZ ov_ok
    MOV AL,#1
    STA [err_flag],AL
ov_ok:
    RET

; ============================================================================
;  ARITMETICA: sin MUL ni DIV de la CPU -- todo desde cero, sobre registros
;  de 24 bits (3 bytes, LSB primero): [acc0..acc2] (acumulador) y
;  [entry0..entry2] (numero tecleado). add_n/sub_n/shl_n/cmp_n son ayudantes
;  genericos de N bytes (N en [cnt_n]) reutilizados por todas las
;  operaciones y tambien por put_dec6 mas abajo.
; ============================================================================
calcular_pendiente:
    MOV AL,#0
    STA [err_flag],AL
    LDA AL,[pending_op]
    CMP AL,#0
    JMPZ cp_add
    CMP AL,#1
    JMPZ cp_sub
    CMP AL,#2
    JMPZ cp_mul
    CALL udiv_acc
    RET
cp_add:
    CALL uadd_acc
    RET
cp_sub:
    CALL usub_acc
    RET
cp_mul:
    CALL umul_acc
    RET

; --- uadd_acc: acc(24 bits) += entry(24 bits) ----------------------------
uadd_acc:
    MOV BL,#lo(acc0)
    MOV BH,#hi(acc0)
    MOV DL,#lo(entry0)
    MOV DH,#hi(entry0)
    MOV AL,#3
    STA [cnt_n],AL
    CALL add_n
    RET

; --- usub_acc: acc(24 bits) -= entry(24 bits), recortado a 0 si seria
; negativo -- se comprueba antes de restar (cmp_n), no hace falta deshacer
; nada ----------------------------------------------------------------------
usub_acc:
    MOV BL,#lo(acc2)
    MOV BH,#hi(acc2)
    MOV DL,#lo(entry2)
    MOV DH,#hi(entry2)
    MOV AL,#3
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPZ us_neg
    MOV BL,#lo(acc0)
    MOV BH,#hi(acc0)
    MOV DL,#lo(entry0)
    MOV DH,#hi(entry0)
    MOV AL,#3
    STA [cnt_n],AL
    CALL sub_n
    RET
us_neg:
    MOV AL,#0
    STA [acc0],AL
    STA [acc1],AL
    STA [acc2],AL
    RET

; --- umul_acc: acc(24 bits) *= entry(24 bits). Suma y desplaza sobre un
; intermedio de 48 bits (p0..p5 = producto, mm0..mm5 = multiplicando que se
; va desplazando, qb0..qb2 = copia de entry que se va vaciando bit a bit),
; para poder comprobar el desbordamiento (>999999) antes de truncar a 24
; bits -- si se truncase antes, un desbordamiento por encima de 24 bits
; podria "dar la vuelta" y parecer un resultado valido por error ----------
umul_acc:
    MOV AL,#0
    STA [p0],AL
    STA [p1],AL
    STA [p2],AL
    STA [p3],AL
    STA [p4],AL
    STA [p5],AL
    LDA AL,[acc0]
    STA [mm0],AL
    LDA AL,[acc1]
    STA [mm1],AL
    LDA AL,[acc2]
    STA [mm2],AL
    MOV AL,#0
    STA [mm3],AL
    STA [mm4],AL
    STA [mm5],AL
    LDA AL,[entry0]
    STA [qb0],AL
    LDA AL,[entry1]
    STA [qb1],AL
    LDA AL,[entry2]
    STA [qb2],AL
uma_l:
    LDA AL,[qb0]
    LDA BL,[qb1]
    OR  AL,BL
    LDA BL,[qb2]
    OR  AL,BL
    CMP AL,#0
    JMPZ uma_d
    LDA AL,[qb0]
    AND AL,#1
    CMP AL,#0
    JMPZ uma_noadd
    MOV BL,#lo(p0)
    MOV BH,#hi(p0)
    MOV DL,#lo(mm0)
    MOV DH,#hi(mm0)
    MOV AL,#6
    STA [cnt_n],AL
    CALL add_n
uma_noadd:
    MOV BL,#lo(mm0)
    MOV BH,#hi(mm0)
    MOV AL,#6
    STA [cnt_n],AL
    CALL shl_n
    CALL shr_qb
    JMP uma_l
uma_d:
    MOV BL,#lo(LIMIT48+5)
    MOV BH,#hi(LIMIT48+5)
    MOV DL,#lo(p5)
    MOV DH,#hi(p5)
    MOV AL,#6
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPZ umr_over
    LDA AL,[p0]
    STA [acc0],AL
    LDA AL,[p1]
    STA [acc1],AL
    LDA AL,[p2]
    STA [acc2],AL
    RET
umr_over:
    MOV AL,#1
    STA [err_flag],AL
    RET

; --- shr_qb: [qb0..qb2] >>= 1 (24 bits, para el multiplicador de umul_acc) -
shr_qb:
    LDA AL,[qb2]
    SHR AL
    STA [qb2],AL
    MOV CL,#0
    JMPNC srq_1
    MOV CL,#1
srq_1:
    LDA AL,[qb1]
    SHR AL
    MOV AH,#0
    JMPNC srq_1b
    MOV AH,#1
srq_1b:
    CMP CL,#0
    JMPZ srq_1c
    OR  AL,#0x80
srq_1c:
    STA [qb1],AL
    MOV CL,AH
    LDA AL,[qb0]
    SHR AL
    CMP CL,#0
    JMPZ srq_2
    OR  AL,#0x80
srq_2:
    STA [qb0],AL
    RET

; --- udiv_acc: acc(24 bits) /= entry(24 bits); si entry=0, err_flag=1.
; Division binaria larga con resto: [rd0..rd5] es un registro combinado de
; 48 bits, dividendo en la mitad baja (rd0..rd2) y resto en la alta
; (rd3..rd5); en cada una de las 24 vueltas se desplaza todo el conjunto un
; bit a la izquierda (eso solo mete el siguiente bit del dividendo en el
; resto, automaticamente) y, si el resto ya vale >= entry, se resta y se
; marca el bit de cociente vacante en rd0. Al final, rd0..rd2 es el
; cociente -- exactamente 24 vueltas siempre, no importa lo grande que sea
; entry (a diferencia de restar de uno en uno, que con numeros de 6 cifras
; podria tardar casi un millon de vueltas) ---------------------------------
udiv_acc:
    LDA AL,[entry0]
    LDA BL,[entry1]
    OR  AL,BL
    LDA BL,[entry2]
    OR  AL,BL
    CMP AL,#0
    JMPZ ud_err
    LDA AL,[acc0]
    STA [rd0],AL
    LDA AL,[acc1]
    STA [rd1],AL
    LDA AL,[acc2]
    STA [rd2],AL
    MOV AL,#0
    STA [rd3],AL
    STA [rd4],AL
    STA [rd5],AL
    MOV AL,#24
    STA [ud_i],AL
ud_l:
    MOV BL,#lo(rd0)
    MOV BH,#hi(rd0)
    MOV AL,#6
    STA [cnt_n],AL
    CALL shl_n

    MOV BL,#lo(rd5)
    MOV BH,#hi(rd5)
    MOV DL,#lo(entry2)
    MOV DH,#hi(entry2)
    MOV AL,#3
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPZ ud_nosub
    MOV BL,#lo(rd3)
    MOV BH,#hi(rd3)
    MOV DL,#lo(entry0)
    MOV DH,#hi(entry0)
    MOV AL,#3
    STA [cnt_n],AL
    CALL sub_n
    LDA AL,[rd0]
    OR  AL,#1
    STA [rd0],AL
ud_nosub:
    LDA AL,[ud_i]
    SUB AL,#1
    STA [ud_i],AL
    JMPNZ ud_l
    LDA AL,[rd0]
    STA [acc0],AL
    LDA AL,[rd1]
    STA [acc1],AL
    LDA AL,[rd2]
    STA [acc2],AL
    RET
ud_err:
    MOV AL,#1
    STA [err_flag],AL
    RET

; --- add_n: [BX..BX+N) += [DX..DX+N), N en [cnt_n], LSB primero (BX/DX
; deben apuntar al byte MENOS significativo de cada uno al entrar) --------
add_n:
    MOV CL,#0
    MOV CH,#0
an_l:
    LDA AL,[BX]
    LDA AH,[DX]
    ADD AL,AH
    MOV AH,#0
    JMPNC an_c1
    MOV AH,#1
an_c1:
    CMP CL,#0
    JMPZ an_c2
    ADD AL,#1
    JMPNC an_c2
    MOV AH,#1
an_c2:
    STA [BX],AL
    MOV CL,AH
    ADD BL,#1
    JMPNC an_bxok
    ADD BH,#1
an_bxok:
    ADD DL,#1
    JMPNC an_dxok
    ADD DH,#1
an_dxok:
    ADD CH,#1
    LDA AH,[cnt_n]
    CMP CH,AH
    JMPNZ an_l
    RET

; --- sub_n: [BX..BX+N) -= [DX..DX+N), N en [cnt_n], LSB primero (igual
; que add_n, para restas con acarreo/prestamo encadenado) -----------------
sub_n:
    MOV CL,#0
    MOV CH,#0
sn_l:
    LDA AL,[BX]
    LDA AH,[DX]
    SUB AL,AH
    MOV AH,#0
    JMPNC sn_c1
    MOV AH,#1
sn_c1:
    CMP CL,#0
    JMPZ sn_c2
    SUB AL,#1
    JMPNC sn_c2
    MOV AH,#1
sn_c2:
    STA [BX],AL
    MOV CL,AH
    ADD BL,#1
    JMPNC sn_bxok
    ADD BH,#1
sn_bxok:
    ADD DL,#1
    JMPNC sn_dxok
    ADD DH,#1
sn_dxok:
    ADD CH,#1
    LDA AH,[cnt_n]
    CMP CH,AH
    JMPNZ sn_l
    RET

; --- shl_n: [BX..BX+N) <<= 1 (desplazamiento conjunto, N en [cnt_n], LSB
; primero -- el bit que sale de cada byte entra en el siguiente) ----------
shl_n:
    MOV CL,#0
    MOV CH,#0
shn_l:
    LDA AL,[BX]
    SHL AL
    MOV AH,#0
    JMPNC shn_c1
    MOV AH,#1
shn_c1:
    CMP CL,#0
    JMPZ shn_c2
    ADD AL,#1
shn_c2:
    STA [BX],AL
    MOV CL,AH
    ADD BL,#1
    JMPNC shn_bxok
    ADD BH,#1
shn_bxok:
    ADD CH,#1
    LDA AH,[cnt_n]
    CMP CH,AH
    JMPNZ shn_l
    RET

; --- cmp_n: compara [BX..BX+N) contra [DX..DX+N) como enteros sin signo de
; N bytes (N en [cnt_n]; BX/DX deben apuntar al byte MAS significativo de
; cada uno al entrar, y la rutina los va retrocediendo). AL=1 si BX>=DX,
; AL=0 si BX<DX -----------------------------------------------------------
cmp_n:
    LDA AL,[cnt_n]
    STA [cn_i],AL
cn_l:
    LDA AL,[BX]
    LDA AH,[DX]
    CMP AL,AH
    JMPC cn_lt
    JMPNZ cn_ge
    LDA AL,[cn_i]
    SUB AL,#1
    STA [cn_i],AL
    JMPZ cn_ge
    SUB BL,#1
    JMPNC cn_bxok
    SUB BH,#1
cn_bxok:
    SUB DL,#1
    JMPNC cn_dxok
    SUB DH,#1
cn_dxok:
    JMP cn_l
cn_ge:
    MOV AL,#1
    RET
cn_lt:
    MOV AL,#0
    RET

; ============================================================================
;  DIBUJO -- lo caro (dibuja_teclado_completo) SOLO se llama una vez, desde
;  start. Todo lo demas (resaltado, numero de la caja) es incremental.
; ============================================================================

; --- dibuja_teclado_completo: 6 botones de operacion + 10 de numero --
; contorno y simbolo/digito, SIN resaltar nada (eso es aparte). La caja de
; resultado de arriba NO lleva recuadro, solo el texto -------------------
dibuja_teclado_completo:
    CALL clr_shadow
    CALL clst

    MOV AL,#1
    STA [box_mode],AL

    MOV AL,#0
    STA [bi],AL
dtc_op_l:
    CALL dibuja_boton_op
    LDA AL,[bi]
    ADD AL,#1
    STA [bi],AL
    CMP AL,#6
    JMPNZ dtc_op_l

    MOV AL,#0
    STA [bi],AL
dtc_num_l:
    CALL dibuja_boton_num
    LDA AL,[bi]
    ADD AL,#1
    STA [bi],AL
    CMP AL,#10
    JMPNZ dtc_num_l

    CALL blit
    RET

; --- dibuja_boton_num: contorno + digito del boton [bi] (btn_pos) --------
dibuja_boton_num:
    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(btn_pos)
    MOV BH,#hi(btn_pos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [bx_x0],AL
    ADD BL,#1
    JMPNC dbn_ok1
    ADD BH,#1
dbn_ok1:
    LDA AL,[BX]
    STA [bx_y0],AL
    LDA AL,[bx_x0]
    ADD AL,#KEY_W
    STA [bx_x1],AL
    LDA AL,[bx_y0]
    ADD AL,#KEY_H
    STA [bx_y1],AL
    CALL draw_box

    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(btn_txtpos)
    MOV BH,#hi(btn_txtpos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tcol],AL
    ADD BL,#1
    JMPNC dbn_ok2
    ADD BH,#1
dbn_ok2:
    LDA AL,[BX]
    STA [trow],AL

    LDA AL,[bi]
    ADD AL,#0x30
    LDA CL,[tcol]
    LDA CH,[trow]
    CALL putc_at
    RET

; --- dibuja_boton_op: contorno + simbolo del boton [bi] (op_pos) ---------
dibuja_boton_op:
    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(op_pos)
    MOV BH,#hi(op_pos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [bx_x0],AL
    ADD BL,#1
    JMPNC dbo_ok1
    ADD BH,#1
dbo_ok1:
    LDA AL,[BX]
    STA [bx_y0],AL
    LDA AL,[bx_x0]
    ADD AL,#KEY_W_OP
    STA [bx_x1],AL
    LDA AL,[bx_y0]
    ADD AL,#KEY_H_OP
    STA [bx_y1],AL
    CALL draw_box

    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(op_txtpos)
    MOV BH,#hi(op_txtpos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [tcol],AL
    ADD BL,#1
    JMPNC dbo_ok2
    ADD BH,#1
dbo_ok2:
    LDA AL,[BX]
    STA [trow],AL

    LDA CL,[bi]
    MOV BL,#lo(op_syms)
    MOV BH,#hi(op_syms)
    CALL idx_ptr
    LDA AL,[BX]
    LDA CL,[tcol]
    LDA CH,[trow]
    CALL putc_at
    RET

; --- selecciona_num: dsel -> [nuevo_dsel]; apaga el resaltado viejo,
; enciende el nuevo -- NUNCA redibuja el contorno/digito ------------------
selecciona_num:
    LDA AL,[dsel]
    STA [bi],AL
    MOV AL,#0
    STA [box_mode],AL
    CALL resalta_num

    LDA AL,[nuevo_dsel]
    STA [dsel],AL
    STA [bi],AL
    MOV AL,#1
    STA [box_mode],AL
    CALL resalta_num

    CALL blit
    RET

; --- selecciona_op: igual que selecciona_num, para osel/op_pos -----------
selecciona_op:
    LDA AL,[osel]
    STA [bi],AL
    MOV AL,#0
    STA [box_mode],AL
    CALL resalta_op

    LDA AL,[nuevo_osel]
    STA [osel],AL
    STA [bi],AL
    MOV AL,#1
    STA [box_mode],AL
    CALL resalta_op

    CALL blit
    RET

; --- resalta_num: dibuja (segun [box_mode]) el marco interior del boton
; de numero [bi] -----------------------------------------------------------
resalta_num:
    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(btn_pos)
    MOV BH,#hi(btn_pos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [bx_x0],AL
    ADD BL,#1
    JMPNC rn_ok
    ADD BH,#1
rn_ok:
    LDA AL,[BX]
    STA [bx_y0],AL

    LDA AL,[bx_x0]
    ADD AL,#3
    STA [bx_x0],AL
    LDA AL,[bx_y0]
    ADD AL,#3
    STA [bx_y0],AL
    LDA AL,[bx_x0]
    ADD AL,#17
    STA [bx_x1],AL
    LDA AL,[bx_y0]
    ADD AL,#9
    STA [bx_y1],AL
    CALL draw_box
    RET

; --- resalta_op: igual que resalta_num, para op_pos ----------------------
resalta_op:
    LDA CL,[bi]
    SHL CL
    MOV BL,#lo(op_pos)
    MOV BH,#hi(op_pos)
    CALL idx_ptr
    LDA AL,[BX]
    STA [bx_x0],AL
    ADD BL,#1
    JMPNC ro_ok
    ADD BH,#1
ro_ok:
    LDA AL,[BX]
    STA [bx_y0],AL

    LDA AL,[bx_x0]
    ADD AL,#3
    STA [bx_x0],AL
    LDA AL,[bx_y0]
    ADD AL,#3
    STA [bx_y0],AL
    LDA AL,[bx_x0]
    ADD AL,#13
    STA [bx_x1],AL
    LDA AL,[bx_y0]
    ADD AL,#9
    STA [bx_y1],AL
    CALL draw_box
    RET

; ============================================================================
;  TEXTO Y NUMEROS
; ============================================================================

; --- actualiza_display: borra toda la fila 0 y escribe el numero en
; [pd4_0..pd4_2] alineado a la derecha (columna DISP_COL..DISP_END), o
; "Err" (tambien pegado al borde derecho) si [err_flag] esta puesto -------
actualiza_display:
    MOV DL,#0
    MOV DH,#0x04
    MOV CL,#0
adp_clr:
    MOV AL,#0
    OUT (DX),AL
    ADD DL,#1
    ADD CL,#1
    CMP CL,#21
    JMPNZ adp_clr

    LDA AL,[err_flag]
    CMP AL,#0
    JMPZ adp_num
    MOV AL,#0x45
    MOV CL,#ERR_COL
    MOV CH,#0
    CALL putc_at
    MOV AL,#0x72
    MOV CL,#ERR_COL+1
    MOV CH,#0
    CALL putc_at
    MOV AL,#0x72
    MOV CL,#ERR_COL+2
    MOV CH,#0
    CALL putc_at
    RET
adp_num:
    MOV CL,#DISP_COL
    MOV CH,#0
    CALL put_dec6
    RET

; --- putc_at: AL=caracter, CL=columna, CH=fila --------------------------
putc_at:
    STA [pc_ch],AL
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    MOV DL,AL
    MOV DH,#0x04
    LDA AL,[pc_ch]
    OUT (DX),AL
    RET

; --- put_dec6: [pd4_0..pd4_2] (0..999999) en (CL,CH) -> 6 digitos,
; alineados a la derecha: los ceros a la izquierda se imprimen como
; espacio en blanco (0x20) hasta el primer digito no-cero; el digito de
; las unidades SIEMPRE se imprime tal cual, asi que el valor 0 sale como
; un unico "0" pegado al borde derecho, no como "000000". Los 4 primeros
; digitos salen de restar repetidamente el valor de la posicion (100000,
; 10000, 1000, 100) mientras se pueda (try_digit_place); una vez por debajo
; de 100, [pd4_0] es un byte normal y las decenas/unidades salen igual que
; en la version de 4 digitos anterior --------------------------------------
put_dec6:
    MOV AL,CH
    SHL AL,#5
    ADD AL,CL
    STA [pd6_dl],AL
    MOV AL,#4
    STA [pd6_dh],AL

    MOV AL,#0
    STA [pd4_started],AL

    MOV AL,#0
    STA [pd4_dig],AL
    MOV AL,#0xA0
    STA [k0],AL
    MOV AL,#0x86
    STA [k1],AL
    MOV AL,#0x01
    STA [k2],AL
pd6_p5_l:
    CALL try_digit_place
    CMP AL,#0
    JMPZ pd6_p5_d
    LDA AL,[pd4_dig]
    ADD AL,#1
    STA [pd4_dig],AL
    JMP pd6_p5_l
pd6_p5_d:
    CALL pd6_emit_digit

    MOV AL,#0
    STA [pd4_dig],AL
    MOV AL,#0x10
    STA [k0],AL
    MOV AL,#0x27
    STA [k1],AL
    MOV AL,#0
    STA [k2],AL
pd6_p4_l:
    CALL try_digit_place
    CMP AL,#0
    JMPZ pd6_p4_d
    LDA AL,[pd4_dig]
    ADD AL,#1
    STA [pd4_dig],AL
    JMP pd6_p4_l
pd6_p4_d:
    CALL pd6_emit_digit

    MOV AL,#0
    STA [pd4_dig],AL
    MOV AL,#0xE8
    STA [k0],AL
    MOV AL,#0x03
    STA [k1],AL
    MOV AL,#0
    STA [k2],AL
pd6_p3_l:
    CALL try_digit_place
    CMP AL,#0
    JMPZ pd6_p3_d
    LDA AL,[pd4_dig]
    ADD AL,#1
    STA [pd4_dig],AL
    JMP pd6_p3_l
pd6_p3_d:
    CALL pd6_emit_digit

    MOV AL,#0
    STA [pd4_dig],AL
    MOV AL,#100
    STA [k0],AL
    MOV AL,#0
    STA [k1],AL
    STA [k2],AL
pd6_p2_l:
    CALL try_digit_place
    CMP AL,#0
    JMPZ pd6_p2_d
    LDA AL,[pd4_dig]
    ADD AL,#1
    STA [pd4_dig],AL
    JMP pd6_p2_l
pd6_p2_d:
    CALL pd6_emit_digit

    ; lo que queda en [pd4_0] es < 100 (pd4_1=pd4_2=0 seguro) -- decenas y
    ; unidades igual que en la version de 4 digitos anterior
    LDA AL,[pd4_0]
    MOV BL,#0
pd6_t_l:
    CMP AL,#10
    JMPC pd6_t_d
    SUB AL,#10
    ADD BL,#1
    JMP pd6_t_l
pd6_t_d:
    STA [pd4_ones],AL
    MOV AL,BL
    STA [pd4_dig],AL
    CALL pd6_emit_digit

    ; unidades: SIEMPRE se imprime, sin supresion de ceros
    LDA AL,[pd6_dl]
    MOV DL,AL
    LDA AL,[pd6_dh]
    MOV DH,AL
    LDA AL,[pd4_ones]
    ADD AL,#0x30
    OUT (DX),AL
    RET

; --- pd6_emit_digit: imprime [pd4_dig] en el cursor (pd6_dl,pd6_dh), como
; espacio en blanco si es 0 y [pd4_started] sigue a 0 (cero a la
; izquierda); avanza el cursor una columna ---------------------------------
pd6_emit_digit:
    LDA AL,[pd6_dl]
    MOV DL,AL
    LDA AL,[pd6_dh]
    MOV DH,AL
    LDA AL,[pd4_dig]
    CMP AL,#0
    JMPNZ ped_digit
    LDA BL,[pd4_started]
    CMP BL,#0
    JMPNZ ped_digit
    MOV AL,#0x20
    JMP ped_put
ped_digit:
    MOV BL,#1
    STA [pd4_started],BL
    LDA AL,[pd4_dig]
    ADD AL,#0x30
ped_put:
    OUT (DX),AL
    LDA AL,[pd6_dl]
    ADD AL,#1
    STA [pd6_dl],AL
    JMPNC ped_dhok
    LDA AL,[pd6_dh]
    ADD AL,#1
    STA [pd6_dh],AL
ped_dhok:
    RET

; --- try_digit_place: si [pd4_0..pd4_2] >= [k0..k2], resta y AL=1; si no,
; AL=0 y no toca nada (usa cmp_n/sub_n genericos, sin necesitar deshacer
; nada porque primero comprueba) --------------------------------------------
try_digit_place:
    MOV BL,#lo(pd4_2)
    MOV BH,#hi(pd4_2)
    MOV DL,#lo(k2)
    MOV DH,#hi(k2)
    MOV AL,#3
    STA [cnt_n],AL
    CALL cmp_n
    CMP AL,#0
    JMPZ tdp_no
    MOV BL,#lo(pd4_0)
    MOV BH,#hi(pd4_0)
    MOV DL,#lo(k0)
    MOV DH,#hi(k0)
    MOV AL,#3
    STA [cnt_n],AL
    CALL sub_n
    MOV AL,#1
    RET
tdp_no:
    MOV AL,#0
    RET

; ============================================================================
;  GRAFICOS: rectangulos rectos, sobre `shadow`. [box_mode] decide si se
;  encienden (1) o se apagan (0) los pixeles -- asi hline_on/vline_on
;  sirven tanto para dibujar el contorno fijo como para el resaltado.
; ============================================================================
draw_box:
    LDA AL,[bx_y0]
    STA [ln_y],AL
    LDA AL,[bx_x0]
    STA [ln_x0],AL
    LDA AL,[bx_x1]
    STA [ln_x1],AL
    CALL hline_on

    LDA AL,[bx_y1]
    STA [ln_y],AL
    CALL hline_on

    LDA AL,[bx_x0]
    STA [ln_x0],AL
    LDA AL,[bx_y0]
    STA [ln_y0],AL
    LDA AL,[bx_y1]
    STA [ln_y1],AL
    CALL vline_on

    LDA AL,[bx_x1]
    STA [ln_x0],AL
    CALL vline_on
    RET

hline_on:
    LDA AL,[ln_x0]
    STA [px_cur],AL
hl_l:
    LDA AL,[px_cur]
    STA [px_x],AL
    LDA AL,[ln_y]
    STA [px_y],AL
    LDA AL,[box_mode]
    CMP AL,#0
    JMPZ hl_off
    CALL shadow_set_px
    JMP hl_cont
hl_off:
    CALL shadow_clr_px
hl_cont:
    LDA AL,[px_cur]
    LDA BL,[ln_x1]
    CMP AL,BL
    JMPZ hl_d
    LDA AL,[px_cur]
    ADD AL,#1
    STA [px_cur],AL
    JMP hl_l
hl_d:
    RET

vline_on:
    LDA AL,[ln_y0]
    STA [px_cur],AL
vl_l:
    LDA AL,[ln_x0]
    STA [px_x],AL
    LDA AL,[px_cur]
    STA [px_y],AL
    LDA AL,[box_mode]
    CMP AL,#0
    JMPZ vl_off
    CALL shadow_set_px
    JMP vl_cont
vl_off:
    CALL shadow_clr_px
vl_cont:
    LDA AL,[px_cur]
    LDA BL,[ln_y1]
    CMP AL,BL
    JMPZ vl_d
    LDA AL,[px_cur]
    ADD AL,#1
    STA [px_cur],AL
    JMP vl_l
vl_d:
    RET

; ============================================================================
;  DOBLE BUFFER (igual patron que cubo.asm/roto_debug.asm/raycast.asm)
; ============================================================================
idx_ptr:
    ADD BL,CL
    JMPNC ip_d
    ADD BH,#1
ip_d:
    RET

calc_pix:
    LDA CH,[px_y]
    LDA CL,[px_x]
    MOV AL,CH
    AND AL,#0x0F
    SHL AL,#4
    MOV DL,CL
    SHR DL,#3
    OR  AL,DL
    STA [pix_lo],AL
    MOV AL,CH
    SHR AL,#4
    STA [pix_hi],AL
    MOV DL,CL
    AND DL,#0x07
    MOV DH,#0x80
cpx_m:
    CMP DL,#0
    JMPZ cpx_d
    SHR DH
    SUB DL,#1
    JMP cpx_m
cpx_d:
    STA [pix_mask],DH
    RET

shadow_set_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    OR  AL,DL
    STA [BX],AL
    RET

shadow_clr_px:
    CALL calc_pix
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    LDA CL,[pix_lo]
    CALL idx_ptr
    LDA AL,[pix_hi]
    ADD BH,AL
    LDA AL,[BX]
    LDA DL,[pix_mask]
    NOT DL
    AND AL,DL
    STA [BX],AL
    RET

clr_shadow:
    MOV BL,#lo(shadow)
    MOV BH,#hi(shadow)
    MOV AL,#0
    MOV CL,#0
    MOV CH,#4
csh_l:
    STA [BX],AL
    ADD BL,#1
    JMPNC csh_addr_ok
    ADD BH,#1
csh_addr_ok:
    SUB CL,#1
    JMPNC csh_cnt_ok
    SUB CH,#1
csh_cnt_ok:
    MOV DL,CH
    OR  DL,CL
    JMPNZ csh_l
    RET

blit:
    MOV BL,#0
    MOV BH,#0
    MOV DL,#lo(shadow)
    MOV DH,#hi(shadow)
bl_l:
    IN  AL,(BX)
    LDA CL,[DX]
    CMP AL,CL
    JMPZ bl_same
    MOV AL,CL
    OUT (BX),AL
bl_same:
    ADD DL,#1
    JMPNC bl_dnc
    ADD DH,#1
bl_dnc:
    ADD BL,#1
    JMPNC bl_l
    ADD BH,#1
    CMP BH,#4
    JMPNZ bl_l
    RET

; ============================================================================
;  RUTINAS COMPARTIDAS
; ============================================================================
clst:
    MOV BL,#0
    MOV BH,#4
    MOV AL,#0
ct_l:
    OUT (BX),AL
    ADD BL,#1
    JMPNC ct_l
    RET

frame_wait:
    OUT (P_T3),AL
fw_l:
    IN  AL,(P_T3)
    CMP AL,#0
    JMPNZ fw_l
    RET

; ============================================================================
;  DATOS
; ============================================================================
entry0:          .space 1   ; numero que se esta tecleando (24 bits, LSB primero)
entry1:          .space 1
entry2:          .space 1
acc0:            .space 1   ; acumulador (24 bits, LSB primero)
acc1:            .space 1
acc2:            .space 1
pending_op:      .space 1   ; 0..3 = + - * /  ; 0xFF = ninguna todavia
fresh:           .space 1   ; 1 = el siguiente digito empieza numero nuevo
dsel:            .space 1   ; boton de numero resaltado (0..9)
osel:            .space 1   ; boton de operacion resaltado (0..5)
nuevo_dsel:      .space 1
nuevo_osel:      .space 1
err_flag:        .space 1

dir_prev:        .space 1
dat_prev:        .space 1
dir_btn_prev:    .space 1
dat_btn_prev:    .space 1
tmp0:            .space 1
tmp1:            .space 1

mx0:             .space 1   ; mul10add_entry: copia de entry antes de x10
mx1:             .space 1
mx2:             .space 1
dig3_0:          .space 1   ; mul10add_entry: digito nuevo, extendido a 24 bits
dig3_1:          .space 1
dig3_2:          .space 1

cnt_n:           .space 1   ; add_n/sub_n/shl_n/cmp_n: numero de bytes
cn_i:            .space 1   ; cmp_n: bytes que quedan por comparar

p0:              .space 1   ; umul_acc: producto de 48 bits (LSB primero)
p1:              .space 1
p2:              .space 1
p3:              .space 1
p4:              .space 1
p5:              .space 1
mm0:             .space 1   ; umul_acc: multiplicando de 48 bits (se desplaza)
mm1:             .space 1
mm2:             .space 1
mm3:             .space 1
mm4:             .space 1
mm5:             .space 1
qb0:             .space 1   ; umul_acc: copia de entry que se va vaciando
qb1:             .space 1
qb2:             .space 1

rd0:             .space 1   ; udiv_acc: dividendo/cociente (24) + resto (24)
rd1:             .space 1
rd2:             .space 1
rd3:             .space 1
rd4:             .space 1
rd5:             .space 1
ud_i:            .space 1   ; udiv_acc: contador de las 24 vueltas

bi:              .space 1
box_mode:        .space 1   ; 0=apaga pixeles  1=enciende
bx_x0:           .space 1
bx_y0:           .space 1
bx_x1:           .space 1
bx_y1:           .space 1
ln_x0:           .space 1
ln_x1:           .space 1
ln_y0:           .space 1
ln_y1:           .space 1
ln_y:            .space 1
px_cur:          .space 1
px_x:            .space 1
px_y:            .space 1
pix_lo:          .space 1
pix_hi:          .space 1
pix_mask:        .space 1

tcol:            .space 1
trow:            .space 1
pc_ch:           .space 1
pd4_0:           .space 1   ; valor de 24 bits a mostrar (LSB primero)
pd4_1:           .space 1
pd4_2:           .space 1
pd4_dig:         .space 1
pd4_ones:        .space 1
pd4_started:     .space 1   ; 0 hasta el primer digito no-cero (para ceros a la izq.)
pd6_dl:          .space 1   ; put_dec6: cursor de salida (puerto de texto)
pd6_dh:          .space 1
k0:              .space 1   ; try_digit_place: valor de la posicion (24 bits)
k1:              .space 1
k2:              .space 1

CAP5:       .db 0xA0, 0x86, 0x01               ; 100000 (LSB primero)
LIMIT24:    .db 0x3F, 0x42, 0x0F               ; 999999 (LSB primero)
LIMIT48:    .db 0x3F, 0x42, 0x0F, 0, 0, 0       ; 999999 extendido a 48 bits

op_syms:    .db 0x2B, 0x2D, 0x2A, 0x2F, 0x3D, 0x43   ; + - * / = C

; --- op_pos: 6 pares (x0,y0) de los botones de operacion, en fila -------
op_pos:
    .db 2,11,  23,11,  44,11,  65,11,  86,11,  107,11
; --- op_txtpos: centro aproximado de cada boton de op_pos ---------------
op_txtpos:
    .db 1,2,   5,2,   8,2,   12,2,   15,2,   19,2

; --- btn_pos: 10 pares (x0,y0), esquina superior izquierda de cada boton
; de numero (0..9), 2 filas de 5 -------------------------------------------
btn_pos:
    .db 3,28,   28,28,   53,28,   78,28,   103,28
    .db 3,45,   28,45,   53,45,   78,45,   103,45
; --- btn_txtpos: centro aproximado de cada boton de btn_pos -------------
btn_txtpos:
    .db 2,4,   6,4,   10,4,   14,4,   19,4
    .db 2,6,   6,6,   10,6,   14,6,   19,6

    .org 0xF400
shadow:     .space 1024
