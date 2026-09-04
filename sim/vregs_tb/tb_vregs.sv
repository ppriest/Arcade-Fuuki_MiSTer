// vregs checks. RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh).
//
// The scroll expectations below are HAND-COMPUTED from fuukitmap.cpp's
// prepare(), not re-derived from the same formula the DUT uses. Re-deriving
// would make the test agree with the RTL by construction and prove nothing --
// including, in particular, the deliberate x/y offset pairing that looks like
// a bug and is not.

`timescale 1ns/1ps

module tb_vregs;

	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	logic        board_fg3 = 0;
	logic [4:0]  cpu_addr = 0;
	logic [1:0]  cpu_sel = 0;
	logic        cpu_wel = 0, cpu_weh = 0;
	logic [15:0] cpu_wdata = 0;
	logic [15:0] cpu_rdata;

	logic [15:0] l0x, l0y, l1x, l1y, l2x, l2y;
	logic        flip, layer2_buffer;
	logic [8:0]  raster_line;
	logic [1:0]  tf, tm, tb;

	vregs dut (
		.clk(clk), .reset(reset), .board_fg3(board_fg3),
		.cpu_addr(cpu_addr), .cpu_sel(cpu_sel),
		.cpu_wel(cpu_wel), .cpu_weh(cpu_weh),
		.cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
		.layer0_scrollx(l0x), .layer0_scrolly(l0y),
		.layer1_scrollx(l1x), .layer1_scrolly(l1y),
		.layer2_scrollx(l2x), .layer2_scrolly(l2y),
		.flip(flip), .layer2_buffer(layer2_buffer), .raster_line(raster_line),
		.tmap_front(tf), .tmap_middle(tm), .tmap_back(tb)
	);

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	task automatic check16(input logic [15:0] got, input logic [15:0] exp,
	                       input string what);
		if (got === exp) $display("  PASS  %s (%04x)", what, got);
		else begin
			$display("  FAIL  %s: got %04x expected %04x", what, got, exp);
			errors++;
		end
	endtask

	// Write one 16-bit register (both byte lanes).
	task automatic wr(input logic [1:0] sel, input logic [4:0] a,
	                  input logic [15:0] d);
		@(posedge clk);
		cpu_sel   <= sel;
		cpu_addr  <= a;
		cpu_wdata <= d;
		cpu_wel   <= 1'b1;
		cpu_weh   <= 1'b1;
		@(posedge clk);
		cpu_wel   <= 1'b0;
		cpu_weh   <= 1'b0;
		@(posedge clk);
	endtask

	initial begin
		$display("=== tb_vregs ===");
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (2) @(posedge clk);

		// -------------------------------------------------------------
		$display("\n--- register file read/write ---");
		wr(2'd0, 5'h0, 16'h1234);
		wr(2'd0, 5'h5, 16'hABCD);
		wr(2'd1, 5'h0, 16'h5678);
		wr(2'd2, 5'h0, 16'h0003);

		@(posedge clk);
		cpu_sel = 2'd0; cpu_addr = 5'h0; #1;
		check16(cpu_rdata, 16'h1234, "regs[0] reads back");
		cpu_sel = 2'd0; cpu_addr = 5'h5; #1;
		check16(cpu_rdata, 16'hABCD, "regs[5] reads back");
		cpu_sel = 2'd1; cpu_addr = 5'h0; #1;
		check16(cpu_rdata, 16'h5678, "unknown block reads back");
		cpu_sel = 2'd2; cpu_addr = 5'h0; #1;
		check16(cpu_rdata, 16'h0003, "priority reads back");

		// -------------------------------------------------------------
		$display("\n--- flip / layer2 buffer / raster line (reg 0x1e, 0x1c) ---");
		wr(2'd0, 5'hE, 16'h00F5);      // 0x1c: raster line 245
		wr(2'd0, 5'hF, 16'h0041);      // 0x1e: bit 0 flip, bit 6 buffer
		#1;
		check(raster_line == 9'd245, "raster_line from 0x1c");
		check(flip == 1'b1,          "flip from 0x1e bit 0");
		check(layer2_buffer == 1'b1, "layer2_buffer from 0x1e bit 6");

		wr(2'd0, 5'hF, 16'h0000);
		#1;
		check(flip == 1'b0 && layer2_buffer == 1'b0, "flip/buffer clear again");

		// -------------------------------------------------------------
		// Hand-computed from prepare(), FG-2, flip off:
		//   scrolly_offs = vregs[0xc] - xoffs = 0x0200 - 0x01F3 = 0x000D
		//   scrollx_offs = vregs[0xe] - yoffs = 0x0400 - 0x03F6 = 0x000A
		//                                  ^^ the deliberate pairing
		//   layer0_scrolly = vregs[0x0] + scrolly_offs = 0x0010 + 0x000D = 0x001D
		//   layer0_scrollx = vregs[0x2] + scrollx_offs = 0x0020 + 0x000A = 0x002A
		//   layer1_scrolly = vregs[0x4] + scrolly_offs = 0x0030 + 0x000D = 0x003D
		//   layer1_scrollx = vregs[0x6] + scrollx_offs = 0x0040 + 0x000A = 0x004A
		//   layer2_scrolly = vregs[0x8]                = 0x0050  (no offsets)
		//   layer2_scrollx = vregs[0xa] + layer2_xoffs = 0x0060 + 0x10 = 0x0070
		// -------------------------------------------------------------
		$display("\n--- scroll decode, FG-2, flip off ---");
		wr(2'd0, 5'h0, 16'h0010);   // 0x00 layer0 Y
		wr(2'd0, 5'h1, 16'h0020);   // 0x02 layer0 X
		wr(2'd0, 5'h2, 16'h0030);   // 0x04 layer1 Y
		wr(2'd0, 5'h3, 16'h0040);   // 0x06 layer1 X
		wr(2'd0, 5'h4, 16'h0050);   // 0x08 layer2 Y
		wr(2'd0, 5'h5, 16'h0060);   // 0x0a layer2 X
		wr(2'd0, 5'h6, 16'h0200);   // 0x0c Y offset
		wr(2'd0, 5'h7, 16'h0400);   // 0x0e X offset
		#1;
		check16(l0y, 16'h001D, "layer0 scrollY");
		check16(l0x, 16'h002A, "layer0 scrollX");
		check16(l1y, 16'h003D, "layer1 scrollY");
		check16(l1x, 16'h004A, "layer1 scrollX");
		check16(l2y, 16'h0050, "layer2 scrollY (no global offset)");
		check16(l2x, 16'h0070, "layer2 scrollX (+0x10 on FG-2)");

		// FG-3 drops layer 2's x offset; everything else is unchanged.
		$display("\n--- same registers, FG-3 ---");
		board_fg3 = 1; #1;
		check16(l2x, 16'h0060, "layer2 scrollX has no +0x10 on FG-3");
		check16(l0y, 16'h001D, "layer0 scrollY unchanged between boards");
		board_fg3 = 0; #1;

		// -------------------------------------------------------------
		// Underflow must WRAP, as u16 does in MAME. All-zero registers give
		// 0 - 0x1F3 = 0xFE0D and 0 - 0x3F6 = 0xFC0A.
		// -------------------------------------------------------------
		$display("\n--- 16-bit wrap on underflow ---");
		wr(2'd0, 5'h0, 16'h0000);
		wr(2'd0, 5'h1, 16'h0000);
		wr(2'd0, 5'h6, 16'h0000);
		wr(2'd0, 5'h7, 16'h0000);
		#1;
		check16(l0y, 16'hFE0D, "layer0 scrollY wraps (0 - 0x1F3)");
		check16(l0x, 16'hFC0A, "layer0 scrollX wraps (0 - 0x3F6)");

		// -------------------------------------------------------------
		$display("\n--- layer order table ---");
		begin
			// front, middle, back for priority 0..5, from fuukitmap.cpp.
			logic [1:0] ef [0:5]; logic [1:0] em [0:5]; logic [1:0] eb [0:5];
			ef[0]=0; em[0]=1; eb[0]=2;
			ef[1]=0; em[1]=2; eb[1]=1;
			ef[2]=1; em[2]=0; eb[2]=2;
			ef[3]=1; em[3]=2; eb[3]=0;
			ef[4]=2; em[4]=0; eb[4]=1;
			ef[5]=2; em[5]=1; eb[5]=0;
			for (int p = 0; p < 6; p++) begin
				wr(2'd2, 5'h0, 16'(p));
				#1;
				check(tf == ef[p] && tm == em[p] && tb == eb[p],
				      $sformatf("priority %0d -> front %0d middle %0d back %0d",
				                p, ef[p], em[p], eb[p]));
			end

			// 6-15 index past MAME's six-entry table. Whatever the ASIC does,
			// this must be DEFINED and must not be X.
			for (int p = 6; p < 16; p++) begin
				wr(2'd2, 5'h0, 16'(p));
				#1;
				if ($isunknown({tf, tm, tb})) begin
					$display("  FAIL  priority %0d produced X", p);
					errors++;
				end
			end
			check(1'b1, "priority 6-15 produce a defined order (no X)");
		end

		// =============================================================
		// Real captured state: gogomile title screen.
		//
		// Values dumped straight out of MAME with
		//     save fg2_vregs.bin,0x8c0000,0x20
		// (debug/gogomile-title/, alongside the screenshot they produced).
		// Every other case here was hand-derived; this one is what the game
		// actually writes, so it is the case that cannot be wrong for the
		// same reason the RTL might be.
		//
		// It settles the x/y offset pairing EMPIRICALLY. The game writes
		// 0x01f3 to the Y offset register and 0x03f6 to the X offset
		// register -- exactly the board XOFFS and YOFFS constants -- so the
		// paired subtraction gives a net offset of ZERO on both axes, which
		// is plainly the intent. Had the pairing been "corrected" to match
		// the register names, it would yield -0x203 and +0x203 and put the
		// whole picture 515 pixels out.
		// =============================================================
		$display("
--- real capture: gogomile title screen ---");
		wr(2'd0, 5'h0, 16'h0000);   // L0 scrollY
		wr(2'd0, 5'h1, 16'h0000);   // L0 scrollX
		wr(2'd0, 5'h2, 16'h0000);   // L1 scrollY
		wr(2'd0, 5'h3, 16'h0000);   // L1 scrollX
		wr(2'd0, 5'h4, 16'h0000);   // L2 scrollY
		wr(2'd0, 5'h5, 16'h0010);   // L2 scrollX
		wr(2'd0, 5'h6, 16'h01f3);   // Layers Y offset == XOFFS
		wr(2'd0, 5'h7, 16'h03f6);   // Layers X offset == YOFFS
		wr(2'd0, 5'hE, 16'hfffe);   // raster IRQ line -- see below
		wr(2'd0, 5'hF, 16'h3390);   // flip off (driver: "$3390/$3393")
		wr(2'd2, 5'h0, 16'h0003);   // priority
		#1;
		check16(l0x, 16'h0000, "capture: layer0 scrollX is exactly 0");
		check16(l0y, 16'h0000, "capture: layer0 scrollY is exactly 0");
		check16(l1x, 16'h0000, "capture: layer1 scrollX is exactly 0");
		check16(l1y, 16'h0000, "capture: layer1 scrollY is exactly 0");
		check16(l2y, 16'h0000, "capture: layer2 scrollY is exactly 0");
		check16(l2x, 16'h0020, "capture: layer2 scrollX is 0x10 + 0x10 board offset");
		check(flip == 1'b0,          "capture: flip screen off");
		check(layer2_buffer == 1'b0, "capture: layer2 buffer 0");
		check(tf == 2'd1 && tm == 2'd2 && tb == 2'd0,
		      "capture: priority 3 -> front 1, middle 2, back 0");

		// The game parks the raster line at 0xfffe when it wants NO raster
		// interrupt. Only the low 9 bits can reach a 0..261 line counter and
		// 0x1fe = 510 is unreachable, so video_timing never fires it -- which
		// is plainly the intent. Recorded because MAME does NOT behave this
		// way: screen_device::time_until_pos() takes vpos modulo the screen
		// height, so 0xfffe wraps onto a real line and fires a raster IRQ the
		// hardware almost certainly does not. See docs/ROADMAP.md.
		check(raster_line == 9'h1fe, "capture: raster line 0xfffe -> 0x1fe, unreachable");

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
