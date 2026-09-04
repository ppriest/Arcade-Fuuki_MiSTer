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

**Phase 0 — repository setup: done.** Repo seeded from `MiSTer-devel/Template_MiSTer` (kept as a
`template` remote for upstream pulls), project renamed to the `Fuuki` revision, Quartus-13
variants removed outside `sys/`, `.gitignore` written (ROMs never committed),
`LESSONS_LEARNED.md` carried over, `screen_rotate_two.sv` vendored, ModelSim `work` library and
`modelsim.ini` established with `scripts/run_sim.sh` as the single entry point.

**Phase 1 — CPU spike: passing in simulation.** TG68K.C vendored untouched from the Psikyo tree
(`rtl/cpu/tg68k/`, see its `PROVENANCE.md` — the copy carries two load-bearing fixes and is
deliberately not pristine upstream). `rtl/cpu/maincpu.sv` instantiates `TG68KdotC_Kernel`
directly, with the full Fuuki address decode, an exact Bresenham clock enable (176/945 for FG-2's
16 MHz, 220/945 for FG-3's 20 MHz — both zero-error on this `clk_sys`), and all three
HOLD_LINE interrupts.

`sim/maincpu_tb/` runs the **real gogomile program ROM** and passes 9/9:

- Smoke: no X propagation, fetches happen, the ROM transport serves reads.
- Boot trace: the CPU fetches the reset vector, reaches `0x400`, and walks
  `0x400, 0x402 ... 0x40E` — the `CLR.L D0`-`CLR.L D7` preamble.
- Interrupts: level 3 is acknowledged (FC=7), the ISR is entered through the level-3 autovector
  at `0x6C`, and — the decisive check — `irq3_pending` clears **while the source is still held
  high**, which is the exact set-vs-clear priority bug that hid in Psikyo for an entire project.

**ROM interleaves proved offline for all four parent sets, before any build**
(`scripts/build_maincpu_hex.py --check`, 3/3 each). Every set puts its reset SP at the top of
work RAM and its PC at a sane ROM address running plausible 68k code: both FG-2 sets open with
`CLR.L D0-D7`; `asurabld` opens `NOP NOP / MOVEQ #1,D0 / MOVEC D0,CACR` — the 68020 cache-enable
sequence; `asurabus` puts its SP at `0x0041FFFC`, the top of the **second** work RAM, which
independently confirms MAME's "Work RAM (used by asurabus)" comment.

**Fmax measured, and timing closed for the CPU.** `rtl/cpu/synth_check/` synthesizes and fits
`maincpu` + TG68K standalone on the real 5CSEBA6U23I7 speed grade 7. Raw Fmax is **44.25 MHz**
against an 85.909091 MHz clock (setup slack -10.960 ns, TNS -4613) -- independently confirming
Psikyo's 48.74 MHz for the same core, and confirming this roadmap's own instruction to budget for
the 68k to be the limiting block. Three audited constraints take the same netlist to **+0.927 ns,
TNS 0.000**, and now live in `Fuuki.sdc` with their reasoning attached:

1. **Kernel-internal multicycle 4** -- the CPU advances only on `cpu_ce`, and the tighter of the two
   enable ratios (220/945) puts consecutive ticks at minimum 4 clocks apart. Safe here specifically
   because the `falling_edge` count is **0** in both kernel files; LESSONS_LEARNED's warning about
   multicycles concerns `TG68K.vhd`, the wrapper this design does not instantiate.
2. **Board select is a false path** -- it comes from the `.mra` mod byte and never changes while the
   game runs. Not merely a harness detail: once the kernel multicycle was in, *every* remaining
   failing path started at the board-select driver, because the CPU-mode generics are all
   "switchable with CPU" and fan out through mode-dependent logic.
3. **Kernel to `maincpu` multicycle 2** -- `maincpu.sv`'s phase counter already spends `acc_ph == 0`
   letting the address settle and acts at `acc_ph == 1`. The constraint states what the RTL assumes.

Worth knowing for later: `get_registers` does **not** match RAM ports, so the `altsyncram` register
file needs `get_keepers`. The first attempt used `get_registers`, missed the register file, and
stalled at -4.320 ns with no hint from the report that the collection came back short.

### Ground truth from MAME (2026-09-04)

A real MAME debugger trace and a set of memory dumps now back the work, in
`debug/` (gitignored -- derived from ROMs, never committed).

**The boot trace diff passes 84/84.** `scripts/parse_mame_trace.py` turns the
trace into an expected fetch list -- expanding MAME's instruction starts into
the words actually fetched -- and `tb_maincpu` matches it as an in-order
subsequence of its own fetch trace. The RTL executes gogomile's boot exactly as
MAME does, which makes the CPU spike ground truth rather than self-consistency.
The list stops at the boot delay loop, 131,068 instructions the regression
deliberately does not grind through.

Four things the trace and dumps settled that reading the driver could not:

1. **All three interrupts are load-bearing, and the game SPIN-WAITS on them.**
   Each ISR sets a bit in a flag word at `$403446` -- level 5 sets bit 1,
   level 3 bit 2, level 1 bit 5 -- and the main code blocks on those bits
   (`btst #$2,$403446 / beq $-` at `$015830`, and the same shape at `$0157FE`
   for bit 5). If any one interrupt fails to reach the CPU, the game does not
   run degraded, it hangs. Worth knowing before blaming the video engine for a
   black screen.
2. **Interrupts nest, at boot, by design.** Every handler does
   `ori #$700,SR` ... `andi #$f8ff,SR` -- raising the mask, setting its flag,
   then dropping the mask to ZERO before the `RTE`. The trace shows level 3
   preempting a level 5 handler and level 1 then preempting that. So multiple
   levels are pending simultaneously and each needs its own acknowledge; a
   single shared pending flag would lose interrupts here.
3. **The x/y offset pairing is confirmed empirically.** At the title screen the
   game writes `0x01f3` to the Y offset register and `0x03f6` to the X offset
   register -- exactly the board's `XOFFS` and `YOFFS` constants -- so the
   paired subtraction gives a net offset of **zero** on both axes. "Correcting"
   the pairing to match the register names would give -0x203 and +0x203 and put
   the picture 515 pixels out. Now a test case in `tb_vregs`.
4. **The layout constants are confirmed from what the game writes.** Sprite RAM
   init writes `0x400` (bit 10, "do not draw") to word 0 of 1024 records
   stepping 8 bytes, confirming the record size and the disable bit; the VRAM
   clear covers exactly 32 KB from `0x500000`; the backdrop is written as 0 to
   `$703ffe`, the last palette word, confirming pen `0x1fff`; and layer 2's
   palette is written at `0x701800`, i.e. word `0xC00` = `0x400*3`.

**Phase 2 -- the renderer: started.** `rtl/video/video_timing.sv` (456 x 262, `ce_pix` = clk/12, the
three interrupt sources at their exact raster positions) and `rtl/video/vregs.sv` (register file,
live scroll decode, layer-order table) are built and pass 9/9 and 25/25 respectively.

**The tilemap line engine renders real frames correctly.** `rtl/video/tilemap_line_engine.sv`
draws one scanline of one layer into a line buffer; three instances serve the three layers, which
differ only in configuration. `sim/tilemap_tb/` renders all 240 scanlines from the **captured
gogomile title screen** -- MAME's own VRAM, scroll registers and palette, plus the real tile ROM
assembled by `scripts/prep_tilemap_tb.py` -- and all three layers come out matching MAME's
screenshot:

| Layer | Format | Content | Worst line |
|---|---|---|---|
| 0 | 16x16x4 | sky gradient, skyline, flowered ground | 723 clk (13%) |
| 1 | 16x16x8 | the "Mile Smile" title logo | 1023 clk (18%) |
| 2 | 8x8x4 | clouds | 1123 clk (20%) |

Against the 5,472-clk scanline budget, so all three layers together are about half of it before
any sharing or overlap -- comfortable, and measured rather than estimated. The engine currently
writes one pixel per cycle with no overlap between fetching tile N+1 and writing tile N; that
headroom is where the sprite path's budget will come from if it turns out to need it.

Two things this test caught that nothing else would have:

- **Layer 1 rendered as a solid block** because the prep script built only half its ROM region.
  gogomile's `tiles_l1` is 8 MB from **four** ROMs -- two `ROM_LOAD32_WORD_SWAP` pairs at
  `0x000000` and `0x400000` -- and building only the first pair left every tile in the upper half
  reading a zero-filled gap. It did not error; it drew a plausible rectangle.
- The whole 8bpp path -- the four-groups-of-four-bytes layout, granularity 16 with pens that
  legitimately exceed it -- is confirmed by the logo rendering with correct gradients.

Still to build: the sprite path, the compositor, the SDRAM backend, sound, `.mra` files, and a
whole-core bitstream. Flip screen is not yet honoured by the engine (the port exists).

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

### Why the frame buffer was abandoned

From `sprite_line_buffer.sv`'s own header: the frame buffer held 2 x 71,680 x 12 bits (~1.7 Mbit)
and needed a 71,680-cycle clear per frame. Both of its defects were structural, not bugs to fix:

- the display bank toggled **mid-scanout**, tearing the visible line;
- the clear overlapped the next render pass while the buffer ignored writes, giving dropped sprites
  and stale pixels.

Two 320-entry banks are 7.7 kbit — about **220x smaller** — and neither failure mode remains
possible: the swap happens at hblank so it cannot tear a visible line, and a bank is cleared while
it is neither displayed nor rendered into.

### The three pieces

1. **Buffered sprite RAM.** The CPU sees one persistent RAM; its contents are **copied** into a
   snapshot at the frame boundary, and the renderer reads only the frozen copy. **A swap is not a
   copy** — Psikyo tried ping-pong banks and got two-frame-stale reads for any entry the CPU did not
   rewrite every frame, including end-of-list markers, which compounded into per-scene sprite
   freezes (LESSONS_LEARNED, "A swap is not a copy"). Fuuki's copy is 4096 words.
   **FG-3 needs two generations**, not one: its hardware buffers sprites by two frames
   (`buf[1] <= buf[0]; buf[0] <= live` on vblank rising edge), along with the sprite tile bank.
   FG-2 has no such buffering in MAME. This is the one place a per-board difference is real, and it
   is a depth-of-buffering parameter, not a different architecture.

2. **A once-per-frame candidate list.** Built during vblank: scan the sprite records, decode them,
   coarsely reject any whose bounding box misses the screen, and store the survivors — position,
   Y extent and the raw record — in depth order. **This is the difference between a line renderer
   that works and one that does not.** Psikyo's first line-renderer attempt (parked 2026-08-29)
   re-walked and re-fetched every record on *every line*, ~10 cycles per sprite per line, which
   burned most of the line budget before drawing a pixel and blew it entirely on large sprites. The
   hoist collapses the per-line cost to **one cycle per candidate** (a pipelined read of a small
   y-test word) plus real rendering work. The per-line test stays deliberately coarse; the engine
   re-does the exact per-sub-tile-row math on every hit, so a conservative false hit costs cycles,
   never a wrong pixel.

3. **A double-buffered 320-pixel line buffer.** Per scanline, driven from `line_start`: swap banks,
   clear the render bank (320 cycles), then render the *next* line into it while the other bank is
   displayed. The clear is a separate pass rather than clear-on-read, because read and clear would
   hit the same address in the same cycle and inferred RAM read-during-write behaviour is not
   something to depend on.

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

### Two traps carried forward

- **The line-start pulse must hard-resync the engine, not be consumed only when idle.** Psikyo's
  engine consumed `line_start` in `S_IDLE` only, so an engine still busy at a line boundary **ate
  the pulse**, finished the previous line's sprites into the freshly swapped bank, then idled a full
  line. One overrun corrupted every line below it — the signature being *correct at the top,
  degrading downward*. The fix: a raw per-line tick aborts rendering immediately, drains any
  in-flight memory request per the req/valid contract during the buffer's clear, and starts the next
  line clean, so an overrun clips at worst the tail sprites of one line and raises a counted event.
- **Depth order is the inverse of Psikyo's.** Psikyo stored candidates in display-list order, where
  later entries overwrite earlier. Fuuki has **no display list** — sprite RAM is a flat array of
  1024 four-word records — and MAME walks it **backwards** so that record 0 is drawn last and wins.
  Whichever way the candidate list is built, state explicitly which end wins and prove it; this is
  exactly the "read both halves of a mechanism" trap that Psikyo's sprite depth inversion fell into.

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
| **Screen rotation** | **`screen_rotate_two.sv`** (Sorgelig) -- vendored. A TAP on the video output, not a filter: analog keeps the native raster while a rotated copy goes to DDR3 for the HDMI framebuffer. Fuuki is ROT0, so this serves rotated displays rather than correcting orientation. See "Output chain". | vendored to `rtl/video/` |
| Framework | **MiSTer-devel/Template_MiSTer**, tracked as a `template` remote so upstream fixes can be pulled | github.com/MiSTer-devel/Template_MiSTer |
| Tilemap + sprite engines (FI-002K / FI-003K) | **Custom RTL, no shortcut.** This is the project. | `fuukispr.cpp`, `fuukitmap.cpp` |
| Sprite pipeline *shape* | Psikyo's per-scanline path is the template: buffered sprite RAM, a once-per-frame candidate list, a per-scanline engine, a double-buffered line buffer, plus the reusable decode stages (record decode, position transform, zoom LUT, sub-tile step, zoom source index, tile row decode). Fuuki's record format, zoom curve and depth order are substituted; the `spritelut` stage is dropped entirely. | `Arcade-Psikyo_MiSTer/rtl/video/sprite_*.sv`, `spriteram_dbuf.sv`, `docs/sprite_buffering.md` |
| DIPs / inputs | From each driver's `INPUT_PORTS_START`, per game. DIPs arrive as an **ioctl download, index 254**, not through the status word. | `fuukifg2.cpp`, `fuukifg3.cpp`; `Arcade-Psikyo_MiSTer/docs/mister_framework_notes.md` |
| High scores | **`hiscore.v`** (Hiscores_MiSTer, GPLv3) -- vendored from the Psikyo tree, proven on hardware. All four parent sets have `hiscore.dat` entries, all in work RAM. See "High scores". | github.com/JimmyStones/Hiscores_MiSTer |
| Crop / integer scaling | **`sys/video_freak.sv`** -- present but NOT wrapped by `arcade_video.v`; instantiate explicitly if those OSD options are wanted | Template_MiSTer `sys/` |

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
5. Sprite path, in the order the dependencies run: buffered sprite RAM (a real copy), the
   once-per-frame candidate list, then the per-scanline engine and its double-buffered line
   buffer. See "Sprite rendering architecture" — build it in that order, because the candidate
   list is what makes the per-line budget close.
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

**Phase 5 -- output chain, hiscores and polish.** See the two sections below; then remaining
clone sets and region variants, and savestates (Psikyo's `docs/savestates.md` is the feasibility
study; the same TG68K/RAM/audio arguments apply).

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
- **DDR3 is free for the rotator here**, because every memory client is on SDRAM by decision. That
  avoids the arbitration Psikyo needed: its ROM loader shared DDRAM, and the rotator has no reset
  port and samples `DDRAM_BUSY` to decide whether a write was accepted, so between loader
  transactions it took phantom writes as accepted and left a permanent stale band in the frame
  buffer. Keep DDR3 single-owner and that whole class of bug does not exist.

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

**Branching.** `develop` is the working branch and carries granular commits. At intervals that
work is **squashed onto `master`**, and `master` is what gets pushed to `origin`. So `master` is a
curated history of meaningful milestones, not a replay of every bisection step; `develop` is where
the detail lives. Never switch branches while a Quartus process is reading the source tree — it
silently kills the run and leaves a truncated log that reads like a tool crash
(LESSONS_LEARNED, "Tooling and workflow").

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
3. ~~**Per-scanline sprites**~~ **DECIDED: buffered sprite RAM, per-scanline render into a line
   buffer, no frame buffer** (see "Sprite rendering architecture"). What remains open is narrower:
   FG-3 needs a **two-generation** snapshot to match its 2-frame hardware buffering while FG-2
   needs one, and it is unconfirmed whether any game drives per-scanline sprite effects that MAME
   cannot currently show.
4. **OPL4 FM synthesis** — unbuilt in the inherited core. Measure whether Asura Blade/Buster key on
   any FM channel before deciding to build milestone 2.
5. ~~**Raster interrupt comparator width**~~ **SETTLED 2026-09-04 from captured
   traces: 9 bits.** The register at `0x1c` is 16 bits but only some of them can reach a 0..261
   line counter, and MAME cannot answer how many. Real vreg write traces of both games driving
   raster effects settle it:

   - **gogomile drives an interrupt on EVERY scanline** — 240 writes per frame, cycling
     `240 -> 1 -> 2 -> ... -> 239 -> 240`. Values 1-5 are in real use.
   - **pbancho** uses lines `0xA8`-`0xDF` (168-223) with a per-line layer-0 Y scroll, exactly the
     "changing the vertical scroll value of the layers each scanline" the driver describes.

   With an **8-bit** comparator against vtotal 262, lines 256-261 alias onto 0-5 and gogomile's
   sequence self-destructs — simulated against the real trace:

   | width | fires at lines |
   | --- | --- |
   | 8-bit | 240, **257, 258, 259, 260, 261**, 6, 7, 8 ... |
   | 9-bit | 240, **1, 2, 3, 4, 5**, 6, 7, 8 ... |

   The 8-bit version consumes the values for lines 1-5 during vblank, so the effect loses its
   first five scanlines, starts at line 6, and takes five spurious interrupts every frame. 9 bits
   reproduces the game's intent exactly. `RASTER_CMP_BITS` in `video_timing.sv` makes this a
   one-line change, and `tb_video_timing` has a case that fails at 8.

   **The divergence from MAME stands, and is unrelated to width.** gogomile parks the register at
   `0xfffe` when it wants no raster interrupt; the low 9 bits are `0x1fe` = 510, unreachable, so
   the RTL fires nothing. MAME's `time_until_pos()` takes vpos modulo the screen height, wraps
   that onto a real scanline and raises a level-5 interrupt the hardware almost certainly does
   not — plausibly part of why both drivers call rasters "often incorrect".
6. **Layer-order values 6-15** — MAME reads past the end of a 6-entry table. Choose and document a
   defined behaviour; check whether any game writes them.
7. **Flip screen** — both drivers state scroll values are wrong when flipped. The FPGA can be
   correct here, but the reference cannot be trusted to show what correct looks like.
8. **The `508000-517fff` region on FG-3** — MAME calls it "more tilemap, or linescroll? Seems to be
   empty all of the time". Verify it stays empty before treating it as plain RAM.
9. **Clone sets** — `gogomileo`, `pbanchoa`, `asurabusj`/`asurabusja`/`asurabusjr` all need their
   own `.mra`, built from their own `ROM_START` and DIP tables. Region encodings differ per game and
   are never assumed to match.
10. **`pbancho` layer-2 ROM** — MAME loads `60.rom3` into both `tiles_l0` and `tiles_l2` with the
   comment "?maybe?". Confirm before duplicating 2 MB in the SDRAM map.
