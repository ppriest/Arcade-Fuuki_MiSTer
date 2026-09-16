// CPU pause. The Pause button toggles it; internal holds (ext_pause) OR in as
// a level, so releasing one cannot clear the user's toggle.
//
// PAUSE_BIT follows the .mra <buttons> list: bits 0-3 are directions, then one
// bit per name. scripts/build_mra.py emits
// "Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause" for every game, so
// Pause is bit 10. Unconfirmed on MiSTer; must move if the list changes.

module pause_control #(
	parameter int PAUSE_BIT = 10
) (
	input  logic        clk,
	input  logic        reset,

	input  logic [31:0] joystick_0,
	input  logic [31:0] joystick_1,

	// Level, not a pulse.
	input  logic        ext_pause,

	// CPU only. Video keeps scanning so the display holds sync.
	output logic        pause_cpu,

	// The button's toggle state, for the probe.
	output logic        pause_latched
);

	wire pause_btn = joystick_0[PAUSE_BIT] | joystick_1[PAUSE_BIT];

	logic pause_btn_d;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pause_btn_d   <= 1'b0;
			pause_latched <= 1'b0;
		end else begin
			pause_btn_d <= pause_btn;
			if (pause_btn && !pause_btn_d)
				pause_latched <= ~pause_latched;
		end
	end

	assign pause_cpu = pause_latched | ext_pause;

endmodule
