#!/usr/bin/env python3
"""Apply GOLD_EXPERIMENT_v1.md §6.0 batching rules to a file list.

§6.0 batching policy:
  - A file is "large" if ≥ 400 source lines OR its source byte size ≥ 15 KB.
  - Large files → one file per batch (solo).
  - Otherwise: pack small files into batches such that
      combined source bytes ≤ 25 KB AND batch size ≤ 4 files.

The tool ALSO (optionally) stages each source file to an anonymized path under
/tmp/gold_sources/<basename> so the dispatch pipeline doesn't have to re-stage.
With --stage, the planner copies sources and emits the anon path in each
batch's `anon_path` field.

Input: a JSON or CSV file describing the corpus. JSON format:
    [
      {"basename": "AutoSample.tcl", "source_path": "/home/giles/.../AutoSample.tcl",
       "corpus": "bluice-BluIceWidgets", "source_corpus_commit": "a54fa24..."},
      ...
    ]

CSV format (header required): basename,source_path,corpus,source_corpus_commit

Output (stdout): a JSON batch plan:
    [
      {"batch_id": 1, "n_files": 1, "combined_bytes": 23560, "combined_lines": 744,
       "files": [{"basename": "AutoSample.tcl",
                  "source_path": "/home/.../AutoSample.tcl",
                  "anon_path": "/tmp/gold_sources/AutoSample.tcl",
                  "corpus": "bluice-BluIceWidgets",
                  "source_corpus_commit": "a54fa24...",
                  "source_lines": 744, "source_bytes": 23560}]},
      ...
    ]

The orchestrator iterates the plan; for each batch it builds one prompt
(via `build_prompt.py --anon-source ...`) and dispatches A+B annotators.

Usage:
  batch_plan.py --files-list phase1.json [--stage] [--out plan.json]
  batch_plan.py --files-list phase1.csv  [--stage] [--out plan.json]
"""
import argparse
import csv
import json
import shutil
import sys
from pathlib import Path


LINE_THRESHOLD = 400
BYTE_THRESHOLD = 15 * 1024
COMBINED_BYTE_CAP = 25 * 1024
BATCH_FILE_CAP = 4


def load_files_list(path: Path) -> list[dict]:
    text = path.read_text()
    if path.suffix.lower() == ".json":
        data = json.loads(text)
    else:
        rows: list[dict] = []
        reader = csv.DictReader(text.splitlines())
        for row in reader:
            rows.append(dict(row))
        data = rows
    out = []
    for item in data:
        if not isinstance(item, dict):
            continue
        bn = item.get("basename")
        sp = item.get("source_path")
        co = item.get("corpus")
        sc = item.get("source_corpus_commit") or item.get("commit") or None
        if not bn or not sp or not co:
            print(f"warn: skipping malformed row: {item!r}", file=sys.stderr)
            continue
        out.append({
            "basename": bn,
            "source_path": sp,
            "corpus": co,
            "source_corpus_commit": sc,
        })
    return out


def measure(file_entry: dict) -> dict:
    src = Path(file_entry["source_path"])
    if not src.exists():
        print(f"error: source not found: {src}", file=sys.stderr)
        sys.exit(2)
    content = src.read_bytes()
    n_bytes = len(content)
    n_lines = content.count(b"\n") + (0 if content.endswith(b"\n") else 1)
    return {
        **file_entry,
        "source_bytes": n_bytes,
        "source_lines": n_lines,
        "is_large": n_lines >= LINE_THRESHOLD or n_bytes >= BYTE_THRESHOLD,
    }


def plan_batches(measured: list[dict]) -> list[dict]:
    """Apply §6.0 batching. Large files solo; pack small files greedily by size."""
    large = [m for m in measured if m["is_large"]]
    small = sorted((m for m in measured if not m["is_large"]),
                   key=lambda m: -m["source_bytes"])  # largest-first FFD

    batches: list[list[dict]] = [[m] for m in large]

    for m in small:
        placed = False
        for batch in batches:
            # skip large-file batches
            if batch and batch[0]["is_large"]:
                continue
            combined = sum(f["source_bytes"] for f in batch) + m["source_bytes"]
            if len(batch) + 1 <= BATCH_FILE_CAP and combined <= COMBINED_BYTE_CAP:
                batch.append(m)
                placed = True
                break
        if not placed:
            batches.append([m])

    # Annotate batches with metadata
    plan: list[dict] = []
    for i, batch in enumerate(batches, start=1):
        files: list[dict] = []
        for f in batch:
            files.append({k: v for k, v in f.items() if k != "is_large"})
        plan.append({
            "batch_id": i,
            "n_files": len(batch),
            "combined_bytes": sum(f["source_bytes"] for f in batch),
            "combined_lines": sum(f["source_lines"] for f in batch),
            "files": files,
        })
    return plan


def stage_sources(plan: list[dict], stage_dir: Path) -> None:
    stage_dir.mkdir(parents=True, exist_ok=True)
    for batch in plan:
        for f in batch["files"]:
            src = Path(f["source_path"])
            anon = stage_dir / f["basename"]
            shutil.copyfile(src, anon)
            f["anon_path"] = str(anon)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--files-list", required=True, type=Path,
                    help="Path to a JSON or CSV file describing the corpus.")
    ap.add_argument("--stage", action="store_true",
                    help="Copy each source into /tmp/gold_sources/<basename> and "
                         "record the anon_path in the plan.")
    ap.add_argument("--stage-dir", type=Path, default=Path("/tmp/gold_sources"))
    ap.add_argument("--out", type=Path,
                    help="Optional output path; otherwise emits plan JSON to stdout.")
    args = ap.parse_args()

    files = load_files_list(args.files_list)
    measured = [measure(f) for f in files]
    plan = plan_batches(measured)

    if args.stage:
        stage_sources(plan, args.stage_dir)

    rendered = json.dumps(plan, indent=2)
    if args.out:
        args.out.write_text(rendered + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(rendered + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
