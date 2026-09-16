// maincpu smoke + boot test, FG-2 (68000 mode) against the real gogomile ROM:
// no X on control signals, boot fetches diffed against a MAME trace, and a
// level-3 interrupt with a synthetic program.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh maincpu_tb).
// Needs sim/maincpu_tb/gogomile_maincpu.hex (scripts/build_maincpu_hex.py).
// If every check fails at once, grep the log for `readmem` first.

`timescale 1ns/1ps

module tb_maincpu;

	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	// 85.909091 MHz = 14.318181 MHz x 6. Half period 5.8207 ns.
	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	// ---------------------------------------------------------------
	// DUT wiring
	// ---------------------------------------------------------------
	logic        rom_req;
	logic [20:0] rom_addr;
	logic        rom_valid;
	logic [15:0] rom_data;

	logic [16:0] workram_addr;
	logic        workram_wel, workram_weh;
	logic [15:0] workram_wdata, workram_rdata;

	logic [13:0] vram_addr;
	logic        vram_wel, vram_weh;
	logic [15:0] vram_wdata, vram_rdata;

	logic [11:0] spriteram_addr;
	logic        spriteram_wel, spriteram_weh;
	logic [15:0] spriteram_wdata, spriteram_rdata;

	logic [12:0] palette_addr;
	logic        palette_wel, palette_weh;
	logic [15:0] palette_wdata, palette_rdata;

	logic [4:0]  vregs_addr;
	logic [1:0]  vregs_sel;
	logic        vregs_wel, vregs_weh;
	logic [15:0] vregs_wdata, vregs_rdata;

	logic [3:0]  sharedram_addr;
	logic        sharedram_we;
	logic [7:0]  sharedram_wdata, sharedram_rdata;

	logic [15:0] system_in = 16'hFFFF;   // inputs are ACTIVE LOW
	logic [15:0] p1p2_in   = 16'hFFFF;
	logic [15:0] dsw_in    = 16'hFFFF;
	logic [15:0] dsw2_in   = 16'hFFFF;

	logic [7:0]  latch_data;
	logic        latch_write;
	logic [31:0] tilebank;

	logic irq1_trig = 0, irq3_trig = 0, irq5_trig = 0;
	logic pause = 0;

	maincpu dut (
		.clk(clk), .reset(reset),
		.board(BOARD_FG2),                      // FG-2: 68000 @ 16 MHz
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.workram_addr(workram_addr), .workram_wel(workram_wel), .workram_weh(workram_weh),
		.workram_wdata(workram_wdata), .workram_rdata(workram_rdata),
		.vram_addr(vram_addr), .vram_wel(vram_wel), .vram_weh(vram_weh),
		.vram_wdata(vram_wdata), .vram_rdata(vram_rdata),
		.spriteram_addr(spriteram_addr), .spriteram_wel(spriteram_wel), .spriteram_weh(spriteram_weh),
		.spriteram_wdata(spriteram_wdata), .spriteram_rdata(spriteram_rdata),
		.palette_addr(palette_addr), .palette_wel(palette_wel), .palette_weh(palette_weh),
		.palette_wdata(palette_wdata), .palette_rdata(palette_rdata),
		.vregs_addr(vregs_addr), .vregs_sel(vregs_sel),
		.vregs_wel(vregs_wel), .vregs_weh(vregs_weh),
		.vregs_wdata(vregs_wdata), .vregs_rdata(vregs_rdata),
		.sharedram_addr(sharedram_addr), .sharedram_we(sharedram_we),
		.sharedram_wdata(sharedram_wdata), .sharedram_rdata(sharedram_rdata),
		.system_in(system_in), .p1p2_in(p1p2_in), .dsw_in(dsw_in), .dsw2_in(dsw2_in),
		.latch_data(latch_data), .latch_write(latch_write), .latch_busy(1'b0),
		.tilebank(tilebank),
		.irq1_trig(irq1_trig), .irq3_trig(irq3_trig), .irq5_trig(irq5_trig),
		.pause(pause)
	);

	// ---------------------------------------------------------------
	// ROM model: req/valid with transport-scale latency. A 1-2 cycle model
	// answers while the FSM is between states and hides duplicate-request
	// bugs (LESSONS_LEARNED, "Re-run the failing case with the production
	// transport in place of behavioural models").
	// ---------------------------------------------------------------
	localparam int ROM_LAT = 12;

	logic [15:0] rom [0:524287];        // 1 MB as 512K big-endian words
	int          rom_ctr = 0;
	logic        rom_busy = 0;
	logic [20:0] rom_lat_addr;
	int          rom_reads = 0;

	always_ff @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) begin
			rom_busy <= 1'b0;
			rom_ctr  <= 0;
		end else if (!rom_busy) begin
			if (rom_req) begin
				rom_busy     <= 1'b1;
				rom_lat_addr <= rom_addr;
				rom_ctr      <= ROM_LAT;
			end
		end else if (rom_ctr > 1) begin
			rom_ctr <= rom_ctr - 1;
		end else begin
			rom_data  <= rom[rom_lat_addr];
			rom_valid <= 1'b1;
			rom_busy  <= 1'b0;
			rom_reads <= rom_reads + 1;
		end
	end

	// ---------------------------------------------------------------
	// BRAM models -- REGISTERED reads. A combinational model hides a consumer
	// that skips the read-latency wait (LESSONS_LEARNED, "Give a registered
	// RAM its full read latency before consuming the data").
	// ---------------------------------------------------------------
	`define BRAM(NAME, DEPTH, AW)                                            \
		logic [15:0] NAME``_mem [0:DEPTH-1];                                  \
		always_ff @(posedge clk) begin                                        \
			if (NAME``_wel) NAME``_mem[NAME``_addr][7:0]  <= NAME``_wdata[7:0]; \
			if (NAME``_weh) NAME``_mem[NAME``_addr][15:8] <= NAME``_wdata[15:8];\
			NAME``_rdata <= NAME``_mem[NAME``_addr];                           \
		end

	`BRAM(workram,   131072, 17)
	`BRAM(vram,       16384, 14)
	`BRAM(spriteram,   4096, 12)
	`BRAM(palette,     8192, 13)

	logic [15:0] vregs_mem [0:31];
	always_ff @(posedge clk) begin
		if (vregs_wel) vregs_mem[vregs_addr][7:0]  <= vregs_wdata[7:0];
		if (vregs_weh) vregs_mem[vregs_addr][15:8] <= vregs_wdata[15:8];
		vregs_rdata <= vregs_mem[vregs_addr];
	end

	logic [7:0] sharedram_mem [0:15];
	always_ff @(posedge clk) begin
		if (sharedram_we) sharedram_mem[sharedram_addr] <= sharedram_wdata;
		sharedram_rdata <= sharedram_mem[sharedram_addr];
	end

	// ---------------------------------------------------------------
	// Bus observation
	// ---------------------------------------------------------------
	// The 68000 boots with SR mask 7, so IRQs are masked until the game lowers
	// it. Exposed to tell "not taken" from "correctly masked".
	wire [2:0]  sr_mask   = dut.u_cpu.FlagsSR[2:0];

	wire [31:0] cpu_a     = dut.a32;
	wire [1:0]  cpu_bs    = dut.busstate;
	wire        cpu_step  = dut.cpu_clkena;
	wire [2:0]  cpu_fc    = dut.fc;

	// Expected fetch addresses from the MAME trace.
	localparam int MAX_EXP = 512;
	logic [31:0] exp_pc [0:MAX_EXP-1];

	int  errors   = 0;
	int  n_fetch  = 0;
	int  x_seen   = 0;

	// Record the first N instruction-fetch addresses, for the boot trace.
	localparam int TRACE_N = 512;
	logic [31:0] trace_a [0:TRACE_N-1];
	int          trace_i = 0;

	// trace_rst: a variable driven in always_ff may not be driven elsewhere
	// (vlog-7061), and case 2 needs the trace restarted.
	logic trace_rst = 0;

	always_ff @(posedge clk) begin
		if (trace_rst) begin
			n_fetch <= 0;
			trace_i <= 0;
		end else if (!reset && cpu_step && (cpu_bs == 2'b00)) begin
			n_fetch <= n_fetch + 1;
			if (trace_i < TRACE_N) begin
				trace_a[trace_i] <= cpu_a;
				trace_i <= trace_i + 1;
			end
		end
	end

	// X-propagation watch: once out of reset, none of these may go unknown.
	always_ff @(posedge clk) begin
		if (!reset) begin
			if ($isunknown(cpu_bs) || $isunknown(dut.cpu_ce) ||
			    $isunknown(rom_req) || $isunknown(dut.ipl)) begin
				if (x_seen == 0)
					$display("[%0t] FAIL: X on a control signal (bs=%b ce=%b req=%b ipl=%b)",
					         $time, cpu_bs, dut.cpu_ce, rom_req, dut.ipl);
				x_seen <= x_seen + 1;
			end
		end
	end

	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	// ---------------------------------------------------------------
	initial begin
		$display("=== tb_maincpu: FG-2 / 68000 / gogomile ===");

		// ROM first (LESSONS_LEARNED, "Write preloaded vectors and tables
		// AFTER $readmemh, never before").
		$readmemh("sim/maincpu_tb/gogomile_maincpu.hex", rom);

		if (rom[0] !== 16'h0040 || rom[1] !== 16'hFFFC) begin
			$display("FATAL: ROM image did not load (rom[0]=%04x rom[1]=%04x).",
			         rom[0], rom[1]);
			$display("       Run vsim FROM THE REPOSITORY ROOT -- $readmemh is");
			$display("       relative to the simulator CWD, not this file.");
			$finish;
		end
		$display("ROM loaded: reset SP=%04x%04x PC=%04x%04x",
		         rom[0], rom[1], rom[2], rom[3]);

		repeat (20) @(posedge clk);
		reset = 0;

		// ---- smoke: run and prove nothing goes X ----
		repeat (20000) @(posedge clk);

		$display("\n--- smoke ---");
		check(x_seen == 0,    "no X on control signals after reset");
		check(n_fetch > 0,    "CPU performed instruction fetches");
		check(rom_reads > 0,  "ROM transport served reads");

		// ---- boot trace ----
		$display("\n--- boot trace (first %0d instruction fetches) ---", trace_i);
		for (int i = 0; i < trace_i && i < 16; i++)
			$display("  %2d: %08x", i, trace_a[i]);

		// The reset-vector read also has busstate=00 and precedes the first
		// instruction in the trace; search for 0x400 rather than using index 0.
		begin
			// Declared and assigned SEPARATELY: a block-local initializer is
			// implicitly STATIC (vlog-2244) and runs once before time 0.
			int start;
			start = -1;
			for (int i = 0; i < trace_i; i++)
				if (start < 0 && trace_a[i] == 32'h00000400) start = i;

			check(start >= 0, "CPU reached the reset PC (0x400)");

			if (start >= 0) begin
				bit seq_ok;
				seq_ok = ((start + 8) <= trace_i);
				for (int i = 0; i < 8 && (start + i) < trace_i; i++)
					if (trace_a[start+i] != 32'h00000400 + 2*i) seq_ok = 0;
				check(seq_ok, "fetches walk 0x400..0x40E (CLR.L D0-D7)");
			end
		end

		$display("  SR interrupt mask after %0d fetches: %0d", n_fetch, sr_mask);

		// =============================================================
		// Diff against a MAME boot trace. gogomile_boot_pcs.txt comes from
		// scripts/parse_mame_trace.py: instruction starts expanded into the
		// words fetched. Matched as an in-order SUBSEQUENCE because some branch
		// lengths cannot be inferred and are left unexpanded; a divergence
		// still fails because the expected address never appears. The list
		// stops at gogomile's boot delay loop.
		// =============================================================
		$display("
--- diff against MAME boot trace ---");
		begin
			int n_exp, mi;

			for (int i = 0; i < MAX_EXP; i++) exp_pc[i] = 32'hFFFFFFFF;
			$readmemh("sim/maincpu_tb/gogomile_boot_pcs.txt", exp_pc);

			n_exp = 0;
			while (n_exp < MAX_EXP && exp_pc[n_exp] !== 32'hFFFFFFFF) n_exp++;

			if (n_exp == 0) begin
				$display("  SKIP  no expected-trace file; regenerate with");
				$display("        python scripts/parse_mame_trace.py debug/gogomile_boot.tr \\");
				$display("               sim/maincpu_tb/gogomile_boot_pcs.txt");
			end else begin
				mi = 0;
				for (int i = 0; i < trace_i && mi < n_exp; i++)
					if (trace_a[i] === exp_pc[mi]) mi++;

				$display("  matched %0d of %0d MAME fetch addresses, in order", mi, n_exp);
				if (mi < n_exp)
					$display("  first unmatched expected address: %08x (RTL trace held %0d fetches)",
					         exp_pc[mi], trace_i);
				check(mi == n_exp, "RTL fetch trace contains MAME's boot trace in order");
			end
		end

		// =============================================================
		// Case 2: interrupt path. gogomile keeps SR mask 7 through early boot,
		// so a synthetic program lowers it:
		//
		//   0x000000  SP = 0x0040FFFC
		//   0x000004  PC = 0x00000400
		//   0x00006C  level-3 autovector (vector 27) -> 0x00000500
		//   0x000400  MOVE #$2000,SR      supervisor, mask 0
		//   0x000404  BRA.S *             spin
		//   0x000500  RTE
		// =============================================================
		$display("\n--- case 2: level 3 (vblank) interrupt, interrupts enabled ---");

		reset = 1;
		repeat (20) @(posedge clk);

		for (int i = 0; i < 1024; i++) rom[i] = 16'h4E71;   // NOP fill
		rom['h000] = 16'h0040; rom['h001] = 16'hFFFC;       // SP
		rom['h002] = 16'h0000; rom['h003] = 16'h0400;       // PC
		rom['h036] = 16'h0000; rom['h037] = 16'h0500;       // vector 27 @ 0x6C
		rom['h200] = 16'h46FC; rom['h201] = 16'h2000;       // MOVE #$2000,SR
		rom['h202] = 16'h60FE;                              // BRA.S *
		rom['h280] = 16'h4E73;                              // RTE

		trace_rst = 1;
		repeat (2) @(posedge clk);
		trace_rst = 0;
		repeat (5) @(posedge clk);
		reset = 0;

		// Let it reach the spin loop and drop the mask.
		repeat (3000) @(posedge clk);
		$display("  SR interrupt mask at the spin loop: %0d", sr_mask);
		check(sr_mask == 3'd0, "program lowered the SR interrupt mask");

		begin
			int iacks;
			bit isr_entered;
			iacks = 0;
			isr_entered = 0;

			// HOLD_LINE: a held LEVEL, as the real system drives it. A one-clock
			// pulse hides set-vs-clear priority bugs.
			irq3_trig = 1;

			fork
				repeat (6000) @(posedge clk);
				forever begin
					@(posedge clk);
					if (dut.iack) iacks++;
					if (cpu_step && (cpu_bs == 2'b00) && (cpu_a == 32'h00000500))
						isr_entered = 1;
				end
			join_any
			disable fork;

			check(iacks > 0,   "CPU ran an interrupt-acknowledge cycle (FC=7)");
			check(isr_entered, "CPU fetched the ISR via the level-3 autovector (0x6C -> 0x500)");

			// irq3_trig is still high: acknowledge must win over the held level,
			// or the ISR re-enters after every RTE.
			check(dut.irq3_pending == 1'b0,
			      "irq3_pending cleared while the source is still held high");

			irq3_trig = 0;
		end

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#20ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
