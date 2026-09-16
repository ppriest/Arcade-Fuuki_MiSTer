# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   quartus_stp -t scripts/read_issp.tcl              # read
#   quartus_stp -t scripts/read_issp.tcl clear        # read, then zero counters
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 (no Tcl
# commands), so ISSP is what a headless workflow can drive.
#
# The probe bus layout is defined where the bus is built. Keep the `fields`
# tables in step with it: a shifted field decodes as plausible nonsense.

# --- field table: {name lo hi format} -------------------------------------
set fields {
    {frames          0   15 dec}
    {core_resets     16  31 dec}
    {mix_pcm         32  37 hex}
    {new2            38  38 bit}
    {iack_level1     40  44 dec}
    {irq1_pending    45  45 bit}
    {irq3_pending    46  46 bit}
    {irq5_pending    47  47 bit}
    {download_seen   48  48 bit}
    {ioctl_download  49  49 bit}
    {pause_latched   50  50 bit}
    {ring_frozen     51  51 bit}
    {snd_state       53  56 hex}
    {snd_peak        57  64 dec}
    {snd_int_edges   65  72 dec}
    {ym_writes       73  88 dec}
    {z80_fetches_k   89  104 dec}
    {smp_maxlat      105 107 dec}
    {opl4_port       108 110 dec}
    {opl4_reg        111 118 hex}
    {smp_outstanding 119 119 bit}
    {smp_stalled     120 120 bit}
    {pll_unlock      121 121 bit}
    {ioctl_dl_edges  122 127 dec}
}

# smp_* watches the sample ROM port shared by FG-2's OKI and FG-3's OPL4
# (fuuki_core.sv, SAMPLE FETCH WATCH). Both chips wait for the fetch, so one
# lost valid is a permanent stall: PCM output freezes at a constant.
#   smp_stalled      a fetch outstanding > 4096 clk (sticky) -- the fault
#   smp_outstanding  one is outstanding at this instant
#   smp_maxlat       worst latency seen, in units of 512 clk (~6 us)
#
# opl4_reg / opl4_port: the register selector the Z80 last wrote to an OPL4
# address port (0, 2 or 4), and which port it went to.
#
# The sound chain, read in this order, says where a silence begins:
#   z80_fetches_k  opcode fetches in units of 1024 (16 bits, saturates)
#   ym_writes      writes to the sound chips (16 bits, saturates)
#   snd_int_edges  interrupt time base ticks: FG-2 YM3812 timer, FG-3 OPL4
#                  IRQ (8 bits). Fetches with no edges: driver lost its clock.
#   snd_peak       largest |audio_l| since the last clear, bits 14:7. Zero
#                  with chips being written is a silent chip.
#   snd_state      {halt_n, rom_wait, int_n, nmi_n}. 0xB = running, INT high;
#                  bit 3 clear = HALT; bit 2 set = ROM fetch unanswered;
#                  bit 1 clear = INT asserted (low across two reads: never
#                  acknowledged).
#
# Counters saturate, some almost immediately: `clear`, then read twice for a
# rate.

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

# Query instance info before opening a session; it fails inside one.
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# Instance S: the FG-2 sound board per chip (fg2_sound.sv). Peaks are
# |output| bits 14:7 since the last clear; counts saturate.
set fields_S {
    {frames          0   15 dec}
    {last_cmd        16  23 hex}
    {cmds            24  31 dec}
    {peak_ym2203     32  39 dec}
    {peak_ym3812     40  47 dec}
    {peak_oki        48  55 dec}
    {wr_ym2203       56  71 dec}
    {wr_ym3812       72  87 dec}
    {wr_oki          88  103 dec}
    {kon_ym3812      104 111 dec}
    {kon_ym2203      112 119 dec}
    {z80_bank        124 125 dec}
    {oki_bank        126 127 dec}
    {cmds_read       128 135 dec}
    {cmd_prev1       136 143 hex}
    {cmd_prev2       144 151 hex}
    {cmd_prev3       152 159 hex}
    {cmd_prev4       160 167 hex}
    {oki_status      168 171 hex}
    {oki_pending     172 175 hex}
    {oki_last_phrase 176 183 hex}
    {oki_last_chbyte 184 191 hex}
    {oki_ch_bytes    192 199 dec}
    {oki_status_rise 200 207 dec}
    {oki_lost_starts 208 215 dec}
    {oki_start_lat   216 223 dec}
    {oki_fetch_max16 224 231 dec}
    {oki_stale       232 239 dec}
    {oki_fetches     240 255 dec}
    {z_pins_nmi_n    256 256 bit}
    {z_pins_int_n    257 257 bit}
    {z_pins_halt_n   258 258 bit}
    {z_pins_wr_n     259 259 bit}
    {z_pins_rd_n     260 260 bit}
    {z_pins_iorq_n   261 261 bit}
    {z_pins_mreq_n   262 262 bit}
    {z_pins_m1_n     263 263 bit}
    {z_wait_n        264 264 bit}
    {z_rom_done      265 265 bit}
    {z_rom_pending   266 266 bit}
    {z_is_rom_read   267 267 bit}
    {z_last_io_data  272 279 hex}
    {z_last_io_port  280 287 hex}
    {z_clk_since_m1  288 303 dec}
    {z_fetches_64    304 319 dec}
    {z_pc            320 335 hex}
    {z_resets_sync   336 343 dec}
    {z_resets_async  344 351 dec}
    {rst_ldr_active  352 359 dec}
    {rst_not_loaded  360 367 dec}
    {rst_ioctl_dl    368 375 dec}
    {rst_pll_unlock  376 383 dec}
    {rst_user_button 384 391 dec}
    {rst_osd_status0 392 399 dec}
    {rst_RESET       400 407 dec}
    {core_rst_async  408 415 dec}
}

set fields_C {
    {frames          0   15 dec}
    {lost_gap_clk    16  31 dec}
    {cmd_lat_max     32  47 dec}
    {cmd_gap_min     48  63 dec}
    {cmd_busy_d0     64  71 dec}
    {cmd_nmi_entries 72  79 dec}
    {cmd_read_dup    80  87 dec}
    {cmd_write_lost  88  95 dec}
    {drv_6218_music  96  103 hex}
    {drv_6217        104 111 hex}
    {drv_64c9_2nd    112 119 hex}
    {drv_64c8_1st    120 127 hex}
    {drv_64ae_queue  128 135 hex}
    {drv_64a9_pair   136 143 hex}
    {lost_new_byte   144 151 hex}
    {lost_old_byte   152 159 hex}
    {h00_byte 160 167 hex}
    {h00_log2gap 168 172 dec}
    {h00_flag 173 175 dec}
    {h01_byte 176 183 hex}
    {h01_log2gap 184 188 dec}
    {h01_flag 189 191 dec}
    {h02_byte 192 199 hex}
    {h02_log2gap 200 204 dec}
    {h02_flag 205 207 dec}
    {h03_byte 208 215 hex}
    {h03_log2gap 216 220 dec}
    {h03_flag 221 223 dec}
    {h04_byte 224 231 hex}
    {h04_log2gap 232 236 dec}
    {h04_flag 237 239 dec}
    {h05_byte 240 247 hex}
    {h05_log2gap 248 252 dec}
    {h05_flag 253 255 dec}
    {h06_byte 256 263 hex}
    {h06_log2gap 264 268 dec}
    {h06_flag 269 271 dec}
    {h07_byte 272 279 hex}
    {h07_log2gap 280 284 dec}
    {h07_flag 285 287 dec}
    {h08_byte 288 295 hex}
    {h08_log2gap 296 300 dec}
    {h08_flag 301 303 dec}
    {h09_byte 304 311 hex}
    {h09_log2gap 312 316 dec}
    {h09_flag 317 319 dec}
    {h10_byte 320 327 hex}
    {h10_log2gap 328 332 dec}
    {h10_flag 333 335 dec}
    {h11_byte 336 343 hex}
    {h11_log2gap 344 348 dec}
    {h11_flag 349 351 dec}
    {h12_byte 352 359 hex}
    {h12_log2gap 360 364 dec}
    {h12_flag 365 367 dec}
    {h13_byte 368 375 hex}
    {h13_log2gap 376 380 dec}
    {h13_flag 381 383 dec}
    {h14_byte 384 391 hex}
    {h14_log2gap 392 396 dec}
    {h14_flag 397 399 dec}
    {h15_byte 400 407 hex}
    {h15_log2gap 408 412 dec}
    {h15_flag 413 415 dec}
}

set fields_D {
    {frames          0   15 dec}
    {f0_as_second    16  23 dec}
    {f0_as_first     24  31 dec}
    {b0_reboots      32  39 dec}
    {pairflag_other_writes 40 47 dec}
    {frz_nmi_count   48  55 dec}
    {b0_flag         62  62 dec}
    {frozen          63  63 dec}
    {pairflag_other_pc 64 79 hex}
    {f00_byte 80 87 hex}
    {f00_log2gap 88 92 dec}
    {f00_flag 93 95 dec}
    {f01_byte 96 103 hex}
    {f01_log2gap 104 108 dec}
    {f01_flag 109 111 dec}
    {f02_byte 112 119 hex}
    {f02_log2gap 120 124 dec}
    {f02_flag 125 127 dec}
    {f03_byte 128 135 hex}
    {f03_log2gap 136 140 dec}
    {f03_flag 141 143 dec}
    {f04_byte 144 151 hex}
    {f04_log2gap 152 156 dec}
    {f04_flag 157 159 dec}
    {f05_byte 160 167 hex}
    {f05_log2gap 168 172 dec}
    {f05_flag 173 175 dec}
    {f06_byte 176 183 hex}
    {f06_log2gap 184 188 dec}
    {f06_flag 189 191 dec}
    {f07_byte 192 199 hex}
    {f07_log2gap 200 204 dec}
    {f07_flag 205 207 dec}
    {f08_byte 208 215 hex}
    {f08_log2gap 216 220 dec}
    {f08_flag 221 223 dec}
    {f09_byte 224 231 hex}
    {f09_log2gap 232 236 dec}
    {f09_flag 237 239 dec}
    {f10_byte 240 247 hex}
    {f10_log2gap 248 252 dec}
    {f10_flag 253 255 dec}
    {f11_byte 256 263 hex}
    {f11_log2gap 264 268 dec}
    {f11_flag 269 271 dec}
    {f12_byte 272 279 hex}
    {f12_log2gap 280 284 dec}
    {f12_flag 285 287 dec}
    {f13_byte 288 295 hex}
    {f13_log2gap 296 300 dec}
    {f13_flag 301 303 dec}
    {f14_byte 304 311 hex}
    {f14_log2gap 312 316 dec}
    {f14_flag 317 319 dec}
    {f15_byte 320 327 hex}
    {f15_log2gap 328 332 dec}
    {f15_flag 333 335 dec}
}

# Take the first instance unless one is named on the command line.
set want ""
foreach a $argv { if {$a ne "clear"} { set want $a } }
set idx [lindex [lindex $insts 0] 0]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0] }
    }
}

if {$want eq "S"} { set fields $fields_S }
if {$want eq "C"} { set fields $fields_C }
if {$want eq "D"} { set fields $fields_D }

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

# write_source_data takes a binary string unless -value_in_hex is given, and
# silently rejects a decimal value. Every write goes through this, in hex.
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }
if {$set_val >= 0}   { write_src $idx $set_val;   puts "source set to $set_val (reads back 0x[read_source_data -instance_index $idx -value_in_hex])" }
if {$pulse_val >= 0} { write_src $idx $pulse_val; write_src $idx 0; puts "source pulsed $pulse_val" }

if {$do_clear} {
    # Source bit 0 clears the counters, which the core reset does not
    # (rtl/debug/debug_counter.sv).
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
