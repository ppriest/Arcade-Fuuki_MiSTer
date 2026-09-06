// FG-2 sound board: Z80 + YM2203 + YM3812 + OKI M6295, from fuukifg2.cpp.
//
//   Z80          12 MHz / 2 = 6 MHz           T80se, clock-enabled
//   YM2203       28.640 MHz / 8 = 3.58 MHz    jt03   (write only; no IRQ used)
//   YM3812       28.640 MHz / 8 = 3.58 MHz    jtopl2 (its timer IRQ is the Z80's INT)
//   M6295        32 MHz / 32 = 1 MHz, pin 7 high   jt6295, 4 x 256 KB ROM banks
//
// Memory map (sound_map):
//   0000-5FFF  ROM, fixed
//   6000-7FFF  RAM, 8 KB (here)
//   8000-FFFF  ROM, banked: bank n (0..2) is physical (n+1)*0x8000, so the
//              physical address is {bank+1, a[14:0]} and the fixed region is
//              {0, a[14:0]} -- one 17-bit address covers the 128 KB image.
// I/O map (sound_io_map, 8-bit):
//   00  w  ROM bank (values above 2 are logged and ignored by MAME)
//   11  r  sound latch            20  w  OKI bank = (data & 6) >> 1
//   30  w  nop, "in the NMI routine"
//   40-41  w  YM2203               50-51 rw  YM3812
//   60  r  OKI status              61  w  OKI data
//
// The main CPU's byte write to 0x8A0001 latches the command and PULSES the
// Z80's NMI (MAME: pulse_input_line). There is no acknowledge port: the NMI
// routine reads 0x11 and writes 0x30. So the latch is a plain register and
// the NMI is a pulse held across a few Z80 clock enables, long enough for
// T80's edge detector, which samples on CLKEN.
//
// The Z80 side -- T80se instantiation, address decode shape, the split
// WAIT_n scheme (fixed one-wait for RAM/IO, a real req/valid handshake for
// ROM with the valid pulse stretched into a level the clock-enabled CPU
// cannot miss) -- is the Psikyo core's sound_cpu.sv, whose header records
// why each of those is the way it is; only the map differs.
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

	// Mute either half at runtime. FM is the YM2203 + YM3812 pair, PCM the
	// OKI -- the same split the FG-3 board's switches make, so one pair of
	// OSD entries serves both.
	input  logic        en_fm,
	input  logic        en_pcm,

	// mono, signed
	output logic signed [15:0] audio,

	// probes
	output logic        dbg_m1,      // one pulse per Z80 opcode fetch
	output logic        dbg_ym_wr    // one pulse per write to either FM chip
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
	// (everything else below 0x6000 is the fixed ROM)

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

	// ---- sound latch and NMI ----
	// NMI_PULSE clock enables low: T80 detects the falling edge on a CLKEN
	// tick, so the pulse must straddle at least one; several, for margin.
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

	// jt03 / jtopl derive their write strobe as !cs_n && !wr_n, so cs_n
	// must carry the I/O qualifier as well as the address decode: WR_n is
	// asserted for memory writes too, and a RAM write to any 0x6x50 would
	// otherwise land in the OPL's register file. The strobe then spans one
	// I/O cycle -- jtopl_mmr samples it every clock and jt12 on its enable,
	// both idempotent for a repeated register write.
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

	// jt6295 detects its own falling edge of wrn on clk, so the level is
	// exactly one write per Z80 I/O cycle. ss = 1: pin 7 high, /132.
	logic [17:0] oki_rom_addr;
	logic [7:0]  oki_rom_data;
	logic        oki_rom_ok;
	jt6295 #(.INTERPOL(0)) u_oki (
		.rst(reset), .clk(clk), .cen(cen_oki), .ss(1'b1),
		.wrn(~(io_active_wr && io_oki_wr)), .din(d_out), .dout(oki_dout),
		.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok),
		.sound(oki_snd), .sample()
	);

	// The chip's ROM bus is a level interface: it sets rom_addr and expects
	// rom_data for it, with rom_ok saying the data is there. Turn each new
	// address into one held request, and hold the answer with its address
	// so rom_ok stays true only while the chip still asks for that byte.
	logic [17:0] oki_hold_addr;
	logic        oki_hold_ok;
	assign oki_addr = {oki_bank, oki_rom_addr};
	assign oki_req  = (oki_rom_addr != oki_hold_addr) || !oki_hold_ok;
	assign oki_rom_ok = oki_hold_ok && (oki_rom_addr == oki_hold_addr);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			oki_hold_addr <= 18'd0;
			oki_hold_ok   <= 1'b0;
			oki_rom_data  <= 8'd0;
		end else begin
			if (oki_valid) begin
				oki_hold_addr <= oki_rom_addr;
				oki_rom_data  <= oki_data;
				oki_hold_ok   <= 1'b1;
			end else if (oki_rom_addr != oki_hold_addr) begin
				oki_hold_ok   <= 1'b0;
			end
		end
	end

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

	// ROM: one request per M-cycle, and none after its answer has arrived
	// -- is_rom_read stays high for the rest of the clock-enable-stretched
	// T-state, and without !rom_done a second request fired every fetch.
	logic rom_pending;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) rom_pending <= 1'b0;
		else if (is_rom_read && !rom_pending && !rom_done) rom_pending <= 1'b1;
		else if (rom_valid) rom_pending <= 1'b0;
	end
	assign rom_req = is_rom_read && !rom_pending && !rom_done;

	// Stretch the one-clock valid into a level held until the M-cycle ends;
	// the data is latched alongside so di is stable for the whole window.
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
	// in 1/32 steps: 5, 10, 27 -- 0.156, 0.313, 0.844. The OKI's 14-bit
	// output is brought to 16 bits first. The gains sum past unity, so the
	// sum saturates rather than wrapping.
	// =====================================================================
	wire signed [15:0] oki16 = {oki_snd, 2'b00};
	wire signed [15:0] ym1_g = en_fm  ? ym1_snd : 16'sd0;
	wire signed [15:0] ym2_g = en_fm  ? ym2_snd : 16'sd0;
	wire signed [15:0] oki_g = en_pcm ? oki16   : 16'sd0;
	wire signed [21:0] mix = (22'(ym1_g) * 22'sd5) + (22'(ym2_g) * 22'sd10) + (22'(oki_g) * 22'sd27);
	wire signed [16:0] mix32 = 17'(mix >>> 5);
	always_ff @(posedge clk) begin
		if      (mix32 >  17'sd32767) audio <= 16'sd32767;
		else if (mix32 < -17'sd32768) audio <= -16'sd32768;
		else                          audio <= 16'(mix32);
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

endmodule
