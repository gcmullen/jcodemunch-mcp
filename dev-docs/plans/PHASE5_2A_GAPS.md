# Phase 5.2a — Tracked gaps for end-of-phase triage

**Living doc.** Each entry is a gap the 5.2a DSL walker will not (or may not)
close. Categorized so 5.2a.6 triage can route each to FIX (still in 5.2a or
5.5 cleanup), DEFER (Phase 6 convention / gold re-arbitration / auto-derive),
or ACCEPT (documented limitation).

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
- **Disposition candidate:** DEFER — Phase 6 gold re-arbitration. Verify
  whether double-emission is consistent gold convention across `namespace
  eval NS:: { ... }` sites in other corpora, or an annotator one-off here.
  If one-off, gold should be corrected to single-emit.

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
- **Disposition candidate:** FIX in a future 5.2.X refinement pass
  (extends 5.2.6 method_dispatch handling to array-indexed receivers;
  extends 5.2.7 callback emission to quoted/braced first-word shapes).
  Schedule decision belongs in 5.2a.6 triage.

### G4 — DSL-impl-file rule (§5.4.2 P3.1) currently broken
- **Where:** `git-gui/lib/class.tcl` — bridge over-emits 15 extra callees
  (precision 0.25, recall 0.4545 per `bridge_diff_v2.json`). Root cause:
  SUBTABLE_A rows for `constructor`/`method`/`field` recursively walk their
  bodies even when they're defined inside `proc class { name body } { ... }`
  — those are data consumers, not class declarations.
- **Scope:** 5.2a.4 owns this. Needs a `_parent_is_dsl_impl` helper that
  detects when the enclosing scope is a DSL-impl proc (name ∈
  {class, type, widget, define, ...}) and suppresses body recursion +
  child-symbol synthesis there.
- **Risk:** bluice corpora have no local `proc class` impls (verified),
  so the fix is low-regression-risk.
- **Disposition candidate:** FIX in 5.2a.4.

### G5 — `oo::define` augmenting onto an unresolved class name
- **Where:** Any `oo::define $varname { ... }` (computed) or
  `oo::define ClassA { ... }` where ClassA is declared in a DIFFERENT
  file the bridge hasn't yet processed.
- **Impact:** Walker has no class symbol to attribute children to.
- **Disposition candidate:** ACCEPT (documented limitation) for in-file
  cases where declaration order is reversed; the bridge is single-pass.
  Multi-file augmenting is a Phase 6 cross-file resolution concern.

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
- **Disposition candidate:** **Phase 6** — cross-file resolution. Requires
  indexer-level orchestration (extractor.py) to pre-scan all corpus files
  for `namespace import` calls, build a global per-namespace import map,
  pass that map as context into each per-file bridge invocation. Companion
  to spike §11's auto-derive DSL grammar work; both are "the indexer
  knows more than any single file does."
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

### G9 — `oo::define <unresolved>` falls back to file-scope attribution
- **Where:** `dsl_walker.tcl::_apply_outer_row` `else` branch (when `kind=""`
  but `_find_class_by_qname` returns -1). Today: emits `WARN:` to stderr,
  recurses into BODY with `parent_sym_idx=parent_sym_idx`, `parent_qname=parent_qname`
  — i.e., directives get attributed to FILE SCOPE.
- **Why it landed:** My 5.2a.2 executor brief contained this fallback path
  (the slop the hook caught). The agent implemented what I asked.
- **Impact:** 9 of clay.tcl's 17 remaining bridge_only extras come from
  dynamic `oo::define $class {...}` shapes. The fallback over-emits
  symbols at file scope that gold doesn't have.
- **Disposition candidate:** FIX in 5.5 closeout — change `_apply_outer_row`
  to SKIP body recursion entirely when the augmenting target isn't
  resolvable. This is the correct gold-first behavior.

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
- **Disposition candidate:** Defer until gold audit. If gold is consistent
  → FIX (small bridge change). If gold is inconsistent → Phase 6 gold
  re-arbitration.

### G8 — `tcl::mathfunc::*` math function refs in `expr {...}`
- **Where:** Convention §6.8 says optional emission.
- **Status:** Gold-consistency unaudited. Bridge emits nothing.
- **Disposition candidate:** Defer until gold audit confirms whether
  consistent gold use exists.

---

## How to update this file

When a sub-step uncovers a gap:
1. Append a new G-numbered entry under the appropriate sub-step's section.
2. Record: where (file + line + measurement), impact (recall / precision /
   symbol count), and a disposition candidate (FIX / DEFER / ACCEPT) with
   one-sentence rationale.
3. Do NOT commit speculative fixes for these gaps inside the current sub-step
   — they get triaged together in 5.2a.6 to keep each commit single-purpose.
