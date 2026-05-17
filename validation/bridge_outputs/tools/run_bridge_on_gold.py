#!/usr/bin/env python3
"""Bridge driver: run tcl_disasm_bridge.tcl on each of the 37 gold-corpus source files.

Writes raw jcm Symbol JSON to:
  validation/bridge_outputs/conv-v1.3/tcl-8.6/<corpus-sha>/<basename>.bridge.json

Wrapped as: {"basename": <name>, "source_path": <abs>, "jcm_symbols": [...]}

Usage:
  .venv/bin/python3 validation/bridge_outputs/tools/run_bridge_on_gold.py
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BRIDGE_SCRIPT = REPO_ROOT / "src" / "jcodemunch_mcp" / "parser" / "tcl" / "disasm_bridge.tcl"
GOLD_BASE = REPO_ROOT / "validation" / "gold_annotations" / "conv-v1.3" / "tcl-8.6"
OUT_BASE = REPO_ROOT / "validation" / "bridge_outputs" / "conv-v1.3" / "tcl-8.6"
BRIDGE_TIMEOUT = 60  # seconds per file

# ---------------------------------------------------------------------------
# Source-path resolution table
# ---------------------------------------------------------------------------
# Maps corpus subdir prefix -> (source_root, needs_find)
# needs_find=True means basename may be nested; use `find` to locate it.
CORPUS_ROOTS: dict[str, tuple[str, bool]] = {
    "bluice-BluIceWidgets-a54fa24":     ("/home/giles/bluice/BluIceWidgets/", False),
    "bluice-DcsWidgets-575a192":        ("/home/giles/bluice/DcsWidgets/", False),
    "bluice-dcs-lib-tcl-3a09993":       ("/home/giles/bluice/dcs-lib-tcl/main/scripts/", False),
    "bluice-dcss-b5c9866":              ("/home/giles/bluice/dcss/scripts/devices/", False),
    "bluice-dhs-tcl-c39768d":           ("/home/giles/bluice/dhs-tcl/main/scripts/base/", False),
    "git-gui-60046bd":                  ("/home/giles/git/git-gui/lib/", False),
    # tcllib packages: basename matches pkg subdir name
    "tcl-corpus-tcllib-tcllib-1.21-snapshot-2026-05-16": (
        "/home/giles/git/tcl-corpus/tcllib/", True),
    "tcl-corpus-clay-tcllib-1.21-snapshot-2026-05-16": (
        "/home/giles/git/tcl-corpus/tcllib/clay/", False),
    "tcl-corpus-snit-tcllib-1.21-snapshot-2026-05-16": (
        "/home/giles/git/tcl-corpus/tcllib/snit/", True),
    "tcl-corpus-BWidget-BWidget-snapshot-2026-05-16": (
        "/home/giles/git/tcl-corpus/BWidget/", True),
}


def resolve_source_path(corpus: str, basename: str) -> Path:
    """Resolve the absolute source path for a gold file."""
    if corpus not in CORPUS_ROOTS:
        raise FileNotFoundError(
            f"No source root mapping for corpus '{corpus}'. "
            f"Add it to CORPUS_ROOTS in {__file__}."
        )
    root, needs_find = CORPUS_ROOTS[corpus]

    # For tcllib-multi-pkg: pkg subdir = stem of basename (e.g. defer.tcl -> defer/)
    if corpus == "tcl-corpus-tcllib-tcllib-1.21-snapshot-2026-05-16":
        stem = Path(basename).stem  # e.g. "defer"
        candidate = Path(root) / stem / basename
        if candidate.exists():
            return candidate
        needs_find = True  # fall through to find

    if not needs_find:
        candidate = Path(root) / basename
        if candidate.exists():
            return candidate
        # Fall through to find in case of subdirectory nesting
        needs_find = True

    if needs_find:
        result = subprocess.run(
            ["find", root, "-name", basename],
            capture_output=True, text=True, timeout=10
        )
        matches = [l.strip() for l in result.stdout.splitlines() if l.strip()]
        if not matches:
            raise FileNotFoundError(
                f"Source file '{basename}' not found under '{root}'. "
                f"Tried: find {root} -name {basename}"
            )
        # Return first match (most shallow path preferred)
        matches.sort(key=lambda p: len(p))
        return Path(matches[0])

    raise FileNotFoundError(
        f"Could not resolve source path for '{basename}' in corpus '{corpus}'. "
        f"Root tried: {root}"
    )


def run_bridge(source_path: Path) -> tuple[list[dict], str | None]:
    """Run the bridge on a single source file. Returns (symbols, error_msg)."""
    try:
        result = subprocess.run(
            ["tclsh8.6", str(BRIDGE_SCRIPT), str(source_path)],
            capture_output=True,
            text=True,
            timeout=BRIDGE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return [], f"TIMEOUT after {BRIDGE_TIMEOUT}s"
    except FileNotFoundError as e:
        return [], f"tclsh8.6 not found: {e}"

    stderr = result.stderr.strip()
    if result.returncode != 0:
        return [], f"bridge exit {result.returncode}: {stderr[:200]}"

    stdout = result.stdout.strip()
    if not stdout:
        return [], f"bridge produced empty stdout{(' stderr: ' + stderr[:100]) if stderr else ''}"

    try:
        symbols = json.loads(stdout)
    except json.JSONDecodeError as e:
        return [], f"JSON parse error: {e} — stdout[:100]: {stdout[:100]}"

    if not isinstance(symbols, list):
        return [], f"Expected JSON array, got {type(symbols).__name__}"

    return symbols, None


def process_gold_dir(corpus_dir: Path) -> list[dict]:
    """Process all gold files in a corpus subdir. Returns per-file results."""
    corpus = corpus_dir.name
    gold_files = sorted(corpus_dir.glob("*.gold.json"))
    results = []

    out_dir = OUT_BASE / corpus
    out_dir.mkdir(parents=True, exist_ok=True)

    for gold_path in gold_files:
        basename = gold_path.name.replace(".gold.json", "")
        t0 = time.monotonic()

        # Resolve source path
        try:
            source_path = resolve_source_path(corpus, basename)
        except FileNotFoundError as e:
            elapsed = time.monotonic() - t0
            print(f"  [ERROR] {corpus}/{basename}: {e}", file=sys.stderr)
            results.append({
                "corpus": corpus,
                "basename": basename,
                "error": str(e),
                "symbol_count": 0,
                "duration_s": round(elapsed, 3),
            })
            continue

        # Run bridge
        symbols, error = run_bridge(source_path)
        elapsed = time.monotonic() - t0

        if error:
            print(
                f"  [ERROR] {corpus}/{basename}: {error} ({elapsed:.2f}s)",
                file=sys.stderr,
            )
        else:
            print(
                f"  [OK]    {corpus}/{basename}: {len(symbols)} symbols ({elapsed:.2f}s)"
            )

        # Write wrapped output
        out_path = out_dir / f"{basename}.bridge.json"
        payload = {
            "basename": basename,
            "source_path": str(source_path),
            "jcm_symbols": symbols,
        }
        out_path.write_text(json.dumps(payload, indent=2))

        results.append({
            "corpus": corpus,
            "basename": basename,
            "source_path": str(source_path),
            "symbol_count": len(symbols),
            "duration_s": round(elapsed, 3),
            "error": error,
        })

    return results


def main() -> int:
    if not BRIDGE_SCRIPT.exists():
        print(f"ERROR: bridge script not found: {BRIDGE_SCRIPT}", file=sys.stderr)
        return 1

    # Verify tclsh8.6 available
    check = subprocess.run(["tclsh8.6", "-c", "puts [info patchlevel]"],
                           capture_output=True, text=True)
    if check.returncode != 0:
        print("ERROR: tclsh8.6 not available on PATH", file=sys.stderr)
        return 1
    print(f"tclsh8.6 version: {check.stdout.strip()}")

    corpus_dirs = sorted(GOLD_BASE.iterdir())
    total_results = []

    for corpus_dir in corpus_dirs:
        if not corpus_dir.is_dir():
            continue
        print(f"\n--- {corpus_dir.name} ---")
        results = process_gold_dir(corpus_dir)
        total_results.extend(results)

    # Summary
    n_ok = sum(1 for r in total_results if not r.get("error"))
    n_err = sum(1 for r in total_results if r.get("error"))
    n_symbols = sum(r["symbol_count"] for r in total_results)
    total_time = sum(r["duration_s"] for r in total_results)

    print(f"\n=== Bridge driver complete ===")
    print(f"  Files processed : {len(total_results)}")
    print(f"  OK              : {n_ok}")
    print(f"  Errors          : {n_err}")
    print(f"  Total symbols   : {n_symbols}")
    print(f"  Wall time       : {total_time:.1f}s")

    if n_err:
        print("\nErrors:", file=sys.stderr)
        for r in total_results:
            if r.get("error"):
                print(f"  {r['corpus']}/{r['basename']}: {r['error']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
