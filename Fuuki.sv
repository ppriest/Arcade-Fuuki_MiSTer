//============================================================================
//
//  Fuuki FG-2 / FG-3 arcade core for MiSTer.
//
//  Copyright (C) 2026 Paul Priest
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details. You should have received a copy of the GNU General Public
//  License along with this program. If not, see <https://www.gnu.org/licenses/>.
//
//============================================================================
//
// Framework glue only. Everything that is actually Fuuki lives in
// rtl/fuuki_core.sv, which is the module sim/ drives; this file wires it to
// hps_io, the PLL, the SDRAM pins and arcade_video, and assembles the input
// port words.
//
// ONE .rbf SERVES BOTH BOARDS, selected at runtime from the .mra's mod byte
// (`<rom index="1">`, arriving as ioctl_index == 1):
//
//     bit 0   0 = FG-2 (M68000)   1 = FG-3 (M68EC020)
//     bit 1   SYSTEM ($800000) layout -- see `sysport_alt` below
//
// NOT IN THIS BUILD, and each is a deliberate omission rather than an
// oversight: sound (Phase 3 -- the Z80, YM2203/YM3812/OKI and the OPL4 are all
// later), HDMI rotation via screen_rotate_two (Fuuki is ROT0, so rotation is a
// convenience, not correctness), and hiscore save. FG-3 will not run until the
// SDRAM controller is widened past 32 MB -- see rtl/memory/fuuki_sdram_top.sv.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// DDR3 is deliberately left unowned. Every memory client here is on SDRAM by
// decision (docs/ROADMAP.md), which is what keeps the rotator's future use of
// DDR3 single-owner -- Psikyo shared DDRAM between its ROM loader and the
// rotator, and the rotator, which has no reset and infers acceptance from
// DDRAM_BUSY, took phantom writes as accepted and left a permanent stale band
// in the frame buffer.
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Silent until Phase 3. AUDIO_S = 0 (unsigned) is the right pairing for a
// constant zero; a signed zero is the same bits, but this says what it means.
assign AUDIO_S   = 0;
assign AUDIO_L   = 0;
assign AUDIO_R   = 0;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Fuuki boards are all ROT0 horizontal, so the original aspect is 4:3 with no
// rotation case to handle. ar != 0 selects Full Screen / ARC1 / ARC2, where a
// zero ARY means "stretch" in the framework's convention.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : 12'({ar} - 2'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Fuuki;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"-;",
	"P1,Debug;",
	"P1-;",
	"P1O[40],Tilemap 0,On,Off;",
	"P1O[41],Tilemap 1,On,Off;",
	"P1O[42],Tilemap 2,On,Off;",
	"P1O[43],Sprites,On,Off;",
	"-;",
	"R[0],Reset;",
	// This list MUST agree with the .mra <buttons> positions, because the
	// .mra is what actually assigns the joystick bits. scripts/build_mra.py
	// pads every game to four button slots with "-" so that Start, Coin and
	// Pause always land on bits 8, 9 and 10 whatever the game's real button
	// count -- which is what lets pause_control.sv hard-code PAUSE_BIT = 10.
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause;",
	"V,v",`BUILD_DATE
};

// Declared ABOVE the instantiation that first uses them. A signal used in a
// port connection before its declaration becomes an implicit 1-bit net, and
// the real declaration is then a second driver -- Quartus reports it as
// "cannot be assigned more than one value" pointing at the DECLARATION, not
// at the use. rtl/cpu/maincpu.sv carries the same note for the same reason.
wire clk_sys, clk_sdram_shifted, pll_locked;

wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 85.909091 MHz = 14.318181 MHz (this hardware's real video crystal, 28.640
// MHz / 2) x 6. Both CPU clock enables land on that grid exactly -- FG-2's
// 16 MHz is 176/945 of it and FG-3's 20 MHz is 220/945 -- which is why
// maincpu.sv uses a Bresenham accumulator and not an integer divide.
//
// outclk_1 is SDRAM_CLK, phase-shifted 180 degrees (5820 ps of the 11641 ps
// period), and drives the pin directly. The PLL is taken unchanged from the
// Psikyo core, where this exact phase is proven on hardware: at 266 degrees
// (tuned for a different controller) that core came up as a frozen pattern
// with the CPU never booting, because commands and read data were latched on
// the wrong edge. Simulation cannot catch it -- the chip model has no notion
// of clock phase.
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// ce_pix: exact 1-in-12 divide to 7.159091 MHz, the pixel clock behind
// 456 x 262 at 59.92 Hz.
reg [3:0] ce_pix_cnt = 0;
wire      ce_pix = (ce_pix_cnt == 0);
always @(posedge clk_sys) ce_pix_cnt <= (ce_pix_cnt == 11) ? 4'd0 : ce_pix_cnt + 4'd1;

///////////////////////   RESET   /////////////////////////////////

// Two domains, and the split is load-bearing -- see rtl/fuuki_core.sv's
// header. `reset` must NOT include ioctl_download, or the SDRAM download FSM
// sits in idle for the entire transfer and nothing is ever written.
wire reset      = RESET | status[0] | buttons[1] | ~pll_locked;
wire core_reset = reset | ioctl_download;

// MiSTer asserts RESET for the WHOLE ROM download, so the memory path gets the
// reset with the download masked out of it. Passing plain `reset` here is what
// made the first bitstream come up as a correct 320x240 raster with every
// pixel black: the download FSM was held in idle for the entire transfer, so
// SDRAM was never written, the CPU never ran, and the palette stayed zero.
// The SDRAM chip's own init sequence is separate again -- it keys off PLL lock
// alone and must not be pulsed by a core reset.
wire sdram_reset = reset & ~ioctl_download;
wire sdram_init  = ~pll_locked;

///////////////////////   BOARD SELECT   //////////////////////////

// Latched from the .mra's index-1 payload and NOT cleared by `reset`, because
// MiSTer holds the core in reset for the whole download -- a mod byte cleared
// by reset would be 0 by the time the game ran, silently selecting FG-2.
reg [7:0] mod_board = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 27'd0) mod_board <= ioctl_dout;
end

wire board_fg3   = mod_board[0];
// bit 1: pbancho PORT_MODIFYs gogomile's SYSTEM port to swap SERVICE1 and
// COIN2, and asurabld happens to use pbancho's arrangement. Two games on one
// board with different input wiring is not something the board-select bit can
// express, so it gets its own.
wire sysport_alt = mod_board[1];

///////////////////////   INPUTS   ////////////////////////////////

// Every port here is IP_ACTIVE_LOW in MAME (0 = pressed) while hps_io's
// joystick words are active HIGH, hence the `~` on the whole concatenation.
//
// MiSTer joystick bit order: 0 = Right, 1 = Left, 2 = Down, 3 = Up, then one
// bit per name in the .mra's <buttons> list -- 4..7 the four button slots,
// 8 Start, 9 Coin, 10 Pause.
//
// P1_P2 ($810000), from fuukifg2.cpp / fuukifg3.cpp INPUT_PORTS_START. FG-2
// wires only BUTTON1 per player; FG-3 adds BUTTON2/3 (and BUTTON4 on the
// ARCADIA review build). Driving all four unconditionally is correct for
// both: FG-2 lists those bits as IPT_UNKNOWN and the .mra names the unused
// slots "-", so nothing can be mapped to them in the first place.
wire [15:0] p1p2_in = ~{
	joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],  // 15..12 P2 B4,B3,B2,B1
	joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],  // 11..8  P2 RIGHT,LEFT,DOWN,UP
	joystick_0[7], joystick_0[6], joystick_0[5], joystick_0[4],  //  7..4  P1 B4,B3,B2,B1
	joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]   //  3..0  P1 RIGHT,LEFT,DOWN,UP
};

// SYSTEM ($800000). The two layouts differ ONLY in bits 1 and 8:
//
//   gogomile          bit 1 = SERVICE1   bit 8 = COIN2
//   pbancho / asura   bit 1 = COIN2      bit 8 = SERVICE1
//
// SERVICE1 (the physical service-credit button) has no joystick slot, so it
// reads as released. Service MODE is reachable regardless -- it is DSW bit 0,
// switchable from the OSD's DIP page, which is what bring-up actually needs.
wire coin1    = joystick_0[9];
wire coin2    = joystick_1[9];
wire start1   = joystick_0[8];
wire start2   = joystick_1[8];
wire service1 = 1'b0;

wire [15:0] system_in = ~{
	7'b0000000,                              // 15..9 IPT_UNKNOWN
	sysport_alt ? service1 : coin2,          //  8
	2'b00,                                   //  7..6 IPT_UNKNOWN
	start2,                                  //  5
	start1,                                  //  4
	2'b00,                                   //  3..2 IPT_UNKNOWN
	sysport_alt ? coin2 : service1,          //  1
	coin1                                    //  0
};

// DIPs arrive on ioctl index 254, byte-addressed, and consume no status bits.
// Byte 0 is bits 7:0 of the first DSW word, byte 1 its 15:8; bytes 2 and 3 are
// FG-3's second DSW at $890000. scripts/build_mra.py emits <switches> in
// exactly that order.
reg [63:0] dip_sw;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;
end

wire [15:0] dsw_in  = dip_sw[15:0];
wire [15:0] dsw2_in = dip_sw[31:16];

///////////////////////   PAUSE   /////////////////////////////////

wire pause_cpu, pause_latched;

pause_control u_pause (
	.clk(clk_sys), .reset(core_reset),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.ext_pause(1'b0),
	.pause_cpu(pause_cpu), .pause_latched(pause_latched)
);

///////////////////////   CORE   //////////////////////////////////

wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_ce;

wire       dbg_frame_start, dbg_line_start, dbg_spr_ovr, dbg_cpu_req, dbg_gfx_req;
wire [20:0] dbg_rom_addr;
wire        dbg_rom_valid;
wire [15:0] dbg_rom_data;
wire       dbg_dl_wr;

fuuki_core u_core (
	.clk(clk_sys), .ce_pix(ce_pix),
	.reset(sdram_reset), .init(sdram_init), .core_reset(core_reset),

	.board_fg3(board_fg3), .sysport_alt(sysport_alt),

	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),

	.system_in(system_in), .p1p2_in(p1p2_in),
	.dsw_in(dsw_in), .dsw2_in(dsw2_in),

	.pause_cpu(pause_cpu),

	// Runtime A/B switches, so a rendering fault can be bisected without a
	// rebuild per step (LESSONS_LEARNED). Menu sense is On,Off, so the
	// enable is the inverse of the status bit.
	.en_l0(~status[40]), .en_l1(~status[41]),
	.en_l2(~status[42]), .en_spr(~status[43]),

	.video_r(core_r), .video_g(core_g), .video_b(core_b),
	.video_hs(core_hs), .video_vs(core_vs),
	.video_hb(core_hb), .video_vb(core_vb),
	.video_ce(core_ce),

	.dbg_frame_start(dbg_frame_start), .dbg_line_start(dbg_line_start),
	.dbg_spr_ovr(dbg_spr_ovr), .dbg_cpu_req(dbg_cpu_req),
	.dbg_gfx_req(dbg_gfx_req), .dbg_rom_addr(dbg_rom_addr),
	.dbg_rom_valid(dbg_rom_valid), .dbg_rom_data(dbg_rom_data),
	.dbg_dl_wr(dbg_dl_wr)
);

///////////////////////   VIDEO   /////////////////////////////////

// CLK_VIDEO and CE_PIXEL are OUTPUTS of arcade_video (it drives CLK_VIDEO
// from its own clk_video input), so they must not be assigned here as well --
// a second driver on CLK_VIDEO propagates back to clk_sys and Quartus reports
// it against the clock, not against this line.
arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(core_ce),

	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hb),
	.VBlank(core_vb),
	.HSync(core_hs),
	.VSync(core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

///////////////////////   JTAG PROBE   ////////////////////////////

// Counters, not a waveform. The bring-up questions are "is anything moving at
// all, and how much" -- frames, scanlines, CPU fetches, graphics fetches --
// and a counter answers those over a serial JTAG link where SignalTap cannot
// even be scripted in Quartus Prime Lite 17.0. See rtl/debug/issp_probe.sv.
//
// The counters are deliberately NOT reset by the core reset, so a value
// survives the reset a failed load causes; source bit 0 clears them.
// scripts/read_issp.tcl decodes this layout and must be kept in step with it:
// a silently shifted field reads as plausible nonsense, not as an error.
wire [7:0] probe_src;
wire       ctr_clear = probe_src[0];

wire [15:0] c_frames, c_lines, c_ovr, c_cpu, c_gfx;
debug_counter #(.W(16)) u_c_frames (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_frame_start), .count(c_frames));
debug_counter #(.W(16)) u_c_lines  (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_line_start),  .count(c_lines));
debug_counter #(.W(16)) u_c_ovr    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_spr_ovr),     .count(c_ovr));
debug_counter #(.W(16)) u_c_cpu    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_cpu_req),     .count(c_cpu));
debug_counter #(.W(16)) u_c_gfx    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_gfx_req),     .count(c_gfx));
// Download writes the arbiter ACCEPTED, which is a different claim from
// "ioctl bytes arrived" (dl_seen below) -- the two disagreeing is exactly the
// signature of a memory path held in reset across the download.
wire [15:0] c_dlwr;
debug_counter #(.W(16)) u_c_dlwr   (.clk(clk_sys), .clear(ctr_clear), .ev(dl_tick),         .count(c_dlwr));

wire dl_seen;
debug_sticky u_dl_seen (.clk(clk_sys), .clear(ctr_clear), .ev(ioctl_wr && ioctl_index == 16'd0), .seen(dl_seen));

// The most recent program fetch, ADDRESS AND DATA CAPTURED AS A PAIR.
//
// The address alone was not enough: it showed the CPU fetching from varied
// places without saying whether what came back was real code. The pair is
// checkable against the ROM image -- gogomile's word 0 must read 0x0040
// (reset SP 0x0040fffc, PC 0x00000400).
//
// The address is latched on the request and only committed when the matching
// data returns, so the two always describe the same fetch.
reg [20:0] pend_rom_addr = '0;
reg [20:0] last_rom_addr = '0;
reg [15:0] last_rom_data = '0;
always @(posedge clk_sys) begin
	if (dbg_cpu_req) pend_rom_addr <= dbg_rom_addr;
	if (dbg_rom_valid) begin
		last_rom_addr <= pend_rom_addr;
		last_rom_data <= dbg_rom_data;
	end
end

// Download writes, PRESCALED BY 256. The plain count saturated a 16-bit
// counter at 65,535 while the full gogomile image needs 9,175,040 word
// writes -- so "saturated" could not tell a complete load from a 0.7% one,
// which is the exact question being asked. 9,175,040 / 256 = 35,840, which
// fits. Expect ~35,840 for a complete FG-2 load.
reg [7:0] dl_pre = 8'd0;
always @(posedge clk_sys) begin
	if (ctr_clear)      dl_pre <= 8'd0;
	else if (dbg_dl_wr) dl_pre <= dl_pre + 8'd1;
end
wire dl_tick = dbg_dl_wr && (dl_pre == 8'd255);

issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_probe (
	.clk(clk_sys),
	.probe({
		7'd0,                // 127..121
		c_dlwr,              // 120..105  download writes accepted
		last_rom_addr,       // 104..84
		board_fg3,           //  83
		pause_latched,       //  82
		ioctl_download,      //  81
		dl_seen,             //  80
		last_rom_data,       //  79..64  what the CPU was actually fed
		c_cpu,               //  63..48
		c_ovr,               //  47..32
		c_lines,             //  31..16
		c_frames             //  15..0
	}),
	.source(probe_src)
);

endmodule
