#!/usr/bin/env python3
"""Render h264/dec/high_tables.sv -- the High-profile ROMs of the RTL, as small `case`
modules -- from tools/high_tables.py (transcribed from the spec PDF and cross-checked
against ffmpeg by tools/gen_high_tables.py). Never hand-typed: `--check` compares the
file in the tree with what this renders (bench/h264/run_h264_top.sh runs it).

Modules (every output registered by its user, not here: these are pure lookups):
  hp_sl_default  (a[5:0] -> q[31:0]) the default scaling lists (Tables 7-3 / 7-4) as the
                 front end emits them: word a of Default_4x4_Intra (0..3), Default_4x4_Inter
                 (4..7), Default_8x8_Intra (8..23), Default_8x8_Inter (24..39); four
                 weights a word in coded (zig-zag) order, the first in bits 7..0
  hp_ctx8        (i[5:0] -> sig_fr[3:0], sig_fl[3:0], last[3:0]) Table 9-43, levelListIdx
                 0..62 (63: zeros, never asked)
  hp_scan8       (field, k[5:0] -> r[5:0]) Table 8-14: scan index -> raster 8 i + j
  hp_zzinv4      (r[3:0] -> k[3:0]) raster 4 i + j -> the zig-zag index (the position of a
                 weight in a coded 4x4 scaling list, 8.5.6)
  hp_zzinv8      (r[5:0] -> k[5:0]) the same for 8x8 (8.5.7)
  hp_norm8       (m[2:0], r[5:0] -> v[5:0]) normAdjust8x8(m, i, j) (8-317 / 8-318)

    render_high_tables.py > h264/dec/high_tables.sv
    render_high_tables.py --check
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import high_tables as HT  # noqa: E402

SV = os.path.join(HERE, "..", "h264", "dec", "high_tables.sv")


def words(lst):
    return [lst[k] | (lst[k + 1] << 8) | (lst[k + 2] << 16) | (lst[k + 3] << 24) for k in range(0, len(lst), 4)]


def norm8(m, i, j):
    v = HT.NORM_ADJUST8[m]
    if i % 4 == 0 and j % 4 == 0:
        return v[0]
    if i % 2 == 1 and j % 2 == 1:
        return v[1]
    if i % 4 == 2 and j % 4 == 2:
        return v[2]
    if (i % 4 == 0 and j % 2 == 1) or (i % 2 == 1 and j % 4 == 0):
        return v[3]
    if (i % 4 == 0 and j % 4 == 2) or (i % 4 == 2 and j % 4 == 0):
        return v[4]
    return v[5]


def render():
    o = ["// h264/dec/high_tables.sv -- the High-profile ROMs (docs/high_profile.md).",
         "// RENDERED by tools/render_high_tables.py from tools/high_tables.py (the spec PDF,",
         "// cross-checked against ffmpeg); do not edit (bench/h264/run_h264_top.sh checks it).",
         "// Pure lookups as `case` blocks (CLAUDE.md: no function automatic, no N'() casts).",
         "", "`default_nettype none", ""]
    dw = words(HT.DEFAULT_4X4_INTRA) + words(HT.DEFAULT_4X4_INTER) + words(HT.DEFAULT_8X8_INTRA) + \
        words(HT.DEFAULT_8X8_INTER)
    assert len(dw) == 40
    o += ["module hp_sl_default (input wire [5:0] a, output logic [31:0] q);",
          "    always_comb begin", "        case (a)"]
    for a, w in enumerate(dw):
        o.append("            6'd%d: q = 32'h%08x;" % (a, w))
    o += ["            default: q = 32'h10101010;", "        endcase", "    end", "endmodule", ""]
    o += ["module hp_ctx8 (input wire [5:0] i, output logic [3:0] sig_fr, output logic [3:0] sig_fl,",
          "                output logic [3:0] last);", "    always_comb begin", "        case (i)"]
    for i in range(63):
        o.append("            6'd%d: begin sig_fr = 4'd%d; sig_fl = 4'd%d; last = 4'd%d; end"
                 % (i, HT.SIG8_FRAME[i], HT.SIG8_FIELD[i], HT.LAST8[i]))
    o += ["            default: begin sig_fr = 4'd0; sig_fl = 4'd0; last = 4'd0; end", "        endcase",
          "    end", "endmodule", ""]
    o += ["module hp_scan8 (input wire field, input wire [5:0] k, output logic [5:0] r);",
          "    always_comb begin", "        case ({field, k})"]
    for f, sc in enumerate((HT.ZIGZAG8, HT.FIELD_SCAN8)):
        for k, r in enumerate(sc):
            o.append("            7'd%d: r = 6'd%d;" % (64 * f + k, r))
    o += ["            default: r = 6'd0;", "        endcase", "    end", "endmodule", ""]
    inv4 = [0] * 16
    for k, r in enumerate(HT.ZIGZAG4):
        inv4[r] = k
    o += ["module hp_zzinv4 (input wire [3:0] r, output logic [3:0] k);",
          "    always_comb begin", "        case (r)"]
    for r, k in enumerate(inv4):
        o.append("            4'd%d: k = 4'd%d;" % (r, k))
    o += ["            default: k = 4'd0;", "        endcase", "    end", "endmodule", ""]
    inv8 = [0] * 64
    for k, r in enumerate(HT.ZIGZAG8):
        inv8[r] = k
    o += ["module hp_zzinv8 (input wire [5:0] r, output logic [5:0] k);",
          "    always_comb begin", "        case (r)"]
    for r, k in enumerate(inv8):
        o.append("            6'd%d: k = 6'd%d;" % (r, k))
    o += ["            default: k = 6'd0;", "        endcase", "    end", "endmodule", ""]
    o += ["module hp_norm8 (input wire [2:0] m, input wire [5:0] r, output logic [5:0] v);",
          "    always_comb begin", "        case ({m, r})"]
    for m in range(6):
        for r in range(64):
            o.append("            9'd%d: v = 6'd%d;" % (64 * m + r, norm8(m, r >> 3, r & 7)))
    o += ["            default: v = 6'd0;", "        endcase", "    end", "endmodule", "",
          "`default_nettype wire", ""]
    return "\n".join(o)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--check"]:
        have = open(SV).read() if os.path.exists(SV) else ""
        if have != render():
            print("high_tables.sv DIFFERS from tools/high_tables.py -- re-render it")
            return 1
        print("high_tables.sv matches tools/high_tables.py")
        return 0
    sys.stdout.write(render())
    return 0


if __name__ == "__main__":
    sys.exit(main())
