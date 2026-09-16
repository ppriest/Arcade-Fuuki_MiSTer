// The OKI ROM bridge against the real sample_cache, at every fetch latency
// that can meet the chip's slot boundary. RUN FROM THE REPOSITORY ROOT
// (scripts/run_sim.sh oki_bridge_tb).
//
// Hazard: `oki_rom_bridge_old` derives its request from the chip's LIVE
// address, so when jt6295 moves the address on the edge that registers valid,
// the request never drops and sample_cache stays in S_DRAIN. Both bridges get:
//
//   * an address rotator moving rom_addr every 344 / 430 clk alternately
//     (jt6295_rom's 1 MHz slots on the 85.9 MHz grid), to a fresh granule
//     each time so every move is a cache miss;
//   * a granule server of FIXED latency L, swept so valid lands on and
//     around the slot boundary.
//
// Checks: the old bridge deadlocks at some L (if not, the bench no longer
// exercises the hazard); the new bridge never does; and every byte the new
// bridge marks ok matches the address on the bus, under random latency and
// slot period with a mid-run bank change.
`timescale 1ns/1ps

// The OKI ROM bridge logic before 9714a18: the request follows the live
// address, so it can deadlock against sample_cache (see oki_rom_bridge.sv).
module oki_rom_bridge_old (
	input  logic        clk,
	input  logic        reset,
	input  logic [17:0] rom_addr,
	output logic [7:0]  rom_data,
	output logic        rom_ok,
	input  logic [1:0]  bank,
	output logic        req,
	output logic [19:0] addr,
	input  logic        valid,
	input  logic [7:0]  data
);
	logic [17:0] hold_addr;
	logic        hold_ok;
	assign addr   = {bank, rom_addr};
	assign req    = (rom_addr != hold_addr) || !hold_ok;
	assign rom_ok = hold_ok && (rom_addr == hold_addr);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hold_addr <= 18'd0; hold_ok <= 1'b0; rom_data <= 8'd0;
		end else begin
			if (valid) begin
				hold_addr <= rom_addr; rom_data <= data; hold_ok <= 1'b1;
			end else if (rom_addr != hold_addr) begin
				hold_ok <= 1'b0;
			end
		end
	end
endmodule

// ---- one bridge + one cache + one fixed-latency granule server ----
module oki_path #(parameter bit OLD = 0) (
	input  logic        clk,
	input  logic        reset,
	input  logic [17:0] rom_addr,
	input  logic [1:0]  bank,
	input  int          latency,        // server clk from g_req to g_valid
	input  bit          random_lat,     // ignore `latency`, draw 3..500 per fetch
	output logic [7:0]  rom_data,
	output logic        rom_ok,
	output logic        req,            // bridge -> cache, for the watch
	output logic        valid
);
	logic [19:0] addr;
	logic [7:0]  data;
	logic        g_req, g_valid;
	logic [25:0] g_addr;
	logic [63:0] g_data;

	generate
		if (OLD) begin : g_old
			oki_rom_bridge_old u_br (.clk(clk), .reset(reset), .rom_addr(rom_addr),
				.rom_data(rom_data), .rom_ok(rom_ok), .bank(bank),
				.req(req), .addr(addr), .valid(valid), .data(data));
		end else begin : g_new
			oki_rom_bridge u_br (.clk(clk), .reset(reset), .rom_addr(rom_addr),
				.rom_data(rom_data), .rom_ok(rom_ok), .bank(bank),
				.req(req), .addr(addr), .valid(valid), .data(data));
		end
	endgenerate

	sample_cache #(.ENTRIES(16)) u_cache (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(req), .addr(26'(addr)), .valid(valid), .data(data),
		.g_req(g_req), .g_addr(g_addr), .g_valid(g_valid), .g_data(g_data)
	);

	// The ROM byte at address A is a function of A, so any tagging error is
	// visible as a wrong byte.
	function automatic [7:0] rom_byte(input [25:0] a);
		rom_byte = a[7:0] ^ {a[15:8]} ^ {6'd0, a[17:16]} ^ 8'h5A;
	endfunction

	// Granule server: g_req is a level held until g_valid, valid registered as
	// sdram_arbiter's c_valid. Requests are captured on g_req's RISING EDGE, as
	// the arbiter does: re-sampling the still-high level after valid issues a
	// duplicate fetch whose late answer is taken as a later request's reply.
	// Reset with the cache, as in the core, or a pre-reset fetch lands in the
	// first post-reset fill.
	int   lat = 0;
	logic busy = 0, pend = 0, g_req_d = 0;
	logic [25:0] g_addr_q;
	always_ff @(posedge clk) begin
		g_valid <= 1'b0;
		g_req_d <= g_req;
		if (g_req && !g_req_d) pend <= 1'b1;
		if (reset) begin
			busy <= 1'b0; pend <= 1'b0; lat <= 0; g_req_d <= 1'b0;
		end else if (busy) begin
			lat <= lat - 1;
			if (lat == 1) begin
				g_valid <= 1'b1;
				for (int k = 0; k < 8; k++) g_data[8*k +: 8] <= rom_byte(g_addr_q + 26'(k));
				busy <= 1'b0;
			end
		end else if (pend) begin
			pend     <= 1'b0;
			busy     <= 1'b1;
			g_addr_q <= g_addr;
			lat      <= random_lat ? 3 + ($urandom % 498) : latency;
		end
	end
endmodule

module tb_oki_bridge;
	localparam real HALF = 5.8207;      // 85.909 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	// ---- stimulus: the chip's address rotator ----
	logic [17:0] rom_addr = 18'd0;
	logic [1:0]  bank = 2'd0;
	int          period = 344;
	bit          random_period = 0;
	int          slot_cnt = 0;
	always_ff @(posedge clk) begin
		if (reset) begin
			slot_cnt <= 0;
		end else if (slot_cnt >= period - 1) begin
			slot_cnt <= 0;
			period   <= random_period ? 300 + ($urandom % 200) : (period == 344 ? 430 : 344);
			// a fresh granule every slot: bits [2:0] random, [17:3] random
			rom_addr <= 18'($urandom);
		end else begin
			slot_cnt <= slot_cnt + 1;
		end
	end

	int latency = 100;
	bit random_lat = 0;

	logic [7:0] rd_old, rd_new;
	logic ok_old, ok_new, req_old, req_new, v_old, v_new;
	oki_path #(.OLD(1)) p_old (.clk(clk), .reset(reset), .rom_addr(rom_addr), .bank(bank),
		.latency(latency), .random_lat(random_lat),
		.rom_data(rd_old), .rom_ok(ok_old), .req(req_old), .valid(v_old));
	oki_path #(.OLD(0)) p_new (.clk(clk), .reset(reset), .rom_addr(rom_addr), .bank(bank),
		.latency(latency), .random_lat(random_lat),
		.rom_data(rd_new), .rom_ok(ok_new), .req(req_new), .valid(v_new));

	// ---- watches: clk a request has been up without a valid, peak-held ----
	int age_old = 0, age_new = 0, worst_old = 0, worst_new = 0;
	int n_valid_new = 0, n_ok_new = 0, n_bad_new = 0;
	// plain always: the peaks and counts are also reset from the initial block
	always @(posedge clk) begin
		if (reset) begin
			age_old <= 0; age_new <= 0;
		end else begin
			age_old <= (req_old && !v_old) ? age_old + 1 : 0;
			age_new <= (req_new && !v_new) ? age_new + 1 : 0;
			if (age_old > worst_old) worst_old <= age_old;
			if (age_new > worst_new) worst_new <= age_new;
			if (v_new) n_valid_new <= n_valid_new + 1;
			// every ok byte must be the byte for the address on the bus NOW
			if (ok_new) begin
				n_ok_new <= n_ok_new + 1;
				if (rd_new != p_new.rom_byte(26'({bank, rom_addr}))) begin
					n_bad_new <= n_bad_new + 1;
					if (n_bad_new < 6)
						$display("    mismatch: bus %05h hold %05h got %02h want %02h  cache st %0d byte_sel %0d",
						         {bank, rom_addr}, p_new.g_new.u_br.hold_addr, rd_new,
						         p_new.rom_byte(26'({bank, rom_addr})), p_new.u_cache.st, p_new.u_cache.byte_sel);
				end
			end
		end
	end

	// At each valid the new path gives: was the byte right for the address
	// the bridge asked, and which cache path served it.
	int n_bad_valid = 0;
	always @(posedge clk) begin
		if (v_new && !reset) begin
			if (p_new.data != p_new.rom_byte(26'(p_new.g_new.u_br.req_addr))) begin
				n_bad_valid <= n_bad_valid + 1;
				if (n_bad_valid < 4)
					$display("    bad valid: asked %05h got %02h want %02h | st %0d sel_idx %0d tag[sel] %06h tval %0d fill_tag %06h pend_addr %07h server g_addr_q %07h rr %0d",
					         p_new.g_new.u_br.req_addr, p_new.data, p_new.rom_byte(26'(p_new.g_new.u_br.req_addr)),
					         p_new.u_cache.st, p_new.u_cache.sel_idx, p_new.u_cache.tag[p_new.u_cache.sel_idx],
					         p_new.u_cache.tval[p_new.u_cache.sel_idx], p_new.u_cache.fill_tag,
					         p_new.u_cache.pend_addr, p_new.g_addr_q, p_new.u_cache.rr);
			end
		end
	end

	int errors = 0;
	task automatic check(input bit cond, input string what);
		if (cond) $display("  PASS  %s", what);
		else begin $display("  FAIL  %s", what); errors++; end
	endtask

	task automatic restart();
		reset = 1;
		worst_old = 0; worst_new = 0;
		repeat (5) @(posedge clk);
		reset = 0;
	endtask

	// A deadlock is a request outstanding for longer than any fetch can take.
	localparam int STALL = 4096;
	int old_stalls = 0, new_stalls = 0, first_stall_lat = -1;

	initial begin
		$display("=== tb_oki_bridge: OKI ROM bridge against sample_cache ===");

		$display("\n--- fixed latency sweep, 300..460 clk, slots of 344/430 ---");
		for (int L = 300; L <= 460; L++) begin
			latency = L;
			restart();
			repeat (24 * 430) @(posedge clk);      // ~24 slots, 12 of each length
			if (worst_old > STALL) begin
				old_stalls++;
				if (first_stall_lat < 0) first_stall_lat = L;
			end
			if (worst_new > STALL) begin
				new_stalls++;
				$display("  new bridge: request outstanding %0d clk at latency %0d", worst_new, L);
			end
		end
		$display("  old bridge deadlocked at %0d of 161 latencies (first at %0d clk)", old_stalls, first_stall_lat);
		$display("  new bridge: %0d deadlocks", new_stalls);
		check(old_stalls > 0, "the old bridge deadlocks somewhere in the sweep (the reproduction)");
		check(new_stalls == 0, "the new bridge never deadlocks in the sweep");

		$display("\n--- random latency 3..500, random slots 300..499, bank change mid-run ---");
		random_lat = 1; random_period = 1;
		restart();
		n_valid_new = 0; n_ok_new = 0; n_bad_new = 0;
		repeat (200000) @(posedge clk);
		bank = 2'd2;
		repeat (200000) @(posedge clk);
		$display("  %0d fetches completed, %0d clk with rom_ok, %0d of them the wrong byte, worst outstanding %0d clk",
		         n_valid_new, n_ok_new, n_bad_new, worst_new);
		check(n_valid_new > 500, "fetches complete under random latency");
		// A request can queue behind a prefetch in flight: two fetches, plus
		// the cache's own cycles.
		check(worst_new < 1100, "no request outstanding longer than two of the slowest fetches");
		check(n_bad_new == 0, "every ok byte is the byte for the address on the bus");

		$display("\n=== %0d error(s) ===", errors);
		if (errors == 0) $display("ALL CHECKS PASSED");
		$finish;
	end

	initial begin
		#400ms;
		$display("TIMEOUT");
		$finish;
	end
endmodule
