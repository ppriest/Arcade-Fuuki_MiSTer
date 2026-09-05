// Source-step lookup for zoomed sprites.
//
// MAME scales a sprite by handing gfx zoom_transpen a 16.16 factor of
// 512 * (zoom + 8), where zoom = 128 - 4*field, so the drawn size of a
// 16-pixel tile is (16 * scale) >> 16 = (zoom + 8) / 8 and destination pixel d
// samples source pixel (d << 16) / scale.
//
// That is a divide per pixel, which nothing here wants. It is also
// unnecessary: the reciprocal only depends on the 4-bit zoom field, so all
// sixteen values fit in a table.
//
//     step = (128 << 16) / (zoom + 8)     added to a 16.16 accumulator,
//                                         source pixel = acc >> 16
//
// The 512*(zoom+8) factor is the NEXT LARGER integer step -- MAME's comment
// says "nearest greater integer value to avoid holes" -- so a nominally
// full-size sprite drawn through the zoom path is 17 pixels, not 16. That is
// why the engine keeps MAME's separate non-zoomed path rather than treating
// full size as zoom 0 and calling it equivalent.

module sprite_zoom_lut (
	input  logic [3:0]  zoom_field,   // sprite record's 4-bit zoom, 0 = full size
	output logic [7:0]  zoom_t,       // 128 - 4*field, i.e. 128 down to 68
	output logic [7:0]  dst_size,     // drawn size of one 16-pixel tile
	output logic [17:0] step          // 16.16 source step per destination pixel
);

	assign zoom_t   = 8'd128 - {2'd0, zoom_field, 2'd0};
	assign dst_size = (zoom_t + 8'd8) >> 3;

	// step = (128 << 16) / (zoom_t + 8), truncated -- the same truncation
	// MAME's integer division performs. Every entry is checkable in one line:
	//     python -c "print([(128<<16)//(136-4*z) for z in range(16)])"
	// which is how the one transcription error in this table was caught.
	always_comb begin
		case (zoom_field)
			4'd0:  step = 18'd61680;    // /136
			4'd1:  step = 18'd63550;    // /132
			4'd2:  step = 18'd65536;    // /128  exactly 1:1
			4'd3:  step = 18'd67650;    // /124
			4'd4:  step = 18'd69905;    // /120
			4'd5:  step = 18'd72315;    // /116
			4'd6:  step = 18'd74898;    // /112
			4'd7:  step = 18'd77672;    // /108
			4'd8:  step = 18'd80659;    // /104
			4'd9:  step = 18'd83886;    // /100
			4'd10: step = 18'd87381;    // /96
			4'd11: step = 18'd91180;    // /92
			4'd12: step = 18'd95325;    // /88
			4'd13: step = 18'd99864;    // /84
			4'd14: step = 18'd104857;   // /80
			default: step = 18'd110376; // /76
		endcase
	end

endmodule
