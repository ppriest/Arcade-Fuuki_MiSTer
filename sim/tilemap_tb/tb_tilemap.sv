// tilemap_line_engine against a REAL captured MAME frame.
//
// RUN FROM THE REPOSITORY ROOT (scripts/run_sim.sh tilemap_tb), after
//     python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile
//
// Renders 240 scanlines of one layer and writes palette indices for
// scripts/tilemap_png.py, compared by eye with MAME's screenshot of the same
// state. VRAM, scroll and screenshot come from MAME; the gfx image comes from
// the ROM via an independent script (LESSONS_LEARNED, "A hardware-vs-image
// comparison cannot detect a wrong image").
//
// +LAYER=n selects the layer; default 2 (the 8x8 text layer).

`timescale 1ns/1ps

module tb_tilemap;

	localparam real HALF = 5.8207;

	logic clk = 0;
	logic reset = 1;
	always #(HALF) clk = ~clk;

	// ---- configuration, read from prep_tilemap_tb.py's config.txt ----
	int    LAYER = 2;
	int    cfg_bank, cfg_tile16, cfg_bpp8, cfg_shift4, cfg_gran256;
	int    cfg_pal_base, cfg_trans, cfg_sx, cfg_sy;

	// ---- DUT ----
	logic        line_start = 0;
	logic [8:0]  render_line = 0;
	logic        busy, done;

	logic [13:0] vram_addr;
	logic [15:0] vram_data;

	logic        gfx_req;
	logic [24:0] gfx_addr;
	logic        gfx_valid;
	logic [63:0] gfx_data;

	logic        lb_we;
	logic [8:0]  lb_x;
	logic [13:0] lb_data;

	tilemap_line_engine dut (
		.clk(clk), .reset(reset),
		.line_start(line_start), .render_line(render_line),
		.busy(busy), .done(done),
		.vram_bank(cfg_bank[1:0]),
		.tile16(cfg_tile16[0]), .bpp8(cfg_bpp8[0]),
		.colour_shift4(cfg_shift4[0]), .gran256(cfg_gran256[0]),
		.pal_base(cfg_pal_base[12:0]), .trans_pen(cfg_trans[7:0]),
		.gfx_base(25'd0),
		.scroll_x(cfg_sx[15:0]), .scroll_y(cfg_sy[15:0]),
		.flip(1'b0),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfx_req(gfx_req), .gfx_addr(gfx_addr),
		.gfx_valid(gfx_valid), .gfx_data(gfx_data),
		.lb_we(lb_we), .lb_x(lb_x), .lb_data(lb_data)
	);

	// ---- VRAM: 16384 words, REGISTERED read ----
	// Registered so a consumer that skips the read-latency wait is caught.
	logic [15:0] vram [0:16383];
	always_ff @(posedge clk) vram_data <= vram[vram_addr];

	// ---- graphics ROM with realistic latency ----
	// 12 cycles, not 1: a short-latency model answers while the FSM is between
	// states and hides protocol bugs (LESSONS_LEARNED).
	localparam int GFX_LAT = 12;
	localparam int GFX_BYTES = 34*1024*1024;   // FG-3 sprite region is 32 MB

	byte unsigned gfx [0:GFX_BYTES-1];
	int  gfx_len = 0;
	int  gfx_ctr = 0;
	logic gfx_busy = 0;
	logic [24:0] gfx_lat_addr;
	int  gfx_reads = 0;

	always_ff @(posedge clk) begin
		gfx_valid <= 1'b0;
		if (reset) begin
			gfx_busy <= 1'b0;
		end else if (!gfx_busy) begin
			if (gfx_req) begin
				gfx_busy     <= 1'b1;
				gfx_lat_addr <= gfx_addr;
				gfx_ctr      <= GFX_LAT;
			end
		end else if (gfx_ctr > 1) begin
			gfx_ctr <= gfx_ctr - 1;
		end else begin
			// Ascending address, byte 0 in bits [7:0]: the SDRAM controller's packing.
			for (int b = 0; b < 8; b++)
				gfx_data[8*b +: 8] <= gfx[gfx_lat_addr + b];
			gfx_valid <= 1'b1;
			gfx_busy  <= 1'b0;
			gfx_reads <= gfx_reads + 1;
		end
	end

	// ---- capture the rendered frame ----
	localparam int W = 320, H = 240;
	logic [13:0] frame [0:H-1][0:W-1];

	// Plain `always`: the initial block also clears this array, and an
	// always_ff variable may not be driven elsewhere (vlog-7061).
	int cur_line = 0;
	always @(posedge clk)
		if (lb_we) frame[cur_line][lb_x] <= lb_data;

	// ---- helpers ----
	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	int fd, r;
	int worst_cycles = 0;

	// Count edges rather than dividing $time: $time is in the timescale unit
	// (1 ns), not ps.
	int cyc = 0;
	always @(posedge clk) cyc <= cyc + 1;

	initial begin
		if (!$value$plusargs("LAYER=%d", LAYER)) LAYER = 2;
		$display("=== tb_tilemap: gogomile title, layer %0d ===", LAYER);

		// Config first, then the big binaries.
		fd = $fopen("sim/tilemap_tb/config.txt", "r");
		if (fd == 0) begin
			$display("FATAL: sim/tilemap_tb/config.txt missing -- run");
			$display("       python scripts/prep_tilemap_tb.py debug/gogomile-title gogomile");
			$finish;
		end
		for (int i = 0; i < 3; i++) begin
			int l;
			r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n",
			            l, cfg_bank, cfg_tile16, cfg_bpp8, cfg_shift4,
			            cfg_gran256, cfg_pal_base, cfg_trans, cfg_sx, cfg_sy);
			if (l == LAYER) break;
		end
		$fclose(fd);
		$display("  bank=%0d tile16=%0d bpp8=%0d gran256=%0d pal_base=%03x trans=%02x scroll=(%0d,%0d)",
		         cfg_bank, cfg_tile16, cfg_bpp8, cfg_gran256,
		         cfg_pal_base, cfg_trans, cfg_sx, cfg_sy);

		load_bin_words("sim/tilemap_tb/vram.bin");
		gfx_len = load_bin_bytes($sformatf("sim/tilemap_tb/l%0d_gfx.bin", LAYER));
		$display("  VRAM loaded, gfx %0d bytes", gfx_len);
		check(gfx_len > 0, "gfx ROM image loaded");

		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++) frame[y][x] = 14'd0;

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// ---- render every scanline ----
		for (int y = 0; y < H; y++) begin
			int t0;
			cur_line    = y;
			render_line = 9'(y);
			@(posedge clk);
			line_start <= 1'b1;
			@(posedge clk);
			line_start <= 1'b0;
			t0 = cyc;
			// do/while, never while/do: the latter races the always_ff
			// updating `done` on the same edge.
			do @(posedge clk); while (!done);
			begin
				int used;
				used = cyc - t0;
				if (used > worst_cycles) worst_cycles = used;
			end
		end

		$display("\n--- render ---");
		$display("  worst line took ~%0d clk of the 5472 available (%0d%%)",
		         worst_cycles, (worst_cycles * 100) / 5472);
		$display("  gfx fetches: %0d", gfx_reads);
		check(worst_cycles < 5472, "a scanline renders inside its cycle budget");

		begin
			int opaque_px;
			opaque_px = 0;
			for (int y = 0; y < H; y++)
				for (int x = 0; x < W; x++)
					if (frame[y][x][13]) opaque_px++;
			$display("  opaque pixels: %0d of %0d", opaque_px, W*H);
			// Not asserted: a layer with an all-zero VRAM bank is legitimately
			// blank (asurabld's title draws only on layer 1).
			if (opaque_px == 0)
				$display("  (layer is blank on this frame -- check its VRAM bank)");
		end

		// Write the frame out for scripts/tilemap_png.py.
		fd = $fopen($sformatf("sim/tilemap_tb/frame_l%0d.txt", LAYER), "w");
		for (int y = 0; y < H; y++) begin
			for (int x = 0; x < W; x++) $fwrite(fd, "%04x ", frame[y][x]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		$display("  wrote sim/tilemap_tb/frame_l%0d.txt", LAYER);

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	// $fread on binaries: faster than hex, and the image layout stays defined
	// only in the prep script.
	task automatic load_bin_words(input string path);
		int f, n;
		byte unsigned vbuf [];   // NOT `buf` -- a Verilog gate primitive
		f = $fopen(path, "rb");
		if (f == 0) begin $display("FATAL: cannot open %s", path); $finish; end
		vbuf = new [32768];
		n = $fread(vbuf, f);
		$fclose(f);
		for (int i = 0; i < n/2; i++)
			vram[i] = {vbuf[2*i], vbuf[2*i+1]};    // big-endian words
		$display("  %s: %0d bytes", path, n);
	endtask

	function automatic int load_bin_bytes(input string path);
		int f, n;
		f = $fopen(path, "rb");
		if (f == 0) begin $display("FATAL: cannot open %s", path); $finish; end
		n = $fread(gfx, f);
		$fclose(f);
		return n;
	endfunction

	initial begin
		#500ms;
		$display("TIMEOUT");
		$finish;
	end

endmodule
