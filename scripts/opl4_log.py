#!/usr/bin/env python3
"""Capture what the FG-3 sound driver sends the OPL4 for a sound, from MAME.

    python scripts/opl4_log.py asurabus --coin 2400
    python scripts/opl4_log.py asurabus --coin 2400 --from 2300 --to 2700

Runs MAME headlessly with scripts/mame/opl4_log.lua, which logs every OPL4
write in the window and inserts a coin at --coin. MAME's own audio for the
run is recorded to audio.wav. Then:

  * every PCM key-on in the window is decoded: the channel's registers at
    that instant, and the wavetable header those registers point at in
    opm.u6 (format, base, loop, end, and the ADSR/LFO bytes the chip loads
    into the channel);
  * the WAV is summarised as peak per 50 ms window, with the coin frame
    marked, so the level of the sound the coin triggered can be read
    against the music around it.

Everything lands in debug/opl4_log/<game>-c<coin>/ (gitignored: ROM-derived).

Why: the RTL's PCM engine reads identically to ymfm and plays Psikyo's
effects on MiSTer, yet Fuuki's one-shot effects come out far quieter than
its music. What differs is what the driver asks of the engine, and that is
a register sequence to capture rather than a mechanism to guess.
"""
import argparse
import os
import struct
import subprocess
import sys
import wave
import zipfile
from pathlib import Path

MAME_DIR = Path(os.getenv("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.getenv("MAME_EXE", "arcade64.exe")
REPO = Path(__file__).resolve().parent.parent

WAVE_ROM = "opm.u6"   # the same name in every FG-3 set


def load_wave_rom(game):
    zpath = REPO / "roms" / (game + ".zip")
    if not zpath.exists():
        return None
    try:
        return zipfile.ZipFile(zpath).read(WAVE_ROM)
    except KeyError:
        return None


def header(rom, wavnum, bank=0):
    """Decode a 12-byte wavetable header as ymfm's load_wavetable does."""
    off = 12 * wavnum
    if wavnum >= 384 and bank:
        off = 512 * 1024 * bank + (wavnum - 384) * 12
    h = rom[off:off + 12]
    if len(h) < 12:
        return None
    fmt = h[0] >> 6
    base = ((h[0] & 0x3F) << 16) | (h[1] << 8) | h[2]
    loop = (h[3] << 8) | h[4]
    end = (-((h[5] << 8) | h[6])) & 0xFFFF
    return dict(fmt=("8-bit", "12-bit", "16-bit", "?")[fmt], base=base, loop=loop,
                end=end, lfo_vib=h[7], ar=h[8] >> 4, dr=h[8] & 15,
                sl=h[9] >> 4, sr=h[9] & 15, rc=h[10] >> 4, rr=h[10] & 15,
                am=h[11] & 7)


def summarise_wav(path, coin_frame, win_ms=50):
    w = wave.open(str(path), "rb")
    rate, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
    raw = w.readframes(n)
    w.close()
    if sw != 2:
        print("  unexpected sample width %d" % sw)
        return
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
    per_win = int(rate * win_ms / 1000) * ch
    print("  audio.wav: %d Hz, %d ch, %.2f s" % (rate, ch, n / rate))
    coin_s = coin_frame / 60.0
    print("  peak |sample| per %d ms window; coin at %.2f s" % (win_ms, coin_s))
    rows = []
    for i in range(0, len(samples), per_win):
        chunk = samples[i:i + per_win]
        if not chunk:
            break
        rows.append((i / ch / rate, max(abs(x) for x in chunk)))
    line = ["%5.1fs:%5d" % (t, pk) for t, pk in rows[::10]]
    for i in range(0, len(line), 6):
        print("    " + "  ".join(line[i:i + 6]))
    print("  around the coin, every window:")
    for t, pk in rows:
        if coin_s - 0.5 <= t <= coin_s + 2.0:
            mark = " <-- coin" if abs(t - coin_s) < win_ms / 1000.0 else ""
            print("    %6.2fs  %5d%s" % (t, pk, mark))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--coin", type=int, default=2400, help="frame to insert a coin at")
    ap.add_argument("--from", dest="frm", type=int, help="first frame to log (default coin-120)")
    ap.add_argument("--to", type=int, help="last frame (default coin+300)")
    ap.add_argument("--decode-only", action="store_true", help="skip MAME; decode an existing run")
    a = ap.parse_args()
    frm = a.frm if a.frm is not None else max(0, a.coin - 120)
    to = a.to if a.to is not None else a.coin + 300

    out = REPO / "debug" / "opl4_log" / ("%s-c%d" % (a.game, a.coin))
    if not a.decode_only:
        if not MAME_EXE.exists():
            sys.exit("MAME not found at %s" % MAME_EXE)
        out.mkdir(parents=True, exist_ok=True)
        for f in ("opl4_writes.txt", "audio.wav", "lua_error.txt"):
            try:
                (out / f).unlink()
            except FileNotFoundError:
                pass
        env = dict(os.environ)
        env.update(FUUKI_OUT=out.as_posix(),
                   FUUKI_SCRIPT=(REPO / "scripts" / "mame" / "opl4_log.lua").as_posix(),
                   FUUKI_LOG_FROM=str(frm), FUUKI_LOG_TO=str(to),
                   FUUKI_COIN_FRAME=str(a.coin))
        cmd = [str(MAME_EXE), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
               "-sound", "none", "-wavwrite", (out / "audio.wav").as_posix(),
               "-autoboot_delay", "0",
               "-autoboot_script", (REPO / "scripts" / "mame" / "run.lua").as_posix(),
               "-seconds_to_run", str(to // 60 + 20),
               "-video", "none", "-nowindow"]
        print("  " + " ".join(cmd))
        r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env,
                           capture_output=True, text=True, timeout=900)
        for line in (r.stdout or "").splitlines():
            if line.startswith("OPL4LOG") or line.startswith("LUAFAIL") or "rror" in line:
                print("  " + line)
        err = out / "lua_error.txt"
        if err.exists():
            sys.exit("--- LUA FAILURE ---\n" + err.read_text())
        if not (out / "opl4_writes.txt").exists():
            print((r.stdout or "")[-2000:])
            print((r.stderr or "")[-2000:])
            sys.exit("no log written")

    # ---- decode ----
    rom = load_wave_rom(a.game)
    lines = (out / "opl4_writes.txt").read_text().splitlines()
    print("\n%s: %d logged lines" % (out, len(lines)))
    coin_line = [ln for ln in lines if "COIN down" in ln]
    print("coin: %s" % (coin_line[0].strip() if coin_line else "not inserted"))
    print("FM writes in window: %d" % sum(1 for ln in lines if " FM " in ln))
    print("\nPCM key-ons in the window:")
    bank = 0
    coin_fr = int(coin_line[0].split()[0]) if coin_line else None
    for ln in lines:
        if "PCM 02=" in ln:
            bank = (int(ln.split("PCM 02=")[1][:2], 16) >> 2) & 7
        if "KEYON" in ln:
            fr = int(ln.split()[0])
            tag = " <== after coin" if coin_fr is not None and fr >= coin_fr else ""
            body = ln.split("KEYON", 1)[1].strip()
            print("  f%-6d %s%s" % (fr, body, tag))
            if rom is not None:
                wav = int(body.split("wave=")[1].split()[0])
                h = header(rom, wav, bank)
                if h:
                    print("          header: %s base=%06X loop=%04X end=%04X  "
                          "AR=%d DR=%d SL=%d SR=%d RC=%d RR=%d AM=%d LFO/VIB=%02X"
                          % (h["fmt"], h["base"], h["loop"], h["end"], h["ar"], h["dr"],
                             h["sl"], h["sr"], h["rc"], h["rr"], h["am"], h["lfo_vib"]))
    wav_path = out / "audio.wav"
    if wav_path.exists() and wav_path.stat().st_size > 100:
        print("")
        summarise_wav(wav_path, a.coin)
    else:
        print("\nno audio.wav (MAME -wavwrite produced nothing)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
