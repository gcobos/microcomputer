#!/usr/bin/env python3
"""sim — emulador headless de la CPU de compi, para probar programas fuera del
aparato. Reproduce cpu.cpp y el modelo de puertos de main.cpp (framebuffer,
rejilla de texto, temporizadores, sonido, encoders y LED).

    python3 tools/sim.py demo.bin --steps 2000000 --script tools/demo_script.txt

El guion de entrada (--script) es una linea por evento:

    <instr>  <accion>

donde <accion> es una de:
    dat+ dat- dir+ dir-        gira un encoder un detente
    datdown datup dirdown dirup   nivel del pulsador
    datclick dirclick          pulsa y suelta (12000 instrucciones)
    frame                       vuelca la pantalla en ese punto
"""
import argparse
import os
import sys

MASK = 0xFFFF
FLAG_C, FLAG_Z, FLAG_N, FLAG_V = 1, 2, 4, 8

# familias de opcode (include/isa.h, ISA version 2 -- ver docs/isa.md)
(F_SYS, F_LDI, F_LDA, F_STA, F_LDAR, F_STAR, F_IN, F_OUT, F_INR, F_OUTR,
 F_ALURR, F_ALUI, F_ALUM, F_ALUP, F_NOT, F_SHR, F_SHL, F_MUL, F_DIV,
 F_INC, F_DEC, F_PUSH, F_POP, F_JMP, F_CALL, F_JX, F_R16, F_R16I,
 F_INCDEC16, F_PUSHPOP16) = range(30)

CLICK_LEN = 12000  # instrucciones que dura un "click" de pulsador
TIMER_COUNT = 10    # ver include/iomap.h

# --- almacen de slots (0x0640/0x0641, ver include/iomap.h) ---------------
# Reproduce storage.h/spi_flash_storage.cpp SIN flash real: cada slot es un
# fichero de 65536 bytes (PROGRAM_SIZE) en --slots-dir, nombrado NN.bin
# (00..59, MAX_PROGRAM_SLOTS). "Usado" = el fichero existe; no hay marca de
# cabecera aparte como en el aparato real porque aqui no hace falta (no
# convive con nada mas en el fichero).
MAX_PROGRAM_SLOTS = 60
PROGRAM_SIZE = 65536


class Ports:
    def __init__(self, instr_ns=20_000, slots_dir=None):
        self.fb = bytearray(1024)
        self.text = bytearray(21 * 8)
        self.attr = bytearray(21 * 8)  # atributos de texto (puertos 0x0500+)
        self.timer = [0] * TIMER_COUNT
        self.timer_set_ns = [0] * TIMER_COUNT
        self.led = 0
        self.dir_pos = 0
        self.dat_pos = 0
        self.dir_btn = 0
        self.dat_btn = 0
        self.snd_lo = self.snd_hi = self.snd_note = self.snd_dur = 0
        self.snd_vel = 100   # 0x0634: velocidad MIDI (solo Bluetooth en el aparato)
        self.snd_instr = 0   # 0x0635: instrumento 0..3
        self.power = 0       # 0x0612: modo ahorro (bit 0) -- aqui solo se recuerda
        self.bat_mv = 3900   # 0x0614/0x0615: bateria simulada (mV; > 4400 = USB)
        self.time_regs = [0] * 14   # 0x0671..0x067E (los congela OUT 0x0670)
        self.snd_hz = 0
        self.now_ns = 0
        self.instr_ns = instr_ns
        self.sound_log = []
        # carga/grabado de programas (0x0640/0x0641) -- self.cpu lo rellena
        # Cpu.__init__ (necesita acceso a la RAM para volcarla/reemplazarla).
        self.slots_dir = slots_dir
        self.cpu = None
        self.last_load_ok = 0
        self.last_save_ok = 0
        # configuracion (0x0650/0x0651, iomap.h) -- espejo de g_screenContrast/
        # g_soundMode en main.cpp. sound_out es lo que lee el puerto 0x0651:
        # 1 = zumbador (de fabrica), 0 = Bluetooth, 2 = silencio.
        self.brightness = 0xCF   # OLED_CONTRAST_FULL (main.cpp), valor de arranque
        self.sound_out = 1
        # EEPROM por slot (0x0700..0x07FF bufer, 0x0800 cargar, 0x0801 grabar
        # -- iomap.h). Lo no grabado nunca se lee como 0xFF (flash borrada),
        # igual que en el aparato. `current_slot` = el slot "en curso" (el
        # que se cargo/grabo por ultima vez; 0 al arrancar, como el arranque
        # automatico del slot 0). Con slots_dir se persiste en NN.eep.
        self.eeprom = bytearray(256)
        # metadatos de slot (PORT_SLOT_QUERY/PORT_SLOT_INFO/PORT_CUR_SLOT,
        # iomap.h): con slots_dir se leen de NN.meta (tools/slots.py); el del
        # programa cargado se graba con el en _prog_save, como en main.cpp
        self.cur_meta = bytes([0xFF]) + bytes(14)
        self.slot_info = bytes([0xFF]) + bytes(14)
        self.slot_info_used = 0
        # PORT_RANDOM: semilla fija para que una ejecucion se pueda repetir
        self.rng = __import__("random").Random(0xC0FF1)
        self.eeprom_store = {}
        self.current_slot = 0
        self.last_eep_load_fail = 0
        self.last_eep_save_ok = 0

    def tick(self):
        self.now_ns += self.instr_ns
        for i in range(TIMER_COUNT):
            if self.timer[i] == 0:
                self.timer_set_ns[i] = self.now_ns
                continue
            period = (1 << i) * 1_000_000  # (1<<i) ms en ns
            elapsed = self.now_ns - self.timer_set_ns[i]
            if elapsed >= period:
                steps = elapsed // period
                self.timer[i] = 0 if steps >= self.timer[i] else self.timer[i] - steps
                self.timer_set_ns[i] += steps * period

    def read(self, port):
        if port < 1024:
            return self.fb[port]
        ti = self._text_index(port)
        if ti is not None:
            return self.text[ti]
        ai = self._attr_index(port)
        if ai is not None:
            return self.attr[ai]
        if 0x0620 <= port < 0x0620 + TIMER_COUNT:
            return self.timer[port - 0x0620]
        if port == 0x0630:
            return self.snd_lo
        if port == 0x0631:
            return self.snd_hi
        if port == 0x0632:
            return self.snd_note
        if port == 0x0633:
            return self.snd_dur
        if port == 0x0634:
            return self.snd_vel
        if port == 0x0635:
            return self.snd_instr
        if port == 0x0600:
            return self.dir_pos
        if port == 0x0601:
            return self.dir_btn
        if port == 0x0602:
            return self.dat_pos
        if port == 0x0603:
            return self.dat_btn
        if port == 0x0610:
            return self.led
        if port == 0x0640:
            return self.last_load_ok
        if port == 0x0641:
            return self.last_save_ok
        if port == 0x0642:
            return self.slot_info_used
        if port == 0x0643:
            return self.current_slot
        if port == 0x0611:
            return self.rng.randrange(256)
        if port == 0x0612:
            return (self.power & 1) | 2          # la pantalla del simulador nunca se apaga
        if port == 0x0614:
            return _bat_percent(self.bat_mv)
        if port == 0x0615:
            return min(255, (self.bat_mv + 10) // 20)
        if port == 0x0670:
            return 0x01 if self.epoch0 is not None else 0
        if 0x0671 <= port < 0x0671 + 14:
            return self.time_regs[port - 0x0671]
        if 0x0660 <= port < 0x0660 + 15:
            return self.slot_info[port - 0x0660]
        if port == 0x0650:
            return self.brightness
        if port == 0x0651:
            return self.sound_out
        if 0x0700 <= port < 0x0800:
            return self.eeprom[port - 0x0700]
        if port == 0x0800:
            return self.last_eep_load_fail
        if port == 0x0801:
            return self.last_eep_save_ok
        return 0

    def write(self, port, val):
        val &= 0xFF
        if port < 1024:
            self.fb[port] = val
            return
        ti = self._text_index(port)
        if ti is not None:
            self.text[ti] = val
            return
        ai = self._attr_index(port)
        if ai is not None:
            self.attr[ai] = val
            return
        if 0x0620 <= port < 0x0620 + TIMER_COUNT:
            i = port - 0x0620
            self.timer[i] = val
            self.timer_set_ns[i] = self.now_ns
            return
        if port == 0x0630:
            self.snd_lo = val
            return
        if port == 0x0631:
            self.snd_hi = val
            self._snd((val << 8) | self.snd_lo)
            return
        if port == 0x0632:
            self.snd_note = val
            self._snd(_note_hz(val))
            return
        if port == 0x0633:
            self.snd_dur = val
            return
        if port == 0x0634:
            self.snd_vel = 1 if val == 0 else min(val, 127)
            return
        if port == 0x0635:
            self.snd_instr = val & 3
            return
        if port == 0x0610:
            self.led = val & 1
            return
        if port == 0x0612:
            self.power = val & 1
            return
        if port == 0x0613:
            # dormir: el tiempo simulado salta n x 10 ms (los temporizadores
            # lo ven en el siguiente tick), sin ejecutar nada entretanto
            self.now_ns += val * 10_000_000
            return
        if port == 0x0670:
            self._latch_time()
            return
        if port == 0x0640:
            self._prog_load(val)
            return
        if port == 0x0641:
            self._prog_save(val)
            return
        if port == 0x0642:
            self.slot_info_used, self.slot_info = self._read_meta(val)
            return
        # brillo y sonido: ajustes del APARATO, solo los cambia SETTINGS de
        # sisop (slot 0) -- igual que main.cpp, el resto de programas se ignora
        if port == 0x0650:
            if self.current_slot == 0:
                self.brightness = val
            return
        if port == 0x0651:
            if self.current_slot == 0:
                self.sound_out = val if val in (0, 2) else 1
            return
        if port == 0x0652:
            # PORT_CFG_SAVE: en el aparato graba brillo/mute en la flash; el
            # simulador no tiene flash de ajustes, solo cuenta las grabaciones
            if self.current_slot == 0:
                self.settings_saves = getattr(self, "settings_saves", 0) + 1
            return
        if 0x0700 <= port < 0x0800:
            self.eeprom[port - 0x0700] = val
            return
        if port == 0x0800:
            self._eep_load()
            return
        if port == 0x0801:
            self._eep_save()
            return

    # hora real simulada (0x0670..0x067E): epoch0 = la hora al arrancar el
    # simulador (la del PC, o --epoch; None = sin hora, --no-time); avanza
    # con el tiempo simulado
    epoch0 = None

    def _latch_time(self):
        import time as _t
        if self.epoch0 is None:
            self.time_regs = [0] * 14
            return
        e = int(self.epoch0 + self.now_ns // 1_000_000_000)
        lt = _t.localtime(e)
        import datetime as _d
        days = (_d.date(lt.tm_year, lt.tm_mon, lt.tm_mday) - _d.date(2020, 1, 1)).days
        lmin = days * 1440 + lt.tm_hour * 60 + lt.tm_min
        self.time_regs = [e & 255, (e >> 8) & 255, (e >> 16) & 255, (e >> 24) & 255,
                          lt.tm_sec, lt.tm_min, lt.tm_hour, lt.tm_mday, lt.tm_mon,
                          lt.tm_year - 2000, (lt.tm_wday + 1) % 7,
                          lmin & 255, (lmin >> 8) & 255, (lmin >> 16) & 255]

    def _eep_path(self):
        if self.slots_dir is None:
            return None
        return os.path.join(self.slots_dir, f"{self.current_slot:02d}.eep")

    def _eep_load(self):
        data = self.eeprom_store.get(self.current_slot)
        path = self._eep_path()
        if data is None and path and os.path.isfile(path):
            with open(path, "rb") as f:
                data = f.read(256)
        if data is None:
            data = b"\xff" * 256          # nunca grabado = flash borrada
        self.eeprom[:] = data.ljust(256, b"\xff")[:256]
        self.last_eep_load_fail = 0

    def _eep_save(self):
        self.eeprom_store[self.current_slot] = bytes(self.eeprom)
        path = self._eep_path()
        if path:
            with open(path, "wb") as f:
                f.write(bytes(self.eeprom))
        self.last_eep_save_ok = 1

    def _read_meta(self, slot):
        """(usado, 15 bytes de metadatos) del slot, como readSlotMeta()."""
        none = bytes([0xFF]) + bytes(14)
        path = self._slot_path(slot)
        if path is None or not os.path.isfile(path):
            return 0, none
        mp = path[:-4] + ".meta"
        if not os.path.isfile(mp):
            return 1, none
        with open(mp, "rb") as f:
            m = f.read(15)
        return 1, m.ljust(15, bytes(1))

    def _slot_path(self, slot):
        if self.slots_dir is None or not (0 <= slot < MAX_PROGRAM_SLOTS):
            return None
        return os.path.join(self.slots_dir, f"{slot:02d}.bin")

    def _prog_load(self, slot):
        # espejo de PORT_PROG_LOAD (iomap.h): carga el slot entero en la RAM
        # de la CPU y la reinicia -- "salto" a otro programa, sin vuelta
        # atras salvo que el programa cargado use este mismo puerto. Slot
        # inexistente/fuera de rango: no toca nada, sigue el que llamo (ni
        # siquiera se limpia pantalla/LED/sonido en ese caso).
        path = self._slot_path(slot)
        if path is None or not os.path.isfile(path):
            self.last_load_ok = 1   # 1 = FALLO (ver iomap.h PORT_PROG_LOAD)
            return
        with open(path, "rb") as f:
            data = f.read(PROGRAM_SIZE)
        if len(data) < PROGRAM_SIZE:
            data = data + bytes(PROGRAM_SIZE - len(data))
        self.cpu.m[:] = data
        self.cpu.r = [0] * 8
        self.cpu.pc = 0
        self.cpu.sp = 0xFFFF
        self.cpu.flags = 0
        self.cpu.halted = False
        # igual que clearRuntimeOutputs() en main.cpp: el programa que
        # arranca no debe heredar pantalla/LED/sonido/encoders del que lo
        # cargo (p.ej. un "sistema operativo" en un slot que encadena
        # varios programas, ver programs/sisop.asm).
        self.fb[:] = bytes(len(self.fb))
        self.text[:] = bytes(len(self.text))
        self.attr[:] = bytes(len(self.attr))
        self.led = 0
        self.dir_pos = 0
        self.dat_pos = 0
        for i in range(TIMER_COUNT):
            self.timer[i] = 0
            self.timer_set_ns[i] = self.now_ns
        self.snd_lo = self.snd_hi = self.snd_note = self.snd_dur = 0
        self.snd_vel = 100   # 0x0634: velocidad MIDI (solo Bluetooth en el aparato)
        self.snd_instr = 0   # 0x0635: instrumento 0..3
        self.power = 0       # 0x0612: modo ahorro (bit 0) -- aqui solo se recuerda
        self.bat_mv = 3900   # 0x0614/0x0615: bateria simulada (mV; > 4400 = USB)
        self.time_regs = [0] * 14   # 0x0671..0x067E (los congela OUT 0x0670)
        self._snd(0)
        # brillo y sonido: preferencias de TODO el aparato -- NO se tocan al
        # cargar otro programa, igual que main.cpp (ver iomap.h).
        self.eeprom[:] = bytes(256)   # el bufer de EEPROM tampoco se hereda
        self.current_slot = slot
        self.cur_meta = self._read_meta(slot)[1]
        self.last_load_ok = 0         # 0 = bien (antes ponia 1 por error)

    def _prog_save(self, slot):
        # espejo de PORT_PROG_SAVE: vuelca la RAM ACTUAL entera (65536 bytes,
        # igual que saveProgram en el aparato real -- no solo la parte
        # "usada" por el programa) en el slot pedido; sigue ejecutandose el
        # mismo programa despues.
        path = self._slot_path(slot)
        if path is None:
            self.last_save_ok = 0
            return
        with open(path, "wb") as f:
            f.write(bytes(self.cpu.m))
        with open(path[:-4] + ".meta", "wb") as f:
            f.write(self.cur_meta)
        self.current_slot = slot
        self.last_save_ok = 1

    def _snd(self, hz):
        if hz != self.snd_hz:
            self.sound_log.append((self.now_ns // 1_000_000, hz))
        self.snd_hz = hz

    @staticmethod
    def _text_index(port):
        if not (0x0400 <= port < 0x0500):
            return None
        off = port - 0x0400
        row, col = off >> 5, off & 31
        if row >= 8 or col >= 21:
            return None
        return row * 21 + col

    @staticmethod
    def _attr_index(port):
        # atributos de texto (0x0500..0x05FF): misma disposicion que el
        # texto (fila*32+col), banco de puertos contiguo justo despues de
        # TEXT_PORT_BASE (0x0400..0x04FF).
        if not (0x0500 <= port < 0x0600):
            return None
        off = port - 0x0500
        row, col = off >> 5, off & 31
        if row >= 8 or col >= 21:
            return None
        return row * 21 + col


def _bat_percent(mv):
    # misma curva que batPercent() en src/main.cpp
    MV = [3300, 3500, 3600, 3700, 3750, 3800, 3900, 4000, 4080, 4150]
    PCT = [0, 5, 12, 30, 40, 50, 65, 80, 90, 100]
    if mv <= MV[0]:
        return 0
    for i in range(1, 10):
        if mv <= MV[i]:
            return PCT[i - 1] + (PCT[i] - PCT[i - 1]) * (mv - MV[i - 1]) // (MV[i] - MV[i - 1])
    return 100


def _note_hz(note):
    if note == 0 or note > 127:
        return 0
    return round(440.0 * 2.0 ** ((note - 69) / 12.0))


class Cpu:
    def __init__(self, image, ports):
        self.m = bytearray(image)
        if len(self.m) < 65536:
            self.m += bytes(65536 - len(self.m))
        self.p = ports
        self.r = [0] * 8       # AL AH BL BH CL CH DL DH
        self.pc = 0
        self.sp = 0xFFFF
        self.flags = 0
        self.halted = False
        self.steps = 0
        ports.cpu = self   # 0x0640/0x0641 necesitan leer/reemplazar la RAM

    # registros de 8 bits (r[] ya es plano)
    def _f8(self):
        v = self.m[self.pc]
        self.pc = (self.pc + 1) & MASK
        return v

    def _f16(self):
        lo = self._f8()
        hi = self._f8()
        return lo | (hi << 8)

    def _push(self, v):
        self.sp = (self.sp - 1) & MASK
        self.m[self.sp] = v & 0xFF

    def _pop(self):
        v = self.m[self.sp]
        self.sp = (self.sp + 1) & MASK
        return v

    def _get16(self, p):
        return self.r[p * 2] | (self.r[p * 2 + 1] << 8)

    def _set16(self, p, v):
        self.r[p * 2] = v & 0xFF
        self.r[p * 2 + 1] = (v >> 8) & 0xFF

    def _flags(self, carry, res, neg_bit, overflow):
        f = FLAG_C if carry else 0
        if res == 0:
            f |= FLAG_Z
        if res & neg_bit:
            f |= FLAG_N
        if overflow:
            f |= FLAG_V
        self.flags = f

    def _arith(self, a, b, is_sub, cin=0):
        full = a - b - cin if is_sub else a + b + cin
        res = full & 0xFF
        carry = full < 0 if is_sub else full > 0xFF
        if is_sub:
            overflow = ((a ^ b) & (a ^ res) & 0x80) != 0
        else:
            overflow = (~(a ^ b) & (a ^ res) & 0x80) != 0
        self._flags(carry, res, 0x80, overflow)
        return res

    def _logic(self, res):
        self._flags(False, res, 0x80, False)
        return res

    def _cmp16(self, a, b):
        res = (a - b) & MASK
        self._flags(a < b, res, 0x8000, ((a ^ b) & (a ^ res) & 0x8000) != 0)

    def _alu(self, op, a, b):
        c = self.flags & FLAG_C
        if op == 0:      # MOV
            return b
        if op == 1:      # ADD
            return self._arith(a, b, False)
        if op == 2:      # ADC
            return self._arith(a, b, False, c)
        if op == 3:      # SUB
            return self._arith(a, b, True)
        if op == 4:      # SBC
            return self._arith(a, b, True, c)
        if op == 5:      # CMP
            self._arith(a, b, True)
            return a
        if op == 6:
            return self._logic(a & b)
        if op == 7:
            return self._logic(a | b)
        if op == 8:
            return self._logic(a ^ b)
        return a

    def _cond(self, c):
        z = bool(self.flags & FLAG_Z)
        cy = bool(self.flags & FLAG_C)
        n = bool(self.flags & FLAG_N)
        v = bool(self.flags & FLAG_V)
        return [True, z, not z, cy, not cy, n, not n, v][c]

    def _call(self, addr):
        self._push((self.pc >> 8) & 0xFF)
        self._push(self.pc & 0xFF)
        self.pc = addr

    def _shift(self, r, n, left):
        v = self.r[r]
        if left:
            res = (v << n) & 0xFF
            carry = bool((v >> (8 - n)) & 1)
            neg = bool(res & 0x80)
            self._flags(carry, res, 0x80, carry != neg)
        else:
            res = (v >> n) & 0xFF
            # V = bit 7 de ANTES de la instruccion (aunque desplace N bits)
            self._flags((v >> (n - 1)) & 1, res, 0x80, v & 0x80)
        self.r[r] = res

    def step(self):
        if self.halted:
            return False
        self.p.tick()
        self.steps += 1
        op = self._f8()
        fam, r = op >> 3, op & 7

        if fam == F_SYS:
            if r == 1:                       # HALT
                self.halted = True
            elif r == 2:                     # RET
                lo = self._pop()
                hi = self._pop()
                self.pc = lo | (hi << 8)
            elif r in (3, 4, 5):             # MOVB / MOVW / MOVBR
                src, dst, count = self._get16(1), self._get16(3), self._get16(2)
                if r == 5:
                    for i in range(count):
                        self.m[(dst - i) & MASK] = self.m[(src - i) & MASK]
                    self._set16(1, src - count)
                    self._set16(3, dst - count)
                else:
                    nbytes = count * 2 if r == 4 else count
                    for i in range(nbytes):
                        self.m[(dst + i) & MASK] = self.m[(src + i) & MASK]
                    self._set16(1, src + nbytes)
                    self._set16(3, dst + nbytes)
                self._set16(2, 0)
        elif fam == F_LDI:
            self.r[r] = self._f8()
        elif fam == F_LDA:
            self.r[r] = self.m[self._f16()]
        elif fam == F_STA:
            self.m[self._f16()] = self.r[r]
        elif fam == F_LDAR:
            self.r[r] = self.m[self._get16(self._f8() & 3)]
        elif fam == F_STAR:
            self.m[self._get16(self._f8() & 3)] = self.r[r]
        elif fam == F_IN:
            self.r[r] = self.p.read(self._f16())
        elif fam == F_OUT:
            self.p.write(self._f16(), self.r[r])
        elif fam == F_INR:
            self.r[r] = self.p.read(self._get16(self._f8() & 3))
        elif fam == F_OUTR:
            self.p.write(self._get16(self._f8() & 3), self.r[r])
        elif fam == F_ALURR:
            b1 = self._f8()
            self.r[r] = self._alu(b1 >> 3, self.r[r], self.r[b1 & 7])
        elif fam == F_ALUI:
            aop = self._f8()
            imm = self._f8()
            self.r[r] = self._alu(aop, self.r[r], imm)
        elif fam == F_ALUM:
            aop = self._f8()
            self.r[r] = self._alu(aop, self.r[r], self.m[self._f16()])
        elif fam == F_ALUP:
            b1 = self._f8()
            self.r[r] = self._alu(b1 >> 2, self.r[r], self.m[self._get16(b1 & 3)])
        elif fam == F_NOT:
            self.r[r] = self._logic((~self.r[r]) & 0xFF)
        elif fam in (F_SHR, F_SHL):
            self._shift(r, (self._f8() & 7) + 1, fam == F_SHL)
        elif fam == F_MUL:
            product = self.r[0] * self.r[r]
            self._set16(0, product)
            hi = product > 0xFF
            self._flags(hi, product, 0x8000, hi)
        elif fam == F_DIV:
            # AL=AX/reg AH=AX%reg -- satura (AL=AH=0xFF, C=V=1) en division
            # entre 0 o cociente que no cabe en 8 bits, igual que cpu.cpp
            divisor = self.r[r]
            ax = self._get16(0)
            if divisor != 0 and ax // divisor <= 0xFF:
                q, rem = divmod(ax, divisor)
                self.r[0], self.r[1] = q, rem
                self._flags(False, q, 0x80, False)
            else:
                self.r[0] = self.r[1] = 0xFF
                self.flags = FLAG_C | FLAG_V | FLAG_N
        elif fam in (F_INC, F_DEC):
            a = self.r[r]
            res = (a - 1) & 0xFF if fam == F_DEC else (a + 1) & 0xFF
            self.r[r] = res
            c = self.flags & FLAG_C           # C no cambia
            self._flags(c, res, 0x80, a == (0x80 if fam == F_DEC else 0x7F))
        elif fam == F_PUSH:
            self._push(self.r[r])
        elif fam == F_POP:
            self.r[r] = self._pop()
        elif fam == F_JMP:
            addr = self._f16()
            if self._cond(r):
                self.pc = addr
        elif fam == F_CALL:
            addr = self._f16()
            if self._cond(r):
                self._call(addr)
        elif fam == F_JX:
            if r in (0, 1):                  # JMPNV / CALLNV
                addr = self._f16()
                if not (self.flags & FLAG_V):
                    if r == 0:
                        self.pc = addr
                    else:
                        self._call(addr)
            elif r == 2:                     # JMP reg16
                self.pc = self._get16(self._f8() & 3)
            elif r == 3:                     # CALL reg16
                self._call(self._get16(self._f8() & 3))
        elif fam == F_R16:
            if r <= 5:
                b1 = self._f8()
                d, src = (b1 >> 3) & 3, b1 & 7
                v = self._get16(d)
                if r == 0:
                    self._set16(d, self._get16(src & 3))
                elif r == 1:
                    self._set16(d, (v + self._get16(src & 3)) & MASK)
                elif r == 2:
                    self._set16(d, (v - self._get16(src & 3)) & MASK)
                elif r == 3:
                    self._cmp16(v, self._get16(src & 3))
                elif r == 4:
                    self._set16(d, (v + self.r[src]) & MASK)
                else:
                    self._set16(d, (v - self.r[src]) & MASK)
        elif fam == F_R16I:
            if r <= 3:
                d = self._f8() & 3
                v = self._get16(d)
                if r == 0:
                    self._set16(d, self._f16())
                elif r == 1:
                    self._set16(d, (v + self._f8()) & MASK)
                elif r == 2:
                    self._set16(d, (v - self._f8()) & MASK)
                else:
                    self._cmp16(v, self._f16())
        elif fam == F_INCDEC16:
            v = self._get16(r & 3)
            self._set16(r & 3, (v - 1) & MASK if r & 4 else (v + 1) & MASK)
        elif fam == F_PUSHPOP16:
            if r & 4:
                lo = self._pop()
                hi = self._pop()
                self._set16(r & 3, lo | (hi << 8))
            else:
                v = self._get16(r & 3)
                self._push(v >> 8)
                self._push(v & 0xFF)
        return not self.halted


def render(ports):
    fb, text = ports.fb, ports.text
    lines = []
    for ry in range(0, 64, 2):
        row = []
        for x in range(128):
            top = fb[(ry) * 16 + (x >> 3)] & (0x80 >> (x & 7))
            bot = fb[(ry + 1) * 16 + (x >> 3)] & (0x80 >> (x & 7))
            row.append(" ▄▀█"[(1 if top else 0) + (2 if bot else 0)] if False else
                       ("█" if top and bot else "▀" if top else "▄" if bot else " "))
        lines.append("".join(row))
    # capa de texto: cada celda 6x8 -> 6 col x 4 half-rows
    for i, ch in enumerate(text):
        if ch == 0:
            continue
        r, c = divmod(i, 21)
        y0 = r * 4  # 8 px / 2 por linea
        x0 = c * 6
        glyph = chr(ch) if 32 <= ch < 127 else "?"
        if 0 <= y0 + 1 < len(lines):
            line = lines[y0 + 1]
            seg = glyph.center(6)
            lines[y0 + 1] = line[:x0] + seg[:max(0, 128 - x0)] + line[x0 + 6:]
    top = "┌" + "─" * 128 + "┐"
    bot = "└" + "─" * 128 + "┘"
    return "\n".join([top] + ["│" + ln + "│" for ln in lines] + [bot])


def load_script(path):
    events = []
    if not path:
        return events
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            at, action = line.split()
            events.append((int(at), action))
    events.sort()
    return events


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--steps", type=int, default=2_000_000)
    ap.add_argument("--script")
    ap.add_argument("--instr-ns", type=int, default=20_000)
    ap.add_argument("--frame-every", type=int, default=0,
                    help="vuelca la pantalla cada N instrucciones")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--epoch", type=int,
                    help="hora real al arrancar (segundos UTC) para 0x0670..; "
                         "por defecto, la del PC")
    ap.add_argument("--no-time", action="store_true",
                    help="sin hora real (como el aparato sin Wi-Fi ni PC)")
    ap.add_argument("--slot", type=int, default=0,
                    help="slot 'en curso' para los puertos de EEPROM "
                         "(0x0700-0x0801); por defecto 0")
    ap.add_argument("--slots-dir",
                    help="directorio con los slots de flash simulados "
                         "(NN.bin) para los puertos 0x0640/0x0641 -- ver "
                         "tools/slots.py para poblarlo desde .asm/.bin")
    args = ap.parse_args(argv)

    with open(args.image, "rb") as f:
        image = f.read()

    ports = Ports(instr_ns=args.instr_ns, slots_dir=args.slots_dir)
    import time as _time
    ports.epoch0 = None if args.no_time else (args.epoch if args.epoch is not None else int(_time.time()))
    ports.current_slot = args.slot
    cpu = Cpu(image, ports)
    events = load_script(args.script)
    ev_i = 0
    click_off = {}  # accion de pulsador -> instruccion en que soltar

    while cpu.steps < args.steps:
        while ev_i < len(events) and events[ev_i][0] <= cpu.steps:
            _, action = events[ev_i]
            ev_i += 1
            if action == "dat+":
                ports.dat_pos = (ports.dat_pos + 1) & 0xFF
            elif action == "dat-":
                ports.dat_pos = (ports.dat_pos - 1) & 0xFF
            elif action == "dir+":
                ports.dir_pos = (ports.dir_pos + 1) & 0xFF
            elif action == "dir-":
                ports.dir_pos = (ports.dir_pos - 1) & 0xFF
            elif action == "datdown":
                ports.dat_btn = 1
            elif action == "datup":
                ports.dat_btn = 0
            elif action == "dirdown":
                ports.dir_btn = 1
            elif action == "dirup":
                ports.dir_btn = 0
            elif action == "datclick":
                ports.dat_btn = 1
                click_off["dat"] = cpu.steps + CLICK_LEN
            elif action == "dirclick":
                ports.dir_btn = 1
                click_off["dir"] = cpu.steps + CLICK_LEN
            elif action == "frame":
                print(f"--- frame @ {cpu.steps} ---")
                print(render(ports))
        for k, off in list(click_off.items()):
            if cpu.steps >= off:
                setattr(ports, f"{k}_btn", 0)
                del click_off[k]
        if args.frame_every and cpu.steps % args.frame_every == 0 and cpu.steps:
            print(f"--- frame @ {cpu.steps}  pc={cpu.pc:04X} ---")
            print(render(ports))
        if not cpu.step():
            break

    if not args.quiet:
        print(f"\npasos: {cpu.steps}   pc=0x{cpu.pc:04X}   "
              f"{'HALT' if cpu.halted else 'en marcha'}")
        print(f"AX={cpu.r[1] << 8 | cpu.r[0]:04X} BX={cpu.r[3] << 8 | cpu.r[2]:04X} "
              f"CX={cpu.r[5] << 8 | cpu.r[4]:04X} DX={cpu.r[7] << 8 | cpu.r[6]:04X} "
              f"SP={cpu.sp:04X} LED={ports.led}")
        if ports.sound_log:
            print("sonido (ms, Hz):", ports.sound_log[:40])
        print(render(ports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
