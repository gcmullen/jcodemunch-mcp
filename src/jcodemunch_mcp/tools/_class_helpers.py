"""Shared class-base resolution helpers.

Single source of truth for the dual-path dispatch that resolves a class
symbol's base classes / interfaces:

  * Tcl class symbols carry ``parent_classes`` (list of {"name", "line"}
    dicts) populated by the Tcl bridge into the ``jcm_tcl_extensions``
    side-table.
  * Other languages (Python, JS, Java, C#, Ruby, Go, ...) encode
    inheritance in the symbol's ``signature`` string; ``_parse_bases()``
    extracts base names via regex.

Both paths are correct for their language scope.  This module exists so
``get_class_hierarchy``, ``find_references`` and ``get_call_hierarchy``
all agree on the dispatch — consolidating here prevents the cross-
language base-code regression that was repaired earlier in P1.3.
"""

from __future__ import annotations

import re

# Patterns to extract base class / interface names from signatures.
# Cross-language path for non-Tcl class symbols (Python, JS, Java, C#,
# Ruby, Go, ...).  Tcl class symbols carry parent_classes via the
# jcm_tcl_extensions side-table; this is the indexed-data shape for
# everything else.
_EXTENDS_RE = re.compile(
    r'\bextends\s+([\w$][\w$,\s]*?)(?=\s+implements|\s*[{(<]|$)', re.IGNORECASE
)
_IMPLEMENTS_RE = re.compile(
    r'\bimplements\s+([\w$][\w$,\s]*?)(?=\s*[{(<]|$)', re.IGNORECASE
)
# Python / Ruby style: class Foo(Bar, Baz)
_PAREN_BASES_RE = re.compile(r'\bclass\s+\w[\w$]*\s*\(([^)]+)\)')


def _parse_bases(signature: str) -> list[str]:
    """Extract base class / interface names from a class signature.

    Cross-language extractor: Python, JavaScript, Java, C#, Ruby, Go.
    Tcl class symbols use parent_classes from the side-table instead;
    see ``get_bases()`` for the dispatch.
    """
    bases: list[str] = []

    # extends Foo, Bar
    m = _EXTENDS_RE.search(signature)
    if m:
        bases += [n.strip() for n in m.group(1).split(",") if n.strip()]

    # implements Foo, Bar
    m = _IMPLEMENTS_RE.search(signature)
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


def get_bases(symbol: dict) -> list[str]:
    """Extract base class names for a class symbol.

    Two language-scoped paths:
      - Tcl class symbols carry ``parent_classes`` populated by the Tcl
        bridge into the ``jcm_tcl_extensions`` side-table.  Read from
        there when present.
      - Other languages (Python, JS, Java, C#, Ruby, Go, ...) encode
        inheritance in the symbol's signature string; :func:`_parse_bases`
        extracts base names via regex.

    Both paths are correct for their language scope.  This is NOT the
    Tcl-bridge architectural fallback retired during P1.3 (single
    parsing substrate per §0.2 rule 1) — that ruling applied to the
    bridge's parser layer, not to cross-language base-code that has
    always served Python / JS / etc.
    """
    # Tcl path: side-table data populated by the Tcl bridge
    pc = symbol.get("parent_classes") or []
    if pc:
        return [
            entry["name"]
            for entry in pc
            if isinstance(entry, dict) and entry.get("name")
        ]
    # Cross-language path: regex on signature
    return _parse_bases(symbol.get("signature", ""))


def collect_class_kin(symbols: list[dict], class_name: str) -> set[str]:
    """Return all class names kin to *class_name* — ancestors + descendants.

    Walks both directions transitively via the dual-path :func:`get_bases`
    dispatch.  Used by call-hierarchy resolution: when a method is
    dispatched on a class, runtime dispatch could land on any same-named
    method on an ancestor (super-class fallback) or descendant (override).

    Returns a set of class names *excluding* ``class_name`` itself.
    Returns an empty set when ``class_name`` is not a class symbol in
    the index.

    Cross-language: works for Tcl (side-table parent_classes) and other
    languages (signature-derived bases) without special-casing.
    """
    class_syms = [
        s for s in symbols if s.get("kind") in ("class", "type") and s.get("name")
    ]
    if not class_syms:
        return set()

    by_name: dict[str, dict] = {}
    children_of: dict[str, list[str]] = {}
    for s in class_syms:
        nm = s["name"]
        by_name.setdefault(nm, s)
    for s in class_syms:
        for base in get_bases(s):
            children_of.setdefault(base, []).append(s["name"])

    if class_name not in by_name:
        return set()

    from collections import deque
    kin: set[str] = set()

    # Ancestors (BFS up)
    visited_up: set[str] = {class_name}
    queue: deque = deque(get_bases(by_name[class_name]))
    while queue:
        base = queue.popleft()
        if base in visited_up:
            continue
        visited_up.add(base)
        kin.add(base)
        if base in by_name:
            queue.extend(get_bases(by_name[base]))

    # Descendants (BFS down)
    visited_down: set[str] = {class_name}
    queue = deque(children_of.get(class_name, []))
    while queue:
        child = queue.popleft()
        if child in visited_down:
            continue
        visited_down.add(child)
        kin.add(child)
        queue.extend(children_of.get(child, []))

    kin.discard(class_name)
    return kin
