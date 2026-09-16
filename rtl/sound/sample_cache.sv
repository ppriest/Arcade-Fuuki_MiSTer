// Granule cache with next-granule prefetch for a sample-ROM stream.
// Ported from the Psikyo core's adpcma_sample_cache.sv.
//
// The OKI M6295's four channels are interleaved on one ROM bus, so
// consecutive fetches belong to different streams and a single cached
// granule evicts on every fetch. jt6295_rom assumes the data has arrived
// two cen32 ticks after it set the address and does not wait, so a demand
// miss that goes to SDRAM is a wrong nibble, and the ADPCM decoder carries
// a wrong nibble for tens of samples.
//
// ENTRIES granules, fully associative: each stream keeps its own. When a
// stream reads the last byte of its granule the next one is prefetched, so
// demand misses only happen at a channel's start.
//
// g_addr comes from a tag registered when the transaction is issued, never
// from the live client address: the chip rotates its address between
// channels regardless, and tagging at completion stores one granule's data
// under another's tag.
//
// req may be held until valid or pulsed; it is captured on its rising edge
// in every state, so a held req cannot re-trigger.
module sample_cache #(
	parameter int ENTRIES = 8
) (
	input  logic clk,
	input  logic reset,
	// flush while the backing store is being written (ioctl_download)
	input  logic inval,

	// narrow client side
	input  logic        req,
	input  logic [25:0] addr,      // byte address
	output logic        valid,
	output logic [7:0]  data,

	// granule side (one sdram_arbiter consumer port)
	output logic        g_req,
	output logic [25:0] g_addr,
	input  logic        g_valid,
	input  logic [63:0] g_data
);

	localparam int IW = $clog2(ENTRIES);

	typedef enum logic [2:0] {
		S_IDLE, S_LOOK, S_HIT, S_FILL, S_DRAIN, S_PF
	} state_t;
	state_t st;

	logic [22:0] tag  [0:ENTRIES-1];   // granule address, addr[25:3]
	logic        tval [0:ENTRIES-1];
	logic [63:0] cdata[0:ENTRIES-1];
	logic [63:0] cdata_q;

	logic [IW-1:0] rr;          // round-robin replacement pointer
	logic [IW-1:0] sel_idx;     // entry being read or filled
	logic [2:0]    byte_sel;
	logic [22:0]   fill_tag;    // REGISTERED: what g_addr is asking for

	logic        pf_want;       // this access was a granule's last byte
	logic [22:0] pf_tag;

	logic        req_d;
	logic        pend;
	logic [25:0] pend_addr;

	// ---- fully-associative lookup ----
	// One comparator array, time-shared with the prefetch target in S_DRAIN.
	wire [22:0] look_tag = (st == S_DRAIN) ? pf_tag : pend_addr[25:3];
	logic          hit;
	logic [IW-1:0] hit_idx;
	always_comb begin
		hit     = 1'b0;
		hit_idx = '0;
		for (int i = 0; i < ENTRIES; i++) begin
			if (tval[i] && (tag[i] == look_tag)) begin
				hit     = 1'b1;
				hit_idx = i[IW-1:0];
			end
		end
	end

	// Byte k of a granule is g_data[8*k +: 8]: sdram.sv puts word 0 in
	// bits [15:0] with the even byte in the low half, so a granule is
	// little-endian across all eight bytes.
	wire [63:0] serve_word = (st == S_FILL) ? g_data : cdata_q;
	assign data  = serve_word[8*byte_sel +: 8];
	assign valid = (st == S_HIT) || ((st == S_FILL) && g_valid);

	assign g_addr = {fill_tag, 3'b000};
	assign g_req  = (st == S_FILL) || (st == S_PF);

	// Own block so Quartus infers an MLAB rather than a 64-bit ENTRIES:1 mux
	// out of logic. The read is registered (S_LOOK).
	wire fill_we = ((st == S_FILL) || (st == S_PF)) && g_valid;
	always_ff @(posedge clk) begin
		if (fill_we) cdata[sel_idx] <= g_data;
		cdata_q <= cdata[sel_idx];
	end

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st        <= S_IDLE;
			rr        <= '0;
			pf_want   <= 1'b0;
			req_d     <= 1'b0;
			pend      <= 1'b0;
			pend_addr <= 26'd0;
			for (int i = 0; i < ENTRIES; i++) tval[i] <= 1'b0;
		end else begin
			if (inval) for (int i = 0; i < ENTRIES; i++) tval[i] <= 1'b0;

			case (st)
				S_IDLE: if (pend) begin
					pend     <= 1'b0;
					byte_sel <= pend_addr[2:0];
					// last byte of the granule: prefetch the next one
					pf_want  <= (pend_addr[2:0] == 3'd7);
					pf_tag   <= pend_addr[25:3] + 23'd1;
					if (hit && !inval) begin
						sel_idx <= hit_idx;
						st      <= S_LOOK;
					end else begin
						fill_tag <= pend_addr[25:3];
						sel_idx  <= rr;
						rr       <= rr + 1'b1;
						st       <= S_FILL;
					end
				end

				S_LOOK: st <= S_HIT;      // cdata_q settling

				S_HIT: st <= S_DRAIN;     // valid pulses this cycle

				S_FILL: if (g_valid) begin
					tag[sel_idx]  <= fill_tag;
					tval[sel_idx] <= !inval;
					st            <= S_DRAIN;
				end

				// A held req must drop before the next lookup, or it would be
				// served twice. Then prefetch. `hit` reads pf_tag here.
				S_DRAIN: if (!req) begin
					pf_want <= 1'b0;
					if (pf_want && !hit && !pend) begin
						fill_tag <= pf_tag;
						sel_idx  <= rr;
						rr       <= rr + 1'b1;
						st       <= S_PF;
					end else begin
						st <= S_IDLE;
					end
				end

				S_PF: if (g_valid) begin
					tag[sel_idx]  <= fill_tag;
					tval[sel_idx] <= !inval;
					st            <= S_IDLE;
				end

				default: st <= S_IDLE;
			endcase

			// After the case, so a req edge on the cycle S_IDLE consumes the
			// previous capture is kept.
			req_d <= req;
			if (req && !req_d) begin
				pend      <= 1'b1;
				pend_addr <= addr;
			end
		end
	end

endmodule
