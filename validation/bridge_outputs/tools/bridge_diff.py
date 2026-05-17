#!/usr/bin/env python3
"""Diff bridge output against gold annotations.

For each <corpus-sha>/<basename>.gold.json (preferring corrected_gold.json):
  - Load gold symbols + callees
  - Load <corpus-sha>/<basename>.bridge.json (jcm wrapped output)
  - Run symbol-set diff on (qualified_name, kind) with kind mapping
  - Run multiset callee-name diff for shared symbols
  - Write <corpus-sha>/<basename>.bridge_diff.json

Usage:
  .venv/bin/python3 validation/bridge_outputs/tools/bridge_diff.py
"""
import json
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
GOLD_BASE = REPO_ROOT / "validation" / "gold_annotations" / "conv-v1.3" / "tcl-8.6"
BRIDGE_BASE = REPO_ROOT / "validation" / "bridge_outputs" / "conv-v1.3" / "tcl-8.6"

# ---------------------------------------------------------------------------
# §7.1 tier denylist — names the bridge may emit that gold filters out.
# Sourced verbatim from build_prompt.py PROMPT_TEMPLATE "Hard denylist" block.
# ---------------------------------------------------------------------------
TIER1_NAMES: frozenset[str] = frozenset({
    "if", "else", "elseif", "while", "for", "foreach", "lmap", "time",
    "switch", "catch", "try", "on", "trap", "finally", "return", "break",
    "continue", "yield", "yieldto",
})

TIER2_SCALAR_NAMES: frozenset[str] = frozenset({
    "set", "incr", "unset", "lappend", "lassign", "lset", "lreplace",
    "llength", "lrange", "lsearch", "lsort", "lindex", "linsert", "lrepeat",
    "lreverse", "list", "split", "join", "format", "scan", "expr",
    "regexp", "regsub", "subst", "concat", "eof", "seek", "tell", "flush",
    "global", "variable",
})

# Tier 2 ensemble prefixes — any name that starts with one of these is Tier 2
TIER2_ENSEMBLE_PREFIXES: frozenset[str] = frozenset({
    "string", "dict", "info", "array", "clock", "chan", "file", "binary",
    "namespace", "package", "encoding",
})

TIER3_NAMES: frozenset[str] = frozenset({
    "puts", "gets", "read", "open", "close", "update", "vwait", "error", "throw",
})

TIER2_3_SCRIPT_DISPATCHERS: frozenset[str] = frozenset({
    "after", "bind", "fileevent",
    "trace add variable", "trace add command", "trace add execution",
    "socket -server",
})


def _tier_of(name: str) -> str | None:
    """Return the tier label for a name that appears in a denylist, or None."""
    if name in TIER1_NAMES:
        return "Tier 1"
    if name in TIER2_SCALAR_NAMES:
        return "Tier 2"
    # Tier 2 ensemble: first word matches a prefix
    first_word = name.split()[0] if name.strip() else name
    if first_word in TIER2_ENSEMBLE_PREFIXES:
        return "Tier 2"
    if name in TIER3_NAMES:
        return "Tier 3"
    if name in TIER2_3_SCRIPT_DISPATCHERS:
        return "Tier 2/3 dispatcher"
    return None


# ---------------------------------------------------------------------------
# Gold kind → jcm kind mapping (for symbol-set diff)
# ---------------------------------------------------------------------------
def gold_kind_to_jcm(kind: str, qualified_name: str = "") -> str:
    """Map a gold §4.1 kind to the jcm VALID_KINDS equivalent."""
    mapping = {
        "proc": "function",
        "method": "method",
        "class_method": "function",  # heuristic — may have parent class
        "constructor": "method",
        "destructor": "method",
        "class": "class",
        "namespace": "namespace",
        # No direct jcm map for these — classify as bridge_only candidates
        "coroutine": "__no_map__",
        "configbody": "__no_map__",
        "lambda": "__no_map__",
    }
    return mapping.get(kind, "__no_map__")


def jcm_kind_to_gold(kind: str) -> list[str]:
    """Return the set of gold kinds that map to this jcm kind."""
    reverse: dict[str, list[str]] = {
        "function": ["proc", "class_method"],
        "method": ["method", "constructor", "destructor"],
        "class": ["class"],
        "namespace": ["namespace"],
        "module": [],    # jcm-only (__script__ module)
        "import": [],    # jcm-only (package require as import symbol)
        "constant": [],
        "type": [],
        "template": [],
    }
    return reverse.get(kind, [])


def load_gold(gold_path: Path) -> dict:
    return json.loads(gold_path.read_text())


def load_bridge(bridge_path: Path) -> dict:
    return json.loads(bridge_path.read_text())


# ---------------------------------------------------------------------------
# Symbol-set diff
# ---------------------------------------------------------------------------
def _gold_sym_key(sym: dict) -> tuple[str, str]:
    """Canonical (qualified_name, jcm_kind) key for a gold symbol."""
    return (sym["qualified_name"], gold_kind_to_jcm(sym["kind"], sym["qualified_name"]))


def _bridge_sym_key(sym: dict) -> tuple[str, str]:
    """Canonical (qualified_name, jcm_kind) key for a bridge symbol."""
    # Skip __script__ module and import symbols — they have no gold equivalent
    return (sym["qualified_name"], sym["kind"])


def symbol_set_diff(
    gold_symbols: list[dict], bridge_symbols: list[dict]
) -> dict:
    """Compute symbol-set diff between gold and bridge."""
    # Gold keys: map to jcm kinds; skip unmapped gold kinds (no jcm counterpart)
    gold_keys: dict[tuple[str, str], dict] = {}
    for s in gold_symbols:
        jcm_k = gold_kind_to_jcm(s["kind"], s["qualified_name"])
        if jcm_k == "__no_map__":
            continue  # coroutine/configbody/lambda not in jcm
        key = (s["qualified_name"], jcm_k)
        gold_keys[key] = s

    # Bridge keys: skip jcm-only kinds (module, import) and __script__
    bridge_keys: dict[tuple[str, str], dict] = {}
    for s in bridge_symbols:
        if s["kind"] in ("import",):
            continue
        if s["qualified_name"] in ("__script__", "__file__"):
            continue
        key = (s["qualified_name"], s["kind"])
        bridge_keys[key] = s

    gold_set = set(gold_keys)
    bridge_set = set(bridge_keys)

    gold_only_keys = gold_set - bridge_set
    bridge_only_keys = bridge_set - gold_set
    shared_keys = gold_set & bridge_set

    gold_only = [{"qualified_name": k[0], "kind": k[1]} for k in sorted(gold_only_keys)]
    bridge_only = [{"qualified_name": k[0], "kind": k[1]} for k in sorted(bridge_only_keys)]

    return {
        "gold_only": gold_only,
        "bridge_only": bridge_only,
        "shared_count": len(shared_keys),
        "_shared_keys": list(shared_keys),  # internal — removed before output
        "_gold_keys": gold_keys,
        "_bridge_keys": bridge_keys,
    }


# ---------------------------------------------------------------------------
# Per-symbol callee diff
# ---------------------------------------------------------------------------
def callee_diff_for_symbol(
    gold_sym: dict, bridge_sym: dict
) -> dict:
    """Multiset diff on callee names for a shared symbol."""
    gold_callees = gold_sym.get("callees", [])
    bridge_call_refs = bridge_sym.get("call_references", [])

    gold_names = Counter(c["name"] for c in gold_callees)
    bridge_names = Counter(bridge_call_refs)

    shared = gold_names & bridge_names
    bridge_miss_counter = gold_names - bridge_names   # in gold but not bridge
    bridge_extra_counter = bridge_names - gold_names  # in bridge but not gold

    # Build gold callee kind lookup (for bridge_miss annotation)
    gold_kind_for_name: dict[str, list[str]] = {}
    for c in gold_callees:
        gold_kind_for_name.setdefault(c["name"], []).append(c.get("kind", "?"))

    bridge_miss = []
    for name, count in sorted(bridge_miss_counter.items()):
        gold_kinds = gold_kind_for_name.get(name, ["?"])
        bridge_miss.append({
            "name": name,
            "gold_kind": gold_kinds[0] if len(set(gold_kinds)) == 1 else gold_kinds,
            "count": count,
        })

    # bridge_extra — check against tier denylist
    bridge_extra = []
    bridge_extra_tier_filtered = []
    for name, count in sorted(bridge_extra_counter.items()):
        tier = _tier_of(name)
        if tier:
            bridge_extra_tier_filtered.append({"name": name, "tier": tier, "count": count})
        else:
            bridge_extra.append({"name": name, "count": count})

    return {
        "qualified_name": gold_sym["qualified_name"],
        "gold_callee_count": sum(gold_names.values()),
        "bridge_call_ref_count": sum(bridge_names.values()),
        "shared_names": sorted(shared.keys()),
        "bridge_miss": bridge_miss,
        "bridge_extra": bridge_extra,
        "bridge_extra_tier_filtered": bridge_extra_tier_filtered,
    }


# ---------------------------------------------------------------------------
# Main diff logic per file
# ---------------------------------------------------------------------------
def diff_file(gold_path: Path, bridge_path: Path) -> dict:
    gold = load_gold(gold_path)
    bridge_wrapped = load_bridge(bridge_path)

    gold_symbols = gold.get("symbols", [])
    bridge_symbols = bridge_wrapped.get("jcm_symbols", [])

    sym_diff = symbol_set_diff(gold_symbols, bridge_symbols)
    shared_keys: list[tuple[str, str]] = sym_diff.pop("_shared_keys")
    gold_keys: dict[tuple[str, str], dict] = sym_diff.pop("_gold_keys")
    bridge_keys: dict[tuple[str, str], dict] = sym_diff.pop("_bridge_keys")

    callee_diffs = []
    for key in sorted(shared_keys):
        gold_sym = gold_keys[key]
        bridge_sym = bridge_keys[key]
        diff = callee_diff_for_symbol(gold_sym, bridge_sym)
        callee_diffs.append(diff)

    # Aggregate counts
    n_gold_callees = sum(d["gold_callee_count"] for d in callee_diffs)
    n_bridge_call_refs = sum(d["bridge_call_ref_count"] for d in callee_diffs)
    n_shared = sum(len(d["shared_names"]) for d in callee_diffs)
    n_bridge_miss = sum(
        sum(m["count"] for m in d["bridge_miss"]) for d in callee_diffs
    )
    n_bridge_extra = sum(
        sum(e["count"] for e in d["bridge_extra"]) for d in callee_diffs
    )
    n_bridge_extra_tier_filtered = sum(
        sum(e["count"] for e in d["bridge_extra_tier_filtered"]) for d in callee_diffs
    )

    return {
        "basename": gold.get("file", gold_path.stem.replace(".gold", "")),
        "gold_path": str(gold_path),
        "bridge_path": str(bridge_path),
        "gold_schema_version": gold.get("schema_version", "?"),
        "symbol_diff": sym_diff,
        "callee_diff_per_symbol": callee_diffs,
        "aggregate": {
            "n_gold_callees": n_gold_callees,
            "n_bridge_call_refs": n_bridge_call_refs,
            "n_shared": n_shared,
            "n_bridge_miss": n_bridge_miss,
            "n_bridge_extra": n_bridge_extra,
            "n_bridge_extra_tier_filtered": n_bridge_extra_tier_filtered,
            "n_bridge_only_symbols": len(sym_diff["bridge_only"]),
            "n_gold_only_symbols": len(sym_diff["gold_only"]),
        },
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> int:
    corpus_dirs = sorted(GOLD_BASE.iterdir())
    n_ok = 0
    n_err = 0

    for corpus_dir in corpus_dirs:
        if not corpus_dir.is_dir():
            continue
        corpus = corpus_dir.name

        # Prefer corrected_gold over gold
        gold_files = sorted(corpus_dir.glob("*.gold.json"))
        for gold_path in gold_files:
            basename = gold_path.name.replace(".gold.json", "")
            # Check for corrected_gold override
            corrected = corpus_dir / f"{basename}.corrected_gold.json"
            effective_gold = corrected if corrected.exists() else gold_path

            bridge_path = BRIDGE_BASE / corpus / f"{basename}.bridge.json"
            if not bridge_path.exists():
                print(
                    f"  [SKIP] {corpus}/{basename}: bridge.json missing "
                    f"(run run_bridge_on_gold.py first)",
                    file=sys.stderr,
                )
                n_err += 1
                continue

            try:
                result = diff_file(effective_gold, bridge_path)
            except Exception as e:
                print(f"  [ERROR] {corpus}/{basename}: {e}", file=sys.stderr)
                n_err += 1
                continue

            out_dir = BRIDGE_BASE / corpus
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{basename}.bridge_diff.json"
            out_path.write_text(json.dumps(result, indent=2))

            agg = result["aggregate"]
            gold_used = "corrected_gold" if corrected.exists() else "gold"
            print(
                f"  [OK] {corpus}/{basename} [{gold_used}]: "
                f"shared_syms={result['symbol_diff']['shared_count']} "
                f"gold_only_syms={agg['n_gold_only_symbols']} "
                f"bridge_only_syms={agg['n_bridge_only_symbols']} "
                f"miss={agg['n_bridge_miss']} extra={agg['n_bridge_extra']} "
                f"tier_filtered={agg['n_bridge_extra_tier_filtered']}"
            )
            n_ok += 1

    print(f"\n=== Diff complete: {n_ok} OK, {n_err} errors ===")
    return 0 if n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
