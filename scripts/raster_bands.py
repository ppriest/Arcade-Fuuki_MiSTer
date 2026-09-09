#!/usr/bin/env python3
"""Decode the per-line display record into raster band boundaries.

    python scripts/memdump.py linecap 0 8 --live --pause
    python scripts/raster_bands.py

Reads debug/hw/dump/linecap_0.bin -- eight words per display line, written
by rtl/fuuki_core.sv's PER-LINE DISPLAY RECORD -- and prints the display
line each scroll value first appears on. That is the whole question behind
gogomile's cloud fault: the chain's arithmetic is known from a MAME capture,
so what matters is WHICH LINE GOT WHICH SCROLL, not what the picture looks
like.

gogomile's title clouds, from debug/gogo-vreglog/fg2_vregs.log, are five
bands whose scrolls move at 2, 1, 1/2, 0 and 0 pixels per frame:

    line   0   band A, written at the 0xFFFE step
    line  30   band B, written at the interrupt for line 0x1D (29)
    line  64   band C,                                   0x3F (63)
    line  89   band D,                                   0x58 (88)
    line 119   band E,                                   0x76 (118)

MAME puts a band's first line at (raster line + 1), because update_partial()
draws through the interrupt's own line with the old registers. The engines
run two lines ahead of the display and an ISR's write is caught at the
hblank after the interrupt, so where the boundary lands depends on how early
level 5 fires (video_timing.sv, irq5_cmp). Measured on gogomile's clouds:
two lines early put every boundary at -1, one line early put every boundary
at +0, and that is what the RTL now does.
"""
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORDS_PER_LINE = 8
# Where MAME's partial update puts each band's first line.
EXPECTED = {0: "A (0xFFFE step)", 30: "B (irq 0x1D)", 64: "C (irq 0x3F)",
            89: "D (irq 0x58)", 119: "E (irq 0x76)"}


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        REPO / "debug" / "hw" / "dump" / "linecap_0.bin"
    if not path.exists():
        sys.exit("no %s -- run: python scripts/memdump.py linecap 0 8 --live --pause"
                 % path)
    raw = path.read_bytes()
    w = [struct.unpack(">H", raw[i:i + 2])[0] for i in range(0, len(raw), 2)]
    lines = len(w) // WORDS_PER_LINE
    if lines < 240:
        print("only %d lines in the dump -- did all 8 pages come back?" % lines)

    print("display line : layer2 X scroll (word 5), layer0 Y scroll (6), "
          "raster reg (7)")
    print("boundaries are where the value CHANGES\n")

    prev_sx = prev_sy = None
    boundaries = []
    overruns = []
    for ln in range(min(lines, 240)):
        b = w[ln * WORDS_PER_LINE:(ln + 1) * WORDS_PER_LINE]
        sx2, sy0, rast = b[5], b[6], b[7] & 0x1FF
        ovr = (b[7] >> 9) & 0xF          # {spr, tm2, tm1, tm0} busy at the swap
        if ovr:
            overruns.append((ln, ovr))
        if sx2 != prev_sx:
            boundaries.append((ln, sx2, sy0, rast))
            print("  line %3d : layer2 X = 0x%04X   layer0 Y = 0x%04X   raster = %3d"
                  % (ln, sx2, sy0, rast))
        prev_sx, prev_sy = sx2, sy0

    print("\nagainst MAME's band starts:")
    got = [b[0] for b in boundaries]
    for want, name in sorted(EXPECTED.items()):
        near = [g for g in got if abs(g - want) <= 6]
        if not near:
            print("  line %3d  %-18s NOT FOUND within 6 lines" % (want, name))
        else:
            d = near[0] - want
            print("  line %3d  %-18s measured at %3d  (%+d lines)"
                  % (want, name, near[0], d))
    print("\n+0 on every boundary is correct. A constant offset is the level-5 lead")
    print("(video_timing.sv, irq5_cmp): one line early measured +0, two lines early -1.")
    # RENDER OVERRUN WATCH (fuuki_core.sv): the engines caught still busy at
    # the swap that presented each line. A flagged line was displayed half
    # drawn by that engine -- tiles from the left as far as it got, then
    # transparent.
    print("\nlines whose engines overran (word 7 bits 12:9 = spr tm2 tm1 tm0):")
    if not overruns:
        print("  none")
    for ln, ovr in overruns:
        names = [n for n, bit in (("tm0", 1), ("tm1", 2), ("tm2", 4), ("spr", 8)) if ovr & bit]
        print("  line %3d : %s" % (ln, " ".join(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
