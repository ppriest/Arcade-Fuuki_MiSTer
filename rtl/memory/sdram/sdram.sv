//
// sdram.sv
//
// SDR SDRAM controller, adapted from Sorgelig's sdram.v (Copyright (c)
// 2018 Sorgelig, GPL-3.0-or-later) -- see PROVENANCE.md in this directory
// for exactly what was changed from upstream (sdram_upstream_reference.sv)
// and why: burst-of-4 read support, so a 64-bit gfx-ROM granule (this
// project's tile-row unit) comes back as one transaction instead of four.
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

module sdram
(
	// interface to the MT48LC16M16 chip
	inout       [15:0] SDRAM_DQ,   // driven via dq_oe/dq_out; vlog -sv rejects upstream's `inout reg`
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,        // init signal after FPGA config to initialize RAM
	input             clk,         // sdram is accessed at up to 128MHz

	// Three ports, fixed priority 0 > 1 > 2. Reads: addr is the word address
	// of the first of 4 sequential words forming one 64-bit granule; its low
	// 2 bits should be 00. Writes are single-word; wrl/wrh select byte lanes.
	// req/ack: toggle req to request, ack takes req's value at completion.
	input      [25:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [63:0] dout0,
	input             req0,
	output reg        ack0 = 1'b0,   // initialised for simulation, as `state` below

	input      [25:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [63:0] dout1,
	input             req1,
	output reg        ack1 = 1'b0,

	input      [25:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [63:0] dout2,
	input             req2,
	output reg        ack2 = 1'b0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@85MHz
localparam BURST_LENGTH   = 3'd2; // 0=1, 1=2, 2=4, 3=8, 7=full page -- 4, for one 64-bit granule
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved -- sequential: words in ascending address order
localparam CAS_LATENCY    = 3'd2; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam STATE_IDLE   = 4'd0;                // state to check the requests
localparam STATE_START  = STATE_IDLE+4'd1;     // state in which a new command is started
localparam STATE_CONT   = STATE_START+RASCAS_DELAY;
localparam STATE_READ0  = STATE_CONT+CAS_LATENCY+4'd1;   // +1: upstream's STATE_READY margin, see PROVENANCE.md
localparam STATE_READ1  = STATE_READ0+4'd1;
localparam STATE_READ2  = STATE_READ0+4'd2;
localparam STATE_READ3  = STATE_READ0+4'd3;
localparam STATE_LAST   = STATE_READ3;         // last state in cycle

reg  [3:0] state = 4'd0;   // explicit: an X here never reaches STATE_LAST in simulation, so init never advances
reg [22:1] a;
reg        a25;   // byte address bit 25: column bit A9 on a 64 MB chip
reg [15:0] data;
reg        we;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg        active = 0;
reg  [2:0] ram_req = 0;
wire [2:0] wr = {wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

// Module level, not block-local: Quartus 17.0 rejects non-blocking
// assignments to block-local regs, static or not.
reg [9:0] rfs_cnt = 10'd0;
reg        rfs = 1'b0, rfs2 = 1'b0;
reg         init_old = 1'b0;

reg [63:0] dout;

assign dout0 = dout;
assign dout1 = dout;
assign dout2 = dout;

// Declared before the access-manager block that reads them; vlog -sv does
// not resolve the forward reference.
localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

reg [1:0] mode;
reg [4:0] reset=5'h1f;

// access manager
always @(posedge clk) begin
	rfs_cnt <= rfs_cnt + 1'd1;
	// 8192 auto-refreshes per 64 ms = one per 7.8125 us. At 85.909091 MHz
	// that is 671 cycles; 670 = 7.80 us. Upstream's 850 is 27% over spec,
	// and the refresh is also deferred by traffic (rfs <= rfs2 below).
	if (rfs_cnt == 670) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == 335) rfs2 <= 1;   // half of the interval above

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if (rfs) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			we <= 0;
			dqm <= 2'b00;
			active <= 0;
			state <= STATE_START;
		end
		else if (ack0 != req0) begin
			{a25,ba,a} <= addr0;
			data <= din0;
			we <= wr[0];
			dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00;
			active <= 1;
			ram_req[0] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack1 != req1) begin
			{a25,ba,a} <= addr1;
			data <= din1;
			we <= wr[1];
			dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00;
			active <= 1;
			ram_req[1] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack2 != req2) begin
			{a25,ba,a} <= addr2;
			data <= din2;
			we <= wr[2];
			dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00;
			active <= 1;
			ram_req[2] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
	end

	// Burst-of-4 read capture, one lane per cycle, ascending address order:
	// lane 0 is the lowest address, dout[15:0]. Writes complete at
	// STATE_READ3 too, with no capture.
	if (state == STATE_READ0 && ram_req && !we) dout[15:0]  <= SDRAM_DQ;
	if (state == STATE_READ1 && ram_req && !we) dout[31:16] <= SDRAM_DQ;
	if (state == STATE_READ2 && ram_req && !we) dout[47:32] <= SDRAM_DQ;
	if (state == STATE_READ3 && ram_req) begin
		if (!we) dout[63:48] <= SDRAM_DQ;
		active <= 0;
		ram_req <= 0;
		if (ram_req[0]) ack0 <= req0;
		else if (ram_req[1]) ack1 <= req1;
		else if (ram_req[2]) ack2 <= req2;
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 4'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end


// initialization
always @(posedge clk) begin
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
reg         dq_oe;
reg  [15:0] dq_out;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bz;

always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? ba : 2'b00;

	dq_oe <= 1'b0;
	casex({active,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= active ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin
			{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
			dq_oe  <= 1'b1;
			dq_out <= data;
		end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(state)
			// Row = high bits, column = low bits, the reverse of upstream.
			// A burst auto-increments the column, so the 4 words of a granule
			// must sit in consecutive columns of one row.
			STATE_START: SDRAM_A <= a[22:10];
			// A10 = auto-precharge. A9 = byte address bit 25: column bit 9 on
			// the 64 MB chip, ignored by the 32 MB chip, so the low 32 MB map
			// identically on both. The 128 MB module's second chip would be
			// byte address bit 26, which this core does not use.
			STATE_CONT:  SDRAM_A <= {dqm, 1'b1, a25, a[9:1]};
		endcase
	end
	else if(mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
end

// Upstream drives SDRAM_CLK through an altddio_out instance. Not vendored:
// the top level drives the phase-shifted pin clock itself, and this keeps
// the module simulable without altera_mf.
assign SDRAM_CLK = clk;

endmodule
