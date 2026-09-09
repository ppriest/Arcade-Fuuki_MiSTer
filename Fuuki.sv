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
// NOT IN THIS BUILD: FG-3 sound (the OPL4) and hiscore save. FG-2 sound is
// rtl/sound/fg2_sound.sv. The output chain below the core is: CRT offset
// (crt_adjust) -> arcade_video (scandoubler, gamma) -> video_freak (crop,
// integer scale, aspect) -> the framework, with screen_rotate_two tapping
// the final output into a rotated or 180-flipped HDMI framebuffer.

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

// DDR3 has two owners and they never overlap: the fast ROM loader, which
// only runs with the core in reset, and the HDMI rotator the rest of the
// time. The pins are MUXED on ldr_active (see "HDMI ROTATION" below) rather
// than shared: the rotator has no reset and infers acceptance from
// DDRAM_BUSY, so Psikyo's first attempt, which let the two share the bus,
// had it take phantom writes as accepted and leave a permanent stale band in
// the frame buffer. Its DDRAM_BUSY is also held high for the loader's whole
// run so it cannot issue at all.

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Signed. FG-2's mix is mono and goes to both channels; FG-3's OPL4 is
// stereo. rtl/fuuki_core.sv picks between the two boards' sound.
wire signed [15:0] core_audio_l, core_audio_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = core_audio_l;
assign AUDIO_R   = core_audio_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Fuuki boards are all ROT0 horizontal: the original aspect is 4:3, or 3:4
// once the picture is rotated for a portrait display. ar != 0 selects Full
// Screen / ARC1 / ARC2, where a zero ARY means "stretch" in the framework's
// convention. video_freak turns these into VIDEO_ARX/ARY, adjusted for its
// crop and integer-scale settings.
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
localparam CONF_STR = {
	"Fuuki;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[64:63],Rotation,Off,CW,CCW;",
	"O[65],Flip 180,Off,On;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[90],Sound: FM,On,Off;",
	"O[91],Sound: PCM,On,Off;",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"O[70:69],Vertical crop,Disabled,216p (5x),224p;",
	"O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[76],CRT offset,Off,On;",
	"O[83:77],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[89:84],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"P1,Debug;",
	"P1-;",
	"P1O[40],Tilemap 0,On,Off;",
	"P1O[41],Tilemap 1,On,Off;",
	"P1O[42],Tilemap 2,On,Off;",
	"P1O[43],Sprites,On,Off;",
	"P1-;",
	// Trace to screen. Live from the OSD so the capture can be moved without
	// a rebuild -- which is the whole point, at ~13 minutes a build.
	"P1O[50],Trace overlay,Off,On;",
	"P1O[52:51],Trace source,Download addr,CPU FC+addr,CPU data+addr,SDRAM dump;",
	"P1O[56:53],Trace window,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P1O[57],Trace mode,First N,Ring (latest);",
	"P1O[58],Re-arm capture,A,B;",
	"P1O[59],Ring trigger,Off,Vector 2-4 read;",
	"P1O[60],Line markers,Off,On;",
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
// Fast ROM loader, declared here because core_reset below reads ldr_active.
wire        ldr_active, ldr_req, ldr_we16, ldr_busy;
wire [25:0] ldr_addr;
wire [15:0] ldr_data;
wire [31:0] probe_src;  // ISSP source bits; driven by issp_probe below, consumed above it
                        // [7:0] controls (see the probe), [31:8] memory-dump {region, page}

wire        forced_scandoubler;
wire [21:0] gamma_bus;
// GAMMA IS FORCED OFF UNDER THE DEBUG OVERLAY. The framework applies the
// user's gamma LUT (MiSTer.ini preset, e.g. Pure_Gamma/gamma_110.txt) to the
// core's RGB before the scaler and before screenshots, so a trace value drawn
// as a pixel came back remapped (0x40 -> 0x38, 0x02 -> 0x01: lossy) and
// looked like memory corruption. Bit 19 is gamma_en (sys/gamma_corr.sv);
// bit 21 is driven back by the consumer, so it is passed through untouched.
wire [21:0] gamma_bus_video;
assign gamma_bus_video[20:0] = {gamma_bus[20], gamma_bus[19] & ~status[50], gamma_bus[18:0]};
assign gamma_bus[21]         = gamma_bus_video[21];
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
// Psikyo core, where this exact phase is proven on MiSTer: at 266 degrees
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
	.locked(pll_locked),
	.reconfig_to_pll(rcfg_to_pll),
	.reconfig_from_pll(rcfg_from_pll)
);

// ---------------------------------------------------------------------------
// RUNTIME SDRAM_CLK PHASE STEPPING, driven over JTAG.
//
// The known-pattern SDRAM test measured DQ being sampled at the transition
// edge: a walking one reads back as the OR of its neighbours, with lanes
// moving in groups. That is a phase problem, and a phase is only trustworthy
// when it has been placed in the MIDDLE of the working window, which means
// measuring the window -- a build per point is 13 minutes, this is 30 s.
//
// Mechanism: the framework's pll_cfg (altera_pll_reconfig) on the core PLL,
// clocked from CLK_50M so it keeps running whatever the PLL does. A write to
// its dynamic-phase-shift register (address 6) moves one counter by N steps
// of VCO/8 -- ~132 ps here (VCO 945 MHz), ~88 steps per 11.64 ns period.
// Counter select 3 is C1, the SDRAM_CLK output. C0 (clk_sys) is left alone.
//
// Control comes from the ISSP probe's source bits, which are the only thing
// that can be poked without reconfiguring the FPGA (a relaunch reloads the
// build's phase):
//     bit 0     clear the debug counters (as before)
//     bit 1     rising edge: step SDRAM_CLK phase UP   by 8 steps (~1 ns)
//     bit 2     rising edge: step SDRAM_CLK phase DOWN by 8 steps
//     bits 7,4,3 which 40-entry page of the trace buffer the overlay shows (0-6)
//     bit 6     toggles the walker / tracer re-arm, for a fresh dump in place
// phase_pos (signed steps from the build's phase) is in the probe.
// ---------------------------------------------------------------------------
wire [63:0] rcfg_to_pll, rcfg_from_pll;

reg [7:0] psrc_s1 = 8'd0, psrc_s2 = 8'd0, psrc_d = 8'd0;
always @(posedge CLK_50M) begin
	psrc_s1 <= probe_src[7:0];
	psrc_s2 <= psrc_s1;
	psrc_d  <= psrc_s2;
end
// The phase-step controls are retired: bit 1 is DUMP NOW (above); bit 2 is
// free now that the sprite depth order is settled.
wire        dps_up   = 1'b0;
wire        dps_dn   = 1'b0;
wire [15:0] dps_n    = 16'd8;   // ~1 ns per command; bits 4:3 now select the readout page

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

// Two domains, and the split is load-bearing -- see rtl/fuuki_core.sv's
// header. `reset` must NOT include ioctl_download, or the SDRAM download FSM
// sits in idle for the entire transfer and nothing is ever written.
wire reset      = RESET | status[0] | buttons[1] | ~pll_locked;

// HOLD THE CPU AND VIDEO IN RESET UNTIL THE ROM HAS BEEN LOADED ONCE.
//
// MiSTer configures the FPGA, and only asserts RESET when the .mra load
// begins. In between, the core runs on whatever SDRAM holds -- the previous
// load's image, partly decayed during reconfiguration -- and the probe
// counted ~3,000 CPU fetches in that window. On real hardware the CPU did
// not come back from that cleanly: an FC-tagged trace of the first accesses
// AFTER the download showed it mid-flight at 0x360000, all supervisor-data
// reads, never fetching an instruction and never reading address 0. Every
// "corrupt ROM word" measured before this was that pre-download run reading
// decayed memory, not the load.
//
// rom_loaded is sticky and has no reset of its own: it is set once the first
// index-0 transfer has ended and stays set, so an OSD reset later still
// resets the game normally. It is not cleared by a later download either --
// at that point RESET and ioctl_download hold the core anyway.
//
// On the FAST path there are no ioctl_wr pulses at all, so dl_index0_seen
// never sets and this would hold the core in reset forever. The copy
// finishing is the equivalent event, and is what releases it there.
reg rom_loaded = 1'b0, dl_index0_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0) dl_index0_seen <= 1'b1;
	if (dl_index0_seen && !ioctl_download) rom_loaded     <= 1'b1;
	if (ldr_active_d && !ldr_active)       rom_loaded     <= 1'b1;
end

// ldr_active is in core_reset, NOT in `reset`: `reset` is what resets the
// loader itself, so putting the loader's own busy flag in it would hold it in
// reset for as long as it tried to run.
wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active;

// MiSTer asserts RESET for the WHOLE ROM download, so the memory path gets the
// reset with the download masked out of it. Passing plain `reset` here is what
// made the first bitstream come up as a correct 320x240 raster with every
// pixel black: the download FSM was held in idle for the entire transfer, so
// SDRAM was never written, the CPU never ran, and the palette stayed zero.
// The SDRAM chip's own init sequence is separate again -- it keys off PLL lock
// alone and must not be pulsed by a core reset.
// POWER-ON ONLY, and this is a change from the download-masked
// `reset & ~ioctl_download` the sibling core uses. That form still pulses
// the memory path's reset at every ioctl_download edge while RESET is held --
// including at the END of the ROM stream. The phy is reset by it; sdram.sv is
// not. The phy's req TOGGLE goes to 0 while the controller's ack may be 1 and
// a transaction may still be completing; the controller then does
// `ack <= req` at completion, and if a new request has already toggled req
// by then, that request is acknowledged WITHOUT being performed -- a write
// silently dropped. Which write depends on the pre-download CPU traffic, so
// the corruption differed from load to load (word 0 read 0x0040 on one load
// and 0x0038 on the next). Psikyo streams its ROM by DDR3 DMA with no phy
// traffic across those edges, so it never met this.
//
// Nothing in the memory path needs a runtime reset: the download FSM and
// the arbiters return to idle on their own, and the bridge's cache is
// invalidated per download through `inval`. The FPGA is reconfigured on
// every .mra launch, which is the real power-on.
wire sdram_reset = ~pll_locked;
wire sdram_init  = ~pll_locked;

///////////////////////   BOARD SELECT   //////////////////////////

// Latched from the .mra's index-1 payload and NOT cleared by `reset`, because
// MiSTer holds the core in reset for the whole download -- a mod byte cleared
// by reset would be 0 by the time the game ran, silently selecting FG-2.
reg [7:0] mod_board = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 27'd0) mod_board <= ioctl_dout;
end

wire board = mod_board[0];   // BOARD_FG2 / BOARD_FG3
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
	// JTAG pause (source bit 5): stops ROM reads so the trace ring, in ring
	// mode, freezes on the last 256 accesses before the pause -- the loop a
	// hung CPU is spinning in (scripts/boot_trace.py --hang).
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
// FAST ROM LOADING
//
// scripts/build_mra.py puts address="0x30000000" on <rom index="0">, so the
// HPS DMAs the ROM straight into DDR3 and the core sees ioctl_download assert
// and deassert with NO ioctl_wr pulses. rom_loader then copies DDR3 -> SDRAM
// with the core held in reset. An .mra WITHOUT the attribute still streams
// through ioctl exactly as before -- which is what the inline-hex .mra files
// in scripts/sdram_pattern_test.py depend on -- so the two paths are told
// apart by whether any byte arrived during the download.
//
// The copy length is the whole board map, so no per-set length is needed;
// copying the padding beyond a smaller set costs only time.
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
		// Only when the ROM did NOT come through the byte path, and only once
		// per download: dl_seen_wr stays 0 forever after a DDR3 load, so
		// without ldr_done every later reset -- OSD reset, the reset button, a
		// PLL relock -- would recopy the whole map.
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
	// FG-2's map ends at 0x1180000 (17.5 MB), FG-3's at 0x3880000 (56.5 MB)
	// -- rtl/memory/fuuki_sdram_top.sv's FG2_BASE_* / FG3_BASE_* tables.
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

	// Runtime A/B switches, so a rendering fault can be bisected without a
	// rebuild per step (LESSONS_LEARNED). Menu sense is On,Off, so the
	// enable is the inverse of the status bit.
	.en_l0(~status[40]), .en_l1(~status[41]),
	.en_l2(~status[42]), .en_spr(~status[43]),
	// FM is the YM2203+YM3812 pair on FG-2 and the OPL3 on FG-3; PCM is the
	// OKI and the OPL4's wavetable engine. Menu sense is On,Off.
	.en_fm(~status[90]), .en_pcm(~status[91]),

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
	// (source 3, which pauses the CPU) selected, so a game runs normally
	// with the overlay off until the moment scripts/memdump.py --live
	// asserts it, dumps from that instant, and releases it.
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
	.dbg_pcm_keyon(dbg_pcm_keyon), .dbg_fm_keyon(dbg_fm_keyon),
	.dbg_frozen(dbg_frozen)
);

///////////////////////   VIDEO   /////////////////////////////////

// CLK_VIDEO and CE_PIXEL are OUTPUTS of arcade_video (it drives CLK_VIDEO
// from its own clk_video input), so they must not be assigned here as well --
// a second driver on CLK_VIDEO propagates back to clk_sys and Quartus reports
// it against the clock, not against this line.
// ---- CRT offset (rtl/video/crt_adjust.sv) ----
// Slides the picture for an analog CRT without touching the sync: the content
// moves inside a line buffer while HSync/VSync stay native, so the monitor
// keeps its lock while you adjust. It sits between the core and arcade_video,
// so HDMI follows the adjustment too -- leave it Off for an untouched HDMI
// image. Only the two offsets are wired; hsize is 0, the module's documented
// no-scaling case, which makes the read rate the write rate.
//
// H-Position: the OSD stores the INDEX into a 97-entry list (0, +1..+48,
// -48..-1), so the negative half wraps at 97, not 128. V-Shift's 64-entry
// list IS two's complement.
wire crt_adj_on = status[76];
wire  [6:0] crt_hpos_idx = crt_adj_on ? status[83:77] : 7'd0;
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48)
	? $signed({2'b00, crt_hpos_idx})
	: $signed({2'b00, crt_hpos_idx}) - 9'sd97;
wire signed [5:0] crt_voffset = crt_adj_on ? $signed(status[89:84]) : 6'sd0;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_adjust #(
	.VTOTAL(262), .HTOTAL(456),
	// CONTENTSHIFT keeps HSync byte-for-byte native; SYNCSHIFT moves the sync.
	.HPOS_MODE(1)
) u_crt_adjust (
	.clk(clk_sys), .pxl_cen(core_ce), .pxl2_cen(core_ce),
	.active(crt_adj_on), .hsize(5'sd0),
	.hoffset(crt_hoffset), .voffset(crt_voffset),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb),
	.hs_ref_out()
);

wire vga_de_raw;

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(core_ce),

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
// 1080-line display, 224 trims 8 lines top and bottom. The offset moves the
// crop window; the scale modes are the framework's.
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

// ---- HDMI ROTATION and flip (rtl/video/screen_rotate_two.sv) ----
// A TAP, not a filter: the analog output keeps the native raster while a
// rotated (or 180-flipped) copy goes into DDR3 and the HPS framebuffer is
// pointed at it. So the DIP "Flip Screen" is not this -- that is the game
// redrawing itself upside down through its own scroll constants, which both
// MAME drivers say they get wrong, and it stays commented out of the .mra
// files. This flip is the output turned round, which is what a cocktail
// cabinet or an upside-down monitor wants.
//
// DDR3 is muxed against the ROM loader on ldr_active; the loader only runs
// with the core in reset, when there is no picture. The rotator's
// DDRAM_BUSY is ORed with ldr_active so it cannot mistake the loader's
// transactions for its own accepted writes.
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

// Counters, not a waveform. The bring-up questions are "is anything moving at
// all, and how much" -- frames, scanlines, CPU fetches, graphics fetches --
// and a counter answers those over a serial JTAG link where SignalTap cannot
// even be scripted in Quartus Prime Lite 17.0. See rtl/debug/issp_probe.sv.
//
// The counters are deliberately NOT reset by the core reset, so a value
// survives the reset a failed load causes; source bit 0 clears them.
// scripts/read_issp.tcl decodes this layout and must be kept in step with it:
// a silently shifted field reads as plausible nonsense, not as an error.
wire       ctr_clear = probe_src[0];

// INTERRUPT STATE, replacing the SDRAM_CLK phase position (that experiment
// changed nothing and is over). Answers, on a hung game: is the interrupt it
// waits for still being generated (irq1 edges advance), is it stuck pending
// (never taken: a mask or kernel problem), or is it taken (level-1
// acknowledges advance) and the handler simply never sets the flag.
wire [2:0] dbg_irq_pending, dbg_iack_level;
wire       dbg_iack, dbg_irq1_trig;
wire [15:0] dbg_smp;   // sample-ROM fetch health, see fuuki_core.sv's SAMPLE FETCH WATCH
wire [2:0]  dbg_tm_ovr;  wire [12:0] dbg_tm_max, dbg_spr_max;   // RENDER OVERRUN WATCH
wire [7:0]  dbg_opl4_state;  // {0, new2, mix_pcm} -- what can silence PCM
wire        dbg_z80_m1, dbg_ym_wr, dbg_pcm_keyon, dbg_fm_keyon;
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
// core_reset RISING EDGES. A CPU that keeps re-reading its reset vector is
// either taking exceptions or being reset; this tells the two apart. Counted
// with no reset of its own, so the count survives the thing it counts.
reg core_reset_d = 1'b1;
always @(posedge clk_sys) core_reset_d <= core_reset;
wire core_reset_rise = core_reset & ~core_reset_d;
wire [15:0] c_rst;
debug_counter #(.W(16)) u_c_rst    (.clk(clk_sys), .clear(ctr_clear), .ev(core_reset_rise),  .count(c_rst));

// ioctl_download rising edges, ANY index -- MiSTer sending anything after the
// ROM is a core_reset pulse, because core_reset ORs ioctl_download in.
reg dl_d = 1'b0;
always @(posedge clk_sys) dl_d <= ioctl_download;
wire [5:0] c_dl_edges;
debug_counter #(.W(6))  u_c_dledge (.clk(clk_sys), .clear(ctr_clear), .ev(ioctl_download & ~dl_d), .count(c_dl_edges));

// PLL lost lock after having it. ~pll_locked is in `reset` AND drives the
// SDRAM chip's init, so a flaky lock would reset the CPU and re-init memory.
reg pll_seen_lock = 1'b0, pll_unlock = 1'b0;
always @(posedge clk_sys) begin
	if (pll_locked) pll_seen_lock <= 1'b1;
	if (ctr_clear) pll_unlock <= 1'b0;
	else if (pll_seen_lock && !pll_locked) pll_unlock <= 1'b1;
end
debug_counter #(.W(16)) u_c_ovr    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_spr_ovr),     .count(c_ovr));
// RENDER OVERRUN WATCH (fuuki_core.sv): lines on which each tilemap engine
// was still busy when the line buffers swapped. Saturating.
wire [7:0] c_tm_ovr0, c_tm_ovr1, c_tm_ovr2;
debug_counter #(.W(8)) u_c_tmovr0 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[0]), .count(c_tm_ovr0));
debug_counter #(.W(8)) u_c_tmovr1 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[1]), .count(c_tm_ovr1));
debug_counter #(.W(8)) u_c_tmovr2 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_tm_ovr[2]), .count(c_tm_ovr2));
debug_counter #(.W(16)) u_c_gfx    (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_gfx_req),     .count(c_gfx));
wire dl_seen;
debug_sticky u_dl_seen (.clk(clk_sys), .clear(ctr_clear), .ev(ioctl_wr && ioctl_index == 16'd0), .seen(dl_seen));

// SOUND, as a chain that says WHERE a silence begins. The Z80 running
// (opcode fetches), the Z80 reaching the chips (writes), voices actually
// being asked for (key-ons, FG-3's OPL4), and the mix moving at all
// (snd_peak). Each is meaningless alone and decisive in sequence: fetches
// with no writes is an I/O or latch fault, writes with no key-ons is a
// driver that never starts a voice, key-ons with no peak is a synthesis or
// sample-path fault. The counters saturate; clear and read again for a rate.
//
// FM key-ons are counted deliberately even though nothing plays them yet:
// the OPL4's FM half is not built, so this is the measure of what Asura
// Blade is asking for and Asura Buster is not.
wire [15:0] c_z80_m1, c_ym_wr;
wire [7:0]  c_pcm_kon;
wire [4:0]  c_fm_kon;
debug_counter #(.W(16)) u_c_z80m1 (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_z80_m1), .count(c_z80_m1));
debug_counter #(.W(16)) u_c_ymwr  (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_ym_wr),  .count(c_ym_wr));
debug_counter #(.W(8))  u_c_pcmkon(.clk(clk_sys), .clear(ctr_clear), .ev(dbg_pcm_keyon), .count(c_pcm_kon));
debug_counter #(.W(5))  u_c_fmkon (.clk(clk_sys), .clear(ctr_clear), .ev(dbg_fm_keyon),  .count(c_fm_kon));

// PEAK of |audio_l| since the last clear, top 8 bits. "Is anything coming
// out" is otherwise unanswerable over a probe: the mix is a moving signal
// and any single sample of it may legitimately be zero. A peak that stays
// at 0 with key-ons counting is the sharpest evidence of a silent chip
// there is. Absolute value, saturating the negative extreme rather than
// wrapping it to itself.
wire signed [15:0] aud_abs = core_audio_l[15] ? (core_audio_l == 16'sh8000 ? 16'sh7FFF : -core_audio_l)
                                              : core_audio_l;
reg [7:0] snd_peak = 8'd0;
always @(posedge clk_sys) begin
	if (ctr_clear)                      snd_peak <= 8'd0;
	else if (aud_abs[14:7] > snd_peak) snd_peak <= aud_abs[14:7];
end

// HIGHEST download address written, in 512-byte units. The trace buffer can
// freeze on a pause between .mra parts and look like the end of the transfer;
// a high-water mark cannot. A complete gogomile load must reach 0x1180000,
// i.e. 0x8C00 here.
reg [16:0] max_dl_addr = 17'd0;
always @(posedge clk_sys) begin
	if (ctr_clear) max_dl_addr <= 17'd0;
	else if (dbg_dl_wr && (dbg_dl_addr[25:9] > max_dl_addr))
		max_dl_addr <= dbg_dl_addr[25:9];
end

issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(32)) u_probe (
	.clk(clk_sys),
	.probe({
		c_dl_edges,          // 127..122  ioctl_download rising edges, any index
		pll_unlock,          // 121
		dbg_smp,             // 120..105  sample fetch: {stalled, outstanding, worst latency, done}
		// 128 bits exactly: the first cut of this was 132 and the probe port
		// silently truncated the top four, misaligning every field above
		// bit 104 (pause_latched read as a tilemap counter's bit). The two
		// peaks are in units of 8 clk to make the width.
		c_tm_ovr0, c_tm_ovr1, c_tm_ovr2,   // 104..81  tilemap overruns per layer (lines)
		c_ovr[7:0],          //  80..73  sprite engine overruns (lines)
		dbg_tm_max[12:3],    //  72..63  worst tilemap line render, clk/8
		dbg_spr_max[12:3],   //  62..53  worst sprite line render, clk/8
		1'b0,                //  52
		dbg_frozen,          //  51  ring mode: has the buffer stopped moving
		pause_latched,       //  50
		ioctl_download,      //  49
		dl_seen,             //  48
		dbg_irq_pending,     //  47..45  {irq5, irq3, irq1} pending
		c_iack1,             //  44..40  level-1 acknowledges (wraps)
		dbg_opl4_state,      //  39..32  {0, NEW2, F9 attenuator pair}
		c_rst,               //  31..16  core_reset rising edges
		c_frames             //  15..0
	}),
	.source(probe_src)
);

endmodule
