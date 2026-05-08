r"""Grep/awk-based ground truth counters for TCL repos.

Counts structural constructs across a repo via raw text matching — approximate
but parser-independent. Used to compute recall metrics for jcodemunch
(which may have its own parser bugs).

Counted constructs:
    procs           ^\s*proc <name>
    classes_raw     ^\s*class <Name> {    (iTk-style)
    classes_itcl    ^\s*(::)?itcl::class
    methods         ^\s*(public|private|protected) method
    itcl_body       ^\s*(::)?itcl::body
    constructors    ^\s*constructor\b
    destructors     ^\s*destructor\b
    namespace_eval  ^\s*namespace eval
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BLUICE = Path("/home/giles/bluice")

TCL_REPOS = ["BluIceWidgets", "DcsWidgets", "dcss", "dhs-tcl", "dcs-lib-tcl"]

PATTERNS = {
    "procs":          re.compile(rb"^\s*proc\s+[A-Za-z_][A-Za-z0-9_:]*", re.M),
    "classes_raw":    re.compile(rb"^\s*class\s+[A-Za-z_][A-Za-z0-9_:]*\s*\{?", re.M),
    "classes_itcl":   re.compile(rb"^\s*(?:::)?itcl::class\s+[A-Za-z_]", re.M),
    "methods":        re.compile(rb"^\s*(?:public|private|protected)\s+method\s+[A-Za-z_]", re.M),
    "itcl_body":      re.compile(rb"^\s*(?:::)?itcl::body\s+", re.M),
    "constructors":   re.compile(rb"^\s*constructor\b", re.M),
    "destructors":    re.compile(rb"^\s*destructor\b", re.M),
    "namespace_eval": re.compile(rb"^\s*namespace\s+eval\s+", re.M),
}


def count_repo(repo: str) -> dict:
    root = BLUICE / repo
    if not root.exists():
        return {"error": f"missing: {root}"}
    counts = {k: 0 for k in PATTERNS}
    file_count = 0
    byte_total = 0
    per_file = {}
    for f in root.rglob("*.tcl"):
        try:
            data = f.read_bytes()
        except Exception:
            continue
        file_count += 1
        byte_total += len(data)
        file_rel = str(f.relative_to(root))
        # Normalize CR / CRLF line endings to LF so the `^` anchor fires on
        # every physical line. Some legacy DHS TCL files (e.g. SimPilatus.tcl)
        # use classic-Mac CR-only endings — without this, the whole file is
        # treated as one giant line and every pattern misses.
        norm = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        pf = {}
        for k, pat in PATTERNS.items():
            n = len(pat.findall(norm))
            counts[k] += n
            pf[k] = n
        per_file[file_rel] = pf
    # Combined class count (raw + itcl forms)
    counts["classes_total"] = counts["classes_raw"] + counts["classes_itcl"]
    # Method-ish total: count each DISTINCT method once. A pure-decl
    # `public method foo` + later `itcl::body Class::foo` is ONE method,
    # not two. We use max(decls, itcl_body) because either form by itself
    # represents the method's existence; if both are present they pair up.
    # ctor/dtor are separate constructs counted independently.
    counts["method_like_total"] = (
        max(counts["methods"], counts["itcl_body"])
        + counts["constructors"] + counts["destructors"]
    )
    return {
        "repo": repo,
        "tcl_file_count": file_count,
        "tcl_byte_total": byte_total,
        "counts": counts,
        "per_file": per_file,
    }


def all_repos() -> dict:
    return {r: count_repo(r) for r in TCL_REPOS}


if __name__ == "__main__":
    if len(sys.argv) > 1:
        # Single repo mode for quick inspection
        print(json.dumps(count_repo(sys.argv[1]), indent=2))
    else:
        data = all_repos()
        # Summary only (not per-file)
        summary = {r: {
            "tcl_file_count": v["tcl_file_count"],
            "counts": v["counts"],
        } for r, v in data.items()}
        print(json.dumps(summary, indent=2))
