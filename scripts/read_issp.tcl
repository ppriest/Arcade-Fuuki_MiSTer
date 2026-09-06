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
    {irq1_pulses     32  39 dec}
    {iack_level1     40  44 dec}
    {irq1_pending    45  45 bit}
    {irq3_pending    46  46 bit}
    {irq5_pending    47  47 bit}
    {cpu_reads       48  63 dec}
    {ym_writes       64  79 dec}
    {download_seen   80  80 bit}
    {ioctl_download  81  81 bit}
    {pause_latched   82  82 bit}
    {ring_frozen     83  83 bit}
    {z80_fetches     84  99 dec}
    {lb_tm1_bad      105 108 dec}
    {lb_spr_bad      109 112 dec}
    {lb_tm1_delta    113 116 hex}
    {lb_spr_delta    117 120 hex}
    {pll_unlock      121 121 bit}
    {ioctl_dl_edges  122 127 dec}
}

# lb_* is the line-buffer check (fuuki_core.sv, LINE-BUFFER CHECK): delta is
# (display line - the row the displayed bank was rendered for), 4-bit two's
# complement, sampled every displayed line; 0 means row V is shown on line V,
# 1 means the picture is one line low. bad counts lines with a non-zero
# delta, saturating at 15, since the core reset. tm1 is tilemap layer 1,
# spr the sprite buffer.
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
# z80_fetches / ym_writes: the sound CPU executing, and the sound CPU
# programming the FM chips. A silent core with z80_fetches advancing and
# ym_writes at zero is a Z80 that runs but never reaches the chips (latch,
# NMI or I/O decode); both at zero is a Z80 that is not running (reset, ROM
# path). Saturate at 65535; clear first for a rate.
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
