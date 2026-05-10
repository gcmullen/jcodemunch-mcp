"""get_call_hierarchy: callers and callees for any indexed symbol, N levels deep."""

import time
from typing import Optional

from ..storage import IndexStore
from ._call_graph import build_symbols_by_file, bfs_callers, bfs_callees
from ._class_helpers import collect_class_kin
from ._utils import resolve_repo
from .get_blast_radius import _build_reverse_adjacency, _find_symbol


def _inheritance_aliases(index, sym: dict) -> list[dict]:
    """Return method symbols on ancestor/descendant classes with the same name.

    Used by ``get_call_hierarchy`` to surface inheritance-aware callers and
    callees: at runtime a call to ``Animal.foo`` could dispatch to ``Dog.foo``
    (descendant override) or, conversely, ``Animal.foo`` if invoked on a
    ``Dog`` receiver could trace back to ``Animal.foo`` (ancestor lookup).

    Cross-language via the dual-path dispatch (Tcl side-table + signature
    regex).  Returns ``[]`` for non-method symbols, methods whose ``parent``
    field is missing or doesn't resolve to a class, or methods on classes
    with no kin in the index.

    The primary symbol itself is *not* included in the returned list.
    """
    if sym.get("kind") not in ("method", "function"):
        return []
    parent_id = sym.get("parent")
    if not parent_id:
        return []
    symbol_index: dict[str, dict] = getattr(index, "_symbol_index", {}) or {}
    parent_sym = symbol_index.get(parent_id)
    if not parent_sym or parent_sym.get("kind") not in ("class", "type"):
        return []
    parent_name = parent_sym.get("name", "")
    if not parent_name:
        return []

    kin_names = collect_class_kin(index.symbols, parent_name)
    if not kin_names:
        return []

    method_name = sym.get("name", "")
    sym_id = sym.get("id", "")
    aliases: list[dict] = []
    seen_ids: set[str] = {sym_id} if sym_id else set()

    for s in index.symbols:
        if s.get("name") != method_name:
            continue
        if s.get("kind") not in ("method", "function"):
            continue
        s_parent_id = s.get("parent")
        if not s_parent_id:
            continue
        s_parent = symbol_index.get(s_parent_id)
        if not s_parent or s_parent.get("name", "") not in kin_names:
            continue
        sid = s.get("id", "")
        if sid in seen_ids:
            continue
        seen_ids.add(sid)
        aliases.append(s)

    return aliases


def get_call_hierarchy(
    repo: str,
    symbol_id: str,
    direction: str = "both",
    depth: int = 3,
    storage_path: Optional[str] = None,
) -> dict:
    """Return incoming callers and outgoing callees for a symbol, N levels deep.

    Uses AST-derived call detection — no LSP required. Callers are found by
    scanning symbols in files that import the target's module; callees are found
    by matching imported-symbol names against the target's source body.

    Args:
        repo: Repository identifier (owner/repo or just repo name).
        symbol_id: Symbol name or full ID to analyse. Use search_symbols to find IDs.
        direction: 'callers' | 'callees' | 'both'. Default 'both'.
        depth: Maximum hops to traverse (1–5). Default 3.
        storage_path: Custom storage path.

    Returns:
        Dict with symbol info, callers list, callees list, depth_reached, and _meta.
        Each caller/callee entry includes {id, name, kind, file, line, depth}.
    """
    depth = max(1, min(depth, 5))
    if direction not in ("callers", "callees", "both"):
        direction = "both"
    start = time.perf_counter()

    try:
        owner, name = resolve_repo(repo, storage_path)
    except ValueError as e:
        return {"error": str(e)}

    store = IndexStore(base_path=storage_path)
    index = store.load_index(owner, name)
    if not index:
        return {"error": f"Repository not indexed: {owner}/{name}"}

    if index.imports is None:
        return {
            "error": (
                "No import data available. Re-index with jcodemunch-mcp >= 1.3.0 "
                "to enable call hierarchy analysis."
            )
        }

    matches = _find_symbol(index, symbol_id)
    if not matches:
        return {"error": f"Symbol not found: '{symbol_id}'. Try search_symbols first."}
    if len(matches) > 1:
        ambiguous = [{"name": s["name"], "file": s["file"], "id": s["id"]} for s in matches]
        return {
            "error": (
                f"Ambiguous symbol '{symbol_id}': found {len(matches)} definitions. "
                "Use the symbol 'id' field to disambiguate."
            ),
            "candidates": ambiguous,
        }

    sym = matches[0]
    symbols_by_file = build_symbols_by_file(index)
    reverse_adj = _build_reverse_adjacency(
        index.imports,
        frozenset(index.source_files),
        getattr(index, "alias_map", None),
        getattr(index, "psr4_map", None),
    )

    callers: list[dict] = []
    callees: list[dict] = []
    depth_reached = 0

    # Inheritance-aware sibling methods (same name, kin classes via the
    # dual-path get_bases dispatch).  At runtime a call dispatched on the
    # parent class could land on any of these via override or super-class
    # lookup, so they're treated as additional resolution targets.
    alias_syms = _inheritance_aliases(index, sym)
    alias_caller_tags: dict[str, str] = {}
    alias_callee_tags: dict[str, str] = {}

    def _merge(
        base: list[dict],
        addition: list[dict],
        tag_map: dict[str, str],
        alias_class: str,
    ) -> list[dict]:
        """Append entries from *addition* to *base*, deduping by id and
        tagging each new entry with ``inheritance_via=<alias_class>``."""
        seen = {e.get("id") for e in base if e.get("id")}
        for entry in addition:
            eid = entry.get("id")
            if not eid or eid in seen:
                continue
            seen.add(eid)
            entry = dict(entry)
            entry["inheritance_via"] = alias_class
            base.append(entry)
            tag_map[eid] = alias_class
        return base

    if direction in ("callers", "both"):
        callers, dr = bfs_callers(
            index, store, owner, name, sym, reverse_adj, symbols_by_file, depth
        )
        depth_reached = max(depth_reached, dr)
        for alias in alias_syms:
            alias_callers, alias_dr = bfs_callers(
                index, store, owner, name, alias, reverse_adj, symbols_by_file, depth
            )
            symbol_index = getattr(index, "_symbol_index", {}) or {}
            alias_class_sym = symbol_index.get(alias.get("parent", "")) or {}
            alias_class = alias_class_sym.get("name", "")
            callers = _merge(callers, alias_callers, alias_caller_tags, alias_class)
            depth_reached = max(depth_reached, alias_dr)

    if direction in ("callees", "both"):
        callees, dr = bfs_callees(
            index, store, owner, name, sym, symbols_by_file, depth
        )
        depth_reached = max(depth_reached, dr)
        for alias in alias_syms:
            alias_callees, alias_dr = bfs_callees(
                index, store, owner, name, alias, symbols_by_file, depth
            )
            symbol_index = getattr(index, "_symbol_index", {}) or {}
            alias_class_sym = symbol_index.get(alias.get("parent", "")) or {}
            alias_class = alias_class_sym.get("name", "")
            callees = _merge(callees, alias_callees, alias_callee_tags, alias_class)
            depth_reached = max(depth_reached, alias_dr)

    elapsed = (time.perf_counter() - start) * 1000

    # Build dispatches section from dispatch edges
    ctx_meta = getattr(index, "context_metadata", None) or {}
    dispatch_edge_data = ctx_meta.get("dispatch_edges", [])
    dispatches: list[dict] = []
    if dispatch_edge_data:
        # Group by (interface_name, method_name)
        grouped: dict[tuple[str, str], list[dict]] = {}
        for de in dispatch_edge_data:
            key = (de.get("interface_name", ""), de.get("method_name", ""))
            grouped.setdefault(key, []).append(de)
        for (iface, method), impls in grouped.items():
            dispatches.append({
                "interface": iface,
                "method": method,
                "implementations": [
                    {
                        "name": imp.get("impl_name", ""),
                        "file": imp.get("impl_file", ""),
                        "line": imp.get("impl_line", 0),
                    }
                    for imp in impls
                ],
            })

    # Determine methodology based on available data
    get_callers = getattr(index, "get_callers_by_name", None)
    callers_by_name = get_callers() if get_callers else None
    has_call_data = bool(callers_by_name)
    has_lsp_data = bool(ctx_meta.get("lsp_edges"))
    has_dispatch_data = bool(dispatch_edge_data)
    if has_dispatch_data:
        methodology = "lsp_dispatch_enriched"
        confidence = "high"
        source = "lsp_bridge + dispatch_resolution + ast_call_references"
        tip = (
            "LSP dispatch-enriched: compiler-grade resolution via language servers with "
            "interface/trait dispatch resolution — concrete implementations of interface "
            "methods are resolved via textDocument/implementation. Each edge has a "
            "'resolution' field: lsp_dispatch (interface dispatch), lsp_resolved "
            "(compiler-grade), ast_resolved (direct AST), ast_inferred (import graph), "
            "or text_matched (heuristic)."
        )
    elif has_lsp_data:
        methodology = "lsp_enriched"
        confidence = "high"
        source = "lsp_bridge + ast_call_references"
        tip = (
            "LSP-enriched: compiler-grade resolution via language servers (pyright, gopls, "
            "typescript-language-server, rust-analyzer) for highest confidence, with AST "
            "call_references and text heuristic as fallback layers. Each edge has a "
            "'resolution' field: lsp_resolved (compiler-grade), ast_resolved (direct AST), "
            "ast_inferred (import graph), or text_matched (heuristic)."
        )
    elif has_call_data:
        methodology = "ast_call_references"
        confidence = "medium"
        source = "ast_call_references"
        tip = (
            "AST-based: call references extracted from tree-sitter AST during indexing. "
            "More precise than text heuristic, but still approximate for dynamic dispatch. "
            "Each edge has a 'resolution' field: ast_resolved (direct AST match), "
            "ast_inferred (resolved via import graph), or text_matched (heuristic). "
            "Enable LSP enrichment for compiler-grade resolution."
        )
    else:
        methodology = "text_heuristic"
        confidence = "low"
        source = "text_heuristic"
        tip = (
            "Text-heuristic: callers = symbols in importing files that mention this "
            "name as a word token; callees = imported symbols mentioned in this "
            "symbol's body. May have false positives for common names or dynamic "
            "dispatch. Use get_impact_preview for a transitive 'what breaks?' view."
        )

    # Summarize resolution tiers across all edges
    resolution_counts: dict[str, int] = {}
    for edge in callers + callees:
        r = edge.get("resolution", "unknown")
        resolution_counts[r] = resolution_counts.get(r, 0) + 1

    inheritance_aliases_meta = [
        {
            "id": a.get("id", ""),
            "name": a.get("name", ""),
            "class": (
                getattr(index, "_symbol_index", {}) or {}
            ).get(a.get("parent", ""), {}).get("name", ""),
            "file": a.get("file", ""),
            "line": a.get("line", 0),
        }
        for a in alias_syms
    ]

    return {
        "repo": f"{owner}/{name}",
        "symbol": {
            "id": sym.get("id", ""),
            "name": sym.get("name", ""),
            "kind": sym.get("kind", ""),
            "file": sym.get("file", ""),
            "line": sym.get("line", 0),
        },
        "direction": direction,
        "depth": depth,
        "depth_reached": depth_reached,
        "caller_count": len(callers),
        "callee_count": len(callees),
        "callers": callers,
        "callees": callees,
        "dispatches": dispatches,
        "_meta": {
            "timing_ms": round(elapsed, 1),
            "methodology": methodology,
            "confidence_level": confidence,
            "source": source,
            "resolution_tiers": resolution_counts,
            "inheritance_aliases": inheritance_aliases_meta,
            "tip": tip,
        },
    }
