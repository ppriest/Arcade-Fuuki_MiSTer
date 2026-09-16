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
// Framework glue only. Everything Fuuki lives in rtl/fuuki_core.sv, the
// module sim/ drives; this file wires it to hps_io, the PLL, the SDRAM pins
// and the video chain, and assembles the input port words.
//
// One .rbf serves both boards, selected from the .mra's mod byte
// (`<rom index="1">`, ioctl_index == 1):
//     bit 0   0 = FG-2 (M68000)   1 = FG-3 (M68EC020)
//     bit 1   SYSTEM ($800000) layout, see `sysport_alt`
//
// Video: crt_vsize -> crt_adjust -> arcade_video -> video_freak, with
// screen_rotate_two tapping the output into a rotated HDMI framebuffer.
// No hiscore save.

module emu
(
	`include "sys/emu_ports.vh"
);


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Signed. FG-2 mono to both channels; FG-3's OPL4 is stereo.
wire signed [15:0] core_audio_l, core_audio_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = core_audio_l;
assign AUDIO_R   = core_audio_r;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// All Fuuki games are ROT0: 4:3, or 3:4 once rotated. ARY 0 means "stretch"
// to video_freak.
wire [1:0] ar = status[122:121];
wire [1:0] rotate_sel = status[64:63];
wire       rotate_en  = |rotate_sel;
wire       rotate_ccw = (rotate_sel == 2'd2);
wire       flip_180   = status[65];
wire [11:0] base_arx = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : 12'({ar} - 2'd1);
wire [11:0] base_ary = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

// Required output once MISTER_FB is enabled; the rotator needs no blanking.
assign FB_FORCE_BLANK = 0;

`include "build_id.v"

// ---------------------------------------------------------------------------
// Debug build or release. The Fuuki_stp revision defines DEBUG_ISSP; Fuuki
// does not. In the release: every H1-prefixed OSD line (the Debug page) is
// hidden by status_menumask bit 1, the status bits behind them are forced
// off so a debug .CFG cannot hide a layer, and the JTAG probe compiles out
// with everything that only fed it.
// ---------------------------------------------------------------------------
`ifdef DEBUG_ISSP
localparam DEBUG_BUILD = 1'b1;
`else
localparam DEBUG_BUILD = 1'b0;
`endif
wire debug_menu_hide = ~DEBUG_BUILD;

localparam CONF_STR = {
	"Fuuki;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[64:63],Rotation,Off,CW,CCW;",
	"O[65],Flip 180,Off,On;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"O[70:69],Vertical crop,Disabled,216p (5x),224p;",
	"O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[76],CRT Adjust,Off,On;",
	"H2O[96:92],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[83:77],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[89:84],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[100:97],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[101],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"O[103:102],Audio mix,Mono,None,25%,50%;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[40],Tilemap 0,On,Off;",
	"H1P1O[41],Tilemap 1,On,Off;",
	"H1P1O[42],Tilemap 2,On,Off;",
	"H1P1O[43],Sprites,On,Off;",
	"H1P1-;",
	"H1P1O[50],Trace overlay,Off,On;",
	"H1P1O[52:51],Trace source,Download addr,CPU FC+addr,CPU data+addr,SDRAM dump;",
	"H1P1O[56:53],Trace window,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"H1P1O[57],Trace mode,First N,Ring (latest);",
	"H1P1O[58],Re-arm capture,A,B;",
	"H1P1O[59],Ring trigger,Off,Vector 2-4 read;",
	"H1P1O[60],Line markers,Off,On;",
	"-;",
	"R[0],Reset;",
	// Must match the .mra <buttons> list, which assigns the joystick bits
	// (see INPUTS and pause_control.sv's PAUSE_BIT).
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause;",
	"V,v",`BUILD_DATE
};

// Declared before first use: a signal first seen in a port connection becomes
// an implicit 1-bit net and the later declaration a second driver.
wire clk_sys, clk_sdram_shifted, pll_locked;
wire        ldr_active, ldr_req, ldr_we16, ldr_busy;
wire [25:0] ldr_addr;
wire [15:0] ldr_data;
wire [31:0] probe_src;  // ISSP source bits: [7:0] controls (see the PLL block), [31:8] memory-dump {region, page}

wire        forced_scandoubler;
wire [21:0] gamma_bus;
// Gamma is forced off under the debug overlay: the framework's gamma LUT is
// applied before the scaler and screenshots and remaps trace pixels. Bit 19
// is gamma_en (sys/gamma_corr.sv); bit 21 is driven back by the consumer.
wire [21:0] gamma_bus_video;
assign gamma_bus_video[20:0] = {gamma_bus[20], gamma_bus[19] & ~status[50], gamma_bus[18:0]};
assign gamma_bus[21]         = gamma_bus_video[21];
wire  [1:0] buttons;
// Debug settings (layer masks [43:40], trace [60:50]) read as zero in the
// release whatever the .CFG holds.
localparam [127:0] DEBUG_STATUS_MASK = (128'hF << 40) | (128'h7FF << 50);
wire [127:0] status_raw;
wire [127:0] status = DEBUG_BUILD ? status_raw : (status_raw & ~DEBUG_STATUS_MASK);

// Both boards drive one speaker (fuukifg2.cpp / fuukifg3.cpp), so the
// default, status value 0, is mono. OSD order: Mono, None, 25%, 50%.
wire [1:0] audio_mix_sel = status[103:102];
assign AUDIO_MIX = (audio_mix_sel == 2'd0) ? 2'd3 : audio_mix_sel - 2'd1;
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
	.status(status_raw),
	.status_menumask({13'd0, ~status[76], debug_menu_hide, 1'b0}),   // H1: the Debug page; H2: CRT Adjust's settings while it is off

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

// 85.909091 MHz = 14.318181 MHz (video crystal 28.640 / 2) x 6; the CPU rates
// are exact fractions of it (maincpu.sv).
// outclk_1 is SDRAM_CLK, shifted 180 degrees (5820 ps of 11641). PLL taken
// unchanged from the Psikyo core. Simulation cannot check the phase (the chip
// model ignores it); a wrong phase (266 degrees) shows on MiSTer as a frozen
// pattern.
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked),
	.reconfig_to_pll(rcfg_to_pll),
	.reconfig_from_pll(rcfg_from_pll)
);

// ---------------------------------------------------------------------------
// SDRAM_CLK phase stepping through pll_cfg, clocked from CLK_50M so it runs
// whatever the PLL does. Register 6 (dynamic phase shift) moves counter 3
// (C1, SDRAM_CLK) by N steps of VCO/8, ~132 ps at VCO 945 MHz. Disabled:
// dps_up / dps_dn are tied to 0.
//
// ISSP source bits [7:0]:
//     bit 0     clear the debug counters
//     bit 1     DUMP NOW (see the core instance)
//     bit 2     free
//     bits 7,4,3 which 40-entry page of the trace buffer the overlay shows (0-6)
//     bit 5     pause the CPU
//     bit 6     toggles the walker / tracer re-arm
// ---------------------------------------------------------------------------
wire [63:0] rcfg_to_pll, rcfg_from_pll;

reg [7:0] psrc_s1 = 8'd0, psrc_s2 = 8'd0, psrc_d = 8'd0;
always @(posedge CLK_50M) begin
	psrc_s1 <= probe_src[7:0];
	psrc_s2 <= psrc_s1;
	psrc_d  <= psrc_s2;
end
wire        dps_up   = 1'b0;
wire        dps_dn   = 1'b0;
wire [15:0] dps_n    = 16'd8;   // ~1 ns per command

reg         cfg_write = 1'b0;
reg  [5:0]  cfg_addr  = 6'd0;
reg  [31:0] cfg_data  = 32'd0;
wire        cfg_wait;
reg  signed [15:0] phase_pos = 16'sd0;

always @(posedge CLK_50M) begin
	cfg_write <= 1'b0;
	if (!cfg_wait && !cfg_write && (dps_up | dps_dn)) begin
		cfg_write <= 1'b1;
		cfg_addr  <= 6'd6;                                  // DPS_REG
		cfg_data  <= {10'd0, dps_up, 5'd3, dps_n};          // [21] up, [20:16] C1, [15:0] steps
		phase_pos <= dps_up ? phase_pos + $signed(dps_n) : phase_pos - $signed(dps_n);
	end
end

pll_cfg u_pll_cfg (
	.mgmt_clk(CLK_50M),
	.mgmt_reset(~pll_locked),
	.mgmt_waitrequest(cfg_wait),
	.mgmt_read(1'b0),
	.mgmt_write(cfg_write),
	.mgmt_readdata(),
	.mgmt_address(cfg_addr),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(rcfg_to_pll),
	.reconfig_from_pll(rcfg_from_pll)
);

assign SDRAM_CLK = clk_sdram_shifted;

// ce_pix: exact 1-in-12 divide to 7.159091 MHz, the pixel clock behind
// 456 x 262 at 59.92 Hz.
reg [3:0] ce_pix_cnt = 0;
wire      ce_pix = (ce_pix_cnt == 0);
always @(posedge clk_sys) ce_pix_cnt <= (ce_pix_cnt == 11) ? 4'd0 : ce_pix_cnt + 4'd1;

///////////////////////   RESET   /////////////////////////////////

// Reset domains: see rtl/fuuki_core.sv's header.
wire reset      = RESET | status[0] | buttons[1] | ~pll_locked;

// Hold the CPU and video in reset until the ROM has been loaded once: MiSTer
// asserts RESET only when the .mra load begins, and before that SDRAM holds
// garbage. rom_loaded is sticky: set when the first index-0 transfer ends
// (byte path) or the loader's copy ends (fast path, no ioctl_wr pulses).
reg rom_loaded = 1'b0, dl_index0_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0) dl_index0_seen <= 1'b1;
	if (dl_index0_seen && !ioctl_download) rom_loaded     <= 1'b1;
	if (ldr_active_d && !ldr_active)       rom_loaded     <= 1'b1;
end

// ldr_active is in core_reset, not in `reset`: `reset` resets the loader
// itself.
wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active;

// The memory path is reset by PLL lock only. `reset` is held for the whole
// download, so the download FSM would write nothing. `reset & ~ioctl_download`
// pulses the phy's reset at each download edge, and a request whose req
// toggle crosses that reset is acknowledged but not performed (a dropped
// write). No runtime reset is needed: the FSM and arbiters return to idle,
// the bridge cache is invalidated per download (`inval`), and the FPGA is
// reconfigured on every .mra launch.
wire sdram_reset = ~pll_locked;
wire sdram_init  = ~pll_locked;

///////////////////////   BOARD SELECT   //////////////////////////

// Latched from the .mra's index-1 payload and not cleared by `reset`: MiSTer
// holds reset for the whole download, so a cleared mod byte would select
// FG-2.
reg [7:0] mod_board = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 27'd0) mod_board <= ioctl_dout;
end

wire board = mod_board[0];   // BOARD_FG2 / BOARD_FG3
// bit 1: pbancho's PORT_MODIFY of gogomile's SYSTEM port swaps SERVICE1 and
// COIN2, and asurabld uses pbancho's arrangement.
wire sysport_alt = mod_board[1];

///////////////////////   INPUTS   ////////////////////////////////

// Every port is IP_ACTIVE_LOW in MAME; hps_io's joysticks are active high,
// hence the `~`. Joystick bits: 0 Right, 1 Left, 2 Down, 3 Up, then one per
// name in the .mra <buttons> list: 4..7 the four button slots, 8 Start,
// 9 Coin, 10 Pause.
//
// P1_P2 ($810000), from fuukifg2.cpp / fuukifg3.cpp INPUT_PORTS_START. FG-2
// wires only BUTTON1 per player; driving all four is harmless there since
// FG-2 reads those bits as IPT_UNKNOWN and the .mra names the slots "-".
wire [15:0] p1p2_in = ~{
	joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],  // 15..12 P2 B4,B3,B2,B1
	joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],  // 11..8  P2 RIGHT,LEFT,DOWN,UP
	joystick_0[7], joystick_0[6], joystick_0[5], joystick_0[4],  //  7..4  P1 B4,B3,B2,B1
	joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]   //  3..0  P1 RIGHT,LEFT,DOWN,UP
};

// SYSTEM ($800000). The two layouts differ only in bits 1 and 8:
//   gogomile          bit 1 = SERVICE1   bit 8 = COIN2
//   pbancho / asura   bit 1 = COIN2      bit 8 = SERVICE1
// SERVICE1 has no joystick slot; service mode is DSW bit 0.
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

// DIPs arrive on ioctl index 254, byte-addressed. Bytes 0-1 are the first
// DSW word, bytes 2-3 FG-3's second DSW at $890000; scripts/build_mra.py
// emits <switches> in that order.
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
	// JTAG pause (source bit 5): in ring mode the trace freezes on the last
	// 256 accesses before it (scripts/boot_trace.py --hang).
	.ext_pause(probe_src[5]),
	.pause_cpu(pause_cpu), .pause_latched(pause_latched)
);

///////////////////////   CORE   //////////////////////////////////

wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_ce;

wire       dbg_frame_start, dbg_line_start, dbg_spr_ovr, dbg_cpu_req, dbg_gfx_req;
wire [20:0] dbg_rom_addr;
wire        dbg_rom_valid;
wire        dbg_frozen;
wire [15:0] dbg_rom_data;
wire        dbg_dl_wr;
wire [25:0] dbg_dl_addr;

// ---------------------------------------------------------------------------
// Fast ROM loading. scripts/build_mra.py puts address="0x30000000" on
// <rom index="0">, so the HPS copies the ROM into DDR3 and the core sees
// ioctl_download with no ioctl_wr pulses; rom_loader then copies DDR3 ->
// SDRAM with the core in reset. An .mra without the attribute streams
// through ioctl (scripts/sdram_pattern_test.py relies on it); the paths are
// told apart by whether any byte arrived during the download.
// ---------------------------------------------------------------------------
reg  dl_active_d = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0;
reg  ldr_done    = 1'b0, dl_seen_wr  = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);

always @(posedge clk_sys) begin
	ldr_start   <= 1'b0;
	dl_active_d <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;   // a new index-0 load begins
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;   // ...and it is streaming bytes

	// A new index-0 download is the only thing that makes a copy due again.
	if (dl_index0 && !dl_active_d) ldr_done <= 1'b0;

	if (reset) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		// Only when the ROM did not come by the byte path, and once per
		// download: without ldr_done every later reset would recopy the map.
		if (!dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;

rom_loader u_rom_loader (
	.clk(clk_sys), .reset(reset),
	// FG-2's map ends at 0x1180000, FG-3's at 0x3880000: the FG2_BASE_* /
	// FG3_BASE_* tables in rtl/memory/fuuki_sdram_top.sv.
	.length(board ? 28'h3880000 : 28'h1180000),
	.start(ldr_start), .busy(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.dl_req(ldr_req), .dl_addr(ldr_addr), .dl_data(ldr_data),
	.dl_we16(ldr_we16), .dl_busy(ldr_busy)
);

// The loader's side of the DDR3 mux (see "HDMI ROTATION").
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

fuuki_core u_core (
	.clk(clk_sys), .ce_pix(ce_pix),
	.reset(sdram_reset), .init(sdram_init), .core_reset(core_reset),

	.board(board), .sysport_alt(sysport_alt),

	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),

	.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
	.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),

	.system_in(system_in), .p1p2_in(p1p2_in),
	.dsw_in(dsw_in), .dsw2_in(dsw2_in),

	.pause_cpu(pause_cpu),

	// Menu sense is On,Off, so the enable is the inverted status bit.
	.en_l0(~status[40]), .en_l1(~status[41]),
	.en_l2(~status[42]), .en_spr(~status[43]),

	.video_r(core_r), .video_g(core_g), .video_b(core_b),
	.video_hs(core_hs), .video_vs(core_vs),
	.video_hb(core_hb), .video_vb(core_vb),
	.video_ce(core_ce),
	.audio_l(core_audio_l), .audio_r(core_audio_r),

	.dbg_frame_start(dbg_frame_start), .dbg_line_start(dbg_line_start),
	.dbg_spr_ovr(dbg_spr_ovr), .dbg_cpu_req(dbg_cpu_req),
	.dbg_gfx_req(dbg_gfx_req), .dbg_rom_addr(dbg_rom_addr),
	.dbg_rom_valid(dbg_rom_valid), .dbg_rom_data(dbg_rom_data),
	.dbg_dl_wr(dbg_dl_wr), .dbg_dl_addr(dbg_dl_addr),

	// JTAG source bit 1 = DUMP NOW: forces the overlay on and the walker
	// (source 3, which pauses the CPU) selected, for scripts/memdump.py --live.
	.dbg_overlay(status[50] | probe_src[1]), .dbg_src(probe_src[1] ? 2'd3 : status[52:51]),
	.dbg_window(status[56:53]), .dbg_ring(status[57]),
	.dbg_rearm(status[58] ^ probe_src[6]), .dbg_page({probe_src[7], probe_src[4:3]}),
	.dbg_trig(status[59]), .dbg_dump(probe_src[31:8]),
	.dbg_marker(status[60]),
	.dbg_irq_pending(dbg_irq_pending), .dbg_iack(dbg_iack), .dbg_iack_level(dbg_iack_level),
	.dbg_irq1_trig(dbg_irq1_trig), .dbg_smp(dbg_smp),
	.dbg_tm_ovr(dbg_tm_ovr), .dbg_tm_max(dbg_tm_max), .dbg_spr_max(dbg_spr_max),
	.dbg_opl4_state(dbg_opl4_state),
	.dbg_z80_m1(dbg_z80_m1), .dbg_ym_wr(dbg_ym_wr),
	.dbg_snd_int(dbg_snd_int), .dbg_snd_state(dbg_snd_state),
	.dbg_clear(probe_src[0]), .dbg_fg2_chips(dbg_fg2_chips),
	.dbg_fg2_oki(dbg_fg2_oki), .dbg_fg2_z80(dbg_fg2_z80), .dbg_fg2_cmd(dbg_fg2_cmd), .dbg_fg2_cmd_hist(dbg_fg2_cmd_hist), .dbg_fg2_cmd_frz(dbg_fg2_cmd_frz),
	.dbg_pcm_keyon(dbg_pcm_keyon), .dbg_fm_keyon(dbg_fm_keyon),
	.dbg_frozen(dbg_frozen)
);

///////////////////////   VIDEO   /////////////////////////////////

// CLK_VIDEO and CE_PIXEL are driven by arcade_video; do not assign them here.
//
// ---- CRT Adjust (rtl/video/crt_vsize.sv, rtl/video/crt_adjust.sv) ----
// Vendored from Arcade-Raiden_MiSTer and wired as Raiden.sv wires them. Sync
// stays native in position, so a CRT keeps lock while adjusting.
// H-Position's OSD index covers 97 entries (0, +1..+48, -48..-1), so the
// negative half wraps at 97. V-Shift and the sizes are two's complement.
// The sizes retime the core's pixel enable and do not survive the
// scandoubler, so both are forced to 0 while it is on.
wire crt_adj_on   = status[76];
wire scandoubled  = (status[46:44] != 3'd0) | forced_scandoubler;
wire crt_size_en  = crt_adj_on & ~scandoubled;
wire  [6:0] crt_hpos_idx = crt_adj_on ? status[83:77] : 7'd0;
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48)
	? $signed({2'b00, crt_hpos_idx})
	: $signed({2'b00, crt_hpos_idx}) - 9'sd97;
wire signed [5:0] crt_voffset = crt_adj_on ? $signed(status[89:84]) : 6'sd0;

// One OSD step of V-Size is 3 lines; negated so "+" is taller.
reg signed [4:0] crt_hsize = 5'sd0;
reg signed [5:0] crt_vsize = 6'sd0;
reg              crt_vsmode = 1'b0;
wire signed [5:0] crt_vsz_step = $signed({{2{status[100]}}, status[100:97]});
always @(posedge clk_sys) if (core_ce) begin
	crt_hsize  <= crt_size_en ? $signed(status[96:92]) : 5'sd0;
	crt_vsize  <= crt_size_en ? -(crt_vsz_step + (crt_vsz_step <<< 1)) : 6'sd0;
	crt_vsmode <= status[101];
end

// V-Size ring: 52 lines of 320 pixels covers |vsize| <= 24, the OSD's +-8 x 3.
wire [7:0] vz_r, vz_g, vz_b;
wire       vz_hs, vz_vs, vz_de, vz_vb, vz_ce;
crt_vsize #(.RING_LINES(52), .LINE_PX(320)) u_crt_vsize (
	.clk(clk_sys), .pxl_cen(core_ce),
	.active(crt_adj_on), .tube_mode(crt_vsmode), .vsize(crt_vsize),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .de_in(~(core_hb | core_vb)), .vb_in(core_vb),
	.r_out(vz_r), .g_out(vz_g), .b_out(vz_b),
	.hs_out(vz_hs), .vs_out(vz_vs), .de_out(vz_de), .vb_out(vz_vb),
	.ce_out(vz_ce)
);

// H-Size read enable: 12 clk per pixel is 48 quarter-clocks, so a step is
// 1/48 of the width. The accumulator restarts on crt_adjust's hs_ref_out,
// never on the raw HSync: the module's read counter restarts on that edge.
wire hs_ref;
reg  hs_ref_d = 1'b0;
always @(posedge clk_sys) hs_ref_d <= hs_ref;
wire hs_ref_rise = hs_ref & ~hs_ref_d;
wire [7:0] rd_period = 8'd48 + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] rd_acc = 8'd0;
wire rd_tick = (rd_acc + 8'd4) >= {1'b0, rd_period};
always @(posedge clk_sys) begin
	if      (hs_ref_rise) rd_acc <= 8'd0;
	else if (rd_tick)     rd_acc <= rd_acc + 8'd4 - {1'b0, rd_period};
	else                  rd_acc <= rd_acc + 8'd4;
end
wire rd_ce  = (crt_hsize == 5'sd0) ? vz_ce : rd_tick;
wire crt_ce = crt_adj_on ? rd_ce : core_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_adjust #(
	.VTOTAL(262), .HTOTAL(456),
	// CONTENTSHIFT keeps HSync byte-for-byte native; SYNCSHIFT moves the sync.
	.HPOS_MODE(1)
) u_crt_adjust (
	.clk(clk_sys), .pxl_cen(vz_ce), .pxl2_cen(rd_ce),
	.active(crt_adj_on), .hsize(crt_hsize),
	.hoffset(crt_hoffset), .voffset(crt_voffset),
	.r_in(vz_r), .g_in(vz_g), .b_in(vz_b),
	.hs_in(vz_hs), .vs_in(vz_vs), .hb_in(~vz_de), .vb_in(vz_vb),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb),
	.hs_ref_out(hs_ref)
);

wire vga_de_raw;

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),

	.RGB_in({crt_r, crt_g, crt_b}),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus_video)
);

// ---- crop, integer scaling, aspect (sys/video_freak.sv) ----
// CROP_SIZE is the number of lines kept out of 240: 216 is exactly 5x on a
// 1080-line display, 224 trims 8 lines top and bottom.
wire [1:0] vcrop_sel = status[70:69];
wire [11:0] crop_size = (vcrop_sel == 2'd1) ? 12'd216 :
	                    (vcrop_sel == 2'd2) ? 12'd224 : 12'd0;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX(base_arx),
	.ARY(base_ary),
	.CROP_SIZE(crop_size),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// ---- HDMI rotation and flip (rtl/video/screen_rotate_two.sv) ----
// A tap: the analog output keeps the native raster; a rotated or flipped copy
// goes to the HPS framebuffer via DDR3. The DIP "Flip Screen" (which both MAME
// drivers get wrong) stays commented out of the .mra files.
// DDR3 is muxed with the ROM loader on ldr_active, not shared: the rotator
// has no reset and infers acceptance from DDRAM_BUSY, so it would take the
// loader's transactions as its own writes and leave a stale band in the
// frame. DDRAM_BUSY is held high for the loader's whole run.
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(flip_180),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

///////////////////////   JTAG PROBE   ////////////////////////////

// Counters, not a waveform (rtl/debug/issp_probe.sv). Not reset by the core
// reset, so a value survives the reset a failed load causes; source bit 0
// clears them. scripts/read_issp.tcl decodes this layout and must be kept in
// step with it: a shifted field reads as plausible nonsense.
wire       ctr_clear = probe_src[0];

// Interrupt state for a hung game: irq1 generated, stuck pending, or taken.
wire [2:0] dbg_irq_pending, dbg_iack_level;
wire       dbg_iack, dbg_irq1_trig;
wire [15:0] dbg_smp;   // sample fetch watch, see fuuki_core.sv
wire [2:0]  dbg_tm_ovr;  wire [12:0] dbg_tm_max, dbg_spr_max;   // render overrun watch
wire [7:0]  dbg_opl4_state;  // {0, new2, mix_pcm}: what can silence PCM
wire        dbg_z80_m1, dbg_ym_wr, dbg_pcm_keyon, dbg_fm_keyon;
wire        dbg_snd_int;           // sound CPU INT falling edges
wire [3:0]  dbg_snd_state;         // {halt_n, rom_wait, int_n, nmi_n}
wire [151:0] dbg_fg2_chips;        // fg2_sound.sv per-chip probe, read as instance S
wire [87:0]  dbg_fg2_oki;          // fg2_sound.sv phrase-start probe, instance S above the chips
wire [95:0]  dbg_fg2_z80;          // fg2_sound.sv Z80 probe, instance S above the OKI probe
wire [143:0] dbg_fg2_cmd;
wire [255:0] dbg_fg2_cmd_hist;
wire [327:0] dbg_fg2_cmd_frz;          // fg2_sound.sv command transport probe, top of instance S

// Which input of core_reset rises: rising edges of each, counted on clk_sys,
// and every assertion of core_reset itself long enough to clock a flop.
reg  [6:0] rsrc_d = 7'd0;
wire [6:0] rsrc = {RESET, status[0], buttons[1], ~pll_locked, ioctl_download, ~rom_loaded, ldr_active};
reg  [7:0] c_rsrc [0:6];
initial for (int i = 0; i < 7; i++) c_rsrc[i] = 8'd0;
always @(posedge clk_sys) begin
	rsrc_d <= rsrc;
	for (int i = 0; i < 7; i++)
		if (ctr_clear) c_rsrc[i] <= 8'd0;
		else if (rsrc[i] && !rsrc_d[i] && ~&c_rsrc[i]) c_rsrc[i] <= c_rsrc[i] + 8'd1;
end
reg [7:0] c_core_reset_async = 8'd0;
always @(posedge core_reset) c_core_reset_async <= c_core_reset_async + 8'd1;
reg  [7:0] c_irq1  = 8'd0;   // irq1_trig pulses (one per frame when healthy)
reg  [4:0] c_iack1 = 5'd0;   // level-1 acknowledge cycles
reg        iack_d  = 1'b0;
always @(posedge clk_sys) begin
	iack_d <= dbg_iack;
	if (ctr_clear) begin
		c_irq1 <= 8'd0; c_iack1 <= 5'd0;
	end else begin
		if (dbg_irq1_trig) c_irq1 <= c_irq1 + 8'd1;
		if (dbg_iack && !iack_d && dbg_iack_level == 3'd1) c_iack1 <= c_iack1 + 5'd1;
	end
end

wire [15:0] c_frames, c_ovr, c_gfx;
debug_counter #(.W(16)) u_c_frames (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_frame_start), .count(c_frames));
// core_reset rising edges: tells a CPU taking exceptions from one being
// reset. No reset of its own.
reg core_reset_d = 1'b1;
always @(posedge clk_sys) core_reset_d <= core_reset;
wire core_reset_rise = core_reset & ~core_reset_d;
wire [15:0] c_rst;
debug_counter #(.W(16)) u_c_rst    (.clk(clk_sys), .clear(ctr_clear), .ev(core_reset_rise),  .count(c_rst));

// ioctl_download rising edges, any index: each is a core_reset pulse.
reg dl_d = 1'b0;
always @(posedge clk_sys) dl_d <= ioctl_download;
wire [5:0] c_dl_edges;
debug_counter #(.W(6))  u_c_dledge (.clk(clk_sys), .clear(ctr_clear), .ev(ioctl_download & ~dl_d), .count(c_dl_edges));

// PLL lost lock after having it: ~pll_locked is in `reset` and drives the
// SDRAM chip's init.
reg pll_seen_lock = 1'b0, pll_unlock = 1'b0;
always @(posedge clk_sys) begin
	if (pll_locked) pll_seen_lock <= 1'b1;
	if (ctr_clear) pll_unlock <= 1'b0;
	else if (pll_seen_lock && !pll_locked) pll_unlock <= 1'b1;
end
debug_counter #(.W(16)) u_c_ovr    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_spr_ovr),     .count(c_ovr));
// Render overrun watch (fuuki_core.sv): lines on which each tilemap engine
// was still busy at the swap. Saturating.
wire [7:0] c_tm_ovr0, c_tm_ovr1, c_tm_ovr2;
debug_counter #(.W(8)) u_c_tmovr0 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[0]), .count(c_tm_ovr0));
debug_counter #(.W(8)) u_c_tmovr1 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[1]), .count(c_tm_ovr1));
debug_counter #(.W(8)) u_c_tmovr2 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[2]), .count(c_tm_ovr2));
debug_counter #(.W(16)) u_c_gfx    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_gfx_req),     .count(c_gfx));
wire dl_seen;
debug_sticky u_dl_seen (.clk(clk_sys), .clear(ctr_clear), .ev(ioctl_wr && ioctl_index == 16'd0), .seen(dl_seen));

// Sound chain, in order: Z80 fetches, chip writes, key-ons, mix peak. The
// first that stays at zero locates the fault. Counters saturate.
// Fetches count in units of 1024: at ~1.5 M/s a plain 16-bit counter
// saturates within 50 ms; scaled it holds 45 s.
wire [15:0] c_z80_k, c_ym_wr;
wire [7:0]  c_pcm_kon;
wire [4:0]  c_fm_kon;
reg  [9:0]  z80_m1_pre = 10'd0;
always @(posedge clk_sys) if (ctr_clear) z80_m1_pre <= 10'd0; else if (dbg_z80_m1) z80_m1_pre <= z80_m1_pre + 10'd1;
debug_counter #(.W(16)) u_c_z80k  (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_z80_m1 && &z80_m1_pre), .count(c_z80_k));
debug_counter #(.W(16)) u_c_ymwr  (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_ym_wr),  .count(c_ym_wr));
debug_counter #(.W(8))  u_c_pcmkon(.clk(clk_sys), .clear(ctr_clear), .ev(dbg_pcm_keyon), .count(c_pcm_kon));
debug_counter #(.W(5))  u_c_fmkon (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_fm_keyon),  .count(c_fm_kon));
// The sound CPU's interrupt time base (FG-2: the YM3812 timer).
wire [7:0] c_snd_int;
debug_counter #(.W(8))  u_c_sndint (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_snd_int), .count(c_snd_int));

// Peak of |audio_l| since the last clear, top 8 bits: any single sample may
// legitimately be zero. The negative extreme saturates rather than wrapping.
wire signed [15:0] aud_abs = core_audio_l[15] ? (core_audio_l == 16'sh8000 ? 16'sh7FFF : -core_audio_l)
	                                          : core_audio_l;
reg [7:0] snd_peak = 8'd0;
always @(posedge clk_sys) begin
	if (ctr_clear)                      snd_peak <= 8'd0;
	else if (aud_abs[14:7] > snd_peak) snd_peak <= aud_abs[14:7];
end

// Highest download address written, in 512-byte units. Unlike the trace
// buffer it cannot be fooled by a pause between .mra parts. A complete
// gogomile load reaches 0x1180000, 0x8C00 here.
reg [16:0] max_dl_addr = 17'd0;
always @(posedge clk_sys) begin
	if (ctr_clear) max_dl_addr <= 17'd0;
	else if (dbg_dl_wr && (dbg_dl_addr[25:9] > max_dl_addr))
		max_dl_addr <= dbg_dl_addr[25:9];
end

`ifndef DEBUG_ISSP
// Release: no probe. Its source bits read as zero and the counters above are
// pruned with it.
assign probe_src = 32'd0;
`else
// Explicit slices, so a field of the wrong width cannot shift its neighbours
// (a concatenation is truncated silently by the port).
// scripts/read_issp.tcl decodes exactly these positions.
wire [127:0] probe_bus;
assign probe_bus[15:0]    = c_frames;
assign probe_bus[31:16]   = c_rst;           // core_reset rising edges
assign probe_bus[39:32]   = dbg_opl4_state;  // {0, new2, mix_pcm[5:0]}
assign probe_bus[44:40]   = c_iack1;         // level-1 acknowledges
assign probe_bus[47:45]   = dbg_irq_pending; // {irq5, irq3, irq1}
assign probe_bus[48]      = dl_seen;
assign probe_bus[49]      = ioctl_download;
assign probe_bus[50]      = pause_latched;
assign probe_bus[51]      = dbg_frozen;      // ring mode: buffer stopped moving
assign probe_bus[52]      = 1'b0;
assign probe_bus[56:53]   = dbg_snd_state;   // {halt_n, rom_wait, int_n, nmi_n}
assign probe_bus[64:57]   = snd_peak;        // peak |audio_l| since clear, bits 14:7
assign probe_bus[72:65]   = c_snd_int;       // sound CPU INT falling edges
assign probe_bus[88:73]   = c_ym_wr;         // writes to the sound chips
assign probe_bus[104:89]  = c_z80_k;         // Z80 opcode fetches / 1024
assign probe_bus[120:105] = dbg_smp;         // {stalled, outstanding, opl4 sel[7:0], port[2:0], worst latency[2:0]}
assign probe_bus[121]     = pll_unlock;
assign probe_bus[127:122] = c_dl_edges;      // ioctl_download rising edges

// Instance D: fg2_sound.sv's command history frozen at the first pair slip.
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(344), .SOURCE_W(1)) u_probe_frz (
	.clk(clk_sys),
	.probe({dbg_fg2_cmd_frz, c_frames}),
	.source()
);

// Instance C: fg2_sound.sv's command transport probe.
issp_probe #(.INSTANCE_ID("C"), .PROBE_W(416), .SOURCE_W(1)) u_probe_cmd (
	.clk(clk_sys),
	.probe({dbg_fg2_cmd_hist, dbg_fg2_cmd, c_frames}),
	.source()
);

// Instance S: the FG-2 sound board per chip (fg2_sound.sv). Cleared by the
// F instance's source bit 0.
issp_probe #(.INSTANCE_ID("S"), .PROBE_W(416), .SOURCE_W(1)) u_probe_snd (
	.clk(clk_sys),
	.probe({c_core_reset_async, c_rsrc[6], c_rsrc[5], c_rsrc[4], c_rsrc[3], c_rsrc[2], c_rsrc[1], c_rsrc[0],
	        dbg_fg2_z80, dbg_fg2_oki, dbg_fg2_chips, c_frames}),
	.source()
);

issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(32)) u_probe (
	.clk(clk_sys),
	.probe(probe_bus),
	.source(probe_src)
);
`endif

endmodule
