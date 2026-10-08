#!/usr/bin/env python3
"""compi — todo lo que se hace con el aparato por el USB, en una herramienta.

    python3 tools/compi.py list                     # slots ocupados, con nombre
    python3 tools/compi.py send programs/pong.asm   # ensambla y graba en su .slot
    python3 tools/compi.py send prog.bin --slot 30  # un .bin necesita --slot
    python3 tools/compi.py recv 22 -o play.bin      # saca un slot a un fichero
    python3 tools/compi.py backup                   # copia de TODO (programas,
                                                    # nombres y EEPROM)
    python3 tools/compi.py restore backups/compi-20261008-101500
    python3 tools/compi.py rm 30                    # vacia un slot (pregunta)
    python3 tools/compi.py ports                    # que puertos parecen un compi
    python3 tools/compi.py wifi MiRed               # Wi-Fi para la hora (pide la clave)
    python3 tools/compi.py net                      # hora, red y zona horaria
    python3 tools/compi.py time                     # pone la hora del PC
    python3 tools/compi.py tz "CET-1CEST,M3.5.0,M10.5.0/3"

El puerto se busca solo (--port para indicarlo a mano) y cada orden se
reintenta si el aparato no contesta. Si el aparato no tiene hora, cualquier
orden le pone la del PC de paso. Todo lo que va y viene se comprueba con
su checksum.

send CONSERVA LOS DATOS del programa: si el .asm declara zonas .persist (p.
ej. las canciones de play.asm) y en el slot ya esta ese mismo programa (mismo
nombre), primero lee esas zonas del aparato y las mete en la imagen nueva.
--no-persist las borra; --keep 0x4000-0xC7FF hace lo mismo a mano (p. ej.
para un .bin).

backup guarda en una carpeta (por defecto backups/compi-<fecha>) un NN.bin
por slot ocupado, un NN.eep por cada EEPROM con algo grabado y un
index.json con nombres y categorias. restore lo vuelve a grabar todo y se
salta lo que ya esta igual en el aparato (compara checksums); no toca los
slots que no estan en la copia salvo con --delete-extra.

Necesita pyserial  (pip install pyserial) y el firmware con el protocolo 2
(COMPI HELLO/LIST/SUM/EEDUMP/EELOAD/DEL); send y recv funcionan tambien con
el anterior.
"""
import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casm  # noqa: E402
from compilink import (CATEGORY_NAMES, EEPROM_SIZE, IMAGE_SIZE, MAX_SLOTS,  # noqa: E402
                       CompiError, Link, candidate_ports)


def say(*a):
    print(*a, flush=True)


def slot_arg(text):
    v = int(text, 0)
    if not 0 <= v < MAX_SLOTS:
        raise argparse.ArgumentTypeError(f"slot fuera de rango (0..{MAX_SLOTS - 1})")
    return v


def range_arg(text):
    try:
        a, b = (int(x, 0) for x in text.split("-"))
    except ValueError:
        raise argparse.ArgumentTypeError("rango INICIO-FIN, p. ej. 0x4000-0xC7FF")
    if not 0 <= a <= b < IMAGE_SIZE:
        raise argparse.ArgumentTypeError("rango fuera de 0x0000-0xFFFF")
    return (a, b + 1)                     # fin inclusivo en la linea de ordenes


def cat_name(c):
    return CATEGORY_NAMES.get(c, str(c))


# --- programas: .asm -> imagen + metadatos ---------------------------------
def build(path):
    """(imagen recortada, slot, categoria, nombre, [(inicio, fin)])."""
    if not path.endswith(".asm"):
        with open(path, "rb") as f:
            return f.read(), None, None, None, []
    asm = casm.Assembler()
    with open(path, encoding="utf-8") as f:
        try:
            image = asm.assemble(f.read(), path)
        except casm.AsmError as e:
            raise CompiError(f"{path}: {e}", transient=False)
    used = max(1, asm.max_addr)
    out = path.rsplit(".", 1)[0] + ".bin"
    with open(out, "wb") as f:            # el .bin, como casm.py
        f.write(image[:used])
    return image[:used], asm.slot, asm.category, asm.name, list(asm.persist)


# --- ordenes -----------------------------------------------------------------
def cmd_ports(args):
    ports = candidate_ports()
    if not ports:
        say("no hay ningun puerto del ESP32-C3 (VID 303a)")
        return 1
    for p in ports:
        try:
            with Link(p, retries=0, log=None) as link:
                hi = link.hello()
            say(f"{p}: compi" + (f" (protocolo {hi[1]}, {hi[0]} slots)" if hi
                                  else " (firmware antiguo: sin HELLO)"))
        except Exception as e:  # noqa: BLE001
            say(f"{p}: no contesta ({e})")
    return 0


def cmd_list(args):
    with Link(args.port) as link:
        slots = link.list()
    say(f"{'slot':>4}  {'categoria':<9}  nombre")
    for s, c, n in slots:
        say(f"{s:>4}  {cat_name(c):<9}  {n}")
    say(f"{len(slots)} slots ocupados de {MAX_SLOTS}")
    return 0


def cmd_send(args):
    data, slot, cat, name, persist = build(args.file)
    if args.slot is not None:
        if slot is not None and slot != args.slot:
            say(f"aviso: --slot {args.slot} no coincide con la .slot {slot} del fichero")
        slot = args.slot
    if slot is None:
        raise CompiError("falta --slot (un .bin no lleva esa informacion)", transient=False)
    keep = list(args.keep or [])
    if args.no_persist:
        persist = []
    with Link(args.port) as link:
        if persist and not keep:
            # solo si el slot tiene ESTE programa: los datos de otro no sirven
            here = {s: (c, n) for s, c, n in _list_or_none(link) or []}
            if slot not in here:
                say(f"slot {slot} vacio: no hay datos que conservar")
            elif name and here[slot][1] != name:
                say(f"en el slot {slot} esta {here[slot][1]!r}, no {name!r}: "
                    f"no se conservan sus datos")
            else:
                keep = persist
        img = bytes(data)
        if keep:
            old = link.dump(slot)
            img = bytearray(img) + bytes(IMAGE_SIZE - len(img))
            for a, b in keep:
                img[a:b] = old[a:b]
                say(f"conservados 0x{a:04X}-0x{b - 1:04X} del slot {slot}")
            img = bytes(img)
        link.load(slot, img, cat, name)
    meta = f" ({name}, {cat_name(cat)})" if name or cat is not None else ""
    say(f"grabado {args.file} en el slot {slot}{meta}  (checksum OK)")
    return 0


def _list_or_none(link):
    try:
        return link.list()
    except CompiError:
        return None                       # firmware antiguo: sin LIST


def cmd_recv(args):
    out = args.output or f"slot{args.slot:02d}.bin"
    with Link(args.port) as link:
        data = link.dump(args.slot, args.len or IMAGE_SIZE)
    with open(out, "wb") as f:
        f.write(data)
    say(f"slot {args.slot} -> {out} ({len(data)} bytes, checksum OK)")
    return 0


def cmd_backup(args):
    folder = args.dir or os.path.join(
        "backups", "compi-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(folder, exist_ok=True)
    index = {"created": datetime.datetime.now().isoformat(timespec="seconds"),
             "slots": [], "eeprom": []}
    with Link(args.port) as link:
        slots = link.list()
        say(f"{len(slots)} slots ocupados -> {folder}")
        for s, c, n in slots:
            data = link.dump(s)
            with open(os.path.join(folder, f"{s:02d}.bin"), "wb") as f:
                f.write(data)
            index["slots"].append({"slot": s, "category": c, "name": n,
                                   "sum": sum(data) & 0xFFFFFFFF})
            say(f"  {s:>2}  {n or '(sin nombre)'}")
        for s in range(MAX_SLOTS):
            ee = link.eeprom_dump(s)
            if ee == b"\xff" * EEPROM_SIZE:
                continue                  # nunca grabada
            with open(os.path.join(folder, f"{s:02d}.eep"), "wb") as f:
                f.write(ee)
            index["eeprom"].append(s)
        say(f"  EEPROM con datos: {index['eeprom'] or 'ninguna'}")
    with open(os.path.join(folder, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2, ensure_ascii=False)
    say(f"copia completa en {folder}")
    return 0


def cmd_restore(args):
    with open(os.path.join(args.dir, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    only = set(args.slots) if args.slots else None
    wanted = [e for e in index["slots"] if only is None or e["slot"] in only]
    with Link(args.port) as link:
        here = {s: (c, n) for s, c, n in link.list()}
        for e in wanted:
            s = e["slot"]
            with open(os.path.join(args.dir, f"{s:02d}.bin"), "rb") as f:
                data = f.read()
            same_meta = here.get(s) == (e["category"], e["name"])
            if same_meta and link.checksum(s) == sum(data) & 0xFFFFFFFF:
                say(f"  {s:>2}  {e['name']}: igual, no se toca")
                continue
            if not args.dry_run:
                link.load(s, data, e["category"], e["name"])
            say(f"  {s:>2}  {e['name']}: restaurado")
        if not args.no_eeprom:
            for s in index["eeprom"]:
                if only is not None and s not in only:
                    continue
                with open(os.path.join(args.dir, f"{s:02d}.eep"), "rb") as f:
                    ee = f.read()
                if link.eeprom_dump(s) == ee:
                    continue
                if not args.dry_run:
                    link.eeprom_load(s, ee)
                say(f"  {s:>2}  EEPROM restaurada")
        if args.delete_extra:
            in_backup = {e["slot"] for e in index["slots"]}
            extra = sorted(s for s in here if s not in in_backup
                           and (only is None or s in only))
            if extra and (args.yes or _confirm(f"vaciar los slots {extra}, que no estan en la copia?")):
                for s in extra:
                    if not args.dry_run:
                        link.delete(s)
                    say(f"  {s:>2}  {here[s][1]}: vaciado")
    say("restauracion terminada" + (" (simulada: --dry-run)" if args.dry_run else ""))
    return 0


def _confirm(question):
    try:
        return input(f"{question} [s/N] ").strip().lower() in ("s", "si", "sí", "y", "yes")
    except EOFError:
        return False


def cmd_net(args):
    import time as _t
    with Link(args.port, auto_time=False) as link:
        st = link.net_status()
    s = st["status"]
    hora = (_t.strftime("%Y-%m-%d %H:%M:%S", _t.localtime(st["epoch"])) + " (en la zona del PC)"
            if s & 1 else "SIN HORA")
    say(f"hora:   {hora}" + ("  · vino del Wi-Fi" if s & 2 else ("  · puesta desde el PC" if s & 1 else "")))
    say(f"wifi:   {st['ssid'] or '(sin configurar: prueba las redes abiertas)'}"
        + ("  · buscando/conectando ahora" if s & 4 else ""))
    if st.get("used"):
        say(f"la hora vino de la red: {st['used']}")
    say(f"zona:   {st['tz']}")
    return 0


def cmd_time(args):
    from compilink import pc_timezone  # noqa: PLC0415
    tz = pc_timezone()
    with Link(args.port, auto_time=False) as link:
        link.set_time()
        if tz and tz != link.net_status()["tz"]:
            link.set_tz(tz)
    say("hora del PC puesta en el aparato" + (f" (zona {tz})" if tz else ""))
    return 0


def cmd_wifi(args):
    password = args.password
    if args.ssid and password is None:
        import getpass  # noqa: PLC0415
        password = getpass.getpass(f"clave de {args.ssid} (vacia si es abierta): ")
    with Link(args.port, auto_time=False) as link:
        link.set_wifi(args.ssid or "", password or "")
    say(f"Wi-Fi: {args.ssid} -- el aparato se conecta un momento para poner la hora"
        if args.ssid else "Wi-Fi quitado")
    return 0


def cmd_tz(args):
    with Link(args.port, auto_time=False) as link:
        link.set_tz(args.tz)
    say(f"zona horaria: {args.tz}")
    return 0


def cmd_sync(args):
    with Link(args.port, auto_time=False) as link:
        link.sync()
    say("sincronizando por Wi-Fi (mira 'compi.py net' en unos segundos)")
    return 0


RESET_REASONS = {0: "desconocido", 1: "encendido", 2: "pin de reset", 3: "por software",
                 4: "CUELGUE (panic)", 5: "VIGILANTE de interrupciones", 6: "VIGILANTE de tareas",
                 7: "VIGILANTE", 8: "deep sleep", 9: "CAIDA DE TENSION (brownout)",
                 10: "SDIO", 11: "USB", 12: "JTAG", 13: "eFuse", 14: "fallo de alimentacion",
                 15: "CPU bloqueada"}


def cmd_diag(args):
    with Link(args.port, auto_time=False) as link:
        d = link.diag()
    up = d["uptime_ms"] // 1000
    say(f"arranques desde el ultimo encendido: {d['boots']}")
    say(f"motivo del ultimo arranque:         {RESET_REASONS.get(d['reason'], d['reason'])}")
    say(f"encendido desde hace:               {up // 3600} h {up // 60 % 60} min {up % 60} s")
    say(f"entradas a RUN (EDIT -> RUN):       {d['exec_starts']}")
    say(f"cargas de un slot:                  {d['loads']}")
    say(f"light sleeps de un programa:        {d['light_sleeps']}")
    if "sound_bt" in d:
        bt = ["parado", "buscando otros compi", "anunciandose"][d["bt_state"]] if d["bt_state"] < 3 else d["bt_state"]
        say(f"salida del sonido:                  {'Bluetooth MIDI' if d['sound_bt'] else 'zumbador'}")
        say(f"Bluetooth:                          {bt}" + ("  · CONECTADO" if d["bt_connected"] else ""))
        c = d["clock"]
        say(f"reloj:                              {'con hora' if c & 1 else 'sin hora'}"
            + ("  · Wi-Fi buscando/conectando" if c & 4 else ""))
    return 0


def cmd_sound(args):
    with Link(args.port, auto_time=False) as link:
        link.set_sound(args.out == "bt")
    say("sonido por " + ("Bluetooth MIDI" if args.out == "bt" else "el zumbador"))
    return 0


def cmd_rm(args):
    with Link(args.port) as link:
        here = {s: n for s, _, n in link.list()}
        if args.slot not in here:
            say(f"el slot {args.slot} ya esta vacio")
            return 0
        if not (args.yes or _confirm(f"vaciar el slot {args.slot} ({here[args.slot]})?")):
            say("no se toca nada")
            return 1
        link.delete(args.slot)
    say(f"slot {args.slot} vaciado")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="puerto serie (por defecto, se busca solo)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ports", help="puertos que parecen un compi")
    sub.add_parser("list", help="slots ocupados con su nombre y categoria")

    p = sub.add_parser("send", help="graba un .asm (o .bin) en un slot")
    p.add_argument("file")
    p.add_argument("--slot", type=slot_arg)
    p.add_argument("--no-persist", action="store_true",
                   help="no conservar las zonas .persist (se borran sus datos)")
    p.add_argument("--keep", type=range_arg, action="append", metavar="INICIO-FIN",
                   help="conservar esta zona de lo que haya en el slot (se puede repetir)")

    p = sub.add_parser("recv", help="saca un slot a un fichero")
    p.add_argument("slot", type=slot_arg)
    p.add_argument("-o", "--output")
    p.add_argument("--len", type=lambda t: int(t, 0), help="solo los primeros N bytes")

    p = sub.add_parser("backup", help="copia de todos los slots, nombres y EEPROM")
    p.add_argument("dir", nargs="?")

    p = sub.add_parser("restore", help="vuelve a grabar una copia")
    p.add_argument("dir")
    p.add_argument("--slots", type=slot_arg, nargs="+", help="solo estos slots")
    p.add_argument("--no-eeprom", action="store_true")
    p.add_argument("--delete-extra", action="store_true",
                   help="vaciar los slots ocupados que no esten en la copia")
    p.add_argument("--yes", action="store_true", help="no preguntar")
    p.add_argument("--dry-run", action="store_true", help="solo decir que haria")

    sub.add_parser("net", help="hora, red Wi-Fi y zona horaria del aparato")
    sub.add_parser("diag", help="reinicios, su motivo, tiempo encendido... del aparato")
    p = sub.add_parser("sound", help="salida del sonido: bt (Bluetooth MIDI) o buzzer")
    p.add_argument("out", choices=["bt", "buzzer"])
    sub.add_parser("time", help="pone la hora del PC en el aparato")
    sub.add_parser("sync", help="que el aparato pida ya la hora por Wi-Fi")
    p = sub.add_parser("wifi", help="red Wi-Fi para la hora (sin nombre: quitarla)")
    p.add_argument("ssid", nargs="?")
    p.add_argument("password", nargs="?", help="si no se da, se pregunta")
    p = sub.add_parser("tz", help="zona horaria POSIX")
    p.add_argument("tz")

    p = sub.add_parser("rm", help="vacia un slot")
    p.add_argument("slot", type=slot_arg)
    p.add_argument("--yes", action="store_true")

    args = ap.parse_args(argv)
    try:
        return {"ports": cmd_ports, "list": cmd_list, "send": cmd_send,
                "recv": cmd_recv, "backup": cmd_backup, "restore": cmd_restore,
                "rm": cmd_rm, "net": cmd_net, "time": cmd_time, "wifi": cmd_wifi,
                "tz": cmd_tz, "sync": cmd_sync, "diag": cmd_diag,
                "sound": cmd_sound}[args.cmd](args)
    except CompiError as e:
        print(f"compi: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
