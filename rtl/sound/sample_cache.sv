// Granule cache with next-granule prefetch for a sample-ROM stream.
//
// Ported from the Psikyo core's adpcma_sample_cache.sv (26-bit addresses
// here, its 25), where it replaced a single-entry bridge on the YM2610's
// ADPCM-A bus. The argument transfers to the OKI M6295 unchanged: its four
// channels are interleaved on one ROM bus, so consecutive fetches belong to
// four different streams and a single cached granule evicts on every fetch.
// The chip's ROM interface is FIXED LATENCY -- jt6295_rom assumes sample
// data has arrived two cen32 ticks after it set the address and does not
// wait -- so a demand miss that crosses the SDRAM's fixed priority chain is
// a wrong nibble, and the ADPCM decoder is predictive, so a wrong nibble
// perturbs the accumulator and the step index for tens of samples.
//
// Two mechanisms:
//
//   ENTRIES granules, fully associative -- each stream keeps its own
//   granule. A stream reads 8 bytes per granule, two nibbles each, so this
//   alone turns most fetches into hits.
//
//   NEXT-GRANULE PREFETCH -- sample addresses walk linearly, so when a stream
//   reads the last byte of its granule the next one is fetched in the
//   background, long before it is wanted. With it, demand misses only happen
//   at a channel's start.
//
// g_addr is driven from a REGISTERED tag captured when the transaction is
// issued, never from the live client address: the chip rotates its address
// between channels regardless of us, and a bridge that tags a fetched
// granule with whatever the address is at completion stores one granule's
// data under another's tag.
//
// req may be HELD until valid or PULSED; S_DRAIN handles both. The request
// is captured on the RISING EDGE of req in every state, so a held req
// presents exactly one edge and cannot re-trigger.
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
	// One comparator array, time-shared: "is the requested granule
	// resident?" in S_IDLE and "is the prefetch target resident?" in S_DRAIN.
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

	// Byte k of a granule is g_data[8*k +: 8]: sdram.sv captures word 0 (the
	// lowest byte address) into bits [15:0] and ascends, and within a word
	// the even byte address is the low half, so a granule is plain
	// little-endian across all eight bytes.
	wire [63:0] serve_word = (st == S_FILL) ? g_data : cdata_q;
	assign data  = serve_word[8*byte_sel +: 8];
	assign valid = (st == S_HIT) || ((st == S_FILL) && g_valid);

	assign g_addr = {fill_tag, 3'b000};
	assign g_req  = (st == S_FILL) || (st == S_PF);

	// Cache data in its own block so Quartus infers an MLAB rather than a
	// 64-bit ENTRIES:1 mux out of logic. The read is registered (S_LOOK).
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
					// Last byte of the granule: the stream is about to cross
					// into the next one.
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

				// Wait for a held req to drop before looking again -- going
				// straight back to S_IDLE would re-latch a still-high req and
				// serve a spurious second read. Then spend the idle time
				// prefetching. `hit` reads pf_tag here.
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

			// After the case, so a req edge arriving on the same cycle
			// S_IDLE consumes the previous capture is kept, not lost.
			req_d <= req;
			if (req && !req_d) begin
				pend      <= 1'b1;
				pend_addr <= addr;
			end
		end
	end

endmodule
