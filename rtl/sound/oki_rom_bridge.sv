// The OKI M6295's ROM bus, turned into one held req/valid fetch at a time.
//
// jt6295's ROM interface is a level: it sets rom_addr and expects rom_data
// for that address, with rom_ok saying the data is there. It rotates
// rom_addr between its four channels' sample pointers and the control
// state machine's phrase-table address every internal slot (~350 clk),
// whether or not we have answered.
//
// The address is registered when the request is issued and the byte stored
// under it; req is the in-flight flag alone, so it falls for at least one
// clock after every valid whatever the chip does with its address. The
// stored byte answers the chip re-presenting that address without a fetch.
//
// Do not tag the fetch with the live rom_addr or derive req from it: an
// address change on the clock edge that registers the valid then leaves
// req high forever, and sample_cache waits in S_DRAIN for req to drop.
// sim/oki_bridge_tb covers this.
module oki_rom_bridge (
	input  logic        clk,
	input  logic        reset,

	// chip side: jt6295's level interface
	input  logic [17:0] rom_addr,
	output logic [7:0]  rom_data,
	output logic        rom_ok,
	input  logic [1:0]  bank,       // oki_banking_w, folded into the address

	// memory side: req is HELD until valid; addr is stable while req is high
	output logic        req,
	output logic [19:0] addr,
	input  logic        valid,
	input  logic [7:0]  data
);

	logic [19:0] hold_addr;     // {bank, rom_addr} the stored byte belongs to
	logic        hold_ok;
	logic [19:0] req_addr;      // {bank, rom_addr} the fetch in flight is for
	logic        in_flight;

	wire [19:0] want_addr = {bank, rom_addr};
	wire        want      = !hold_ok || (want_addr != hold_addr);

	assign req    = in_flight;
	assign addr   = req_addr;
	assign rom_ok = hold_ok && (want_addr == hold_addr);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hold_addr <= 20'd0;
			hold_ok   <= 1'b0;
			req_addr  <= 20'd0;
			in_flight <= 1'b0;
			rom_data  <= 8'd0;
		end else begin
			if (in_flight) begin
				if (valid) begin
					hold_addr <= req_addr;
					rom_data  <= data;
					hold_ok   <= 1'b1;
					in_flight <= 1'b0;
				end
			end else if (want) begin
				req_addr  <= want_addr;
				in_flight <= 1'b1;
			end
		end
	end

endmodule
