# clk_sys = 14.318181 MHz x 6 = 945/11 MHz = 85.909091 MHz.
# Read output_files/*.sta.summary: the Fitter reports success on a design that
# fails timing.
create_clock -name clk -period 11.6414 [get_ports clk]
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# TG68K kernel multicycle 4. Unconstrained Fmax is 44.25 MHz against
# 85.909 MHz. The kernel advances only on cpu_ce, a Bresenham enable at
# 176/945 (FG-2) or 220/945 (FG-3); 945/220 = 4.29, so enables are >= 4 clk
# apart.
# Safe here, unlike the LESSONS_LEARNED warning: that concerns the TG68K.vhd
# wrapper's falling-edge registers, which this design does not instantiate.
# `grep -c falling_edge` is 0 for TG68KdotC_Kernel.vhd and TG68K_ALU.vhd;
# every clocked kernel process is gated by clkena_in or clkena_lw
# (use_VBR_Stackframe, line 464, is a static decode of the generics).
# Kernel-internal only: maincpu.sv's own logic runs at full clk_sys.
# ---------------------------------------------------------------------------
set kernel [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -setup -from $kernel -to $kernel 4
set_multicycle_path -hold  -from $kernel -to $kernel 3

# ---------------------------------------------------------------------------
# Board select is static (the .mra mod byte, set during ROM download). Here it
# is driven by pat[31]; unconstrained, the CPU-mode-dependent TG68K logic
# (VBR_Stackframe, extAddr_Mode, MUL/DIV width, BitField) is analysed as a
# live path and cannot close. The core needs the same exception on its
# board-select source.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*pat[31]*}]

# ---------------------------------------------------------------------------
# Kernel -> maincpu access state machine: multicycle 2.
# Kernel outputs change only on cpu_ce (>= 4 clk apart), and maincpu.sv's
# phase counter lets them settle in acc_ph == 0 and acts at acc_ph == 1.
# get_registers does not match RAM ports (the kernel's regfile altsyncram),
# hence get_keepers. The kernel is removed from the destination so this cannot
# override the multicycle 4 above: a later overlapping set_multicycle_path
# wins.
# Do not raise past 4 without re-deriving the enable ratio. If the phase
# counter is changed to act at phase 0, this constraint must go.
# ---------------------------------------------------------------------------
set kernel_k [get_keepers {*TG68KdotC_Kernel*}]
set maincpu_k [remove_from_collection [get_keepers {*maincpu*}] $kernel_k]
set_multicycle_path -setup -from $kernel_k -to $maincpu_k 2
set_multicycle_path -hold  -from $kernel_k -to $maincpu_k 1

# Harness only: the XOR-reduction tree onto the result pin is not part of the
# core.
set_false_path -to [get_keepers {result*}]
