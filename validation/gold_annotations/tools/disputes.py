#!/usr/bin/env python3
"""Emit the dispute list (in the schema GOLD_ARBITER_PROMPT_v1.md §Inputs expects)
from a file's `<basename>.discrepancies.json`.

Inputs:
  - Path to `<basename>.discrepancies.json` (positional) OR --in <path>.

Output (to stdout):
  A single JSON array. Each element:
    {
      "symbol": "<qualified_name>",
      "symbol_kind": "<class|method|...>",
      "name": "<callee-name>",
      "callee_kind": "<static|qualified|...>",
      "line": <int>,
      "source": "A_only | B_only | kind_mismatch | line_drift_>2"
    }

Sources covered:
  - `per_symbol_callees` entries with `source` ∈ {A_only, B_only} → emitted verbatim.
  - `per_symbol_callees` entries with `issue: "line_drift_>2"` → emitted with
     source="line_drift_>2"; line = a_line (b_line carried as note in --pretty).
  - Optional --detect-kind-mismatch: pair A_only+B_only entries that share
    (symbol, name, line) but differ in callee_kind, collapse them to a single
    kind_mismatch entry.

The `symbol_set.a_only` / `symbol_set.b_only` arrays (symbol-level divergences)
are NOT included by default — arbiter operates per callee, not per symbol.
Pass --include-symbol-set to surface them as synthetic disputes with
callee_name = "<symbol-set>".

Usage:
  disputes.py <basename>.discrepancies.json [--detect-kind-mismatch]
  disputes.py --in <path> [--detect-kind-mismatch]
"""
import argparse
import json
import sys
from pathlib import Path


def normalize_callee_entry(entry: dict) -> dict:
    """Map a per_symbol_callees entry → arbiter dispute entry."""
    source = entry.get("source") or entry.get("issue")
    line = entry.get("line")
    if source == "line_drift_>2":
        line = entry.get("a_line")
    return {
        "symbol": entry.get("qualified_name"),
        "symbol_kind": entry.get("kind"),
        "name": entry.get("name"),
        "callee_kind": entry.get("callee_kind"),
        "line": line,
        "source": source,
    }


def detect_kind_mismatches(disputes: list[dict]) -> list[dict]:
    """Collapse (A_only, B_only) pairs that share (symbol, name, line) but differ
    in callee_kind into a single kind_mismatch entry."""
    by_loc: dict = {}
    for d in disputes:
        key = (d["symbol"], d["name"], d["line"])
        by_loc.setdefault(key, []).append(d)

    out: list[dict] = []
    used: set = set()
    for i, d in enumerate(disputes):
        if i in used:
            continue
        key = (d["symbol"], d["name"], d["line"])
        partners = [
            (j, p)
            for j, p in enumerate(disputes)
            if j != i
            and j not in used
            and (p["symbol"], p["name"], p["line"]) == key
            and p["callee_kind"] != d["callee_kind"]
            and {d["source"], p["source"]} == {"A_only", "B_only"}
        ]
        if partners:
            j, p = partners[0]
            used.add(i)
            used.add(j)
            # Order: A first, B second
            a_entry, b_entry = (d, p) if d["source"] == "A_only" else (p, d)
            out.append({
                "symbol": d["symbol"],
                "symbol_kind": d["symbol_kind"],
                "name": d["name"],
                "callee_kind_A": a_entry["callee_kind"],
                "callee_kind_B": b_entry["callee_kind"],
                "line": d["line"],
                "source": "kind_mismatch",
            })
        else:
            used.add(i)
            out.append(d)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", help="Path to <basename>.discrepancies.json")
    ap.add_argument("--in", dest="in_path", help="Alternative to positional path")
    ap.add_argument("--detect-kind-mismatch", action="store_true")
    ap.add_argument(
        "--include-symbol-set",
        action="store_true",
        help="Also surface symbol-set divergences as synthetic disputes.",
    )
    ap.add_argument("--pretty", action="store_true")
    args = ap.parse_args()

    path = args.in_path or args.path
    if not path:
        print("error: must provide path or --in", file=sys.stderr)
        return 2

    with open(path) as fh:
        disc = json.load(fh)

    disputes: list[dict] = []
    for entry in disc.get("per_symbol_callees", []):
        disputes.append(normalize_callee_entry(entry))

    if args.include_symbol_set:
        for entry in disc.get("symbol_set", {}).get("a_only", []):
            disputes.append({
                "symbol": entry.get("qualified_name"),
                "symbol_kind": entry.get("kind"),
                "name": "<symbol-set>",
                "callee_kind": None,
                "line": (entry.get("a_entry") or {}).get("line"),
                "source": "A_only",
            })
        for entry in disc.get("symbol_set", {}).get("b_only", []):
            disputes.append({
                "symbol": entry.get("qualified_name"),
                "symbol_kind": entry.get("kind"),
                "name": "<symbol-set>",
                "callee_kind": None,
                "line": (entry.get("b_entry") or {}).get("line"),
                "source": "B_only",
            })

    if args.detect_kind_mismatch:
        disputes = detect_kind_mismatches(disputes)

    indent = 2 if args.pretty else None
    json.dump(disputes, sys.stdout, indent=indent)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
