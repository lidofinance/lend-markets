#!/usr/bin/env python3
"""
Build a markdown contract-size report (and diff) from `forge build --sizes --json` output.

Inputs:
    --head <file>   Required. Forge sizes JSON for PR head (or current revision).
    --base <file>   Optional. Forge sizes JSON for base branch. Enables the diff column.
    --min-size <n>  Filter out contracts whose runtime size is below n bytes in both base and
                    head AND that have zero delta. Default 200. Drops near-empty library stubs
                    (~45 bytes) while keeping real contracts visible.
    --warn-margin   Bytes. Print a warning line for any contract whose runtime margin to
                    EIP-170 (24576) is below this. Default 5120 (~5 KB).
    --output <file> Write the markdown report here. Defaults to stdout.

`forge build --sizes --json` emits the size object as the first line on stdout, followed by
per-contract diagnostic JSON lines. We pick the first line whose top-level value has a
`runtime_size` field — that is the size object regardless of where forge places it.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

EIP_170 = 24576


@dataclass
class Size:
    runtime: int
    init: int

    @classmethod
    def from_dict(cls, d: dict) -> "Size":
        return cls(runtime=int(d["runtime_size"]), init=int(d["init_size"]))


def load_sizes(path: Path) -> dict[str, Size]:
    """Extract the sizes dict from forge output.

    forge mixes the sizes JSON with diagnostic lines on stdout when warnings exist. The sizes
    blob is a JSON object whose values have `runtime_size`; scan lines until one parses to that
    shape.
    """
    raw = path.read_text()
    # Forge prints the whole sizes blob on one line, but be defensive: try whole file, then
    # line-by-line.
    candidates = [raw] + raw.splitlines()
    for candidate in candidates:
        candidate = candidate.strip()
        if not candidate.startswith("{"):
            continue
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict) or not parsed:
            continue
        first_val = next(iter(parsed.values()))
        if isinstance(first_val, dict) and "runtime_size" in first_val:
            return {name: Size.from_dict(val) for name, val in parsed.items()}
    raise SystemExit(f"no sizes object found in {path}")


def is_vendored(name: str) -> bool:
    """Drop contracts that come from `lib/` (forge tags ambiguous names with their source path)
    and version-suffixed twins (`Foo.0.8.19`, `Foo.0.8.24`) — they're the same upstream lib
    compiled under different solc versions."""
    if "(lib/" in name or name.startswith("lib/"):
        return True
    if name.endswith(".0.8.19") or name.endswith(".0.8.24"):
        return True
    return False


def fmt_int(n: int) -> str:
    return f"{n:,}".replace(",", " ")


def fmt_delta(n: int) -> str:
    if n == 0:
        return "·"
    sign = "+" if n > 0 else "−"
    return f"{sign}{fmt_int(abs(n))}"


def render(
    head: dict[str, Size],
    base: dict[str, Size] | None,
    min_size: int,
    warn_margin: int,
) -> str:
    names = set(head)
    if base is not None:
        names |= set(base)
    names = {n for n in names if not is_vendored(n)}

    rows = []
    for name in names:
        h = head.get(name)
        b = base.get(name) if base is not None else None
        h_rt = h.runtime if h else 0
        h_in = h.init if h else 0
        b_rt = b.runtime if b else 0
        b_in = b.init if b else 0
        d_rt = h_rt - b_rt if base is not None else 0
        d_in = h_in - b_in if base is not None else 0
        if max(h_rt, b_rt) < min_size and d_rt == 0:
            continue
        margin = EIP_170 - h_rt if h else None
        rows.append((name, h_rt, h_in, b_rt, b_in, d_rt, d_in, margin))

    # Sort: changed first by |Δ runtime| desc, unchanged after by runtime size desc.
    rows.sort(key=lambda r: (-abs(r[5]), -r[1]))

    out = []
    if base is not None:
        out.append("| Contract | runtime | Δ runtime | init | Δ init | EIP-170 margin |")
        out.append("|---|---:|---:|---:|---:|---:|")
        for name, h_rt, h_in, b_rt, b_in, d_rt, d_in, margin in rows:
            margin_str = fmt_int(margin) if margin is not None else "—"
            if h_rt == 0 and base is not None and b_rt > 0:
                margin_str = "removed"
            out.append(
                f"| {name} | {fmt_int(h_rt)} | {fmt_delta(d_rt)} | "
                f"{fmt_int(h_in)} | {fmt_delta(d_in)} | {margin_str} |"
            )
    else:
        out.append("| Contract | runtime | init | EIP-170 margin |")
        out.append("|---|---:|---:|---:|")
        for name, h_rt, h_in, _, _, _, _, margin in rows:
            margin_str = fmt_int(margin) if margin is not None else "—"
            out.append(
                f"| {name} | {fmt_int(h_rt)} | {fmt_int(h_in)} | {margin_str} |"
            )

    warnings = [
        (name, margin)
        for name, h_rt, _, _, _, _, _, margin in rows
        if margin is not None and h_rt > 0 and margin < warn_margin
    ]
    if warnings:
        out.append("")
        out.append(f"**Warning**: {len(warnings)} contract(s) within {fmt_int(warn_margin)} bytes of the 24 KB EIP-170 limit:")
        for name, margin in warnings:
            out.append(f"- `{name}` — {fmt_int(margin)} bytes free")

    over_limit = [
        (name, h_rt)
        for name, h_rt, _, _, _, _, _, margin in rows
        if margin is not None and margin < 0
    ]
    if over_limit:
        out.append("")
        out.append(f"**Error**: {len(over_limit)} contract(s) exceed the EIP-170 24 KB limit:")
        for name, size in over_limit:
            out.append(f"- `{name}` — {fmt_int(size)} bytes (max {fmt_int(EIP_170)})")

    return "\n".join(out) + "\n"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--head", type=Path, required=True)
    p.add_argument("--base", type=Path)
    p.add_argument("--min-size", type=int, default=200)
    p.add_argument("--warn-margin", type=int, default=5120)
    p.add_argument("--output", type=Path)
    p.add_argument("--fail-on-oversize", action="store_true", help="Exit non-zero if any contract exceeds EIP-170.")
    args = p.parse_args()

    head = load_sizes(args.head)
    base = load_sizes(args.base) if args.base and args.base.exists() else None

    report = render(head, base, args.min_size, args.warn_margin)

    if args.output:
        args.output.write_text(report)
    else:
        sys.stdout.write(report)

    if args.fail_on_oversize:
        over = [n for n, s in head.items() if not is_vendored(n) and s.runtime > EIP_170]
        if over:
            print(f"\nFAIL: oversized contracts: {', '.join(over)}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
