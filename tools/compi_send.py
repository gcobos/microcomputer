#!/usr/bin/env python3
"""compi_send — graba una imagen de programa en un slot de la flash de compi
por el USB. Atajo de `tools/compi.py send` (ver ahi el detalle):

    python3 tools/compi_send.py programs/demo.asm            # slot de su .slot
    python3 tools/compi_send.py --slot 4 programs/demo.bin   # un .bin pide --slot

--port es opcional: el puerto se busca solo. Si el .asm declara zonas
.persist (los datos del programa, p. ej. las canciones de musicmaker.asm), se
conservan las que ya hay en el aparato; --no-persist las borra.

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
    ap.add_argument("image", help="fichero .bin o .asm")
    ap.add_argument("--port", help="p. ej. /dev/ttyACM0 o COM5 (por defecto, se busca solo)")
    ap.add_argument("--slot", help="slot de flash 0..59 (si se omite, la .slot del .asm)")
    ap.add_argument("--no-persist", action="store_true")
    ap.add_argument("--baud", type=int, default=115200, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    fwd = (["--port", args.port] if args.port else []) + ["send", args.image]
    if args.slot is not None:
        fwd += ["--slot", args.slot]
    if args.no_persist:
        fwd.append("--no-persist")
    return compi.main(fwd)


if __name__ == "__main__":
    sys.exit(main())
