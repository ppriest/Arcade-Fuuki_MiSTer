#!/usr/bin/env bash
# Compile and run one testbench. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_sim.sh maincpu_tb
#
# $readmemh paths resolve against the simulator's CWD, not the testbench
# file, so every bench in this project is written to be run from the repo
# root and this script enforces it. A wrong CWD leaves ROMs all zeroes and
# fails every check at once, which reads exactly like an RTL regression --
# grep the log for `readmem` first (LESSONS_LEARNED, "Testbench discipline").
set -euo pipefail

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name> [vsim args...]}"
# Anything after the bench name goes to vsim, so a plusarg can select a
# variant of the same bench:  scripts/run_sim.sh video_tb +FG3=1
shift
MS="${MODELSIM_BIN:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}"

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

# scripts/hwlock.py: a simulation must not start while a JTAG tool is reading
# the device. It MAY run beside a Quartus build.
python scripts/hwlock.py --require-no-jtag "this simulation" || exit 1

# Orphaned kernels from killed runs spin at 100% CPU indefinitely and make
# every later simulation look pathologically slow. Sweep before launching.
if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

# A FRESH library every run. Everything is recompiled anyway, and a run that
# dies mid-compile (a tool timeout, a crash) leaves work/_lock behind, on
# which every later vlog/vcom waits silently and forever -- which looked
# exactly like a bench that printed nothing.
#
# The corollary: ONE RUN AT A TIME. Two concurrent invocations delete and
# rebuild the same library underneath each other, and the loser prints
# nothing at all.
rm -rf work
"$MS/vlib.exe" work

echo "--- vcom: TG68K, T80 ---"
"$MS/vcom.exe" -quiet -2008 -work work \
    rtl/cpu/tg68k/TG68K_Pack.vhd \
    rtl/cpu/tg68k/TG68K_ALU.vhd \
    rtl/cpu/tg68k/TG68KdotC_Kernel.vhd
"$MS/vcom.exe" -quiet -93 -work work \
    rtl/cpu/t80/T80_Pack.vhd rtl/cpu/t80/T80_MCode.vhd rtl/cpu/t80/T80_ALU.vhd \
    rtl/cpu/t80/T80_Reg.vhd rtl/cpu/t80/T80.vhd rtl/cpu/t80/T80se.vhd

echo "--- vlog: RTL + testbench ---"
# Compile the whole core RTL every time rather than a per-bench file list.
# It costs seconds and removes an entire class of "the bench passed against a
# stale module" failure. synth_check/ is excluded: it is a Quartus-only
# harness with its own top level.
# screen_rotate_two.sv is excluded deliberately: it is vendored MiSTer-devel
# framework code that references signals before declaring them. Quartus
# accepts that; ModelSim rejects it (vlog-2730). The file must stay UNTOUCHED
# -- "vendor components untouched" -- so it is left out of simulation rather
# than patched. It is still in files.qip and still synthesized.
# Two deliberate exclusions:
#   screen_rotate_two.sv    vendored MiSTer-devel code that references signals
#                           before declaring them. Quartus accepts it, ModelSim
#                           does not (vlog-2730), and it must stay UNTOUCHED --
#                           so it is left out of simulation rather than patched.
#                           It is still in files.qip and still synthesized.
#   *_upstream_reference.sv pristine upstream copies kept beside the vendored
#                           modules purely so the local changes can be diffed.
#                           They are not part of any design.
# opl3_pkg.sv FIRST. Quartus resolves SystemVerilog packages across the whole
# project, so file order does not matter to it; ModelSim needs a package
# compiled before anything that imports it, and a plain alphabetical sort puts
# channels.sv and operator.sv ahead of it -- which fails as a cascade of
# "Undefined variable" on every constant in the package.
OPL3_PKG=rtl/sound/opl3/opl3_pkg.sv
RTL=$(find rtl -name '*.sv'         -not -path '*/synth_check/*'         -not -name 'screen_rotate_two.sv'         -not -name '*_upstream_reference.sv' -not -name 'opl3_pkg.sv' | sort)
# The jotego sound cores are plain Verilog. Their trees carry alternates and
# retired versions of the same module names (jt12's alt/ and deprecated/),
# and jt6295 ships its own jt12_comb.v -- one copy of each is compiled.
JT=$(find rtl/sound -name '*.v' -not -path '*/alt/*' -not -path '*/deprecated/*' \
     -not -name 'jt2413.v' -not -path 'rtl/sound/jt6295/hdl/jt12_comb.v' -not -path 'rtl/sound/jt6295/hdl/jt12_interpol.v' | sort)
# shellcheck disable=SC2086
# The jotego cores initialise their free-running dividers only under
# SIMULATION, and their envelope pipelines not at all: hardware powers both
# up at zero, a four-state simulator leaves them X and the chips never make
# a sound. +initreg/+initmem =r+0 give every un-reset variable and array
# the power-up zero.
"$MS/vlog.exe" -quiet -sv -work work +define+SIMULATION +initreg=r+0 +initmem=r+0 $JT
"$MS/vlog.exe" -quiet -sv -work work $OPL3_PKG $RTL "sim/$TB"/*.sv

echo "--- vsim: tb_${TB%_tb} ---"
"$MS/vsim.exe" -c -do "run -all; quit -f" "work.tb_${TB%_tb}" "$@" 2>&1 \
  | grep -v "arithmetic operand\|Instance: /tb_.*/dut/u_cpu\|^# Loading"
