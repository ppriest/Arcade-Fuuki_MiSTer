# Fuuki core for MiSTer

MiSTer FPGA core for Fuuki's FG-2 and FG-3 arcade platforms, built with Quartus Prime 17.0.2 Lite
for the DE10-nano.

## Contents

- [History](#history)
- [Screenshots](#screenshots)
- [Installation](#installation)
- [Status](#status)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## Games

Supports the following games

| Name | Year | Board | Main CPU | Sound CPU | Sound chips | Notes |
|-|-|-|-|-|-|-|
| Susume! Mile Smile / Go Go! Mile Smile | 1995 | FG-2 | M68000 @ 16 MHz | Z80 @ 6 MHz | YM2203 + YM3812 + OKI M6295 | |
| Gyakuten!! Puzzle Bancho | 1996 | FG-2 | M68000 @ 16 MHz | Z80 @ 6 MHz | YM2203 + YM3812 + OKI M6295 | Japan only |
| Asura Blade - Sword of Dynasty | 1998 | FG-3 | M68EC020 @ 20 MHz | Z80 @ 6 MHz | YMF278B (OPL4) | Japan. Uses the OPL4's PCM+FM synthesis |
| Asura Buster - Eternal Warriors | 2000 | FG-3 | M68EC020 @ 20 MHz | Z80 @ 6 MHz | YMF278B (OPL4) | JP 2000, US 2001. PCM only |

Both boards share the same video hardware — the FI-002K sprite chip and FI-003K tilemap chip, with
Mitsubishi's M60067-0901FP alongside. Reproducing those two custom video chips is the
substance of the project. FG-3 keeps FG-2's video architecture but substitutes: a 32-bit CPU, an OPL4for sound, sprite tile banking, deeper tile depth, and a second work RAM.

## History

Nothing released yet — no `.rbf` has been built. See Status.

## Screenshots

## Installation

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and put them in `_Arcade/_Fuuki`, **keeping the
  `_alternatives/` folder alongside them**. Parent sets sit at
  the top level and clones live in `_alternatives/_<game>/`, per the
  [MRA documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/mra/), so the menu
  lists one entry per game rather than one per ROM revision
* Put the MAME merged or split ROMs in `games/mame`

FG-3 (Asura Blade / Asura Buster) needs **more than the stock 32 MB SDRAM module** — its ROM image
is 56.5 MB. FG-2 (Mile Smile / Puzzle Bancho) runs on a stock board.

## Status

**Pre-hardware.** The CPU and the whole video pipeline are built and verified in simulation
against MAME as the reference; nothing has been synthesized as a whole core, and no game has yet
run on a DE10-nano. Do not read the sections below as "working" — read them as "verified this far".

What is built and measured:

* **68000 and 68EC020 from one TG68K.C instance** (`rtl/cpu/maincpu.sv`). The kernel's `CPU` port
  picks the mode at runtime from the mod byte, so FG-2 and FG-3 share a CPU. Both clock enables
  are exact Bresenham ratios on `clk_sys` (176/945 = 16 MHz, 220/945 = 20 MHz), not rounded
  divides. gogomile's boot diffs **84 of 84 fetch addresses** against a real MAME trace.
* **All three interrupts** — level 1 at scanline 248, level 3 vblank, level 5 on a programmable
  raster line — held until acknowledged, and nesting correctly. The games *spin-wait* on flags
  their ISRs set, so a missing interrupt hangs rather than degrades.
* **FI-003K tilemaps** (`rtl/video/tilemap_line_engine.sv`): three layers, 16×16×4, 16×16×8 and
  8×8×4, per-scanline with live register sampling. Worst line 13–20% of the scanline budget per
  layer.
* **FI-002K sprites**: buffered sprite RAM (a real copy, not a bank swap), a once-per-frame
  candidate list built in vblank, then a per-scanline engine into a double-buffered 320-pixel line
  buffer. No whole-frame pixel buffer anywhere — that is the shape the hardware used and it is
  where the block RAM would otherwise go.
* **Compositor** with the bit-indexed pdrawgfx priority rule, and the backdrop as the last palette
  pen rather than pen 0.
* **SDRAM backend** (`rtl/memory/fuuki_sdram_top.sv`): every runtime ROM on the one physical chip,
  proved by a real HPS download and read-back through every client port against a
  command-decoding chip model.
* **The whole pipeline diffed against MAME.** `sim/video_tb/` composes a captured frame through
  the real RTL and compares it to MAME's screenshot of that same state.

Two findings worth stating because they shape the design:

* **Per-scanline rendering with live register sampling is mandatory, not stylistic.** gogomile
  raster-scrolls layer 2 into five parallax bands on its *title screen*, rewriting the scroll
  register four times a frame from the level-5 ISR. Each band's empirically best scroll matches a
  written value exactly. A renderer that samples scroll once per frame cannot draw that screen.
* **Asura Blade uses the OPL4's FM synthesis; Asura Buster does not.** Measured, not assumed:
  299 key-ons across three channels in five minutes of attract, with all six channel pairs in
  4-operator mode and audible Total Levels, versus zero key-ons for Buster. Because 4-op is an
  OPL3 feature, an OPL2 core cannot substitute.

Sound is deliberately deferred until the renderer is complete; none of it is wired yet.

### Todo

- [ ] Sound: Z80, and the FG-2 chip set (YM2203, YM3812, OKI M6295)
- [ ] Sound: OPL4 — vendor [gtaylormb/opl3_fpga](https://github.com/gtaylormb/opl3_fpga) for the FM
      half and put Psikyo's PCM wavetable engine on top
- [ ] Flip screen in the renderer (the port exists; MAME substitutes different offset constants
      when flipped, so it cannot be done as an output rotation)
- [ ] `.mra` files for every set, including the clones
- [ ] First whole-core synthesis, timing closure, and a bitstream
- [ ] Hardware bring-up on a DE10-nano
- [ ] Hiscore support (`hiscore.v`); all four parent sets have `hiscore.dat` entries in work RAM
- [ ] CRT offset, and wire `video_freak` for crop/integer scaling
- [ ] **SDRAM: widen the controller past 32 MB for FG-3.** asurabus needs 56.5 MB. The target is
      the **128 MB** module — the data fits 64 MB naturally, but 128 MB is the module people
      actually have. FG-2's largest set is 16.1 MB and runs on a stock 32 MB module
- [ ] Replay the captured video-register write log per scanline in `sim/video_tb/`, so
      raster-scrolled layers can be diffed properly

### Resource usage

**No whole-core build exists yet, so there are no core-wide numbers.** The one measured data point
is the CPU standalone (`rtl/cpu/synth_check/`), on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7:

| resource | `maincpu` + TG68K.C | available |
| --- | --- | --- |
| Logic (ALMs) | 2,828 (7%) | 41,910 |
| Registers | 1,463 | -- |
| Block memory bits | 1,024 (<1%) | 5,662,720 |
| DSP blocks | 6 (5%) | 112 |

Raw Fmax for that block is **44.25 MHz** against an 85.909091 MHz clock — the 68k is the
Fmax-limiting block, as expected. It closes at **+0.927 ns** with three audited constraints in
`Fuuki.sdc`, each carrying its justification: a kernel-internal multicycle bounded by the clock
enable, a false path on the static board select, and a multicycle stating what `maincpu.sv`'s
phase counter already assumes.

Block RAM is the resource to watch rather than logic. FG-3 needs ~280 KB of on-chip RAM for work
RAM, VRAM, palette, sprite RAM and its snapshots, against 691 KB on the device — before line
buffers and caches.

## AI Attestation

*Draft — to be replaced with the author's own account.*

This core is being developed with heavy use of a frontier coding assistant, in the same manner as
[Arcade-Psikyo_MiSTer](https://github.com/ppriest/Arcade-Psikyo_MiSTer). The MAME drivers being
ported here, `fuukifg2.cpp` and `fuukifg3.cpp`, carry the author among their copyright holders, so
the reference and the port share an author.

What the assistant is held to, and what shows in the repository:

* Hardware facts come from the MAME driver, not from recall. Every ROM interleave, graphics
  layout, register map and timing constant is traced to a line of source or a measurement.
* Claims are checked before they are written down. The graphics layouts were rendered to PNG from
  real ROM data before any RTL used them; the CPU is diffed against a real MAME trace; the video
  pipeline is diffed against MAME's own screenshot.
* Where the reference and the hardware disagree, or where MAME's own comments disclaim accuracy,
  that is recorded as an open question rather than silently resolved.

`docs/LESSONS_LEARNED.md` carries the accumulated rules from the Psikyo project, and this core has
already added entries of its own.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter (both Fuuki drivers flag raster effects and flipped-screen scroll as imperfect).

* **The `sim/` suite** — a ModelSim testbench for every project-authored block: the CPU bus
  wrapper, video timing, video registers, both tilemap and sprite pipelines, the compositor, the
  line buffers, and the full SDRAM backend with its arbiter and bridges. Plus integration benches
  that run the whole video pipeline against the real SDRAM controller and a command-decoding chip
  model.
* **Ground truth captured from MAME automatically.** `scripts/mame_capture.py` drives MAME
  headlessly over its Lua interface and dumps every region the video hardware reads — VRAM, sprite
  RAM, palette, video registers, work RAM — plus the screenshot MAME rendered from exactly that
  state, and optionally a log of every video-register write tagged with the raster line in force.
  That makes "compare against MAME" a single command rather than a hand-driven debugger session.
* **Offline proofs before building.** ROM interleaves are scored against MAME's disassembly, and
  graphics layouts rendered to PNG, before any RTL depends on them.
* Regression tests are written for every bug found, including the ones that turned out to be
  testbench faults.

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for
  - the [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework this project
    is seeded from
  - the SDRAM controller (`sdram.sv`, vendored via
    [Arcade-Jackal_MiSTer](https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer) and extended here
    to burst-4 reads)
  - the screen-rotation module (`screen_rotate_two.sv`, from
    [Arcade-SKNS_MiSTer](https://github.com/MiSTer-devel/Arcade-SKNS_MiSTer))
- The **MAMEdev team** — in particular **Luca Elia**, **David Haywood** and my own earlier work —
  for [MAME](https://github.com/mamedev/mame)'s `fuukifg2.cpp`, `fuukifg3.cpp`, `fuukispr.cpp` and
  `fuukitmap.cpp`, the reference this core's memory maps, video timing and sprite/tilemap
  semantics are verified against.
- **Tobias Gubener** ([TobiFlex](https://github.com/TobiFlex)) for
  [TG68K.C](https://github.com/TobiFlex/TG68K.C), serving as both the 68000 and the 68EC020.
- **Daniel Wallner** for the **T80** Z80 core, vendored via
  [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) and maintained since by MikeJ and the
  MiSTer-devel community.
- **Greg Taylor** ([gtaylormb](https://github.com/gtaylormb)) for
  [opl3_fpga](https://github.com/gtaylormb/opl3_fpga), a reverse-engineered YMF262 (OPL3) — the FM
  half of the OPL4 that Asura Blade needs.
- **Jose Tejada** ([@jotego](https://github.com/jotego)) for the JTFRAME sound cores —
  [jt03](https://github.com/jotego/jt12) (YM2203),
  [jtopl2](https://github.com/jotego/jtopl) (YM3812) and
  [jt6295](https://github.com/jotego/jt6295) (OKI M6295), the FG-2 sound section.
- **Aaron Giles** for [ymfm](https://github.com/aaronsgiles/ymfm), the behavioural reference the
  OPL4 work is checked against.
- **Alan Steremberg** and **Jim Gregory** ([JimmyStones](https://github.com/JimmyStones)) for
  [Hiscores_MiSTer](https://github.com/JimmyStones/Hiscores_MiSTer), with per-game configuration
  from MAME's own
  [hiscore.dat](https://github.com/mamedev/mame/blob/master/plugins/hiscore/hiscore.dat).
- **I Beceri Videoludici** ([rmonic79](https://github.com/rmonic79)) for CRT Offset.
- **Arcade-Psikyo_MiSTer**, the completed core this project reuses the CPU, SDRAM stack and OPL4
  PCM engine from, and inherits its `LESSONS_LEARNED.md` from.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source |
| `releases` | `.mra` files, and `.rbf` builds once any are published |
| `docs` | design notes and hard-won debugging lessons |
| `sim` | ModelSim testbenches |
| `scripts` | capture/verification tooling (see [`scripts/README.md`](scripts/README.md)) |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL v3 (see `LICENSE`). Imported components keep their own licences and are GPLv3-compatible:
TG68K.C (LGPLv3+), T80, the adapted SDR SDRAM controller (Sorgelig, GPL-3.0-or-later),
`screen_rotate_two.sv` (Sorgelig, GPLv2), the MiSTer framework in `sys/`, opl3_fpga (LGPL-3.0),
and the jotego JTFRAME cores (GPLv3).

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
