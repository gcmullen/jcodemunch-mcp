# Phase 3 Plan — Tooling, Convention v1.2, Corpus Expansion, Bridge-vs-Gold

**Status:** DRAFT (prepared 2026-05-16 for AM kickoff)
**Branch:** `tcl-disasm-bridge`
**Predecessors:** Phase 1 (8 files), Phase 2 (16 files) — both artifact-complete.
**Goal:** Harden the harness, tighten the convention based on Phase 2 spec ambiguities, and expand the gold corpus to **37 files** (+13 from new repos). Bridge-vs-gold validation deferred to **Phase 4**.

---

## 0. Carry-over from Phase 2

- `/tmp/gold_sources/`, `/tmp/gold_dispatches/`, `/tmp/gold_arbiter/` still hold built prompts, wrapped JSONs, and orchestration scripts. **Decision needed (D5 below):** full clean / selective clean / defer.
- No commits made on this branch since the Phase 2 work started. All artifacts persisted only to `validation/gold_annotations/conv-v1.0/tcl-8.6/<corpus>-<sha>/`.
- 8 of 16 Phase 2 raws had audit violations (mostly Sonnet missing-`line` bug). Recorded but not retried. Eligible for re-dispatch under the new pipeline if we choose.

### Gold-acceptance status (as of end of Phase 2)

| Status | Files |
|---|---|
| **Accept-as-final candidates** (clean arbiter audit, full verdict coverage) | Phase 1: 8 files. Phase 2 Wave 2 with disputes: Clock.tcl, DEG_HORZ.tcl. Phase 2 Wave 1: Scan3DView.tcl, BeamlineChooser.tcl, Cif.tcl, MessageBoard.tcl, AsyncGets.tcl. Phase 2 Wave 2 with 0 disputes: AttributeDisplay, ComponentGateExtension, Logger, DeviceBase, IonChamberBase, ShutterBase, AsyncExec, DetectorStop. |
| **Provisional — needs deep-dive** | **BeamlineVideo.tcl** — 35/166 arbiter verdicts came back with `line: null`. `apply_arbiter.py` could not place them in `corrected_gold.json`. Underlying cause TBD (see P3.0a below). |

**Hold all gold-finalization steps for BeamlineVideo until P3.0a completes.** Other 23 files are gold-ready.

---

## 1. P3.0a — BeamlineVideo deep-dive (FIRST STEP — blocks BeamlineVideo finalization)

**Trigger:** 35 of 166 arbiter verdicts have `line: null` and were dropped by `apply_arbiter.py` as `unmatched_verdicts`. Samples include `('DCS::BeamlineVideoNotebook::constructor', '::mediator', None)`, `('...constructor', 'getStr', None)`, `('...constructor', 'create${tt}Tab', None)`.

**Investigation steps:**
1. Read `BeamlineVideo.tcl.arbiter.json` and isolate the 35 null-line verdicts.
2. Cross-reference each verdict's `(symbol, callee_name)` against the original `BeamlineVideo.tcl.A.opus.raw.json` and `B.sonnet.raw.json`. Identify which side(s) originally had a line and which didn't.
3. Read `BeamlineVideo.tcl.discrepancies.json` for those 35 entries — verify the underlying dispute shape (likely `a_line=null` or `b_line=null` due to Sonnet's missing-`line` schema bug).
4. Classify the 35:
   - **Sonnet-source bug** → mitigation: re-dispatch B.sonnet under the prompt with the forcing example (P3.0 T4), rebuild gold, re-run arbiter. The new B raw will carry line info, the arbiter will then have a non-null line to reason about.
   - **Arbiter cannot decide** (real dynamic-dispatch where line is genuinely indeterminate) → record as `convention_ambiguous` or document the `line: null` semantics explicitly in convention v1.2.
5. Spot-check 3–5 of the null-line verdicts manually against the source. Confirm the classification.

**Decision (D6):** based on the classification result, choose one of:
- **(a) Re-dispatch B.sonnet only** with v1.3 prompt → rebuild → re-arbiter only for BeamlineVideo. Cheapest.
- **(b) Re-dispatch both A and B** under v1.2 convention + v1.3 prompt. Most consistent with later P3.3 work.
- **(c) Accept the 35 null-line verdicts as preserved discrepancies** (per spec L4, "discrepancies are data"); finalize gold with them noted in `corrected_gold` as `discrepancy: true`.

**Output:** `dev-docs/verdicts/BEAMLINEVIDEO_DEEP_DIVE.md` (or `.review.json` if escalating to human review).

**Mitigation overlap with P3.0:** the line-tolerance flag (T2) and the Sonnet line-repair pass (T3) BOTH partially mitigate this issue for future files; the BeamlineVideo deep-dive determines whether they're sufficient or whether a stronger fix (prompt-side forcing example + retry) is required.

---

## 2. P3.0 — Pipeline & driver protocol (shaped toward a future `/jcm-gold` skill)

P3.0 is **one coherent deliverable**: a deterministic shell pipeline + versioned meta-prompt templates + an LLM driver protocol. Together they form the foundation for a future `/jcm-gold` slash-command skill (Phase 3.5 or later). The pieces stand alone if the skill never ships.

### Architecture (the "pipeline is the contract" model)

```
LLM (me) ←→ pipeline/run.py (shell engine)
   │              │
   │              ├─ phases: prepare | post-annotate | post-arbitrate | summary
   │              ├─ structured JSON status output per phase (next_step.action drives the LLM)
   │              ├─ auto-retry-once on §7/§8 fail; review.json on second
   │              └─ auto-arbiter-audit step after every arbitration round
   │
   └─ dispatches Agent tool using meta_prompts/{annotator_subagent.md, arbiter_subagent.md}
      (templates with {PROMPT_PATH}, {OUTPUT_PATH}, {N_FILES} placeholders; filled file + sha256 recorded)
```

The LLM is the **driver** — it parses each phase's JSON output, sees `next_step.action` (e.g. `"dispatch_annotators"`, `"dispatch_arbiters"`, `"none"`), and either dispatches Agent calls or moves to the next phase. The conversation surfaces only at fixed reporting checkpoints; the LLM never improvises meta-prompts or hand-patches failures.

### Per-run filesystem layout

Pipeline generates a `run_id = YYYYMMDD_HHMMSS_<6char-rand>` at `prepare` time. All transient comms live under:

```
/tmp/jcm-gold/<run_id>/
  sources/        ← anonymized source copies
  dispatches/     ← real prompts, filled meta-prompts, wrapped JSONs (annotator stage)
  arbiter/        ← arbiter prompts, filled meta-prompts, arbiter outputs
  prepared.json
  arbiter_dispatches.json
  summary.json
```

Persistent artifacts go to `validation/gold_annotations/conv-vX/tcl-X/<corpus>-<sha7>/`. Per-run tmp directory eliminates clash risk between concurrent runs.

### Deliverables

| ID | Task | Output |
|---|---|---|
| T1 | `pipeline/run.py` — single-entrypoint shell engine. Phases: prepare / post-annotate / post-arbitrate / summary. Auto-retry-once on §7/§8 fail (writes review.json on 2nd). Auto-runs arbiter-audit step after post-arbitrate. Emits structured JSON status per phase with a `next_step` field the LLM driver consumes. Per-run tmp directory with `run_id`. | `validation/gold_annotations/pipeline/run.py` |
| T2 | Meta-prompt templates — annotator & arbiter subagent wrappers with `{PROMPT_PATH}`, `{OUTPUT_PATH}`, `{N_FILES}` placeholders. Pipeline substitutes per dispatch, writes filled text to disk, records sha256 in `prepared.json` / `arbiter_dispatches.json` for full provenance reproducibility. | `validation/gold_annotations/pipeline/meta_prompts/{annotator_subagent.md, arbiter_subagent.md}` |
| T3 | Driver protocol doc — the LLM's conversational contract. Defines: when to dispatch agents, when to call the pipeline, what events to surface to the user, what triggers escalation, the parsing contract for `next_step`. | `dev-docs/specs/JCM_GOLD_DRIVER_PROTOCOL.md` |
| T4 | `apply_arbiter.py --line-tolerance N` — default 2. Fixes DEG_HORZ-style ±1 drift. Does not fix `line: null` (see P3.0a / T6). | Patch to existing tool |
| T5 | `unwrap.py --repair-missing-lines` — infer missing `line` field from `note` text or fall back to enclosing symbol's line. Prevents Sonnet schema bug from producing `line: null` callees and downstream `line: null` arbiter verdicts. | Patch + test |
| T6 | Annotator prompt forcing-example — add an inline example to the prompt template that explicitly shows `{"name": "X", "line": <int>, "kind": "..."}` and warns omission causes rejection. Prevents the bug at source. | Edit `dev-docs/specs/GOLD_PROMPT_v1.md` |
| T7 | Provenance schema extension — gold artifacts gain `run_id`, `meta_prompt_a_sha256`, `meta_prompt_b_sha256`, `meta_prompt_template_version` fields. | Patch to `build_gold.py` |
| T8 | Fix `build_gold.py` line-drift default — current `av.get("line", 0)` collapses missing/null lines to 0, producing fake `line_drift_>2` entries (e.g., drift=87 when one side has line 87 and the other has null). Change to: skip drift comparison when either line is missing/None; surface as a dedicated `b_missing_line` / `a_missing_line` dispute kind instead. Prevents the T6-class bug from masquerading as drift in any future run that slips a missing-line callee past the prompt. | Patch to `build_gold.py` |

### Reproducibility invariants

The pipeline guarantees these or fails loudly:

1. **Byte-identical meta-prompts across runs** — given the same input and same template version, two filled meta-prompts have matching sha256.
2. **No conversation-mediated improvisation** — the LLM never hand-writes a meta-prompt, never hand-patches a failed dispatch, never one-shots a build_gold script. Every operation is either a pipeline phase call or an Agent dispatch using a templated meta-prompt.
3. **All failures surface as `<basename>.review.json` or `summary.json::errors`** — there is no "silent skip" or in-conversation workaround.
4. **`run_id` per invocation** — two `/jcm-gold` runs (now or future) never collide.

### Sequencing

T1 + T2 + T3 are a tight bundle (the pipeline doesn't work without all three). T4, T5, T7, T8 are independent patches. T6 is a spec edit. Bundle goes first; T4–T8 in parallel after. **T6 already shipped early** (validated end-to-end on BeamlineVideo: 132 → 0 missing-line schema violations, 95 → 0 fake `line_drift_>2` artifacts).

---

## 3. P3.1 — Convention v1.2 (parallel to P3.0)

**Source data:** 11 `convention_ambiguous` verdicts surfaced in Phase 2:
- **AsyncGets.tcl × 5** — `eval $cmd args` and `eval $callback args` callback-through-eval patterns; arbiter says spec under-specifies (`§5.8` / `§6.12` interaction)
- **Scan3DView.tcl × 3** — TBD; pull from arbiter justification text
- **BeamlineVideo.tcl × 3** — TBD; same

**Steps:**
1. Extract every `convention_ambiguous` verdict from all Phase 2 arbiter.json files. Cluster by cited spec section.
2. Identify the 3–5 §-anchors that genuinely under-specify.
3. Likely tightenings: §5.8 (eval-through-dynamic), §6.12 (callback recognition for `eval $cb args` form), §5.14 (additional `unresolved_dispatches.subkind` values).
4. Draft v1.2 changelog at the top of `TCL_CALLGRAPH_CONVENTION.md`.

**Output:** `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` bumped to v1.2 + changelog.

---

## 4. P3.2 — Phase 2 verdict doc (historical retrospective)

**Path:** `dev-docs/verdicts/GOLD_PHASE2_VERDICT.md`

**Framing:** retrospective, not prospective. D2 has flipped to YES (re-annotate the 24 under v1.3 via the new pipeline); convention v1.3 has shipped; P3.0 pipeline + meta-prompts + driver protocol are built. Phase 2 gold remains on disk at `conv-v1.0/tcl-8.6/` as the historical baseline that motivated v1.3 and the pipeline. The canonical gold dataset is what P3.3 produces under `conv-v1.3/tcl-8.6/`.

**Contents:**
- Per-file agreement metrics: symbol-set Jaccard, per-symbol callee Jaccard, line-drift histogram (measured, not estimated).
- Dispute taxonomy (actuals):
  - Sonnet missing-`line` schema bug — measured from Wave 1 audit data
  - Real-semantic disputes resolved by arbiter — 139 A_correct + 75 B_correct + 95 both
  - `convention_ambiguous` — **13 actual on disk** (AsyncGets ×5, Scan3DView ×5, BeamlineVideo v1 ×3); all dispositioned in v1.3 (P3.1 folded 5 image-create + 1 eval-cb into convention; T6/T8 resolved 7 tooling-side)
- Verdict roll-up: A=139, B=75, both=95, neither=7, ambiguous=13.
- **BeamlineVideo v1 → v2 → v3 transition table** (166 → 56 → 4 disputes) as concrete evidence of the convention-drift problem that motivated v1.3.
- **P3.0 tooling case studies** — what T6 (forcing example), T8 (line classifier), T5 (line-repair), and the line-tolerance fix each prevented or fixed.
- Acceptance: present Phase 2 metrics; defer pass/fail thresholds to Phase 4 (bridge-vs-gold) where the canonical dataset is v1.3 gold.

**Phase 2 gold's role going forward:** comparison baseline. Diffing v1.3 re-annotation results against Phase 2 gold quantifies the impact of v1.3 changes per file. The Phase 2 corpus dirs are preserved untouched at `conv-v1.0/`.

**Can be done immediately** — no dependency on P3.0/P3.1 (both complete) or P3.3 (the doc covers Phase 2 history regardless of what P3.3 produces).

---

## 5. P3.3 — Corpus expansion: 24 → 37 files (depends on P3.0; ideally P3.1)

**Decisions resolved (2026-05-16):**

- **D1:** new files go to `conv-v1.3/tcl-8.6/` (storage path tracks convention version; existing 24 stay at `conv-v1.0/` as historical baseline).
- **D2:** **YES** — re-annotate the existing 24 against v1.3. BeamlineVideo v1→v3 evidence and the Phase 2 arbiter verdict pattern justify the trip. P3.0 pipeline + meta-prompts make it cheap.
- **D3:** sources picked — see locked +13 list below.

### Locked +13 distribution (13 new files, joining the 24 re-annotated for 37 total)

`.tcl-corpus.json` marker files have been added to non-git tcl-corpus subdirs so `infer_corpus()` resolves each to a stable `(corpus, version)` pair.

| # | Source | Corpus (resolved) | Pattern emphasis |
|---|---|---|---|
| 1 | `/home/giles/git/git-gui/lib/class.tcl` | `git-gui` (commit `60046bd6`) | Defines git-gui's `class NAME BODY` DSL macro — tests §5.4.2 |
| 2 | `/home/giles/git/git-gui/lib/branch.tcl` | `git-gui` | Small pure-Tcl proc-only file |
| 3 | `/home/giles/git/git-gui/lib/about.tcl` | `git-gui` | Tk dialog with `bind` / `-command` callbacks |
| 4 | `/home/giles/git/git-gui/lib/console.tcl` | `git-gui` | Tk window + `after` script-accepting |
| 5 | `/home/giles/git/git-gui/lib/commit.tcl` | `git-gui` | Procedural Tcl + `exec git` pipelines |
| 6 | `/home/giles/git/git-gui/lib/blame.tcl` | `git-gui` | Largest single Tk file (35KB) — solo batch likely |
| 7 | `/home/giles/git/tcl-corpus/tcllib/cmdline/cmdline.tcl` | `tcl-corpus-tcllib` | Pure-Tcl pkg idioms, no Tk |
| 8 | `/home/giles/git/tcl-corpus/tcllib/defer/defer.tcl` | `tcl-corpus-tcllib` | Small pure-Tcl pkg with `trace add` patterns |
| 9 | `/home/giles/git/tcl-corpus/tcllib/cron/cron.tcl` | `tcl-corpus-tcllib` | Event-loop + `after`/`vwait` patterns |
| 10 | `/home/giles/git/tcl-corpus/tcllib/clay/clay.tcl` | `tcl-corpus-clay` | TclOO patterns — `oo::class create`, `superclass`, `mixin` — **new dialect for the corpus** |
| 11 | `/home/giles/git/tcl-corpus/tcllib/clay/pkgIndex.tcl` | `tcl-corpus-clay` | `package ifneeded` patterns (tiny) |
| 12 | `/home/giles/git/tcl-corpus/tcllib/snit/validate.tcl` | `tcl-corpus-snit` | Snit's `snit::widget` / `snit::type` dialect (`snit.tcl` main is 128KB, deferred) |
| 13 | `/home/giles/git/tcl-corpus/BWidget/dialog.tcl` | `tcl-corpus-BWidget` | Tk megawidget toolkit other than iTk |

Combined: 6 git-gui + 5 tcllib-family + 1 snit + 1 BWidget. Covers 4 new dialects (pure-Tcl, Snit, BWidget, TclOO clay) plus reinforces existing iTk/Tk coverage.

### Execution

Once D3 is final (above), the run is:

```bash
python3 validation/gold_annotations/pipeline/run.py prepare \
  --storage-prefix conv-v1.3/tcl-8.6 \
  <24 existing source paths> <13 new source paths>
```

Then driver-protocol loop: dispatch annotators (waves ≤6 in-flight), `post-annotate`, dispatch arbiters, `post-arbitrate`, `summary`. Estimated wall time 2-4 hours, ~5-8M LLM tokens.

---

## 6. (Phase 4 preview — bridge-vs-gold validation + optional enrichment lanes)

Moved to a separate `dev-docs/plans/PHASE4_PLAN.md` (to be drafted at end of Phase 3). High-level shape:
- Run `jcodemunch_mcp.parser.extractor` + disasm bridge against the 37-file corpus; emit `§4`-schema JSON.
- Diff bridge output vs corrected_gold (or gold where no arbiter ran).
- Per-callee-kind precision/recall/F1, bridge-side bugs vs gold-side bugs vs `convention_ambiguous`.
- Output: `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION.md`.

**Auxiliary Phase 4 ideas-in-progress** live at `dev-docs/plans/PHASE4_NOTES.md` (scratchpad). Currently noted there:

- **Eval-resolution / bytecode-extraction pass** — second pass that augments gold entries marked `unresolved / eval_var | callback_var | var_command | computed_lambda`. Two approaches: static def-use chain walk (cheap, partial) + Tcl bytecode disassembly via `::tcl::unsupported::disassemble` (heavy, precise where dependencies load). Output is layered (`<basename>.eval_resolution.json`), not replacing `gold.json`. Can run in parallel with the bridge-vs-gold lane.

The Phase 3 deliverable is "37-file gold corpus annotated under v1.3 convention via H6 pipeline." Phase 4 consumes it.

---

## 7. Decisions resolved

| ID | Question | Resolution |
|---|---|---|
| D1 | New-files storage path | **`conv-v1.3/tcl-8.6/`** — path tracks convention version; existing 24 stay at `conv-v1.0/` as historical baseline |
| D2 | Re-annotate existing 24 against v1.3? | **Yes** — BeamlineVideo v1→v3 evidence + Phase 2 arbiter verdicts + new schema fields (args/arity, receiver_hint) require re-run; pipeline makes it cheap |
| D3 | Source roots for the +13 files? | **git-gui (6 files) + tcl-corpus subdirs (7 files)** — see §5 locked list. tcl-corpus subdirs got `.tcl-corpus.json` markers (option-2 patched into `infer_corpus()`) |
| D4 | Sonnet retry behavior on 48K cap hit | **Retry Sonnet** (don't fall back to Opus B). T6 forcing example + 48K env makes repeat caps rare; pipeline writes review.json on actual failure |
| D5 | `/tmp` cleanup timing | **After D2 completes** — Phase 2 staging stays for diff inspection through re-annotation |
| D6 | BeamlineVideo remediation (P3.0a) | **Done** — option (a) executed earlier: B.sonnet re-dispatched under v1.1+T6, then A.opus too; v3 gold final (4 disputes, all resolved) |

---

## 8. Status snapshot (current)

**Done:**
- P3.0a — BeamlineVideo deep-dive + remediation
- P3.0 — pipeline + meta-prompts + driver protocol + T2/T4/T5/T6/T7/T8 patches
- P3.1 — convention v1.3 (Bucket A + B + C1/C3/C5/C6 + D + E folded; P3.1 ambiguity fold-in; 2 post-canary follow-ups: §5.10 qualified precedence, §7.2 `${var}`-name, plus `list` Tier 2, §5.4.2 DSL-impl clarification)
- 3 canary rounds (initial small files; P3.1 ambiguity files; regression set including new git-gui + snit dialects)

**Pending Phase 3:**
- **P3.2 — verdict doc** (`GOLD_PHASE2_VERDICT.md`) — analytical, decoupled from D2 run
- **P3.3 — D2 + +13 corpus expansion run** — produces canonical v1.3 gold for 37 files. Single pipeline invocation, ~2-4 hr wall, ~5-8M tokens
- **P3.5 — `/tmp` cleanup** post-D2

Phase 3 closes when P3.3 lands 37 v1.3 gold artifacts under `conv-v1.3/tcl-8.6/<corpus>-<sha>/`. Phase 4 (bridge-vs-gold + optional eval-resolution lane per `PHASE4_NOTES.md`) opens with that corpus as input.

---

## 9. Out of scope for Phase 3

- Commits / PRs — still no commits without explicit user approval per project policy.
- Phase 4 (whatever comes after bridge validation).
- LSP-bridge or call-graph consumer changes — those live in `src/jcodemunch_mcp/enrichment/` and `src/jcodemunch_mcp/tools/get_call_hierarchy.py` and are downstream of the parser improvements bridge-vs-gold will surface.

---

End of plan.
