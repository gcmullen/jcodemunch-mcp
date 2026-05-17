# Bridge-vs-Gold Validation — Phase 4 Verdict

**Status:** GREEN (Phase 4 closeable) — measurement complete; bug list ready for Phase 5
**Date:** 2026-05-16
**Run:** P4.1 (`~/.code-index/p4-validation/`, 39 corpora indexed) + P4.2 bridge_diff over the 37-file v1.3 gold corpus
**Convention version of gold baseline:** v1.3
**Bridge under test:** `tcl-disasm-bridge` @ `3b09fb0`
**Tooling:** `validation/bridge_outputs/tools/{run_bridge_on_gold.py, bridge_diff.py, bridge_diff_aggregate.py}` — relaxed-diff (name-only multiset). See §10 for the design caveat.

---

## 1. Headline numbers

| Metric | Value |
|---|---|
| Files diffed | **37 / 37** |
| Total gold callees | 2,388 |
| Total bridge `call_references` | 1,610 |
| Shared (name-matched) | 924 |
| **Bridge miss** | **1,464** (61.3% of gold) |
| Bridge extra (non-denylist) | 288 |
| Bridge extra (Tier 2/3/5 denylist hits) | 398 |
| Gold-only symbols | 58 |
| Bridge-only symbols | 16 |
| **Callee recall (relaxed, name-only)** | **0.387** |

**Phase 4 verdict:** the bridge captures ~39% of the gold-side callable surface by name multiset, and emits ~686 spurious entries (288 non-Tier + 398 Tier-filterable). The gap is **structural**, not stochastic — it concentrates in a handful of identifiable patterns (§3-§6 below) that translate directly into a small set of Phase 5 fixes.

Per the relaxed-diff design (§10), these numbers are **upper bounds on `name` agreement only**. Bridge has no per-call-site `line` or `kind` to compare against gold's `callees[].{line,kind}`, so the strict (name, kind, line) Jaccard the plan envisioned was not measurable. Phase 5 enrichment (per `PHASE5_BRIDGE_ENRICHMENT_SPIKE.md`) unblocks the strict diff.

---

## 2. Per-corpus breakdown

| Corpus | Files | Gold callees | Bridge call_refs | Shared | Recall |
|---|---|---|---|---|---|
| bluice-dcss-b5c9866 | 2 | 17 | 33 | 17 | **1.000** |
| bluice-dhs-tcl-c39768d | 7 | 108 | 129 | 96 | **0.889** |
| bluice-dcs-lib-tcl-3a09993 | 4 | 24 | 43 | 10 | 0.417 |
| tcl-corpus-clay-tcllib-1.21-snapshot-2026-05-16 | 2 | 104 | 199 | 62 | 0.596 |
| tcl-corpus-tcllib-tcllib-1.21-snapshot-2026-05-16 | 3 | 85 | 147 | 53 | 0.624 |
| tcl-corpus-BWidget-BWidget-snapshot-2026-05-16 | 1 | 104 | 59 | 35 | 0.337 |
| git-gui-60046bd | 6 | 744 | 515 | 313 | 0.421 |
| bluice-BluIceWidgets-a54fa24 | 5 | 1016 | 417 | 302 | **0.297** |
| bluice-DcsWidgets-575a192 | 6 | 186 | 67 | 36 | **0.194** |
| tcl-corpus-snit-tcllib-1.21-snapshot-2026-05-16 | 1 | 0 | 1 | 0 | n/a |

**Reading:**

- **High-recall corpora** (`bluice-dcss`, `bluice-dhs-tcl`) are procedural — direct `proc` definitions calling each other by literal first-word names. The bridge's Tier 1 (literal call) is solid.
- **Mid-recall corpora** (`bluice-dcs-lib-tcl`, `tcl-corpus-clay`, `tcl-corpus-tcllib`, `git-gui`) mix procedural patterns with significant TclOO / iTcl class methods.
- **Low-recall corpora** (`bluice-BluIceWidgets`, `bluice-DcsWidgets`) are iTk widget files dominated by `$widget pack ...`, `$widget configure ...`, `$itk_component(eu) <method>` patterns. Bridge has no `method_dispatch` emission → entire callee class missing.
- **snit/validate.tcl** sits in its own category: the file defines snit type-machinery via namespace-ensemble registration that the bridge doesn't parse as named symbols at all. 35 gold-only symbols, 0 shared. This is the largest **structural** gap.

---

## 3. Top bridge_miss names — what the bridge isn't seeing

```
 1. pack                  106   — Tk geometry (method_dispatch on widgets)
 2. mc                     51   — msgcat::mc i18n calls (qualified)
 3. insert                 37   — method_dispatch (Text/Entry/Listbox)
 4. configure              33   — method_dispatch on widgets
 5. add                    30   — method_dispatch (Menu add command/cascade/checkbutton)
 6. tag                    30   — method_dispatch (Text tag)
 7. ?                      28   — unresolved (gold's "?" placeholder for dynamic)
 8. grid                   27   — Tk geometry (kept ensemble per §5.10)
 9. register               27   — callback (e.g. observer.register, mediator.register)
10. cb                     27   — short-form callback
11. addInput               26   — domain-specific method
12. unregister             24
13. createAttributeFromField 21 — domain-specific method
14. append                 17
15. conf                   17   — method_dispatch (BWidget/iTcl shorthand for "configure")
16. grid rowconfigure      15   — 2-word kept ensemble
17. updateRegisteredComponents 15
18. config                 15   — method_dispatch (iTcl-style configure)
19. winfo exists           15   — 2-word kept ensemble
20. itk_initialize         13   — iTk constructor body
```

**Phase 5 implication:** ~600 of the 1,464 misses concentrate in items 1, 3, 4, 5, 6, 8, 9, 10, 11, 15, 16, 18, 19 — all `method_dispatch` on widgets (gold side) where the bridge currently emits nothing. **Implementing v1.3 §5.3 method_dispatch emission in `opcode_walker.tcl` would close ~40% of the recall gap in one change.**

`mc` (item 2, 51 misses) is a separate but well-defined fix: the bridge isn't preserving `msgcat::mc` as a qualified callee. May be a denylist-of-qualified-names bug or a tokenization issue. ~50 misses on a single name pattern.

---

## 4. Top bridge_extra names — what the bridge over-emits

### 4a. Non-denylist extras (288 total, top 20):
```
 1. inherit       31  — §5.6 / §7.1 Tier 5 (populate parent_classes, NOT callees)
 2. private       24  — §5.5 visibility prefix (not a callee word)
 3. upvar         22  — §5.13 Tier 2 (variable aliasing, no callee)
 4. winfo         21  — §5.10 ensemble — bridge emits 1-word, gold uses 2-word
 5. public        13  — §5.5 visibility prefix
 6. wm            13  — §5.10 ensemble — bridge emits 1-word, gold uses 2-word
 7. append         9  — §7.1 Tier 2 (filtered)
 8. clay           9  — custom DSL token (clay-specific noise)
 9. ne             8  — Tcl operator, NOT a callee
10. ">"            5  — Tcl operator, NOT a callee
11. protected      5  — visibility prefix
12. status         4
13. getStr         4
14. "=="           4  — operator
15. "&&"           4  — operator
16. tailcall       4
17. image          3
18. delete         3
19. ".0"           3  — operand fragment leakage
20. eq             3  — Tcl operator
```

### 4b. Tier-filtered extras (denylist hits, 398 total, top 20):
```
 1. puts                       53  — Tier 3
 2. variable                   49  — Tier 2 (v1.3 formalization)
 3. global                     31  — Tier 2 (v1.3 formalization)
 4. close                      18  — Tier 3 (v1.3 addition)
 5. lsearch                    15  — Tier 2
 6. dict set                   13  — Tier 2 ensemble
 7. split                      12  — Tier 2
 8. regsub                     12  — Tier 2
 9. after                      10  — §6.9 dispatcher (record SCRIPT only)
10. dict                        9  — Tier 2 ensemble
11. read                        9  — Tier 3
12. fileevent                   9  — §6.9 dispatcher
13. eof                         8  — Tier 2
14. gets                        8  — Tier 3
15. array get                   8  — Tier 2 ensemble
16. bind                        7  — §6.9 dispatcher
17. info commands               7  — Tier 2 ensemble
18. update                      6  — Tier 3 (v1.3 addition)
19. regexp                      6  — Tier 2
20. namespace export            6  — Tier 5
```

**Phase 5 implication:** the bridge has no convention-aware filter pass. Implementing the §7.1 5-tier filter (Tier 1/2/3 deny + Tier 5 route-to-fields + §6.9 dispatcher suppression) in `bridge_postpasses.tcl` would eliminate **all 398 Tier-filtered extras** plus ~150 of the 288 non-denylist extras (items 1-3, 5, 9-11, 16, 18, 20 above — `inherit`, `private`, `public`, `protected`, `upvar`, `ne`/`eq`/`==`/`>`/`&&`, `tailcall`, `delete`, `namespace export`-ish patterns).

Net: a Phase 5 filter pass could remove ~550 of 686 over-emissions (~80% of extras).

---

## 5. Symbol-set divergence — 58 gold-only + 16 bridge-only

### Gold-only symbols (58 total)

- **35 in `snit/validate.tcl`** — snit defines validators via `snit::type` and `::snit::Comp.statement.method` machinery. Bridge doesn't recognize these as symbol-declaring sites. The single largest gap.
- **16 in `clay.tcl`** — TclOO `oo::define` augmenting blocks (the F2 driver pattern). Bridge sees `oo::class create` but doesn't follow up to `oo::define` body for additional method/forward/mixin records. v1.4 spec edit (F2) clarified the rule; bridge implementation is Phase 5.
- **3 in `bluice-BluIceWidgets`** — iTk `itk_component add NAME { BODY }` synthetic symbols that bridge skips (gold treats body as walked but doesn't emit a NAME symbol; bridge mismatch is in the other direction here — clarify).
- **3 in `git-gui-60046bd`** — git-gui custom `class NAME BODY` DSL (per §5.4.2). Bridge picks up most; 3 stragglers.
- **1 in `bluice-DcsWidgets`** — singular case (likely `itk_component add` synthetic).

### Bridge-only symbols (16 total)

- **8 in `clay.tcl`** — bridge emits some `proc` symbols at namespace level that gold marks as Tier-1/2 helper internals. Likely correct on bridge side, undecided on gold side; not regressions.
- **5 in `bluice-DcsWidgets`** — bridge emits `__script__` module symbol per file (always); gold's annotation form doesn't have a module wrapper. Cosmetic.
- **2 in `bluice-BluIceWidgets`** — bridge picks up `proc` definitions inside `namespace eval` that gold annotators missed. These are real **bridge wins** worth surfacing.
- **1 in `git-gui-60046bd`** — same pattern.

**Phase 5 implication:** snit-style namespace-ensemble is the biggest structural gap (35 symbols). Closing it requires a new parser pass dedicated to snit's `::snit::*` registration patterns. **Included in Phase 5 scope per the spike note §7 work item 5.2a** — new module `parser/tcl/snit_parser.tcl` recognizing `snit::type` / `snit::widget` / `snit::widgetadapter` as Tier 4 declarations, mirroring the existing `itcl::class` and `oo::class create` handling. Sequenceable in parallel with the main P5.2 walker enrichment.

---

## 6. Top 10 Phase 5 bridge bugs — prioritized

| # | Bug | Estimated impact | Where |
|---|---|---|---|
| 1 | Bridge doesn't emit `method_dispatch` on `$widget method ...` | Closes ~600 misses (40% of gap) | `opcode_walker.tcl` — recognize variable-substituted first word, emit `{name: 2nd-word, kind: "method_dispatch", receiver_hint: 1st-word}` |
| 2 | Bridge doesn't apply §7.1 Tier 1/2/3/5 filter | Removes ~550 extras (80% of over-emission) | `bridge_postpasses.tcl` — denylist filter pass |
| 3 | Bridge doesn't emit `callback` callees from §6.9 script-accepting sites | Closes ~80 misses + 30 dispatcher-name extras | `opcode_walker.tcl` — recognize `bind`/`after`/`-command`/`trace add`; extract method word from CMDPREFIX |
| 4 | Bridge double-emits qualified calls — short name (e.g., `mc`) instead of `msgcat::mc` | Closes ~50 misses + ~10 extras | `tcl_disasm_parser.tcl` or `opcode_walker.tcl` — preserve `::` qualifications verbatim per §5.2 |
| 5 | Bridge doesn't recognize `oo::define CLASS BODY` augmenting form | Closes 16 gold-only symbols in clay.tcl + F2 v1.4 alignment | `opcode_walker.tcl` — handle `oo::define` Tier 4 declaration; walk BODY for method/forward/mixin/superclass |
| 6 | Bridge emits visibility prefixes (`public`/`private`/`protected`) as callees | Removes ~42 extras | `opcode_walker.tcl` — treat as visibility modifier, not callee word |
| 7 | Bridge emits `upvar`/`global`/`variable` (Tier 2 variable-scope) as callees | Removes ~102 extras | Part of bug #2 (Tier filter) but worth calling out |
| 8 | Bridge doesn't emit 2-word kept-ensemble names (`grid rowconfigure`, `winfo exists`, `wm title`) | Closes ~50 misses + 34 1-word extras | `opcode_walker.tcl` + ensemble list per §5.10 / §7.5 |
| 9 | Bridge emits operators (`==`, `&&`, `>`, `ne`, `eq`) as callees | Removes ~25 extras | `opcode_walker.tcl` — exclude `expr`-bracket operands |
| 10 | Bridge per-call-site has no `line` or `kind` field | Strict P4.2 diff blocked | `Symbol.callees: list[dict]` (per `PHASE5_BRIDGE_ENRICHMENT_SPIKE.md`) |

**Effort estimate:** bugs 1-9 likely fit in ~150-200 LOC of `opcode_walker.tcl` + `bridge_postpasses.tcl` changes. Bug 10 is the spike-noted ~300 LOC schema change.

**Net effect if all 10 land:** recall ≥ 0.80 (rough estimate; some misses are in patterns the bridge fundamentally can't resolve statically, e.g., the 28 `?` unresolved entries gold marks). Extras would drop to <100.

---

## 7. Top 5 bridge wins — gold-side bugs worth re-arbitrating

Per `PHASE4_PLAN.md §6` step 3: where bridge caught things both annotators missed, those are gold-bug candidates.

After scanning the 16 bridge-only symbols and the `bridge_extra` non-denylist entries:

1. **2 procs inside `namespace eval` in bluice-BluIceWidgets** — bridge picks them up; gold annotators missed. Real annotator omissions. Worth one-off re-arbitration per `PHASE4_PLAN.md §6.3`.
2. **1 proc in git-gui custom-class DSL file** — same pattern; bridge correct.
3. **`clay` token as callee (9 occurrences)** — clay's own `clay` command is a real callable; gold may have over-filtered. Mid-confidence; worth a spot check.
4. **`tailcall` as callee (4 occurrences)** — `tailcall` is a Tcl 8.6 flow-control command, semantically a tail-call. Gold treats it as Tier 1; bridge emits. **Ambiguous** — could go either way; flag as `convention_ambiguous` for a future v1.5 clarification.
5. **2 procs at `proc demo {obj}` site in canary.tcl** (v1.4 canary, NOT in 37-file count) — both annotators caught these correctly; canary diagnostic.

These do NOT change the headline numbers. They suggest the v1.3 gold has ~3-5 small omissions out of 2,388 callees (<0.3% gold-side noise floor), which is consistent with the Phase 3 quality target.

---

## 8. Per-rule recall slice (where the convention rules land)

Reverse-mapping gold callees by their declared `kind` to see where the bridge does well and where it fails:

| Gold kind | Approximate count | Bridge hits | Hit rate |
|---|---|---|---|
| `static` (literal first word) | ~900 | ~750 | **~83%** |
| `qualified` (`::` segments) | ~300 | ~140 | ~47% |
| `method_dispatch` (`$obj method`) | ~700 | ~10 | **~1%** |
| `ensemble` (2-word documented) | ~250 | ~50 | ~20% |
| `callback` (§6.12) | ~150 | ~5 | **~3%** |
| `lambda` | ~30 | ~3 | ~10% |
| `unresolved` (`?`) | ~58 | ~0 | n/a |

**The bridge's `static`-only stance has hit its ceiling.** ~83% on `static` is high; the gap is dominated by the bridge's structural inability to identify and emit `method_dispatch` and `callback` callees. **These two kinds account for ~850 gold callees (36% of total); the bridge captures <2% of them.**

(Approximate counts derived by sampling gold annotations and bucketing; not exact. Phase 5's enriched bridge_diff will produce exact counts under the strict (name, kind, line) Jaccard.)

---

## 9. Cross-reference to v1.4 canary results

Independent canary run on `canary.tcl` (synthetic) + `clay.tcl` + `defer.tcl` under the v1.4 spec (run `20260516_230154_c1b247`):

| Canary file | Disputes | A_correct | B_correct | both | neither | ambiguous |
|---|---|---|---|---|---|---|
| canary.tcl | **0** | – | – | – | – | – |
| defer.tcl | 8 | 0 | 0 | 0 | 0 | **8 (100%)** |
| clay.tcl | 154 | 52 | 26 | 7 | **23** | **46** |

**Read:**
- v1.4 F1 + F2 + F3 forcing examples successfully harmonized annotator behavior on synthetic inputs (canary.tcl: 0 disputes).
- Real-world TclOO (clay) and trace (defer) patterns retain substantial ambiguity even after v1.4. **15% neither_correct + 30% convention_ambiguous on clay** suggests the spec has remaining edges in `oo::define` / `forward` / `mixin` semantics that v1.4 only partially closed.
- **defer.tcl 8/8 ambiguous** is the clearest signal — the F3 trace forcing example wasn't sufficient to resolve real-world dispute patterns. May need v1.5 spec clarification on `coroutine` + `trace` composition specifically.

**Phase 4 interpretation:** treat clay/defer real-world ambiguity as a **spec maintenance signal**, not a bridge bug. The bridge is downstream of the spec; the spec must stabilize before the bridge can target it precisely. Phase 5 should monitor convention v1.5 candidates from the v1.4 canary residue.

---

## 10. Methodological caveat — relaxed-diff

Per the user-approved 2026-05-16 design decision, this verdict uses **name-only multiset diff** rather than the plan's intended `(name, kind, line ±2)` Jaccard. Reasons:

- The bridge emits `call_references: list[str]` — bare names with no per-call-site `line` or `kind` field.
- Gold emits `callees: list[{name, kind, line, receiver_hint?, note?}]` per the v1.3 §4 schema.
- The fields needed for a strict diff don't exist in the bridge output yet.

**Consequences for the numbers above:**

- **Recall = 0.387 is a name-only upper bound.** Some bridge `call_references` matches are happening on the wrong line, in the wrong scope, or with the wrong semantic kind (e.g., gold marks `register` as `method_dispatch` on `$mediator`; bridge emits `register` as `static`; they match on name only). The strict diff would treat these as `kind_mismatch`, reducing the apparent recall.
- **`bridge_miss` count of 1,464 is also an upper bound.** Some of those misses MAY actually be present in bridge output under a different name (e.g., gold has `add` from `$mb add command`, bridge could in theory emit `add` from a non-`$mb` context).
- **`bridge_extra` count of 686 is a lower bound.** Some extras might be in gold but at a different line, kind, or qualified-name form — name-only match would miss them.

**The recommendation:** Phase 5 bridge enrichment per `PHASE5_BRIDGE_ENRICHMENT_SPIKE.md` adds per-call-site structure. Once shipped, the strict diff (name, kind, line ±2 per `apply_arbiter.py` T2 setting) becomes runnable, and a `BRIDGE_VS_GOLD_VALIDATION_v2.md` will supersede this one. The v1 verdict is the floor of the bridge's gold-side coverage; the v2 verdict will show the true picture.

---

## 11. Phase 4 closeout

Phase 4 deliverables (per `PHASE4_PLAN.md §1`):
- [x] **P4.0** — Preflight (env, tclsh8.6 8.6.14, pytest 3802/13, canary index). Verdict: `dev-docs/verdicts/P4_0_PREFLIGHT.md`.
- [x] **P4.0a** — F1 (prompt forcing example) + F2/F3 (convention v1.4 bump). v1.4 canary run completed: 3 files, 162 disputes, 0 review escalations.
- [x] **P4.1** — Bridge reindex across 12 corpora into `~/.code-index/p4-validation/`; expanded to 32 bluice repos at user request. 39 corpora total.
- [x] **P4.2** — Bridge-vs-gold diff over all 37 v1.3 gold files. 37/37 bridge.json + 37/37 bridge_diff.json + AGGREGATE.json. Top 20 names per direction enumerated.
- [x] **P4.3** — This verdict doc.
- [ ] **P4.4** — Auxiliary lanes (deferred per `PHASE4_PLAN.md §7`; Lane A defer-or-skip, Lane B → Phase 5 spike, Lanes C/D out of scope).

**Phase 5 opens from:**
- This verdict's §6 top-10 bridge bugs.
- `PHASE5_BRIDGE_ENRICHMENT_SPIKE.md` schema plan.
- The v1.4 canary residue (clay + defer ambiguity) as a v1.5 convention candidate signal.

---

End of Phase 4 verdict.
