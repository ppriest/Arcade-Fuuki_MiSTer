# Tooling

The capture and verification scripts for the Fuuki core. Reference data is captured rather than
hand-made, so any claim about the hardware can be re-checked cheaply — and re-checked the same way
by anyone else with a MAME install and the ROM sets.

## Scripts

| script | purpose |
| - | - |
| `run_sim.sh` | compile the RTL and run one testbench, from the repository root |
| `build.sh` | run the full Quartus flow and fail on negative slack rather than on the Fitter's opinion |
| `deploy.py` | copy the `.rbf` and the `.mra` files to a MiSTer; prints every clock's slack first, and refuses a bitstream the build did not actually produce |
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
| `hw.py` | launch a game via MiSTer Remote's API (bouncing through `menu.rbf` so the FPGA is really reprogrammed) and pull screenshots; the screenshot folder is named from the MRA setname, which it reads from the device |
| `cfg.py` | set OSD status bits in a per-core `.CFG` by read-modify-write, so untouched bits survive; the CFG is only read when the core loads |
| `sweep.py` | launch every deployed set in turn and tabulate the JTAG probe side by side, because one black screen is consistent with several different faults and comparing sets separates them |
| `sdram_dump_check.py` | diff an SDRAM read-back dump (trace source 3, the walker in `fuuki_core.sv`) against the program ROM, keyed by the index each row carries so dropped or duplicated scanlines cannot mis-attribute a word |
| `sdram_pattern_test.py` | known-pattern SDRAM write/read test through the real download path -- inline-hex `.mra` files, no ROM -- so address-dependent, data-dependent and timing faults can be told apart; every result is guarded by checking the device actually loaded the test |
| `phase_sweep.py` | walk the SDRAM_CLK phase at runtime over JTAG with a pattern loaded, and report errors against phase: the DQ eye. **Not runnable as it stands** — the probe field it read was repurposed for the interrupt state; restore it before using this |
| `decode_debug_screenshot.py` | read exact 24-bit values back out of a trace-overlay screenshot, one per scanline (vendored from the Psikyo core) |
| `tracer_readout.py` | read the core's 256-entry trace ring back through the screenshot path, as inverted bands whose pairs must XOR to all-ones — so a transform anywhere in the capture path is detected rather than read as data |
| `wait_scene.py` | poll screenshots until the frame matches a reference crop, then hold the CPU paused there, so a dump is one instant of one chosen scene |
| `read_issp.tcl` | read the core's debug counters over JTAG via In-System Sources and Probes (`quartus_stp -t`), since SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 |
| `report_worst_paths.tcl` | `quartus_sta -t scripts/report_worst_paths.tcl Fuuki` -- the 15 worst clk_sys setup paths from the compiled database, to `output_files/worst_paths_Fuuki.rpt`. |
| `soak.py` | `python scripts/soak.py gogomile --seconds 120` -- run a game and sample the probe (irq pulses, pending flags, PC) and a screenshot every 10 s; flags a hang. |
| `memdump.py` | `python scripts/memdump.py vram 0 64` -- read SDRAM / VRAM / palette / sprite RAM / vregs / work RAM back from the running core over JTAG (CPU paused per page), optionally `--compare` against an expected image. Needs `cfg.py <game> --set overlay=1 src=3 ring=0`. |
| `boot_trace.py` | `capture` the first 256 CPU accesses, `--trig` the 255 before the first exception, `hang` the last 256 before a JTAG pause, `compare` against MAME. |

MAME lives wherever `MAME_DIR` points (default `C:\Emulation\Emulators\MAME`).

## Note for anyone automating MAME

Pass `-nodebug` explicitly if the install has `debug 1` in its `mame.ini`, or every launch halts in
the debugger while an autoboot script still appears to run. And keep every Lua subscription in a
variable that outlives the call, or the garbage collector reclaims it and the callback silently
stops firing.
