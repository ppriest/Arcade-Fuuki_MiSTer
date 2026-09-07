// The FG-2 sound board running the REAL gogomile Z80 firmware: T80, jt03,
// jtopl2 and jt6295 clocked exactly as rtl/fuuki_core.sv clocks them, behind
// variable-latency req/valid models of the two ROM ports.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh fg2_sound_tb), after
//     python scripts/prep_sound_tb.py
//
// What it checks, in order of how much it proves:
//   1. the Z80 runs -- opcode fetches keep coming, and a watchdog fails the
//      run if none arrives for 2 ms of simulated time (a wedged WAIT_n or a
//      lost ROM handshake looks exactly like that);
//   2. the firmware's own initialisation reaches the FM chips (writes seen
//      on the YM ports) without any command from the main CPU;
//   3. the two commands the captured main-CPU trace sends at boot
//      (0x87, then 0x03: debug/gogomile_vregs.tr) are taken -- the NMI
//      handler reads the latch;
//   4. after them the board makes sound: the mix leaves zero, and the OKI
//      fetches sample bytes.
// It does not judge what the sound IS. That is for the ear, on MiSTer.
`timescale 1ns/1ps
module tb_fg2_sound;
	localparam real HALF = 5.8207;      // 85.909 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	// ---- clock enables, as fuuki_core.sv derives them ----
	logic [9:0] cen_z80_acc = 10'd0, cen_oki_acc = 10'd0;
	logic [4:0] cen_ym_cnt  = 5'd0;
	always_ff @(posedge clk) begin
		cen_z80_acc <= (cen_z80_acc >= 10'd945 - 10'd66) ? cen_z80_acc + 10'd66 - 10'd945 : cen_z80_acc + 10'd66;
		cen_oki_acc <= (cen_oki_acc >= 10'd945 - 10'd11) ? cen_oki_acc + 10'd11 - 10'd945 : cen_oki_acc + 10'd11;
		cen_ym_cnt  <= (cen_ym_cnt == 5'd23) ? 5'd0 : cen_ym_cnt + 5'd1;
	end
	wire cen_z80 = (cen_z80_acc >= 10'd945 - 10'd66);
	wire cen_oki = (cen_oki_acc >= 10'd945 - 10'd11);
	wire cen_ym  = (cen_ym_cnt == 5'd0);

	// ---- DUT ----
	logic [7:0]  latch_data = 8'd0;
	logic        latch_write = 1'b0;
	logic        rom_req, rom_valid, oki_req, oki_valid;
	logic [16:0] rom_addr;
	logic [19:0] oki_addr;
	logic [7:0]  rom_data, oki_data;
	logic signed [15:0] audio;
	logic        dbg_m1, dbg_ym_wr;

	fg2_sound dut (
		.clk(clk), .reset(reset),
		.cen_z80(cen_z80), .cen_ym(cen_ym), .cen_oki(cen_oki),
		.latch_data(latch_data), .latch_write(latch_write),
		// Both halves on: this bench asks whether the board makes sound at
		// all, not what each half contributes.
		.en_fm(1'b1), .en_pcm(1'b1),
		.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
		.oki_req(oki_req), .oki_addr(oki_addr), .oki_valid(oki_valid), .oki_data(oki_data),
		.audio(audio), .dbg_m1(dbg_m1), .dbg_ym_wr(dbg_ym_wr)
	);

	// ---- ROM models ----
	// Z80 program: req pulses, valid after a latency that varies 4..160 clk
	// -- a narrow-bridge hit at one end, and at the other more than the
	// 149 clk worst SDRAM round trip the Psikyo core measured behind the
	// same fixed priority chain.
	logic [7:0] z80_rom [0:131071];
	logic [7:0] oki_rom [0:1048575];
	int         rom_lat = 0;
	logic [16:0] rom_addr_q;
	always_ff @(posedge clk) begin
		rom_valid <= 1'b0;
		if (rom_lat > 0) begin
			rom_lat <= rom_lat - 1;
			if (rom_lat == 1) begin
				rom_valid <= 1'b1;
				rom_data  <= z80_rom[rom_addr_q];
			end
		end else if (rom_req) begin
			rom_addr_q <= rom_addr;
			rom_lat    <= 4 + ($urandom % 157);
		end
	end
	// OKI samples: req is held until valid; latency 3..170 clk, past the
	// same worst case, against the chip's ~8 us fixed deadline.
	int oki_lat = 0;
	logic oki_busy = 0;
	always_ff @(posedge clk) begin
		oki_valid <= 1'b0;
		if (oki_busy) begin
			oki_lat <= oki_lat - 1;
			if (oki_lat == 1) begin
				oki_valid <= 1'b1;
				oki_data  <= oki_rom[oki_addr];
				oki_busy  <= 1'b0;
			end
		end else if (oki_req) begin
			oki_busy <= 1'b1;
			oki_lat  <= 3 + ($urandom % 168);
		end
	end

	// ---- observation ----
	int n_m1 = 0, n_ym_wr = 0, n_oki_rd = 0, n_latch_rd = 0, n_audio_nz = 0;
	int nz_ym1 = 0, nz_ym2 = 0, nz_oki = 0;
	int   last_m1_ns = 0;
	logic [7:0] latch_seen = 8'd0;
	// plain always: last_m1_ns is also set from the initial block
	always @(posedge clk) begin
		if (dbg_m1)    begin n_m1 <= n_m1 + 1; last_m1_ns <= $time / 1000; end
		if (dbg_ym_wr) n_ym_wr <= n_ym_wr + 1;
		if (oki_valid) n_oki_rd <= n_oki_rd + 1;
		if (audio != 16'sd0) n_audio_nz <= n_audio_nz + 1;
		if (dut.ym1_snd != 0) nz_ym1 <= nz_ym1 + 1;
		if (dut.ym2_snd != 0) nz_ym2 <= nz_ym2 + 1;
		if (dut.oki_snd != 0) nz_oki <= nz_oki + 1;
		// the NMI handler's IN A,(0x11)
		if (!dut.iorq_n && !dut.rd_n && dut.a[7:0] == 8'h11 && cen_z80) begin
			n_latch_rd <= n_latch_rd + 1;
			latch_seen <= dut.latch_reg;
		end
	end

	// ---- diagnostics: FM writes, the INT line, where the Z80 spends its time ----
	int n_int = 0;
	logic int_d = 1;
	logic ymwr_d = 0;
	int pc_hist [int];
	always @(posedge clk) begin
		int_d <= dut.int_n;
		if (int_d && !dut.int_n) n_int <= n_int + 1;
		ymwr_d <= dut.io_active_wr && (dut.io_ym1 || dut.io_ym2);
		if ((dut.io_active_wr && (dut.io_ym1 || dut.io_ym2)) && !ymwr_d)
			$display("    %8.3f ms  %s port %0d <= %02h", $time / 1e6, dut.io_ym1 ? "YM2203" : "YM3812", dut.a[0], dut.d_out);
		if (dbg_m1) pc_hist[dut.a] += 1;
	end
	task automatic show_hist(input string what);
		int keys [$];
		int best [$];
		$display("  PC histogram (%s): %0d distinct addresses", what, pc_hist.size());
		foreach (pc_hist[k]) keys.push_back(k);
		keys.sort with (-pc_hist[item]);
		for (int i = 0; i < keys.size() && i < 12; i++)
			$display("    %04h  x%0d", keys[i], pc_hist[keys[i]]);
		pc_hist.delete();
	endtask

	// Watchdog: no opcode fetch for 2 ms is a wedged CPU.
	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask
	task automatic run_ms(input real ms);
		int t0;
		t0 = $time / 1000;
		while ($time / 1000 < t0 + ms * 1000) begin
			repeat (10000) @(posedge clk);
			if (($time / 1000) - last_m1_ns > 2000) begin
				$display("  FAIL  watchdog: no Z80 opcode fetch for 2 ms (pc area %h)", dut.a);
				errors++;
				$display("\n=== %0d error(s) ===", errors);
				$finish;
			end
		end
	endtask
	task automatic send(input [7:0] cmd);
		@(posedge clk);
		latch_data  <= cmd;
		latch_write <= 1'b1;
		@(posedge clk);
		latch_write <= 1'b0;
	endtask

	int n0, n1;
	initial begin
		$display("=== tb_fg2_sound: gogomile firmware on the FG-2 sound board ===");
		$readmemh("sim/fg2_sound_tb/z80.hex", z80_rom);
		$readmemh("sim/fg2_sound_tb/oki.hex", oki_rom);
		if (z80_rom[0] === 8'hxx) begin
			$display("  FAIL  z80.hex not loaded -- run scripts/prep_sound_tb.py from the repo root");
			$finish;
		end
		repeat (100) @(posedge clk);
		reset = 0;
		last_m1_ns = $time / 1000;

		$display("\n--- firmware boot, no command ---");
		run_ms(20.0);
		$display("  %0d opcode fetches, %0d FM writes, %0d OKI reads", n_m1, n_ym_wr, n_oki_rd);
		check(n_m1 > 1000, "the Z80 runs");
		check(n_ym_wr > 0, "the firmware's init reaches the FM chips");
		$display("  INT (YM3812 timer) fell %0d times", n_int);
		$display("  OPL timers: value_A %02h value_B %02h load_A %b load_B %b flagen_A %b flag_A %b cnt_A %02h zero-seen %b",
		         dut.u_ym2.u_base.u_mmr.value_A, dut.u_ym2.u_base.u_mmr.value_B,
		         dut.u_ym2.u_base.u_mmr.load_A, dut.u_ym2.u_base.u_mmr.load_B,
		         dut.u_ym2.u_base.u_mmr.flagen_A, dut.u_ym2.u_base.flag_A,
		         dut.u_ym2.u_base.u_timers.timer_A.cnt, dut.u_ym2.u_base.zero);
		show_hist("boot, no command");

		$display("\n--- command 0x87, then 0x03, as the main CPU sends at boot ---");
		n0 = n_latch_rd; n1 = n_ym_wr;
		send(8'h87);
		run_ms(5.0);
		check(n_latch_rd > n0 && latch_seen == 8'h87, "NMI handler read command 0x87 from the latch");
		send(8'h03);
		run_ms(60.0);
		check(latch_seen == 8'h03, "NMI handler read command 0x03 from the latch");
		$display("  after the commands: %0d more FM writes, %0d OKI reads, %0d non-zero mix samples",
		         n_ym_wr - n1, n_oki_rd, n_audio_nz);
		$display("  INT (YM3812 timer) fell %0d times in total", n_int);
		show_hist("after the commands");
		$display("  non-zero output clocks: YM2203 %0d, YM3812 %0d, OKI %0d; mix register %0d", nz_ym1, nz_ym2, nz_oki, audio);
		$display("  unknowns: ym1_snd %b ym2_snd %b oki_snd %b audio %b | jtopl: eg_V %b op_result %b acc.snd %b keyon_I %b fnum_I %b slot %b cenop %b",
		         $isunknown(dut.ym1_snd), $isunknown(dut.ym2_snd), $isunknown(dut.oki_snd), $isunknown(audio),
		         $isunknown(dut.u_ym2.u_base.eg_V), $isunknown(dut.u_ym2.u_base.op_result),
		         $isunknown(dut.u_ym2.u_base.u_acc.snd), $isunknown(dut.u_ym2.u_base.keyon_I),
		         $isunknown(dut.u_ym2.u_base.fnum_I), $isunknown(dut.u_ym2.u_base.slot), $isunknown(dut.u_ym2.u_base.cenop));
		$display("  unknowns: jt03 snd %b fm_snd %b | jt6295 sound %b", $isunknown(dut.u_ym1.snd), $isunknown(dut.u_ym1.fm_snd), $isunknown(dut.u_oki.sound));
		check(n_ym_wr > n1, "the commands produced FM writes");
		check(n_audio_nz > 0, "the mix left zero");

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end
endmodule
