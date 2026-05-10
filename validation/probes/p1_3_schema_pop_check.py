#!/usr/bin/env python3
"""P1.3 Stream 1 Deliverable A.3 — Schema-pop SQL sanity check.

Verifies that jcm_tcl_extensions side-table is populated correctly across
the bluice corpus, by:
  1. Querying SQLite for parent_classes / package_requires populated counts.
  2. Cross-checking against grep counts on source.
  3. Surfacing any repo with suspiciously low SQL counts.

Usage:
  python3 validation/probes/p1_3_schema_pop_check.py
"""
from __future__ import annotations

import json
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

BASE = Path("/tmp/p1_3_corpus_indexes")
REPOS = [
    ("BluIceWidgets", "/home/giles/bluice/BluIceWidgets"),
    ("DcsWidgets", "/home/giles/bluice/DcsWidgets"),
    ("dcs-lib-tcl", "/home/giles/bluice/dcs-lib-tcl"),
    ("dhs-tcl", "/home/giles/bluice/dhs-tcl"),
    ("dcss", "/home/giles/bluice/dcss"),
]


def find_db(repo_dir: Path) -> Path | None:
    candidates = list(repo_dir.glob("*.db"))
    if not candidates:
        return None
    return candidates[0]


def grep_count(pattern: str, root: str, file_globs: list[str]) -> int:
    """Count files (or matches) matching `pattern` under root."""
    cmd = ["grep", "-rn", "--include=*.tcl", "--include=*.test", "-E", pattern, root]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return -1
    if r.returncode > 1:  # 0=match, 1=no match, >1 = error
        return -1
    out = r.stdout.decode("utf-8", errors="replace")
    return out.count("\n")


def main() -> int:
    rows = []
    issues = []
    for repo_name, source_root in REPOS:
        repo_dir = BASE / repo_name
        db = find_db(repo_dir)
        if db is None:
            issues.append(f"{repo_name}: NO DB FOUND under {repo_dir}")
            continue
        conn = sqlite3.connect(str(db))
        # Confirm side-table exists
        side = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='jcm_tcl_extensions'"
        ).fetchone()
        if not side:
            issues.append(f"{repo_name}: jcm_tcl_extensions side-table missing")
            conn.close()
            continue
        # Counts via SQL
        n_parent = conn.execute(
            "SELECT COUNT(*) FROM jcm_tcl_extensions WHERE parent_classes IS NOT NULL"
        ).fetchone()[0]
        n_pkg = conn.execute(
            "SELECT COUNT(*) FROM jcm_tcl_extensions WHERE package_requires IS NOT NULL"
        ).fetchone()[0]
        n_total_side = conn.execute(
            "SELECT COUNT(*) FROM jcm_tcl_extensions"
        ).fetchone()[0]
        n_tcl_syms = conn.execute(
            "SELECT COUNT(*) FROM symbols WHERE language='tcl'"
        ).fetchone()[0]
        n_classes = conn.execute(
            "SELECT COUNT(*) FROM symbols WHERE language='tcl' AND kind='class'"
        ).fetchone()[0]
        n_scripts = conn.execute(
            "SELECT COUNT(*) FROM symbols WHERE language='tcl' AND kind='script'"
        ).fetchone()[0]
        # Sample populated rows for inspection
        sample_parent = conn.execute(
            """SELECT s.qualified_name, x.parent_classes
               FROM jcm_tcl_extensions x JOIN symbols s ON x.symbol_id = s.id
               WHERE x.parent_classes IS NOT NULL LIMIT 3"""
        ).fetchall()
        sample_pkg = conn.execute(
            """SELECT s.qualified_name, x.package_requires
               FROM jcm_tcl_extensions x JOIN symbols s ON x.symbol_id = s.id
               WHERE x.package_requires IS NOT NULL LIMIT 3"""
        ).fetchall()
        conn.close()

        # Grep cross-checks
        # parent_classes: matches on `inherit ` (iTcl/iTk) and `superclass ` (TclOO)
        n_inherit = grep_count(r"^\s*(inherit|superclass)\s+\S", source_root, [])
        # package_requires: matches `package require X`
        n_require = grep_count(r"^\s*package\s+require\s+\S", source_root, [])

        # Plausibility
        # parent_classes side-rows should be roughly comparable to inherit/superclass count;
        # but multiple parents in one symbol → 1 row, multiple files declaring same class merge.
        # Just sanity: SQL count should be > 0 if grep > 5 (or note as anomaly).
        plausible_parent = "yes"
        if n_inherit > 5 and n_parent == 0:
            plausible_parent = "NO (zero side-rows but grep found inherit/superclass)"
            issues.append(f"{repo_name}: parent_classes anomaly {n_parent}/{n_inherit}")
        elif n_inherit > 20 and n_parent < n_inherit / 10:
            plausible_parent = f"low ({n_parent} side-rows vs ~{n_inherit} grep matches)"

        plausible_pkg = "yes"
        if n_require > 5 and n_pkg == 0:
            plausible_pkg = "NO (zero side-rows but grep found package require)"
            issues.append(f"{repo_name}: package_requires anomaly {n_pkg}/{n_require}")

        rows.append({
            "repo": repo_name,
            "db": str(db),
            "tcl_symbols": n_tcl_syms,
            "tcl_classes": n_classes,
            "tcl_scripts": n_scripts,
            "side_table_rows_total": n_total_side,
            "parent_classes_sql": n_parent,
            "parent_classes_grep": n_inherit,
            "parent_plausible": plausible_parent,
            "package_requires_sql": n_pkg,
            "package_requires_grep": n_require,
            "package_plausible": plausible_pkg,
            "sample_parent": [(q, json.loads(p) if p else None) for q, p in sample_parent],
            "sample_pkg": [(q, json.loads(p) if p else None) for q, p in sample_pkg],
        })

    print("=" * 80)
    print("P1.3 schema-pop sanity check")
    print("=" * 80)
    print(f"{'Repo':<14} {'tcl_syms':>9} {'tcl_cls':>8} {'parent SQL/grep':>17} {'pkg SQL/grep':>14}")
    for r in rows:
        print(f"{r['repo']:<14} {r['tcl_symbols']:>9} {r['tcl_classes']:>8}  "
              f"{r['parent_classes_sql']:>5}/{r['parent_classes_grep']:<10}  "
              f"{r['package_requires_sql']:>5}/{r['package_requires_grep']:<7}")

    print()
    print("Sample populated rows:")
    for r in rows:
        print(f"  {r['repo']}:")
        for q, p in r["sample_parent"]:
            print(f"    parent_classes  {q!r:<60} -> {p}")
        for q, p in r["sample_pkg"]:
            print(f"    package_requires {q!r:<60} -> {p}")
    print()
    if issues:
        print("ISSUES SURFACED:")
        for i in issues:
            print(f"  - {i}")
    else:
        print("No anomalies — all repos plausible.")
    out_json = Path("/tmp/p1_3_corpus_indexes/schema_pop_check.json")
    out_json.write_text(json.dumps(rows, indent=2))
    print(f"\nRaw data: {out_json}")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
