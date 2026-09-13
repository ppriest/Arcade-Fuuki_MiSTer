// CPU pause. The Pause button toggles it; internal holds (ext_pause) OR in as
// a level, so releasing one cannot clear the user's toggle.
//
// PAUSE_BIT follows the .mra <buttons> list: MiSTer numbers bits 0-3 as the
// directions, then one bit per name in list order. The list is
// "Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause" for every game
// (scripts/build_mra.py pads to four button slots), so Pause is bit 10.
// Not yet confirmed on MiSTer; if the list changes, this must move with it.

module pause_control #(
	parameter int PAUSE_BIT = 10
) (
	input  logic        clk,
	input  logic        reset,

	// Either player's Pause works.
	input  logic [31:0] joystick_0,
	input  logic [31:0] joystick_1,

	// Internal holds, ORed by the caller. A level, not a pulse.
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
