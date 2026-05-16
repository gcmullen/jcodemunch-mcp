# Phase 1 gold annotations vs. pre-disasm oracle batches

**Date:** 2026-05-15
**Comparator inputs:**
- Pre-disasm "old gold" baseline: `validation/oracle/layer2_oracle_batch_{small,medium,large,scan3d}.json` (24 distinct files, symbol → expected_callees name list)
- Phase 1 gold: `validation/gold_annotations/conv-v1.0/tcl-8.6/<corpus>-<sha7>/<basename>.gold.json` plus, where present, `<basename>.corrected_gold.json` (8 files, convention versions v1.0 / v1.1 / v1.3; all valid for this comparison)
- Convention used to classify diffs: `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` v1.1

> **Side note:** the smaller `validation/golden_set/edges_v1.jsonl` (95 hand-curated edges across 8 files) is a *deterministic-anchor subset*, not the broader pre-disasm evaluation set. The 24-file oracle batches are what this report uses as the "pre-disassemble golden set."

This report is a symmetric difference summary. **Neither set is treated as authoritative for precision/recall.** Reads are honest: Phase 1 has measurable wins and a small number of real misses; oracle has structural omissions but occasionally records semantic facts Phase 1 chose to filter.

---

## Files in scope

### Overlap (8 files — Phase 1 ⊆ Oracle for file paths)

| File | Phase 1 cv | Arbiter pass? | Oracle batch |
|---|---|---|---|
| `BluIceWidgets/AutoSample.tcl` | v1.1 | no | large |
| `BluIceWidgets/BarcodeView.tcl` | v1.0 | no | small |
| `BluIceWidgets/BeamlineAuthView.tcl` | v1.3 | yes (40 disputes; 36 A / 3 B / 1 neither) | medium |
| `DcsWidgets/Component.tcl` | v1.3 | yes (32 disputes; 19 A / 13 B) | large |
| `dcs-lib-tcl/main/scripts/DcssHardwareServer.tcl` | v1.1 | yes (7 disputes; 2 A / 5 B) | small |
| `dcss/scripts/devices/MFX_MOTOR.tcl` | v1.1 | yes (4 disputes; 0 A / 4 B) | small |
| `dhs-tcl/main/scripts/base/controller/ControllerBase.tcl` | v1.0 | no | medium |
| `dhs-tcl/main/scripts/base/devices/MotorBase.tcl` | v1.0 | no | large |

### Oracle-only (16 files — needs new Phase 1 gold against the v1.3 harness)

```
BluIceWidgets/BeamlineVideo.tcl
BluIceWidgets/Scan3DView.tcl
DcsWidgets/AttributeDisplay.tcl
DcsWidgets/BeamlineChooser.tcl
DcsWidgets/Cif.tcl
DcsWidgets/ComponentGateExtension.tcl
DcsWidgets/MessageBoard.tcl
dcs-lib-tcl/main/scripts/AsyncGets.tcl
dcs-lib-tcl/main/scripts/Clock.tcl
dcs-lib-tcl/main/scripts/Logger.tcl
dcss/scripts/devices/DEG_HORZ.tcl
dhs-tcl/main/scripts/base/devices/DeviceBase.tcl
dhs-tcl/main/scripts/base/devices/IonChamberBase.tcl
dhs-tcl/main/scripts/base/devices/ShutterBase.tcl
dhs-tcl/main/scripts/base/operations/AsyncExec.tcl
dhs-tcl/main/scripts/base/operations/DetectorStop.tcl
```

### Phase-1-only (0 files)

Every Phase 1 file is also in the oracle batches.

---

## Aggregate metrics

Across the 8 overlap files (full-name set intersection of `(qualified_name, callee_name)`):

| Metric | Oracle | Phase 1 | Shared | Oracle-only | Phase1-only |
|---|--:|--:|--:|--:|--:|
| Symbols (distinct `qualified_name`) | 160 | 176 | 160 | 0 | **16** |
| Callees (distinct `(qname, callee_name)`) | 310 | 322 | 286 | 24 | 36 |

- **Symbol-set Jaccard (union):** 160 / 176 = **0.909**
- **Callee-set Jaccard (union of all 8 files):** 286 / 346 = **0.827**
- **Per-file callee Jaccard distribution:** mean 0.861, min 0.606 (`Component.tcl`), max 1.000 (`MFX_MOTOR.tcl`)
- **Symbol containment:** every oracle symbol is present in Phase 1. The 16 Phase-1-only symbols are all `kind: "class"` containers, which the oracle never enumerated.

Per-file callee Jaccard (sorted):

| File | Oracle callees | Phase 1 callees | Shared | Jaccard |
|---|--:|--:|--:|--:|
| `MFX_MOTOR.tcl` | 12 | 12 | 12 | 1.000 |
| `MotorBase.tcl` | 58 | 59 | 58 | 0.983 |
| `ControllerBase.tcl` | 33 | 34 | 33 | 0.971 |
| `AutoSample.tcl` | 59 | 62 | 58 | 0.921 |
| `DcssHardwareServer.tcl` | 14 | 14 | 13 | 0.867 |
| `BarcodeView.tcl` | 4 | 5 | 4 | 0.800 |
| `BeamlineAuthView.tcl` | 80 | 80 | 68 | 0.739 |
| `Component.tcl` | 50 | 56 | 40 | 0.606 |

The two lowest-Jaccard files (`BeamlineAuthView.tcl`, `Component.tcl`) are the v1.3 corrected files; their two-sided diffs are driven by genuine convention disagreements (see §"Difference categories"), not noise.

---

## Difference categories

Counts below are over the 60-callee symmetric difference (24 oracle-only + 36 phase1-only). Each row of the diff was hand-classified against the convention.

### Phase1-only (36 callees + 16 symbol additions)

| # | Category | Convention ref | Count | Verdict |
|---|---|---|--:|---|
| P1 | Class container symbols enumerated | §4.1, §5.4 | 16 | **Phase 1 better** |
| P2 | `eval LITERAL ARGS` collapsed to literal | §5.8.1 (D1) | 5 | **Phase 1 better** |
| P3 | Callback recorded under script-accepting command | §6.9, §6.12 | 4 | **Phase 1 better** |
| P4 | FQN preserved verbatim (`::mediator register`) | §5.2, §7.4 | 6 | **Phase 1 better** |
| P5 | Leading `::` handling (drops vs. keeps) | §5.2 | 2 | Discrepant; verbatim rule is direction-of-source |
| P6 | `method_dispatch` on iTcl `info` | §5.3 | 1 | **Phase 1 better** |
| P7 | Ensemble 2-word naming on Tk dispatchers (`grid rowconfigure`, `grid forget`, …) | §5.10, §7.5 | 5 | Convention edge — see Q |
| P8 | 2-word naming `delete object` | §5.10, §7.5 | 1 | Convention edge |
| P9 | `? [unresolved]` for `$obj $m` / `$cmd` | §5.3, §5.14 | 4 | **Phase 1 better** |
| P10 | Static callee recorded inside `catch { … }` body | §6.5 | 1 | **Phase 1 better** |
| P11 | `::config` recorded as qualified, not method-word | §5.2 vs §5.3 disambiguation | 1 | **Phase 1 better** (convention-correct) |
| P12 | Phase 1 convention violations | §7.1 (Tier 2), §6.9 | ~5 | **Phase 1 worse** |
| P13 | Multi-occurrence callees recorded as duplicates (e.g. two `pack` calls, two `breakConnection`) | (set-collapse artifact) | — | Counts collapse here; visible in line-level data |

#### Representative examples

**P1 — Class symbols added (§4.1):**
All 16 phase1-only symbols are `class` containers: `BarcodeView`, `DCS::Component`, `DCS::ComponentGate`, `DCS::ComponentORGate`, `DCS::ItkWigetWrapper`, `DCS::ManualInputWrapper`, `objectMediator`, `DcssProtocol::DcssHardwareServer`, `Dhs::ControllerBase`, `Dhs::MotorBase`, `AutoSampleWidget`, `AutoSampleSelfWidget`, `AutoSampleCommandWidget`, `AutoSampleConfigWidget`, `BeamlineAuthView`, `BeamlineAuthUserView`. Oracle's schema is method-only and never registered container symbols.

**P2 — `eval LITERAL ARGS` D1 collapse (§5.8.1):**
Five constructors record `eval itk_initialize $args` → `{name: "itk_initialize", kind: "static", note: "via eval D1"}`. Oracle records nothing at these sites.
- `BarcodeView::constructor`, `BeamlineAuthView::constructor`, `BeamlineAuthUserView::constructor`, `AutoSampleWidget::constructor`, `AutoSampleCommandWidget::constructor`.

**P3 — Callback recognition (§6.9 + §6.12):**
- `BeamlineAuthUserView::constructor` → `removeBeamline [callback]` from `bind $w <Delete> [list $this removeBeamline]`.
- `BeamlineAuthView::constructor` → `handleSelection [callback]`.
- `BeamlineAuthView::handleNeedRefreshEvent` and `handleSessionIdChange` each → `updateUserList [callback]` from `after idle [list $this updateUserList]`.
Oracle records the dispatcher (`bind`) but not the callback method name — exactly the inverse of what the convention requires (§6.9 *forbids* recording the dispatcher; §6.12 *requires* recording the method).

**P4 — FQN preserved verbatim (§5.2, §7.4):**
Six edges where the source writes `::mediator register $this` or `::mediator unregister $this`:
- `DCS::Component::register`, `DCS::Component::unregister`, `DCS::ComponentGate::addInput`, `DCS::ComponentGate::deleteAllInput`, `DCS::ComponentGate::deleteInput`, `objectMediator::announceDestruction`.
Phase 1 records `::mediator register` / `::mediator unregister` as `qualified`. Oracle stripped to bare `register` / `unregister`, losing the `::mediator` receiver. §5.2 names this stripping pattern as "always wrong"; §7.4 explains why preservation matters for find-references.

**P9 — Unresolved `var_method` / `var_command` (§5.3, §5.14):**
- `DCS::Component::sendUpdate`, `DCS::ComponentGate::sendUpdate`, `objectMediator::register`, `safeCallback`: phase 1 emits `{name: "?", kind: "unresolved"}` for dynamic-method sites. Oracle records nothing — these sites are invisible in the oracle schema.

**P10 — Body of `catch` walked (§6.5):**
`DcssProtocol::DcssHardwareServer::destructor` records `close [static]` from inside `catch { close $_listener }`. Oracle missed the inner call.

**P11 — `::config getStr` as qualified call (§5.2 + §5.3 second paragraph):**
`AutoSampleSelfWidget::handleHelp` — source has `::config getStr ...`. The convention is explicit: "A literal qualified name in command position (e.g., `::config getStr foo`) is NOT method dispatch — it is a §5.2 qualified call where `::config` is the callee and `getStr foo` are data arguments." Phase 1 records `::config [qualified]`. Oracle records `getStr`, treating it as if `::config` were a receiver — convention-deviant, though the method-word `getStr` is a useful search key.

**P12 — Phase 1 convention violations:**
- `Dhs::ControllerBase::afterPropertiesSet`: `lappend [static]` — `lappend` is on §7.1 Tier 2 and should NOT be recorded.
- `Dhs::MotorBase::constructor`: `namespace current [static]` — `namespace` is on §7.1 Tier 2 and should NOT be recorded.
- `AutoSampleSelfWidget::handleHelp`: `after [static]` — §6.9 explicitly forbids recording `after` as a callee; only its SCRIPT's callee is recorded.
These three are unambiguous Phase 1 errors; two are in v1.0 (grandfathered, no arbiter pass), one in v1.1 (arbiter pass apparently missed it).

### Oracle-only (24 callees)

| # | Category | Convention ref | Count | Verdict |
|---|---|---|--:|---|
| O1 | Tk widget creation calls inside `itk_component add { … }` | §5.4.6 → §5.1 / §5.2 | 9 | **Oracle better** — Phase 1 real miss |
| O2 | `bind` dispatcher recorded as static | §6.9 | 1 | Oracle convention-deviant; Phase 1 correct |
| O3 | Callback for `socket -server [list $this accept]` | §6.9 (narrow) vs §6.12.2 (shape-driven) | 1 | Convention edge |
| O4 | Tier 2 `string` ensemble recorded as static | §7.1 | 1 | Oracle convention-deviant; Phase 1 correct |
| O5 | Method-word from `$obj method` recorded as bare name where Phase 1 used FQN of receiver (`get`, `getStr`, `register`, `unregister`, `delete`) | §5.2 vs §5.3 | 7 | Discrepant; convention favors Phase 1 form |
| O6 | Bare `grid` recorded once where Phase 1 expanded to 2-word phrases | §5.10 / §7.5 (interpretation) | 1 | Discrepant; both defensible |
| O7 | Leading `::` retained (`::DCS::Component::constructor`) | §5.2 verbatim | 4 | Discrepant; convention-correctness depends on source verbatim form |
| O8 | One genuine `get` callee not present in Phase 1 (`BeamlineAuthView::updateUserList`) | §5.3 | 1 | Possible Phase 1 miss — needs source check |

#### Representative examples

**O1 — Widget creation calls missed by Phase 1 (the strongest oracle win):**
- `BeamlineAuthUserView::constructor` oracle records `::DCS::Button`, `DCS::Checkbutton`, `DCS::Entry`, `iwidgets::labeledframe`, `iwidgets::scrolledlistbox` (5). Phase 1 records none of them, although §5.4.6 explicitly says "BODY of `itk_component add` IS walked for inner callees, attributed to the enclosing method." This file is v1.3 with a 40-dispute arbiter pass; the arbiter ruled 36 A-correct, 3 B-correct, 1 neither — so these widget calls were either omitted by both models or removed in adjudication. Either way it is a Phase 1 coverage gap.
- `BeamlineAuthView::constructor` oracle records `button`, `iwidgets::labeledframe`, `iwidgets::scrolledlistbox`, `label` (4) — same pattern, same file.

This is the **only** systematic category in which oracle beats Phase 1 on a convention reading. 9 of the 24 oracle-only callees fall here.

**O2 — `bind` dispatcher (§6.9 violation):**
- `BeamlineAuthUserView::constructor` oracle records `bind`. §6.9 forbids it: "The dispatcher command itself (`bind`, `after`, `fileevent`, `trace add ...`) is NOT recorded as a `static` callee — only the SCRIPT's callee per §6.12 is recorded." Phase 1 correctly omits `bind` and records the callback method instead.

**O3 — `socket -server [list $this accept]` (convention edge):**
- `DcssProtocol::DcssHardwareServer::listen` oracle records `accept`. The source is `socket -server [list $this accept] -myaddr $dcssHost $dcssPort`. §6.9's script-accepting list is `bind`, `after`, `fileevent`, `trace`, `coroutine` — `socket -server` is not on it. But §6.12.2 says "any vendor flag (...) whose value is shaped like a callback. Recognition is value-shape-driven, not flag-name-driven." Either reading is defensible. Phase 1 took the narrow §6.9 list; oracle took the broad §6.12.2 shape rule.

**O4 — Tier 2 `string` recorded (§7.1 violation):**
- `DCS::Component::replace%sInCommandWithValue` oracle records `string`. §7.1 Tier 2 includes `string` and all its subcommands; the convention says do NOT add to callees. Phase 1 correctly omits.

**O5 — Method-word recording without receiver:**
- `Component::register` site oracle records `register`, phase 1 records `::mediator register` (qualified). This is the same data, encoded differently — convention favors Phase 1 form (§5.2). 7 such pairs across the Component / handleHelp files.

**O8 — Possible real Phase 1 miss:**
- `BeamlineAuthView::updateUserList` oracle records `get`, phase 1 has no equivalent. Without re-reading the v1.3 corrected file alongside source line-by-line, I cannot rule out either (a) an annotator omission in Phase 1, or (b) a convention-driven filter (e.g. `$listbox get` treated as `info`/`array` style ensemble — but `get` is not in the §7.1 Tier 2 list). Marking it as a probable Phase 1 miss pending source verification.

---

## Quality call

**Phase 1's gold is better than the pre-disasm oracle on every category except one, and that one is a recoverable coverage gap rather than a structural advantage of the oracle.**

Specifically:

- **Where Phase 1 is decisively better:** symbol enumeration (16 class containers oracle never recorded), `eval`-collapse (§5.8.1), callback recognition (§6.9 + §6.12), FQN preservation (§5.2 + §7.4), unresolved-dispatch annotation (§5.14), `catch`-body walking (§6.5), and convention-correct treatment of `::ns cmd args` qualified calls (§5.2 vs §5.3). These categories account for ~25 of the 36 phase1-only callees and all 16 phase1-only symbols. The convention exists specifically to make these calls visible; the oracle pre-dates the convention and lacks the vocabulary.
- **Where the oracle has a real point:** widget creation calls inside `itk_component add { … }` creation scripts (`BeamlineAuthUserView::constructor`, `BeamlineAuthView::constructor`). These are convention-required (§5.4.6) and Phase 1 missed them. 9 of the 24 oracle-only callees fall here, all in the same two constructors of one v1.3 file. A targeted re-annotation pass over those two symbols would close the gap.
- **Where they disagree on form but both are defensible:** the 7 entries in O5 are the same edges encoded differently — oracle uses the bare method-word, phase 1 uses the verbatim qualified form. The convention favors Phase 1, but downstream tools that need method-word search will need an index layer either way.
- **Where Phase 1 is worse:** five Phase 1 callees are convention violations (`lappend`, `namespace current`, `after`, plus the disputed `grid rowconfigure` interpretations). Three are unambiguous (Tier 2 / §6.9 misrecording); two are in v1.0 grandfathered files that never went through the arbiter. The v1.1+ files with arbiter passes show one residual error (`after` in `AutoSampleSelfWidget::handleHelp`).

On the symmetric headline: Phase 1 captures everything the oracle captures **except** the 9 widget-creation misses in two BeamlineAuth* constructors and the ~7 method-word strippings (which the convention says oracle had wrong), and adds 25 convention-driven facts the oracle never recorded. Overall callee Jaccard is 0.827; the bottom-quartile file (`Component.tcl`, 0.606) is dominated by §5.2 FQN-preservation gains and §5.3 / §5.14 unresolved additions — all in Phase 1's favor.

**Verdict: Phase 1 gold is materially higher-quality than the pre-disasm oracle, with one bounded follow-up (rerun §5.4.6 walk on `BeamlineAuth*` constructors) sufficient to close the remaining real gap.**

---

## Caveats

1. **Convention-version mix in Phase 1.** Per `provenance.convention_version`:
   - **v1.0 (grandfathered, no arbiter pass):** `BarcodeView`, `ControllerBase`, `MotorBase` — 3 files.
   - **v1.1 (arbiter pass applied):** `DcssHardwareServer`, `MFX_MOTOR` — 2 files. Plus `AutoSample.tcl` at v1.1 *without* a corrected file.
   - **v1.3 (9-section audit + arbiter):** `BeamlineAuthView`, `Component` — 2 files.
   The v1.0 files contribute the three unambiguous Phase 1 convention violations (P12) — they pre-date the §7.1 Tier 2 / §6.9 enforcement passes.

2. **`MFX_MOTOR.tcl` is the cleanest agreement.** 100% callee Jaccard (12/12) and 100% symbol-set agreement (8/8). This file's source structure — straightforward iTcl methods with direct `pattern_a` and `pattern_b` calls — falls inside both schemas without ambiguity.

3. **Line numbers are not directly comparable.** Phase 1 corpora are pinned to specific SHA7s (`bluice-BluIceWidgets-a54fa24`, …); the oracle batches do not record a corpus SHA. Apparent line-number drift between the two sets is corpus-version drift, not annotator error.

4. **Set-level comparison collapses duplicates.** Phase 1 records each `pack` call separately (e.g. two callees in `BarcodeView::constructor`); oracle records `pack` once. The Jaccard computation in this report uses set semantics — multi-occurrence facts are visible in line-level dumps (`/tmp/phase1_vs_oracle_data.json` produced during analysis) but collapse in the headline metrics.

5. **Oracle schema is name-only.** Oracle stores `expected_callees: ["name", ...]` with no kind. The "kind" classifications in this report (`qualified`, `method_dispatch`, `callback`, `unresolved`, etc.) come entirely from Phase 1; any oracle entry would be uncategorized at the kind level.

6. **`Component.tcl` arbiter ratio (32 disputes; 19 A / 13 B / 0 both / 0 neither).** The corrected file remains the lowest-Jaccard against oracle (0.606), but the disagreement is entirely about *form* (FQN preservation, ensemble naming) and *additional coverage* (unresolved dispatch, class symbols), not about correctness. A flat name comparison understates Phase 1's quality on this file.

7. **`BeamlineAuthView.tcl` arbiter ratio (40 disputes; 36 A / 3 B / 1 neither).** Despite the heavy arbiter pass, the §5.4.6 widget-creation gap survives. This suggests the §5.4.6 walk is under-prompted in the current LLM annotator template; it is the single highest-value improvement to make before re-running the v1.3 harness on the 16 oracle-only files.
