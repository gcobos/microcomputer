"""compilink — conexión con compi por el USB (protocolo "COMPI ..." de
src/main.cpp, ver provisionPoll() y los comentarios de encima).

La usan tools/compi.py (y, por debajo, compi_send.py / compi_recv.py).
Aporta lo que antes tenía que hacer cada herramienta a mano:

  * Busca el puerto sola: el USB-serie del propio ESP32-C3 (VID 0x303A). Si
    hay varios, se queda con el que contesta a "COMPI HELLO".
  * Reintenta: si el aparato no contesta (p. ej. justo tras reconectarse el
    USB, o porque otra cosa del PC tocó el puerto), cierra, espera, vuelve a
    abrir y repite la orden. Los errores "de verdad" (slot vacío, fuera de
    rango) no se reintentan.
  * Comprueba el checksum de todo lo que va y viene.

Necesita pyserial  (pip install pyserial).
"""
import time

IMAGE_SIZE = 65536
EEPROM_SIZE = 256
MAX_SLOTS = 60
CHUNK = 1024                 # COMPI_CHUNK en src/main.cpp
ESPRESSIF_VID = 0x303A

CATEGORY_NAMES = {1: "SYSTEM", 2: "GAME", 3: "PROGRAM", 4: "UTILITY",
                  5: "DEMO", 6: "DOCS", 255: "-"}


def pc_timezone():
    """Zona horaria del PC en formato POSIX (la ultima linea de un fichero
    TZif, p. ej. /etc/localtime), o None si no se puede saber."""
    import os  # noqa: PLC0415
    for path in (os.environ.get("TZ_FILE"), "/etc/localtime"):
        if not path:
            continue
        try:
            with open(path, "rb") as f:
                tail = f.read()[-128:]
            line = tail.rstrip(b"\n").rsplit(b"\n", 1)[-1].decode()
            if line and len(line) < 64 and not line.startswith("TZif"):
                return line
        except OSError:
            pass
    return None


class CompiError(Exception):
    """Fallo de la orden. transient=True: merece la pena reintentar."""

    def __init__(self, msg, transient=True):
        super().__init__(msg)
        self.transient = transient


def _serial():
    try:
        import serial  # noqa: PLC0415
        return serial
    except ImportError:
        raise CompiError("falta pyserial  ->  pip install pyserial", transient=False)


def candidate_ports():
    """Puertos que parecen un compi (USB-serie nativo del ESP32), en orden."""
    _serial()
    from serial.tools import list_ports  # noqa: PLC0415
    return [p.device for p in sorted(list_ports.comports(), key=lambda p: p.device)
            if p.vid == ESPRESSIF_VID]


class Link:
    def __init__(self, port=None, baud=115200, retries=3, log=print, auto_time=True):
        self.port = port
        self.baud = baud
        self.retries = retries
        self.log = log or (lambda *a, **k: None)
        self.ser = None
        self.auto_time = auto_time

    # -- apertura y busqueda del puerto ------------------------------------
    def __enter__(self):
        self.open()
        if self.auto_time:
            self._auto_time()
        return self

    def _auto_time(self):
        """Si el aparato no tiene hora (ni Wi-Fi que se la de), le pone la
        del PC. Silencioso: con un firmware anterior no hace nada."""
        try:
            hi = self.hello()
            if not hi or hi[1] < 3:
                return
            st = self.net_status()
            if not st["status"] & 1:
                self.set_time()
                tz = pc_timezone()
                if tz and tz != st["tz"]:
                    self.set_tz(tz)
                self.log("  (puesta la hora del PC en el aparato)")
        except CompiError:
            pass

    def __exit__(self, *exc):
        self.close()

    def _open_port(self, port):
        serial = _serial()
        ser = serial.Serial(port, self.baud, timeout=2)
        time.sleep(0.3)
        ser.reset_input_buffer()
        return ser

    def open(self):
        if self.port:
            self.ser = self._open_port(self.port)
            return
        cands = candidate_ports()
        if not cands:
            raise CompiError("no encuentro ningun compi por USB (USB-serie del "
                             "ESP32-C3, VID 303a). ¿Esta enchufado? Con --port "
                             "se puede indicar a mano.", transient=False)
        if len(cands) == 1:
            self.port = cands[0]
            self.ser = self._open_port(self.port)
            return
        for p in cands:                   # varios: el que conteste
            try:
                self.ser = self._open_port(p)
                if self._hello_once() is not None:
                    self.port = p
                    return
            except Exception:  # noqa: BLE001
                pass
            self.close()
        raise CompiError(f"hay varios puertos del ESP32 ({', '.join(cands)}) y "
                         f"ninguno contesta como compi; usa --port", transient=False)

    def close(self):
        if self.ser is not None:
            try:
                self.ser.close()
            except Exception:  # noqa: BLE001
                pass
            self.ser = None

    def _reopen(self):
        self.close()
        time.sleep(1.0)
        port = self.port
        for _ in range(10):               # el USB puede tardar en reaparecer
            try:
                self.ser = self._open_port(port)
                return
            except Exception:  # noqa: BLE001
                time.sleep(0.5)
        raise CompiError(f"no puedo volver a abrir {port}")

    # -- primitivas -----------------------------------------------------------
    def _send_line(self, text):
        self.ser.reset_input_buffer()
        self.ser.write((text + "\n").encode())
        self.ser.flush()

    def _wait(self, prefixes, timeout):
        """Primera linea que empiece por alguno de los prefijos (o COMPI ERR)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.ser.readline().decode(errors="replace").strip()
            if line.startswith("COMPI ERR"):
                why = line[len("COMPI ERR"):].strip()
                # slot vacio / fuera de rango: no se arregla repitiendo
                raise CompiError(f"el aparato dice: {why}",
                                 transient=why.startswith(("datos", "flash")))
            if any(line.startswith(p) for p in prefixes):
                return line
        raise CompiError(f"el aparato no contesta (esperaba {prefixes[0]!r})")

    def _read_exact(self, n, timeout=20):
        data = bytearray()
        deadline = time.time() + timeout
        while len(data) < n and time.time() < deadline:
            data += self.ser.read(n - len(data))
        if len(data) != n:
            raise CompiError(f"solo llegaron {len(data)} de {n} bytes")
        return bytes(data)

    def _retry(self, what, fn):
        last = None
        for attempt in range(1 + self.retries):
            try:
                if self.ser is None:
                    self.open()
                return fn()
            except CompiError as e:
                if not e.transient:
                    raise
                last = e
            except OSError as e:          # SerialException hereda de OSError
                last = CompiError(str(e))
            if attempt < self.retries:
                self.log(f"  {what}: {last} -- reintento {attempt + 1}/{self.retries}")
                self._reopen()
        raise CompiError(f"{what}: {last}", transient=False)

    # -- ordenes ---------------------------------------------------------------
    def _hello_once(self):
        self._send_line("COMPI HELLO")
        try:
            parts = self._wait(["COMPI HI"], 2).split()
            return int(parts[2]), int(parts[3])
        except (CompiError, IndexError, ValueError):
            return None

    def hello(self):
        """(slots, version del protocolo); None si el firmware es anterior
        (solo entiende LOAD y DUMP)."""
        return self._hello_once()

    def list(self):
        """[(slot, categoria, nombre)] de los slots ocupados."""
        def go():
            self._send_line("COMPI LIST")
            out = []
            deadline = time.time() + 10
            while time.time() < deadline:
                line = self.ser.readline().decode(errors="replace").rstrip("\r\n")
                if line.startswith("COMPI SLOT "):
                    rest = line[len("COMPI SLOT "):]
                    slot, cat, *name = rest.split(" ", 2)
                    out.append((int(slot), int(cat), name[0] if name else ""))
                elif line.startswith("COMPI END"):
                    if int(line.split()[2]) != len(out):
                        raise CompiError("lista incompleta")
                    return out
            raise CompiError("el aparato no contesta a LIST (¿firmware antiguo?)")
        return self._retry("listar", go)

    def checksum(self, slot):
        """Suma de los 65536 bytes del slot, o None si esta vacio."""
        def go():
            self._send_line(f"COMPI SUM {slot}")
            try:
                return int(self._wait(["COMPI OK"], 10).split()[2])
            except CompiError as e:
                if "empty" in str(e):
                    return None
                raise
        return self._retry(f"checksum del slot {slot}", go)

    def dump(self, slot, length=IMAGE_SIZE):
        def go():
            self._send_line(f"COMPI DUMP {slot} {length}")
            n = int(self._wait(["COMPI READY"], 10).split()[2])
            data = self._read_exact(n)
            got = int(self._wait(["COMPI OK"], 10).split()[2])
            if got != sum(data) & 0xFFFFFFFF:
                raise CompiError("checksum distinto (transmision corrupta)")
            return data
        return self._retry(f"leer el slot {slot}", go)

    def load(self, slot, data, category=None, name=None):
        """Graba data (hasta 65536 bytes; el resto, a 0) con sus metadatos."""
        data = bytes(data)
        if len(data) > IMAGE_SIZE:
            raise CompiError(f"la imagen ({len(data)} B) pasa de {IMAGE_SIZE}", transient=False)
        header = f"COMPI LOAD {slot} {len(data)}"
        if category is not None and (category != 255 or name):
            header += f" {category} {name or ''}"

        def go():
            self._send_line(header)
            self._wait(["COMPI READY"], 10)
            off = 0
            while off < len(data):
                chunk = data[off:off + CHUNK]
                self.ser.write(chunk)
                self.ser.flush()
                off += len(chunk)
                self._wait(["COMPI CHUNK"], 5)
            got = int(self._wait(["COMPI OK"], 20).split()[2])
            if got != sum(data) & 0xFFFFFFFF:
                raise CompiError("checksum distinto tras grabar")
        return self._retry(f"grabar el slot {slot}", go)

    def eeprom_dump(self, slot):
        def go():
            self._send_line(f"COMPI EEDUMP {slot}")
            n = int(self._wait(["COMPI READY"], 5).split()[2])
            data = self._read_exact(n)
            got = int(self._wait(["COMPI OK"], 5).split()[2])
            if got != sum(data) & 0xFFFFFFFF:
                raise CompiError("checksum distinto (transmision corrupta)")
            return data
        return self._retry(f"leer la EEPROM del slot {slot}", go)

    def eeprom_load(self, slot, data):
        data = bytes(data)
        if len(data) != EEPROM_SIZE:
            raise CompiError(f"la EEPROM son {EEPROM_SIZE} bytes", transient=False)

        def go():
            self._send_line(f"COMPI EELOAD {slot}")
            self._wait(["COMPI READY"], 5)
            self.ser.write(data)
            self.ser.flush()
            got = int(self._wait(["COMPI OK"], 10).split()[2])
            if got != sum(data) & 0xFFFFFFFF:
                raise CompiError("checksum distinto tras grabar")
        return self._retry(f"grabar la EEPROM del slot {slot}", go)

    def diag(self):
        """Diagnostico del aparato (ver COMPI DIAG en src/main.cpp)."""
        def go():
            self._send_line("COMPI DIAG")
            p = self._wait(["COMPI DIAG"], 5).split()
            keys = ("boots", "reason", "uptime_ms", "exec_starts", "loads", "light_sleeps",
                    "sound_bt", "bt_state", "bt_connected", "clock", "bat_mv", "usb", "bt_itvl_us")
            return dict(zip(keys, (int(x) for x in p[2:15])))
        return self._retry("diagnostico", go)

    def tone(self, hz, duty, ms, decay=False):
        """PRUEBA del timbre del zumbador: un tono con ese ciclo de trabajo
        (0..1023 = 0..100 %); con decay, el ciclo baja hasta 0 (COMPI TONE)."""
        def go():
            self._send_line(f"COMPI TONE {int(hz)} {int(duty)} {int(ms)} {1 if decay else 0}")
            self._wait(["COMPI OK"], ms / 1000 + 3)
        return self._retry("tocar un tono", go)

    def note(self, instr, hz, ms):
        """PRUEBA: una nota en el zumbador con el instrumento 0..3 (COMPI NOTE)."""
        def go():
            self._send_line(f"COMPI NOTE {int(instr)} {int(hz)} {int(ms)}")
            self._wait(["COMPI OK"], ms / 1000 + 3)
        return self._retry("tocar una nota", go)

    def midi_test(self, n, ms):
        """PRUEBA: n notas por Bluetooth MIDI cada ms milisegundos (COMPI MIDITEST)."""
        self._send_line(f"COMPI MIDITEST {int(n)} {int(ms)}")
        self._wait(["COMPI OK"], n * ms / 1000 + 5)

    def set_sound(self, out):
        """out: "bt", "buzzer" u "off" (silencio)."""
        def go():
            self._send_line("COMPI SOUND " + {"bt": "BT", "off": "OFF"}.get(out, "BUZZER"))
            self._wait(["COMPI OK"], 5)
        return self._retry("cambiar la salida del sonido", go)

    # -- hora y red (protocolo 3) ---------------------------------------------
    def set_time(self, epoch=None):
        epoch = int(time.time()) if epoch is None else int(epoch)

        def go():
            self._send_line(f"COMPI TIME {epoch}")
            self._wait(["COMPI OK"], 5)
        return self._retry("poner la hora", go)

    def net_status(self):
        """{'status', 'epoch', 'ssid', 'tz'}; status = bits de PORT_TIME_CTRL."""
        def go():
            self._send_line("COMPI NET")
            parts = self._wait(["COMPI NET"], 5).split()
            def hx(t):
                return "" if t == "-" else bytes.fromhex(t).decode(errors="replace")
            return {"status": int(parts[2]), "epoch": int(parts[3]), "ssid": hx(parts[4]),
                    "tz": parts[5] if len(parts) > 5 else "",
                    "used": hx(parts[6]) if len(parts) > 6 else ""}
        return self._retry("leer el estado de la red", go)

    def set_wifi(self, ssid, password=""):
        if ssid:
            arg = ssid.encode().hex() + (" " + password.encode().hex() if password else "")
        else:
            arg = "-"
        if len(ssid.encode()) > 32 or len(password.encode()) > 64:
            raise CompiError("el nombre de red va hasta 32 bytes y la clave hasta 64", transient=False)

        def go():
            self._send_line(f"COMPI WIFI {arg}")
            self._wait(["COMPI OK"], 10)
        return self._retry("configurar el Wi-Fi", go)

    def set_tz(self, tz):
        def go():
            self._send_line(f"COMPI TZ {tz}")
            self._wait(["COMPI OK"], 10)
        return self._retry("poner la zona horaria", go)

    def sync(self):
        def go():
            self._send_line("COMPI SYNC")
            self._wait(["COMPI OK"], 5)
        return self._retry("sincronizar", go)

    def delete(self, slot):
        def go():
            self._send_line(f"COMPI DEL {slot}")
            self._wait(["COMPI OK"], 10)
        return self._retry(f"borrar el slot {slot}", go)
