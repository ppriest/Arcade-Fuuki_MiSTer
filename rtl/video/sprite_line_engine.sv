// Per-scanline sprite renderer.
//
// Draws the sprites intersecting one scanline into a 320-pixel line buffer.
// sprite_line_list builds the candidate list once per frame; per line each
// candidate costs one y-extent read plus real rendering.
//
// line_tick is a hard resync in every state, not a pulse consumed when idle.
// Writes stop the same cycle. An in-flight graphics request is drained, not
// abandoned: the transport delivers its response regardless and a later
// request would collect it. An overrun clips at worst the tail sprites of one
// line and raises ovr_ev.
//
// Record format: sprite_line_list.sv. Sprites are 16x16x4 on both boards, so
// one tile row is 8 bytes, one 64-bit granule.
//
// The next sub-tile's granule is fetched while the current one draws: S_TILE
// computes the address of sub-tile ix+1, S_PIX issues the request on its first
// pixel, the response lands in gfx_row_next. A tile costs max(latency, ~20 clk)
// instead of the sum. Still one request outstanding at a time.

module sprite_line_engine (
	input  logic clk,
	input  logic reset,

	// Raw per-line pulse. Fires every line, and is the resync point.
	input  logic        line_tick,
	// Gated pulse: begin rendering `render_line` (the line buffer is ready).
	input  logic        line_start,
	input  logic [8:0]  render_line,
	output logic        busy,
	output logic        ovr_ev,       // pulse: a line was cut short

	input  logic        board,   // BOARD_FG2 / BOARD_FG3
	input  logic [31:0] tilebank,     // FG-3 sprite tile bank, already buffered
	input  logic [25:0] gfx_base,     // byte address of the sprite tile ROM

	// ---- candidate list ----
	input  logic [10:0] n_entries,
	output logic [9:0]  yt_addr,
	input  logic [18:0] yt_data,      // { y_top[9:0] signed, span_y[8:0] }
	output logic [9:0]  rec_addr,
	input  logic [63:0] rec_data,

	// ---- graphics ROM, req/valid, one-cycle req pulse ----
	output logic        gfx_req,
	output logic [25:0] gfx_addr,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_data,

	// ---- line buffer write port ----
	output logic        lb_we,
	output logic [8:0]  lb_x,
	output logic [15:0] lb_data       // { opaque, priority[1:0], pal[12:0] }
);


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	localparam int SCREEN_W = 320;
	localparam logic [12:0] SPRITE_PAL_BASE = 13'h800;   // 0x400*2
	localparam logic [3:0]  TRANS_PEN       = 4'd15;

	// ---- scan state ----
	logic [9:0]  scan_i;
	logic [8:0]  cur_line;

	// ---- current sprite ----
	logic [15:0] w0, w1, w2, w3;
	logic signed [10:0] sx, sy;
	logic [4:0]  xnum, ynum;
	logic        flipx, flipy, nonzoom;
	logic [1:0]  pri;
	logic [5:0]  colour;
	logic [15:0] base_code;

	logic [4:0]  iy;          // sub-tile row under test / selected
	logic [4:0]  ix;          // sub-tile column being drawn
	logic [3:0]  src_row;     // row within the tile, before flip
	logic [7:0]  dst_w;       // drawn width of one sub-tile
	logic signed [11:0] tile_x0;
	logic [7:0]  dx;          // destination pixel within the sub-tile
	// 16.16 source accumulator with four integer bits: worst case
	// (dst_w-1) * step = 16 * 61680 = 986,880 needs 20 bits.
	logic [19:0] xacc;
	logic [63:0] gfx_row;

	// ---- zoom lookups ----
	// Outputs registered in S_DECODE for timing. w2 is latched in S_REC_W, so
	// this costs no cycles and keeps the lookup off the chained-multiplier path.
	wire [7:0]  zxt, zyt, dstx, dsty;
	wire [17:0] stepx, stepy;
	sprite_zoom_lut u_zx (.zoom_field(w2[15:12]), .zoom_t(zxt), .dst_size(dstx), .step(stepx));
	sprite_zoom_lut u_zy (.zoom_field(w2[11:8]),  .zoom_t(zyt), .dst_size(dsty), .step(stepy));

	logic [7:0]  zxt_r, zyt_r, dstx_r, dsty_r;
	logic [17:0] stepx_r, stepy_r;
	logic [7:0]  row_delta;   // line12 - row_origin, held for S_ROWCALC

	// Origin of sub-tile row iy. One expression for both paths: at zoom 0 the
	// zoom term is 128 and (iy * 128) >> 3 is iy * 16.
	// yacc accumulates iy * zyt_r (S_FINDROW steps iy by one) instead of
	// multiplying, to keep a multiplier out of S_FINDROW's loop.
	logic [12:0] yacc;
	wire signed [11:0] row_origin = 12'(sy) + 12'(yacc >> 3);
	// The zoom path scales by the next larger integer step, so a nominally
	// full-size sprite drawn through it is 17 pixels tall. MAME keeps a
	// separate non-zoomed path; so does this.
	wire [7:0] dst_h = nonzoom ? 8'd16 : dsty_r;

	wire signed [11:0] line12 = 12'({3'd0, cur_line});

	// Every operand signed and 13 bits wide. With an unsigned dst_h the
	// compare goes unsigned, and a row ending above the screen (negative end)
	// wraps and hits every scanline.
	wire signed [12:0] row_top = 13'(row_origin);
	wire signed [12:0] row_end = row_top + $signed({5'd0, dst_h});
	wire signed [12:0] line13  = 13'(line12);
	wire row_hit = (line13 >= row_top) && (line13 < row_end);

	// ---- code index ----
	// MAME increments the tile code in loop order and positions by the loop
	// variable, so with flip the code is counted from the far end: iteration
	// number, not position. ny is fixed once S_FINDROW has chosen the row and
	// is registered in S_ROWCALC for timing; nx varies per sub-tile.
	logic [4:0] ny_r;
	wire [4:0] nx = flipx ? (xnum - 5'd1 - ix) : ix;
	wire [9:0] code_index = {5'd0, ny_r} * {5'd0, xnum} + {5'd0, nx};

	// FG-3: code = (code & 0x3fff) + lookup * 0x4000, the lookup being a
	// 4-bit field of the buffered tilebank register (spr_tile_cb).
	wire [1:0]  bank_sel = base_code[15:14];
	wire [3:0]  bank_val = tilebank[16 + 4*bank_sel +: 4];
	// Depends only on base_code, fixed per sprite. Registered in S_ROWCALC so
	// the per-sub-tile path is the code multiply and one add.
	logic [17:0] code_base_r;
	wire [17:0] tile_no = code_base_r + {8'd0, code_index};

	logic [12:0] xoff;        // ix * zxt_r, accumulated like yacc
	logic [17:0] tile_no_r;   // tile_no, registered in S_TILE

	// ---- prefetch of sub-tile ix+1 ----
	wire [4:0]  ix_next        = ix + 5'd1;
	wire        has_next       = (ix_next < xnum);
	wire [4:0]  nx_next        = flipx ? (xnum - 5'd1 - ix_next) : ix_next;
	wire [9:0]  code_index_nxt = {5'd0, ny_r} * {5'd0, xnum} + {5'd0, nx_next};
	wire [17:0] tile_no_next   = code_base_r + {8'd0, code_index_nxt};
	logic [17:0] tile_no_next_r;   // registered in S_TILE beside tile_no_r
	logic        pf_pending;       // the prefetch request is in flight
	logic        pf_valid;         // gfx_row_next holds sub-tile ix+1's row
	logic [63:0] gfx_row_next;

	// Row within the tile, after the tile's own flip-Y.
	wire [3:0] row_f = flipy ? (4'd15 - src_row) : src_row;
	// 128 bytes per tile, 8 per row. tile_no_r, not tile_no: the code_index
	// multiply is done a state earlier.
	wire [25:0] row_addr = gfx_base + {tile_no_r, 7'd0} + {row_f, 3'd0};
	// Same row of the next sub-tile: row_f is per sprite per line.
	wire [25:0] row_addr_next = gfx_base + {tile_no_next_r, 7'd0} + {row_f, 3'd0};

	// ---- pixel extraction, 4bpp packed, MSB nibble first ----
	wire [3:0] src_px = nonzoom ? dx[3:0] : xacc[19:16];
	wire [3:0] spx    = flipx ? (4'd15 - src_px) : src_px;
	wire [7:0] pix_b  = gfx_row[8*(spx[3:1]) +: 8];
	wire [3:0] pen    = spx[0] ? pix_b[3:0] : pix_b[7:4];

	wire [12:0] pal_index = SPRITE_PAL_BASE + {colour, 4'd0} + {9'd0, pen};
	wire signed [11:0] out_x = tile_x0 + 12'({4'd0, dx});
	wire on_screen = (out_x >= 0) && (out_x < 12'(SCREEN_W));

	typedef enum logic [3:0] {
		S_IDLE, S_SCAN, S_SCAN_W, S_REC, S_REC_W, S_DECODE,
		S_FINDROW, S_ROWCALC, S_TILE, S_REQ, S_WAIT, S_PIX, S_NEXT_TILE,
		S_NEXT, S_DRAIN
	} state_t;
	state_t st;

	assign yt_addr  = scan_i;
	assign rec_addr = scan_i;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st         <= S_IDLE;
			busy       <= 1'b0;
			ovr_ev     <= 1'b0;
			gfx_req    <= 1'b0;
			lb_we      <= 1'b0;
			pf_pending <= 1'b0;
			pf_valid   <= 1'b0;
		end else begin
			gfx_req <= 1'b0;
			lb_we   <= 1'b0;
			ovr_ev  <= 1'b0;

			// The prefetch response lands here in every state except S_WAIT
			// and S_DRAIN, which consume it themselves.
			if (pf_pending && gfx_valid && st != S_WAIT && st != S_DRAIN) begin
				gfx_row_next <= gfx_data;
				pf_pending   <= 1'b0;
				pf_valid     <= 1'b1;
			end

			// ---- hard resync, checked before anything else ----
			// A prefetch in flight is an outstanding request: drain it.
			if (line_tick) begin
				if (st != S_IDLE) ovr_ev <= (st != S_NEXT) && (st != S_SCAN);
				pf_valid <= 1'b0;
				if (st == S_WAIT || pf_pending) begin
					st <= S_DRAIN;
				end else begin
					st   <= S_IDLE;
					busy <= 1'b0;
				end
			end else begin
				case (st)
				S_IDLE: begin
					if (line_start) begin
						scan_i   <= 10'd0;
						cur_line <= render_line;
						busy     <= 1'b1;
						st       <= (n_entries == 11'd0) ? S_IDLE : S_SCAN;
						if (n_entries == 11'd0) busy <= 1'b0;
					end
				end

				// One candidate per pass: address out, data one cycle later.
				S_SCAN:   st <= S_SCAN_W;
				S_SCAN_W: begin
					// Coarse bounding-box test on the stored y extent.
					if ((line12 >= 12'($signed(yt_data[18:9]))) &&
					    (line12 <  12'($signed(yt_data[18:9])) + 12'({3'd0, yt_data[8:0]})))
						st <= S_REC;
					else
						st <= S_NEXT;
				end

				S_REC:   st <= S_REC_W;
				S_REC_W: begin
					w0 <= rec_data[63:48];
					w1 <= rec_data[47:32];
					w2 <= rec_data[31:16];
					w3 <= rec_data[15:0];
					st <= S_DECODE;
				end

				S_DECODE: begin
					sx        <= 11'($signed(w0[9:0]));
					sy        <= 11'($signed(w1[9:0]));
					xnum      <= 5'(w0[15:12]) + 5'd1;
					ynum      <= 5'(w1[15:12]) + 5'd1;
					flipx     <= w0[11];
					flipy     <= w1[11];
					pri       <= w2[7:6];
					colour    <= w2[5:0];
					base_code <= w3;
					nonzoom   <= (w2[15:8] == 8'd0);
					zxt_r <= zxt; zyt_r <= zyt;
					dstx_r <= dstx; dsty_r <= dsty;
					stepx_r <= stepx; stepy_r <= stepy;
					iy        <= 5'd0;
					yacc      <= 13'd0;
					st        <= S_FINDROW;
				end

				// Exact per-sub-tile-row test; the list's test was a coarse
				// bounding box. At most 16 iterations.
				S_FINDROW: begin
					if (row_hit) begin
						// Subtract only. The multiply is in S_ROWCALC so the
						// two multipliers are not chained in one cycle.
						row_delta <= 8'(line12 - row_origin);
						ix        <= 5'd0;
						xoff      <= 13'd0;
						st        <= S_ROWCALC;
					end else if (iy == (ynum - 5'd1)) begin
						st <= S_NEXT;          // conservative false hit: costs cycles only
					end else begin
						iy   <= iy + 5'd1;
						yacc <= yacc + {5'd0, zyt_r};
					end
				end

				// Once per sprite per line, not per pixel.
				S_ROWCALC: begin
					src_row <= nonzoom
					         ? row_delta[3:0]
					         : 4'((({10'd0, row_delta} * {8'd0, stepy_r}) >> 16));
					dst_w   <= nonzoom ? 8'd16 : dstx_r;
					// Fixed for the rest of this sprite; see their declarations.
					ny_r        <= flipy ? (ynum - 5'd1 - iy) : iy;
					code_base_r <= (board == BOARD_FG3)
					             ? ({4'd0, base_code[13:0]} + {bank_val, 14'd0})
					             : ({2'd0, base_code});
					st      <= S_TILE;
				end

				S_TILE: begin
					tile_x0        <= 12'(sx) + 12'(xoff >> 3);
					tile_no_r      <= tile_no;
					tile_no_next_r <= tile_no_next;
					dx             <= 8'd0;
					xacc           <= 20'd0;
					// This sub-tile's row: prefetched, in flight, or not yet
					// requested (the sprite's first tile).
					if (pf_valid) begin
						gfx_row  <= gfx_row_next;
						pf_valid <= 1'b0;
						st       <= S_PIX;
					end else if (pf_pending) begin
						st <= S_WAIT;
					end else begin
						st <= S_REQ;
					end
				end

				S_REQ: begin
					gfx_req  <= 1'b1;
					gfx_addr <= {row_addr[25:3], 3'd0};
					st       <= S_WAIT;
				end

				// Direct request or in-flight prefetch: either way the
				// response is this tile's row.
				S_WAIT: begin
					if (gfx_valid) begin
						gfx_row    <= gfx_data;
						pf_pending <= 1'b0;
						st         <= S_PIX;
					end
				end

				S_PIX: begin
					// First pixel: start the next sub-tile's fetch.
					if (dx == 8'd0 && has_next && !pf_pending && !pf_valid) begin
						gfx_req    <= 1'b1;
						gfx_addr   <= {row_addr_next[25:3], 3'd0};
						pf_pending <= 1'b1;
					end
					// Pen 15 is transparent for sprites (fuukispr transpen).
					if (on_screen && (pen != TRANS_PEN)) begin
						lb_we   <= 1'b1;
						lb_x    <= 9'(out_x);
						lb_data <= {1'b1, pri, pal_index};
					end
					if (dx == (dst_w - 8'd1)) begin
						st <= S_NEXT_TILE;
					end else begin
						dx   <= dx + 8'd1;
						xacc <= xacc + {2'd0, stepx_r};
					end
				end

				S_NEXT_TILE: begin
					if (ix == (xnum - 5'd1)) st <= S_NEXT;
					else begin
						ix   <= ix + 5'd1;
						xoff <= xoff + {5'd0, zxt_r};
						st   <= S_TILE;
					end
				end

				S_NEXT: begin
					if (scan_i == 10'(n_entries - 11'd1)) begin
						busy <= 1'b0;
						st   <= S_IDLE;
					end else begin
						scan_i <= scan_i + 10'd1;
						st     <= S_SCAN;
					end
				end

				// Swallow the response to a request issued before a resync.
				S_DRAIN: begin
					if (gfx_valid) begin
						pf_pending <= 1'b0;
						st         <= S_IDLE;
						busy       <= 1'b0;
					end
				end

				default: st <= S_IDLE;
				endcase
			end
		end
	end

endmodule
