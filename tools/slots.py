#!/usr/bin/env python3
"""slots — administra un directorio que hace de "flash simulada" para
tools/sim.py (puertos 0x0640/0x0641 de carga/grabado de programas, ver
include/iomap.h), para poder probar en el simulador un "sistema operativo"
en el slot 0 (o cualquier programa que cargue/grabe otros slots) sin el
aparato real.

Cada slot es un fichero NN.bin de 65536 bytes dentro de --slots-dir
(00..59, MAX_PROGRAM_SLOTS) -- exactamente lo que tools/sim.py lee/escribe
al recibir un OUT a esos puertos (ver Ports._prog_load/_prog_save ahi).

    # coloca pong.asm en SU PROPIO slot (la ".slot 2" del fichero)
    python3 tools/slots.py --slots-dir mi_flash put programs/pong.asm

    # fuerza un slot concreto, con un .asm o un .bin ya montado
    python3 tools/slots.py --slots-dir mi_flash put --slot 0 programs/sisop.asm

    # lista que slots estan ocupados
    python3 tools/slots.py --slots-dir mi_flash list

Luego, para arrancar desde ahi en el simulador:

    python3 tools/sim.py mi_flash/00.bin --slots-dir mi_flash --steps 2000000
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casm  # noqa: E402 - necesita el sys.path.insert de arriba

PROGRAM_SIZE = 65536
MAX_PROGRAM_SLOTS = 60


def slot_path(slots_dir, slot):
    return os.path.join(slots_dir, f"{slot:02d}.bin")


def meta_path(slots_dir, slot):
    """Metadatos del slot (categoria + nombre, 15 bytes -- storage.h
    SLOT_META_SIZE), al lado de su .bin: el equivalente a la cabecera del
    slot en la flash real."""
    return os.path.join(slots_dir, f"{slot:02d}.meta")


def meta_bytes(category, name):
    m = bytearray(15)
    m[0] = 0xFF if category is None else category & 0xFF
    nm = (name or "").encode()[:14]
    m[1:1 + len(nm)] = nm
    return bytes(m)


def build_if_needed(path):
    """Igual que build_if_needed en compi_send.py: devuelve (bytes_usados,
    slot_sugerido_o_None). Un .bin no lleva ".slot", asi que ahi es None."""
    if not path.endswith(".asm"):
        with open(path, "rb") as f:
            return f.read(), None, meta_bytes(None, None)
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    asm = casm.Assembler()
    try:
        image = asm.assemble(text, path)
    except casm.AsmError as e:
        print(f"slots: error ensamblando {path}: {e}", file=sys.stderr)
        sys.exit(1)
    used = max(1, asm.max_addr)
    return image[:used], asm.slot, meta_bytes(asm.category, asm.name)


def cmd_put(args):
    data, suggested, meta = build_if_needed(args.file)
    slot = args.slot if args.slot is not None else suggested
    if slot is None:
        print("slots: --slot es obligatorio (el .asm no tiene directiva .slot, "
              "o el origen es un .bin)", file=sys.stderr)
        sys.exit(1)
    if not (0 <= slot < MAX_PROGRAM_SLOTS):
        print(f"slots: slot {slot} fuera de rango (0..{MAX_PROGRAM_SLOTS - 1})",
              file=sys.stderr)
        sys.exit(1)
    if len(data) > PROGRAM_SIZE:
        print(f"slots: {args.file} ocupa {len(data)} bytes, mas de los "
              f"{PROGRAM_SIZE} de un slot", file=sys.stderr)
        sys.exit(1)
    os.makedirs(args.slots_dir, exist_ok=True)
    padded = data + bytes(PROGRAM_SIZE - len(data))
    with open(slot_path(args.slots_dir, slot), "wb") as f:
        f.write(padded)
    with open(meta_path(args.slots_dir, slot), "wb") as f:
        f.write(meta)
    print(f"slots: {args.file} -> slot {slot} ({len(data)} bytes utiles de "
          f"{PROGRAM_SIZE})")


def cmd_list(args):
    any_found = False
    for slot in range(MAX_PROGRAM_SLOTS):
        p = slot_path(args.slots_dir, slot)
        if os.path.isfile(p):
            any_found = True
            mp = meta_path(args.slots_dir, slot)
            info = ""
            if os.path.isfile(mp):
                m = open(mp, "rb").read()
                info = f"  cat {m[0]:3d}  {m[1:].split(bytes(1))[0].decode(errors='replace')}"
            print(f"{slot:2d}  {os.path.getsize(p)} bytes  {p}{info}")
    if not any_found:
        print(f"slots: {args.slots_dir} no tiene ningun slot todavia")


def cmd_rm(args):
    p = slot_path(args.slots_dir, args.slot)
    if os.path.isfile(p):
        os.remove(p)
        if os.path.isfile(meta_path(args.slots_dir, args.slot)):
            os.remove(meta_path(args.slots_dir, args.slot))
        print(f"slots: borrado el slot {args.slot}")
    else:
        print(f"slots: el slot {args.slot} ya estaba vacio")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--slots-dir", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_put = sub.add_parser("put", help="ensambla/copia un .asm o .bin a un slot")
    p_put.add_argument("file")
    p_put.add_argument("--slot", type=int, default=None,
                        help="fuerza el slot (si no, usa la .slot del .asm)")
    p_put.set_defaults(func=cmd_put)

    p_list = sub.add_parser("list", help="lista los slots ocupados")
    p_list.set_defaults(func=cmd_list)

    p_rm = sub.add_parser("rm", help="borra (vacia) un slot")
    p_rm.add_argument("slot", type=int)
    p_rm.set_defaults(func=cmd_rm)

    args = ap.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
