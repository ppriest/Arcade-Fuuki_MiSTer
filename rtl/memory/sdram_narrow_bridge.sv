// Bridges a byte- or word-wide req/valid read port onto one 64-bit-granule
// sdram_arbiter client port. sdram.sv only returns whole 8-byte-aligned
// granules, so every narrow consumer (maincpu's 16-bit fetch, the Z80's
// 8-bit fetch) needs the same fetch-then-slice logic.
//
// Granule cache: the last fetched granule is kept and any request inside it
// is served in one cycle (B_HIT) with no SDRAM transaction. Sequential
// opcode streams hit 3 of 4 (words) or 7 of 8 (bytes). Every cached region
// is ROM, so `inval` (tied to ioctl_download) is the only invalidation.
//
// Layout within a granule, from sdram.sv's read capture: word i (ascending
// byte address) is g_data[16*i +: 16]; within a word the even byte is the
// low half. So word_index = addr[2:1], byte_in_word = addr[0].
//
// Client contract: req may be a one-cycle pulse or a level held until
// valid; `addr` must hold stable until the valid pulse. Toward the arbiter,
// g_req is held until g_valid, one request at a time.

module sdram_narrow_bridge #(
	parameter int WORD_BYTES = 2   // 1 = byte-wide client (Z80), 2 = word-wide (maincpu)
) (
	input  logic clk,
	input  logic reset,

	// flush the granule cache; hold high while the backing store is written
	input  logic inval,

	// narrow client side
	input  logic                     req,
	input  logic [25:0]              addr,    // byte address of the desired unit
	output logic                     valid,
	output logic [8*WORD_BYTES-1:0] data,

	// wide granule side (one sdram_arbiter client port)
	output logic         g_req,
	output logic [25:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	typedef enum logic [1:0] {B_IDLE, B_WAIT, B_HIT, B_DRAIN} bstate_t;
	bstate_t bstate;

	logic [1:0] word_sel;
	logic         byte_sel;

	// ---- granule cache ----
	logic [63:0] cache_data;
	logic [22:0] cache_tag;      // granule address, addr[25:3]
	logic         cache_valid;
	logic [22:0] tag_inflight;   // latched at accept: addr is only stable until valid.
								  // Must be cache_tag's full width or granules above
								  // 32 MB alias onto their low-half twins.

	wire hit = cache_valid && (addr[25:3] == cache_tag);

	assign g_addr = {addr[25:3], 3'b000};   // 8-byte-align down to the granule base
	assign g_req  = (bstate == B_WAIT);

	// B_HIT serves from the cache; B_WAIT serves from the live granule the
	// cycle it arrives (and fills the cache the same cycle).
	logic [15:0] sel_word;
	assign sel_word = (bstate == B_HIT) ? cache_data[16*word_sel +: 16]
										  : g_data[16*word_sel +: 16];

	generate
		if (WORD_BYTES == 1) begin : g_byte
			assign data = byte_sel ? sel_word[15:8] : sel_word[7:0];
		end else begin : g_word
			assign data = sel_word;
		end
	endgenerate

	assign valid = ((bstate == B_WAIT) && g_valid) || (bstate == B_HIT);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bstate       <= B_IDLE;
			cache_valid <= 1'b0;
		end else begin
			if (inval) cache_valid <= 1'b0;

			case (bstate)
				B_IDLE: begin
					if (req) begin
						word_sel <= addr[2:1];
						byte_sel <= addr[0];
						if (hit && !inval) begin
							bstate <= B_HIT;
						end else begin
							tag_inflight <= addr[25:3];
							bstate        <= B_WAIT;
						end
					end
				end
				B_WAIT: begin
					if (g_valid) begin
						if (!inval) begin
							cache_data  <= g_data;
							cache_tag   <= tag_inflight;
							cache_valid <= 1'b1;
						end
						bstate <= B_IDLE;
					end
				end
				B_HIT: begin
					// valid pulses this cycle. B_DRAIN, not B_IDLE: a held-req
					// client drops req the cycle after it sees valid, and a
					// 1-cycle hit would otherwise re-latch it and serve twice.
					bstate <= B_DRAIN;
				end
				B_DRAIN: begin
					if (!req) bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

endmodule
