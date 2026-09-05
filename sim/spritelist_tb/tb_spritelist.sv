// sprite_line_list against the REAL captured spriteram.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh spritelist_tb).
// Reads debug/gogomile-title/fg2_spriteram.bin directly -- the same 8 KB MAME
// was rendering from when it drew debug/gogomile-title/0000.png.
//
// The expected answer was derived INDEPENDENTLY, by decoding that file in
// Python against fuukispr.cpp, not by running this RTL and writing down what
// it produced. At the title screen exactly two records survive:
//
//   record 1000   (105, 108)  2x2 tiles, span 32x32, pri 0, col 32
//   record  148   (260, 230)  4x1 tiles, span 64x16, pri 0, col  8   "CREDIT 0"
//
// and they pin the depth order too. The scan runs from record 1023 down to 0,
// so record 1000 is found FIRST and record 148 LAST -- which is what makes 148
// win, since the engine renders the list in order and later writes overwrite
// earlier ones. A forward scan would produce the same two entries in the
// opposite order and silently invert sprite depth.

`timescale 1ns/1ps

module tb_spritelist;

	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	logic        build_start = 0;
	logic        build_busy;
	logic [10:0] n_entries;

	logic [11:0] sr_addr;
	logic [15:0] sr_data;

	logic [9:0]  yt_addr = 0;
	logic [18:0] yt_data;
	logic [9:0]  rec_addr = 0;
	logic [63:0] rec_data;

	sprite_line_list dut (
		.clk(clk), .reset(reset),
		.build_start(build_start), .build_busy(build_busy), .n_entries(n_entries),
		.sr_addr(sr_addr), .sr_data(sr_data),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data)
	);

	// Sprite RAM model: registered read, like the real one.
	logic [15:0] sram [0:4095];
	always_ff @(posedge clk) sr_data <= sram[sr_addr];

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	int cyc = 0;
	always @(posedge clk) cyc <= cyc + 1;

	task automatic read_entry(input int i,
	                          output logic [18:0] yt,
	                          output logic [63:0] rc);
		@(posedge clk);
		yt_addr  <= 10'(i);
		rec_addr <= 10'(i);
		@(posedge clk);
		@(posedge clk);
		yt = yt_data;
		rc = rec_data;
	endtask

	logic [18:0] yt0, yt1;
	logic [63:0] rc0, rc1;
	int t0, build_cycles;

	initial begin
		$display("=== tb_spritelist: gogomile title, real spriteram ===");

		begin
			int f, n;
			byte unsigned vbuf [];      // NOT `buf` -- a Verilog gate primitive
			f = $fopen("debug/gogomile-title/fg2_spriteram.bin", "rb");
			if (f == 0) begin
				$display("FATAL: debug/gogomile-title/fg2_spriteram.bin not found.");
				$display("       Capture one with:");
				$display("       python scripts/mame_capture.py gogomile --frame 1100 --name gogomile-title");
				$finish;
			end
			vbuf = new [8192];
			n = $fread(vbuf, f);
			$fclose(f);
			for (int i = 0; i < n/2; i++) sram[i] = {vbuf[2*i], vbuf[2*i+1]};
			$display("  spriteram loaded: %0d bytes", n);
			check(n == 8192, "captured spriteram is 8 KB");
		end

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// ---- build ----
		@(posedge clk);
		build_start <= 1'b1;
		@(posedge clk);
		build_start <= 1'b0;
		t0 = cyc;
		// do/while, never while/do: the latter races the always_ff updating
		// build_busy on the same edge.
		do @(posedge clk); while (build_busy);
		build_cycles = cyc - t0;

		$display("\n--- build ---");
		$display("  %0d entries, %0d cycles (vblank has 120384)", n_entries, build_cycles);
		check(build_cycles < 120384, "the build fits inside vblank");
		check(n_entries == 11'd2, "exactly two records survive, as MAME's own state says");

		if (n_entries == 11'd2) begin
			read_entry(0, yt0, rc0);
			read_entry(1, yt1, rc1);

			$display("  entry 0: y_top %0d span %0d  words %04x %04x %04x %04x",
			         $signed(yt0[18:9]), yt0[8:0],
			         rc0[63:48], rc0[47:32], rc0[31:16], rc0[15:0]);
			$display("  entry 1: y_top %0d span %0d  words %04x %04x %04x %04x",
			         $signed(yt1[18:9]), yt1[8:0],
			         rc1[63:48], rc1[47:32], rc1[31:16], rc1[15:0]);

			// Record 1000 is at (105,108), 2x2 tiles -> span 32.
			check($signed(yt0[18:9]) == 108 && yt0[8:0] == 9'd32,
			      "entry 0 is record 1000: y 108, span 32");
			check(rc0[15:0] == 16'h16d1, "entry 0 carries record 1000's tile code");

			// Record 148 is "CREDIT 0" at (260,230), 4x1 tiles -> span 16.
			check($signed(yt1[18:9]) == 230 && yt1[8:0] == 9'd16,
			      "entry 1 is record 148: y 230, span 16");
			check(rc1[15:0] == 16'h3dbb, "entry 1 carries record 148's tile code");

			// The depth check. Record 148 must come LAST so it wins.
			check(rc1[15:0] == 16'h3dbb && rc0[15:0] == 16'h16d1,
			      "backward scan puts the LOWER record number last (it wins)");
		end

		// A second build must produce the same answer -- n_entries has to be
		// cleared on start, not accumulated.
		@(posedge clk);
		build_start <= 1'b1;
		@(posedge clk);
		build_start <= 1'b0;
		do @(posedge clk); while (build_busy);
		check(n_entries == 11'd2, "a second build gives the same count, not double");

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
