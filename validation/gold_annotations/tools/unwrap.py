#!/usr/bin/env python3
"""Unwrap a `{"files": [...]}` batched annotator response into per-file raw artifacts.

Applies mechanical schema normalization while unwrapping:
- Normalize `language`: lowercase + map known synonyms ("tcl/itcl" -> "itcl").
- Coerce `package_requires` and `imports` from `[{name, version}, ...]` objects to `[name, ...]`.
- Drop class-level `package_requires` / `package_provides` / `imports` that exactly match the file_level (they bled from top-level into the enclosing class symbol).
- Drop misspelled audit keys when the correct key also exists (e.g. `packet_lines` if `package_lines` present).
- Preserve everything else verbatim.

Each entry in `files` is written to `<out_dir>/<basename>.<suffix>.raw.json` where
`<suffix>` is e.g. `A.opus` or `B.sonnet`.

Usage:
  unwrap.py --in <wrapped.json> --out-dir <dir> --suffix A.opus
  cat wrapped.json | unwrap.py --out-dir <dir> --suffix B.sonnet --stdin
"""
import argparse
import json
import sys
from pathlib import Path


VALID_LANGUAGES = {"tcl", "itcl", "tk", "itk"}


def language_from_extension(basename: str) -> str:
    """Pick language by file extension (case-insensitive). Per convention §4: author's
    declared intent wins; content does NOT override."""
    ext = Path(basename).suffix.lower().lstrip(".")
    if ext in VALID_LANGUAGES:
        return ext
    return "tcl"  # default fallback


def normalize_language(annotator_value, basename: str) -> str:
    """Always derive from file extension. Annotator's emitted value is ignored to
    enforce author-intent-by-extension per convention §4."""
    return language_from_extension(basename)


def coerce_string_array(value):
    """Coerce a list to bare package/import names. Handles three malformed shapes:
    - [{name, version}, ...] dicts → flatten to names.
    - ["Pkg 1.2", "Pkg2", ...] strings with embedded version → split on whitespace,
      keep only the leading name token.
    """
    if not isinstance(value, list):
        return []
    out = []
    for item in value:
        if isinstance(item, str):
            # Strip any embedded version suffix (e.g. "DependencyInjector 3.3" → "DependencyInjector")
            name = item.strip().split(None, 1)[0] if item.strip() else item
            out.append(name)
        elif isinstance(item, dict) and "name" in item:
            out.append(item["name"])
        # else: drop silently
    return out


def dedup_class_imports(symbol: dict, file_level: dict) -> None:
    """If a class/namespace symbol has package_requires/imports identical to file_level,
    clear it — those declarations are top-level, not body-local."""
    if symbol.get("kind") not in ("class", "namespace"):
        return
    for field in ("package_requires", "imports"):
        sym_v = symbol.get(field) or []
        fl_v = file_level.get(field) or []
        if sym_v and sym_v == fl_v:
            symbol[field] = []
    # package_provides: same rule
    sym_pp = symbol.get("package_provides") or []
    fl_pp = file_level.get("package_provides") or []
    if sym_pp and sym_pp == fl_pp:
        symbol["package_provides"] = []


def fix_audit_typos(audit: dict) -> None:
    """If a typo'd extra key exists alongside the correct one, drop the typo."""
    typo_pairs = [
        ("packet_lines", "package_lines"),
        ("package_line", "package_lines"),
        ("eval_site_seen", "eval_sites_seen"),
        ("flag_option_seen", "flag_options_seen"),
        ("tier3_keyword_appearance", "tier3_keyword_appearances"),
        ("method_declaration", "method_declarations"),
    ]
    for typo, correct in typo_pairs:
        if typo in audit and correct in audit:
            del audit[typo]


def normalize_annotation(annotation: dict) -> dict:
    """Apply mechanical schema normalization in-place; return the annotation."""
    basename = annotation.get("file", "")
    annotation["language"] = normalize_language(annotation.get("language"), basename)

    file_level = annotation.get("file_level") or {}
    file_level["package_requires"] = coerce_string_array(file_level.get("package_requires"))
    file_level["imports"] = coerce_string_array(file_level.get("imports"))
    # Default-fill required file_level keys per §4 schema (always-array invariant).
    file_level.setdefault("package_provides", [])
    file_level.setdefault("callees", [])
    annotation["file_level"] = file_level

    for sym in annotation.get("symbols", []):
        sym["package_requires"] = coerce_string_array(sym.get("package_requires"))
        sym["imports"] = coerce_string_array(sym.get("imports"))
        dedup_class_imports(sym, file_level)

    audit = annotation.get("compliance_audit") or {}
    if isinstance(audit, dict):
        fix_audit_typos(audit)
        annotation["compliance_audit"] = audit

    return annotation


def repair_missing_lines(annotation: dict, source_text: str) -> int:
    """For each callee with missing/null `line`, infer a source line.

    Strategy (per P3.0 T5):
    1. Search the source within the enclosing symbol's line range for the callee's
       `name`, then for its `note` text. First match wins.
    2. Fallback to the enclosing symbol's `line` if no source match.

    Marks every repaired entry with `line_repaired: true` for provenance.
    Returns the count of repaired callees.
    """
    if not source_text:
        return 0
    src_lines = source_text.splitlines()
    n_lines = len(src_lines)
    repaired = 0
    for sym in annotation.get("symbols", []):
        sym_start = sym.get("line")
        sym_end = sym.get("end_line", sym_start)
        if not isinstance(sym_start, int):
            continue
        if not isinstance(sym_end, int) or sym_end < sym_start:
            sym_end = sym_start
        search_lo = max(0, sym_start - 1)
        search_hi = min(n_lines, sym_end)
        for c in sym.get("callees", []):
            line_val = c.get("line")
            if isinstance(line_val, int):
                continue
            inferred = None
            name = c.get("name") or ""
            note = c.get("note") or ""
            # Primary: search for the callee's name within the symbol body
            if name and name not in ("?",):
                for i in range(search_lo, search_hi):
                    if name in src_lines[i]:
                        inferred = i + 1
                        break
            # Fallback: search for the note text (must be at least 5 chars to avoid noise)
            if inferred is None and len(note) >= 5:
                for i in range(search_lo, search_hi):
                    if note in src_lines[i]:
                        inferred = i + 1
                        break
            # Last resort: use the enclosing symbol's start line
            if inferred is None:
                inferred = sym_start
            c["line"] = inferred
            c["line_repaired"] = True
            repaired += 1
    return repaired


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_path", help="Wrapped JSON file (omit to read stdin)")
    ap.add_argument("--stdin", action="store_true", help="Read wrapped JSON from stdin")
    ap.add_argument("--out-dir", required=True, help="Output directory")
    ap.add_argument("--suffix", required=True, help="Filename suffix, e.g. 'A.opus' or 'B.sonnet'")
    ap.add_argument(
        "--repair-missing-lines",
        action="store_true",
        help="Infer missing/null `line` fields on callees by searching the source "
        "file within each symbol's line range. Requires --source-dir.",
    )
    ap.add_argument(
        "--source-dir",
        help="Directory containing the anonymized source files used during dispatch "
        "(e.g. /tmp/gold_sources/). Required when --repair-missing-lines is set.",
    )
    args = ap.parse_args()

    if args.repair_missing_lines and not args.source_dir:
        print("error: --repair-missing-lines requires --source-dir", file=sys.stderr)
        return 2

    if args.stdin or args.in_path is None:
        wrapped = json.load(sys.stdin)
    else:
        with open(args.in_path) as fh:
            wrapped = json.load(fh)

    files = wrapped.get("files")
    if not isinstance(files, list):
        print("error: expected {'files': [...]} top-level structure", file=sys.stderr)
        return 1

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    written = []
    repair_stats: dict[str, int] = {}
    for ann in files:
        if not isinstance(ann, dict) or "file" not in ann:
            print(f"warn: skipping non-conforming entry: {ann!r}", file=sys.stderr)
            continue
        normalized = normalize_annotation(dict(ann))
        basename = normalized["file"]
        if args.repair_missing_lines:
            source_path = Path(args.source_dir) / basename
            if source_path.exists():
                source_text = source_path.read_text()
                n = repair_missing_lines(normalized, source_text)
                if n > 0:
                    repair_stats[basename] = n
            else:
                print(f"warn: source not found for line-repair: {source_path}", file=sys.stderr)
        out_path = out_dir / f"{basename}.{args.suffix}.raw.json"
        with out_path.open("w") as fh:
            json.dump(normalized, fh)
            fh.write("\n")
        written.append(str(out_path))

    result = {"written": written}
    if args.repair_missing_lines:
        result["line_repairs"] = repair_stats
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
