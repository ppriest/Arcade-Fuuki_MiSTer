// In-System Sources and Probes: read core state over JTAG, and poke it back.
//
// Used instead of SignalTap because SignalTap acquisition is not scriptable
// in Quartus Prime Lite 17.0; In-System Sources and Probes is
// (`start_insystem_source_probe`, `read_probe_data`, `write_source_data`).
//
// Generic wrapper with no opinion about what is measured. Build the probe
// bus in the module that owns the signals and pass it in.
//
// Rules for a trustworthy probe (docs/LESSONS_LEARNED.md, "Debug
// instrumentation: how not to fool yourself"):
//   * Never reset a debug counter with the reset under investigation; use
//     rtl/debug/debug_counter.sv, which has no reset.
//   * Pair every "bad event" counter with a "total events" counter.
//   * Sample registered signals, and prove the probe on a known-good
//     configuration first.
//   * Capture the full address; low bits alone make a linear sweep look
//     like dropped high address bits.
//
// instance_id is the tag the host script selects on. Register of them:
//   "F"   general core state
// Host side: scripts/read_issp.tcl.

module issp_probe #(
	parameter [7:0] INSTANCE_ID = "F",
	parameter int   PROBE_W     = 128,
	parameter int   SOURCE_W    = 8
) (
	input  logic                 clk,

	// Everything read back over JTAG, concatenated by the caller. Document
	// the layout where it is built and keep scripts/read_issp.tcl in step;
	// a shifted field reads as plausible nonsense, not as an error.
	input  logic [PROBE_W-1:0]   probe,

	// Written from the host. Bit 0 is conventionally "clear the counters".
	// Synchronous to clk and safe to use as enables.
	output logic [SOURCE_W-1:0]  source
);

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(PROBE_W),
		.source_width(SOURCE_W),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp (
		.probe(probe),
		.source(source),
		.source_clk(clk),
		.source_ena(1'b1)
	);

endmodule
