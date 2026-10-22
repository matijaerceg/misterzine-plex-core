#!/usr/bin/env python3
"""Exhaust every waiting-store mask/current-store pair against C.4.4 count semantics."""
NSTORE = 20
limit = 1 << NSTORE
for mask in range(limit):
    population = mask.bit_count()
    for current in range(NSTORE):
        got = population - ((mask >> current) & 1)
        # Independent definition: clear the current store, then count the rest.
        want = (mask & ~(1 << current)).bit_count()
        if got != want:
            raise SystemExit(f"FAIL: mask={mask:#x} current={current} got={got} want={want}")
print(f"PASS: exhaustive DPB drop semantics ({limit * NSTORE:,} mask/current pairs)")
