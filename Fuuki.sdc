## ---------------------------------------------------------------------------
## Fuuki core timing constraints.
##
## The stock MiSTer .sdc (derive_pll_clocks + derive_clock_uncertainty) leaves
## every external interface unanalysed, SDRAM included. Read
## output_files/<rev>.sta.summary after every build: the Fitter reports
## success on a design that fails timing.
##
## The exceptions below were derived in rtl/cpu/synth_check/. Each carries the
## audit that justifies it; keep the audit with the constraint.
## ---------------------------------------------------------------------------

derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# TG68K kernel multicycle 4.
# The kernel advances only on cpu_ce, a Bresenham enable at 176/945 (FG-2,
# 16 MHz) or 220/945 (FG-3, 20 MHz). The tighter, 945/220 = 4.29, puts
# consecutive enables at least 4 clk apart. Unconstrained Fmax is 44 MHz
# against 85.909 MHz.
# Safe because the async-bus wrapper TG68K.vhd (falling-edge registers) is not
# instantiated: `grep -c falling_edge` is 0 for TG68KdotC_Kernel.vhd and
# TG68K_ALU.vhd, and every clocked process in the kernel is gated by clkena_in
# or clkena_lw (use_VBR_Stackframe is a static decode of the generics).
# Scoped to kernel-internal paths; maincpu.sv's own logic runs at full clk_sys.
# ---------------------------------------------------------------------------
set kernel [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -setup -from $kernel -to $kernel 4
set_multicycle_path -hold  -from $kernel -to $kernel 3

# ---------------------------------------------------------------------------
# Board select is static. Fuuki.sv's mod_board is latched from ioctl index 1
# and never changes while the game runs; board_fg3 and sysport_alt are bits of
# it. Without this the CPU-mode-dependent logic inside TG68K (VBR_Stackframe,
# extAddr_Mode, MUL/DIV width, BitField) is analysed as a live path and cannot
# close.
# After a build confirm the collection was non-empty in
# output_files/Fuuki.sta.rpt: an empty get_registers warns and constrains
# nothing.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*mod_board*}]

# ---------------------------------------------------------------------------
# Kernel -> everything else in fuuki_core: multicycle 2.
# The kernel's outputs change only on a cpu_ce tick (>= 4 clk apart), and
# maincpu.sv's access phase counter spends acc_ph == 0 letting the address
# settle and acts at acc_ph == 1, so two clocks separate a CPU step from the
# first thing that consumes it. Destinations include the RAM arrays in
# fuuki_core (palette, sprite RAM, work RAM, VRAM), fed from the kernel's
# altsyncram regfile; get_registers does not match RAM ports, hence
# get_keepers and the *fuuki_core* scope.
# The kernel is removed from the destination so this cannot override the
# multicycle 4 above: a later overlapping set_multicycle_path wins.
# Do not raise past 4 without re-deriving the enable ratio. If the phase
# counter is ever changed to act at phase 0, this constraint must go.
# ---------------------------------------------------------------------------
set kernel_k [get_keepers {*TG68KdotC_Kernel*}]
set core_k [remove_from_collection [get_keepers {*fuuki_core*}] $kernel_k]
set_multicycle_path -setup -from $kernel_k -to $core_k 2
set_multicycle_path -hold  -from $kernel_k -to $core_k 1

# The CLK_50M -> clk_sys crossings in Fuuki.sv (probe_src, phase_pos, through
# synchronisers) need no constraint: sys/sys_top.sdc puts the core PLL outputs
# and FPGA_CLK1_50 in exclusive clock groups. Do not add false paths for them.

# ---------------------------------------------------------------------------
# T80 sound CPU multicycle. Both boards' Z80s are the same core on the same
# enable.
# Audit: no falling_edge in rtl/cpu/t80/; every clocked process in T80se.vhd,
# T80.vhd and T80_Reg.vhd is gated by CEN/ClkEn; the CEN-ungated DIRSet branch
# is tied to '0' by rtl/sound/fg2_sound.sv and synthesises away. cen_z80 ticks
# 14-15 clk apart (66/945, rtl/fuuki_core.sv), so every T80 register output
# is stable ~14 cycles.
# T80 -> T80 gets 4 (clears the measured -1.258 ns with margin). T80 ->
# anywhere gets 2: fg2_sound samples the T80's bus pins at full clk, and one
# cycle of latency costs 1 of the ~14 its handshakes have. Paths into the T80
# stay single-cycle.
# ---------------------------------------------------------------------------
set t80 [get_registers {*|fg2_sound:u_snd2|T80se:u_cpu|* *|fg3_sound:u_snd3|T80se:u_cpu|*}]
if {[get_collection_size $t80] > 0} {
    set_multicycle_path -setup -end 2 -from $t80 -to [all_registers]
    set_multicycle_path -hold  -end 1 -from $t80 -to [all_registers]

    set_multicycle_path -setup -end 4 -from $t80 -to $t80
    set_multicycle_path -hold  -end 3 -from $t80 -to $t80
} else {
    post_message -type critical_warning \
        "Fuuki.sdc: no T80se registers matched -- sound CPU multicycle NOT applied"
}

# ---------------------------------------------------------------------------
# jt12 (YM2203) phase-generator multicycle 2.
# Audit: jt12_pg.v has one clocked block, under `if (clk_en)`, holding
# keycode_II / detune_mod_II / phinc_II. jt12_sh_rst.v (u_phsh, u_pad) has one
# clocked block under `if (clk_en)`. clk_en is jt12_div's `cen & cen_int`, and
# cen is cen_ym at 1/24 of clk_sys, so both ends tick >= 24 clk apart.
# jt12_reg's cur_ch / cur_op and jt12_lfo's lfo_mod are under clk_en too;
# lfo_mod's only full-rate branch is the lfo_en clear, itself changed only by
# cen-cadenced MMR writes.
# Collections name registers, not subtrees, so nothing unaudited is swept in.
# jt12 itself is unmodified.
# ---------------------------------------------------------------------------
set jtsrc [get_registers {*|jt03:u_ym1|*jt12_reg:u_reg|cur_ch[*] *|jt03:u_ym1|*jt12_reg:u_reg|cur_op[*] *|jt03:u_ym1|*jt12_lfo:*|lfo_mod[*] *|jt03:u_ym1|*jt12_pg:u_pg|phinc_II[*] *|jt03:u_ym1|*jt12_pg:u_pg|keycode_II[*] *|jt03:u_ym1|*jt12_pg:u_pg|detune_mod_II[*] *|jt03:u_ym1|*jt12_mmr:u_mmr|effect}]
set jtdst [get_registers {*|jt03:u_ym1|*jt12_pg:u_pg|phinc_II[*] *|jt03:u_ym1|*jt12_pg:u_pg|keycode_II[*] *|jt03:u_ym1|*jt12_pg:u_pg|detune_mod_II[*] *|jt03:u_ym1|*jt12_pg:u_pg|jt12_sh_rst:u_pad|* *|jt03:u_ym1|*jt12_pg:u_pg|jt12_sh_rst:u_phsh|*}]
if {[get_collection_size $jtsrc] > 0 && [get_collection_size $jtdst] > 0} {
    set_multicycle_path -setup -end 2 -from $jtsrc -to $jtdst
    set_multicycle_path -hold  -end 1 -from $jtsrc -to $jtdst
} else {
    post_message -type critical_warning \
        "Fuuki.sdc: jt12 phase-generator multicycle NOT applied (empty collection)"
}

# ===========================================================================
# OPL4 (FG-3). Without the two exceptions below the design closes at
# +0.078 ns.
# ===========================================================================

# ---------------------------------------------------------------------------
# OPL4 PCM engine: 2-cycle inside, because it advances only on opl4.sv's
# pcm_cen, high every other clk_sys cycle. The whole case statement in
# rtl/sound/opl4/opl4_pcm.sv sits inside `if (cen)`. In simulation with all
# 24 channels keyed on a pass takes 962 of the 1948 clk_sys cycles between
# sample ticks.
# Excluded, because they are written at full rate:
#   * fr_mem_valid / fr_mem_data, tick_pending, load_pending / load_ch:
#     latches for one-clk pulses (mem_rd_valid, sample_tick, wavesel_stb).
#   * mem_rd_req, pcm_hdr_we, key_consume: cleared every edge so they stay one
#     cycle wide for opl4.sv's arbiter and opl4_regs.
#   * ch_key: a separate always_ff, not cen-gated.
# They are removed from both ends, so a full-rate latch into the engine keeps
# its single cycle.
# ---------------------------------------------------------------------------
set opl4all [get_registers {*|opl4_pcm:u_pcm|*}]
set opl4fr  [get_registers {*|opl4_pcm:u_pcm|fr_mem_valid *|opl4_pcm:u_pcm|fr_mem_data[*] *|opl4_pcm:u_pcm|tick_pending *|opl4_pcm:u_pcm|load_pending *|opl4_pcm:u_pcm|load_ch[*] *|opl4_pcm:u_pcm|mem_rd_req *|opl4_pcm:u_pcm|pcm_hdr_we *|opl4_pcm:u_pcm|key_consume *|opl4_pcm:u_pcm|ch_key[*]}]
set opl4cen [remove_from_collection $opl4all $opl4fr]
if {[get_collection_size $opl4cen] > 0} {
    set_multicycle_path -setup -end 2 -from $opl4cen -to $opl4cen
    set_multicycle_path -hold  -end 1 -from $opl4cen -to $opl4cen
} else {
    post_message -type critical_warning         "Fuuki.sdc: OPL4 PCM cen multicycle NOT applied (empty collection)"
}

# OPL4 PCM output accumulate -> acc_l / acc_r: multicycle 2. Subsumed by the
# cen rule above (same value); kept because it names the path.
# S_OUT does two multiplies and two table lookups in one step, ~19 ns:
#     c_amd -> am_depth_f -> (* lfo_tri) -> am_add ---+
#     ch_env, ch_tl[16:8] ----------------------------+-> os_env_eff
#     c_pan -> pan_att_l/r -> pan_l/r ----------------+-> os_lenv/os_renv
#          -> att2vol -> os_lvol/os_rvol -> (* w_sample) -> acc_l/acc_r
# Audit (rtl/sound/opl4/opl4_pcm.sv): S_OUT is reached only via S_CALC ->
# S_ENV -> S_FETCH0 [-> S_FETCH1] -> S_OUT. c_amd and w_lfo are latched at the
# end of S_CALC (3 steps before S_OUT), c_pan in S_RD1, ch_env and ch_tl in
# S_ENV (2 steps); am_add, pan_l and pan_r are read only in S_OUT. So 2 is the
# tightest window across the listed sources.
# w_sample is excluded: written in S_FETCH0/1 and consumed in S_OUT on the
# next step, so the final multiply stays full-rate. Naming only these sources
# keeps the acc_l/acc_r feedback out of the exception.
set accsrc [get_registers {*|opl4_pcm:u_pcm|c_amd[*] *|opl4_pcm:u_pcm|c_pan[*] *|opl4_pcm:u_pcm|w_lfo[*] *|opl4_pcm:u_pcm|ch_env[*] *|opl4_pcm:u_pcm|ch_tl[*]}]
set accdst [get_registers {*|opl4_pcm:u_pcm|acc_l[*] *|opl4_pcm:u_pcm|acc_r[*]}]
if {[get_collection_size $accsrc] > 0 && [get_collection_size $accdst] > 0} {
    set_multicycle_path -setup -end 2 -from $accsrc -to $accdst
    set_multicycle_path -hold  -end 1 -from $accsrc -to $accdst
} else {
    post_message -type critical_warning \
        "Fuuki.sdc: OPL4 PCM accumulate multicycle NOT applied (empty collection)"
}
