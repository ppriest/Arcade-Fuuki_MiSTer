# Report the worst clk_sys setup paths from a compiled database, no recompile.
#   quartus_sta -t scripts/report_worst_paths.tcl [revision]   # default Fuuki
set rev "Fuuki"
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist

set clk "emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"

report_timing -setup -npaths 15 -detail full_path -from_clock $clk -to_clock $clk \
    -panel_name "Worst 15 setup paths (clk_sys)" -file "output_files/worst_paths_$rev.rpt"

delete_timing_netlist
# -dont_export_assignments: otherwise project_close re-saves the .qsf,
# reverting hand edits (it lost MISTER_FB=1 once).
project_close -dont_export_assignments
