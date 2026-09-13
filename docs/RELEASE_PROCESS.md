# Release process

Two Quartus revisions from one source, held to different standards. Modelled
on the Psikyo core's `Psikyo_stp` / `Psikyo` pair.

| | `Fuuki_stp` (debug) | `Fuuki` (release) |
| --- | --- | --- |
| Project file | `Fuuki_stp.qpf` (this revision alone) | `Fuuki.qpf` (lists both) |
| Settings | `Fuuki_stp.qsf`: a copy of `Fuuki.qsf` plus `DEBUG_ISSP=1` | `Fuuki.qsf` |
| Built by | `build_staged.py` (default) | `build_staged.py --rev Fuuki` |
| Contains | JTAG probe, Debug OSD page, Sound FM/PCM mute switches | none of it: the probe compiles out, the OSD lines are hidden and their status bits forced to zero (`Fuuki.sv`, "DEBUG BUILD OR RELEASE") |
| Timing | may ship with negative slack, stated | must close timing on every clock |
| Goes to | our own DE10-nano | `releases/`, other people's hardware |

A debug build runs on hardware we control, in front of someone who knows what
a marginal path looks like, and the instrumentation costs timing we do not
intend to pay in a release. A release goes to hardware we cannot see, where a
path that only just fails is an intermittent glitch someone else cannot
diagnose. So `build_staged.py` warns about negative slack on the debug
revision and refuses to print the deploy command for a release that has any,
naming the failing clocks; `--allow-negative-slack` overrides that with a
warning and obliges the release notes to state the shortfall. `deploy.py`
prints every clock's slack before any copy and refuses a bitstream that
missed timing unless told otherwise.

`Fuuki_stp.qsf` is a full copy of `Fuuki.qsf`, not a `source` overlay:
Quartus rejects the `set_hps_location_assignment` lines when they arrive
through a `source` command inside a `.qsf`. Keep the two in step by hand;
only the macro line should differ.

Steps for a release:

1. `python scripts/build_staged.py --rev Fuuki`. It must pass the timing gate.
2. Deploy it (`deploy.py`, the command the build prints) and play the four
   parent sets: gogomile, pbancho, asurabld, asurabus. Sound and video both.
3. Copy the `.rbf` to `releases/Arcade-Fuuki_YYYYMMDD.rbf` (`git add -f`;
   `releases/*.rbf` is ignored), remove the previous one, and add the entry
   to the README's History.
4. Publish the `.rbf` and the `.mra` set together. They are coupled: the
   SDRAM layout is encoded in the MRAs from `fuuki_sdram_top.sv`, so a
   mismatched pair fails in ways that look like core bugs. Regenerate with
   `scripts/build_mra.py` if the map or the ROM sets changed.

If anything needs diagnosing, the debug revision is the one to load: same
commit, `--rev` omitted.
