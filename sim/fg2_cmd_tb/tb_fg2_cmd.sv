// Diagnostic, no checks: the FG-2 sound board running gogomile's Z80 firmware
// (same setup as tb_fg2_sound) is sent 0x87, 0x03, then 0x02, and per-window
// YM key-ons, OKI writes/status and non-zero mix counts are printed.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh fg2_cmd_tb), after
//     python scripts/prep_sound_tb.py
`timescale 1ns/1ps
module tb_fg2_cmd;
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
		.latch_data(latch_data), .latch_write(latch_write), .latch_busy(),
		.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
		.oki_req(oki_req), .oki_addr(oki_addr), .oki_valid(oki_valid), .oki_data(oki_data),
		.audio(audio), .dbg_m1(dbg_m1), .dbg_ym_wr(dbg_ym_wr)
	);

	// ---- ROM models ----
	// Z80 program: req pulses; latency 4..160 clk, from a narrow-bridge hit to beyond
	// the 149 clk worst SDRAM round trip measured on the Psikyo core.
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
	// OKI samples: req held until valid; latency 3..170 clk, against the
	// chip's ~8 us deadline.
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

	// ---- per-window observation: key-ons, OKI status reads and writes ----
	int w_kon2 = 0, w_kon1 = 0, w_okiwr = 0, w_okird = 0, w_nz = 0;
	logic [7:0] last_oki_status = 8'h00, ym2_sel = 0, ym1_sel = 0;
	logic ym2w_d = 0, ym1w_d = 0, okiw_d = 0, okir_d = 0;
	always @(posedge clk) begin
		ym2w_d <= dut.io_active_wr && dut.io_ym2;
		ym1w_d <= dut.io_active_wr && dut.io_ym1;
		okiw_d <= dut.io_active_wr && dut.io_oki_wr;
		okir_d <= dut.io_active_rd && dut.io_oki_rd;
		if (dut.io_active_wr && dut.io_ym2 && !ym2w_d) begin
			if (!dut.a[0]) ym2_sel <= dut.d_out;
			else if (ym2_sel >= 8'hB0 && ym2_sel <= 8'hB8 && dut.d_out[5]) w_kon2++;
		end
		if (dut.io_active_wr && dut.io_ym1 && !ym1w_d) begin
			if (!dut.a[0]) ym1_sel <= dut.d_out;
			else if (ym1_sel == 8'h28 && dut.d_out[7:4] != 0) w_kon1++;
		end
		if (dut.io_active_wr && dut.io_oki_wr && !okiw_d) begin
			w_okiwr++;
			$display("    %9.3f ms  OKI write %02h", $time / 1e6, dut.d_out);
		end
		if (dut.io_active_rd && dut.io_oki_rd && !okir_d) begin
			w_okird++;
			if (dut.oki_dout != last_oki_status)
				$display("    %9.3f ms  OKI status now %02h", $time / 1e6, dut.oki_dout);
			last_oki_status <= dut.oki_dout;
		end
		if (audio != 0) w_nz++;
	end
	task automatic window(input string what, input real ms, input int n_bins);
		for (int i = 0; i < n_bins; i++) begin
			w_kon2 = 0; w_kon1 = 0; w_okiwr = 0; w_okird = 0; w_nz = 0;
			run_ms(ms);
			$display("  %-10s +%4.0f ms  YM3812 key-ons %3d  YM2203 key-ons %3d  OKI wr %2d rd %4d  nonzero mix %0d",
			         what, (i + 1) * ms, w_kon2, w_kon1, w_okiwr, w_okird, w_nz);
		end
	endtask

	initial begin
		$display("=== tb_fg2_cmd: gogomile firmware, the command sequence before the stop ===");
		$readmemh("sim/fg2_sound_tb/z80.hex", z80_rom);
		$readmemh("sim/fg2_sound_tb/oki.hex", oki_rom);
		repeat (100) @(posedge clk);
		reset = 0;
		last_m1_ns = $time / 1000;
		run_ms(20.0);
		send(8'h87); run_ms(5.0); send(8'h03);
		window("after 03", 25.0, 2);
		send(8'h02);
		window("after 02", 25.0, 8);
		$display("
ALL CHECKS PASSED");
		$finish;
	end
endmodule
