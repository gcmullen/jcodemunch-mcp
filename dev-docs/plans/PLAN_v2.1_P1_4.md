# PLAN_v2.1 §3 P1.4 — Validation Phase (handoff-ready)

**Status**: PLAN-LOCKED. Execution awaits explicit user go.
**Branch**: `tcl-disasm-bridge` (HEAD `5133c10`)
**Predecessor verdict**: `dev-docs/verdicts/P1_3_VERDICT.md` (P1.3 closed 2026-05-09)
**Budget**: 5 working days + Day 0 (~half day pre-flight). Cap: 7 days hard.
**Plan author session**: tcl-disasm-P1.4p (2026-05-09 → 2026-05-11)
**Execution session**: NEW (this document is the handoff)

---

## 0. Mission (one paragraph)

P1.4 is the validation phase of the TCL/iTcl/Tk/iTk bridge rewrite. Goal: **measure the accuracy of JCM MCP tool calls when querying Tcl codebases, with uncertainty bounds and per-pattern stratification, on a multi-corpus Tcl sample**. Primary corpora: bluice + dcss (the customer codebases this bridge exists to serve). Secondary: 4 OSS Tcl projects to test generalization within Tcl. **P1.4 produces a calibration report, NOT a "bridge is certified correct" claim.** The previous F1 ≥ 95% gate has been demoted; the new release gate is cross-tool invariant pass-rate. The bridge stays as-is; if invariants fail, they get logged as findings, not fixed in P1.4.

---

## 1. State at handoff (verify with pre-flight gates §3)

| Item | Value |
|---|---|
| Branch | `tcl-disasm-bridge` at `5133c10` |
| pytest | 3,802 passed, 13 skipped |
| Fixtures | 26/26 PASS |
| Corpus recognition (bluice) | 0 / 12,256 events |
| Corpus recognition (`/usr/share/tcltk`) | 0 / 14,187 events |
| Existing oracle F1 | 93.8% (P 91.7% / R 96.0%) on 357 symbols / 24 files |
| v1 vs v2 bridges | bit-identical on oracle slice (SHA-256 hash equality) |
| Existing infrastructure | `validation/harness.py` (A/B MCP capture, 535 LoC), `validation/queries.py` (frozen registry), `validation/ground_truth.py` (parser-independent grep), `validation/layer2_compare.py`, `validation/golden_set/edges_v1.jsonl` (95 entries with `evidence` field) |

---

## 2. Required reading order (before any work)

1. **This document** (PLAN_v2.1_P1_4.md) — what to do
2. `dev-docs/verdicts/P1_3_VERDICT.md` — state predecessor, P1.3 close-out
3. `dev-docs/specs/SPEC_v2.md §10` — validation architecture (4 signals + reconciliation)
4. `dev-docs/plans/PLAN_v2.1.md §3 P1.4` — original 4-5 day plan (this document supersedes scope but the architecture context is useful)
5. `validation/harness.py` — existing A/B MCP capture rig; **EXTEND**, don't rewrite
6. `validation/ground_truth.py` — existing parser-independent grep counter; **EXTEND** with per-tool ground truth
7. `validation/layer2_compare.py` — F1 measurement; **STRATIFY** by pattern_kind, don't replace
8. `validation/golden_set/edges_v1.jsonl` + `README.md` — 95-entry hand-curated set with `evidence` field
9. `validation/oracle/layer2_oracle_batch_*.json` — 357-symbol LLM oracle (24 files)

**Do not re-debate the strategy.** Six agent rounds (critic, architect, planner, scientist, document-specialist) converged on this plan. Re-deriving wastes the budget. If you find a fatal flaw, surface it to the user; do NOT change scope unilaterally.

---

## 3. Pre-flight gates (run BEFORE any P1.4 work)

```bash
cd /home/giles/git/jcodemunch-mcp-fork
git status --short                                                # expect clean
git log --oneline -3                                              # 5133c10 P1.3 at HEAD
tclsh validation/fixtures/disasm/run.tcl                          # 26/26 PASS
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl         # 0 / 12,256
uv run --no-project --with pytest --with-editable . pytest tests/ -q   # 3,802 passed
python3 validation/layer2_compare.py 2>&1 | grep -E "OVERALL|PRECIS|RECALL|F1"
# expect F1 93.8% / P 91.7% / R 96.0% / TP 744 / FN 31 / FP 67
```

If any gate fails, **stop and escalate to user**. Do not proceed under regression.

---

## 4. Standing rules (carry forward)

- **TCL/iTcl/Tk/iTk scope only.** No work on Python/JS/Go/Rust/Java/C#/Ruby/PHP/SQL/Erlang/Fortran/Razor.
- **Non-Tcl languages MUST NOT break.** Full pytest passes every day. The `_class_helpers.py` dispatch path (Tcl→side-table; non-Tcl→`_parse_bases` regex) is sacrosanct. New validation tooling guards on `symbol.language == "tcl"` before doing anything.
- **No commits/pushes/PRs without explicit user permission.** P1.4 produces uncommitted artifacts; commit at end-of-phase only on user go.
- **Never include Co-Authored-By trailer** in any commit message, push note, or PR body. Strip from any HEREDOC template.
- **`/home/giles/bluice/<repo>/` is READ-ONLY corpus.** Never modify.
- **`/home/giles/.claude/`, `.omc/` (gitignored)** are free to write.
- **Fork has blanket edit exception for TCL parsing scope.** Validation tooling under `validation/` is in scope.
- **No code copy-paste from old bridge** (`tcl-native-parser:src/jcodemunch_mcp/parser/tcl_parser_bridge.tcl`). Behavioral matching against SPEC_v2 is fine.
- **Failures over fallbacks** (Strict-A storage discipline). Applies to architecture, not to cross-language base-code which must be preserved.
- **Decisions stay with user.** Orchestrator surfaces decision points; never unilaterally chooses.
- **Speech-to-text user.** Interpret homophones charitably.

---

## 5. LOCKED decisions (do not re-debate)

1. **Validator-first sequencing.** Mutation testing of position validator runs Days 1–2; κ check Day 5. Rationale: validator P/R is needed before validator-driven signals (omissions sweep, inverted-grep) can be trusted; κ result changes how layer-2 is reported, not the architecture.
2. **Release gate**: cross-tool invariant pass-rate on full 7-repo Tcl corpus. Per-invariant per-repo, vacuity-aware (`satisfied_nonvacuous / total_nonvacuous`). F1 ≥ 95% NOT a gate; F1 reported with Wilson CI stratified by pattern_kind.
3. **Calibrate-before-gate principle**: every new mechanism (position validator, inverted-grep, omissions sweep) gets its own measured accuracy *before* it produces gate-eligible verdicts.
4. **LLM verifier must be substrate-blind** (per critic #3). Never show LLM the bridge's answer before asking it to produce its own. Compare programmatically.
5. **Keep blanket-grep as recall-floor sentinel** (per critic — do not retire). Run as cheap monthly check.
6. **Existing 357-symbol oracle is one signal, not authority.** Decided by Day-5 κ result: stays in portfolio if κ ≥ 0.80 across the three designs; reported as "indicative, not validated" otherwise.
7. **Position validator scope**: target 50-80 LoC initial; cap 300 LoC per critic's silent-failure surface analysis. Emit `unknown` rather than guess (per architect's R2 contract).
8. **Position validator denylist** generated from `interp create; info commands` on pinned Tcl 8.6.14 + iTcl 3.4 + iTk + BWidget — versioned and hashed (per critic finding #4).
9. **Re-implemented BFS** for traversal-layer validation: NOT done in P1.4 (per architect — acceptably non-circular under 3 conditions, but those need separate engineering). For P1.4, traversal validation reduces to *invariants on the tool itself* (e.g., `callees(callees(X)) ⊆ callees(X, depth=2)`).
10. **Composite tools** validated via monotonicity invariants (oracle-free). Score itself never adjudicated.
11. **Tier 3 runtime trace tests** are escalation-only, not standard methodology. Cap: 10 disputed edges max for P1.4.
12. **Architectural commitments deferred to P2**: full Bridge IR refactor with `provenance.witness`, libclang Tcl rule extraction, C4 PositionSubstrate as a *generalizable contract* (P1.4 ships the Tcl plugin only, no cross-language abstraction), per-tool 4-layer Tool Contract YAML rollout (one tool proof of concept only), Adversarial Wiki / dispute CLI.
13. **Cross-language pilot** (Python via pyright): **NOT in P1.4 nor P1.5.** Scope is Tcl validation only per user.
14. **Multi-quarter framing accepted.** P1.4 is first checkpoint, not the program. P1.5+ scope deferred.

---

## 6. RESOLVED decisions (locked at handoff 2026-05-12)

User adjudicated all 4 pending decisions before handoff. Do not re-ask.

1. **Secondary corpus pick**: **all 4** — `tcllib`, `tklib`, `BWidget`, `iWidgets`. Best generalization coverage.
2. **Secondary corpus storage path**: **`/home/giles/git/tcl-corpus/`** (sibling to the fork worktree, NOT under `$HOME/bluice/`, NOT inside the worktree). Each repo lives at `/home/giles/git/tcl-corpus/<reponame>/`.
3. **Commit policy**: **single end-of-phase commit, user reviews first.** All Day-0–Day-5 artifacts stay uncommitted in the worktree. No mid-phase commits. No pushes without explicit user go.
4. **Validator mutation score < 0.90**: **surface as finding, document, continue.** Log surviving mutants in VERDICT.md as "validator silent-failure surface" finding; validator results reported but flagged as not fully calibrated; subsequent days proceed.

---

## 7. Corpus

### Primary (load-bearing — bridge exists to serve these)
| Repo | Path | Notes |
|---|---|---|
| BluIceWidgets | `/home/giles/bluice/BluIceWidgets/` | 4,592 symbols; 332 classes; iTcl/iTk heavy |
| DcsWidgets | `/home/giles/bluice/DcsWidgets/` | 3,810 symbols; 225 classes |
| dhs-tcl | `/home/giles/bluice/dhs-tcl/` | 1,624 symbols; 178 classes |
| dcss | `/home/giles/bluice/dcss/` | 4,848 symbols (procedural); the synchrotron control system |
| dcs-lib-tcl | `/home/giles/bluice/dcs-lib-tcl/` | 116 symbols; 10 classes |

### Secondary (generalization-within-Tcl — pull during Day 0)
| Repo | Source | Why |
|---|---|---|
| **tcllib** | `https://core.tcl-lang.org/tcllib` (fossil clone or tar release) | Tcl standard library; broadest pure-Tcl coverage; minimal iTcl |
| **tklib** | `https://core.tcl-lang.org/tklib` | Tk widget standard library; complements BWidget/iWidgets |
| **BWidget** | `https://sourceforge.net/projects/tcllib/files/BWidget/` (or system `/usr/share/bwidget/`) | iTk-style widget patterns; already partially covered in P1.3 `/usr/share/tcltk` probe |
| **iWidgets** | Ships with iTcl distribution; or fossil `https://core.tcl-lang.org/itcl/` | Pure iTcl/iTk — closest idiom match to bluice/dcss |

**Storage**: `/home/giles/git/tcl-corpus/<reponame>/` (sibling to the fork worktree, per §6 #2). Each repo: index via `jcodemunch-mcp index /home/giles/git/tcl-corpus/<reponame>` on Day 0; confirm clean indexing.

---

## 8. Five-day work plan

### Day 0 (~half day, pre-Day-1)

**Goal:** corpus ready, regression intact.

- Pull secondary corpus to `/home/giles/git/tcl-corpus/` (per §6 #2). Each repo at `/home/giles/git/tcl-corpus/<reponame>/`.
- Index each repo: `jcodemunch-mcp index /home/giles/git/tcl-corpus/tcllib`, etc. (record repo IDs).
- For each: confirm crashes-free indexing; record symbol count + class count; note any first-pass findings (recognized opcode rate, schema-pop variance).
- **Pytest gate**: `uv run --no-project --with pytest --with-editable . pytest tests/ -q` → 3,802 passed.
- Generate position-validator denylist: `tclsh -c 'package require Tcl; package require Itcl; lsort [info commands]' > validation/planes/denylist_tcl_8.6.14.txt` + hash.

**Deliverable**: indexed secondary corpus with repo IDs documented in a Day-0 working note under `dev-docs/verdicts/P1_4_DAY0_LOG.md` (uncommitted).

---

### Day 1 — Position validator fixtures + minimal impl

**Goal:** position validator's adversarial fixture set ready + skeleton implementation.

**Build adversarial fixture set** (per scientist Exp 2; 240 total, 30 per category):

| Cat | Fixture shape | Tests |
|---|---|---|
| 1 | `;` after `#`-comment without newline | comment-state persistence across `;` |
| 2 | `#` inside `{...}` not at line-start | `#` is NOT a comment here (token in brace body) |
| 3 | Escape sequences inside `"..."` (`\"`, `\\`) | quote-escape logic |
| 4 | Nested `{}` inside `"..."` | not a brace_body |
| 5 | Multi-line string continuation with `\` | line-continuation in quote |
| 6 | `[` inside `"..."` | not a nested command |
| 7 | `#` after `{` on same line (`{ # not a comment`) | comment vs body start |
| 8 | Empty body `{}` adjacent to command token | boundary |

Hand-label each fixture's correct classification: `command_position` / `inside_quote` / `inside_comment` / `inside_brace_body` / `arg_position`. **Two annotators** (LLM-LLM with explicit adjudication on disagreements; κ ≥ 0.80 required before fixtures lock).

**Implement minimal position validator** at `validation/planes/position_validator.py` (or `.tcl`):
- Inputs: source bytes + byte_offset
- Outputs: classification ∈ {`command_position`, `inside_quote`, `inside_comment`, `inside_brace_body`, `arg_position`, `unknown`}
- Plus `evidence: {rule_id, prev_sigil, depth}` per architect's R1 contract
- Target: 50-80 LoC; cap 300 LoC per critic. Emit `unknown` rather than guess.

**Pytest gate at EOD.**

---

### Day 2 — Position validator mutation testing

**Goal:** validator P/R measured + mutation score ≥ 0.90 confirmed.

**Run validator against 240 fixtures.** Compute per-category P/R + Wilson CI. Per-category recall ≥ 0.80 required; aggregate ≥ 0.90.

**6 systematic source mutations** (per scientist Exp 2):

| ID | Mutation |
|---|---|
| M1 | Flip `>` to `>=` in brace-depth check |
| M2 | Invert comment-start condition |
| M3 | Swap quote-open/close tracking |
| M4 | Remove escape-character skip |
| M5 | Break multi-line continuation flag |
| M6 | Remove `inside_brace_body` → `command_position` transition |

Each mutant must be killed by ≥1 fixture. **Mutation score = killed / 6 ≥ 0.90 required.**

If mutation score < 0.90: surface to user per §6 pending decision #4. Likely action: add fixture targeting the surviving mutant; document if untestable.

**Output**: `validation/planes/POSITION_VALIDATOR_CALIBRATION.md` with P/R table, mutation score, fixture census.

**Pytest gate at EOD.**

---

### Day 3 — Inverted-grep vs blanket-grep paired comparison

**Goal:** quantify whether the new verification approach is actually better.

**Sample 300 bridge-emitted edges from the full 7-repo corpus**, stratified:
- Bluice/dcss: 200 edges (primary)
- Secondary corpora: 100 edges total (cross-check)
- Within each: stratified by pattern_kind (pattern_a / pattern_b / pattern_a_fqn_multi / callback / unresolved)

**For each edge, run BOTH verification paths**:

1. **Blanket-grep**: `grep -nw '<callee>' <repo>/**/*.tcl` filtered to position-validator's `command_position` results. Classify as TP/FP/FN against hand-labeled truth.
2. **Inverted-grep + LLM**: Substrate-blind — show LLM only the source line + caller's source range. Ask "what command is being called at line N column C?" Compare programmatically to the bridge's emitted callee. Classify TP/FP/FN.

**Pre-register** (hash and write before data collection):
- Edge sample seed
- LLM model + temperature + prompt template
- Stratification bucket definitions
- McNemar's α = 0.05
- Δ_FP threshold = 0.10 (10 percentage points absolute)

**Paired McNemar's test** on the FP outcomes. Report:
- Per-strategy FP rate point estimate + Wilson CI
- McNemar's χ² + p-value
- Per-codebase stratification (bluice vs secondary)

**If McNemar's says blanket-grep is BETTER**: keep blanket-grep as recall-floor sentinel; revise inverted-grep design or drop it. **Do not silently retire blanket-grep.** Per critic.

**Output**: `validation/planes/INVERTED_GREP_CALIBRATION.md`.

**Pytest gate at EOD.**

---

### Day 4 — Cross-tool invariants + composite-tool monotonicity

**Goal:** the actual release gate, run on the full 7-repo Tcl corpus.

**Implement 8 cross-tool invariants** at `validation/planes/invariants/`:

| ID | Invariant | Tool dependencies |
|---|---|---|
| INV-CALL-1 | `find_references(X) ⊇ get_call_hierarchy(X).callers` | layer-2 |
| INV-CLASS-1 | `parent_classes[X]=[P]` ⇒ `P ∈ get_class_hierarchy(X).ancestors` | layer-1 fork-ext |
| INV-PKG-1 | `package_registry(repo).packages ⊇ ⋃ {script.package_requires for f in repo}` | layer-5 fork-ext |
| INV-CH-2 | `get_call_hierarchy(X, depth=N) ⊇ get_call_hierarchy(X, depth=N-1)` (monotonicity) | layer-2 |
| INV-BR-1 | `get_blast_radius(X) ⊇ direct_callers(X)` (1-hop floor) | imports + layer-2 |
| INV-IMP-1 | `get_impact_preview(X) ⊆ get_blast_radius(X)` | both |
| INV-SRC-1 | `get_symbol_source(X).source contains X.name` (modulo aliasing) | layer-1 |
| INV-DEP-1 | `get_dependency_graph(F).imports == grep '^\s*package require' F` | layer-5 |

**Run each invariant on each repo** via existing `validation/harness.py` infrastructure (extend it; don't rewrite).

**Vacuity-aware reporting** (per critic finding #6):
- Numerator = invariant satisfied AND both sides non-empty
- Denominator = both sides non-empty
- Empty-rate reported separately per invariant per repo as a corpus health metric

**Per-invariant gate**: ≥ 0.95 satisfied on non-vacuous cases per repo. **Aggregate gate (release-gate)**: 0 invariant violations across all repos OR all violations documented with cause.

**Composite-tool monotonicity** for `get_pr_risk_profile`:
- `risk(empty_pr) = 0`
- `increase(churn) ⇒ non_decrease(risk_score)`
- `risk_score ∈ [0, 1]`
- 50 synthetic PR profiles with hand-computed expected scores; Spearman ρ ≥ 0.90

**Output**: `validation/planes/INVARIANTS_REPORT.md` with per-invariant per-repo pass-rate + violation log.

**Pytest gate at EOD.**

---

### Day 5 — Oracle κ + stratified F1 + spot-check

**Goal:** decide oracle's fate; produce honest F1 reporting; close blast-radius gap.

**Three κ designs on existing 357-symbol oracle** (per prior strategy discussion):

| Design | Approach | What it measures |
|---|---|---|
| 1 | LLM-LLM independent annotation of 100-symbol stratified resample (κ between annotators) | Oracle internal consistency |
| 2 | LLM-oracle vs v1+v2+sandbox substrate consensus (κ across 100 symbols) | Oracle-substrate agreement |
| 3 | Automated citation check on 95-entry golden set (substring exists at cited line) | Lower-bound data integrity |

**Decision rule**: existing oracle stays in portfolio if (Design 1 κ ≥ 0.80) AND (Design 2 κ ≥ 0.70) AND (Design 3 ≥ 95% citations valid). Otherwise: reported as "indicative, not validated."

**Blast-radius spot-check**: N=40 minimum (N=150 if time allows) per scientist Day-4 power analysis. Pick 5 representative X across the corpus; for each, sample 8-30 entries from `get_blast_radius(X)`; verify there's a call path from each entry to X via BFS on validated layer-2 edges. Wilson CI on miss rate. Gate at upper CI ≤ 0.15 miss rate.

**Stratified per-pattern-kind F1 with Wilson CI** on layer-2: extend `validation/layer2_compare.py` to emit per-pattern-kind breakdown with Wilson 95% CI. Replace aggregate F1 as headline. Aggregate moves to footnote.

**Output**: `validation/planes/ORACLE_VERDICT.md` + updated `validation/layer2_compare.py` with stratification.

**Pytest gate at EOD.**

---

### Day 5 evening / Day 6 morning — VERDICT.md authoring

Write `dev-docs/verdicts/P1_4_VERDICT.md` per §9 deliverable spec.

---

## 9. Deliverable: `dev-docs/verdicts/P1_4_VERDICT.md`

Required sections:

1. **Verdict header** — date, branch, predecessor verdict, budget actual vs planned, headline summary
2. **Per-deliverable status** — each of Day-0…Day-5 with pass/partial/fail + evidence
3. **Position validator P/R + mutation score** (Day 2) — table + Wilson CI per category, mutation score, surviving mutants if any
4. **Inverted-grep vs blanket-grep** (Day 3) — McNemar's p-value, per-strategy FP rate + CI, per-codebase stratification
5. **Cross-tool invariant report** (Day 4) — per-invariant per-repo pass-rate (vacuity-aware), violation log, release-gate verdict
6. **Composite-tool monotonicity** (Day 4) — Spearman ρ + monotonicity violations
7. **Oracle κ verdict** (Day 5) — three designs' results, decision (oracle stays / disqualified)
8. **Blast-radius spot-check** (Day 5) — N, miss rate + Wilson CI
9. **Stratified per-pattern-kind F1 with Wilson CI** (Day 5) — replaces aggregate F1 as headline; aggregate as footnote
10. **Regression evidence** — full pytest 3,802 passed each day (table); non-Tcl language tests all green
11. **Reference frame** — JARVIS Python 84% real-world precision; ISSTA 2024 "Total Recall?" finding; Statfier (ESEC/FSE 2023) methodology analog; Midtgaard 2017 (STVR) backing for PBT-on-static-analysis; EMI (PLDI 2014); Tcl_ParseCommand `TCL_TOKEN_*` as canonical position vocabulary; Tcl SOTA gap (Nagelfar no-iTcl; universal-ctags broken `::`; ttclcheck unmaintained — **JCM is iTcl SOTA by default**)
12. **What P1.4 does NOT prove** (honest gap statement — see §11)
13. **Phase 2 handoff** — catalog deferred items in priority order
14. **Re-run reproducer** — every script + expected output, like P1.3 verdict

---

## 10. Honest gap statement (must appear in §12 of VERDICT.md)

P1.4 does NOT prove the bridge is correct. It produces:
- **Internal consistency** evidence (invariants pass).
- **Calibrated validation tools** (validator + inverted-grep have measured P/R).
- **Generalization-within-Tcl signal** (bridge survives bluice + dcss + 4 OSS Tcl corpora).
- **Honest uncertainty bounds** (Wilson CI, κ, McNemar's, mutation score).
- **Non-Tcl regression protection** (pytest 3,802 each day).

P1.4 does NOT close:
- Absolute truth on bridge output (no Tcl expert in the loop; no Tcl LSP equivalent to pyright/gopls/tsserver).
- Traversal-logic bugs in relational tools that produce internally-consistent wrong answers.
- `get_blast_radius` full-closure validation (only spot-check + invariants).
- Position validator's residual bridge-shape (denylist hand-derived; substrate cross-check shares parser-level biases). Mitigated, not eliminated.
- LLM training-data correlation in inverted-grep adjudication. Mitigated by substrate-blind prompts.
- Long-tail user disputes (no Adversarial Wiki / dispute CLI in P1.4).
- Generalization to Tcl codebases outside the 7-repo sample.

---

## 11. Failure escalation

| Failure mode | Action |
|---|---|
| Pre-flight gate fails | STOP. Escalate to user. Do not proceed under regression. |
| Pytest goes red on any day | Revert that day's work. Escalate immediately. Do not continue until green. |
| Validator mutation score < 0.90 | Surface as P1.4 finding; document untestable code path or add fixture. Per §6 pending decision #4: default = log + continue; user may override to gate. |
| McNemar's says blanket-grep is BETTER | Keep blanket-grep as recall-floor sentinel; document inverted-grep as inferior; revise or drop the new mechanism. Do not silently retire blanket-grep. |
| Any invariant fails on bluice/dcss | Log as bridge bug in VERDICT.md §5; do NOT block P1.4 verdict (P1.4 reports findings, doesn't fix the bridge). |
| All three κ designs < threshold | Existing oracle disqualified. Report layer-2 F1 as "indicative, not validated." Surface to user. |
| Validator > 300 LoC | Stop adding cases. Document silent-failure surface. Surface to user — may need full Tcl_ParseCommand-backed implementation, which is P2 not P1.4. |
| Corpus indexing fails on a secondary repo | Document the failure mode; deindex; reduce secondary corpus to N-1 repos; report finding. Do not block P1.4. |
| Time slips past Day 7 | Stop. Hand off intermediate state to user. Do not extend without user authorization. |

---

## 12. Output paths reference

| Artifact | Path |
|---|---|
| This plan | `dev-docs/plans/PLAN_v2.1_P1_4.md` |
| Day-0 log | `dev-docs/verdicts/P1_4_DAY0_LOG.md` (uncommitted) |
| Position validator | `validation/planes/position_validator.py` (or `.tcl`) |
| Position validator fixtures | `validation/planes/fixtures/position/cat_<N>/<NN>.test` |
| Position validator calibration report | `validation/planes/POSITION_VALIDATOR_CALIBRATION.md` |
| Denylist | `validation/planes/denylist_tcl_8.6.14.txt` + hash |
| Inverted-grep calibration | `validation/planes/INVERTED_GREP_CALIBRATION.md` |
| Invariants | `validation/planes/invariants/inv_<id>.py` |
| Invariants report | `validation/planes/INVARIANTS_REPORT.md` |
| Composite monotonicity | `validation/planes/COMPOSITE_MONOTONICITY.md` |
| Oracle κ verdict | `validation/planes/ORACLE_VERDICT.md` |
| Updated layer-2 compare | `validation/layer2_compare.py` (stratified) |
| Final verdict | `dev-docs/verdicts/P1_4_VERDICT.md` |

All paths under `validation/planes/` are NEW; create the directory on Day 0.

---

## 13. Reference frame for VERDICT.md §11

**Comparison baselines** (cite by URL):
- JARVIS Python call graph: 84% precision on real-world apps — arXiv:2305.05949
- "Total Recall? How Good Are Static Call Graphs Really?" ISSTA 2024 — static tools systematically have poor recall on real programs — ACM DL 10.1145/3650212.3652114
- "On the Soundness of Call Graph Construction in the Presence of Dynamic Language Features" APLAS 2018 — all major Java tools unsound under reflection

**Methodology citations**:
- Statfier (ESEC/FSE 2023): semantic-preserving transformations for analyzer FN/FP — ACM DL 10.1145/3611643.3616272
- Midtgaard "QuickChecking static analysis properties" STVR 2017 — Wiley 10.1002/stvr.1640
- EMI (Yang et al., PLDI 2014): Equivalence Modulo Inputs — ACM DL 10.1145/2594291.2594334
- Capture-recapture for defect estimation — ScienceDirect

**Tcl SOTA**:
- Nagelfar (Tcl Wiki) — no iTcl
- tclint (github.com/nmoroze/tclint) — lint+format, no call graph
- universal-ctags Tcl parser (docs.ctags.io) — `.` instead of `::` namespace separator bug, no call graph
- ttclcheck (xdobry.de) — iTcl-aware but unmaintained
- Tcl Wiki "Static call graph" page — "80% solution" string-search approach
- **JCM is iTcl SOTA by default.** No production tool does call-graph extraction for iTcl with correct namespace resolution.

**Canonical Tcl primitive reference**:
- `Tcl_ParseCommand` — tcl-lang.org/man/tcl8.7/TclLib/ParseCmd.html
- `TCL_TOKEN_*` types define position-token vocabulary

---

## 14. Anti-drift discipline (read this last)

This plan is a 5-day cut. Drift kills it. Specific anti-drift rules:

1. **No new strategy debate.** Six agent rounds produced this plan. If you find a fatal flaw, surface it to the user; do NOT redesign.
2. **No scope expansion.** Tcl-only. Bluice/dcss + 4 secondary. ~30 MCP tools but only the 7 listed in §8 Day 4. Do not validate tools outside the listed set in P1.4.
3. **No "while I'm here" refactors.** Cross-language paths are sacrosanct. Do not edit `tools/*.py` or `parser/*` for non-Tcl languages.
4. **No optimization without measurement.** If a script is slow, measure first; optimize only if it blocks a day's gate.
5. **No re-implementing existing infrastructure.** `harness.py`, `queries.py`, `ground_truth.py`, `layer2_compare.py` get EXTENDED, not rewritten.
6. **No commits without explicit user permission.** Including on green days.
7. **End-of-day discipline.** Each day ends with pytest green + a 100-word status line to the user. Don't roll into the next day silently.
8. **If something doesn't fit P1.4, write it in §13 of VERDICT.md (Phase 2 handoff) and MOVE ON.** Do not let "this would be better with X" eat the budget.

---

## 15. Quick-start for execution session

```
1. Read dev-docs/plans/PLAN_v2.1_P1_4.md (this file)
2. Read dev-docs/verdicts/P1_3_VERDICT.md
3. Read dev-docs/specs/SPEC_v2.md §10
4. Run §3 pre-flight gates. STOP if any fails.
5. §6 decisions are RESOLVED — do not re-ask. Confirm you've internalized them, then proceed.
6. Wait for user go.
7. Day 0: corpus pull + index to `/home/giles/git/tcl-corpus/`. Confirm pytest 3,802.
8. Day 1: position validator fixtures + minimal impl.
9. Day 2: mutation testing. Surface if < 0.90.
10. Day 3: inverted-grep McNemar's. Pre-register hypothesis.
11. Day 4: cross-tool invariants + composite monotonicity.
12. Day 5: oracle κ + stratified F1 + blast-radius spot-check.
13. Day 5 EOD or Day 6 AM: VERDICT.md per §9 spec.
14. End-of-phase: surface to user; await commit go.
```

**Total deliverable: one VERDICT.md + uncommitted artifacts under `validation/planes/`. No source-code changes (bridge stays as-is). All findings logged for P1.5+ disposition.**

---

End of plan. The next session has everything it needs.
