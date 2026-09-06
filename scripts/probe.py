#!/usr/bin/env python3
"""Read the core's JTAG probe, guarded against a concurrent Quartus build.

    python scripts/probe.py            # read every field
    python scripts/probe.py clear      # read, then zero the counters
    python scripts/probe.py --fields frames pcm_keyons snd_peak

The same thing as `quartus_stp -t scripts/read_issp.tcl`, with two
differences worth having: it refuses to run while Quartus is compiling (see
scripts/hwlock.py -- that combination has bugchecked this PC three times),
and it prints one line per read so a sequence of samples is readable rather
than four screens of Quartus banner.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hwlock import jtag_session   # noqa: E402

QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
TCL = REPO / "scripts" / "read_issp.tcl"


def read(clear=False):
    args = [str(QUARTUS_STP), "-t", str(TCL)] + (["clear"] if clear else [])
    r = subprocess.run(args, capture_output=True, text=True,
                       timeout=300, cwd=str(REPO))
    # quartus_stp writes the decoded fields to stderr, not stdout, so both
    # streams are parsed -- reading only stdout decodes nothing at all.
    out = {}
    for ln in (r.stdout.splitlines() + r.stderr.splitlines()):
        s = ln.strip()
        if not s or s.startswith("Info") or s.startswith("Error"):
            continue
        parts = s.split()
        if len(parts) == 2 and not s.startswith(("hardware:", "device:",
                                                 "instance:", "raw")):
            out[parts[0]] = parts[1]
    if not out and "not found" in (r.stdout + r.stderr):
        sys.exit("JTAG hardware not found -- is the USB-Blaster plugged in?\n"
                 "(after a forced Quartus kill it sometimes needs a replug)")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", nargs="?", choices=("read", "clear"),
                    default="read")
    ap.add_argument("--fields", nargs="*",
                    help="only these fields, in this order")
    a = ap.parse_args()

    with jtag_session("probe.py"):
        v = read(clear=(a.action == "clear"))
    if not v:
        sys.exit("no fields decoded -- does read_issp.tcl match the build?")
    keys = a.fields if a.fields else list(v)
    print(" ".join("%s=%s" % (k, v.get(k, "?")) for k in keys))
    return 0


if __name__ == "__main__":
    sys.exit(main())
