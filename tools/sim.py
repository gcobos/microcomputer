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

# familias
(F_NOP, F_HALT, F_LDI, F_LDA, F_STA, F_ADD, F_SUB, F_AND, F_OR, F_XOR,
 F_NOT, F_SHR, F_SHL, F_IN, F_OUT, F_PUSH, F_POP, F_JMP, F_CALL, F_RET,
 F_ALUI) = range(21)
F_EXT = 31

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
        # g_soundMuted en main.cpp. sound_muted empieza en False (sonido
        # activado), igual que g_soundMuted en el firmware real.
        self.brightness = 0xCF   # OLED_CONTRAST_FULL (main.cpp)
        self.sound_muted = False

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
        if port == 0x0650:
            return self.brightness
        if port == 0x0651:
            return 0 if self.sound_muted else 1
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
        if port == 0x0610:
            self.led = val & 1
            return
        if port == 0x0640:
            self._prog_load(val)
            return
        if port == 0x0641:
            self._prog_save(val)
            return
        if port == 0x0650:
            self.brightness = val
            return
        if port == 0x0651:
            self.sound_muted = (val == 0)
            return

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
        self._snd(0)
        # brillo: de fabrica en cada ejecucion nueva (clearRuntimeOutputs());
        # sonido silenciado/activado NO se toca -- es una preferencia de
        # sesion, igual que main.cpp (ver iomap.h PORT_CFG_SOUND_EN).
        self.brightness = 0xCF
        self.last_load_ok = 1

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

    def _arith(self, a, b, is_sub):
        full = a - b if is_sub else a + b
        res = full & 0xFF
        carry = (a < b) if is_sub else (full > 0xFF)
        if is_sub:
            overflow = ((a ^ b) & (a ^ res) & 0x80) != 0
        else:
            overflow = (~(a ^ b) & (a ^ res) & 0x80) != 0
        f = 0
        if carry:
            f |= FLAG_C
        if res == 0:
            f |= FLAG_Z
        if res & 0x80:
            f |= FLAG_N
        if overflow:
            f |= FLAG_V
        self.flags = f
        return res

    def _logic(self, res):
        f = 0
        if res == 0:
            f |= FLAG_Z
        if res & 0x80:
            f |= FLAG_N
        self.flags = f
        return res

    def _alu(self, op, a, b):
        if op == 0:  # MOV
            return b
        if op == 1:
            return self._arith(a, b, False)
        if op == 2:
            return self._arith(a, b, True)
        if op == 3:
            self._arith(a, b, True)
            return a
        if op == 4:
            return self._logic(a & b)
        if op == 5:
            return self._logic(a | b)
        if op == 6:
            return self._logic(a ^ b)
        return a

    def _cond(self, c):
        z = bool(self.flags & FLAG_Z)
        cy = bool(self.flags & FLAG_C)
        n = bool(self.flags & FLAG_N)
        v = bool(self.flags & FLAG_V)
        table = [True, z, not z, cy, not cy, n, not n, v]
        return table[c] if c < len(table) else True

    def step(self):
        if self.halted:
            return False
        self.p.tick()
        self.steps += 1
        op = self._f8()
        fam, r = op >> 3, op & 7

        if fam == F_NOP:
            pass
        elif fam == F_HALT:
            self.halted = True
        elif fam == F_LDI:
            self.r[r] = self._f8()
        elif fam == F_LDA:
            self.r[r] = self.m[self._f16()]
        elif fam == F_STA:
            self.m[self._f16()] = self.r[r]
        elif fam in (F_ADD, F_SUB, F_AND, F_OR, F_XOR):
            alu = {F_ADD: 1, F_SUB: 2, F_AND: 4, F_OR: 5, F_XOR: 6}[fam]
            addr = self._f16()
            self.r[r] = self._alu(alu, self.r[r], self.m[addr])
        elif fam == F_NOT:
            self.r[r] = self._logic((~self.r[r]) & 0xFF)
        elif fam == F_SHR:
            v = self.r[r]
            res = v >> 1
            self.r[r] = res
            f = 0
            if v & 1:
                f |= FLAG_C
            if res == 0:
                f |= FLAG_Z
            if res & 0x80:
                f |= FLAG_N
            if v & 0x80:
                f |= FLAG_V
            self.flags = f
        elif fam == F_SHL:
            v = self.r[r]
            res = (v << 1) & 0xFF
            self.r[r] = res
            carry = bool(v & 0x80)
            neg = bool(res & 0x80)
            f = 0
            if carry:
                f |= FLAG_C
            if res == 0:
                f |= FLAG_Z
            if neg:
                f |= FLAG_N
            if carry != neg:
                f |= FLAG_V
            self.flags = f
        elif fam == F_IN:
            self.r[r] = self.p.read(self._f16())
        elif fam == F_OUT:
            self.p.write(self._f16(), self.r[r])
        elif fam == 21:  # LDA reg,[reg16]
            pair = self._f8() & 3
            addr = self.r[pair * 2] | (self.r[pair * 2 + 1] << 8)
            self.r[r] = self.m[addr]
        elif fam == 22:  # STA [reg16],reg
            pair = self._f8() & 3
            addr = self.r[pair * 2] | (self.r[pair * 2 + 1] << 8)
            self.m[addr] = self.r[r]
        elif fam == 23:  # IN reg,(reg16)
            pair = self._f8() & 3
            port = self.r[pair * 2] | (self.r[pair * 2 + 1] << 8)
            self.r[r] = self.p.read(port)
        elif fam == 24:  # OUT (reg16),reg
            pair = self._f8() & 3
            port = self.r[pair * 2] | (self.r[pair * 2 + 1] << 8)
            self.p.write(port, self.r[r])
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
                self._push((self.pc >> 8) & 0xFF)
                self._push(self.pc & 0xFF)
                self.pc = addr
        elif fam == F_RET:
            lo = self._pop()
            hi = self._pop()
            self.pc = lo | (hi << 8)
        elif fam == 25:  # SHR reg,#N (N = byte2+1, 1..8)
            n = (self._f8() & 7) + 1
            v = self.r[r]
            res = (v >> n) & 0xFF
            self.r[r] = res
            f = 0
            if (v >> (n - 1)) & 1:
                f |= FLAG_C
            if res == 0:
                f |= FLAG_Z
            if res & 0x80:
                f |= FLAG_N
            if v & 0x80:  # V = bit 7 de ANTES de esta instruccion (una sola,
                f |= FLAG_V  # aunque desplace N bits -- no de cada paso interno)
            self.flags = f
        elif fam == 26:  # SHL reg,#N (N = byte2+1, 1..8)
            n = (self._f8() & 7) + 1
            v = self.r[r]
            res = (v << n) & 0xFF
            self.r[r] = res
            carry = bool((v >> (8 - n)) & 1)
            neg = bool(res & 0x80)
            f = 0
            if carry:
                f |= FLAG_C
            if res == 0:
                f |= FLAG_Z
            if neg:
                f |= FLAG_N
            if carry != neg:
                f |= FLAG_V
            self.flags = f
        elif fam == F_EXT:
            operand = self._f8()
            dst, src = (operand >> 3) & 7, operand & 7
            self.r[dst] = self._alu(r, self.r[dst], self.r[src])
        elif fam == F_ALUI:
            dst = self._f8() & 7
            imm = self._f8()
            self.r[dst] = self._alu(r, self.r[dst], imm)
        elif fam == 27:  # MUL reg : AX = AL * reg, sin signo
            b = self.r[r]
            product = self.r[0] * b
            self.r[0] = product & 0xFF
            self.r[1] = (product >> 8) & 0xFF
            hi = 1 if product > 0xFF else 0
            f = hi
            if product == 0:
                f |= FLAG_Z
            if product & 0x8000:
                f |= FLAG_N
            if hi:
                f |= FLAG_V
            self.flags = f
        elif fam == 28:  # DIV reg : AL=AX/reg AH=AX%reg, sin signo -- satura
                          # (AL=AH=0xFF, C=V=1) en division entre 0 o cociente
                          # que no cabe en 8 bits, igual que cpu.cpp
            divisor = self.r[r]
            ax = self.r[0] | (self.r[1] << 8)
            ok, q, rem = False, 0, 0
            if divisor != 0:
                q, rem = divmod(ax, divisor)
                ok = q <= 0xFF
            if ok:
                self.r[0] = q
                self.r[1] = rem
                f = 0
                if q == 0:
                    f |= FLAG_Z
                if q & 0x80:
                    f |= FLAG_N
                self.flags = f
            else:
                self.r[0] = 0xFF
                self.r[1] = 0xFF
                self.flags = FLAG_C | FLAG_V | FLAG_N
        elif fam == 29:  # INC/DEC reg16 : opcode bajo = dir<<2|reg16, sin flags
            reg16 = r & 3
            dec = bool(r & 4)
            v = self.r[reg16 * 2] | (self.r[reg16 * 2 + 1] << 8)
            v = (v - 1) & MASK if dec else (v + 1) & MASK
            self.r[reg16 * 2] = v & 0xFF
            self.r[reg16 * 2 + 1] = (v >> 8) & 0xFF
        elif fam == 30:  # "extension 2": subop en r (ver isa.h OP_EXT2)
            sub = r
            if sub in (0, 1):  # ADD/SUB dst16,src8 (sin signo, sin flags)
                operand = self._f8()
                dst16 = (operand >> 3) & 3
                src8 = operand & 7
                v = self.r[dst16 * 2] | (self.r[dst16 * 2 + 1] << 8)
                ext = self.r[src8]
                v = (v + ext) & MASK if sub == 0 else (v - ext) & MASK
                self.r[dst16 * 2] = v & 0xFF
                self.r[dst16 * 2 + 1] = (v >> 8) & 0xFF
            elif sub in (2, 3):  # MOVB/MOVW: BX=origen DX=destino CX=cuenta
                src = self.r[2] | (self.r[3] << 8)
                dst = self.r[6] | (self.r[7] << 8)
                count = self.r[4] | (self.r[5] << 8)
                nbytes = count * 2 if sub == 3 else count
                for i in range(nbytes):
                    self.m[(dst + i) & MASK] = self.m[(src + i) & MASK]
                newsrc = (src + nbytes) & MASK
                newdst = (dst + nbytes) & MASK
                self.r[2], self.r[3] = newsrc & 0xFF, (newsrc >> 8) & 0xFF
                self.r[6], self.r[7] = newdst & 0xFF, (newdst >> 8) & 0xFF
                self.r[4] = self.r[5] = 0
            elif sub == 4:  # JMPNV
                addr = self._f16()
                if not (self.flags & FLAG_V):
                    self.pc = addr
            elif sub == 5:  # CALLNV
                addr = self._f16()
                if not (self.flags & FLAG_V):
                    self._push((self.pc >> 8) & 0xFF)
                    self._push(self.pc & 0xFF)
                    self.pc = addr
            elif sub == 6:  # MOV reg16,#imm16 -- unica LEN 4, sin flags
                pair = self._f8() & 3
                imm = self._f16()
                self.r[pair * 2] = imm & 0xFF
                self.r[pair * 2 + 1] = (imm >> 8) & 0xFF
            # sub 7: reservado, se comporta como NOP
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
    ap.add_argument("--slots-dir",
                    help="directorio con los slots de flash simulados "
                         "(NN.bin) para los puertos 0x0640/0x0641 -- ver "
                         "tools/slots.py para poblarlo desde .asm/.bin")
    args = ap.parse_args(argv)

    with open(args.image, "rb") as f:
        image = f.read()

    ports = Ports(instr_ns=args.instr_ns, slots_dir=args.slots_dir)
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
