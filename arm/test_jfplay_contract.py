#!/usr/bin/env python3
"""Check that the documented control vocabulary is present in jfplay.c."""

import ast
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent


def table_values(markdown: str, heading: str) -> list[str]:
    match = re.search(rf"^## {re.escape(heading)}\s*$", markdown, re.MULTILINE)
    if not match:
        raise ValueError(f"missing heading: {heading}")
    section = markdown[match.end():]
    next_heading = re.search(r"^## ", section, re.MULTILINE)
    if next_heading:
        section = section[:next_heading.start()]
    values = []
    for line in section.splitlines():
        if not line.startswith("|") or re.match(r"^\|\s*[-:]", line):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if cells and cells[0].lower() not in {"command", "key"}:
            token = cells[0].strip("`").split()[0]
            if token:
                values.append(token)
    return values


def c_string_literals(source: str) -> set[str]:
    literals = set()
    for token in re.findall(r'"(?:\\.|[^"\\])*"', source):
        try:
            literals.add(ast.literal_eval(token))
        except (SyntaxError, ValueError):
            pass
    return literals


def main() -> int:
    doc = (HERE / "jfplay.md").read_text(encoding="utf-8")
    source = (HERE / "jfplay.c").read_text(encoding="utf-8")
    ownership = (HERE / "core_owner.h").read_text(encoding="utf-8")
    wanted = table_values(doc, "FIFO commands") + table_values(doc, "Status keys")
    literals = c_string_literals(source + ownership)
    missing = [name for name in wanted if not any(name in literal for literal in literals)]
    if missing:
        print("missing C string literals: " + ", ".join(missing), file=sys.stderr)
        return 1
    policy_tokens = {
        "in-file seek option": "--start-in-file",
        "analog aspect option": "--analog-aspect",
        "analog aspect command": "aspect ",
        "anti-twitter option": "--anti-twitter",
        "anti-twitter command": "anti-twitter ",
        "PCM queue bound": "#define PCM_MAX_FRAMES 96000",
        "bounded hardware stop reset": "h264ring_flush(p->ring, 1000)",
        "explicit ended state": "STATE_ENDED",
        "timestamp preroll": "#define PTS_MARGIN 90000",
        "natural resampler drain": "drain_swr(p)",
        "core ownership monitor": 'fopen("/tmp/CORENAME", "r")',
        "upstream core name accepted": '"H264"',
        "app core name option": '"--core-name"',
        "app core name launches and owns": "h264ring_launch_core_as(p.cfg.rbf, p.cfg.core_name, 5000)",
        "video writes require ownership": "if (!core_owner_ok(p)) return AVERROR_EXIT;",
        "lost core skips stop cleanup": "if (!core_owner_ok(p)) {\n        p->have_stop_position = 1;",
        "cleanup writes require ownership": "if (core_owner_ok(p)) {\n            if (!p->stop_reset_failed)",
        "raster heartbeat timeout": "#define CORE_HEARTBEAT_TIMEOUT_MS 100",
        "raster heartbeat sample": "H264RING_ST(&st, SEQ_HEAD)",
    }
    absent = [name for name, token in policy_tokens.items() if token not in source + ownership]
    if absent:
        print("missing implementation policies: " + ", ".join(absent), file=sys.stderr)
        return 1
    print(f"contract vocabulary OK: {len(wanted)} names")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
