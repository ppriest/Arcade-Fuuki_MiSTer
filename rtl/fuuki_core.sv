// The whole Fuuki core below the MiSTer framework glue: CPU, work/video RAM,
// the three tilemap layers, the sprite path, the compositor and the SDRAM
// backend. Fuuki.sv wires this to hps_io, the PLL and arcade_video and does
// nothing else of substance.
//
// The split is deliberate. Everything here is testable in ModelSim against
// MAME captures; everything in Fuuki.sv needs a DE10-nano to exercise. Keeping
// framework glue out of this file is what lets sim/video_tb drive the same
// modules the bitstream does.
//
// ---------------------------------------------------------------------------
// TWO RESET DOMAINS, AND THIS IS NOT OPTIONAL.
//
//   `reset`      reset & ~ioctl_download. Feeds the SDRAM backend ONLY.
//   `init`       ~pll_locked. The SDRAM chip's own power-up sequence.
//   `core_reset` reset | ioctl_download. Feeds the CPU and the video pipeline.
//
// The MASK on the first one is the part that is easy to get wrong, and the
// first Fuuki bitstream did get it wrong: `reset` was passed through with the
// framework's RESET still in it.
//
// MiSTer holds core RESET asserted for the ENTIRE ROM download. Anything in
// the memory path gated by a reset that includes the download is dead for the
// whole transfer: Psikyo passed a composite reset into its SDRAM top, the
// download FSM sat in idle while the HPS delivered every byte, not one write
// reached the chip, and every later read returned power-up contents
// (LESSONS_LEARNED, "Never hold the memory path in the core reset"). The
// symptom was a black screen with nothing pointing at memory.
// ---------------------------------------------------------------------------
//
// ONE .rbf SERVES BOTH BOARDS. `board` comes from the .mra mod byte and
// picks the CPU mode, the tile depths, the colour shift and the sprite
// buffering. It is a runtime input, never a parameter.

module fuuki_core (
	input  logic clk,          // 85.909091 MHz
	input  logic ce_pix,       // clk/12 = 7.159091 MHz
	// SDRAM path only, and it must be MASKED OFF during the download:
	// pass `reset & ~ioctl_download`, never the framework's RESET. See
	// fuuki_sdram_top.sv's port comment for what happens otherwise.
	input  logic reset,
	// SDRAM chip power-up init, separate from any core reset: `~pll_locked`.
	input  logic init,
	input  logic core_reset,   // reset | ioctl_download: CPU and video

	// ---- board select, from the .mra mod byte ----
	input  logic board,   // BOARD_FG2 / BOARD_FG3
	input  logic sysport_alt,  // pbancho/asura SYSTEM layout (see Fuuki.sv)

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
	input  logic [26:0] ioctl_addr,

	// Fast ROM load (Fuuki.sv drives these; see rtl/memory/rom_loader.sv)
	input  logic        ldr_active,
	input  logic        ldr_req,
	input  logic [25:0] ldr_addr,
	input  logic [15:0] ldr_data,
	input  logic        ldr_we16,
	output logic        ldr_busy,
	input  logic [7:0]  ioctl_dout,
	output logic        ioctl_wait,

	// ---- inputs, already assembled into the driver's port words ----
	input  logic [15:0] system_in,
	input  logic [15:0] p1p2_in,
	input  logic [15:0] dsw_in,
	input  logic [15:0] dsw2_in,

	input  logic        pause_cpu,

	// ---- per-layer enables, for bisecting a rendering fault live ----
	input  logic        en_l0, en_l1, en_l2, en_spr,
	// Sound halves, so a missing sound can be attributed without a rebuild.
	input  logic        en_fm, en_pcm,

	// ---- video out, 2 clocks behind hcnt (see the output stage) ----
	output logic [7:0]  video_r,
	output logic [7:0]  video_g,
	output logic [7:0]  video_b,
	output logic        video_hs,
	output logic        video_vs,
	output logic        video_hb,
	output logic        video_vb,
	output logic        video_ce,

	// ---- audio, signed. FG-2's mono mix goes to both channels; FG-3's
	// OPL4 is stereo. ----
	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,

	// ---- for the JTAG probe ----
	output logic        dbg_frame_start,
	output logic        dbg_line_start,
	output logic        dbg_spr_ovr,
	output logic        dbg_cpu_req,
	output logic        dbg_gfx_req,
	output logic [20:0] dbg_rom_addr,
	output logic        dbg_rom_valid,
	output logic [15:0] dbg_rom_data,
	output logic        dbg_dl_wr,
	output logic [25:0] dbg_dl_addr,
	output logic [2:0]  dbg_irq_pending, // {irq5, irq3, irq1} pending in maincpu
	output logic        dbg_iack,        // interrupt-acknowledge access in progress
	output logic [2:0]  dbg_iack_level,  // level on A3..A1 during it
	output logic        dbg_irq1_trig,   // the line-248 interrupt source, one clk per frame
	output logic [15:0] dbg_smp,         // sound health: fetch watch + last OPL4 register
	output logic        dbg_z80_m1,      // one pulse per Z80 opcode fetch, either board
	output logic        dbg_ym_wr,       // one pulse per write to a sound chip, either board
	output logic        dbg_pcm_keyon,   // FG-3: OPL4 PCM voice keyed on
	output logic        dbg_fm_keyon,    // FG-3: OPL4 FM voice keyed on (nothing plays it yet)

	// ---- trace-to-screen controls (see the debug_tracer instance) ----
	input  logic        dbg_overlay,
	input  logic [1:0]  dbg_src,
	input  logic [3:0]  dbg_window,
	input  logic        dbg_ring,
	input  logic        dbg_rearm,
	input  logic [2:0]  dbg_page,     // which 40-entry page of the buffer to show
	input  logic [23:0] dbg_dump,     // memory dump: {region[3:0], page[19:0]} (JTAG source [31:8])
	input  logic        dbg_trig,     // ring mode: freeze on the first exception-vector read
	input  logic        dbg_marker,   // white pixels at x 0..7 on lines 0 and 239: is the framing exact?
	input  logic [1:0]  raster_lead,  // lines early for level 5: 0, 1 or 2 (video_timing.sv)
	output logic        dbg_frozen
);


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	// =====================================================================
	// Video timing
	// =====================================================================
	logic [8:0] hcnt, vcnt, vcnt_next, vcnt_next2;
	logic       h_active, v_active, hblank, vblank, hsync, vsync;
	logic       line_start, frame_start;
	logic       irq1_trig, irq3_trig, irq5_trig;
	logic [8:0] raster_line;

	video_timing u_vt (
		.clk(clk), .ce_pix(ce_pix), .reset(core_reset),
		.raster_line(raster_line), .raster_lead(raster_lead),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start),
		.irq1_trig(irq1_trig), .irq3_trig(irq3_trig), .irq5_trig(irq5_trig)
	);

	assign dbg_frame_start = frame_start;
	assign dbg_line_start  = line_start;

	// =====================================================================
	// Main CPU
	// =====================================================================
	logic         rom_req, rom_valid;
	logic [20:0]  rom_addr;
	logic [15:0]  rom_data;

	logic [16:0]  workram_addr;
	logic         workram_wel, workram_weh;
	logic [15:0]  workram_wdata, workram_rdata;

	logic [13:0]  vram_addr;
	logic         vram_wel, vram_weh;
	logic [15:0]  vram_wdata, vram_rdata;

	logic [11:0]  spriteram_addr;
	logic         spriteram_wel, spriteram_weh;
	logic [15:0]  spriteram_wdata, spriteram_rdata;

	logic [12:0]  palette_addr;
	logic         palette_wel, palette_weh;
	logic [15:0]  palette_wdata, palette_rdata;

	logic [4:0]   vregs_addr;
	logic [1:0]   vregs_sel;
	logic [25:0]  dl_addr_dbg;
	logic [2:0]   cpu_fc;
	// Declared here, ABOVE the maincpu instance that pauses on it, not at the
	// walker where it is defined: vlog rejects use-before-declare (vlog-2388)
	// and Quartus silently resolves it, which is how it reached hardware.
	wire          walk_active = (dbg_src == 2'd3);
	// Memory-dump decode, declared here because the memories below index by it.
	wire [3:0]    dump_region = dbg_dump[23:20];
	wire [19:0]   dump_page   = dbg_dump[19:0];
	wire          walk_sdram  = (dump_region == 4'd0);
	wire          walk_mem    = walk_active && !walk_sdram;
	logic [7:0]   walk_idx = 8'd0;
	assign dbg_dl_addr = dl_addr_dbg;
	logic         vregs_wel, vregs_weh;
	logic [15:0]  vregs_wdata, vregs_rdata;

	logic [3:0]   sharedram_addr;
	logic         sharedram_we;
	logic [7:0]   sharedram_wdata, sharedram_rdata;

	logic [7:0]   latch_data;
	logic         latch_write;
	logic [31:0]  tilebank;

	maincpu u_cpu (
		.clk(clk), .reset(core_reset),
		.board(board),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.workram_addr(workram_addr),
		.workram_wel(workram_wel), .workram_weh(workram_weh),
		.workram_wdata(workram_wdata), .workram_rdata(workram_rdata),
		.vram_addr(vram_addr),
		.vram_wel(vram_wel), .vram_weh(vram_weh),
		.vram_wdata(vram_wdata), .vram_rdata(vram_rdata),
		.spriteram_addr(spriteram_addr),
		.spriteram_wel(spriteram_wel), .spriteram_weh(spriteram_weh),
		.spriteram_wdata(spriteram_wdata), .spriteram_rdata(spriteram_rdata),
		.palette_addr(palette_addr),
		.palette_wel(palette_wel), .palette_weh(palette_weh),
		.palette_wdata(palette_wdata), .palette_rdata(palette_rdata),
		.vregs_addr(vregs_addr), .vregs_sel(vregs_sel),
		.vregs_wel(vregs_wel), .vregs_weh(vregs_weh),
		.vregs_wdata(vregs_wdata), .vregs_rdata(vregs_rdata),
		.sharedram_addr(sharedram_addr), .sharedram_we(sharedram_we),
		.sharedram_wdata(sharedram_wdata), .sharedram_rdata(sharedram_rdata),
		.system_in(system_in), .p1p2_in(p1p2_in),
		.dsw_in(dsw_in), .dsw2_in(dsw2_in),
		.latch_data(latch_data), .latch_write(latch_write),
		.tilebank(tilebank),
		.irq1_trig(irq1_trig), .irq3_trig(irq3_trig), .irq5_trig(irq5_trig),
		.dbg_irq_pending(dbg_irq_pending), .dbg_iack(dbg_iack), .dbg_iack_level(dbg_iack_level),
		.pause(pause_cpu | walk_active),   // the walker owns the ROM port
		.dbg_fc(cpu_fc)
	);
	assign dbg_irq1_trig = irq1_trig;

	assign dbg_cpu_req   = rom_req;
	assign dbg_rom_addr  = rom_addr;
	assign dbg_rom_valid = rom_valid;
	assign dbg_rom_data  = rom_data;

	// FG-3's 16 shared bytes at 0x903FE0 are inside rtl/sound/fg3_sound.sv,
	// which is where the Z80 that answers on them lives. The bring-up stub
	// that used to play the Z80's side of srom.u7's handshake from here is
	// gone with it.

	// =====================================================================
	// Work RAM -- 64K x 16, one array serves both boards
	//
	// workram_addr is already a WORD address (maincpu.sv: addr24[17:1]), like
	// every other *_addr here, and is used whole. It was indexed [16:1] --
	// halved again -- so consecutive words shared one entry. The boot code
	// only wrote RAM until the first interrupt; then the 68000 stacked PC.lo,
	// PC.hi and SR into three words that occupied two entries, the ISR's
	// movem overwrote the SR's, and rte popped SR=0, PC=0: user mode at
	// address 0, then vector 4. The CPU testbench models this RAM itself
	// (sim/maincpu_tb, `BRAM), so it could not see the core's indexing.
	// Bit 16 is dropped: 0x410000-0x41FFFF mirrors 0x400000-0x40FFFF.
	// =====================================================================
	logic [15:0] workram [0:65535];
	always_ff @(posedge clk) begin
		if (workram_wel) workram[workram_addr[15:0]][7:0]  <= workram_wdata[7:0];
		if (workram_weh) workram[workram_addr[15:0]][15:8] <= workram_wdata[15:8];
		workram_rdata <= workram[walk_mem ? {dump_page[7:0], walk_idx} : workram_addr[15:0]];
	end

	// =====================================================================
	// Tilemap VRAM -- 16K x 16, FOUR readers
	//
	// The CPU and the three layer engines all read this, and every engine
	// needs its own registered single-cycle read (that is the contract in
	// tilemap_line_engine.sv). Rather than arbitrate -- which would break
	// that contract and stall the engines against each other -- the array is
	// MIRRORED: every write goes to all four copies, and each reader owns
	// one. Quartus infers four simple dual-port M10K blocks.
	//
	// The cost is 1 Mbit of the device's 5.5. It could be cut to a quarter,
	// because engine 0 only ever reads bank 0, engine 1 bank 1 and engine 2
	// banks 2/3 -- but that means slicing the address per copy, and a first
	// bitstream is the wrong place to trade a correctness risk for BRAM
	// there is no shortage of.
	// =====================================================================
	logic [13:0] tm_vaddr [0:2];
	logic [15:0] tm_vdata [0:2];

	logic [15:0] vram_cpu [0:16383];
	logic [15:0] vram_l0  [0:16383];
	logic [15:0] vram_l1  [0:16383];
	logic [15:0] vram_l2  [0:16383];

	always_ff @(posedge clk) begin
		if (vram_wel) begin
			vram_cpu[vram_addr][7:0] <= vram_wdata[7:0];
			vram_l0 [vram_addr][7:0] <= vram_wdata[7:0];
			vram_l1 [vram_addr][7:0] <= vram_wdata[7:0];
			vram_l2 [vram_addr][7:0] <= vram_wdata[7:0];
		end
		if (vram_weh) begin
			vram_cpu[vram_addr][15:8] <= vram_wdata[15:8];
			vram_l0 [vram_addr][15:8] <= vram_wdata[15:8];
			vram_l1 [vram_addr][15:8] <= vram_wdata[15:8];
			vram_l2 [vram_addr][15:8] <= vram_wdata[15:8];
		end
		vram_rdata  <= vram_cpu[walk_mem ? {dump_page[5:0], walk_idx} : vram_addr];
		tm_vdata[0] <= vram_l0[tm_vaddr[0]];
		tm_vdata[1] <= vram_l1[tm_vaddr[1]];
		tm_vdata[2] <= vram_l2[tm_vaddr[2]];
	end

	// =====================================================================
	// Palette -- 8192 x xRGB-555, CPU read/write plus the compositor's read
	// =====================================================================
	logic [12:0] pal_rd_addr;
	logic [15:0] pal_rd_data;

	logic [15:0] pal_cpu [0:8191];
	logic [15:0] pal_vid [0:8191];

	always_ff @(posedge clk) begin
		if (palette_wel) begin
			pal_cpu[palette_addr][7:0] <= palette_wdata[7:0];
			pal_vid[palette_addr][7:0] <= palette_wdata[7:0];
		end
		if (palette_weh) begin
			pal_cpu[palette_addr][15:8] <= palette_wdata[15:8];
			pal_vid[palette_addr][15:8] <= palette_wdata[15:8];
		end
		palette_rdata <= pal_cpu[walk_mem ? {dump_page[4:0], walk_idx} : palette_addr];
		pal_rd_data   <= pal_vid[pal_rd_addr];
	end

	// =====================================================================
	// Video registers
	// =====================================================================
	logic [15:0] layer_scrollx [0:2];
	logic [15:0] layer_scrolly [0:2];
	logic        flip, layer2_buffer;
	logic [1:0]  tmap_front, tmap_middle, tmap_back;

	vregs u_vregs (
		.clk(clk), .reset(core_reset),
		.board(board),
		.cpu_addr(walk_mem ? walk_idx[4:0] : vregs_addr),
		.cpu_sel(walk_mem ? (walk_idx < 8'd16 ? 2'd0 : walk_idx < 8'd18 ? 2'd1 : 2'd2) : vregs_sel),
		.cpu_wel(vregs_wel), .cpu_weh(vregs_weh),
		.cpu_wdata(vregs_wdata), .cpu_rdata(vregs_rdata),
		.layer0_scrollx(layer_scrollx[0]), .layer0_scrolly(layer_scrolly[0]),
		.layer1_scrollx(layer_scrollx[1]), .layer1_scrolly(layer_scrolly[1]),
		.layer2_scrollx(layer_scrollx[2]), .layer2_scrolly(layer_scrolly[2]),
		.flip(flip), .layer2_buffer(layer2_buffer), .raster_line(raster_line),
		.tmap_front(tmap_front), .tmap_middle(tmap_middle), .tmap_back(tmap_back)
	);

	// =====================================================================
	// PER-LINE REGISTER SNAPSHOT
	//
	// Everything the renderer reads out of the video registers is latched
	// once per scanline, at the START OF HBLANK, and the engines and the
	// compositor see only the latched copy.
	//
	// The engines used to read the live registers and sample them on their
	// line buffer's READY edge, which is not a fixed point in the line: a CPU
	// write landing near it took effect on one line or the next depending on
	// where the buffer's clear pass happened to be, so gogomile's title
	// clouds jittered back and forth between frames. Hblank is a fixed point
	// and is after the raster interrupt fires (video_timing drives irq5 at
	// hcnt == H_ACTIVE), so an ISR's write cannot race the latch it belongs
	// after.
	//
	// PER LINE, not per frame: pbancho rewrites the layer scroll from a
	// level-5 handler on every line of a band, and latching once per frame
	// would flatten exactly the effect the raster interrupt exists to produce.
	// =====================================================================
	wire vreg_latch = ce_pix && (hcnt == 9'd320);

	logic [15:0] r_scrollx [0:2], r_scrolly [0:2];
	logic        r_layer2_buffer;
	logic [1:0]  r_front, r_middle, r_back;

	always_ff @(posedge clk or posedge core_reset) begin
		if (core_reset) begin
			for (int i = 0; i < 3; i++) begin
				r_scrollx[i] <= 16'd0;
				r_scrolly[i] <= 16'd0;
			end
			r_layer2_buffer <= 1'b0;
			r_front <= 2'd0; r_middle <= 2'd1; r_back <= 2'd2;
		end else if (vreg_latch) begin
			for (int i = 0; i < 3; i++) begin
				r_scrollx[i] <= layer_scrollx[i];
				r_scrolly[i] <= layer_scrolly[i];
			end
			r_layer2_buffer <= layer2_buffer;
			r_front <= tmap_front; r_middle <= tmap_middle; r_back <= tmap_back;
		end
	end

	// =====================================================================
	// Per-layer configuration.
	//
	// Straight from each driver's GFXDECODE and video_start(), and the same
	// table scripts/prep_tilemap_tb.py writes for the testbench -- the two
	// must agree or the bitstream renders differently from the thing that
	// was diffed against MAME's screenshot.
	//
	//             layer 0        layer 1        layer 2
	//   FG-2      16x16x4        16x16x8        8x8x4
	//             gran 16        gran 16 (*)    gran 16
	//             trans 0x0f     trans 0xff     trans 0x0f
	//
	//   FG-3      16x16x8        16x16x8        8x8x4
	//             gran 256       gran 256       gran 16
	//             colour >>= 4   colour >>= 4   colour as-is
	//             trans 0xff     trans 0xff     trans 0x0f
	//
	// (*) FG-2's layer 1 is 8bpp with granularity SIXTEEN, set explicitly by
	//     gfx(1)->set_granularity(16). The pen legitimately exceeds the
	//     granularity and must never be masked.
	// =====================================================================
	wire [2:0] cfg_tile16 = 3'b011;                       // layers 0,1 are 16x16
	wire [2:0] cfg_bpp8   = (board == BOARD_FG3) ? 3'b011 : 3'b010;  // FG-2: layer 1 only
	wire [2:0] cfg_gran256= (board == BOARD_FG3) ? 3'b011 : 3'b000;
	wire [2:0] cfg_shift4 = (board == BOARD_FG3) ? 3'b011 : 3'b000;

	// gfx_base is 0 for every layer: fuuki_sdram_top adds BASE_TILES_Lx on
	// its own side, so an offset here would be applied twice.
	localparam logic [12:0] PAL_BASE [0:2] = '{13'h0000, 13'h0400, 13'h0C00};

	// =====================================================================
	// Three tilemap layers
	// =====================================================================
	logic        tm_req   [0:2];
	logic [25:0] tm_addr  [0:2];
	logic        tm_valid [0:2];
	logic [63:0] tm_data  [0:2];
	logic        tm_we    [0:2];
	logic [8:0]  tm_wx    [0:2];
	logic [13:0] tm_wd    [0:2];
	logic        tm_busy  [0:2], tm_done [0:2];
	logic [13:0] tm_rd    [0:2];
	logic        tm_ready [0:2];
	logic        tm_ready_d [0:2], tm_ready_rise [0:2];
	logic        tm_bank [0:2];       // each layer's line-buffer render bank (probe)
	logic        spr_lb_bank;         // the sprite line buffer's (probe)

	always_ff @(posedge clk) begin
		for (int i = 0; i < 3; i++) begin
			tm_ready_d[i]    <= tm_ready[i];
			tm_ready_rise[i] <= tm_ready[i] && !tm_ready_d[i];
		end
	end

	assign dbg_gfx_req = tm_req[0];

	genvar g;
	generate
		for (g = 0; g < 3; g++) begin : layer
			// Start on the line buffer's READY edge, not on line_start, and
			// render vcnt_next2 -- exactly as sim/video_tb wires it, because
			// that is the configuration whose composed frame was diffed
			// against MAME's screenshot. Starting at line_start puts the
			// engine's first ~320 writes inside the buffer's clear pass,
			// where the clear owns the write port and they vanish.
			//
			// NOTE video_timing.sv's header prescribes vcnt_next for tilemaps
			// and vcnt_next2 only for sprites, and jtcps1 does the same thing
			// (scroll at `vrender`, CPS2 objects at `vrender1`). This core
			// uses vcnt_next2 for BOTH, and the extra line is load-bearing:
			// it is what gives the engine a WHOLE LINE to render in.
			//
			// TRIED AND REVERTED: swapping the tilemap line buffers at the
			// start of active instead of at line_start, which presents a bank
			// one line earlier and so allows vcnt_next. It broke both games --
			// the right-hand side of every tilemap went blank and flickered --
			// because it also cuts the render window down to hblank: 1632 clk,
			// less the 320-clk clear, against a worst line measured at 1123
			// clk for ONE layer in isolation. Three layers share one SDRAM
			// port, so the real figure is larger and the engine simply does
			// not finish the line. jtcps1 gets away with one line because its
			// scroll layers render on the fly during the active display
			// rather than into a buffer during hblank.
			//
			// So the two-line lead stays until the renderer is fast enough,
			// or overlaps its fetch with the display, to live inside hblank.
			tilemap_line_engine u_tm (
				.clk(clk), .reset(core_reset),
				.line_start(tm_ready_rise[g]), .render_line(vcnt_next2),
				.busy(tm_busy[g]), .done(tm_done[g]),
				.vram_bank(g[1:0] == 2'd2 ? {1'b1, r_layer2_buffer} : g[1:0]),
				.tile16(cfg_tile16[g]), .bpp8(cfg_bpp8[g]),
				.colour_shift4(cfg_shift4[g]), .gran256(cfg_gran256[g]),
				.pal_base(PAL_BASE[g]),
				.trans_pen(cfg_bpp8[g] ? 8'hFF : 8'h0F),
				.gfx_base(26'd0),
				.scroll_x(r_scrollx[g]), .scroll_y(r_scrolly[g]),
				.flip(flip),
				.vram_addr(tm_vaddr[g]), .vram_data(tm_vdata[g]),
				.gfx_req(tm_req[g]), .gfx_addr(tm_addr[g]),
				.gfx_valid(tm_valid[g]), .gfx_data(tm_data[g]),
				.lb_we(tm_we[g]), .lb_x(tm_wx[g]), .lb_data(tm_wd[g])
			);

			line_buffer #(.WIDTH(14)) u_lb (
				.clk(clk), .reset(core_reset),
				.line_start(line_start), .ready(tm_ready[g]), .render_bank_o(tm_bank[g]),
				.we(tm_we[g]), .wx(tm_wx[g]), .wdata(tm_wd[g]),
				.rx(hcnt), .rdata(tm_rd[g])
			);
		end
	endgenerate

	// =====================================================================
	// Sprite path: buffered RAM -> once-per-frame candidate list -> per-line
	// engine -> double-buffered line buffer.
	// =====================================================================
	logic        copy_busy, copy_busy_d;
	logic [11:0] sr_addr;
	logic [15:0] sr_data;
	logic [31:0] tilebank_render;

	spriteram_dbuf u_sdbuf (
		.clk(clk), .reset(core_reset),
		.board(board),
		.cpu_addr(walk_mem ? {dump_page[3:0], walk_idx} : spriteram_addr),
		.cpu_wel(spriteram_wel), .cpu_weh(spriteram_weh),
		.cpu_wdata(spriteram_wdata), .cpu_rdata(spriteram_rdata),
		.tilebank_live(tilebank), .tilebank_render(tilebank_render),
		.copy_start(frame_start), .copy_busy(copy_busy),
		.rd_addr(sr_addr), .rd_data(sr_data)
	);

	// Both boards snapshot sprite RAM at frame_start (spriteram_dbuf), and
	// the list must not read across the copy: it builds when the copy ends.
	always_ff @(posedge clk) copy_busy_d <= copy_busy;
	wire copy_done  = copy_busy_d && !copy_busy;
	wire build_start = copy_done;

	logic        build_busy;
	logic [10:0] n_entries;
	logic [9:0]  yt_addr, rec_addr;
	logic [18:0] yt_data;
	logic [63:0] rec_data;

	sprite_line_list u_list (
		.clk(clk), .reset(core_reset),
		.build_start(build_start), .build_busy(build_busy), .n_entries(n_entries),
		.sr_addr(sr_addr), .sr_data(sr_data),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data)
	);

	logic        spr_busy, spr_ovr;
	logic        spr_req, spr_valid;
	logic [25:0] spr_addr;
	logic [63:0] spr_gdata;
	logic        spr_we;
	logic [8:0]  spr_wx;
	logic [15:0] spr_wd, spr_rd;
	logic        spr_ready, spr_ready_d, spr_ready_rise;

	always_ff @(posedge clk) begin
		spr_ready_d    <= spr_ready;
		spr_ready_rise <= spr_ready && !spr_ready_d;
	end

	assign dbg_spr_ovr = spr_ovr;

	sprite_line_engine u_spr (
		.clk(clk), .reset(core_reset),
		.line_tick(line_start),
		.line_start(spr_ready_rise && !build_busy),
		.render_line(vcnt_next2),
		.busy(spr_busy), .ovr_ev(spr_ovr),
		.board(board), .tilebank(tilebank_render), .gfx_base(26'd0),
		.n_entries(n_entries),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data),
		.gfx_req(spr_req), .gfx_addr(spr_addr),
		.gfx_valid(spr_valid), .gfx_data(spr_gdata),
		.lb_we(spr_we), .lb_x(spr_wx), .lb_data(spr_wd)
	);

	line_buffer #(.WIDTH(16)) u_spr_lb (
		.clk(clk), .reset(core_reset),
		.line_start(line_start), .ready(spr_ready), .render_bank_o(spr_lb_bank),
		.we(spr_we), .wx(spr_wx), .wdata(spr_wd),
		.rx(hcnt), .rdata(spr_rd)
	);

	// =====================================================================
	// LINE-BUFFER CHECK (probe): does display line V show the row rendered
	// FOR line V?
	//
	// Each engine renders vcnt_next2 into the bank that line_start just made
	// the render bank, and that bank is displayed after the NEXT line_start.
	// Simulation agrees the arithmetic lands row V on line V; hardware shows
	// sprites a line below where MAME puts them. This tags each bank with the
	// row its engine set out to render and, on every displayed line, holds
	// (vcnt - tag of the bank being displayed). 0 means the row is on its
	// line; +1 means the picture is one line LOW (row V displayed on V+1).
	// The bad counters saturate at 15 and count lines where the delta was not
	// zero, so a one-off glitch and a systematic offset read differently.
	// =====================================================================
	logic [8:0] tm1_tag [0:1];
	logic [8:0] spr_tag [0:1];
	logic [3:0] tm1_delta = 4'd0, spr_delta = 4'd0, tm1_bad = 4'd0, spr_bad = 4'd0;
	wire  [8:0] tm1_disp_tag = tm1_tag[~tm_bank[1]];
	wire  [8:0] spr_disp_tag = spr_tag[~spr_lb_bank];
	always_ff @(posedge clk) begin
		if (tm_ready_rise[1])               tm1_tag[tm_bank[1]] <= vcnt_next2;
		if (spr_ready_rise && !build_busy)  spr_tag[spr_lb_bank] <= vcnt_next2;
		if (core_reset) begin
			tm1_bad <= 4'd0; spr_bad <= 4'd0;
		end else if (ce_pix && h_active && v_active && hcnt == 9'd100) begin
			tm1_delta <= 4'(vcnt - tm1_disp_tag);
			spr_delta <= 4'(vcnt - spr_disp_tag);
			if (vcnt != tm1_disp_tag && tm1_bad != 4'd15) tm1_bad <= tm1_bad + 4'd1;
			if (vcnt != spr_disp_tag && spr_bad != 4'd15) spr_bad <= spr_bad + 4'd1;
		end
	end
	// The line-buffer check that used to be on the probe is retired: it read
	// delta 0 for hundreds of frames on both engines, and the sprite-offset
	// fault it was built for turned out to be the scaler. The counters stay
	// so the check can be re-exported without rebuilding the logic.
	wire [15:0] lb_check_unused = {spr_delta, tm1_delta, spr_bad, tm1_bad};

	// =====================================================================
	// SAMPLE FETCH WATCH. The sample ROM port serves FG-2's OKI and FG-3's
	// OPL4 wavetable, and BOTH chips assume their fetch completes: jt6295
	// does not wait at all, and the OPL4 issues a one-cycle request and then
	// holds busy_mem until a valid it can only get from us. So a single lost
	// valid is not a glitch, it is a permanent stall -- the PCM engine stops
	// advancing, its accumulator holds its last value, and the mix goes to a
	// constant. That is silence with a non-zero level, which is exactly what
	// a peak-hold reads as "still working".
	//
	// So: is a fetch outstanding right now, how long has the worst one
	// taken, and has any ever exceeded a threshold no healthy fetch should.
	//   [15]     stalled: a fetch has been outstanding > 4096 clk (sticky)
	//   [14]     a fetch is outstanding at this instant
	//   [13:6]   the register selector the Z80 last wrote to an OPL4 address
	//            port -- a sound CPU writing hard with no key-ons is in a
	//            loop, and this names the register it is on
	//   [5:3]    which OPL4 port that write went to
	//   [2:0]    worst fetch latency, in units of 512 clk, saturating
	//
	// The fetch counter and the finer latency field are gone: the count only
	// ever read 255 and the latency field was scaled wrong -- it saturated
	// once a fetch passed 63 CLOCKS, which every healthy SDRAM round trip
	// does, so it read 63 on a working machine and measured nothing.
	// =====================================================================
	logic [7:0]  dbg_opl4_sel;
	logic [2:0]  dbg_opl4_port;
	logic [7:0]  shared_dump;
	logic        smp_out = 1'b0, smp_stall = 1'b0;
	logic [15:0] smp_age = 16'd0;
	logic [2:0]  smp_maxlat = 3'd0;
	always_ff @(posedge clk) begin
		if (core_reset) begin
			smp_out <= 1'b0; smp_stall <= 1'b0; smp_age <= 16'd0;
			smp_maxlat <= 3'd0;
		end else begin
			if (smp_valid) begin
				smp_out <= 1'b0;
				smp_age <= 16'd0;
				if (smp_age[15:12] != 4'd0)               smp_maxlat <= 3'd7;
				else if (smp_age[11:9] > smp_maxlat)      smp_maxlat <= smp_age[11:9];
			end else if (smp_out) begin
				if (smp_age != 16'hFFFF) smp_age <= smp_age + 16'd1;
				if (smp_age > 16'd4096)  smp_stall <= 1'b1;
			end else if (smp_req) begin
				smp_out <= 1'b1;
				smp_age <= 16'd0;
			end
		end
	end
	// smp_age counts in clk; >>6 puts the reported worst latency in units of
	// 64 clk, so 1 unit is about 0.75 us at 85.909 MHz.
	assign dbg_smp = {smp_stall, smp_out, dbg_opl4_sel, dbg_opl4_port, smp_maxlat};

	// =====================================================================
	// The compositor's resolved layer-priority value. Declared HERE, above
	// the record that samples it, not beside the compositor 240 lines below:
	// vlog rejects use-before-declare and Quartus quietly accepts it, which
	// is how a truncated bus once reached hardware (LESSONS_LEARNED).
	logic [2:0] dbg_pri;

	// PER-LINE DISPLAY RECORD (dump region 6). EIGHT words per display line,
	// 240 lines, written as the line is shown:
	//   0..2  layer 0..2 at x = 160: { opaque, 2'b0, palette index }
	//   3     sprite at x = 160:     { opaque, priority[1:0], palette index }
	//   4     { any sprite on the line, 3'b0, layer priority value, first x }
	//   5     layer 2's LATCHED X scroll -- gogomile's cloud chain
	//   6     layer 0's LATCHED Y scroll -- pbancho's per-line effect
	//   7     the raster register in force, reduced ({7'b0, raster_line})
	//
	// Words 5-7 are what make a raster fault answerable. The chain's own
	// arithmetic is known from a MAME capture -- gogomile's clouds are five
	// bands at 2, 1, 1/2, 0, 0 pixels per frame, starting at lines 0, 30, 64,
	// 89 and 119 -- so the question is only ever WHICH DISPLAY LINE GOT WHICH
	// SCROLL, and this answers it directly instead of by inference from the
	// picture. It also measures whether a change (the Raster IRQ lead switch,
	// say) moved those boundaries at all, which by eye is a guess.
	logic [15:0] linecap [0:2047];
	logic [13:0] lc_l0, lc_l1, lc_l2;
	logic [15:0] lc_spr;
	logic [2:0]  lc_pri;
	logic [15:0] lc_sx2, lc_sy0;
	logic [8:0]  lc_spr_x = 9'd0;
	logic        lc_spr_seen = 1'b0, lc_writing = 1'b0;
	logic [2:0]  lc_wcnt = 3'd0;
	logic [7:0]  lc_line = 8'd0;
	logic [15:0] lc_wdata, linecap_rdata;
	always_comb begin
		case (lc_wcnt)
			3'd0:    lc_wdata = {lc_l0[13], 2'b0, lc_l0[12:0]};
			3'd1:    lc_wdata = {lc_l1[13], 2'b0, lc_l1[12:0]};
			3'd2:    lc_wdata = {lc_l2[13], 2'b0, lc_l2[12:0]};
			3'd3:    lc_wdata = {lc_spr[15], lc_spr[14:13], lc_spr[12:0]};
			3'd4:    lc_wdata = {lc_spr_seen, 3'b0, lc_pri, lc_spr_x};
			3'd5:    lc_wdata = lc_sx2;
			3'd6:    lc_wdata = lc_sy0;
			default: lc_wdata = {7'b0, raster_line};
		endcase
	end
	always_ff @(posedge clk) begin
		if (ce_pix && h_active && v_active) begin
			if (hcnt == 9'd160) begin
				lc_l0 <= tm_rd[0]; lc_l1 <= tm_rd[1]; lc_l2 <= tm_rd[2];
				lc_spr <= spr_rd;  lc_pri <= dbg_pri;
			end
			if (spr_rd[15] && !lc_spr_seen) begin
				lc_spr_seen <= 1'b1;
				lc_spr_x    <= hcnt;
			end
		end
		if (line_start && v_active) begin
			lc_writing <= 1'b1;
			lc_wcnt    <= 3'd0;
			lc_line    <= vcnt[7:0];
			// The scrolls as the line just DISPLAYED was rendered with. They
			// are captured here, at the same edge the next line's latch
			// happens, so the value recorded against line V is the one the
			// engines used for it.
			lc_sx2     <= r_scrollx[2];
			lc_sy0     <= r_scrolly[0];
		end else if (lc_writing) begin
			linecap[{lc_line, lc_wcnt}] <= lc_wdata;
			lc_wcnt <= lc_wcnt + 3'd1;
			if (lc_wcnt == 3'd7) begin
				lc_writing  <= 1'b0;
				lc_spr_seen <= 1'b0;
			end
		end
		linecap_rdata <= linecap[{dump_page[2:0], walk_idx}];
	end

	// =====================================================================
	// Compositor and palette lookup
	// =====================================================================
	// =====================================================================
	// Trace to screen.
	//
	// 128 bits of JTAG probe answers "how much" and "where is it now". It
	// cannot answer "what happened in the run-up", which is the question that
	// identifies a cause. This buffers 256 events and reads them out one per
	// scanline, so a single screenshot carries 256 consecutive samples -- the
	// technique the sibling Psikyo core used for its bring-up, module
	// vendored from it unchanged.
	//
	// RING MODE first: it holds the LATEST 256 events and freezes when the
	// stream goes quiet, so a stopped download freezes the buffer on the last
	// writes before it stopped.
	//
	// The module has NO RESET PORT, deliberately -- its header explains why,
	// and this core was already bitten by exactly that: counters cleared by
	// the very reset under investigation.
	// =====================================================================
	logic [23:0] trace_data;
	logic        trace_stb;

	// CPU accesses are captured on the VALID that completes them, paired with
	// the address that was requested, and tagged with the kernel's function
	// code. Capturing on rom_req alone gave a scrambled order on hardware
	// (0, 3, 1, ...) that no 68000 sequence produces; the completed access
	// is the one the CPU actually consumed. FC separates a vector/data read
	// (5) from a program fetch (6) from an interrupt acknowledge (7), which is
	// the difference between "the core is being reset" and "the CPU is taking
	// exceptions".
	//
	// GATED ON THE DOWNLOAD HAVING FINISHED. The CPU runs for ~3,000 fetches
	// on empty SDRAM before MiSTer asserts RESET for the transfer; ungated,
	// those fill a first-N capture and window 0 never shows the real boot.
	// dl_done has no reset, on purpose (see debug_tracer.sv's header).
	logic        dl_seen0 = 1'b0, dl_done = 1'b0;
	logic [20:0] pend_addr;
	//
	// ldr_active counts as "the ROM arrived" too: on the fast DDR path the HPS
	// DMAs the image straight into DDR3 and NO ioctl_wr ever reaches the core,
	// so gating on writes alone left dl_done clear forever -- which silently
	// disabled trace sources 1 and 2 and the SDRAM/memory walker, whose dumps
	// then came back as 256 zeros.
	always_ff @(posedge clk) begin
		if (ioctl_wr && ioctl_index == 16'd0) dl_seen0 <= 1'b1;
		if (ldr_active)                       dl_seen0 <= 1'b1;
		if (dl_seen0 && !ioctl_download && !ldr_active) dl_done <= 1'b1;
		if (rom_req)                          pend_addr <= rom_addr;
	end

	// =====================================================================
	// SDRAM read-back walker -- trace source 3.
	//
	// Reads 256 consecutive words through the CPU's OWN path (bridge, cache,
	// arbiter, controller) with the CPU paused, and hands each one to the
	// tracer as {word index, data}: one page of what the CPU would see, per
	// screenshot, to diff against the ROM image. dbg_window picks the page,
	// so pages 0-15 cover the first 8 KB -- vector table and boot code.
	//
	// Runs one pass when it becomes active or dbg_rearm toggles, and only
	// once the download has finished, for the same reason the fetch sources
	// are gated. A short settle after the kick lets any in-flight CPU access
	// drain, so its valid is not mistaken for the walker's first.
	// =====================================================================
	// walk_active is declared with the other core-level signals near the top.
	//
	// MEMORY DUMP. dbg_dump = {region, page} from the JTAG source [31:8]:
	//   region 0  SDRAM, page = 512-byte page of the 64 MB (page 0 falls back
	//             to dbg_window, which is how the pattern test addresses it)
	//   region 1  tilemap VRAM      (64 pages)     region 4  video registers
	//   region 2  palette           (32 pages)               (0-15 regs, 16-17 unknown,
	//   region 3  sprite RAM (live) (16 pages)               18 priority, 19-20 tile bank)
	//   region 5  work RAM          (256 pages)
	//   region 6  per-line display record (8 pages) -- see PER-LINE DISPLAY RECORD
	//   region 7  FG-3's 16 shared bytes with the Z80 (1 page, words 0-15)
	// Non-SDRAM regions read the CPU-side port of each memory, which is why
	// the CPU is paused while the walker runs. Each entry is {index, word}.
	logic        walk_active_d = 1'b0, walk_rearm_d = 1'b0, dl_done_d = 1'b0;
	logic        walking = 1'b0, walk_wait = 1'b0, walk_req = 1'b0, walk_stb = 1'b0;
	logic [7:0]  walk_settle = 8'd0;
	logic [23:0] walk_data = 24'd0;
	logic        mem_v1 = 1'b0, mem_v2 = 1'b0;      // registered-RAM read latency
	always_ff @(posedge clk) begin
		mem_v1 <= walk_req && !walk_sdram;
		mem_v2 <= mem_v1;
	end
	logic [15:0] mem_word;
	always_comb begin
		case (dump_region)
			4'd1:    mem_word = vram_rdata;
			4'd2:    mem_word = palette_rdata;
			4'd3:    mem_word = spriteram_rdata;
			// region 4: words 0-18 through the vregs port (regs, unknown,
			// priority); 19-20 the sprite tile bank as the renderer sees it.
			4'd4:    mem_word = (walk_idx == 8'd19) ? tilebank_render[31:16] :
			                    (walk_idx == 8'd20) ? tilebank_render[15:0]  : vregs_rdata;
			4'd5:    mem_word = workram_rdata;
			4'd6:    mem_word = linecap_rdata;
			4'd7:    mem_word = {8'd0, shared_dump};
			default: mem_word = 16'hDEAD;
		endcase
	end
	wire        walk_valid = walk_sdram ? rom_valid : mem_v2;
	wire [15:0] walk_word  = walk_sdram ? rom_data  : mem_word;

	// Kick on ANY of: the download finishing while the source is already
	// selected, the source being selected after the download, or a re-arm.
	// The first version kicked only on the source's rising edge AND
	// dl_done, but the OSD bits arrive from the HPS before the download ends,
	// so that edge always passed with dl_done low and the walker never ran --
	// the dump decoded as 256 zeros.
	wire walk_kick = walk_active && dl_done &&
	                 ((dl_done && !dl_done_d) || !walk_active_d ||
	                  (dbg_rearm ^ walk_rearm_d));

	always_ff @(posedge clk) begin
		walk_active_d <= walk_active;
		walk_rearm_d  <= dbg_rearm;
		dl_done_d     <= dl_done;
		walk_req      <= 1'b0;
		walk_stb      <= 1'b0;
		if (!walking) begin
			if (walk_kick) begin
				walking     <= 1'b1;
				walk_idx    <= 8'd0;
				walk_wait   <= 1'b0;
				walk_settle <= 8'd255;
			end
		end else if (walk_settle != 8'd0) begin
			walk_settle <= walk_settle - 8'd1;
		end else if (!walk_wait) begin
			walk_req  <= 1'b1;
			walk_wait <= 1'b1;
		end else if (walk_valid) begin
			walk_stb  <= 1'b1;
			walk_data <= {walk_idx, walk_word};
			walk_wait <= 1'b0;
			if (walk_idx == 8'd255) walking <= 1'b0;
			else                    walk_idx <= walk_idx + 8'd1;
		end
	end

	// SDRAM byte address of the word being walked: 512-byte page x index.
	wire [25:0] walk_addr = (dump_page == 20'd0) ? {13'd0, dbg_window, walk_idx, 1'b0}
	                                             : {dump_page[16:0], walk_idx, 1'b0};

	always_comb begin
		case (dbg_src)
			// The download stream: word address of each accepted write.
			2'd0: begin trace_stb = dbg_dl_wr; trace_data = dl_addr_dbg[24:1]; end
			// Completed CPU accesses: {FC, word address}.
			2'd1: begin trace_stb = rom_valid && dl_done;
			            trace_data = {cpu_fc, pend_addr}; end
			// Completed CPU accesses: {returned word, low 8 bits of address}.
			2'd2: begin trace_stb = rom_valid && dl_done;
			            trace_data = {rom_data, pend_addr[7:0]}; end
			// SDRAM read-back: {word index within the page, data}.
			default: begin trace_stb = walk_stb; trace_data = walk_data; end
		endcase
	end

	// TRIGGER: the first supervisor-data read inside vectors 2..4 (bus error,
	// address error, illegal instruction; byte 0x08..0x13, word 4..9). The
	// boot never reads those legitimately, so in ring mode the buffer freezes
	// holding the 255 ROM reads that led to the exception plus the vector
	// read itself as the newest entry. The readout rotates on that entry.
	wire vec_trig = rom_valid && dl_done && (cpu_fc == 3'd5) &&
	                (pend_addr >= 21'd4) && (pend_addr <= 21'd9);

	// Band and row-in-band are counted, not divided: `vcnt / 6` synthesised
	// to an lpm_divide on the tracer's BRAM address and missed clk_sys by
	// 2.671 ns. The counters lag vcnt by one clock, which lands in hblank.
	logic [23:0] trace_rd;
	logic [5:0]  trace_band     = '0;   // 0..39 on the visible lines
	logic [2:0]  trace_row      = '0;   // 0..5 within the band
	logic        trace_inv      = '0;   // rows 3..5 of each band show ~value
	logic [8:0]  trace_rd_index = '0;
	logic [8:0]  trace_vcnt_q   = '0;
	always_ff @(posedge clk) begin
		trace_vcnt_q <= vcnt;
		if (vcnt != trace_vcnt_q) begin
			if (vcnt == 9'd0) begin
				trace_band <= '0; trace_row <= '0;
			end else if (trace_row == 3'd5) begin
				trace_band <= trace_band + 6'd1; trace_row <= '0;
			end else begin
				trace_row  <= trace_row + 3'd1;
			end
		end
		trace_inv      <= trace_row >= 3'd3;
		trace_rd_index <= 9'(dbg_page * 9'd40) + 9'(trace_band);
	end

	// IDLE_BITS 28 = 2**28 clk = 3.1 s of quiet before the ring freezes. The
	// default 22 is 49 ms, which the pause between .mra parts trips -- the
	// buffer then froze mid-transfer and looked exactly like the end of it.
	debug_tracer #(.DEPTH(256), .WIDTH(24), .IDLE_BITS(28)) u_trace (
		.clk(clk),
		.cap_stb(trace_stb), .cap_data(trace_data),
		// The walker reuses dbg_window as its PAGE selector, so the tracer
		// must not also treat it as an event-skip: with window=2 it skipped
		// 16,382 events and the 256-word dump recorded nothing.
		.ctl_rearm(dbg_rearm), .ctl_window(walk_active ? 4'd0 : dbg_window),
		.ctl_ring(dbg_ring), .ctl_trig_en(dbg_trig), .cap_trig(vec_trig),
		// BANDED, SELF-CHECKING READOUT. Each entry occupies SIX scanlines:
		// three showing the value, three its bitwise INVERSE. The decoder pairs
		// (v, ~v) runs by content and requires v ^ ~v == all ones, so any
		// transform between this pixel and the PNG is detected instead of being
		// read as data. That check is what exposed the framework's gamma LUT
		// (now forced off under the overlay in Fuuki.sv), which the one-row
		// readout had reported as SDRAM corruption. 40 entries per screen,
		// page-selected over JTAG; 7 pages cover the 256-entry buffer.
		.rd_index(trace_rd_index), .rd_data(trace_rd),
		.frozen(dbg_frozen)
	);


	compositor u_comp (
		.l0(tm_rd[0]), .l1(tm_rd[1]), .l2(tm_rd[2]),
		.spr(spr_rd),
		.tmap_front(r_front), .tmap_middle(r_middle), .tmap_back(r_back),
		.en_l0(en_l0), .en_l1(en_l1), .en_l2(en_l2), .en_spr(en_spr),
		.pal_addr(pal_rd_addr), .dbg_pri(dbg_pri)
	);

	// =====================================================================
	// Output stage.
	//
	// The pixel path is TWO registered reads deep -- the line buffers, then
	// the palette -- so the colour for hcnt appears two clocks later. The
	// blanking, sync and pixel enable are delayed by the same two clocks so
	// the scaler sees them paired. Getting this wrong shifts the picture by
	// two clk_sys (a sixth of a pixel) and, worse, samples the wrong side of
	// a blanking edge.
	//
	// xRGB-555 as MAME decodes it: palette_device::xRGB_555 is
	// standard_rgb_decoder<5,5,5, 10,5,0>, so bits 14:10 are RED, 9:5 green,
	// 4:0 blue. pal5bit() replicates the top 3 bits into the low byte, which
	// is what makes white actually reach 0xFF.
	// =====================================================================
	function automatic [7:0] pal5bit(input [4:0] v);
		pal5bit = {v, v[4:2]};
	endfunction

	// Line markers: the first and last active lines, at the left edge, so a
	// screen or a screenshot shows whether the framing keeps both. Delayed
	// with the blanking so they sit on the pixels they name.
	wire marker_px = dbg_marker && (hcnt < 9'd8) && (vcnt == 9'd0 || vcnt == 9'd239);
	logic [1:0] q_mk;
	logic [1:0] q_hs, q_vs, q_hb, q_vb, q_ce;
	always_ff @(posedge clk) begin
		q_mk <= {q_mk[0], marker_px};
		q_hs <= {q_hs[0], hsync};
		q_vs <= {q_vs[0], vsync};
		q_hb <= {q_hb[0], hblank};
		q_vb <= {q_vb[0], vblank};
		q_ce <= {q_ce[0], ce_pix};
	end

	// The overlay REPLACES the picture rather than blending: the decoder reads
	// exact 24-bit values back out of the PNG, so blending would corrupt them.
	wire [23:0] trace_px = trace_inv ? ~trace_rd : trace_rd;
	assign video_r  = q_mk[1] ? 8'hFF : dbg_overlay ? trace_px[23:16] : pal5bit(pal_rd_data[14:10]);
	assign video_g  = q_mk[1] ? 8'hFF : dbg_overlay ? trace_px[15:8]  : pal5bit(pal_rd_data[9:5]);
	assign video_b  = q_mk[1] ? 8'hFF : dbg_overlay ? trace_px[7:0]   : pal5bit(pal_rd_data[4:0]);
	assign video_hs = q_hs[1];
	assign video_vs = q_vs[1];
	assign video_hb = q_hb[1];
	assign video_vb = q_vb[1];
	assign video_ce = q_ce[1];

	// =====================================================================
	// SDRAM backend
	//
	// `reset` here is the DOWNLOAD-MASKED reset, not `core_reset` and not the
	// framework's RESET -- see this file's header and the port comment in
	// fuuki_sdram_top.sv.
	// =====================================================================
	// The sound boards' two memory clients, declared before the backend that
	// serves them. One pair of ports, whichever board is running.
	logic        z80_rom_req, z80_rom_valid, smp_req, smp_valid;
	logic [18:0] z80_rom_addr;
	logic [21:0] smp_addr;
	logic [7:0]  z80_rom_data, smp_data;

	fuuki_sdram_top u_sdram (
		.board(board),
		.clk(clk), .reset(reset), .init(init),
		.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
		.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.tm0_req(tm_req[0]), .tm0_addr(tm_addr[0]),
		.tm0_valid(tm_valid[0]), .tm0_data(tm_data[0]),
		.tm1_req(tm_req[1]), .tm1_addr(tm_addr[1]),
		.tm1_valid(tm_valid[1]), .tm1_data(tm_data[1]),
		.tm2_req(tm_req[2]), .tm2_addr(tm_addr[2]),
		.tm2_valid(tm_valid[2]), .tm2_data(tm_data[2]),
		.spr_req(spr_req), .spr_addr(spr_addr),
		.spr_valid(spr_valid), .spr_data(spr_gdata),
		// rom_addr is a WORD address; the backend takes an even BYTE address
		// and adds BASE_MAINCPU itself.
		.cpu_req (walk_active ? (walk_req && walk_sdram) : rom_req),
		.cpu_addr(walk_active ? walk_addr : 26'({rom_addr, 1'b0})),
		.cpu_valid(rom_valid), .cpu_data(rom_data),
		.z80_req(z80_rom_req), .z80_addr(z80_rom_addr),
		.z80_valid(z80_rom_valid), .z80_data(z80_rom_data),
		.smp_req(smp_req), .smp_addr(smp_addr),
		.smp_valid(smp_valid), .smp_data(smp_data),
		.dbg_dl_wr(dbg_dl_wr), .dbg_dl_addr(dl_addr_dbg)
	);

	// =====================================================================
	// SOUND. One board runs, the other is held in reset: FG-2's Z80 with the
	// YM2203 / YM3812 / OKI set (rtl/sound/fg2_sound.sv), FG-3's Z80 with the
	// OPL4 (rtl/sound/fg3_sound.sv). Both are synthesized, because one .rbf
	// serves both boards.
	//
	// Clock enables, all exact on the 85.909 MHz grid (14.318181 x 6):
	//   Z80    6 MHz      66/945   (both boards: 12 MHz / 2)
	//   YM     3.58 MHz   1/24     (28.640 / 8 = 85.909 / 24)
	//   OKI    1 MHz      11/945
	// The fractional ones are Bresenham accumulators, as the main CPU's. The
	// OPL4 derives its own 33.8688 MHz enable internally.
	// =====================================================================
	logic [9:0] cen_z80_acc = 10'd0, cen_oki_acc = 10'd0;
	logic [4:0] cen_ym_cnt  = 5'd0;
	logic       cen_z80, cen_ym, cen_oki;
	always_ff @(posedge clk) begin
		cen_z80_acc <= (cen_z80_acc >= 10'd945 - 10'd66) ? cen_z80_acc + 10'd66 - 10'd945 : cen_z80_acc + 10'd66;
		cen_oki_acc <= (cen_oki_acc >= 10'd945 - 10'd11) ? cen_oki_acc + 10'd11 - 10'd945 : cen_oki_acc + 10'd11;
		cen_ym_cnt  <= (cen_ym_cnt == 5'd23) ? 5'd0 : cen_ym_cnt + 5'd1;
	end
	assign cen_z80 = (cen_z80_acc >= 10'd945 - 10'd66);
	assign cen_oki = (cen_oki_acc >= 10'd945 - 10'd11);
	assign cen_ym  = (cen_ym_cnt == 5'd0);

	wire snd_fg3 = (board == BOARD_FG3);

	logic        fg2_rom_req, fg2_smp_req;
	logic [16:0] fg2_rom_addr;
	logic [19:0] fg2_smp_addr;
	logic signed [15:0] fg2_audio;
	logic        fg2_m1, fg2_ym_wr;

	fg2_sound u_snd2 (
		.clk(clk), .reset(core_reset || snd_fg3),
		.cen_z80(cen_z80), .cen_ym(cen_ym), .cen_oki(cen_oki),
		.latch_data(latch_data), .latch_write(latch_write),
		.en_fm(en_fm), .en_pcm(en_pcm),
		.rom_req(fg2_rom_req), .rom_addr(fg2_rom_addr),
		.rom_valid(z80_rom_valid && !snd_fg3), .rom_data(z80_rom_data),
		.oki_req(fg2_smp_req), .oki_addr(fg2_smp_addr),
		.oki_valid(smp_valid && !snd_fg3), .oki_data(smp_data),
		.audio(fg2_audio),
		.dbg_m1(fg2_m1), .dbg_ym_wr(fg2_ym_wr)
	);

	logic        fg3_rom_req, fg3_smp_req;
	logic [18:0] fg3_rom_addr;
	logic [21:0] fg3_smp_addr;
	logic signed [15:0] fg3_audio_l, fg3_audio_r;
	logic        fg3_m1, fg3_opl4_wr;

	fg3_sound u_snd3 (
		.clk(clk), .reset(core_reset || !snd_fg3),
		.cen_z80(cen_z80),
		.host_addr(sharedram_addr), .host_we(sharedram_we),
		.host_wdata(sharedram_wdata), .host_rdata(sharedram_rdata),
		.en_fm(en_fm), .en_pcm(en_pcm),
		.rom_req(fg3_rom_req), .rom_addr(fg3_rom_addr),
		.rom_valid(z80_rom_valid && snd_fg3), .rom_data(z80_rom_data),
		.wave_req(fg3_smp_req), .wave_addr(fg3_smp_addr),
		.wave_valid(smp_valid && snd_fg3), .wave_data(smp_data),
		.audio_l(fg3_audio_l), .audio_r(fg3_audio_r),
		.dbg_m1(fg3_m1), .dbg_opl4_wr(fg3_opl4_wr),
		.dbg_fm_keyon(dbg_fm_keyon), .dbg_pcm_keyon(dbg_pcm_keyon),
		.dbg_opl4_sel(dbg_opl4_sel), .dbg_opl4_port(dbg_opl4_port),
		.dbg_shared_addr(walk_idx[3:0]), .dbg_shared_data(shared_dump)
	);

	assign z80_rom_req  = snd_fg3 ? fg3_rom_req : fg2_rom_req;
	assign z80_rom_addr = snd_fg3 ? fg3_rom_addr : 19'(fg2_rom_addr);
	assign smp_req      = snd_fg3 ? fg3_smp_req : fg2_smp_req;
	assign smp_addr     = snd_fg3 ? fg3_smp_addr : 22'(fg2_smp_addr);

	assign audio_l = snd_fg3 ? fg3_audio_l : fg2_audio;
	assign audio_r = snd_fg3 ? fg3_audio_r : fg2_audio;
	assign dbg_z80_m1 = snd_fg3 ? fg3_m1     : fg2_m1;
	assign dbg_ym_wr  = snd_fg3 ? fg3_opl4_wr : fg2_ym_wr;

endmodule
