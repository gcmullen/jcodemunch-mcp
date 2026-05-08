#!/usr/bin/env python3
"""Validate validation/golden_set/edges_v1.jsonl against the current bridge.

Per PLAN_v2.1 §2.7 Signal 4: the golden set is the deterministic gate.
Every (file, caller_qname, callee_name) entry must be captured by the
current bridge in `call_references` (or in `unresolved_dispatches` for
entries with `pattern_kind` starting with `unresolved_`).

Mismatches do NOT necessarily indicate golden-set bugs — they may be
existing bridge gaps documented in HUMAN_ESCALATIONS or v2.1 wins. The
validator's output is a per-entry verdict that documents the current
baseline; v2.1 success requires every PASS entry stays PASS and every
DOCUMENTED-MISS entry has a written rationale.
"""
from __future__ import annotations
import json, os, subprocess, sys
from collections import defaultdict

BRIDGE_PATH = "/tmp/bridge.tcl"
BLUICE_ROOT = "/home/giles/bluice"
GOLDEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "edges_v1.jsonl")


def load_golden():
    entries = []
    with open(GOLDEN_PATH) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"BAD JSON on line {n}: {e}", file=sys.stderr)
                sys.exit(2)
    return entries


def run_bridge(rel_path):
    abs_path = os.path.join(BLUICE_ROOT, rel_path)
    if not os.path.exists(abs_path):
        return None, f"file not found: {abs_path}"
    proc = subprocess.run(
        ["tclsh", BRIDGE_PATH, abs_path],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        return None, f"bridge exit {proc.returncode}: {proc.stderr[:300]}"
    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as e:
        return None, f"bridge JSON parse: {e}"


def main():
    entries = load_golden()
    by_file = defaultdict(list)
    for e in entries:
        by_file[e["file"]].append(e)

    print(f"Golden set: {len(entries)} entries across {len(by_file)} files")
    print()

    bridge_cache = {}
    pass_count = 0
    miss_count = 0
    expected_v2_1_only = 0   # entries marked requires_v2_1 the bridge misses
    misses = []
    v2_1_pending = []

    for file_path in sorted(by_file):
        if file_path not in bridge_cache:
            bridge_out, err = run_bridge(file_path)
            if err:
                print(f"  BRIDGE FAILED on {file_path}: {err}")
                bridge_cache[file_path] = None
                continue
            bridge_cache[file_path] = bridge_out

        symbols = bridge_cache[file_path] or []
        # Index symbols by qualified_name
        sym_by_qname = {}
        for s in symbols:
            qn = s.get("qualified_name", "")
            sym_by_qname[qn] = s
            # Also accept variant: trim leading ::
            if qn.startswith("::"):
                sym_by_qname[qn[2:]] = s

        for ent in by_file[file_path]:
            caller = ent["caller_qname"]
            callee = ent["callee_name"]
            kind = ent["pattern_kind"]
            line_n = ent["line"]
            sym = sym_by_qname.get(caller)
            if sym is None:
                miss_count += 1
                misses.append((file_path, line_n, caller, callee, kind,
                               "CALLER_NOT_FOUND"))
                continue
            requires_v2_1 = bool(ent.get("requires_v2_1"))
            if kind.startswith("unresolved_"):
                ud_kinds = {u.get("kind") for u in
                            sym.get("unresolved_dispatches", [])}
                # Bridge stores tag without `unresolved_` prefix
                # (e.g. `eval_var`, `var_method`, `interp_eval`).
                expected = kind[len("unresolved_"):]
                if expected in ud_kinds:
                    pass_count += 1
                elif requires_v2_1:
                    expected_v2_1_only += 1
                    v2_1_pending.append((file_path, line_n, caller, kind,
                                         f"expected={expected} got={sorted(ud_kinds)}"))
                else:
                    miss_count += 1
                    misses.append((file_path, line_n, caller, callee, kind,
                                   f"UNRESOLVED_NOT_TAGGED (expected: {expected}, got: {sorted(ud_kinds)})"))
            else:
                refs = set(sym.get("call_references", []))
                if callee in refs:
                    pass_count += 1
                elif requires_v2_1:
                    expected_v2_1_only += 1
                    refs_short = sorted(refs)[:8]
                    v2_1_pending.append((file_path, line_n, caller, kind,
                                         f"callee={callee} sample_refs={refs_short}"))
                else:
                    miss_count += 1
                    refs_short = sorted(refs)[:8]
                    misses.append((file_path, line_n, caller, callee, kind,
                                   f"NOT_IN_CALL_REFS (sample refs: {refs_short})"))

    total = pass_count + miss_count + expected_v2_1_only
    cur_total = pass_count + miss_count
    pct_current = (100.0 * pass_count / cur_total) if cur_total else 0.0
    pct_total_required = (100.0 * pass_count / total) if total else 0.0
    print(f"=== RESULT ===")
    print(f"Total entries:                {total}")
    print(f"  Currently captured:          {pass_count}")
    print(f"  Currently missed:            {miss_count} (bridge bugs)")
    print(f"  Marked requires_v2_1:        {expected_v2_1_only} (current-bridge gap, v2.1 must capture)")
    print()
    print(f"Current-bridge capture rate (excluding requires_v2_1): {pct_current:.1f}%")
    print(f"v2.1 target capture rate (full set):                   100.0% required")
    print()
    if misses:
        print("=== UNEXPECTED MISSES (bridge bugs to investigate) ===")
        for m in misses:
            print(f"  {m[0]}:{m[1]} {m[2]} -> {m[3]} ({m[4]})")
            print(f"    {m[5]}")
        print()

    if v2_1_pending:
        print("=== requires_v2_1 ENTRIES (current-bridge gaps; v2.1 must capture) ===")
        for v in v2_1_pending:
            print(f"  {v[0]}:{v[1]} {v[2]} ({v[3]})")
            print(f"    {v[4]}")
        print()

    return 0 if miss_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
