#!/usr/bin/env bash
# Compile and run one testbench, from the repository root.
#
#     scripts/run_sim.sh maincpu_tb
#     scripts/run_sim.sh video_tb +FG3=1     # extra args go to vsim
#
# $readmemh paths resolve against the CWD; a wrong CWD leaves ROMs zero and
# fails every check like an RTL regression (LESSONS_LEARNED, "Testbench
# discipline").
set -euo pipefail

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name> [vsim args...]}"
shift
MS="${MODELSIM_BIN:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}"

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

# scripts/hwlock.py: no simulation while a JTAG tool runs (Quartus is fine).
python scripts/hwlock.py --require-no-jtag "this simulation" || exit 1

# Orphaned vsimk processes from killed runs keep consuming CPU and slow later
# simulations; warn about them.
if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

# Fresh library every run: a run killed mid-compile leaves work/_lock, on
# which later vlog/vcom wait silently forever. Consequently one run at a time
# per tree: concurrent runs delete each other's library.
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
# Compile all core RTL every time, so no bench runs against a stale module.
# Exclusions:
#   synth_check/            Quartus-only harness with its own top level
#   screen_rotate_two.sv    vendored MiSTer-devel code that uses signals before
#                           declaring them; ModelSim rejects it (vlog-2730) and
#                           vendor code stays untouched. Still synthesized.
#   *_upstream_reference.sv pristine upstream copies kept only for diffing
# opl3_pkg.sv goes first: ModelSim needs a package compiled before its
# importers, and alphabetical order puts channels.sv/operator.sv ahead of it.
OPL3_PKG=rtl/sound/opl3/opl3_pkg.sv
RTL=$(find rtl -name '*.sv'         -not -path '*/synth_check/*'         -not -name 'screen_rotate_two.sv'         -not -name '*_upstream_reference.sv' -not -name 'opl3_pkg.sv' | sort)
# jotego cores: skip duplicate module definitions (jt12 alt/ and deprecated/,
# jt6295's own jt12_comb.v/jt12_interpol.v).
JT=$(find rtl/sound -name '*.v' -not -path '*/alt/*' -not -path '*/deprecated/*' \
     -not -name 'jt2413.v' -not -path 'rtl/sound/jt6295/hdl/jt12_comb.v' -not -path 'rtl/sound/jt6295/hdl/jt12_interpol.v' | sort)
# shellcheck disable=SC2086
# The jotego cores leave dividers and envelope pipelines un-reset; the FPGA
# powers them up at zero, the simulator at X (no sound). +initreg/+initmem
# =r+0 zero them.
"$MS/vlog.exe" -quiet -sv -work work +define+SIMULATION +initreg=r+0 +initmem=r+0 $JT
"$MS/vlog.exe" -quiet -sv -work work $OPL3_PKG $RTL "sim/$TB"/*.sv

echo "--- vsim: tb_${TB%_tb} ---"
"$MS/vsim.exe" -c -do "run -all; quit -f" "work.tb_${TB%_tb}" "$@" 2>&1 \
  | grep -v "arithmetic operand\|Instance: /tb_.*/dut/u_cpu\|^# Loading"
