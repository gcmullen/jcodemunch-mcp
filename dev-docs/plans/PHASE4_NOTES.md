# Phase 4 — scratchpad notes

**Status:** placeholder; not a plan. Items here accumulate as Phase 3 work surfaces things worth remembering before Phase 4 starts.

Phase 4's primary mission per `PHASE3_PLAN.md §6` is bridge-vs-gold validation — run jcodemunch's TCL parser + disasm bridge against the 37-file v1.3 gold corpus and diff. This file collects ideas that augment that core mission.

---

## Idea: bytecode-extraction pass for `eval $foo` / dynamic dispatch resolution

**Source:** P3.1-canary-2 discussion (2026-05-16) — user asked whether we trace `$foo` for `eval $foo`. Current convention §5.8.2 + §8.2 explicitly mark these as `unresolved` with `subkind: "eval_var"`. The note + raw fields preserve the variable name for downstream tooling but the static-LLM annotator doesn't trace it.

**Proposed Phase 4 enrichment lane (independent of bridge-vs-gold):**

### Architecture

A second pass that runs AFTER the LLM annotation phase and AUGMENTS gold entries marked `unresolved / eval_var`, `unresolved / callback_var`, `unresolved / var_command`, `unresolved / computed_lambda`. Two complementary approaches:

1. **Static def-use chain pass** (cheaper, partial coverage)
   - Walk the enclosing symbol body for `set <varname> "<value>"` / `set <varname> [list <value>...]` / `variable <varname> <value>` assignments.
   - When a known unresolved entry references `$<varname>`, link to the assignment's value.
   - Add a new gold field `resolution_candidates: [{source: "set@line", value: "<verbatim>"}]` to the unresolved_dispatches entry.
   - Context-scope tracking required: `set` at proc level shadows class-level `variable`; `upvar` aliases require following.
   - Confidence: partial — only catches values literally assigned in the same body. Cross-proc def-use needs symbol-graph walk.

2. **Tcl bytecode extraction** (heavier, precise where it works)
   - For each proc symbol in the gold, run `::tcl::unsupported::disassemble proc <qualified_name>` in a real Tcl 8.6 interp.
   - Parse the bytecode listing for `invokeStk` / `invokeReplace` opcodes — these name the commands actually invoked at runtime.
   - Cross-reference bytecode-extracted commands with LLM-annotated callees to:
     - Confirm static callees (high-confidence match)
     - Surface dynamic-dispatch resolutions the LLM couldn't see
     - Flag bytecode-only callees (something the proc calls that the LLM missed)
   - Heavy lift: requires running each annotated source through a Tcl interp; many bluice/dcss files need their dependencies (iTcl, iTk, BWidget, custom DSLs) loaded before they'll compile. Sandbox carefully.

### Context-scope tracking

Both approaches need to know:
- Which proc/method body the eval/var-command site lives in
- The lexical chain of `variable`, `global`, `upvar`, `namespace eval` declarations above it
- Whether the var is class instance state (iTcl/TclOO) vs proc-local vs namespace-scoped

The gold schema partially captures this via `parent_classes`, `qualified_name`, and (v1.3) `args`/`arity`. A def-use pass would need to additionally read the symbol body source text — which means the pass must have source file access.

### Output

A new artifact under `validation/gold_annotations/conv-v1.3/tcl-8.6/<corpus>-<sha>/`:

- `<basename>.eval_resolution.json` — per-file table of `(unresolved_entry, resolution_candidates[])`. Sources cited: `def_use`, `bytecode`, `both`, `none`.
- `<basename>.bytecode_diff.json` — bytecode-extracted callees vs LLM-annotated callees, marking matches/extras/misses.

These augment, don't replace, `gold.json`. The original LLM annotation stays canonical; the resolution pass is a layered analysis.

### Phase 4 sequencing implication

If this lands in Phase 4, it can run **in parallel** with bridge-vs-gold validation (no shared inputs beyond the gold corpus). Two independent enrichment lanes:

```
[Phase 3 gold corpus] ─┬─→ [Phase 4a: bridge-vs-gold validation]
                       └─→ [Phase 4b: eval-resolution / bytecode pass]
```

### Convention implication

Doesn't change the convention. `§5.8.2 + §8.2` still mark these as unresolved at the LLM-annotation level. The bytecode pass adds resolution **data**; the convention defines what "unresolved" means.

### Cost rough estimate

- Static def-use pass: ~1 day to implement, ~minutes to run on 37 files
- Bytecode pass: ~3-5 days to implement (sandbox + dependency-load harness), ~hours to run on 37 files
- Combined: ~1 week + compute

### Open questions for Phase 4 kickoff

1. Do we want the resolution pass as a separate phase (4b) or fold into bridge-vs-gold (4a)?
2. Bytecode pass requires running real Tcl — acceptable security surface? Sandboxing strategy?
3. Some Phase 2 ambiguities (AsyncGets `eval $_callback`) would be auto-resolvable by a def-use pass. Worth re-running the canary with the pass enabled?

---

End of scratchpad.
