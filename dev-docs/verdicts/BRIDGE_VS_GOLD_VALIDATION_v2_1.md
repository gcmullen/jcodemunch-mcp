# Bridge-vs-Gold Validation v2.1 — Phase 5.2a Closeout Verdict

**Status:** <TBD: PASS / HOLD>
**Date:** 2026-05-17 (skeleton); 5.2a.6 closeout TBD
**Run:** 5.2a.0 through 5.2a.5 (re-measurement)
**Convention version of gold baseline:** v1.3
**Bridge under test:** `tcl-disasm-bridge` @ post-5.2a.5
**Tooling:** `validation/bridge_outputs/tools/bridge_diff_v2.py` — strict `(name, kind, line ±2)` Jaccard with greedy matching

---

## 0. Two-pass summary

| Phase | Strict recall | Strict precision | F1 | Status |
|---|---|---|---|---|
| **P5.2.X baseline (pre-5.2a)** | 0.7182 | 0.8808 | 0.7912 | Gate passed; 5.2a unblocked |
| **P5.2a.5 (final post-5.2a re-measurement)** | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | <TBD: PASS / HOLD / ACCEPT> |

The 5.2a work focused on generic class-DSL walker + annotations for iTcl / iTk / TclOO `oo::define` augmenting / Snit / Clay. Baseline gate (0.65 strict recall) was met by P5.2.X; 5.2a.0–5.2a.4 implement DSL handling; 5.2a.5 re-measures strict diff to detect any new miss/extra categories surfaced by DSL walking.

---

## 1. Headline numbers — final (post-5.2a.5)

| Metric | P5.2.X baseline | **P5.2a.5 (final)** | Δ vs P5.2.X |
|---|---|---|---|
| **Strict-diff recall** (name, kind, line ±2) | 0.7182 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict-diff precision** | 0.8808 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict F1** | 0.7912 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Total gold callees** | 2388 | <TBD post-5.2a.5 measurement> | — |
| **Total bridge `callees` records** | 1947 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict matches** | 1715 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict miss** | 673 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict extra** | 232 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| **Strict kind_mismatches** | 13 | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |

---

## 2. Strict-diff miss breakdown by kind

Post-5.2a.5 re-measurement:

| Kind | Misses | % of total | Root cause |
|---|---|---|---|
| `static` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `qualified` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `method_dispatch` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `callback` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `lambda` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `constructor` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `method` (DSL-derived) | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |
| `unresolved` | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> | — |

---

## 3. Strict-diff extras (false positives)

Post-5.2a.5 re-measurement:

| Kind | Extras | Note |
|---|---|---|
| `method_dispatch` | <TBD post-5.2a.5 measurement> | — |
| `callback` | <TBD post-5.2a.5 measurement> | — |
| `method` (DSL-derived) | <TBD post-5.2a.5 measurement> | — |
| Other | <TBD post-5.2a.5 measurement> | — |

---

## 4. Per-corpus strict recall

| Corpus | Files | Gold | Bridge | Matches | Recall | Δ vs P5.2.X |
|---|---|---|---|---|---|---|
| bluice-dcss-b5c9866 | 2 | 17 | <TBD> | <TBD> | <TBD> | <TBD> |
| bluice-dhs-tcl-c39768d | 7 | 108 | <TBD> | <TBD> | <TBD> | <TBD> |
| bluice-dcs-lib-tcl-3a09993 | 4 | 24 | <TBD> | <TBD> | <TBD> | <TBD> |
| tcl-corpus-clay | 2 | 104 | <TBD> | <TBD> | <TBD> | <TBD> |
| tcl-corpus-tcllib | 3 | 85 | <TBD> | <TBD> | <TBD> | <TBD> |
| tcl-corpus-BWidget | 1 | 104 | <TBD> | <TBD> | <TBD> | <TBD> |
| git-gui-60046bd | 6 | 744 | <TBD> | <TBD> | <TBD> | <TBD> |
| bluice-BluIceWidgets | 5 | 1016 | <TBD> | <TBD> | <TBD> | <TBD> |
| bluice-DcsWidgets | 6 | 186 | <TBD> | <TBD> | <TBD> | <TBD> |
| tcl-corpus-snit | 1 | <TBD> | <TBD> | <TBD> | <TBD> | <TBD> |

(Per-corpus numbers from `AGGREGATE_v2_1.json`.)

---

## 5. §7.5 disposition matrix re-evaluation (5.2a focus)

The §7.5 matrix tracks all miss + extra categories and their disposition. 5.2a adds DSL handling; this section re-evaluates which rows were closed and which remain.

### FIX rows — SHIPPED in 5.2a

| Row | Status | Evidence |
|---|---|---|
| Snit/Clay class-DSL declaration + method emission (~54 gold-only symbols) | **5.2a.0–5.2a.1** | New `dsl_annotations.tcl` + `dsl_walker.tcl` modules. 5.2a.1 (snit) locks `snit::type`/`snit::widget` declaration walking; `validate.tcl` recall 0.000 → 0.972. 5.2a.2+ cover clay/oo::define/iTcl/iTk. |
| iTcl `itcl::class` + `itcl::widget` declarations | **5.2a.2** | <TBD post-5.2a.5 measurement> |
| TclOO `oo::class create` + `oo::define` augmenting | **5.2a.2** | <TBD post-5.2a.5 measurement> |
| Clay `clay::define` declarations | **5.2a.2** | <TBD post-5.2a.5 measurement> |
| iTk `itk_component add` + CONFIG-BODY walk | **5.2a.3** | <TBD post-5.2a.5 measurement> |
| DSL-impl-file rule (§5.4.2 P3.1) — suppress body recursion for `proc class/type/define { name body }` | **5.2a.4** | <TBD post-5.2a.5 measurement> |

### FIX rows — DEFERRED (newly surfaced by 5.2a)

| Row | Status | Disposition |
|---|---|---|
| <TBD: identified during 5.2a implementation> | NOT SHIPPED | <TBD post-5.2a.5 measurement + 5.2a.6 triage decision> |

### ACCEPT rows — DOCUMENTED (unchanged from P5.2.X)

| Row | Status |
|---|---|
| `?` unresolved placeholder (29 strict misses in P5.2.X) | **ACCEPT** — fundamentally unresolvable static. |
| `tcl::mathfunc::*` math function refs | **ACCEPT** — convention §6.8 marks as optional. |

### DEFER rows — TRACKED (cross-ref PHASE5_2A_GAPS.md)

Per `dev-docs/plans/PHASE5_2A_GAPS.md`:

| Row | Target | Status |
|---|---|---|
| G1 — Gold double-emission of `::snit` / `::snit::` namespaces | Phase 6 gold re-arbitration | <TBD post-5.2a.5 measurement> |
| G2 — Constructor/destructor wire-kind convention (global) | Needs gold-side audit; potential 5.5 fix | <TBD post-5.2a.5 measurement> |
| G3 — DcsWidgets 0.290 recall (method_dispatch + callback depth) | Future 5.2.X refinement or Phase 6 | <TBD post-5.2a.5 measurement> |
| G4 — DSL-impl-file rule (§5.4.2 P3.1) broken on `git-gui/lib/class.tcl` | 5.2a.4 (SHIPPED) | <TBD post-5.2a.5 measurement> |
| G5 — `oo::define` augmenting onto unresolved class name | ACCEPT (Phase 6 cross-file resolution) | — |
| G6 — `forward` target callee not recorded | ACCEPT (convention §8.8 documented limitation) | — |
| G7 — `?` dynamic-dispatch placeholders (28 misses) | DEFER pending gold consistency audit | <TBD post-5.2a.5 measurement> |
| G8 — `tcl::mathfunc::*` math function refs in `expr {...}` | DEFER pending gold consistency audit | <TBD post-5.2a.5 measurement> |

---

## 6. Verdict

**Post-5.2a.5 re-measurement verdict: <TBD: PASS / HOLD>**

Gating criteria for 5.2a closeout:
1. **All FIX-shipped rows landed** AND code compiles green AND tests passing.
2. **No unexpected new miss/extra categories** surfaced by DSL walking (v2 diff matched existing disposition matrix).
3. **Strict-diff metrics stable or improved** vs P5.2.X baseline (0.7182 recall, 0.8808 precision).

**Expected outcomes (pre-measurement):**
- Snit (5.2a.1) achieved 0.972 recall on `validate.tcl`; per-corpus snit should rise from n/a to ≥0.80.
- Clay (5.2a.2) and iTcl/TclOO (5.2a.2) should close gold-only symbol gaps and improve recall on clay / git-gui corpora.
- iTk (5.2a.3) should improve DcsWidgets recall modestly (G3 impact limited; deeper fixes deferred).
- DSL-impl-file rule (5.2a.4) should prevent over-emission on `git-gui/lib/class.tcl`.

<TBD post-5.2a.5 measurement: INSERT ACTUAL VERDICT HERE>

---

## 7. Recommendation

**Post-5.2a.5 triage decision: <TBD: proceed to Phase 6 / hold for cleanup / etc.>**

Pending measurement completion:
- If verdict is **PASS** + all FIX rows shipped + disposition matrix rows resolved → **proceed to Phase 6** (convention v1.5 expansion, cross-file resolution, auto-derive DSL grammar).
- If verdict is **HOLD** + new gap categories surface → **5.2a.6 triage** to decide FIX-in-5.2a vs DEFER-to-5.5-or-Phase-6 per existing principles.
- If precision regresses unexpectedly → investigate dedup opportunities in `_add_callee_to_parent` (see P5.2.X §7).

---

## 8. Phase 5.2a ledger

Sub-step closeout:

| Sub-step | Commit | Scope | Tests added | Pytest baseline |
|---|---|---|---|---|
| 5.2a.0 | bf64003 | DSL walker skeleton + empty annotations | +3 | 524 combined (adjacent storage/call/graph suites) |
| 5.2a.1 | 5d73e4d | Snit class-DSL dispatch (`snit::type`/`snit::widget`) | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| 5.2a.2 | <TBD post-5.2a.2 commit> | Clay + oo::define + iTcl class-DSL dispatch | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| 5.2a.3 | <TBD post-5.2a.3 commit> | iTk `itk_component add` + CONFIG-BODY walk | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| 5.2a.4 | <TBD post-5.2a.4 commit> | DSL-impl-file rule (§5.4.2 P3.1) — suppress recursion in impl-procs | <TBD post-5.2a.5 measurement> | <TBD post-5.2a.5 measurement> |
| 5.2a.5 | <TBD post-5.2a.5 commit> | Strict-diff v2 re-measurement (no code; measurement only) | — | — |
| 5.2a.6 | <TBD this commit> | Verdict doc + closeout triage + disposition matrix finalization | (this file) | <TBD post-5.2a.5 measurement> |

**Expected final pytest (5.2a.6):** 231 (test_tcl_parser.py) + 524 (adjacent) + <TBD post-5.2a.5 measurement> (new DSL tests) — all green; no regressions across 5.2a pipeline.

---

## Appendix: Measurement gaps (all TBD until 5.2a.5 runs)

Placeholders in this document requiring post-5.2a.5 re-measurement:

### Section 0
- P5.2a.5 strict recall value
- P5.2a.5 strict precision value
- P5.2a.5 strict F1 value
- Pass/hold/accept determination

### Section 1
- P5.2a.5 strict recall
- P5.2a.5 strict precision
- P5.2a.5 strict F1
- Gold callees count (may differ if gold version changes)
- Total bridge `callees` records post-DSL walking
- Strict matches count
- Strict miss count
- Strict extra count
- Strict kind_mismatches count

### Section 2
- All miss kind counts and percentages (static, qualified, method_dispatch, callback, lambda, constructor, method, unresolved)

### Section 3
- All extra kind counts (method_dispatch, callback, method, other)

### Section 4
- All 10 per-corpus rows: bridge count, matches, recall, delta vs P5.2.X

### Section 5
- Evidence + measurement results for each FIX-shipped row (5.2a.0–5.2a.4)
- Any newly surfaced FIX-deferred rows
- Measurement impact on G1–G8 DEFER rows

### Section 6
- Verdict determination (PASS / HOLD)

### Section 7
- Recommendation (Phase 6 / hold for cleanup / etc.)

### Section 8
- Commit SHAs for 5.2a.2, 5.2a.3, 5.2a.4, 5.2a.5
- Tests added counts for 5.2a.1–5.2a.5
- Pytest baseline values for each step
- Final combined pytest count

---

End of Phase 5.2a skeleton.
