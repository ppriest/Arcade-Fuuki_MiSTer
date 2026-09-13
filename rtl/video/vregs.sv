// Fuuki video registers (FI-003K), from fuukitmap.cpp.
//
// Three address blocks, selected by addr[17:16] in the CPU's 0x8C0000-0x8EFFFF
// window (maincpu.sv does that split and passes it here as `sel`):
//
//   sel 0   0x8C0000   16 words of scroll / offset / raster / flip
//   sel 1   0x8D0000   "unknown, flipscreen related" (MAME's words)
//   sel 2   0x8E0000   priority: the layer order
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
// The scroll outputs are combinational from the register file, so a mid-frame
// CPU write takes effect on the next scanline. The level-5 raster interrupt
// depends on that; do not latch them per frame.

module vregs (
	input  logic clk,
	input  logic reset,

	input  logic board,   // BOARD_FG2 / BOARD_FG3

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


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
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

	// ---- raster line: the low 8 bits of regs[0x1c], as MAME ----
	// fuukitmap.cpp hands the value to screen::time_until_pos(), which reduces
	// it modulo the screen height, 256 on both boards (fuukifg2.cpp
	// set_size(320, 256); fuukifg3.cpp set_size(512, 256)). So gogomile's
	// parked 0xFFFE fires on line 254, in vblank, every frame, and the game
	// needs that: its main loop spins on `btst #1,$403446 / beq` and only the
	// level-5 handler sets the bit. Do not reduce modulo this core's 262-line
	// frame; that puts 0xFFFE on line 34, mid-picture.
	//
	// Zero-extended to 9 bits so video_timing.sv's comparator cannot alias
	// lines 256-261 onto 0-5.
	always_ff @(posedge clk or posedge reset) begin
		if (reset) raster_line <= 9'd0;
		else       raster_line <= {1'b0, regs[4'hE][7:0]};
	end

	// ---- scroll offsets ----
	// From fuukitmap.cpp::prepare(), operators included:
	//
	//     scrolly_offs = m_vregs[0xc/2] - (m_flip ? m_xoffs_flip : m_xoffs);
	//     scrollx_offs = m_vregs[0xe/2] - (m_flip ? m_yoffs_flip : m_yoffs);
	//
	// The Y register pairs with the X constant and vice versa. That is what the
	// driver does and the set_xoffs()/set_yoffs() values assume it. Do not
	// "fix" the swap: it moves every layer by hundreds of pixels.
	//
	// Per-board constants, from each machine config:
	//                     FG-2                        FG-3
	//   set_xoffs         0x1f3, flip 0x103           0x1f3, flip 0x103
	//   set_yoffs         0x3f6, flip 0x2a7           0x3f6, flip 0x2c7
	//   set_layer2_xoffs  0x10                        (not set -> 0)
	//   set_layer2_yoffs  (commented out -> 0)        (not set -> 0)
	//
	// Both drivers say the scroll values are wrong with flip on, so the flip
	// constants are unverified.
	localparam logic [15:0] XOFFS       = 16'h01F3;
	localparam logic [15:0] XOFFS_FLIP  = 16'h0103;
	localparam logic [15:0] YOFFS       = 16'h03F6;
	localparam logic [15:0] YOFFS_FLIP_FG2 = 16'h02A7;
	localparam logic [15:0] YOFFS_FLIP_FG3 = 16'h02C7;

	wire [15:0] yoffs_flip = (board == BOARD_FG3) ? YOFFS_FLIP_FG3 : YOFFS_FLIP_FG2;
	wire [15:0] layer2_xoffs = (board == BOARD_FG3) ? 16'h0000 : 16'h0010;

	// Paired as the driver pairs them (above).
	wire [15:0] scrolly_offs = regs[4'h6] - (flip ? XOFFS_FLIP : XOFFS);
	wire [15:0] scrollx_offs = regs[4'h7] - (flip ? yoffs_flip : YOFFS);

	// 16-bit wrapping arithmetic, as MAME's u16. The tilemap wraps on its own
	// 64x32 geometry downstream.
	assign layer0_scrolly = regs[4'h0] + scrolly_offs;
	assign layer0_scrollx = regs[4'h1] + scrollx_offs;
	assign layer1_scrolly = regs[4'h2] + scrolly_offs;
	assign layer1_scrollx = regs[4'h3] + scrollx_offs;

	// Layer 2 does not get the global offsets, only its own constants.
	assign layer2_scrolly = regs[4'h4];
	assign layer2_scrollx = regs[4'h5] + layer2_xoffs;

	// ---- layer order ----
	// The low 4 bits of the priority register index a table of orderings
	// (fuukitmap.cpp: "not independent bits causing layers to switch"). MAME
	// indexes a six-entry table with `& 0x0f`, so 6-15 read out of bounds
	// there; here they fall through to entry 0 (docs/ROADMAP.md open item 5).
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
