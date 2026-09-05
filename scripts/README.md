# Tooling

The capture and verification scripts for the Fuuki core. Reference data is captured rather than
hand-made, so any claim about the hardware can be re-checked cheaply — and re-checked the same way
by anyone else with a MAME install and the ROM sets.

## Scripts

| script | purpose |
| - | - |
| `run_sim.sh` | compile the RTL and run one testbench, from the repository root |
| `mame_capture.py` | drive MAME headlessly and capture a reference frame: every video region, the screenshot, and optionally a video-register write log |
| `mame/capture.lua` | the Lua half of the above, run inside MAME |
| `mame/run.lua` | autoboot wrapper that catches Lua syntax and runtime errors and writes them to a file the Python runner reads back — otherwise a broken script fails as a modal dialog that is invisible headlessly |
| `mame/probe.lua` | report which Lua API calls this MAME build actually provides, so the capture scripts are written against what exists rather than against the current online docs |
| `mame/fm_probe.lua` | decode OPL4 register traffic and count FM key-ons |
| `mame/vregs_frames.lua` | log video-register writes with the raster line in force |
| `parse_mame_trace.py` | turn a MAME debugger trace into an expected fetch list for `tb_maincpu` |
| `build_maincpu_hex.py` | assemble a program ROM from a set and score its interleave offline |
| `decode_gfx.py` | decode graphics tiles to ASCII, straight from the ROM zip |
| `gfx_sheet.py` | render graphics tiles to a PNG sheet (ROM data only — not the game's real colours, which live in RAM) |
| `prep_tilemap_tb.py` | build the tilemap testbench's ROM images and configuration from a capture |
| `tilemap_png.py` | turn `tb_tilemap`'s rendered frame into a PNG using the captured palette |
| `video_png.py` | turn `tb_video`'s composed frame into a PNG and diff it pixel-for-pixel against MAME's screenshot of the same state |
| `build_mra.py` | generate every `.mra`, both boards, and prove each one byte-for-byte: each region is built from the driver's ROM_START semantics, the map digits are found by TESTING against that rather than derived, and the finished file is re-read and compared. Offsets come from `fuuki_sdram_top.sv`, never duplicated here. Parents land in `releases/`, clones in `releases/_alternatives/_<parent>/`, named from the MAME description |
| `mra.py` | build the SDRAM image an `.mra` describes, the way mra-tools-c would, so an `.mra`'s output can be checked byte-for-byte against an image built directly from the driver's `ROM_START` |
| `read_issp.tcl` | read the core's debug counters over JTAG via In-System Sources and Probes (`quartus_stp -t`), since SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 |

MAME lives wherever `MAME_DIR` points (default `C:\Emulation\Emulators\MAME`).

## Note for anyone automating MAME

Pass `-nodebug` explicitly if the install has `debug 1` in its `mame.ini`, or every launch halts in
the debugger while an autoboot script still appears to run. And keep every Lua subscription in a
variable that outlives the call, or the garbage collector reclaims it and the callback silently
stops firing.
