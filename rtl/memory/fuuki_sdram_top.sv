// SDRAM backend: every ROM the core reads at runtime, on one physical chip.
//
// ---------------------------------------------------------------------------
// PORT ASSIGNMENT, AND WHY IT IS THE ONLY BANDWIDTH KNOB THERE IS.
//
// sdram.sv drives ONE physical MT48LC16M16. Its three "ports" are logical and
// time-multiplexed, arbitrated onto that single chip with FIXED PRIORITY --
// port 0 always preempts port 1, which always preempts port 2. So "use another
// port" is not more parallel bandwidth; the only thing available to tune is
// which client sits behind which priority slot.
//
//   Port 0   the three tilemap graphics streams (arbiter, 3 clients)
//   Port 1   sprite graphics                    (arbiter, 1 client)
//   Port 2   main CPU program fetch + HPS ROM download (arbiter, 2 clients)
//
// Tilemaps take the top slot because they have the hardest deadline: a late
// tilemap granule corrupts the picture on the scanline being built, with no
// slack anywhere. Sprites come next -- also per-scanline, but rendering a line
// ahead into a buffer gives them a line of margin. The CPU sits last on
// purpose: starving it makes the game run slower, which degrades gracefully,
// whereas starving either video path does not.
//
// The download shares port 2 and takes absolute priority within it, which
// costs nothing because it only runs before anything is being drawn.
//
// Rough demand at 5,472 clk per scanline, ~7 cycles per granule:
//   tilemaps  ~83 granules  ->  ~580 clk   (11%)
//   CPU       ~65 misses    ->  ~455 clk   ( 8%)  behind the granule cache
//   sprites   scene-dependent
// Comfortable, but MEASURE it rather than trusting this note: Psikyo left
// whole-frame sprite throughput unbudgeted, and its render slowdown under load
// is still open -- its ROADMAP's "Fix the slowdown" records the first
// re-partition attempt as measuring WORSE, not better.
// ---------------------------------------------------------------------------
//
// Address map. This module is the authority; every `.mra` must load to these
// same offsets, and scripts/build_mra.py generates them from this table.
//
// There are TWO maps, one per board, not one map sized for the larger. A
// shared map sized for FG-3 would force gogomile's `.mra` to pad out to FG-3's
// sprite base and ship ~56 MB of filler for a 17.5 MB game. The boards never
// coexist in one session, so the cost of two tables is a mux.

module fuuki_sdram_top (
	input  logic clk,
	// MASKED OFF DURING THE DOWNLOAD. The caller must pass
	//
	//     reset & ~ioctl_download
	//
	// and NOT the framework's RESET, because MiSTer holds core RESET asserted
	// for the ENTIRE ROM download. Anything in the memory path gated by a
	// reset that includes it is dead for the whole transfer: the download FSM
	// sits in idle while the HPS delivers every byte, not one write reaches
	// the chip, and every later read returns power-up contents.
	//
	// This is not a hypothetical. Psikyo hit it, LESSONS_LEARNED records it
	// ("Never hold the memory path in the core reset"), this header warned
	// about it -- and the first Fuuki bitstream still shipped with plain
	// `reset` wired here. It came up as a correct 320x240 raster that was
	// 100% black: video timing is independent of memory, so the only symptom
	// was that nothing was ever drawn.
	input  logic reset,

	// SDRAM power-up initialisation, SEPARATE from `reset` on purpose. This
	// drives the chip's init sequence and must NOT be asserted by a core
	// reset or a download -- pass `~pll_locked`.
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
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic        ioctl_wait,

	// ---- tilemap graphics, 64-bit granules, 8-byte aligned ----
	input  logic        tm0_req,  input logic [24:0] tm0_addr,
	output logic        tm0_valid, output logic [63:0] tm0_data,
	input  logic        tm1_req,  input logic [24:0] tm1_addr,
	output logic        tm1_valid, output logic [63:0] tm1_data,
	input  logic        tm2_req,  input logic [24:0] tm2_addr,
	output logic        tm2_valid, output logic [63:0] tm2_data,

	// ---- sprite graphics ----
	input  logic        spr_req,  input logic [24:0] spr_addr,
	output logic        spr_valid, output logic [63:0] spr_data,

	// ---- main CPU program fetch, 16-bit words ----
	input  logic        cpu_req,
	input  logic [24:0] cpu_addr,      // byte address, even
	output logic        cpu_valid,
	output logic [15:0] cpu_data,

	// One pulse per download write the arbiter actually ACCEPTS. Counted into
	// the JTAG probe, because "the ROM stream reached the core" and "the ROM
	// reached the chip" are different claims and the first bitstream
	// satisfied only the first: the download FSM was held in reset, so bytes
	// arrived and nothing was written, with no symptom but a black screen.
	output logic        dbg_dl_wr
);

	// ---- address map, FG-2 ----
	// Sized for the largest FG-2 set: ends at 0x118_0000, 17.5 MB, so both
	// FG-2 games fit the 32 MB chip this controller currently addresses.
	localparam logic [24:0] BASE_MAINCPU = 25'h000_0000;   // 2 MB reserved
	localparam logic [24:0] BASE_AUDIOCPU= 25'h020_0000;   // 512 KB
	localparam logic [24:0] BASE_TILES_L0= 25'h028_0000;   // 2 MB
	localparam logic [24:0] BASE_TILES_L1= 25'h048_0000;   // 8 MB
	localparam logic [24:0] BASE_TILES_L2= 25'h0C8_0000;   // 2 MB
	localparam logic [24:0] BASE_SPRITES = 25'h0E8_0000;   // 2 MB
	localparam logic [24:0] BASE_OKI     = 25'h108_0000;   // 1 MB

	// =====================================================================
	// ---- address map, FG-3 ----
	//
	// The regions total 56.5 MB laid end to end with no packing tricks, so
	// the map needs 26 address bits and would run unchanged on either a 64 MB
	// or the 128 MB module -- it does not decide which board FG-3 requires.
	// That choice is docs/ROADMAP.md's open item 1, and it was made on
	// AVAILABILITY (32 MB and 128 MB are the boards people actually own), not
	// on capacity. Sizing the map for 64 MB and the controller for the target
	// module keeps the two questions apart.
	//
	// Sizes are the ROM_REGION declarations in fuukifg3.cpp, not the sum of
	// the ROMs actually loaded: asurabld leaves the first 4 MB of its 32 MB
	// sprite region empty ("spXX.uYY -- XX is the bank number"), and the
	// sprite tile bank can address it, so the hole is part of the map.
	//
	// NOT YET WIRED. Every address port through this module, its arbiters,
	// phy and bridge is [24:0] / [24:1] -- 32 MB -- and FG-3 needs [25:0].
	// The `.mra` files are generated against this table (scripts/build_mra.py
	// parses it), so the offsets are fixed and the widening is mechanical,
	// but until it lands FG-3 cannot run. See docs/ROADMAP.md.
	// =====================================================================
	localparam logic [25:0] FG3_BASE_MAINCPU  = 26'h000_0000;   // 2 MB
	localparam logic [25:0] FG3_BASE_AUDIOCPU = 26'h020_0000;   // 512 KB
	localparam logic [25:0] FG3_BASE_TILES_L0 = 26'h028_0000;   // 8 MB
	localparam logic [25:0] FG3_BASE_TILES_L1 = 26'h0A8_0000;   // 8 MB
	localparam logic [25:0] FG3_BASE_TILES_L2 = 26'h128_0000;   // 2 MB  (MAME "tiles_bg")
	localparam logic [25:0] FG3_BASE_SPRITES  = 26'h148_0000;   // 32 MB
	localparam logic [25:0] FG3_BASE_OKI      = 26'h348_0000;   // 4 MB  (MAME "ymf", OPL4 samples)
	// end 0x388_0000 = 56.5 MB

	// ---- physical controller ----
	logic [24:1] p_addr [0:2];
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
	logic [24:0] phy_addr [0:2];
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

	// =====================================================================
	// Port 0 -- the three tilemap graphics streams.
	//
	// These are CORRELATED consumers, not independent ones: three layers with
	// identical scanline timing request in near-lockstep. Psikyo sized a
	// 2-entry ping-pong buffer for two such streams and it absorbed only one
	// simultaneous loss, stalling roughly one tile in five. If that shows up
	// here, the answer is an N-entry ring per client, not a bigger arbiter.
	// =====================================================================
	logic [2:0]     tm_req_v;
	logic [74:0]    tm_addr_v;     // 3 x 25
	logic [2:0]     tm_valid_v;
	logic [63:0]    tm_rdata;

	assign tm_req_v  = {tm2_req, tm1_req, tm0_req};
	assign tm_addr_v = {tm2_addr + BASE_TILES_L2,
	                    tm1_addr + BASE_TILES_L1,
	                    tm0_addr + BASE_TILES_L0};

	assign tm0_valid = tm_valid_v[0];
	assign tm1_valid = tm_valid_v[1];
	assign tm2_valid = tm_valid_v[2];
	// Shared read bus: capture it on YOUR OWN valid and nowhere else. Every
	// port's data comes from one register inside sdram.sv, so sampling a cycle
	// late reads another client's in-flight granule.
	assign tm0_data = tm_rdata;
	assign tm1_data = tm_rdata;
	assign tm2_data = tm_rdata;

	sdram_arbiter #(.N(3)) u_arb_tm (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[0]), .phy_we(phy_we[0]), .phy_we16(phy_we16[0]),
		.phy_addr(phy_addr[0]), .phy_wdata(phy_wdata[0]),
		.phy_busy(phy_busy[0]), .phy_valid(phy_valid[0]), .phy_rdata(phy_rdata[0]),
		.c_req(tm_req_v), .c_addr(tm_addr_v), .c_valid(tm_valid_v), .c_rdata(tm_rdata),
		.dl_req(1'b0), .dl_addr(25'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// =====================================================================
	// Port 1 -- sprite graphics, a single client.
	//
	// Still through an arbiter, deliberately. sdram_phy asserts valid and
	// returns to idle on the SAME cycle, so a held request wired straight to
	// it is re-sampled as a second transaction and the client silently gets
	// the previous transaction's data. Arbitrated clients get a cycle of
	// margin because c_valid asserts one cycle before the arbiter returns to
	// idle. Psikyo gave sprite gfx a dedicated unarbitrated port on the
	// grounds that one client needs no arbiter, and it produced corrupted
	// sprites under contention -- the third occurrence of that defect class in
	// that project.
	// =====================================================================
	logic [0:0] spr_req_v, spr_valid_v;
	assign spr_req_v = spr_req;
	assign spr_valid = spr_valid_v[0];

	sdram_arbiter #(.N(1)) u_arb_spr (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
		.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
		.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
		.c_req(spr_req_v), .c_addr(spr_addr + BASE_SPRITES),
		.c_valid(spr_valid_v), .c_rdata(spr_data),
		.dl_req(1'b0), .dl_addr(25'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// =====================================================================
	// Port 2 -- main CPU program fetch, and the ROM download.
	// =====================================================================
	logic        dl_req, dl_we16, dl_busy;
	logic        dl_busy_d;
	// The arbiter latches a download request by raising dl_busy, so its rising
	// edge is exactly one accepted write.
	always_ff @(posedge clk) dl_busy_d <= dl_busy;
	assign dbg_dl_wr = dl_busy & ~dl_busy_d;
	logic [24:0] dl_addr;
	logic [15:0] dl_data;

	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// The CPU fetches 16-bit words; the transport moves 64-bit granules. The
	// bridge holds a granule so three of every four sequential fetches hit
	// without touching the chip at all -- which is most of why the CPU's
	// bandwidth share stays modest.
	logic        cpu_g_req, cpu_g_valid;
	logic [24:0] cpu_g_addr;
	logic [63:0] cpu_g_data;

	logic [15:0] cpu_word_le;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
		.clk(clk), .reset(reset),
		.req(cpu_req), .addr(cpu_addr + BASE_MAINCPU),
		.valid(cpu_valid), .data(cpu_word_le),
		.g_req(cpu_g_req), .g_addr(cpu_g_addr),
		.g_valid(cpu_g_valid), .g_data(cpu_g_data)
	);

	// BYTE ORDER, FIXED AT THE SEAM.
	//
	// The download packs a byte pair as {odd, even}, so SDRAM holds words
	// little-endian, and the bridge's generic word path hands them back that
	// way -- which is correct for genuinely little-endian regions and wrong
	// for a 68k program image, where byte N of the .mra stream is the MORE
	// significant half of its word.
	//
	// The adapter goes HERE, at the one consumer that needs it, rather than
	// changing the bridge's convention out from under its other callers.
	// LESSONS_LEARNED, "Fix byte order at the seam, with a dedicated adapter".
	// Note the graphics ports need no equivalent: they consume raw 64-bit
	// granules in ascending-address order, which is already what they want.
	assign cpu_data = {cpu_word_le[7:0], cpu_word_le[15:8]};

	logic [0:0] cpu_req_v, cpu_valid_v;
	assign cpu_req_v   = cpu_g_req;
	assign cpu_g_valid = cpu_valid_v[0];

	sdram_arbiter #(.N(1)) u_arb_cpu (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[2]), .phy_we(phy_we[2]), .phy_we16(phy_we16[2]),
		.phy_addr(phy_addr[2]), .phy_wdata(phy_wdata[2]),
		.phy_busy(phy_busy[2]), .phy_valid(phy_valid[2]), .phy_rdata(phy_rdata[2]),
		.c_req(cpu_req_v), .c_addr(cpu_g_addr),
		.c_valid(cpu_valid_v), .c_rdata(cpu_g_data),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

endmodule
