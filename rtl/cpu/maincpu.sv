// Fuuki main CPU: TG68KdotC_Kernel plus address decode and bus sequencing.
//
// One instance serves both boards; the kernel's CPU port selects the mode
// at runtime from the .mra mod byte:
//
//     FG-2   M68000    @ 16 MHz    CPU = 2'b00
//     FG-3   M68EC020  @ 20 MHz    CPU = 2'b11
//
// The kernel is instantiated directly, not through TG68K.vhd (see
// rtl/cpu/tg68k/PROVENANCE.md). Consequences:
//   * busstate: 00 fetch code, 10 read data, 11 write data, 01 no access.
//   * data_in and data_write are separate ports; no tri-state.
//   * No DTACK. The CPU is stalled purely by holding clkena low.
//   * IPL_autovector is tied high.
//
// The data bus is 16 bits in both modes, so FG-3's 32-bit program ROM is
// read as 16-bit words.
//
// IPL is inverted inside the kernel (`IPL_nr <= NOT IPL`): level 3 is
// IPL = 3'b100, so this module drives `ipl = ~level`.

module maincpu (
	input  logic clk,
	input  logic reset,

	input  logic board,   // BOARD_FG2 / BOARD_FG3

	// Program ROM, via a req/valid transport (SDRAM).
	// rom_req is a one-cycle pulse, the SDRAM bridge's contract. A held
	// level does not hang; it re-issues the read and pulses valid repeatedly.
	output logic         rom_req,
	output logic [20:0]  rom_addr,     // word address, up to 2 MB (FG-3)
	input  logic         rom_valid,
	input  logic [15:0]  rom_data,

	// Work RAM: FG-2 0x400000-0x40FFFF, FG-3 also 0x410000-0x41FFFF.
	// One 128 KB array serves both; FG-2 never touches the top half.
	output logic [16:0]  workram_addr,
	output logic         workram_wel, workram_weh,
	output logic [15:0]  workram_wdata,
	input  logic [15:0]  workram_rdata,

	// Tilemap VRAM, 0x500000-0x507FFF: four 8 KB banks in one array.
	// Bank 0 = layer 0, 1 = layer 1, 2/3 = layer 2 double buffer.
	output logic [13:0]  vram_addr,
	output logic         vram_wel, vram_weh,
	output logic [15:0]  vram_wdata,
	input  logic [15:0]  vram_rdata,

	// Sprite RAM, 0x600000-0x601FFF (FG-2 mirrors it at +0x8000).
	output logic [11:0]  spriteram_addr,
	output logic         spriteram_wel, spriteram_weh,
	output logic [15:0]  spriteram_wdata,
	input  logic [15:0]  spriteram_rdata,

	// Palette RAM, 0x700000-0x703FFF: 8192 x xRGB-555.
	output logic [12:0]  palette_addr,
	output logic         palette_wel, palette_weh,
	output logic [15:0]  palette_wdata,
	input  logic [15:0]  palette_rdata,

	// Video registers, 0x8C0000-0x8EFFFF. Sub-decoded by addr[17:16]:
	//   0 -> scroll/offset/raster/flip regs (0x8C0000, 16 words)
	//   1 -> unknown, flipscreen-related    (0x8D0000)
	//   2 -> layer-order priority register  (0x8E0000)
	output logic [4:0]   vregs_addr,     // word index within the 16-word block
	output logic [1:0]   vregs_sel,      // which of the three blocks
	output logic         vregs_wel, vregs_weh,
	output logic [15:0]  vregs_wdata,
	input  logic [15:0]  vregs_rdata,

	// FG-3 only: shared RAM with the Z80, 0x903FE0-0x903FFF.
	output logic [3:0]   sharedram_addr,
	output logic         sharedram_we,
	output logic [7:0]   sharedram_wdata,
	input  logic [7:0]   sharedram_rdata,

	// Input ports, active LOW as the driver reads them.
	input  logic [15:0]  system_in,
	input  logic [15:0]  p1p2_in,
	input  logic [15:0]  dsw_in,
	input  logic [15:0]  dsw2_in,      // FG-3 only

	// FG-2 only: sound command latch at 0x8A0001. The write pulses the
	// Z80's NMI. Decoded for byte, word and long writes.
	output logic [7:0]   latch_data,
	output logic         latch_write,

	// FG-3 only: sprite tile bank, 0xA00000 (long).
	output logic [31:0]  tilebank,

	// Interrupt sources: levels held by the video timing, MAME's HOLD_LINE.
	input  logic         irq1_trig,    // scanline 248
	input  logic         irq3_trig,    // vblank start
	input  logic         irq5_trig,    // programmable raster line

	input  logic         pause,

	// Debug: function code, so a trace can tell a program fetch (6) from a
	// vector/data read (5) from an interrupt acknowledge (7).
	output logic [2:0]   dbg_fc,
	output logic [2:0]   dbg_irq_pending, // {irq5, irq3, irq1} pending
	output logic         dbg_iack,        // interrupt-acknowledge access in progress
	output logic [2:0]   dbg_iack_level   // level on A3..A1 during that access
);


	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	// ---- CPU clock enable ----
	// clk_sys is 945/11 MHz. Both CPU rates sit on the 1/11 MHz grid exactly,
	// so a Bresenham accumulator has zero frequency error:
	//     FG-2  16 MHz = 176/11 MHz  -> 176/945
	//     FG-3  20 MHz = 220/11 MHz  -> 220/945
	// Do not use an integer divide: /5 is 7.4% fast, /6 is 10.5% slow.
	localparam int CE_DEN     = 945;
	localparam int CE_NUM_FG2 = 176;   // 16 MHz
	localparam int CE_NUM_FG3 = 220;   // 20 MHz

	wire [10:0] ce_num = (board == BOARD_FG3) ? 11'(CE_NUM_FG3) : 11'(CE_NUM_FG2);

	logic [10:0] ce_acc;
	logic        cpu_ce;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			ce_acc <= 11'd0;
			cpu_ce <= 1'b0;
		end else if (pause) begin
			cpu_ce <= 1'b0;
		end else if (ce_acc + ce_num >= 11'(CE_DEN)) begin
			ce_acc <= 11'(ce_acc + ce_num - 11'(CE_DEN));
			cpu_ce <= 1'b1;
		end else begin
			ce_acc <= 11'(ce_acc + ce_num);
			cpu_ce <= 1'b0;
		end
	end

	// ---- kernel instance ----
	// Declared before the instantiation: a port connection before the
	// declaration creates an implicit net, then vlog-2388 on the real one.
	logic [31:0] a32;
	logic [15:0] cpu_din, cpu_dout;
	logic [1:0]  busstate;
	logic        nWr, nUDS, nLDS;
	logic [2:0]  fc;
	logic [2:0]  ipl;
	logic        cpu_clkena;

	TG68KdotC_Kernel #(
		// 68020-only feature generics at 2 = "switchable with CPU", so one
		// instance serves both boards.
		.SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
		.MUL_Mode(2), .DIV_Mode(2), .BitField(2),
		.BarrelShifter(0), .MUL_Hardware(1)
	) u_cpu (
		.clk(clk),
		.nReset(~reset),
		.clkena_in(cpu_clkena),
		.data_in(cpu_din),
		.IPL(ipl),
		.IPL_autovector(1'b1),   // all three Fuuki IRQs are autovectored
		.berr(1'b0),             // active HIGH in the kernel; no bus errors here
		.CPU((board == BOARD_FG3) ? 2'b11 : 2'b00),
		.addr_out(a32),
		.data_write(cpu_dout),
		.nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
		.busstate(busstate),
		.longword(),
		.nResetOut(),
		.FC(fc),
		.clr_berr(),
		.skipFetch(),
		.regin_out(), .CACR_out(), .VBR_out()
	);

	// ---- address decode ----
	// Every region is decoded on a range, so word and long accesses land as
	// well as byte ones: FG-3 reads its ports as 16-bit values on a 32-bit
	// bus and writes the sound latch through a 32-bit map with a byte mask.
	wire [23:0] addr24 = a32[23:0];

	// ROM is 1 MB on FG-2, 2 MB on FG-3.
	wire is_rom = (board == BOARD_FG3) ? (addr24 <= 24'h1FFFFF)
	                        : (addr24 <= 24'h0FFFFF);

	wire is_workram   = (addr24 >= 24'h400000) && (addr24 <= 24'h41FFFF);
	wire is_vram      = (addr24 >= 24'h500000) && (addr24 <= 24'h507FFF);

	// FG-2 mirrors sprite RAM at +0x8000 (MAME: .mirror(0x008000)).
	wire is_spriteram = ((addr24 >= 24'h600000) && (addr24 <= 24'h601FFF)) ||
	                    ((board == BOARD_FG2) && (addr24 >= 24'h608000) && (addr24 <= 24'h609FFF));

	wire is_palette   = (addr24 >= 24'h700000) && (addr24 <= 24'h703FFF);

	wire is_system    = (addr24 >= 24'h800000) && (addr24 <= 24'h800003);
	wire is_p1p2      = (addr24 >= 24'h810000) && (addr24 <= 24'h810003);
	wire is_dsw       = (addr24 >= 24'h880000) && (addr24 <= 24'h880003);
	wire is_dsw2      =  (board == BOARD_FG3) && (addr24 >= 24'h890000) && (addr24 <= 24'h890003);

	// FG-2 sound latch: MAME maps a byte at 0x8a0001, reached by byte, word
	// and long writes alike; decode the enclosing word.
	wire is_latch     = (board == BOARD_FG2) && (addr24 >= 24'h8A0000) && (addr24 <= 24'h8A0003);

	wire is_vregs     = (addr24 >= 24'h8C0000) && (addr24 <= 24'h8EFFFF);
	wire is_sharedram =  (board == BOARD_FG3) && (addr24 >= 24'h903FE0) && (addr24 <= 24'h903FFF);
	wire is_tilebank  =  (board == BOARD_FG3) && (addr24 >= 24'hA00000) && (addr24 <= 24'hA00003);

	// FG-3's 0x508000-0x517FFF: MAME calls it "more tilemap, or linescroll?
	// Seems to be empty all of the time". Decoded so accesses terminate, not
	// backed by RAM; reads return zero. docs/ROADMAP.md open item 7.
	wire is_unused_ram = (board == BOARD_FG3) && (addr24 >= 24'h508000) && (addr24 <= 24'h517FFF);

	assign vregs_sel  = addr24[17:16];   // 0 = regs, 1 = unknown, 2 = priority
	assign vregs_addr = addr24[5:1];

	assign workram_addr   = addr24[17:1];
	assign vram_addr      = addr24[14:1];
	assign spriteram_addr = addr24[12:1];
	assign palette_addr   = addr24[13:1];
	assign sharedram_addr = addr24[4:1];

	assign rom_addr = addr24[21:1];

	// ---- bus sequencing ----
	// acc_ready is a level, never a pulse: the CPU samples it once per
	// cpu_ce, roughly every 4-5 clk, so a one-cycle pulse would be missed.
	//
	// a32 is a registered kernel output that changes on a cpu_ce tick, and
	// its decode path is longer than one clk period:
	//     acc_ph 0 : address still settling, do nothing
	//     acc_ph 1 : settled, commit writes here
	//     acc_ph 2 : BRAM has data for the settled address, capture it
	// A write committed at phase 0 goes to a half-settled address.
	logic        acc_ready;
	logic [15:0] acc_data;
	logic [1:0]  acc_ph;
	logic        rom_req_sent;

	wire mem_needed = (busstate != 2'b01);
	wire is_write   = (busstate == 2'b11);

	assign cpu_clkena = cpu_ce && (!mem_needed || acc_ready);

	// Byte lane enables, only meaningful for writes.
	wire wr_l = is_write && !nLDS;
	wire wr_h = is_write && !nUDS;

	// An interrupt-acknowledge cycle is FC = 3'b111 during a real access.
	wire iack = mem_needed && (fc == 3'b111);

	// ---- read mux ----
	// Combinational; captured into acc_data at phase 2.
	logic [15:0] rd_mux;
	always_comb begin
		if      (is_workram)   rd_mux = workram_rdata;
		else if (is_vram)      rd_mux = vram_rdata;
		else if (is_spriteram) rd_mux = spriteram_rdata;
		else if (is_palette)   rd_mux = palette_rdata;
		else if (is_vregs)     rd_mux = vregs_rdata;
		else if (is_sharedram) rd_mux = {8'h00, sharedram_rdata};
		else if (is_system)    rd_mux = system_in;
		else if (is_p1p2)      rd_mux = p1p2_in;
		else if (is_dsw)       rd_mux = dsw_in;
		else if (is_dsw2)      rd_mux = dsw2_in;
		else                   rd_mux = 16'h0000;
	end

	// ---- writes ----
	// Committed at phase 1 only.
	wire wr_now = (acc_ph == 2'd1) && is_write;

	assign workram_wel   = wr_now && is_workram   && wr_l;
	assign workram_weh   = wr_now && is_workram   && wr_h;
	assign vram_wel      = wr_now && is_vram      && wr_l;
	assign vram_weh      = wr_now && is_vram      && wr_h;
	assign spriteram_wel = wr_now && is_spriteram && wr_l;
	assign spriteram_weh = wr_now && is_spriteram && wr_h;
	assign palette_wel   = wr_now && is_palette   && wr_l;
	assign palette_weh   = wr_now && is_palette   && wr_h;
	assign vregs_wel     = wr_now && is_vregs     && wr_l;
	assign vregs_weh     = wr_now && is_vregs     && wr_h;
	assign sharedram_we  = wr_now && is_sharedram && wr_l;

	assign workram_wdata   = cpu_dout;
	assign vram_wdata      = cpu_dout;
	assign spriteram_wdata = cpu_dout;
	assign palette_wdata   = cpu_dout;
	assign vregs_wdata     = cpu_dout;
	assign sharedram_wdata = cpu_dout[7:0];

	// Sound latch: one pulse per write, carrying the low byte (0x8A0001).
	assign latch_data  = cpu_dout[7:0];
	assign latch_write = wr_now && is_latch && wr_l;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) tilebank <= 32'd0;
		else if (wr_now && is_tilebank) begin
			// A 32-bit register on a 16-bit bus: move.l arrives as two word
			// cycles, A00000 then A00002, selected by A1, not by byte lane.
			if (!addr24[1]) begin
				if (wr_h) tilebank[31:24] <= cpu_dout[15:8];
				if (wr_l) tilebank[23:16] <= cpu_dout[7:0];
			end else begin
				if (wr_h) tilebank[15:8]  <= cpu_dout[15:8];
				if (wr_l) tilebank[7:0]   <= cpu_dout[7:0];
			end
		end
	end

	// ---- access state machine ----
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			acc_ph       <= 2'd0;
			acc_ready    <= 1'b0;
			acc_data     <= 16'h0000;
			rom_req      <= 1'b0;
			rom_req_sent <= 1'b0;
		end else begin
			rom_req <= 1'b0;   // a pulse, never held

			if (!mem_needed) begin
				acc_ph       <= 2'd0;
				acc_ready    <= 1'b0;
				rom_req_sent <= 1'b0;
			end else if (acc_ready) begin
				// Hold ready until the CPU steps, then start the next access clean.
				if (cpu_clkena) begin
					acc_ready    <= 1'b0;
					acc_ph       <= 2'd0;
					rom_req_sent <= 1'b0;
				end
			end else if (is_rom && !is_write) begin
				if (!rom_req_sent) begin
					if (acc_ph == 2'd1) begin
						// Issue only once the address has settled.
						rom_req      <= 1'b1;
						rom_req_sent <= 1'b1;
					end else begin
						acc_ph <= acc_ph + 2'd1;
					end
				end else if (rom_valid) begin
					acc_data  <= rom_data;
					acc_ready <= 1'b1;
				end
			end else begin
				// BRAM regions, input ports, write-only registers and the
				// unmapped hole all complete in a fixed three phases.
				if (acc_ph == 2'd2) begin
					acc_data  <= rd_mux;
					acc_ready <= 1'b1;
				end else begin
					acc_ph <= acc_ph + 2'd1;
				end
			end
		end
	end

	assign cpu_din = acc_data;
	assign dbg_fc  = fc;

	// ---- interrupts ----
	// Three HOLD_LINE sources: set on the source's rising edge, hold until
	// the CPU acknowledges. Acknowledge must win over set: each source is a
	// level still asserted when the CPU responds (vblank lasts 22
	// scanlines), so set-wins would never clear the flag and the ISR would
	// re-enter after every RTE.
	//
	// The level to clear is the one the kernel latched when it took the
	// interrupt (rIPL_nr), driven onto A3..A1 during the acknowledge cycle
	// (TG68KdotC_Kernel.vhd, "memaddr_a(4 downto 0) <= '1' & rIPL_nr & '0'").
	// Do not clear the highest pending level instead: a higher interrupt
	// arriving between decision and acknowledge is then dropped untaken.
	//
	// Set from a one-cycle edge, so a set cannot starve the acknowledge. A
	// coincident edge and acknowledge is a new interrupt arriving as an old
	// one is acknowledged; latching it is correct.
	logic irq1_pending, irq3_pending, irq5_pending;
	logic irq1_d, irq3_d, irq5_d;

	wire [2:0] irq_level = irq5_pending ? 3'd5 :
	                       irq3_pending ? 3'd3 :
	                       irq1_pending ? 3'd1 : 3'd0;

	assign ipl = ~irq_level;   // kernel inverts internally; 0 -> 3'b111

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			irq1_pending <= 1'b0;
			irq3_pending <= 1'b0;
			irq5_pending <= 1'b0;
			irq1_d       <= 1'b0;
			irq3_d       <= 1'b0;
			irq5_d       <= 1'b0;
		end else begin
			irq1_d <= irq1_trig;
			irq3_d <= irq3_trig;
			irq5_d <= irq5_trig;

			// Acknowledge, then set: a coincident edge must survive.
			if (iack) begin
				case (addr24[3:1])
					3'd5: irq5_pending <= 1'b0;
					3'd3: irq3_pending <= 1'b0;
					3'd1: irq1_pending <= 1'b0;
					default: ;
				endcase
			end

			if (irq1_trig && !irq1_d) irq1_pending <= 1'b1;
			if (irq3_trig && !irq3_d) irq3_pending <= 1'b1;
			if (irq5_trig && !irq5_d) irq5_pending <= 1'b1;
		end
	end

	// Debug taps, after the declarations they read: vlog rejects
	// use-before-declare.
	assign dbg_irq_pending = {irq5_pending, irq3_pending, irq1_pending};
	assign dbg_iack        = iack;
	assign dbg_iack_level  = addr24[3:1];

endmodule
