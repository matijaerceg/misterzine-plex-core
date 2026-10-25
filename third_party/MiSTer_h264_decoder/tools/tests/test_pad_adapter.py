#!/usr/bin/env python3
"""Simulate the actual core pad adapter, including Start, on every input bit."""
from pathlib import Path
import re, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "h264/emu.sv").read_text()
fn = re.search(r"function \[31:0\] input_region_joy.*?endfunction", src, re.S).group()
# Compact JN slots: d-pad, OK, Back, shoulders, Pause/Play.
expected = [0, 1, 2, 3, 5, 4, 8, 9, 11]
checks = []
for bit in range(32):
    want = 1 << expected[bit] if bit < len(expected) else 0
    checks.append(f"if (input_region_joy(32'h{1 << bit:08x}) !== 32'h{want:08x}) $fatal(1, \"pad bit {bit}\");")
bench = "module test;\n" + fn + "\ninitial begin\n" + "\n".join(checks) + "\n$display(\"pad adapter: ALL GREEN\"); $finish; end endmodule\n"
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp)
    (p / "test.sv").write_text(bench)
    subprocess.run(["iverilog", "-g2012", "-o", str(p / "sim"), str(p / "test.sv")], check=True)
    subprocess.run(["vvp", str(p / "sim")], check=True)
