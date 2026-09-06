// Double-buffered 320-pixel line buffer, used by every layer.
//
// Parameterised on width because the layers carry different payloads:
//   tilemaps  14 bits  { opaque, palette index[12:0] }
//   sprites   16 bits  { opaque, priority[1:0], palette index[12:0] }
// The sprite priority travels with the pixel because the compositor resolves
// sprite-vs-layer with a BIT-INDEXED mask chosen by that priority, per pixel.
//
// Replaces a whole-frame sprite buffer, and the size difference is the
// argument: a 320x240 double-buffered frame at 15 bits is about 2.3 Mbit and
// needs a 76,800-cycle clear every frame, while two 320-entry banks are
// 9.6 kbit -- roughly 240x smaller -- and clear in 320 cycles.
//
// Psikyo shipped the frame-buffer version and retired it, because both of its
// failure modes were structural rather than bugs to fix: the display bank
// toggled MID-SCANOUT and tore the visible line, and the clear overlapped the
// next render pass while the buffer ignored writes, dropping sprites and
// leaving stale pixels. Neither is possible here -- the swap happens in
// hblank, so it cannot tear a visible line, and a bank is cleared while it is
// neither displayed nor rendered into.
//
// Sequencing, all driven from line_start:
//   1. swap banks -- the bank just displayed becomes the render bank
//   2. clear it (320 cycles), holding `ready` low
//   3. raise `ready`; the engine renders the NEXT line into it while the
//      other bank is displayed
//
// The clear is a separate pass rather than clear-on-read because read and
// clear would hit the same address in the same cycle, and inferred RAM's
// read-during-write behaviour is not something to depend on.
//
// Per-line budget: 5,472 clk. The clear is 320 of them, 6%.
//
module line_buffer #(
	parameter int WIDTH = 16
) (
	input  logic clk,
	input  logic reset,

	// One pulse per scanline, in hblank.
	input  logic        line_start,
	output logic        ready,        // render bank cleared, safe to write
	output logic        render_bank_o, // which bank the engine writes into (probe)

	// ---- write port: the sprite engine, rendering the NEXT line ----
	input  logic        we,
	input  logic [8:0]  wx,           // 0..319
	input  logic [WIDTH-1:0] wdata,

	// ---- read port: the compositor, displaying the CURRENT line ----
	input  logic [8:0]  rx,
	output logic [WIDTH-1:0] rdata
);

	localparam int W = 320;

	// Two banks. Each is one write port and one read port -- never two reads
	// plus a write on the same array, which is the shape that makes Quartus
	// silently duplicate a memory.
	logic [WIDTH-1:0] bank0 [0:W-1];
	logic [WIDTH-1:0] bank1 [0:W-1];

	logic        render_bank;      // which bank the engine writes into
	logic [8:0]  clr_x;
	logic        clearing;

	// While clearing, the write port belongs to the clear pass; afterwards it
	// belongs to the engine. The engine is held off by `ready` in the meantime,
	// so the two can never contend.
	wire        wr_en   = clearing ? 1'b1        : we;
	wire [8:0]  wr_x    = clearing ? clr_x       : wx;
	wire [WIDTH-1:0] wr_data = clearing ? {WIDTH{1'b0}} : wdata;

	wire b0_we = wr_en && (render_bank == 1'b0);
	wire b1_we = wr_en && (render_bank == 1'b1);

	// The compositor always reads the bank the engine is NOT writing.
	logic [WIDTH-1:0] b0_q, b1_q;

	always_ff @(posedge clk) begin
		if (b0_we) bank0[wr_x] <= wr_data;
		b0_q <= bank0[rx];
	end

	always_ff @(posedge clk) begin
		if (b1_we) bank1[wr_x] <= wr_data;
		b1_q <= bank1[rx];
	end

	assign rdata = render_bank ? b0_q : b1_q;
	assign render_bank_o = render_bank;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			render_bank <= 1'b0;
			clearing    <= 1'b0;
			clr_x       <= 9'd0;
			ready       <= 1'b0;
		end else if (line_start) begin
			// Swap and start clearing, unconditionally. line_start is a hard
			// resync point: it must NOT be conditional on being idle. Psikyo's
			// first line renderer consumed the pulse only when idle, so an
			// engine still busy at a line boundary ATE it, finished the old
			// line's sprites into the freshly swapped bank, then idled a whole
			// line -- and one overrun corrupted every line below it, giving the
			// "correct at the top, degrading downward" signature.
			render_bank <= ~render_bank;
			clearing    <= 1'b1;
			clr_x       <= 9'd0;
			ready       <= 1'b0;
		end else if (clearing) begin
			if (clr_x == 9'(W - 1)) begin
				clearing <= 1'b0;
				ready    <= 1'b1;
			end else begin
				clr_x <= clr_x + 9'd1;
			end
		end
	end

endmodule
