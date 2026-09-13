// Per-scanline tilemap renderer for one Fuuki layer.
//
// One instance per layer; they differ only in configuration inputs (tile
// size, colour depth, palette mapping).
//
// Per-scanline because the games rewrite scroll registers mid-frame from the
// level-5 raster interrupt (gogomile on every scanline). All configuration
// inputs are sampled at line_start and held for the line, so a mid-line CPU
// write lands on the next line.
//
// The map is always 64 x 32 tiles: 1024 x 512 pixels at 16x16, 512 x 256 at
// 8x8. Scrolling wraps on those sizes.
//
// VRAM: four 8 KB banks, each 64*32 tiles x 2 words:
//     word 0   tile code
//     word 1   bit 7 flip Y, bit 6 flip X, bits 5-0 colour
//
// gfx_data is one 64-bit granule, bytes in ascending address order, byte 0 in
// bits [7:0]: the SDRAM controller's packing, fixed at this seam rather than
// in a shared module.
//     16x16x4   one row = 8 bytes  = 1 granule
//     16x16x8   one row = 16 bytes = 2 granules
//     8x8x4     one row = 4 bytes  = half a granule, selected by byte
//               address bit 2
// Bit layouts: docs/gfx_layouts.md.

module tilemap_line_engine (
	input  logic clk,
	input  logic reset,

	// ---- per-line control ----
	input  logic        line_start,    // 1-cycle pulse, start of hblank
	input  logic [8:0]  render_line,   // the line to render (vcnt_next)
	output logic        busy,
	output logic        done,          // 1-cycle pulse when the line is complete

	// ---- layer configuration, sampled at line_start ----
	input  logic [1:0]  vram_bank,     // 0 = L0, 1 = L1, 2/3 = L2 double buffer
	input  logic        tile16,        // 1 = 16x16 tiles, 0 = 8x8
	input  logic        bpp8,          // 1 = 8 bits per pixel, 0 = 4
	input  logic        colour_shift4, // FG-3 layers 0/1: colour >>= 4
	input  logic        gran256,       // palette granularity 256 (else 16)
	input  logic [12:0] pal_base,      // palette colour base for this layer
	input  logic [7:0]  trans_pen,     // pen treated as transparent
	input  logic [25:0] gfx_base,      // byte address of this layer's tile ROM
	input  logic [15:0] scroll_x,
	input  logic [15:0] scroll_y,

	// Screen flip. Not yet honoured. MAME does not flip by rotating the
	// output: fuukitmap.cpp substitutes offset constants and fuukispr.cpp
	// recomputes sprite positions, so it has to be done here.
	input  logic        flip,

	// ---- tilemap VRAM read port (registered, 1-cycle latency) ----
	output logic [13:0] vram_addr,
	input  logic [15:0] vram_data,

	// ---- graphics ROM, req/valid ----
	// req is a one-cycle pulse. Check it against the transport wired
	// underneath: a mismatched shape returns the previous request's data
	// rather than hanging.
	output logic        gfx_req,
	output logic [25:0] gfx_addr,      // byte address, 8-byte aligned
	input  logic        gfx_valid,
	input  logic [63:0] gfx_data,

	// ---- line buffer write port ----
	output logic        lb_we,
	output logic [8:0]  lb_x,          // 0..319
	output logic [13:0] lb_data        // { opaque, palette index[12:0] }
);

	localparam int SCREEN_W = 320;

	// ---- latched configuration ----
	logic [1:0]  c_bank;
	logic        c_tile16, c_bpp8, c_shift4, c_gran256;
	logic [12:0] c_pal_base;
	logic [7:0]  c_trans;
	logic [25:0] c_gfx_base;
	logic [15:0] c_scroll_x;

	// ---- per-line derived state ----
	logic [4:0]  tile_row;      // 0..31
	logic [3:0]  row_in_tile;   // 0..15 (0..7 when 8x8)
	logic [5:0]  tile_col;      // 0..63, wraps naturally
	logic [3:0]  first_skip;    // pixels to discard from the first tile
	logic signed [9:0] tile_x;  // screen x of the current tile's pixel 0

	// How much of the first tile column is off the left edge. Named wires
	// because Quartus 17.0 cannot parse `-10'(expr)`.
	wire [9:0] first_off16 = {6'd0, c_scroll_x[3:0]};
	wire [9:0] first_off8  = {7'd0, c_scroll_x[2:0]};

	// ---- current tile ----
	logic [15:0] tile_code;
	logic [15:0] tile_attr;
	logic [63:0] gfx_lo, gfx_hi;
	logic [4:0]  px;            // pixel index within the tile

	wire [3:0]  tile_mask  = c_tile16 ? 4'd15 : 4'd7;
	wire [4:0]  tile_size  = c_tile16 ? 5'd16 : 5'd8;
	wire        attr_flipx = tile_attr[6];
	wire        attr_flipy = tile_attr[7];
	wire [5:0]  attr_colour_raw = tile_attr[5:0];
	// FG-3 shifts the colour right by 4 on layers 0 and 1, leaving two bits
	// selecting one of four 256-entry banks (tmap_colour_cb).
	wire [5:0]  attr_colour = c_shift4 ? {4'd0, attr_colour_raw[5:4]} : attr_colour_raw;

	// ---- FSM ----
	typedef enum logic [3:0] {
		S_IDLE, S_SETUP, S_CODE, S_CODE_W, S_ATTR, S_ATTR_W,
		S_REQ_LO, S_WAIT_LO, S_REQ_HI, S_WAIT_HI, S_WRITE, S_NEXT, S_DONE
	} state_t;
	state_t st;

	// Row within the tile, after the tile's own flip-Y.
	wire [3:0] src_row = attr_flipy ? (tile_mask - row_in_tile) : row_in_tile;

	// Byte address of this tile row.
	//   16x16x8  256 bytes/tile, 16 bytes/row
	//   16x16x4  128 bytes/tile,  8 bytes/row
	//   8x8x4     32 bytes/tile,  4 bytes/row
	logic [25:0] row_addr;
	always_comb begin
		if (!c_tile16)        row_addr = c_gfx_base + {tile_code, 5'd0} + {src_row[2:0], 2'd0};
		else if (c_bpp8)      row_addr = c_gfx_base + {tile_code, 8'd0} + {src_row, 4'd0};
		else                  row_addr = c_gfx_base + {tile_code, 7'd0} + {src_row, 3'd0};
	end

	// ---- pixel extraction ----
	// Source pixel index within the tile, after flip-X.
	wire [3:0] spx = attr_flipx ? (tile_mask - px[3:0]) : px[3:0];

	logic [7:0] pen;
	always_comb begin
		logic [7:0] b0, b1, b2, b3;
		logic [63:0] gsel;
		if (!c_tile16) begin
			// 8x8x4: the 4-byte row sits in one half of the granule, chosen
			// by bit 2 of its byte address.
			gsel = row_addr[2] ? {32'd0, gfx_lo[63:32]} : {32'd0, gfx_lo[31:0]};
			b0   = gsel[8*(spx[2:1]) +: 8];
			pen  = spx[0] ? {4'd0, b0[3:0]} : {4'd0, b0[7:4]};
		end else if (!c_bpp8) begin
			// 16x16x4: packed nibbles, most significant nibble first.
			b0  = gfx_lo[8*(spx[3:1]) +: 8];
			pen = spx[0] ? {4'd0, b0[3:0]} : {4'd0, b0[7:4]};
		end else begin
			// 16x16x8: four groups of four bytes per row, four pixels per
			// group. The group's first two bytes carry the high nibble of
			// the pixel and the next two the low nibble.
			gsel = spx[3] ? gfx_hi : gfx_lo;      // groups 0,1 low granule
			b0 = gsel[8*({spx[2], 2'd0}) +: 8];   // byte 4g+0
			b1 = gsel[8*({spx[2], 2'd1}) +: 8];   // byte 4g+1
			b2 = gsel[8*({spx[2], 2'd2}) +: 8];   // byte 4g+2
			b3 = gsel[8*({spx[2], 2'd3}) +: 8];   // byte 4g+3
			case (spx[1:0])
				2'd0: pen = {b0[7:4], b2[7:4]};
				2'd1: pen = {b0[3:0], b2[3:0]};
				2'd2: pen = {b1[7:4], b3[7:4]};
				default: pen = {b1[3:0], b3[3:0]};
			endcase
		end
	end

	// palette index = base + colour * granularity + pen.
	// Granularity 16 is deliberate for FG-2's 8bpp layer 1: the pen can
	// exceed the granularity there ("256 colour tiles with palette selectable
	// on 16 colour boundaries"), so the pen is added, never masked.
	wire [12:0] pal_index = c_pal_base +
	                        (c_gran256 ? {attr_colour[4:0], 8'd0} : {attr_colour, 4'd0}) +
	                        pen;

	wire opaque = (pen != c_trans);

	// Screen x for the current pixel. Skipped pixels of the first tile are
	// simply not written.
	wire signed [10:0] out_x = 11'(tile_x) + 11'(px);
	wire on_screen = (out_x >= 0) && (out_x < SCREEN_W);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st      <= S_IDLE;
			busy    <= 1'b0;
			done    <= 1'b0;
			gfx_req <= 1'b0;
			lb_we   <= 1'b0;
		end else begin
			done    <= 1'b0;
			gfx_req <= 1'b0;
			lb_we   <= 1'b0;

			case (st)
			S_IDLE: begin
				if (line_start) begin
					// Latch every configuration input for the whole line.
					c_bank     <= vram_bank;
					c_tile16   <= tile16;
					c_bpp8     <= bpp8;
					c_shift4   <= colour_shift4;
					c_gran256  <= gran256;
					c_pal_base <= pal_base;
					c_trans    <= trans_pen;
					c_gfx_base <= gfx_base;
					c_scroll_x <= scroll_x;

					// Source row, wrapping on the map height.
					begin
						logic [15:0] sy;
						sy = 16'(render_line) + scroll_y;
						if (tile16) begin
							tile_row    <= sy[8:4];     // 512-pixel map
							row_in_tile <= sy[3:0];
						end else begin
							tile_row    <= sy[7:3];     // 256-pixel map
							row_in_tile <= {1'b0, sy[2:0]};
						end
					end
					busy <= 1'b1;
					st   <= S_SETUP;
				end
			end

			S_SETUP: begin
				// First tile column and how much of it is off the left edge.
				// Do not write `-10'(signed'(...))`: Quartus 17.0 rejects
				// both casts, though ModelSim accepts them. The operand's top
				// bit is clear, so unary minus on the 10-bit wire is
				// bit-identical.
				if (c_tile16) begin
					tile_col   <= c_scroll_x[9:4];
					first_skip <= c_scroll_x[3:0];
					tile_x     <= -first_off16;
				end else begin
					tile_col   <= c_scroll_x[8:3];
					first_skip <= {1'b0, c_scroll_x[2:0]};
					tile_x     <= -first_off8;
				end
				st <= S_CODE;
			end

			// Registered VRAM read: data is valid one state after the
			// address. Consuming it early gets the previous address's data.
			S_CODE:   st <= S_CODE_W;
			S_CODE_W: begin tile_code <= vram_data; st <= S_ATTR;   end
			S_ATTR:   st <= S_ATTR_W;
			S_ATTR_W: begin tile_attr <= vram_data; st <= S_REQ_LO; end

			S_REQ_LO: begin
				gfx_req  <= 1'b1;
				gfx_addr <= {row_addr[25:3], 3'd0};
				st       <= S_WAIT_LO;
			end
			S_WAIT_LO: begin
				if (gfx_valid) begin
					gfx_lo <= gfx_data;
					// 8bpp 16x16 rows are 16 bytes: a second granule.
					st <= (c_tile16 && c_bpp8) ? S_REQ_HI : S_WRITE;
					px <= 5'd0;
				end
			end
			S_REQ_HI: begin
				gfx_req  <= 1'b1;
				gfx_addr <= {row_addr[25:3], 3'd0} + 26'd8;
				st       <= S_WAIT_HI;
			end
			S_WAIT_HI: begin
				if (gfx_valid) begin
					gfx_hi <= gfx_data;
					st     <= S_WRITE;
					px     <= 5'd0;
				end
			end

			S_WRITE: begin
				// One pixel per cycle. Off-edge pixels are computed and
				// discarded, keeping the address arithmetic in one place.
				if (on_screen) begin
					lb_we   <= 1'b1;
					lb_x    <= 9'(out_x);
					lb_data <= {opaque, pal_index};
				end
				if (px == 5'(tile_size - 1)) st <= S_NEXT;
				else                          px <= px + 5'd1;
			end

			S_NEXT: begin
				if ((11'(tile_x) + 11'(tile_size)) >= 11'(SCREEN_W)) begin
					st <= S_DONE;
				end else begin
					tile_x   <= tile_x + 10'(tile_size);
					tile_col <= tile_col + 6'd1;   // wraps at 64, as the map does
					st       <= S_CODE;
				end
			end

			S_DONE: begin
				busy <= 1'b0;
				done <= 1'b1;
				st   <= S_IDLE;
			end

			default: st <= S_IDLE;
			endcase
		end
	end

	// VRAM address: bank, tile index (row*64 + col), then which of the tile's
	// two words. Code is word 0, attributes word 1.
	wire word_sel = (st == S_ATTR) || (st == S_ATTR_W);
	assign vram_addr = {c_bank, tile_row, tile_col, word_sel};

endmodule
