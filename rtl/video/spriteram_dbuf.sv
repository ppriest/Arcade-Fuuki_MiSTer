// Sprite RAM, snapshotted once per frame for the renderer.
//
// The CPU sees one persistent 8 KB RAM (1024 records x 4 words). At
// copy_start, in vblank, all of it is copied into `snap`; the list builder and
// line engine read only `snap` for the following frame. A frame is therefore
// drawn from the sprite RAM as it was at one instant, as MAME's single-pass
// screen_update does. The sprite tile bank travels with the snapshot.
//
// Do not render from the live RAM: the candidate list freezes only the list,
// and per-line re-reads of records the game is rewriting flicker (gogomile
// title).
//
// FG-3 (fuukifg3.cpp screen_vblank) appears to hold sprites two generations
// back. That second generation is not modelled; one snapshot is what can be
// checked against a still frame.
//
// Do not replace the copy with two ping-ponged banks: the CPU's view would
// alternate between two memories, so a record not rewritten every frame reads
// back two frames stale, end-of-list markers and disable bits included
// (LESSONS_LEARNED, "A swap is not a copy"). The copy is 4096 cycles against
// vblank's 120,384.

module spriteram_dbuf (
	input  logic clk,
	input  logic reset,

	input  logic        board,   // BOARD_FG2 / BOARD_FG3, unused: both boards snapshot

	// ---- CPU port (0x600000-0x601FFF) ----
	input  logic [11:0] cpu_addr,
	input  logic        cpu_wel,
	input  logic        cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// ---- tile bank (FG-3, 0xA00000), snapshotted with the sprite data ----
	input  logic [31:0] tilebank_live,
	output logic [31:0] tilebank_render,

	// ---- frame boundary ----
	// Pulse once per frame. copy_busy is held while the snapshot is being
	// taken; the render side must not read across it.
	input  logic        copy_start,
	output logic        copy_busy,

	// ---- render port: what the sprite engine sees ----
	input  logic [11:0] rd_addr,
	output logic [15:0] rd_data
);


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	// Two arrays, each with one write port and one read port. Asking one
	// array for two read addresses plus a write makes Quartus duplicate the
	// whole array silently (LESSONS_LEARNED, "Driving a dual-port RAM's second
	// read port can silently REPLICATE the whole array"). Confirm against
	// `Block Memory Bits` after fitting: 2 x 65,536 bits.
	logic [15:0] live [0:4095];
	logic [15:0] snap  [0:4095];   // the frame's snapshot

	// Declared before the always_ff blocks that assign them, or the tool
	// infers an implicit net and rejects the real declaration.
	logic [11:0] cp_cnt;
	logic        cp_run;
	logic [11:0] cp_wr_addr;
	logic        cp_wr_en;
	logic [15:0] portb_q, buf_q;

	// ---- live: port A = CPU (read/write), port B = the copy engine ----
	always_ff @(posedge clk) begin
		if (cpu_wel) live[cpu_addr][7:0]  <= cpu_wdata[7:0];
		if (cpu_weh) live[cpu_addr][15:8] <= cpu_wdata[15:8];
		cpu_rdata <= live[cpu_addr];
		portb_q   <= live[cp_cnt];
	end

	// ---- snap: written by the copy engine, read by the render port ----
	always_ff @(posedge clk) begin
		buf_q <= snap[rd_addr];
		if (cp_wr_en) snap[cp_wr_addr] <= portb_q;
	end

	// Copy engine: one pass over 4096 words, one read per cycle, written one
	// cycle later to spend the RAM's read latency.
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			cp_cnt          <= 12'd0;
			cp_run          <= 1'b0;
			cp_wr_en        <= 1'b0;
			copy_busy       <= 1'b0;
			tilebank_render <= 32'd0;
		end else begin
			cp_wr_en <= 1'b0;
			if (!cp_run) begin
				if (copy_start) begin
					cp_cnt          <= 12'd0;
					cp_run          <= 1'b1;
					copy_busy       <= 1'b1;
					tilebank_render <= tilebank_live;
				end
			end else begin
				cp_wr_en   <= 1'b1;
				cp_wr_addr <= cp_cnt;
				if (cp_cnt == 12'hFFF) begin
					cp_run    <= 1'b0;
					copy_busy <= 1'b0;
				end else begin
					cp_cnt <= cp_cnt + 12'd1;
				end
			end
		end
	end

	assign rd_data = buf_q;

	// verilator lint_off UNUSED
	wire _unused_board = board;
	// verilator lint_on UNUSED

endmodule
