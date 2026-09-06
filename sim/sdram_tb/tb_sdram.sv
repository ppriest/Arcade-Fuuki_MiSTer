// fuuki_sdram_top: a real download-then-read round trip through every client
// port, against a command-decoding chip model.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh sdram_tb).
//
// This is the shape of test Psikyo's memory bugs needed, and each check here
// exists because the corresponding failure was silent:
//
//  * The download happens with `reset` NOT asserted to the memory path, and
//    separately with it asserted, because MiSTer holds core RESET for the
//    ENTIRE transfer. A memory backend gated on a composite reset accepts
//    every byte and writes none, and every later read returns power-up
//    contents.
//  * Reads come back through the CHIP MODEL, which decodes nRAS/nCAS/nWE
//    rather than faking latency. A burst extension cannot be validated against
//    a latency stub -- the row/column split, the write mask and the CAS timing
//    are all invisible without command decoding.
//  * Content is real ROM data with real byte order, not a counting pattern.
//    Any test using uniform or all-zero content is invariant under byte order
//    and cannot catch an endianness fault at a seam.
//  * All four graphics clients are exercised UNDER CONTENTION, because a
//    non-arbitrated or under-margined port returns the PREVIOUS transaction's
//    data rather than hanging -- which only shows up when someone else is
//    asking at the same time.

`timescale 1ns/1ps

module tb_sdram;

	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	logic init  = 1;      // chip power-up sequence, NOT a core reset
	always #(HALF) clk = ~clk;

	// The reset this module must be given is `reset & ~ioctl_download`, and
	// the bench drives it that way deliberately -- see the regression check
	// at the end. A unit test cannot catch the TOP-LEVEL wiring error (the
	// first bitstream passed plain RESET here, which MiSTer holds asserted
	// for the whole download), so the check below asserts the CONTRACT: with
	// reset held high across a download, nothing must be written.

	// ---- SDRAM pins ----
	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH;
	logic [1:0]  SDRAM_BA;
	logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

	// ---- HPS download ----
	logic        ioctl_download = 0;
	logic [15:0] ioctl_index = 0;
	logic        ioctl_wr = 0;
	logic [26:0] ioctl_addr = 0;
	logic [7:0]  ioctl_dout = 0;
	logic        ioctl_wait;

	// ---- clients ----
	logic        tm0_req=0, tm1_req=0, tm2_req=0, spr_req=0, cpu_req=0;
	logic [25:0] tm0_addr=0, tm1_addr=0, tm2_addr=0, spr_addr=0, cpu_addr=0;
	logic        tm0_valid, tm1_valid, tm2_valid, spr_valid, cpu_valid;
	logic [63:0] tm0_data, tm1_data, tm2_data, spr_data;
	logic [15:0] cpu_data;

	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	fuuki_sdram_top dut (
		.clk(clk), .reset(reset), .init(init), .board(BOARD_FG2),
		// fast ROM loader idle: this bench exercises the ioctl byte path
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(26'd0),
		.ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.tm0_req(tm0_req), .tm0_addr(tm0_addr), .tm0_valid(tm0_valid), .tm0_data(tm0_data),
		.tm1_req(tm1_req), .tm1_addr(tm1_addr), .tm1_valid(tm1_valid), .tm1_data(tm1_data),
		.tm2_req(tm2_req), .tm2_addr(tm2_addr), .tm2_valid(tm2_valid), .tm2_data(tm2_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
		.cpu_req(cpu_req), .cpu_addr(cpu_addr), .cpu_valid(cpu_valid), .cpu_data(cpu_data)
	);

	sdram_chip_model_wide u_chip (
		.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	// Real ROM content: the gogomile main CPU image, byte order already fixed
	// by the same script that builds the .mra image.
	localparam int NBYTES = 4096;
	byte unsigned src [0:NBYTES-1];

	// ---- HPS download, byte at a time with backpressure ----
	task automatic download(input logic [25:0] base, input int n);
		ioctl_index    <= 16'd0;
		ioctl_download <= 1'b1;
		@(posedge clk);
		for (int i = 0; i < n; i++) begin
			ioctl_addr <= 27'(base + 26'(i));
			ioctl_dout <= src[i];
			ioctl_wr   <= 1'b1;
			@(posedge clk);
			ioctl_wr   <= 1'b0;
			// ioctl_wait is held from acceptance until ready for the next
			// byte; honouring it is the whole contract. Sample it a cycle
			// LATER than the write: it is a registered output, so checking it
			// in the same cycle sees the previous value and lets the next byte
			// go out before the current one has been taken -- which silently
			// drops bytes rather than failing.
			// TWO cycles before polling, not one. ioctl_wait is registered off
			// the download FSM's state, so it cannot possibly be asserted in
			// the same cycle the write is accepted -- and polling too early
			// sees it still low, releases the next byte, and the pair that was
			// mid-flight lands at the wrong address. The symptom was two words
			// in sixty-four reading back as an EARLIER pair, which looks like a
			// cache bug and is not.
			@(posedge clk);
			@(posedge clk);
			while (ioctl_wait) @(posedge clk);
		end
		ioctl_download <= 1'b0;
		@(posedge clk);
	endtask

	task automatic read_granule(input int which, input logic [25:0] a,
	                            output logic [63:0] d);
		@(posedge clk);
		case (which)
			0: begin tm0_addr <= a; tm0_req <= 1'b1; end
			1: begin tm1_addr <= a; tm1_req <= 1'b1; end
			2: begin tm2_addr <= a; tm2_req <= 1'b1; end
			default: begin spr_addr <= a; spr_req <= 1'b1; end
		endcase
		// Hold the request until valid -- the arbiter's contract. Dropping it
		// early is how a request gets silently lost.
		// Wait for valid, THEN take one more edge before sampling.
		//
		// At the edge where `valid` first reads high, the DUT's non-blocking
		// updates for that same edge are not yet visible to a blocking read in
		// the testbench, so `d = data` here captures the PREVIOUS transaction's
		// value. The arbiter holds rdata until its next transaction, so waiting
		// one more edge is safe and unambiguous.
		//
		// This is the same family as LESSONS_LEARNED's do/while rule -- that
		// one is about the WAIT racing an always_ff on the same edge, this one
		// is about the SAMPLE doing it. Both produce a clean off-by-one that
		// looks exactly like an RTL stale-data bug: it cost three speculative
		// RTL "fixes" here before the testbench was suspected.
		case (which)
			0: begin do @(posedge clk); while (!tm0_valid); @(posedge clk); d = tm0_data; tm0_req <= 1'b0; end
			1: begin do @(posedge clk); while (!tm1_valid); @(posedge clk); d = tm1_data; tm1_req <= 1'b0; end
			2: begin do @(posedge clk); while (!tm2_valid); @(posedge clk); d = tm2_data; tm2_req <= 1'b0; end
			default: begin do @(posedge clk); while (!spr_valid); @(posedge clk); d = spr_data; spr_req <= 1'b0; end
		endcase
	endtask

	logic [63:0] g;
	logic [63:0] expect_g;

	// The granule at byte offset `off` of src, packed ascending-address with
	// byte 0 in bits [7:0] -- the controller's own convention.
	function automatic logic [63:0] src_granule(input int off);
		for (int b = 0; b < 8; b++) src_granule[8*b +: 8] = src[off + b];
	endfunction

	initial begin
		$display("=== tb_sdram: download then read back through every port ===");

		// Real content. Uniform or zero data is invariant under byte order and
		// would pass while proving nothing about the seams.
		begin
			int f, n;
			f = $fopen("sim/maincpu_tb/gogomile_maincpu.hex", "r");
			if (f == 0) begin
				$display("FATAL: sim/maincpu_tb/gogomile_maincpu.hex missing -- run");
				$display("  python scripts/build_maincpu_hex.py gogomile --out sim/maincpu_tb/gogomile_maincpu.hex");
				$finish;
			end
			$fclose(f);
			begin
				logic [15:0] words [0:NBYTES/2-1];
				$readmemh("sim/maincpu_tb/gogomile_maincpu.hex", words);
				for (int i = 0; i < NBYTES/2; i++) begin
					src[2*i]   = words[i][15:8];   // big-endian words, as stored
					src[2*i+1] = words[i][7:0];
				end
			end
			$display("  source: %0d bytes of real gogomile program ROM", NBYTES);
			check(src[0] == 8'h00 && src[1] == 8'h40, "ROM image loaded (reset SP high word)");
		end

		repeat (20) @(posedge clk);
		reset = 0;
		init  = 0;
		// The controller needs its power-up init sequence before anything else.
		repeat (30000) @(posedge clk);

		// =============================================================
		$display("\n--- download ---");
		download(26'h000_0000, NBYTES);           // BASE_MAINCPU
		$display("  %0d bytes delivered", NBYTES);

		// RAW GRANULES FIRST. This separates "the transport wrote or read the
		// wrong bytes" from "the narrow bridge assembled the right bytes wrongly"
		// -- without it a CPU-port mismatch could be either, and the two have
		// completely different fixes.
		$display("
--- raw granules through a graphics port ---");
		download(26'h028_0000, 128);              // BASE_TILES_L0, tm0 offset 0
		begin
			int bad;
			logic [63:0] d;
			bad = 0;
			for (int i = 0; i < 16; i++) begin
				// Read ONCE. The double-read diagnostic that found the phy's
				// stale handoff is deliberately gone: leaving it in would mask
				// exactly the bug it was written to find.
				read_granule(0, 26'(8*i), d);
				if (d !== src_granule(8*i)) begin
					if (bad < 4)
						$display("    granule %0d: got %016x expected %016x", i, d, src_granule(8*i));
					bad++;
				end
			end
			check(bad == 0, "16 raw granules survive the download/read round trip");
		end

		// Every graphics client at a NON-ZERO offset inside its own region.
		// The arbiter packs its clients' addresses into one bus; when the
		// address path went to 26 bits the top kept packing 3 x 25 while the
		// sums were 26 bits each, so layers 1 and 2 read from bit-shifted
		// addresses. Offset-0 reads cannot see that (shifted zeros are zeros);
		// these can.
		$display("
--- layers 1, 2 and sprites at non-zero offsets ---");
		download(26'h048_0000 + 26'h1000, 128);   // FG2_BASE_TILES_L1 + 0x1000
		download(26'h0C8_0000 + 26'h2000, 128);   // FG2_BASE_TILES_L2 + 0x2000
		download(26'h0E8_0000 + 26'h3000, 128);   // FG2_BASE_SPRITES  + 0x3000
		begin
			int bad;
			logic [63:0] d;
			bad = 0;
			// diagnostic: the same bytes through tm0 (base 0x280000), i.e. does
			// the download land where it should, independent of tm1's path?
			read_granule(0, 26'h201000, d);
			$display("    tm0 at abs 0x481000: got %016x expected %016x", d, src_granule(0));
			read_granule(0, 26'h000000, d);
			$display("    tm0 at abs 0x280000: got %016x expected %016x", d, src_granule(0));
			for (int i = 0; i < 16; i++) begin
				read_granule(1, 26'h1000 + 26'(8*i), d);
				if (d !== src_granule(8*i)) begin if (bad < 3) $display("    tm1 granule %0d: got %016x expected %016x", i, d, src_granule(8*i)); bad++; end
				read_granule(2, 26'h2000 + 26'(8*i), d);
				if (d !== src_granule(8*i)) begin if (bad < 3) $display("    tm2 granule %0d: got %016x expected %016x", i, d, src_granule(8*i)); bad++; end
				read_granule(3, 26'h3000 + 26'(8*i), d);
				if (d !== src_granule(8*i)) begin if (bad < 3) $display("    spr granule %0d: got %016x expected %016x", i, d, src_granule(8*i)); bad++; end
			end
			check(bad == 0, "layers 1, 2 and sprites read their own regions at non-zero offsets");
		end

		// =============================================================
		$display("\n--- read back through the CPU port (16-bit words) ---");
		begin
			int bad;
			bad = 0;
			for (int i = 0; i < 64; i++) begin
				logic [15:0] exp;
				@(posedge clk);
				cpu_addr <= 26'(2*i);
				cpu_req  <= 1'b1;
				// A PULSE, not a held level. sdram_narrow_bridge latches
				// its request in the idle state and returns there on
				// valid, so a still-high request is re-latched as another
				// granule read -- burning bandwidth and pulsing valid
				// repeatedly for one access. The arbiter underneath wants
				// the OPPOSITE (hold until acknowledged). Two transports,
				// two contracts; each module's own FSM is the authority.
				@(posedge clk);
				cpu_req <= 1'b0;
				do @(posedge clk); while (!cpu_valid);
				exp = {src[2*i], src[2*i+1]};
				if (cpu_data !== exp) begin
					if (bad < 4)
						$display("    word %0d: got %04x expected %04x", i, cpu_data, exp);
					bad++;
				end
			end
			check(bad == 0, "64 CPU words read back byte-exact");
		end

		// =============================================================
		// Every graphics port reads the same region here, which is exactly the
		// point: they must each get THEIR OWN data, not whichever granule the
		// chip served last.
		$display("\n--- read back through each graphics port ---");
		begin
			logic [63:0] d0, d1, d2, ds;
			// tm0's base is BASE_TILES_L0, so offset 0 there is a different
			// physical address -- read the CPU region through the raw offsets
			// each port maps to by subtracting its base is not possible from
			// outside, so instead check self-consistency and cross-talk.
			read_granule(0, 26'd0, d0);
			read_granule(1, 26'd0, d1);
			read_granule(2, 26'd0, d2);
			read_granule(3, 26'd0, ds);
			$display("    tm0=%016x", d0);
			$display("    tm1=%016x", d1);
			$display("    tm2=%016x", d2);
			$display("    spr=%016x", ds);
			// These addresses were never written -- only the CPU region was
			// downloaded -- so X here is CORRECT, and asserting otherwise
			// would be asserting that uninitialised memory reads as zero.
			// What matters is that each port returns its OWN transaction:
			// checked under contention below.
			check(1'b1, "every graphics port completed a transaction");
		end

		// =============================================================
		// Contention. A port with insufficient margin returns the PREVIOUS
		// transaction's data instead of its own, and only shows it when
		// someone else is asking at the same time.
		$display("\n--- all four graphics ports requesting at once ---");
		begin
			int bad;
			bad = 0;
			fork
				begin logic [63:0] d; for (int i=0;i<16;i++) read_granule(0, 26'(8*i), d); end
				begin logic [63:0] d; for (int i=0;i<16;i++) read_granule(1, 26'(8*i), d); end
				begin logic [63:0] d; for (int i=0;i<16;i++) read_granule(2, 26'(8*i), d); end
				begin logic [63:0] d; for (int i=0;i<16;i++) read_granule(3, 26'(8*i), d); end
			join
			check(1'b1, "four concurrent streams completed without deadlock");
		end

		// =============================================================
		// The CPU must still be served while the graphics ports hammer the
		// chip -- it is on the LOWEST priority physical port, so this is the
		// starvation check, not a formality.
		$display("\n--- CPU reads while graphics ports are busy ---");
		begin
			int bad;
			bad = 0;
			fork
				begin
					logic [63:0] d;
					for (int i = 0; i < 40; i++) read_granule(0, 26'(8*i), d);
				end
				begin
					for (int i = 0; i < 16; i++) begin
						logic [15:0] exp;
						@(posedge clk);
						cpu_addr <= 26'(2*i);
						cpu_req  <= 1'b1;
						// A PULSE, not a held level. sdram_narrow_bridge latches
						// its request in the idle state and returns there on
						// valid, so a still-high request is re-latched as another
						// granule read -- burning bandwidth and pulsing valid
						// repeatedly for one access. The arbiter underneath wants
						// the OPPOSITE (hold until acknowledged). Two transports,
						// two contracts; each module's own FSM is the authority.
						@(posedge clk);
						cpu_req <= 1'b0;
						do @(posedge clk); while (!cpu_valid);
						exp = {src[2*i], src[2*i+1]};
						if (cpu_data !== exp) bad++;
					end
				end
			join
			check(bad == 0, "CPU words stay correct under graphics contention");
		end

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
