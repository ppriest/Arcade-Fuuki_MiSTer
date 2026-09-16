// Synthesis/timing harness for maincpu + TG68K.C. Not a simulation model.
//
// maincpu has more port bits than the device has pins: inputs come from a
// pattern register, outputs are XOR-reduced onto one pin. Unconnected outputs
// would let Quartus optimise the CPU away. BRAM read data is registered, not
// constant, so the fitter cannot fold the read mux and flatter the report.

module maincpu_synth_top (
	input  logic clk,
	input  logic rst_n,
	input  logic stim,
	output logic result
);

	logic reset;
	assign reset = ~rst_n;

	logic [31:0] pat;
	always_ff @(posedge clk or posedge reset)
		if (reset) pat <= 32'h1234_5678;
		else       pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

	logic        rom_req;
	logic [20:0] rom_addr;
	logic [15:0] rom_data;
	logic        rom_valid;

	logic [16:0] workram_addr;
	logic        workram_wel, workram_weh;
	logic [15:0] workram_wdata, workram_rdata;

	logic [13:0] vram_addr;
	logic        vram_wel, vram_weh;
	logic [15:0] vram_wdata, vram_rdata;

	logic [11:0] spriteram_addr;
	logic        spriteram_wel, spriteram_weh;
	logic [15:0] spriteram_wdata, spriteram_rdata;

	logic [12:0] palette_addr;
	logic        palette_wel, palette_weh;
	logic [15:0] palette_wdata, palette_rdata;

	logic [4:0]  vregs_addr;
	logic [1:0]  vregs_sel;
	logic        vregs_wel, vregs_weh;
	logic [15:0] vregs_wdata, vregs_rdata;

	logic [3:0]  sharedram_addr;
	logic        sharedram_we;
	logic [7:0]  sharedram_wdata, sharedram_rdata;

	logic [7:0]  latch_data;
	logic        latch_write;
	logic [31:0] tilebank;

	always_ff @(posedge clk) begin
		rom_data        <= pat[15:0];
		rom_valid       <= pat[16];
		workram_rdata   <= pat[15:0]  ^ 16'hA5A5;
		vram_rdata      <= pat[15:0]  ^ 16'h5A5A;
		spriteram_rdata <= pat[15:0]  ^ 16'h0FF0;
		palette_rdata   <= pat[15:0]  ^ 16'hF00F;
		vregs_rdata     <= pat[15:0]  ^ 16'h1234;
		sharedram_rdata <= pat[7:0];
	end

	maincpu dut (
		.clk(clk), .reset(reset),
		.board(pat[31]),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.workram_addr(workram_addr), .workram_wel(workram_wel), .workram_weh(workram_weh),
		.workram_wdata(workram_wdata), .workram_rdata(workram_rdata),
		.vram_addr(vram_addr), .vram_wel(vram_wel), .vram_weh(vram_weh),
		.vram_wdata(vram_wdata), .vram_rdata(vram_rdata),
		.spriteram_addr(spriteram_addr), .spriteram_wel(spriteram_wel),
		.spriteram_weh(spriteram_weh), .spriteram_wdata(spriteram_wdata),
		.spriteram_rdata(spriteram_rdata),
		.palette_addr(palette_addr), .palette_wel(palette_wel), .palette_weh(palette_weh),
		.palette_wdata(palette_wdata), .palette_rdata(palette_rdata),
		.vregs_addr(vregs_addr), .vregs_sel(vregs_sel),
		.vregs_wel(vregs_wel), .vregs_weh(vregs_weh),
		.vregs_wdata(vregs_wdata), .vregs_rdata(vregs_rdata),
		.sharedram_addr(sharedram_addr), .sharedram_we(sharedram_we),
		.sharedram_wdata(sharedram_wdata), .sharedram_rdata(sharedram_rdata),
		.system_in(pat[15:0]), .p1p2_in(pat[31:16]),
		.dsw_in(pat[15:0] ^ 16'hFFFF), .dsw2_in(pat[31:16] ^ 16'hFFFF),
		.latch_data(latch_data), .latch_write(latch_write), .latch_busy(1'b0),
		.tilebank(tilebank),
		.irq1_trig(pat[3]), .irq3_trig(pat[7]), .irq5_trig(pat[11]),
		.pause(1'b0)
	);

	always_ff @(posedge clk)
		result <= ^{rom_req, rom_addr,
		            workram_addr, workram_wel, workram_weh, workram_wdata,
		            vram_addr, vram_wel, vram_weh, vram_wdata,
		            spriteram_addr, spriteram_wel, spriteram_weh, spriteram_wdata,
		            palette_addr, palette_wel, palette_weh, palette_wdata,
		            vregs_addr, vregs_sel, vregs_wel, vregs_weh, vregs_wdata,
		            sharedram_addr, sharedram_we, sharedram_wdata,
		            latch_data, latch_write, tilebank};

endmodule
