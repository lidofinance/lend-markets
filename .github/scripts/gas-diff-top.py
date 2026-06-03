#!/usr/bin/env python3
"""
Reduce `forge snapshot --diff` output to a short top-N markdown table.

Foundry emits one line per test:
    ━ Suite::test_name() (gas: 12345 → 12420 | +75 +0.61%)

Plus a final summary:
    Total tests: 50, ↑ 5, ↓ 3, ━ 42
    Overall gas change: -125 (-0.025%)

The full diff can be hundreds of lines on a non-trivial suite. We keep:
    - top N tests ranked by absolute gas delta (non-zero only)
    - the totals line
    - a count of how many tests had any delta

Usage:
    gas-diff-top.py --input diff.txt --output report.md --top 10
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROW_RE = re.compile(
    r"^━\s+(?P<test>.+?)\s+\(gas:\s+(?P<base>\d+)\s+→\s+(?P<head>\d+)\s+\|\s+(?P<delta>[+\-]?\d+)\s+(?P<pct>[+\-]?[\d.]+|NaN)%?\)"
)
TOTALS_RE = re.compile(r"^(Total tests:.*|Overall gas change:.*)$")


def fmt_int(n: int) -> str:
    return f"{n:,}".replace(",", " ")


def fmt_delta(n: int) -> str:
    if n == 0:
        return "·"
    sign = "+" if n > 0 else "−"
    return f"{sign}{fmt_int(abs(n))}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--output", type=Path)
    p.add_argument("--top", type=int, default=10)
    args = p.parse_args()

    rows: list[tuple[int, str, int, int, str]] = []
    totals: list[str] = []
    changed = 0

    for line in args.input.read_text().splitlines():
        m = ROW_RE.match(line)
        if m:
            delta = int(m.group("delta"))
            if delta == 0:
                continue
            changed += 1
            rows.append((delta, m.group("test"), int(m.group("base")), int(m.group("head")), m.group("pct")))
            continue
        if TOTALS_RE.match(line):
            totals.append(line)

    rows.sort(key=lambda r: -abs(r[0]))
    top = rows[: args.top]

    out: list[str] = []
    if changed == 0:
        out.append("No gas change.")
    else:
        out.append(
            f"Top {min(args.top, changed)} of {changed} test(s) with non-zero gas delta:"
        )
        out.append("")
        out.append("| Test | base | head | Δ | Δ % |")
        out.append("|---|---:|---:|---:|---:|")
        for delta, test, base, head, pct in top:
            out.append(
                f"| `{test}` | {fmt_int(base)} | {fmt_int(head)} | {fmt_delta(delta)} | {pct}% |"
            )

    if totals:
        out.append("")
        for t in totals:
            out.append(f"`{t}`")

    rendered = "\n".join(out) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
