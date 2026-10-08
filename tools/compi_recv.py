#!/usr/bin/env python3
"""compi_recv — saca la imagen de un slot de la flash de compi por el USB y
la deja en un .bin. Atajo de `tools/compi.py recv`:

    python3 tools/compi_recv.py --slot 4 -o demo_dump.bin
    python3 tools/compi_recv.py --slot 4 --len 4096 -o cabecera.bin

--port es opcional: el puerto se busca solo. Para verlo como ensamblador,
tools/compi_disasm.py. Para copiar TODO el aparato, `tools/compi.py backup`.

Necesita pyserial  (pip install pyserial).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import argparse  # noqa: E402

import compi  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="p. ej. /dev/ttyACM0 o COM5 (por defecto, se busca solo)")
    ap.add_argument("--slot", required=True, help="slot de flash 0..59")
    ap.add_argument("--len", dest="length", help="bytes a traer desde el principio")
    ap.add_argument("-o", "--output", required=True, help="fichero .bin de salida")
    ap.add_argument("--baud", type=int, default=115200, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    fwd = (["--port", args.port] if args.port else []) + ["recv", args.slot, "-o", args.output]
    if args.length:
        fwd += ["--len", args.length]
    return compi.main(fwd)


if __name__ == "__main__":
    sys.exit(main())
