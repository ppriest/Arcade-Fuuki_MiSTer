// Once-per-frame sprite candidate list.
//
// THIS MODULE IS WHY A PER-SCANLINE SPRITE RENDERER IS AFFORDABLE.
//
// Fuuki has 1024 sprite records of 4 words each. Testing them all on every
// scanline means 4096 sprite-RAM reads per line against a 5,472-cycle budget,
// before a single pixel is drawn -- it does not fit, and it is not close.
// Psikyo's first line-renderer attempt did exactly that (re-walking and
// re-fetching every record every line, ~10 cycles per sprite per line), blew
// the budget on busy scenes, and was parked.
//
// The fix is to do the walking, fetching and coarse rejection ONCE per frame,
// during vblank, and leave the per-line cost at one cycle per surviving
// candidate: a pipelined read of a small y-extent word. Budget here is about
// 1024 records x ~4 cycles = 4K cycles against vblank's 120,384 -- 3%.
//
// ---------------------------------------------------------------------------
// DEPTH ORDER: THE HIGHEST-NUMBERED RECORD IS DRAWN ON TOP.
//
// The scan runs from record 0 upwards and appends, so record 1023 lands last
// in the list; the per-line engine renders the list in order with later writes
// overwriting earlier ones, so the last one stored wins.
//
// THIS IS THE ORDER MEASURED ON MISTER, and it is the opposite of what
// reading fuukispr.cpp suggests. That file walks the list from the last record
// to the first when a colpri callback is installed ("Draw them backwards, for
// pdrawgfx"), which both Fuuki drivers do -- so record 0 is drawn last there
// and should be on top. Built that way, asurabld drew its high-score table,
// its in-game sprites and its character-name flashes wrongly, and flipping the
// order fixed all three (Fuuki.sv's "Sprite order" switch was added to make
// that an A/B on one frozen frame rather than a rebuild). The discrepancy with
// the driver is NOT explained; do not "correct" this back to match a reading
// of fuukispr.cpp without re-running that comparison on MiSTer.
//
// Record format (docs/ROADMAP.md, "Sprites"):
//   word0  15-12 xnum-1   11 flipX  10 DISABLE   9-0 X (signed)
//   word1  15-12 ynum-1   11 flipY              9-0 Y (signed)
//   word2  15-12 zoomX  11-8 zoomY  7-6 priority  5-0 colour
//   word3  tile code (FG-3: 15-14 select a tile bank)
//
// The y test stored here is deliberately COARSE -- a whole bounding box. The
// engine re-does the exact per-sub-tile-row arithmetic on every hit, so a
// conservative false hit costs a few cycles and never a wrong pixel.

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

	// 1024 entries is the worst case: every record visible. The y-extent RAM
	// is the one read every line, so it is kept narrow on purpose.
	logic [18:0] yt  [0:1023];
	logic [63:0] rec [0:1023];

	always_ff @(posedge clk) yt_data  <= yt[yt_addr];
	always_ff @(posedge clk) rec_data <= rec[rec_addr];

	logic [9:0]  idx;        // record being examined, counts DOWN
	logic [9:0]  wr_idx;     // next free list slot
	logic [15:0] w0, w1, w2, w3;

	typedef enum logic [3:0] {
		S_IDLE, S_A0, S_A1, S_A2, S_A3, S_LAT3, S_GEOM, S_EVAL, S_DONE
	} state_t;
	state_t st;

	// ---- geometry, computed at S_EVAL from the four latched words ----
	// Signed 10-bit positions, exactly MAME's (v & 0x1ff) - (v & 0x200).
	wire signed [9:0] sx = $signed(w0[9:0]);
	wire signed [9:0] sy = $signed(w1[9:0]);

	wire [4:0] xnum = 5'(w0[15:12]) + 5'd1;    // 1..16 tiles
	wire [4:0] ynum = 5'(w1[15:12]) + 5'd1;

	// Zoom: xzoom = 128 - 4*field, giving 128 (full size) down to 68 (~53%).
	wire [7:0] xz = 8'd128 - {2'd0, w2[15:12], 2'd0};
	wire [7:0] yz = 8'd128 - {2'd0, w2[11:8],  2'd0};

	// MAME takes a separate NON-ZOOMED path when both zoom fields are zero,
	// and it is not equivalent: the zoomed path scales by the next larger
	// integer step "to avoid holes", so a nominally full-size sprite drawn
	// through it comes out 17 pixels tall rather than 16.
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

	// TIMING: the spans are REGISTERED in S_GEOM, one state before they are
	// used. Computed inline, the chain ran w2 -> yz -> the y_step multiply ->
	// span_y -> y_bot -> visible -> the candidate RAMs' WRITE ENABLE, all in
	// the single S_EVAL cycle -- which was the critical path of the whole
	// design at -1.313 ns once sprite_line_engine was pipelined.
	//
	// The extra state costs one clock per record examined: 1024 records go
	// from 6144 to 7168 clocks, against roughly 120,000 clocks of vblank
	// before anything is drawn, so it is not close to the budget.
	logic [9:0] span_y_r, span_x_r;

	// Coarse visibility. Rejecting here is what keeps the per-line scan short;
	// being conservative costs only cycles, so the test is a plain bounding
	// box with no per-sub-tile refinement.
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
					idx        <= 10'd0;       // scan forwards -- see header
					wr_idx     <= 10'd0;
					n_entries  <= 11'd0;
					build_busy <= 1'b1;
					st         <= S_A0;
				end
			end

			// Four reads, one address per cycle, each result taken one cycle
			// after its address is presented. The RAM's read latency is spent
			// rather than assumed.
			S_A0: st <= S_A1;
			S_A1: begin w0 <= sr_data; st <= S_A2; end
			S_A2: begin w1 <= sr_data; st <= S_A3; end
			S_A3: begin w2 <= sr_data; st <= S_LAT3; end
			S_LAT3: begin w3 <= sr_data; st <= S_GEOM; end

			// Geometry only -- see the timing note at span_y_r.
			S_GEOM: begin
				span_y_r <= span_y;
				span_x_r <= span_x;
				st       <= S_EVAL;
			end

			S_EVAL: begin
				// The list can hold every record, so the cap can only be hit
				// by a frame in which all 1024 are visible. Guarding on
				// n_entries rather than on wr_idx wrapping keeps the intent
				// obvious and cannot alias at the boundary.
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
