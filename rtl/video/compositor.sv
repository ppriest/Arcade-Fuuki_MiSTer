// Pixel compositor: three tilemap layers, sprites, and the backdrop.
// Combinational, one pixel in and one out, from the line buffers filled
// during the previous line.
//
// The priority mask is bit-indexed, not a value compare. MAME draws back,
// middle, front with priority codes 1, 2, 4, ORing each into a priority
// bitmap where the layer is opaque, so a pixel carries a 3-bit value saying
// which layers covered it. The sprite's 2-bit priority field selects a mask:
//
//     0   0x00   above all layers
//     1   0xf0   behind the front layer
//     2   0xfc   behind front + middle
//     3   0xfe   behind all layers
//
// and the sprite pixel is suppressed when (pri_mask >> pri_value) & 1.
// Do not AND the mask with the value: that lets priority-1 sprites beat a
// layer unconditionally.
//
// Example, sprite priority 1, mask 0xf0:
//     pri_value 0 (nothing drew)      bit 0 = 0   sprite shows
//     pri_value 1 (back drew)         bit 1 = 0   sprite shows
//     pri_value 4 (front drew)        bit 4 = 1   sprite hidden
//     pri_value 5 (back + front)      bit 5 = 1   sprite hidden
//
// Layer role is not layer number. Front, middle and back come from the
// priority register's table (vregs.sv) and games change it. The inputs are
// by number and assigned to roles by the tmap_* selectors.
//
// The backdrop is the last palette pen, 0x1fff, not pen 0: MAME fills with
// (0x800*4)-1 and the game writes black there at boot.

module compositor (
	// ---- the three tilemap layers, by NUMBER ----
	// Each is { opaque, palette index[12:0] } as tilemap_line_engine emits it.
	input  logic [13:0] l0,
	input  logic [13:0] l1,
	input  logic [13:0] l2,

	// ---- sprites: { opaque, priority[1:0], palette index[12:0] } ----
	input  logic [15:0] spr,

	// ---- layer order, from the priority register ----
	input  logic [1:0]  tmap_front,
	input  logic [1:0]  tmap_middle,
	input  logic [1:0]  tmap_back,

	// ---- per-layer enable, for debugging: an A/B without a rebuild ----
	input  logic        en_l0,
	input  logic        en_l1,
	input  logic        en_l2,
	input  logic        en_spr,

	output logic [12:0] pal_addr,     // palette index to look up
	output logic [2:0]  dbg_pri       // the priority value, for probes
);

	localparam logic [12:0] BACKDROP = 13'h1fff;

	// Enables applied here rather than at each engine, so a disabled layer
	// still costs its memory traffic and cannot mask a bandwidth problem.
	wire [13:0] l0e = {l0[13] & en_l0, l0[12:0]};
	wire [13:0] l1e = {l1[13] & en_l1, l1[12:0]};
	wire [13:0] l2e = {l2[13] & en_l2, l2[12:0]};

	// Do not write the role selects as a function called from a continuous
	// assignment: the assignment's sensitivity is the function's arguments,
	// so the select re-evaluates only when the layer order changes and holds
	// stale (X) layer data otherwise.
	logic [13:0] back, middle, front;

	always_comb begin
		case (tmap_back)
			2'd0:    back = l0e;
			2'd1:    back = l1e;
			default: back = l2e;
		endcase
		case (tmap_middle)
			2'd0:    middle = l0e;
			2'd1:    middle = l1e;
			default: middle = l2e;
		endcase
		case (tmap_front)
			2'd0:    front = l0e;
			2'd1:    front = l1e;
			default: front = l2e;
		endcase
	end

	// Codes 1, 2, 4 ORed where each role's layer is opaque.
	wire [2:0] pri_value = {front[13], middle[13], back[13]};
	assign dbg_pri = pri_value;

	// Front-most opaque layer wins; otherwise the backdrop.
	wire [12:0] layer_pal = front[13]  ? front[12:0]
	                      : middle[13] ? middle[12:0]
	                      : back[13]   ? back[12:0]
	                                   : BACKDROP;

	// Sprite priority -> mask, copied from colpri_cb including its operators.
	logic [7:0] pri_mask;
	always_comb begin
		case (spr[14:13])
			2'd0:    pri_mask = 8'h00;                     // above all
			2'd1:    pri_mask = 8'hf0;                     // behind front
			2'd2:    pri_mask = 8'hf0 | 8'hcc;             // behind front+middle
			default: pri_mask = 8'hf0 | 8'hcc | 8'haa;     // behind all
		endcase
	end

	wire sprite_blocked = pri_mask[pri_value];
	wire sprite_wins    = spr[15] & en_spr & ~sprite_blocked;

	assign pal_addr = sprite_wins ? spr[12:0] : layer_pal;

endmodule
