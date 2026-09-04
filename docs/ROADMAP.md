# Fuuki (FG-2 / FG-3) MiSTer Core — Roadmap

## Context

Goal: a DE10-nano MiSTer core for Fuuki arcade hardware, covering **both** board generations
emulated by MAME's `src/mame/fuuki/` — FG-2 (`fuukifg2.cpp`: Susume!/Go Go! Mile Smile,
Gyakuten!! Puzzle Bancho) and FG-3 (`fuukifg3.cpp`: Asura Blade, Asura Buster) — as a single
Quartus 17.0.2 SystemVerilog project producing **one `.rbf`** plus a `.mra` per supported game.
The board variant is selected at runtime from a mod byte in each `.mra`, exactly as
`Arcade-Psikyo_MiSTer` does for its two board families.

The two boards share the same video hardware. MAME models it as two shared devices —
`fuukispr.cpp` (FI-002K sprites) and `fuukitmap.cpp` (FI-003K tilemaps) — instantiated
identically by both drivers, differing only in per-board callbacks. That shared video ASIC pair
is the real engineering content here, and the reason one core is the right shape.

**This project reuses `Arcade-Psikyo_MiSTer` heavily.** That core is complete, runs on real
hardware, and was built by the same author against the same toolchain, framework and DE10-nano.
Its hard-won rules live in **[`docs/LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**, carried over
verbatim — read the relevant section before starting a subsystem, not after it misbehaves.
Several of its findings bind decisions in this document directly and are cited inline.

## Progress (kept current — last updated 2026-09-04)

**Phase 0 — repository setup: in progress.** Repo seeded from `MiSTer-devel/Template_MiSTer`
(kept as a `template` remote for upstream pulls), project renamed to the `Fuuki` revision,
Quartus-13 variants removed outside `sys/`, `.gitignore` written (ROMs never committed),
`LESSONS_LEARNED.md` carried over, `screen_rotate_two.sv` vendored. Nothing else built yet — no
core RTL, no `.mra`, no bitstream.

Hardware facts below are read directly from the MAME drivers, not recalled.

## Hardware reality (from the drivers, not assumption)

Two boards, one video architecture:

| | **FG-2** | **FG-3** |
|---|---|---|
| Games | Go Go!/Susume! Mile Smile, Gyakuten!! Puzzle Bancho | Asura Blade, Asura Buster |
| Years | 1995, 1996 | 1998, 2000/2001 |
| Main CPU | M68000 @ 16 MHz (32 MHz XTAL / 2) | M68EC020 @ 20 MHz (40 MHz XTAL / 2) |
| Sound CPU | Z80 @ 6 MHz (12 MHz / 2) | Z80 @ 6 MHz (12 MHz / 2) |
| Sound chips | YM2203 + YM3812 (both 28.640 MHz / 8 = 3.58 MHz) + OKI M6295 (32 MHz / 32 = 1 MHz) | YMF278B (OPL4) @ 33.8688 MHz |
| Sound comms | 8-bit latch + Z80 **NMI** | 16-byte **shared RAM** (68020 `$903fe0`, Z80 `$7ff0`) |
| Video chips | FI-002K (GA2), FI-003K (GA3), M60067-0901FP (GA1) | same |
| Sprite tile bank | none | 4 banks via `$a00000`, buffered 2 frames |
| Sprite buffering | drawn from live spriteram | buffered **2 frames** (`memcpy` chain) |
| Layer 0 tiles | 16x16x**4** | 16x16x**8** |
| Layer 1 tiles | 16x16x8 (granularity 16) | 16x16x8 |
| Layer 2 tiles | 8x8x4 | 8x8x4 |
| Transparent pens (L0/L1/L2) | `0x0f` / `0xff` / `0x0f` | `0xff` / `0xff` / `0x0f` |
| Tilemap colour | as-is | layers 0,1: `colour >>= 4` |

Everything else — VRAM layout, video registers, the sprite record format, the priority scheme,
the three interrupts — is identical.

### Main CPU memory map

Common to both boards unless marked:

| Address | Size | Contents |
|---|---|---|
| `000000-0fffff` (FG-2) / `000000-1fffff` (FG-3) | 1 / 2 MB | Program ROM |
| `400000-40ffff` | 64 KB | Work RAM |
| `410000-41ffff` | 64 KB | Work RAM — **FG-3 only** (used by asurabus) |
| `500000-507fff` | 32 KB | Tilemap VRAM — four 8 KB banks (see below) |
| `508000-517fff` | 64 KB | **FG-3 only** — "more tilemap, or linescroll? Seems to be empty all of the time" (MAME) |
| `600000-601fff` | 8 KB | Sprite RAM (FG-2: mirrored at `+0x8000`) |
| `700000-703fff` | 16 KB | Palette RAM — 8192 x xRGB-555 |
| `800000` | word | SYSTEM inputs (coins, service, start) |
| `810000` | word | P1/P2 inputs |
| `880000` | word | DSW (FG-2: the only DIP port) |
| `890000` | word | **FG-3 only** — second DIP port |
| `8a0001` | byte | **FG-2 only** — sound command latch (write triggers Z80 NMI) |
| `8c0000-8effff` | — | Video registers (see below) |
| `903fe0-903fff` | 32 B | **FG-3 only** — shared RAM with Z80 (`umask32(0x00ff00ff)`, 16 usable bytes) |
| `a00000` | long | **FG-3 only** — sprite tile bank |

FG-3 reads its input/DIP ports as 16-bit values on a 32-bit bus (`lr16(...)`), and its sprite RAM
through explicit 16-bit accessors. **Decode word AND long accesses**, not just byte-aligned ones —
Psikyo lost real time to a sound latch that only decoded exact byte addresses, so word and long
writes silently vanished (LESSONS_LEARNED / its ROADMAP "Fix sound", root cause 1).

### Tilemap VRAM (`500000-507fff`)

Four 8 KB banks, each 64x32 tiles x 2 words:

| Bank | Offset | Layer |
|---|---|---|
| 0 | `0000-1fff` | Layer 0 |
| 1 | `2000-3fff` | Layer 1 |
| 2 | `4000-5fff` | Layer 2, buffer A |
| 3 | `6000-7fff` | Layer 2, buffer B |

Layer 2 is **double-buffered in VRAM**: which bank is displayed is selected by `vregs[0x1e] & 0x40`.
Per tile, two words:

```
0.w  Code
2.w  bit 7    Flip Y
     bit 6    Flip X
     bits 5-0 Colour
```

### Video registers (`8c0000`)

```
8c0000 + 0x00.w   Layer 0 Scroll Y        0x0c.w  Layers Y offset
         0x02.w   Layer 0 Scroll X        0x0e.w  Layers X offset
         0x04.w   Layer 1 Scroll Y        0x1c.w  Raster IRQ (level 5) scanline
         0x06.w   Layer 1 Scroll X        0x1e.w  bit 0  Flip screen
         0x08.w   Layer 2 Scroll Y                bit 6  Layer 2 VRAM buffer select
         0x0a.w   Layer 2 Scroll X
8c0000 + 0x10000  Flipscreen-related (unknown)
8c0000 + 0x20000  Priority — low 4 bits index the layer-order table
```

Layer 0/1 scroll has the global X/Y offset added; layer 2 does not. Per-board constants come from
`set_xoffs`/`set_yoffs`/`set_layer2_xoffs` in each driver's machine config, and differ between
FG-2 and FG-3 (and between normal and flipped screen).

**The layer order is a table lookup, not independent enable bits** — MAME says so explicitly
("It's not independent bits causing layers to switch, that wouldn't make sense with 3 bits"):

| `priority & 0x0f` | front | middle | back |
|---|---|---|---|
| 0 | 0 | 1 | 2 |
| 1 | 0 | 2 | 1 |
| 2 | 1 | 0 | 2 |
| 3 | 1 | 2 | 0 |
| 4 | 2 | 0 | 1 |
| 5 | 2 | 1 | 0 |

Note MAME indexes a **6-entry** table with `priority & 0x0f`, so values 6-15 read out of bounds.
Whatever the real ASIC does for those values is unknown; pick a defined behaviour in RTL, document
it, and check whether any game actually writes them.

### Sprites

1024 records of 4 words in an 8 KB RAM. Up to 16x16 tiles of 16x16x4 pixels each, per-sprite zoom,
flip and priority:

```
0.w  bits 15-12  Number of tiles along X, minus 1
     bit  11     Flip X
     bit  10     1 = do not draw this sprite
     bits  9-0   X position, signed:  (v & 0x1ff) - (v & 0x200)
2.w  bits 15-12  Number of tiles along Y, minus 1
     bit  11     Flip Y
     bits  9-0   Y position, signed
4.w  bits 15-12  Zoom X   (0 = full size, 15 = half size)
     bits 11-8   Zoom Y
     bits  7-6   Priority vs. layers
     bits  5-0   Colour
6.w              Tile code   (FG-3: bits 15-14 = tile bank, bits 13-0 = code)
```

Zoom: `xzoom = 128 - 4 * zoomx`, giving 128 (full) down to 68 (about 53%). Tile placement is
`sx + (x * xzoom) / 8`. When both zoom fields are 0 MAME takes a separate non-zooming path; the
zoomed path deliberately scales by `512 * (xzoom + 8)` — the *next larger* integer step — "to avoid
holes". Reproduce that rounding rather than an exact ratio, or zoomed sprites grow seams.

**Draw order:** because both boards install a `colpri_cb`, MAME walks the list **backwards**
(`start = size-4; inc = -4`) "for pdrawgfx", so record 0 is drawn last and wins among equal
priorities. Do not infer the net ordering from the loop direction alone — Psikyo inverted its
sprite depth on exactly that reasoning, shipped it, and reverted it (LESSONS_LEARNED, "Read both
halves of a mechanism before changing it").

### Priority: bit-indexed, not a value compare

The three tilemap layers are drawn with priority codes **back = 1, middle = 2, front = 4**, ORed
into MAME's priority bitmap. Each sprite's 2-bit priority field selects a mask:

| Sprite priority | `pri_mask` | Meaning |
|---|---|---|
| 0 | `0x00` | Above all layers |
| 1 | `0xf0` | Behind the front layer |
| 2 | `0xfc` (`0xf0` OR `0xcc`) | Behind front + middle |
| 3 | `0xfe` (`0xf0` OR `0xcc` OR `0xaa`) | Behind all layers |

**The mask is bit-indexed by the priority-bitmap value at that pixel** (pdrawgfx convention: the
sprite pixel is suppressed when `(pri_mask >> pri_value) & 1`), **not** ANDed against it. This is
the single highest-risk detail in the whole video port: Psikyo shipped the value-AND version, which
let priority-1 sprites beat a layer unconditionally, and it took a live JTAG spriteram dump to find
(LESSONS_LEARNED, "Copy a driver's register expression including its operators"). Note its
corrected table also ended in `0xFE` — the same value that falls out of Fuuki's expression
naturally.

Backdrop is the **last palette pen**, `(0x800 * 4) - 1 = 0x1fff`, not pen 0.

### Interrupts

Three, all from the tilemap device, all `HOLD_LINE`:

| Level | Source | When |
|---|---|---|
| 1 | `level_1_irq_callback` | Scanline 248 (in vblank) |
| 3 | `vblank_irq_callback` | VBlank start |
| 5 | `raster_irq_callback` | Programmable scanline, from `vregs[0x1c]` |

`HOLD_LINE` means assert and hold until acknowledged. Psikyo's `maincpu.sv` already implements
exactly this pattern for a held autovectored IRQ, including the acknowledge-priority rule that a
one-clock testbench pulse hid for an entire project (LESSONS_LEARNED, "Ask of every stimulus
whether it is the shape the real system produces").

### Raster effects are a first-class requirement, not polish

Level 5 exists to let the game rewrite video registers mid-frame. MAME services it with
`screen().update_partial(vpos())` and lists the results as unfinished in **both** drivers' to-do
lists:

- fg2: *"Raster effects (level 5 interrupt is used for that). In pbancho they involve changing the
  vertical scroll value of the layers each scanline... In gogomile they weave the water backgrounds
  and do some parallax scrolling on later levels. partly done, could do with some tweaking"*
- fg3: *"Raster Effects are imperfect, bad frames when lots of new sprites."*
- both: *"The scroll values are generally wrong when flip screen is on and rasters are often
  incorrect"*

A per-scanline hardware renderer gets this class of effect **right by construction**, where MAME's
partial-update approximation does not. That makes accuracy here a genuine opportunity to exceed the
reference rather than merely match it — and it sets a hard architectural constraint: **every video
register must be sampled per scanline, live, never latched once per frame.**

The corollary from Psikyo is mechanical: any module feeding the compositor directly must consume at
`ce_pix`, and only a module rendering a frame ahead into a buffer may run at full clock
(LESSONS_LEARNED, "Prefer a hypothesis that predicts the number exactly" — a missing `ce_pix` port
rendered exactly 28 of 320 columns).

**Open question, per board: are sprites also per-scanline?** MAME draws them once, at the last
visible line, and says why: *"as we're likely framebuffered (sprites are delayed by 2-3 frames, at
least on FG3, and doing rasters on sprites causes glitches) we only draw the sprites when MAME wants
to draw the final screen line. Ideally we should framebuffer them instead."* FG-3 demonstrably
buffers spriteram by two frames in hardware. FG-2 has no such buffering in the driver. Design the
sprite engine so live-per-scanline vs. frame-buffered is a **per-board switch**, not a baked-in
assumption, and settle it against real games. If a game does drive per-scanline sprite effects, that
is behaviour MAME cannot currently show.

### Screen timing — must be chosen, not copied

**Neither driver calls `set_raw()`.** Both declare `set_refresh_hz(60)` and a visible area only:

| | Total | Visible |
|---|---|---|
| FG-2 | 320 x 256 | 320 x 240 |
| FG-3 | 512 x 256 | 320 x 240 |

So htotal/vtotal/sync widths are *not* available from MAME and must be derived from the PCB
crystals and standard arcade practice. FG-2's 28.640 MHz XTAL is 2 x 14.318181 MHz, the classic
arcade value, giving:

**Pixel clock 28.640 / 4 = 7.16 MHz, htotal 456, vtotal 262 = 59.92 Hz.**

**Decision taken: both boards use this same video timing.** FG-3's PCB parts list transcribes its
video crystal as 28.432 MHz, but that figure is not used — the two boards share a video ASIC pair,
and 28.6432 vs 28.432 is exactly the kind of digit that gets dropped in a transcribed parts list.
Treating them as one clock is both the more likely hardware truth and the simpler design.

Two consequences worth having deliberately:

- **One video timing module and one PLL for the whole core**, with no per-board timing switch,
  no second set of PLL ratios and no per-board `ce_pix` divider. The mod byte selects CPU mode,
  memory map and video *features* — not clocks.
- **The timing is identical to what Psikyo already runs** (14.318181 MHz screen XTAL, 456 x 262,
  59.92 Hz), so its `video_timing` module, PLL configuration and pixel-divide ratios transfer
  directly rather than being re-derived.

Level-1 IRQ firing at scanline 248 confirms vtotal > 248, consistent with 262. Derive the
clock-enable ratio exactly rather than rounding (LESSONS_LEARNED, "Derive the clock-enable ratio
exactly") — the tempting integer divides are meaningfully wrong.

## The memory constraint — the one big architectural decision

Real uncompressed ROM footprint per game, measured from the supplied sets (not estimated):

| Game | Total | Largest regions |
|---|---|---|
| pbancho | **9.4 MB** | 4 x 2 MB gfx |
| gogomile | **16.1 MB** | tiles_l1 8 MB, plus 5 x 2 MB |
| asurabld | **48.5 MB** | sprites 28 MB, tiles 16 MB, PCM 4 MB |
| asurabus | **56.5 MB** | sprites 32 MB, tiles 16 MB, PCM 4 MB |

The vendored `sdram.sv` this project inherits from Psikyo addresses `[24:1]` — **exactly 32 MB**,
the stock MiSTer SDRAM module.

**FG-2 fits comfortably. FG-3 does not fit at all.** asurabus needs 56.5 MB, so FG-3 requires a
**64 MB module at minimum** (leaving about 7 MB spare) and realistically the 128 MB module, plus
widening the controller's address path and row/bank/column split. That work is bounded and well
understood, but it must be scheduled, and it changes the core's hardware requirement for FG-3 users.

This is why the phase plan below puts FG-2 first: it is the smaller CPU, the smaller ROM, the
simpler sound, and it exercises the entire shared video engine — which is the actual work — without
blocking on the memory question.

DDRAM is **not** the escape hatch for the graphics path. MiSTer's own developer documentation
describes `DDRAM_*` as for "non-critical time purposes" with latency that "can be way longer" than
its ~20-cycle typical, and Psikyo measured this, pivoted off DDRAM, and recorded the whole analysis
(LESSONS_LEARNED, "Choose SDRAM over DDRAM for hard real-time fetch budgets";
`Arcade-Psikyo_MiSTer/docs/phase1_sdram_map.md`). **Decision taken: SDRAM, built on Psikyo's
interface.**

## Component reuse map

Everything vendored is copied in **untouched**, with a `PROVENANCE.md` beside it recording origin,
commit, licence and any integration notes. That is Psikyo's convention, and the reason its
"suspect your own integration before any vendored module" rule is affordable to follow.

| Function | Plan | Source |
|---|---|---|
| **M68000 (FG-2) and M68EC020 (FG-3)** | **One `TG68KdotC_Kernel`, mode-switched at runtime.** Its `CPU` port is `00`=68000, `01`=68010, `11`=68020, and the 68020-only features (`extAddr_Mode`, `MUL_Mode`, `DIV_Mode`, `BitField`, `VBR_Stackframe`) are all generics already set to "switchable with CPU". One instance, one bus wrapper, mod-byte selected. Its data bus is 16-bit in both modes, so the memory path does not change shape. | `Arcade-Psikyo_MiSTer/rtl/cpu/tg68k/` (TobiFlex/TG68K.C) |
| 68k bus wrapper | Port Psikyo's `maincpu.sv` — it instantiates the kernel **directly** (not the `TG68K.vhd` adapter, deliberately), owns DTACK, address decode and held-autovector IRQs, and its header records why each choice is what it is. | `Arcade-Psikyo_MiSTer/rtl/cpu/maincpu.sv` |
| Z80 (both boards) | **T80** | already vendored in `Arcade-Psikyo_MiSTer/rtl/cpu/t80/` |
| YM2203 (FG-2) | **jt03** (`jt12` repo, GPL-3.0) — `cen`, `irq_n`, separate and combined PSG+FM outputs | github.com/jotego/jt12 |
| YM3812 / OPL2 (FG-2) | **jtopl2** (`jtopl` repo, GPL-3.0) — `jtopl #(.OPL_TYPE(2))`, has `cen` and `irq_n`, which FG-2 needs for the Z80 INT line | github.com/jotego/jtopl |
| OKI M6295 (FG-2) | **jt6295** (GPL-3.0) — 18-bit `rom_addr` = 256 KB, matching gogomile's 4 x `0x40000` banking exactly | github.com/jotego/jt6295 |
| YMF278B / OPL4 (FG-3) | **No third-party core exists.** Psikyo has a from-scratch one: full bus protocol, timers/IRQ, and the 24-channel PCM wavetable engine working on hardware; **FM synthesis was milestone 2 and is not built**. Whether FG-3 needs the FM half must be measured, not assumed — Psikyo added `dbg_fm_keyon` instrumentation for exactly that question. | `Arcade-Psikyo_MiSTer/rtl/sound/opl4/` |
| SDRAM controller | **Psikyo's `psikyo_sdram_top.sv` stack** — burst-4 `sdram.sv` (Sorgelig, extended), multi-port arbiters, `sdram_download.sv` HPS wrapper, granule cache. Needs address widening for FG-3. | `Arcade-Psikyo_MiSTer/rtl/memory/` |
| **Video mixer / scaling** | **`sys/arcade_video.v`** — the MiSTer-devel standard (`video_mixer` + `video_freak`), already present in the template's `sys/`. | Template_MiSTer `sys/` |
| **Screen rotation** | **`screen_rotate_two.sv`** (Sorgelig) — vendored. Fuuki games are all ROT0 horizontal, so this is not needed for orientation, but it is the standard path and is wired the same way. | vendored to `rtl/video/` |
| Framework | **MiSTer-devel/Template_MiSTer**, tracked as a `template` remote so upstream fixes can be pulled | github.com/MiSTer-devel/Template_MiSTer |
| Tilemap + sprite engines (FI-002K / FI-003K) | **Custom RTL, no shortcut.** This is the project. | `fuukispr.cpp`, `fuukitmap.cpp` |
| DIPs / inputs | From each driver's `INPUT_PORTS_START`, per game. DIPs arrive as an **ioctl download, index 254**, not through the status word. | `fuukifg2.cpp`, `fuukifg3.cpp`; `Arcade-Psikyo_MiSTer/docs/mister_framework_notes.md` |
| High scores | `hiscore.v` — standard module, polish item | MiSTer-devel |

## Phased roadmap

**Phase 0 — repository and toolchain.** Template seeded, project renamed, ignore rules,
`LESSONS_LEARNED.md` carried over, staged-build script ported, ModelSim `work` library and
`modelsim.ini` conventions established. *In progress.*

**Phase 1 — CPU spike.** Bring `TG68KdotC_Kernel` up in **68000 mode** with Psikyo's `maincpu.sv`
wrapper, running real gogomile program ROM in ModelSim, then synthesize and check Fmax on the real
netlist. Psikyo measured 48.74 MHz for this core on speed-grade 7 and found all 50 worst-slack paths
inside it — **budget for the 68k to be the Fmax-limiting block** and confirm the number early rather
than discovering it after the video engine exists. Deliberately exercise the ISA extensions
depended on.
**Exit: the simulated boot trace matches MAME's boot trace** (see "Golden references" below), and
Fmax is known.

**Phase 2 — the renderer, FG-2, no sound.** *This is the priority and the bulk of the work.*
Sound is stubbed silent throughout; the sound CPU and chips come later.

1. SDRAM backend ported from Psikyo, with the ROM-download path and the `core_reset` /
   memory-reset split correct from day one (LESSONS_LEARNED, "Never hold the memory path in the
   core reset" — MiSTer holds `RESET` for the entire ROM download).
2. `.mra` for gogomile, proven **offline** against MAME's disassembly before any build
   ("Prove the interleave against MAME's disassembly offline, before building"). Note the region
   macros differ per region and per game: `ROM_LOAD16_BYTE`, `ROM_LOAD16_WORD_SWAP` and
   `ROM_LOAD32_WORD_SWAP` all appear here, and the map-digit rule is mechanical — check it, do not
   reason about it.
3. Video timing plus a per-scanline tilemap engine for one layer, live vreg sampling,
   `ce_pix`-correct.
4. The remaining two layers, layer-2 VRAM double buffering, the layer-order table.
5. Sprite engine: record walk, zoom/position, gfx fetch, pixel output, per-board buffering switch.
6. Compositor: bit-indexed priority resolve, backdrop = pen `0x1fff`, palette lookup.
7. Inputs and DIPs from `INPUT_PORTS_START`; `.mra` `<switches>` per game.

Exit: gogomile and pbancho boot and play correctly on real hardware, with raster effects
(pbancho's per-scanline vertical scroll, gogomile's water weave and title linescroll) visibly
correct — silently.

**Phase 3 — FG-2 sound.** Z80 plus latch/NMI, jt03, jtopl2 (IRQ to Z80 INT), jt6295 with 4-bank
OKI ROM. Psikyo's sound bring-up cost four separate transport root causes before audio worked;
its "Fix sound" narrative is the checklist.

**Phase 4 — FG-3.** Switch the CPU mode to `11`, add the second work RAM, second DIP port, shared
sound RAM, sprite tile bank and its 2-frame buffering, per-board tile depths and colour shifts.
Sound is the OPL4 core from Psikyo — with the open question of whether FM synthesis is needed.
**Gated on the memory decision below**, which must be settled before this phase starts.

**Phase 5 — polish.** CRT offset, hiscore, remaining clone sets and region variants, savestates
(Psikyo's `docs/savestates.md` is the feasibility study; the same TG68K/RAM/audio arguments apply).

## Verification strategy

**Simulation-first, and simulation-heavy.** Every component gets its own ModelSim testbench before
integration, and each integration step gets one too. JTAG (USB Blaster) is available for later
hardware bring-up, but it is the tool of last resort for questions simulation can answer more
cheaply. Psikyo's whole "When simulation passes and hardware fails" section exists because the
opposite order was tried.

Testbench discipline is not optional here — LESSONS_LEARNED's "Testbench discipline" section lists
seven distinct ways a testbench has already produced a confident wrong answer on this exact
toolchain. The ones that will bite first:

- `do @(posedge clk); while (signal);` — never `while (signal) @(posedge clk);`.
- Model registered RAM reads as registered (`rdata <= mem[addr]`), so a behavioural model cannot
  hide a missing wait state.
- Write preloaded vectors and tables **after** `$readmemh`, never before.
- Grep the log for `readmem` before touching RTL when a bench fails wholesale.
- Ask of every stimulus whether it is the shape the real system produces — a one-clock `vblank`
  pulse hid a real IRQ bug for an entire project.
- Write a smoke test (elaborate, run N cycles, check for X-propagation) before any functional test
  on a new top-level.

### Golden references from MAME

MAME boot **program traces** and **memory dumps** can be produced on demand, which changes what is
provable offline and should be exploited hard rather than treated as a fallback:

| Reference | Validates | Phase |
|---|---|---|
| Boot program trace (PC / bus cycles) | The CPU spike, end to end — diff the ModelSim trace against MAME's rather than eyeballing "it looks like it is running". Catches wrong interleave, wrong reset vector, wrong IRQ timing and wrong DTACK behaviour in one test. | 1 |
| Program ROM disassembly at known offsets | `.mra` interleave, offline, before any build. Score candidate interleave models against reconstructed known words. | 2 |
| VRAM / vregs / spriteram dumps at a known frame | Tilemap and sprite engines, without needing hardware: preload the dump, render one frame in sim, compare against MAME's output for that frame. | 2 |
| Palette RAM dump | Colour path and the backdrop-is-last-pen rule | 2 |

Two cautions from Psikyo, both learned expensively: a hardware-vs-image comparison **cannot detect a
wrong image** when both sides were built from the same byte-order assumption; and any test using
uniform or all-zero content is invariant under byte order and cannot catch endianness bugs at all.
Use real content.

### Other gates

- **Re-run any failing case with the real transport in place of behavioural models** before blaming
  synthesis. Psikyo had a protocol bug that every module-level sim passed and hardware failed,
  purely because a short-latency behavioural ROM model absorbed a duplicate request.
- **Every `.mra` gated on an XML well-formedness check before deploy.** A malformed comment once
  produced a black screen whose every symptom pointed at RTL.
- **Open `output_files/<rev>.sta.summary` on every build.** Quartus reports "Fitter was successful"
  on a design that grossly fails timing; Psikyo shipped an `.rbf` at -8.879 ns setup slack without
  noticing. Read the Fmax Summary first.
- **A/B against MAME** for zoom curve, priority and raster behaviour — with the caveat that MAME
  itself flags raster effects and flipped-screen scroll as wrong, so it is the reference for
  everything *except* the places its own comments disclaim.

## Repository setup

Dev repo: `D:\Arcade-Fuuki_MiSTer`, `origin` = github.com/ppriest/Arcade-Fuuki_MiSTer, seeded from
`MiSTer-devel/Template_MiSTer` (kept as a `template` remote for upstream pulls). ROMs live in
`roms/` and are **gitignored** — no ROM data is ever committed.

**Builds are staged, not run in-tree.** `scripts/build_staged.py` (to be ported from Psikyo)
snapshots HEAD into a git worktree at `build/` (gitignored) and runs the full Quartus flow there,
so the main tree stays editable during the compile and all Quartus scratch — `db/`,
`output_files/`, logs, the `.rbf` and `.sta.summary` — lands under `build/`. A dirty tree is
refused by default: the build is exactly HEAD. This exists because a Psikyo build once died
mid-Fitter when a project file was edited during the run, and the deploy step then verified the
*previous* build's stale `.rbf` as green.

Toolchain is Quartus Prime 17.0.2, per the
[MiSTer developer documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/).
Note `quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH` and must be invoked by full path,
and Quartus must never be launched wrapped in `nohup ... &`.

## Open items / decisions

1. **FG-3 memory: which SDRAM module?** asurabus needs 56.5 MB against a 32 MB stock module.
   Options: (a) require the 64 MB module for FG-3 — fits with about 7 MB spare, no headroom;
   (b) require the 128 MB module — comfortable, and the module most owners of large cores already
   have; (c) FG-2 only on stock hardware. Either (a) or (b) needs the controller's address path,
   row/bank/column split and arbiter widened. **This blocks Phase 4 and nothing earlier**, so it
   needs a decision before FG-3 work starts, not before Phase 2.
2. ~~**Screen timing**~~ **DECIDED 2026-09-04: both boards use FG-2's 28.640 MHz video crystal —
   7.16 MHz pixel clock, 456 x 262, 59.92 Hz, identical to Psikyo.** One timing module, one PLL, no
   per-board switch. FG-3's parts list transcribes 28.432 MHz; that figure is deliberately not used
   (see "Screen timing"). Revisit only if a real FG-3 board measurement contradicts it.
3. **Per-scanline sprites** — settle per board whether sprites are live or frame-buffered, and
   whether any game drives sprite raster effects that MAME cannot currently show.
4. **OPL4 FM synthesis** — unbuilt in the inherited core. Measure whether Asura Blade/Buster key on
   any FM channel before deciding to build milestone 2.
5. **Layer-order values 6-15** — MAME reads past the end of a 6-entry table. Choose and document a
   defined behaviour; check whether any game writes them.
6. **Flip screen** — both drivers state scroll values are wrong when flipped. The FPGA can be
   correct here, but the reference cannot be trusted to show what correct looks like.
7. **The `508000-517fff` region on FG-3** — MAME calls it "more tilemap, or linescroll? Seems to be
   empty all of the time". Verify it stays empty before treating it as plain RAM.
8. **Clone sets** — `gogomileo`, `pbanchoa`, `asurabusj`/`asurabusja`/`asurabusjr` all need their
   own `.mra`, built from their own `ROM_START` and DIP tables. Region encodings differ per game and
   are never assumed to match.
9. **`pbancho` layer-2 ROM** — MAME loads `60.rom3` into both `tiles_l0` and `tiles_l2` with the
   comment "?maybe?". Confirm before duplicating 2 MB in the SDRAM map.
