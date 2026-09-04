#!/usr/bin/env python3
"""Render Fuuki graphics ROM tiles to a PNG tile sheet.

Companion to scripts/decode_gfx.py, which prints ASCII. This one produces an
image, which is a far better way to judge whether a layout is right.

IMPORTANT -- these are NOT the game's real colours. The palette lives in RAM
at 0x700000 and is written by the game at runtime; it is not in the ROM. What
is in the ROM is a PEN INDEX per pixel. This tool therefore renders pen index
as false colour (a fixed hue ramp) so structure is visible, and draws the
layer's TRANSPARENT pen as a grey checkerboard.

Note the transparent pen is the LAST pen, not pen 0:
    FG-2  L0 0x0f   L1 0xff   L2 0x0f      sprites 15
    FG-3  L0 0xff   L1 0xff   L2 0x0f      sprites 15
"""
import argparse, colorsys, zipfile, sys
from PIL import Image

def load(zpath, member, member2=None, swap=True):
    z = zipfile.ZipFile(zpath)
    names = {n.split('/')[-1]: n for n in z.namelist()}
    if member not in names:
        sys.exit(f"{member} not in {zpath}")
    data = bytearray(z.read(names[member]))
    if member2:
        # ROM_LOAD32_WORD_SWAP pair: `member` supplies bytes 0,1 of each long
        # (the pixel's HIGH nibble), `member2` bytes 2,3 (the LOW nibble).
        d2 = z.read(names[member2])
        out = bytearray(len(data) * 2)
        for i in range(0, len(data), 2):
            out[2*i+0] = data[i+1]; out[2*i+1] = data[i+0]
            out[2*i+2] = d2[i+1];   out[2*i+3] = d2[i+0]
        return bytes(out)
    if swap:
        for i in range(0, len(data) - 1, 2):
            data[i], data[i+1] = data[i+1], data[i]
    return bytes(data)

def pixels(data, kind, index):
    if kind == '16x16x4':
        base, w, h = index*128, 16, 16
        return w, h, [[((data[base+y*8+(x>>1)] >> 4) if (x & 1) == 0
                        else (data[base+y*8+(x>>1)] & 15))
                       for x in range(w)] for y in range(h)]
    if kind == '8x8x4':
        base, w, h = index*32, 8, 8
        return w, h, [[((data[base+y*4+(x>>1)] >> 4) if (x & 1) == 0
                        else (data[base+y*4+(x>>1)] & 15))
                       for x in range(w)] for y in range(h)]
    if kind == '16x16x8':
        base, w, h = index*256, 16, 16
        rows = []
        for y in range(h):
            r = []
            for x in range(w):
                o = base + y*16 + 4*(x >> 2)
                b = data[o:o+4]
                i = x & 3
                if   i == 0: r.append(((b[0] >> 4) << 4) | (b[2] >> 4))
                elif i == 1: r.append(((b[0] & 15) << 4) | (b[2] & 15))
                elif i == 2: r.append(((b[1] >> 4) << 4) | (b[3] >> 4))
                else:        r.append(((b[1] & 15) << 4) | (b[3] & 15))
            rows.append(r)
        return w, h, rows
    sys.exit("unknown kind")

def ramp(n):
    """Fixed false-colour ramp: hue sweeps, value rises. Distinguishes
    neighbouring pen indices, which a plain grey ramp does not."""
    out = []
    for i in range(n):
        f = i / max(1, n - 1)
        r, g, b = colorsys.hsv_to_rgb((0.75 - 0.75*f) % 1.0, 0.75, 0.25 + 0.75*f)
        out.append((int(r*255), int(g*255), int(b*255)))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('zip'); ap.add_argument('member')
    ap.add_argument('kind', choices=['16x16x4', '8x8x4', '16x16x8'])
    ap.add_argument('out')
    ap.add_argument('--member2')
    ap.add_argument('--start', type=lambda s: int(s, 0), default=0)
    ap.add_argument('--cols', type=int, default=16)
    ap.add_argument('--rows', type=int, default=16)
    ap.add_argument('--zoom', type=int, default=3)
    ap.add_argument('--no-swap', action='store_true')
    ap.add_argument('--transparent', type=lambda s: int(s, 0), default=None,
                    help="pen drawn as a checkerboard; defaults to the last pen")
    ap.add_argument('--autoscale', action='store_true', help=(
        "spread the ramp across the pen range actually USED. 8bpp tiles often "
        "sit in a narrow low band (palette granularity is 16, so a tile may "
        "only use pens 3-29 of 255) and render almost black otherwise -- which "
        "reads as a decode failure and is not one."))
    a = ap.parse_args()

    data = load(a.zip, a.member, a.member2, swap=not a.no_swap)
    depth = 256 if a.kind == '16x16x8' else 16
    trans = a.transparent if a.transparent is not None else depth - 1
    pal = ramp(depth)

    # Survey the pen range actually used before drawing anything.
    lo, hi = depth - 1, 0
    for r in range(a.rows):
        for c in range(a.cols):
            idx = a.start + r*a.cols + c
            need = idx * (128 if a.kind == '16x16x4' else 32 if a.kind == '8x8x4' else 256)
            if need + 32 > len(data):
                continue
            _, _, px = pixels(data, a.kind, idx)
            for row in px:
                for v in row:
                    if v != trans:
                        lo = min(lo, v); hi = max(hi, v)
    if hi < lo:
        lo, hi = 0, depth - 1
    print(f"  pen range in view: {lo}..{hi} of 0..{depth-1}")

    def shade(v):
        if a.autoscale and hi > lo:
            return pal[(v - lo) * (depth - 1) // (hi - lo)]
        return pal[v]

    tw, th, _ = pixels(data, a.kind, a.start)
    gap = 1
    W = a.cols * (tw + gap) + gap
    H = a.rows * (th + gap) + gap
    img = Image.new('RGB', (W, H), (24, 24, 28))

    used = 0
    for r in range(a.rows):
        for c in range(a.cols):
            idx = a.start + r*a.cols + c
            need = idx * (128 if a.kind == '16x16x4' else 32 if a.kind == '8x8x4' else 256)
            if need + 32 > len(data):
                continue
            _, _, px = pixels(data, a.kind, idx)
            used += 1
            ox = gap + c*(tw+gap); oy = gap + r*(th+gap)
            for y in range(th):
                for x in range(tw):
                    v = px[y][x]
                    if v == trans:
                        s = 90 if ((x >> 2) ^ (y >> 2)) & 1 else 70
                        img.putpixel((ox+x, oy+y), (s, s, s))
                    else:
                        img.putpixel((ox+x, oy+y), shade(v))

    img = img.resize((W*a.zoom, H*a.zoom), Image.NEAREST)
    img.save(a.out)
    print(f"{a.out}: {a.cols}x{a.rows} tiles from 0x{a.start:x}, {used} drawn, "
          f"{tw}x{th}x{'8' if depth == 256 else '4'}bpp, transparent pen {trans}")

main()
