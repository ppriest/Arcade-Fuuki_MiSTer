# TG68K.C provenance

The 68k CPU core, used for **both** boards: FG-2's M68000 and FG-3's M68EC020.

## Chain of custody

| Stage | What |
|---|---|
| Upstream | https://github.com/TobiFlex/TG68K.C, commit `ade33e396a1e647c2de9daf71ff9d5b3979639b2` (2025-03-24) |
| Then | `Arcade-Psikyo_MiSTer/rtl/cpu/tg68k/` — added simulation-fidelity fixes and one synthesis fix, both listed below, and proved the result on real DE10-nano hardware |
| Here | Copied from that Psikyo tree **untouched**. Do not edit these files. |

Licence: LGPLv3+, stated in each file's header; upstream ships no separate LICENSE file.
Copyright (c) Tobias Gubener <tobiflex@opencores.org>.

**These files are NOT pristine upstream.** They carry Psikyo's fixes, each of which is
load-bearing and was confirmed by reverting it. Taking a fresh upstream copy instead would
reintroduce a ModelSim crash and a silicon-only reset failure. If upstream is ever re-pulled,
re-apply both fixes deliberately.

### Modification 1 — zero initializers (simulation fidelity)

Explicit `:= '0'` / `:= (others => '0')` initializers added to every previously-uninitialized
`std_logic` / `std_logic_vector` declaration in `TG68K_ALU.vhd` and `TG68KdotC_Kernel.vhd`
(~123 signals total).

Without them, ModelSim propagates `'X'` through arithmetic from time 0, on every clock edge,
and a real program — as opposed to a short spike — cascades this into multi-GB allocation
failures and SIGSEGV. This is a known upstream issue
(TobiFlex/TG68K.C#21, "uninitialised signals in arithmetic"); upstream declines the fix on the
grounds that real hardware zero-powers these registers and initializers cost logic. That
reasoning is correct for hardware and useless for simulation, which is why the fix lives here.

Not an algorithm change. Same class of fix as the `sdram.sv` uninitialized-state fix.

### Modification 2 — RESET/HALT tri-state (synthesis correctness)

`TG68K.vhd` drives `RESET`/`HALT` as an open-collector bus (`'0' WHEN ... ELSE 'Z'`) because the
core can self-assert reset, while the wrapping SystemVerilog also drives those lines. ModelSim
resolves this correctly with `tri1`; **Quartus 17.0 does not** — it emits
`Warning (13048): Converted tri-state node ... into a selector`, and that selector's steady-state
behaviour for both-drivers-released is wrong on silicon, sticking the core in permanent reset.
Confirmed on a DE10-nano with a VGA-colour-coded debug build.

The fix is a separate single-driver `ext_force_run` port ORed into the downstream computation
(`cpu1reset <= (RESET OR HALT) OR ext_force_run`), **not** making either side non-tri-state —
doing that gives a hard `Error (13076)` multi-driver conflict, sometimes surfacing at a much
deeper signal than the one touched.

Relevant only if `TG68K.vhd` is instantiated. It is not, here — see below.

## How this core is used

**Instantiate `TG68KdotC_Kernel` directly.** `TG68K.vhd` is an async-68000-bus *adapter*, not the
CPU: it wraps the kernel in a bus-protocol emulator that assumes `CLK` is the CPU clock, hence its
many `falling_edge` registers. Slowing that down means fighting its design, and the multicycle
constraints needed to make the timing report accept the result are actively dangerous — a
constraint matching the wrapper sweeps half-cycle paths into a collection granted two or four full
cycles, which the Fitter then routes that slowly, and the design fails only on silicon.

The kernel is entirely rising-edge (verified: zero `falling_edge` occurrences) and exposes
`clkena_in` for exactly this purpose. `mist-devel/plus_too`'s `tg68k.v` is the canonical example.
`TG68K.vhd` is kept in the tree for reference and is **not** added to `files.qip`.

### One instance serves both boards

The `CPU` port selects core mode at **runtime**, so the board's mod byte can drive it directly:

| `CPU` | Mode | Board |
|---|---|---|
| `00` | 68000 | FG-2 |
| `01` | 68010 | — |
| `11` | 68020 | FG-3 |

Every 68020-only feature is a generic already set to "switchable with CPU":
`VBR_Stackframe` (2 = switchable with `CPU(0)`), `extAddr_Mode`, `MUL_Mode`, `DIV_Mode` and
`BitField` (2 = switchable with `CPU(1)`). Leave them at 2.

The data bus is **16 bits wide in both modes** (`data_in`/`data_write` are `15 downto 0`, with a
`longword` output), so the memory path does not change shape between boards — FG-3's 32-bit
program ROM is still read as 16-bit words.

## Known risk (from upstream's own README)

> The core does not value cycle accuracy. The core saves the FPGA resources with a good
> execution speed.

This is a real tension with matching MAME's behaviour, and it is the first thing to suspect if a
game runs logically correct but glitches on timing-sensitive effects. That matters more here than
it did on Psikyo: Fuuki's **level-5 raster interrupt** drives per-scanline video register changes,
which is precisely a timing-sensitive effect. See `docs/ROADMAP.md`, "Raster effects are a
first-class requirement".

## Facts worth not rediscovering

- **IPL is inverted inside the kernel** (`IPL_nr <= NOT IPL`). Requesting level 3 (Fuuki's vblank
  IRQ) means driving `IPL = 3'b100`, not `3'b011`. Read from source, not inferred from pin naming.
- **VPA must be asserted only during a real interrupt-acknowledge cycle** (`FC = 3'b111`), never
  permanently. Tied low permanently, every ordinary ROM fetch races two different cycle-termination
  mechanisms at once.
- **Expect this core to be the Fmax-limiting block. MEASURED HERE: 44.25 MHz.**
  `rtl/cpu/synth_check/`, real device 5CSEBA6U23I7 speed grade 7, against an 85.909091 MHz clock:
  raw setup slack **-10.960 ns**, TNS -4613. Psikyo independently measured 48.74 MHz for the same
  core on the same device, with all 50 worst-slack paths inside `TG68KdotC_Kernel` -- the
  `altsyncram` register file and its bypass network. The same register file dominates here.

  **This does not block the design, and the fix is constraints, not RTL.** The core advances only
  on `cpu_ce`, so paths inside it genuinely have several clocks. With three audited constraints the
  same netlist closes at **+0.927 ns, TNS 0.000**:

  | Constraint | Justification |
  | --- | --- |
  | kernel-internal multicycle 4 | the enable is 176/945 or 220/945, so consecutive ticks are at minimum 4 clocks apart; safe because `falling_edge` count is 0 in both kernel files |
  | board select is a false path | it comes from the `.mra` mod byte and is static after ROM download; while it toggled in the harness, every remaining failing path started there |
  | kernel to `maincpu` multicycle 2 | `maincpu.sv`'s phase counter deliberately spends `acc_ph == 0` letting the address settle and acts at `acc_ph == 1` -- two clocks |

  Note `get_registers` does **not** match RAM ports, so the register file needs `get_keepers`; the
  first attempt missed it and only reached -4.320 ns. The proven set lives in `Fuuki.sdc`.
  It also has no clock-enable of its own to protect you beyond `clkena_in`.
- **Hierarchical references into this VHDL do not elaborate under Quartus** at any depth, though
  they work in ModelSim. For a debug tap, add a real output port; unconnected new ports at other
  instantiation sites are legal.
- Standalone footprint on the DE10-nano's 5CSEBA6U23I7: **2,788 / 41,910 ALMs (7%)**, 1,378
  registers, 2 RAM blocks, 6/112 DSPs.

## Status in this project

- [x] Vendored
- [x] Compiles under ModelSim-Altera 10.5b in this tree
- [x] Boots real gogomile program ROM in **68000 mode** (`CPU = "00"`)
- [ ] Simulated boot trace diffed against a MAME boot trace
- [x] Fmax confirmed on this project's own post-fit netlist (44.25 MHz raw; closes at +0.927 ns
      with the audited constraints above)
- [x] Elaborates for Quartus -- 0 errors, 2,828 ALMs (7%), 1,463 registers, 6 DSPs
