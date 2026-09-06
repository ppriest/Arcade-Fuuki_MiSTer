// Sprite RAM, snapshotted once per frame for the renderer.
//
// The CPU sees ONE persistent 8 KB RAM (1024 records x 4 words). At each
// frame boundary (copy_start, in vblank) the whole of it is copied into
// `snap`, and the sprite line list and line engine read only `snap` for the
// frame that follows. So a frame is drawn from the sprite RAM as it was at
// one instant -- which is what MAME's screen_update does when it draws the
// sprites in one pass -- however the CPU rewrites records during the frame.
//
// The first version rendered FG-2 from the live RAM, on the reading that the
// once-per-frame candidate list already froze the display list. It froze the
// LIST; each scanline then re-read the records themselves from the live RAM
// while the game was rewriting them, so a sprite could change tile or
// position mid-frame, and a record rewritten between the list build and its
// scanline dropped out for a frame. gogomile's title showed it as flicker.
//
// FG-3's hardware appears (fuukifg3.cpp screen_vblank) to hold sprites two
// generations back; that second generation is deliberately NOT modelled --
// the lag MAME shows may be interrupt timing rather than hardware, and one
// snapshot is the behaviour that can be checked against a still frame. The
// sprite tile bank travels with the snapshot it describes.
//
// ---------------------------------------------------------------------------
// A SWAP IS NOT A COPY.
//
// Ping-ponging two banks looks equivalent and is not: under ping-pong the
// CPU's view alternates between two memories, so any record it does not
// rewrite every frame reads back what was written TWO frames ago -- including
// end-of-list markers and disable bits. Psikyo shipped that, and it produced
// ghosting and per-scene sprite freezes that compounded under load. A real
// copy removed both. See LESSONS_LEARNED, "A swap is not a copy".
//
// So the CPU always addresses `live`, and `snap` is a genuine copy: 4096
// cycles per frame against vblank's 120,384.
// ---------------------------------------------------------------------------

module spriteram_dbuf (
	input  logic clk,
	input  logic reset,

	input  logic        board,   // BOARD_FG2 / BOARD_FG3 (both snapshot; kept for the tile bank's home)

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
	// =====================================================================
	// Three arrays of 4096 words, and a strict TWO PORTS EACH budget.
	//
	// A block RAM has one write port and one read port per physical port.
	// Asking one array for two independent READ addresses plus a write is a
	// shape M10K cannot provide, and Quartus satisfies it silently by
	// DUPLICATING the entire array -- 8 KB becomes 16 KB, and a design that
	// fitted yesterday stops fitting (LESSONS_LEARNED, "Driving a dual-port
	// RAM's second read port can silently REPLICATE the whole array").
	//
	// `live` would naturally want three readers: the CPU, the copy engine and
	// FG-2's render path. It gets two, because the copy engine and the render
	// path are MUTUALLY EXCLUSIVE by board -- FG-3 copies and renders from
	// buf1, FG-2 renders from live and never copies -- so one muxed address
	// serves both. Confirm against `Block Memory Bits` after fitting: this
	// module should account for 3 x 65,536 bits and not a bit more.
	// =====================================================================
	logic [15:0] live [0:4095];
	logic [15:0] snap  [0:4095];   // the frame's snapshot

	// Declared before the always_ff blocks that assign them: using a signal
	// before its declaration makes the tool infer an implicit net and then
	// reject the real one.
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

	// Copy engine: one pass over 4096 words. One read is issued per cycle and
	// written one cycle later, so the RAM's read latency is spent rather than
	// assumed (LESSONS_LEARNED, "Give a registered RAM its full read latency
	// before consuming it").
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
