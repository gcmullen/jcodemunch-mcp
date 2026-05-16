# Gold Experiment v1.0 — LLM-derived call-graph ground truth

**Status:** LOCKED v1.0
**Date:** 2026-05-15
**Convention pinned:** `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` v1.0 (commit `a2747c3`)
**Goal:** Produce two-annotator LLM-derived call-graph annotations for a defined Tcl corpus, with programmatic audit + cross-check + preserved discrepancies. Output is a versioned, reproducible reference dataset for bridge-vs-gold validation.

---

## 1. Mission

For each file in §5, run two independent LLM annotators (Opus + Sonnet) using the v1.0 convention + Shape B audit-required prompt (§9). Validate each annotation via programmatic JSON-schema check (§7) and audit-vs-output cross-check (§8). Where annotators agree, the consensus is the gold entry; where they disagree, both versions are preserved for human analysis. No tiebreaker LLM. Output artifacts (§10) are written under `validation/gold_annotations/conv-v1.0/<corpus>/`. The Phase-1 pilot covers 8 files (§5); pass criteria in §11.

The experiment is **self-contained**: a fresh session with this document plus the convention doc has everything needed to execute. Do **not** consult any other context.

---

## 2. Hard rules

### DO NOT

- Read any file under `dev-docs/verdicts/`, `dev-docs/plans/`, `src/jcodemunch_mcp/parser/`, `validation/probes/`, `validation/oracle/`, `validation/golden_set/`, `validation/planes/` (these contain project-side artifacts that would bias annotators).
- Spawn third-LLM adjudicators or tiebreakers. Discrepancies are kept as data.
- Modify the convention doc or this spec mid-run.
- Add commits, push, or open PRs without explicit user permission.
- Add `Co-Authored-By` trailers.

### DO

- Read this spec and the convention doc.
- Read the source Tcl files listed in §5 from their committed paths (read-only).
- Spawn annotator subagents per §6, one pair (Opus + Sonnet) per file.
- Apply Shape B prompts (§9) verbatim — inline the convention doc into each annotator's prompt.
- Validate every annotation per §7 + §8 before writing gold artifacts.
- Write gold artifacts under §10's paths.
- Record provenance per §10.3 on every artifact.

---

## 3. Reading order for the executing session

1. **This document.**
2. `dev-docs/specs/GOLD_PROMPT_v1.md` (the parametric annotator prompt — the atomic operation invoked per-file).
3. `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (the convention; cached and inlined into every dispatch).
4. Each source file in §5, read once at dispatch time.

Do **not** read anything else. The independence of the gold dataset depends on this.

---

## 4. Locked decisions

| ID | Decision |
|---|---|
| L1 | **Corpus**: 8 files for Phase 1 pilot — see §5. |
| L2 | **Two annotators**: Opus + Sonnet, both with the Shape B audit-required prompt. No tiebreaker LLM. |
| L3 | **Storage**: `validation/gold_annotations/conv-v1.0/<corpus>/<file>.{gold,A.opus.raw,B.sonnet.raw,audit,discrepancies}.json`. Per-file provenance block required (§10.3). |
| L4 | **Discrepancy policy**: preserve both versions as data; no automated reconciliation. Two-tier gold output: CONSENSUS entries (both agreed) + DISCREPANCY entries (both preserved with marker). |
| L5 | **Model version pinning**: none. Aliases `opus` / `sonnet` resolve at run time; provenance captures the resolved IDs. |
| L6 | **Schema strictness**: STRICT. Annotations that violate the §4 schema of the convention doc are rejected; re-run once; second failure escalates to human review log. |
| L7 | **Audit-vs-output cross-check**: REQUIRED. Programmatic post-processing (§8) verifies internal consistency. Failures rejected; re-run once; second failure escalates. |

---

## 5. Phase 1 corpus (8 files)

Selected to span iTcl / Tk / iTk / dcss + small to large.

| # | Source path | Approx. lines | Pattern emphasis |
|---|---|---|---|
| 1 | `/home/giles/bluice/BluIceWidgets/BarcodeView.tcl` | 29 | iTk small — class + inherit + itk_component + `-onClick` callback + `eval LITERAL` |
| 2 | `/home/giles/bluice/dhs-tcl/main/scripts/base/controller/ControllerBase.tcl` | 188 | iTcl medium — method visibility + `eval $obj method` + `eval LITERAL`+ inherit |
| 3 | `/home/giles/bluice/dhs-tcl/main/scripts/base/devices/MotorBase.tcl` | 403 | iTcl large — 40 methods + proc-in-class (`class_method`) + heavy Tier 3 (`puts`/`error`) + qualified FQN calls |
| 4 | `/home/giles/bluice/BluIceWidgets/AutoSample.tcl` | 744 | iTk + custom `class NAME BODY` DSL + heavy itk_component creation + callbacks |
| 5 | `/home/giles/bluice/BluIceWidgets/BeamlineAuthView.tcl` | 530 | iTk widget mid-complexity |
| 6 | `/home/giles/bluice/DcsWidgets/Component.tcl` | 985 | Large iTcl base class — heavy dispatch patterns |
| 7 | `/home/giles/bluice/dcs-lib-tcl/main/scripts/DcssHardwareServer.tcl` | ~110 | iTcl networking — no Tk, eval + callbacks |
| 8 | `/home/giles/bluice/dcss/scripts/devices/MFX_MOTOR.tcl` | ~50 | dcss device script — pure procedural, no class, no Tk |

These paths are read-only corpus. Do not modify.

---

## 6. Pipeline

### 6.0 Batching (orchestrator decision)

The orchestrator groups files into batches before dispatching annotators. Decision rule:

- A file is "large" if ≥ 400 source lines OR ≥ 15 KB. Large files → one file per agent.
- Otherwise, group small files into a batch such that combined source ≤ 25 KB AND batch size ≤ 4 files.

Each batch is sent to two annotators in parallel (Opus + Sonnet). The annotator returns `{"files": [...]}` with one entry per input file (per `GOLD_PROMPT_v1.md`). The orchestrator unwraps and stores per-file raws using each file's basename.

### 6.1 Per-batch atomic operation (the "gold standard for X.tcl" unit)

For each batch in §6.0, dispatch each annotator (Opus + Sonnet) using the **batched anonymized-source-read protocol** defined in `GOLD_PROMPT_v1.md` v1.2. Convention text is inlined into the prompt verbatim; source files are copied to `/tmp/gold_sources/<basename>` and the agent uses the Read tool exactly N times (one per file in the batch) to access them. This is the only blessed dispatch protocol from v1.2 forward; single-shot inline dispatches in existing batch-1 raws are grandfathered.

**Per-batch dispatch (Opus and Sonnet in parallel):**

1. **Stage sources.** For each `(basename, source_path)` in the batch, the orchestrator copies `source_path → /tmp/gold_sources/<basename>` (overwriting only if content differs; idempotent).
2. **Build the prompt** via `tools/build_prompt.py --mode full --convention <path> --anon-source <basename>:<anon_path> [--anon-source ...] --out <prompt-path>`. Convention is inlined; the FILES TO ANNOTATE section lists the anon paths.
3. **Spawn annotator A** (Agent tool, `subagent_type: general-purpose`, `model: opus`, `run_in_background: true`, `prompt:` = the prompt body).
4. **Spawn annotator B** (Agent tool, `subagent_type: general-purpose`, `model: sonnet`, `run_in_background: true`, `prompt:` = the same prompt body).
5. **Wait** for both A and B to complete. Each returns one `{"files":[...]}` JSON object.
6. **Pass each response to `tools/unwrap.py`** — it extracts each `files[i]` and writes `<basename>.A.opus.raw.json` / `<basename>.B.sonnet.raw.json` per file.
7. **Schema check (§7)** on each unwrapped annotation independently. If fail → re-dispatch the batch once. If fail again → log to `<file>.review.json` and skip the offending file's pair.
8. **Audit-vs-output cross-check (§8)** on each annotation independently. Same retry rule.
9. **Cross-annotator comparison (§8.4)** between A and B per file. Classify each callee entry as CONSENSUS or DISCREPANCY.
10. **Write artifacts** per §10 with provenance per §10.3 (record `dispatch_mode: "anon_read_batched"`).
11. **Cleanup.** Remove `/tmp/gold_sources/<basename>` files for this batch after both A and B raws are persisted and audit-clean.

### 6.2 Concurrency batching (across files)

**Maximum 6 annotator subagents in flight at once** (3 files × 2 annotators per file = 6 subagents). Batch the file list accordingly:

- 8 files → 3 batches: [files 1–3], [files 4–6], [files 7–8]
- Each batch: dispatch all 6 (or 4 for the final batch) subagents in one tool-call group; wait for all to complete; run §6.1 steps 6–9 on each file's pair; then proceed to next batch.
- Do NOT dispatch the next batch's subagents until the previous batch's are all complete, to keep total in-flight ≤ 6.

Within a batch, step 6/7 retries (one re-dispatch per annotator) DO count against the 6-cap. If a retry would push in-flight > 6, defer that retry until other batch subagents complete.

### 6.3 Independence

Per-file work is independent. A failure on file X does not affect file Y. If a file's pair fails after retries, it's logged and the batch continues.

---

## 7. Schema strictness (L6)

Annotator output MUST conform to the §4 schema in `TCL_CALLGRAPH_CONVENTION.md`. Validation rules:

1. Top-level object MUST have exactly these keys: `file`, `language`, `symbols`, `file_level`, `compliance_audit`. Extra keys at top level → REJECT.
2. `language` MUST be one of `"tcl"`, `"itcl"`, `"tk"`, `"itk"`. Other values → REJECT.
3. `symbols` MUST be a **flat array** of symbol objects. Nested children arrays inside a symbol → REJECT. (Each symbol stands alone with `qualified_name` carrying the hierarchy.)
4. Each symbol object MUST have these required keys: `qualified_name`, `line`, `end_line`, `kind`, `visibility`, `parent_classes`, `package_requires`, `package_provides`, `imports`, `callees`, `unresolved_dispatches`. Extra keys → REJECT (`name`, `parent`, `signature`, `docstring`, `decorators` are not in the schema).
5. `kind` MUST be one of: `proc`, `method`, `class_method`, `constructor`, `destructor`, `class`, `namespace`, `coroutine`, `configbody`, `lambda`.
6. `visibility` MUST be `"public"` | `"private"` | `"protected"` | `null` (JSON null, not string `"null"`).
7. `package_provides` MUST be an array of objects `{name, version}` (version may be `null`). List of strings → REJECT.
8. `parent_classes`, `package_requires`, `imports`, `callees`, `unresolved_dispatches` MUST be arrays (possibly empty, never `null`).
9. `callees` entries MUST have keys `name`, `line`, `kind`; `note` optional. `kind` ∈ `static|ensemble|callback|qualified|method_dispatch|lambda|unresolved`.
10. `file_level` MUST have exactly these keys: `package_requires`, `package_provides`, `imports`, `callees`. No others.
11. `compliance_audit` MUST have all six required sections per §9 audit schema: `method_declarations`, `flag_options_seen`, `tier3_keyword_appearances`, `eval_sites_seen`, `inherit_or_superclass_lines`, `package_lines`. Each may be empty array, never absent.

On schema violation: re-run once. Second violation → write `<file>.review.json` with the raw output + violation list and skip the pair.

---

## 8. Audit-vs-output cross-check (L7)

A programmatic script (Python ~80 LoC) validates internal consistency between an annotator's `compliance_audit` block and its `symbols/callees/file_level` arrays.

### 8.1 Required cross-checks per annotation

For each annotation, verify:

1. **Tier 3 keyword consistency**: for every entry in `compliance_audit.tier3_keyword_appearances`, the keyword must NOT appear at that line in any symbol's `callees` array. Contradiction → REJECT.
2. **Flag option consistency**: for every entry in `compliance_audit.flag_options_seen` with `value_form: "data_value_not_callback"`, the flag's value must NOT be recorded as a callee at that line. Contradiction → REJECT.
3. **Method declaration consistency**: for every entry in `compliance_audit.method_declarations`, the corresponding symbol in `symbols` (matched by `line`) must have matching `kind` and `visibility`. Contradiction → REJECT.
4. **Inherit consistency**: for every entry in `compliance_audit.inherit_or_superclass_lines`, the named `parent_class` must appear in the enclosing class symbol's `parent_classes` array AND must NOT appear in any `callees` array. Contradiction → REJECT.
5. **Eval site consistency**: for every entry in `compliance_audit.eval_sites_seen`, the `callee_recorded` value must appear in some symbol's `callees` (or `unresolved_dispatches`) at the audit's line. Contradiction → REJECT.
6. **Package line consistency**: for every entry in `compliance_audit.package_lines`, the named value must appear in the declared `field_populated` (either `file_level.<field>` or some symbol's `<field>`). Contradiction → REJECT.

### 8.2 Pseudo-code for the cross-check script

```python
def audit_consistency_check(annotation: dict) -> list[str]:
    """Return list of violation strings; empty list = passes."""
    violations = []
    audit = annotation["compliance_audit"]
    symbols = annotation["symbols"]
    file_level = annotation["file_level"]

    # 8.1.1 Tier 3
    for t3 in audit["tier3_keyword_appearances"]:
        for sym in symbols:
            for c in sym.get("callees", []):
                if c["line"] == t3["line"] and c["name"] == t3["keyword"]:
                    violations.append(
                        f"Tier3 contradiction: audit says {t3['keyword']}@{t3['line']} "
                        f"excluded, but {sym['qualified_name']} has it in callees"
                    )

    # 8.1.2 Data-value flag options
    for fo in audit["flag_options_seen"]:
        if fo["value_form"] != "data_value_not_callback":
            continue
        # No callee should appear at this line whose name matches the flag's value
        # (we don't have the flag's value verbatim, so this is conservative)
        # … (full check elaborated in implementation)

    # 8.1.3 Method declarations
    for md in audit["method_declarations"]:
        match = next((s for s in symbols if s.get("line") == md["line"]), None)
        if match is None:
            violations.append(
                f"Method audit at line {md['line']} has no matching symbol"
            )
            continue
        if match["kind"] != md["kind_recorded"]:
            violations.append(
                f"Kind mismatch at line {md['line']}: "
                f"audit says {md['kind_recorded']}, symbol says {match['kind']}"
            )
        if match["visibility"] != md["visibility_recorded"]:
            # Note: audit may say "null" string; coerce to None
            audit_vis = md["visibility_recorded"]
            if audit_vis == "null":
                audit_vis = None
            if match["visibility"] != audit_vis:
                violations.append(
                    f"Visibility mismatch at line {md['line']}: "
                    f"audit says {audit_vis}, symbol says {match['visibility']}"
                )

    # 8.1.4 Inherit/superclass
    for ih in audit["inherit_or_superclass_lines"]:
        parent = ih["parent_class"]
        found_in_parent_classes = False
        for sym in symbols:
            if sym["kind"] == "class" and parent in sym["parent_classes"]:
                found_in_parent_classes = True
            for c in sym.get("callees", []):
                if c["name"] == parent and c.get("line") == ih["line"]:
                    violations.append(
                        f"Inherit contradiction: {parent}@{ih['line']} found in callees"
                    )
        if not found_in_parent_classes:
            violations.append(
                f"Inherit {parent} declared in audit but not in any parent_classes"
            )

    # 8.1.5 Eval sites: name appears in callees or unresolved_dispatches at line
    # 8.1.6 Package lines: value lands in declared field
    # … (elaborate as in spec)

    return violations
```

### 8.3 On failure

Same retry policy as §7: re-run once; second failure → write `<file>.review.json` and skip the pair.

### 8.4 Cross-annotator comparison

After both A and B pass their independent checks, compute per-symbol agreement:

1. **Symbol set**: compute `(qualified_name, kind)` sets for A and B. 
   - Identical → continue.
   - Different → record symbol-set discrepancy in `<file>.discrepancies.json` and continue with the intersection.
2. **Per-symbol callee Jaccard**: for each symbol present in both, compute Jaccard similarity on the `(name, kind)` set of its `callees`.
3. **Line number drift**: per symbol, compute `|A.line - B.line|`. ±2 lines acceptable.
4. **Classification**:
   - **CONSENSUS callee entry**: both annotators emit a callee with matching `(name, kind)` for the symbol. Take A's line if within ±2 of B; otherwise both lines preserved.
   - **DISCREPANCY callee entry**: callee in A but not B, or vice versa, or `kind` mismatch. Preserve both with markers `source: "A_only" | "B_only" | "kind_mismatch"`.

---

## 9. Annotator prompt template — REFERENCE

The per-file annotator prompt is the **reusable atomic operation** defined in `dev-docs/specs/GOLD_PROMPT_v1.md`. The orchestrator reads that file, substitutes the three placeholders (`{{CONVENTION_DOC}}`, `{{FILENAME}}`, `{{FILE_CONTENT}}`), and dispatches via the Agent tool.

Inputs to substitution:
- `{{CONVENTION_DOC}}` = the full verbatim text of `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (read once at experiment start; cache; inline into every dispatch).
- `{{FILENAME}}` = the basename of the source file (e.g., `AutoSample.tcl`) — NOT the full path. Path strings would leak corpus origin.
- `{{FILE_CONTENT}}` = the verbatim Tcl source text.

Caller-side parameters (Agent tool, not in prompt body):
- `model` = `"opus"` for annotator A, `"sonnet"` for annotator B.
- `subagent_type` = `"general-purpose"`.
- `run_in_background` = `true` (so the orchestrator can manage concurrency per §6.2).

Do **not** re-derive the prompt body — read it from `GOLD_PROMPT_v1.md`. Re-deriving risks drift between this experiment and future experiments that share the prompt.

---

## 10. Output artifacts

### 10.1 Path scheme

The storage path encodes three independent axes: the **convention version** (the rules the LLM applies), the **Tcl interpreter version** the convention assumes, and the **source-corpus commit** (which exact tree of the source repo was annotated). All three matter when comparing results over time:

```
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.gold.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.A.opus.raw.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.B.sonnet.raw.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.audit.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.discrepancies.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.arbiter.json
validation/gold_annotations/conv-<convver>/tcl-<tclver>/<corpus>-<src-sha7>/<basename>.corrected_gold.json
```

Where:
- `<convver>` is the convention version (e.g., `v1.0`). Bumps whenever `TCL_CALLGRAPH_CONVENTION.md` changes.
- `<tclver>` is the Tcl interpreter version the convention pins to (e.g., `8.6`). Per `TCL_CALLGRAPH_CONVENTION.md` §1, this is currently `8.6`; a future revision targeting Tcl 9.0 would surface here.
- `<corpus>` is the source repo logical name (e.g., `bluice-BluIceWidgets`).
- `<src-sha7>` is the first 7 chars of the source repo HEAD SHA at annotation time. Combined with `<corpus>` it uniquely identifies the tree that was annotated.

Phase 1 corpora and their commits at first-pass annotation:
- `bluice-BluIceWidgets-a54fa24`
- `bluice-DcsWidgets-575a192`
- `bluice-dcs-lib-tcl-3a09993`
- `bluice-dcss-b5c9866`
- `bluice-dhs-tcl-c39768d`

(Add other ecosystems as needed; same shape.)

`<basename>` is the source file's basename without directory (e.g., `AutoSample.tcl`).

### 10.2 Artifact contents

- **`<file>.gold.json`**: the final two-tier gold annotation — consensus entries unmarked, discrepancy entries marked with `discrepancy: true` and both versions preserved.
- **`<file>.A.opus.raw.json`**: annotator A's verbatim JSON output.
- **`<file>.B.sonnet.raw.json`**: annotator B's verbatim JSON output.
- **`<file>.audit.json`**: result of §8 cross-checks for A and B — list of violations found (empty list = clean pass).
- **`<file>.discrepancies.json`**: list of cross-annotator disagreements with both versions preserved.

### 10.3 Provenance block (required in `<file>.gold.json`)

```json
"provenance": {
  "convention_version": "v1.0",
  "convention_commit": "a2747c3",
  "tcl_version": "8.6",
  "tcl_version_source": "convention_pin",
  "jcodemunch_repo": "jcodemunch-mcp-fork",
  "jcodemunch_branch": "tcl-disasm-bridge",
  "jcodemunch_head": "<HEAD sha at experiment time>",
  "source_corpus": "<corpus name, e.g. bluice-BluIceWidgets>",
  "source_corpus_commit": "<full HEAD sha of the source repo at annotation time>",
  "source_path": "<full source path>",
  "model_A_alias": "opus",
  "model_A_resolved": "<from process env at run, e.g. claude-opus-4-7>",
  "model_B_alias": "sonnet",
  "model_B_resolved": "<from process env at run, e.g. claude-sonnet-4-6>",
  "prompt_hash": "<sha256 of the Shape B template after substitution>",
  "dispatch_mode": "anon_read_batched | inline_single_shot",
  "experiment_started_at": "<ISO-8601>",
  "experiment_finished_at": "<ISO-8601>"
}
```

Field semantics:
- `convention_version` / `convention_commit` — the rules the LLM applied. Bumps only when `TCL_CALLGRAPH_CONVENTION.md` changes.
- `tcl_version` — the Tcl interpreter version the convention is written against (currently `"8.6"` per convention §1). Independent of the convention version; future runs against Tcl 9.0 would set `"9.0"`.
- `tcl_version_source` — `"convention_pin"` when derived from the convention's documented target, `"runtime_detected"` if the orchestrator probed an installed interpreter. Documents the basis for the recorded value.
- `source_corpus_commit` — the full HEAD SHA of the source repo (e.g., bluice/BluIceWidgets) at annotation time. The short 7-char form is also embedded in the storage path per §10.1.
- `dispatch_mode` — records which dispatch protocol produced this annotation (multi-turn was explored but is blocked pending runtime support; current path is `anon_read_batched` with v1.2 prompt, `inline_single_shot` for batch-1 v1.0 grandfathered raws).

If env doesn't expose resolved model IDs, record `null` and note the alias only.

---

## 11. Acceptance criteria for Phase 1

The Phase-1 pilot passes if:

1. **All 8 files** produce both A and B raw annotations that pass §7 schema check (after up to 1 retry per annotator).
2. **All 8 files** pass §8 audit-vs-output cross-check (after up to 1 retry per annotator).
3. **Symbol-set agreement ≥ 90%** averaged across the 8 files (i.e., at most ~10% of `(qualified_name, kind)` pairs are in only one annotator's output).
4. **Per-symbol callee Jaccard ≥ 0.85** averaged across all symbols across all 8 files.
5. **Audit artifacts** are produced and readable for every file.
6. **Discrepancies are preserved** in `<file>.discrepancies.json` for every file with disagreements (never silently dropped).

If <8 files pass: list the failures in `dev-docs/verdicts/GOLD_PILOT_PHASE1_LOG.md`, summarize the failure mode, and stop. Do not proceed to Phase 2.

If all 8 pass: write a one-page `dev-docs/verdicts/GOLD_PILOT_PHASE1_VERDICT.md` summarizing the agreement metrics and any patterns observed in the discrepancies.

---

## 12. Anti-drift

- This experiment is **isolated** from the rest of the project. Do not consult `dev-docs/verdicts/`, `dev-docs/plans/`, `src/`, or `validation/probes/` for context.
- Do not change the convention doc or this spec mid-run.
- Do not silently filter or repair annotator output beyond the §7 schema rejection rule. Discrepancies are data; preserve them.
- Do not spawn a third LLM as tiebreaker.
- Do not commit gold artifacts without explicit user permission.

---

## 13. Quick-start for an executing session

```
1. Read dev-docs/specs/GOLD_EXPERIMENT_v1.md (this spec).
2. Read dev-docs/specs/GOLD_PROMPT_v1.md (the parametric annotator prompt).
3. Read dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md (the convention; cache it).
4. Batch the 8 files in §5 into 3 groups per §6.2 (max 6 subagents in flight).
5. For each batch: dispatch A (opus) + B (sonnet) per file via §9/GOLD_PROMPT_v1.md; wait; run §7 schema check + §8 audit cross-check per annotation (1 retry on failure); §8.4 cross-annotator compare; write artifacts per §10 with provenance §10.3.
6. After all 3 batches complete: verify acceptance per §11.
7. Write the phase verdict at dev-docs/verdicts/GOLD_PILOT_PHASE1_VERDICT.md.
8. Stop. Surface artifact list to user. Do NOT commit.
```

The convention doc + this spec + GOLD_PROMPT_v1.md + the 8 source files in §5 are the complete inputs. Nothing else is needed.

End of spec.
