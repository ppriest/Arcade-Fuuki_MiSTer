// spriteram_dbuf + line_buffer #(.WIDTH(16)). RUN FROM THE REPO ROOT.
//
// The two checks that matter here are the ones whose failures do not look like
// failures:
//
//  * COPY, NOT SWAP. Under ping-pong a record the CPU does not rewrite every
//    frame reads back what was written TWO frames ago. The test writes a
//    record once, then leaves it alone across several frames and requires the
//    CPU to keep reading it back. Ping-pong passes a single-frame test.
//
//  * TWO GENERATIONS, IN ORDER. FG-3 delays sprites by exactly two frames.
//    Copying live->buf0 before buf0->buf1 would collapse that to one, and the
//    symptom on screen is sprites arriving a frame early, which is not
//    obviously wrong in motion.

`timescale 1ns/1ps

module tb_spritebuf;

	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	// ---- spriteram_dbuf ----
	logic        board_fg3 = 1;
	logic [11:0] cpu_addr = 0;
	logic        cpu_wel = 0, cpu_weh = 0;
	logic [15:0] cpu_wdata = 0;
	logic [15:0] cpu_rdata;
	logic [31:0] tilebank_live = 0, tilebank_render;
	logic        copy_start = 0, copy_busy;
	logic [11:0] rd_addr = 0;
	logic [15:0] rd_data;

	spriteram_dbuf u_dbuf (
		.clk(clk), .reset(reset), .board_fg3(board_fg3),
		.cpu_addr(cpu_addr), .cpu_wel(cpu_wel), .cpu_weh(cpu_weh),
		.cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
		.tilebank_live(tilebank_live), .tilebank_render(tilebank_render),
		.copy_start(copy_start), .copy_busy(copy_busy),
		.rd_addr(rd_addr), .rd_data(rd_data)
	);

	// ---- line_buffer #(.WIDTH(16)) ----
	logic        lb_line_start = 0, lb_ready;
	logic        lb_we = 0;
	logic [8:0]  lb_wx = 0, lb_rx = 0;
	logic [15:0] lb_wdata = 0, lb_rdata;

	line_buffer #(.WIDTH(16)) u_lb (
		.clk(clk), .reset(reset),
		.line_start(lb_line_start), .ready(lb_ready),
		.we(lb_we), .wx(lb_wx), .wdata(lb_wdata),
		.rx(lb_rx), .rdata(lb_rdata)
	);

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	task automatic cpu_write(input int a, input logic [15:0] d);
		@(posedge clk);
		cpu_addr  <= 12'(a);
		cpu_wdata <= d;
		cpu_wel   <= 1'b1;
		cpu_weh   <= 1'b1;
		@(posedge clk);
		cpu_wel <= 1'b0;
		cpu_weh <= 1'b0;
	endtask

	task automatic cpu_read(input int a, output logic [15:0] d);
		@(posedge clk);
		cpu_addr <= 12'(a);
		@(posedge clk);   // registered read latency
		@(posedge clk);
		d = cpu_rdata;
	endtask

	task automatic render_read(input int a, output logic [15:0] d);
		@(posedge clk);
		rd_addr <= 12'(a);
		@(posedge clk);
		@(posedge clk);
		d = rd_data;
	endtask

	// One frame boundary: pulse copy_start and wait out the copy.
	task automatic frame;
		@(posedge clk);
		copy_start <= 1'b1;
		@(posedge clk);
		copy_start <= 1'b0;
		@(posedge clk);
		if (board_fg3) begin
			// do/while, never while/do -- the latter races the always_ff
			// updating copy_busy on the same edge.
			do @(posedge clk); while (copy_busy);
		end
	endtask

	logic [15:0] v;

	initial begin
		$display("=== tb_spritebuf ===");
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// =============================================================
		$display("\n--- FG-3: two generations of delay ---");
		board_fg3 = 1;

		cpu_write(12'h010, 16'hAAAA);
		frame;                                    // buf0 = AAAA
		render_read(12'h010, v);
		check(v !== 16'hAAAA, "after 1 frame the render side does NOT yet see it");

		frame;                                    // buf1 = AAAA
		render_read(12'h010, v);
		check(v === 16'hAAAA, "after 2 frames the render side sees it");

		// Order check: a value written and then immediately superseded must
		// still appear on the render side two frames later, in sequence. If
		// the passes ran in the wrong order, BBBB would overtake AAAA.
		cpu_write(12'h010, 16'hBBBB);
		frame;
		render_read(12'h010, v);
		check(v === 16'hAAAA, "generations advance in order (AAAA still showing)");
		frame;
		render_read(12'h010, v);
		check(v === 16'hBBBB, "the newer value arrives exactly one frame later");

		// =============================================================
		// A swap would pass everything above. This is what separates them.
		$display("\n--- copy, not swap: a stale record survives many frames ---");
		cpu_write(12'h100, 16'h1234);
		for (int i = 0; i < 6; i++) frame;        // never rewritten
		cpu_read(12'h100, v);
		check(v === 16'h1234, "CPU still reads back its own record after 6 frames");
		render_read(12'h100, v);
		check(v === 16'h1234, "render side sees the same record, not a stale bank");

		// =============================================================
		$display("\n--- tile bank is delayed in lockstep with the data ---");
		tilebank_live = 32'hDEADBEEF;
		frame;
		check(tilebank_render !== 32'hDEADBEEF, "tile bank not yet visible after 1 frame");
		frame;
		check(tilebank_render === 32'hDEADBEEF, "tile bank visible after 2 frames");

		// =============================================================
		$display("\n--- FG-2: no buffering, render sees live immediately ---");
		board_fg3 = 0;
		cpu_write(12'h020, 16'hC0DE);
		render_read(12'h020, v);
		check(v === 16'hC0DE, "FG-2 render port reads the live RAM with no delay");
		frame;
		check(copy_busy === 1'b0, "FG-2 runs no copy at all");

		// =============================================================
		$display("\n--- line buffer: swap, clear, ready ---");
		@(posedge clk);
		lb_line_start <= 1'b1;
		@(posedge clk);
		lb_line_start <= 1'b0;
		check(lb_ready === 1'b0, "ready drops while the new render bank is cleared");
		begin
			int n;
			n = 0;
			do begin @(posedge clk); n++; end while (!lb_ready);
			$display("  clear took %0d cycles (320 expected, 5472 available)", n);
			check(n <= 330, "clear fits comfortably inside the line budget");
		end

		// Write the render bank, then swap and read it back on the display side.
		for (int x = 0; x < 8; x++) begin
			@(posedge clk);
			lb_we    <= 1'b1;
			lb_wx    <= 9'(x);
			lb_wdata <= 16'hE000 | 16'(x);       // opaque, priority 3, index x
		end
		@(posedge clk);
		lb_we <= 1'b0;

		@(posedge clk);
		lb_line_start <= 1'b1;
		@(posedge clk);
		lb_line_start <= 1'b0;
		do @(posedge clk); while (!lb_ready);

		begin
			bit ok;
			ok = 1;
			for (int x = 0; x < 8; x++) begin
				@(posedge clk);
				lb_rx <= 9'(x);
				@(posedge clk);
				@(posedge clk);
				if (lb_rdata !== (16'hE000 | 16'(x))) begin
					$display("    x=%0d read %04x expected %04x", x, lb_rdata, 16'hE000 | 16'(x));
					ok = 0;
				end
			end
			check(ok, "written pixels read back from the display bank after a swap");
		end

		// And the freshly swapped render bank must be clear, not stale.
		begin
			bit clean;
			clean = 1;
			for (int x = 0; x < 8; x++) begin
				@(posedge clk);
				lb_rx <= 9'(x);
				@(posedge clk);
				@(posedge clk);
			end
			@(posedge clk);
			lb_line_start <= 1'b1;
			@(posedge clk);
			lb_line_start <= 1'b0;
			do @(posedge clk); while (!lb_ready);
			for (int x = 0; x < 8; x++) begin
				@(posedge clk);
				lb_rx <= 9'(x);
				@(posedge clk);
				@(posedge clk);
				if (lb_rdata !== 16'd0) clean = 0;
			end
			check(clean, "a bank is clear when it comes back round (no stale pixels)");
		end

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#50ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
