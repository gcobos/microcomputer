#!/usr/bin/env python3
"""compi_send — graba una imagen de programa en un slot de la flash de compi
por el puerto USB-CDC (protocolo de provisioning de src/main.cpp).

    python3 tools/compi_send.py --port /dev/ttyACM0 --slot 4 programs/demo.bin

Tambien puede ensamblar sobre la marcha si le pasas un .asm:

    python3 tools/compi_send.py --port /dev/ttyACM0 --slot 4 programs/demo.asm

Si no se indica --slot y el origen es un .asm con directiva ".slot N", se usa
ese slot (el mismo que casm.py anota como "slot de destino sugerido"). Un
.bin no lleva esa informacion, asi que ahi --slot es obligatorio.

Solo se manda por el cable el tamano real del fichero (casm.py ya lo recorta
tras el ultimo byte usado): el protocolo "COMPI LOAD <slot> <len>" acepta
len < 65536 y el aparato rellena el resto de la RAM con ceros al recibirlo
(cpu.clearMemory() en src/main.cpp), asi que no hace falta rellenar aqui. Si
el fichero ya viene con 65536 bytes (p. ej. un .bin antiguo), se manda igual
sin cambios de comportamiento.

Necesita pyserial  (pip install pyserial).
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casm  # noqa: E402 - necesita el sys.path.insert de arriba

IMAGE_SIZE = 65536
COMPI_CHUNK = 1024  # debe coincidir con COMPI_CHUNK en src/main.cpp


def build_if_needed(path):
    """Devuelve (bytes, slot). slot es None si no se puede deducir (.bin)."""
    if not path.endswith(".asm"):
        with open(path, "rb") as f:
            return f.read(), None
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    asm = casm.Assembler()
    try:
        image = asm.assemble(text)
    except casm.AsmError as e:
        print(f"compi_send: error ensamblando: {e}", file=sys.stderr)
        sys.exit(1)
    used = max(1, asm.max_addr)
    out = path[:-4] + ".bin"
    with open(out, "wb") as f:
        f.write(image[:used])
    return image[:used], asm.slot


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="fichero .bin o .asm")
    ap.add_argument("--port", required=True, help="p. ej. /dev/ttyACM0 o COM5")
    ap.add_argument("--slot", type=int,
                     help="slot de flash 0..59 (si se omite, se deduce de la "
                          "directiva .slot del .asm; un .bin lo exige)")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args(argv)

    try:
        import serial  # noqa: PLC0415
    except ImportError:
        print("compi_send: falta pyserial  ->  pip install pyserial", file=sys.stderr)
        return 2

    data, deduced_slot = build_if_needed(args.image)

    if args.slot is not None:
        slot = args.slot
        if deduced_slot is not None and deduced_slot != slot:
            print(f"compi_send: aviso: --slot {slot} no coincide con la "
                  f".slot {deduced_slot} del fichero; se usa {slot}", file=sys.stderr)
    elif deduced_slot is not None:
        slot = deduced_slot
        print(f"compi_send: slot deducido de la directiva .slot: {slot}")
    else:
        print("compi_send: falta --slot (el .bin no lleva esa informacion)",
              file=sys.stderr)
        return 2

    if not (0 <= slot < 60):
        print("compi_send: slot fuera de rango (0..59)", file=sys.stderr)
        return 2

    if len(data) > IMAGE_SIZE:
        print(f"compi_send: la imagen ({len(data)} B) pasa de {IMAGE_SIZE}", file=sys.stderr)
        return 2
    # el aparato pone a 0 el resto de la RAM antes de recibir (clearMemory());
    # esos ceros no aportan a la suma, asi que el checksum es el mismo que si
    # se mandaran los 65536 bytes completos.
    checksum = sum(data) & 0xFFFFFFFF

    with serial.Serial(args.port, args.baud, timeout=8) as ser:
        time.sleep(0.3)
        ser.reset_input_buffer()
        header = f"COMPI LOAD {slot} {len(data)}\n".encode()
        ser.write(header)
        ser.flush()

        line = ser.readline().decode(errors="replace").strip()
        while line and "READY" not in line and "ERR" not in line:
            line = ser.readline().decode(errors="replace").strip()
        if "READY" not in line:
            print(f"compi_send: el aparato no acepto la cabecera: {line!r}", file=sys.stderr)
            return 1

        # Se manda a trozos y se espera el eco "COMPI CHUNK <n>" de cada uno:
        # el USB-CDC nativo del C3 descarta datos en silencio si se le manda
        # todo de golpe y su cola de recepcion se llena (ver src/main.cpp,
        # provisionPoll()). Ir a trozos obliga a ir al ritmo del aparato.
        offset = 0
        reply = ""
        while offset < len(data):
            chunk = data[offset:offset + COMPI_CHUNK]
            ser.write(chunk)
            ser.flush()
            offset += len(chunk)

            deadline = time.time() + 5
            reply = ""
            while time.time() < deadline:
                reply = ser.readline().decode(errors="replace").strip()
                if reply.startswith("COMPI CHUNK") or reply.startswith("COMPI ERR"):
                    break
            if reply.startswith("COMPI ERR"):
                break
            if not reply.startswith("COMPI CHUNK"):
                print(f"compi_send: fallo: sin eco tras el byte {offset}: {reply!r}",
                      file=sys.stderr)
                return 1

        if not reply.startswith("COMPI ERR"):
            deadline = time.time() + 15
            reply = ""
            while time.time() < deadline:
                reply = ser.readline().decode(errors="replace").strip()
                if reply.startswith("COMPI OK") or reply.startswith("COMPI ERR"):
                    break

    if reply.startswith("COMPI OK"):
        got = int(reply.split()[2])
        ok = "  (checksum OK)" if got == checksum else f"  (!! checksum {got} != {checksum})"
        print(f"compi_send: grabado en el slot {slot}{ok}")
        return 0 if got == checksum else 1
    print(f"compi_send: fallo: {reply!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
