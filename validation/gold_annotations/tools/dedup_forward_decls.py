#!/usr/bin/env python3
"""Apply convention §6.1 forward-declaration dedup to a raw annotation file.

§6.1: if both a class-body forward declaration (method NAME without body) and
an out-of-line `itcl::body` exist for the same qualified_name, emit ONE
symbol — use the body's line/end_line as canonical.

This is a one-off remediation for raws produced before v1.1 §6.1 tightened the
schema (e.g., the Opus Component.tcl raw). It is NOT applied automatically by
unwrap.py because it could mask annotator errors on later runs.

Detection heuristic:
- Group symbols by qualified_name.
- If a group has multiple entries, keep the one with the most callees
  (tiebreaker: largest end_line - line span; tiebreaker: highest line).
- Drop the others.

The audit block is NOT touched (the cross-check is symbol-level, not body-count).

Usage:
  dedup_forward_decls.py --in <raw>.json --out <raw>.json [--dry-run]
"""
import argparse
import json
import sys
from pathlib import Path


def body_span(sym: dict) -> int:
    line = sym.get("line") or 0
    end = sym.get("end_line") or 0
    try:
        return int(end) - int(line)
    except (TypeError, ValueError):
        return 0


def pick_canonical(group: list[dict]) -> tuple[dict, list[dict]]:
    """Return (kept, dropped_list)."""
    def score(s: dict) -> tuple[int, int, int]:
        return (
            len(s.get("callees", []) or []),
            body_span(s),
            int(s.get("line") or 0),
        )

    sorted_group = sorted(group, key=score, reverse=True)
    return sorted_group[0], sorted_group[1:]


def dedup(annotation: dict) -> dict:
    symbols = annotation.get("symbols", []) or []
    by_qn: dict = {}
    for sym in symbols:
        qn = sym.get("qualified_name")
        by_qn.setdefault(qn, []).append(sym)

    kept: list[dict] = []
    dropped_log: list[dict] = []

    # Preserve original ordering — walk symbols and keep only the canonical entry
    # for each qualified_name (decide canonical first, then filter).
    canonical_for_qn: dict = {}
    drop_ids: set = set()
    for qn, group in by_qn.items():
        if len(group) <= 1:
            canonical_for_qn[qn] = id(group[0])
            continue
        canon, dropped = pick_canonical(group)
        canonical_for_qn[qn] = id(canon)
        for d in dropped:
            drop_ids.add(id(d))
            dropped_log.append({
                "qualified_name": qn,
                "line": d.get("line"),
                "end_line": d.get("end_line"),
                "n_callees": len(d.get("callees") or []),
                "kept_line": canon.get("line"),
                "kept_end_line": canon.get("end_line"),
                "kept_n_callees": len(canon.get("callees") or []),
            })

    for sym in symbols:
        if id(sym) not in drop_ids:
            kept.append(sym)

    annotation["symbols"] = kept
    return {"kept": len(kept), "dropped": len(dropped_log), "log": dropped_log}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_path", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    annotation = json.loads(args.in_path.read_text())
    stats = dedup(annotation)

    if not args.dry_run:
        with args.out.open("w") as fh:
            json.dump(annotation, fh)
            fh.write("\n")

    print(json.dumps({
        "in": str(args.in_path),
        "out": str(args.out) if not args.dry_run else None,
        "dry_run": args.dry_run,
        "kept_symbols": stats["kept"],
        "dropped_forward_decls": stats["dropped"],
        "drop_log": stats["log"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
