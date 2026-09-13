// Trace buffer for bring-up, read out through the video output and
// controlled live from the OSD.
//
// No reset port, deliberately: registers power up to zero at configuration
// and are only re-armed on purpose. A reset here would clear the capture
// with the very reset being investigated. Do not add one.
//
// Capture: pulse `cap_stb` one clk per event with `cap_data` valid that
// cycle. `cap_stb` must be a deliberate registered capture point, proven in
// simulation before its MiSTer output is trusted.
//
// Readout: `rd_index` is normally the video line counter, one entry per
// scanline. `rd_data` is a registered BRAM read, one cycle late.
//
// Window: `ctl_window` skips ctl_window*8191 events before recording, so
// the window walks across a long boot sequence from the OSD, no rebuild.
//
// Re-arm: any change on `ctl_rearm` restarts capture with the current window
// without resetting the core. Capture runs from configuration without a
// re-arm, so the power-on boot is caught by default.

module debug_tracer #(
	parameter int DEPTH = 256,   // entries
	parameter int WIDTH = 24,    // bits per entry (24 = one RGB pixel)

	// Ring mode, selected live by `ctl_ring`: keep overwriting so the buffer
	// holds the most recent DEPTH events, and freeze once the stream is
	// quiet for 2**IDLE_BITS clk. A stopped stream freezes on the last
	// events before it stopped; a running one keeps churning, so two
	// screenshots differ. MODE_RING itself is unused (see below).
	parameter bit MODE_RING = 1'b0,
	parameter int IDLE_BITS = 22   // ring mode: freeze after 2**IDLE_BITS idle clks
) (
	input  logic              clk,

	// ---- capture side ----
	input  logic              cap_stb,    // ONE cycle per event
	input  logic [WIDTH-1:0]  cap_data,

	// ---- live control (OSD status bits; deliberately NOT reset-coupled) ----
	input  logic              ctl_rearm,  // any change restarts capture
	input  logic [3:0]        ctl_window, // skip ctl_window*8191 events first
	input  logic              ctl_ring,   // 1 = ring (latest N), 0 = first N
	input  logic              ctl_trig_en,// 1 = freeze on first cap_trig

	// Trigger: freeze on the first occurrence of an event, leaving the
	// buffer holding the DEPTH events leading up to it. Ring mode alone
	// cannot show that once the CPU is in a tight loop.
	input  logic              cap_trig,

	// ---- readout ----
	input  logic [8:0]        rd_index,
	output logic [WIDTH-1:0]  rd_data,

	// Ring mode: high once the buffer has stopped moving. Echo it somewhere
	// visible; a screenshot of a churning ring is meaningless.
	output logic              frozen
);

	localparam int AW = $clog2(DEPTH);

	(* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

	// Initialisers and no reset: Quartus powers these to 0 at configuration.
	logic [AW:0]  wptr      = '0;   // extra MSB is the "full" flag
	logic [19:0]  skip_cnt  = '0;
	logic         rearm_d   = 1'b0;

	wire full        = wptr[AW];

	// Skip step ctl_window * 8191: odd and not a multiple of DEPTH, so it
	// cannot alias with a power-of-two event period and make every window
	// setting capture the same thing. Window 15 skips ~123k events, past
	// the boot ROM checksum (~96k long reads).
	wire [19:0] skip_target = ({16'd0, ctl_window} << 13) - {16'd0, ctl_window};

	// Ring mode: clk cycles since the last event, saturating. IDLE_BITS=22
	// is ~49 ms at 85.9 MHz, longer than a frame, so a vblank lull cannot
	// trip it.
	logic [IDLE_BITS-1:0] idle_cnt = '0;
	wire idle_hit = &idle_cnt;

	logic trig_seen = 1'b0;

	// `frozen` is combinational from the registered trig_seen, so on the
	// trigger cycle itself it is still 0 and the triggering event is
	// captured as the newest entry.
	assign frozen = ctl_ring ? (idle_hit | trig_seen) : full;

	always_ff @(posedge clk) begin
		rearm_d <= ctl_rearm;

		if (ctl_rearm != rearm_d) begin
			wptr      <= '0;
			skip_cnt  <= '0;
			idle_cnt  <= '0;
			trig_seen <= 1'b0;
		end else if (cap_stb) begin
			idle_cnt <= '0;
			if (ctl_trig_en && cap_trig) trig_seen <= 1'b1;
			if (!frozen) begin
				if (skip_cnt < skip_target) begin
					skip_cnt <= skip_cnt + 20'd1;
				end else begin
					// mem is indexed by wptr[AW-1:0], so in ring mode the
					// oldest entry is overwritten.
					mem[wptr[AW-1:0]] <= cap_data;
					wptr              <= wptr + 1'b1;
				end
			end
		end else if (ctl_ring && !idle_hit) begin
			idle_cnt <= idle_cnt + 1'b1;
		end
	end

	// MODE_RING is documentation only; ctl_ring is the live selector.
	// Referenced so lint does not flag it.
	// verilator lint_off UNUSED
	wire _unused_mode_ring = MODE_RING;
	// verilator lint_on UNUSED

	// Registered read infers a BRAM port rather than a mux.
	always_ff @(posedge clk) begin
		rd_data <= mem[rd_index[AW-1:0]];
	end

endmodule
