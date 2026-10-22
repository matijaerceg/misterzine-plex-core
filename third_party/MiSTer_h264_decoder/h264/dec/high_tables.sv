// h264/dec/high_tables.sv -- the High-profile ROMs (docs/high_profile.md).
// RENDERED by tools/render_high_tables.py from tools/high_tables.py (the spec PDF,
// cross-checked against ffmpeg); do not edit (bench/h264/run_h264_top.sh checks it).
// Pure lookups as `case` blocks (CLAUDE.md: no function automatic, no N'() casts).

`default_nettype none

module hp_sl_default (input wire [5:0] a, output logic [31:0] q);
    always_comb begin
        case (a)
            6'd0: q = 32'h140d0d06;
            6'd1: q = 32'h1c1c1414;
            6'd2: q = 32'h20201c1c;
            6'd3: q = 32'h2a252520;
            6'd4: q = 32'h140e0e0a;
            6'd5: q = 32'h18181414;
            6'd6: q = 32'h1b1b1818;
            6'd7: q = 32'h221e1e1b;
            6'd8: q = 32'h0d0a0a06;
            6'd9: q = 32'h10100d0b;
            6'd10: q = 32'h12121010;
            6'd11: q = 32'h17121212;
            6'd12: q = 32'h17171717;
            6'd13: q = 32'h19191917;
            6'd14: q = 32'h19191919;
            6'd15: q = 32'h1b1b1b1b;
            6'd16: q = 32'h1b1b1b1b;
            6'd17: q = 32'h1d1d1d1d;
            6'd18: q = 32'h1f1d1d1d;
            6'd19: q = 32'h1f1f1f1f;
            6'd20: q = 32'h2121211f;
            6'd21: q = 32'h24242121;
            6'd22: q = 32'h26262424;
            6'd23: q = 32'h2a282826;
            6'd24: q = 32'h0f0d0d09;
            6'd25: q = 32'h11110f0d;
            6'd26: q = 32'h13131111;
            6'd27: q = 32'h15131313;
            6'd28: q = 32'h15151515;
            6'd29: q = 32'h16161615;
            6'd30: q = 32'h16161616;
            6'd31: q = 32'h18181818;
            6'd32: q = 32'h18181818;
            6'd33: q = 32'h19191919;
            6'd34: q = 32'h1b191919;
            6'd35: q = 32'h1b1b1b1b;
            6'd36: q = 32'h1c1c1c1b;
            6'd37: q = 32'h1e1e1c1c;
            6'd38: q = 32'h20201e1e;
            6'd39: q = 32'h23212120;
            default: q = 32'h10101010;
        endcase
    end
endmodule

module hp_ctx8 (input wire [5:0] i, output logic [3:0] sig_fr, output logic [3:0] sig_fl,
                output logic [3:0] last);
    always_comb begin
        case (i)
            6'd0: begin sig_fr = 4'd0; sig_fl = 4'd0; last = 4'd0; end
            6'd1: begin sig_fr = 4'd1; sig_fl = 4'd1; last = 4'd1; end
            6'd2: begin sig_fr = 4'd2; sig_fl = 4'd1; last = 4'd1; end
            6'd3: begin sig_fr = 4'd3; sig_fl = 4'd2; last = 4'd1; end
            6'd4: begin sig_fr = 4'd4; sig_fl = 4'd2; last = 4'd1; end
            6'd5: begin sig_fr = 4'd5; sig_fl = 4'd3; last = 4'd1; end
            6'd6: begin sig_fr = 4'd5; sig_fl = 4'd3; last = 4'd1; end
            6'd7: begin sig_fr = 4'd4; sig_fl = 4'd4; last = 4'd1; end
            6'd8: begin sig_fr = 4'd4; sig_fl = 4'd5; last = 4'd1; end
            6'd9: begin sig_fr = 4'd3; sig_fl = 4'd6; last = 4'd1; end
            6'd10: begin sig_fr = 4'd3; sig_fl = 4'd7; last = 4'd1; end
            6'd11: begin sig_fr = 4'd4; sig_fl = 4'd7; last = 4'd1; end
            6'd12: begin sig_fr = 4'd4; sig_fl = 4'd7; last = 4'd1; end
            6'd13: begin sig_fr = 4'd4; sig_fl = 4'd8; last = 4'd1; end
            6'd14: begin sig_fr = 4'd5; sig_fl = 4'd4; last = 4'd1; end
            6'd15: begin sig_fr = 4'd5; sig_fl = 4'd5; last = 4'd1; end
            6'd16: begin sig_fr = 4'd4; sig_fl = 4'd6; last = 4'd2; end
            6'd17: begin sig_fr = 4'd4; sig_fl = 4'd9; last = 4'd2; end
            6'd18: begin sig_fr = 4'd4; sig_fl = 4'd10; last = 4'd2; end
            6'd19: begin sig_fr = 4'd4; sig_fl = 4'd10; last = 4'd2; end
            6'd20: begin sig_fr = 4'd3; sig_fl = 4'd8; last = 4'd2; end
            6'd21: begin sig_fr = 4'd3; sig_fl = 4'd11; last = 4'd2; end
            6'd22: begin sig_fr = 4'd6; sig_fl = 4'd12; last = 4'd2; end
            6'd23: begin sig_fr = 4'd7; sig_fl = 4'd11; last = 4'd2; end
            6'd24: begin sig_fr = 4'd7; sig_fl = 4'd9; last = 4'd2; end
            6'd25: begin sig_fr = 4'd7; sig_fl = 4'd9; last = 4'd2; end
            6'd26: begin sig_fr = 4'd8; sig_fl = 4'd10; last = 4'd2; end
            6'd27: begin sig_fr = 4'd9; sig_fl = 4'd10; last = 4'd2; end
            6'd28: begin sig_fr = 4'd10; sig_fl = 4'd8; last = 4'd2; end
            6'd29: begin sig_fr = 4'd9; sig_fl = 4'd11; last = 4'd2; end
            6'd30: begin sig_fr = 4'd8; sig_fl = 4'd12; last = 4'd2; end
            6'd31: begin sig_fr = 4'd7; sig_fl = 4'd11; last = 4'd2; end
            6'd32: begin sig_fr = 4'd7; sig_fl = 4'd9; last = 4'd3; end
            6'd33: begin sig_fr = 4'd6; sig_fl = 4'd9; last = 4'd3; end
            6'd34: begin sig_fr = 4'd11; sig_fl = 4'd10; last = 4'd3; end
            6'd35: begin sig_fr = 4'd12; sig_fl = 4'd10; last = 4'd3; end
            6'd36: begin sig_fr = 4'd13; sig_fl = 4'd8; last = 4'd3; end
            6'd37: begin sig_fr = 4'd11; sig_fl = 4'd11; last = 4'd3; end
            6'd38: begin sig_fr = 4'd6; sig_fl = 4'd12; last = 4'd3; end
            6'd39: begin sig_fr = 4'd7; sig_fl = 4'd11; last = 4'd3; end
            6'd40: begin sig_fr = 4'd8; sig_fl = 4'd9; last = 4'd4; end
            6'd41: begin sig_fr = 4'd9; sig_fl = 4'd9; last = 4'd4; end
            6'd42: begin sig_fr = 4'd14; sig_fl = 4'd10; last = 4'd4; end
            6'd43: begin sig_fr = 4'd10; sig_fl = 4'd10; last = 4'd4; end
            6'd44: begin sig_fr = 4'd9; sig_fl = 4'd8; last = 4'd4; end
            6'd45: begin sig_fr = 4'd8; sig_fl = 4'd13; last = 4'd4; end
            6'd46: begin sig_fr = 4'd6; sig_fl = 4'd13; last = 4'd4; end
            6'd47: begin sig_fr = 4'd11; sig_fl = 4'd9; last = 4'd4; end
            6'd48: begin sig_fr = 4'd12; sig_fl = 4'd9; last = 4'd5; end
            6'd49: begin sig_fr = 4'd13; sig_fl = 4'd10; last = 4'd5; end
            6'd50: begin sig_fr = 4'd11; sig_fl = 4'd10; last = 4'd5; end
            6'd51: begin sig_fr = 4'd6; sig_fl = 4'd8; last = 4'd5; end
            6'd52: begin sig_fr = 4'd9; sig_fl = 4'd13; last = 4'd6; end
            6'd53: begin sig_fr = 4'd14; sig_fl = 4'd13; last = 4'd6; end
            6'd54: begin sig_fr = 4'd10; sig_fl = 4'd9; last = 4'd6; end
            6'd55: begin sig_fr = 4'd9; sig_fl = 4'd9; last = 4'd6; end
            6'd56: begin sig_fr = 4'd11; sig_fl = 4'd10; last = 4'd7; end
            6'd57: begin sig_fr = 4'd12; sig_fl = 4'd10; last = 4'd7; end
            6'd58: begin sig_fr = 4'd13; sig_fl = 4'd14; last = 4'd7; end
            6'd59: begin sig_fr = 4'd11; sig_fl = 4'd14; last = 4'd7; end
            6'd60: begin sig_fr = 4'd14; sig_fl = 4'd14; last = 4'd8; end
            6'd61: begin sig_fr = 4'd10; sig_fl = 4'd14; last = 4'd8; end
            6'd62: begin sig_fr = 4'd12; sig_fl = 4'd14; last = 4'd8; end
            default: begin sig_fr = 4'd0; sig_fl = 4'd0; last = 4'd0; end
        endcase
    end
endmodule

module hp_scan8 (input wire field, input wire [5:0] k, output logic [5:0] r);
    always_comb begin
        case ({field, k})
            7'd0: r = 6'd0;
            7'd1: r = 6'd1;
            7'd2: r = 6'd8;
            7'd3: r = 6'd16;
            7'd4: r = 6'd9;
            7'd5: r = 6'd2;
            7'd6: r = 6'd3;
            7'd7: r = 6'd10;
            7'd8: r = 6'd17;
            7'd9: r = 6'd24;
            7'd10: r = 6'd32;
            7'd11: r = 6'd25;
            7'd12: r = 6'd18;
            7'd13: r = 6'd11;
            7'd14: r = 6'd4;
            7'd15: r = 6'd5;
            7'd16: r = 6'd12;
            7'd17: r = 6'd19;
            7'd18: r = 6'd26;
            7'd19: r = 6'd33;
            7'd20: r = 6'd40;
            7'd21: r = 6'd48;
            7'd22: r = 6'd41;
            7'd23: r = 6'd34;
            7'd24: r = 6'd27;
            7'd25: r = 6'd20;
            7'd26: r = 6'd13;
            7'd27: r = 6'd6;
            7'd28: r = 6'd7;
            7'd29: r = 6'd14;
            7'd30: r = 6'd21;
            7'd31: r = 6'd28;
            7'd32: r = 6'd35;
            7'd33: r = 6'd42;
            7'd34: r = 6'd49;
            7'd35: r = 6'd56;
            7'd36: r = 6'd57;
            7'd37: r = 6'd50;
            7'd38: r = 6'd43;
            7'd39: r = 6'd36;
            7'd40: r = 6'd29;
            7'd41: r = 6'd22;
            7'd42: r = 6'd15;
            7'd43: r = 6'd23;
            7'd44: r = 6'd30;
            7'd45: r = 6'd37;
            7'd46: r = 6'd44;
            7'd47: r = 6'd51;
            7'd48: r = 6'd58;
            7'd49: r = 6'd59;
            7'd50: r = 6'd52;
            7'd51: r = 6'd45;
            7'd52: r = 6'd38;
            7'd53: r = 6'd31;
            7'd54: r = 6'd39;
            7'd55: r = 6'd46;
            7'd56: r = 6'd53;
            7'd57: r = 6'd60;
            7'd58: r = 6'd61;
            7'd59: r = 6'd54;
            7'd60: r = 6'd47;
            7'd61: r = 6'd55;
            7'd62: r = 6'd62;
            7'd63: r = 6'd63;
            7'd64: r = 6'd0;
            7'd65: r = 6'd8;
            7'd66: r = 6'd16;
            7'd67: r = 6'd1;
            7'd68: r = 6'd9;
            7'd69: r = 6'd24;
            7'd70: r = 6'd32;
            7'd71: r = 6'd17;
            7'd72: r = 6'd2;
            7'd73: r = 6'd25;
            7'd74: r = 6'd40;
            7'd75: r = 6'd48;
            7'd76: r = 6'd56;
            7'd77: r = 6'd33;
            7'd78: r = 6'd10;
            7'd79: r = 6'd3;
            7'd80: r = 6'd18;
            7'd81: r = 6'd41;
            7'd82: r = 6'd49;
            7'd83: r = 6'd57;
            7'd84: r = 6'd26;
            7'd85: r = 6'd11;
            7'd86: r = 6'd4;
            7'd87: r = 6'd19;
            7'd88: r = 6'd34;
            7'd89: r = 6'd42;
            7'd90: r = 6'd50;
            7'd91: r = 6'd58;
            7'd92: r = 6'd27;
            7'd93: r = 6'd12;
            7'd94: r = 6'd5;
            7'd95: r = 6'd20;
            7'd96: r = 6'd35;
            7'd97: r = 6'd43;
            7'd98: r = 6'd51;
            7'd99: r = 6'd59;
            7'd100: r = 6'd28;
            7'd101: r = 6'd13;
            7'd102: r = 6'd6;
            7'd103: r = 6'd21;
            7'd104: r = 6'd36;
            7'd105: r = 6'd44;
            7'd106: r = 6'd52;
            7'd107: r = 6'd60;
            7'd108: r = 6'd29;
            7'd109: r = 6'd14;
            7'd110: r = 6'd22;
            7'd111: r = 6'd37;
            7'd112: r = 6'd45;
            7'd113: r = 6'd53;
            7'd114: r = 6'd61;
            7'd115: r = 6'd30;
            7'd116: r = 6'd7;
            7'd117: r = 6'd15;
            7'd118: r = 6'd38;
            7'd119: r = 6'd46;
            7'd120: r = 6'd54;
            7'd121: r = 6'd62;
            7'd122: r = 6'd23;
            7'd123: r = 6'd31;
            7'd124: r = 6'd39;
            7'd125: r = 6'd47;
            7'd126: r = 6'd55;
            7'd127: r = 6'd63;
            default: r = 6'd0;
        endcase
    end
endmodule

module hp_zzinv4 (input wire [3:0] r, output logic [3:0] k);
    always_comb begin
        case (r)
            4'd0: k = 4'd0;
            4'd1: k = 4'd1;
            4'd2: k = 4'd5;
            4'd3: k = 4'd6;
            4'd4: k = 4'd2;
            4'd5: k = 4'd4;
            4'd6: k = 4'd7;
            4'd7: k = 4'd12;
            4'd8: k = 4'd3;
            4'd9: k = 4'd8;
            4'd10: k = 4'd11;
            4'd11: k = 4'd13;
            4'd12: k = 4'd9;
            4'd13: k = 4'd10;
            4'd14: k = 4'd14;
            4'd15: k = 4'd15;
            default: k = 4'd0;
        endcase
    end
endmodule

module hp_zzinv8 (input wire [5:0] r, output logic [5:0] k);
    always_comb begin
        case (r)
            6'd0: k = 6'd0;
            6'd1: k = 6'd1;
            6'd2: k = 6'd5;
            6'd3: k = 6'd6;
            6'd4: k = 6'd14;
            6'd5: k = 6'd15;
            6'd6: k = 6'd27;
            6'd7: k = 6'd28;
            6'd8: k = 6'd2;
            6'd9: k = 6'd4;
            6'd10: k = 6'd7;
            6'd11: k = 6'd13;
            6'd12: k = 6'd16;
            6'd13: k = 6'd26;
            6'd14: k = 6'd29;
            6'd15: k = 6'd42;
            6'd16: k = 6'd3;
            6'd17: k = 6'd8;
            6'd18: k = 6'd12;
            6'd19: k = 6'd17;
            6'd20: k = 6'd25;
            6'd21: k = 6'd30;
            6'd22: k = 6'd41;
            6'd23: k = 6'd43;
            6'd24: k = 6'd9;
            6'd25: k = 6'd11;
            6'd26: k = 6'd18;
            6'd27: k = 6'd24;
            6'd28: k = 6'd31;
            6'd29: k = 6'd40;
            6'd30: k = 6'd44;
            6'd31: k = 6'd53;
            6'd32: k = 6'd10;
            6'd33: k = 6'd19;
            6'd34: k = 6'd23;
            6'd35: k = 6'd32;
            6'd36: k = 6'd39;
            6'd37: k = 6'd45;
            6'd38: k = 6'd52;
            6'd39: k = 6'd54;
            6'd40: k = 6'd20;
            6'd41: k = 6'd22;
            6'd42: k = 6'd33;
            6'd43: k = 6'd38;
            6'd44: k = 6'd46;
            6'd45: k = 6'd51;
            6'd46: k = 6'd55;
            6'd47: k = 6'd60;
            6'd48: k = 6'd21;
            6'd49: k = 6'd34;
            6'd50: k = 6'd37;
            6'd51: k = 6'd47;
            6'd52: k = 6'd50;
            6'd53: k = 6'd56;
            6'd54: k = 6'd59;
            6'd55: k = 6'd61;
            6'd56: k = 6'd35;
            6'd57: k = 6'd36;
            6'd58: k = 6'd48;
            6'd59: k = 6'd49;
            6'd60: k = 6'd57;
            6'd61: k = 6'd58;
            6'd62: k = 6'd62;
            6'd63: k = 6'd63;
            default: k = 6'd0;
        endcase
    end
endmodule

module hp_norm8 (input wire [2:0] m, input wire [5:0] r, output logic [5:0] v);
    always_comb begin
        case ({m, r})
            9'd0: v = 6'd20;
            9'd1: v = 6'd19;
            9'd2: v = 6'd25;
            9'd3: v = 6'd19;
            9'd4: v = 6'd20;
            9'd5: v = 6'd19;
            9'd6: v = 6'd25;
            9'd7: v = 6'd19;
            9'd8: v = 6'd19;
            9'd9: v = 6'd18;
            9'd10: v = 6'd24;
            9'd11: v = 6'd18;
            9'd12: v = 6'd19;
            9'd13: v = 6'd18;
            9'd14: v = 6'd24;
            9'd15: v = 6'd18;
            9'd16: v = 6'd25;
            9'd17: v = 6'd24;
            9'd18: v = 6'd32;
            9'd19: v = 6'd24;
            9'd20: v = 6'd25;
            9'd21: v = 6'd24;
            9'd22: v = 6'd32;
            9'd23: v = 6'd24;
            9'd24: v = 6'd19;
            9'd25: v = 6'd18;
            9'd26: v = 6'd24;
            9'd27: v = 6'd18;
            9'd28: v = 6'd19;
            9'd29: v = 6'd18;
            9'd30: v = 6'd24;
            9'd31: v = 6'd18;
            9'd32: v = 6'd20;
            9'd33: v = 6'd19;
            9'd34: v = 6'd25;
            9'd35: v = 6'd19;
            9'd36: v = 6'd20;
            9'd37: v = 6'd19;
            9'd38: v = 6'd25;
            9'd39: v = 6'd19;
            9'd40: v = 6'd19;
            9'd41: v = 6'd18;
            9'd42: v = 6'd24;
            9'd43: v = 6'd18;
            9'd44: v = 6'd19;
            9'd45: v = 6'd18;
            9'd46: v = 6'd24;
            9'd47: v = 6'd18;
            9'd48: v = 6'd25;
            9'd49: v = 6'd24;
            9'd50: v = 6'd32;
            9'd51: v = 6'd24;
            9'd52: v = 6'd25;
            9'd53: v = 6'd24;
            9'd54: v = 6'd32;
            9'd55: v = 6'd24;
            9'd56: v = 6'd19;
            9'd57: v = 6'd18;
            9'd58: v = 6'd24;
            9'd59: v = 6'd18;
            9'd60: v = 6'd19;
            9'd61: v = 6'd18;
            9'd62: v = 6'd24;
            9'd63: v = 6'd18;
            9'd64: v = 6'd22;
            9'd65: v = 6'd21;
            9'd66: v = 6'd28;
            9'd67: v = 6'd21;
            9'd68: v = 6'd22;
            9'd69: v = 6'd21;
            9'd70: v = 6'd28;
            9'd71: v = 6'd21;
            9'd72: v = 6'd21;
            9'd73: v = 6'd19;
            9'd74: v = 6'd26;
            9'd75: v = 6'd19;
            9'd76: v = 6'd21;
            9'd77: v = 6'd19;
            9'd78: v = 6'd26;
            9'd79: v = 6'd19;
            9'd80: v = 6'd28;
            9'd81: v = 6'd26;
            9'd82: v = 6'd35;
            9'd83: v = 6'd26;
            9'd84: v = 6'd28;
            9'd85: v = 6'd26;
            9'd86: v = 6'd35;
            9'd87: v = 6'd26;
            9'd88: v = 6'd21;
            9'd89: v = 6'd19;
            9'd90: v = 6'd26;
            9'd91: v = 6'd19;
            9'd92: v = 6'd21;
            9'd93: v = 6'd19;
            9'd94: v = 6'd26;
            9'd95: v = 6'd19;
            9'd96: v = 6'd22;
            9'd97: v = 6'd21;
            9'd98: v = 6'd28;
            9'd99: v = 6'd21;
            9'd100: v = 6'd22;
            9'd101: v = 6'd21;
            9'd102: v = 6'd28;
            9'd103: v = 6'd21;
            9'd104: v = 6'd21;
            9'd105: v = 6'd19;
            9'd106: v = 6'd26;
            9'd107: v = 6'd19;
            9'd108: v = 6'd21;
            9'd109: v = 6'd19;
            9'd110: v = 6'd26;
            9'd111: v = 6'd19;
            9'd112: v = 6'd28;
            9'd113: v = 6'd26;
            9'd114: v = 6'd35;
            9'd115: v = 6'd26;
            9'd116: v = 6'd28;
            9'd117: v = 6'd26;
            9'd118: v = 6'd35;
            9'd119: v = 6'd26;
            9'd120: v = 6'd21;
            9'd121: v = 6'd19;
            9'd122: v = 6'd26;
            9'd123: v = 6'd19;
            9'd124: v = 6'd21;
            9'd125: v = 6'd19;
            9'd126: v = 6'd26;
            9'd127: v = 6'd19;
            9'd128: v = 6'd26;
            9'd129: v = 6'd24;
            9'd130: v = 6'd33;
            9'd131: v = 6'd24;
            9'd132: v = 6'd26;
            9'd133: v = 6'd24;
            9'd134: v = 6'd33;
            9'd135: v = 6'd24;
            9'd136: v = 6'd24;
            9'd137: v = 6'd23;
            9'd138: v = 6'd31;
            9'd139: v = 6'd23;
            9'd140: v = 6'd24;
            9'd141: v = 6'd23;
            9'd142: v = 6'd31;
            9'd143: v = 6'd23;
            9'd144: v = 6'd33;
            9'd145: v = 6'd31;
            9'd146: v = 6'd42;
            9'd147: v = 6'd31;
            9'd148: v = 6'd33;
            9'd149: v = 6'd31;
            9'd150: v = 6'd42;
            9'd151: v = 6'd31;
            9'd152: v = 6'd24;
            9'd153: v = 6'd23;
            9'd154: v = 6'd31;
            9'd155: v = 6'd23;
            9'd156: v = 6'd24;
            9'd157: v = 6'd23;
            9'd158: v = 6'd31;
            9'd159: v = 6'd23;
            9'd160: v = 6'd26;
            9'd161: v = 6'd24;
            9'd162: v = 6'd33;
            9'd163: v = 6'd24;
            9'd164: v = 6'd26;
            9'd165: v = 6'd24;
            9'd166: v = 6'd33;
            9'd167: v = 6'd24;
            9'd168: v = 6'd24;
            9'd169: v = 6'd23;
            9'd170: v = 6'd31;
            9'd171: v = 6'd23;
            9'd172: v = 6'd24;
            9'd173: v = 6'd23;
            9'd174: v = 6'd31;
            9'd175: v = 6'd23;
            9'd176: v = 6'd33;
            9'd177: v = 6'd31;
            9'd178: v = 6'd42;
            9'd179: v = 6'd31;
            9'd180: v = 6'd33;
            9'd181: v = 6'd31;
            9'd182: v = 6'd42;
            9'd183: v = 6'd31;
            9'd184: v = 6'd24;
            9'd185: v = 6'd23;
            9'd186: v = 6'd31;
            9'd187: v = 6'd23;
            9'd188: v = 6'd24;
            9'd189: v = 6'd23;
            9'd190: v = 6'd31;
            9'd191: v = 6'd23;
            9'd192: v = 6'd28;
            9'd193: v = 6'd26;
            9'd194: v = 6'd35;
            9'd195: v = 6'd26;
            9'd196: v = 6'd28;
            9'd197: v = 6'd26;
            9'd198: v = 6'd35;
            9'd199: v = 6'd26;
            9'd200: v = 6'd26;
            9'd201: v = 6'd25;
            9'd202: v = 6'd33;
            9'd203: v = 6'd25;
            9'd204: v = 6'd26;
            9'd205: v = 6'd25;
            9'd206: v = 6'd33;
            9'd207: v = 6'd25;
            9'd208: v = 6'd35;
            9'd209: v = 6'd33;
            9'd210: v = 6'd45;
            9'd211: v = 6'd33;
            9'd212: v = 6'd35;
            9'd213: v = 6'd33;
            9'd214: v = 6'd45;
            9'd215: v = 6'd33;
            9'd216: v = 6'd26;
            9'd217: v = 6'd25;
            9'd218: v = 6'd33;
            9'd219: v = 6'd25;
            9'd220: v = 6'd26;
            9'd221: v = 6'd25;
            9'd222: v = 6'd33;
            9'd223: v = 6'd25;
            9'd224: v = 6'd28;
            9'd225: v = 6'd26;
            9'd226: v = 6'd35;
            9'd227: v = 6'd26;
            9'd228: v = 6'd28;
            9'd229: v = 6'd26;
            9'd230: v = 6'd35;
            9'd231: v = 6'd26;
            9'd232: v = 6'd26;
            9'd233: v = 6'd25;
            9'd234: v = 6'd33;
            9'd235: v = 6'd25;
            9'd236: v = 6'd26;
            9'd237: v = 6'd25;
            9'd238: v = 6'd33;
            9'd239: v = 6'd25;
            9'd240: v = 6'd35;
            9'd241: v = 6'd33;
            9'd242: v = 6'd45;
            9'd243: v = 6'd33;
            9'd244: v = 6'd35;
            9'd245: v = 6'd33;
            9'd246: v = 6'd45;
            9'd247: v = 6'd33;
            9'd248: v = 6'd26;
            9'd249: v = 6'd25;
            9'd250: v = 6'd33;
            9'd251: v = 6'd25;
            9'd252: v = 6'd26;
            9'd253: v = 6'd25;
            9'd254: v = 6'd33;
            9'd255: v = 6'd25;
            9'd256: v = 6'd32;
            9'd257: v = 6'd30;
            9'd258: v = 6'd40;
            9'd259: v = 6'd30;
            9'd260: v = 6'd32;
            9'd261: v = 6'd30;
            9'd262: v = 6'd40;
            9'd263: v = 6'd30;
            9'd264: v = 6'd30;
            9'd265: v = 6'd28;
            9'd266: v = 6'd38;
            9'd267: v = 6'd28;
            9'd268: v = 6'd30;
            9'd269: v = 6'd28;
            9'd270: v = 6'd38;
            9'd271: v = 6'd28;
            9'd272: v = 6'd40;
            9'd273: v = 6'd38;
            9'd274: v = 6'd51;
            9'd275: v = 6'd38;
            9'd276: v = 6'd40;
            9'd277: v = 6'd38;
            9'd278: v = 6'd51;
            9'd279: v = 6'd38;
            9'd280: v = 6'd30;
            9'd281: v = 6'd28;
            9'd282: v = 6'd38;
            9'd283: v = 6'd28;
            9'd284: v = 6'd30;
            9'd285: v = 6'd28;
            9'd286: v = 6'd38;
            9'd287: v = 6'd28;
            9'd288: v = 6'd32;
            9'd289: v = 6'd30;
            9'd290: v = 6'd40;
            9'd291: v = 6'd30;
            9'd292: v = 6'd32;
            9'd293: v = 6'd30;
            9'd294: v = 6'd40;
            9'd295: v = 6'd30;
            9'd296: v = 6'd30;
            9'd297: v = 6'd28;
            9'd298: v = 6'd38;
            9'd299: v = 6'd28;
            9'd300: v = 6'd30;
            9'd301: v = 6'd28;
            9'd302: v = 6'd38;
            9'd303: v = 6'd28;
            9'd304: v = 6'd40;
            9'd305: v = 6'd38;
            9'd306: v = 6'd51;
            9'd307: v = 6'd38;
            9'd308: v = 6'd40;
            9'd309: v = 6'd38;
            9'd310: v = 6'd51;
            9'd311: v = 6'd38;
            9'd312: v = 6'd30;
            9'd313: v = 6'd28;
            9'd314: v = 6'd38;
            9'd315: v = 6'd28;
            9'd316: v = 6'd30;
            9'd317: v = 6'd28;
            9'd318: v = 6'd38;
            9'd319: v = 6'd28;
            9'd320: v = 6'd36;
            9'd321: v = 6'd34;
            9'd322: v = 6'd46;
            9'd323: v = 6'd34;
            9'd324: v = 6'd36;
            9'd325: v = 6'd34;
            9'd326: v = 6'd46;
            9'd327: v = 6'd34;
            9'd328: v = 6'd34;
            9'd329: v = 6'd32;
            9'd330: v = 6'd43;
            9'd331: v = 6'd32;
            9'd332: v = 6'd34;
            9'd333: v = 6'd32;
            9'd334: v = 6'd43;
            9'd335: v = 6'd32;
            9'd336: v = 6'd46;
            9'd337: v = 6'd43;
            9'd338: v = 6'd58;
            9'd339: v = 6'd43;
            9'd340: v = 6'd46;
            9'd341: v = 6'd43;
            9'd342: v = 6'd58;
            9'd343: v = 6'd43;
            9'd344: v = 6'd34;
            9'd345: v = 6'd32;
            9'd346: v = 6'd43;
            9'd347: v = 6'd32;
            9'd348: v = 6'd34;
            9'd349: v = 6'd32;
            9'd350: v = 6'd43;
            9'd351: v = 6'd32;
            9'd352: v = 6'd36;
            9'd353: v = 6'd34;
            9'd354: v = 6'd46;
            9'd355: v = 6'd34;
            9'd356: v = 6'd36;
            9'd357: v = 6'd34;
            9'd358: v = 6'd46;
            9'd359: v = 6'd34;
            9'd360: v = 6'd34;
            9'd361: v = 6'd32;
            9'd362: v = 6'd43;
            9'd363: v = 6'd32;
            9'd364: v = 6'd34;
            9'd365: v = 6'd32;
            9'd366: v = 6'd43;
            9'd367: v = 6'd32;
            9'd368: v = 6'd46;
            9'd369: v = 6'd43;
            9'd370: v = 6'd58;
            9'd371: v = 6'd43;
            9'd372: v = 6'd46;
            9'd373: v = 6'd43;
            9'd374: v = 6'd58;
            9'd375: v = 6'd43;
            9'd376: v = 6'd34;
            9'd377: v = 6'd32;
            9'd378: v = 6'd43;
            9'd379: v = 6'd32;
            9'd380: v = 6'd34;
            9'd381: v = 6'd32;
            9'd382: v = 6'd43;
            9'd383: v = 6'd32;
            default: v = 6'd0;
        endcase
    end
endmodule

`default_nettype wire
