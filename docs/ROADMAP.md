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

## Progress (kept current)

**All four parent sets run on hardware, without sound.** Mile Smile and Puzzle Bancho (FG-2) and
Asura Blade and Asura Buster (FG-3) boot and play on a DE10-nano from one bitstream, the board
selected by the `.mra` mod byte. `releases/Arcade-Fuuki_20260905.rbf` is that build: timing met on
every clock, `clk_sys` setup slack +0.482 ns, 30% of the ALMs and 64% of the RAM blocks.

### Built and running

| Subsystem | State |
|---|---|
| CPU (`rtl/cpu/maincpu.sv`) | One `TG68KdotC_Kernel` as both 68000 and 68EC020, mode from the mod byte. Exact Bresenham clock enables. gogomile's boot matches MAME's trace 84/84 fetches. |
| Interrupts | All three, held until acknowledged, nesting. Acknowledge clears the level the kernel drives on A3..A1, not the highest pending. |
| Tilemaps (`tilemap_line_engine.sv`) | Three layers, per scanline, all three tile formats and both boards' depths, colour shifts and transparent pens. |
| Sprites (`sprite_line_*.sv`) | Sprite RAM snapshotted once per frame, a candidate list built in vblank, a per-scanline engine into a double-buffered line buffer. Zoom, flip, multi-tile sprites, FG-3's tile bank. |
| Compositor | Bit-indexed pdrawgfx priority, backdrop = last pen. |
| Video registers | Latched once per scanline at hblank, so raster effects still work while nothing races the CPU's writes. |
| SDRAM (`fuuki_sdram_top.sv`) | 26-bit addressing; FG-3's 56.5 MB map fits and FG-2 maps identically on a stock 32 MB module. Verified on hardware with known patterns, 256/256 exact. |
| Fast ROM load (`rom_loader.sv`) | `.mra` index 0 goes straight to DDR3 and is copied to SDRAM with the core in reset. Asura Blade is playable ~14 s after launch against ~75 s through the ioctl path. |
| `.mra` files | All nine sets, parents and clones, each proved byte-for-byte against `ROM_START`. |

### Not built

Sound of any kind (Phase 3 and the OPL4 work below), flip screen in the renderer, hiscore support,
and HDMI rotation — `screen_rotate_two.sv` is vendored but not wired, and DDR3 now belongs to the
ROM loader, so its pins must be muxed on the loader's busy flag before the rotator can have them.

FG-3's Z80 handshake is a **stub**: `rtl/fuuki_core.sv` plays the sound CPU's side of the shared-RAM
protocol read out of `srom.u7`, because asurabld's boot spins until it sees `0xCD`. It must go when
the real Z80 lands.

### Open video faults, and where the investigation stands

**gogomile's title-cloud jitter is fixed.** The register at `0x1c` is effectively 8 bits: MAME's
`time_until_pos()` reduces it modulo the driver's 256-line screen (`set_size(320, 256)` /
`set_size(512, 256)`), so the game's parked `0xFFFE` fires on line 254, in vblank. The RTL was
reducing modulo its own 262-line frame, which put that interrupt on line 34, in the picture; the
captured register log shows the clouds are a five-band layer-2 X-scroll chain whose `0xFFFE` step
writes the top band's scroll and restarts the chain, so it ran mid-frame and only every other
frame's chain started from line 29. `vregs.sv` now takes the low byte. Confirmed on hardware.

Two hypotheses were tried and dropped on the way: rendering the tilemaps one line ahead instead of
two (broke both games — the render window is too short, see the note in `rtl/fuuki_core.sv`), and
a one-shot interrupt armed per write — dropped on reading `fuukitmap.cpp`, not on hardware:
`vregs_w` schedules the raster timer with a frame-length period and the callback re-arms it, so
MAME fires it every frame the value stands, as the comparator does.

**Still open, both on the current bitstream:**

- **One line of gogomile's title cloud moves with the wrong band**, and **pbancho's bottom strip
  shows layer fragments where MAME draws black.** By analysis the band a raster ISR's write lands
  on is two lines below MAME's: IRQ5 fires at the hblank of line N, the write is caught by the
  per-line latch at the next hblank and rendered two lines ahead, so it first shows on N+3 where
  MAME's partial update applies it from N+1. The `Raster IRQ lead` OSD switch (page 1;
  `cfg.py --set lead=N`) fires IRQ5 one or two lines early to move that band without a rebuild.
  **Leads 1 and 2 changed nothing on the screen** — the stray line is in the same place at all
  three settings — so it is not the band boundary landing late. Whatever it is happens at the
  boundary wherever the boundary falls: the first line after a scroll change. Not pursued further
  yet.
- **The credits text sits one line lower than in MAME**, its bottom row lost off the picture.
  Reported on hardware, unexplained. What has been measured against it:
  - the framing is exact — the `Line markers` switch draws lines 0 and 239 and both sit on the
    first and last visible rows, so the visible window is not shifted;
  - each line buffer is displayed on the line it was rendered for — the probe's `lb_*_delta`
    fields (fuuki_core.sv, "LINE-BUFFER CHECK") read 0 for layer 1 and for the sprite buffer over
    hundreds of frames;
  - the sprite engine puts record row `sy` on display line `sy` in `sim/sprite_tb`, which captures
    by display `vcnt`, as `fuukispr.cpp` does.
  What has not been measured is the sprite rows on hardware against the sprite RAM at the same
  instant; the `linecap` dump region (below) plus a sprite RAM dump is the check.

**Instruments added for this**, all in the current bitstream: the line-buffer row-tag check on the
probe (`read_issp.tcl`: `lb_tm1_delta`, `lb_spr_delta`, and saturating `lb_*_bad` counters); dump
region 6 `linecap`, the compositor's inputs on every displayed line (layers 0-2 at x=160, first
opaque sprite x), 4 pages via `memdump.py linecap 0 4`; and the two OSD switches above.

**Do not run `memdump.py` while Quartus is compiling.** Two `KERNEL_SECURITY_CHECK_FAILURE`
bugchecks (0x139, corrupted kernel list entry) at 12:20 and 12:27 on 2026-09-06, both while the
dump loop was cycling the USB-Blaster with a compile running on the same machine; the
combination had not been used before and the dumps had run clean without it. Unproven as the
cause, but the two are not to be overlapped again until it is.

Sprite faults found and fixed on hardware are recorded in
[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) rather than here; the short version is that a signed
comparison written with one unsigned operand made tall sprites repeat a row down the screen, and a
16.16 accumulator one bit too narrow made zoomed sprites sample only a quarter of each tile.

### Verification state

Simulation covers every project-authored block, and `sim/sdram_tb` exercises the whole memory
backend against a command-decoding chip model. Two gaps worth knowing before trusting a number:

- **`sim/video_tb`'s frame-versus-MAME comparison is currently broken** — it renders tilemaps blank
  on both boards while hardware draws them correctly. Until that is repaired, the frame-match
  percentage is not evidence of anything.
- Hardware questions are answered with the on-chip instruments instead: a trace ring readable
  through the video output, and `scripts/memdump.py`, which reads any CPU-visible memory back out
  of a running core with the CPU paused.

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
| Sprite tile bank | none | 4 banks via `$a00000` |
| Sprite buffering (in MAME) | drawn from live spriteram | buffered 2 frames (`memcpy` chain) |
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

**Draw order: the highest-numbered record is drawn on top, established on hardware.** Reading
`fuukispr.cpp` suggests the opposite — both boards install a `colpri_cb`, so MAME walks the list
backwards (`start = size-4; inc = -4`) "for pdrawgfx", which would put record 0 on top. Built that
way, asurabld drew its high-score table, its in-game sprites and its character-name flashes
wrongly, and reversing the order fixed all three. **The discrepancy with the driver is not
explained.** Do not restore the driver's apparent order without re-running that comparison on
hardware.

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

A per-scanline hardware renderer can get this class of effect right where MAME's partial-update
approximation does not, which makes accuracy here an opportunity to exceed the reference rather
than merely match it. It is not free, though — two raster faults are still open (see "Progress"),
so treat this as the goal rather than a property already achieved.

The architectural constraint it sets is hard: **every video register the renderer reads must be
sampled per scanline, never once per frame.** In this core they are latched once per line at
hblank, which is per-scanline sampling with a defined sampling point — what a raster interrupt's
write can be timed against — rather than the engines reading live registers at whatever moment
their line buffer happened to become ready.

The corollary from Psikyo is mechanical: any module feeding the compositor directly must consume at
`ce_pix`; only a module rendering *ahead* into a buffer may run at full clock
(LESSONS_LEARNED, "Prefer a hypothesis that predicts the number exactly" — a missing `ce_pix` port
rendered exactly 28 of 320 columns).

## Sprite rendering architecture — buffered sprite RAM, per-scanline, no frame buffer

**Decided.** Sprites are rendered **per scanline into a line buffer**, from a **buffered copy of
sprite RAM**. There is no whole-frame pixel buffer anywhere in this design.

This is the shape real arcade hardware used, the shape the rest of the MiSTer ecosystem uses
(JTFRAME's `JTFRAME_LF_BUFFER`, including `JTFRAME_LF_ZOOM` for zoomed sprites) — and, importantly,
it is where `Arcade-Psikyo_MiSTer` **ended up**, not where it started. Psikyo shipped a whole-frame
sprite buffer first and **retired it on 2026-08-30**. Its `sprite_frame_buffer.sv` survives in that
tree only as the golden reference for the line path's differential testbench. Do not resurrect it,
and treat any older Psikyo prose describing "renders a full frame ahead" as superseded.

### The three pieces

1. **Snapshotted sprite RAM.** The CPU sees one persistent RAM; its contents are **copied** into a
   snapshot at the frame boundary, and the renderer reads only the frozen copy. A swap is not a
   copy — ping-pong banks give two-frame-stale reads for any record the CPU does not rewrite every
   frame (LESSONS_LEARNED, "A swap is not a copy"). Fuuki's copy is 4096 words.

   **One generation, both boards.** MAME buffers FG-3's sprites two frames and FG-2's not at all;
   this core snapshots once for both. FG-2 rendering from the live RAM was wrong — the candidate
   list froze the display *list* while each scanline still re-read records the game was
   rewriting — and FG-3's second generation is deliberately not modelled, because the lag MAME
   shows may be interrupt timing rather than hardware, and one snapshot is what a still frame can
   actually verify.

2. **A once-per-frame candidate list.** Built during vblank: scan the sprite records, decode them,
   coarsely reject any whose bounding box misses the screen, and store the survivors — position,
   Y extent and the raw record. **This is the difference between a line renderer that works and one
   that does not**: it collapses the per-line cost to one cycle per candidate plus real rendering
   work, where re-walking every record per line burns the line budget before drawing a pixel. The
   per-line test stays deliberately coarse; the engine re-does the exact per-sub-tile-row maths on
   every hit, so a conservative false hit costs cycles, never a wrong pixel.

3. **A double-buffered 320-pixel line buffer.** Per scanline: swap banks, clear the render bank
   (320 cycles), then render the *next* line into it while the other bank is displayed. The clear
   is a separate pass rather than clear-on-read, because read and clear would hit the same address
   in the same cycle and inferred RAM read-during-write behaviour is not something to depend on.

### Budgets (same video timing as Psikyo, so these transfer)

| Quantity | Value |
|---|---|
| Cycles per line | htotal 456 x 12 = **5,472 clk** |
| Line-buffer clear | 320 clk (6% of the line) |
| Vblank | (262 - 240) = 22 lines x 5,472 = **120,384 clk** |
| Candidate-list build | 1024 records x ~9 cycles = **~9.2K clk** — about 8% of vblank |

Comfortable, but note Fuuki's worst case is **larger than Psikyo's**: sprites are up to 16 x 16
tiles (256 sub-tiles) against Psikyo's 8 x 8, so a single large sprite costs proportionally more per
line. Budget the engine against a worst-case list, not an average one — Psikyo left whole-frame
sprite throughput unbudgeted and paid for it.

### The trap carried forward

**The line-start pulse must hard-resync the engine, not be consumed only when idle.** Psikyo's
engine consumed `line_start` in `S_IDLE` only, so an engine still busy at a line boundary **ate
the pulse**, finished the previous line's sprites into the freshly swapped bank, then idled a full
line. One overrun corrupted every line below it — the signature being *correct at the top,
degrading downward*. The fix: a raw per-line tick aborts rendering immediately, drains any
in-flight memory request per the req/valid contract during the buffer's clear, and starts the next
line clean, so an overrun clips at worst the tail sprites of one line and raises a counted event.

Psikyo's decode and render stages are reusable as-is in shape — record decode, position transform,
zoom LUT, sub-tile step, zoom source index, tile row decode — with Fuuki's own record format and
zoom curve substituted. Note Fuuki has **no `spritelut` indirection**: the tile code addresses
graphics directly (FG-3 adding a 2-bit bank lookup), which removes one fetch stage and one SDRAM
client from Psikyo's pipeline.

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

**FG-2 fits comfortably. FG-3 does not fit at all**, so the address path was widened to 26 bits
end to end and the controller now drives byte-address bit 25 onto A9 at column time — the 64 MB
layout of the 128 MB module's first chip. A 32 MB chip ignores A9, so FG-2 maps identically on
either module and only FG-3 needs the upgrade. Done and running; the map is in "Open items" below.

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
| YMF278B / OPL4 — PCM half (FG-3) | Psikyo's from-scratch core: full bus protocol, timers/IRQ and the 24-channel PCM wavetable engine, working on hardware. The **timers are load-bearing on their own** — both games hammer FM register `0x04` ~35,000 times per 5 minutes as the sound driver's sequencer heartbeat, whether or not they use FM voices. | `Arcade-Psikyo_MiSTer/rtl/sound/opl4/` |
| YMF278B / OPL4 — FM half (FG-3) | **DECIDED: vendor `gtaylormb/opl3_fpga`** — a reverse-engineered SystemVerilog YMF262 (OPL3), LGPL-3.0. Required because Asura Blade drives three 4-operator voices (measured, open item 4), and 4-op is an OPL3 feature that jtopl2/OPL2 cannot provide. See "OPL4: an OPL3 core under Psikyo's PCM engine". | github.com/gtaylormb/opl3_fpga |
| SDRAM controller | **Ported from Psikyo** — burst-4 `sdram.sv` (Sorgelig, extended), multi-port arbiters, `sdram_download.sv` HPS wrapper, granule cache. Widened to 26 bits here for FG-3. Done. | `Arcade-Psikyo_MiSTer/rtl/memory/` |
| **Video mixer / scaling** | **`sys/arcade_video.v`** — the MiSTer-devel standard (`video_mixer` + `video_freak`), already present in the template's `sys/`. | Template_MiSTer `sys/` |
| **Screen rotation** | **`screen_rotate_two.sv`** (Sorgelig) -- vendored, **not wired**. A TAP on the video output, not a filter: analog keeps the native raster while a rotated copy goes to DDR3 for the HDMI framebuffer. Fuuki is ROT0, so this serves rotated displays rather than correcting orientation. DDR3 now belongs to the ROM loader, so the pins must be muxed on its busy flag first. See "Output chain". | vendored to `rtl/video/` |
| Framework | **MiSTer-devel/Template_MiSTer**, tracked as a `template` remote so upstream fixes can be pulled | github.com/MiSTer-devel/Template_MiSTer |
| Tilemap + sprite engines (FI-002K / FI-003K) | **Custom RTL, no shortcut.** This is the project. | `fuukispr.cpp`, `fuukitmap.cpp` |
| Sprite pipeline *shape* | Psikyo's per-scanline path is the template: buffered sprite RAM, a once-per-frame candidate list, a per-scanline engine, a double-buffered line buffer, plus the reusable decode stages (record decode, position transform, zoom LUT, sub-tile step, zoom source index, tile row decode). Fuuki's record format, zoom curve and depth order are substituted; the `spritelut` stage is dropped entirely. | `Arcade-Psikyo_MiSTer/rtl/video/sprite_*.sv`, `spriteram_dbuf.sv`, `docs/sprite_buffering.md` |
| DIPs / inputs | From each driver's `INPUT_PORTS_START`, per game. DIPs arrive as an **ioctl download, index 254**, not through the status word. | `fuukifg2.cpp`, `fuukifg3.cpp`; `Arcade-Psikyo_MiSTer/docs/mister_framework_notes.md` |
| High scores | **`hiscore.v`** (Hiscores_MiSTer, GPLv3) -- vendored from the Psikyo tree, proven on hardware. All four parent sets have `hiscore.dat` entries, all in work RAM. See "High scores". | github.com/JimmyStones/Hiscores_MiSTer |
| Crop / integer scaling | **`sys/video_freak.sv`** -- present but NOT wrapped by `arcade_video.v`; instantiate explicitly if those OSD options are wanted | Template_MiSTer `sys/` |

## Phased roadmap

Phases 0 to 2 and 4 are done: the toolchain, the CPU, the whole renderer, the SDRAM backend, the
`.mra` files and both boards running on hardware. What is left, in the order it makes sense to do
it:

**Finish the raster path.** The two open video faults above,
then flip screen in the tilemap and sprite engines. Flip is a game feature, not an output
transform: MAME substitutes different offset constants when flipped and recomputes every sprite
position, so the flipped image is not a rotation of the unflipped one.

**FG-2 sound.** Z80 plus latch/NMI, jt03, jtopl2 (IRQ to the Z80's INT), jt6295 with the 4-bank OKI
ROM. Psikyo's sound bring-up cost four separate transport root causes before audio worked; its
"Fix sound" narrative is the checklist.

**FG-3 sound.** The OPL4, built as described below, and the real Z80 in place of the shared-RAM
handshake stub in `rtl/fuuki_core.sv`.

**Output chain and polish.** Hiscores, CRT offset and `video_freak`, then HDMI rotation once DDR3
is shared with the ROM loader. Then the remaining clone sets and region variants, and savestates
(Psikyo's `docs/savestates.md` is the feasibility study; the same TG68K/RAM/audio arguments apply).

**Repair `sim/video_tb`.** It renders tilemaps blank on both boards, so the offline
frame-versus-MAME comparison — the cheapest objective check this project has for exactly the
raster questions still open — cannot currently be believed.

## OPL4: an OPL3 core under Psikyo's PCM engine

**Decided.** The YMF278B is assembled from two independently sourced halves rather than written
from scratch:

| Half | Source | State |
|---|---|---|
| **FM (OPL3 / YMF262)** | vendor **`gtaylormb/opl3_fpga`**, LGPL-3.0, SystemVerilog | to do |
| **PCM (24-channel wavetable), bus protocol, timers, status/ID** | Psikyo's `rtl/sound/opl4/`, working on hardware | port |

Why this split rather than finishing Psikyo's core: its FM half was "milestone 2" and was never
started, and writing an OPL3 is a serious piece of work — 18 channels, 4-operator mode, eight
waveforms, stereo. `opl3_fpga` is a mature reverse-engineered implementation under a licence in
the same family as the already-vendored TG68K.C. Vendoring it is cheaper by a wide margin than
building the same thing twice.

`antxiko/mangOPL4` is a whole OPL4 and would be the obvious candidate, but carries **no licence at
all** and therefore cannot be used.

### What the seam between the halves has to get right

This is an integration job, and the integration is where the risk sits, not in either half:

- **The register split is fixed by the chip, not by us.** `ymfm::ymf278b::write()` routes I/O
  offsets 0/1 to FM bank 0, 2/3 to FM bank 1 (address `| 0x100`), and 4/5 to PCM. The vendored
  OPL3 takes the FM ports; Psikyo's core keeps PCM. Nothing needs inventing.
- **The timers stay with the OPL4 side, and they are load-bearing on their own.** Both FG-3 games
  write FM register `0x04` roughly 35,000 times per five minutes — that is the sound driver's
  sequencer heartbeat, and its IRQ is how music is paced whether or not FM voices are used. Psikyo
  already implements both timers and the IRQ. Do **not** let the vendored OPL3's own timer logic
  become a second, competing source of that interrupt.
- **Status and ID reads must stay coherent** across the two halves: the Z80 polls busy/status, and
  a read served by the wrong half will hang the driver.
- **Output mixing.** MAME routes six outputs (FM L/R, PCM L/R, and a further pair) at differing
  gains; the mix has to reproduce that balance rather than simply summing.
- **The FM half must be gated by the same clock-enable discipline as everything else**, and its
  wave-ROM/PCM client keeps its existing SDRAM port. Only one half reads sample ROM.

**Asura Buster does not need the FM half at all** (zero key-ons measured), so it is a working
target before the OPL3 integration is finished — worth knowing for sequencing the work.

## Output chain: scaler, rotation, flip

Three separate things that are easy to conflate. Only one of them is a game feature.

**Scaling and filtering -- `sys/arcade_video.v`.** Already vendored with the template. It wraps
`video_mixer` and gives the scandoubler (so a CRT/VGA setup gets a real 15 kHz picture), gamma,
scanline FX and the `gamma_bus`. Feed it the packed RGB, `ce_pix`, and the raw blank/sync signals
from `video_timing.sv`.

**It does NOT wrap `video_freak`.** That is where cropping and the integer-scaling modes live
(`CROP_SIZE`, `CROP_OFF`, `SCALE`), and `sys/video_freak.sv` is present but unconnected. If those
OSD options are wanted, instantiate it explicitly between the core and `VIDEO_ARX/ARY` -- do not
assume `arcade_video` is doing it.

**Rotation -- `rtl/video/screen_rotate_two.sv`, and it is a TAP, not a filter.** `VGA_R/G/B/HS/VS/DE`
still drive the analog output directly with the native raster, while the rotator writes a rotated
(and optionally 180-flipped) copy into DDR3 and points the HPS framebuffer at it. So CRT keeps the
untouched raster and **HDMI** gets rotation. Wire it after `arcade_video`, and set `VIDEO_ARX/ARY`
to swap when rotation is enabled.

- **Fuuki games are all ROT0 horizontal**, so unlike Psikyo (vertical) rotation is not needed for
  correct orientation -- it is there for users running a rotated display. Aspect handling is
  correspondingly simpler: 4:3 normally, 3:4 when rotated.
- **DDR3 is no longer free.** It was, while every memory client sat on SDRAM — but the fast ROM
  loader now owns it, so wiring the rotator means muxing the pins on the loader's busy flag, which
  is exactly the arbitration Psikyo needed. Its rotator has no reset port and samples `DDRAM_BUSY`
  to decide whether a write was accepted, so between loader transactions it took phantom writes as
  accepted and left a permanent stale band in the frame buffer. The loader only runs with the core
  in reset, so the mux is straightforward — but it has to exist before the rotator does.

**Flip screen is a GAME feature and belongs in the renderer, not the output.** It comes from
video register `0x1e` bit 0 (and a DIP), and MAME does not implement it as a 180-degree rotation of
an otherwise identical image: `fuukitmap.cpp` substitutes **different offset constants** when
flipped (`xoffs_flip` / `yoffs_flip`, and FG-2 and FG-3 differ in the latter), and `fuukispr.cpp`
recomputes every sprite position as `sx = max_x - sx - xnum * 16` with the flip bits inverted. So
the flipped image is not a transform of the unflipped one, and doing it with the rotator's 180
flip -- which is what Psikyo did, because its flip was not in the pipeline at all -- would leave
the picture shifted.

Both drivers warn "the scroll values are generally wrong when flip screen is on", so MAME is not a
trustworthy reference for this specific case. `vregs.sv` already carries the flip constants; the
tilemap and sprite engines must honour `flip` themselves.

## High scores

`rtl/hiscore.v` -- Hiscores_MiSTer (Alan Steremberg / Jim Gregory, GPLv3), the standard module,
vendored from the Psikyo tree where it is proven on hardware. It pauses the core and borrows a BRAM
port; `maincpu.sv` already has the `pause` input this needs.

**Checked against MAME's `hiscore.dat`, and all four parent sets have entries** -- every one of them
reading from work RAM at `0x40xxxx`, which is already exposed as a BRAM port:

| Set | Entries | Region | Largest block |
|---|---|---|---|
| gogomile | 1 | `0x40660d` | **0x161 = 353 bytes** |
| pbancho | 3 | `0x402e1f`, `0x400ad3`, `0x400b41` | 0x3b |
| asurabld | 5 | `0x4036ea` - `0x40378a` | 4 |
| asurabus (+ `asurabusj/ja/jr`) | 1 | `0x40326d` | **0x132 = 306 bytes** |

Two things fall straight out of that table:

- **`HS_SCOREWIDTH` must be at least 9**, not the default 8. gogomile and asurabus both need more
  than the 256 bytes an 8-bit score width allows.
- **`gogomileo` and `pbanchoa` have no `hiscore.dat` entry at all**, so those clone `.mra` files
  either ship without hiscore data or borrow the parent's -- a decision to make deliberately rather
  than discover.

`CFG_ADDRESSWIDTH`'s default of 4 (16 entries) is ample; the worst case here is 5.

## Verification strategy

**Simulation first, hardware to settle what simulation cannot see.** Every component has its own
ModelSim testbench and each integration step has one too, and that is still where a change should
be proved. But the honest record of this bring-up is that several real bugs were only ever visible
on the machine: work RAM indexed a bit too narrowly, an arbiter still packing 25-bit addresses
after a widening, and a sprite depth order that hardware settled against a reading of the driver.
So the instruments are built to answer hardware questions directly rather than to argue from
simulation — a trace ring readable through the video output, and `scripts/memdump.py`, which reads
any CPU-visible memory back out of a running core with the CPU paused.

Testbench discipline is not optional here: LESSONS_LEARNED's "Testbench discipline" section lists
the distinct ways a testbench has already produced a confident wrong answer on this toolchain, and
they are not repeated here. Read it before writing a new bench.

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

**Branching.** `develop` is the working branch and carries granular commits. At intervals that
work is **squashed onto `master`**, and `master` is what gets pushed to `origin`. So `master` is a
curated history of meaningful milestones, not a replay of every bisection step; `develop` is where
the detail lives. Never switch branches while a Quartus process is reading the source tree — it
silently kills the run and leaves a truncated log that reads like a tool crash
(LESSONS_LEARNED, "Tooling and workflow").

**Builds run in-tree**, with `scripts/build.sh` driving the Quartus flow and `scripts/deploy.py`
copying the result to the MiSTer. Psikyo's staged build — snapshotting HEAD into a worktree so the
tree stays editable during a compile — was not ported; the protection that mattered was, and lives
in `deploy.py`, which refuses to copy a `.rbf` unless the build log says the compile succeeded, the
`.rbf` is not older than that log, and the timing summary has no negative slack. A Psikyo build
once died mid-Fitter and its deploy then verified the *previous* build's stale `.rbf` as green.
`deploy.py` also prints every clock's slack before it copies anything, and names each core
`Arcade-Fuuki_NNNNNNNN.rbf` with an incrementing number so earlier builds stay on the device as
fallbacks (rename the newest to `.held` to drop back one).

Toolchain is Quartus Prime 17.0.2, per the
[MiSTer developer documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/).
Note `quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH` and must be invoked by full path,
and Quartus must never be launched wrapped in `nohup ... &`.

## Open items / decisions

### Settled

**FG-3 memory: the 128 MB module.** asurabus needs 56.5 MB, which does not fit the stock 32 MB
part. It fits 64 MB naturally, but 128 MB is the module people actually own, so that is the stated
requirement. The map below is fixed in `rtl/memory/fuuki_sdram_top.sv` as `FG3_BASE_*` and
`scripts/build_mra.py` generates every FG-3 `.mra` from it, so the offsets are load-bearing:

| offset | size | region |
|---|---|---|
| `0x0000000` | 2 MB | 68020 program |
| `0x0200000` | 0.5 MB | Z80 program |
| `0x0280000` | 8 MB | `tiles_l0` |
| `0x0A80000` | 8 MB | `tiles_l1` |
| `0x1280000` | 2 MB | `tiles_bg` (our `tiles_l2`) |
| `0x1480000` | 32 MB | sprites |
| `0x3480000` | 4 MB | OPL4 PCM |

56.5 MB used, ending at `0x3880000`. Region order matches FG-2's, so one region-select mux serves
both boards. Sizes are the `ROM_REGION` declarations, **not** the sum of ROMs loaded: asurabld
leaves the first 4 MB of its sprite region empty and the tile bank can still address it.

**Screen timing: both boards use FG-2's 28.640 MHz video crystal** — 7.16 MHz pixel clock,
456 x 262, 59.92 Hz, identical to Psikyo. One timing module, one PLL, no per-board switch. FG-3's
parts list transcribes 28.432 MHz; that figure is deliberately not used, because the two boards
share a video ASIC pair and 28.6432 vs 28.432 is the kind of digit a transcribed parts list drops.
Revisit only if a real FG-3 board measurement contradicts it.

**Sprites: snapshotted RAM, per-scanline render, no frame buffer**, one snapshot generation for
both boards. See "Sprite rendering architecture".

**The raster comparator is 9 bits, and out-of-range values wrap.** Captured traces settle the
width: gogomile drives an interrupt on *every* scanline, cycling `240 -> 1 -> 2 ... -> 239 -> 240`,
and an 8-bit comparator against vtotal 262 aliases lines 256-261 onto 0-5, eating the values for
lines 1-5 and taking five spurious interrupts a frame. pbancho uses lines `0xA8`-`0xDF` with a
per-line layer-0 Y scroll. The *register* is 8 bits, though: MAME's `time_until_pos()` reduces
it modulo the driver's 256-line screen, so `vregs.sv` zero-extends the low byte and gogomile's
parked `0xFFFE` fires at line 254, in vblank — which the game needs, because its main loop spins
on a bit only the level-5 handler sets. `tb_video_timing` has a case that fails at 8 bits of
comparator; `tb_vregs` checks the 8-bit register.

**Asura Blade needs OPL4 FM; Asura Buster does not.** Measured with `scripts/mame/fm_probe.lua`
over five emulated minutes of attract per game: 299 key-ons on three channels for Blade, with all
six channel pairs in 4-operator mode and Total Levels of 20-22 while the cue plays, against zero
key-ons for Buster. Because 4-op is an OPL3 feature, an OPL2 core cannot substitute — see the
OPL4 section. Two bounds on the measurement: attract is not all of gameplay, and only the US
`asurabus` set was tested. Neither changes the decision, which Blade forces on its own.

**Sprite depth order: highest-numbered record on top**, established on hardware and contrary to a
reading of `fuukispr.cpp`. See "Sprites" above; the discrepancy is unexplained.

### Open

1. **The two open video faults** — gogomile's title-cloud jitter and pbancho's bottom strip. See
   "Progress" above for what has been tried and what the driver reading changed.
2. **Raster bands land two lines later than MAME's**, because the engines render two lines ahead
   of the display and the ISR's write is caught a line after the interrupt. Reducing the lead is
   ruled out (the render window); firing IRQ5 early is the `Raster IRQ lead` switch, to be settled
   on the screen.
3. **Layer-order values 6-15** — MAME indexes a 6-entry table with `priority & 0x0f`, so those read
   out of bounds. The RTL picks a defined behaviour; check whether any game writes them.
4. **Flip screen** — both drivers state scroll values are wrong when flipped, so the reference
   cannot be trusted to show what correct looks like. `vregs.sv` carries the constants; the engines
   do not yet honour them.
5. **The `508000-517fff` region on FG-3** — MAME calls it "more tilemap, or linescroll? Seems to be
   empty all of the time". Verify it stays empty before treating it as plain RAM.
6. **`pbancho` layer-2 ROM** — MAME loads `60.rom3` into both `tiles_l0` and `tiles_l2` with the
   comment "?maybe?". Confirm before duplicating 2 MB in the SDRAM map.
7. **Clone `hiscore.dat` coverage** — `gogomileo` and `pbanchoa` have no entry, so those `.mra`
   files either ship without hiscore data or borrow the parent's. Decide deliberately.
