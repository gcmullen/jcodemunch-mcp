#!/usr/bin/env python3
"""Aggregate all bridge_diff.json files into a roll-up report.

Reads:  validation/bridge_outputs/conv-v1.3/tcl-8.6/<corpus>/<basename>.bridge_diff.json
Writes: validation/bridge_outputs/conv-v1.3/tcl-8.6/AGGREGATE.json
Prints: stdout summary suitable for inclusion in BRIDGE_VS_GOLD_VALIDATION.md

Usage:
  .venv/bin/python3 validation/bridge_outputs/tools/bridge_diff_aggregate.py
"""
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BRIDGE_BASE = REPO_ROOT / "validation" / "bridge_outputs" / "conv-v1.3" / "tcl-8.6"
AGG_OUT = BRIDGE_BASE / "AGGREGATE.json"


def main() -> int:
    diff_files = sorted(BRIDGE_BASE.rglob("*.bridge_diff.json"))
    if not diff_files:
        print("ERROR: no bridge_diff.json files found. Run bridge_diff.py first.",
              file=sys.stderr)
        return 1

    # Global counters
    total_files = 0
    total_gold_callees = 0
    total_bridge_call_refs = 0
    total_shared = 0
    total_bridge_miss = 0
    total_bridge_extra = 0
    total_bridge_extra_tier_filtered = 0
    total_gold_only_symbols = 0
    total_bridge_only_symbols = 0

    # Per-corpus breakdown
    corpus_stats: dict[str, dict] = defaultdict(lambda: {
        "files": 0,
        "n_gold_callees": 0,
        "n_bridge_call_refs": 0,
        "n_shared": 0,
        "n_bridge_miss": 0,
        "n_bridge_extra": 0,
        "n_bridge_extra_tier_filtered": 0,
        "n_gold_only_symbols": 0,
        "n_bridge_only_symbols": 0,
    })

    # Frequency counters for top-N analysis
    miss_counter: Counter = Counter()
    extra_counter: Counter = Counter()
    extra_tier_counter: Counter = Counter()

    per_file_rows = []

    for diff_path in diff_files:
        corpus = diff_path.parent.name
        try:
            data = json.loads(diff_path.read_text())
        except Exception as e:
            print(f"  [WARN] Could not read {diff_path}: {e}", file=sys.stderr)
            continue

        agg = data.get("aggregate", {})
        total_files += 1

        # Roll-up totals
        total_gold_callees += agg.get("n_gold_callees", 0)
        total_bridge_call_refs += agg.get("n_bridge_call_refs", 0)
        total_shared += agg.get("n_shared", 0)
        total_bridge_miss += agg.get("n_bridge_miss", 0)
        total_bridge_extra += agg.get("n_bridge_extra", 0)
        total_bridge_extra_tier_filtered += agg.get("n_bridge_extra_tier_filtered", 0)
        total_gold_only_symbols += agg.get("n_gold_only_symbols", 0)
        total_bridge_only_symbols += agg.get("n_bridge_only_symbols", 0)

        # Per-corpus
        cs = corpus_stats[corpus]
        cs["files"] += 1
        cs["n_gold_callees"] += agg.get("n_gold_callees", 0)
        cs["n_bridge_call_refs"] += agg.get("n_bridge_call_refs", 0)
        cs["n_shared"] += agg.get("n_shared", 0)
        cs["n_bridge_miss"] += agg.get("n_bridge_miss", 0)
        cs["n_bridge_extra"] += agg.get("n_bridge_extra", 0)
        cs["n_bridge_extra_tier_filtered"] += agg.get("n_bridge_extra_tier_filtered", 0)
        cs["n_gold_only_symbols"] += agg.get("n_gold_only_symbols", 0)
        cs["n_bridge_only_symbols"] += agg.get("n_bridge_only_symbols", 0)

        # Frequency analysis across all per-symbol diffs
        for sym_diff in data.get("callee_diff_per_symbol", []):
            for m in sym_diff.get("bridge_miss", []):
                miss_counter[m["name"]] += m.get("count", 1)
            for e in sym_diff.get("bridge_extra", []):
                extra_counter[e["name"]] += e.get("count", 1)
            for e in sym_diff.get("bridge_extra_tier_filtered", []):
                label = f"{e['name']} ({e.get('tier', '?')})"
                extra_tier_counter[label] += e.get("count", 1)

        per_file_rows.append({
            "corpus": corpus,
            "basename": data.get("basename", "?"),
            "gold_schema_version": data.get("gold_schema_version", "?"),
            **agg,
        })

    # Compute recall-like ratio (shared / gold_callees)
    callee_recall = (
        round(total_shared / total_gold_callees, 4)
        if total_gold_callees > 0 else None
    )

    top20_miss = [{"name": n, "count": c} for n, c in miss_counter.most_common(20)]
    top20_extra = [{"name": n, "count": c} for n, c in extra_counter.most_common(20)]
    top20_extra_tier = [
        {"label": n, "count": c} for n, c in extra_tier_counter.most_common(20)
    ]

    aggregate = {
        "total_files": total_files,
        "totals": {
            "n_gold_callees": total_gold_callees,
            "n_bridge_call_refs": total_bridge_call_refs,
            "n_shared": total_shared,
            "n_bridge_miss": total_bridge_miss,
            "n_bridge_extra": total_bridge_extra,
            "n_bridge_extra_tier_filtered": total_bridge_extra_tier_filtered,
            "n_gold_only_symbols": total_gold_only_symbols,
            "n_bridge_only_symbols": total_bridge_only_symbols,
            "callee_recall_approx": callee_recall,
        },
        "by_corpus": dict(corpus_stats),
        "top20_bridge_miss_names": top20_miss,
        "top20_bridge_extra_names": top20_extra,
        "top20_bridge_extra_tier_filtered": top20_extra_tier,
        "per_file": per_file_rows,
    }

    AGG_OUT.write_text(json.dumps(aggregate, indent=2))
    print(f"Wrote: {AGG_OUT}")

    # --- Stdout summary ---
    print()
    print("=" * 70)
    print("Bridge-vs-Gold Validation — Aggregate Summary")
    print("=" * 70)
    print(f"Files diffed         : {total_files}")
    print(f"Gold callees (total) : {total_gold_callees}")
    print(f"Bridge call_refs     : {total_bridge_call_refs}")
    print(f"Shared (matched)     : {total_shared}")
    print(f"Bridge miss          : {total_bridge_miss}  "
          f"({100*total_bridge_miss/max(total_gold_callees,1):.1f}% of gold)")
    print(f"Bridge extra (new)   : {total_bridge_extra}")
    print(f"Bridge extra (tier-filtered): {total_bridge_extra_tier_filtered}")
    print(f"Gold-only symbols    : {total_gold_only_symbols}")
    print(f"Bridge-only symbols  : {total_bridge_only_symbols}")
    if callee_recall is not None:
        print(f"Callee recall approx : {callee_recall:.3f}  "
              f"(shared / gold_callees)")
    print()

    print("--- By corpus ---")
    for corpus, cs in sorted(corpus_stats.items()):
        recall = (
            round(cs["n_shared"] / cs["n_gold_callees"], 3)
            if cs["n_gold_callees"] > 0 else "n/a"
        )
        print(
            f"  {corpus[:50]:<50}  "
            f"files={cs['files']}  "
            f"miss={cs['n_bridge_miss']}  "
            f"extra={cs['n_bridge_extra']}  "
            f"recall={recall}"
        )
    print()

    print("--- Top 5 bridge_miss names (gold has it, bridge doesn't) ---")
    for row in top20_miss[:5]:
        print(f"  {row['name']!r:40s}  count={row['count']}")
    print()

    print("--- Top 5 bridge_extra names (bridge has it, gold doesn't) ---")
    for row in top20_extra[:5]:
        print(f"  {row['name']!r:40s}  count={row['count']}")
    print()

    print("--- Top 5 bridge_extra tier-filtered (denylist hits) ---")
    for row in top20_extra_tier[:5]:
        print(f"  {row['label']!r:50s}  count={row['count']}")
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
