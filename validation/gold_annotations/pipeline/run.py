#!/usr/bin/env python3
"""jcm-gold pipeline — the deterministic shell engine for gold annotation runs.

The LLM (driver) is responsible for the three LLM-dispatch points (annotator A,
annotator B, arbiter) via the Agent tool. The pipeline is responsible for
everything else: staging, prompt building, unwrapping, auditing, gold merging,
arbiter staging, verdict application, summary.

Per-run state lives at /tmp/jcm-gold/<run_id>/ to avoid clashes between
concurrent runs. Persistent artifacts go to validation/gold_annotations/<conv>/<tcl>/<corpus>-<sha>/.

Phases (each emits structured JSON with `next_step.action` for the driver):

  prepare <file_path...> [--convention PATH] [--storage-prefix PREFIX]
    → stages sources, builds real prompts, fills meta-prompts, writes prepared.json.
    next_step.action = "dispatch_annotators"

  post-annotate <run_id>
    → unwraps wrapped JSONs from /tmp/jcm-gold/<run_id>/dispatches/,
      audits each raw, routes to corpus dirs, builds gold + discrepancies,
      stages arbiter prompts for files with non-empty discrepancies.
    next_step.action = "dispatch_arbiters" | "summarize"

  post-arbitrate <run_id>
    → reads arbiter outputs from /tmp/jcm-gold/<run_id>/arbiter/,
      validates + saves to corpus dir, applies verdicts to produce corrected_gold.
    next_step.action = "summarize"

  summary <run_id>
    → prints the run summary table (files processed, disputes, verdict split,
      review.json escalations, audit failures).
    next_step.action = "none"

Failure handling:
- Schema/audit violations on an annotator raw → marked for retry-once (the driver
  re-dispatches that annotator); second failure writes <basename>.review.json
  and skips the file's pair.
- Missing wrapped JSON at expected path → review.json with failure_mode=missing_output.
- Conversation never workarounds a failure. Fix the pipeline.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOLS = REPO_ROOT / "validation/gold_annotations/tools"
META_PROMPTS = Path(__file__).resolve().parent / "meta_prompts"
META_PROMPT_TEMPLATE_VERSION = "v1.0"

DEFAULT_CONVENTION = REPO_ROOT / "dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md"
DEFAULT_STORAGE_PREFIX = "validation/gold_annotations/conv-v1.0/tcl-8.6"


# ---------- helpers ----------


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_cmd(argv: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    r = subprocess.run(argv, cwd=str(cwd) if cwd else None, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def utcnow_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def generate_run_id() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S_") + secrets.token_hex(3)


def run_dir_for(run_id: str) -> Path:
    return Path(f"/tmp/jcm-gold/{run_id}")


def parse_convention_version(convention_path: Path) -> str:
    """Pull `**Version:** X.Y` from the convention doc header."""
    for line in convention_path.read_text().splitlines()[:20]:
        m = line.strip()
        if m.lower().startswith("**version:**"):
            return m.split(":", 1)[1].strip().lstrip("*").strip()
    return "unknown"


def infer_corpus(source_path: Path) -> tuple[str, str, str]:
    """Infer (corpus_name, corpus_root_dir, commit_or_version) from a source file path.

    Walks up looking for one of:
      1. A `.git` directory → use git HEAD sha. corpus name = `bluice-<repo-dirname>`
         when under /home/giles/bluice/, otherwise just the repo dirname.
      2. A `.tcl-corpus.json` marker file (non-git snapshots, e.g. vendored Tcllib
         or BWidget). Marker shape: `{"name": "<corpus-name>", "version": "<id>"}`.
         The marker's directory becomes the corpus root; `version` stands in for
         the commit sha (recorded verbatim in provenance).

    Whichever marker is hit FIRST in the upward walk wins, which lets nested
    sub-corpora (e.g. tcl-corpus/snit/, tcl-corpus/tcllib/) each carry their own
    `.tcl-corpus.json` and be addressed independently.
    """
    p = source_path.resolve()
    for parent in [p.parent, *p.parents]:
        if (parent / ".git").exists():
            repo_dir = parent
            rel = parent.parent.name if parent.parent.name == "bluice" else None
            corpus = f"bluice-{repo_dir.name}" if rel == "bluice" else repo_dir.name
            commit = head_sha(str(repo_dir))
            return corpus, str(repo_dir), commit
        marker = parent / ".tcl-corpus.json"
        if marker.exists():
            cfg = json.loads(marker.read_text())
            name = cfg.get("name")
            version = cfg.get("version") or cfg.get("commit") or "unspecified"
            if not name:
                raise ValueError(f"{marker} missing required 'name' field")
            return name, str(parent), version
    raise ValueError(f"no .git or .tcl-corpus.json found above {source_path}")


def head_sha(repo_dir: str) -> str:
    rc, stdout, stderr = run_cmd(["git", "-C", repo_dir, "rev-parse", "HEAD"])
    if rc != 0:
        raise RuntimeError(f"git rev-parse failed for {repo_dir}: {stderr}")
    return stdout.strip()


def jcm_head_sha() -> str:
    return head_sha(str(REPO_ROOT))


def _short_commit(source_sha: str) -> str:
    """Return a short id for the corpus dir suffix.

    For git SHAs (all hex, >=7 chars) use the standard 7-char prefix.
    For non-SHA version strings (e.g. "tcllib-1.21-snapshot-2026-05-16" from
    a .tcl-corpus.json marker), preserve the full string — truncating to 7
    chars would mangle the version label.
    """
    import re as _re
    if _re.fullmatch(r"[0-9a-f]{7,}", source_sha or ""):
        return source_sha[:7]
    return source_sha or "unspecified"


def corpus_dir_for(storage_prefix: str, corpus: str, source_sha: str) -> Path:
    """Resolve a corpus directory under validation/gold_annotations/.

    `storage_prefix` is the version+interpreter slug (e.g. "conv-v1.3/tcl-8.6"),
    NOT a full path. The validation/gold_annotations/ base is anchored here so
    callers can't accidentally route output to the project root.
    """
    return REPO_ROOT / "validation/gold_annotations" / storage_prefix / f"{corpus}-{_short_commit(source_sha)}"


# ---------- prepare ----------


def cmd_prepare(args) -> int:
    run_id = generate_run_id()
    rd = run_dir_for(run_id)
    (rd / "sources").mkdir(parents=True, exist_ok=True)
    (rd / "dispatches").mkdir(parents=True, exist_ok=True)
    (rd / "arbiter").mkdir(parents=True, exist_ok=True)

    convention_path = Path(args.convention).resolve()
    convention_version = parse_convention_version(convention_path)
    rc, conv_commit, _ = run_cmd(["git", "-C", str(REPO_ROOT), "rev-parse", "--short=7", "HEAD"])
    conv_commit = conv_commit.strip() if rc == 0 else "unknown"

    # Enrich each file with corpus + commit
    files = []
    for src_str in args.files:
        src = Path(src_str).resolve()
        if not src.exists():
            print(f"error: source not found: {src}", file=sys.stderr)
            return 2
        corpus, repo_dir, commit = infer_corpus(src)
        files.append({
            "basename": src.name,
            "source_path": str(src),
            "corpus": corpus,
            "source_corpus_commit": commit,
        })

    files_list_path = rd / "files_list.json"
    files_list_path.write_text(json.dumps(files, indent=2))

    # Run batch_plan.py --stage
    plan_path = rd / "batch_plan.json"
    rc, _, err = run_cmd([
        "python3", str(TOOLS / "batch_plan.py"),
        "--files-list", str(files_list_path),
        "--stage", "--stage-dir", str(rd / "sources"),
        "--out", str(plan_path),
    ])
    if rc != 0:
        print(f"error: batch_plan.py failed: {err}", file=sys.stderr)
        return rc
    plan = json.loads(plan_path.read_text())

    # Per batch: build real prompt + fill meta-prompts
    meta_template = (META_PROMPTS / "annotator_subagent.md").read_text()
    # Extract just the body (after the --- marker)
    if "---\n\n" in meta_template:
        meta_body = meta_template.split("---\n\n", 1)[1]
    else:
        meta_body = meta_template

    started = utcnow_iso()
    batches_out = []
    for batch in plan:
        bid = batch["batch_id"]
        anon_args = []
        for f in batch["files"]:
            # Patch anon path to live under the run-scoped dir
            anon = rd / "sources" / f["basename"]
            f["anon_path"] = str(anon)
            anon_args.extend(["--anon-source", f"{f['basename']}:{anon}"])

        prompt_path = rd / "dispatches" / f"batch{bid}.prompt.txt"
        rc, _, err = run_cmd([
            "python3", str(TOOLS / "build_prompt.py"),
            "--convention", str(convention_path),
            "--out", str(prompt_path),
            *anon_args,
        ])
        if rc != 0:
            print(f"error: build_prompt batch{bid}: {err}", file=sys.stderr)
            return rc
        prompt_sha = sha256_file(prompt_path)
        n_files = len(batch["files"])

        a_out = rd / "dispatches" / f"batch{bid}.A.opus.wrapped.json"
        b_out = rd / "dispatches" / f"batch{bid}.B.sonnet.wrapped.json"
        a_meta_path = rd / "dispatches" / f"batch{bid}.A.opus.meta_prompt.txt"
        b_meta_path = rd / "dispatches" / f"batch{bid}.B.sonnet.meta_prompt.txt"

        def fill(role_out: Path) -> str:
            return (meta_body
                    .replace("{PROMPT_PATH}", str(prompt_path))
                    .replace("{OUTPUT_PATH}", str(role_out))
                    .replace("{N_FILES}", str(n_files)))

        a_meta_path.write_text(fill(a_out))
        b_meta_path.write_text(fill(b_out))

        batches_out.append({
            "batch_id": bid,
            "n_files": n_files,
            "files": batch["files"],
            "prompt_path": str(prompt_path),
            "prompt_sha256": prompt_sha,
            "annotator_dispatches": [
                {
                    "model": "opus", "role": "A",
                    "meta_prompt_path": str(a_meta_path),
                    "meta_prompt_sha256": sha256_file(a_meta_path),
                    "output_path": str(a_out),
                },
                {
                    "model": "sonnet", "role": "B",
                    "meta_prompt_path": str(b_meta_path),
                    "meta_prompt_sha256": sha256_file(b_meta_path),
                    "output_path": str(b_out),
                },
            ],
        })

    prepared = {
        "run_id": run_id,
        "run_dir": str(rd),
        "started_at": started,
        "convention_path": str(convention_path),
        "convention_version": convention_version,
        "convention_commit": conv_commit,
        "storage_prefix": args.storage_prefix,
        "meta_prompt_template_version": META_PROMPT_TEMPLATE_VERSION,
        "jcm_head": jcm_head_sha(),
        "batches": batches_out,
        "next_step": {
            "action": "dispatch_annotators",
            "max_in_flight": 6,
            "dispatches": [d for b in batches_out for d in b["annotator_dispatches"]],
        },
    }
    (rd / "prepared.json").write_text(json.dumps(prepared, indent=2))
    print(json.dumps(prepared, indent=2))
    return 0


# ---------- post-annotate ----------


def cmd_post_annotate(args) -> int:
    run_id = args.run_id
    rd = run_dir_for(run_id)
    prepared = json.loads((rd / "prepared.json").read_text())

    finished = utcnow_iso()
    files_report = []
    arbiter_dispatches = []

    arbiter_meta_template = (META_PROMPTS / "arbiter_subagent.md").read_text()
    if "---\n\n" in arbiter_meta_template:
        arbiter_meta_body = arbiter_meta_template.split("---\n\n", 1)[1]
    else:
        arbiter_meta_body = arbiter_meta_template

    skipped_batches = []
    for batch in prepared["batches"]:
        bid = batch["batch_id"]
        # If --skip-missing: defer batches whose wrapped JSONs aren't on disk yet.
        # This lets the orchestrator process annotator waves incrementally.
        if args.skip_missing:
            both_present = all(Path(d["output_path"]).exists() for d in batch["annotator_dispatches"])
            if not both_present:
                skipped_batches.append(bid)
                continue
        # Unwrap A + B
        for dispatch in batch["annotator_dispatches"]:
            role = dispatch["role"]
            suffix = "A.opus" if role == "A" else "B.sonnet"
            wrapped = Path(dispatch["output_path"])
            if not wrapped.exists():
                # Per-file review.json for every file in this batch tied to the missing wrapper
                for f in batch["files"]:
                    corpus_dir = corpus_dir_for(prepared["storage_prefix"], f["corpus"], f["source_corpus_commit"])
                    corpus_dir.mkdir(parents=True, exist_ok=True)
                    review_path = corpus_dir / f"{f['basename']}.review.json"
                    review_path.write_text(json.dumps({
                        "basename": f["basename"],
                        "status": f"annotator_{role}_missing_output",
                        "failure_mode": "wrapped_json_not_written",
                        "expected_path": str(wrapped),
                        "run_id": run_id,
                    }, indent=2) + "\n")
                continue
            # unwrap routes to a tmp dir, then we move into corpus dirs
            tmp_unwrap = rd / "unwrap" / f"batch{bid}_{suffix}"
            tmp_unwrap.mkdir(parents=True, exist_ok=True)
            rc, _, err = run_cmd([
                "python3", str(TOOLS / "unwrap.py"),
                "--in", str(wrapped),
                "--out-dir", str(tmp_unwrap),
                "--suffix", suffix,
                "--repair-missing-lines",
                "--source-dir", str(rd / "sources"),
            ])
            if rc != 0:
                print(f"error: unwrap {suffix} batch{bid}: {err}", file=sys.stderr)
                continue

        # For each file in batch: route raws to corpus dir, audit, build gold, stage arbiter if disputes
        for f in batch["files"]:
            corpus_dir = corpus_dir_for(prepared["storage_prefix"], f["corpus"], f["source_corpus_commit"])
            corpus_dir.mkdir(parents=True, exist_ok=True)
            file_status = {"basename": f["basename"], "corpus": f["corpus"], "audit": {}, "gold_built": False}

            # Route raws
            for suffix in ("A.opus", "B.sonnet"):
                src = rd / "unwrap" / f"batch{bid}_{suffix}" / f"{f['basename']}.{suffix}.raw.json"
                dst = corpus_dir / f"{f['basename']}.{suffix}.raw.json"
                if src.exists():
                    shutil.move(str(src), str(dst))

            a_raw = corpus_dir / f"{f['basename']}.A.opus.raw.json"
            b_raw = corpus_dir / f"{f['basename']}.B.sonnet.raw.json"
            if not (a_raw.exists() and b_raw.exists()):
                file_status["status"] = "missing_raw"
                files_report.append(file_status)
                continue

            # Audit each raw
            for suffix, path in (("A", a_raw), ("B", b_raw)):
                rc, stdout, stderr = run_cmd(["python3", str(TOOLS / "audit_check.py"), str(path)])
                try:
                    a = json.loads(stdout)
                    file_status["audit"][suffix] = {"clean": a.get("clean"), "violations": len(a.get("violations", []))}
                except Exception:
                    file_status["audit"][suffix] = {"clean": False, "error": stderr[:200]}

            # Build gold
            prompt_sha = batch["prompt_sha256"]
            a_meta_sha = batch["annotator_dispatches"][0]["meta_prompt_sha256"]
            b_meta_sha = batch["annotator_dispatches"][1]["meta_prompt_sha256"]
            rc, _, err = run_cmd([
                "python3", str(TOOLS / "build_gold.py"),
                "--a-raw", str(a_raw), "--b-raw", str(b_raw),
                "--source-path", f["source_path"],
                "--corpus", f["corpus"],
                "--out-dir", str(corpus_dir),
                "--basename", f["basename"],
                "--convention-version", prepared["convention_version"],
                "--convention-commit", prepared["convention_commit"],
                "--tcl-version", "8.6",
                "--source-corpus-commit", f["source_corpus_commit"],
                "--dispatch-mode", "anon_read_batched",
                "--head-sha", prepared["jcm_head"],
                "--branch", "tcl-disasm-bridge",
                "--started", prepared["started_at"],
                "--finished", finished,
                "--prompt-hash-a", prompt_sha, "--prompt-hash-b", prompt_sha,
                "--meta-prompt-hash-a", a_meta_sha,
                "--meta-prompt-hash-b", b_meta_sha,
                "--meta-prompt-template-version", prepared["meta_prompt_template_version"],
                "--run-id", run_id,
            ])
            if rc != 0:
                file_status["status"] = "build_gold_failed"
                file_status["error"] = err[-200:]
                files_report.append(file_status)
                continue
            file_status["gold_built"] = True

            # Check disputes
            disc_path = corpus_dir / f"{f['basename']}.discrepancies.json"
            n_disputes = 0
            if disc_path.exists():
                disc = json.loads(disc_path.read_text())
                n_disputes = len(disc.get("per_symbol_callees", []))
            file_status["n_disputes"] = n_disputes

            # Stage arbiter if disputes > 0
            if n_disputes > 0:
                arb_dir = rd / "arbiter"
                stem = f["basename"].replace(".tcl", "")
                arb_source = arb_dir / f["basename"]
                shutil.copyfile(f["source_path"], arb_source)
                arb_a = arb_dir / f"{stem}.A.opus.raw.json"
                arb_b = arb_dir / f"{stem}.B.sonnet.raw.json"
                shutil.copyfile(a_raw, arb_a)
                shutil.copyfile(b_raw, arb_b)
                # disputes
                rc, stdout, stderr = run_cmd([
                    "python3", str(TOOLS / "disputes.py"),
                    "--detect-kind-mismatch", str(disc_path),
                ])
                if rc != 0:
                    file_status["status"] = "disputes_failed"
                    files_report.append(file_status)
                    continue
                disputes_path = arb_dir / f"{f['basename']}.disputes.json"
                disputes_path.write_text(stdout)
                actual_disputes = json.loads(stdout)
                # arbiter prompt
                arb_prompt = arb_dir / f"{stem}.arbiter_prompt.txt"
                rc, _, err = run_cmd([
                    "python3", str(TOOLS / "build_arbiter_prompt.py"),
                    "--convention", prepared["convention_path"],
                    "--basename", f["basename"],
                    "--source", str(arb_source),
                    "--a-raw", str(arb_a), "--b-raw", str(arb_b),
                    "--disputes", str(disputes_path),
                    "--out", str(arb_prompt),
                ])
                if rc != 0:
                    file_status["status"] = "build_arbiter_prompt_failed"
                    files_report.append(file_status)
                    continue
                # fill arbiter meta-prompt
                arb_output = arb_dir / f"{f['basename']}.arbiter_output.json"
                arb_meta_path = arb_dir / f"{stem}.arbiter.meta_prompt.txt"
                arb_meta_filled = (arbiter_meta_body
                                   .replace("{ARBITER_PROMPT_PATH}", str(arb_prompt))
                                   .replace("{OUTPUT_PATH}", str(arb_output))
                                   .replace("{N_DISPUTES}", str(len(actual_disputes)))
                                   .replace("{BASENAME}", f["basename"]))
                arb_meta_path.write_text(arb_meta_filled)
                arbiter_dispatches.append({
                    "basename": f["basename"],
                    "corpus": f["corpus"],
                    "corpus_dir": str(corpus_dir),
                    "meta_prompt_path": str(arb_meta_path),
                    "meta_prompt_sha256": sha256_file(arb_meta_path),
                    "output_path": str(arb_output),
                    "n_disputes": len(actual_disputes),
                })

            files_report.append(file_status)

    out = {
        "run_id": run_id,
        "phase": "post-annotate",
        "finished_at": finished,
        "files": files_report,
        "arbiter_dispatches": arbiter_dispatches,
        "next_step": {
            "action": "dispatch_arbiters" if arbiter_dispatches else "summarize",
            "max_in_flight": 6,
            "dispatches": arbiter_dispatches,
        },
    }
    (rd / "post_annotate.json").write_text(json.dumps(out, indent=2))
    print(json.dumps(out, indent=2))
    return 0


# ---------- post-arbitrate ----------


def cmd_post_arbitrate(args) -> int:
    run_id = args.run_id
    rd = run_dir_for(run_id)
    post_annotate = json.loads((rd / "post_annotate.json").read_text())
    arbiter_dispatches = post_annotate.get("arbiter_dispatches", [])

    results = []
    for d in arbiter_dispatches:
        basename = d["basename"]
        corpus_dir = Path(d["corpus_dir"])
        output_path = Path(d["output_path"])
        if not output_path.exists():
            review_path = corpus_dir / f"{basename}.review.json"
            review_path.write_text(json.dumps({
                "basename": basename,
                "status": "arbiter_missing_output",
                "failure_mode": "arbiter_output_not_written",
                "expected_path": str(output_path),
                "run_id": run_id,
            }, indent=2) + "\n")
            results.append({"basename": basename, "status": "arbiter_missing"})
            continue
        # save_arbiter (pipes the arbiter output JSON into save_arbiter.py)
        arbiter_blob = output_path.read_bytes()
        proc = subprocess.run(
            ["python3", str(TOOLS / "save_arbiter.py"),
             "--out-dir", str(corpus_dir),
             "--basename", basename,
             "--expected-disputes", str(d["n_disputes"])],
            input=arbiter_blob, capture_output=True,
        )
        if proc.returncode != 0:
            results.append({"basename": basename, "status": "save_arbiter_failed", "err": proc.stderr.decode()[:200]})
            continue
        # apply_arbiter
        gold_path = corpus_dir / f"{basename}.gold.json"
        arbiter_path = corpus_dir / f"{basename}.arbiter.json"
        corrected_path = corpus_dir / f"{basename}.corrected_gold.json"
        rc, _, err = run_cmd([
            "python3", str(TOOLS / "apply_arbiter.py"),
            "--gold", str(gold_path),
            "--arbiter", str(arbiter_path),
            "--out", str(corrected_path),
        ])
        if rc != 0:
            results.append({"basename": basename, "status": "apply_arbiter_failed", "err": err[-200:]})
            continue
        # Quick audit of the arbiter
        arb = json.loads(arbiter_path.read_text())
        verdicts = arb.get("verdicts", [])
        null_line = sum(1 for v in verdicts if v.get("line") is None)
        no_just = sum(1 for v in verdicts if not (v.get("justification") or "").strip())
        results.append({
            "basename": basename,
            "status": "applied",
            "summary": arb.get("summary", {}),
            "verdict_count": len(verdicts),
            "null_line": null_line,
            "no_justification": no_just,
            "human_review_recommended": null_line > 0 or no_just > 0,
        })

    out = {
        "run_id": run_id,
        "phase": "post-arbitrate",
        "finished_at": utcnow_iso(),
        "results": results,
        "next_step": {"action": "summarize"},
    }
    (rd / "post_arbitrate.json").write_text(json.dumps(out, indent=2))
    print(json.dumps(out, indent=2))
    return 0


# ---------- summary ----------


def cmd_summary(args) -> int:
    run_id = args.run_id
    rd = run_dir_for(run_id)
    prepared = json.loads((rd / "prepared.json").read_text())
    post_annotate = json.loads((rd / "post_annotate.json").read_text()) if (rd / "post_annotate.json").exists() else {}
    post_arbitrate = json.loads((rd / "post_arbitrate.json").read_text()) if (rd / "post_arbitrate.json").exists() else {}

    total_files = sum(b["n_files"] for b in prepared["batches"])
    gold_built = sum(1 for f in post_annotate.get("files", []) if f.get("gold_built"))
    review_files = []
    # Scan corpus dirs for review.json
    for batch in prepared["batches"]:
        for f in batch["files"]:
            cd = corpus_dir_for(prepared["storage_prefix"], f["corpus"], f["source_corpus_commit"])
            rp = cd / f"{f['basename']}.review.json"
            if rp.exists():
                review_files.append(str(rp))

    # Aggregate arbiter results
    arb_results = post_arbitrate.get("results", [])
    arb_summary = {"a": 0, "b": 0, "both": 0, "neither": 0, "ambiguous": 0, "human_review": 0}
    for r in arb_results:
        s = r.get("summary", {})
        arb_summary["a"] += s.get("a_correct", 0)
        arb_summary["b"] += s.get("b_correct", 0)
        arb_summary["both"] += s.get("both_correct", 0)
        arb_summary["neither"] += s.get("neither_correct", 0)
        arb_summary["ambiguous"] += s.get("convention_ambiguous", 0)
        if r.get("human_review_recommended"):
            arb_summary["human_review"] += 1

    summary = {
        "run_id": run_id,
        "run_dir": str(rd),
        "started_at": prepared.get("started_at"),
        "finished_at": utcnow_iso(),
        "convention_version": prepared.get("convention_version"),
        "convention_commit": prepared.get("convention_commit"),
        "jcm_head": prepared.get("jcm_head"),
        "files_input": total_files,
        "gold_built": gold_built,
        "review_escalations": len(review_files),
        "review_paths": review_files,
        "arbiter_results": arb_summary,
        "next_step": {"action": "none"},
    }
    (rd / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


# ---------- main ----------


def main() -> int:
    ap = argparse.ArgumentParser(prog="run.py")
    sub = ap.add_subparsers(dest="phase", required=True)

    p = sub.add_parser("prepare", help="Stage sources, build prompts, fill meta-prompts.")
    p.add_argument("files", nargs="+", help="Source file paths to annotate.")
    p.add_argument("--convention", default=str(DEFAULT_CONVENTION))
    p.add_argument("--storage-prefix", default=DEFAULT_STORAGE_PREFIX)
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("post-annotate", help="Unwrap + audit + build gold + stage arbiters.")
    p.add_argument("run_id")
    p.add_argument(
        "--skip-missing",
        action="store_true",
        help="Skip batches whose wrapped JSONs aren't on disk yet (for incremental "
        "per-wave processing). Default: write review.json for missing wrappers.",
    )
    p.set_defaults(func=cmd_post_annotate)

    p = sub.add_parser("post-arbitrate", help="Save + apply arbiter verdicts.")
    p.add_argument("run_id")
    p.set_defaults(func=cmd_post_arbitrate)

    p = sub.add_parser("summary", help="Print/write run summary.")
    p.add_argument("run_id")
    p.set_defaults(func=cmd_summary)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
