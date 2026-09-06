// FG-3 sound board: Z80 + YMF278B (OPL4), from fuukifg3.cpp.
//
//   Z80       12 MHz / 2 = 6 MHz ("6MHz verified" in the driver), T80se
//   YMF278B   33.8688 MHz, its IRQ on the Z80's INT
//
// Memory map (sound_map):
//   0000-5FFF  ROM, fixed
//   6000-6FFF  RAM, 4 KB (here)
//   7FF0-7FFF  the 16 bytes shared with the 68020 at 0x903FE0
//   8000-FFFF  ROM, banked: 16 entries of 0x8000 from the region base, so
//              the physical address is {bank, a[14:0]} and the fixed region
//              is {4'd0, a[14:0]} -- one 19-bit address covers all 512 KB.
// I/O map (sound_io_map, 8-bit):
//   00     w  ROM bank            30  w  nop ("leftover/unused nmi handler")
//   40-45 rw  YMF278B
//
// There is no sound latch and no NMI on this board: the 68020 and the Z80
// talk through those 16 shared bytes. srom.u7's protocol, read from the
// firmware: at boot the Z80 writes 0xCD to byte 0 and spins until the 68020
// replaces it with 0xAE; its main loop then watches the even bytes for a
// command whose high nibble is 0xA, with the odd byte after it as the
// parameter, and clears the byte once taken. asurabld's boot spins at
// 0x200F6 until byte 0 reads 0xCD, so this Z80 running is what lets the
// 68020 leave its reset code -- it replaces the bring-up stub that used to
// play the Z80's side from fuuki_core.sv.
//
// The OPL4 is Psikyo's (rtl/sound/opl4/, from E:\Arcade-Psikyo_MiSTer):
// full bus protocol, status/ID/BUSY/LD, both timers with IRQ, and the
// 24-channel PCM wavetable engine, running on hardware there. Its FM half
// is not built: FM register writes are accepted and the FM term of the DO2
// mix is zero, so Asura Buster (measured: no FM key-ons at all) is complete
// and Asura Blade is missing its FM cues until the OPL3 lands.
//
// The Z80 side -- T80se, the split WAIT_n, the stretched ROM handshake --
// is fg2_sound.sv's, which is Psikyo's sound_cpu.sv; only the map differs.
module fg3_sound (
	input  logic        clk,
	input  logic        reset,

	// 6 MHz clock enable, from clk (85.909 MHz): 66/945
	input  logic        cen_z80,

	// 68020 side of the shared RAM. Byte addressed 0-15; the CPU wins a
	// same-cycle collision with the Z80, as the bring-up stub did.
	input  logic [3:0]  host_addr,
	input  logic        host_we,
	input  logic [7:0]  host_wdata,
	output logic [7:0]  host_rdata,

	// Z80 program ROM, 512 KB, byte req/valid: req pulses once per access,
	// data must be valid on the cycle valid pulses
	output logic        rom_req,
	output logic [18:0] rom_addr,
	input  logic        rom_valid,
	input  logic [7:0]  rom_data,

	// OPL4 wave ROM, 4 MB, byte req/valid; req is HELD until valid
	output logic        wave_req,
	output logic [21:0] wave_addr,
	input  logic        wave_valid,
	input  logic [7:0]  wave_data,

	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,

	// probes
	output logic        dbg_m1,          // one pulse per Z80 opcode fetch
	output logic        dbg_opl4_wr,     // one pulse per write to the OPL4
	output logic        dbg_fm_keyon,    // FM key-on -- nothing plays it yet
	output logic        dbg_pcm_keyon
);

	// =====================================================================
	// Z80
	// =====================================================================
	logic m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
	logic [15:0] a;
	logic [7:0]  di, d_out;
	logic        wait_n;
	logic        opl4_irq_n;

	T80se #(
		.Mode(0), .T2Write(0), .IOWait(1)
	) u_cpu (
		.RESET_n(~reset), .CLK_n(clk), .CLKEN(cen_z80), .WAIT_n(wait_n),
		.INT_n(opl4_irq_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
		.A(a), .DI(di), .DO(d_out)
	);

	// ---- address decode ----
	wire is_ram    = (a[15:12] == 4'h6);                  // 6000-6FFF
	wire is_shared = (a[15:4]  == 12'h7FF);               // 7FF0-7FFF
	wire is_banked = a[15];                                // 8000-FFFF
	// everything below 0x6000 is the fixed ROM; 0x7000-0x7FEF is unmapped

	logic [3:0] bank;
	assign rom_addr = is_banked ? {bank, a[14:0]} : {4'd0, a[14:0]};

	// ---- RAM, 4 KB ----
	logic [7:0] ram [0:4095];
	logic [7:0] ram_rd_data;
	always_ff @(posedge clk) ram_rd_data <= ram[a[11:0]];

	// ---- shared RAM, 16 bytes, two write ports ----
	// Registers rather than an inferred dual-port RAM: at 16 bytes the flops
	// cost nothing and there is no read-during-write behaviour to depend on.
	logic [7:0] shared [0:15];
	assign host_rdata = shared[host_addr];

	// ---- I/O decode ----
	wire io_active_rd = !iorq_n && !rd_n;
	wire io_active_wr = !iorq_n && !wr_n;
	wire io_bank      = (a[7:0] == 8'h00);
	wire io_opl4      = (a[7:3] == 5'h08) && (a[2:0] <= 3'd5);   // 40-45

	// =====================================================================
	// OPL4
	// =====================================================================
	logic [7:0] opl4_dout;
	logic signed [15:0] opl4_l, opl4_r;

	opl4 u_opl4 (
		.clk(clk), .reset(reset),
		.cs(io_opl4 && !iorq_n), .rd(!rd_n), .wr(!wr_n),
		.addr(a[2:0]), .din(d_out), .dout(opl4_dout), .irq_n(opl4_irq_n),
		.mem_rd_req(wave_req), .mem_rd_addr(wave_addr),
		.mem_rd_valid(wave_valid), .mem_rd_data(wave_data),
		.snd_l(opl4_l), .snd_r(opl4_r),
		.dbg_fm_wr(), .dbg_fm_keyon(dbg_fm_keyon), .dbg_pcm_keyon(dbg_pcm_keyon)
	);

	assign audio_l = opl4_l;
	assign audio_r = opl4_r;

	// =====================================================================
	// Writes, read mux, ROM handshake, WAIT_n
	// =====================================================================
	wire mem_active_rd = !mreq_n && !rd_n;
	wire mem_active_wr = !mreq_n && !wr_n;
	wire is_rom_read   = mem_active_rd && !is_ram && !is_shared;

	logic       rom_done;
	logic [7:0] rom_data_hold;

	always_comb begin
		if (mem_active_rd) begin
			if      (is_ram)    di = ram_rd_data;
			else if (is_shared) di = shared[a[3:0]];
			else                di = rom_data_hold;
		end else if (io_active_rd) begin
			di = io_opl4 ? opl4_dout : 8'hFF;
		end else begin
			di = 8'hFF;
		end
	end

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bank <= 4'd0;
			// Byte 0 powers up at 0xCD only because the firmware writes it;
			// clear the whole block so a reset cannot leave a stale command
			// for the 68020 to act on.
			for (int i = 0; i < 16; i++) shared[i] <= 8'h00;
		end else begin
			if (mem_active_wr && is_ram)    ram[a[11:0]]    <= d_out;
			if (io_active_wr && io_bank)    bank            <= d_out[3:0];
			// The 68020 wins a same-cycle collision.
			if (host_we)                    shared[host_addr] <= host_wdata;
			else if (mem_active_wr && is_shared) shared[a[3:0]] <= d_out;
		end
	end

	// RAM / shared / I/O: one fixed wait cycle, excluding ROM reads so the
	// two schemes never fight over wait_n.
	logic access_started;
	wire access_now        = (!mreq_n || !iorq_n) && (!rd_n || !wr_n);
	wire access_now_nonrom = access_now && !is_rom_read;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) access_started <= 1'b0;
		else       access_started <= access_now_nonrom;
	end

	// ROM: one request per M-cycle, and none after its answer has arrived --
	// is_rom_read stays high for the rest of the clock-enable-stretched
	// T-state, and without !rom_done a second request fires every fetch.
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

	// ---- probes ----
	logic m1_d, oplwr_d;
	wire  m1_active   = !m1_n && !mreq_n && !rd_n;
	wire  opl4_wr_now = io_active_wr && io_opl4;
	always_ff @(posedge clk) begin
		m1_d    <= m1_active;
		oplwr_d <= opl4_wr_now;
	end
	assign dbg_m1      = m1_active && !m1_d;
	assign dbg_opl4_wr = opl4_wr_now && !oplwr_d;

endmodule
