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
import sys

MASK = 0xFFFF
FLAG_C, FLAG_Z, FLAG_N, FLAG_V = 1, 2, 4, 8

# familias
(F_NOP, F_HALT, F_LDI, F_LDA, F_STA, F_ADD, F_SUB, F_AND, F_OR, F_XOR,
 F_NOT, F_SHR, F_SHL, F_IN, F_OUT, F_PUSH, F_POP, F_JMP, F_CALL, F_RET,
 F_ALUI) = range(21)
F_EXT = 31

CLICK_LEN = 12000  # instrucciones que dura un "click" de pulsador


class Ports:
    def __init__(self, instr_ns=20_000):
        self.fb = bytearray(1024)
        self.text = bytearray(21 * 8)
        self.attr = bytearray(21 * 8)  # atributos de texto (puertos 0x0500+)
        self.timer = [0] * 8
        self.timer_set_ns = [0] * 8
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

    def tick(self):
        self.now_ns += self.instr_ns
        for i in range(8):
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
        if 0x0620 <= port < 0x0628:
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
        if 0x0620 <= port < 0x0628:
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
        return [True, z, not z, cy, not cy, n, not n][c] if c < 7 else True

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
        # 27..30: NOP
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
    args = ap.parse_args(argv)

    with open(args.image, "rb") as f:
        image = f.read()

    ports = Ports(instr_ns=args.instr_ns)
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
