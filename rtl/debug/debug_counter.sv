// Debug counter: saturates rather than wrapping, and has no reset.
//
// Saturating, because a wrapped count is ambiguous: 3 could be 65,539.
//
// No reset, so it cannot be cleared by the reset being investigated
// (docs/LESSONS_LEARNED.md, "Never reset a debug counter with the reset
// you are investigating"). Quartus powers registers to zero, so the count
// is what happened since configuration. `clear` comes from the JTAG source
// bus, never from core logic.

module debug_counter #(
	parameter int W = 16
) (
	input  logic         clk,
	input  logic         clear,   // JTAG source bus only
	input  logic         ev,      // count one event per asserted cycle
	output logic [W-1:0] count = '0
);

	// The power-up value is the port initialiser. Do not use an `initial`
	// block: it is a second driver and vlog-7061 rejects it.
	always_ff @(posedge clk) begin
		if (clear)                 count <= '0;
		else if (ev && ~&count)    count <= count + 1'b1;   // saturate at all-ones
	end

endmodule


// Sticky flag: set once an event has happened, until cleared over JTAG.
// Cannot distinguish once from constantly; use a counter if that matters.
module debug_sticky (
	input  logic clk,
	input  logic clear,
	input  logic ev,
	output logic seen = 1'b0
);

	always_ff @(posedge clk) begin
		if (clear)   seen <= 1'b0;
		else if (ev) seen <= 1'b1;
	end

endmodule
