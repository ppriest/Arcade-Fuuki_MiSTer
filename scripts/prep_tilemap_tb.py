#!/usr/bin/env python3
"""Build tb_tilemap's inputs from a captured MAME frame plus the ROM set.

    python scripts/prep_tilemap_tb.py debug/gogomile-title

Produces, in sim/tilemap_tb/:
    vram.bin        the captured tilemap VRAM, verbatim
    l{0,1,2}_gfx.bin  each layer's tile ROM, assembled exactly as the SDRAM
                    image will hold it (interleave applied, byte order fixed)
    config.txt      scroll and layer settings decoded from the captured vregs
    palette.bin     the captured palette, for turning indices back into pixels

The point is to render the SAME state MAME rendered and compare against the
screenshot it produced. Building the gfx images here rather than in the
testbench keeps the interleave in one place -- the same place decode_gfx.py and
the .mra generator will use -- so there is one definition of "the SDRAM image"
rather than three that can drift.
"""
import struct, sys, zipfile
from pathlib import Path

# Per layer: the region size, and the groups that fill it. Each group is
# (destination offset, kind, parts):
#   "swap16"  one ROM_LOAD16_WORD_SWAP
#   "pair32"  a ROM_LOAD32_WORD_SWAP pair, first part supplying bytes 0,1 of
#             each long -- which is the pixel's HIGH nibble
#
# Transcribed from each ROM_START, and the offsets matter: gogomile's layer 1
# is an 8 MB region built from FOUR ROMs as two pairs, at 0x000000 and
# 0x400000. Building only the first pair leaves every tile in the upper half
# reading whatever the gap contains -- which rendered as a solid block rather
# than failing, and is exactly the sort of thing only a picture catches.
GOGOMILE = {
    0: (0x200000, [(0x000000, "swap16", ["lh5370h6.rom3"])]),
    1: (0x800000, [(0x000000, "pair32", ["lh5370h7.rom15", "lh5370h8.rom11"]),
                   (0x400000, "pair32", ["lh5370h9.rom16", "lh5370ha.rom12"])]),
    2: (0x200000, [(0x000000, "swap16", ["lh5370hb.rom19"])]),
    # Sprites, stored under key "s". 16x16x4 on both boards.
    "s": (0x200000, [(0x000000, "swap16", ["lh537k2r.rom20"])]),
}
PBANCHO = {
    0: (0x200000, [(0x000000, "swap16", ["60.rom3"])]),
    1: (0x400000, [(0x000000, "pair32", ["59.rom15", "61.rom11"])]),
    # MAME loads 60.rom3 here too, commented "?maybe?" -- see ROADMAP open item.
    2: (0x200000, [(0x000000, "swap16", ["60.rom3"])]),
    "s": (0x200000, [(0x000000, "swap16", ["58.rom20"])]),
}
SETS = {"gogomile": GOGOMILE, "pbancho": PBANCHO}


def group(z, names, kind, parts):
    blobs = [bytearray(z.read(names[p])) for p in parts]
    if kind == "swap16":
        d = blobs[0]
        for i in range(0, len(d) - 1, 2):
            d[i], d[i+1] = d[i+1], d[i]
        return bytes(d)
    a, b = blobs
    out = bytearray(len(a) * 2)
    for i in range(0, len(a), 2):
        out[2*i+0] = a[i+1]; out[2*i+1] = a[i+0]
        out[2*i+2] = b[i+1]; out[2*i+3] = b[i+0]
    return bytes(out)


def build(zpath, size, groups):
    z = zipfile.ZipFile(zpath)
    names = {n.split('/')[-1]: n for n in z.namelist()}
    img = bytearray(size)
    for off, kind, parts in groups:
        blob = group(z, names, kind, parts)
        if off + len(blob) > size:
            sys.exit(f"group at 0x{off:x} overruns the {size:#x}-byte region")
        img[off:off+len(blob)] = blob
    return bytes(img)


def main():
    cap = Path(sys.argv[1] if len(sys.argv) > 1 else "debug/gogomile-title")
    game = sys.argv[2] if len(sys.argv) > 2 else "gogomile"
    out = Path("sim/tilemap_tb")   # shared by the tilemap and sprite benches
    out.mkdir(parents=True, exist_ok=True)

    vregs = (cap / "fg2_vregs.bin").read_bytes()
    w = lambda i: struct.unpack_from(">H", vregs, i * 2)[0]

    # Decoded the same way vregs.sv does, INCLUDING the deliberate x/y offset
    # pairing (docs/ROADMAP.md) -- reproduced here so the testbench gets the
    # same numbers the RTL will compute, from an independent implementation.
    XOFFS, YOFFS, L2_XOFFS = 0x01F3, 0x03F6, 0x0010
    flip = w(15) & 1
    if flip:
        sys.exit("captured frame has flip screen ON; the engine does not honour flip yet")
    soy = (w(6) - XOFFS) & 0xFFFF
    sox = (w(7) - YOFFS) & 0xFFFF
    scroll = {
        0: (((w(1) + sox) & 0xFFFF), ((w(0) + soy) & 0xFFFF)),
        1: (((w(3) + sox) & 0xFFFF), ((w(2) + soy) & 0xFFFF)),
        2: (((w(5) + L2_XOFFS) & 0xFFFF), (w(4) & 0xFFFF)),
    }
    l2_buffer = (w(15) >> 6) & 1

    for f in ("vram", "palette", "spriteram", "priority"):
        (out / f"{f}.bin").write_bytes((cap / f"fg2_{f}.bin").read_bytes())

    spec = SETS[game]
    for layer, (size, groups) in spec.items():
        img = build(f"roms/{game}.zip", size, groups)
        (out / f"l{layer}_gfx.bin").write_bytes(img)
        desc = "; ".join(f"@{off:#08x} {kind} {'+'.join(parts)}" for off, kind, parts in groups)
        print(f"  l{layer}_gfx.bin  {len(img):>9,} bytes  {desc}")

    with open(out / "config.txt", "w") as f:
        for layer in (0, 1, 2):
            sx, sy = scroll[layer]
            bank = layer if layer < 2 else (2 + l2_buffer)
            tile16 = 1 if layer < 2 else 0
            bpp8 = 1 if layer == 1 else 0            # FG-2: only layer 1 is 8bpp
            gran256 = 0                              # FG-2 uses granularity 16 throughout
            shift4 = 0                               # FG-3 only
            trans = 0xFF if bpp8 else 0x0F
            pal_base = {0: 0x000, 1: 0x400, 2: 0xC00}[layer]
            f.write(f"{layer} {bank} {tile16} {bpp8} {shift4} {gran256} "
                    f"{pal_base} {trans} {sx} {sy}\n")

    print(f"\n  scroll (x, y) after offset decode:")
    for layer in (0, 1, 2):
        print(f"    layer {layer}: {scroll[layer][0]:5d}, {scroll[layer][1]:5d}")
    print(f"    layer 2 VRAM buffer: {l2_buffer}")
    print(f"  -> {out}")


main()
