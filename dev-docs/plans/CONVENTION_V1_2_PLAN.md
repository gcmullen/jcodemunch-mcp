# Convention v1.2 plan — folding the independent audit findings

**Status:** DRAFT
**Date:** 2026-05-16
**Source:** `dev-docs/verdicts/CONVENTION_AUDIT_LAYER_A.md`, `dev-docs/verdicts/CONVENTION_AUDIT_LAYER_B.md`
**Goal:** decide which audit findings fold into convention v1.2, in what order, and at what cost.

Every recommendation is classified by:

- **Impact on existing 24-file gold corpus** —
  - **none**: text/spec edit; existing artifacts are unaffected.
  - **forward-only**: new field populated on new runs; existing artifacts gain a missing or null entry (backward-compat shim trivial).
  - **re-annotation**: existing artifacts conform under v1.1 but not v1.2; staying conformant requires re-running through the pipeline.
  - **breaking**: existing artifacts violate the new schema or tier rules and would need re-annotation or a migration shim.
- **Cost** — trivial (1-2 line edit) / small (patch one tool) / medium (patch + canary re-run) / large (patch + full corpus re-run).
- **Priority** — high (load-bearing for downstream consumers or pipeline correctness) / medium (quality-of-life) / low (cosmetic).

---

## Bucket A — Layer A polish (convention text edits)

| # | Finding | Change | Impact | Cost | Priority |
|---|---|---|---|---|---|
| A1 | §5.10 cites broken URL `itcldelete.html` (HTTP 404) | Replace with ItclCmd index URL or note 404 + substitute (mirroring §10.4 pattern) | none | trivial | medium |
| A2 | §5.4.2 (bare `class NAME BODY` DSL) labeled Layer A but is a vendor alias, not a Tcl spec construct | Reclassify as Layer B with explicit `Rationale:` OR add "Layer A by analogy to §5.4.1 conditional on alias being present" qualifier | none | trivial | low |
| A3 | §6.9 "dispatcher is NOT a callee" is a Layer B filtering choice presented under Layer A | Tag explicitly as Layer B (cross-ref §7.1) so Layer-A-only reader is not misled | none | trivial | low |
| A4 | §6.3 "if COMMAND is a brace-literal script, walk it" is by-analogy to `apply`, not direct spec | Add half-sentence noting it is convention-level extension | none | trivial | low |
| A5 | §6.11 missing `-cgetmethodvar` / `-configuremethodvar` / `-validatemethodvar` dynamic variants | Document these as `callback_var` unresolved entries (matches existing §6.12 callback_var pattern) | forward-only (no Phase 1/2 source exercised these flags) | small | medium |

**Bucket A net:** all five edits are zero-impact text changes. Safe to fold immediately. Total convention diff ≈ 30-40 lines.

---

## Bucket B — Tier completeness (Layer B behavior changes)

| # | Finding | Change | Impact | Cost | Priority |
|---|---|---|---|---|---|
| B1 | `lmap`, `time` missing from any tier; semantically siblings of `foreach`/`expr` | Add to Tier 1 (control flow, body-walked) | re-annotation if any existing source uses them | small | high |
| B2 | Tier 2 prose only walks `dict for` / `dict update` bodies; misses `dict with`, `dict map`, `dict filter` (script form) | Extend "How to apply" exception list | re-annotation if any existing source uses them | small | high |
| B3 | `open`, `close` not in Tier 3; clutter call graphs as ordinary static callees | Add to Tier 3 (filtered out) | re-annotation (high-frequency change — many files use these) | small | high |
| B4 | `flush`, `seek`, `tell`, `concat`, `eof` similar | Tier 2 (utilities) | re-annotation possible (low-frequency) | small | medium |
| B5 | `oo::define`, `oo::objdefine`, `interp create` unspecified | Add to Tier 4 declarations with clarified treatment | re-annotation if exercised; minor (low frequency in current corpus) | medium | medium |
| B6 | `global`, `variable` (TclOO `my`) classification unclear | Either Tier 5 (declarations) or Tier 2 (variable-scope utilities). Phase 2 arbiter already ruled `global` and `variable` are Tier 2 (Clock/DEG_HORZ verdicts) → formalize | re-annotation possible (changes prior wrong behavior) | small | high |
| B7 | `update`, `vwait` (event-loop primitives) unclassified | Tier 3 (effectively I/O-shaped) | re-annotation possible (low-frequency) | small | low |
| B8 | `auto_load`, `auto_import`, `tm path add` (loading surface) unclassified | Tier 5 (structural) | re-annotation possible (very low-frequency) | small | low |

**Bucket B net:** these are real behavior changes. The 24 existing gold artifacts were annotated under v1.0/v1.1 which silently let these terms through as static callees (or omitted them inconsistently). Going to v1.2 makes them either filtered or recategorized.

**The arbiter verdicts on `global`/`variable` from Phase 2 (Clock, DEG_HORZ) are evidence that the convention IS already converging in this direction** — the arbiter applied "Tier 2" reasoning to those exact keywords without the convention explicitly stating it. v1.2 should make that explicit.

---

## Bucket C — Schema additions

| # | Finding | Change | Impact | Cost | Priority |
|---|---|---|---|---|---|
| C1 | No `schema_version` at top level | Add `"schema_version": "1.2"` to §4 schema; populate in build_gold.py | forward-only (existing artifacts get null on read) | small | high |
| C2 | No `args` / `arity` on symbol object | Add `args: [str, ...]` and `arity: int` (or just `arity`) | re-annotation required to populate (existing gold has null) | medium (annotator + audit_check + build_gold patches) | high |
| C3 | `note` strings are "freeform" but §5.3 / §6.9 / §7.2 prescribe specific text | Promote prescribed note shapes to a named enum, e.g. `note_kind ∈ {receiver_form, flag_name, ...}` while keeping `note` freeform fallback | forward-only | small | medium |
| C4 | No `receiver_hint` on method_dispatch callees | Add `receiver_hint: str | null` (e.g., `"$obj"`, `"$itk_component(...)"`); refactor tools cluster by receiver | re-annotation required | medium | medium |
| C5 | `note` field's required-vs-optional status unclear | Pick one (recommend: always present, may be empty string) | forward-only | small | low |
| C6 | `qualified_name` for global procs: leading `::` allowed/required/forbidden? | Spec: always strip leading `::` for the qualified_name of global symbols (still preserve in callee names per §5.2) | re-annotation possible (the rule was implicit, both forms seen) | small | medium |
| C7 | `namespace_imports` field referenced in §7.1 Tier 5 but not in §4 schema | Either add to schema with shape, or move MAY clause to §9 Out of scope | forward-only either way | trivial | low |

**Bucket C net:** C1 is one line and high-value (lets future tooling detect convention version drift mechanically). C2 + C4 are bigger because they require re-annotation to populate. C5/C7 are housekeeping.

---

## Bucket D — Enum additions (small schema-breaking)

| # | Finding | Change | Impact | Cost | Priority |
|---|---|---|---|---|---|
| D1 | `§5.7` re-purposes `computed_namespace` subkind for dynamic `source $path`; conflates two phenomena | Add `computed_source` to `unresolved_dispatches.subkind` enum | forward-only (existing gold has none of these; no Phase 1/2 source used `source $var`) | small | medium |

---

## Bucket E — Doc cleanup (non-functional)

| # | Finding | Change | Impact | Cost | Priority |
|---|---|---|---|---|---|
| E1 | §5.10 ensemble list missing `binary` and `encoding` vs §7.1/§7.5 | Add or replace with cross-ref to §7.1 | none | trivial | low |
| E2 | §7.7 (comments ignored) is spec-restatement, not Layer B | Delete or move to Layer A | none | trivial | low |
| E3 | §7.2 callback-flag `$var` rule duplicated in §6.12 | Pick one normative source, cross-ref the other | none | trivial | low |
| E4 | `lambda` qualified-name pattern `<enclosing>::__lambda_<line>` is convention but not in §4 schema | Promote to §4 or §7 explicit rule | none | trivial | low |
| E5 | `file` field type spec is vague | Specify: basename only, per existing v1.2 prompt behavior | forward-only | trivial | low |

---

## Sequencing (recommended)

```
Step 1 — Bucket A + E (zero-impact text edits)            ~30 min
  → Convention bumps to v1.2 at this point with no
    re-annotation required. Existing gold remains valid
    (it was conv-v1.0/v1.1 with strict-subset semantics).

Step 2 — Bucket C1 (schema_version field)                 ~10 min
  → Patch build_gold.py to emit schema_version.
    All future runs carry the version tag.
    Backward-fill optional via a one-time migration script.

Step 3 — Bucket B (Tier completeness)                     ~1-2 hr
  → Convention edits + audit_check.py updates if any
    tier 1/3 keywords need new validators.
  → Now the existing 24 are silently non-conformant under
    v1.2 (the Phase 2 arbiter verdicts for `global`/`variable`
    are RIGHT under v1.2 but those calls live in gold as
    A_only entries marked "B_correct" — already overlaid as
    corrected_gold).
  → DECISION POINT: re-annotate the 24, accept the silent
    drift, or generate a "v1.1 → v1.2 migration" report
    listing which existing callees would now be filtered.

Step 4 — Bucket D (computed_source subkind)               ~15 min
  → Single enum value, build_gold + audit_check accept it.

Step 5 — Bucket C2/C4 (args/arity, receiver_hint)         ~2-3 hr
  → Annotator prompt updates to populate these fields.
  → Re-annotation MANDATORY to get values; existing artifacts
    survive with null defaults.
  → This is the most invasive change. Schedule separately.

Step 6 — Bucket C3/C5/C6/C7 (housekeeping)                ~30 min
  → Spec clarifications; mostly text changes.
```

---

## Decision points

| ID | Decision | Default |
|---|---|---|
| C-D1 | Bundle Steps 1-2-4 + Bucket E into a single v1.2 release? | Yes — all zero-impact-on-existing-gold |
| C-D2 | Apply Step 3 (Tier completeness) — re-annotate existing 24? | Defer per existing PHASE3_PLAN.md D2 decision; if D2 = yes-re-annotate, do at the same time |
| C-D3 | Apply Step 5 (args/arity/receiver_hint) — re-annotate existing 24? | Strongly recommend yes (these enable refactor tooling that downstream Phase 4 will need); could be batched with C-D2 |
| C-D4 | Convention version: bump to v1.2 after Step 1-2-4+E only, or wait until Steps 3+5 are also in? | Bump after Step 1-2-4+E. Then v1.3 after Step 3, v1.4 after Step 5. Smaller versioned hops let consumers track changes incrementally. |

---

## Impact-on-existing-gold matrix

For each existing gold artifact under `validation/gold_annotations/conv-v1.0/tcl-8.6/<corpus>-<sha>/`, here is the worst-case impact per Bucket:

| Bucket | Existing gold survives unchanged | Field-level migration needed | Re-annotation needed |
|---|---|---|---|
| A | ✓ | – | – |
| B (Tier completeness) | – | – (the disputed terms were never correct under v1.0 either; arbiter caught them as such) | ✓ if we want strict v1.2 conformance |
| C1 schema_version | ✓ (null tolerated by readers) | optional one-time backfill | – |
| C2 args/arity | ✓ (null tolerated) | – | ✓ to get real values |
| C3 note shapes | ✓ | – | – |
| C4 receiver_hint | ✓ (null tolerated) | – | ✓ to get real values |
| D1 computed_source | ✓ (no existing source uses dynamic source) | – | – |
| E | ✓ | – | – |

---

## Recommendation

**Fold in immediately (this session or next):** Buckets A, C1, D1, E — total ~1 hour, zero impact on existing gold. Bumps convention to v1.2 cleanly.

**Schedule with D2 decision:** Bucket B (Tier completeness) + Bucket C2/C4 (args/arity/receiver_hint). These tie naturally to "re-annotate the 24" — if we're re-running anyway, we get the schema upgrades for free.

**Skip / defer:** Bucket E items are pure cleanup, can ride along with the others or wait.

---

End of plan.
