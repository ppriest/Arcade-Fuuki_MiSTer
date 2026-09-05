// The whole video pipeline against a real captured MAME frame.
//
//   3 x tilemap_line_engine + line_buffer      \
//   spriteram -> list -> engine -> line_buffer  >-- compositor -> palette -> RGB
//   vregs (captured)                           /
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh video_tb), after
//     python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile
//
// This is the test the whole renderer has been building towards: it produces a
// full composed frame from MAME's own VRAM, spriteram, scroll registers,
// priority register and palette, which scripts/video_png.py then diffs against
// the screenshot MAME rendered from exactly that state. Pixel counts, not eyes.
//
// Each engine gets its own graphics-ROM model because the four regions are
// separate images. Sharing one SDRAM port between them is the memory
// backend's problem, not this one's, and conflating the two would make a
// rendering test fail for bandwidth reasons and vice versa.

`timescale 1ns/1ps

module tb_video;

	localparam real HALF = 5.8207;
	localparam int  H_TOTAL = 456, V_TOTAL = 262, H_ACTIVE = 320, V_ACTIVE = 240;
	localparam int  W = 320, H = 240;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	logic [3:0] ce_div = 0;
	wire        ce_pix = (ce_div == 4'd0);
	always_ff @(posedge clk) ce_div <= (ce_div == 4'd11) ? 4'd0 : ce_div + 4'd1;

	// ---- video timing ----
	logic [8:0] hcnt, vcnt, vcnt_next, vcnt_next2;
	logic h_active, v_active, hblank, vblank, hsync, vsync;
	logic line_start, frame_start;
	logic irq1, irq3, irq5;

	video_timing u_vt (
		.clk(clk), .ce_pix(ce_pix), .reset(reset),
		.raster_line(9'h1fe),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start),
		.irq1_trig(irq1), .irq3_trig(irq3), .irq5_trig(irq5)
	);

	// ---- captured configuration ----
	int cfg_bank [0:2], cfg_t16 [0:2], cfg_b8 [0:2], cfg_s4 [0:2];
	int cfg_g256 [0:2], cfg_pb [0:2], cfg_tr [0:2], cfg_sx [0:2], cfg_sy [0:2];
	int prio_reg;

	// Layer order, decoded exactly as vregs.sv does.
	logic [1:0] tmap_front, tmap_middle, tmap_back;
	always_comb begin
		case (prio_reg[3:0])
			4'd0:    {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd1, 2'd2};
			4'd1:    {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd2, 2'd1};
			4'd2:    {tmap_front, tmap_middle, tmap_back} = {2'd1, 2'd0, 2'd2};
			4'd3:    {tmap_front, tmap_middle, tmap_back} = {2'd1, 2'd2, 2'd0};
			4'd4:    {tmap_front, tmap_middle, tmap_back} = {2'd2, 2'd0, 2'd1};
			4'd5:    {tmap_front, tmap_middle, tmap_back} = {2'd2, 2'd1, 2'd0};
			default: {tmap_front, tmap_middle, tmap_back} = {2'd0, 2'd1, 2'd2};
		endcase
	end

	// ---- shared VRAM (all three tilemap engines read it) ----
	logic [15:0] vram [0:16383];

	// ---- per-layer engines and line buffers ----
	logic [13:0] tm_vaddr [0:2];
	logic [15:0] tm_vdata [0:2];
	logic        tm_req   [0:2];
	logic [24:0] tm_addr  [0:2];
	logic        tm_valid [0:2];
	logic [63:0] tm_data  [0:2];
	logic        tm_we    [0:2];
	logic [8:0]  tm_wx    [0:2];
	logic [13:0] tm_wd    [0:2];
	logic        tm_busy  [0:2], tm_done [0:2];
	logic [13:0] tm_rd    [0:2];
	logic        tm_ready [0:2];
	logic        tm_ready_d [0:2], tm_ready_rise [0:2];

	always_ff @(posedge clk) begin
		for (int i = 0; i < 3; i++) begin
			tm_ready_d[i]    <= tm_ready[i];
			tm_ready_rise[i] <= tm_ready[i] && !tm_ready_d[i];
		end
	end

	// VRAM is one memory with three readers here. In the core it is a real
	// arbitrated port; modelling it as three independent registered reads is
	// deliberate for a RENDERING test -- see the header.
	always_ff @(posedge clk) begin
		tm_vdata[0] <= vram[tm_vaddr[0]];
		tm_vdata[1] <= vram[tm_vaddr[1]];
		tm_vdata[2] <= vram[tm_vaddr[2]];
	end

	genvar g;
	generate
		for (g = 0; g < 3; g++) begin : layer
			// Start on the buffer's READY edge, not on line_start. Starting at
			// line_start puts the engine's first ~320 writes inside the line
			// buffer's clear pass, where the clear owns the write port and
			// they are silently discarded.
			tilemap_line_engine u_tm (
				.clk(clk), .reset(reset),
				.line_start(tm_ready_rise[g]), .render_line(vcnt_next2),
				.busy(tm_busy[g]), .done(tm_done[g]),
				.vram_bank(cfg_bank[g][1:0]),
				.tile16(cfg_t16[g][0]), .bpp8(cfg_b8[g][0]),
				.colour_shift4(cfg_s4[g][0]), .gran256(cfg_g256[g][0]),
				.pal_base(cfg_pb[g][12:0]), .trans_pen(cfg_tr[g][7:0]),
				.gfx_base(25'd0),
				.scroll_x(cfg_sx[g][15:0]), .scroll_y(cfg_sy[g][15:0]),
				.flip(1'b0),
				.vram_addr(tm_vaddr[g]), .vram_data(tm_vdata[g]),
				.gfx_req(tm_req[g]), .gfx_addr(tm_addr[g]),
				.gfx_valid(tm_valid[g]), .gfx_data(tm_data[g]),
				.lb_we(tm_we[g]), .lb_x(tm_wx[g]), .lb_data(tm_wd[g])
			);

			line_buffer #(.WIDTH(14)) u_lb (
				.clk(clk), .reset(reset),
				.line_start(line_start), .ready(tm_ready[g]),
				.we(tm_we[g]), .wx(tm_wx[g]), .wdata(tm_wd[g]),
				.rx(hcnt), .rdata(tm_rd[g])
			);
		end
	endgenerate

	// ---- sprite path ----
	logic [15:0] sram [0:4095];
	logic [11:0] sr_addr;
	logic [15:0] sr_data;
	always_ff @(posedge clk) sr_data <= sram[sr_addr];

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

	logic        spr_busy, spr_ovr;
	logic        spr_req, spr_valid;
	logic [24:0] spr_addr;
	logic [63:0] spr_gdata;
	logic        spr_we;
	logic [8:0]  spr_wx;
	logic [15:0] spr_wd, spr_rd;
	logic        spr_ready, spr_ready_d, spr_ready_rise;

	always_ff @(posedge clk) begin
		spr_ready_d    <= spr_ready;
		spr_ready_rise <= spr_ready && !spr_ready_d;
	end

	sprite_line_engine u_spr (
		.clk(clk), .reset(reset),
		.line_tick(line_start),
		.line_start(spr_ready_rise && !build_busy),
		.render_line(vcnt_next2),
		.busy(spr_busy), .ovr_ev(spr_ovr),
		.board_fg3(1'b0), .tilebank(32'd0), .gfx_base(25'd0),
		.n_entries(n_entries),
		.yt_addr(yt_addr), .yt_data(yt_data),
		.rec_addr(rec_addr), .rec_data(rec_data),
		.gfx_req(spr_req), .gfx_addr(spr_addr),
		.gfx_valid(spr_valid), .gfx_data(spr_gdata),
		.lb_we(spr_we), .lb_x(spr_wx), .lb_data(spr_wd)
	);

	line_buffer #(.WIDTH(16)) u_spr_lb (
		.clk(clk), .reset(reset),
		.line_start(line_start), .ready(spr_ready),
		.we(spr_we), .wx(spr_wx), .wdata(spr_wd),
		.rx(hcnt), .rdata(spr_rd)
	);

	// ---- compositor ----
	logic [12:0] pal_addr;
	logic [2:0]  dbg_pri;

	compositor u_comp (
		.l0(tm_rd[0]), .l1(tm_rd[1]), .l2(tm_rd[2]),
		.spr(spr_rd),
		.tmap_front(tmap_front), .tmap_middle(tmap_middle), .tmap_back(tmap_back),
		.en_l0(1'b1), .en_l1(1'b1), .en_l2(1'b1), .en_spr(1'b1),
		.pal_addr(pal_addr), .dbg_pri(dbg_pri)
	);

	// ---- palette (captured), xRGB-555 ----
	logic [15:0] pal [0:8191];
	logic [15:0] pal_q;
	always_ff @(posedge clk) pal_q <= pal[pal_addr];

	// ---- graphics ROM models, one per region ----
	localparam int GFX_LAT = 12;
	byte unsigned g0 [0:2*1024*1024-1];
	byte unsigned g1 [0:8*1024*1024-1];
	byte unsigned g2 [0:2*1024*1024-1];
	byte unsigned gs [0:2*1024*1024-1];

	`define GFXMODEL(NAME, MEM, REQ, ADDR, VALID, DATA)                        \
		int   NAME``_ctr = 0;                                                   \
		logic NAME``_busy = 0;                                                  \
		logic [24:0] NAME``_la;                                                 \
		always_ff @(posedge clk) begin                                          \
			VALID <= 1'b0;                                                       \
			if (reset) NAME``_busy <= 1'b0;                                      \
			else if (!NAME``_busy) begin                                         \
				if (REQ) begin                                                    \
					NAME``_busy <= 1'b1; NAME``_la <= ADDR; NAME``_ctr <= GFX_LAT;  \
				end                                                               \
			end else if (NAME``_ctr > 1) NAME``_ctr <= NAME``_ctr - 1;           \
			else begin                                                           \
				for (int b = 0; b < 8; b++) DATA[8*b +: 8] <= MEM[NAME``_la + b]; \
				VALID <= 1'b1; NAME``_busy <= 1'b0;                               \
			end                                                                  \
		end

	`GFXMODEL(m0, g0, tm_req[0], tm_addr[0], tm_valid[0], tm_data[0])
	`GFXMODEL(m1, g1, tm_req[1], tm_addr[1], tm_valid[1], tm_data[1])
	`GFXMODEL(m2, g2, tm_req[2], tm_addr[2], tm_valid[2], tm_data[2])
	`GFXMODEL(ms, gs, spr_req,   spr_addr,   spr_valid,   spr_gdata)

	// ---- capture the composed frame ----
	// The palette read is registered, so the RGB for hcnt lands two cycles
	// later. Tracking the coordinate through the same delay keeps them paired.
	logic [15:0] frame [0:H-1][0:W-1];
	logic capture_on = 0;
	logic [8:0] x_d1, x_d2, y_d1, y_d2;
	logic       v_d1, v_d2;

	always @(posedge clk) begin
		x_d1 <= hcnt;  x_d2 <= x_d1;
		y_d1 <= vcnt;  y_d2 <= y_d1;
		v_d1 <= h_active && v_active;  v_d2 <= v_d1;
		if (v_d2 && capture_on) frame[y_d2][x_d2] <= pal_q;
	end

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	int ovr_count = 0;
	always @(posedge clk) if (spr_ovr) ovr_count <= ovr_count + 1;

	int fd, r;

	task automatic load_bytes(input string path, inout byte unsigned mem []);
	endtask

	initial begin
		$display("=== tb_video: gogomile title, full pipeline ===");

		// ---- configuration ----
		fd = $fopen("sim/tilemap_tb/config.txt", "r");
		if (fd == 0) begin
			$display("FATAL: run  python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile");
			$finish;
		end
		for (int i = 0; i < 3; i++) begin
			int l;
			r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n", l,
			            cfg_bank[i], cfg_t16[i], cfg_b8[i], cfg_s4[i],
			            cfg_g256[i], cfg_pb[i], cfg_tr[i], cfg_sx[i], cfg_sy[i]);
		end
		$fclose(fd);

		// ---- binaries ----
		begin
			int f, n;
			byte unsigned vbuf [];

			f = $fopen("sim/tilemap_tb/vram.bin", "rb");
			vbuf = new [32768]; n = $fread(vbuf, f); $fclose(f);
			for (int i = 0; i < n/2; i++) vram[i] = {vbuf[2*i], vbuf[2*i+1]};

			f = $fopen("sim/tilemap_tb/spriteram.bin", "rb");
			vbuf = new [8192]; n = $fread(vbuf, f); $fclose(f);
			for (int i = 0; i < n/2; i++) sram[i] = {vbuf[2*i], vbuf[2*i+1]};

			f = $fopen("sim/tilemap_tb/palette.bin", "rb");
			vbuf = new [16384]; n = $fread(vbuf, f); $fclose(f);
			for (int i = 0; i < n/2; i++) pal[i] = {vbuf[2*i], vbuf[2*i+1]};

			f = $fopen("sim/tilemap_tb/priority.bin", "rb");
			vbuf = new [2]; n = $fread(vbuf, f); $fclose(f);
			prio_reg = {vbuf[0], vbuf[1]};
			#1;   // let the combinational decode settle before printing it
			$display("  priority register = %04x -> front %0d middle %0d back %0d",
			         prio_reg[15:0], tmap_front, tmap_middle, tmap_back);

			f = $fopen("sim/tilemap_tb/l0_gfx.bin", "rb"); n = $fread(g0, f); $fclose(f);
			f = $fopen("sim/tilemap_tb/l1_gfx.bin", "rb"); n = $fread(g1, f); $fclose(f);
			f = $fopen("sim/tilemap_tb/l2_gfx.bin", "rb"); n = $fread(g2, f); $fclose(f);
			f = $fopen("sim/tilemap_tb/ls_gfx.bin", "rb"); n = $fread(gs, f); $fclose(f);
			$display("  all gfx images loaded");
		end

		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++) frame[y][x] = 16'd0;

		repeat (20) @(posedge clk);
		reset = 0;

		@(posedge frame_start);
		@(posedge frame_start);
		capture_on = 1;
		@(posedge frame_start);
		capture_on = 0;

		// Probe: sample the pipeline mid-frame to see where the X comes from.
		begin
			@(posedge frame_start);
			while (!(vcnt == 9'd100 && hcnt == 9'd160)) @(posedge clk);
			$display("  probe hcnt=%0d vcnt=%0d", hcnt, vcnt);
			$display("    tm_rd = %04x %04x %04x   spr_rd = %04x", tm_rd[0], tm_rd[1], tm_rd[2], spr_rd);
			$display("    tmap f=%0d m=%0d b=%0d  dbg_pri=%0d", tmap_front, tmap_middle, tmap_back, dbg_pri);
			$display("    pal_addr=%04x pal_q=%04x", pal_addr, pal_q);
			$display("    tm_ready=%b%b%b spr_ready=%b busy=%b%b%b", tm_ready[0], tm_ready[1], tm_ready[2], spr_ready, tm_busy[0], tm_busy[1], tm_busy[2]);
			$display("    pal0=%04x pal1=%04x pal1fff=%04x", pal[0], pal[1], pal[13'h1fff]);
		end

		$display("\n--- results ---");
		$display("  sprite candidates: %0d", n_entries);
		$display("  sprite line overruns: %0d", ovr_count);
		check(ovr_count == 0, "no sprite scanline overran its budget");

		fd = $fopen("sim/tilemap_tb/frame_rgb.txt", "w");
		for (int y = 0; y < H; y++) begin
			for (int x = 0; x < W; x++) $fwrite(fd, "%04x ", frame[y][x]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		$display("  wrote sim/tilemap_tb/frame_rgb.txt");

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
