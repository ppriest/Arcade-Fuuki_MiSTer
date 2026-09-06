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
    {snd_peak        48  55 dec}
    {pcm_keyons      56  63 dec}
    {ym_writes       64  79 dec}
    {download_seen   80  80 bit}
    {ioctl_download  81  81 bit}
    {pause_latched   82  82 bit}
    {ring_frozen     83  83 bit}
    {z80_fetches     84  99 dec}
    {fm_keyons      100 104 dec}
    {smp_maxlat      105 107 dec}
    {opl4_port       108 110 dec}
    {opl4_reg        111 118 hex}
    {smp_outstanding 119 119 bit}
    {smp_stalled     120 120 bit}
    {pll_unlock      121 121 bit}
    {ioctl_dl_edges  122 127 dec}
}

# smp_* watches the sample ROM port, shared by FG-2's OKI and FG-3's OPL4
# wavetable (fuuki_core.sv, SAMPLE FETCH WATCH). Both chips assume the fetch
# completes -- the OPL4 issues one request and holds busy_mem until a valid
# only this path can give it -- so one lost valid is a PERMANENT stall, not
# a glitch: the PCM engine stops advancing and its output goes to a
# constant, which is silence at a non-zero level.
#   smp_stalled      a fetch has been outstanding > 4096 clk (sticky). This
#                    being set is the fault; nothing healthy comes close.
#   smp_outstanding  one is outstanding at this instant
#   smp_maxlat       worst latency seen, in units of 512 clk (~6 us)
#
# opl4_reg / opl4_port name what the Z80 last told the OPL4: the register
# selector it wrote to an address port (0, 2 or 4) and which port the last
# write went to. A sound CPU writing hard while starting no voices is stuck
# in a loop, and this says which register the loop is on.
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
# The sound chain, read in this order, says where a silence begins:
#   z80_fetches  the sound CPU is executing at all
#   ym_writes    it is reaching the sound chips
#   pcm_keyons   FG-3: the OPL4 is being asked to start PCM voices
#   fm_keyons    FG-3: ... and FM voices, which NOTHING PLAYS YET -- the
#                OPL4's FM half is not built, so a non-zero count here is
#                the game asking for something this core cannot make.
#                Asura Blade does; Asura Buster does not.
#   snd_peak     the largest |audio_l| seen since the last clear, bits 14:7.
#                Zero with key-ons counting is a silent chip; non-zero is
#                audio genuinely leaving the mix.
# All saturate; clear first and read again for a rate.
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
