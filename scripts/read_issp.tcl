# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   quartus_stp -t scripts/read_issp.tcl              # read
#   quartus_stp -t scripts/read_issp.tcl clear        # read, then zero counters
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 -- there are no
# *signaltap* Tcl commands -- so ISSP is what a headless workflow can drive.
# See rtl/debug/issp_probe.sv for why counters answer a bring-up question
# better than a waveform does.
#
# The probe bus layout is defined where the bus is BUILT, not here. Keep the
# `fields` table below in step with it: a silently shifted field decodes as
# plausible nonsense rather than as an error, which is worse than a crash.

# --- field table: {name lo hi format} -------------------------------------
# Edit this to match the probe bus the core currently exports.
set fields {
    {frames          0   15 dec}
    {core_resets     16  31 dec}
    {phase_pos       32  47 sdec}
    {cpu_reads       48  63 dec}
    {last_rom_data   64  79 hex}
    {download_seen   80  80 bit}
    {ioctl_download  81  81 bit}
    {pause_latched   82  82 bit}
    {ring_frozen     83  83 bit}
    {last_rom_addr   84 104 hex}
    {dl_writes_256   105 120 dec}
    {pll_unlock      121 121 bit}
    {ioctl_dl_edges  122 127 dec}
}

# dl_writes vs download_seen is the pair that matters: download_seen says ioctl
# bytes REACHED the core, dl_writes says the arbiter ACCEPTED them into SDRAM.
# The first bitstream had download_seen=yes and would have had dl_writes=0,
# because the memory path was held in reset for the whole transfer.
#
# max_dl_addr512 is the HIGHEST download address written, in 512-byte units:
# multiply by 0x200 for the byte address. Unlike the trace buffer it has no
# idle timeout, so a pause mid-download cannot make it look like the end.
# A complete gogomile load must reach 0x1180000 -> 0x8C00 here.
#
# ring_frozen was labelled board_fg3 after the probe layout changed and the
# label did not. It decoded an FG-2 game as an FG-3 board -- exactly the
# "silently shifted field reads as plausible nonsense" this file warns about.
#
# dl_writes_256 counts download writes in units of 256. A COMPLETE gogomile
# load is 9,175,040 word writes = 35,840 here; anything much lower means the
# transfer is being dropped, not merely slow.
#
# last_rom_addr / last_rom_data are captured as a PAIR, so they can be checked
# against the ROM image directly. gogomile word 0 must read 0x0040.
#
# NOTE the counters SATURATE at 65535 and several of them count per-cycle
# events, so they pin almost immediately. Always `clear` first and read again
# to get a rate; a pinned 65535 means "lots", nothing more.

# last_rom_addr is a WORD address: double it for the 68k byte address the
# disassembler shows.

proc bits_to_int {s lo hi} {
    # read_probe_data returns the bus MSB-first, so index from the right.
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set do_clear [expr {[lsearch -exact $argv "clear"] >= 0}]
# `set N`   : write source byte N (decimal) and leave it
# `pulse N` : write N, then 0 -- for the edge-triggered controls
set set_val -1; set pulse_val -1
set i [lsearch -exact $argv "set"];   if {$i >= 0} { set set_val   [lindex $argv [expr {$i+1}]] }
set i [lsearch -exact $argv "pulse"]; if {$i >= 0} { set pulse_val [lindex $argv [expr {$i+1}]] }

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} {
        set dev $d
    }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this fails with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# Take the first instance unless one is named on the command line.
set want ""
foreach a $argv { if {$a ne "clear"} { set want $a } }
set idx [lindex [lindex $insts 0] 0]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0] }
    }
}

start_insystem_source_probe -device_name $dev -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
puts "raw ([string length $raw] bits): $raw"
puts ""

foreach f $fields {
    lassign $f name lo hi fmt
    set v [bits_to_int $raw $lo $hi]
    switch $fmt {
        sdec { if {$v >= 32768} { set v [expr {$v - 65536}] }; puts [format "  %-16s %d" $name $v] }
        hex  { puts [format "  %-16s 0x%08X" $name $v] }
        bit  { puts [format "  %-16s %s"     $name [expr {$v ? "yes" : "no"}]] }
        default { puts [format "  %-16s %d"  $name $v] }
    }
}

# write_source_data takes a BINARY STRING unless -value_in_hex is given; a
# decimal "8" is silently rejected (the source read back 00 while the script
# printed "source set to 8"). Every write goes through this, in hex.
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }
if {$set_val >= 0}   { write_src $idx $set_val;   puts "source set to $set_val (reads back 0x[read_source_data -instance_index $idx -value_in_hex])" }
if {$pulse_val >= 0} { write_src $idx $pulse_val; write_src $idx 0; puts "source pulsed $pulse_val" }

if {$do_clear} {
    # Source bit 0 is the counter clear, by convention. Pulse it: the counters
    # are deliberately NOT reset by the core's own reset (see
    # rtl/debug/debug_counter.sv), so this is the only thing that zeroes them.
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
