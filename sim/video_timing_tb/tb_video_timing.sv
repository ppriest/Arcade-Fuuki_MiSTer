// video_timing checks. RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh).
//
// The interesting checks here are the ones that would otherwise only show up
// as "the picture is one line off" on MiSTer weeks later: the wrap of
// vcnt_next/vcnt_next2 at the frame boundary, and each interrupt firing
// EXACTLY once per frame at the right raster position.

`timescale 1ns/1ps

module tb_video_timing;

	localparam real HALF = 5.8207;      // 85.909091 MHz

	localparam int H_TOTAL  = 456;
	localparam int V_TOTAL  = 262;
	localparam int H_ACTIVE = 320;
	localparam int V_ACTIVE = 240;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	// ce_pix = clk_sys / 12 -> 7.159 MHz, the pixel clock.
	logic [3:0] ce_div = 0;
	logic       ce_pix;
	always_ff @(posedge clk or posedge reset)
		if (reset)               ce_div <= 0;
		else if (ce_div == 4'd11) ce_div <= 0;
		else                      ce_div <= ce_div + 4'd1;
	assign ce_pix = (ce_div == 4'd0);

	logic [8:0] raster_line = 9'd100;

	logic [8:0] hcnt, vcnt, vcnt_next, vcnt_next2;
	logic h_active, v_active, hblank, vblank, hsync, vsync;
	logic line_start, frame_start;
	logic irq1_trig, irq3_trig, irq5_trig;

	video_timing dut (
		.clk(clk), .ce_pix(ce_pix), .reset(reset),
		.raster_line(raster_line),
		.hcnt(hcnt), .vcnt(vcnt),
		.vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start),
		.irq1_trig(irq1_trig), .irq3_trig(irq3_trig), .irq5_trig(irq5_trig)
	);

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	// ---- observation counters ----
	int n_line_start = 0, n_frame_start = 0;
	int n_irq1 = 0, n_irq3 = 0, n_irq5 = 0;
	int max_h = 0, max_v = 0;
	int irq1_v = -1, irq3_v = -1, irq5_v = -1, irq5_h = -1;
	int wrap_bad = 0;
	int active_px = 0;

	always_ff @(posedge clk) begin
		if (!reset) begin
			if (line_start)  n_line_start  <= n_line_start + 1;
			if (frame_start) n_frame_start <= n_frame_start + 1;
			if (irq1_trig) begin n_irq1 <= n_irq1 + 1; irq1_v <= int'(vcnt); end
			if (irq3_trig) begin n_irq3 <= n_irq3 + 1; irq3_v <= int'(vcnt); end
			if (irq5_trig) begin
				n_irq5 <= n_irq5 + 1;
				irq5_v <= int'(vcnt);
				irq5_h <= int'(hcnt);
			end
			if (int'(hcnt) > max_h) max_h <= int'(hcnt);
			if (int'(vcnt) > max_v) max_v <= int'(vcnt);

			if (ce_pix && h_active && v_active) active_px <= active_px + 1;

			// vcnt_next/vcnt_next2 must ALWAYS be vcnt+1 / vcnt+2 modulo
			// V_TOTAL. This is the check that catches a raw truncation at the
			// frame boundary, which on MiSTer looks like the top line of the
			// screen fetching the wrong row.
			if (vcnt_next  != 9'((int'(vcnt) + 1) % V_TOTAL)) wrap_bad <= wrap_bad + 1;
			if (vcnt_next2 != 9'((int'(vcnt) + 2) % V_TOTAL)) wrap_bad <= wrap_bad + 1;
		end
	end

	initial begin
		$display("=== tb_video_timing ===");
		repeat (20) @(posedge clk);
		reset = 0;

		// Run exactly two frames' worth of pixel clocks, plus a margin.
		repeat (2 * H_TOTAL * V_TOTAL * 12 + 100) @(posedge clk);

		$display("\n--- counters ---");
		$display("  max hcnt = %0d (expect %0d)", max_h, H_TOTAL-1);
		$display("  max vcnt = %0d (expect %0d)", max_v, V_TOTAL-1);
		check(max_h == H_TOTAL-1, "hcnt spans 0..455");
		check(max_v == V_TOTAL-1, "vcnt spans 0..261");
		check(wrap_bad == 0,      "vcnt_next / vcnt_next2 wrap on V_TOTAL");

		$display("\n--- frame structure ---");
		$display("  line_start pulses  = %0d", n_line_start);
		$display("  frame_start pulses = %0d", n_frame_start);
		// Two full frames of lines, give or take where the run started/ended.
		check(n_line_start >= 2*V_TOTAL - 2 && n_line_start <= 2*V_TOTAL + 2,
		      "line_start fires once per scanline");
		check(n_frame_start == 2, "frame_start fires once per frame");

		$display("\n--- interrupts ---");
		$display("  irq1 x%0d at line %0d (expect 2 @ 248)", n_irq1, irq1_v);
		$display("  irq3 x%0d at line %0d (expect 2 @ 240)", n_irq3, irq3_v);
		// Level 5 fires ONE LINE BEFORE the programmed line: the lead measured
		// exact on gogomile's cloud bands (video_timing.sv, irq5_cmp).
		$display("  irq5 x%0d at line %0d, hcnt %0d (expect 2 @ 99, hcnt 320)",
		         n_irq5, irq5_v, irq5_h);
		check(n_irq1 == 2 && irq1_v == 248, "level 1 fires once per frame at line 248");
		check(n_irq3 == 2 && irq3_v == 240, "level 3 fires once per frame at vblank start");
		check(n_irq5 == 2 && irq5_v == 99 && irq5_h == H_ACTIVE,
		      "level 5 fires once per frame, one line before the programmed line, at hblank");

		// A raster line outside the frame must produce NO interrupt -- the
		// game can point it anywhere, and inventing an interrupt the hardware
		// would not produce is worse than missing one.
		$display("\n--- level 5 pointed off-screen ---");
		begin
			int n_before;              // NOT `before` -- a SystemVerilog keyword
			n_before = n_irq5;
			raster_line = 9'd300;             // >= V_TOTAL, never reached
			repeat (H_TOTAL * V_TOTAL * 12 + 100) @(posedge clk);
			check(n_irq5 == n_before, "level 5 never fires for an out-of-range line");
		end

		// =============================================================
		// Comparator width: exactly ONE fire per frame for a low line.
		//
		// This is the case that pins RASTER_CMP_BITS. gogomile drives an
		// interrupt on every scanline, cycling 240 -> 1 -> 2 -> ... , so
		// values 1..5 are in real use. With an 8-bit comparator against
		// vtotal = 262 those alias onto lines 257..261 and fire a SECOND
		// time in vblank, which walks the whole effect five lines down the
		// screen and costs five spurious interrupts a frame. At 9 bits each
		// value matches exactly one line.
		//
		// Set RASTER_CMP_BITS to 8 in video_timing.sv and this check fails
		// with 4 fires instead of 2 -- which is the point of having it.
		// =============================================================
		$display("
--- raster line 2: one fire per frame (comparator width) ---");
		begin
			int n_before;
			raster_line = 9'd2;
			// Resynchronise to a frame boundary FIRST, then take the baseline.
			// Sampling n_irq5 before the sync counts any fire that happens
			// between changing raster_line and the boundary, which showed up
			// as 3 fires in 2 frames -- a testbench fault, not aliasing.
			@(posedge frame_start);
			n_before = n_irq5;
			repeat (2 * H_TOTAL * V_TOTAL * 12) @(posedge clk);
			$display("  level 5 fired %0d times in 2 frames (expect 2)", n_irq5 - n_before);
			check(n_irq5 - n_before == 2,
			      "raster line 2 fires once per frame, not twice (no 8-bit aliasing)");
		end

		// =============================================================
		// The one-line lead at the frame boundary: raster line 0 fires on
		// the LAST line of the previous frame, once, not never.
		// =============================================================
		$display("\n--- raster line 0: fires on line %0d ---", V_TOTAL - 1);
		begin
			int n_before;
			raster_line = 9'd0;
			@(posedge frame_start);
			n_before = n_irq5;
			repeat (H_TOTAL * V_TOTAL * 12) @(posedge clk);
			$display("  x%0d at line %0d (expect 1 @ %0d)", n_irq5 - n_before, irq5_v, V_TOTAL - 1);
			check(n_irq5 - n_before == 1 && irq5_v == V_TOTAL - 1 && irq5_h == H_ACTIVE,
			      "raster line 0 wraps to the last line of the frame");
			raster_line = 9'd100;
		end

		$display("\n--- active area ---");
		$display("  active pixels counted = %0d", active_px);
		check(active_px > 0, "active window produced pixels");

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#200ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
