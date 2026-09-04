#!/usr/bin/env python3
"""Decode Fuuki graphics tiles from a real ROM set and render them as ASCII.

Proving the bit layout OFFLINE, before writing the RTL that depends on it.
A wrong gfx layout produces plausible-looking garbage on hardware and is
expensive to diagnose there; here it takes seconds and the answer is visual.

Layouts, transcribed from the drivers' gfx_layout structs:

  gfx_16x16x4_packed_msb   sprites, FG-2 layer 0
      128 bytes/tile, 8 bytes/row, pixel = nibble, MSB nibble first.

  gfx_8x8x4_packed_msb     layer 2 (both boards)
      32 bytes/tile, 4 bytes/row, same nibble order.

  layout_16x16x8           FG-2 layer 1, FG-3 layers 0 and 1
      256 bytes/tile, 16 bytes/row.
      planeoffset { STEP4(0,1), STEP4(16,1) } = {0,1,2,3, 16,17,18,19}
      xoffset     { STEP4(0,4), STEP4(16*2,4), STEP4(16*4,4), STEP4(16*6,4) }
      MAME builds a pixel with planeoffset[0] as the MSB, and counts bits
      MSB-first within each byte, which works out to 4 groups of 4 bytes per
      row, each group holding 4 pixels:
          pixel 4g+0 = { b[4g+0][7:4], b[4g+2][7:4] }
          pixel 4g+1 = { b[4g+0][3:0], b[4g+2][3:0] }
          pixel 4g+2 = { b[4g+1][7:4], b[4g+3][7:4] }
          pixel 4g+3 = { b[4g+1][3:0], b[4g+3][3:0] }
      i.e. the first two bytes of each group carry the HIGH nibble of the
      pixel value and the next two carry the LOW nibble.
"""
import argparse, zipfile, sys

SHADE = " .:-=+*#%@"

def px_4bpp(data, base, w, y, x):
    row = base + y * (w // 2)
    b = data[row + (x >> 1)]
    return (b >> 4) if (x & 1) == 0 else (b & 0x0F)

def px_16x16x8(data, base, y, x):
    row = base + y * 16
    g, i = x >> 2, x & 3
    b = data[row + 4*g : row + 4*g + 4]
    if   i == 0: return ((b[0] >> 4) << 4) | (b[2] >> 4)
    elif i == 1: return ((b[0] & 15) << 4) | (b[2] & 15)
    elif i == 2: return ((b[1] >> 4) << 4) | (b[3] >> 4)
    else:        return ((b[1] & 15) << 4) | (b[3] & 15)

def render(data, kind, index):
    if kind == '16x16x4':
        base, w, h, mx = index*128, 16, 16, 15
        get = lambda y, x: px_4bpp(data, base, 16, y, x)
    elif kind == '8x8x4':
        base, w, h, mx = index*32, 8, 8, 15
        get = lambda y, x: px_4bpp(data, base, 8, y, x)
    elif kind == '16x16x8':
        base, w, h, mx = index*256, 16, 16, 255
        get = lambda y, x: px_16x16x8(data, base, y, x)
    else:
        sys.exit("unknown kind")
    if base + w*h > len(data):
        sys.exit("tile index past end of ROM")
    rows, hist = [], {}
    for y in range(h):
        line = ""
        for x in range(w):
            v = get(y, x)
            hist[v] = hist.get(v, 0) + 1
            line += SHADE[min(len(SHADE)-1, v * len(SHADE) // (mx+1))] * 2
        rows.append(line)
    return rows, hist

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('zip')
    ap.add_argument('member')
    ap.add_argument('--member2', help=(
        "second ROM for a 32-bit ROM_LOAD32_WORD_SWAP pair: `member` supplies "
        "bytes 0,1 of each long and `member2` supplies bytes 2,3, with each "
        "source word byte-swapped."))
    ap.add_argument('kind', choices=['16x16x4', '8x8x4', '16x16x8'])
    ap.add_argument('--tiles', default='0,1,2,3')
    ap.add_argument('--interleave', choices=['none', 'word_swap'], default='none',
                    help="word_swap = ROM_LOAD16_WORD_SWAP, i.e. byte-swap each word")
    a = ap.parse_args()

    z = zipfile.ZipFile(a.zip)
    names = {n.split('/')[-1]: n for n in z.namelist()}
    data = bytearray(z.read(names[a.member]))
    if a.member2:
        # ROM_LOAD32_WORD_SWAP pair. Built from the ROM_START offsets, not
        # reasoned about: the map-digit rule is mechanical, so check it.
        d2 = z.read(names[a.member2])
        out = bytearray(len(data) * 2)
        for i in range(0, len(data), 2):
            out[2*i + 0] = data[i+1]
            out[2*i + 1] = data[i+0]
            out[2*i + 2] = d2[i+1]
            out[2*i + 3] = d2[i+0]
        data = out
        a.interleave = 'none'
    if a.interleave == 'word_swap':
        for i in range(0, len(data) - 1, 2):
            data[i], data[i+1] = data[i+1], data[i]

    for t in [int(x, 0) for x in a.tiles.split(',')]:
        rows, hist = render(data, a.kind, t)
        nz = sum(v for k, v in hist.items() if k != 0)
        print(f"--- tile {t} ({a.kind}) non-zero px {nz}/{sum(hist.values())}, "
              f"{len(hist)} distinct values ---")
        for r in rows:
            print("  " + r)

main()
