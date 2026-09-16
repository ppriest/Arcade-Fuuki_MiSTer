#!/usr/bin/env bash
# Compile the core and report timing, not just the exit code.
#
#     scripts/build.sh            # full compile
#     scripts/build.sh --map      # analysis & synthesis only (fast syntax check)
#     scripts/build.sh --report   # re-read the last build's reports, compile nothing
#
# Quartus reports "Fitter was successful" on a design that fails timing, so
# this reads output_files/<rev>.sta.summary (as Fuuki.sdc's header asks) and
# fails on negative slack.
set -euo pipefail

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

Q="${QUARTUS_BIN:-/c/intelFPGA_lite/17.0/quartus/bin64}"
REV=Fuuki
OUT=output_files

mode="${1:-full}"

if [ "$mode" != "--report" ]; then
	mkdir -p "$OUT"
	# build_id.v comes from the PRE_FLOW script, which quartus_map alone does
	# not run; without it Fuuki.sv fails with `can't open Verilog Design File`.
	"$Q/quartus_sh.exe" -t sys/build_id.tcl x "$REV" "$REV" >/dev/null

	if [ "$mode" = "--map" ]; then
		"$Q/quartus_map.exe" --read_settings_files=on --write_settings_files=off \
			"$REV" -c "$REV" 2>&1 | tee "$OUT/build.log" | grep -E "^Error|^\s+Error" || true
		grep -qE "^Error" "$OUT/build.log" && { echo "SYNTHESIS FAILED"; exit 1; }
		echo "analysis & synthesis OK"
		exit 0
	fi

	"$Q/quartus_sh.exe" --flow compile "$REV" -c "$REV" > "$OUT/build.log" 2>&1 || {
		echo "COMPILE FAILED"; grep -E "^Error|^\s+Error" "$OUT/build.log" | head -20; exit 1; }
fi

echo
echo "==== resource usage ===================================================="
# .fit.summary is a plain "key : value" list with no section banner.
grep -E "Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total DSP Blocks|Total pins|Total PLLs" \
	"$OUT/$REV.fit.summary" || echo "(no $OUT/$REV.fit.summary)"

echo
echo "==== timing ============================================================"
if [ -f "$OUT/$REV.sta.summary" ]; then
	cat "$OUT/$REV.sta.summary"
else
	echo "no $OUT/$REV.sta.summary -- STA did not run"
	exit 1
fi

# Negative slack anywhere is a failure, whatever the flow's exit code.
if grep -qE "Slack[[:space:]]*:[[:space:]]*-" "$OUT/$REV.sta.summary"; then
	echo
	echo "*** TIMING NOT MET -- negative slack above. The .rbf is not trustworthy. ***"
	exit 1
fi

echo
if [ -f "$OUT/$REV.rbf" ]; then
	ls -l "$OUT/$REV.rbf"
	echo "timing met."
else
	echo "no .rbf produced"
	exit 1
fi
