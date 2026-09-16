// SDRAM backend: every ROM the core reads at runtime, on one physical chip.
//
// sdram.sv drives one MT48LC16M16 through three logical ports at fixed
// priority, port 0 over 1 over 2. Priority is the only bandwidth knob;
// another port is not more bandwidth.
//
//   Port 0   tilemap graphics (3 clients)   hardest deadline: no slack on the scanline being built
//   Port 1   sprite graphics (1 client)     rendered a line ahead, so a line of margin
//   Port 2   main CPU, Z80, samples, and the ROM download   starving the CPU only slows the game
//
// Unmeasured estimate at 5,472 clk per scanline, ~7 clk per granule:
// tilemaps ~83 granules (11%), CPU ~65 cache misses (8%), sprites
// scene-dependent.
//
// Address map. This module is the authority: every .mra loads to these
// offsets, and scripts/build_mra.py parses the FG2_BASE_* / FG3_BASE_*
// tables below to generate them. Two maps, one per board: a shared map
// sized for FG-3 would make FG-2 .mra files pad ~56 MB for a 17.5 MB game.

module fuuki_sdram_top (
	input  logic clk,
	// Power-on only: pass ~pll_locked. Do not pass the core reset or anything
	// that toggles with ioctl_download: MiSTer holds RESET for the whole
	// download, and a reset edge mid-transaction desynchronises the phy's req
	// toggle from sdram.sv's ack, so a later write is acknowledged unperformed.
	input  logic reset,

	// Starts the SDRAM init sequence. Same rule as reset.
	input  logic init,

	// ---- SDRAM pins ----
	output logic [12:0] SDRAM_A,
	inout  wire  [15:0] SDRAM_DQ,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nWE,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_CKE,

	// ---- HPS ROM download ----
	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic        board,         // BOARD_FG2 / BOARD_FG3: selects the region table
	input  logic [26:0] ioctl_addr,

	// Fast ROM loading: rom_loader drives the download port instead of the
	// ioctl path while ldr_active is high. The two never overlap; see
	// Fuuki.sv, "FAST ROM LOADING".
	input  logic        ldr_active,
	input  logic        ldr_req,
	input  logic [25:0] ldr_addr,
	input  logic [15:0] ldr_data,
	input  logic        ldr_we16,
	output logic        ldr_busy,
	input  logic [7:0]  ioctl_dout,
	output logic        ioctl_wait,

	// ---- tilemap graphics, 64-bit granules, 8-byte aligned ----
	input  logic        tm0_req,  input logic [25:0] tm0_addr,
	output logic        tm0_valid, output logic [63:0] tm0_data,
	input  logic        tm1_req,  input logic [25:0] tm1_addr,
	output logic        tm1_valid, output logic [63:0] tm1_data,
	input  logic        tm2_req,  input logic [25:0] tm2_addr,
	output logic        tm2_valid, output logic [63:0] tm2_data,

	// ---- sprite graphics ----
	input  logic        spr_req,  input logic [25:0] spr_addr,
	output logic        spr_valid, output logic [63:0] spr_data,

	// ---- main CPU program fetch, 16-bit words ----
	input  logic        cpu_req,
	input  logic [25:0] cpu_addr,      // byte address, even
	output logic        cpu_valid,
	output logic [15:0] cpu_data,

	// ---- sound: Z80 program bytes and sample bytes, either board ----
	// Offsets within their region; the bases are added here. FG-2: Z80 +
	// OKI samples. FG-3: Z80 + OPL4 wave ROM.
	input  logic        z80_req,
	input  logic [18:0] z80_addr,
	output logic        z80_valid,
	output logic [7:0]  z80_data,
	input  logic        smp_req,       // held until valid
	input  logic [21:0] smp_addr,
	output logic        smp_valid,
	output logic [7:0]  smp_data,

	// One pulse per download write the arbiter accepts, and its address.
	// Counted into the JTAG probe: "the stream reached the core" and "the
	// ROM reached the chip" are different claims.
	output logic        dbg_dl_wr,
	output logic [25:0] dbg_dl_addr
);

	// ---- address map, FG-2 ----
	// Ends at 0x118_0000, 17.5 MB.
	localparam logic [25:0] FG2_BASE_MAINCPU = 26'h000_0000;   // 2 MB reserved
	localparam logic [25:0] FG2_BASE_AUDIOCPU= 26'h020_0000;   // 512 KB
	localparam logic [25:0] FG2_BASE_TILES_L0= 26'h028_0000;   // 2 MB
	localparam logic [25:0] FG2_BASE_TILES_L1= 26'h048_0000;   // 8 MB
	localparam logic [25:0] FG2_BASE_TILES_L2= 26'h0C8_0000;   // 2 MB
	localparam logic [25:0] FG2_BASE_SPRITES = 26'h0E8_0000;   // 2 MB
	localparam logic [25:0] FG2_BASE_OKI     = 26'h108_0000;   // 1 MB

	// ---- address map, FG-3 ----
	// Sizes are the ROM_REGION declarations in fuukifg3.cpp, not the ROMs
	// loaded: asurabld leaves the first 4 MB of its 32 MB sprite region empty
	// and the sprite tile bank can address it, so the hole is part of the map.
	// Ends at 0x388_0000, 56.5 MB: 26 address bits; sdram.sv drives bit 25 onto A9.
	localparam logic [25:0] FG3_BASE_MAINCPU  = 26'h000_0000;   // 2 MB
	localparam logic [25:0] FG3_BASE_AUDIOCPU = 26'h020_0000;   // 512 KB
	localparam logic [25:0] FG3_BASE_TILES_L0 = 26'h028_0000;   // 8 MB
	localparam logic [25:0] FG3_BASE_TILES_L1 = 26'h0A8_0000;   // 8 MB
	localparam logic [25:0] FG3_BASE_TILES_L2 = 26'h128_0000;   // 2 MB  (MAME "tiles_bg")
	localparam logic [25:0] FG3_BASE_SPRITES  = 26'h148_0000;   // 32 MB
	localparam logic [25:0] FG3_BASE_OKI      = 26'h348_0000;   // 4 MB  (MAME "ymf", OPL4 samples)

	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	wire [25:0] base_maincpu  = (board == BOARD_FG3) ? FG3_BASE_MAINCPU  : FG2_BASE_MAINCPU;
	wire [25:0] base_audiocpu = (board == BOARD_FG3) ? FG3_BASE_AUDIOCPU : FG2_BASE_AUDIOCPU;
	wire [25:0] base_oki      = (board == BOARD_FG3) ? FG3_BASE_OKI      : FG2_BASE_OKI;
	wire [25:0] base_tiles_l0 = (board == BOARD_FG3) ? FG3_BASE_TILES_L0 : FG2_BASE_TILES_L0;
	wire [25:0] base_tiles_l1 = (board == BOARD_FG3) ? FG3_BASE_TILES_L1 : FG2_BASE_TILES_L1;
	wire [25:0] base_tiles_l2 = (board == BOARD_FG3) ? FG3_BASE_TILES_L2 : FG2_BASE_TILES_L2;
	wire [25:0] base_sprites  = (board == BOARD_FG3) ? FG3_BASE_SPRITES  : FG2_BASE_SPRITES;

	// ---- physical controller ----
	logic [25:1] p_addr [0:2];
	logic        p_wrl  [0:2];
	logic        p_wrh  [0:2];
	logic [15:0] p_din  [0:2];
	logic [63:0] p_dout [0:2];
	logic        p_req  [0:2];
	logic        p_ack  [0:2];

	sdram u_sdram (
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]),
		.din0(p_din[0]), .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]),
		.addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]),
		.din1(p_din[1]), .dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
		.addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]),
		.din2(p_din[2]), .dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2])
	);

	// ---- one phy per physical port ----
	logic        phy_req [0:2], phy_we [0:2], phy_we16 [0:2];
	logic [25:0] phy_addr [0:2];
	logic [15:0] phy_wdata [0:2];
	logic        phy_busy [0:2], phy_valid [0:2];
	logic [63:0] phy_rdata [0:2];

	genvar p;
	generate
		for (p = 0; p < 3; p++) begin : phy
			sdram_phy u_phy (
				.clk(clk), .reset(reset),
				.port_addr(p_addr[p]), .port_wrl(p_wrl[p]), .port_wrh(p_wrh[p]),
				.port_din(p_din[p]), .port_dout(p_dout[p]),
				.port_req(p_req[p]), .port_ack(p_ack[p]),
				.req(phy_req[p]), .we(phy_we[p]), .we16(phy_we16[p]),
				.addr(phy_addr[p]), .wdata(phy_wdata[p]),
				.busy(phy_busy[p]), .valid(phy_valid[p]), .rdata(phy_rdata[p])
			);
		end
	endgenerate

	// ---- port 0: the three tilemap streams ----
	// Correlated consumers with identical scanline timing. If they stall,
	// the fix is an N-entry ring per client, not a bigger arbiter.
	logic [2:0]     tm_req_v;
	logic [77:0]    tm_addr_v;   // 3 x 26: must match sdram_arbiter's per-client width
	logic [2:0]     tm_valid_v;
	logic [63:0]    tm_rdata;

	assign tm_req_v  = {tm2_req, tm1_req, tm0_req};
	assign tm_addr_v = {tm2_addr + base_tiles_l2,
	                    tm1_addr + base_tiles_l1,
	                    tm0_addr + base_tiles_l0};

	assign tm0_valid = tm_valid_v[0];
	assign tm1_valid = tm_valid_v[1];
	assign tm2_valid = tm_valid_v[2];
	// Shared read bus: capture on your own valid, nowhere else.
	assign tm0_data = tm_rdata;
	assign tm1_data = tm_rdata;
	assign tm2_data = tm_rdata;

	sdram_arbiter #(.N(3)) u_arb_tm (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[0]), .phy_we(phy_we[0]), .phy_we16(phy_we16[0]),
		.phy_addr(phy_addr[0]), .phy_wdata(phy_wdata[0]),
		.phy_busy(phy_busy[0]), .phy_valid(phy_valid[0]), .phy_rdata(phy_rdata[0]),
		.c_req(tm_req_v), .c_addr(tm_addr_v), .c_valid(tm_valid_v), .c_rdata(tm_rdata),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ---- port 1: sprite graphics, a single client ----
	// Still through an arbiter; see sdram_arbiter.sv on N = 1.
	logic [0:0] spr_req_v, spr_valid_v;
	assign spr_req_v = spr_req;
	assign spr_valid = spr_valid_v[0];

	sdram_arbiter #(.N(1)) u_arb_spr (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
		.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
		.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
		.c_req(spr_req_v), .c_addr(spr_addr + base_sprites),
		.c_valid(spr_valid_v), .c_rdata(spr_data),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ---- port 2: main CPU, Z80, samples, and the ROM download ----
	logic        dl_req, dl_we16;
	logic        dl_busy;
	logic [25:0] dl_addr;
	logic [15:0] dl_data;
	logic        dl_busy_d;
	// The arbiter raises dl_busy when it latches a download request, so its
	// rising edge is exactly one accepted write.
	always_ff @(posedge clk) dl_busy_d <= dl_busy;
	assign dbg_dl_wr   = dl_busy & ~dl_busy_d;
	assign dbg_dl_addr = dl_addr;

	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// The bridge caches one granule (sdram_narrow_bridge.sv).
	logic        cpu_g_req, cpu_g_valid;
	logic [25:0] cpu_g_addr;
	logic [63:0] cpu_g_data;

	logic [15:0] cpu_word_le;

	// inval = ioctl_download is the cache's only invalidation. Leave it
	// unconnected and the cache serves the previous load's image.
	sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(cpu_req), .addr(cpu_addr + base_maincpu),
		.valid(cpu_valid), .data(cpu_word_le),
		.g_req(cpu_g_req), .g_addr(cpu_g_addr),
		.g_valid(cpu_g_valid), .g_data(cpu_g_data)
	);

	// Byte order, fixed at the seam. The download packs a byte pair as
	// {odd, even}, so SDRAM holds words little-endian. A 68k program word
	// has the even byte as its high half. The graphics ports need no swap:
	// they consume granules in ascending byte order.
	assign cpu_data = {cpu_word_le[7:0], cpu_word_le[15:8]};

	logic        z80_g_req, z80_g_valid;
	logic [25:0] z80_g_addr;
	logic [63:0] z80_g_data;
	sdram_narrow_bridge #(.WORD_BYTES(1)) u_z80_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(z80_req), .addr(26'(z80_addr) + base_audiocpu),
		.valid(z80_valid), .data(z80_data),
		.g_req(z80_g_req), .g_addr(z80_g_addr),
		.g_valid(z80_g_valid), .g_data(z80_g_data)
	);

	// Sample fetches interleave many channels (OKI 4, OPL4 24), so a single
	// cached granule would evict on every fetch. Hence the multi-entry cache.
	logic        smp_g_req, smp_g_valid;
	logic [25:0] smp_g_addr;
	logic [63:0] smp_g_data;
	sample_cache #(.ENTRIES(16)) u_smp_cache (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(smp_req), .addr(26'(smp_addr) + base_oki),
		.valid(smp_valid), .data(smp_data),
		.g_req(smp_g_req), .g_addr(smp_g_addr),
		.g_valid(smp_g_valid), .g_data(smp_g_data)
	);

	logic [2:0] p2_req_v, p2_valid_v;
	logic [63:0] p2_rdata;
	assign p2_req_v    = {smp_g_req, z80_g_req, cpu_g_req};
	assign cpu_g_valid = p2_valid_v[0];
	assign z80_g_valid = p2_valid_v[1];
	assign smp_g_valid = p2_valid_v[2];
	assign cpu_g_data  = p2_rdata;
	assign z80_g_data  = p2_rdata;
	assign smp_g_data  = p2_rdata;

	// One download port on the arbiter, driven by whichever loader is live.
	logic        arb_dl_req, arb_dl_we16, arb_dl_busy;
	logic [25:0] arb_dl_addr;
	logic [15:0] arb_dl_data;
	assign arb_dl_req  = ldr_active ? ldr_req  : dl_req;
	assign arb_dl_addr = ldr_active ? ldr_addr : dl_addr;
	assign arb_dl_data = ldr_active ? ldr_data : dl_data;
	assign arb_dl_we16 = ldr_active ? ldr_we16 : dl_we16;
	assign dl_busy     = ldr_active ? 1'b0        : arb_dl_busy;
	assign ldr_busy    = ldr_active ? arb_dl_busy : 1'b0;

	sdram_arbiter #(.N(3)) u_arb_cpu (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[2]), .phy_we(phy_we[2]), .phy_we16(phy_we16[2]),
		.phy_addr(phy_addr[2]), .phy_wdata(phy_wdata[2]),
		.phy_busy(phy_busy[2]), .phy_valid(phy_valid[2]), .phy_rdata(phy_rdata[2]),
		.c_req(p2_req_v), .c_addr({smp_g_addr, z80_g_addr, cpu_g_addr}),
		.c_valid(p2_valid_v), .c_rdata(p2_rdata),
		.dl_req(arb_dl_req), .dl_addr(arb_dl_addr), .dl_data(arb_dl_data),
		.dl_we16(arb_dl_we16), .dl_busy(arb_dl_busy)
	);

endmodule
