// jt6295 behind each OKI ROM bridge, through the real sample_cache, playing
// every phrase in gogomile's OKI ROM. RUN FROM THE REPOSITORY ROOT
// (scripts/run_sim.sh oki_phrase_tb), after scripts/prep_sound_tb.py.
//
// For each valid phrase in bank 2 (the bank gogomile selects in play): start
// it on channel 1, and record whether the status bit rises (the control
// state machine read the phrase header), whether any sample reaches the
// output, and whether the status bit falls again (it played to its stop
// address). The old bridge and the new one run side by side on the same
// stimulus. +LAT=n sets the granule server's fixed latency (default 120 clk).
`timescale 1ns/1ps

module tb_oki_phrase;
	localparam real HALF = 5.8207;      // 85.909 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	logic [9:0] cen_acc = 10'd0;
	always_ff @(posedge clk) cen_acc <= (cen_acc >= 10'd945 - 10'd11) ? cen_acc + 10'd11 - 10'd945 : cen_acc + 10'd11;
	wire cen_oki = (cen_acc >= 10'd945 - 10'd11);

	logic [7:0] oki_rom [0:1048575];
	int lat = 120;

	logic       wrn = 1'b1;
	logic [7:0] din = 8'd0;
	localparam logic [1:0] BANK = 2'd2;

	logic [7:0] st_old, st_new;
	logic signed [13:0] snd_old, snd_new;

	oki_path #(.OLD(1)) p_old (.clk(clk), .reset(reset), .cen(cen_oki), .wrn(wrn), .din(din), .bank(BANK),
	                           .lat(lat), .status(st_old), .sound(snd_old));
	oki_path #(.OLD(0)) p_new (.clk(clk), .reset(reset), .cen(cen_oki), .wrn(wrn), .din(din), .bank(BANK),
	                           .lat(lat), .status(st_new), .sound(snd_new));

	task automatic oki_write(input [7:0] d);
		@(posedge clk); din <= d; wrn <= 1'b0;
		repeat (400) @(posedge clk);
		wrn <= 1'b1;
		repeat (400) @(posedge clk);
	endtask

	// 1 ms of clk
	task automatic run_ms(input int ms);
		repeat (ms * 85909) @(posedge clk);
	endtask

	int started_old, started_new, sounded_old, sounded_new, ended_old, ended_new;
	always @(posedge clk) begin
		if (st_old[0]) started_old <= 1;
		if (st_new[0]) started_new <= 1;
		if (snd_old != 0) sounded_old <= 1;
		if (snd_new != 0) sounded_new <= 1;
	end

	initial begin
		int n_valid = 0, bad_new = 0, bad_old = 0;
		void'($value$plusargs("LAT=%d", lat));
		$readmemh("sim/fg2_sound_tb/oki.hex", oki_rom);
		$display("=== tb_oki_phrase: bank %0d, granule latency %0d clk ===", BANK, lat);
		repeat (50) @(posedge clk);
		reset = 0;
		run_ms(2);
		for (int p = 1; p < 128; p++) begin
			int base, s, e, len_ms;
			base = int'(BANK) * 32'h40000 + p * 8;
			s = {oki_rom[base], oki_rom[base+1], oki_rom[base+2]} & 32'h3FFFF;
			e = {oki_rom[base+3], oki_rom[base+4], oki_rom[base+5]} & 32'h3FFFF;
			if (!(s > 0 && s < e && e < 32'h40000)) continue;
			n_valid++;
			// ADPCM at 7576 Hz, two nibbles a byte
			len_ms = ((e - s) * 2 * 1000) / 7576 + 20;
			if (n_valid > 30) break;
			if (len_ms > 60) len_ms = 60;
			started_old = 0; started_new = 0; sounded_old = 0; sounded_new = 0;
			oki_write(8'h80 | 8'(p));   // phrase
			oki_write(8'h10);           // channel 1, full volume
			run_ms(len_ms);
			// only phrases that finish inside the window can be checked for the end
			ended_old = (len_ms < 60) ? !st_old[0] : 1;
			ended_new = (len_ms < 60) ? !st_new[0] : 1;
			if (!(started_new && sounded_new && ended_new)) bad_new++;
			if (!(started_old && sounded_old && ended_old)) bad_old++;
			if (!(started_new && sounded_new && ended_new) || !(started_old && sounded_old && ended_old))
				$display("  phrase %3d (%0d bytes, %0d ms): old start %0d sound %0d end %0d | new start %0d sound %0d end %0d",
				         p, e - s, len_ms, started_old, sounded_old, ended_old, started_new, sounded_new, ended_new);
			oki_write(8'h78);           // stop all channels
			run_ms(2);
		end
		$display("  %0d valid phrases: old bridge %0d failures, new bridge %0d failures", n_valid, bad_old, bad_new);
		if (bad_new == 0) $display("ALL CHECKS PASSED");
		$finish;
	end
endmodule

// The OKI ROM bridge logic before 9714a18: the request follows the live
// address, so it can deadlock against sample_cache (see oki_rom_bridge.sv).
module oki_rom_bridge_old (
	input  logic        clk,
	input  logic        reset,
	input  logic [17:0] rom_addr,
	output logic [7:0]  rom_data,
	output logic        rom_ok,
	input  logic [1:0]  bank,
	output logic        req,
	output logic [19:0] addr,
	input  logic        valid,
	input  logic [7:0]  data
);
	logic [17:0] hold_addr;
	logic        hold_ok;
	assign addr   = {bank, rom_addr};
	assign req    = (rom_addr != hold_addr) || !hold_ok;
	assign rom_ok = hold_ok && (rom_addr == hold_addr);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hold_addr <= 18'd0; hold_ok <= 1'b0; rom_data <= 8'd0;
		end else begin
			if (valid) begin
				hold_addr <= rom_addr; rom_data <= data; hold_ok <= 1'b1;
			end else if (rom_addr != hold_addr) begin
				hold_ok <= 1'b0;
			end
		end
	end
endmodule

// ---- one OKI, one bridge, the real sample_cache, a fixed-latency granule server ----
module oki_path #(parameter bit OLD = 0) (
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,
	input  logic        wrn,
	input  logic [7:0]  din,
	input  logic [1:0]  bank,
	input  int          lat,
	output logic [7:0]  status,
	output logic signed [13:0] sound
);
	logic [17:0] rom_addr;
	logic [7:0]  rom_data;
	logic        rom_ok, req, valid, g_req, g_valid;
	logic [19:0] addr;
	logic [7:0]  data;
	logic [25:0] g_addr;
	logic [63:0] g_data;

	jt6295 #(.INTERPOL(0)) u_oki (
		.rst(reset), .clk(clk), .cen(cen), .ss(1'b1),
		.wrn(wrn), .din(din), .dout(status),
		.rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
		.sound(sound), .sample()
	);

	generate
		if (OLD) begin : g_old
			oki_rom_bridge_old u_br (.clk(clk), .reset(reset), .rom_addr(rom_addr), .rom_data(rom_data),
				.rom_ok(rom_ok), .bank(bank), .req(req), .addr(addr), .valid(valid), .data(data));
		end else begin : g_new
			oki_rom_bridge u_br (.clk(clk), .reset(reset), .rom_addr(rom_addr), .rom_data(rom_data),
				.rom_ok(rom_ok), .bank(bank), .req(req), .addr(addr), .valid(valid), .data(data));
		end
	endgenerate

	sample_cache #(.ENTRIES(16)) u_cache (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(req), .addr(26'(addr)), .valid(valid), .data(data),
		.g_req(g_req), .g_addr(g_addr), .g_valid(g_valid), .g_data(g_data)
	);

	int   cnt = 0;
	logic busy = 0, pend = 0, g_req_d = 0;
	logic [25:0] a_q;
	always_ff @(posedge clk) begin
		g_valid <= 1'b0;
		g_req_d <= g_req;
		if (g_req && !g_req_d) pend <= 1'b1;
		if (reset) begin
			busy <= 0; pend <= 0; cnt <= 0;
		end else if (busy) begin
			cnt <= cnt - 1;
			if (cnt == 1) begin
				g_valid <= 1'b1;
				for (int k = 0; k < 8; k++) g_data[8*k +: 8] <= tb_oki_phrase.oki_rom[20'(a_q) + 20'(k)];
				busy <= 0;
			end
		end else if (pend) begin
			pend <= 0; busy <= 1; a_q <= g_addr; cnt <= lat;
		end
	end
endmodule
