# Bridge-vs-Gold Validation v2 — Phase 5.2.8 Staged-Gate Measurement

**Status:** YELLOW — strict-diff gate not met; relaxed-diff progress real but partial
**Date:** 2026-05-17
**Run:** P5.2.8 (post-5.2.7 walker, bridge sweep + relaxed `bridge_diff.py` + strict `bridge_diff_v2.py`)
**Convention version of gold baseline:** v1.3
**Bridge under test:** `tcl-disasm-bridge` @ `37a99f2` (P5.2.7 closeout)
**Tooling:** `validation/bridge_outputs/tools/{run_bridge_on_gold.py, bridge_diff.py, bridge_diff_v2.py}` — bridge_diff_v2 added this phase; strict `(name, kind, line ±2)` Jaccard with greedy matching.

---

## 1. Headline numbers

| Metric | P4.3 baseline | Post-5.2.7 | Δ |
|---|---|---|---|
| **Relaxed-diff recall** (name-only multiset) | 0.387 | **0.428** | +4.1 pts |
| **Strict-diff recall** (name, kind, line ±2) | — (not measured) | **0.2609** | new |
| Strict-diff precision | — | **0.9326** | new |
| Strict F1 | — | 0.4077 | new |
| Total gold callees | 2388 | 2388 | — |
| Total bridge `call_references` | 1610 | 1158 | −452 |
| Total bridge `callees` records | 0 | **668** | +668 (new field) |
| Relaxed shared | 924 | 1022 | +98 |
| Relaxed bridge_miss | 1464 | 1366 | −98 |
| Relaxed bridge_extra (non-denylist) | 288 | **136** | **−152** |
| Relaxed bridge_extra (Tier-filtered) | 398 | **0** | **−398** |
| Strict matches | — | 623 | new |
| Strict miss | — | 1765 | new |
| Strict extra | — | **45** | new |
| Strict kind_mismatches (diagnostic) | — | 4 | new |

**Phase 5.2.8 verdict — STAGED GATE NOT MET.**
* Strict recall 0.2609 is **below the 0.65 gate** in spike §7.5 disposition matrix.
* Strict precision 0.9326 is high — **what the bridge does emit is correct 93% of the time.**
* The gap is **coverage**, not correctness: the bridge emits 668 callees records vs gold's 2388 (28% coverage).

---

## 2. Strict-diff miss breakdown by kind

The 1765 strict misses partition cleanly by convention §4.2 kind:

| Kind | Misses | % of total | Root cause |
|---|---|---|---|
| `static` | 1140 | 64.6% | **Bridge populates `callees` only for method_dispatch (5.2.6) and callback (5.2.7); `static` literal-first-word calls still go to `call_references` only.** Top names: `pack`, `mc`, `grid`, `cb`, `fconfigure`, `frame`, `label`, `append`. |
| `qualified` | 270 | 15.3% | Same root cause — `qualified` calls (e.g. `::msgcat::mc`, `::DCS::ComponentGate`) go to `call_references` only. |
| `method_dispatch` | 201 | 11.4% | 5.2.6 hooks pattern_b + unrecognized + callback (3 paths). Remaining 200 likely come from events I didn't wire (e.g. `expand_args`, eval_var, dict-body recursion). |
| `callback` | 125 | 7.1% | 5.2.7 covers bind/after/fileevent/trace with strcat/list/brace shapes. Remaining likely from `-command "..."` flag values inside Tk widget creation (§6.10) and the multi-command-script case. |
| `unresolved` | 29 | 1.6% | Convention §7.5 disposition matrix marks `?` (unresolved placeholder for genuinely dynamic dispatch) as **ACCEPT** — fundamentally unresolvable static. |

**Key insight: 80% of misses are `static` + `qualified` kinds — call-shape paths that the 5.2.6 / 5.2.7 work intentionally didn't touch.** Per spike §3, all 7 §4.2 kinds (`static | qualified | ensemble | method_dispatch | callback | lambda | unresolved`) should populate `callees`. Only method_dispatch and callback shipped; the other 5 are unfinished walker work.

---

## 3. Strict-diff extras (false positives) — small but informative

Only 45 strict extras total (vs 686 in P4.3 baseline). Both kinds:

| Kind | Extras | Note |
|---|---|---|
| `method_dispatch` | 28 | Bridge emits method_dispatch where gold has `callback` (when the method_dispatch is inside a `[list $obj method]` callback prefix — convention §6.12 says `kind: callback`). 5.2.7's `bind` callback hook catches this at the dispatcher level, but the inner method_dispatch recursion still emits the duplicate. |
| `callback` | 17 | Bridge inferred `callback` for a script-shape gold annotated differently (or didn't annotate at all). Inspection candidates for the §7.5 matrix. |

**4 kind_mismatches reported** — same `(name, line ±2)` but different kind. Tiny number; not a systemic issue.

---

## 4. Per-corpus strict recall

| Corpus | Files | Gold | Bridge | Matches | Recall | Δ vs P4.3 relaxed |
|---|---|---|---|---|---|---|
| bluice-dcss-b5c9866 | 2 | 17 | 8 | 7 | 0.412 | (was 1.000 relaxed) |
| bluice-dhs-tcl-c39768d | 7 | 108 | 40 | 36 | 0.333 | (was 0.889 relaxed) |
| bluice-dcs-lib-tcl-3a09993 | 4 | 24 | 9 | 7 | 0.292 | (was 0.417 relaxed) |
| tcl-corpus-clay | 2 | 104 | 17 | 1 | 0.010 | (was 0.596 relaxed) |
| tcl-corpus-tcllib | 3 | 85 | 4 | 0 | 0.000 | (was 0.624 relaxed) |
| tcl-corpus-BWidget | 1 | 104 | 8 | 3 | 0.029 | (was 0.337 relaxed) |
| git-gui-60046bd | 6 | 744 | 132 | 51 | 0.069 | (was 0.421 relaxed) |
| bluice-BluIceWidgets | 5 | 1016 | 387 | 461 | 0.454 | (was 0.297 relaxed) |
| bluice-DcsWidgets | 6 | 186 | 63 | 57 | 0.306 | (was 0.194 relaxed) |
| tcl-corpus-snit | 1 | 0 | 0 | 0 | n/a | (was n/a) |

(Per-corpus numbers from `AGGREGATE_v2.json`.)

**Reading:** the corpora with the most static/qualified calls (git-gui, tcllib, clay) drop hardest under strict-diff because the bridge isn't emitting those kinds at all. The widget-heavy corpora (BluIceWidgets) actually do BETTER under strict because method_dispatch (5.2.6) is well covered.

---

## 5. §7.5 disposition matrix re-evaluation

Spike §7.5 says "the matrix IS the contract. Phase 5 cannot close until every row above has been addressed per its disposition." Re-evaluating after 5.2.0–5.2.7 + this measurement:

### FIX rows — SHIPPED in 5.2

| Row | Status | Evidence |
|---|---|---|
| Tk widget method_dispatch (`$widget pack/configure/...`) ~600 misses | **SHIPPED 5.2.6** | 5.2.6 emits method_dispatch records; remaining strict-diff miss is partially due to gold/bridge line drift and partially due to the bare `static` callee gap (see §6). |
| §7.1 Tier 2/3/5 denylist (398 extras) | **SHIPPED 5.2.1** | Tier-filtered count: 398 → 0. |
| §5.5 visibility prefixes (42 extras) | **SHIPPED 5.2.3** | Caller-side regression test class locks the contract. |
| §6.8 operator exclusion (25 extras) | **SHIPPED 5.2.4** | 36-test parametric class. |
| §5.10 / §7.5 2-word kept-ensemble | **SHIPPED 5.2.5** | `grid rowconfigure` / `winfo exists` / `image create photo` / `delete object` all emitting 2-/3-word. |
| §6.9/§6.12 callback emission | **SHIPPED 5.2.7** | bind/after/fileevent/trace + 3 script-shapes covered. |
| §5.2 qualified-name preservation (50 misses) | **NOT NEEDED 5.2.2** | Investigation showed bridge already preserves qualified names; mc 51 miss was multiset-dedup semantics, closed by 5.2.6 per-call records. |

### FIX rows — DEFERRED (newly surfaced by v2 strict diff)

| Row | Status | Disposition |
|---|---|---|
| **Static-callee `callees` emission** (1140 strict misses, 64.6% of gap) | **NOT SHIPPED** | Spike §3 per-kind table explicitly includes `static` in the list; 5.2.6/5.2.7 only emitted method_dispatch + callback. **This is the single biggest remaining gap.** Estimated ~50-100 LOC: wire `_add_call_to_parent` callers to also push a kind=static (or kind=qualified for `::`-prefixed names) entry into `callees` with the line number resolved from cmd char-offset. |
| **Qualified-callee `callees` emission** (270 misses, 15.3%) | **NOT SHIPPED** | Subset of above; same wiring. |
| **Remaining method_dispatch coverage** (201 misses, 11.4%) | **NOT SHIPPED** | 5.2.6 covers pattern_b + unrecognized + callback paths. Remaining likely from `expand_args` / `eval_var` / dict-body recursion. ~30-50 LOC. |
| **Remaining callback coverage** (125 misses, 7.1%) | **NOT SHIPPED** | 5.2.7 covers §6.9 dispatchers. Remaining from §6.10 `-command "..."` flag values (where strcat collapse doesn't fire) + multi-command-script case. ~40-60 LOC. |

### ACCEPT rows — DOCUMENTED

| Row | Status |
|---|---|
| `?` unresolved placeholder (29 strict misses) | **ACCEPT** — fundamentally unresolvable static. |
| `tcl::mathfunc::*` math function refs | **ACCEPT** — convention §6.8 marks as optional. |

### DEFER rows — TRACKED

| Row | Target |
|---|---|
| `tailcall` as static callee | Phase 6 convention v1.5 spec track. |
| 1-word `trace` (info / remove) | Phase 6 convention v1.5 spec track. |
| Snit/Clay class declarations | **5.2a** (class-DSL walker). |

---

## 6. Staged-gate verdict

**Spike §7 step 4:** *"5.2 must achieve recall ≥ 0.65 on v2 strict diff before 5.2a starts. If 5.2 alone is below 0.65, hold for triage."*

**Current strict recall: 0.2609.** Gate not met. **HOLD for triage.**

Triage analysis:
* The deficit is not a regression; the relaxed recall improved (0.387 → 0.428) and precision is high (0.93).
* The single dominant cause (80% of strict misses) is `static`/`qualified` callees never being populated into the new `callees` field. The walker emits them only into the legacy `call_references` (deduped, kindless) surface.
* No surprises in the §7.5 matrix; no DEFER candidates surfaced that the spike didn't anticipate.

---

## 7. Recommended next step

**Path A (recommended): 5.2.X — populate `callees` for static/qualified kinds.**

* Extend the existing `_add_call_to_parent` call sites with a parallel `_add_callee_to_parent` emission carrying `{name, line, kind: static}` (or `kind: qualified` when `::` in name).
* ~50-100 LOC across `disasm_bridge.tcl`.
* Re-measure strict recall after. Expected: 1140 + 270 + a fraction of the method_dispatch/callback misses recovered → projected strict recall **~0.70–0.80**.

**Path B: lower the staged-gate threshold.**

* Argue that 0.93 precision validates the bridge's correctness; recall depends on coverage breadth that may be acceptable at a lower threshold.
* No code work; spike §7.5 edit only.

**Path C: defer the strict-diff gate to a later phase.**

* Ship 5.2 closeout under relaxed-diff recall (0.428, +4 pts vs P4.3) and proceed to 5.2a / 5.3.
* Strict-diff coverage becomes a Phase 5.5 closeout or Phase 6 item.

The data is clean and the diagnosis specific. Phase 5.2 ratification awaits the user's call on A / B / C.

---

## 8. Phase 5.2 ledger

Sub-step closeout:

| Sub-step | Commit | Scope | Tests added | Pytest baseline |
|---|---|---|---|---|
| 5.0 | `27627cf` | JCM_TCL_INDEX_VERSION bump-path test + B1 closeout | +3 | 3805 / 13 |
| 5.1 | `c902497` | Symbol.callees + Symbol.args schema + side-table v2 | +8 | 3812 / 12 |
| 5.2.0 | `a373ef9` | callees + args plumbing through bridge JSON + extractor | +3 | (TCL parser locally green) |
| 5.2.1 | `b2258ff` | Tier 1/2/3/5 denylist filter post-pass | +35 | (TCL parser locally green) |
| 5.2.2 | `31177dc` | §5.2 qualified-name preservation — not needed, locked | +4 | (TCL parser locally green) |
| 5.2.3 | `8b33208` | §5.5 visibility-prefix recognition | +4 | (TCL parser locally green) |
| 5.2.4 | `438f71a` | §6.8 operator exclusion | +36 | (TCL parser locally green) |
| 5.2.5 | `b846d51` | §5.10/§7.5 kept-ensemble 2-word emission | +22 | (TCL parser locally green) |
| 5.2.6 | `b25bd51` | §5.3 method_dispatch emission | +7 | (TCL parser locally green) |
| 5.2.7 | `37a99f2` | §6.9/§6.12 callback emission | +13 | (TCL parser locally green) |

Final pytest: 222 (test_tcl_parser.py) + 293 (adjacent storage/call/graph suites) — all green; no regressions across 10 commits.

---

End of Phase 5.2.8 verdict.
