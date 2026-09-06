#!/usr/bin/env python3
"""Drive MAME headlessly to capture reference frames for the RTL to be checked against.

    python scripts/mame_capture.py gogomile --frame 900 --name title
    python scripts/mame_capture.py pbancho  --frame 3000 --name play --vreglog

Writes into debug/<name>/ (gitignored -- this is ROM-derived data and is never
committed): a binary dump of every region the video hardware reads, the
screenshot MAME rendered from exactly that state, and optionally a log of every
video-register write.

Why this exists: the renderer is being built against MAME's output as the
accuracy target, and "compare against MAME" is only cheap if capturing a
reference frame is one command. Capturing by hand through the debugger is
several commands, easy to get subtly wrong, and impossible to repeat exactly.

The screenshot is the point as much as the dumps. Preloading the dumps in
simulation, rendering one frame and diffing against the screenshot validates
the whole tilemap and sprite path with no hardware involved.
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

    # START CLEAN. MAME numbers snapshots by finding the first free slot in the
    # directory, so re-running into an existing capture leaves a MIXTURE: dumps
    # from one run beside snapshots from several. Picking "the newest snapshot"
    # out of that pairs an image from one frame with memory from another, and
    # the resulting diff looks like a catastrophic rendering fault -- 1% pixel
    # match, with the RTL drawing a title screen while the reference showed a
    # combat scene. Nothing warns; the files all look plausible.
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
        # MUST be explicit: this MAME install has `debug 1` in its mame.ini, so
        # every launch otherwise opens the debugger and HALTS at startup. The
        # autoboot script still runs and prints, which makes it look like it is
        # working, but the machine never advances a frame and the capture's
        # frame notifier never fires -- it just sits there.
        "-nodebug",
        "-nothrottle",              # run as fast as the host allows
        "-sound", "none",
        "-autoboot_delay", "0",
        # Through the bootstrap, so a Lua syntax or runtime error is written to
        # a file instead of only appearing in a modal dialog nobody can see.
        "-autoboot_script", (repo / "scripts" / "mame" / "run.lua").as_posix(),
        # Snapshots land beside the dumps rather than in MAME's own snap/ tree.
        "-snapshot_directory", out.as_posix(),
        # A hard stop, so a script that never reaches its frame cannot leave
        # MAME running forever. Generous: at -nothrottle a frame is quick, but
        # the guard is wall-clock emulated time, not real time.
        "-seconds_to_run", str(max(30, a.frame // 60 + 20)),
    ]
    # mame.ini also sets `window 1`, so the headless case overrides it
    # explicitly rather than relying on -video none alone.
    cmd += (["-window", "-nomaximize"] if a.show
            else ["-video", "none", "-nowindow"])

    print("  " + " ".join(cmd))
    # cwd matters: MAME resolves mame.ini, and therefore rompath, relative to it.
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
        # Show MAME's own output. A Lua SYNTAX error in the autoboot script
        # makes MAME pop a modal dialog and sit there -- headless, that looks
        # exactly like "the script ran and quietly did nothing", and the run
        # only ends when the timeout kills it. Printing what MAME said turns
        # that into a one-line diagnosis instead of a hunt.
        print("--- MAME stdout ---")
        print((r.stdout or "").strip()[-2000:])
        print("--- MAME stderr ---")
        print((r.stderr or "").strip()[-2000:])
        sys.exit(f"no dumps written to {out}")

    # MAME nests snapshots one level down, under the system name, and numbers
    # them 0000.png, 0001.png ... Search recursively and give the newest a
    # stable name so downstream tooling has something fixed to point at.
    snaps = sorted(out.rglob("[0-9][0-9][0-9][0-9].png"))
    if len(snaps) == 1:
        shutil.copyfile(snaps[0], out / "reference.png")
    elif len(snaps) > 1:
        # Cannot happen now the directory starts clean, but if it ever does,
        # refuse rather than guess which image goes with the dumps.
        sys.exit(f"{len(snaps)} snapshots in {out} -- cannot tell which frame "
                 f"the dumps belong to; delete the directory and re-capture")
    else:
        print("  WARNING: no snapshot was written")

    print(f"\n{out}:")
    for n in sorted(p.name for p in out.iterdir()):
        print(f"  {n:24s} {(out / n).stat().st_size:>8,} bytes")


main()
