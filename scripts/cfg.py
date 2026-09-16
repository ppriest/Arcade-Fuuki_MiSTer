#!/usr/bin/env python3
"""Set OSD status bits in a MiSTer per-core .CFG by READ-MODIFY-WRITE.

    python scripts/cfg.py gogomile --show
    python scripts/cfg.py gogomile --set overlay=1 src=0 ring=1
    python scripts/cfg.py gogomile --clear-debug

/media/fat/config/<setname>.CFG is the whole 128-bit status word, little
endian (byte N holds status[8N+7:8N]), shared with aspect, scandoubler and
other settings. Writing fresh bytes clears all of them (on the Psikyo core it
zeroed DIPs and turned Service Mode on), so this pulls the file, flips only
the named bits, and pushes it back. A missing file starts from all-zero, as
MiSTer does.

BIT MAP -- keep in step with Fuuki.sv's CONF_STR.

DEBUG_BITS reach the core only in the Fuuki_stp build; the release forces
them to zero (Fuuki.sv, "DEBUG BUILD OR RELEASE").
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REMOTE_CFG = "/media/fat/config"

# name -> (low_bit, width). From Fuuki.sv's CONF_STR.
BITS = {
    "reset":    (0, 1),
    "no_l0":    (40, 1),   # "Tilemap 0,On,Off" -- 1 = off
    "no_l1":    (41, 1),
    "no_l2":    (42, 1),
    "no_spr":   (43, 1),
    "fx":       (44, 3),   # scandoubler
    "overlay":  (50, 1),   # trace overlay
    "src":      (51, 2),   # 0 download addr, 1 CPU addr, 2 CPU data, 3 palette wr
    "window":   (53, 4),
    "ring":     (57, 1),   # 0 = first N, 1 = ring (latest N)
    "rearm":    (58, 1),   # any CHANGE re-arms
    "trig":     (59, 1),   # ring mode: freeze on the first exception-vector read
    "marker":   (60, 1),   # white pixels x 0..7 on lines 0 and 239
    "rotate":   (63, 2),   # HDMI rotation: 0 off, 1 CW, 2 CCW
    "flip180":  (65, 1),   # HDMI picture turned round
    "scale":    (66, 3),   # video_freak scale mode
    "vcrop":    (69, 2),   # 0 off, 1 216p, 2 224p
    "crop_off": (71, 5),   # crop window offset, two's complement
    "crt":      (76, 1),   # CRT Adjust on
    "hsize":    (92, 5),   # CRT H-Size, two's complement -16..+15
    "vsize":    (97, 4),   # CRT V-Size, two's complement -8..+7 (x3 lines)
    "vsmode":   (101, 1),  # CRT V-Size mode: 0 PVM, 1 Cabinet
    "audio_mix": (102, 2), # 0 mono (default), 1 none, 2 25%, 3 50%
    "aspect":   (121, 2),
}
DEBUG_BITS = ("overlay", "src", "window", "ring", "rearm", "trig",
              "no_l0", "no_l1", "no_l2", "no_spr", "marker")


def env():
    p = REPO / "mister.env"
    if not p.exists():
        sys.exit("mister.env not found")
    e = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            e[k.strip()] = v.strip()
    return e


def putty(name):
    for c in (name, os.path.join(r"C:\Program Files\PuTTY", name)):
        f = shutil.which(c) or (c if os.path.isfile(c) else None)
        if f:
            return f
    sys.exit(f"Couldn't find {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("setname")
    ap.add_argument("--set", nargs="*", default=[], metavar="NAME=VALUE")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--clear-debug", action="store_true",
                    help="zero every debug field, leaving everything else alone")
    a = ap.parse_args()

    e = env()
    pscp, plink = putty("pscp.exe"), putty("plink.exe")
    host = f"{e['MISTER_USER']}@{e['MISTER_HOST']}"
    remote = f"{REMOTE_CFG}/{a.setname}.CFG"
    local = REPO / "debug" / "hw" / f"{a.setname}.CFG"
    local.parent.mkdir(parents=True, exist_ok=True)

    r = subprocess.run([pscp, "-batch", "-pw", e["MISTER_PASSWORD"],
                        f"{host}:{remote}", str(local)],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        print(f"  no existing {a.setname}.CFG on the device -- starting from "
              f"all-zero, which is what MiSTer uses for a first run")
        raw = bytearray(16)
    else:
        raw = bytearray(local.read_bytes())
        if len(raw) < 16:
            raw += bytearray(16 - len(raw))

    word = int.from_bytes(raw[:16], "little")

    def get(name):
        lo, w = BITS[name]
        return (word >> lo) & ((1 << w) - 1)

    if a.show or not (a.set or a.clear_debug):
        print(f"{a.setname}.CFG ({len(raw)} bytes)")
        for n in BITS:
            print(f"  {n:9s} = {get(n)}")
        print(f"  raw[0:8] = {raw[:8].hex(' ')}")
        if not (a.set or a.clear_debug):
            return 0

    changes = []
    pairs = list(a.set)
    if a.clear_debug:
        pairs += [f"{n}=0" for n in DEBUG_BITS]
    for kv in pairs:
        if "=" not in kv:
            sys.exit(f"expected NAME=VALUE, got {kv!r}")
        n, v = kv.split("=", 1)
        if n not in BITS:
            sys.exit(f"unknown field {n!r}. Known: {', '.join(BITS)}")
        lo, w = BITS[n]
        v = int(v, 0)
        if v >= (1 << w):
            sys.exit(f"{n} is {w} bit(s); {v} does not fit")
        old = get(n)
        word = (word & ~(((1 << w) - 1) << lo)) | (v << lo)
        if old != v:
            changes.append(f"{n} {old} -> {v}")

    raw[:16] = word.to_bytes(16, "little")
    local.write_bytes(bytes(raw))

    subprocess.run([plink, "-ssh", "-batch", "-pw", e["MISTER_PASSWORD"],
                    host, f"mkdir -p {REMOTE_CFG}"], capture_output=True,
                   timeout=60)
    r = subprocess.run([pscp, "-batch", "-pw", e["MISTER_PASSWORD"],
                        str(local), f"{host}:{remote}"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(f"failed to write {remote}: {r.stderr.strip()}")

    print(f"  {remote}: " + (", ".join(changes) if changes else "no change"))
    print("  (the CFG is read when the core LOADS -- relaunch to apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
