# Phase 4 Plan — Bridge-vs-Gold Validation + jcm Setup Hardening

**Status:** DRAFT — Phase 4 starts in a FRESH SESSION (the Phase 3 session that produced this plan got too big).
**Date:** 2026-05-16
**Branch:** `tcl-disasm-bridge`
**Predecessor:** Phase 3 — 37-file v1.3 gold corpus at `validation/gold_annotations/conv-v1.3/tcl-8.6/<corpus>-<sha-or-version>/`
**Goal:** Validate jcodemunch's TCL parser + disasm bridge against the gold corpus. Find discrepancies, classify as bridge-side bugs / gold-side bugs / convention-ambiguous, drive bridge fixes from the diff.

---

## START HERE — fresh-session onboarding

If you are a new Claude Code session picking up Phase 4 cold, read these in order before doing anything:

1. **This file** — full plan from §0 below.
2. **Convention** — `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (v1.3; bumps to v1.4 after P4.0a F2+F3 land). This is the ground truth the bridge is measured against.
3. **Pipeline** — `validation/gold_annotations/pipeline/run.py` + `validation/gold_annotations/pipeline/meta_prompts/{annotator_subagent,arbiter_subagent}.md` + `dev-docs/specs/JCM_GOLD_DRIVER_PROTOCOL.md`. Phase 3 built this; Phase 4 only uses the gold it produced (does not invoke the pipeline).
4. **Gold corpus** — `validation/gold_annotations/conv-v1.3/tcl-8.6/<corpus>-<sha-or-version>/<basename>.{A.opus.raw,B.sonnet.raw,audit,gold,discrepancies,arbiter,corrected_gold}.json`. 37 files. See §0 below for the corpus list.
5. **D2 audit findings** — §3a below summarizes the 882-verdict dispute pattern audit that informs Phase 4's interpretation rules.
6. **PHASE4_NOTES.md scratchpad** — `dev-docs/plans/PHASE4_NOTES.md` (auxiliary lane ideas, bytecode-pass design).
7. **Prior phase plans** — `dev-docs/plans/PHASE3_PLAN.md` (full Phase 3 history; reference only — don't redo Phase 3 work).

### State at handoff (verify these are still true before starting)

- **Branch:** `tcl-disasm-bridge` — verify `git branch --show-current` matches.
- **No commits** in Phase 3 to source tree. All work is in worktree only (`git status` will show many modified + untracked files under `dev-docs/`, `validation/`).
- **Convention version:** v1.3 (on disk at `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md`). P4.0a F2+F3 bump to v1.4.
- **Gold-corpus location:** `validation/gold_annotations/conv-v1.3/tcl-8.6/`. 10 corpus subdirs, 37 files total. Confirm with: `find validation/gold_annotations/conv-v1.3 -name "*.gold.json" | wc -l` (should be 37).
- **Phase 2 historical gold:** `validation/gold_annotations/conv-v1.0/tcl-8.6/` — preserved untouched. Do NOT modify; it's the baseline.
- **`~/.code-index/` state:** unknown — may have stale Phase 2 index data. P4.0a / P4.0 will recommend a fresh dedicated dir.
- **Tcl interpreter:** `tclsh8.6` must be on PATH. P4.0 verifies.
- **D2 run staging at `/tmp/jcm-gold/20260516_180155_11856e/`** — wrapped JSONs, arbiter outputs, prompts. Useful for forensics; NOT needed for P4 work proper. Can be cleaned anytime.

### Entry command for fresh session

The user will say something like "start Phase 4" or "begin P4.0 preflight." If unclear, ask which lane (P4.0a fixes first vs P4.0 preflight first — they're parallelizable). Recommended order:

1. **P4.0a F1+F4 first** (~25 min, no convention bump) — prompt/tool patches.
2. **P4.0a F2+F3** (convention v1.4, ~25 min) — only if user confirms (involves spec edit).
3. **P4.0 preflight** (~1 hr) — verify jcm env, tcl interpreter, canary index.
4. **P4.1 reindex** (depends on P4.0 green) — bridge against all 37 files.
5. **P4.2/P4.3** (analysis + verdict doc).
6. **P4.4** (aux lanes, optional).

---

---

## 0. Predecessor recap (what Phase 3 delivered)

- **37 gold artifacts** under `validation/gold_annotations/conv-v1.3/tcl-8.6/`:
  - 24 from bluice ecosystem (BluIceWidgets, DcsWidgets, dcs-lib-tcl, dcss, dhs-tcl)
  - 6 from git-gui (lib/)
  - 7 from tcl-corpus (tcllib, snit, BWidget, clay)
- **882 arbiter verdicts** applied across 19 disputed files. Verdict mix: A=544 / B=173 / both=11 / neither=132 / ambiguous=17
- **0 review.json escalations**, 0 null-line verdicts
- **Convention v1.3** locked at `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md`
- **Pipeline** (`validation/gold_annotations/pipeline/run.py`) + meta-prompt templates + driver protocol all hardened
- **`schema_version: "1.3"`** stamped on every annotation; provenance includes `run_id`, `convention_commit`, `meta_prompt_hash_A/B`, `meta_prompt_template_version`

Phase 4 consumes this gold corpus as ground truth.

---

## 1. Mission

Run jcodemunch's TCL parser + the `tcl-disasm-bridge` branch's disasm walker against the 37-file gold corpus. For each file, diff bridge output against `<basename>.corrected_gold.json` (or `<basename>.gold.json` where no arbiter ran). Quantify precision/recall/F1 per callee-kind. Bug-list the deltas. The output is `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION.md` plus a per-file `<basename>.bridge_diff.json` artifact set.

---

## 2. Hard rules

- Read-only on the gold corpus — never edit a `<basename>.{gold,corrected_gold,arbiter}.json` to make the bridge look better.
- Never tweak the convention to retro-fit a bridge mismatch. Convention edits, if any, follow the same convention-audit + canary-rerun discipline Phase 3 used. Default position: convention is right, bridge is buggy.
- Tcl interpreter dependency lives on the system — the bridge needs a real `tclsh8.6` available. No silent fallbacks to LLM-style annotation.
- All bridge runs MUST be deterministic (same input → same output). Any non-determinism = bridge bug.

---

## 3a. P4.0a — Convention/prompt fixes from the D2 dispute audit (preflight; low-risk)

The D2 run produced 882 arbiter verdicts across 19 disputed files. A similarity-deduped pattern audit collapsed those to 150 unique dispute patterns. The audit revealed: **the convention is doing its job — most disputes are annotator emission noise, not convention gaps.** Only ~32 verdicts (~3.6%) suggest spec edits, and those are minor.

### Top D2 dispute themes (from the audit)

| Theme | Verdicts | Spec status | Phase 4 implication |
|---|---|---|---|
| §5.3 method_dispatch coverage (one annotator caught, other missed) | 297 | Convention OK | High noise floor on this rule — bridge gets grace here |
| §5.3 naming bug (compound `name` field: `add command` vs `add`) | 101 | Convention OK; **prompt-side gap** | P4.0a fix candidate (annotator prompt forcing-example) |
| §7.1 Tier 2 filter misses (denylisted ensembles emitted) | ~50 | Convention OK | Bridge gets ZERO grace — both annotators agreed denylist applies |
| §5.10 ensemble/Tk geometry granularity (1-word vs 2-word) | ~45 | Convention OK | Bridge should match arbiter's 1-word-when-no-subcommand rule |
| §5.13 upvar/global/variable wrongly emitted as static | ~30 | Convention OK | Pure annotator slip; bridge should be clean |
| **TclOO `oo::define` (clay-specific)** | 15 | **Convention gap candidate** | P4.0a fix candidate (v1.4 §7.1 Tier 4 clarification) |
| `convention_ambiguous` (defer.tcl §5.13, commit.tcl §7.1 Tier 2) | 17 | Minor spec slack | Documented as known-fuzzy in verdict doc |

Full audit detail at `/tmp/jcm-gold/20260516_180155_11856e/post_arbitrate.json` (per-file) and the verdict files under `validation/gold_annotations/conv-v1.3/tcl-8.6/<corpus>/<basename>.arbiter.json`.

### P4.0a recommended fixes (ship BEFORE P4.1 reindex)

These are all low-risk, no-effect-on-existing-gold edits. They cap future noise + give the bridge a cleaner spec to target.

| # | Fix | Where | Cost | Why |
|---|---|---|---|---|
| F1 | Add prompt forcing example: `name` field on `method_dispatch` callees MUST be the literal second-word identifier ONLY (never `method sub` 2-word phrases). | `dev-docs/specs/GOLD_PROMPT_v1.md` + `validation/gold_annotations/tools/build_prompt.py` PROMPT_TEMPLATE | ~10 min | Would collapse the 101 `§5.3 naming bug` neither_correct verdicts — also makes the bridge's target shape unambiguous |
| F2 | Add §7.1 Tier 4 sub-clarification on `oo::define` callee emission shape: directives inside `oo::define CLASS BODY` are walked as class-body directives but the `oo::define` invocation itself is NOT a callee. Recordable callees from BODY are method/forward/mixin/superclass declarations (per Tier 4) and any inner calls in `method` bodies. | `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` §7.1 Tier 4 + §5.4.5 cross-ref | ~15 min | Closes the 15 clay-specific `neither_correct` verdicts; gives the bridge an explicit rule for `oo::define` |
| F3 | Minor §5.13 clarification: `trace add variable VAR OPS COMMAND_PREFIX` records COMMAND_PREFIX's first word as a §6.12 callback, NOT `trace add variable` as a static callee. Restates §6.9 explicitly for the trace flavor (defer.tcl ambiguity source). | `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` §5.13 / §6.9 cross-ref | ~10 min | Closes 6 of the 17 `convention_ambiguous` verdicts |
| F4 | Unwrap.py: tolerate single trailing extra `}` in wrapped JSON (Sonnet's recurring compact-emission quirk that hit commit.tcl during D2 wave 3). | `validation/gold_annotations/tools/unwrap.py` | ~15 min | Removes need for the manual 1-byte repair workflow from D2 wave 3 |

**Sequencing:** F1-F4 are all standalone, can be done in parallel before P4.1 reindex. Convention bumps to **v1.4** if F2 + F3 ship together (substantive Layer A clarification + spec-conformance edge case). If only F1 (prompt-only) + F4 (tool-only) ship, convention stays at v1.3. **Recommend shipping all four** — total ~50 min, sets up cleaner bridge measurement.

### Phase 4 interpretation rules (built into the verdict doc)

When the P4.2 bridge_diff sees a disagreement, the audit drives how to weight it:

1. **§5.3 method_dispatch deltas** — gold's own agreement rate is ~67% on this rule (297 disagreements / 882 total). Report bridge precision/recall here but flag the gold's noise floor in the verdict doc; don't treat sub-90% bridge accuracy as a regression.
2. **§7.1 Tier 2 denylist deltas** — gold is 100% consistent (both annotators agreed Tier 2 should filter). Bridge ≠ Tier 2 = real bridge bug. Zero grace.
3. **§5.10 ensemble granularity** — gold has ~45 disagreements; arbiter sided with 1-word-when-no-subcommand most often. Bridge should match arbiter, not raw annotator output.
4. **TclOO `oo::define`** — gold is fuzzy (15 neither_correct). Bridge agreement here is informational, not score-impacting, until F2 ships and we have a clean spec.
5. **`convention_ambiguous` regions** — exclude from precision/recall denominators; report as "spec uncertainty" separately.

---

## 3. P4.0 — jcm setup hardening (preflight; blocks everything)

Past problems noted: jcm setup has historically been brittle (Python env mismatch, missing tcl interpreter, tree-sitter-tcl grammar gaps, broken `index_folder` against unusual layouts). Phase 4.0 makes this reproducible and self-checking before any reindex runs.

### Preflight checklist

| Check | Command | Pass criterion |
|---|---|---|
| Python env active | `python3 -c "import jcodemunch_mcp"` | imports without error |
| Editable install fresh | `pip install -e .` from `/home/giles/git/jcodemunch-mcp-fork` | exit 0; no resolution conflicts |
| Test suite green | `pytest -x --tb=short` | 3724 passed, 7 skipped (or current baseline) |
| Tcl interpreter | `tclsh8.6 -c 'puts [info patchlevel]'` | prints 8.6.x |
| Disasm bridge invokable | `tclsh8.6 src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl -- --selftest` (add a `--selftest` mode if missing) | exit 0 |
| Canary index | `jcodemunch-mcp index /tmp/tcl_canary` (a 1-proc fixture file) | symbol count matches expected (1) |
| Bridge env vars | `JCODEMUNCH_TCL_PARSE_TIMEOUT` defaults to 30; raise if needed | seen + documented |
| Disk space | `~/.code-index/` writable, ≥1 GB free | green |

If any check fails, P4.0 escalates with the failure mode + recommended fix BEFORE proceeding to P4.1. Failure modes from past:
- iTcl/iTk packages not installed on system → bridge tries to load `[itcl::class]` and segfaults
- Tree-sitter-tcl grammar missing fields → parser falls back to regex
- `tcl_disasm_bridge.tcl` requires a fresh interp per file (cleanup state) — race conditions on parallel runs

Phase 4.0 writes a `dev-docs/verdicts/P4_0_PREFLIGHT.md` recording each check, version, result. The doc is the audit trail for what was true at validation time — bridge output is only trusted relative to those versions.

---

## 4. P4.1 — Reindex the gold corpus repos via jcm

For each of the 37 source files, run jcm through the current `tcl-disasm-bridge`-branch parser + walker. Output is per-file extracted symbols + callees in the `TCL_CALLGRAPH_CONVENTION.md §4` schema.

### Targets

| Corpus | Path | Files | Indexing path |
|---|---|---|---|
| bluice-BluIceWidgets | `/home/giles/bluice/BluIceWidgets/` | 5 in gold | `jcodemunch-mcp index /home/giles/bluice/BluIceWidgets` (filter to gold subset) |
| bluice-DcsWidgets | `/home/giles/bluice/DcsWidgets/` | 6 in gold | same shape |
| bluice-dcs-lib-tcl | `/home/giles/bluice/dcs-lib-tcl/main/scripts/` | 4 in gold | same shape |
| bluice-dcss | `/home/giles/bluice/dcss/scripts/devices/` | 2 in gold | same shape |
| bluice-dhs-tcl | `/home/giles/bluice/dhs-tcl/main/scripts/base/` | 7 in gold | same shape |
| git-gui | `/home/giles/git/git-gui/lib/` | 6 in gold | same shape |
| tcl-corpus-tcllib | `/home/giles/git/tcl-corpus/tcllib/{cmdline,defer,cron}/` | 3 in gold | per-pkg index |
| tcl-corpus-clay | `/home/giles/git/tcl-corpus/tcllib/clay/` | 2 in gold | per-pkg index |
| tcl-corpus-snit | `/home/giles/git/tcl-corpus/tcllib/snit/` | 1 in gold (validate.tcl) | per-pkg index |
| tcl-corpus-BWidget | `/home/giles/git/tcl-corpus/BWidget/` | 1 in gold (dialog.tcl) | per-pkg index |

### Output format

For each gold file, extract jcm's parse result into the same JSON shape as the gold annotation (file, language, symbols[], file_level, callees per symbol). Persist as:

```
validation/bridge_outputs/conv-v1.3/tcl-8.6/<corpus>-<id>/<basename>.bridge.json
```

The bridge.json shape matches `§4` schema so the diff is mechanical.

### Handling non-git corpora

The pipeline patched `infer_corpus()` to read `.tcl-corpus.json` markers — jcm's `index_folder` doesn't know about those. P4.1 either:
- Adds the same marker-reading shim to jcm's CodeIndex `source_root` derivation, OR
- Maps tcl-corpus paths explicitly via a small per-corpus config

Both are short patches; choice deferred to implementation.

### Risk: incremental vs full reindex

jcm supports incremental reindex. For validation correctness we want **full** reindex (no cached partial state). Add `--force-full-reindex` flag (or use a clean `~/.code-index/`) for the validation run.

---

## 5. P4.2 — Bridge-vs-gold diff

For each of the 37 files:

1. Load `gold = corrected_gold.json or gold.json` (corrected_gold takes precedence when present).
2. Load `bridge = <basename>.bridge.json`.
3. Symbol-set diff: `(qualified_name, kind)` set intersection / A-only / B-only.
4. Per-symbol callee diff: for shared symbols, compute Jaccard on `(name, kind, line)` tuples (with ±2 line tolerance per established T2 setting in `apply_arbiter.py`).
5. Per-callee-kind precision/recall/F1: bucketed by `static | qualified | ensemble | method_dispatch | callback | lambda | unresolved`.
6. Classify each delta:
   - **bridge_miss** — gold has it, bridge doesn't
   - **bridge_extra** — bridge has it, gold doesn't (possible bridge over-emission)
   - **kind_mismatch** — same name+line, different kind (often spec-resolvable)
   - **line_drift** — same name+kind, line within ±2 (acceptable noise)
   - **convention_ambiguous** — gold's arbiter marked it ambiguous; bridge match/miss is informational

### Output

Per file: `validation/bridge_outputs/conv-v1.3/tcl-8.6/<corpus>-<id>/<basename>.bridge_diff.json`

Per run summary: `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION.md` with:
- Overall precision/recall/F1 (macro + per-callee-kind)
- Per-corpus breakdown (does the bridge perform worse on tcl-corpus dialects than bluice?)
- Top 20 bridge bugs (by frequency)
- Top 10 bridge wins (cases where bridge caught things both annotators missed — possible gold-side bugs worth re-arbitrating)
- Convention sections most-implicated in bridge misses (data for v1.4 if needed)

### Tooling

Build a small `validation/bridge_outputs/tools/bridge_diff.py` to do steps 1-6. ~150 lines Python. Reuses the convention's `§4` schema parsing already exercised by `audit_check.py`, `build_gold.py`, `apply_arbiter.py`.

---

## 6. P4.3 — Verdict doc + bug triage

When P4.2 lands:

1. Write the validation verdict doc (`BRIDGE_VS_GOLD_VALIDATION.md`).
2. File the top bridge bugs as issues / TODOs in `dev-docs/plans/BRIDGE_BUGS_v1.md`.
3. For bridge wins that suggest gold bugs: list candidates and offer to re-arbitrate those specific callees via the existing pipeline (one-off per-callee mini-arbitrations).
4. If convention gaps surface, defer to a Phase 4.x or Phase 5 v1.4 convention edit (don't retrofit during Phase 4 validation — keep Phase 4 a measurement, not a moving target).

---

## 7. P4.4 — Auxiliary lanes (after P4.3 lands, optional)

From `PHASE4_NOTES.md`:

### Lane A — Eval-resolution / bytecode-extraction pass

For gold entries marked `unresolved` with `subkind ∈ {eval_var, callback_var, var_command, computed_lambda, computed_source}`:

- **Static def-use chain pass** (cheaper, partial): walk enclosing symbol body for `set <var> <value>`; link unresolved entries to the assignment. Output `<basename>.eval_resolution.json` augmenting (not replacing) `gold.json`.
- **Bytecode pass** (heavy, precise): run `::tcl::unsupported::disassemble proc <qn>` on a real Tcl interp; extract `invokeStk` opcodes; cross-reference with LLM-annotated callees. Output `<basename>.bytecode_diff.json`.

Both gated on P4.0's tcl interpreter setup checks. Bytecode pass requires dependency loading (iTcl/iTk/etc.) — sandbox carefully.

### Lane B — Refactor tool consumers

With v1.3 schema fields (`args`/`arity`, `receiver_hint`, `schema_version`), refactor tools can now:
- Detect arity mismatches on rename/move (using `args`/`arity`)
- Cluster `method_dispatch` calls by receiver (using `receiver_hint` instead of parsing `note`)
- Reject pre-v1.3 annotations cleanly (using `schema_version`)

P4.4 Lane B could update one consumer tool (e.g. `plan_refactoring.py` or `get_call_hierarchy.py`) to consume the new fields and emit a "what would break" preview. Defer scope to post-P4.3 demo.

### Lane C — LSP bridge tie-in

`src/jcodemunch_mcp/enrichment/lsp_bridge.py` does LSP-based call-graph enrichment for Go/Python/TS/Rust. A TCL LSP doesn't really exist (`tcl-lsp` is experimental), so this lane is speculative. If P4.2 reveals systematic bridge bugs in a specific area (e.g., qualified-name resolution across `namespace eval` nesting), an enrichment pass that simulates `namespace path` resolution could help. Speculative — open Phase 5 candidate.

### Lane D — Performance comparison

The bridge runs in real-time during indexing; the gold is reference data. Phase 4 can measure: time-to-index for the 37 files vs LLM-annotation wall time (which was hours). This validates the "bridge as runtime substitute for LLM" assumption.

---

## 8. Decisions to resolve before P4 kickoff

| ID | Decision | Default |
|---|---|---|
| P4-D1 | Use existing `~/.code-index/` or fresh dedicated dir for P4.1? | **Fresh dedicated** — `~/.code-index/p4-validation/` so re-runs are clean and don't poison user's everyday index |
| P4-D2 | Run bridge against all 37 files or scope to bluice first to derisk? | **All 37** — the corpus diversity is the whole point; staging by corpus risks hiding cross-dialect bugs |
| P4-D3 | Sequence — P4.0 → P4.1 → P4.2 → P4.3 strictly serial, or pipeline? | **Strictly serial** for P4.0 → P4.1 (setup correctness gates everything); parallel-OK for P4.2 → P4.3 |
| P4-D4 | tcl-corpus indexing path: jcm `index_folder` or per-pkg index? | **Per-pkg index** — tcllib is huge; we only want our 7 files in the bridge output |
| P4-D5 | When does P4.4 (aux lanes) kick off? | After P4.3 verdict ships; lanes A/B/D in parallel, C only if P4.3 surfaces a need |
| P4-D6 | Bridge-side bug fixes — Phase 4 scope or Phase 5? | **Phase 5** — Phase 4 measures; Phase 5 fixes. Keeps P4 a clean validation milestone. |

---

## 9. Out of scope for Phase 4

- Convention v1.4 edits (defer to Phase 5 if needed; v1.3 is locked through Phase 4 measurement)
- Bridge-side code fixes (Phase 5)
- Re-annotation of any of the 37 gold files (Phase 3 owns gold; Phase 4 is read-only on it)
- New corpus expansion beyond 37 files
- New annotator runs of any kind
- Convention v2.0 / convention refactor

---

## 10. Estimated sequencing

```
P4.0 jcm preflight        (~1 hr setup + checks)
   ↓
P4.1 reindex 37 files     (~10-30 min depending on bridge speed)
   ↓
P4.2 bridge_diff.py       (~1 hr build + 5 min run)
   ↓
P4.3 verdict doc          (~1-2 hr analysis + write-up)
   ↓
P4.4 aux lanes (parallel) (~1 day if pursued)
```

Phase 4 closes when `BRIDGE_VS_GOLD_VALIDATION.md` lands with precision/recall/F1 numbers and a triaged bug list. Phase 5 (bridge fixes) opens from that bug list.

---

End of plan.
