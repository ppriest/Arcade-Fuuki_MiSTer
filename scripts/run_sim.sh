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

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name>}"
MS="${MODELSIM_BIN:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}"

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

# Orphaned kernels from killed runs spin at 100% CPU indefinitely and make
# every later simulation look pathologically slow. Sweep before launching.
if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

[ -d work ] || "$MS/vlib.exe" work

echo "--- vcom: TG68K ---"
"$MS/vcom.exe" -quiet -2008 -work work \
    rtl/cpu/tg68k/TG68K_Pack.vhd \
    rtl/cpu/tg68k/TG68K_ALU.vhd \
    rtl/cpu/tg68k/TG68KdotC_Kernel.vhd

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
RTL=$(find rtl -name '*.sv'         -not -path '*/synth_check/*'         -not -name 'screen_rotate_two.sv'         -not -name '*_upstream_reference.sv' | sort)
# shellcheck disable=SC2086
"$MS/vlog.exe" -quiet -sv -work work $RTL "sim/$TB"/*.sv

echo "--- vsim: tb_${TB%_tb} ---"
"$MS/vsim.exe" -c -do "run -all; quit -f" "work.tb_${TB%_tb}" 2>&1 \
  | grep -v "arithmetic operand\|Instance: /tb_.*/dut/u_cpu\|^# Loading"
