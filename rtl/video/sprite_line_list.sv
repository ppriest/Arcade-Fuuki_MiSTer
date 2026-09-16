// Once-per-frame sprite candidate list.
//
// 1024 records x 4 words tested on every scanline would be 4096 sprite-RAM
// reads per line against a 5,472-cycle budget. So the walk, fetch and coarse
// rejection happen once per frame in vblank (about 7K cycles against
// 120,384), and the per-line cost is one y-extent read per candidate.
//
// Depth order: the highest-numbered record is drawn on top. The scan runs
// from record 0 upwards and appends; the engine renders in list order with
// later writes winning. This is the order measured on MiSTer (asurabld
// high-score table, in-game sprites, character-name flashes) and the opposite
// of what fuukispr.cpp's backwards walk for pdrawgfx suggests. The
// discrepancy is not explained. Do not reverse it without re-running that
// comparison on MiSTer; Fuuki.sv's "Sprite order" switch is the A/B.
//
// Record format (docs/ROADMAP.md, "Sprites"):
//   word0  15-12 xnum-1   11 flipX  10 DISABLE   9-0 X (signed)
//   word1  15-12 ynum-1   11 flipY              9-0 Y (signed)
//   word2  15-12 zoomX  11-8 zoomY  7-6 priority  5-0 colour
//   word3  tile code (FG-3: 15-14 select a tile bank)
//
// The stored y test is a coarse bounding box. The engine re-does the exact
// per-sub-tile-row test, so a false hit costs cycles, never a wrong pixel.

module sprite_line_list (
	input  logic clk,
	input  logic reset,

	// Pulse once per frame, after the sprite RAM snapshot is stable.
	input  logic        build_start,
	output logic        build_busy,
	output logic [10:0] n_entries,     // 0..1024

	// ---- sprite RAM read port (from spriteram_dbuf) ----
	output logic [11:0] sr_addr,
	input  logic [15:0] sr_data,

	// ---- candidate list read ports, for the per-line engine ----
	input  logic [9:0]  yt_addr,
	output logic [18:0] yt_data,       // { y_top[9:0] signed, span_y[8:0] }
	input  logic [9:0]  rec_addr,
	output logic [63:0] rec_data       // the four raw words
);

	// 1024 entries: every record visible. The y-extent RAM is the one read
	// every line, so it is kept narrow.
	logic [18:0] yt  [0:1023];
	logic [63:0] rec [0:1023];

	always_ff @(posedge clk) yt_data  <= yt[yt_addr];
	always_ff @(posedge clk) rec_data <= rec[rec_addr];

	logic [9:0]  idx;        // record being examined
	logic [9:0]  wr_idx;     // next free list slot
	logic [15:0] w0, w1, w2, w3;

	typedef enum logic [3:0] {
		S_IDLE, S_A0, S_A1, S_A2, S_A3, S_LAT3, S_GEOM, S_EVAL, S_DONE
	} state_t;
	state_t st;

	// ---- geometry, from the four latched words ----
	// Signed 10-bit positions, MAME's (v & 0x1ff) - (v & 0x200).
	wire signed [9:0] sx = $signed(w0[9:0]);
	wire signed [9:0] sy = $signed(w1[9:0]);

	wire [4:0] xnum = 5'(w0[15:12]) + 5'd1;    // 1..16 tiles
	wire [4:0] ynum = 5'(w1[15:12]) + 5'd1;

	// Zoom: xzoom = 128 - 4*field, 128 (full size) down to 68 (~53%).
	wire [7:0] xz = 8'd128 - {2'd0, w2[15:12], 2'd0};
	wire [7:0] yz = 8'd128 - {2'd0, w2[11:8],  2'd0};

	// MAME's separate non-zoomed path when both fields are zero; the zoom path
	// draws 17 pixels at full size (sprite_zoom_lut.sv).
	wire nonzoom = (w2[15:8] == 8'd0);

	// Distance between sub-tile origins, and the drawn size of one sub-tile.
	//   step = (n * zoom) >> 3          matches sx + (x * xzoom) / 8
	//   size = (zoom + 8) >> 3          matches the 512*(zoom+8) scale factor
	wire [12:0] y_step = {5'd0, ynum - 5'd1} * {5'd0, yz};
	wire [12:0] x_step = {5'd0, xnum - 5'd1} * {5'd0, xz};

	wire [9:0] span_y = nonzoom ? {1'b0, ynum, 4'd0}                       // ynum*16
	                            : (10'(y_step >> 3) + 10'((yz + 8'd8) >> 3));
	wire [9:0] span_x = nonzoom ? {1'b0, xnum, 4'd0}
	                            : (10'(x_step >> 3) + 10'((xz + 8'd8) >> 3));

	// Registered in S_GEOM for timing: w2 -> multiply -> span -> visible ->
	// RAM write enable does not fit one cycle. Costs one clock per record.
	logic [9:0] span_y_r, span_x_r;

	// Coarse visibility: a plain bounding box (see header).
	wire signed [11:0] y_top  = 12'(sy);
	wire signed [11:0] y_bot  = 12'(sy) + 12'(span_y_r);
	wire signed [11:0] x_left = 12'(sx);
	wire signed [11:0] x_rgt  = 12'(sx) + 12'(span_x_r);

	wire visible = !w0[10]                    // not disabled
	            && (y_bot > 12'sd0) && (y_top < 12'sd240)
	            && (x_rgt > 12'sd0) && (x_left < 12'sd320);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st         <= S_IDLE;
			build_busy <= 1'b0;
			n_entries  <= 11'd0;
			idx        <= 10'd0;
			wr_idx     <= 10'd0;
		end else begin
			case (st)
			S_IDLE: begin
				if (build_start) begin
					idx        <= 10'd0;       // scan forwards: see header
					wr_idx     <= 10'd0;
					n_entries  <= 11'd0;
					build_busy <= 1'b1;
					st         <= S_A0;
				end
			end

			// Four reads, one address per cycle, each result taken one cycle
			// after its address.
			S_A0: st <= S_A1;
			S_A1: begin w0 <= sr_data; st <= S_A2; end
			S_A2: begin w1 <= sr_data; st <= S_A3; end
			S_A3: begin w2 <= sr_data; st <= S_LAT3; end
			S_LAT3: begin w3 <= sr_data; st <= S_GEOM; end

			S_GEOM: begin
				span_y_r <= span_y;
				span_x_r <= span_x;
				st       <= S_EVAL;
			end

			S_EVAL: begin
				if (visible && (n_entries < 11'd1024)) begin
					yt[wr_idx]  <= {y_top[9:0], span_y_r[8:0]};
					rec[wr_idx] <= {w0, w1, w2, w3};
					wr_idx      <= wr_idx + 10'd1;
					n_entries   <= n_entries + 11'd1;
				end
				if (idx == 10'd1023) st <= S_DONE;
				else begin
					idx <= idx + 10'd1;
					st  <= S_A0;
				end
			end

			S_DONE: begin
				build_busy <= 1'b0;
				st         <= S_IDLE;
			end

			default: st <= S_IDLE;
			endcase
		end
	end

	// Word address within the record being read. The state names the word.
	logic [1:0] word_sel;
	always_comb begin
		case (st)
			S_A0:   word_sel = 2'd0;
			S_A1:   word_sel = 2'd1;
			S_A2:   word_sel = 2'd2;
			default: word_sel = 2'd3;
		endcase
	end
	assign sr_addr = {idx, word_sel};

endmodule
