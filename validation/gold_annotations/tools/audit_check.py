#!/usr/bin/env python3
"""Per-§8 audit-vs-output cross-check for a single annotation JSON file.

Usage: audit_check.py <annotation.json>
Prints a JSON object {violations: [...], symbols: N, callees: N, audit_entries: {...}}.
Exit 0 = clean, 1 = violations found.
"""
import json
import sys
from pathlib import Path


def check(annotation: dict) -> list[str]:
    violations: list[str] = []

    # --- Top-level shape ---
    required_top = {"file", "language", "symbols", "file_level", "compliance_audit"}
    # v1.2+ adds optional `schema_version`. Older raws lack it; either is accepted.
    allowed_top = required_top | {"schema_version"}
    top_keys = set(annotation.keys())
    extra_top = top_keys - allowed_top
    missing_top = required_top - top_keys
    if missing_top:
        violations.append(f"missing top-level keys: {sorted(missing_top)}")
    if extra_top:
        violations.append(f"extra top-level keys: {sorted(extra_top)}")

    if annotation.get("language") not in {"tcl", "itcl", "tk", "itk"}:
        violations.append(f"language not in valid set: {annotation.get('language')!r}")

    symbols = annotation.get("symbols", [])
    file_level = annotation.get("file_level", {})
    audit = annotation.get("compliance_audit", {})

    # --- Symbol shape ---
    sym_required = {
        "qualified_name", "line", "end_line", "kind", "visibility",
        "parent_classes", "package_requires", "package_provides",
        "imports", "callees", "unresolved_dispatches",
    }
    # v1.3 adds optional `args` and `arity` (populated for callable kinds).
    sym_allowed = sym_required | {"args", "arity"}
    valid_kinds = {
        "proc", "method", "class_method", "constructor", "destructor",
        "class", "namespace", "coroutine", "configbody", "lambda",
    }
    valid_vis = {"public", "private", "protected", None}
    valid_callee_kinds = {
        "static", "ensemble", "callback", "qualified",
        "method_dispatch", "lambda", "unresolved",
    }
    # v1.3 callees may carry an optional `receiver_hint` (required on method_dispatch).
    callee_allowed_keys = {"name", "line", "kind", "note", "receiver_hint"}

    for i, sym in enumerate(symbols):
        keys = set(sym.keys())
        missing = sym_required - keys
        extra = keys - sym_allowed
        ident = sym.get("qualified_name", f"<symbols[{i}]>")
        if missing:
            violations.append(f"symbol {ident}: missing keys {sorted(missing)}")
        if extra:
            violations.append(f"symbol {ident}: extra keys {sorted(extra)}")
        if sym.get("kind") not in valid_kinds:
            violations.append(f"symbol {ident}: invalid kind {sym.get('kind')!r}")
        if sym.get("visibility") not in valid_vis:
            violations.append(f"symbol {ident}: invalid visibility {sym.get('visibility')!r}")
        # package_provides must be list of {name, version}
        for pp in sym.get("package_provides", []):
            if not isinstance(pp, dict) or "name" not in pp or "version" not in pp:
                violations.append(f"symbol {ident}: bad package_provides entry {pp!r}")
        # array fields never null/absent
        for arr in ("parent_classes", "package_requires", "package_provides",
                    "imports", "callees", "unresolved_dispatches"):
            if not isinstance(sym.get(arr), list):
                violations.append(f"symbol {ident}: {arr} must be array")
        # callees shape
        for c in sym.get("callees", []):
            for k in ("name", "line", "kind"):
                if k not in c:
                    violations.append(f"symbol {ident}: callee missing key {k}: {c!r}")
            if c.get("kind") not in valid_callee_kinds:
                violations.append(f"symbol {ident}: invalid callee kind {c.get('kind')!r}")

    # --- §7.1 / §6.9 callee denylist (callees[].name must not be a Tier-1/2/3
    # control-flow keyword, ensemble dispatcher, or script-accepting dispatcher).
    # REVIEW NOTE: this denylist is the minimal set surfaced by the Phase 1 vs
    # pre-disasm oracle comparison (see dev-docs/verdicts/PHASE1_VS_GOLDEN_SET_COMPARISON.md).
    # Re-evaluate the membership of `_DENY_TIER2_SINGLE`, `_DENY_TIER2_PREFIXES`,
    # `_DENY_DISPATCHERS`, and `_DENY_TIER1` after Phase 2 corpora land — Phase 2
    # files may surface additional Tier-2 names (`encoding`, `binary`, …) or
    # dispatcher forms (`socket -server`, `coroutine`) that warrant inclusion
    # or carve-outs.
    _DENY_TIER1 = {
        "if", "else", "elseif", "while", "for", "foreach", "switch",
        "catch", "try", "on", "trap", "finally", "return", "break",
        "continue", "yield", "yieldto",
    }
    _DENY_TIER2_SINGLE = {
        "set", "incr", "unset", "lappend", "lassign", "lset", "lreplace",
        "llength", "lrange", "lsearch", "lsort", "lindex", "linsert",
        "lrepeat", "lreverse", "split", "join", "format", "scan", "expr",
        "regexp", "regsub", "subst",
    }
    _DENY_TIER3 = {"puts", "gets", "read", "error", "throw"}
    _DENY_TIER2_PREFIXES = {
        "string", "dict", "info", "array", "clock", "chan", "file",
        "binary", "namespace", "package", "encoding",
    }
    _DENY_DISPATCHERS = {
        "after", "bind", "fileevent",
        "trace add variable", "trace add command", "trace add execution",
    }
    # Denylists apply only to command-position kinds (the literal first word of a
    # command). Method dispatches, callback names, lambda references, and unresolved
    # entries are method/script names dispatched on objects — `read`/`set`/etc. that
    # appear there are method names that happen to alias Tcl built-ins, not the
    # built-ins themselves, so §7.1 / §6.9 filters do not apply.
    _COMMAND_POSITION_KINDS = {"static", "qualified", "ensemble"}
    for sym in symbols:
        ident = sym.get("qualified_name", "<unknown>")
        for c in sym.get("callees", []):
            name = c.get("name", "")
            if not isinstance(name, str) or not name:
                continue
            if c.get("kind") not in _COMMAND_POSITION_KINDS:
                continue
            ln = c.get("line")
            first = name.split()[0]
            if name in _DENY_TIER1:
                violations.append(
                    f"symbol {ident}: callee {name!r}@{ln} is on §7.1 Tier-1 "
                    f"denylist (control-flow keyword — walk body, do not record)"
                )
            elif name in _DENY_TIER2_SINGLE:
                violations.append(
                    f"symbol {ident}: callee {name!r}@{ln} is on §7.1 Tier-2 "
                    f"denylist (value/list manipulation)"
                )
            elif name in _DENY_TIER3:
                violations.append(
                    f"symbol {ident}: callee {name!r}@{ln} is on §7.1 Tier-3 "
                    f"denylist (I/O and error)"
                )
            elif name in _DENY_DISPATCHERS:
                violations.append(
                    f"symbol {ident}: callee {name!r}@{ln} is a §6.9 "
                    f"script-accepting dispatcher (record the SCRIPT's callee, "
                    f"not the dispatcher)"
                )
            elif " " in name and first in _DENY_TIER2_PREFIXES:
                violations.append(
                    f"symbol {ident}: callee {name!r}@{ln} starts with "
                    f"§7.1 Tier-2 ensemble prefix {first!r}"
                )

    # --- file_level shape ---
    fl_required = {"package_requires", "package_provides", "imports", "callees"}
    fl_keys = set(file_level.keys())
    if fl_required - fl_keys:
        violations.append(f"file_level missing keys: {sorted(fl_required - fl_keys)}")
    if fl_keys - fl_required:
        violations.append(f"file_level extra keys: {sorted(fl_keys - fl_required)}")

    # --- compliance_audit required sections (v1.2 baseline) ---
    audit_required_v12 = {
        "method_declarations", "flag_options_seen", "tier3_keyword_appearances",
        "eval_sites_seen", "inherit_or_superclass_lines", "package_lines",
    }
    # v1.3 added forcing-function sections (Tier 1, Tier 2, script-accepting sites).
    # OPTIONAL for backwards compatibility with v1.2 raws — if present, validated
    # and cross-checked; if absent, silently OK. New v1.3 dispatches MUST include
    # these per the v1.3 prompt template.
    audit_optional_v13 = {
        "tier1_keyword_appearances", "tier2_ensemble_appearances",
        "script_accepting_sites_seen",
    }
    audit_required = audit_required_v12
    audit_keys = set(audit.keys())
    if audit_required - audit_keys:
        violations.append(f"compliance_audit missing sections: {sorted(audit_required - audit_keys)}")
    for s in audit_required:
        v = audit.get(s)
        if not isinstance(v, list):
            violations.append(f"compliance_audit.{s} must be array")
    for s in audit_optional_v13:
        if s in audit and not isinstance(audit[s], list):
            violations.append(f"compliance_audit.{s} must be array (when present)")

    # --- §8.1.1 Tier 3 keyword consistency ---
    for t3 in audit.get("tier3_keyword_appearances", []):
        kw = t3.get("keyword")
        ln = t3.get("line")
        for sym in symbols:
            for c in sym.get("callees", []):
                if c.get("line") == ln and c.get("name") == kw:
                    violations.append(
                        f"Tier3 contradiction: audit excludes {kw}@{ln} "
                        f"but {sym.get('qualified_name')} has it in callees"
                    )

    # --- §8.1.3 Method declaration consistency ---
    sym_by_line = {s.get("line"): s for s in symbols}
    method_kinds = {"method", "class_method", "constructor", "destructor",
                    "configbody", "proc", "lambda"}
    for md in audit.get("method_declarations", []):
        ln = md.get("line")
        match = sym_by_line.get(ln)
        if match is None:
            # not all method_declarations correspond to a symbol-at-this-line:
            # some annotators record the declaration line, others record the body line.
            # Tolerate ±2-line drift before flagging.
            close = [s for s in symbols if isinstance(s.get("line"), int)
                     and isinstance(ln, int) and abs(s["line"] - ln) <= 2
                     and s.get("kind") in method_kinds]
            if not close:
                violations.append(f"Method audit @line {ln} has no matching symbol")
                continue
            match = close[0]
        if match.get("kind") != md.get("kind_recorded"):
            violations.append(
                f"kind mismatch @line {ln}: audit {md.get('kind_recorded')!r} "
                f"vs symbol {match.get('kind')!r}"
            )
        audit_vis = md.get("visibility_recorded")
        if audit_vis == "null":
            audit_vis = None
        if match.get("visibility") != audit_vis:
            violations.append(
                f"visibility mismatch @line {ln}: audit {audit_vis!r} "
                f"vs symbol {match.get('visibility')!r}"
            )

    # --- §8.1.4 Inherit consistency ---
    for ih in audit.get("inherit_or_superclass_lines", []):
        parent = ih.get("parent_class")
        ln = ih.get("line")
        in_parent_classes = any(
            sym.get("kind") == "class" and parent in sym.get("parent_classes", [])
            for sym in symbols
        )
        if not in_parent_classes:
            violations.append(
                f"Inherit audit {parent}@{ln}: not in any class's parent_classes"
            )
        for sym in symbols:
            for c in sym.get("callees", []):
                if c.get("name") == parent and c.get("line") == ln:
                    violations.append(
                        f"Inherit contradiction: {parent}@{ln} found in callees "
                        f"({sym.get('qualified_name')})"
                    )

    # --- §8.1.5 Eval site consistency ---
    tier2 = {
        "set", "incr", "unset", "lappend", "lassign", "lset", "lreplace",
        "llength", "lrange", "lsearch", "lsort", "lindex", "linsert",
        "lrepeat", "lreverse", "split", "join", "format", "scan", "expr",
        "regexp", "regsub", "subst",
        "string", "dict", "info", "array", "clock", "chan", "file", "binary",
    }
    tier3 = {"puts", "gets", "read", "error", "throw"}
    for es in audit.get("eval_sites_seen", []):
        ln = es.get("line")
        callee_rec = es.get("callee_recorded", "")
        token = (callee_rec or "").split()[0] if callee_rec else ""
        if callee_rec in ("?", "", None):
            continue
        # Tier 2 / Tier 3 D1 collapses are intentionally not surfaced as callees
        if token in tier2 or token in tier3:
            continue
        # Annotator notes like "(Tier 2 not recorded)" or "not recorded"
        rec_lower = (callee_rec or "").lower()
        if "not recorded" in rec_lower or "tier 2" in rec_lower or "tier 3" in rec_lower:
            continue
        found = False
        for sym in symbols:
            for c in sym.get("callees", []):
                if c.get("line") == ln and c.get("name") == token:
                    found = True
                    break
            for u in sym.get("unresolved_dispatches", []):
                if u.get("line") == ln:
                    found = True
                    break
            if found:
                break
        for c in file_level.get("callees", []):
            if c.get("line") == ln and c.get("name") == token:
                found = True
                break
        if not found:
            decision = (es.get("decision") or "").lower()
            if "tier 2" in decision or "not recorded" in decision:
                pass
            else:
                violations.append(
                    f"Eval site @line {ln}: callee_recorded={callee_rec!r} "
                    f"not found in callees or unresolved_dispatches"
                )

    # --- §8.1.6 Package-line consistency ---
    for pl in audit.get("package_lines", []):
        cmd = pl.get("command")
        val = pl.get("value", "")
        field = pl.get("field_populated", "")
        ln = pl.get("line")
        # Strip leading "package require"/"package provide"/"source" if annotator
        # interpreted "verbatim" as the full command line rather than the bare name.
        stripped = val or ""
        for prefix in ("package require ", "package provide ", "source "):
            if stripped.startswith(prefix):
                stripped = stripped[len(prefix):]
                break
        name_token = stripped.split()[0] if stripped else ""
        found = False
        if field == "package_requires":
            if name_token in file_level.get("package_requires", []):
                found = True
            for sym in symbols:
                if name_token in sym.get("package_requires", []):
                    found = True
        elif field == "package_provides":
            for entry in file_level.get("package_provides", []):
                if entry.get("name") == name_token:
                    found = True
            for sym in symbols:
                for entry in sym.get("package_provides", []):
                    if entry.get("name") == name_token:
                        found = True
        elif field == "imports":
            if name_token in file_level.get("imports", []):
                found = True
            for sym in symbols:
                if name_token in sym.get("imports", []):
                    found = True
        if not found:
            violations.append(
                f"Package-line @line {ln} {cmd} {val!r} not found in {field}"
            )

    return violations


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: audit_check.py <annotation.json>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    with path.open() as fh:
        ann = json.load(fh)
    violations = check(ann)
    summary = {
        "file": ann.get("file"),
        "symbols": len(ann.get("symbols", [])),
        "callees_total": sum(len(s.get("callees", [])) for s in ann.get("symbols", [])),
        "audit_section_sizes": {
            k: len(ann.get("compliance_audit", {}).get(k, []))
            for k in (
                "method_declarations", "flag_options_seen",
                "tier3_keyword_appearances", "eval_sites_seen",
                "inherit_or_superclass_lines", "package_lines",
            )
        },
        "violations": violations,
        "clean": not violations,
    }
    print(json.dumps(summary, indent=2))
    return 0 if not violations else 1


if __name__ == "__main__":
    sys.exit(main())
