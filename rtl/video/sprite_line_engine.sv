// Per-scanline sprite renderer.
//
// Renders only the sprites intersecting one scanline into a 320-pixel line
// buffer. This is the shape real arcade hardware used and the shape the rest
// of the MiSTer ecosystem uses (JTFRAME's line-buffer path, zoom included).
//
// It works with sprite_line_list, which does the expensive part once per frame
// so the per-line cost is one pipelined y-extent read per candidate plus real
// rendering. Without that hoist a per-line renderer cannot fit: see that
// module's header.
//
// ---------------------------------------------------------------------------
// THE LINE PULSE IS A HARD RESYNC, NOT SOMETHING CONSUMED WHEN IDLE.
//
// Psikyo's first line renderer consumed its line pulse only in the idle state,
// so an engine still busy at a line boundary ATE the pulse: it finished the
// previous line's sprites into the freshly swapped bank, then idled for a
// whole line. One overrun corrupted every line below it, giving the
// unmistakable "correct at the top, degrading downward" hardware signature.
//
// Here line_tick aborts immediately in every state. Writes stop the same
// cycle; an in-flight graphics request is drained rather than abandoned,
// because the transport will deliver its response regardless and a later
// request would otherwise collect it. An overrun therefore clips at worst the
// tail sprites of one line -- which are the ones furthest back in depth -- and
// raises ovr_ev so it can be counted rather than guessed at.
// ---------------------------------------------------------------------------
//
// Record format and geometry are documented in sprite_line_list.sv. Sprites
// are 16x16x4 on both boards, so one tile row is 8 bytes -- exactly one
// 64-bit granule, with no second fetch.

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

	input  logic        board_fg3,
	input  logic [31:0] tilebank,     // FG-3 sprite tile bank, already buffered
	input  logic [24:0] gfx_base,     // byte address of the sprite tile ROM

	// ---- candidate list ----
	input  logic [10:0] n_entries,
	output logic [9:0]  yt_addr,
	input  logic [18:0] yt_data,      // { y_top[9:0] signed, span_y[8:0] }
	output logic [9:0]  rec_addr,
	input  logic [63:0] rec_data,

	// ---- graphics ROM, req/valid, one-cycle req pulse ----
	output logic        gfx_req,
	output logic [24:0] gfx_addr,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_data,

	// ---- line buffer write port ----
	output logic        lb_we,
	output logic [8:0]  lb_x,
	output logic [15:0] lb_data       // { opaque, priority[1:0], pal[12:0] }
);

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
	logic [17:0] xacc;        // 16.16 source accumulator
	logic [63:0] gfx_row;

	// ---- zoom lookups ----
	//
	// TIMING, and this is why the outputs are REGISTERED rather than used
	// straight from the tables. The first synthesis of this core missed setup
	// by 3.483 ns at 85.909091 MHz, and every one of the 400 worst paths ran
	// through here: w2 -> table -> (iy * zyt) -> subtract -> (* stepy) -> ...
	// two chained multipliers plus the lookup in a single 11.641 ns cycle,
	// 14.593 ns of data delay.
	//
	// The tables depend only on w2, which is latched a whole state earlier in
	// S_REC_W, so registering their outputs in S_DECODE costs no cycles at all
	// and takes the lookup off the path. Splitting the two multipliers is the
	// other half -- see S_ROWCALC.
	wire [7:0]  zxt, zyt, dstx, dsty;
	wire [17:0] stepx, stepy;
	sprite_zoom_lut u_zx (.zoom_field(w2[15:12]), .zoom_t(zxt), .dst_size(dstx), .step(stepx));
	sprite_zoom_lut u_zy (.zoom_field(w2[11:8]),  .zoom_t(zyt), .dst_size(dsty), .step(stepy));

	logic [7:0]  zxt_r, zyt_r, dstx_r, dsty_r;
	logic [17:0] stepx_r, stepy_r;
	logic [7:0]  row_delta;   // line12 - row_origin, held for S_ROWCALC

	// Origin of sub-tile row iy. The same expression covers both paths: at
	// zoom 0 the zoom term is 128, and (iy * 128) >> 3 is exactly iy * 16.
	//
	// ACCUMULATED, not multiplied. Written as (iy * zyt_r) >> 3 this put a
	// multiplier inside S_FINDROW's own loop -- iy -> multiply -> compare ->
	// iy -- which was the design's critical path at -1.099 ns, 340 of the 400
	// violating paths ending on iy. S_FINDROW steps iy by one each iteration,
	// so yacc holds iy * zyt_r exactly by adding zyt_r per step, and
	// (yacc >> 3) is bit-identical to the product it replaces.
	logic [12:0] yacc;
	wire signed [11:0] row_origin = 12'(sy) + 12'(yacc >> 3);
	// Drawn height, which is where the two paths DIVERGE: the zoom path scales
	// by the next larger integer step, making a nominally full-size sprite 17
	// pixels tall rather than 16. MAME keeps a separate non-zoomed path for
	// exactly this reason, so this one does too.
	wire [7:0] dst_h = nonzoom ? 8'd16 : dsty_r;

	wire signed [11:0] line12 = 12'({3'd0, cur_line});
	wire row_hit = (line12 >= row_origin) && (line12 < (row_origin + 12'(dst_h)));

	// ---- code index ----
	// MAME increments the tile code in LOOP order while positioning by the
	// loop variable, so with flip the code that lands at a given screen
	// position is counted from the far end. Iteration number, not position.
	// ny is fixed once S_FINDROW has chosen the row, so it is REGISTERED in
	// S_ROWCALC: leaving it inline put iy -> subtract -> multiply -> adds ->
	// tile_no_r on the critical path at -0.305 ns. nx still varies per
	// sub-tile and stays combinational.
	logic [4:0] ny_r;
	wire [4:0] nx = flipx ? (xnum - 5'd1 - ix) : ix;
	wire [9:0] code_index = {5'd0, ny_r} * {5'd0, xnum} + {5'd0, nx};

	// FG-3 replaces the top two code bits with a 4-bit bank looked up in the
	// buffered tilebank register (spr_tile_cb): code = (code & 0x3fff) +
	// lookup * 0x4000.
	wire [1:0]  bank_sel = base_code[15:14];
	wire [3:0]  bank_val = tilebank[16 + 4*bank_sel +: 4];
	// The board-dependent base -- including FG-3's variable bank select into
	// tilebank -- depends only on base_code, which is fixed for the whole
	// sprite. Registered in S_ROWCALC so the per-sub-tile path is the code
	// multiply and ONE add, not a mux and two.
	logic [17:0] code_base_r;
	wire [17:0] tile_no = code_base_r + {8'd0, code_index};

	logic [12:0] xoff;        // ix * zxt_r, accumulated -- see row_origin
	logic [17:0] tile_no_r;   // tile_no, registered in S_TILE

	// Row within the tile, after the tile's own flip-Y.
	wire [3:0] row_f = flipy ? (4'd15 - src_row) : src_row;
	// 16x16x4: 128 bytes per tile, 8 bytes per row -- one granule, no second fetch.
	// tile_no_r, not tile_no: the code_index multiply is done a state earlier,
	// so S_REQ's path into gfx_addr is two adds rather than a multiply-add.
	wire [24:0] row_addr = gfx_base + {tile_no_r, 7'd0} + {row_f, 3'd0};

	// ---- pixel extraction, 4bpp packed, MSB nibble first ----
	wire [3:0] src_px = nonzoom ? dx[3:0] : 4'((xacc >> 16));
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
			st      <= S_IDLE;
			busy    <= 1'b0;
			ovr_ev  <= 1'b0;
			gfx_req <= 1'b0;
			lb_we   <= 1'b0;
		end else begin
			gfx_req <= 1'b0;
			lb_we   <= 1'b0;
			ovr_ev  <= 1'b0;

			// ---- hard resync, checked before anything else ----
			// An outstanding request is drained rather than abandoned: the
			// transport will deliver its response regardless, and a later
			// request would otherwise collect it and render the wrong tile.
			if (line_tick) begin
				if (st != S_IDLE) ovr_ev <= (st != S_NEXT) && (st != S_SCAN);
				if (st == S_WAIT) begin
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
					// w2 was latched in S_REC_W, so the tables are settled and
					// this costs nothing. See the zoom-lookup timing note.
					zxt_r <= zxt; zyt_r <= zyt;
					dstx_r <= dstx; dsty_r <= dsty;
					stepx_r <= stepx; stepy_r <= stepy;
					iy        <= 5'd0;
					yacc      <= 13'd0;
					st        <= S_FINDROW;
				end

				// Exact per-sub-tile-row test, re-done here because the list's
				// test was a coarse bounding box and may have let a miss
				// through. At most 16 iterations.
				S_FINDROW: begin
					if (row_hit) begin
						// Subtract only. The multiply that turns this into
						// src_row moves to S_ROWCALC, so the two multipliers
						// are one per cycle instead of chained -- see the
						// zoom-lookup timing note above.
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

				// One cycle, once per sprite per line -- not per pixel -- so
				// the cost is invisible against the per-line budget.
				S_ROWCALC: begin
					src_row <= nonzoom
					         ? row_delta[3:0]
					         : 4'((({10'd0, row_delta} * {8'd0, stepy_r}) >> 16));
					dst_w   <= nonzoom ? 8'd16 : dstx_r;
					// Both fixed for the rest of this sprite -- see their
					// declarations. Computed here in parallel with src_row,
					// not chained behind it.
					ny_r        <= flipy ? (ynum - 5'd1 - iy) : iy;
					code_base_r <= board_fg3
					             ? ({4'd0, base_code[13:0]} + {bank_val, 14'd0})
					             : ({2'd0, base_code});
					st      <= S_TILE;
				end

				S_TILE: begin
					// xoff accumulates ix * zxt_r for the same reason yacc
					// accumulates iy * zyt_r; tile_no is registered here so
					// S_REQ's address add does not also carry the code
					// multiply.
					tile_x0   <= 12'(sx) + 12'(xoff >> 3);
					tile_no_r <= tile_no;
					dx        <= 8'd0;
					xacc      <= 18'd0;
					st        <= S_REQ;
				end

				S_REQ: begin
					gfx_req  <= 1'b1;
					gfx_addr <= {row_addr[24:3], 3'd0};
					st       <= S_WAIT;
				end

				S_WAIT: begin
					if (gfx_valid) begin
						gfx_row <= gfx_data;
						st      <= S_PIX;
					end
				end

				S_PIX: begin
					// Pen 15 is transparent for sprites (fuukispr's transpen).
					if (on_screen && (pen != TRANS_PEN)) begin
						lb_we   <= 1'b1;
						lb_x    <= 9'(out_x);
						lb_data <= {1'b1, pri, pal_index};
					end
					if (dx == (dst_w - 8'd1)) begin
						st <= S_NEXT_TILE;
					end else begin
						dx   <= dx + 8'd1;
						xacc <= xacc + stepx_r;
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
						st   <= S_IDLE;
						busy <= 1'b0;
					end
				end

				default: st <= S_IDLE;
				endcase
			end
		end
	end

endmodule
