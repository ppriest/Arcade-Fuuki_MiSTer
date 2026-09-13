// N-way round-robin arbiter onto one sdram_phy port, plus an absolute-priority
// write path for the ROM download.
//
// Client contract: c_req[i] is a level held until c_valid[i] pulses. A
// one-shot pulse arriving while another client is being served is lost.
// One-shot sources (hps_io's ioctl_wr) go through a converter such as
// sdram_download.sv.
//
// Use N = 1 rather than wiring a lone client to the phy: sdram_phy returns
// to idle on its valid cycle and re-samples a still-high request as a second
// transaction. The registered c_valid here gives the client a cycle of margin.
//
// The download write path wins over every read; it is only active while ROM
// loads, before anything is drawn.
//
// This module moves 64-bit granules at 8-byte-aligned addresses and knows
// nothing about regions or widths; narrower clients sit behind
// sdram_narrow_bridge.

module sdram_arbiter #(
	parameter int N = 4
) (
	input  logic clk,
	input  logic reset,

	// ---- physical port (to sdram_phy) ----
	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [25:0]  phy_addr,
	output logic [15:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0]  phy_rdata,

	// ---- read clients, packed ----
	// c_req is a LEVEL held until the matching c_valid pulses.
	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,     // shared; capture it on your own valid

	// ---- download write path, absolute priority ----
	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE} state_t;
	state_t st;

	logic [$clog2(N)-1:0] rr_ptr;    // round-robin start point
	logic [$clog2(N)-1:0] serving;

	// Pending requests: set by a rising edge on c_req, cleared when served.
	// This lets pulse clients and level clients share one arbiter.
	logic [N-1:0] pend, c_req_d;

	logic       have_pick;
	logic [$clog2(N)-1:0] pick;

	// Next pending client at or after rr_ptr, wrapping. An integer loop over
	// N, so the wrap arithmetic cannot overflow a hand-sized counter.
	always_comb begin
		have_pick = 1'b0;
		pick      = rr_ptr;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_ptr) + k) % N;
			if (!have_pick && pend[idx]) begin
				have_pick = 1'b1;
				pick      = ($clog2(N))'(idx);
			end
		end
	end

	// Address slice for the chosen client.
	logic [25:0] pick_addr;
	always_comb begin
		pick_addr = 26'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick)) pick_addr = c_addr[26*k +: 26];
	end

	// Read data is latched on phy_valid. Nothing between sdram.sv's dout and
	// here registers it, and dout0/1/2 are the same register, so c_valid
	// (registered, one cycle after phy_valid) must present a latched copy
	// or the client reads another port's granule.
	logic [63:0] rdata_l;
	assign c_rdata = rdata_l;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st       <= S_IDLE;
			phy_req  <= 1'b0;
			c_valid  <= '0;
			dl_busy  <= 1'b0;
			rr_ptr   <= '0;
			serving  <= '0;
			pend     <= '0;
			c_req_d  <= '0;
		end else begin
			phy_req <= 1'b0;
			c_valid <= '0;

			// Edge capture in every state, so a request arriving mid-service
			// is still recorded.
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			case (st)
			S_IDLE: begin
				if (!phy_busy) begin
					if (dl_req) begin
						phy_req   <= 1'b1;
						phy_we    <= 1'b1;
						phy_we16  <= dl_we16;
						phy_addr  <= dl_addr;
						phy_wdata <= dl_data;
						dl_busy   <= 1'b1;
						st        <= S_WRITE;
					end else if (have_pick) begin
						phy_req  <= 1'b1;
						phy_we   <= 1'b0;
						phy_we16 <= 1'b0;
						phy_addr <= pick_addr;
						serving  <= pick;
						pend[pick] <= 1'b0;
						st       <= S_READ;
					end
				end
			end

			S_READ: begin
				if (phy_valid) begin
					rdata_l <= phy_rdata;
					// c_valid asserts one cycle before this machine is back in
					// idle: the margin against re-sampling a held request.
					c_valid[serving] <= 1'b1;
					rr_ptr <= (int'(serving) == N-1) ? '0
					                                 : ($clog2(N))'(int'(serving) + 1);
					st     <= S_IDLE;
				end
			end

			S_WRITE: begin
				// Writes have no valid; the phy drops busy when done.
				if (!phy_busy) begin
					dl_busy <= 1'b0;
					st      <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
