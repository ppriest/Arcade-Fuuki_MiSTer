// Every client of fuuki_sdram_top at once, with the OKI side driven by a real
// jt6295 through either OKI ROM bridge, and every byte each client receives
// checked against the chip model. RUN FROM THE REPOSITORY ROOT, after
// scripts/prep_sound_tb.py:
//     scripts/run_sim.sh sdram_share_tb +NEW=1     # the bridge from 9714a18
//     scripts/run_sim.sh sdram_share_tb +NEW=0     # the logic before it
//
// Question: does the OKI side's request pattern make the shared port-2
// arbiter (68000 program, Z80 program, OKI samples) hand any client wrong
// data, or stall one?
`timescale 1ns/1ps

module tb_sdram_share;
	localparam real HALF = 5.8207;      // 85.909 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1, init = 1;

	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;
	logic [1:0]  SDRAM_BA;

	logic        tm_req [3] = '{0, 0, 0};
	logic [25:0] tm_addr [3];
	logic        tm_valid [3];
	logic [63:0] tm_data [3];
	logic        spr_req = 0;
	logic [25:0] spr_addr = 0;
	logic        spr_valid;
	logic [63:0] spr_data;
	logic        cpu_req = 0;
	logic [25:0] cpu_addr = 0;
	logic        cpu_valid;
	logic [15:0] cpu_data;
	logic        z80_req = 0;
	logic [18:0] z80_addr = 0;
	logic        z80_valid;
	logic [7:0]  z80_data;
	logic        smp_req;
	logic [21:0] smp_addr;
	logic        smp_valid;
	logic [7:0]  smp_data;

	fuuki_sdram_top dut (
		.clk, .reset, .init, .board(1'b0),
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(26'd0), .ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
		.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE,
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
		.ioctl_wait(),
		.tm0_req(tm_req[0]), .tm0_addr(tm_addr[0]), .tm0_valid(tm_valid[0]), .tm0_data(tm_data[0]),
		.tm1_req(tm_req[1]), .tm1_addr(tm_addr[1]), .tm1_valid(tm_valid[1]), .tm1_data(tm_data[1]),
		.tm2_req(tm_req[2]), .tm2_addr(tm_addr[2]), .tm2_valid(tm_valid[2]), .tm2_data(tm_data[2]),
		.spr_req, .spr_addr, .spr_valid, .spr_data,
		.cpu_req, .cpu_addr, .cpu_valid, .cpu_data,
		.z80_req, .z80_addr, .z80_valid, .z80_data,
		.smp_req, .smp_addr, .smp_valid, .smp_data,
		.dbg_dl_wr(), .dbg_dl_addr()
	);

	sdram_chip_model_wide u_chip (
		.clk, .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
	);

	localparam logic [25:0] BASE_AUDIOCPU = 26'h020_0000, BASE_TILES_L0 = 26'h028_0000,
	                        BASE_TILES_L1 = 26'h048_0000, BASE_TILES_L2 = 26'h0C8_0000,
	                        BASE_SPRITES  = 26'h0E8_0000, BASE_OKI      = 26'h108_0000;

	// byte k of a granule is its k-th byte; within a model word the even byte is low
	function automatic logic [7:0] mbyte(input logic [25:0] a);
		logic [15:0] w;
		w = u_chip.mem[a[24:1]];
		return a[0] ? w[15:8] : w[7:0];
	endfunction

	// ---- OKI: jt6295 behind the selected bridge ----
	bit use_new = 1;
	logic [9:0] cen_acc = 10'd0;
	always_ff @(posedge clk) cen_acc <= (cen_acc >= 10'd945 - 10'd11) ? cen_acc + 10'd11 - 10'd945 : cen_acc + 10'd11;
	wire cen_oki = (cen_acc >= 10'd945 - 10'd11);
	logic       wrn = 1'b1;
	logic [7:0] din = 8'd0;
	logic [17:0] oki_rom_addr;
	logic [7:0]  rd_old, rd_new;
	logic        ok_old, ok_new, req_old, req_new;
	logic [19:0] a_old, a_new;
	wire         snd_reset = reset;
	jt6295 #(.INTERPOL(0)) u_oki (
		.rst(snd_reset), .clk, .cen(cen_oki), .ss(1'b1), .wrn, .din, .dout(),
		.rom_addr(oki_rom_addr), .rom_data(use_new ? rd_new : rd_old), .rom_ok(use_new ? ok_new : ok_old),
		.sound(), .sample()
	);
	share_bridge_old u_old (.clk, .reset(snd_reset), .rom_addr(oki_rom_addr), .rom_data(rd_old), .rom_ok(ok_old),
		.bank(2'd2), .req(req_old), .addr(a_old), .valid(smp_valid && !use_new), .data(smp_data));
	share_bridge_new u_new (.clk, .reset(snd_reset), .rom_addr(oki_rom_addr), .rom_data(rd_new), .rom_ok(ok_new),
		.bank(2'd2), .req(req_new), .addr(a_new), .valid(smp_valid && use_new), .data(smp_data));
	assign smp_req  = use_new ? req_new : req_old;
	assign smp_addr = 22'(use_new ? a_new : a_old);

	int errors = 0;
	int n_smp = 0, n_z80 = 0, n_cpu = 0, n_gfx = 0;
	int e_smp = 0, e_z80 = 0, e_cpu = 0, e_gfx = 0;
	bit checking = 0;

	// the sample cache captures its request on req's rising edge
	logic        smp_req_d = 0;
	logic [21:0] smp_cap;
	always @(posedge clk) begin
		smp_req_d <= smp_req;
		if (smp_req && !smp_req_d) smp_cap <= smp_addr;
		if (smp_valid && checking) begin
			n_smp <= n_smp + 1;
			if (smp_data !== mbyte(BASE_OKI + 26'(smp_cap))) begin
				e_smp++; if (errors < 10) $display("  %0t ps OKI byte %05h: got %02h expected %02h", $time, smp_cap, smp_data, mbyte(BASE_OKI + 26'(smp_cap)));
				errors++;
			end
		end
	end

	task automatic oki_write(input [7:0] d);
		@(posedge clk); din <= d; wrn <= 1'b0;
		repeat (30) @(posedge clk);
		wrn <= 1'b1;
		repeat (8000) @(posedge clk);
	endtask

	// ---- Z80 program fetch: a pulse per M-cycle, address held until valid ----
	task automatic z80_client();
		logic [18:0] pc;
		pc = 19'h0;
		forever begin
			@(posedge clk);
			z80_addr <= pc; z80_req <= 1'b1;
			@(posedge clk);
			z80_req <= 1'b0;
			fork : wz
				begin do @(posedge clk); while (!z80_valid); end
				begin repeat (200000) @(posedge clk); $display("  STALL z80 at %05h", pc); errors++; end
			join_any
			disable wz;
			repeat (14 * (2 + $urandom % 4)) @(posedge clk);
			pc = ($urandom % 16 == 0) ? 19'($urandom % 32'h80000) : pc + 19'd1;
		end
	endtask

	// ---- 68000 program fetch: word pulses ----
	task automatic cpu_client();
		logic [25:0] a;
		a = 26'h400;
		forever begin
			@(posedge clk);
			cpu_addr <= a; cpu_req <= 1'b1;
			@(posedge clk);
			cpu_req <= 1'b0;
			fork : wc
				begin do @(posedge clk); while (!cpu_valid); end
				begin repeat (200000) @(posedge clk); $display("  STALL cpu at %06h", a); errors++; end
			join_any
			disable wc;
			repeat ($urandom % 6) @(posedge clk);
			a = ($urandom % 12 == 0) ? 26'(($urandom % 32'h100000) * 2) : a + 26'd2;
		end
	endtask

	// ---- graphics: held-until-valid granule reads on the higher-priority ports ----
	function automatic logic [63:0] mgran(input logic [25:0] a);
		for (int k = 0; k < 8; k++) mgran[8*k +: 8] = mbyte(a + 26'(k));
	endfunction
	task automatic gfx_client(input int which);
		forever begin
			logic [25:0] off;
			off = 26'(($urandom % 32'h40000) * 8);
			@(posedge clk);
			if (which < 3) begin tm_addr[which] <= off; tm_req[which] <= 1'b1; end
			else begin spr_addr <= off; spr_req <= 1'b1; end
			if (which < 3) begin do @(posedge clk); while (!tm_valid[which]); tm_req[which] <= 1'b0; end
			else           begin do @(posedge clk); while (!spr_valid);      spr_req <= 1'b0; end
			// bursts during "active video", idle otherwise
			if ($urandom % 64 == 0) repeat ($urandom % 20000) @(posedge clk);
		end
	endtask

	// Checks on the clock, where valid and data are read from the same cycle.
	localparam logic [25:0] GBASE [4] = '{BASE_TILES_L0, BASE_TILES_L1, BASE_TILES_L2, BASE_SPRITES};
	always @(posedge clk) begin
		if (z80_valid && checking) begin
			n_z80 <= n_z80 + 1;
			if (z80_data !== mbyte(BASE_AUDIOCPU + 26'(z80_addr))) begin
				e_z80++; if (errors < 10) $display("  %0t ps Z80 byte %05h: got %02h expected %02h", $time, z80_addr, z80_data, mbyte(BASE_AUDIOCPU + 26'(z80_addr)));
				errors++;
			end
		end
		if (cpu_valid && checking) begin
			n_cpu <= n_cpu + 1;
			if (cpu_data !== {mbyte(cpu_addr), mbyte(cpu_addr + 26'd1)}) begin
				e_cpu++; if (errors < 10) $display("  %0t ps CPU word %06h: got %04h expected %04h", $time, cpu_addr, cpu_data, {mbyte(cpu_addr), mbyte(cpu_addr + 26'd1)});
				errors++;
			end
		end
		for (int k = 0; k < 4; k++) begin
			logic v; logic [63:0] d; logic [25:0] o;
			v = (k < 3) ? tm_valid[k] : spr_valid;
			d = (k < 3) ? tm_data[k]  : spr_data;
			o = (k < 3) ? tm_addr[k]  : spr_addr;
			if (v && checking) begin
				n_gfx++;
				if (d !== mgran(GBASE[k] + o)) begin
					e_gfx++; if (errors < 10) $display("  %0t ps gfx%0d granule %06h: got %016h expected %016h", $time, k, o, d, mgran(GBASE[k] + o));
					errors++;
				end
			end
		end
	end

	initial begin
		int valid [$];
		int ms = 150;
		logic [7:0] oki [0:1048575];
		void'($value$plusargs("NEW=%d", use_new));
		void'($value$plusargs("MS=%d", ms));
		$display("=== tb_sdram_share: %s OKI bridge, %0d ms ===", use_new ? "NEW" : "OLD", ms);
		// content: a hash everywhere a client reads, gogomile's OKI ROM in its region
		for (int unsigned w = 0; w < 26'h118_0000 / 2; w++)
			u_chip.mem[w] = 16'((w * 32'h9E3779B1) >> 13);
		$readmemh("sim/fg2_sound_tb/oki.hex", oki);
		for (int i = 0; i < 1048576; i += 2)
			u_chip.mem[(BASE_OKI + 26'(i)) >> 1] = {oki[i+1], oki[i]};
		for (int p = 1; p < 128; p++) begin
			int b, s, e;
			b = 2 * 32'h40000 + p * 8;
			s = {oki[b], oki[b+1], oki[b+2]} & 32'h3FFFF;
			e = {oki[b+3], oki[b+4], oki[b+5]} & 32'h3FFFF;
			if (s > 0 && s < e && e < 32'h40000) valid.push_back(p);
		end
		repeat (20) @(posedge clk);
		reset = 0; init = 0;
		repeat (30000) @(posedge clk);
		checking = 1;
		fork
			z80_client();
			cpu_client();
			gfx_client(0); gfx_client(1); gfx_client(2); gfx_client(3);
			forever begin
				int c, p;
				c = $urandom % 4;
				p = valid[$urandom % valid.size()];
				oki_write(8'(8'h08 << c));
				oki_write(8'h80 | 8'(p));
				oki_write(8'(8'h10 << c));
				repeat (($urandom % 2) ? ($urandom % 3000) : ($urandom % 400000)) @(posedge clk);
			end
			begin
				repeat (ms) repeat (85909) @(posedge clk);
			end
		join_any
		$display("  fetches checked: OKI %0d, Z80 %0d, 68000 %0d, graphics %0d", n_smp, n_z80, n_cpu, n_gfx);
		$display("  errors: OKI %0d, Z80 %0d, 68000 %0d, graphics %0d, stalls/other %0d", e_smp, e_z80, e_cpu, e_gfx, errors - e_smp - e_z80 - e_cpu - e_gfx);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	// a smp request outstanding for 200k clk
	int smp_age = 0;
	always @(posedge clk) begin
		if (smp_valid || !smp_req) smp_age <= 0;
		else smp_age <= smp_age + 1;
		if (smp_age == 200000) begin $display("  STALL OKI request %05h", smp_addr); errors++; end
	end
endmodule

// ---- the bridge logic before 9714a18 ----
module share_bridge_old (
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
module share_bridge_new (
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
