#!/usr/bin/env python3
"""Compare Layer-2 LLM oracle against parser-stored callees.

For each (file, qualified_name) entry in the merged oracle, look up the
parser's call_references in SQLite and compute:
  - precision: parser_callees ∩ oracle_callees / parser_callees
  - recall:    parser_callees ∩ oracle_callees / oracle_callees
  - F1:        2*P*R / (P+R)

Aggregate per-file and overall. Surface the 20 largest discrepancies.
"""
from __future__ import annotations
import json, glob, os, sqlite3, sys
from collections import defaultdict

REPO_TO_DB = {
    "/home/giles/bluice/BluIceWidgets":  "/home/giles/.code-index/local-BluIceWidgets-19352233.db",
    "/home/giles/bluice/DcsWidgets":     "/home/giles/.code-index/local-DcsWidgets-7dc5ff84.db",
    "/home/giles/bluice/dcss":           "/home/giles/.code-index/local-dcss-c606e2b4.db",
    "/home/giles/bluice/dhs-tcl":        "/home/giles/.code-index/local-dhs-tcl-59162212.db",
    "/home/giles/bluice/dcs-lib-tcl":    "/home/giles/.code-index/local-dcs-lib-tcl-c2394eb3.db",
}

def repo_db_for(abs_path):
    for repo, db in REPO_TO_DB.items():
        if abs_path.startswith(repo + "/"):
            return repo, db, abs_path[len(repo)+1:]
    return None, None, None


def normalize(name):
    """Normalize a callee name for comparison: drop leading ::, return just
    last segment if namespaced (parser callees are sometimes bare even when
    oracle is FQN, and vice versa)."""
    if name.startswith("::"):
        name = name[2:]
    return name


def name_set(callees):
    """Build a comparison set including both full and last-segment forms."""
    out = set()
    for c in callees or []:
        n = normalize(c)
        out.add(n)
        if "::" in n:
            out.add(n.rsplit("::", 1)[-1])
    return out


ORACLE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oracle")


def load_layer2():
    merged = {}
    for path in sorted(glob.glob(os.path.join(ORACLE_DIR, "layer2_oracle_batch_*.json"))):
        d = json.load(open(path))
        for f in d.get("files", []):
            file_path = f["file"]
            for s in f.get("symbols", []):
                merged[(file_path, s["qualified_name"])] = {
                    "expected": s.get("expected_callees", []),
                    "line": s.get("line"),
                }
    return merged


def lookup_parser_callees(file_abs, qualified_name):
    repo, db_path, rel = repo_db_for(file_abs)
    if not repo:
        return None
    db = sqlite3.connect(db_path)
    rows = db.execute(
        "SELECT data FROM symbols WHERE file=? AND qualified_name=?",
        (rel, qualified_name)
    ).fetchall()
    if not rows:
        return None
    # Pick the row with non-NULL data if available
    for r in rows:
        if r[0] is not None:
            try:
                v = json.loads(r[0])
                if isinstance(v, list):
                    return v
            except Exception:
                pass
    return []


def main():
    oracle = load_layer2()
    print(f"Layer-2 oracle: {len(oracle)} symbols across "
          f"{len({k[0] for k in oracle})} files")

    total_expected = 0
    total_parser = 0
    total_tp = 0   # true positives  (in both)
    total_fn = 0   # false negatives (in oracle only — missed by parser)
    total_fp = 0   # false positives (in parser only — not real callees)

    per_file = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0,
                                    "missed": [], "spurious": []})
    discrepancies = []

    not_found = 0
    for (file_path, qname), entry in sorted(oracle.items()):
        expected = entry["expected"] or []
        actual_raw = lookup_parser_callees(file_path, qname)
        if actual_raw is None:
            not_found += 1
            continue
        actual = actual_raw

        es = name_set(expected)
        as_ = name_set(actual)

        # Match using both-sides normalization. A name in oracle is a "hit"
        # if any of its forms are in parser's set. A parser name is "spurious"
        # only if none of its forms are in oracle.
        oracle_hit = set()
        for e in expected:
            forms = name_set([e])
            if forms & as_:
                oracle_hit.add(e)
        parser_hit = set()
        for a in actual:
            forms = name_set([a])
            if forms & es:
                parser_hit.add(a)

        tp = len(oracle_hit)
        fn = len(set(expected) - oracle_hit)
        fp = len(set(actual) - parser_hit)

        total_expected += len(set(expected))
        total_parser += len(set(actual))
        total_tp += tp
        total_fn += fn
        total_fp += fp

        rel_file = file_path.replace("/home/giles/bluice/", "")
        per_file[rel_file]["tp"] += tp
        per_file[rel_file]["fp"] += fp
        per_file[rel_file]["fn"] += fn
        missed = sorted(set(expected) - oracle_hit)
        spurious = sorted(set(actual) - parser_hit)
        if missed: per_file[rel_file]["missed"].extend(missed)
        if spurious: per_file[rel_file]["spurious"].extend(spurious)

        if missed or spurious:
            discrepancies.append({
                "file": rel_file,
                "qname": qname,
                "missed": missed,
                "spurious": spurious,
            })

    p = total_tp / (total_tp + total_fp) if (total_tp + total_fp) else 0
    r = total_tp / (total_tp + total_fn) if (total_tp + total_fn) else 0
    f1 = 2*p*r/(p+r) if (p+r) else 0

    print(f"\n=== OVERALL ===")
    print(f"  symbols compared:   {len(oracle) - not_found}  (not found in DB: {not_found})")
    print(f"  oracle callees:     {total_expected}")
    print(f"  parser callees:     {total_parser}")
    print(f"  true positives:     {total_tp}")
    print(f"  missed (oracle only):  {total_fn}")
    print(f"  spurious (parser only):{total_fp}")
    print(f"  PRECISION:          {100*p:.1f}%")
    print(f"  RECALL:             {100*r:.1f}%")
    print(f"  F1:                 {100*f1:.1f}%")

    print(f"\n=== TOP 20 DISCREPANCIES BY (missed+spurious) ===")
    discrepancies.sort(key=lambda d: -(len(d["missed"]) + len(d["spurious"])))
    for d in discrepancies[:20]:
        print(f"\n{d['file']}::{d['qname']}")
        if d["missed"]:
            print(f"  oracle had, parser missed: {d['missed']}")
        if d["spurious"]:
            print(f"  parser captured, not in oracle: {d['spurious']}")

    print(f"\n=== PER-FILE SUMMARY ===")
    print(f"{'file':<60} {'tp':>4} {'miss':>5} {'spur':>5} {'P%':>6} {'R%':>6}")
    for f, s in sorted(per_file.items()):
        tp = s["tp"]; fp = s["fp"]; fn = s["fn"]
        pp = 100*tp/(tp+fp) if (tp+fp) else 0
        rr = 100*tp/(tp+fn) if (tp+fn) else 0
        print(f"{f:<60} {tp:>4} {fn:>5} {fp:>5} {pp:>5.1f} {rr:>5.1f}")


if __name__ == "__main__":
    main()
