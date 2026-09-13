// Source-step lookup for zoomed sprites.
//
// MAME hands zoom_transpen a 16.16 scale of 512 * (zoom + 8), zoom = 128 -
// 4*field, so a 16-pixel tile draws (zoom + 8) / 8 wide and destination pixel
// d samples source pixel (d << 16) / scale. The reciprocal depends only on the
// 4-bit field, so it is a table:
//
//     step = (128 << 16) / (zoom + 8)     added to a 16.16 accumulator,
//                                         source pixel = acc >> 16
//
// 512*(zoom+8) is the next larger integer step ("nearest greater integer
// value to avoid holes"), so a full-size sprite through the zoom path is 17
// pixels, not 16. That is why the engine keeps MAME's separate non-zoomed
// path.

module sprite_zoom_lut (
	input  logic [3:0]  zoom_field,   // sprite record's 4-bit zoom, 0 = full size
	output logic [7:0]  zoom_t,       // 128 - 4*field, i.e. 128 down to 68
	output logic [7:0]  dst_size,     // drawn size of one 16-pixel tile
	output logic [17:0] step          // 16.16 source step per destination pixel
);

	assign zoom_t   = 8'd128 - {2'd0, zoom_field, 2'd0};
	assign dst_size = (zoom_t + 8'd8) >> 3;

	// step = (128 << 16) / (zoom_t + 8), truncated as MAME's integer division.
	// Check: python -c "print([(128<<16)//(136-4*z) for z in range(16)])"
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
