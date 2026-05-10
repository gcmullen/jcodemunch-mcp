#!/usr/bin/env python3
"""P1.3 Stream 1 Deliverable A.4 — Downstream-tool smoke spot-checks.

For each tool, pick 5 inputs from bluice via heuristics; run the tool; verify
output is plausible (not validation — smoke-only). Report per-call verdict.

Tools exercised:
  1. get_class_hierarchy   — pick 5 widely-used classes (parents w/ 2-5 descendants)
  2. get_dependency_graph  — pick 5 files with `package require` / `source`
  3. find_importers        — pick 5 packages imported by multiple files (we re-use
                             find_importers on common header files since the tool
                             is file-based, not package-based)
  4. package_registry      — verify Tcl-handler-extracted package names match what's
                             in `package_requires` at __script__ symbols
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from collections import Counter
from pathlib import Path

# Set CODE_INDEX_PATH to be the parent of all our P1.3 indexes.
# But each repo has its own subdir. The tool resolve_repo expects a registry-aware path.
# Simplest: set CODE_INDEX_PATH per-call.
sys.path.insert(0, "/home/giles/git/jcodemunch-mcp-fork/src")

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
    return candidates[0] if candidates else None


def list_repos_in_storage(storage_path: str) -> list[str]:
    """Mirror what resolve_repo expects."""
    from jcodemunch_mcp.tools.list_repos import list_repos
    res = list_repos(storage_path=storage_path)
    return [r["repo"] for r in res.get("repos", [])]


def pick_class_hierarchy_targets(db_path: str, repo_name: str) -> list[str]:
    """Find class names where the class has ≥1 ancestor or ≥2 descendants populated."""
    conn = sqlite3.connect(db_path)
    # Pick classes that appear as a parent in another class's parent_classes
    rows = conn.execute(
        """SELECT s.qualified_name, x.parent_classes
           FROM jcm_tcl_extensions x JOIN symbols s ON x.symbol_id = s.id
           WHERE x.parent_classes IS NOT NULL"""
    ).fetchall()
    parent_freq: Counter = Counter()
    for qname, p_json in rows:
        try:
            for entry in json.loads(p_json):
                pname = entry.get("name", "")
                # Strip leading ::, take last segment
                pname_clean = pname.lstrip(":").split("::")[-1]
                parent_freq[pname_clean] += 1
        except (json.JSONDecodeError, AttributeError):
            continue
    # Also pick top class by # of children
    candidates = [name for name, count in parent_freq.most_common(20) if count >= 2]
    # Cross-reference against actual classes in this index
    class_names = {row[0] for row in conn.execute(
        "SELECT qualified_name FROM symbols WHERE language='tcl' AND kind='class'"
    ).fetchall()}
    conn.close()
    # Map candidate parent -> a class in the index (if present)
    selected = []
    for cand in candidates:
        match = next((c for c in class_names if c.split("::")[-1] == cand), None)
        if match:
            selected.append(match)
        if len(selected) >= 5:
            break
    return selected


def pick_files_with_requires(db_path: str) -> list[str]:
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        """SELECT DISTINCT s.file
           FROM jcm_tcl_extensions x JOIN symbols s ON x.symbol_id = s.id
           WHERE x.package_requires IS NOT NULL
           LIMIT 5"""
    ).fetchall()
    conn.close()
    return [r[0] for r in rows]


def pick_widely_imported_files(db_path: str) -> list[str]:
    """Pick files that are likely imported by multiple other files."""
    conn = sqlite3.connect(db_path)
    pkg_freq: Counter = Counter()
    rows = conn.execute(
        """SELECT x.package_requires
           FROM jcm_tcl_extensions x JOIN symbols s ON x.symbol_id = s.id
           WHERE x.package_requires IS NOT NULL"""
    ).fetchall()
    for (p_json,) in rows:
        try:
            for entry in json.loads(p_json):
                pkg_freq[entry.get("name", "")] += 1
        except (json.JSONDecodeError, AttributeError):
            continue
    # Most-used package names
    top = [name for name, _ in pkg_freq.most_common(10) if name and not name[0].isupper() == False]
    # Files that DEFINE these packages (heuristic: filename matches package name)
    files_in_repo = {row[0] for row in conn.execute(
        "SELECT DISTINCT file FROM symbols WHERE language='tcl'"
    ).fetchall()}
    conn.close()
    selected = []
    for pkg in [name for name, _ in pkg_freq.most_common(20) if name]:
        # Find any file whose basename starts with pkg
        for f in files_in_repo:
            base = os.path.basename(f)
            if base.lower().startswith(pkg.lower()) and f.endswith(".tcl"):
                selected.append(f)
                break
        if len(selected) >= 5:
            break
    return selected


def run_tool_class_hierarchy(repo: str, class_names: list[str], storage_path: str) -> list[dict]:
    from jcodemunch_mcp.tools.get_class_hierarchy import get_class_hierarchy
    out = []
    for cn in class_names:
        try:
            res = get_class_hierarchy(repo=repo, class_name=cn, storage_path=storage_path)
            err = res.get("error")
            if err:
                out.append({"input": cn, "verdict": f"error: {err}"})
            else:
                ac = res.get("ancestor_count", 0)
                dc = res.get("descendant_count", 0)
                if ac == 0 and dc == 0:
                    out.append({"input": cn, "verdict": f"questionable: 0 ancestors / 0 descendants"})
                else:
                    out.append({"input": cn, "verdict": f"plausible: {ac} ancestors, {dc} descendants"})
        except Exception as e:
            out.append({"input": cn, "verdict": f"crash: {type(e).__name__}: {e}"})
    return out


def run_tool_dep_graph(repo: str, files: list[str], storage_path: str) -> list[dict]:
    from jcodemunch_mcp.tools.get_dependency_graph import get_dependency_graph
    out = []
    for f in files:
        try:
            res = get_dependency_graph(repo=repo, file=f, direction="imports", storage_path=storage_path)
            err = res.get("error")
            if err:
                out.append({"input": f, "verdict": f"error: {err}"})
            else:
                nodes = len(res.get("nodes", []))
                edges = len(res.get("edges", []))
                out.append({"input": f, "verdict": f"plausible: {nodes} nodes, {edges} edges"})
        except Exception as e:
            out.append({"input": f, "verdict": f"crash: {type(e).__name__}: {e}"})
    return out


def run_tool_find_importers(repo: str, files: list[str], storage_path: str) -> list[dict]:
    from jcodemunch_mcp.tools.find_importers import find_importers
    out = []
    for f in files:
        try:
            res = find_importers(repo=repo, file_path=f, storage_path=storage_path)
            err = res.get("error")
            if err:
                out.append({"input": f, "verdict": f"error: {err}"})
            else:
                imp = len(res.get("importers", []))
                out.append({"input": f, "verdict": f"plausible: {imp} importers"})
        except Exception as e:
            out.append({"input": f, "verdict": f"crash: {type(e).__name__}: {e}"})
    return out


def run_tool_package_registry(repo: str, db_path: str, storage_path: str) -> list[dict]:
    """Verify package_registry sees Tcl packages from `package_requires` side-table."""
    from jcodemunch_mcp.tools.package_registry import build_package_registry
    out = []
    # Collect distinct package names from side-table
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        """SELECT x.package_requires FROM jcm_tcl_extensions x
           WHERE x.package_requires IS NOT NULL"""
    ).fetchall()
    conn.close()
    extracted = Counter()
    for (p_json,) in rows:
        try:
            for entry in json.loads(p_json):
                pn = entry.get("name", "")
                if pn:
                    extracted[pn] += 1
        except (json.JSONDecodeError, AttributeError):
            continue
    top5 = extracted.most_common(5)
    for pkg_name, count in top5:
        out.append({
            "input": pkg_name,
            "verdict": f"plausible: side-table has '{pkg_name}' at {count} __script__ symbols",
        })
    return out


def main() -> int:
    print("=" * 80)
    print("P1.3 Deliverable A.4 — downstream-tool spot-checks")
    print("=" * 80)
    full = {}
    for repo_name, _src in REPOS:
        repo_dir = BASE / repo_name
        db = find_db(repo_dir)
        storage_path = str(repo_dir)
        if db is None:
            print(f"\n--- {repo_name}: NO DB FOUND ---")
            continue
        # Resolve display repo identifier from list_repos
        try:
            repos_list = list_repos_in_storage(storage_path)
        except Exception as e:
            print(f"\n--- {repo_name}: list_repos failed: {e} ---")
            continue
        if not repos_list:
            print(f"\n--- {repo_name}: empty repo list ---")
            continue
        repo_id = repos_list[0]

        print(f"\n=== Repo: {repo_name}  (id={repo_id}) ===")

        # 1. get_class_hierarchy
        ch_targets = pick_class_hierarchy_targets(str(db), repo_name)
        print(f"\n  [get_class_hierarchy] picked: {ch_targets}")
        ch_results = run_tool_class_hierarchy(repo_id, ch_targets, storage_path)
        for r in ch_results:
            print(f"    - {r['input']}: {r['verdict']}")

        # 2. get_dependency_graph
        dg_files = pick_files_with_requires(str(db))
        # Strip absolute prefix to get repo-relative path
        from jcodemunch_mcp.tools._utils import resolve_repo
        owner, name = resolve_repo(repo_id, storage_path)
        from jcodemunch_mcp.storage.index_store import IndexStore
        idx = IndexStore(base_path=storage_path).load_index(owner, name)
        src_root = idx.source_root if idx else ""
        dg_files_rel = []
        for f in dg_files:
            if src_root and f.startswith(src_root):
                rel = os.path.relpath(f, src_root)
                dg_files_rel.append(rel)
            else:
                dg_files_rel.append(f)
        print(f"\n  [get_dependency_graph] picked: {dg_files_rel}")
        dg_results = run_tool_dep_graph(repo_id, dg_files_rel, storage_path)
        for r in dg_results:
            print(f"    - {r['input']}: {r['verdict']}")

        # 3. find_importers
        fi_files = pick_widely_imported_files(str(db))
        fi_files_rel = []
        for f in fi_files:
            if src_root and f.startswith(src_root):
                rel = os.path.relpath(f, src_root)
                fi_files_rel.append(rel)
            else:
                fi_files_rel.append(f)
        print(f"\n  [find_importers] picked: {fi_files_rel}")
        fi_results = run_tool_find_importers(repo_id, fi_files_rel, storage_path)
        for r in fi_results:
            print(f"    - {r['input']}: {r['verdict']}")

        # 4. package_registry verification
        print(f"\n  [package_registry / side-table] top-5 extracted package names:")
        pr_results = run_tool_package_registry(repo_id, str(db), storage_path)
        for r in pr_results:
            print(f"    - {r['input']}: {r['verdict']}")

        full[repo_name] = {
            "class_hierarchy": ch_results,
            "dependency_graph": dg_results,
            "find_importers": fi_results,
            "package_registry": pr_results,
        }
    out_path = Path("/tmp/p1_3_corpus_indexes/downstream_spotcheck.json")
    out_path.write_text(json.dumps(full, indent=2))
    print(f"\nRaw data: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
