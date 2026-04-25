"""Traverse class inheritance chains from indexed symbol signatures."""

import re
import time
from collections import deque
from typing import Optional

from ..storage import IndexStore
from ._utils import resolve_repo

# Patterns to extract base class / interface names from signatures
_EXTENDS_RE = re.compile(
    r'\bextends\s+([\w$][\w$,\s]*?)(?=\s+implements|\s*[{(<]|$)', re.IGNORECASE
)
_IMPLEMENTS_RE = re.compile(
    r'\bimplements\s+([\w$][\w$,\s]*?)(?=\s*[{(<]|$)', re.IGNORECASE
)
# Python / Ruby style: class Foo(Bar, Baz)
_PAREN_BASES_RE = re.compile(r'\bclass\s+\w[\w$]*\s*\(([^)]+)\)')
# C++ / iTcl style: `class Foo : Bar, Baz` — used by the TCL native parser
# for `class`, `itcl::class`, `itk::usual`, and `oo::class create` signatures
# where inherit / superclass parents are joined with `: P1, P2, P3`.
_COLON_BASES_RE = re.compile(
    r'(?:\b(?:itcl::class|itk::usual|class)|oo::class\s+create)\s+[\w:]+\s*:\s*([^{]+?)(?:\s*\{|$)'
)


def _strip_leading_colons(name: str) -> str:
    """Strip leading `::` from a fully-qualified TCL name for matching.

    Bridge emits signatures with names like `::itk::Widget`; class_by_name
    is keyed on the tokens as they appear in the class-decl, which often
    lack the leading `::`.
    """
    return name.lstrip(":")


def _parse_bases(signature: str) -> list[str]:
    """Extract base class / interface names from a class signature."""
    bases: list[str] = []

    # extends Foo, Bar
    m = _EXTENDS_RE.search(signature)
    if m:
        bases += [n.strip() for n in m.group(1).split(",") if n.strip()]

    # implements Foo, Bar
    m = _IMPLEMENTS_RE.search(signature)
    if m:
        bases += [n.strip() for n in m.group(1).split(",") if n.strip()]

    # iTcl / C++ style: `class Foo : Parent1, Parent2`
    m = _COLON_BASES_RE.search(signature)
    if m:
        bases += [n.strip() for n in m.group(1).split(",") if n.strip()]

    # class Foo(Bar, Baz)  — Python / Ruby
    if not bases:
        m = _PAREN_BASES_RE.search(signature)
        if m:
            candidates = [n.strip() for n in m.group(1).split(",") if n.strip()]
            # Filter out obviously non-class args (e.g. Generic[T], *args)
            bases += [c for c in candidates if re.match(r'^[A-Z][\w.]*$', c)]

    return bases


def _build_class_maps(symbols: list[dict]) -> tuple[dict[str, dict], dict[str, list[str]]]:
    """
    Returns:
        class_by_name: {name -> symbol}  (first match wins for duplicates)
        children_of:   {name -> [child_names]}
    """
    class_syms = [s for s in symbols if s.get("kind") in ("class", "type")]
    class_by_name: dict[str, dict] = {}
    for sym in class_syms:
        name = sym.get("name", "")
        if name and name not in class_by_name:
            class_by_name[name] = sym
        # Also register the `::`-stripped form for TCL-style fully-qualified
        # names like `::itk::Widget`, so lookup by either `itk::Widget` or
        # `::itk::Widget` resolves.
        stripped = _strip_leading_colons(name)
        if stripped and stripped != name and stripped not in class_by_name:
            class_by_name[stripped] = sym

    children_of: dict[str, list[str]] = {}
    for sym in class_syms:
        for base in _parse_bases(sym.get("signature", "")):
            lookup = base if base in class_by_name else _strip_leading_colons(base)
            if lookup in class_by_name:
                children_of.setdefault(lookup, []).append(sym["name"])

    return class_by_name, children_of


def get_class_hierarchy(
    repo: str,
    class_name: str,
    storage_path: Optional[str] = None,
) -> dict:
    """Get the full inheritance hierarchy for a class.

    Traverses both upward (ancestors via ``extends``/``implements``) and
    downward (subclasses / implementors) from the named class.

    Args:
        repo: Repository identifier (owner/repo or just repo name).
        class_name: Name of the class to analyse.
        storage_path: Custom storage path.

    Returns:
        Dict with ``ancestors`` list (base classes, ordered nearest-first),
        ``descendants`` list (subclasses, BFS order), and the target class info.
    """
    start = time.perf_counter()

    try:
        owner, name = resolve_repo(repo, storage_path)
    except ValueError as e:
        return {"error": str(e)}

    store = IndexStore(base_path=storage_path)
    index = store.load_index(owner, name)
    if not index:
        return {"error": f"Repository not indexed: {owner}/{name}"}

    class_by_name, children_of = _build_class_maps(index.symbols)

    if class_name not in class_by_name:
        # Case-insensitive fallback
        lower = class_name.lower()
        match = next((n for n in class_by_name if n.lower() == lower), None)
        if not match:
            return {"error": f"Class '{class_name}' not found in index. Only 'class' and 'type' kinds are searched."}
        class_name = match

    target = class_by_name[class_name]

    def _fmt(sym: dict) -> dict:
        return {
            "name": sym["name"],
            "file": sym.get("file", ""),
            "line": sym.get("line", 0),
            "signature": sym.get("signature", ""),
        }

    # Ancestors: walk up via _parse_bases, BFS
    ancestors: list[dict] = []
    visited_up: set[str] = {class_name}
    queue: deque = deque(_parse_bases(target.get("signature", "")))
    while queue:
        base_name = queue.popleft()
        if base_name in visited_up:
            continue
        visited_up.add(base_name)
        if base_name in class_by_name:
            sym = class_by_name[base_name]
            ancestors.append(_fmt(sym))
            queue.extend(_parse_bases(sym.get("signature", "")))
        else:
            # External base (not in index) — record name only
            ancestors.append({"name": base_name, "file": "(external)", "line": 0, "signature": ""})

    # Descendants: walk down via children_of, BFS
    descendants: list[dict] = []
    visited_down: set[str] = {class_name}
    queue = deque(children_of.get(class_name, []))
    while queue:
        child_name = queue.popleft()
        if child_name in visited_down:
            continue
        visited_down.add(child_name)
        if child_name in class_by_name:
            sym = class_by_name[child_name]
            descendants.append(_fmt(sym))
            queue.extend(children_of.get(child_name, []))

    elapsed = (time.perf_counter() - start) * 1000
    return {
        "repo": f"{owner}/{name}",
        "class": _fmt(target),
        "ancestor_count": len(ancestors),
        "descendant_count": len(descendants),
        "ancestors": ancestors,
        "descendants": descendants,
        "_meta": {"timing_ms": round(elapsed, 1)},
    }
