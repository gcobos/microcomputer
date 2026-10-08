; ============================================================================
;  lib/ports.asm  -  constantes de puertos de compi (ver include/iomap.h)
;  Uso:  .include "ports.asm"   (solo define constantes, no ocupa memoria)
; ============================================================================
P_FB          = 0x0000   ; framebuffer 128x64, 16 puertos por fila
P_TEXT        = 0x0400   ; texto: 0x0400 + fila*32 + col (21x8)
P_ATTR        = 0x0500   ; atributos de texto, misma disposicion
P_DIR_POS     = 0x0600   ; encoder DIRECCION: posicion (IN)
P_DIR_BTN     = 0x0601   ; encoder DIRECCION: pulsado (IN)
P_DAT_POS     = 0x0602   ; encoder DATOS: posicion (IN)
P_DAT_BTN     = 0x0603   ; encoder DATOS: pulsado (IN)
P_LED         = 0x0610   ; LED de a bordo (bit 0)
P_RANDOM      = 0x0611   ; IN: byte aleatorio (generador por hardware)
P_POWER       = 0x0612   ; OUT bit0 = modo ahorro, bit1 = encender pantalla; IN bit1 = encendida
P_SLEEP       = 0x0613   ; OUT n: la CPU duerme n x 10 ms (esperar sin gastar)
P_T0          = 0x0620   ; temporizadores: t_i baja 1 cada 2^i ms
P_T3          = 0x0623   ;   8 ms/paso
P_T4          = 0x0624   ;  16 ms/paso
P_T5          = 0x0625   ;  32 ms/paso
P_T6          = 0x0626   ;  64 ms/paso
P_T7          = 0x0627   ; 128 ms/paso
P_T8          = 0x0628   ; 256 ms/paso
P_T9          = 0x0629   ; 512 ms/paso
P_SND_FREQ_LO = 0x0630
P_SND_FREQ_HI = 0x0631
P_SND_NOTE    = 0x0632   ; nota MIDI (0 = silencio)
P_SND_DUR     = 0x0633   ; duracion automatica x10 ms (0 = sostenida)
P_SND_VEL     = 0x0634   ; velocidad MIDI 1..127 (solo Bluetooth; pegajosa)
P_PROG_LOAD   = 0x0640   ; OUT slot: cargar y saltar a ese programa
P_PROG_SAVE   = 0x0641   ; OUT slot: grabar la RAM entera ahi
P_SLOT_QUERY  = 0x0642   ; OUT slot: consultar sus metadatos; IN: 1 si usado
P_CUR_SLOT    = 0x0643   ; IN: slot del programa en curso
P_SLOT_INFO   = 0x0660   ; IN: categoria (0x0660) + nombre (0x0661..0x066E)
P_CFG_BRIGHTNESS = 0x0650
P_CFG_SOUND_EN   = 0x0651
P_CFG_SAVE       = 0x0652
P_TIME        = 0x0670   ; hora real: OUT congela; IN bit0 = hay hora
P_T_EPOCH     = 0x0671   ; 0x0671..0x0674: segundos UTC desde 1970
P_T_SEC       = 0x0675   ; segundo, minuto, hora, dia, mes, año-2000,
P_T_MIN       = 0x0676   ; dia de la semana (0 = domingo) -- locales
P_T_HOUR      = 0x0677
P_T_DAY       = 0x0678
P_T_MONTH     = 0x0679
P_T_YEAR      = 0x067A
P_T_WDAY      = 0x067B
P_T_LMIN      = 0x067C   ; 0x067C..0x067E: minutos locales desde 1-1-2020
P_EEP_BASE    = 0x0700   ; EEPROM del slot: bufer de 256 bytes
P_EEP_LOAD    = 0x0800
P_EEP_SAVE    = 0x0801

; categorias de programa (.category, PORT_SLOT_INFO)
CAT_NONE    = 0xFF
CAT_SYSTEM  = 1
CAT_GAME    = 2
CAT_PROGRAM = 3
CAT_UTILITY = 4
CAT_DEMO    = 5
CAT_DOCS    = 6

ATTR_INVERSE   = 0x01
ATTR_BLINK     = 0x02
ATTR_UNDERLINE = 0x04
