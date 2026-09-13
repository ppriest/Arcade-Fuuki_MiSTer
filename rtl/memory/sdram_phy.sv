// Single-port wrapper around one of sdram.sv's three physical ports,
// translating its toggle-based req/ack handshake into the project's
// req(pulse while !busy)/valid(pulse)/busy client interface, the same shape
// as ddram_phy.sv.
//
// Two transaction shapes, matching sdram.sv's port contract:
//   READ:  8-byte-aligned granule in (`addr`'s low 3 bits should be 0),
//          full 64-bit `port_dout` out from sdram.sv's burst-4 read.
//   WRITE: one 16-bit word or one byte, see we16.

module sdram_phy (
	input  logic clk,
	input  logic reset,

	// one of sdram.sv's three physical ports
	output logic [25:1] port_addr,
	output logic         port_wrl,
	output logic         port_wrh,
	output logic [15:0] port_din,
	input  logic [63:0] port_dout,
	output logic         port_req,
	input  logic         port_ack,

	// client interface
	input  logic         req,      // pulse: start a transaction (only while !busy)
	input  logic         we,       // 0 = 8-byte-granule burst read, 1 = write
	// 1 = write both byte lanes from wdata[15:0] (addr must be even);
	// 0 = write the single byte wdata[7:0] into the lane addr[0] selects.
	input  logic         we16,
	input  logic [25:0] addr,     // byte offset: 64 MB, the first chip of the 128 MB module
	input  logic [15:0] wdata,    // data to write (we=1 only); see we16
	output logic         busy,     // 1 while a transaction is in flight
	output logic         valid,    // 1-cycle pulse: rdata holds the requested granule (read only)
	output logic [63:0] rdata
);

	typedef enum logic {S_IDLE, S_WAIT} state_t;
	state_t state;

	logic req_toggle;

	assign port_req = req_toggle;
	assign busy      = (state != S_IDLE);
	assign rdata      = port_dout;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state      <= S_IDLE;
			req_toggle <= 1'b0;
			valid      <= 1'b0;
		end else begin
			valid <= 1'b0;
			case (state)
				S_IDLE: begin
					if (req) begin
						port_addr  <= addr[25:1];
						port_wrl   <= we && (we16 || !addr[0]);
						port_wrh   <= we && (we16 ||  addr[0]);
						// byte form replicates so the lane select picks the real one
						port_din   <= we16 ? wdata : {wdata[7:0], wdata[7:0]};
						req_toggle <= ~req_toggle;
						state      <= S_WAIT;
					end
				end

				S_WAIT: begin
					if (port_ack == req_toggle) begin
						if (!we) valid <= 1'b1;
						state <= S_IDLE;
					end
				end

				default: ;
			endcase
		end
	end

endmodule
