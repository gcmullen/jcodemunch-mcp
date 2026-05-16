#!/usr/bin/env python3
"""Build per-file gold artifacts from two annotator outputs.

Per §8.4 of GOLD_EXPERIMENT_v1.md:
- Computes (qualified_name, kind) symbol-set agreement.
- For each symbol present in both, computes Jaccard on (name, kind) callee sets.
- Classifies entries as CONSENSUS or DISCREPANCY.
- Writes <file>.gold.json (two-tier), <file>.audit.json (audit results),
  and <file>.discrepancies.json.

Usage:
  build_gold.py \
    --a-raw <path>.A.opus.raw.json \
    --b-raw <path>.B.sonnet.raw.json \
    --source-path <full source path> \
    --corpus <corpus name> \
    --out-dir <output dir> \
    --basename <file basename> \
    --convention-version v1.0 \
    --convention-commit a2747c3 \
    --head-sha <jcodemunch HEAD sha> \
    --branch <jcodemunch branch> \
    --started <iso8601> \
    --finished <iso8601> \
    --prompt-hash-a <sha256> \
    --prompt-hash-b <sha256>
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from audit_check import check as audit_check  # type: ignore


def jaccard(a: set, b: set) -> float:
    u = a | b
    if not u:
        return 1.0
    return len(a & b) / len(u)


def build_callee_key(c: dict) -> tuple:
    return (c.get("name"), c.get("kind"))


def build_gold(a: dict, b: dict) -> tuple[dict, dict]:
    """Return (gold_symbols_list, discrepancies_dict)."""
    a_syms = {(s["qualified_name"], s["kind"]): s for s in a["symbols"]}
    b_syms = {(s["qualified_name"], s["kind"]): s for s in b["symbols"]}

    a_only_keys = set(a_syms.keys()) - set(b_syms.keys())
    b_only_keys = set(b_syms.keys()) - set(a_syms.keys())
    shared_keys = set(a_syms.keys()) & set(b_syms.keys())

    discrepancies: dict = {
        "symbol_set": {
            "a_only": [
                {"qualified_name": q, "kind": k, "source": "A_only",
                 "a_entry": a_syms[(q, k)]}
                for (q, k) in sorted(a_only_keys)
            ],
            "b_only": [
                {"qualified_name": q, "kind": k, "source": "B_only",
                 "b_entry": b_syms[(q, k)]}
                for (q, k) in sorted(b_only_keys)
            ],
            "summary": {
                "a_total": len(a_syms),
                "b_total": len(b_syms),
                "shared": len(shared_keys),
                "agreement_pct": round(
                    100.0 * len(shared_keys) / max(1, len(a_syms | b_syms.keys())), 2
                ),
            },
        },
        "per_symbol_callees": [],
        "line_drifts": [],
    }

    gold_symbols: list = []
    callee_jaccards: list[float] = []

    # Add A-only and B-only symbols as discrepancy entries in gold
    for q, k in sorted(a_only_keys):
        sym = dict(a_syms[(q, k)])
        sym["discrepancy"] = True
        sym["discrepancy_source"] = "A_only"
        gold_symbols.append(sym)
    for q, k in sorted(b_only_keys):
        sym = dict(b_syms[(q, k)])
        sym["discrepancy"] = True
        sym["discrepancy_source"] = "B_only"
        gold_symbols.append(sym)

    # Shared symbols: compute callee consensus
    for key in sorted(shared_keys):
        a_sym = a_syms[key]
        b_sym = b_syms[key]

        # Line drift check (±2 acceptable)
        a_line = a_sym.get("line")
        b_line = b_sym.get("line")
        if isinstance(a_line, int) and isinstance(b_line, int):
            drift = abs(a_line - b_line)
            if drift > 2:
                discrepancies["line_drifts"].append({
                    "qualified_name": key[0], "kind": key[1],
                    "a_line": a_line, "b_line": b_line, "drift": drift,
                })

        # Callee comparison on (name, kind)
        a_callees = a_sym.get("callees", [])
        b_callees = b_sym.get("callees", [])
        a_set = {build_callee_key(c) for c in a_callees}
        b_set = {build_callee_key(c) for c in b_callees}
        jac = jaccard(a_set, b_set)
        callee_jaccards.append(jac)

        consensus = a_set & b_set
        a_only_cl = a_set - b_set
        b_only_cl = b_set - a_set

        # Build merged callees list: consensus first (A's version), then A-only, then B-only
        merged_callees: list = []
        a_by_key: dict = {}
        b_by_key: dict = {}
        for c in a_callees:
            a_by_key.setdefault(build_callee_key(c), []).append(c)
        for c in b_callees:
            b_by_key.setdefault(build_callee_key(c), []).append(c)

        for ck in consensus:
            # consensus pair
            a_versions = a_by_key.get(ck, [])
            b_versions = b_by_key.get(ck, [])
            # Pair them up by line proximity
            paired = []
            used_b = set()
            for ai, av in enumerate(a_versions):
                best_b = None
                best_idx = None
                best_drift = 9999
                for bi, bv in enumerate(b_versions):
                    if bi in used_b:
                        continue
                    a_l = av.get("line")
                    b_l = bv.get("line")
                    if isinstance(a_l, int) and isinstance(b_l, int):
                        drift = abs(a_l - b_l)
                    else:
                        # Missing/null line on either side — pair only as last resort.
                        # Sentinel keeps the matchmaker monotone with real-drift candidates.
                        drift = 9998
                    if drift < best_drift:
                        best_drift = drift
                        best_b = bv
                        best_idx = bi
                if best_b is not None:
                    used_b.add(best_idx)
                    paired.append((av, best_b, best_drift))
                else:
                    paired.append((av, None, None))
            # Any remaining b-only-versions
            for bi, bv in enumerate(b_versions):
                if bi not in used_b:
                    paired.append((None, bv, None))

            for av, bv, dr in paired:
                if av is not None and bv is not None:
                    a_line_val = av.get("line")
                    b_line_val = bv.get("line")
                    a_has_line = isinstance(a_line_val, int)
                    b_has_line = isinstance(b_line_val, int)
                    if a_has_line and b_has_line and (dr is None or dr <= 2):
                        # consensus
                        entry = dict(av)  # keep A's line
                        if dr is not None and dr > 0:
                            entry["b_line"] = b_line_val
                        merged_callees.append(entry)
                    else:
                        # Dispute: either real drift > 2, or missing line on one/both sides.
                        # T8 distinguishes these so missing-line bugs don't masquerade as drift.
                        if not a_has_line and not b_has_line:
                            issue = "both_missing_line"
                        elif not a_has_line:
                            issue = "a_missing_line"
                        elif not b_has_line:
                            issue = "b_missing_line"
                        else:
                            issue = "line_drift_>2"
                        entry_a = dict(av); entry_a["discrepancy"] = True; entry_a["discrepancy_source"] = "A_line"; entry_a["paired_b_line"] = b_line_val
                        entry_b = dict(bv); entry_b["discrepancy"] = True; entry_b["discrepancy_source"] = "B_line"; entry_b["paired_a_line"] = a_line_val
                        merged_callees.append(entry_a)
                        merged_callees.append(entry_b)
                        discrepancies["per_symbol_callees"].append({
                            "qualified_name": key[0], "kind": key[1],
                            "name": av.get("name"), "callee_kind": av.get("kind"),
                            "issue": issue,
                            "a_line": a_line_val, "b_line": b_line_val,
                        })
                elif av is not None:
                    entry = dict(av); entry["discrepancy"] = True; entry["discrepancy_source"] = "A_only"
                    merged_callees.append(entry)
                else:
                    entry = dict(bv); entry["discrepancy"] = True; entry["discrepancy_source"] = "B_only"
                    merged_callees.append(entry)

        for ck in a_only_cl:
            for v in a_by_key.get(ck, []):
                entry = dict(v); entry["discrepancy"] = True; entry["discrepancy_source"] = "A_only"
                merged_callees.append(entry)
                discrepancies["per_symbol_callees"].append({
                    "qualified_name": key[0], "kind": key[1],
                    "name": v.get("name"), "callee_kind": v.get("kind"),
                    "line": v.get("line"), "source": "A_only",
                })
        for ck in b_only_cl:
            for v in b_by_key.get(ck, []):
                entry = dict(v); entry["discrepancy"] = True; entry["discrepancy_source"] = "B_only"
                merged_callees.append(entry)
                discrepancies["per_symbol_callees"].append({
                    "qualified_name": key[0], "kind": key[1],
                    "name": v.get("name"), "callee_kind": v.get("kind"),
                    "line": v.get("line"), "source": "B_only",
                })

        # Use A's symbol as the base, replace callees with merged
        merged_sym = dict(a_sym)
        merged_sym["callees"] = merged_callees
        # Mark visibility/end_line discrepancies if any
        for field in ("visibility", "end_line"):
            if a_sym.get(field) != b_sym.get(field):
                merged_sym.setdefault("field_discrepancies", []).append({
                    "field": field, "a": a_sym.get(field), "b": b_sym.get(field),
                })
        gold_symbols.append(merged_sym)

    avg_jaccard = (
        sum(callee_jaccards) / len(callee_jaccards) if callee_jaccards else 1.0
    )
    discrepancies["metrics"] = {
        "symbol_set_agreement_pct": discrepancies["symbol_set"]["summary"]["agreement_pct"],
        "avg_callee_jaccard": round(avg_jaccard, 4),
        "n_shared_symbols": len(shared_keys),
    }

    return gold_symbols, discrepancies


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a-raw", required=True)
    ap.add_argument("--b-raw", required=True)
    ap.add_argument("--source-path", required=True)
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--basename", required=True)
    ap.add_argument("--convention-version", default="v1.0")
    ap.add_argument("--convention-commit", default="a2747c3")
    ap.add_argument("--tcl-version", default="8.6",
                    help="Tcl interpreter version the convention pins to (§1 of convention).")
    ap.add_argument("--tcl-version-source", default="convention_pin",
                    choices=("convention_pin", "runtime_detected"))
    ap.add_argument("--source-corpus-commit", default=None,
                    help="Full HEAD SHA of the source corpus repo at annotation time.")
    ap.add_argument("--dispatch-mode", default="anon_read_batched",
                    choices=("anon_read_batched", "inline_single_shot"))
    ap.add_argument("--head-sha", required=True)
    ap.add_argument("--branch", default="tcl-disasm-bridge")
    ap.add_argument("--started", required=True)
    ap.add_argument("--finished", required=True)
    ap.add_argument("--prompt-hash-a", default=None)
    ap.add_argument("--prompt-hash-b", default=None)
    ap.add_argument("--run-id", default=None,
                    help="Per-run identifier (e.g. YYYYMMDD_HHMMSS_<rand>) recorded in provenance.")
    ap.add_argument("--meta-prompt-hash-a", default=None,
                    help="sha256 of the filled annotator meta-prompt sent to model A.")
    ap.add_argument("--meta-prompt-hash-b", default=None,
                    help="sha256 of the filled annotator meta-prompt sent to model B.")
    ap.add_argument("--meta-prompt-template-version", default=None,
                    help="Version tag of the meta-prompt template (e.g. v1.0).")
    args = ap.parse_args()

    with open(args.a_raw) as fh:
        a = json.load(fh)
    with open(args.b_raw) as fh:
        b = json.load(fh)

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Audit both
    a_violations = audit_check(a)
    b_violations = audit_check(b)
    audit = {
        "A_opus": {"clean": not a_violations, "violations": a_violations},
        "B_sonnet": {"clean": not b_violations, "violations": b_violations},
    }
    (out / f"{args.basename}.audit.json").write_text(
        json.dumps(audit, indent=2) + "\n"
    )

    # Build gold + discrepancies
    gold_symbols, discrepancies = build_gold(a, b)

    # Merge file_level: prefer A; record disagreements as discrepancies
    file_level = dict(a.get("file_level", {}))
    fl_disc: list = []
    for fld in ("package_requires", "package_provides", "imports", "callees"):
        if a.get("file_level", {}).get(fld) != b.get("file_level", {}).get(fld):
            fl_disc.append({
                "field": fld,
                "a": a.get("file_level", {}).get(fld),
                "b": b.get("file_level", {}).get(fld),
            })
    if fl_disc:
        discrepancies["file_level"] = fl_disc

    gold = {
        "schema_version": args.convention_version.lstrip("v") if args.convention_version else "1.2",
        "file": a.get("file") or args.basename,
        "language": a.get("language"),
        "language_B": b.get("language") if b.get("language") != a.get("language") else None,
        "symbols": gold_symbols,
        "file_level": file_level,
        "provenance": {
            "convention_version": args.convention_version,
            "convention_commit": args.convention_commit,
            "tcl_version": args.tcl_version,
            "tcl_version_source": args.tcl_version_source,
            "jcodemunch_repo": "jcodemunch-mcp-fork",
            "jcodemunch_branch": args.branch,
            "jcodemunch_head": args.head_sha,
            "source_corpus": args.corpus,
            "source_corpus_commit": args.source_corpus_commit,
            "source_path": args.source_path,
            "model_A_alias": "opus",
            "model_A_resolved": None,
            "model_B_alias": "sonnet",
            "model_B_resolved": None,
            "prompt_hash_A": args.prompt_hash_a,
            "prompt_hash_B": args.prompt_hash_b,
            "meta_prompt_hash_A": args.meta_prompt_hash_a,
            "meta_prompt_hash_B": args.meta_prompt_hash_b,
            "meta_prompt_template_version": args.meta_prompt_template_version,
            "run_id": args.run_id,
            "dispatch_mode": args.dispatch_mode,
            "experiment_started_at": args.started,
            "experiment_finished_at": args.finished,
        },
        "metrics": discrepancies["metrics"],
    }
    (out / f"{args.basename}.gold.json").write_text(
        json.dumps(gold, indent=2) + "\n"
    )
    (out / f"{args.basename}.discrepancies.json").write_text(
        json.dumps(discrepancies, indent=2) + "\n"
    )

    print(json.dumps({
        "file": args.basename,
        "a_clean": not a_violations,
        "b_clean": not b_violations,
        "symbol_agreement_pct": discrepancies["symbol_set"]["summary"]["agreement_pct"],
        "avg_callee_jaccard": discrepancies["metrics"]["avg_callee_jaccard"],
        "n_a_only_sym": len(discrepancies["symbol_set"]["a_only"]),
        "n_b_only_sym": len(discrepancies["symbol_set"]["b_only"]),
        "n_callee_disc": len(discrepancies["per_symbol_callees"]),
        "n_line_drift": len(discrepancies["line_drifts"]),
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
