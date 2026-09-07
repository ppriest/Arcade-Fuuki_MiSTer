// Replay Asura Buster's coin chime into the OPL4 and watch its envelope.
//
// RUN FROM THE REPOSITORY ROOT:  bash scripts/run_sim.sh opl4_chime_tb
// Needs debug/hw/opm_u6.bin -- the real 4 MB wave ROM, extracted from
// roms/asurabus.zip (scripts/opl4_log.py's WAVE_ROM). Gitignored.
//
// The register sequence is the one the sound driver sent for the chime,
// captured from MAME with scripts/opl4_log.py (coin at frame 2400, channel
// 23 written at frame 2402), in the same order and with Z80-like pacing.
// The wavetable header the wave number points at -- wave 289: 8-bit,
// AR=15 DR=2 SL=14 SR=0 RC=0 RR=1 -- is loaded by the chip from the ROM
// exactly as in the FPGA build.
//
// What it decides. The voice plays at oct=-1 with the header's RC=0, so the
// reference's rate correction is (oct+RC)*2 + fnum[9] = -2 and the decay
// rate 2*4-2 = 6: slow, from full level. A correction handled as unsigned
// turns -2 into 62, clamps the rate to 63 and drops the envelope to SL=14
// (0x1C0, about -42 dB) in its first clock. Rate 6 steps the envelope about
// once every 2048 samples, so after 100 ms of samples it has barely moved:
//   PASS  envelope at 100 ms  <  0x040  (decaying slowly from full)
//   FAIL  envelope at 100 ms  >= 0x180  (already parked at SL=14)
// The output peak per 10 ms is printed alongside, and it should sit near
// its first-bin value throughout rather than collapsing after the first.
`timescale 1ns/1ps
module tb_opl4_chime;
	logic clk = 0;
	always #5 clk = ~clk;          // the chip's Bresenham is per clk; absolute rate is irrelevant here
	logic reset;

	logic        cs, rd, wr;
	logic [2:0]  addr;
	logic [7:0]  din, dout;
	logic        irq_n;
	logic        mem_rd_req, mem_rd_valid;
	logic [21:0] mem_rd_addr;
	logic [7:0]  mem_rd_data;
	logic signed [15:0] snd_l, snd_r;
	logic        dbg_fm_wr, dbg_fm_keyon, dbg_pcm_keyon, dbg_new2;
	logic [5:0]  dbg_mix_pcm;

	opl4 dut (
		.clk(clk), .reset(reset),
		.cs(cs), .rd(rd), .wr(wr), .addr(addr), .din(din), .dout(dout), .irq_n(irq_n),
		.mem_rd_req(mem_rd_req), .mem_rd_addr(mem_rd_addr),
		.mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data),
		.fm_l(16'sd0), .fm_r(16'sd0), .en_fm(1'b1), .en_pcm(1'b1),
		.snd_l(snd_l), .snd_r(snd_r),
		.dbg_fm_wr(dbg_fm_wr), .dbg_fm_keyon(dbg_fm_keyon), .dbg_pcm_keyon(dbg_pcm_keyon),
		.dbg_new2(dbg_new2), .dbg_mix_pcm(dbg_mix_pcm)
	);

	// ---- the real wave ROM ----
	logic [7:0] rom [0:4194303];
	int fd, nread;
	initial begin
		fd = $fopen("debug/hw/opm_u6.bin", "rb");
		if (fd == 0) begin
			$display("FAIL  cannot open debug/hw/opm_u6.bin -- extract opm.u6 from roms/asurabus.zip there");
			$finish;
		end
		nread = $fread(rom, fd);
		$fclose(fd);
		$display("wave ROM: %0d bytes", nread);
	end

	// SDRAM-ish latency, as Psikyo's bench models it: valid five clocks after req
	logic [21:0] pend_addr;
	logic [2:0]  pend_cnt;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pend_cnt     <= 3'd0;
			mem_rd_valid <= 1'b0;
			mem_rd_data  <= 8'd0;
		end else begin
			mem_rd_valid <= 1'b0;
			if (mem_rd_req) begin
				pend_addr <= mem_rd_addr;
				pend_cnt  <= 3'd5;
			end else if (pend_cnt != 0) begin
				pend_cnt <= pend_cnt - 3'd1;
				if (pend_cnt == 3'd1) begin
					mem_rd_data  <= rom[pend_addr];
					mem_rd_valid <= 1'b1;
				end
			end
		end
	end

	// ---- bus helpers, Z80-paced ----
	// The driver's OUT instructions are a few microseconds apart; each write
	// here is followed by 300 clk (3 us) so the header load between the
	// wave-number write and the key-on gets the time it gets on the board.
	task automatic bwrite(input [2:0] a, input [7:0] d);
		@(posedge clk);
		addr = a; din = d; cs = 1; wr = 1;
		repeat (6) @(posedge clk);
		wr = 0; cs = 0;
		repeat (300) @(posedge clk);
	endtask
	task automatic fm_wr(input [8:0] a, input [7:0] d);
		if (a[8]) bwrite(3'd2, a[7:0]); else bwrite(3'd0, a[7:0]);
		bwrite(a[8] ? 3'd3 : 3'd1, d);
	endtask
	task automatic pcm_wr(input [7:0] a, input [7:0] d);
		bwrite(3'd4, a);
		bwrite(3'd5, d);
	endtask

	// ---- observation: output peak per 10 ms bin, and channel 23's envelope ----
	localparam int CH = 23;
	int peak_bin = 0, peak_all = 0, samples = 0, mag = 0;
	logic snd_tick_d = 0;
	int env_at_100ms = -1;
	int peak_first_bin = -1;
	int bin = 0;

	// one output sample per rising edge of the engine's sample tick
	wire sample_tick = dut.u_pcm.tick_pending;
	logic tick_d = 0;
	always @(posedge clk) begin
		tick_d <= sample_tick;
		if (sample_tick && !tick_d) begin
			samples++;
			// ModelSim 10.5b has no $abs; take the magnitude by hand
			mag = (snd_l < 0) ? -int'(snd_l) : int'(snd_l);
			if (mag > peak_bin) peak_bin = mag;
			if (mag > peak_all) peak_all = mag;
		end
	end

	task automatic report_bin(input int ms);
		$display("  %3d ms  peak|snd_l| %5d   ch%0d env 0x%03h  eg_state %0d  tl %0d  fmt %0d  base %06h",
		         ms, peak_bin, CH, dut.u_pcm.ch_env[CH], dut.u_pcm.ch_eg_state[CH],
		         dut.u_pcm.ch_tl[CH] >> 10, dut.u_pcm.ch_format[CH], dut.u_pcm.ch_baseaddr[CH]);
		if (peak_first_bin < 0) peak_first_bin = peak_bin;
		peak_bin = 0;
	endtask

	// ~1948 clk per output sample; 10 ms is 441 samples at 44.1 kHz
	task automatic wait_samples(input int n);
		int target;
		target = samples + n;
		while (samples < target) @(posedge clk);
	endtask

	int errors = 0;
	initial begin
		$display("=== tb_opl4_chime: Asura Buster's coin chime, wave 289 on channel 23 ===");
		reset = 1; cs = 0; rd = 0; wr = 0; addr = 0; din = 0;
		repeat (20) @(posedge clk);
		reset = 0;
		repeat (20) @(posedge clk);

		// the driver's init: OPL3 NEW + NEW2, without which no PCM key-on counts
		fm_wr(9'h105, 8'h03);
		if (!dbg_new2) begin errors++; $display("FAIL  NEW2 not set"); end

		// the captured sequence, frame 2402, in order
		pcm_wr(8'h67, 8'h00);   // TL=0  LD=0
		pcm_wr(8'hAF, 8'h00);   // AR/DR (overwritten by the header below)
		pcm_wr(8'hC7, 8'h0F);   // SL/SR
		pcm_wr(8'hDF, 8'hF0);   // RC/RR
		pcm_wr(8'hF7, 8'hFF);   // AM
		pcm_wr(8'h67, 8'h02);   // TL=1  LD=0
		pcm_wr(8'h37, 8'h01);   // wave hi bit = 1, fnum lo = 0
		pcm_wr(8'h1F, 8'h21);   // wave lo = 0x21 -> wave 289: header load
		pcm_wr(8'h67, 8'h02);
		pcm_wr(8'h37, 8'h01);
		pcm_wr(8'h4F, 8'hF0);   // oct = -1, fnum hi = 0, no reverb
		pcm_wr(8'h7F, 8'h80);   // key on, pan 0, no damp

		$display("  header loaded: fmt %0d base %06h loop %04h end %04h  (expect 0 33df2c 8000 8784)",
		         dut.u_pcm.ch_format[CH], dut.u_pcm.ch_baseaddr[CH],
		         dut.u_pcm.ch_loop[CH], dut.u_pcm.ch_end[CH]);
		if (dut.u_pcm.ch_baseaddr[CH] !== 22'h33df2c) begin
			errors++; $display("FAIL  header base address wrong");
		end

		samples = 0; peak_bin = 0; peak_all = 0;
		for (int ms = 10; ms <= 120; ms += 10) begin
			wait_samples(441);
			report_bin(ms);
			if (ms == 100) env_at_100ms = dut.u_pcm.ch_env[CH];
		end

		$display("");
		$display("  envelope at 100 ms: 0x%03h   (rate 6 decays slowly from 0; rate 63 parks at SL=14 = 0x1c0)", env_at_100ms);
		if (env_at_100ms >= 'h180) begin
			errors++;
			$display("  FAIL  the envelope is parked at the sustain level: the decay rate was clamped to 63");
		end else if (env_at_100ms < 'h040) begin
			$display("  PASS  the envelope is decaying slowly from full level");
		end else begin
			errors++;
			$display("  FAIL  envelope neither near 0 nor at SL -- unexpected rate");
		end
		if (peak_all == 0) begin
			errors++; $display("  FAIL  no output at all");
		end
		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	// watchdog
	initial begin
		#400ms;
		$display("FAIL  watchdog: bench did not finish");
		$finish;
	end
endmodule
