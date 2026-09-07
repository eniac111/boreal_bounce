#!/usr/bin/env python3
"""Convert an SFont bitmap font (as used by Frozen-Bubble's level editor) to a BMFont .fnt
file plus a PNG glyph page that Godot 4 imports as a FontFile.

SFont layout: row 0 of the image is a marker row; runs of pink (255,0,255) separate glyphs.
Glyph i (0-based) sits between marker run i and i+1 and encodes ASCII 33 + i. The Frozen-Bubble
fonts contain 58 glyphs, '!' .. 'Z' (uppercase only); we alias lowercase letters onto the
uppercase glyphs so tr() strings still render.
"""
import sys
from pathlib import Path
from PIL import Image

PINK = (255, 0, 255)


SCALE = 2  # the page is upscaled so the font can be drawn crisply on large windows


def convert(src: Path, dst_png: Path, dst_fnt: Path, face: str) -> int:
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    top = [im.getpixel((x, 0))[:3] for x in range(w)]
    runs = []
    x = 0
    while x < w:
        if top[x] == PINK:
            s = x
            while x < w and top[x] == PINK:
                x += 1
            runs.append((s, x))
        else:
            x += 1
    glyphs = []  # (char_code, x, width)
    for i in range(len(runs) - 1):
        gx = runs[i][1]
        gw = runs[i + 1][0] - gx
        glyphs.append((33 + i, gx, gw))
    page = im.crop((0, 1, w, h))  # drop marker row
    S = SCALE
    page = page.resize((page.width * S, page.height * S), Image.LANCZOS)
    page.save(dst_png)
    gh = (h - 1) * S
    space_w = glyphs[0][2] * S if glyphs else 8 * S
    lines = [
        f'info face="{face}" size={gh} bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=0,0 outline=0',
        f"common lineHeight={gh} base={gh} scaleW={w * S} scaleH={gh} pages=1 packed=0 alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4",
        f'page id=0 file="{dst_png.name}"',
    ]
    chars = [f"char id=32 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance={space_w} page=0 chnl=15"]
    by_code = {}
    for code, gx, gw in glyphs:
        by_code[code] = (gx * S, gw * S)
        chars.append(f"char id={code} x={gx * S} y=0 width={gw * S} height={gh} xoffset=0 yoffset=0 xadvance={gw * S} page=0 chnl=15")
    for lower in range(ord("a"), ord("z") + 1):
        upper = lower - 32
        if upper in by_code and lower not in by_code:
            gx, gw = by_code[upper]
            chars.append(f"char id={lower} x={gx} y=0 width={gw} height={gh} xoffset=0 yoffset=0 xadvance={gw} page=0 chnl=15")
    lines.append(f"chars count={len(chars)}")
    lines.extend(chars)
    dst_fnt.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(glyphs)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: sfont_to_fnt.py <src.png> <dst.png> <dst.fnt>")
    n = convert(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[2]).stem)
    print(f"{n} glyphs")
