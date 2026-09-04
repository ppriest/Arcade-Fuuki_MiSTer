# Arcade-Fuuki_MiSTer

A MiSTer FPGA core for Fuuki arcade hardware, covering both board generations:

- **FG-2** (M68000) — Susume! / Go Go! Mile Smile, Gyakuten!! Puzzle Bancho
- **FG-3** (M68EC020) — Asura Blade, Asura Buster

Both boards share the same video hardware (FI-002K sprites, FI-003K tilemaps), so one
`.rbf` serves all of them; the board variant is selected at runtime from a mod byte in
each game's `.mra`.

Seeded from [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer).

## Documentation

- **[`docs/ROADMAP.md`](docs/ROADMAP.md)** — hardware reference, architecture, phase plan
  and current status. Start here.
- **[`docs/LESSONS_LEARNED.md`](docs/LESSONS_LEARNED.md)** — reusable rules carried over
  from `Arcade-Psikyo_MiSTer`, the completed core this project reuses components from.
  Read the relevant section before starting a subsystem, not after it misbehaves.

## Building

Quartus Prime 17.0.2, per the
[MiSTer developer documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/).
Open `Fuuki.qpf` and compile.

## ROMs

No ROM data is distributed with this project. `roms/` is gitignored; supply your own
MAME-compatible sets to build the images the `.mra` files describe.
