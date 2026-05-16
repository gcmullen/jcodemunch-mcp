#!/usr/bin/env python3
"""Apply per-callee arbiter verdicts onto a file's `<basename>.gold.json` to
produce `<basename>.corrected_gold.json`.

The `<basename>.gold.json` already contains MERGED callees per symbol, where
discrepancy entries are tagged with `discrepancy: true` and `discrepancy_source`
∈ {A_only, B_only, A_line, B_line}. The `<basename>.arbiter.json` file has a
list of verdicts, each keyed by (symbol, callee_name, line) plus the
verdict enum.

Resolution rules per handoff (GOLD_PILOT_PHASE1_HANDOFF.md "Step 3"):
- A_correct        → keep A's callee entry, drop B's mirror (if any), clear discrepancy flag
- B_correct        → keep B's callee entry, drop A's mirror (if any), clear discrepancy flag
- both_correct     → keep both, tag each entry with `arbiter: "both_correct"`
- neither_correct  → drop both
- convention_ambiguous → keep both, tag with `arbiter: "convention_ambiguous"` + flag for human

Every callee entry touched by an arbiter verdict gains an `arbiter_verdict`
sub-object recording the verdict + rule_basis + justification for traceability.

Symbols/callees the arbiter did NOT touch are passed through unchanged.

Usage:
  apply_arbiter.py \
    --gold <basename>.gold.json \
    --arbiter <basename>.arbiter.json \
    --out <basename>.corrected_gold.json
"""
import argparse
import json
import sys
from pathlib import Path


def find_callees(
    symbol: dict, callee_name: str, line: int, tolerance: int = 0
) -> list[tuple[int, dict]]:
    """Return all (index, callee) pairs in this symbol matching name+line.

    Line match is exact when tolerance=0 (default). Set tolerance>0 to allow
    ±N line drift between verdict line and gold-callee line. A non-zero
    tolerance can cause cascading drops when multiple distinct callees with
    the same name occupy adjacent lines (e.g. multiple `variable` declarations
    in a proc body); use 0 unless you have a specific drift to compensate for.
    """
    callees = symbol.get("callees", [])
    out: list[tuple[int, dict]] = []
    for i, c in enumerate(callees):
        if c.get("name") != callee_name:
            continue
        c_line = c.get("line")
        if c_line == line:
            out.append((i, c))
        elif tolerance > 0 and isinstance(c_line, int) and isinstance(line, int) and abs(c_line - line) <= tolerance:
            out.append((i, c))
    return out


def apply_verdict(symbol: dict, verdict: dict, stats: dict, tolerance: int = 0) -> None:
    """Mutate `symbol['callees']` in place per the verdict."""
    name = verdict["callee_name"]
    line = verdict["line"]
    decision = verdict["verdict"]
    rule_basis = verdict.get("rule_basis", "")
    justification = verdict.get("justification", "")

    matches = find_callees(symbol, name, line, tolerance=tolerance)
    if not matches:
        stats.setdefault("unmatched_verdicts", []).append({
            "symbol": symbol.get("qualified_name"),
            "callee_name": name,
            "line": line,
            "verdict": decision,
        })
        return

    # Split matches by source: A_only, B_only, A_line, B_line, or no discrepancy marker
    a_indices: list[int] = []
    b_indices: list[int] = []
    other_indices: list[int] = []  # consensus entries (rare here)
    for i, c in matches:
        src = c.get("discrepancy_source")
        if src in ("A_only", "A_line"):
            a_indices.append(i)
        elif src in ("B_only", "B_line"):
            b_indices.append(i)
        else:
            other_indices.append(i)

    verdict_meta = {
        "verdict": decision,
        "rule_basis": rule_basis,
        "justification": justification,
    }

    drop: set[int] = set()
    if decision == "A_correct":
        for i in a_indices:
            symbol["callees"][i].pop("discrepancy", None)
            symbol["callees"][i].pop("discrepancy_source", None)
            symbol["callees"][i]["arbiter_verdict"] = verdict_meta
        for i in b_indices:
            drop.add(i)
    elif decision == "B_correct":
        for i in b_indices:
            symbol["callees"][i].pop("discrepancy", None)
            symbol["callees"][i].pop("discrepancy_source", None)
            symbol["callees"][i]["arbiter_verdict"] = verdict_meta
        for i in a_indices:
            drop.add(i)
    elif decision == "both_correct":
        for i in a_indices + b_indices + other_indices:
            symbol["callees"][i].pop("discrepancy", None)
            symbol["callees"][i].pop("discrepancy_source", None)
            symbol["callees"][i]["arbiter_verdict"] = verdict_meta
    elif decision == "neither_correct":
        for i in a_indices + b_indices + other_indices:
            drop.add(i)
    elif decision == "convention_ambiguous":
        for i in a_indices + b_indices + other_indices:
            symbol["callees"][i]["arbiter_verdict"] = verdict_meta
            symbol["callees"][i]["needs_human_review"] = True
        stats.setdefault("convention_ambiguous_callees", []).append({
            "symbol": symbol.get("qualified_name"),
            "callee_name": name,
            "line": line,
        })
    else:
        stats.setdefault("unknown_verdicts", []).append(decision)
        return

    if drop:
        symbol["callees"] = [
            c for i, c in enumerate(symbol["callees"]) if i not in drop
        ]

    stats[decision] = stats.get(decision, 0) + 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--arbiter", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument(
        "--line-tolerance",
        type=int,
        default=0,
        help="Allow ±N line drift between arbiter verdict line and gold callee line. "
        "Default 0 (strict). Non-zero values can cause cascading drops when multiple "
        "callees with the same name occupy adjacent lines.",
    )
    args = ap.parse_args()

    gold = json.loads(args.gold.read_text())
    arbiter = json.loads(args.arbiter.read_text())

    # Index symbols by qualified_name for fast lookup
    by_qn: dict = {}
    for sym in gold.get("symbols", []):
        by_qn.setdefault(sym.get("qualified_name"), []).append(sym)

    stats: dict = {
        "n_verdicts": 0,
        "A_correct": 0,
        "B_correct": 0,
        "both_correct": 0,
        "neither_correct": 0,
        "convention_ambiguous": 0,
    }

    for v in arbiter.get("verdicts", []):
        stats["n_verdicts"] += 1
        candidates = by_qn.get(v.get("symbol")) or []
        if not candidates:
            stats.setdefault("missing_symbols", []).append(v.get("symbol"))
            continue
        # Apply to all symbols matching the qualified_name (typically just one)
        for sym in candidates:
            apply_verdict(sym, v, stats, tolerance=args.line_tolerance)

    # Embed arbiter provenance
    gold["arbiter"] = {
        "arbiter_file": str(args.arbiter.name),
        "summary": arbiter.get("summary", {}),
        "applied": stats,
    }

    args.out.write_text(json.dumps(gold, indent=2) + "\n")

    print(json.dumps({
        "out_path": str(args.out),
        "applied": stats,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
