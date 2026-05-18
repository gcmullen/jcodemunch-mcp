# Phase 5.2a — Tracked gaps + Phase 5 sub-phase roadmap

**Living doc.** Each entry is a gap the 5.2a DSL walker will not (or may not)
close.

## Sub-phase routing policy

**Phase 6 is reserved for sandbox-needing work only.** The bridge is purely
static (no `interp create`, no `exec tclsh`, no `source` of user code) —
nothing in current scope requires a sandbox. All non-sandbox follow-up work
stays in Phase 5 sub-phases:

| Sub-phase | Theme | Gaps owned |
|---|---|---|
| **5.5** | Verdict + closeout + small architectural cleanups | G2, G11, G12 |
| **5.6** | Gold re-arbitration + convention v1.5 + per-pattern bridge fixes | G1, G3, G7, G8, G13, G14, convention v1.5 (tailcall/uplevel/trace) |
| **5.7** | Cross-file orchestration in extractor.py (per-namespace import maps; augment-target registries) | G5, G10 |
| **5.8** | Auto-derive DSL grammar from package bytecode (spike §11) | spike §11 |
| **Phase 6** | (reserved; currently empty — sandbox-needing investigations only) | — |

Per the gold-first principle: bridge tracks gold. Most gaps below are NOT
candidates for bridge expansion — they're candidates for gold-side
investigation, convention edits, or documented limitations.

---

## Surfaced during 5.2a.1 (Snit, commit `5d73e4d`)

### G1 — Gold double-emission of `::snit` and `::snit::` namespaces
- **Where:** `tcllib/snit/validate.tcl` line 13 — gold emits TWO namespace
  symbols (`::snit` and `::snit::`) for one `namespace eval ::snit:: { ... }`.
  Bridge emits one (`::snit::`).
- **Impact:** 1 strict miss on snit/validate.tcl. Bridge symbol-set recall
  35/36 = 0.972 instead of 36/36.
- **Disposition:** **5.6 gold re-arbitration**. Verify whether
  double-emission is consistent gold convention across `namespace eval NS::
  { ... }` sites in other corpora, or an annotator one-off here. If
  one-off, gold should be corrected to single-emit.

### G2 — Constructor/destructor wire-kind convention (global)
- **Where:** `disasm_bridge.tcl` `_apply_a_row` lines ~1063 remap kind ∈
  {constructor, destructor, configbody} → wire `kind=method`. Snit body
  grammar overrides this (emits kind=constructor/destructor directly via
  `_emit_ctor_or_dtor`), but iTcl / TclOO / itcl::body sites still go
  through the global remap.
- **Impact:** If gold expects `kind=constructor` for iTcl/TclOO constructors
  too (likely — gold for snit is consistent with kind=constructor), there's
  a global bridge↔gold kind-mismatch waiting to be measured.
- **Disposition candidate:** Needs gold-side audit. Sample iTcl + TclOO
  constructor entries in clay / git-gui / BluIceWidgets gold; if they all
  use kind=constructor, the bridge's wire convention is wrong globally
  and should be changed in 5.5 (with test_tcl_parser updates).

---

## Surfaced during 5.2a research (pre-implementation)

### G3 — DcsWidgets 0.290 recall is NOT primarily 5.2a.3 scope
- **Where:** bluice-DcsWidgets corpus, 326 strict misses (201 method_dispatch
  + 125 callback).
- **Finding (5.2a.3 research agent):** The misses concentrate INSIDE
  CREATE-BODY of `itk_component add`, not in the un-walked CONFIG-BODY.
  Patterns: `$itk_component(canvas) configure` (method_dispatch on
  array-indexed receivers), `-command "$this handleX"` shapes that
  5.2.7 doesn't fully cover.
- **5.2a.3 lift:** small — closes the +13 iTk-component-name misses, walks
  CONFIG-BODY, but cannot single-handedly take DcsWidgets to 0.75+.
- **Disposition:** **5.6 per-pattern bridge fixes** (extends 5.2.6
  method_dispatch handling to array-indexed receivers; extends 5.2.7
  callback emission to quoted/braced first-word shapes). Largely
  superseded by G14 (Pattern A — qualified static receivers).

### G4 — DSL-impl-file rule (§5.4.2 P3.1) — LANDED in 41c18728
- **Where:** `git-gui/lib/class.tcl` and similar DSL impl files.
- **Resolution:** Handled by the DSL grammar `dsl_impl` (mapping `class`,
  `method`, `constructor`, etc. to `{action suppress}`) combined with
  ANNOTATIONS rows for `proc class` / `proc field` / `proc method` /
  `proc constructor` / `proc type` / `proc widget` that push `dsl_impl`
  onto BODY_GRAMMAR_STACK during the impl proc's body walk. Generic and
  contextual — no `_parent_is_dsl_impl` helper was needed; the
  grammar-stack mechanism handled it cleanly.
- **Status:** CLOSED.

### G5 — `oo::define` augmenting onto an unresolved class name
- **Where:** Any `oo::define $varname { ... }` (computed) or
  `oo::define ClassA { ... }` where ClassA is declared in a DIFFERENT
  file the bridge hasn't yet processed.
- **Impact:** Walker has no class symbol to attribute children to.
- **Disposition:** **5.7 cross-file resolution**. Multi-file augmenting
  needs indexer-level orchestration to pre-scan corpora for class
  declarations and pass an augment-target registry into per-file bridge
  invocations. In-file reverse-order cases stay ACCEPT (documented
  limitation; bridge is single-pass).

### G6 — `forward` target callee not recorded
- **Where:** `forward NAME COMMAND_PREFIX` per convention §8.8 limitation
  — emits method symbol with empty body; COMMAND_PREFIX's first word is
  NOT recorded as a callee on the synthesized symbol.
- **Disposition:** ACCEPT — documented convention limitation, not a bridge
  bug.

---

## Surfaced during 5.2a generic-engine refactor

### G12 — Class-body primitives still in SUBTABLE_A (Phase 5.5 architectural unification candidate)
- **Where:** SUBTABLE_A in `recursion_tables.tcl` still owns rows for
  `method`, `body`, `configbody`, `constructor`, `destructor`,
  `public/private/protected method`, `namespace eval`. Most of these are
  iTcl/TclOO **class-body keywords**, not Tcl primitives — they only have
  meaning inside a class body. SUBTABLE_A handles them context-blindly
  (emits a method symbol regardless of whether we're actually inside a
  class body).
- **Why it works today anyway:** the DSL grammars (snit/clay/itcl/oo_define/
  oo_inline) intercept these directives when actually inside a DSL body
  via the BODY_GRAMMAR_STACK pre-pass. SUBTABLE_A's rows only fire at
  file scope or in non-DSL contexts, where they over-emit but
  gold-corpus impact is small.
- **What proper migration would require:**
  1. Extend the ANNOTATIONS row format with an 8th column `extra_keywords`
     (or similar) so DSL rows can propagate `out_of_line`, `visibility public`,
     etc. The dedup fix (commit 383541c) depends on the `out_of_line` keyword
     being on the symbol; losing it via migration re-introduces the dedup bug.
  2. Extend body-grammar lookup to handle 2-word prefix matches
     (`public method NAME`, `private method NAME`, etc.).
  3. Port `_handle_namespace_eval`'s computed-namespace handler (`namespace
     eval $varname { ... }`) into the DSL walker — or keep it as a sibling
     SUBTABLE_C-style schema handler.
- **Disposition candidate:** **Phase 5.5** — separate sub-step for
  architectural unification. Not a recall lift; correctness improvement
  (eliminates false-positive method emission in non-DSL contexts).
  Not in 5.2a scope.



### G10 — Cross-file `namespace import` tracking (Phase 6 candidate)
- **Where:** Bridge currently handles bare aliases (e.g. `class FooBar { ... }`
  in bluice.tcl after `namespace import ::itcl::*`) via unconditional
  ANNOTATIONS rows per convention §5.4.2 by-analogy.
- **Limitation:** Works only when import + bare-usage are in the SAME file.
  Tcl's `namespace import` is namespace-scoped (not file-scoped) — `setup.tcl`
  can install an import into `::`, and `widgets.tcl` later uses bare `class`
  with no import locally visible. Bridge has no cross-file state.
- **Disposition:** **5.7 cross-file orchestration**. Requires extractor.py
  to pre-scan all corpus files for `namespace import` calls, build a
  global per-namespace import map, pass that map as context into each
  per-file bridge invocation. Sibling to G5 (cross-file augment-target
  registry); the two could share infrastructure.
- **Today's mitigation:** the convention §5.4.2 by-analogy stance (treat
  bare `class` as iTcl unconditionally) is what gold validates against,
  so the gap is documented-not-blocking until a corpus surfaces a
  bare-name collision.

### G11 — Constructor wire-kind inconsistency between DSL grammars
- **Where:** `oo_inline` body grammar (5.2a.X) emits `kind=method` for
  `constructor`/`destructor` to preserve the `test_constructor_extracted`
  assertion that pins SUBTABLE_A's legacy wire convention. Meanwhile
  `snit`, `clay`, and `oo_define` grammars correctly emit
  `kind=constructor` / `kind=destructor` per gold.
- **Impact:** `oo::class create Foo { constructor ... }` emits kind=method
  (legacy); `oo::define Foo { constructor ... }` and `snit::type Foo
  { constructor ... }` emit kind=constructor (gold-correct). Inconsistent
  output for the same gold convention.
- **Disposition candidate:** **5.5 closeout** — update
  `test_constructor_extracted` to expect kind=constructor, change
  SUBTABLE_A wire remap at `_apply_a_row:1063`, harmonize
  `oo_inline` grammar with the other DSL grammars. Touches existing
  tests; needs explicit re-baseline.

---

## Surfaced during 5.2a.2 (Clay + oo::define, agent-implemented)

### G9 — `oo::define <unresolved>` fallback — LANDED in 097b008
- **Where:** `dsl_walker.tcl::_apply_outer_row` augment branch.
- **Resolution:** When `_find_class_by_qname` returns -1 (target is a
  variable like `$class`, or otherwise unresolvable), the bridge now
  emits the augment-command-name (`::oo::define`) as a qualified callee
  on the parent and SKIPS body recursion (no attribution to wrong scope).
- **Lift:** clay corpus 0.5962 → 0.6250.
- **Status:** CLOSED.

---

## Persistent ACCEPT/DEFER from spike §7.5 (pre-Phase-5)

These remain unfinished from earlier 5.2 work; tracked here for the
combined 5.2a.6 triage view.

### G7 — 28 `?` dynamic-dispatch placeholders (ACCEPT row → FIX candidate)
- **Where:** Gold uses `?` for `$cmd $args` shapes that cannot be statically
  resolved. Bridge currently emits nothing.
- **Status:** Earlier flagged as a bridge expansion candidate (emit `?` from
  `_handle_unresolved`). Per gold-first, blocked on gold-consistency audit
  across all 39 corpora.
- **Disposition:** **5.6 gold audit + bridge**. If gold is consistent
  across all 39 corpora → FIX (small bridge change: emit `name="?"` from
  `_handle_unresolved` for fully-dynamic dispatch). If inconsistent →
  5.6 gold re-arbitration on the inconsistent files.

### G8 — `tcl::mathfunc::*` math function refs in `expr {...}`
- **Where:** Convention §6.8 says optional emission.
- **Status:** Gold-consistency unaudited. Bridge emits nothing.
- **Disposition:** **5.6 gold audit** — confirm whether consistent gold
  use exists; if yes, small bridge fix in expr-operand handling.

---

### G13 — Pattern B: dual-form symbol emission (`::Class::method` AND `Class::method`)
- **Where:** Surfaced in DcsWidgets investigation. Gold for
  `bluice-DcsWidgets/ComponentGateExtension.tcl` emits the same method
  under TWO separate symbol entries: one with leading `::` (fully
  qualified absolute) and one without (relative to enclosing namespace).
  Bridge emits only the canonical fully-qualified form.
- **Impact:** ~5-9 misses on ComponentGateExtension.tcl alone (the
  unqualified-form symbol's callees never compare against gold because
  the symbol doesn't exist in bridge output).
- **Why it's not a clear bridge fix:** Same shape as G1 (`::snit` vs
  `::snit::` double-emission). Looks like gold-annotator inconsistency,
  not a convention rule. Bridge-side dual-emission would be
  gold-overriding, not gold-tracking.
- **Disposition:** **5.6 gold audit**. Audit whether dual-form is
  consistent across all 39 corpora. If consistent → convention should
  formalize and bridge can match. If only some files → those gold files
  need re-arbitration.

### G14 — Pattern A: qualified static receiver method-dispatch (`::ns method args`)
- **Where:** Confirmed pattern in DcsWidgets (`::mediator
  announceDestruction $this`, ~19 misses) and BWidget
  (`BWidget::grab release $path`, `BWidget::focus release $path`, ~4
  misses). Likely present in other corpora wherever code uses a USER
  namespace as a static receiver for method-style dispatch.
- **Today's bridge behavior:** When first word is qualified (e.g.
  `::mediator`), the bare-static-emit branch at `_handle_pattern_a:967-974`
  emits ONE qualified callee (`::mediator`). Second word (e.g.
  `announceDestruction`) is dropped.
- **Gold expectation:** TWO callees at the same line: a 2-word qualified
  callee (`::mediator announceDestruction`) AND a `method_dispatch` callee
  with `name=announceDestruction`, `receiver_hint=::mediator`. Mirrors
  convention §5.3 method_dispatch for `$obj method` but with a static
  qualified receiver instead of a variable receiver.
- **Generic fix:** ~15 LOC in `_handle_pattern_a`'s bare-static-emit
  branch. Predicate: bare-name (qualified-name stripped of namespace
  prefix) not in Tier 2 denylist + first word starts with `::` or
  contains `::` + second word is a literal method name. Emit BOTH the
  2-word qualified and the method_dispatch.
- **Estimated lift:** ~19 (DcsWidgets) + ~4 (BWidget) + unknown other
  corpora = ~23-30+ misses recovered. Aggregate ≈ +0.01-0.02.
- **False-positive guard:** Tier 1/2/3 denylist consultation prevents
  `::set var val` style stdlib-qualified spurious emission.
- **Disposition:** **5.6 per-pattern bridge fix**. Executor-ready.

---

## How to update this file

When a sub-step uncovers a gap:
1. Append a new G-numbered entry under the appropriate sub-step's section.
2. Record: where (file + line + measurement), impact (recall / precision /
   symbol count), and a disposition candidate (FIX / DEFER / ACCEPT) with
   one-sentence rationale.
3. Do NOT commit speculative fixes for these gaps inside the current sub-step
   — they get triaged together in 5.2a.6 to keep each commit single-purpose.
