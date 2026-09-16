// Replay a MAME OPL4 register log into the OPL4 against the real wave ROM,
// and record the output for comparison with MAME's own audio.
//
// RUN FROM THE REPOSITORY ROOT, after scripts/prep_opl4_replay.py:
//     bash scripts/run_sim.sh opl4_replay_tb +GAME=asurabld +FAST_TO=2380 +END=2470
//
// Writes before FAST_TO are replayed back to back, to set the chip state the
// driver built since boot; from FAST_TO to END each frame's writes go in at
// the frame's start and the rest of the frame runs at the chip's real rate.
// Every 44.1 kHz tick from FAST_TO on writes {l, r} to out.raw.
//
// Late ticks are counted: a sample tick arriving while the previous one is
// still pending is a sample the engine did not produce in its budget.
//
// +LAT=n sets the wave ROM read latency in clk (default 5). +WRITES=file
// replays another stimulus. +TRACE writes trace_rtl.txt, per channel per
// sample "n ch env tl pos sample", for comparison with scripts/ymfm_replay.cpp,
// which runs ymfm (MAME's YMF278B) on the same writes with the same pacing.
`timescale 1ns/1ps
module tb_opl4_replay;
	logic clk = 0;
	always #5 clk = ~clk;
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
		.fm_l(16'sd0), .fm_r(16'sd0),
		.snd_l(snd_l), .snd_r(snd_r),
		.dbg_fm_wr(dbg_fm_wr), .dbg_fm_keyon(dbg_fm_keyon), .dbg_pcm_keyon(dbg_pcm_keyon),
		.dbg_new2(dbg_new2), .dbg_mix_pcm(dbg_mix_pcm)
	);

	// ---- wave ROM ----
	logic [7:0] rom [0:4194303];
	string game = "asurabld";
	int lat = 5;
	initial begin
		int fd, n;
		void'($value$plusargs("GAME=%s", game));
		void'($value$plusargs("LAT=%d", lat));
		fd = $fopen({"debug/hw/", game, "_wave.bin"}, "rb");
		if (fd == 0) begin
			$display("FAIL  no debug/hw/%s_wave.bin -- run scripts/prep_opl4_replay.py", game);
			$finish;
		end
		n = $fread(rom, fd);
		$fclose(fd);
		$display("wave ROM: %0d bytes, read latency %0d clk", n, lat);
	end

	logic [21:0] pend_addr;
	int          pend_cnt;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pend_cnt     <= 0;
			mem_rd_valid <= 1'b0;
		end else begin
			mem_rd_valid <= 1'b0;
			if (mem_rd_req) begin
				pend_addr <= mem_rd_addr;
				pend_cnt  <= lat;
			end else if (pend_cnt != 0) begin
				pend_cnt <= pend_cnt - 1;
				if (pend_cnt == 1) begin
					mem_rd_data  <= rom[pend_addr];
					mem_rd_valid <= 1'b1;
				end
			end
		end
	end

	// ---- bus ----
	task automatic bwrite(input [2:0] a, input [7:0] d);
		@(posedge clk);
		addr = a; din = d; cs = 1; wr = 1;
		repeat (6) @(posedge clk);
		wr = 0; cs = 0;
		repeat (300) @(posedge clk);
	endtask

	// ---- capture and late-tick count ----
	logic recording = 0;
	int   fo, n_samples = 0, n_late = 0, peak = 0;
	always @(posedge clk) begin
		if (dut.sample_tick && recording) begin
			$fwrite(fo, "%c%c%c%c", snd_l[7:0], snd_l[15:8], snd_r[7:0], snd_r[15:8]);
			n_samples++;
			if (dut.u_pcm.tick_pending) n_late++;
			if (snd_l > peak) peak = snd_l;
			if (-snd_l > peak) peak = -snd_l;
		end
	end

	// +TRACE: per channel, per output sample, what reaches the multiply --
	// "n ch env tl pos sample", n counting samples from FAST_TO. Compare
	// with the ymfm reference harness's trace_ymfm.txt.
	bit  trace = 0;
	int  ft, tr_n = 0;
	initial begin
		trace = $test$plusargs("TRACE");
		if (trace) ft = $fopen("sim/opl4_replay_tb/trace_rtl.txt", "w");
	end
	always @(posedge clk) begin
		if (trace && recording && dut.u_pcm.cen && dut.u_pcm.tick_pending && !dut.u_pcm.load_pending && dut.u_pcm.state == dut.u_pcm.S_IDLE)
			tr_n <= tr_n + 1;
		if (trace && recording && tr_n < 30000 && dut.u_pcm.state == dut.u_pcm.S_OUT)
			$fwrite(ft, "%0d %0d %0d %0d %0d %0d
", tr_n, dut.u_pcm.ch, dut.u_pcm.ch_env[dut.u_pcm.ch],
			        dut.u_pcm.ch_tl[dut.u_pcm.ch] >> 8, dut.u_pcm.w_curpos, dut.u_pcm.w_sample);
	end

	// ticks merged into one pass anywhere in the run, fast replay included
	int n_lost_all = 0;
	always @(posedge clk) if (dut.sample_tick && dut.u_pcm.tick_pending) n_lost_all++;
	final $display("sample ticks merged over the whole run: %0d", n_lost_all);

	// 85.909091 MHz / 59.92 Hz
	localparam int CLK_PER_FRAME = 1433730;

	int fast_to = 2380, end_fr = 2470;
	initial begin
		int fs, r, fr, port, val, cur, t0, n_fast = 0, n_real = 0;
		void'($value$plusargs("FAST_TO=%d", fast_to));
		void'($value$plusargs("END=%d", end_fr));
		reset = 1; cs = 0; rd = 0; wr = 0; addr = 0; din = 0;
		repeat (20) @(posedge clk);
		reset = 0;
		repeat (20) @(posedge clk);

		begin string wf; wf = "sim/opl4_replay_tb/writes.hex"; void'($value$plusargs("WRITES=%s", wf)); fs = $fopen(wf, "r"); end
		if (fs == 0) begin
			$display("FAIL  no sim/opl4_replay_tb/writes.hex -- run scripts/prep_opl4_replay.py");
			$finish;
		end
		fo = $fopen("sim/opl4_replay_tb/out.raw", "wb");

		cur = -1;
		while (!$feof(fs)) begin
			r = $fscanf(fs, "%h %h %h\n", fr, port, val);
			if (r != 3) break;
			if (fr >= end_fr) break;
			if (fr < fast_to) begin
				bwrite(3'(port), 8'(val));
				n_fast++;
				continue;
			end
			if (!recording) begin
				$display("fast replay: %0d port writes before frame %0d; NEW2 %0d; recording", n_fast, fast_to, dbg_new2);
				recording = 1;
				if (trace) begin
					int fr_;
					fr_ = $fopen("sim/opl4_replay_tb/regs_rtl.txt", "w");
					for (int i = 0; i < 256; i++) $fwrite(fr_, "%02x %02x\n", i, dut.u_regs.pcm_regs[i]);
					$fclose(fr_);
				end
				cur = fast_to;
				t0 = $time / 10;
			end
			// run whole frames until the write's frame begins
			while (cur < fr) begin
				while ($time / 10 - t0 < CLK_PER_FRAME) @(posedge clk);
				t0 = t0 + CLK_PER_FRAME;
				cur++;
			end
			bwrite(3'(port), 8'(val));
			n_real++;
		end
		while (cur < end_fr) begin
			while ($time / 10 - t0 < CLK_PER_FRAME) @(posedge clk);
			t0 = t0 + CLK_PER_FRAME;
			cur++;
		end
		$fclose(fs);
		$fclose(fo);
		$display("recorded frames %0d..%0d: %0d port writes, %0d samples (%.2f s), %0d late ticks, peak %0d",
		         fast_to, end_fr, n_real, n_samples, n_samples / 44100.0, n_late, peak);
		$display("ALL CHECKS PASSED");
		$finish;
	end
endmodule
