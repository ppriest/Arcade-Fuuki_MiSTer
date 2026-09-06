# opl3 (YMF262 / OPL3) provenance

Vendored from https://github.com/gtaylormb/opl3_fpga, `master` at commit
`b74ba7f` (fetched file by file from GitHub's contents API on 2026-09-06), for the FM half of
FG-3's YMF278B. Taken: every source file under `fpga/modules/` -- `top_level/pkg`,
`top_level/src`, `channels/src`, `operator/src`, `misc/src`, `timers/src`, `host_if/src`,
`clks/src` -- flattened into this directory, plus `COPYING.LESSER`. Not taken: the Vivado block
design, board definitions, constraints, simulation harnesses, the packaged IP under
`opl3_fpga_2_0/`, the `software/` tree and the `docs/`, all of which are that project's own
Xilinx build scaffolding.

**License: LGPL-3.0**, which is a different posture again from the GPL-3.0 jotego cores and the
permissive TG68K/T80. It is a lesser licence, so it constrains this project less than the GPL-3.0
cores already do; nothing here is affected in practice, since the whole repository is
open-source, but it is worth knowing the tree now carries three licences.

## Portability

It is portable as fetched. The only Xilinx traces anywhere in the 31 source files are a
documentation URL in a comment and one `(* ASYNC_REG = "true" *)` attribute in `reset_sync.sv`,
which Quartus ignores. No XPM macros, no vendor primitives, no `UNISIM`. It compiles under
Quartus Prime Lite 17.0 as-is, SystemVerilog package and `module opl3 import opl3_pkg::*`
included -- which was the real risk, and it is cleared.

## The one vendor edit

`opl3_pkg.sv`, `CLK_DIV_COUNT`. Upstream computes it as
`int'($ceil(CLK_FREQ/DESIRED_SAMPLE_FREQ))` and its own comment on that line says the expression
is "unsupported by Quartus 17, set manually" -- and Quartus 17.0 is what this project builds
with, so the edit is required rather than chosen.

The value is not upstream's either, because the clock is not upstream's. This core drives the
OPL3 from `clk_sys` at 85.909091 MHz (945/11), not from a dedicated 12.727 MHz, and it stands in
for the FM half of a YMF278B whose FM sample rate is its 33.8688 MHz chip clock over 684 =
49.5158 kHz. 85909091 / 49515.8 = 1734.96, so the divider is **1735**, giving 49.5153 kHz, 10 ppm
low.

Running the pipeline far slower than upstream's 256-clock budget is safe by construction, not by
measurement: `control_operators.sv` holds state 0 until `sample_clk_en` and returns to it after
the 36 operator states, so a longer period is idle time and cannot overrun.

## How it is wired

`rtl/sound/fg3_sound.sv` gives it the Z80 bus restricted to I/O ports `0x40-0x43`. That is not an
adaptation: those four ports **are** the YMF262 bus -- address low, data, address high, data --
which is the interface this core presents, so it attaches where the real part joins its two
halves. Ports `0x44-0x45` (PCM) are withheld from it.

Status, timers and IRQ stay with `rtl/sound/opl4/opl4_regs.sv`, which implements them and is
proven on hardware. `INSTANTIATE_TIMERS` is 0 in `opl3_pkg.sv` (upstream's default), so this core
does not contend for them, and its `dout`, `irq_n` and `led` are left unconnected. Its 24-bit
sample (a channel sum shifted left by 5) is brought to the PCM engine's 16-bit scale with `>>> 8`
and handed to `opl4.sv` for the DO2 mix, where the F8 attenuator balances it against PCM exactly
as the reference does.
