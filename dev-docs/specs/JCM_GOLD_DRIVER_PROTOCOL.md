# JCM-Gold Driver Protocol

**Status:** DRAFT v1.0
**Date:** 2026-05-16
**Audience:** the LLM driver (Claude, in any session) executing a gold-annotation run.
**Companion artifacts:** `validation/gold_annotations/pipeline/run.py`, `pipeline/meta_prompts/{annotator_subagent.md, arbiter_subagent.md}`.

This document is the **contract** between the user and the LLM driver. The user invokes a gold-annotation run with a list of source files; the LLM follows the protocol below to drive the pipeline end-to-end. The LLM never improvises meta-prompts, never hand-patches failed dispatches, and never one-shots a build_gold script. Every operation is either a pipeline phase call or an Agent dispatch using a templated meta-prompt.

---

## 1. Invocation shape

The user sends a natural-language request of one of these forms:

- "Build gold annotations for these files: `<path1>` `<path2>` …"
- "Make gold for `<path>`"
- (future) `/jcm-gold <path1> <path2> …`

The LLM treats any of these as a trigger to follow this protocol.

## 2. Phase loop

The LLM drives four pipeline phases sequentially. Each phase emits structured JSON on stdout with a `next_step.action` field telling the LLM what to do next.

```
prepare  →  dispatch_annotators  →  post-annotate  →  ?
                                                       │
                                          if disputes  ├─→ dispatch_arbiters → post-arbitrate → summary
                                                       │
                                          if no disputes
                                                       └─────────────────────→ summary
```

### 2.1 Phase: `prepare`

The LLM runs:

```bash
python3 validation/gold_annotations/pipeline/run.py prepare <file_path1> [<file_path2> ...]
```

The pipeline stages sources, builds real prompts, fills meta-prompts, records sha256s, and emits `prepared.json` with `next_step.action = "dispatch_annotators"`.

The LLM **reports to the user**: `"Run <run_id> prepared. <N> files in <M> batches. Dispatching annotators."`

### 2.2 Action: `dispatch_annotators`

For each entry in `next_step.dispatches`, the LLM dispatches one background Agent. The dispatch is mechanical — the meta-prompt is already filled by the pipeline and lives at `dispatch["meta_prompt_path"]`. The LLM:

1. Reads `dispatch["meta_prompt_path"]` (a small file).
2. Calls `Agent` with:
   - `subagent_type = "general-purpose"`
   - `model = dispatch["model"]` ("opus" or "sonnet")
   - `run_in_background = true`
   - `prompt = <the meta-prompt file's content>` (verbatim, no edits)
   - `description = "Annotator <role> batch<bid>"` for traceability

3. Honors `next_step.max_in_flight` (6) — dispatches in waves if there are more than 6 pending.

The LLM **does not** read the real prompt or the source files. The subagent does.

When all dispatches ack, the LLM moves to the next phase. The LLM does NOT report intermediate annotator acks to the user (just the wave-complete event).

### 2.3 Phase: `post-annotate`

The LLM runs:

```bash
python3 validation/gold_annotations/pipeline/run.py post-annotate <run_id>
```

The pipeline unwraps each wrapped JSON, repairs missing lines, audits, routes raws to corpus dirs, builds gold + discrepancies, and stages arbiter prompts for files with non-empty disputes. Emits `post_annotate.json`.

The LLM **reports to the user**:

```
post-annotate complete:
  Files gold-built: <N>/<total>
  Audit clean A/B: <a_clean>/<b_clean>
  Files with disputes: <K>  (→ <K> arbiters queued)
  Review escalations: <Z>   (if any review.json was written)
```

If `Z > 0`, the LLM also lists each review.json basename + failure_mode and **stops to ask the user how to proceed** before dispatching arbiters. Otherwise it continues.

### 2.4 Action: `dispatch_arbiters` (only if disputes exist)

Same shape as `dispatch_annotators`: for each entry in `arbiter_dispatches`, the LLM dispatches a background Agent with `model = "opus"`, `prompt = <content of meta_prompt_path>`, concurrency cap 6.

### 2.5 Phase: `post-arbitrate`

The LLM runs:

```bash
python3 validation/gold_annotations/pipeline/run.py post-arbitrate <run_id>
```

The pipeline saves each arbiter output, validates against expected dispute count, applies verdicts to produce `corrected_gold.json`, and runs an auto-audit on each arbiter (verdict-to-dispute coverage, null-line check, missing-justification check).

The LLM **always reports the auto-audit** — this is the step Phase 2 had ad-hoc; the pipeline makes it mandatory. Per-file output includes `human_review_recommended: true|false`. If any file has it set, the LLM surfaces those files to the user with the specific anomaly (null-line, no-justification, etc.).

### 2.6 Phase: `summary`

The LLM runs:

```bash
python3 validation/gold_annotations/pipeline/run.py summary <run_id>
```

The pipeline emits the final run-level summary table. The LLM reports the table to the user verbatim plus a short prose conclusion: where the gold artifacts landed, how many files needed arbitration, any review escalations.

The conversation ends with the user able to inspect every artifact at `validation/gold_annotations/<storage_prefix>/<corpus>-<sha7>/`.

---

## 3. Hard rules (the "no improvisation" guardrails)

1. **Meta-prompts are not edited.** The LLM passes the meta-prompt file's content verbatim to the Agent tool. No conditional tweaks, no extra hints, no model-specific override.
2. **Pipeline failures are reported, not worked around.** If the pipeline writes `<basename>.review.json` for a file, the LLM surfaces the failure to the user immediately and waits for direction. The LLM does NOT dispatch a custom recovery agent, write a one-off shell script, or edit a raw file.
3. **No ad-hoc orchestration scripts.** All multi-file operations go through the pipeline phases. If a needed orchestration step doesn't exist in `run.py`, the answer is to add it to `run.py` (a Phase 3 patch), not to script around it in the conversation.
4. **Concurrency cap is enforced.** `next_step.max_in_flight = 6` is non-negotiable. Larger dispatch lists are waved.
5. **Provenance fields are byte-perfect.** The pipeline computes sha256s for prompts and meta-prompts; the LLM does not re-compute or alter them.

## 4. When to talk to the user

| Event | LLM behavior |
|---|---|
| `prepare` completes | Brief ack: "Run X prepared. N files in M batches. Dispatching." |
| Annotator acks arriving | Silent (harness notifies the LLM; the user doesn't need running commentary) |
| All annotators ack'd | Brief: "All annotators complete. Running post-annotate." |
| `post-annotate` completes, no review.json, no arbiter needed | Report summary + skip arbiter phase, move to `summary` |
| `post-annotate` completes, no review.json, arbiters needed | Report summary, dispatch arbiters |
| `post-annotate` completes, review.json written | Report, escalate, await user direction |
| Arbiter acks arriving | Silent |
| `post-arbitrate` completes, clean auto-audit | Report verdict roll-up + audit confirmation |
| `post-arbitrate` completes, `human_review_recommended` on any file | Report + name those files with anomalies |
| `summary` complete | Report final table |

## 5. Error escalation paths

When the pipeline writes a `<basename>.review.json`, the LLM stops and asks. The review.json contents tell the user what failed:

- `failure_mode = "wrapped_json_not_written"` — an annotator subagent didn't produce its output (model failure, output-cap, etc.). User decides: re-dispatch single annotator, drop the file, etc.
- `failure_mode = "schema_violation_twice"` — annotator output failed §7 schema check after one retry. User decides: re-dispatch with different prompt revision, accept and continue, etc.
- `failure_mode = "audit_violation_twice"` — audit cross-check failed twice. Same options.
- `failure_mode = "arbiter_output_not_written"` — arbiter didn't produce output. User decides.

In every case the LLM **does not** invent a fix. It surfaces the failure and waits.

## 6. Provenance contract

Every gold artifact carries provenance fields the LLM never alters:

- `run_id` — pinpoints exactly which run produced this artifact.
- `convention_version` + `convention_commit` — the rules the annotator saw.
- `prompt_hash_A` / `prompt_hash_B` — sha256 of the real prompts each annotator received.
- `meta_prompt_hash_A` / `meta_prompt_hash_B` — sha256 of the filled meta-prompts.
- `meta_prompt_template_version` — version tag of the template used.
- `model_A_alias` / `model_B_alias` — opus/sonnet/etc.

Two runs against the same input with the same template version + convention version produce byte-identical prompts + meta-prompts (verified by sha256). Any drift surfaces as a hash mismatch.

## 7. Not yet in scope (future)

- `/jcm-gold` slash-command skill — a thin wrapper that loads this protocol and triggers the prepare phase. Same pipeline underneath.
- Auto-retry on schema/audit fail — currently the pipeline writes review.json on first fail; user-driven retry path. Phase 3.5+: retry-once-automatic per spec §7/§8.
- Cross-run consistency check — compare two runs' meta_prompt_sha256s on the same input. Pipeline phase `verify-reproducibility`.

End of protocol.
