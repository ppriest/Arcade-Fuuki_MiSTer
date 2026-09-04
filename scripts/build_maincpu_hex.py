#!/usr/bin/env python3
"""Build a main-CPU ROM image (and ModelSim .hex) from a MAME ROM set.

The interleave is taken from each driver's ROM_START, not guessed:

  FG-2  ROM_LOAD16_BYTE  fp2n->0x000000, fp1n->0x000001
        => 68000 big-endian word N = { even_rom[N], odd_rom[N] }

  FG-3  ROM_LOAD32_BYTE  pgm3->0, pgm2->1, pgm1->2, pgm0->3
        => big-endian long N = { pgm3[N], pgm2[N], pgm1[N], pgm0[N] }

Output is one 16-bit big-endian word per line, which is what the testbench's
$readmemh expects. LESSONS_LEARNED, "Prove the interleave against MAME's
disassembly offline, before building": run --check to score the reset vector
and the first instructions before trusting any of this.
"""
import argparse, zipfile, sys

SETS = {
    'gogomile': dict(board='fg2', parts=['fp2n.rom2', 'fp1n.rom1']),
    'pbancho':  dict(board='fg2', parts=['no1..rom2', 'no2..rom1']),
    'asurabld': dict(board='fg3', parts=['pgm3.u1', 'pgm2.u2', 'pgm1.u3', 'pgm0.u4']),
    'asurabus': dict(board='fg3', parts=['uspgm3.u1', 'uspgm2.u2', 'uspgm1.u3', 'uspgm0.u4']),
}

def build(zippath, spec):
    z = zipfile.ZipFile(zippath)
    names = {n.split('/')[-1]: n for n in z.namelist()}
    blobs = []
    for p in spec['parts']:
        if p not in names:
            sys.exit(f"missing ROM part {p} in {zippath}")
        blobs.append(z.read(names[p]))
    n = len(blobs[0])
    for b in blobs:
        if len(b) != n:
            sys.exit("ROM parts differ in size")
    out = bytearray()
    for i in range(n):
        for b in blobs:
            out.append(b[i])
    return bytes(out)

def check(img):
    """Score the image against what a 68k reset MUST look like."""
    sp = int.from_bytes(img[0:4], 'big')
    pc = int.from_bytes(img[4:8], 'big')
    ok = 0
    print(f"  reset SP = 0x{sp:08X}")
    print(f"  reset PC = 0x{pc:08X}")
    # SP should point into work RAM (0x400000-0x41FFFF), PC into ROM.
    if 0x400000 <= sp <= 0x420000:
        print("    SP lands in work RAM               OK"); ok += 1
    else:
        print("    SP does NOT land in work RAM       FAIL")
    if 0 < pc < len(img) and (pc & 1) == 0:
        print("    PC is even and inside the ROM      OK"); ok += 1
    else:
        print("    PC is not a sane ROM address       FAIL")
    words = [int.from_bytes(img[pc+2*i:pc+2*i+2], 'big') for i in range(8)]
    print("  first words at PC: " + " ".join(f"{w:04X}" for w in words))
    # A 68k program almost never starts with an odd/illegal opcode; 0xFFFF
    # and 0x0000 both indicate a wrong interleave.
    if words[0] not in (0x0000, 0xFFFF):
        print("    first opcode is not 0000/FFFF      OK"); ok += 1
    else:
        print("    first opcode is 0000/FFFF          FAIL")
    return ok

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set', choices=sorted(SETS))
    ap.add_argument('--zip')
    ap.add_argument('--out')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    spec = SETS[a.set]
    img = build(a.zip or f"roms/{a.set}.zip", spec)
    print(f"{a.set}: {spec['board']}, {len(spec['parts'])} parts -> {len(img)} bytes "
          f"({len(img)/1048576:.2f} MB)")
    if a.check:
        score = check(img)
        print(f"  score {score}/3")
        if score < 3:
            sys.exit(1)
    if a.out:
        with open(a.out, 'w') as f:
            for i in range(0, len(img), 2):
                f.write(f"{img[i]:02x}{img[i+1]:02x}\n")
        print(f"  wrote {a.out}")

main()
