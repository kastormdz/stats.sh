#!/usr/bin/env python3
"""Renderiza a PNG la salida de stats.sh (terminal oscura, JetBrains Mono).

    ./test/render_png.py salida.txt stats.png

Detalle importante del tamano de fuente: JetBrains Mono tiene avance 0.5926 em, asi que
13.5px * 0.5926 = 8.0 css px = 16.0 px dispositivo con device_scale_factor=2 (entero
exacto). Con eso los bloques contiguos (█) tilean sin costuras. No cambiar el tamano sin
rehacer esa cuenta: 12.5px daria 14.8 px dispositivo y aparecen lineas de subpixel.
"""
import re
import struct
import sys

from playwright.sync_api import sync_playwright

COLORS = {"0": "#d4d4d4", "0;31": "#e06c75", "0;32": "#98c379", "0;34": "#61afef", "0;37": "#abb2bf"}
ESC = re.compile(r"\x1b\[([0-9;]*)m")


def to_html(s):
    out, cur, bold, pos = [], "#d4d4d4", False, 0
    for m in ESC.finditer(s):
        chunk = s[pos:m.start()]
        if chunk:
            style = f"color:{cur}" + (";font-weight:bold" if bold else "")
            out.append(f'<span style="{style}">{chunk.replace("&", "&amp;").replace("<", "&lt;")}</span>')
        code = m.group(1)
        if code == "0":
            cur, bold = "#d4d4d4", False
        elif code == "1":
            bold = True
        elif code in COLORS:
            cur = COLORS[code]
        pos = m.end()
    tail = s[pos:]
    if tail:
        style = f"color:{cur}" + (";font-weight:bold" if bold else "")
        out.append(f'<span style="{style}">{tail.replace("&", "&amp;").replace("<", "&lt;")}</span>')
    return "".join(out)


def main(txt_path, out_path):
    raw = open(txt_path, "rb").read().decode("utf-8")
    html = """<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;background:#1e1e1e;}
  body{padding:30px 36px;}
  pre{margin:0;font-family:'JetBrains Mono','Fira Code','DejaVu Sans Mono',monospace;
      font-size:13.5px;line-height:1.20;color:#d4d4d4;white-space:pre;letter-spacing:0;
      -webkit-font-smoothing:antialiased;font-variant-ligatures:none;}
</style></head><body><pre>""" + to_html(raw.rstrip("\n")) + "</pre></body></html>"

    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 900, "height": 600}, device_scale_factor=2)
        pg.set_content(html)
        pg.wait_for_timeout(1200)  # que asienten las fuentes
        box = pg.locator("pre").bounding_box()
        print(f"contenido: {box['width']:.0f}x{box['height']:.0f} css px")
        pg.screenshot(path=out_path, full_page=True)
        b.close()

    d = open(out_path, "rb").read()
    w, h = struct.unpack(">II", d[16:24])
    print(f"{out_path}: {w}x{h} px, {len(d) / 1024:.0f} KB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
