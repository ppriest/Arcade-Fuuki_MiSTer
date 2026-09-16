// jt6295 driven the way gogomile's Z80 driver drives it, behind each OKI ROM
// bridge and the real sample_cache, compared against the same chip on an
// ideal ROM. RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh oki_driver_tb),
// after scripts/prep_sound_tb.py.
//
// The driver's phrase start (z80 0x174C): stop the channel, delay, phrase
// byte, delay, channel/volume byte, with CALL 0x1CDF (~93 us) before each
// OUT. Events pick a random channel and a random valid bank-2 phrase; gaps
// are either back-to-back or several ms, so channels overlap.
//
// Every path sees identical writes. Logged per path: each completed control
// walk (channel, start and stop address). A path whose walk list differs
// from the ideal one lost or corrupted a phrase start.
`timescale 1ns/1ps

module tb_oki_driver;
	localparam real HALF = 5.8207;      // 85.909 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	logic [9:0] cen_acc = 10'd0;
	always_ff @(posedge clk) cen_acc <= (cen_acc >= 10'd945 - 10'd11) ? cen_acc + 10'd11 - 10'd945 : cen_acc + 10'd11;
	wire cen_oki = (cen_acc >= 10'd945 - 10'd11);

	logic [7:0] oki_rom [0:1048575];
	logic       wrn = 1'b1;
	logic [7:0] din = 8'd0;
	localparam logic [1:0] BANK = 2'd2;

	localparam int NP = 5;
	// path 0 ideal; 1/2 old/new at a short latency; 3/4 old/new at a long one
	drv_path #(.KIND(0), .LMIN(0),   .LMAX(0))    p0 (.clk, .reset, .cen(cen_oki), .wrn, .din, .bank(BANK));
	drv_path #(.KIND(1), .LMIN(3),   .LMAX(200))  p1 (.clk, .reset, .cen(cen_oki), .wrn, .din, .bank(BANK));
	drv_path #(.KIND(2), .LMIN(3),   .LMAX(200))  p2 (.clk, .reset, .cen(cen_oki), .wrn, .din, .bank(BANK));
	drv_path #(.KIND(1), .LMIN(100), .LMAX(1500)) p3 (.clk, .reset, .cen(cen_oki), .wrn, .din, .bank(BANK));
	drv_path #(.KIND(2), .LMIN(100), .LMAX(1500)) p4 (.clk, .reset, .cen(cen_oki), .wrn, .din, .bank(BANK));

	task automatic oki_write(input [7:0] d);
		@(posedge clk); din <= d; wrn <= 1'b0;
		repeat (30) @(posedge clk);
		wrn <= 1'b1;
		repeat (8000) @(posedge clk);     // CALL 0x1CDF before the next OUT
	endtask

	initial begin
		int valid [$];
		int n_ev = 80;
		void'($value$plusargs("EVENTS=%d", n_ev));
		$readmemh("sim/fg2_sound_tb/oki.hex", oki_rom);
		for (int p = 1; p < 128; p++) begin
			int base, s, e;
			base = int'(BANK) * 32'h40000 + p * 8;
			s = {oki_rom[base], oki_rom[base+1], oki_rom[base+2]} & 32'h3FFFF;
			e = {oki_rom[base+3], oki_rom[base+4], oki_rom[base+5]} & 32'h3FFFF;
			if (s > 0 && s < e && e < 32'h40000) valid.push_back(p);
		end
		$display("=== tb_oki_driver: %0d events, %0d valid bank-%0d phrases ===", n_ev, valid.size(), BANK);
		repeat (50) @(posedge clk);
		reset = 0;
		repeat (100000) @(posedge clk);
		for (int i = 0; i < n_ev; i++) begin
			int c, p, gap;
			c = $urandom % 4;
			p = valid[$urandom % valid.size()];
			oki_write(8'(8'h08 << c));              // stop the channel
			oki_write(8'h80 | 8'(p));               // phrase
			oki_write(8'(8'h10 << c));              // channel, full volume
			gap = ($urandom % 2) ? ($urandom % 3000) : (86000 + $urandom % 1200000);
			repeat (gap) @(posedge clk);
		end
		repeat (400000) @(posedge clk);
		begin
			int bad = 0;
			for (int k = 1; k < NP; k++) begin
				int m;
				m = compare(k);
				if (m) bad++;
			end
			if (bad) $display("=== %0d path(s) differ from the ideal ROM ===", bad);
			else     $display("ALL PATHS MATCH THE IDEAL ROM");
		end
		$finish;
	end

	function automatic int path_n(int k);
		case (k) 0: return p0.n; 1: return p1.n; 2: return p2.n; 3: return p3.n; default: return p4.n; endcase
	endfunction
	function automatic logic [39:0] path_ev(int k, int i);
		case (k) 0: return p0.ev[i]; 1: return p1.ev[i]; 2: return p2.ev[i]; 3: return p3.ev[i]; default: return p4.ev[i]; endcase
	endfunction
	function automatic int compare(int k);
		string nm [5] = '{"ideal", "old  3..200", "new  3..200", "old  100..1500", "new  100..1500"};
		int nk, n0, mism = 0;
		nk = path_n(k); n0 = path_n(0);
		for (int i = 0; i < n0 && i < nk; i++)
			if (path_ev(k, i) !== path_ev(0, i)) begin
				if (mism < 4)
					$display("    %s walk %0d: ch %h start %05h stop %05h, ideal ch %h start %05h stop %05h", nm[k], i,
					         path_ev(k, i)[39:36], path_ev(k, i)[35:18], path_ev(k, i)[17:0],
					         path_ev(0, i)[39:36], path_ev(0, i)[35:18], path_ev(0, i)[17:0]);
				mism++;
			end
		$display("  %-15s %3d walks (ideal %0d), %0d differ, max walk %0d clk, nonzero samples %0d (ideal %0d)",
		         nm[k], nk, n0, mism, path_maxwalk(k), path_nz(k), path_nz(0));
		return mism || (nk != n0);
	endfunction
	function automatic int path_maxwalk(int k);
		case (k) 0: return p0.maxwalk; 1: return p1.maxwalk; 2: return p2.maxwalk; 3: return p3.maxwalk; default: return p4.maxwalk; endcase
	endfunction
	function automatic int path_nz(int k);
		case (k) 0: return p0.nz; 1: return p1.nz; 2: return p2.nz; 3: return p3.nz; default: return p4.nz; endcase
	endfunction
endmodule

// ---- the bridge logic before 9714a18 ----
module drv_bridge_old (
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

// ---- the bridge from 9714a18 ----
module drv_bridge_new (
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
	logic [19:0] hold_addr, req_addr;
	logic        hold_ok, in_flight;
	wire [19:0] want_addr = {bank, rom_addr};
	wire        want      = !hold_ok || (want_addr != hold_addr);
	assign req    = in_flight;
	assign addr   = req_addr;
	assign rom_ok = hold_ok && (want_addr == hold_addr);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hold_addr <= 20'd0; hold_ok <= 1'b0; req_addr <= 20'd0; in_flight <= 1'b0; rom_data <= 8'd0;
		end else if (in_flight) begin
			if (valid) begin
				hold_addr <= req_addr; rom_data <= data; hold_ok <= 1'b1; in_flight <= 1'b0;
			end
		end else if (want) begin
			req_addr <= want_addr; in_flight <= 1'b1;
		end
	end
endmodule

// KIND 0: ideal ROM (registered read, always ok). 1: old bridge. 2: new bridge.
module drv_path #(parameter int KIND = 0, parameter int LMIN = 3, parameter int LMAX = 200) (
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,
	input  logic        wrn,
	input  logic [7:0]  din,
	input  logic [1:0]  bank
);
	logic [17:0] rom_addr;
	logic [7:0]  rom_data;
	logic        rom_ok;
	logic signed [13:0] sound;
	logic [7:0]  status;

	jt6295 #(.INTERPOL(0)) u_oki (
		.rst(reset), .clk(clk), .cen(cen), .ss(1'b1),
		.wrn(wrn), .din(din), .dout(status),
		.rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
		.sound(sound), .sample()
	);

	generate
		if (KIND == 0) begin : g_ideal
			always_ff @(posedge clk) rom_data <= tb_oki_driver.oki_rom[{bank, rom_addr}];
			assign rom_ok = 1'b1;
		end else begin : g_bridge
			logic        req, valid, g_req, g_valid;
			logic [19:0] addr;
			logic [7:0]  data;
			logic [25:0] g_addr;
			logic [63:0] g_data;
			if (KIND == 1) begin : g_old
				drv_bridge_old u_br (.clk, .reset, .rom_addr, .rom_data, .rom_ok, .bank, .req, .addr, .valid, .data);
			end else begin : g_new
				drv_bridge_new u_br (.clk, .reset, .rom_addr, .rom_data, .rom_ok, .bank, .req, .addr, .valid, .data);
			end
			sample_cache #(.ENTRIES(16)) u_cache (
				.clk, .reset, .inval(1'b0),
				.req, .addr(26'(addr)), .valid, .data,
				.g_req, .g_addr, .g_valid, .g_data
			);
			// arbiter-like: a request is captured on its rising edge
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
					if (cnt <= 1) begin
						g_valid <= 1'b1;
						for (int k = 0; k < 8; k++) g_data[8*k +: 8] <= tb_oki_driver.oki_rom[20'(a_q) + 20'(k)];
						busy <= 0;
					end
				end else if (pend) begin
					pend <= 0; busy <= 1; a_q <= g_addr;
					cnt <= LMIN + ($urandom % (LMAX - LMIN + 1));
				end
			end
		end
	endgenerate

	// completed control walks
	logic [39:0] ev [0:4095];
	int n = 0, maxwalk = 0, walk_t = 0, nz = 0;
	logic [2:0] st_d = 3'd7;
	always @(posedge clk) begin
		st_d <= u_oki.u_ctrl.st;
		if (u_oki.u_ctrl.st != 3'd7) walk_t <= walk_t + 1;
		if (st_d == 3'd6 && u_oki.u_ctrl.st == 3'd7) begin
			ev[n] <= {u_oki.u_ctrl.start, u_oki.u_ctrl.start_addr, u_oki.u_ctrl.stop_addr};
			n <= n + 1;
			if (walk_t > maxwalk) maxwalk <= walk_t;
			walk_t <= 0;
		end
		if (sound != 0) nz <= nz + 1;
	end
endmodule
