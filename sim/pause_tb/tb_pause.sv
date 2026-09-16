// pause_control checks. RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh pause_tb).
//
// Checks: a press toggles once however long it is held; either player's button
// works; an internal pause reason does not clobber the user's toggle.

`timescale 1ns/1ps

module tb_pause;

	localparam real HALF = 5.8207;
	localparam int  PB   = 10;      // the Pause bit; see pause_control.sv

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	logic [31:0] joy0 = 0, joy1 = 0;
	logic        ext_pause = 0;
	logic        pause_cpu, pause_latched;

	pause_control #(.PAUSE_BIT(PB)) dut (
		.clk(clk), .reset(reset),
		.joystick_0(joy0), .joystick_1(joy1),
		.ext_pause(ext_pause),
		.pause_cpu(pause_cpu), .pause_latched(pause_latched)
	);

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	// Press and release, holding for `hold` cycles. Takes a player INDEX, not a
	// `ref`: a non-blocking assignment may not target a ref argument. Blocking
	// assignment after the edge is sampled by the DUT on the next one.
	task automatic press(input int player, input int hold);
		@(posedge clk);
		if (player == 0) joy0[PB] = 1'b1; else joy1[PB] = 1'b1;
		repeat (hold) @(posedge clk);
		if (player == 0) joy0[PB] = 1'b0; else joy1[PB] = 1'b0;
		repeat (3) @(posedge clk);
	endtask

	initial begin
		$display("=== tb_pause ===");
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (3) @(posedge clk);

		check(pause_cpu == 1'b0 && pause_latched == 1'b0, "starts unpaused");

		// -------------------------------------------------------------
		$display("\n--- toggle on press ---");
		press(0, 1);
		check(pause_latched == 1'b1 && pause_cpu == 1'b1, "first press pauses");

		press(0, 1);
		check(pause_latched == 1'b0 && pause_cpu == 1'b0, "second press unpauses");

		$display("\n--- a long hold still toggles exactly once ---");
		press(0, 500);
		check(pause_latched == 1'b1, "held for 500 cycles: still one toggle");
		press(0, 500);
		check(pause_latched == 1'b0, "and one toggle back");

		// -------------------------------------------------------------
		$display("\n--- either player's button works ---");
		press(1, 2);
		check(pause_latched == 1'b1, "player 2 pauses");
		press(1, 2);
		check(pause_latched == 1'b0, "player 2 unpauses");

		// Buttons are ORed before the edge detector: a simultaneous press is one toggle.
		$display("\n--- both players at once is a single toggle ---");
		@(posedge clk);
		joy0[PB] = 1'b1; joy1[PB] = 1'b1;
		repeat (4) @(posedge clk);
		joy0[PB] = 1'b0; joy1[PB] = 1'b0;
		repeat (3) @(posedge clk);
		check(pause_latched == 1'b1, "simultaneous press toggles once");
		press(0, 2);
		check(pause_latched == 1'b0, "back to running");

		// -------------------------------------------------------------
		// ext_pause (hiscore RAM access, debug auto-pause) holds the CPU
		// without touching the user's latch.
		// -------------------------------------------------------------
		$display("\n--- internal pause reasons ---");
		ext_pause = 1'b1;
		repeat (3) @(posedge clk);
		check(pause_cpu == 1'b1 && pause_latched == 1'b0,
		      "ext_pause holds the CPU without setting the user toggle");
		ext_pause = 1'b0;
		repeat (3) @(posedge clk);
		check(pause_cpu == 1'b0, "releasing ext_pause resumes");

		$display("\n--- ext_pause while the user has paused ---");
		press(0, 2);
		check(pause_latched == 1'b1, "user paused");
		ext_pause = 1'b1;
		repeat (3) @(posedge clk);
		check(pause_cpu == 1'b1, "still paused with both reasons");
		ext_pause = 1'b0;
		repeat (3) @(posedge clk);
		check(pause_cpu == 1'b1 && pause_latched == 1'b1,
		      "releasing ext_pause does NOT clear the user's pause");

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#10ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
