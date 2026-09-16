#!/usr/bin/env python3
"""Turn a MAME OPL4 write log into stimulus for sim/opl4_replay_tb.

    python scripts/opl4_log.py asurabld --coin 2400 --from 0 --to 2520
    python scripts/prep_opl4_replay.py asurabld --coin 2400
    bash scripts/run_sim.sh opl4_replay_tb +FAST_TO=2380 +END=2470
    python scripts/prep_opl4_replay.py asurabld --coin 2400 --wav

Writes sim/opl4_replay_tb/writes.hex (one "frame port data" line per port
write, in log order) and debug/hw/<game>_wave.bin (the wave ROM). --wav
turns the bench's sim/opl4_replay_tb/out.raw into out.wav and prints its
peak per 50 ms beside MAME's audio.wav over the same frames.
"""
import argparse
import re
import struct
import sys
import wave
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TB = REPO / "sim" / "opl4_replay_tb"
FPS = 59.92
LOG_RE = re.compile(r"\s*(\d+)\s+\d+\s+(FM|PCM)\s+([0-9A-Fa-f]+)=([0-9A-Fa-f]+)")


def stimulus(game, coin):
    log = REPO / "debug" / "opl4_log" / f"{game}-c{coin}" / "opl4_writes.txt"
    out = []
    for ln in log.read_text().splitlines():
        m = LOG_RE.match(ln)
        if not m:
            continue
        fr, kind, a, d = int(m[1]), m[2], int(m[3], 16), int(m[4], 16)
        if kind == "FM":
            hi = (a >> 8) & 1
            out += [(fr, 2 if hi else 0, a & 0xFF), (fr, 3 if hi else 1, d)]
        else:
            out += [(fr, 4, a), (fr, 5, d)]
    TB.mkdir(parents=True, exist_ok=True)
    with open(TB / "writes.hex", "w") as f:
        for fr, port, v in out:
            f.write(f"{fr:06x} {port:x} {v:02x}\n")
    print(f"{len(out)} port writes, frames {out[0][0]}..{out[-1][0]} -> {TB / 'writes.hex'}")

    z = zipfile.ZipFile(REPO / "roms" / f"{game}.zip")
    member = next(i for i in z.infolist() if i.filename.split("/")[-1] in ("pcm.u6", "opm.u6"))
    dst = REPO / "debug" / "hw" / f"{game}_wave.bin"
    dst.write_bytes(z.read(member))
    print(f"wave ROM {member.filename} -> {dst}")


def peaks(frames, rate, chans, first_frame):
    step = rate // 20
    return [max(abs(s) for s in frames[i:i + step * chans]) if frames[i:i + step * chans] else 0
            for i in range(0, len(frames), step * chans)]


def to_wav(game, coin, start_frame):
    raw = (TB / "out.raw").read_bytes()
    n = len(raw) // 4
    samples = struct.unpack(f"<{n * 2}h", raw[:n * 4])
    with wave.open(str(TB / "out.wav"), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(raw[:n * 4])
    print(f"out.wav: {n} samples, {n / 44100:.2f} s from frame {start_frame}")

    mame = REPO / "debug" / "opl4_log" / f"{game}-c{coin}" / "audio.wav"
    with wave.open(str(mame)) as w:
        rate, ch = w.getframerate(), w.getnchannels()
        w.setpos(int(start_frame / FPS * rate))
        data = w.readframes(int(n / 44100 * rate))
    m = struct.unpack(f"<{len(data) // 2}h", data)
    ours, theirs = peaks(samples, 44100, 2, start_frame), peaks(m, rate, ch, start_frame)
    print("  time    frame   sim peak   MAME peak")
    for i in range(max(len(ours), len(theirs))):
        t = i * 0.05
        print(f"  {t:5.2f}s  {start_frame + t * FPS:6.0f}  {ours[i] if i < len(ours) else '':>8}  "
              f"{theirs[i] if i < len(theirs) else '':>9}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--coin", type=int, required=True)
    ap.add_argument("--wav", action="store_true")
    ap.add_argument("--start", type=int, default=2380, help="the bench's FAST_TO frame")
    a = ap.parse_args()
    if a.wav:
        to_wav(a.game, a.coin, a.start)
    else:
        stimulus(a.game, a.coin)


main()
