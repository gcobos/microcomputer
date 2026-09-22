#!/usr/bin/env python3
"""compi_recv — saca la imagen de un slot de la flash de compi por el puerto
USB-CDC (mitad "DUMP" del protocolo de provisioning de src/main.cpp, hermano
de compi_send.py) y la deja en un .bin en el ordenador.

    python3 tools/compi_recv.py --port /dev/ttyACM0 --slot 4 -o demo_dump.bin

Por defecto trae los 65536 bytes completos (la flash no guarda "hasta donde
llega el programa", solo imagenes enteras -- ver storage.h); con --len se
pide solo un trozo desde el principio, p. ej. para mirar rapido el arranque
de un programa grande sin esperar la imagen entera:

    python3 tools/compi_recv.py --port /dev/ttyACM0 --slot 4 --len 4096 -o cabecera.bin

Para verlo como texto ensamblador, tools/compi_disasm.py:

    python3 tools/compi_disasm.py demo_dump.bin -o demo_dump.asm

Necesita pyserial  (pip install pyserial).
"""
import argparse
import sys
import time

IMAGE_SIZE = 65536


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True, help="p. ej. /dev/ttyACM0 o COM5")
    ap.add_argument("--slot", type=int, required=True, help="slot de flash 0..59")
    ap.add_argument("--len", type=int, dest="length",
                     help="bytes a traer desde el principio (por defecto, la "
                          "imagen entera de %d)" % IMAGE_SIZE)
    ap.add_argument("-o", "--output", required=True, help="fichero .bin de salida")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args(argv)

    try:
        import serial  # noqa: PLC0415
    except ImportError:
        print("compi_recv: falta pyserial  ->  pip install pyserial", file=sys.stderr)
        return 2

    if not (0 <= args.slot < 60):
        print("compi_recv: slot fuera de rango (0..59)", file=sys.stderr)
        return 2
    if args.length is not None and not (0 <= args.length <= IMAGE_SIZE):
        print(f"compi_recv: --len fuera de rango (0..{IMAGE_SIZE})", file=sys.stderr)
        return 2

    with serial.Serial(args.port, args.baud, timeout=8) as ser:
        time.sleep(0.3)
        ser.reset_input_buffer()
        request = f"COMPI DUMP {args.slot}"
        if args.length is not None:
            request += f" {args.length}"
        ser.write((request + "\n").encode())
        ser.flush()

        line = ser.readline().decode(errors="replace").strip()
        while line and "READY" not in line and "ERR" not in line:
            line = ser.readline().decode(errors="replace").strip()
        if "READY" not in line:
            print(f"compi_recv: el aparato no acepto el slot {args.slot}: {line!r}",
                  file=sys.stderr)
            return 1

        try:
            length = int(line.split()[2])
        except (IndexError, ValueError):
            print(f"compi_recv: cabecera rara: {line!r}", file=sys.stderr)
            return 1

        data = ser.read(length)
        if len(data) != length:
            print(f"compi_recv: solo llegaron {len(data)} de {length} bytes "
                  f"(timeout)", file=sys.stderr)
            return 1

        deadline = time.time() + 5
        reply = ""
        while time.time() < deadline:
            reply = ser.readline().decode(errors="replace").strip()
            if reply.startswith("COMPI OK") or reply.startswith("COMPI ERR"):
                break

    if not reply.startswith("COMPI OK"):
        print(f"compi_recv: fallo: {reply!r}", file=sys.stderr)
        return 1

    checksum = sum(data) & 0xFFFFFFFF
    got = int(reply.split()[2])
    if got != checksum:
        print(f"compi_recv: !! checksum {got} != {checksum} (transmision "
              f"corrupta)", file=sys.stderr)
        return 1

    with open(args.output, "wb") as f:
        f.write(data)
    print(f"compi_recv: slot {args.slot} -> {args.output} "
          f"({len(data)} bytes, checksum OK)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
