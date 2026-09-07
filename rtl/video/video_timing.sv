// Raw video timing for both Fuuki boards, plus the three interrupt sources.
//
// ---------------------------------------------------------------------------
// WHERE THESE NUMBERS COME FROM -- read this before changing any of them.
//
// Neither Fuuki driver calls set_raw(). fuukifg2.cpp and fuukifg3.cpp declare
// only set_refresh_hz(60) and a visible area, so htotal, vtotal and every sync
// position are NOT available from MAME and had to be derived. See
// docs/ROADMAP.md, "Screen timing":
//
//   FG-2's 28.640 MHz XTAL is 2 x 14.318181 MHz, the classic arcade value:
//       pixel clock 28.640 / 4 = 7.16 MHz, htotal 456, vtotal 262 -> 59.92 Hz
//
//   FG-3's parts list transcribes 28.432 MHz. That figure is deliberately NOT
//   used: the two boards share a video ASIC pair, and 28.6432 -> 28.432 is a
//   plausible dropped digit in a transcribed list. BOTH BOARDS USE THIS
//   TIMING, so there is one timing module, one PLL and no per-board switch.
//
// Corroboration, not proof: the level-1 interrupt fires at scanline 248, which
// requires vtotal > 248, and 262 fits with 240 visible lines.
//
// This is also exactly Psikyo's timing, so its PLL ratios and pixel divide
// transfer directly -- ce_pix is clk_sys/12 = 85.909091/12 = 7.159 MHz.
//
// Sync PULSE positions are an RTL design choice, not sourced from MAME, which
// has no opinion on them because it does not drive a CRT: hsync is a 32-pixel
// pulse starting 16 pixels into hblank, vsync a 3-line pulse starting 4 lines
// into vblank. MiSTer's own scaler is what adapts this to a real display.
// ---------------------------------------------------------------------------

module video_timing (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,

	// Programmable raster interrupt line, from video register 0x1c.
	input  logic [8:0] raster_line,
	// How many lines EARLY level 5 fires: 0 = at the hblank of the programmed
	// line, as MAME's timer; 1 or 2 = that many lines before it. A runtime
	// switch, because the band a raster ISR's write lands on is two lines
	// below MAME's (the write is caught at the next hblank and rendered two
	// lines ahead) and which lead is right is a question for the screen.
	input  logic [1:0] raster_lead,

	output logic [8:0] hcnt,          // 0-455
	output logic [8:0] vcnt,          // 0-261

	// The line a fetch started at the NEXT line_start will DISPLAY on.
	//
	// line_start fires at the start of hblank, while vcnt still holds the line
	// just displayed, but what it fetches appears on the following line -- so
	// the tilemap engines must index with vcnt+1, never vcnt.
	//
	// The sprite path needs ONE MORE line of lead than the tilemaps. The
	// tilemap engines latch their row at line_start and display it on the very
	// next line; sprite_line_buffer SWAPS banks at line_start, so a bank filled
	// after one line_start is not displayed until after the NEXT one. Psikyo
	// indexed its sprite render with vcnt+1 and its rows landed one scanline
	// BELOW the tilemaps on MiSTer.
	//
	// Both are wrapped on V_TOTAL before use: a raw vcnt+1 at the last raster
	// line would fetch line 0 as row 262.
	output logic [8:0] vcnt_next,     // vcnt + 1, wrapped -- tilemap fetch row
	output logic [8:0] vcnt_next2,    // vcnt + 2, wrapped -- sprite render row

	output logic h_active,            // hcnt in [0, 319]
	output logic v_active,            // vcnt in [0, 239]
	output logic hblank,
	output logic vblank,
	output logic hsync,
	output logic vsync,

	output logic line_start,          // 1-cycle pulse at the start of hblank
	output logic frame_start,         // 1-cycle pulse on vblank's rising edge

	// Interrupt sources. Each is a ONE-CYCLE pulse; maincpu.sv edge-detects
	// them into a held pending flag that only an acknowledge clears, which is
	// what reproduces MAME's HOLD_LINE. Positions are from fuukitmap.cpp's own
	// timers:
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

	// =====================================================================
	// Width of the raster-line comparator -- SETTLED FROM REAL TRACES.
	//
	// The register at 0x1c is 16 bits, but only some of them can reach a
	// 0..261 line counter. How many is a hardware question MAME cannot
	// answer, so it was measured against captured MAME traces of both games
	// driving real raster effects (debug/, 2026-09-04).
	//
	// gogomile drives an interrupt on EVERY scanline: 240 writes per frame,
	// cycling 240 -> 1 -> 2 -> ... -> 239 -> 240. That usage decides it.
	//
	// With an 8-bit comparator against vtotal = 262, lines 256..261 alias
	// onto 0..5, and the sequence self-destructs:
	//
	//     8-bit:  fires at 240, 257, 258, 259, 260, 261, 6, 7, 8 ...
	//     9-bit:  fires at 240,   1,   2,   3,   4,   5, 6, 7, 8 ...
	//
	// The 8-bit version consumes the values for lines 1-5 during vblank, so
	// the effect loses its first five scanlines, starts at line 6, and takes
	// five spurious interrupts per frame. The 9-bit version reproduces the
	// game's evident intent exactly, one interrupt per line.
	//
	// 9 is therefore the default. Set it to 8 to reproduce the aliasing
	// deliberately (tb_video_timing has a case that pins the difference).
	// =====================================================================
	localparam int RASTER_CMP_BITS = 9;

	// ---- raster counters ----
	// hcnt/vcnt only ADVANCE on ce_pix but hold their value otherwise, matching
	// the framework's ce_pix/CE_PIXEL convention.
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
	// Gated on ce_pix so each fires exactly once per frame, at one raster
	// position, rather than every clk cycle the comparison happens to hold.
	assign irq1_trig = ce_pix && (hcnt == 9'd0) && (vcnt == 9'(IRQ1_LINE));
	assign irq3_trig = ce_pix && (hcnt == 9'd0) && (vcnt == 9'(V_ACTIVE));

	// raster_line arrives from vregs.sv already reduced modulo V_TOTAL, as
	// MAME's time_until_pos() does, so every register value fires exactly
	// once per frame. The first version let out-of-range values (gogomile's
	// parked 0xFFFE) fire nothing, and the game hung waiting for the IRQ5
	// that MAME still delivers -- see the note in vregs.sv.
	wire [8:0] irq5_cmp = (raster_lead == 2'd2) ? vcnt_next2 :
	                      (raster_lead == 2'd1) ? vcnt_next  : vcnt;
	assign irq5_trig = ce_pix && (hcnt == 9'(H_ACTIVE)) &&
	                   (irq5_cmp[RASTER_CMP_BITS-1:0] == raster_line[RASTER_CMP_BITS-1:0]);

endmodule
