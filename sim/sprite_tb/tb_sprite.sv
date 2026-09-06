// The whole sprite path against a REAL captured frame:
//   spriteram (captured) -> sprite_line_list -> sprite_line_engine
//                        -> line_buffer #(.WIDTH(16)) -> a rendered frame
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh sprite_tb), after
//     python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile
//
// Drives a real 456x262 line cadence rather than "pulse line_start and wait",
// because the line pulse is a hard resync point and the interesting failure --
// an engine still busy when the next line begins -- only exists if lines
// actually arrive on time. LESSONS_LEARNED, "Ask of every stimulus whether it
// is the shape the real system produces".
//
// Expected content, derived independently from the captured spriteram (see
// tb_spritelist): "CREDIT 0" at (260,230) and a 32x32 sprite at (105,108).

`timescale 1ns/1ps

module tb_sprite;

	localparam logic BOARD_FG2 = 1'b0, BOARD_FG3 = 1'b1;   // .mra mod byte bit 0
	localparam real HALF = 5.8207;
	localparam int  H_TOTAL = 456, V_TOTAL = 262, H_ACTIVE = 320, V_ACTIVE = 240;
	localparam int  W = 320, H = 240;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	// ---- pixel clock and raster, as video_timing produces them ----
	logic [3:0] ce_div = 0;
	wire        ce_pix = (ce_div == 4'd0);
	always_ff @(posedge clk) ce_div <= (ce_div == 4'd11) ? 4'd0 : ce_div + 4'd1;

	logic [8:0] hcnt = 0, vcnt = 0;
	always_ff @(posedge clk) if (ce_pix) begin
		if (hcnt == 9'(H_TOTAL-1)) begin
			hcnt <= 0;
			vcnt <= (vcnt == 9'(V_TOTAL-1)) ? 9'd0 : vcnt + 9'd1;
		end else hcnt <= hcnt + 9'd1;
	end

	wire line_tick   = ce_pix && (hcnt == 9'(H_ACTIVE));
	wire frame_start = line_tick && (vcnt == 9'(V_ACTIVE));
	// vcnt+2 wrapped: the sprite path needs one more line of lead than the
	// tilemaps, because the line buffer swaps at line_start so a bank filled
	// after one pulse is not displayed until after the next.
	wire [8:0] vcnt_next2 = (vcnt >= 9'(V_TOTAL-2)) ? (vcnt - 9'(V_TOTAL-2)) : (vcnt + 9'd2);

	// ---- sprite RAM (captured), read by the list builder ----
	logic [15:0] sram [0:4095];
	logic [11:0] sr_addr;
	logic [15:0] sr_data;
	always_ff @(posedge clk) sr_data <= sram[sr_addr];

	// ---- candidate list ----
	logic        build_busy;
	logic [10:0] n_entries;
	logic [9:0]  yt_addr, rec_addr;
	logic [18:0] yt_data;
	logic [63:0] rec_data;

	sprite_line_list u_list (
		.clk(clk), .reset(reset),
		.build_start(frame_start), .build_busy(build_busy), .n_entries(n_entries),
		.sr_addr(sr_addr), .sr_data(sr_data),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data)
	);

	// ---- engine ----
	logic        eng_busy, ovr_ev;
	logic        gfx_req, gfx_valid;
	logic [24:0] gfx_addr;
	logic [63:0] gfx_data;
	logic        lb_we;
	logic [8:0]  lb_x;
	logic [15:0] lb_wdata;

	// Declared BEFORE the expressions that use them: referencing a signal
	// before its declaration makes the tool infer an implicit net and then
	// reject the real one (vlog-2388/2730).
	logic        lb_ready;
	logic        lb_ready_d, lb_ready_rise;
	logic        capture_on = 0;

	// The engine starts only when the buffer is ready and the list is stable.
	wire         eng_start = lb_ready_rise && !build_busy;

	always_ff @(posedge clk) begin
		lb_ready_d    <= lb_ready;
		lb_ready_rise <= lb_ready && !lb_ready_d;
	end

	sprite_line_engine u_eng (
		.clk(clk), .reset(reset),
		.line_tick(line_tick), .line_start(eng_start), .render_line(vcnt_next2),
		.busy(eng_busy), .ovr_ev(ovr_ev),
		.board(BOARD_FG2), .tilebank(32'd0), .gfx_base(26'd0), .spr_reverse(1'b0),
		.n_entries(n_entries),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data),
		.gfx_req(gfx_req), .gfx_addr(gfx_addr),
		.gfx_valid(gfx_valid), .gfx_data(gfx_data),
		.lb_we(lb_we), .lb_x(lb_x), .lb_data(lb_wdata)
	);

	// ---- line buffer ----
	logic [8:0]  lb_rx;
	logic [15:0] lb_rdata;

	line_buffer #(.WIDTH(16)) u_lb (
		.clk(clk), .reset(reset),
		.line_start(line_tick), .ready(lb_ready),
		.we(lb_we), .wx(lb_x), .wdata(lb_wdata),
		.rx(lb_rx), .rdata(lb_rdata)
	);

	// ---- graphics ROM, realistic latency ----
	localparam int GFX_LAT = 12;
	byte unsigned gfx [0:2*1024*1024-1];
	int   gfx_ctr = 0, gfx_reads = 0;
	logic gfx_busy = 0;
	logic [24:0] gfx_lat_addr;

	always_ff @(posedge clk) begin
		gfx_valid <= 1'b0;
		if (reset) gfx_busy <= 1'b0;
		else if (!gfx_busy) begin
			if (gfx_req) begin
				gfx_busy     <= 1'b1;
				gfx_lat_addr <= gfx_addr;
				gfx_ctr      <= GFX_LAT;
			end
		end else if (gfx_ctr > 1) gfx_ctr <= gfx_ctr - 1;
		else begin
			for (int b = 0; b < 8; b++)
				gfx_data[8*b +: 8] <= gfx[gfx_lat_addr + b];
			gfx_valid <= 1'b1;
			gfx_busy  <= 1'b0;
			gfx_reads <= gfx_reads + 1;
		end
	end

	// ---- capture the displayed frame by reading the buffer during scanout ----
	logic [15:0] frame [0:H-1][0:W-1];
	always @(posedge clk) if (ce_pix && (hcnt < 9'(H_ACTIVE)) && (vcnt < 9'(V_ACTIVE)))
		lb_rx <= hcnt;
	// One-cycle read latency, so the value read belongs to the previous hcnt.
	logic [8:0] rx_d1, rx_d2;
	logic       vis_d1, vis_d2;
	logic [8:0] vy_d1, vy_d2;
	always @(posedge clk) begin
		rx_d1 <= lb_rx;   rx_d2 <= rx_d1;
		vis_d1 <= (hcnt < 9'(H_ACTIVE)) && (vcnt < 9'(V_ACTIVE)); vis_d2 <= vis_d1;
		vy_d1 <= vcnt;    vy_d2 <= vy_d1;
		if (vis_d2 && capture_on) frame[vy_d2][rx_d2] <= lb_rdata;
	end

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	int ovr_count = 0;
	always @(posedge clk) if (ovr_ev) ovr_count <= ovr_count + 1;

	int fd;

	initial begin
		$display("=== tb_sprite: gogomile title, full sprite path ===");

		begin
			int f, n;
			byte unsigned vbuf [];
			f = $fopen("sim/tilemap_tb/spriteram.bin", "rb");
			if (f == 0) begin
				$display("FATAL: sim/tilemap_tb/spriteram.bin missing -- run");
				$display("  python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile");
				$finish;
			end
			vbuf = new [8192];
			n = $fread(vbuf, f);
			$fclose(f);
			for (int i = 0; i < n/2; i++) sram[i] = {vbuf[2*i], vbuf[2*i+1]};

			f = $fopen("sim/tilemap_tb/ls_gfx.bin", "rb");
			if (f == 0) begin $display("FATAL: ls_gfx.bin missing"); $finish; end
			n = $fread(gfx, f);
			$fclose(f);
			$display("  spriteram 8192 B, sprite gfx %0d B", n);
		end

		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++) frame[y][x] = 16'd0;

		repeat (20) @(posedge clk);
		reset = 0;

		// Let one frame build the list and prime the pipeline, then capture
		// the next full frame.
		@(posedge frame_start);
		@(posedge frame_start);
		capture_on = 1;
		@(posedge frame_start);
		capture_on = 0;

		$display("\n--- results ---");
		$display("  candidates: %0d", n_entries);
		$display("  gfx fetches this run: %0d", gfx_reads);
		$display("  line overruns: %0d", ovr_count);
		// Deliberately NOT an exact count. This bench renders whatever capture
		// is currently prepped into sim/tilemap_tb/, so pinning the number ties
		// it to one scene and turns a re-prep into a false failure -- which is
		// exactly what happened. The exact-content check lives in
		// spritelist_tb, which reads a FIXED capture directory and names both
		// records it expects.
		check(n_entries > 0 && n_entries <= 11'd1024,
		      "candidate list found a plausible number of sprites");
		check(ovr_count == 0, "no scanline overran its budget");

		begin
			int opaque_px;
			opaque_px = 0;
			for (int y = 0; y < H; y++)
				for (int x = 0; x < W; x++)
					if (frame[y][x][15]) opaque_px++;
			$display("  opaque pixels: %0d", opaque_px);
			// Scene-independent bounds: something was drawn, and it did not
			// cover the screen. A full 76,800 would mean every pixel opaque,
			// which no sprite layer does.
			check(opaque_px > 100 && opaque_px < 60000,
			      "sprites drew a plausible amount of the screen");
		end

		fd = $fopen("sim/tilemap_tb/frame_spr.txt", "w");
		for (int y = 0; y < H; y++) begin
			for (int x = 0; x < W; x++) $fwrite(fd, "%04x ", frame[y][x]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		$display("  wrote sim/tilemap_tb/frame_spr.txt");

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#500ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
