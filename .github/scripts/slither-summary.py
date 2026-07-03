#!/usr/bin/env python3
"""
Render a short markdown summary of slither findings from `slither` text output.

Per finding, slither emits a block:

    INFO:Detectors:
    <finding text, possibly multiline>
    Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#<detector-id>

The summary collapses findings into a table by detector id and lists the affected
contracts. The full log stays in the `slither-log` artefact and the Job Summary;
the comment is intentionally short so it doesn't drown out review threads.

Usage:
    slither-summary.py --log slither.log --output comment.md
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

REF_RE = re.compile(
    r"Reference:\s+https://github\.com/crytic/slither/wiki/Detector-Documentation#(\S+)"
)
# A finding header sits at column 0 (no leading whitespace) and starts either with
# `Reentrancy in ContractName...` or directly with `ContractName.something(...)`. Continuation
# lines inside a finding are indented with tabs and are not matched.
FINDING_RE = re.compile(
    r"^(?:Reentrancy in )?([A-Z][A-Za-z0-9_]*)\.",
    re.MULTILINE,
)
SUMMARY_RE = re.compile(r"analyzed \((\d+) contracts? with (\d+) detectors?\), (\d+) result")


def parse(log: str) -> tuple[dict[str, dict], dict]:
    # Each detector class produces one block prefixed by `INFO:Detectors:`; inside the block,
    # there may be one or more findings sharing the same trailing `Reference:` URL.
    blocks = log.split("INFO:Detectors:\n")[1:]
    agg: dict[str, dict] = defaultdict(lambda: {"count": 0, "contracts": set()})

    for block in blocks:
        m = REF_RE.search(block)
        if not m:
            continue
        detector = m.group(1)
        body = block.split("Reference:")[0]
        # Count individual finding headers within this detector block.
        finding_count = 0
        contracts: set[str] = set()
        for fm in FINDING_RE.finditer(body):
            finding_count += 1
            name = fm.group(1)
            if name not in {"None", "ID", "WAD"}:
                contracts.add(name)
        if finding_count == 0:
            continue
        agg[detector]["count"] += finding_count
        agg[detector]["contracts"] |= contracts

    summary_match = SUMMARY_RE.search(log)
    meta = {}
    if summary_match:
        meta["analyzed_contracts"] = int(summary_match.group(1))
        meta["detectors"] = int(summary_match.group(2))
        meta["slither_reported_total"] = int(summary_match.group(3))
    return agg, meta


def render(agg: dict[str, dict], meta: dict) -> str:
    total = sum(v["count"] for v in agg.values())
    out: list[str] = []

    if total == 0:
        out.append("## Slither — no findings (medium+)")
        out.append("")
        out.append("Clean run. Detectors active per `slither.config.json`.")
    else:
        out.append(f"## Slither — {total} finding(s)")
        out.append("")
        out.append("| Detector | Count | Contracts |")
        out.append("|---|---:|---|")
        for det, info in sorted(agg.items(), key=lambda x: (-x[1]["count"], x[0])):
            contracts = ", ".join(f"`{c}`" for c in sorted(info["contracts"])) or "—"
            out.append(f"| [`{det}`](https://github.com/crytic/slither/wiki/Detector-Documentation#{det}) | {info['count']} | {contracts} |")
        out.append("")
        out.append("Full log: `slither-log` artefact and Job Summary.")

    if meta:
        out.append("")
        out.append(
            f"<sub>{meta.get('analyzed_contracts', '?')} contracts analyzed "
            f"with {meta.get('detectors', '?')} detectors.</sub>"
        )
    return "\n".join(out) + "\n"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--log", type=Path, required=True)
    p.add_argument("--output", type=Path)
    args = p.parse_args()

    log = args.log.read_text()
    agg, meta = parse(log)
    md = render(agg, meta)

    if args.output:
        args.output.write_text(md)
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
