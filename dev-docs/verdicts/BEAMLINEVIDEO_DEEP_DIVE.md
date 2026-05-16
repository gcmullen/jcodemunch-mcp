# BeamlineVideo.tcl — Deep-dive on 35 null-line arbiter verdicts

**Status:** P3.0a investigation complete
**Date:** 2026-05-16
**Source artifacts:** `validation/gold_annotations/conv-v1.0/tcl-8.6/bluice-BluIceWidgets-a54fa24/BeamlineVideo.tcl.*`

---

## Trigger

The BeamlineVideo arbiter pass produced **166 verdicts** for 166 disputes. Of those, **35 came back with `line: null`**. `apply_arbiter.py` listed all 35 as `unmatched_verdicts` and did NOT apply them to `corrected_gold.json`. The verdict reasoning is preserved in `arbiter.json`, but the corrected_gold overlay is incomplete by 35 entries.

## Method

For each of the 35 null-line verdicts, looked up its `(symbol, callee_name)` in:
1. `BeamlineVideo.tcl.A.opus.raw.json`
2. `BeamlineVideo.tcl.B.sonnet.raw.json`
3. `BeamlineVideo.tcl.discrepancies.json`

Cross-referenced with the BeamlineVideo.tcl source where needed (spot-checked `::mediator announceExistence` at line 348, etc.).

## Findings

### Surface tally (all 35)

| Cross-ref category | Count |
|---|---|
| A had no entry; B emitted (with `line: null`) | 35 |
| Any other shape | 0 |

The naive read is "A missed 35 callees." That's misleading. The B emissions split by **kind**:

| B-side kind | Count | Arbiter verdict pattern | Real meaning |
|---|---|---|---|
| `method_dispatch` | 27 | All `A_correct` | B emitted `method_dispatch` where the receiver was actually a literal qualified name (e.g. `::config getStr foo` — first word `::config`, NOT `$obj`). Convention v1.1 §5.3 is explicit: `method_dispatch` fires only when first word is `$var` / `${var}`. A applied this rule correctly. B did not (B was run against the v1.0 prompt; v1.1 sharpened this exact case). |
| `static` | 9 | All `B_correct` | B caught real proc/class calls (`ComboSamplePositioningWidget`, etc.) that A under-emitted. These are genuine A-side misses. |
| `qualified` | 4 | 3 `B_correct`, 1 `A_correct` | B mostly right on §5.2 qualified-name preservation. |
| `unresolved` | 4 | 1 `B_correct`, 3 `convention_ambiguous` | Dynamic-dispatch edge cases (`create${tt}Tab` etc.). Spec under-specifies — feeds into convention v1.2. |
| `callback` | 1 | `B_correct` | B caught a callback A missed. |

### Verdict roll-up among the 35

| Verdict | Count | Interpretation |
|---|---|---|
| `A_correct` | 18 | A's omission was correct; B over-emitted (mostly `method_dispatch` against §5.3). |
| `B_correct` | 14 | B caught real calls A missed (mostly `static`). |
| `convention_ambiguous` | 3 | Spec under-specifies; flag for v1.2. |

## Root causes (two compounding)

1. **Sonnet's missing-`line` schema bug.** B.sonnet emitted `{name, kind, note}` without the required `line` field on all 35 callees. This is the same bug that produced ~170 disputes across DcsWidgets files. Fix at source: P3.0 T6 (annotator prompt forcing-example) + P3.0 T5 (`unwrap.py --repair-missing-lines` safety net).
2. **Wave 1 used v1.0 prompts.** The convention v1.1 edits (made between Wave 1 and Wave 2) sharpened §5.3 with the explicit `::config getStr foo` worked example and §5.10/§7.5 with the geometry-ensemble distinction. B.sonnet never saw those tightenings; many of its 27 `method_dispatch` over-emissions are exactly the case v1.1 added the example to prevent.

The 35 null-line verdicts are NOT primarily an arbiter problem. They are **disputes that exist because B was annotating against a softer version of the convention than A** (since the convention was tightened mid-run). The arbiter correctly evaluated the disputes against the latest convention.

## What A actually did

A.opus did NOT silently miss 35 callees. For the 27 `method_dispatch` over-emissions B produced, A likely recorded the same source lines as `qualified` callees (e.g., `::config getStr foo` → `{name: "::config getStr", kind: "qualified"}` per §5.2). The discrepancy generator paired these only when B emitted `method_dispatch` at the same name, producing an `A_only`-shaped record for B's malformed entry rather than recognizing the underlying agreement on the call site.

Direction for verification: `disputes.py` could be extended to detect this pattern (same call site, different kind classification) and surface it as `kind_classification_disagreement` instead of `B_only`. Optional Phase 3 follow-up.

## D6 recommendation: **(a) Re-dispatch B.sonnet only with v1.3 prompt + v1.1 convention**

**Rationale:**

- 27 of the 35 entries are downstream of B's v1.0-era §5.3 misclassification. v1.1 convention + an explicit forcing example for the `line` field would fix both bugs in one re-dispatch.
- A.opus is correctly applying v1.1 already; no benefit re-running it.
- The 9 B_correct `static` entries (real A misses) are preserved in the discrepancies — the gold layer will retain them as B_only entries. They are not lost.
- Three `convention_ambiguous` entries (dynamic-dispatch edge cases) are spec-tightening candidates, not annotation failures. Feed into convention v1.2 work in P3.1.

**Concrete steps (when ready):**

1. Ship P3.0 T6 (annotator prompt forcing-example for `line` field).
2. Ship P3.0 T5 (`unwrap.py --repair-missing-lines`) — safety net even with T6 in place.
3. Build the new meta-prompt template (P3.0 T2 annotator subagent).
4. Run the pipeline (P3.0 T1) end-to-end for BeamlineVideo only, re-dispatching B.sonnet against v1.1 convention. A's raw is untouched.
5. Re-build gold + re-run arbiter for BeamlineVideo.
6. Verify the new arbiter pass has 0 null-line verdicts (or a much smaller count, restricted to genuine ambiguity).

**Side benefit:** running this through the new pipeline serves as the end-to-end smoke test for P3.0 before P3.3 corpus expansion.

## Implications for Phase 3 (broader)

- **Convention version is real provenance.** Any annotation produced against a softer convention is suspect once the convention tightens. Going forward, gold provenance MUST record both `convention_version` and `convention_commit`, and the pipeline should refuse to mix outputs across convention versions in the same gold artifact.
- **The 23 already-finalized Wave-1/Wave-2 files were also annotated against v1.0** (Wave 1) or v1.1 (Wave 2). Most have audit-clean status because their source code didn't exercise the §5.3 / §7.5 / §6.12 edge cases. BeamlineVideo's high iTk + literal-qualified-receiver density made it the canary. **No action required on the other 23 files unless verification shows similar drift**, but the same issue could lurk in any future iTk-heavy file annotated under v1.0/v1.1 if not re-dispatched.
- **P3.3's D2 decision** (re-annotate existing 24 against v1.2?) gains weight from this finding. If v1.2 tightens further (which P3.1 is likely to do based on the 11 ambiguous verdicts from Phase 2), the same drift risk applies. Recommended: re-annotate the existing 24 against v1.2 as part of the canonical Phase 3 deliverable. Cost: ~5 hours of LLM dispatch through the new pipeline; benefit: one consistent gold dataset under one convention.

## Appendix

Full classified verdict list with A/B/discrepancy context: `BEAMLINEVIDEO_DEEP_DIVE_appendix.json`.
