## ---------------------------------------------------------------------------
## Fuuki core timing constraints.
##
## The stock MiSTer .sdc is derive_pll_clocks + derive_clock_uncertainty and
## nothing else: it constrains internal register-to-register paths and leaves
## every external interface, SDRAM included, unanalyzed. "Timing passed" here
## therefore says nothing about the memory interface.
##
## ALWAYS read output_files/<rev>.sta.summary after a build. Quartus reports
## "Fitter was successful" on a design that grossly fails timing, and nothing
## in the default flow warns you. Read the Fmax Summary first.
##
## The constraints below were DERIVED AND PROVEN in the standalone harness at
## rtl/cpu/synth_check/, which takes the CPU from -10.960 ns setup slack
## (TNS -4613) to +0.927 ns (TNS 0.000) on the real device and speed grade.
## Each carries its audit; keep the reasoning with the constraint.
## ---------------------------------------------------------------------------

derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# TG68K kernel multicycle -- WITH ITS AUDIT, because an unaudited multicycle
# is how a design passes timing and fails on silicon.
#
# The unconstrained result is Fmax 44.25 MHz against an 85.909091 MHz clock
# (slack -10.960 ns), which matches Psikyo's independently measured 48.74 MHz
# for the same core on the same device and speed grade. The core cannot be
# made to run at clk_sys and does not need to: it advances ONLY on cpu_ce.
#
# The enable is a Bresenham accumulator at 176/945 (FG-2, 16 MHz) or 220/945
# (FG-3, 20 MHz). The TIGHTER of the two sets the bound: 945/220 = 4.29, so
# consecutive enables are at minimum 4 clk cycles apart. A multicycle of 4 is
# therefore backed by the hardware, not wishful.
#
# Why this is SAFE here, where LESSONS_LEARNED warns it is dangerous:
#   * That warning is about TG68K.vhd, the async-bus WRAPPER, which is full of
#     falling-edge registers -- a multicycle sweeping those grants a HALF-cycle
#     path four full cycles and the Fitter routes it that slowly.
#   * This design does not instantiate that wrapper. Audited directly:
#     `grep -c falling_edge` returns 0 for BOTH TG68KdotC_Kernel.vhd and
#     TG68K_ALU.vhd. There is no posedge-to-negedge path to mis-constrain.
#   * Every clocked process in the kernel is gated by clkena_in or clkena_lw.
#     The one exception (use_VBR_Stackframe, line 464) is a static decode of
#     the CPU-mode generics, not a data path.
#
# Scoped to kernel-internal paths only: the boundary into maincpu.sv's own
# logic is NOT relaxed, because that logic runs at full clk_sys.
# ---------------------------------------------------------------------------
set kernel [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -setup -from $kernel -to $kernel 4
set_multicycle_path -hold  -from $kernel -to $kernel 3

# ---------------------------------------------------------------------------
# Board select is STATIC.
#
# board_fg3 comes from the .mra mod byte: it is established during ROM
# download and never changes while the game runs. In this harness it is driven
# by pat[31] (a free-running pattern register), which makes the fitter treat
# CPU-mode-dependent logic as a live timing path -- and after the kernel
# multicycle was applied, EVERY remaining failing path started there.
#
# That is a harness artifact, but the underlying requirement is real and
# carries into the core: whatever drives board_fg3 must be constrained as
# static, or the mode-dependent logic inside TG68K (VBR_Stackframe,
# extAddr_Mode, MUL/DIV width, BitField -- all "switchable with CPU") shows up
# as combinational depth that nothing can close.
# ---------------------------------------------------------------------------
# The register now exists: Fuuki.sv's `mod_board`, latched from ioctl index 1
# and never cleared. board_fg3 and sysport_alt are bits of it, so constraining
# the register covers both.
#
# A false path aimed at nothing silently constrains nothing, so this is worth
# checking rather than assuming: after a build, confirm the collection was
# non-empty in output_files/Fuuki.sta.rpt (an empty get_registers produces a
# warning, not an error, and the design then fails timing for a reason the
# report attributes elsewhere).
set_false_path -from [get_registers {*mod_board*}]

# ---------------------------------------------------------------------------
# Kernel outputs into maincpu's access state machine: 2 cycles, by design.
#
# After the multicycle and the static-board-select false path, every remaining
# failing path ran from the kernel's altsyncram register file
# (regfile_rtl_0 -- note get_registers does NOT match RAM ports, which is why
# the kernel multicycle above missed it) into maincpu's acc_* registers.
#
# maincpu.sv's phase counter already assumes this path needs more than one
# clock, and says so in its own comment: a32 is a registered kernel output
# that changes on a cpu_ce tick, and its downstream decode path is longer than
# one 11.64 ns period, so acc_ph == 0 is spent letting it SETTLE and nothing
# acts until acc_ph == 1. That is two clocks from the CPU step to the first
# action, which is what this constraint tells the analyzer.
#
# The bound is real, not chosen to make the report green: the source only
# changes on a cpu_ce tick, and consecutive ticks are >= 4 clocks apart, so
# even 2 is conservative. Do NOT raise it past 4 without re-deriving the
# enable ratio -- and if the phase counter is ever changed to act at phase 0,
# this constraint becomes a lie and must go.
# ---------------------------------------------------------------------------
# Destination is EVERY maincpu register fed from the kernel, with the kernel's
# own registers explicitly removed so this cannot override the multicycle 4
# above (a later overlapping set_multicycle_path wins, and silently tightening
# the kernel back to 2 would undo the constraint that matters most).
# remove_from_collection on both ends is the discipline LESSONS_LEARNED asks
# for when scoping any multicycle.
# SCOPE WIDENED FROM *maincpu* TO *fuuki_core*, and the reason is the same trap
# this file already warns about one constraint up: get_registers does not match
# RAM ports. Restricting the DESTINATION to *maincpu* missed every RAM the CPU
# writes -- the palette, sprite RAM, work RAM, VRAM -- because those arrays live
# in fuuki_core, not in maincpu. The first integrated build failed on exactly
# those endpoints (kernel regfile -> pal_vid porta_we_reg, -0.187 ns).
#
# This is a widening of an already-audited constraint, not a new relaxation.
# The SOURCE is still only the kernel, and the physical argument is unchanged
# and applies to every destination fed from it: the kernel advances ONLY on
# cpu_ce, consecutive ticks are >= 4 clocks apart, and maincpu.sv's phase
# counter spends acc_ph == 0 letting the address settle and acts at
# acc_ph == 1 -- so a write enable is asserted two clocks after the address
# that selects it. A multicycle of 2 states what the RTL already does.
#
# If maincpu.sv's phase counter is ever changed to act at phase 0, this
# constraint becomes a lie and must go with it.
set kernel_k [get_keepers {*TG68KdotC_Kernel*}]
set core_k [remove_from_collection [get_keepers {*fuuki_core*}] $kernel_k]
set_multicycle_path -setup -from $kernel_k -to $core_k 2
set_multicycle_path -hold  -from $kernel_k -to $core_k 1

# The runtime phase stepper in Fuuki.sv lives in the CLK_50M domain and hands
# probe_src / phase_pos across to clk_sys through synchronisers. No constraint
# is needed here: sys/sys_top.sdc already places the core PLL's outputs and
# FPGA_CLK1_50 in separate EXCLUSIVE clock groups, so those crossings are cut
# by the framework. (Two scoped false paths were added for this and removed
# again once that was checked -- a constraint that duplicates an existing cut
# only invites a wrong comment about why it is there.)

# ---------------------------------------------------------------------------
# T80 sound CPU multicycle -- Psikyo's constraint, with its audit, transferred.
# ---------------------------------------------------------------------------
# The first sound build failed on T80-internal F/IR ALU-flag paths alone:
# -1.258 ns worst, all fifteen reported endpoints inside T80:u0. Psikyo hit
# the same family and audited it before relaxing:
# Both boards' Z80s are covered: they are the same core on the same enable.
#   1. No half-cycle paths to sweep in: no falling_edge anywhere in
#      rtl/cpu/t80/, and every clocked process in T80se.vhd / T80.vhd /
#      T80_Reg.vhd is rising-edge gated by CEN/ClkEn. The one CEN-ungated
#      branch (DIRSet, the save-state register load) is tied to its '0'
#      default by rtl/sound/fg2_sound.sv's instantiation and synthesizes away.
#   2. The relaxation is backed by RTL: cen_z80 ticks 14-15 clk_sys cycles
#      apart (Bresenham 66/945, rtl/fuuki_core.sv), so every T80 register
#      output is stable for ~14 cycles between updates.
# T80 -> T80 gets 4 (14 is available; 4 clears the measured paths with
# margin). T80 -> anywhere gets 2: fg2_sound samples the T80's bus pins at
# full clk rate, and seeing a value one cycle later costs 1 of the ~14 cycles
# its handshakes actually have. Paths INTO the T80 stay single-cycle.
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
# jt12 (YM2203) phase-generator multicycle -- Psikyo's audited family.
# ---------------------------------------------------------------------------
# With the T80 relaxed, the remaining failing set was one family: jt12_pg's
# stage-II registers (detune_mod_II, phinc_II) -> jt12_pg's phase shift
# register u_phsh (-0.226 ns worst, every reported endpoint). Audited here as
# Psikyo audited it before constraining:
#   * jt12_pg.v has exactly ONE clocked block, under `if (clk_en)`, holding
#     keycode_II / detune_mod_II / phinc_II.
#   * jt12_sh_rst.v (u_phsh, u_pad) has one clocked block, under `if (clk_en)`.
#   * clk_en is jt12_div's post-prescaler enable, `cen & cen_int`, and cen is
#     cen_ym at 1/24 of clk_sys -- so both ends tick >= 24 clk_sys apart.
#   * jt12_reg's cur_ch / cur_op and jt12_lfo's lfo_mod are the same family's
#     sources on Psikyo (both under clk_en; lfo_mod's only full-rate branch
#     is the lfo_en clear, itself changed only by cen-cadenced MMR writes).
# Collections are the NAMED registers, not subtree wildcards, so nothing
# unaudited is swept in. A constraint, not a fork: jt12 stays untouched.
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
# OPL4 (FG-3). Both exceptions below are the Psikyo core's, transferred with
# their audits unchanged -- the module is the same file, the register names
# are the same, and the enable cadence is the same, because that core's
# clk_sys is 945/11 MHz exactly as this one's is (see E:\Arcade-Psikyo_MiSTer).
# Without them this design closes at +0.078 ns with the OPL4 in it, margin
# thin enough to be a fitter-seed lottery.
# ===========================================================================
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# OPL4 PCM engine -- runs on a clock enable, so everything inside it is 2-cycle
# ---------------------------------------------------------------------------
# opl4_pcm's FSM used to advance on every clk_sys edge. That made every path
# inside it a genuine single-cycle path, which is why the two entries below
# had to be narrow and argued case by case, and why the envelope rate chain
# (c_oct/c_rc -> p_eg_inc) kept coming back as the design's worst family with
# nothing legitimate to constrain.
#
# The engine now advances only on opl4.sv's pcm_cen, which is high every
# other clk_sys cycle. It has the cycles: measured in simulation against the
# real opl4 with all 24 channels keyed on, a pass took 553 of the 1948
# clk_sys cycles between sample ticks before the change and 962 after -- 49%
# of budget, so it still finishes with room.
#
# Audit (rtl/sound/opl4/opl4_pcm.sv). The whole case statement sits inside
# `if (cen)`, so every register written there launches and captures only on
# cen edges: two clk_sys periods, unconditionally, with no dependence on
# which state follows which. That is a stronger argument than the state-
# distance ones below, and it subsumes them -- they are left in place because
# they are the same setup value and cost nothing, not because they are still
# load-bearing.
#
# EXCLUDED, and this is the part that matters. A handful of registers in that
# module are deliberately written at FULL rate and would be over-constrained
# by a blanket rule:
#   * fr_mem_valid / fr_mem_data, tick_pending, load_pending / load_ch --
#     latches for one-clk_sys-wide pulses (mem_rd_valid, sample_tick,
#     wavesel_stb) that a cen-only engine would otherwise miss.
#   * mem_rd_req, pcm_hdr_we, key_consume -- cleared on every edge so they
#     stay one cycle wide for opl4.sv's arbiter and opl4_regs. Their data
#     inputs are therefore evaluated every edge.
#   * ch_key -- a separate always_ff that is not cen-gated at all.
# They are removed from both ends of the exception, so a path from a
# full-rate latch into the engine still gets one cycle, which is what the
# hardware does.
set opl4all [get_registers {*|opl4_pcm:u_pcm|*}]
set opl4fr  [get_registers {*|opl4_pcm:u_pcm|fr_mem_valid *|opl4_pcm:u_pcm|fr_mem_data[*] *|opl4_pcm:u_pcm|tick_pending *|opl4_pcm:u_pcm|load_pending *|opl4_pcm:u_pcm|load_ch[*] *|opl4_pcm:u_pcm|mem_rd_req *|opl4_pcm:u_pcm|pcm_hdr_we *|opl4_pcm:u_pcm|key_consume *|opl4_pcm:u_pcm|ch_key[*]}]
set opl4cen [remove_from_collection $opl4all $opl4fr]
if {[get_collection_size $opl4cen] > 0} {
    set_multicycle_path -setup -end 2 -from $opl4cen -to $opl4cen
    set_multicycle_path -hold  -end 1 -from $opl4cen -to $opl4cen
} else {
    post_message -type critical_warning         "Fuuki.sdc: OPL4 PCM cen multicycle NOT applied (empty collection)"
}

# OPL4 PCM output accumulate -> acc_l / acc_r
#
# With the envelope family above constrained, every remaining violated
# clk_sys path (all 400 sampled) converges on one destination family:
# opl4_pcm's acc_l/acc_r. S_OUT does two multiplies and two table lookups in
# a single cycle:
#     c_amd -> am_depth_f -> (* lfo_tri) -> am_add ---+
#     ch_env, ch_tl[16:8] ----------------------------+-> os_env_eff
#     c_pan -> pan_att_l/r -> pan_l/r ----------------+-> os_lenv/os_renv
#          -> att2vol -> os_lvol/os_rvol -> (* w_sample) -> acc_l/acc_r
#
# Audit (rtl/sound/opl4/opl4_pcm.sv). S_OUT is reachable only via
# S_CALC -> S_ENV -> S_FETCH0 [-> S_FETCH1] -> S_OUT, one state per clk:
#   * c_amd and w_lfo are latched at the edge ending S_CALC -> 3 edges to
#     S_OUT. c_pan is latched back in S_RD1, so more still.
#   * ch_env and ch_tl are written in S_ENV -> 2 edges to S_OUT. Their only
#     earlier readers are the next channel's S_RD1/S_CALC, a whole slot
#     later.
#   * am_add, pan_l and pan_r are read ONLY in S_OUT -- nothing consumes
#     them a cycle after their sources are latched.
# So 2 is the tightest available window across the listed sources; setup 2
# doubles the budget, which is enough for a path measured at ~19 ns.
#
# w_sample is deliberately EXCLUDED as a source: it is written in
# S_FETCH0/S_FETCH1 and consumed in S_OUT on the very next edge, so the
# final multiply stays a full-rate path. acc_l/acc_r as sources are likewise
# excluded -- listing only the named registers keeps that single-cycle
# feedback out of the exception.
set accsrc [get_registers {*|opl4_pcm:u_pcm|c_amd[*] *|opl4_pcm:u_pcm|c_pan[*] *|opl4_pcm:u_pcm|w_lfo[*] *|opl4_pcm:u_pcm|ch_env[*] *|opl4_pcm:u_pcm|ch_tl[*]}]
set accdst [get_registers {*|opl4_pcm:u_pcm|acc_l[*] *|opl4_pcm:u_pcm|acc_r[*]}]
if {[get_collection_size $accsrc] > 0 && [get_collection_size $accdst] > 0} {
    set_multicycle_path -setup -end 2 -from $accsrc -to $accdst
    set_multicycle_path -hold  -end 1 -from $accsrc -to $accdst
} else {
    post_message -type critical_warning \
        "Fuuki.sdc: OPL4 PCM accumulate multicycle NOT applied (empty collection)"
}

