"""_tcl_callees — additive enrichment of callee/rename outputs with TCL per-call-site metadata.

All public functions are purely additive:
- they only ADD new keys (prefixed ``tcl_``) to existing result dicts;
- they NEVER remove or replace existing fields;
- if ``sym`` carries no ``callees`` list (or it is empty), every function
  returns its input unchanged — byte-equal for non-TCL symbols and for TCL
  symbols that have not yet been disassembled.

No globals, no I/O, no logging at module top-level.
"""
from __future__ import annotations

from typing import Any


def enrich_callees_from_references(result: list[dict], sym: dict) -> list[dict]:
    """Augment ``_callees_from_references()`` output with per-call-site metadata.

    Each output dict in *result* represents a resolved callee symbol.  For each,
    matching entries in ``sym.get("callees")`` are looked up by ``name``; a new
    optional ``tcl_call_sites`` key is attached containing the list of
    ``{line, kind, receiver_hint, note}`` records that produced this callee.

    If *sym* has no callees, *result* is returned unchanged.
    """
    callees: list[dict] = sym.get("callees") or []
    if not callees:
        return result

    # Build name → [call-site records] index once
    sites_by_name: dict[str, list[dict[str, Any]]] = {}
    for site in callees:
        n = site.get("name", "")
        if n:
            sites_by_name.setdefault(n, []).append({
                "line": site.get("line"),
                "kind": site.get("kind"),
                "receiver_hint": site.get("receiver_hint"),
                "note": site.get("note"),
            })

    enriched: list[dict] = []
    for entry in result:
        entry_name = entry.get("name", "")
        matching = sites_by_name.get(entry_name)
        if matching:
            # Shallow-copy so we never mutate the caller's dict
            new_entry = dict(entry)
            new_entry["tcl_call_sites"] = matching
            enriched.append(new_entry)
        else:
            enriched.append(entry)
    return enriched


def enrich_find_direct_callees(result: list[dict], sym: dict) -> list[dict]:
    """Same contract as :func:`enrich_callees_from_references` but applied to
    ``find_direct_callees()`` output.

    If *sym* has no callees, *result* is returned unchanged.
    """
    return enrich_callees_from_references(result, sym)


def enrich_rename_plan(
    plan: dict,
    sym: dict,
    caller_syms: list[dict] | None = None,
) -> dict:
    """Enrich a rename plan with line-accurate call-site refs from caller symbols' callees.

    For each edit-site block in ``plan["edits"]``, if any of *caller_syms*
    carries a ``callees`` entry whose name matches the symbol being renamed,
    a ``tcl_call_sites`` key is added to the edit dict — the aggregated list
    of ``{line, kind, receiver_hint, note}`` records across all callers.

    If *sym* itself has callees recorded, those are used directly as an
    additional source.

    Returns *plan* unchanged (byte-equal) when no callee data is available.
    """
    if caller_syms is None:
        caller_syms = []

    sym_name: str = sym.get("name", "") if isinstance(sym, dict) else ""

    # Collect all call-site records that target sym_name from every caller
    all_sites: list[dict[str, Any]] = []
    for csym in [sym, *caller_syms]:
        for site in (csym.get("callees") or []):
            if site.get("name") == sym_name:
                all_sites.append({
                    "line": site.get("line"),
                    "kind": site.get("kind"),
                    "receiver_hint": site.get("receiver_hint"),
                    "note": site.get("note"),
                })

    if not all_sites:
        return plan

    # Attach to the plan — additive key only, never overwrite existing fields
    new_plan = dict(plan)
    new_plan["tcl_call_sites"] = all_sites
    return new_plan
