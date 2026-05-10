# JCM TCL Bridge — Architecture Plan v2.2 PATCH

**Date**: 2026-05-08
**Status**: P1.2-ready delta on top of `PLAN_v2.1.md`
**Origin**: P1.1 closure surfaced 7 P1.2 questions; Q3+Q6 resolved
empirically, Q1+Q5 routed to omc:architect, Q7 routed to omc:critic.
This patch consolidates the resulting recommendations into spec text
the P1.2 session reads alongside PLAN_v2.1.

**Reading order for P1.2** (paths updated for the dev-docs/ reorg
at P1.3 close):
1. `dev-docs/plans/PLAN_v2.1.md` — base plan (unchanged)
2. **This patch** (`dev-docs/plans/PLAN_v2_2_PATCH.md`) — resolves
   the open spec questions
3. `validation/probes/P1_2_QUESTIONS_EVIDENCE.md` — empirical
   evidence for Q3 + Q6
4. `dev-docs/verdicts/P1_1_VERDICT.md` — P1.1 close-out
5. `dev-docs/verdicts/P1_3_VERDICT.md` — P1.3 close-out
   (post-architect-revision storage approach + consumer wire-ups)

The patch supersedes PLAN_v2.1 in the named sections; everything else
in v2.1 stands.

---

## Δ §2.1 — Walker substrate (Q1 + Q5 resolution)

PLAN v2.1 §2.1 walker pseudocode iterates `for cmd in bc.commands`
and pattern-matches `cmd.instructions` per command. **This per-command
framing is REPLACED.** The P1.1 spike shipped with this framing and
hit two unrecognized cases out of 12,010 walker events (0.017%) on the
full bluice corpus — both cases sub-table B bracket inlining where the
disassembler attributes opcodes for one source command to a different
"Command N:" header than its terminal invoke.

### v2.2 walker model: forward stack simulation, anchor by src range

The walker treats the bytecode as **one stack machine across all
"Command N:" labels**. Per-command headers are a labelling of pc ranges
to source ranges, not a partition of stack frames.

```
walk(parsed, parent_src):
    flat_insns = sort by pc(union of all c.instructions)
    src_ranges = [(cmd_idx, src_start, src_end) for c in parsed.commands]
    stack      = []                         # explicit stack model

    for insn in flat_insns:
        match opcode_class(insn.op):
          PUSH_LITERAL:    stack.push(LITERAL slot, source_pc=insn.pc)
          LOAD_VAR:        stack.replace_top_with(VAR slot, source_pc=insn.pc)
          STRCAT n:        stack.collapse_n_into(EXPR strcat slot)
          EXPAND_START:    record marker
          EXPAND_STK_TOP:  stack.replace_top_with(EXPR expanded slot)
          INVOKE op N:     # terminal OR interior — same handling
              slots = stack.pop_n(N)
              cmd_anchor = lookup_src_range(slots[0].source_pc, src_ranges)
              emit(dispatch_match(slots, op), cmd=cmd_anchor)
              stack.push(EXPR invoke_result slot, source_pc=insn.pc)
          SPECIALIZED_OP:  apply per-op stack-effect rule (no emit)
          JUMP / NOP:      ignore (no stack effect from walker's view)
```

**Three load-bearing changes vs v2.1**:

1. **No "terminal" vs "interior" invoke distinction.** Every invoke
   pops N, pushes 1, and emits an event. This subsumes Q5: bracket
   substitutions are interior invokes whose results feed an outer
   invoke; both emit cleanly.

2. **Anchor by src range, not by pc range.** The cmd_anchor for an
   emitted event is the cmd_idx whose `(src_start, src_end)` range
   contains the source_pc of the **bottom-most slot** consumed by
   the invoke (i.e., where the callee literal was pushed). This
   correctly attributes `if [catch ... err]`'s catch invocation to
   Command 1 (the bracketed catch source) rather than Command 0
   (the outer if).

3. **Explicit stack-effect table for every opcode the walker
   tolerates.** ~25 opcodes (push1/push4/loadStk/strcat/
   expandStart/expandStkTop/invokeStk{1,4}/invokeReplace/
   invokeExpanded/listIndexImm/storeStk/pop/jumpFalse1/jumpTrue1/
   startCommand/done/...). The table is declarative, testable in
   isolation, and evolves additively as new opcodes surface in
   later Tcl versions.

**Expected post-rewrite outcome**: 12,010/12,010 corpus events
recognized; the 2 unrecognized cases close by construction.

### LoC and fixture impact

- Walker LoC: 569 → ~640 (Δ +65–85). Within the §6.1.4 soft cap of
  900-1200 with comfortable headroom for recursion tables, body-base
  helper, and unresolved detector.
- Re-baseline fixtures: 11 (`eval_var`), 13 (`uplevel_var`), 14
  (`interp_eval`), 15 (`eval_brackets`), possibly 5 (`expand_args`).
  Event payloads should match; only the matching path inside the
  walker changes.
- New fixtures (P1.2 deliverable):
  - `19_bracket_inline_if.test` — `if [catch "..." err] { body }`
  - `20_bracket_inline_specialized.test` — `set x [lindex $argv 0]`
  - `21_nested_brackets.test` — `puts [lindex [split $s ","] 0]`
  - `22_interior_invoke.test` — explicit Q5 case `foo [bar baz] qux`

### Strategy considered and rejected

Strategy B (pre-pass merger that detects sub-table B inlining and
concatenates inner Command's instructions into outer Command's frame)
was rejected for two reasons: (1) Tcl 8.6 doesn't always nest cleanly
(`if [catch ...] {body}` is interleaved, not nested) so the merger
would invent a synthetic "merged command" abstraction unanchored to
anything Tcl emits; (2) the cross-boundary logic is exactly what
Strategy A does anyway, but Strategy A keeps the abstraction in the
walker (one stack machine, one src→pc anchor map) rather than pushing
it into the parser layer.

Hybrid Strategy C ("Strategy A for src-anchor attribution + per-cmd
walker iterator") was rejected: preserves the wrong mental model;
doesn't dissolve Q5; leaves us heuristic-patching boundary cases.

---

## Δ §0.2 rule 5 — schema additions (Q7 resolution)

PLAN v2.1 §0.2 rule 5 specifies `static_inheritance: list[str]` and
`static_package_requires: list[str]`. The omc:critic evaluation
identified 3 critical and 4 major spec gaps (see the critic output
embedded in the P1.2 archive). All gaps are resolved here.

> **REVISED AT P1.3 CLOSE — storage approach replaced.**
> The original §Δ0.2 storage approach below
> (**M3: `INDEX_VERSION 9 → 10` + JSON columns** wired into
> `_SCHEMA_SQL`) is **STRUCK**. Architect review after P1.2 found
> three load-bearing CRITICALs:
>
> 1. `_migrate_v9_to_v10` was a pure version-stamp; the
>    `_SCHEMA_SQL` column adds never landed.
> 2. The serialization paths
>    (`_symbol_to_row`, `_row_to_symbol_dict`, `_symbol_to_dict`,
>    `_symbol_to_dict_for_delta`) silently dropped both
>    `parent_classes` and `package_requires`.
> 3. No round-trip storage test existed to catch the gap (the
>    bridge populated the fields in-memory; nothing on the read path
>    ever saw them after the index was written and re-loaded).
>
> P1.3 redesigned storage to **Option C+D** (side-table + dual
> version axis):
> - `INDEX_VERSION` returns to **9** (lockstep with upstream); the
>   speculative bump to 10 is undone — `_migrate_v9_to_v10` is
>   deleted and removed from the migration ladder.
> - Fork-extension data tracks on a separate axis:
>   **`JCM_TCL_INDEX_VERSION = 1`**, stored under `meta` as
>   `jcm_tcl_writer_version`. **Strict-A** load gate refuses any DB
>   without an exact-match stamp; legacy v4→v9 migrations stamp
>   transparently.
> - Fork-extension fields live in a **side-table
>   `jcm_tcl_extensions`** with hybrid typed columns
>   (`parent_classes TEXT`, `package_requires TEXT`,
>   `extras_json TEXT`). The side-table is created via
>   `CREATE TABLE IF NOT EXISTS` per call (mirroring
>   `embedding_store.py`); intentionally NOT in `_SCHEMA_SQL` to
>   avoid the `_initialized_dbs` cache trap that would mask
>   out-of-band drops.
> - Cascade is explicit (no implicit FK CASCADE): `incremental_save`
>   issues `DELETE FROM jcm_tcl_extensions ...` ahead of the symbols
>   delete.
> - **Cross-language base-code preservation** is non-negotiable.
>   `_parse_bases` (signature-regex extractor) lives in
>   `tools/_class_helpers.py` and serves Python / JS / Java / C# /
>   Ruby / Go / Rust / etc. The side-table path serves Tcl class
>   symbols (populated structurally by the bridge). The
>   `_get_bases()` dispatcher routes by language.
>
> Cross-reference: `dev-docs/verdicts/P1_3_VERDICT.md` and the
> CHANGELOG `[Unreleased]` "Schema additions wired through to
> storage" + "Storage shape" sections carry the full close-out
> detail. The original **M3** in the decisions table below is
> **STRUCK** and kept only for historical lineage; M1, M2, M4, C1,
> C2, C3 stand as originally written.

### v2.2 schema additions

The Phase-1 bridge JSON output gains exactly the following named
fields. Existing fields per `PLAN_v2.1 §0.2 rule 5` and the v1.x
schema are unchanged.

```
parent_classes: list[{name: str, line: int}]
package_requires: list[{name: str, version: str|null}]
```

#### Naming — bare prefix (M1)

The `static_` prefix is **dropped**. Existing schema fields are bare
(`call_references`, `decorators`, etc.); inserting `static_` would
break naming symmetry. When Phase 2 lands, runtime augmentation lives
in parallel `runtime_*` fields (`runtime_parent_classes`,
`runtime_package_requires`) — consumers merge static + runtime at
read time. This avoids renaming the Phase-1 fields when Phase 2
ships.

User direction tie-in: end goal is "accurate index used for
developing/understanding code, bug fixes, feature impl." Bare-name
fields are the developer-friendly default; the prefix-dance is a
schema-internals concern that consumers shouldn't carry.

#### Field types — rich (M2 + M4)

`parent_classes` carries the **declaration line** of each `inherit`
(or TclOO `superclass`) statement. Cheap to capture during the
recursion table A walker (the line is in the parent command's
src_range); expensive to retrofit later (schema bump + reindex).

`package_requires` carries the **VERSION** argument. Bridge today
embeds version in the symbol's `signature` string; preserving it in
the field is required to avoid regressing `get_dependency_graph` use
cases ("which repos pin Itcl >= 3.4"). VERSION is `null` when the
source omits it (`package require Tcl` with no version argument).

User direction tie-in: "LoC can also be larger if it is necessary."
The richer schema costs O(1) bookkeeping per inherit/package-require
edge; downstream developer utility is meaningful (jump-to-line in
class-hierarchy tools, version-pin reporting in dependency tools).

#### Empty-list semantics (C3) — load-bearing

**Both fields are always present, always lists. Empty source → `[]`.
No null. No omission.**

This is required by the consumer brittleness pattern documented in
`~/.claude/projects/-home-giles-bluice/memory/jcm_munch_response_shape.md`.
Three-state shape (present-and-empty / null / omitted) has burned
the team in the past. Lock to one form.

#### `package require` symbol-vs-field collision (C1) — both

`parse_package` emits **both**:

1. **A `kind=import` symbol per `package require` occurrence** — the
   existing v1.x behavior, consumed by `find_importers` for Tcl repos.
   Unchanged.
2. **An entry in the file's `package_requires` field** — new in v2.2,
   consumed by `get_dependency_graph` and Phase-2 cross-repo tools.

Both sources are populated from the same parse. Tests must lock both:
`test_package_require_emits_import_symbol` (existing) and
`test_package_require_populates_field` (new).

#### Host symbol for `package_requires` (C2) — file-level `__script__`

`package_requires` lives on **the file's `__script__` symbol**.
Rationale: `package require` semantically loads a package at file load
time regardless of nesting depth (Tcl's package mechanism is global
state, not namespace-scoped). Carrying the field on every namespace
symbol whose body contains a require would duplicate data without
adding useful structure.

`parent_classes` lives on **the class symbol** (one list per class,
one entry per Base in the order they appear in the source).

#### Index version bump (M3) — STRUCK

> ~~`INDEX_VERSION` is bumped 9 → 10 with the v2.2 schema. Forces
> re-index on upgrade so the empty-list rule (C3) holds across all
> repos with no "pre-v2.2 repo, missing field" gap. Storage layer
> rejects newer indexes via `sqlite_store.py`'s version gate as
> today; this is a forward-compatible bump.~~

**Replaced at P1.3 close** (see opening note at the top of this
section). `INDEX_VERSION` returns to **9** in lockstep with upstream;
fork-extension data tracks on a separate axis as
`JCM_TCL_INDEX_VERSION = 1` (stored under `meta.jcm_tcl_writer_version`).
Fork extensions persist in the `jcm_tcl_extensions` side-table.
Strict-A load gate (failures-not-fallbacks) refuses any DB without an
exact-match stamp.

CHANGELOG entry must still call out the re-index requirement and
explain the `parent_classes` / `package_requires` fields with
examples — the user-visible re-index requirement holds; only the
mechanism changed (schema-version stamp on a fork axis instead of
upstream `INDEX_VERSION` bump).

### Carried-forward items (no decision change)

- **TclOO `superclass`**: folds into `parent_classes` alongside iTcl
  `inherit`. Bridge today already handles both keywords
  (tcl-native-parser:tcl_parser_bridge.tcl find_inherit_parents). Same
  field, same shape.
- **Verbatim base names**: entries in `parent_classes` carry the
  source-form name including any `::namespace::Foo` qualification.
  The bridge does not strip or normalize.
- **Cross-repo edge**: out of Phase 1. The Phase-2 handoff doc names
  this as a `get_cross_repo_map` consumer concern.
- **Pragma scanner interaction**: `# JCM:ignore` above a `package
  require` is documented as Phase-2 behavior; Phase 1 captures the
  package_require regardless.

---

## Δ §5.8 — consumer audit list

PLAN v2.1 §5.8 asks reviewers to "verify the additions are minimal
and don't disrupt downstream JCM consumer parsing." The audit set is
now enumerated. P1.4's downstream consumer-impact pass must verify
each consumer either:
(a) gracefully ignores the new fields (for v1.x-shape consumers), or
(b) reads them per the documented schema (for v2.2 consumers).

| Consumer (per CLAUDE.md "Key Files") | Field used | Verification |
|---|---|---|
| `get_class_hierarchy` | `parent_classes` | Reads new field; falls back to `_parse_bases(signature)` only for legacy indexes |
| `get_dependency_graph` | `package_requires` | Reads new field for version-aware dep edges |
| `find_importers` | `kind=import` symbols | Unchanged (C1: both sources populated) |
| `get_cross_repo_map` | `package_requires` | Phase-2 wiring |
| `get_repo_outline` | None | Unaffected |
| `package_registry` | `kind=import` symbols + `package_requires` | Both — version-aware where the field is present |

---

## Δ §3 P1.2 — deliverables (refined)

The PLAN v2.1 P1.2 list still holds. Two concrete additions:

1. **Walker rewrite per §2.1 v2.2 model** is in scope under
   deliverable (a) `tcl_disasm_bridge.tcl` — the bridge driver
   consumes the new walker contract. The walker rewrite is
   technically a P1.1 carry-over but is fastest to land alongside
   the bridge driver since the rewrite re-baselines fixtures the
   bridge tests against.

2. **Recursion-table sub-table A `class NAME BODY` row** (Q2 verdict
   from P1.1) — confirmed in scope; PLAN v2.1 §2.4 sub-table A is
   amended to include the row alongside `itcl::class NAME BODY`.

P1.2 LoC budget: **soft target 900-1200; hard cap removed per user
direction.** §6.1.4 R24 guidance stands; LoC is secondary to
correctness, organization, and human readability per §6.1.10.

---

## Open questions still carried (not resolved by this patch)

- **Q2-style fixture**: callback method recovery in nested cases
  (`after 100 "$obj method [getArg]"`). Add to P1.2 fixture suite
  during build; no spec change.
- **Q4**: user-defined `namespace ensemble create -compile 1`. Bluice
  has none; mechanism via `ensemble_enumeration_probe.tcl` documented.
  Not a Phase-1 spec concern.
- **`namespace` ensemble subcommand drift over time**: P1.4 re-runs
  the enumeration probe before the cut-over decision (§3 P1.3).

---

## End notes

This patch resolves the 5 actionable P1.2 questions surfaced during
P1.1 (Q1, Q3, Q5, Q6, Q7); Q2 and Q4 are documented as scope items.

Schema decisions are pinned to the user's stated end goal (accurate
index for developing/understanding/bug-fixing/feature-impl) within
the Phase-1/Phase-2 boundary (no runtime evaluation, no sandbox
crossing). The walker rewrite is empirically grounded (12,010 corpus
events, 99.98% recognition pre-rewrite, 100% post-rewrite by
construction).

P1.2 reads PLAN_v2.1 + this patch as the spec.
