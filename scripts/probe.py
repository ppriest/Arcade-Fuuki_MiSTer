#!/usr/bin/env python3
"""Read the core's JTAG probe, guarded against a concurrent Quartus build.

    python scripts/probe.py            # read every field
    python scripts/probe.py clear      # read, then zero the counters
    python scripts/probe.py --fields frames pcm_keyons snd_peak

Wraps `quartus_stp -t scripts/read_issp.tcl`: refuses to run beside Quartus
(scripts/hwlock.py) and prints one line per read.
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


def read(clear=False, instance=None):
    args = [str(QUARTUS_STP), "-t", str(TCL)] + (["clear"] if clear else []) + ([instance] if instance else [])
    r = subprocess.run(args, capture_output=True, text=True,
                       timeout=300, cwd=str(REPO))
    # quartus_stp writes the decoded fields to stderr, so parse both streams.
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
    ap.add_argument("--instance", help="probe instance: F (default), S (FG-2 sound board per chip) or C (FG-2 command transport); clear always acts on F")
    ap.add_argument("--fields", nargs="*",
                    help="only these fields, in this order")
    a = ap.parse_args()

    with jtag_session("probe.py"):
        # clear drives instance F's source bit 0, which clears both probes
        v = read(clear=(a.action == "clear"), instance="F" if a.action == "clear" else (a.instance or "F"))
    if not v:
        sys.exit("no fields decoded -- does read_issp.tcl match the build?")
    keys = a.fields if a.fields else list(v)
    print(" ".join("%s=%s" % (k, v.get(k, "?")) for k in keys))
    return 0


if __name__ == "__main__":
    sys.exit(main())
