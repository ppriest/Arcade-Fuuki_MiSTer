# jt6295 (OKI M6295) provenance

Vendored from https://github.com/jotego/jt6295, `master` at commit
`7d76b0be8cd8f85f3ae741178c9830b20e2071a1`, fetched file by file from GitHub's contents API on
2026-09-06. Only `hdl/` and `LICENSE` were taken. Used as FG-2's M6295 at 1 MHz with pin 7 high
(`ss = 1`), `INTERPOL = 0`.

Two files in its `hdl/` -- `jt12_comb.v` and `jt12_interpol.v` -- are copies of modules that
also live in `rtl/sound/jt12/hdl/mixer/`. One copy of each is compiled (the jt12 tree's), so
neither is listed in `files.qip` and both are excluded in `scripts/run_sim.sh`.

The chip's ROM bus is a level interface (`rom_addr` out, `rom_data`/`rom_ok` in) that assumes
sample data arrives within two cen32 ticks of the address changing; `rtl/sound/fg2_sound.sv`
turns it into a held request and `rtl/sound/sample_cache.sv` keeps the four channels' granules
resident so that deadline is met from a cache, not from SDRAM.

**License: GPL-3.0**, the same posture as jt12/jt49 -- see `rtl/sound/jt12/PROVENANCE.md`.
