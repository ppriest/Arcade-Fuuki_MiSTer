// Fuuki video registers (FI-003K), from fuukitmap.cpp.
//
// Three address blocks, selected by addr[17:16] in the CPU's 0x8C0000-0x8EFFFF
// window (maincpu.sv does that split and passes it here as `sel`):
//
//   sel 0   0x8C0000   16 words of scroll / offset / raster / flip
//   sel 1   0x8D0000   "unknown, flipscreen related" (MAME's words)
//   sel 2   0x8E0000   priority -- the layer ORDER
//
// Register map (fuukitmap.cpp's own comment block):
//
//   00.w  Layer 0 Scroll Y      0c.w  Layers Y Offset
//   02.w  Layer 0 Scroll X      0e.w  Layers X Offset
//   04.w  Layer 1 Scroll Y      1c.w  Trigger a level 5 irq on this raster line
//   06.w  Layer 1 Scroll X      1e.w  bit 0  Flip screen
//   08.w  Layer 2 Scroll Y            bit 6  Layer 2 VRAM buffer select
//   0a.w  Layer 2 Scroll X
//
// EVERYTHING HERE IS LIVE. The scroll outputs are combinational from the
// register file so that a mid-frame CPU write takes effect on the very next
// scanline -- that is the entire point of the level-5 raster interrupt, and
// latching these once per frame would silently discard the effects MAME's own
// to-do list says it renders imperfectly (docs/ROADMAP.md, "Raster effects are
// a first-class requirement").

module vregs (
	input  logic clk,
	input  logic reset,

	input  logic board_fg3,

	// CPU port, from maincpu.sv
	input  logic [4:0]  cpu_addr,     // word index within the selected block
	input  logic [1:0]  cpu_sel,      // 0 = regs, 1 = unknown, 2 = priority
	input  logic        cpu_wel,
	input  logic        cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// Decoded, live
	output logic [15:0] layer0_scrollx, layer0_scrolly,
	output logic [15:0] layer1_scrollx, layer1_scrolly,
	output logic [15:0] layer2_scrollx, layer2_scrolly,

	output logic        flip,
	output logic        layer2_buffer,   // which VRAM bank layer 2 displays
	output logic [8:0]  raster_line,     // level-5 interrupt scanline

	// Layer order: which layer is drawn front / middle / back
	output logic [1:0]  tmap_front,
	output logic [1:0]  tmap_middle,
	output logic [1:0]  tmap_back
);

	logic [15:0] regs [0:15];
	logic [15:0] unk  [0:1];
	logic [15:0] priority_reg;

	// ---- CPU writes ----
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			for (int i = 0; i < 16; i++) regs[i] <= 16'h0000;
			unk[0]       <= 16'h0000;
			unk[1]       <= 16'h0000;
			priority_reg <= 16'h0000;
		end else begin
			case (cpu_sel)
				2'd0: begin
					if (cpu_wel) regs[cpu_addr[3:0]][7:0]  <= cpu_wdata[7:0];
					if (cpu_weh) regs[cpu_addr[3:0]][15:8] <= cpu_wdata[15:8];
				end
				2'd1: begin
					if (cpu_wel) unk[cpu_addr[0]][7:0]  <= cpu_wdata[7:0];
					if (cpu_weh) unk[cpu_addr[0]][15:8] <= cpu_wdata[15:8];
				end
				default: begin
					if (cpu_wel) priority_reg[7:0]  <= cpu_wdata[7:0];
					if (cpu_weh) priority_reg[15:8] <= cpu_wdata[15:8];
				end
			endcase
		end
	end

	always_comb begin
		case (cpu_sel)
			2'd0:    cpu_rdata = regs[cpu_addr[3:0]];
			2'd1:    cpu_rdata = unk[cpu_addr[0]];
			default: cpu_rdata = priority_reg;
		endcase
	end

	// ---- flip / layer-2 buffer ----
	assign flip          = regs[4'hF][0];    // 0x1e.w bit 0
	assign layer2_buffer = regs[4'hF][6];    // 0x1e.w bit 6

	// ---- raster line: regs[0x1c] MODULO 262, as MAME ----
	// The first version took the low 9 bits, on the reading that gogomile
	// parks the register at 0xFFFE (line 510, unreachable) to mean "no raster
	// interrupt". On hardware gogomile then hung within seconds of its
	// attract: its main loop spins on `btst #1,$403446 / beq`, and bit 1 is
	// set only by the level-5 handler -- the game needs one IRQ5 per frame
	// even with the chain parked. MAME provides it because vregs_w hands the
	// value to screen::time_until_pos(), which does `vpos %= height`: 0xFFFE
	// fires at line 34 there, every frame, and the game is known to work.
	// Values below 262 are unchanged, so docs/ROADMAP.md item 5 (9-bit
	// comparator, from captured traces) still holds; this only defines the
	// out-of-range values. Computed by repeated subtraction after each write
	// -- at most 250 clocks, under a twentieth of a scanline -- while the
	// previous line stays in force.
	localparam int V_TOTAL = 262;
	logic [15:0] raster_raw_q;
	logic [15:0] raster_work;
	logic        raster_busy;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			raster_line  <= 9'd0;
			raster_raw_q <= 16'h0000;
			raster_work  <= 16'h0000;
			raster_busy  <= 1'b0;
		end else begin
			raster_raw_q <= regs[4'hE];
			if (regs[4'hE] != raster_raw_q) begin
				raster_work <= regs[4'hE];
				raster_busy <= 1'b1;
			end else if (raster_busy) begin
				if (raster_work >= 16'(V_TOTAL)) begin
					raster_work <= raster_work - 16'(V_TOTAL);
				end else begin
					raster_line <= raster_work[8:0];
					raster_busy <= 1'b0;
				end
			end
		end
	end

	// =====================================================================
	// Scroll offsets
	//
	// COPIED FROM fuukitmap.cpp::prepare() INCLUDING ITS OPERATORS, and that
	// matters more than usual here because the expression looks wrong:
	//
	//     scrolly_offs = m_vregs[0xc/2] - (m_flip ? m_xoffs_flip : m_xoffs);
	//     scrollx_offs = m_vregs[0xe/2] - (m_flip ? m_yoffs_flip : m_yoffs);
	//
	// The Y offset register is combined with the X constant and vice versa.
	// That is not a transcription slip on this side: it is what the driver
	// does, and the set_xoffs()/set_yoffs() values are what make the picture
	// land correctly given that pairing. "Fixing" the apparent swap would
	// move every layer by hundreds of pixels.
	//
	// LESSONS_LEARNED, "Copy a driver's register expression including its
	// operators": a polarity or pairing error passes review because the names
	// look right. Carry it across and comment it.
	//
	// Per-board constants, from each machine config:
	//                     FG-2                        FG-3
	//   set_xoffs         0x1f3, flip 0x103           0x1f3, flip 0x103
	//   set_yoffs         0x3f6, flip 0x2a7           0x3f6, flip 0x2c7
	//   set_layer2_xoffs  0x10                        (not set -> 0)
	//   set_layer2_yoffs  (commented out -> 0)        (not set -> 0)
	//
	// Only the FLIPPED y offset and layer 2's x offset differ between boards.
	// Note both drivers say the scroll values are wrong when flip is on, so
	// the flip constants are inherited uncertainty, not verified behaviour.
	// =====================================================================
	localparam logic [15:0] XOFFS       = 16'h01F3;
	localparam logic [15:0] XOFFS_FLIP  = 16'h0103;
	localparam logic [15:0] YOFFS       = 16'h03F6;
	localparam logic [15:0] YOFFS_FLIP_FG2 = 16'h02A7;
	localparam logic [15:0] YOFFS_FLIP_FG3 = 16'h02C7;

	wire [15:0] yoffs_flip = board_fg3 ? YOFFS_FLIP_FG3 : YOFFS_FLIP_FG2;
	wire [15:0] layer2_xoffs = board_fg3 ? 16'h0000 : 16'h0010;

	// Deliberately paired the way the driver pairs them (see above).
	wire [15:0] scrolly_offs = regs[4'h6] - (flip ? XOFFS_FLIP : XOFFS);
	wire [15:0] scrollx_offs = regs[4'h7] - (flip ? yoffs_flip : YOFFS);

	// All of this is 16-bit wrapping arithmetic in MAME (u16), so it must wrap
	// here too -- the tilemap wraps on its own 64x32 geometry downstream.
	assign layer0_scrolly = regs[4'h0] + scrolly_offs;
	assign layer0_scrollx = regs[4'h1] + scrollx_offs;
	assign layer1_scrolly = regs[4'h2] + scrolly_offs;
	assign layer1_scrollx = regs[4'h3] + scrollx_offs;

	// Layer 2 does NOT get the global offsets -- only its own constants.
	assign layer2_scrolly = regs[4'h4];
	assign layer2_scrollx = regs[4'h5] + layer2_xoffs;

	// =====================================================================
	// Layer order
	//
	// "It's not independent bits causing layers to switch, that wouldn't make
	// sense with 3 bits" -- fuukitmap.cpp. The low 4 bits of the priority
	// register index a table of orderings.
	//
	// MAME indexes a SIX-entry table with `m_priority & 0x0f`, so values 6-15
	// read out of bounds -- undefined in C++ and unknown on the real ASIC.
	// This picks a defined behaviour rather than inheriting whatever MAME's
	// stack happens to contain: values 6-15 fall through to entry 0. Flagged
	// in docs/ROADMAP.md open item 5; if a game is ever seen writing one of
	// those values, this is the line to revisit.
	// =====================================================================
	always_comb begin
		case (priority_reg[3:0])
			4'd0:    {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd1, 2'd2};
			4'd1:    {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd2, 2'd1};
			4'd2:    {tmap_front, tmap_middle, tmap_back} = {2'd1, 2'd0, 2'd2};
			4'd3:    {tmap_front, tmap_middle, tmap_back} = {2'd1, 2'd2, 2'd0};
			4'd4:    {tmap_front, tmap_middle, tmap_back} = {2'd2, 2'd0, 2'd1};
			4'd5:    {tmap_front, tmap_middle, tmap_back} = {2'd2, 2'd1, 2'd0};
			default: {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd1, 2'd2};
		endcase
	end

endmodule
