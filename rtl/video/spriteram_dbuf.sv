// Sprite RAM with the boards' own frame buffering.
//
// The CPU sees ONE persistent 8 KB RAM (1024 records x 4 words). What the
// renderer sees depends on the board:
//
//   FG-2   the live RAM. MAME draws FG-2 sprites straight from spriteram.
//   FG-3   two generations behind, matching fuukifg3.cpp's screen_vblank():
//              buf[1] = buf[0];  buf[0] = live;
//          and the sprite TILE BANK is delayed by the same two frames, in
//          lockstep, because it is part of the same snapshot.
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
// So the CPU always addresses `live`, and the generations are genuine copies.
// The cost is 8192 cycles per frame against vblank's 120,384 -- 7%.
// ---------------------------------------------------------------------------
//
// FG-2 performs no copy at all and reads `live` directly. That is not a
// shortcut: the per-frame candidate list (sprite_line_list) is itself built
// once in vblank, so it already freezes the display list for the frame. Adding
// a copy underneath it would buy a second generation of delay that the real
// board does not have.

module spriteram_dbuf (
	input  logic clk,
	input  logic reset,

	input  logic        board_fg3,

	// ---- CPU port (0x600000-0x601FFF) ----
	input  logic [11:0] cpu_addr,
	input  logic        cpu_wel,
	input  logic        cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// ---- tile bank (FG-3, 0xA00000), buffered with the sprite data ----
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
	logic [15:0] buf0 [0:4095];
	logic [15:0] buf1 [0:4095];

	// Declared before the always_ff blocks that assign them: using a signal
	// before its declaration makes the tool infer an implicit net and then
	// reject the real one.
	logic [12:0] cp_cnt;
	logic        cp_run;
	logic [11:0] cp_wr_addr;
	logic        cp_wr_en;
	logic        cp_pass_d;
	logic [15:0] buf0_q, portb_q, buf1_q;
	logic [31:0] tilebank_buf0;

	wire [11:0] cp_rd_addr = cp_cnt[11:0];
	wire        cp_pass    = cp_cnt[12];

	// ---- live: port A = CPU (read/write), port B = copy engine OR render ----
	wire [11:0] portb_addr = board_fg3 ? cp_rd_addr : rd_addr;

	always_ff @(posedge clk) begin
		if (cpu_wel) live[cpu_addr][7:0]  <= cpu_wdata[7:0];
		if (cpu_weh) live[cpu_addr][15:8] <= cpu_wdata[15:8];
		cpu_rdata <= live[cpu_addr];
		portb_q   <= live[portb_addr];
	end

	// ---- buf0: read by the copy engine, written by it ----
	always_ff @(posedge clk) begin
		buf0_q <= buf0[cp_rd_addr];
		if (cp_wr_en && cp_pass_d) buf0[cp_wr_addr] <= portb_q;
	end

	// ---- buf1: written by the copy engine, read by the render port ----
	always_ff @(posedge clk) begin
		buf1_q <= buf1[rd_addr];
		if (cp_wr_en && !cp_pass_d) buf1[cp_wr_addr] <= buf0_q;
	end

	// =====================================================================
	// Copy engine: two passes over 4096 words, in this order and no other.
	//
	//   pass 0   buf1 <= buf0     the OLDER generation moves along first
	//   pass 1   buf0 <= live
	//
	// Doing pass 1 first would let this frame's data reach buf1 immediately,
	// collapsing two generations of delay into one -- and the symptom would be
	// sprites arriving a frame early, which is not obviously a bug when you
	// are looking at a moving picture.
	//
	// One read is issued per cycle and written one cycle later, so the RAM's
	// read latency is spent rather than assumed. Reading and writing in the
	// same cycle would store the PREVIOUS address's data (LESSONS_LEARNED,
	// "Give a registered RAM its full read latency before consuming it").
	// =====================================================================
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			cp_cnt          <= 13'd0;
			cp_run          <= 1'b0;
			cp_wr_en        <= 1'b0;
			cp_pass_d       <= 1'b0;
			copy_busy       <= 1'b0;
			tilebank_buf0   <= 32'd0;
			tilebank_render <= 32'd0;
		end else begin
			cp_wr_en <= 1'b0;

			if (!cp_run) begin
				// FG-2 keeps no generations, so nothing is copied and
				// copy_busy never asserts.
				if (copy_start && board_fg3) begin
					cp_cnt    <= 13'd0;
					cp_run    <= 1'b1;
					copy_busy <= 1'b1;
					// The tile bank shifts along with the data it describes.
					tilebank_render <= tilebank_buf0;
					tilebank_buf0   <= tilebank_live;
				end
			end else begin
				// Commit what last cycle's read produced.
				cp_wr_en   <= 1'b1;
				cp_wr_addr <= cp_rd_addr;
				cp_pass_d  <= cp_pass;

				if (cp_cnt == 13'h1FFF) begin
					cp_run    <= 1'b0;
					copy_busy <= 1'b0;
				end else begin
					cp_cnt <= cp_cnt + 13'd1;
				end
			end
		end
	end

	// FG-2 renders from live (through port B), FG-3 from the two-generation
	// copy. Selected combinationally on the registered outputs, so both paths
	// have identical one-cycle read latency.
	assign rd_data = board_fg3 ? buf1_q : portb_q;

endmodule
