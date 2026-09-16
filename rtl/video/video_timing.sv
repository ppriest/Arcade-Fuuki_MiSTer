// Raw video timing for both Fuuki boards, plus the three interrupt sources.
//
// Neither driver calls set_raw(); fuukifg2.cpp and fuukifg3.cpp give only
// set_refresh_hz(60) and a visible area, so htotal, vtotal and sync positions
// are derived (docs/ROADMAP.md, "Screen timing"):
//
//   FG-2's 28.640 MHz XTAL is 2 x 14.318181 MHz: pixel clock 28.640 / 4 =
//   7.16 MHz, htotal 456, vtotal 262, 59.92 Hz.
//
//   FG-3's parts list says 28.432 MHz. Treated as a transcription of 28.6432,
//   since the boards share the video ASIC pair. One timing for both boards,
//   one PLL, no per-board switch.
//
// Corroboration: the level-1 interrupt fires at line 248, so vtotal > 248.
// ce_pix is clk_sys/12 = 85.909091/12 = 7.159 MHz.
//
// Sync pulse positions are an RTL choice, not from MAME: hsync is a 32-pixel
// pulse starting 16 pixels into hblank, vsync a 3-line pulse starting 4 lines
// into vblank.

module video_timing (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,

	// Programmable raster interrupt line, from video register 0x1c. Level 5
	// fires one line before it; see irq5_cmp.
	input  logic [8:0] raster_line,

	output logic [8:0] hcnt,          // 0-455
	output logic [8:0] vcnt,          // 0-261

	// The line a fetch started at the next line_start will display on.
	// line_start fires at the start of hblank with vcnt still the line just
	// displayed, so the tilemap engines fetch vcnt+1. The sprite line buffer
	// swaps banks at line_start, so a bank filled after one line_start is not
	// displayed until after the next: sprites render vcnt+2. Both wrap on
	// V_TOTAL.
	output logic [8:0] vcnt_next,     // vcnt + 1, wrapped: tilemap fetch row
	output logic [8:0] vcnt_next2,    // vcnt + 2, wrapped: sprite render row

	output logic h_active,            // hcnt in [0, 319]
	output logic v_active,            // vcnt in [0, 239]
	output logic hblank,
	output logic vblank,
	output logic hsync,
	output logic vsync,

	output logic line_start,          // 1-cycle pulse at the start of hblank
	output logic frame_start,         // 1-cycle pulse on vblank's rising edge

	// Interrupt sources, one-cycle pulses. maincpu.sv edge-detects them into
	// a held pending flag cleared only by acknowledge (MAME's HOLD_LINE).
	// Positions from fuukitmap.cpp's timers:
	//   level 1  screen().time_until_pos(248)                    -> line 248, x=0
	//   level 3  screen().time_until_vblank_start()              -> line 240, x=0
	//   level 5  screen().time_until_pos(vregs[0x1c], max_x + 1) -> that line,
	//                                                               x = 320
	output logic irq1_trig,
	output logic irq3_trig,
	output logic irq5_trig
);

	localparam int H_TOTAL   = 456;
	localparam int H_ACTIVE  = 320;
	localparam int H_SYNC_ON = H_ACTIVE + 16;   // 336
	localparam int H_SYNC_W  = 32;

	localparam int V_TOTAL   = 262;
	localparam int V_ACTIVE  = 240;
	localparam int V_SYNC_ON = V_ACTIVE + 4;    // 244
	localparam int V_SYNC_W  = 3;

	localparam int IRQ1_LINE = 248;

	// Width of the raster-line comparator. gogomile programs an interrupt on
	// every scanline, cycling 240 -> 1 -> 2 -> ... -> 239 -> 240. An 8-bit
	// compare against vtotal 262 aliases lines 256-261 onto 0-5:
	//
	//     8-bit:  fires at 240, 257, 258, 259, 260, 261, 6, 7, 8 ...
	//     9-bit:  fires at 240,   1,   2,   3,   4,   5, 6, 7, 8 ...
	//
	// losing the effect's first five lines and adding five spurious interrupts
	// a frame (checked against MAME traces in debug/). tb_video_timing pins it.
	localparam int RASTER_CMP_BITS = 9;

	// ---- raster counters ----
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hcnt <= 9'd0;
			vcnt <= 9'd0;
		end else if (ce_pix) begin
			if (hcnt == 9'(H_TOTAL - 1)) begin
				hcnt <= 9'd0;
				vcnt <= (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
			end else begin
				hcnt <= hcnt + 9'd1;
			end
		end
	end

	assign vcnt_next  = (vcnt >= 9'(V_TOTAL - 1)) ? (vcnt - 9'(V_TOTAL - 1))
	                                              : (vcnt + 9'd1);
	assign vcnt_next2 = (vcnt >= 9'(V_TOTAL - 2)) ? (vcnt - 9'(V_TOTAL - 2))
	                                              : (vcnt + 9'd2);

	assign h_active = (hcnt < 9'(H_ACTIVE));
	assign v_active = (vcnt < 9'(V_ACTIVE));
	assign hblank   = ~h_active;
	assign vblank   = ~v_active;

	assign hsync = (hcnt >= 9'(H_SYNC_ON)) && (hcnt < 9'(H_SYNC_ON + H_SYNC_W));
	assign vsync = (vcnt >= 9'(V_SYNC_ON)) && (vcnt < 9'(V_SYNC_ON + V_SYNC_W));

	assign line_start  = ce_pix && (hcnt == 9'(H_ACTIVE));
	assign frame_start = ce_pix && (hcnt == 9'(H_ACTIVE)) && (vcnt == 9'(V_ACTIVE));

	// ---- interrupt sources ----
	// Gated on ce_pix so each fires once per frame at one raster position.
	assign irq1_trig = ce_pix && (hcnt == 9'd0) && (vcnt == 9'(IRQ1_LINE));
	assign irq3_trig = ce_pix && (hcnt == 9'd0) && (vcnt == 9'(V_ACTIVE));

	// raster_line arrives from vregs.sv already reduced as MAME's
	// time_until_pos() reduces it, so every register value fires once a frame.
	//
	// Level 5 fires at the hblank one line before the programmed line, not at
	// that line's own hblank as MAME's timer does: the engines render two lines
	// ahead of the display and a raster ISR's write is caught at the hblank
	// after the interrupt. Measured on gogomile's title clouds
	// (scripts/raster_bands.py):
	//
	//     lead 2 : bands start at 29, 63, 88, 118   (MAME: 30, 64, 89, 119)
	//     lead 1 : bands start at 30, 64, 89, 119   exact
	wire [8:0] irq5_cmp = vcnt_next;
	assign irq5_trig = ce_pix && (hcnt == 9'(H_ACTIVE)) &&
	                   (irq5_cmp[RASTER_CMP_BITS-1:0] == raster_line[RASTER_CMP_BITS-1:0]);

endmodule
