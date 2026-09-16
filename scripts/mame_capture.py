#!/usr/bin/env python3
"""Drive MAME headlessly to capture reference frames for the RTL to be checked against.

    python scripts/mame_capture.py gogomile --frame 900 --name title
    python scripts/mame_capture.py pbancho  --frame 3000 --name play --vreglog

Writes into debug/<name>/ (gitignored, ROM-derived): a dump of every region the
video hardware reads, MAME's screenshot of that state, and optionally a log of
video-register writes. Simulation preloads the dumps and diffs its frame
against the screenshot.
"""
import argparse, os, shutil, subprocess, sys
from pathlib import Path

MAME_DIR = Path(os.getenv("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.getenv("MAME_EXE", "arcade64.exe")

FG3 = {"asurabld", "asurabus", "asurabusj", "asurabusja", "asurabusjr"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, default=600,
                    help="frame number to capture at (60 = 1 second)")
    ap.add_argument("--name", help="output subdirectory under debug/ (default: <game>-f<frame>)")
    ap.add_argument("--vreglog", action="store_true",
                    help="also log every video-register write, tagged with frame and raster line")
    ap.add_argument("--show", action="store_true",
                    help="render to a window instead of running headless")
    a = ap.parse_args()

    if not MAME_EXE.exists():
        sys.exit(f"MAME not found at {MAME_EXE} (set MAME_DIR / MAME_EXE)")

    repo = Path(__file__).resolve().parent.parent
    out = repo / "debug" / (a.name or f"{a.game}-f{a.frame}")

    # Start clean: MAME numbers snapshots by first free slot, so re-running
    # into an existing capture pairs dumps from one run with a snapshot from
    # another.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    env = dict(os.environ)
    env.update(
        FUUKI_OUT=out.as_posix(),
        FUUKI_FRAME=str(a.frame),
        FUUKI_BOARD="fg3" if a.game in FG3 else "fg2",
        FUUKI_VREGLOG="1" if a.vreglog else "0",
        FUUKI_SCRIPT=(repo / "scripts" / "mame" / "capture.lua").as_posix(),
    )

    cmd = [
        str(MAME_EXE), a.game,
        "-skip_gameinfo",
        # This install's mame.ini has `debug 1`, which halts at startup while
        # the autoboot script still runs, so no frame ever advances.
        "-nodebug",
        "-nothrottle",
        "-sound", "none",
        "-autoboot_delay", "0",
        # Via the bootstrap, so a Lua error goes to a file, not a modal dialog.
        "-autoboot_script", (repo / "scripts" / "mame" / "run.lua").as_posix(),
        "-snapshot_directory", out.as_posix(),
        # Hard stop in emulated time, in case the script never reaches its frame.
        "-seconds_to_run", str(max(30, a.frame // 60 + 20)),
    ]
    # mame.ini also sets `window 1`, so headless overrides it explicitly.
    cmd += (["-window", "-nomaximize"] if a.show
            else ["-video", "none", "-nowindow"])

    print("  " + " ".join(cmd))
    # MAME resolves mame.ini, and so rompath, relative to cwd.
    r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env,
                       capture_output=True, text=True, timeout=900)
    for line in (r.stdout or "").splitlines():
        if line.startswith("CAPTURE") or "rror" in line:
            print("  " + line)
    if r.returncode != 0:
        print((r.stderr or "").strip()[:1500])

    err = out / "lua_error.txt"
    if err.exists():
        print("--- LUA FAILURE ---")
        print(err.read_text().strip())
        sys.exit("the capture script failed; nothing was captured")

    got = sorted(p.name for p in out.iterdir())
    if not any(n.endswith(".bin") for n in got):
        # A Lua syntax error in the autoboot script opens a modal dialog, which
        # headless looks like a silent no-op; MAME's output shows why.
        print("--- MAME stdout ---")
        print((r.stdout or "").strip()[-2000:])
        print("--- MAME stderr ---")
        print((r.stderr or "").strip()[-2000:])
        sys.exit(f"no dumps written to {out}")

    # MAME nests snapshots under the system name as NNNN.png; copy to a
    # stable name.
    snaps = sorted(out.rglob("[0-9][0-9][0-9][0-9].png"))
    if len(snaps) == 1:
        shutil.copyfile(snaps[0], out / "reference.png")
    elif len(snaps) > 1:
        # The directory starts clean, so this should not happen; refuse to guess.
        sys.exit(f"{len(snaps)} snapshots in {out} -- cannot tell which frame "
                 f"the dumps belong to; delete the directory and re-capture")
    else:
        print("  WARNING: no snapshot was written")

    print(f"\n{out}:")
    for n in sorted(p.name for p in out.iterdir()):
        print(f"  {n:24s} {(out / n).stat().st_size:>8,} bytes")


main()
