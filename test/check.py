#!/usr/bin/env python3
"""Valida una salida de stats.sh: UTF-8 estricto + ancho visible del recuadro.

Uso:
    check.py ARCHIVO ANCHO [ARCHIVO ANCHO ...]
    check.py --json ARCHIVO

Sale 0 si todo esta bien, 1 si algo falla (imprime el detalle).
No tiene dependencias: solo stdlib, para poder correr en cualquier python3.
"""
import json
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
BOX = ("\u2502", "\u250c", "\u251c", "\u2514")  # │ ┌ ├ └
XFAIL = re.compile(r"\ufffd")


def check_box(path, width):
    try:
        text = open(path, "rb").read().decode("utf-8")
    except UnicodeDecodeError as e:
        # byte partido = caracter multibyte cortado al medio
        print(f"FAIL {path}: UTF-8 invalido ({e.reason} en el byte {e.start})")
        return False
    visible = [ANSI.sub("", l) for l in text.split("\n")]
    box = [l for l in visible if l.startswith(BOX)]
    if not box:
        print(f"FAIL {path}: no hay lineas de recuadro")
        return False
    bad = [len(l) for l in box if len(l) != width]
    repl = [i for i, l in enumerate(visible) if XFAIL.search(l)]
    if bad or repl:
        print(f"FAIL {path}: {len(bad)} lineas fuera de {width} {bad[:3]}, reemplazos {repl[:3]}")
        return False
    print(f"OK   {path}: recuadro {width} alineado, {len(box)} lineas, UTF-8 valido")
    return True


def check_json(path):
    try:
        raw = open(path, "rb").read().decode("utf-8")
        data = json.loads(raw)
    except Exception as e:
        print(f"FAIL {path}: JSON invalido ({e})")
        return False
    faltan = [k for k in ("hostname", "cpu", "memory", "network", "disks", "services") if k not in data]
    mem = data.get("memory", {})
    sin_claves = [k for k in ("available_mb", "free_mb", "usage_pct") if k not in mem]
    if faltan or sin_claves:
        print(f"FAIL {path}: faltan claves {faltan} {sin_claves}")
        return False
    print(f"OK   {path}: JSON valido ({len(data)} claves, available_mb={mem['available_mb']})")
    return True


def main(argv):
    if "--json" in argv:
        return 0 if all(check_json(p) for p in argv[argv.index("--json") + 1:]) else 1
    if len(argv) < 2 or (len(argv) - 1) % 2:
        print(__doc__)
        return 2
    ok = True
    for i in range(1, len(argv), 2):
        ok = check_box(argv[i], int(argv[i + 1])) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
