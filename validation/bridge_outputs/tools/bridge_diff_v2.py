#!/usr/bin/env python3
"""Strict (name, kind, line ±2) Jaccard diff — Phase 5.2.8 staged-gate measurement.

Supersedes the relaxed name-only multiset diff in bridge_diff.py for the
Phase 5 strict-diff verdict.  Operates on the per-call-site `callees` list
populated by the bridge in P5.2.0+ (method_dispatch in P5.2.6, callback in
P5.2.7).

Algorithm: greedy match per shared symbol.
  For each gold callee tuple (name, kind, line_g), find a bridge callee
  with the same (name, kind) and |line_b - line_g| <= 2 that hasn't been
  matched yet.  Mark both matched.  Unmatched gold = strict_miss.
  Unmatched bridge = strict_extra.

Also reports a kind_mismatch sidecar: gold and bridge agree on (name,
line ±2) but disagree on kind — diagnostic for where convention §6.12
callback vs §5.3 method_dispatch interpretation diverges.

Usage:
  .venv/bin/python3 validation/bridge_outputs/tools/bridge_diff_v2.py
"""
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
GOLD_BASE = REPO_ROOT / "validation" / "gold_annotations" / "conv-v1.3" / "tcl-8.6"
BRIDGE_BASE = REPO_ROOT / "validation" / "bridge_outputs" / "conv-v1.3" / "tcl-8.6"
LINE_TOLERANCE = 2  # per apply_arbiter.py T2 setting / spike §7.6 R3


# ---------------------------------------------------------------------------
# Reuse the kind-mapping + symbol-set logic from bridge_diff.py
# ---------------------------------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bridge_diff import (  # noqa: E402
    gold_kind_to_jcm,
    load_gold,
    load_bridge,
    symbol_set_diff,
    _tier_of,
)


# ---------------------------------------------------------------------------
# Strict per-symbol callee diff
# ---------------------------------------------------------------------------
def _normalize_kind(kind: str) -> str:
    """Normalize convention §4.2 kind names — keep as-is.

    Convention kinds: static | qualified | ensemble | method_dispatch
                     | callback | lambda | unresolved
    The bridge emits these verbatim per P5.2.0+ plumbing.
    """
    return kind or "static"


def _line_match(line_a: int, line_b: int) -> bool:
    """True when |line_a - line_b| <= LINE_TOLERANCE."""
    try:
        return abs(int(line_a) - int(line_b)) <= LINE_TOLERANCE
    except (TypeError, ValueError):
        return False


def strict_callee_diff(gold_callees: list[dict], bridge_callees: list[dict]) -> dict:
    """Greedy match gold vs bridge callees under (name, kind, line ±2) semantics.

    Also reports kind_mismatch as a sidecar diagnostic — same (name, line ±2)
    but different kind.  These are NOT counted as strict matches; they remain
    in strict_miss + strict_extra, but the sidecar lets us see the kind
    drift separately for the convention §5.3 vs §6.12 disambiguation.
    """
    # Index gold callees by (name, kind) for fast lookup.
    gold_by_nk: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for c in gold_callees:
        nk = (c.get("name", ""), _normalize_kind(c.get("kind", "static")))
        gold_by_nk[nk].append(dict(c, _matched=False))

    bridge_by_nk: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for c in bridge_callees:
        nk = (c.get("name", ""), _normalize_kind(c.get("kind", "static")))
        bridge_by_nk[nk].append(dict(c, _matched=False))

    matches = 0
    kind_mismatches: list[dict] = []

    # Pass 1: strict (name, kind, line ±2) match.
    for nk, golds in gold_by_nk.items():
        bridges = bridge_by_nk.get(nk, [])
        if not bridges:
            continue
        for g in golds:
            if g["_matched"]:
                continue
            for b in bridges:
                if b["_matched"]:
                    continue
                if _line_match(g.get("line", 0), b.get("line", 0)):
                    g["_matched"] = True
                    b["_matched"] = True
                    matches += 1
                    break

    # Pass 2: name-only same-line — kind mismatch diagnostic.
    # Only count if BOTH sides still have unmatched entries at that line.
    gold_by_name: dict[str, list[dict]] = defaultdict(list)
    for nk, lst in gold_by_nk.items():
        for c in lst:
            if not c["_matched"]:
                gold_by_name[nk[0]].append(c)
    bridge_by_name: dict[str, list[dict]] = defaultdict(list)
    for nk, lst in bridge_by_nk.items():
        for c in lst:
            if not c["_matched"]:
                bridge_by_name[nk[0]].append(c)

    for name, golds in gold_by_name.items():
        bridges = bridge_by_name.get(name, [])
        for g in golds:
            for b in bridges:
                if g.get("_km") or b.get("_km"):
                    continue
                if _line_match(g.get("line", 0), b.get("line", 0)):
                    if _normalize_kind(g.get("kind", "")) != _normalize_kind(b.get("kind", "")):
                        kind_mismatches.append({
                            "name": name,
                            "line_gold": g.get("line"),
                            "line_bridge": b.get("line"),
                            "kind_gold": _normalize_kind(g.get("kind", "")),
                            "kind_bridge": _normalize_kind(b.get("kind", "")),
                        })
                        g["_km"] = True
                        b["_km"] = True
                        break

    # Collect unmatched as miss / extra.
    strict_miss: list[dict] = []
    for nk, lst in gold_by_nk.items():
        for c in lst:
            if c["_matched"]:
                continue
            strict_miss.append({
                "name": nk[0],
                "kind": nk[1],
                "line": c.get("line"),
            })
    strict_extra: list[dict] = []
    for nk, lst in bridge_by_nk.items():
        for c in lst:
            if c["_matched"]:
                continue
            strict_extra.append({
                "name": nk[0],
                "kind": nk[1],
                "line": c.get("line"),
            })

    return {
        "gold_callee_count": len(gold_callees),
        "bridge_callee_count": len(bridge_callees),
        "strict_matches": matches,
        "strict_miss": strict_miss,
        "strict_extra": strict_extra,
        "kind_mismatches": kind_mismatches,
    }


def _bridge_callees_for_symbol(bridge_sym: dict) -> list[dict]:
    """Bridge symbol's callees list (P5.2.0+ field).  Empty for pre-5.2 builds."""
    return bridge_sym.get("callees", []) or []


# ---------------------------------------------------------------------------
# Per-file diff
# ---------------------------------------------------------------------------
def diff_file_v2(gold_path: Path, bridge_path: Path) -> dict:
    gold = load_gold(gold_path)
    bridge_wrapped = load_bridge(bridge_path)

    gold_symbols = gold.get("symbols", [])
    bridge_symbols = bridge_wrapped.get("jcm_symbols", [])

    sym_diff = symbol_set_diff(gold_symbols, bridge_symbols)
    shared_keys = sym_diff.pop("_shared_keys")
    gold_keys = sym_diff.pop("_gold_keys")
    bridge_keys = sym_diff.pop("_bridge_keys")

    per_sym = []
    for key in sorted(shared_keys):
        g = gold_keys[key]
        b = bridge_keys[key]
        d = strict_callee_diff(
            g.get("callees", []),
            _bridge_callees_for_symbol(b),
        )
        d["qualified_name"] = g["qualified_name"]
        per_sym.append(d)

    n_gold = sum(d["gold_callee_count"] for d in per_sym)
    n_bridge = sum(d["bridge_callee_count"] for d in per_sym)
    n_matches = sum(d["strict_matches"] for d in per_sym)
    n_miss = sum(len(d["strict_miss"]) for d in per_sym)
    n_extra = sum(len(d["strict_extra"]) for d in per_sym)
    n_km = sum(len(d["kind_mismatches"]) for d in per_sym)

    recall = n_matches / n_gold if n_gold else 0.0
    precision = n_matches / n_bridge if n_bridge else 0.0
    f1 = (2 * recall * precision / (recall + precision)) if (recall + precision) else 0.0

    return {
        "basename": gold.get("file", gold_path.stem.replace(".gold", "")),
        "gold_path": str(gold_path),
        "bridge_path": str(bridge_path),
        "gold_schema_version": gold.get("schema_version", "?"),
        "line_tolerance": LINE_TOLERANCE,
        "symbol_diff": sym_diff,
        "callee_diff_per_symbol_v2": per_sym,
        "aggregate_v2": {
            "n_gold_callees": n_gold,
            "n_bridge_callees": n_bridge,
            "strict_matches": n_matches,
            "strict_miss": n_miss,
            "strict_extra": n_extra,
            "kind_mismatches": n_km,
            "recall": round(recall, 4),
            "precision": round(precision, 4),
            "f1": round(f1, 4),
            "n_bridge_only_symbols": len(sym_diff["bridge_only"]),
            "n_gold_only_symbols": len(sym_diff["gold_only"]),
        },
    }


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
def main() -> int:
    corpus_dirs = sorted(GOLD_BASE.iterdir())
    n_ok = 0
    n_err = 0
    totals = Counter()
    per_corpus: dict[str, dict] = {}

    for corpus_dir in corpus_dirs:
        if not corpus_dir.is_dir():
            continue
        corpus = corpus_dir.name
        per_corpus.setdefault(corpus, Counter())
        gold_files = sorted(corpus_dir.glob("*.gold.json"))
        for gold_path in gold_files:
            basename = gold_path.name.replace(".gold.json", "")
            corrected = corpus_dir / f"{basename}.corrected_gold.json"
            effective_gold = corrected if corrected.exists() else gold_path
            bridge_path = BRIDGE_BASE / corpus / f"{basename}.bridge.json"
            if not bridge_path.exists():
                print(
                    f"  [SKIP] {corpus}/{basename}: bridge.json missing",
                    file=sys.stderr,
                )
                n_err += 1
                continue
            try:
                result = diff_file_v2(effective_gold, bridge_path)
            except Exception as e:  # noqa: BLE001
                print(f"  [ERROR] {corpus}/{basename}: {e}", file=sys.stderr)
                n_err += 1
                continue
            out_path = BRIDGE_BASE / corpus / f"{basename}.bridge_diff_v2.json"
            out_path.write_text(json.dumps(result, indent=2))
            agg = result["aggregate_v2"]
            print(
                f"  [OK] {corpus}/{basename}: "
                f"recall={agg['recall']:.3f} prec={agg['precision']:.3f} "
                f"matches={agg['strict_matches']} "
                f"miss={agg['strict_miss']} extra={agg['strict_extra']} "
                f"km={agg['kind_mismatches']}"
            )
            for k in ("n_gold_callees", "n_bridge_callees",
                      "strict_matches", "strict_miss", "strict_extra",
                      "kind_mismatches"):
                totals[k] += agg[k]
                per_corpus[corpus][k] += agg[k]
            n_ok += 1

    # Aggregate file
    n_gold = totals["n_gold_callees"]
    n_bridge = totals["n_bridge_callees"]
    n_matches = totals["strict_matches"]
    recall = n_matches / n_gold if n_gold else 0.0
    precision = n_matches / n_bridge if n_bridge else 0.0
    f1 = (2 * recall * precision / (recall + precision)) if (recall + precision) else 0.0

    per_corpus_summary = {}
    for corpus, c in per_corpus.items():
        g = c["n_gold_callees"]
        b = c["n_bridge_callees"]
        m = c["strict_matches"]
        per_corpus_summary[corpus] = {
            "n_gold_callees": g,
            "n_bridge_callees": b,
            "strict_matches": m,
            "strict_miss": c["strict_miss"],
            "strict_extra": c["strict_extra"],
            "kind_mismatches": c["kind_mismatches"],
            "recall": round(m / g, 4) if g else 0.0,
            "precision": round(m / b, 4) if b else 0.0,
        }

    aggregate_path = BRIDGE_BASE / "AGGREGATE_v2.json"
    aggregate_path.write_text(json.dumps({
        "line_tolerance": LINE_TOLERANCE,
        "files_processed": n_ok,
        "errors": n_err,
        "totals": {
            "n_gold_callees": n_gold,
            "n_bridge_callees": n_bridge,
            "strict_matches": n_matches,
            "strict_miss": totals["strict_miss"],
            "strict_extra": totals["strict_extra"],
            "kind_mismatches": totals["kind_mismatches"],
            "recall": round(recall, 4),
            "precision": round(precision, 4),
            "f1": round(f1, 4),
        },
        "per_corpus": per_corpus_summary,
    }, indent=2))

    print(f"\n=== bridge_diff_v2 complete: {n_ok} OK, {n_err} errors ===")
    print(f"  Strict recall    : {recall:.4f}")
    print(f"  Strict precision : {precision:.4f}")
    print(f"  Strict F1        : {f1:.4f}")
    print(f"  Aggregate file   : {aggregate_path}")
    return 0 if n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
