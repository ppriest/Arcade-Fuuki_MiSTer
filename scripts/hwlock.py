#!/usr/bin/env python3
"""Keep JTAG and Quartus/ModelSim off this machine at the same time.

A JTAG session (read_issp.tcl, memdump.py, the tracer readout) running beside
a Quartus compile has bugchecked this PC (KERNEL_SECURITY_CHECK_FAILURE,
0x139). Enforced both ways:

  * a JTAG tool refuses to start while Quartus or ModelSim is running;
  * a build or simulation refuses to start while a JTAG tool holds the marker.

Quartus and ModelSim may run side by side, several of each.

The marker is a file because the JTAG side is both Python and quartus_stp
Tcl. It holds the pid and purpose; a marker whose pid is gone is cleared, so
a crashed tool does not block later builds.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Machine-wide, not per-repo: the Fuuki, Psikyo and Seta cores share one
# USB-Blaster and Quartus install, and every copy of this file must agree.
MARKER = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "mister_jtag_running"


def quartus_processes():
    """Names of running Quartus and ModelSim processes, empty if none."""
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-Process quartus*,vsim*,vlog,vcom,vlib -ErrorAction SilentlyContinue | "
             "Select-Object -ExpandProperty ProcessName"],
            capture_output=True, text=True, timeout=30)
        return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    except Exception:
        # If the check cannot run, do not block the tool.
        return []


def _pid_alive(pid):
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "if (Get-Process -Id %d -ErrorAction SilentlyContinue) "
             "{ 'yes' } else { 'no' }" % pid],
            capture_output=True, text=True, timeout=30)
        return r.stdout.strip() == "yes"
    except Exception:
        return False


def read_marker():
    """(pid, what) if a live JTAG session holds the marker, else None.
    A stale marker is removed."""
    if not MARKER.exists():
        return None
    try:
        pid_s, what = MARKER.read_text(encoding="utf-8").split("\n", 1)
        pid = int(pid_s.strip())
    except Exception:
        MARKER.unlink(missing_ok=True)
        return None
    if not _pid_alive(pid):
        MARKER.unlink(missing_ok=True)
        return None
    return pid, what.strip()


def require_no_quartus(what="this JTAG session"):
    """Refuse to run a JTAG tool while Quartus is compiling."""
    procs = quartus_processes()
    if procs:
        sys.exit(
            "REFUSING %s: Quartus/ModelSim is running (%s).\n"
            "JTAG concurrent with either has bugchecked this PC (0x139). "
            "Wait for it, or stop it deliberately."
            % (what, ", ".join(sorted(set(procs)))))


def require_no_jtag(what="this build"):
    """Refuse to start a build while a JTAG tool holds the marker."""
    held = read_marker()
    if held:
        pid, why = held
        sys.exit(
            "REFUSING %s: a JTAG session is running (pid %d, %s).\n"
            "JTAG concurrent with a compile has bugchecked this PC three "
            "times (0x139). Wait for it, or kill it deliberately and delete\n"
            "  %s" % (what, pid, why, MARKER))


if __name__ == "__main__":
    # command-line form for shell scripts: exit non-zero if a JTAG session
    # holds the marker
    if len(sys.argv) >= 2 and sys.argv[1] == "--require-no-jtag":
        require_no_jtag(sys.argv[2] if len(sys.argv) > 2 else "this build")
        sys.exit(0)


class jtag_session:
    """Context manager: guard, take the marker, release it on the way out."""

    def __init__(self, what="jtag"):
        self.what = what

    def __enter__(self):
        require_no_quartus(self.what)
        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text("%d\n%s at %s\n"
                          % (os.getpid(), REPO.name + ": " + self.what, time.strftime("%H:%M:%S")),
                          encoding="utf-8")
        return self

    def __exit__(self, *exc):
        MARKER.unlink(missing_ok=True)
        return False
