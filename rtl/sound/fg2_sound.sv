// FG-2 sound board: Z80 + YM2203 + YM3812 + OKI M6295, from fuukifg2.cpp.
//
//   Z80          12 MHz / 2 = 6 MHz           T80se, clock-enabled
//   YM2203       28.640 MHz / 8 = 3.58 MHz    jt03   (write only; no IRQ used)
//   YM3812       28.640 MHz / 8 = 3.58 MHz    jtopl2 (its timer IRQ is the Z80's INT)
//   M6295        32 MHz / 32 = 1 MHz, pin 7 high   jt6295, 4 x 256 KB ROM banks
//
// Memory map (sound_map):
//   0000-5FFF  ROM, fixed
//   6000-7FFF  RAM, 8 KB
//   8000-FFFF  ROM, banked: bank n (0..2) is physical (n+1)*0x8000, so the
//              physical address is {bank+1, a[14:0]}; one 17-bit address
//              covers the 128 KB image.
// I/O map (sound_io_map, 8-bit):
//   00  w  ROM bank (values above 2 ignored)
//   11  r  sound latch            20  w  OKI bank = (data & 6) >> 1
//   30  w  nop, in the NMI routine
//   40-41  w  YM2203               50-51 rw  YM3812
//   60  r  OKI status              61  w  OKI data
//
// The main CPU's write to 0x8A0001 latches the command and pulses the Z80
// NMI (MAME pulse_input_line). No acknowledge port: the NMI routine reads
// 0x11 and writes 0x30.
//
// Z80 side (T80se, split WAIT_n, stretched ROM handshake): the Psikyo
// core's sound_cpu.sv; only the map differs.
module fg2_sound (
	input  logic        clk,
	input  logic        reset,

	// clock enables, from clk (85.909 MHz)
	input  logic        cen_z80,     // 6 MHz     66/945
	input  logic        cen_ym,      // 3.58 MHz  1/24
	input  logic        cen_oki,     // 1 MHz     11/945

	// sound latch, from the main CPU
	input  logic [7:0]  latch_data,
	input  logic        latch_write, // pulse
	// Latch pacing: high from a latch write until LATCH_SETTLE clk after the
	// Z80 reads it (capped at LATCH_CAP), holding the main CPU's write access.
	output logic        latch_busy,

	// Z80 program ROM, 128 KB, byte req/valid: req pulses once per access,
	// data must be valid on the cycle valid pulses
	output logic        rom_req,
	output logic [16:0] rom_addr,
	input  logic        rom_valid,
	input  logic [7:0]  rom_data,

	// OKI sample ROM, 1 MB (bank folded in), byte req/valid; req is HELD
	// until valid
	output logic        oki_req,
	output logic [19:0] oki_addr,
	input  logic        oki_valid,
	input  logic [7:0]  oki_data,

	// mono, signed
	output logic signed [15:0] audio,

	// probes
	output logic        dbg_m1,      // one pulse per Z80 opcode fetch
	output logic        dbg_ym_wr,   // one pulse per write to either FM chip
	output logic        dbg_int_n,   // the YM3812 timer interrupt, as the Z80 sees it
	output logic        dbg_nmi_n,   // the sound-latch NMI pulse
	output logic        dbg_halt_n,
	output logic        dbg_rom_wait,// a ROM fetch is outstanding on the SDRAM
	// Per-chip output peaks, writes and key-ons, the last sound command.
	// Cleared by dbg_clear (the JTAG source bit, never a core reset).
	input  logic        dbg_clear,
	output logic [151:0] dbg_chips,
	output logic [87:0] dbg_oki,
	// Z80 resets seen, PC, last I/O write, bus pins.
	output logic [95:0] dbg_z80,
	output logic [143:0] dbg_cmd,
	// The last 16 commands, newest low: {pair flag when the NMI handler read
	// it, log2 clk since the previous write, the byte}, 16 bits each.
	output logic [255:0] dbg_cmd_hist,
	// The history frozen at the first read of a byte >= 0x80 while the
	// driver expects a second byte, and counts of the pair flag's other
	// movers.
	output logic [327:0] dbg_cmd_frz
);

	// =====================================================================
	// Z80
	// =====================================================================
	logic m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
	logic [15:0] a;
	logic [7:0]  di, d_out;
	logic        nmi_n, int_n, wait_n;

	T80se #(
		.Mode(0), .T2Write(0), .IOWait(1)
	) u_cpu (
		.RESET_n(~reset), .CLK_n(clk), .CLKEN(cen_z80), .WAIT_n(wait_n),
		.INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
		.A(a), .DI(di), .DO(d_out)
	);

	// ---- address decode ----
	wire is_ram    = (a[15:13] == 3'b011);        // 6000-7FFF
	wire is_banked = a[15];                        // 8000-FFFF
	// below 0x6000 is the fixed ROM

	logic [1:0] bank;                              // 0..2
	assign rom_addr = is_banked ? {bank + 2'd1, a[14:0]} : {2'b00, a[14:0]};

	// ---- RAM, 8 KB ----
	logic [7:0] ram [0:8191];
	logic [7:0] ram_rd_data;
	always_ff @(posedge clk) ram_rd_data <= ram[a[12:0]];

	// ---- I/O decode ----
	wire io_active_rd = !iorq_n && !rd_n;
	wire io_active_wr = !iorq_n && !wr_n;
	wire io_bank    = (a[7:0] == 8'h00);
	wire io_latch   = (a[7:0] == 8'h11);
	wire io_okibank = (a[7:0] == 8'h20);
	wire io_ym1     = (a[7:1] == 7'h20);           // 40-41
	wire io_ym2     = (a[7:1] == 7'h28);           // 50-51
	wire io_oki_rd  = (a[7:0] == 8'h60);
	wire io_oki_wr  = (a[7:0] == 8'h61);

	// ---- latch pacing ----
	// The driver takes commands in pairs, alternating on a flag its NMI
	// handler updates ~100 T-states after IN A,(0x11) (z80 0x1E05-0x1E1D,
	// ~17 us at 6 MHz). A command written before then nests the NMI, both
	// handlers read the second byte, and every later pair is swapped: music
	// stops and effects play the wrong phrase until F0 F0 F0. The 16 MHz
	// 68000 does not send commands that close; TG68K does (probe D: 24-48 us
	// apart). So the main CPU's write is held until the Z80 has read the byte
	// plus LATCH_SETTLE clk. LATCH_CAP bounds the hold if the Z80 never reads.
	localparam int LATCH_SETTLE = 4300;      // 50 us
	localparam int LATCH_CAP    = 172000;    // 2 ms
	logic        lp_unread;
	logic [17:0] lp_cnt;                     // clk since the write, or since the read
	logic        lp_settle;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			lp_unread <= 1'b0; lp_settle <= 1'b0; lp_cnt <= 18'd0;
		end else if (latch_write) begin
			lp_unread <= 1'b1; lp_settle <= 1'b0; lp_cnt <= 18'd0;
		end else if (lp_unread) begin
			lp_cnt <= lp_cnt + 18'd1;
			if (io_active_rd && io_latch) begin
				lp_unread <= 1'b0; lp_settle <= 1'b1; lp_cnt <= 18'd0;
			end else if (lp_cnt == 18'(LATCH_CAP)) begin
				lp_unread <= 1'b0;
			end
		end else if (lp_settle) begin
			lp_cnt <= lp_cnt + 18'd1;
			if (lp_cnt == 18'(LATCH_SETTLE)) lp_settle <= 1'b0;
		end
	end
	assign latch_busy = lp_unread || lp_settle;

	// ---- sound latch and NMI ----
	// NMI held low for NMI_PULSE clock enables: T80 detects the falling edge
	// on a CLKEN tick, so the pulse must straddle at least one.
	localparam int NMI_PULSE = 8;
	logic [7:0] latch_reg;
	logic [3:0] nmi_cnt;
	assign nmi_n = (nmi_cnt == 4'd0);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			latch_reg <= 8'd0;
			nmi_cnt   <= 4'd0;
		end else begin
			if (latch_write) begin
				latch_reg <= latch_data;
				nmi_cnt   <= 4'(NMI_PULSE);
			end else if (cen_z80 && nmi_cnt != 4'd0) begin
				nmi_cnt <= nmi_cnt - 4'd1;
			end
		end
	end

	// ---- bank registers ----
	logic [1:0] oki_bank;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bank     <= 2'd0;
			oki_bank <= 2'd0;
		end else begin
			// sound_rombank_w: values above 2 are ignored
			if (io_active_wr && io_bank && d_out[7:2] == 6'd0 && d_out[1:0] != 2'd3)
				bank <= d_out[1:0];
			// oki_banking_w: (data & 6) >> 1
			if (io_active_wr && io_okibank) oki_bank <= d_out[2:1];
		end
	end

	// =====================================================================
	// Sound chips
	// =====================================================================
	logic [7:0]  ym1_dout, ym2_dout, oki_dout;
	logic        ym2_irq_n;
	logic signed [15:0] ym1_snd, ym2_snd;
	logic signed [13:0] oki_snd;

	// jt03 / jtopl strobe on !cs_n && !wr_n, so cs_n must include !iorq_n or
	// a RAM write to 0x6x50 lands in the OPL's registers. The strobe spans
	// the whole I/O cycle; both chips are idempotent for a repeated write.
	wire ym1_cs_n = ~(io_ym1 && !iorq_n);
	wire ym2_cs_n = ~(io_ym2 && !iorq_n);
	jt03 u_ym1 (
		.rst(reset), .clk(clk), .cen(cen_ym),
		.din(d_out), .addr(a[0]), .cs_n(ym1_cs_n), .wr_n(wr_n),
		.dout(ym1_dout), .irq_n(),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(),
		.snd(ym1_snd), .snd_sample(), .debug_view()
	);

	jtopl2 u_ym2 (
		.rst(reset), .clk(clk), .cen(cen_ym),
		.din(d_out), .addr(a[0]), .cs_n(ym2_cs_n), .wr_n(wr_n),
		.dout(ym2_dout), .irq_n(ym2_irq_n),
		.snd(ym2_snd), .sample()
	);
	assign int_n = ym2_irq_n;

	// jt6295 edge-detects wrn on clk, so the level is one write per Z80 I/O
	// cycle. ss = 1: pin 7 high, /132.
	logic [17:0] oki_rom_addr;
	logic [7:0]  oki_rom_data;
	logic        oki_rom_ok;
	jt6295 #(.INTERPOL(0)) u_oki (
		.rst(reset), .clk(clk), .cen(cen_oki), .ss(1'b1),
		.wrn(~(io_active_wr && io_oki_wr)), .din(d_out), .dout(oki_dout),
		.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
		.sound(oki_snd), .sample()
	);

	oki_rom_bridge u_oki_bridge (
		.clk(clk), .reset(reset),
		.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
		.bank(oki_bank),
		.req(oki_req), .addr(oki_addr), .valid(oki_valid), .data(oki_data)
	);

	// =====================================================================
	// Z80 read data mux, ROM handshake, WAIT_n
	// =====================================================================
	wire mem_active_rd = !mreq_n && !rd_n;
	wire mem_active_wr = !mreq_n && !wr_n;
	wire is_rom_read   = mem_active_rd && !is_ram;

	logic       rom_done;
	logic [7:0] rom_data_hold;

	always_comb begin
		if (mem_active_rd) begin
			di = is_ram ? ram_rd_data : rom_data_hold;
		end else if (io_active_rd) begin
			if      (io_latch)  di = latch_reg;
			else if (io_ym2)    di = ym2_dout;
			else if (io_oki_rd) di = oki_dout;
			else                di = 8'hFF;
		end else begin
			di = 8'hFF;
		end
	end

	always_ff @(posedge clk) if (mem_active_wr && is_ram) ram[a[12:0]] <= d_out;

	// RAM/I/O: one fixed wait cycle, excluding ROM reads so the two schemes
	// never fight over wait_n.
	logic access_started;
	wire access_now        = (!mreq_n || !iorq_n) && (!rd_n || !wr_n);
	wire access_now_nonrom = access_now && !is_rom_read;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) access_started <= 1'b0;
		else       access_started <= access_now_nonrom;
	end

	// ROM: one request per M-cycle. is_rom_read stays high for the rest of
	// the clock-enable-stretched T-state, so !rom_done blocks a second one.
	logic rom_pending;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) rom_pending <= 1'b0;
		else if (is_rom_read && !rom_pending && !rom_done) rom_pending <= 1'b1;
		else if (rom_valid) rom_pending <= 1'b0;
	end
	assign rom_req = is_rom_read && !rom_pending && !rom_done;

	// Stretch the one-clock valid into a level held until the M-cycle ends.
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			rom_done      <= 1'b0;
			rom_data_hold <= 8'd0;
		end else if (rom_valid) begin
			rom_done      <= 1'b1;
			rom_data_hold <= rom_data;
		end else if (!is_rom_read) begin
			rom_done <= 1'b0;
		end
	end

	assign wait_n = is_rom_read        ? rom_done
	              : access_now_nonrom ? access_started
	              : 1'b1;

	// =====================================================================
	// Mix, as the driver routes to its mono speaker:
	//   YM2203 0.15    YM3812 0.30    M6295 0.85
	// in 1/32 steps: 5, 10, 27. The gains sum past unity, so the sum
	// saturates. Three register stages: in one clock, from the chips'
	// combinational outputs, this is the design's worst timing path.
	// =====================================================================
	wire signed [15:0] oki16 = {oki_snd, 2'b00};

	logic signed [15:0] s1_ym1, s1_ym2, s1_oki;
	logic signed [21:0] s2_ym1, s2_ym2, s2_oki;
	logic signed [22:0] s3_sum;

	always_ff @(posedge clk) begin
		// 1: register the chip outputs
		s1_ym1 <= ym1_snd;
		s1_ym2 <= ym2_snd;
		s1_oki <= oki16;
		// 2: scale
		s2_ym1 <= 22'(s1_ym1) * 22'sd5;
		s2_ym2 <= 22'(s1_ym2) * 22'sd10;
		s2_oki <= 22'(s1_oki) * 22'sd27;
		// 3: sum, then shift and saturate
		s3_sum <= 23'(s2_ym1) + 23'(s2_ym2) + 23'(s2_oki);
		if      ((s3_sum >>> 5) >  23'sd32767) audio <=  16'sd32767;
		// 16'sh8000, not -16'sd32768: see opl4.sv sat16.
		else if ((s3_sum >>> 5) < -23'sd32768) audio <= 16'sh8000;
		else                                   audio <= 16'(s3_sum >>> 5);
	end

	// ---- probes ----
	logic m1_d, ymwr_d;
	wire  m1_active = !m1_n && !mreq_n && !rd_n;
	wire  ym_wr_now = io_active_wr && (io_ym1 || io_ym2);
	always_ff @(posedge clk) begin
		m1_d   <= m1_active;
		ymwr_d <= ym_wr_now;
	end
	assign dbg_m1    = m1_active && !m1_d;
	assign dbg_ym_wr = ym_wr_now && !ymwr_d;
	assign dbg_int_n    = int_n;
	assign dbg_nmi_n    = nmi_n;
	assign dbg_halt_n   = halt_n;
	assign dbg_rom_wait = is_rom_read && !rom_done;

	// ---- per-chip probe ----
	wire ym1_wr = io_active_wr && io_ym1;
	wire ym2_wr = io_active_wr && io_ym2;
	wire oki_wr = io_active_wr && io_oki_wr;
	logic ym1_wr_d, ym2_wr_d, oki_wr_d, latch_wr_d;
	logic [7:0] ym1_sel, ym2_sel;              // the register each chip's address port holds
	logic [7:0] pk_ym1, pk_ym2, pk_oki;        // peak |output|, bits 14:7
	logic [15:0] n_ym1, n_ym2, n_oki;          // data and address writes, saturating
	logic [7:0]  kon_ym1, kon_ym2;             // key-on writes, saturating
	logic [7:0]  last_cmd, n_cmd, n_cmd_rd;
	logic [31:0] cmd_hist;                     // the four commands before last_cmd, newest low
	logic        latch_rd_d;
	wire         latch_rd = io_active_rd && io_latch;
	wire  [15:0] a_ym1 = ym1_snd[15] ? 16'(-ym1_snd) : ym1_snd;
	wire  [15:0] a_ym2 = ym2_snd[15] ? 16'(-ym2_snd) : ym2_snd;
	wire  [15:0] a_oki = oki16[15]   ? 16'(-oki16)   : oki16;
	always_ff @(posedge clk) begin
		ym1_wr_d <= ym1_wr; ym2_wr_d <= ym2_wr; oki_wr_d <= oki_wr; latch_wr_d <= latch_write;
		if (dbg_clear) begin
			pk_ym1 <= '0; pk_ym2 <= '0; pk_oki <= '0;
			n_ym1 <= '0; n_ym2 <= '0; n_oki <= '0;
			kon_ym1 <= '0; kon_ym2 <= '0; n_cmd <= '0; n_cmd_rd <= '0;
		end else begin
			if (a_ym1[14:7] > pk_ym1) pk_ym1 <= a_ym1[14:7];
			if (a_ym2[14:7] > pk_ym2) pk_ym2 <= a_ym2[14:7];
			if (a_oki[14:7] > pk_oki) pk_oki <= a_oki[14:7];
			if (ym1_wr && !ym1_wr_d) begin
				if (~&n_ym1) n_ym1 <= n_ym1 + 16'd1;
				if (!a[0]) ym1_sel <= d_out;
				// YM2203 key-on: register 0x28, operator bits 7:4 set
				else if (ym1_sel == 8'h28 && d_out[7:4] != 4'd0 && ~&kon_ym1) kon_ym1 <= kon_ym1 + 8'd1;
			end
			if (ym2_wr && !ym2_wr_d) begin
				if (~&n_ym2) n_ym2 <= n_ym2 + 16'd1;
				if (!a[0]) ym2_sel <= d_out;
				// YM3812 key-on: registers 0xB0-0xB8, bit 5
				else if (ym2_sel >= 8'hB0 && ym2_sel <= 8'hB8 && d_out[5] && ~&kon_ym2) kon_ym2 <= kon_ym2 + 8'd1;
			end
			if (oki_wr && !oki_wr_d && ~&n_oki) n_oki <= n_oki + 16'd1;
			if (latch_write && !latch_wr_d && ~&n_cmd) n_cmd <= n_cmd + 8'd1;
			// the NMI handler's IN A,(0x11): a command actually taken
			if (latch_rd && !latch_rd_d && ~&n_cmd_rd) n_cmd_rd <= n_cmd_rd + 8'd1;
		end
		latch_rd_d <= latch_rd;
		if (latch_write && !latch_wr_d) begin
			cmd_hist <= {cmd_hist[23:0], last_cmd};
			last_cmd <= latch_data;
		end
	end
	assign dbg_chips = {cmd_hist,                      // 151:120
	                    n_cmd_rd,                      // 119:112
	                    oki_bank, bank, 4'd0,          // 111:104
	                    kon_ym1, kon_ym2,              // 103:88
	                    n_oki, n_ym2, n_ym1,           //  87:40
	                    pk_oki, pk_ym2, pk_ym1,        //  39:16
	                    n_cmd, last_cmd};              //  15:0

	// ---- OKI phrase-start probe ----
	// From the chip's pins alone (jt6295 is vendored). The driver starts a
	// phrase with a stop byte, the phrase byte, then a channel byte (z80
	// 0x174C); the channel's status bit should then rise. A channel byte whose
	// status bit has not risen 2^22 clk (~49 ms) later is a lost start.
	logic        o_cmd;                     // a phrase byte was the last byte
	logic [7:0]  o_phrase, o_chbyte;
	logic [3:0]  o_pend, o_st_d;
	logic [21:0] o_age;                     // since the oldest pending channel byte
	logic [7:0]  o_n_ch, o_n_rise, o_n_lost, o_lat, o_n_stale, o_fl_max;
	logic [15:0] o_n_fetch;
	logic [11:0] o_fl;                      // current fetch age, clk
	wire  [3:0]  o_st   = oki_dout[3:0];
	wire  [3:0]  o_rise = o_st & ~o_st_d;
	always_ff @(posedge clk) begin
		o_st_d <= o_st;
		if (reset) begin
			o_cmd <= 1'b0; o_pend <= 4'd0;
		end else begin
			if (oki_wr && !oki_wr_d) begin
				if (o_cmd) begin
					o_cmd <= 1'b0; o_chbyte <= d_out;
					o_pend <= o_pend | d_out[7:4];
					if (o_pend == 4'd0) o_age <= 22'd0;
				end else if (d_out[7]) begin
					o_cmd <= 1'b1; o_phrase <= d_out;
				end
			end
			if (o_pend != 4'd0 && ~&o_age) o_age <= o_age + 22'd1;
			if ((o_pend & o_rise) != 4'd0) o_pend <= o_pend & ~o_rise;
			if (&o_age && o_pend != 4'd0) o_pend <= 4'd0;
		end
		if (oki_req && !oki_valid) begin
			if (~&o_fl) o_fl <= o_fl + 12'd1;
		end else o_fl <= 12'd0;
		if (dbg_clear) begin
			o_n_ch <= '0; o_n_rise <= '0; o_n_lost <= '0; o_lat <= '0;
			o_n_stale <= '0; o_fl_max <= '0; o_n_fetch <= '0;
		end else begin
			if (oki_wr && !oki_wr_d && o_cmd && ~&o_n_ch) o_n_ch <= o_n_ch + 8'd1;
			if (o_rise != 4'd0 && ~&o_n_rise) o_n_rise <= o_n_rise + 8'd1;
			if ((o_pend & o_rise) != 4'd0 && o_age[21:14] > o_lat) o_lat <= o_age[21:14];
			if (&o_age && o_pend != 4'd0 && ~&o_n_lost) o_n_lost <= o_n_lost + 8'd1;
			if (oki_valid) begin
				o_n_fetch <= o_n_fetch + 16'd1;
				// completed for an address the chip no longer presents
				if (oki_addr != {oki_bank, oki_rom_addr} && ~&o_n_stale) o_n_stale <= o_n_stale + 8'd1;
				if (o_fl[11:4] > o_fl_max) o_fl_max <= o_fl[11:4];
			end
		end
	end
	assign dbg_oki = {o_n_fetch,                        // 87:72  completed fetches, wrapping
	                  o_n_stale, o_fl_max,              // 71:56  stale completions; worst fetch /16 clk
	                  o_lat, o_n_lost,                  // 55:40  worst start latency /16384 clk; lost starts
	                  o_n_rise, o_n_ch,                 // 39:24  status rises; channel bytes
	                  o_chbyte, o_phrase,               // 23:8   last channel byte; last phrase byte
	                  o_pend, o_st};                    //  7:0

	// ---- Z80 probe ----
	// z_rst_async counts every assertion of `reset` long enough to clock a
	// flop -- what T80's asynchronous reset reacts to; z_rst_sync counts the
	// ones a clk edge sees. Neither is cleared by the reset it counts.
	logic [7:0]  z_rst_async = 8'd0;
	always_ff @(posedge reset) z_rst_async <= z_rst_async + 8'd1;
	logic        z_rst_d = 1'b0;
	logic [7:0]  z_rst_sync;
	logic [15:0] z_pc, z_m1_n64;
	logic [5:0]  z_m1_pre;
	logic [7:0]  z_io_port, z_io_data;
	logic        z_iow_d;
	logic [15:0] z_since_m1;                 // clk since the last opcode fetch, saturating
	wire         z_iow = io_active_wr;
	always_ff @(posedge clk) begin
		z_rst_d <= reset;
		z_iow_d <= z_iow;
		if (dbg_m1) begin z_pc <= a; z_since_m1 <= 16'd0; end
		else if (~&z_since_m1) z_since_m1 <= z_since_m1 + 16'd1;
		if (z_iow && !z_iow_d) begin z_io_port <= a[7:0]; z_io_data <= d_out; end
		if (dbg_clear) begin
			z_rst_sync <= '0; z_m1_n64 <= '0; z_m1_pre <= '0;
		end else begin
			if (reset && !z_rst_d && ~&z_rst_sync) z_rst_sync <= z_rst_sync + 8'd1;
			if (dbg_m1) begin
				z_m1_pre <= z_m1_pre + 6'd1;
				if (&z_m1_pre && ~&z_m1_n64) z_m1_n64 <= z_m1_n64 + 16'd1;
			end
		end
	end
	assign dbg_z80 = {z_rst_async, z_rst_sync,          // 95:80
	                  z_pc,                             // 79:64  PC of the last opcode fetch
	                  z_m1_n64,                         // 63:48  opcode fetches / 64
	                  z_since_m1,                       // 47:32  clk since the last fetch
	                  z_io_port, z_io_data,             // 31:16  last I/O write
	                  4'd0, is_rom_read, rom_pending, rom_done, wait_n,   // 15:8
	                  m1_n, mreq_n, iorq_n, rd_n, wr_n, halt_n, int_n, nmi_n};  // 7:0

	// ---- command transport probe ----
	// The driver takes commands in pairs (NMI handler, z80 0x1E01): a flag at
	// 0x64A9 alternates first and second byte, so one byte lost or read twice
	// swaps every later pair. Shadows of the driver's command state, captured
	// on the Z80's writes, and the latch's write/read timing.
	logic [7:0]  c_64a9, c_64ae, c_64c8, c_64c9, c_6217, c_6218;
	logic        c_unread;                  // a latch write not yet read
	logic [7:0]  c_lost, c_dup, c_nmi, c_busy;
	logic [15:0] c_gap, c_lat, c_lat_max;   // clk, saturating
	logic [15:0] c_gap_min = 16'hFFFF;      // power-up value: no clear has run yet
	// the most recent overwrite of an unread byte: that byte, the new one, and
	// clk since the write it overwrote.
	logic [7:0]  c_lost_old, c_lost_new;
	logic [15:0] c_lost_gap;
	// history: the byte and its gap are known at the write, the driver's pair
	// flag at the read; entry 0 is completed by the read.
	logic [255:0] c_hist;
	logic [23:0]  c_since;                  // clk since the previous write, saturating
	logic [4:0]   c_log2;
	logic         c_rd_d3, c_frz = 1'b0, c_64a9_w_d;
	logic [255:0] c_frz_hist;
	logic [7:0]   c_frz_nmi, c_64a9_at_rd;
	logic [7:0]   c_64a9_other = 8'd0, c_f0_first = 8'd0, c_f0_second = 8'd0, c_b0 = 8'd0;
	logic [15:0]  c_64a9_other_pc;
	logic         c_b0_flag;
	always_comb begin
		c_log2 = 5'd0;
		for (int i = 0; i < 24; i++) if (c_since[i]) c_log2 = 5'(i + 1);
	end
	logic        c_rd_d2, c_m1_d, c_iow_d;
	wire         c_mem_wr = mem_active_wr && is_ram;
	always_ff @(posedge clk) begin
		c_rd_d2 <= latch_rd;
		c_iow_d <= io_active_wr;
		if (c_mem_wr) begin
			case (a)
				16'h64A9: c_64a9 <= d_out;
				16'h64AE: c_64ae <= d_out;
				16'h64C8: c_64c8 <= d_out;
				16'h64C9: c_64c9 <= d_out;
				16'h6217: c_6217 <= d_out;
				16'h6218: c_6218 <= d_out;
				default: ;
			endcase
		end
		if (~&c_gap) c_gap <= c_gap + 16'd1;
		if (c_unread && ~&c_lat) c_lat <= c_lat + 16'd1;
		if (~&c_since) c_since <= c_since + 24'd1;
		if (latch_write && !latch_wr_d) begin
			c_unread <= 1'b1; c_gap <= 16'd0; c_lat <= 16'd0;
			c_since <= 24'd0;
			c_hist <= {c_hist[239:0], 3'b111, c_log2, latch_data};   // flag 7: not read yet
		end else if (latch_rd && !c_rd_d2) begin
			c_unread <= 1'b0;
			c_hist[15:13] <= {2'b00, c_64a9[0]};
		end
		// freeze one clk after the read, with entry 0 completed
		c_rd_d3 <= latch_rd && !c_rd_d2;
		if (c_rd_d3 && !c_frz && c_64a9_at_rd[0] && c_hist[7] && c_hist[7:0] != 8'hB0 && c_hist[7:0] != 8'hF0) begin
			c_frz <= 1'b1; c_frz_hist <= c_hist; c_frz_nmi <= c_nmi;
		end
		if (latch_rd && !c_rd_d2) c_64a9_at_rd <= c_64a9;
		if (c_mem_wr && a == 16'h64A9 && !(z_pc >= 16'h1E00 && z_pc < 16'h1E70) && !c_64a9_w_d) begin
			c_64a9_other <= c_64a9_other + 8'd1; c_64a9_other_pc <= z_pc;
		end
		c_64a9_w_d <= c_mem_wr && a == 16'h64A9;
		if (latch_rd && !c_rd_d2) begin
			if (latch_reg == 8'hF0 && !c_64a9[0]) c_f0_first  <= c_f0_first + 8'd1;
			if (latch_reg == 8'hF0 &&  c_64a9[0]) c_f0_second <= c_f0_second + 8'd1;
			if (latch_reg == 8'hB0) begin c_b0 <= c_b0 + 8'd1; c_b0_flag <= c_64a9[0]; end
		end
		if (dbg_clear) begin
			c_lost <= '0; c_dup <= '0; c_nmi <= '0; c_busy <= '0;
			c_gap_min <= 16'hFFFF; c_lat_max <= '0;
		end else begin
			if (latch_write && !latch_wr_d) begin
				if (c_unread && ~&c_lost) c_lost <= c_lost + 8'd1;
				if (c_unread) begin
					c_lost_old <= latch_reg; c_lost_new <= latch_data; c_lost_gap <= c_gap;
				end
				if (c_gap < c_gap_min) c_gap_min <= c_gap;
			end
			if (latch_rd && !c_rd_d2) begin
				if (!c_unread && ~&c_dup) c_dup <= c_dup + 8'd1;
				if (c_lat > c_lat_max) c_lat_max <= c_lat;
			end
			if (dbg_m1 && a == 16'h0066 && ~&c_nmi) c_nmi <= c_nmi + 8'd1;
			if (io_active_wr && !c_iow_d && a[7:0] == 8'h11 && ~&c_busy) c_busy <= c_busy + 8'd1;
		end
	end
	assign dbg_cmd = {c_lost_old, c_lost_new,                         // 143:128
	                  c_64a9, c_64ae, c_64c8, c_64c9, c_6217, c_6218,   // 127:80
	                  c_lost, c_dup, c_nmi, c_busy,                     //  79:48
	                  c_gap_min, c_lat_max,                             //  47:16
	                  c_lost_gap};                                      //  15:0
	assign dbg_cmd_hist = c_hist;
	// None of these is cleared: they cover the whole run since load.
	assign dbg_cmd_frz  = {c_frz_hist,                                   // 327:72
	                       c_64a9_other_pc,                              //  71:56
	                       c_frz, c_b0_flag, 6'd0, c_frz_nmi,             //  55:40
	                       c_64a9_other, c_b0, c_f0_first, c_f0_second};  //  39:0

endmodule
