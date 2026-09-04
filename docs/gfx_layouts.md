# Graphics ROM layouts

The bit-level layout of every graphics region, transcribed from the drivers'
`gfx_layout` structs and **verified against the real ROMs offline** with
`scripts/decode_gfx.py`. Both the tilemap and sprite engines address graphics
through these, so an error here is an error everywhere.

Doing this before writing the RTL is deliberate. A wrong graphics layout does
not fail loudly — it produces plausible-looking garbage on screen, which is
expensive to diagnose on hardware and trivial to diagnose here.

## Which region uses which layout

| Region | FG-2 | FG-3 |
|---|---|---|
| `fuukispr` (sprites) | `gfx_16x16x4_packed_msb` | same |
| `tiles_l0` | `gfx_16x16x4_packed_msb` | `layout_16x16x8` |
| `tiles_l1` | `layout_16x16x8` | `layout_16x16x8` |
| `tiles_l2` / `tiles_bg` | `gfx_8x8x4_packed_msb` | same |

## `gfx_16x16x4_packed_msb` — 128 bytes/tile, 8 bytes/row

Standard MAME packed-nibble layout, most significant nibble first.

```
pixel x of row y  =  byte[ y*8 + (x >> 1) ], high nibble if x is even
                                             low  nibble if x is odd
tile base = index * 128
```

## `gfx_8x8x4_packed_msb` — 32 bytes/tile, 4 bytes/row

Identical rule, narrower:

```
pixel x of row y  =  byte[ y*4 + (x >> 1) ], high nibble if x even, low if odd
tile base = index * 32
```

## `layout_16x16x8` — 256 bytes/tile, 16 bytes/row

The one worth reading carefully. From the struct:

```c
16, 16, RGN_FRAC(1,1), 8,
{ STEP4(0,1), STEP4(16,1) },                                   // planeoffset
{ STEP4(0,4), STEP4(16*2,4), STEP4(16*4,4), STEP4(16*6,4) },   // xoffset
{ STEP16(0,16*8) },                                            // yoffset
16*16*8                                                        // charincrement
```

- `planeoffset` = `{0,1,2,3, 16,17,18,19}`
- `xoffset` = `{0,4,8,12, 32,36,40,44, 64,68,72,76, 96,100,104,108}`
- `yoffset` steps 128 bits = 16 bytes per row
- 2048 bits = 256 bytes per tile

MAME counts bits MSB-first within each byte, and builds a pixel with
`planeoffset[0]` as the **MSB**. Working that through, each row is **four
groups of four bytes**, and each group holds four pixels:

```
group g covers bytes 4g .. 4g+3  and pixels 4g .. 4g+3

  pixel 4g+0 = { byte[4g+0][7:4], byte[4g+2][7:4] }
  pixel 4g+1 = { byte[4g+0][3:0], byte[4g+2][3:0] }
  pixel 4g+2 = { byte[4g+1][7:4], byte[4g+3][7:4] }
  pixel 4g+3 = { byte[4g+1][3:0], byte[4g+3][3:0] }

  high nibble of the pixel comes from the FIRST two bytes of the group,
  low nibble from the SECOND two.
```

### What that means physically

An 8bpp tile is **two 4bpp tiles**: one ROM supplies every pixel's high
nibble, the other its low nibble, each laid out exactly like
`gfx_16x16x4_packed_msb`. That falls straight out of the `ROM_LOAD32_WORD_SWAP`
pairing — on gogomile, `lh5370h7` is the high-nibble half and `lh5370h8` the
low-nibble half.

**This produces a diagnostic worth knowing**, because it looks alarming when
you first see it: the high-nibble ROM decodes as smooth, coherent artwork,
while the low-nibble ROM decodes as apparent noise. That is correct and
expected — the low nibble of a smooth gradient is high-frequency by
construction. Measured horizontal adjacent-pixel match rate over 600 tiles:

| ROM | Role | Adjacent-match |
|---|---|---|
| `lh5370h7` | high nibble | **0.855** (smooth) |
| `lh5370h8` | low nibble | **0.533** (noisy) |

A noisy low half is evidence the split is RIGHT. Reading it as evidence of a
broken layout — which is the natural first reaction — sends you looking for a
bug that is not there.

## Byte order: `_SWAP` confirmed for every region

Every Fuuki graphics ROM is loaded with a `_SWAP` macro
(`ROM_LOAD16_WORD_SWAP` or `ROM_LOAD32_WORD_SWAP`). Rather than reasoning
about the map-digit rule, this was measured: decode each ROM both ways and
compare adjacent-pixel match rates over 600 tiles.

| ROM | Region | swapped | not swapped |
|---|---|---|---|
| `lh5370h6` | L0 4bpp | **0.488** | 0.419 |
| `lh5370hb` | L2 4bpp | **0.831** | 0.805 |
| `lh537k2r` | sprites | **0.869** | 0.831 |
| `lh5370h7` | L1 high | **0.855** | 0.784 |
| `lh5370h8` | L1 low | **0.533** | 0.501 |

Swapped wins in **all five**, consistently. Note the absolute score is a
property of the artwork, not of correctness — L0 scores lower than L2 simply
because it is more detailed — so only the swapped-vs-not comparison within a
row means anything. Do not use an absolute threshold.

## Palette addressing

`palette index = colour_base + colour * granularity + pen`

From each driver's `GFXDECODE` entries and callbacks:

| Layer | Board | `colour_base` | granularity | colour source |
|---|---|---|---|---|
| L0 | FG-2 | `0x000` | 16 | `attr & 0x3f` |
| L1 | FG-2 | `0x400` | 16 | `attr & 0x3f` |
| L2 | FG-2 | `0xC00` | 16 | `attr & 0x3f` |
| L0 | FG-3 | `0x000` | 256 | `(attr & 0x3f) >> 4` |
| L1 | FG-3 | `0x400` | 256 | `(attr & 0x3f) >> 4` |
| L2 | FG-3 | `0xC00` | 16 | `attr & 0x3f` |
| Sprites | both | `0x800` | 16 | `attr & 0x3f` |

Two things that are easy to get wrong:

- **FG-2's layer 1 is 8bpp with granularity 16**, set explicitly by
  `gfx(1)->set_granularity(16)` — "256 colour tiles with palette selectable on
  16 colour boundaries". The pen can therefore exceed the granularity, which is
  the entire point; do not mask it.
- **FG-3 shifts the tilemap colour right by 4** for layers 0 and 1 only
  (`tmap_colour_cb`), leaving 2 bits of colour selecting one of four 256-entry
  banks. Layer 2 is not shifted.

Backdrop is the **last pen**, `(0x800 * 4) - 1 = 0x1fff` — not pen 0.

## Transparent pens

Set in each driver's `video_start()`:

| Layer | FG-2 | FG-3 |
|---|---|---|
| L0 | `0x0f` | `0xff` |
| L1 | `0xff` | `0xff` |
| L2 | `0x0f` | `0x0f` |

Sprites use pen `15` (the `transpen` argument in `fuukispr.cpp`).

## Tooling

```bash
# Render tiles as ASCII, any layout, straight out of the MAME zip.
python scripts/decode_gfx.py roms/gogomile.zip lh5370h6.rom3 16x16x4 \
    --tiles 0x40,0x41 --interleave word_swap

# An 8bpp ROM_LOAD32_WORD_SWAP pair:
python scripts/decode_gfx.py roms/gogomile.zip lh5370h7.rom15 16x16x8 \
    --member2 lh5370h8.rom11 --tiles 0x300
```

When reading the output, remember the shading is scaled to the full pen range,
so a legitimately dark 8bpp tile (pens 3-29 of 255) renders almost blank. That
is not a decode failure.
