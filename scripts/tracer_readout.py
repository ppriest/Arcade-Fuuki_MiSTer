#!/usr/bin/env python3
"""Read the core's 256-entry trace buffer back through the screenshot path.

    from tracer_readout import read_buffer
    entries, problems = read_buffer(tag="boot_fc")      # list of 256 (int | None)

The overlay (rtl/fuuki_core.sv, "Banded readout") shows each entry on six
scanlines -- three of the value, three of its bitwise inverse -- 40 entries
per screen over seven JTAG-selected pages. Entries are recovered by content,
not row number: v and ~v come from the same BRAM entry, so any capture-path
transform (e.g. the framework's gamma LUT, docs/LESSONS_LEARNED.md) shows up
as an unpaired run instead of being read as data.

Per screen: split rows into runs of identical value; runs of 2..5 rows are
band halves (blended edge rows are excluded); consecutive runs with
v ^ w == 0xFFFFFF are one entry. Anything unpaired is reported, not guessed.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HW = REPO / "scripts" / "hw.py"
DECODE = REPO / "scripts" / "decode_debug_screenshot.py"
ISSP = REPO / "scripts" / "read_issp.tcl"
QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
OUT = REPO / "debug" / "hw" / "trace"

PAGES = 7           # 7 x 40 = 280 >= 256
PER_PAGE = 40
PAGE_BITS = {0: 0x00, 1: 0x08, 2: 0x10, 3: 0x18, 4: 0x80, 5: 0x88, 6: 0x90}   # bits 4:3 and 7


def issp(*args):
    # Guarded by scripts/hwlock.py; every script that reads the probe
    # through here shares the guard.
    from hwlock import jtag_session
    with jtag_session("tracer_readout.issp"):
        p = subprocess.run([str(QUARTUS_STP), "-t", str(ISSP), *map(str, args)],
                           capture_output=True, text=True, timeout=180, cwd=str(REPO))
    return p.stdout


def shot(png):
    # The buffer is static while read (first-N holds it; ring mode is read
    # frozen), so the default 4 s settle is not needed.
    subprocess.run([sys.executable, str(HW), "shot", "--out", str(png), "--settle", "1"],
                   capture_output=True, cwd=str(REPO))
    return png.exists()


CORE_LINES = 240


def rows_of(png):
    """One value per CORE scanline, whatever size the screenshot is.

    With MISTER_FB (rotation) the screenshot is the framebuffer, e.g.
    810x1080, so a scanline spans several image rows. Take the row at the
    centre of each scanline's span; blended edge rows fall between centres.
    """
    out = subprocess.run([sys.executable, str(DECODE), str(png), "--mode", "scanline",
                          "--limit", "0"], capture_output=True, text=True).stdout
    rows, height = {}, 0
    for line in out.splitlines():
        m = re.match(r"#.*?:\s*(\d+)x(\d+)", line)
        if m:
            height = int(m.group(2))
        m = re.match(r"\s*(\d+)\s+0x([0-9A-Fa-f]+)", line)
        if m:
            rows[int(m.group(1))] = int(m.group(2), 16)
    if height <= 0:
        height = (max(rows) + 1) if rows else CORE_LINES
    if height == CORE_LINES:
        return [rows.get(i) for i in range(CORE_LINES)]
    scale = height / CORE_LINES
    return [rows.get(int((i + 0.5) * scale)) for i in range(CORE_LINES)]


def entries_from_rows(rows):
    """(entries_in_order, problems) from one screen of rows."""
    runs = []                      # (value, length)
    for v in rows:
        if v is None:
            continue
        if runs and runs[-1][0] == v:
            runs[-1][1] += 1
        else:
            runs.append([v, 1])
    # keep plausible band halves; edge/blend rows make 1-row runs, drop them
    halves = [(v, n) for v, n in runs if 2 <= n <= 5]
    entries, problems, i = [], [], 0
    while i + 1 < len(halves):
        v, a = halves[i]; w, b = halves[i + 1]
        if (v ^ w) == 0xFFFFFF:
            entries.append(v); i += 2
        else:
            problems.append(f"unpaired run {v:06X}x{a} next {w:06X}x{b}")
            i += 1
    return entries, problems


def read_buffer(tag="trace", settle=0.6, src_high=0, low_or=0):
    """Walk all pages; return (entries[256], problems).

    src_high: value kept in JTAG source bits [31:8] throughout (the memory
    dump's {region, page}); the readout page bits live in [7:0]. low_or is
    OR-ed into every [7:0] write (0x20 = hold the CPU paused)."""
    OUT.mkdir(parents=True, exist_ok=True)
    entries = [None] * 256
    problems = []
    for page in range(PAGES):
        issp("set", (src_high << 8) | PAGE_BITS[page] | low_or); time.sleep(settle)
        png = OUT / f"{tag}_p{page}.png"
        if not shot(png):
            problems.append(f"page {page}: no screenshot"); continue
        got, probs = entries_from_rows(rows_of(png))
        problems += [f"page {page}: {p}" for p in probs]
        if len(got) != PER_PAGE and page < PAGES - 1:
            problems.append(f"page {page}: recovered {len(got)} of {PER_PAGE} entries")
        for k, v in enumerate(got[:PER_PAGE]):
            idx = page * PER_PAGE + k
            if idx < 256:
                entries[idx] = v
    issp("set", (src_high << 8) | low_or)
    return entries, problems


if __name__ == "__main__":
    tag = sys.argv[1] if len(sys.argv) > 1 else "trace"
    ents, probs = read_buffer(tag)
    print(f"{sum(e is not None for e in ents)}/256 entries recovered; {len(probs)} problems")
    for p in probs[:10]:
        print("  ", p)
    for i in range(0, 256, 8):
        print(f"  {i:3d}: " + " ".join("------" if e is None else f"{e:06X}" for e in ents[i:i+8]))
