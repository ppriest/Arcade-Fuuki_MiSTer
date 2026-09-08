# Fuuki core for MiSTer

MiSTer FPGA core for [Fuuki](https://en.wikipedia.org/wiki/Fuuki)'s FG-2 and FG-3 arcade
platforms, built with Quartus Prime 17.0.2 Lite for the DE10-nano.

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

Both boards share the same video hardware — the FI-002K sprite chip and FI-003K tilemap chip, with a 
Mitsubishi's M60067-0901FP. Reproducing those two custom video chips is the substance of
the project. FG-3 keeps FG-2's video architecture but substitutes a 32-bit CPU, an OPL4 for sound,
sprite tile banking, deeper tiles and a second work RAM.

Some links discussing the games and hardware:
* https://www.hardcoregaming101.net/series/asura-buster-blade/
* https://nicole.express/2025/a-very-fuuki-circuit-board.html

## History

* Arcade-Fuuki_20260907.rbf
  * **Beta release**
  * **FG-3 sound effects fixed.**

* Arcade-Fuuki_20260906.rbf
  * **Alpha release**
  * **Sound.** FG-2's Z80 with the YM2203 / YM3812 / OKI M6295 set, and FG-3's Z80 with the YMF278B — Psikyo's OPL4 PCM engine plus gtaylormb/opl3_fpga for the FM half. Asura games are buggy and sounds are silent or cut out.
  * HDMI rotation and Flip 180, vertical crop, integer scaling, CRT offset.
  * gogomile's title-cloud jitter is fixed: the raster register is 8 bits, not 9.

* Arcade-Fuuki_20260905.rbf
  * **Alpha release**
  * Games all run fine
  * No sound
  * Raster effects are rough in places
  * Includes fast DDR loading
  * No HDMI rotate/flip yet

## Installation

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and put them in `_Arcade/_Fuuki`
* Put the MAME merged or split ROMs in `games/mame`

FG-3 (Asura Blade / Asura Buster) needs **64MB or more SDRAM module**

## Status

**Runs on MiSTer, with sound.** All four parent sets boot and play on a DE10-nano
with 0.482 ns of setup slack on `clk_sys`.

What is built and running:

* **68000 and 68EC020 from one TG68K.C instance**
* **All three interrupts** — level 1 at scanline 248, level 3 vblank, level 5 on a programmable raster line — held until acknowledged, and nesting correctly.
* **FI-003K tilemaps** (`rtl/video/tilemap_line_engine.sv`): three layers, 16×16×4, 16×16×8 and 8×8×4, rendered per scanline. Every register the renderer reads is latched once per line, so a   raster interrupt can still move a layer mid-frame.
* **FI-002K sprites**: sprite RAM snapshotted once per frame (a real copy, not a bank swap), a candidate list built in vblank, then a per-scanline engine into a double-buffered 320-pixel line buffer. No whole-frame pixel buffer anywhere.
* **Compositor** with the bit-indexed pdrawgfx-style priority rule, and the backdrop as the last palette pen.
* **Fast ROM loading.**

Known issues:

* **One line of gogomile's title cloud scrolls when it should not** — a raster effect on layer 2.
  Firing the raster interrupt one or two lines early (an OSD switch) changes nothing, so it is not
  the band landing late.
* **gogomile's sound drops out on later stages, from stage 3 on** (reported, not yet measured).
* (Fixed) pbancho's attract-mode black bands ending partway across the screen were sprite-engine
  overrun, not a compositor fault; the sprite engine now prefetches the next sub-tile while drawing.

See `docs/ROADMAP.md` for the measurements behind each, and what has been ruled out.

### Todo

- [ ] gogomile's title-cloud raster line
- [ ] gogomile's stage-3 sound dropout
- [x] Sound: Z80, and the FG-2 chip set (YM2203, YM3812, OKI M6295)
- [x] Sound: OPL4 PCM and the FG-3 Z80 — built, and measured playing on MiSTer
- [x] Sound: the OPL4's FM half — [gtaylormb/opl3_fpga](https://github.com/gtaylormb/opl3_fpga),
      measured synthesising on Asura Blade
- [x] HDMI rotation and Flip 180, vertical crop, integer scaling, CRT offset
- [ ] Hiscore support
- [ ] The DIP Flip Screen in the renderer (both MAME drivers are marked inaccurate. Hidden in MRAs)

### Resource usage

Whole core, on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7, for the bitstream in `releases/`:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 12,761 (30%) | 41,910 |
| Registers | 17,947 | -- |
| Block memory bits | 2,748,161 (49%) | 5,662,720 |
| RAM blocks | 356 (64%) | 553 |
| DSP blocks | 43 (38%) | 112 |
| PLLs | 3 | 6 |

**+0.482 ns** of setup slack on `clk_sys` (85.909091 MHz).

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant, in the same manner as
[Arcade-Psikyo_MiSTer](https://github.com/ppriest/Arcade-Psikyo_MiSTer). The MAME drivers being
ported here, `fuukifg2.cpp` and `fuukifg3.cpp`, carry the author among their copyright holders, so
the reference and the port share an author.

What the assistant is held to, and what shows in the repository:

* Authentic screenshots and narrative from PCB here: https://nicole.express/2025/a-very-fuuki-circuit-board.html
* Hardware facts come from the MAME driver. Every ROM interleave, graphics
  layout, register map and timing constant is traced to a line of source or a measurement.
* Claims are checked before they are written down. The graphics layouts were rendered to PNG from
  real ROM data before any RTL used them; the CPU is diffed against a real MAME trace; the video
  pipeline is diffed against MAME's own screenshot.
* Where the reference and the hardware disagree, or where MAME's own comments disclaim accuracy,
  that is recorded as an open question rather than silently resolved.

`docs/LESSONS_LEARNED.md` carries the accumulated rules from the Psikyo project, and this core.

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
* **On-MiSTer instruments, driven over JTAG.** A trace ring readable through the video output,
  and `scripts/memdump.py`, which reads SDRAM, VRAM, palette, sprite RAM, video registers or work
  RAM back out of a running core with the CPU paused, so a fault can be read off the real machine
  rather than inferred.
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
| `releases` | `.mra` files, and the current `.rbf` |
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
