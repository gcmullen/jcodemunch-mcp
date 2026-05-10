# SPEC_v2.md — JCM TCL Bridge Specification (Phase 1, v2.1 architecture)

**Status:** DRAFT — authored during P1.2 alongside Worker 1's walker
rewrite, Worker 2's recursion tables, and Worker 3's bridge driver.
Replaces the predecessor TCL bridge spec (carried on the
`tcl-native-parser` branch as `tcl_parser_bridge.tcl`'s implicit
contract plus the rule inventory in `validation/RULE_INVENTORY.md`)
when v2.1 ships at the P1.3 cut-over.

**Version:** v2.1 architecture, walker model v2.2 (Strategy A
flat-pc-stream)
**Branch:** `tcl-disasm-bridge`
**Tcl support floor:** 8.6.14 verified; 8.6.10–8.6.13 expected stable
but untested; 9.0 unverified follow-on.

**Authoritative source documents** (this spec integrates and
cross-references; conflicts route to user decision):

1. `dev-docs/verdicts/WALKER_CONTRACT_v2_2.md` — walker API contract
   (ground truth for walker layer).
2. `dev-docs/plans/PLAN_v2.1.md` — architecture
   plan; §2 architecture, §3 phase plan, §4 risks, §6 success
   criteria, §7 file map.
3. `dev-docs/plans/PLAN_v2_2_PATCH.md` — schema
   additions (§Δ0.2: `parent_classes`, `package_requires`) and
   walker rewrite delta (§Δ2.1).
4. `validation/RULE_INVENTORY.md` — every old-bridge rule's fate
   (§A–§J).
5. `dev-docs/verdicts/P1_1_VERDICT.md` — P1.1 close-out; stable APIs
   (`::jcm::disasm::parser::disassemble_and_parse`,
   `::jcm::disasm::walker::walk`).
6. `dev-docs/verdicts/ENSEMBLE_VERDICT.md` — 10-row ensemble
   pre-rename table (R32 finding: `string` ensemble row added).
7. `dev-docs/verdicts/TCL_VERSION_VERDICT.md` — Tcl 8.6.14 verified
   floor; 9.0 unverified follow-on.
8. `validation/probes/P1_2_QUESTIONS_EVIDENCE.md` — Q3 / Q6 corpus
   evidence (12,010 walker events, 99.98% recognition pre-rewrite,
   100% by construction post-rewrite).

> **Reading order for implementers:** §1 → §2 → §7 (schema) → §3
> (walker rules) → §4 (recursion tables) → §5 (body-base) → §6
> (unresolved-dispatch categories) → §8–§12 (operational layers).

---

## Table of contents

1. [Introduction](#1-introduction)
2. [Architecture](#2-architecture)
3. [Walker rules](#3-walker-rules)
4. [Recursion tables](#4-recursion-tables)
5. [Body-base infrastructure](#5-body-base-infrastructure)
6. [Unresolved-dispatch categories](#6-unresolved-dispatch-categories)
7. [Schema](#7-schema)
8. [Pragma conventions (R31)](#8-pragma-conventions-r31)
9. [Tcl version support](#9-tcl-version-support)
10. [Validation architecture](#10-validation-architecture)
11. [Success criteria](#11-success-criteria)
12. [Phase 2 handoff](#12-phase-2-handoff)
13. [Open spec gaps surfaced for user decision](#13-open-spec-gaps-surfaced-for-user-decision)

---

## 1. Introduction

### 1.1 What this bridge does

The JCM TCL bridge produces Layer-1 (symbols) and Layer-2 (call
edges) for TCL source code by recursively disassembling Tcl bytecode
via `tcl::unsupported::disassemble` and applying declarative rules
on the resulting opcode streams. The output is a JSON document
identical in shape to the v1.x bridge's output, with two named
schema additions (`parent_classes`, `package_requires`; see §7).

### 1.2 Phase 1 scope

**In scope:**

- Static parse of every `.tcl` file passed to the bridge.
- Symbol extraction: procs, methods (4 visibilities), classes
  (iTcl + TclOO + bluice custom DSL), namespaces, components,
  interfaces, configbodies, constructors, destructors, coroutines,
  imports.
- Call-edge extraction: Pattern A / A2 / B / callback / ensemble /
  apply-lambda / namespace-eval per §3.
- Unresolved-dispatch tagging across 5 walker event kinds (§6).
- Static inheritance capture (`parent_classes`).
- Static package-require capture (`package_requires`).
- Pragma comments (`# JCM:dynamic` / `# JCM:export` / `# JCM:ignore`)
  as advisory metadata (§8).

**Out of scope (Phase 2):**

- Runtime augmentation (executing file-scope code in a faked env).
- Tk widget / DCSS command / iTcl method runtime stubs.
- Cross-repo edge wiring (`get_cross_repo_map` consumer wiring).
- Pragma-suppression semantics (currently advisory only).
- Wiring of `parent_classes` / `package_requires` into downstream
  JCM consumers (`get_class_hierarchy`, `get_dependency_graph`).
- ROI vs. continued patching question (open per §5.7 of PLAN_v2.1).

### 1.3 Phase 1 ↔ Phase 2 boundary

Phase 1 produces **the data**; Phase 2 wires it into consumers and
augments with runtime signals. The schema fields landed in Phase 1
are bare-named and forward-compatible (`parent_classes` parallels a
future `runtime_parent_classes`); adding Phase-2 runtime data does
not require renaming Phase-1 fields.

### 1.4 Quality posture

Code organization, elegance, and human readability are first-class
concerns alongside correctness (§11 success criterion #10). LoC
targets are soft; F1 ≥ 95% against the validated oracle is a hard
gate.

---

## 2. Architecture

### 2.1 Single-substrate disassemble-recursive design

Per `PLAN_v2.1 §0.2 rule 1`, the bridge has **one parsing
mechanism**: recursive bytecode disassembly via
`tcl::unsupported::disassemble`. Rule application happens
declaratively on opcode streams. The claim is "single substrate,
declarative rules" — NOT "fewer rules than today." Rule count is
similar to the v1.x bridge; the **correctness substrate** is
materially better because Tcl's compiler does the parsing and
emits canonical command boundaries via `src N-M` byte ranges.

**Hard rules** (`PLAN_v2.1 §0.2`, ratified):

1. Single extraction substrate: bytecode disassembly.
2. NO C extension. (R33 fallback documented in §9.4.)
3. NO runtime-faking sandbox. Definition-capture-only sandboxes
   (Signal 2; §10.2) are explicitly permitted as validation
   infrastructure; they record bodies without evaluating them.
4. NO code copy-paste from old bridge. Behavioral matching against
   the contract and helper-pattern re-derivation is fine; importing
   the v1.x parser-layer hodgepodge is forbidden.
5. Same JSON output schema as v1.x, with two named additions
   (§7.2): `parent_classes`, `package_requires`.

**Rule 4 clarification (post-critic-pass)**: "No copy-paste from
v1 bridge" applies to **semantic logic** — parsing, dispatch
ordering, recursion routing, the rules table, body-extraction
strategy. **Mechanical helpers** with one obvious shape (JSON
serialization primitives, UTF-8 char/byte mapping, brace-counting,
dedup-by-key registries) may match v1 byte-for-byte because the
convergent design is the only correct shape. The bridge author
flags this boundary themselves at the metrics-block header in
`tcl_disasm_bridge.tcl` ("Re-derived from first principles per
§0.2 rule 4. The implementations match v1's keyword-counting
heuristics" — search for that comment to find the current line).

**Anti-patterns rejected** (PLAN_v2.1 §0.3):

- C extension via TEA (empirically unjustified per v1 critic).
- Pure-Python static parser (re-introduces parser corner cases).
- Hybrid (parser + bytecode + regex) (violates single-substrate).
- Runtime-faking sandbox (Phase 1 hard rule).
- Bytecode as a secondary signal (bytecode walks the entire
  pattern space).
- Old bridge as a base for incremental edits (greenfield discipline).

### 2.2 Pipeline: parser → walker → recursion-table → bridge driver

```
┌──────────────────────────────────────────────────────────────────┐
│ tcl_disasm_bridge.tcl  (Worker 3 — driver)                       │
│   read source                                                    │
│   pragma_pre_pass(source)  ──────────┐                           │
│   loop file → ::jcm::disasm::parser  │                           │
│              ::jcm::disasm::walker   │ events stream             │
│              recursion-table dispatch├─→ symbols + call edges    │
│              schema accumulator      │                           │
│   emit JSON                          │                           │
└──────────────────────────────────────┴───────────────────────────┘
       │                          │                    │
       ▼                          ▼                    ▼
tcl_disasm_parser.tcl       opcode_walker.tcl   recursion_tables.tcl
(Worker 1 / 306 LoC)        (Worker 1 / ~640    (Worker 2)
                             LoC after rewrite)

Stable APIs (per P1.1 verdict §"Posture for P1.2"):

  ::jcm::disasm::parser::disassemble_and_parse $src
      → dict{stats, source_preview, commands, literals[, error]}

  ::jcm::disasm::walker::walk $parsed
      → list[event-dict]      # walker emission order
                              # under Strategy A == flat pc order
```

### 2.3 Module map (PLAN_v2.1 §7 + WALKER_CONTRACT v2.2 §10)

| Path | Owner | Purpose |
|---|---|---|
| `src/jcodemunch_mcp/parser/tcl_disasm_parser.tcl` | Worker 1 | Disassembly text → structured commands+instructions+src ranges. Pure function. CLI entrypoint for inspection. |
| `src/jcodemunch_mcp/parser/opcode_walker.tcl` | Worker 1 | Strategy A flat-pc-stream walker. Stack simulator; src-range anchor; declarative dispatch + stack-effect tables. |
| `src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl` | Worker 3 | Driver: read → pragma pre-pass → parse → walk → dispatch → emit JSON. Carries `parent_src_offset`, `parent_file` through recursion. |
| `src/jcodemunch_mcp/parser/recursion_tables.tcl` | Worker 2 | Sub-tables A / B / C handlers. Body-content extraction via §5 helpers. |
| `src/jcodemunch_mcp/parser/compute_body_base.tcl` | Worker 2 | Word-position walker + `is_quote_balanced` + body content extractor + cross-file index. ~130–170 LoC per §5. |
| `src/jcodemunch_mcp/parser/unresolved_detector.tcl` | Worker 2 | 5 walker event kinds → schema entries. Pragma cross-validation. |
| `src/jcodemunch_mcp/parser/extractor.py` (existing) | — | TCL branch points to `tcl_disasm_bridge.tcl` (replaces v1.x bridge). |
| `validation/fixtures/disasm/run.tcl` + 22 `.test` | Worker 1 | Walker fixture suite. Re-baseline-by-capture for 9 fixtures; must-not-change for 13. |
| `validation/probes/p1_2_corpus_recognition_probe.tcl` | Worker 1 | Corpus recognition gate (0 unrecognized events across 12,010 corpus events). |
| `tests/test_tcl_parser.py` | Worker 3 | 83 ported tests + 4 new schema-field tests. |
| `dev-docs/specs/SPEC_v2.md` | Planner (this file) | This document. |

### 2.4 Empirical grounding

Strategy A's "every-invoke-pops-N-pushes-1" model is empirically
verified on the bluice corpus:

- **Corpus scope:** BluIceWidgets, DcsWidgets, dcs-lib-tcl/main/
  scripts, dhs-tcl, dcss/scripts/** — 822–823 files.
- **Disassembly failures:** 0.
- **P1.1 walker emission count:** 12,010 events.
- **P1.1 recognition rate:** 99.98% (2 unrecognized of 12,010).
- **Both unrecognized cases** are sub-table B bracket inlining
  (per `P1_2_QUESTIONS_EVIDENCE.md §Q6`):
  - `if [catch ...] { body }` (3 occurrences across
    `scriptingEngine.tcl`, `SequenceDevice*.tcl`).
  - `lindex $argv 0` at file scope (multiple
    `BluIceWidgets/bluice*.tcl` files).
- **Strategy A closes both by construction** (`PLAN_v2_2_PATCH §Δ2.1`):
  bracket subs are interior invokes whose results feed an outer
  invoke; both emit cleanly under flat-pc-stream + innermost-wins
  src-range anchor.

---

## 3. Walker rules

### 3.1 Strategy A semantics

The walker treats Tcl bytecode as **one stack machine across all
"Command N:" labels**. Per-command headers are a labelling of pc
ranges to source ranges, not a partition of stack frames.

Three load-bearing properties (`WALKER_CONTRACT v2.2 §3.1`):

1. **No "terminal" vs "interior" invoke distinction.** Every invoke
   pops N, pushes 1, and emits an event.
2. **Anchor by src range, not pc range.** The cmd_anchor for an
   emitted event is the cmd_idx whose `(src_start, src_end)` is
   the **smallest range containing** `slots[0].src_offset`
   (innermost-wins).
3. **Explicit stack-effect table** for every opcode the walker
   tolerates (§3.4). Declarative; testable in isolation; evolves
   additively as new opcodes surface.

Public entrypoint (stable since P1.1):

```tcl
::jcm::disasm::walker::walk $parsed → list[event-dict]
```

`parsed` is the dict returned by
`::jcm::disasm::parser::disassemble_and_parse $src`. Output is a
list of event dicts in **walker emission order**, which under
Strategy A is **flat pc order** (NOT cmd-idx order).

### 3.2 Dispatch table (16 rows, `WALKER_CONTRACT v2.2 §3.3`)

Order matters: most-specific first, fallthrough to `pattern_a`.
P1.3 Stream 3 added two `invokeReplace`-routed rows (priorities 1
and 2) per the **C-2 split decision** for §13.6 — the existing
`namespace_eval` row stays at priority 3 (was 1) and `var_command`
sits between `var_method` and `pattern_b` per §13.5.

| Priority | Kind | Match predicate |
|--:|---|---|
| 1 | `computed_namespace` | `op==invokeReplace AND last slot LITERAL "::tcl::namespace::eval" AND ≥1 interior slot is VAR` |
| 2 | `ensemble_fqn_rewrite` | `op==invokeReplace AND last slot LITERAL ^::tcl::(array\|binary\|chan\|clock\|dict\|encoding\|file\|info\|namespace\|string)::SUB$ AND last slot != "::tcl::namespace::eval"` (emits `kind ensemble`) |
| 3 | `namespace_eval` | `op==invokeReplace AND last slot LITERAL "::tcl::namespace::eval"` |
| 4 | `expand_args` | `op==invokeExpanded` |
| 5 | `callback` | `op==invokeStk{1,4} AND last slot EXPR strcat-with-method` |
| 6 | `apply_lambda` | `op==invokeStk{1,4} AND slot 0 LITERAL "apply" AND slot 1 LITERAL list-shaped` |
| 7 | `ensemble` | `op==invokeStk{1,4} AND slot 0 LITERAL "::tcl::ENSEMBLE::SUB"` |
| 8 | `eval_var` | `op==invokeStk{1,4} AND slot 0 LITERAL "eval" AND slot 1 VAR` |
| 9 | `eval_brackets` | `op==invokeStk{1,4} AND slot 0 LITERAL "eval" AND slot 1 EXPR invoke_result` |
| 10 | `uplevel_var` | `op==invokeStk{1,4} AND slot 0 LITERAL "uplevel" AND last slot VAR` |
| 11 | `interp_eval` | `op==invokeStk{1,4} AND slot 0 LITERAL "interp" AND slot 1 LITERAL "eval"` |
| 12 | `var_method` | `op==invokeStk{1,4} AND slot 0 VAR AND slot 1 VAR` |
| 13 | `var_command` | `op==invokeStk{1,4} AND slot 0 VAR AND N==1` (§13.5) |
| 14 | `pattern_b` | `op==invokeStk{1,4} AND slot 0 VAR AND slot 1 LITERAL` |
| 15 | `pattern_a2` | `op==invokeStk{1,4} AND slot 0 LITERAL "::ns" (single-segment FQN) AND slot 1 LITERAL` |
| 16 | `pattern_a` | `op==invokeStk{1,4} AND slot 0 LITERAL` (fallback) |

**`eval_brackets` is an explicit dispatch row.** The P1.1
`_sub_table_b_heuristic` proc is **deleted under Strategy A** —
bracket inlining is handled correctly by the flat-pc walk +
innermost-wins anchor + the explicit `eval_brackets` row.

**§13.6 C-2 split (P1.3 Stream 3, USER-DECIDED):** the prior
"single broad predicate at priority 12.5 falling through to
`pattern_a`" approach is **superseded**. Two distinct dispatch
rows now run BEFORE `namespace_eval`:

- **Row 1 — `computed_namespace`** catches `namespace eval $var
  BODY` (Shape A) and emits a new `kind=computed_namespace`
  event. The bridge driver's existing unresolved-family handler
  (`eval_var/interp_eval/var_command/computed_namespace` case)
  consumes it. Empirical examples in `/usr/share/tcltk`:
  - `tcllib1.21/dns/dns.tcl` uses `namespace eval ::dns::$id { ... }`.
  - `tcllib1.21/oo/build.tcl` uses `namespace eval $ns { ... }`.
  - `tk8.6/iconlist.tcl` and similar use `namespace eval [info object namespace $obj] { ... }` (computed via interior `[...]`).

- **Row 2 — `ensemble_fqn_rewrite`** catches stock-ensemble
  subcommands routed via `invokeReplace` (Shape B) and emits
  `kind=ensemble` (NOT a new kind) so the bridge driver's
  existing ensemble handler runs unchanged. Events carry an
  extra `bytecode_form=invokeReplace` field for auditability.
  Empirical examples in `/usr/share/tcltk`:
  - `tcllib1.21/clock/rfc2822.tcl:211` uses `clock format
    [parse_date ...]` → `invokeReplace 3 2` w/
    `::tcl::clock::format`.
  - `tcllib1.21/clock/rfc2822.tcl:213` same shape.
  - many `dict for {k v} $d { ... }`, `dict update $d ...`,
    `dict with $d ...` sites that compile to invokeReplace.

Row 1 explicitly **excludes** the literal `"::tcl::namespace::eval"`
shape (delegated to Row 3 `namespace_eval`); Row 2 explicitly
excludes that exact literal too (otherwise the regex would catch
it). Both excludes preserve `namespace_eval`'s claim on the
literal-namespace shape.

The §13.6 §8 corpus-recognition gate stays clean: both new rows
emit recognized events (not `unrecognized`). Cross-codebase
recognition rate on `/usr/share/tcltk` improved from
**39 unrecognized / 14,215 events** (baseline) to
**0 unrecognized / 14,187 events** after Stream 3 (the event count
delta is from Tier 2's now-correct stack-effect application
collapsing some redundant fallthroughs).

### 3.3 Ensemble pre-rename table (10 rows, post R32)

Empirically derived from `tclsh 8.6.14` disassembly of the 24-file
oracle subset PLUS the full 823-file bluice corpus
(`ENSEMBLE_VERDICT.md`). Tcl 8.6's compiler resolves common
ensemble subcommands at compile time, replacing the literal command
name with a fully-qualified internal name. The bridge un-renames
these via a static lookup so captured edges match the source-form
name developers actually write.

| Compiler-emitted literal | Source form |
|---|---|
| `::tcl::array::*` | `array *` |
| `::tcl::binary::*` | `binary *` |
| `::tcl::chan::*` | `chan *` |
| `::tcl::clock::*` | `clock *` |
| `::tcl::dict::*` | `dict *` |
| `::tcl::encoding::*` | `encoding *` |
| `::tcl::file::*` | `file *` |
| `::tcl::info::*` | `info *` |
| `::tcl::namespace::*` | `namespace *` |
| **`::tcl::string::*`** | **`string *`** **(R32 — added in P1.1f)** |

**Notable empirical finding** (`ENSEMBLE_VERDICT.md`,
`WALKER_CONTRACT §3.3`): Tcl 8.6 compiles `string length` /
`compare` / `match` / `range` / `equal` / `first` / `last` /
`index` / `map` / `trim` / `toupper` / `tolower` to specialized
opcodes (`strlen`, `strcmp`, `strmatch`, `strrangeImm`, `streq`,
etc.) — these never reach the dispatch path. Other `string`
subcommands (corpus-verified `string repeat`; likely `string
replace`, `string reverse`, `string is`, `string totitle`) fall
through to ensemble dispatch and emit `::tcl::string::*` literals
the bridge must rename.

**Scope:** generic to stock Tcl 8.6, not bluice-specific. Bluice/DCS
define no user-level `namespace ensemble create` declarations
(verified empirically; `P1_1_VERDICT.md §Q4`). Future codebases
that define their own compile-time-renamed ensembles via
`namespace ensemble create -compile 1` would need additional rows;
the P1.1 enumeration probe (`ensemble_enumeration_probe.tcl`) is the
mechanism for detecting that.

**Two bytecode routes per ensemble (P1.3 Stream 3):** the same 10
ensembles above are reached via two distinct bytecode shapes
depending on argument shape:

1. `invokeStk{1,4}` — slot 0 holds the rewritten literal (e.g.,
   `::tcl::clock::seconds`); the existing `ensemble` dispatch row
   (priority 7) catches these.
2. `invokeReplace` — last slot holds the rewritten literal; the
   `ensemble_fqn_rewrite` dispatch row (priority 2 — see §3.2)
   catches these and emits `kind=ensemble` so downstream
   consumers see no shape difference. Events carry
   `bytecode_form=invokeReplace` for audit signal.

Empirical mapping (from `/usr/share/tcltk` recognition probe):
- `clock format $x` → `invokeReplace` route (Shape B);
- `clock seconds`, `clock clicks` (no arg) → `invokeStk1` route;
- `dict for {k v} $d { ... }` → `invokeReplace` route;
- `array names a` → `invokeStk1` route.

### 3.4 Stack-effect table (~30 opcodes, `WALKER_CONTRACT v2.2 §3.2`)

One declarative entry per opcode the walker tolerates. Format:

```tcl
# {opcode pop_count push_count effect_class operand_form}
set ::jcm::disasm::walker::STACK_EFFECTS {
    push1            0 1 PUSH_LITERAL    int1
    push4            0 1 PUSH_LITERAL    int4
    pushString       0 1 PUSH_LITERAL    string
    loadStk          1 1 LOAD_VAR        none
    loadScalarStk    1 1 LOAD_VAR        none
    strcat           N 1 STRCAT          int
    expandStart      0 1 EXPAND_START    none
    expandStkTop     1 1 EXPAND_STK_TOP  int
    invokeStk1       N 1 INVOKE          int
    invokeStk4       N 1 INVOKE          int
    invokeReplace    N 1 INVOKE_REPLACE  two-int
    invokeExpanded   * 1 INVOKE_EXPANDED none
    listIndexImm     1 1 SPECIALIZED_OP  int
    storeStk         2 1 SPECIALIZED_OP  none
    pop              1 0 SPECIALIZED_OP  none
    jumpFalse1       1 0 JUMP            int
    jumpTrue1        1 0 JUMP            int
    jump1            0 0 JUMP            int
    jump4            0 0 JUMP            int
    startCommand     0 0 NOP             two-int
    done             0 0 NOP             none
    nop              0 0 NOP             none
    strlen           1 1 SPECIALIZED_OP  none
    strcmp           2 1 SPECIALIZED_OP  none
    strmatch         2 1 SPECIALIZED_OP  none
    strrangeImm      1 1 SPECIALIZED_OP  two-int
    streq            2 1 SPECIALIZED_OP  none
    dictGet          2 1 SPECIALIZED_OP  int
    incrStk          1 1 SPECIALIZED_OP  none
    incrStkImm       1 1 SPECIALIZED_OP  int
}
```

**Operand-form notes** (Worker 1 implements parsing):

- `int` / `int1` / `int4`: single integer operand.
- `string`: string operand (used by `pushString`).
- `two-int`: space-separated `"N M"` pair.
  - For `invokeReplace`: `pop_count` is N (use
    `[lindex [split $operand " "] 0]`); M is the source-form
    word-count collapse used by namespace_eval dispatch.
- `none`: no operand.
- `N` in pop_count: read from operand per `operand_form`.
- `*` in pop_count: dynamic count (`invokeExpanded`'s pops are
  bounded by the EXPAND_MARKER on stack — pop until marker is hit).
- `1` in pop_count for `expandStkTop`: pops only the list slot and
  pushes a single EXPR(expanded_args) slot. The EXPAND_MARKER stays
  on the stack as a sentinel; it is consumed later by `invokeExpanded`
  whose `*` pop_count means "pop everything above and including the
  most-recent EXPAND_MARKER". Empirical receipt for `puts {*}$xs`:
  expandStart pushes MARKER → push "puts" → push xs + loadStk →
  expandStkTop replaces VAR(xs) with EXPR(expanded_args), marker
  stays → invokeExpanded pops EXPR + "puts" + MARKER, slot[0]="puts".
  See `WALKER_CONTRACT §3.1.6` for the corrected canonical pseudocode.

**Adding a new opcode = one row.** Worker 1 shipped a 62-row table
covering the bluice-empirical surface (47 opcodes observed across
12,256 corpus events) plus ~15 safety-margin entries. Source of
truth: `src/jcodemunch_mcp/parser/opcode_walker.tcl` `STACK_EFFECTS`
dict. The sketch above is illustrative — see the shipped table for
the canonical row set. Cross-codebase coverage on `/usr/share/tcltk`
surfaces 12 additional opcodes (P1.3 task #15 expansion plan).

**Tier 2 contract: delta-correct, not shape-correct.** Tier 2
entries (those NOT in `STACK_EFFECTS` but resolved at lookup time
from `tclInstructionTable[]` via `_ensure_tier2_loaded` /
`_tier2_synthesize`) provide canonical pop_count / push_count for
**stack-balance tracking** but DO NOT preserve slot-shape
information. For binary opcodes (e.g. `add`), Tier 2 produces a
single-EXPR-pop-then-push instead of pop=2 / push=1 with EXPR
shape preservation. Today this is invisible because no dispatch
row consumes Tier 2 outputs at slot[-2] depth; if a future row
needs slot-shape preservation for a Tier 2 opcode, the affected
opcode must be **promoted to Tier 1 hand-classification**
(`STACK_EFFECTS` row + corresponding shape rules).

Later Tcl versions extend the table additively. Opcodes encountered
during walk that lack a table
row trigger an `unrecognized` event with `reason=unknown_opcode`
and continue (the walker DOES NOT crash on unknown opcodes — same
posture as `orphan_pc` and `stack_underflow`).

**SPECIALIZED_OP coverage:** the §2.5 GONE list from `PLAN_v2.1`
(string length / compare / match / range / equal; dict get; incr;
storeStk; listIndexImm) is captured. P1.1 fixtures 16–18 cover these
silently — they should still produce zero events under Strategy A.

### 3.5 Event payload schema

11 recognized kinds + `unrecognized` retain the P1.1 dict shape;
v2.2 adds two fields per event:

- `src_start INT` — byte offset of the anchored cmd's source range
- `src_end INT` — byte offset of the anchored cmd's source range end

Both offsets are **byte offsets relative to the source string passed
to `::jcm::disasm::parser::disassemble_and_parse`** — verified
empirically against tclsh 8.6.14 with UTF-8 input
(`WALKER_CONTRACT §2`, `puts héllo` = 10 chars / 11 bytes;
disassembler's `src 0-10` matches the 11-byte length).

| kind | required fields (post-v2.2) |
|---|---|
| `pattern_a` | `cmd, src_start, src_end, name STRING, arg_count INT` |
| `pattern_a2` | `cmd, src_start, src_end, fqn STRING, method STRING, arg_count INT` |
| `pattern_b` | `cmd, src_start, src_end, method STRING, arg_count INT` |
| `callback` | `cmd, src_start, src_end, method STRING` |
| `expand_args` | `cmd, src_start, src_end, name STRING` |
| `apply_lambda` | `cmd, src_start, src_end, lambda STRING` |
| `namespace_eval` | `cmd, src_start, src_end, ns STRING, body STRING` |
| `ensemble` | `cmd, src_start, src_end, ensemble STRING, subcommand STRING, arg_count INT` |
| `eval_var` | `cmd, src_start, src_end` |
| `var_method` | `cmd, src_start, src_end` |
| `uplevel_var` | `cmd, src_start, src_end` |
| `interp_eval` | `cmd, src_start, src_end` |
| `eval_brackets` | `cmd, src_start, src_end` |
| `unrecognized` | `cmd, src_start, src_end, reason STRING, terminal_op STRING, terminal_arg STRING, body_preview STRING` |

The `cmd` field's **semantic shifts under Strategy A**: in v2.1 it
was "the cmd whose pc range contains the terminal invoke"; in v2.2
it's "the cmd whose src range is the smallest one containing the
source_offset of the bottom-most slot consumed by the invoke,
breaking ties by smallest containing range (innermost-wins)". For
non-bracketed cases the two are identical; for bracket inlining they
differ — which is the whole point.

### 3.6 Disasm error and corruption handling

`disasm_error` flow (`WALKER_CONTRACT §1` + `§3.1.5`): if `parsed`
carries `error`, `walk` returns immediately with
`[{kind disasm_error reason STRING}]` and emits no other events.

Three corruption cases the walker tolerates (do NOT abort run):

- **`orphan_pc`** (`WALKER_CONTRACT §3.1.3`): no src range contains
  the slot's offset. Emit `unrecognized` with `reason="orphan_pc"`.
- **`stack_underflow`** (`WALKER_CONTRACT §3.1.4`): invoke pops more
  than stack has. Emit `unrecognized` with
  `reason="stack_underflow"`. Drop slots until the next
  `startCommand` boundary (the bytecode's natural reset point).
- **`unknown_opcode`** (§3.4): opcode lacks a STACK_EFFECTS row.
  Emit `unrecognized` with `reason="unknown_opcode"`.

The bridge driver logs all three at `logger.warning` per the
project's silent-exception rule (CLAUDE.md "Maintenance Practices").

### 3.7 Parent-offset composition (recursive walks)

Walker events carry **body-relative** src offsets. For the file's
top-level call, body == file, so the offsets are file-relative. For
**recursive walker invocations** (Worker 2's sub-table A handlers
re-disassembling proc/method/namespace bodies), the body source is
a substring of the parent. Walker callers MUST track
`parent_src_offset INT` and `parent_file PATH` alongside each
`walk` invocation:

```
file_offset = parent_src_offset + event.src_start
file_line   = lookup_line(line_map_of_file, file_offset)
```

The walker DOES NOT carry these fields on events — they're a
**consumer responsibility**. Bridge driver pseudocode
(`WALKER_CONTRACT §3.1.1`):

```
recurse_body(body_src, parent_src_offset, parent_file, parent_qname):
    parsed = parser::disassemble_and_parse $body_src
    events = walker::walk $parsed
    for ev in events:
        record(ev,
               file_offset = parent_src_offset + ev.src_start,
               file_line   = lookup_line(line_map, file_offset),
               qname       = derive_qname(parent_qname, ev))
```

---

## 4. Recursion tables

### 4.1 Sub-table A — Literal-recursion bodies

Body is opaque literal at the outer level. Walker emits a recognized
event (e.g., `pattern_a name=proc`) carrying the cmd's src range.
Worker 2 extracts body content via §5 helpers and recurses with
`disassemble lambda` or `disassemble script`.

| Construct | Body slot | Recurse via | Layer-1 effect |
|---|---|---|---|
| `proc NAME ARGS BODY` | arg 4 | `disassemble lambda {ARGS BODY}` | symbol kind=function |
| `namespace eval NS BODY` | arg 3 | `disassemble script BODY` | symbol kind=namespace |
| `itcl::class NAME BODY` | arg 3 | `disassemble script BODY` | symbol kind=class (iTcl) |
| **`class NAME BODY`** (custom DSL, P1.1 Q2) | arg 3 | `disassemble script BODY` | symbol kind=class |
| `oo::class create NAME BODY` | arg 3 | `disassemble script BODY` | symbol kind=class (TclOO) |
| `oo::define NAME BODY` | arg 3 | `disassemble script BODY` | adds to existing class |
| `public method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=public |
| `private method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=private |
| `protected method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=protected |
| `method NAME ARGS BODY` (bare) | arg 4 | `disassemble lambda` | kind=method (default) |
| `body NAME ARGS BODY` (out-of-line) | arg 4 | `disassemble lambda` | attaches to existing class via cross-file index (§5.4) |
| `configbody NAME BODY` | arg 3 | `disassemble script` | kind=configbody |
| `constructor ARGS BODY ?INIT?` | arg 3 | `disassemble lambda` | kind=constructor |
| `destructor BODY` | arg 2 | `disassemble lambda` | kind=destructor |
| `apply LAMBDA args` (R8) | inside lambda | `disassemble lambda` | anonymous, attached to call site |
| `foreach var list BODY` | last arg | `disassemble script` | (no symbol; recurse for L2) |
| `lmap var list BODY` | last arg | `disassemble script` | (no symbol) |
| `catch BODY ?varname?` | arg 2 | `disassemble script` | (no symbol) |
| `eval BODY` (when literal) | arg 2 | `disassemble script` | (no symbol) |
| `uplevel ?level? SCRIPT` (when literal) | last | `disassemble script` | (no symbol) |
| `time SCRIPT ?count?` | arg 2 | `disassemble script` | (no symbol) |
| `coroutine NAME SCRIPT ?args?` | arg 3 | `disassemble script` | symbol kind=coroutine |
| `bind ?tag? window SCRIPT` | last | `disassemble script` | (no symbol) |
| `itk_component add ?-protected? NAME CREATE ?CONFIG?` | CREATE only | `disassemble script` (CONFIG = iTk DSL, **explicitly skipped**) | kind=component |
| `itk_option define -switch RES CLASS DEFAULT ?CONFIG?` | last (optional) | `disassemble script` | kind=interface |

**Distinguishing inlined-inner from outer events**
(`WALKER_CONTRACT §4.1`): under Strategy A, sub-table B inner
commands appear as events with `src_start` falling INSIDE the outer
command's `src_start..src_end` range. Worker 2 uses this containment
check to decide "is this event inside the body I just recursed
into?" vs "is this event the outer parent?".

### 4.2 Sub-table B — Outer-bytecode-inlined bodies

Body is jump-compiled INTO the outer bytecode. Calls already visible
at the outer command list. **No recursion needed** — the walker just
processes the outer command stream.

| Construct | How visible |
|---|---|
| `if cond body ?elseif cond body? ?else body?` | each branch is its own command in outer bytecode |
| `while cond body` | body's commands inlined after `startCommand` |
| `for init cond next body` | body's commands inlined after `startCommand` |
| `[bracket]` substitution | the bracketed call is its own command in outer bytecode |

Strategy A's flat-pc walk + innermost-wins anchor closes the 2/12,010
unrecognized cases here without Worker 2 changes
(`P1_2_QUESTIONS_EVIDENCE.md §Q6`, empirical 12,010 → 12,010
recognition gain).

### 4.3 Sub-table C — Mixed / conditional

Walker behavior depends on the construct's compilation form. Each
needs its own handler.

| Construct | Behavior |
|---|---|
| `try BODY ?on/trap errcode varlist BODY?* ?finally BODY?` | BODYs inlined in outer bytecode; errcode/varlist recognized as data positions and skipped |
| `switch ?opts? string ?pat body ...?` (multi-arg form) | bodies inlined |
| `switch ?opts? string {?pat body ...?}` (all-in-one form) | the brace block is a literal; recurse with `disassemble script` then process pat/body pairs |
| `dict for {k v} dict body` | body inlined |
| `dict with var ?keypath? body` | body inlined |
| `dict update var key1 var1 ?key2 var2 ...? body` | body inlined |
| `inherit Base1 Base2 ...` (R12) | no body; record each Base in `parent_classes` field (§7.2.1) |
| **`superclass Base1 Base2 ...`** (TclOO, carried-forward from §Δ0.2) | no body; folds into `parent_classes` alongside `inherit` |
| `package require NAME ?VERSION?` (R13) | no body; record in `package_requires` field (§7.2.2). ALSO emits the existing `kind=import` symbol — both sources populated from the same parse for backward compat with `find_importers` (§7.2.3) |

### 4.4 Per-row spec format (for future additions)

Every recursion-table row carries:

- **Construct:** the source-form command pattern.
- **Body slot:** which arg index holds the body (1-based; arg 0 is
  the command name itself).
- **Recurse-via:** `disassemble lambda {ARGS BODY}` (functions /
  methods) or `disassemble script BODY` (namespaces / control
  flow) or `(none)` (sub-table B inlined).
- **Layer-1 effect:** symbol kind emitted, or `(no symbol)`.
- **Layer-2 effect:** call-edges from body content, or
  `(no L2 from this row)` when sub-table B handles inline.

---

## 5. Body-base infrastructure

### 5.1 The two body-extraction problems (verified empirically)

**Disassembly comment-text problem** (`PLAN_v2.1 §2.2`,
`/tmp/v2_check_truncation.tcl`): `tcl::unsupported::disassemble`
outputs literal operands as `# "..."` comments, but truncates them
at approximately 40 characters with `...`. A 60-character proc body
shows as `"    callA arg1 arg2; callB arg1 arg2; ca..."`. Comments
are informational; **the walker cannot extract body content from
them.**

**Literal-vs-source mismatch problem** (`PLAN_v2.1 §2.2`): the
bytecode literal table stores Tcl's *interpreted* form of strings:
escape sequences resolved (`\n` → literal newline byte), `\$` → `$`.
The source file still contains the unresolved byte sequence. Naive
`string first $literal $source` fails on any body containing escape
sequences.

### 5.2 Strategy: word-position walker on parent source

The bridge re-derives the v1.x bridge's approach (per §0.2 rule 4 of
PLAN_v2.1: helper-pattern reuse, NOT copy-paste):

1. **Use `src N-M` byte ranges** from disassembly to identify each
   command's start/end positions in the parent source string. These
   are reliable; only comment text is truncated.
2. **Custom word-position walker** (~30–50 LoC) operates directly on
   the parent command's source text. Walks left-to-right, tracking:
   - Word boundary (whitespace transitions; respects backslash-
     newline continuation per Tcl's word grammar).
   - Brace nesting (`{...}` words, with depth counting).
   - Quote state (`"..."` words, with backslash escape handling).
   - Quote-balance guard (the `is_quote_balanced` pattern from the
     v1.x bridge — `info complete` cannot be trusted alone; it is
     quote-blind for brace counting per memory
     `jcm_info_complete_brace_bug.md`).
   - Returns the byte position where the Nth word begins.

   This is NOT a full Tcl-command-grammar parser. It is a focused
   word-boundary walker, equivalent in scope to the v1.x bridge's
   helpers. The Tcl compiler still parses command boundaries (via
   disassembly's src ranges); the walker only skips past N-1 words
   within an already-bounded command.
3. **Body-arg extraction:** given the parent command's source text
   and the body-arg index (e.g., 4 for `proc NAME ARGS BODY`):
   - Walker returns the byte position where the Nth word begins.
   - Body's file offset = `parent_base_offset + walker_result`.
   - Body content is the substring from that position through the
     matching close-brace/quote (walker tracks this naturally).
4. **Inline class/namespace bodies:** recurse with `disassemble
   script $body_content`, passing the body's file offset as the new
   `base_offset`.
5. **Proc/method bodies:** recurse with `disassemble lambda {{args}
   body}`, same base-offset propagation.

### 5.3 Production packaging budget (130–170 LoC)

Per `PLAN_v2.1 §2.2 (R6 + R27)`:

| Component | LoC |
|---|--:|
| Word-position walker | 30–50 |
| `is_quote_balanced` guard | ~30 |
| Body-content extraction (substring through matching delimiter) | ~30 |
| Two-pass cross-file index for `body Widget::method` attribution | ~30–50 |
| Driver + plumbing | ~10 |
| **Total** | **130–170** |

P1.0 body-base probe (`validation/probes/body_base_probe.tcl`)
verified the strategy on 382/382 bluice files + 5/5 synthetic; this
is the gate that the production helper must continue to pass.

### 5.4 Cross-file index for `body Widget::method` attribution

The `body NAME ARGS BODY` (out-of-line method definition) construct
attaches a method body to a class declared in a different file. The
helper builds a two-pass index:

- **Pass 1:** discover all classes (`itcl::class`, `class`,
  `oo::class create`) across all files in the indexed set; record
  `(qualified_name, file)`.
- **Pass 2:** for every `body NAME ARGS BODY`, resolve `NAME` to a
  class via the pass-1 map; emit the method symbol with `parent`
  pointing at the class symbol regardless of which file the `body`
  declaration lives in.

### 5.5 Edge cases handled correctly

(Which the v2 string-first strategy did NOT handle.)

- **Identical-bodied methods** (each `setX`/`setY`/`setZ` in a
  class body parses to its own `public method NAME ARGS BODY`
  command with distinct src ranges).
- **Bodies with escape sequences** (the walker walks the source,
  not the interpreted literal).
- **Body content appearing in earlier comments** (the walker walks
  word boundaries; comments are skipped by `lindex`-equivalent
  semantics).

### 5.6 Edge cases that remain unresolved (tagged accordingly)

- **Dynamic body construction** (`proc foo {} [getBody]`): the body
  arg is itself a `[bracket]` substitution at the source level.
  Recursion is infeasible (the body string is a runtime expression).
  Same gap as today; tagged as `dynamic_body` in
  `unresolved_dispatches`. Cross-validated by the §8 dynamic-body
  regex pre-scan.

---

## 6. Unresolved-dispatch categories

5 walker event kinds map directly to schema entries on a symbol's
`unresolved_dispatches` list. Tag conventions per `PLAN_v2.1 §4.1–
§4.6`:

| Walker kind | SPEC §4 category | Schema tag | Notes |
|---|---|---|---|
| `eval_var` | §4.1 | `eval_var` | `eval $var` form (loadStk-arg, no string literal) |
| `var_method` | §4.4 | `var_method` | `$obj $methodvar` form (two loadStk, no method push) |
| `uplevel_var` | §4.5 | `uplevel_var` | `uplevel $script` form |
| `interp_eval` | §4.6 | `interp_eval` | `interp eval $other $cmd` form |
| `eval_brackets` | §4.2 | `eval_brackets` | `eval [bracket]` form |

### 6.1 `var_command` (§4.3)

The v1.x bridge has both `var_command` and `var_method`. Under
Strategy A, `$var args` (no method push) is matched by the
`var_method` row (priority 10 in §3.2) when `slot 1 == VAR`. When
`slot 1 != VAR`, the case devolves into `pattern_b` or fallthrough.
P1.2 fixture suite must lock `var_command` cases as a separate
event kind if they survive the dispatch model — surfaced as open
spec gap (§13.5).

### 6.2 Per-symbol accumulation

Worker 3's bridge driver collects unresolved-dispatch events
emitted **inside a symbol's body** (containment via
`event.src_start ∈ [symbol.byte_offset, symbol.byte_offset +
symbol.byte_length]`) and appends them to that symbol's
`unresolved_dispatches` list. Events at file scope go to
`__script__`'s `unresolved_dispatches`.

### 6.3 Pragma-derived entries (§8)

Pragma comments matched to symbols append additional entries to the
symbol's `unresolved_dispatches`:

```
{kind pragma_dynamic resolves_to "foo" line N}    # # JCM:dynamic
{kind pragma_export                  line N}     # # JCM:export
{kind pragma_ignore                  line N}     # # JCM:ignore
```

---

## 7. Schema

### 7.1 Output JSON shape (Phase 1 contract)

The bridge JSON output is identical to the v1.x bridge's output,
with the two named additions (§7.2). Existing fields are unchanged:

```
{
  "file": "/abs/path/to/file.tcl",
  "language": "tcl",
  "symbols": [ {symbol-record}, ... ],
  "errors": [ ... ]
}
```

Per-symbol record (carried from v1.x):

```
{
  "id": "<file>::<qualified_name>#<kind>",
  "file": "<rel-or-abs path>",
  "line": INT (1-based),
  "end_line": INT,
  "byte_offset": INT,
  "byte_length": INT,
  "name": STRING,
  "qualified_name": STRING,
  "kind": STRING (function|method|class|namespace|...),
  "language": "tcl",
  "signature": STRING,
  "docstring": STRING,
  "summary": STRING,
  "decorators": LIST[STRING],
  "keywords": LIST[STRING],
  "parent": STRING|null,
  "content_hash": STRING,
  "ecosystem_context": STRING,
  "call_references": LIST[CALL-EDGE],
  "unresolved_dispatches": LIST[UNRESOLVED-ENTRY]
}
```

### 7.2 v2.2 additions (`PLAN_v2_2_PATCH §Δ0.2`)

#### 7.2.1 `parent_classes` on class symbols

```
parent_classes: list[{name: STRING, line: INT}]
```

- Carried on **class symbols** (`kind == "class"`) — wire-level
  field is host-only; absent on non-class wire entries (see
  §7.5.1 "Wire vs Python model"; the Python `Symbol` dataclass
  defaults non-host to `[]`).
- Captures iTcl `inherit` AND TclOO `superclass` declarations with
  their source-line numbers.
- Verbatim base names: entries carry the source-form name including
  any `::namespace::Foo` qualification. The bridge does not strip
  or normalize.
- Present on every class symbol (always a list, empty → `[]`);
  absent from the wire on non-class kinds (Python view: `[]`).

Powers `get_class_hierarchy` runtime-free queries.

#### 7.2.2 `package_requires` on `__script__`

```
package_requires: list[{name: STRING, version: STRING|null}]
```

- Carried on the file's **`__script__` symbol** only (file-level,
  not per-namespace) per `PLAN_v2_2_PATCH §Δ0.2 (C2)` — wire-level
  field is host-only; absent on non-`__script__` wire entries
  (see §7.5.1; Python `Symbol` dataclass defaults non-host to
  `[]`). Rationale: `package require` semantically loads a package
  at file load time regardless of nesting depth (Tcl's package
  mechanism is global state, not namespace-scoped).
- Captures `package require NAME ?VERSION?` declarations.
- `version` is `null` when source omits it (`package require Tcl`
  with no version argument).
- Present on `__script__` (always a list, empty → `[]`); absent
  from the wire on every other symbol (Python view: `[]`).

Powers version-aware `get_dependency_graph` queries.

#### 7.2.3 `package require` symbol-vs-field collision (C1) — both

`parse_package` emits **both**:

1. **A `kind=import` symbol per `package require` occurrence** — the
   existing v1.x behavior, consumed by `find_importers` for Tcl
   repos. Unchanged.
2. **An entry in the file's `package_requires` field** — new in v2.2,
   consumed by `get_dependency_graph` and Phase-2 cross-repo tools.

Both sources are populated from the same parse. Tests must lock
both: `test_package_require_emits_import_symbol` (existing) and
`test_package_require_populates_field` (new).

### 7.3 Seven schema decisions (`PLAN_v2_2_PATCH §Δ0.2`)

These decisions are pinned and load-bearing; they are not subject
to revision without re-running the omc:critic gate.

| # | Decision | Rationale |
|--:|---|---|
| 1 | **Bare names (no `static_` prefix)** (M1) | Existing schema fields are bare (`call_references`, `decorators`); `static_` would break naming symmetry. Phase-2 runtime augmentation lives in parallel `runtime_*` fields; consumers merge at read time. |
| 2 | **`parent_classes` carries `{name, line}`** (M2) | Cheap to capture during recursion-table A walker (line is in parent cmd's src_range); expensive to retrofit (schema bump + reindex). Powers jump-to-line in class-hierarchy tools. |
| 3 | **`package_requires` carries `{name, version\|null}`** (M2) | Bridge today embeds version in `signature`; preserving the field is required to avoid regressing `get_dependency_graph` use cases. |
| 4 | **Empty-list always `[]`, never `null`, never omitted** (C3) | Three-state shape (present-and-empty / null / omitted) has burned the team historically (memory `jcm_munch_response_shape.md`). One form. |
| 5 | **`package require` populates BOTH `kind=import` symbol AND `package_requires` field** (C1) | Backward compat with `find_importers`; forward compat with `get_dependency_graph`. |
| 6 | **`package_requires` lives on `__script__` only** (C2) | Tcl's package mechanism is global state, not namespace-scoped. |
| 7 | **Side-table + dual version axis** (M3, **revised at P1.3 close**) | Original M3 ("INDEX_VERSION 9 → 10 + JSON columns") was reverted after architect review surfaced 3 CRITICALs. Shipped design: `jcm_tcl_extensions` side-table + `JCM_TCL_INDEX_VERSION = 1` axis (separate from upstream `INDEX_VERSION`); INDEX_VERSION returns to **9** in lockstep with upstream. Strict-A load gate refuses any DB without the fork-extension stamp; legacy v4→v9 migrations stamp transparently. |

### 7.4 Storage layer (revised at P1.3 close)

> **NOTE — P1.3 close revision.** The original v2.2 plan called for
> `INDEX_VERSION 9 → 10` + JSON columns wired into `_SCHEMA_SQL`. That
> approach was reverted after architect review. P1.2's
> `_migrate_v9_to_v10` was a pure version-stamp; the `_SCHEMA_SQL`
> column adds never landed; serialization paths
> (`_symbol_to_row`, `_row_to_symbol_dict`, `_symbol_to_dict`,
> `_symbol_to_dict_for_delta`) silently dropped both fields, and no
> round-trip storage test existed to catch the gap. P1.3 redesigned
> the storage layer to Option C+D (side-table + dual version axis);
> see CHANGELOG `[Unreleased]` "Schema additions wired through to
> storage" + "Storage shape" sections for the load-bearing details.

**Shipped storage shape:**

- **Side-table `jcm_tcl_extensions`** is the single source of truth
  for fork-extension fields on Tcl symbols. Hybrid columns: typed
  `parent_classes TEXT` (JSON-encoded `list[{name, line}]`) and
  `package_requires TEXT` (JSON-encoded `list[{name, version|null}]`)
  for the stable Phase-1 fields, plus `extras_json TEXT` reserved
  for Phase-2 prototype work.
- **`CREATE TABLE IF NOT EXISTS`** is per-call (mirroring
  `embedding_store.py`). The side-table is intentionally NOT in
  `_SCHEMA_SQL` because the storage layer's `_initialized_dbs` cache
  short-circuits `_SCHEMA_SQL` execution after first connect — an
  out-of-band drop of a SCHEMA_SQL-created table would not be
  re-created on next connect, masking missing-side-table bugs in
  diagnostics. The IF-NOT-EXISTS-per-call pattern is cache-trap-proof.
- **Cascade is explicit**, not implicit. `incremental_save` issues
  `DELETE FROM jcm_tcl_extensions WHERE symbol_id IN (SELECT id FROM
  symbols WHERE file IN (…))` ahead of the symbols delete; `PRAGMA
  foreign_keys` is not set globally, so there is no implicit FK
  cascade. The explicit DELETE is load-bearing.
- **`INDEX_VERSION` returns to 9** (lockstep with upstream). The
  speculative bump to 10 was undone — `_migrate_v9_to_v10` is deleted
  and removed from the migration ladder.
- **Fork-extension data tracks on a separate axis:**
  `JCM_TCL_INDEX_VERSION = 1` is stored under the existing `meta`
  table as `jcm_tcl_writer_version`. Cross-direction load guard is
  **Strict-A** (P1.3 close, "failures rather than fallbacks"
  directive): any DB without an exact-match stamp is refused with a
  clear WARNING, forcing re-index. This includes upstream-built
  indexes (no stamp), older-fork indexes (stamp < constant), and
  newer-fork indexes (stamp > constant). Legacy indexes loaded via
  JSON→SQLite migration or the v4→v9 migration ladder are stamped
  automatically at migration time so they satisfy the gate without a
  manual re-index.
- **Branch-delta wire format**
  (`_symbol_to_dict_for_delta`, `save_branch_delta`,
  `compose_branch_index`) intentionally omits the fork-extension
  fields — wiring deferred to v2.0; locked by an explicit no-op test
  (`test_branch_delta_does_not_carry_fork_extension_data`) so the
  deferral cannot silently regress.

**Cross-language base-code preservation (load-bearing):**

The dual-path design is non-negotiable. `_parse_bases` (signature-
regex extractor) lives in `tools/_class_helpers.py` and serves
Python / JS / Java / C# / Ruby / Go / Rust / etc. — every non-Tcl
language with a class-with-bases shape. The side-table path serves
Tcl class symbols (populated structurally by the bridge). The
`_get_bases()` dispatch is the single entry point that routes by
language. Removing or weakening the regex path would break
cross-language inheritance resolution; the Tcl side-table is
purely additive.

CHANGELOG `[Unreleased]` calls out the re-index requirement and
explains the `parent_classes` / `package_requires` fields with
examples; see `WALKER_CONTRACT v2.2 §10` for the skeleton and
`dev-docs/verdicts/P1_3_VERDICT.md` for the full P1.3 close-out.

### 7.5 Consumer-brittleness pattern (always-list-never-omit-never-null)

Per memory `jcm_munch_response_shape.md`: downstream JCM consumers
historically broke on three-state shape. The empty-list-always rule
(decision #4 above) is **load-bearing**: any future schema field
the bridge emits MUST follow the same pattern.

#### 7.5.1 Wire vs Python model

The "always-list, never-omit" rule (§7.5) holds at the **Python
consumer layer**. The bridge wire format is permitted to omit
host-only fields (`parent_classes`, `package_requires`) on
non-host symbols — wire-level absence is encoder-internal:

| Field | Wire (JSON) | Python `Symbol` dataclass |
|---|---|---|
| `parent_classes` | Present-as-`[]` on `kind=class` symbols only; absent on every other kind. | `default_factory=list` → `[]` for non-class symbols (consumer sees a uniform typed surface). |
| `package_requires` | Present-as-`[]` on the synthetic `__script__` host symbol only; absent on every other symbol. | `default_factory=list` → `[]` for non-host symbols. |

This split (decided=B per §13.2 / §13.3) keeps the wire compact
without breaking consumer code: `Symbol.parent_classes` and
`Symbol.package_requires` are always lists, regardless of whether
the JSON field was emitted. Tests that pin the wire shape vs the
Python shape exist as separate assertions in
`tests/test_tcl_parser.py::TestStreamTwoCleanupInvariants`.

### 7.6 Consumer audit list (`PLAN_v2_2_PATCH §Δ§5.8`)

P1.4's downstream consumer-impact pass must verify each consumer
either (a) gracefully ignores the new fields, or (b) reads them per
the documented schema:

| Consumer | Field used | Verification |
|---|---|---|
| `get_class_hierarchy` | `parent_classes` | Reads new field; falls back to `_parse_bases(signature)` for legacy indexes |
| `get_dependency_graph` | `package_requires` | Reads new field for version-aware dep edges |
| `find_importers` | `kind=import` symbols | Unchanged (C1: both sources populated) |
| `get_cross_repo_map` | `package_requires` | Phase-2 wiring |
| `get_repo_outline` | None | Unaffected |
| `package_registry` | `kind=import` symbols + `package_requires` | Both — version-aware where field is present |

---

## 8. Pragma conventions (R31)

### 8.1 Three pragma kinds

Per `PLAN_v2.1 §3 P1.2 [R31]`:

| Pragma comment | Semantics (Phase 1, advisory) |
|---|---|
| `# JCM:dynamic resolves_to=foo` | Tags a runtime-constructed body site (e.g., `proc foo {} [getBody]`) with the developer-asserted target. |
| `# JCM:export` | Marks an internal symbol as intentionally public; cross-references will surface it. |
| `# JCM:ignore` | Opts a definition out of indexing (PHASE-2 SUPPRESSION; in Phase 1 the bridge records the pragma but does NOT suppress). |

### 8.2 Pre-pass scanner (15 LoC)

The pragma scanner is a **pre-pass over file source**, run BEFORE
the walker, producing:

```tcl
pragmas: list[{kind STRING, line INT, target_line INT}]
```

where `kind` is one of `dynamic`, `export`, `ignore`; `line` is the
pragma comment's line number; `target_line` is the next non-blank
non-comment line (the statement the pragma applies to).

### 8.3 Symbol-attachment rule (NG-1 fix per `WALKER_CONTRACT §4.3`)

Worker 3 attaches pragmas **to symbols, not events**:

- A pragma at line P with `target_line=T` attaches to the symbol
  whose `declaration_line == T`.
- The pragma applies to ALL events inside that symbol's body
  (events whose `src_start` falls within the symbol's
  `byte_offset .. byte_offset + byte_length` range).
- Multi-line bodies inherit the tag (e.g., `# JCM:dynamic` over a
  `proc foo {a b} { ... 20 lines ... }` attaches to the proc symbol;
  every dynamic dispatch inside the body inherits the tag).
- Single-line constructs work the same way (e.g., `# JCM:ignore`
  over a `package require` line: the package-require's symbol
  declaration is at `target_line`, so the pragma attaches there).
- When no symbol's `declaration_line == target_line` (orphan pragma
  above whitespace or a non-symbol-defining statement), the pragma
  is logged at `logger.warning` and dropped.

### 8.4 Dynamic-body regex pre-scan (5–10 LoC)

Worker 3's pragma scanner also runs `\bproc\s+\S+\s+\S+\s+\[`
across each file's source. Output cross-validates against the
walker's `unresolved_dispatches: dynamic_body` tagging.
**Disagreement is a bridge bug:**

- Scanner sees a dynamic-body proc the walker missed → bug.
- Walker tagged a dynamic-body the scanner missed → bug.

Both cases log at `logger.warning` level with file:line for triage.
Narrow scope: this is a cross-validation signal for one specific
pattern, NOT a return to broad regex extraction (which the v2
review rejected as 1.56× over-counting).

### 8.5 Phase 1 vs Phase 2 semantics

Per `PLAN_v2_2_PATCH §Δ0.2 carried-forward items`:

- **Phase 1:** pragmas are **advisory metadata only**. `# JCM:ignore`
  over a `package require` does NOT suppress the existing
  `kind=import` symbol — it adds a `pragma_ignore` entry to the
  symbol's `unresolved_dispatches` for visibility.
- **Phase 2:** suppression semantics; cross-tool integration.

---

## 9. Tcl version support

### 9.1 Verified floor: Tcl 8.6.14

Per `TCL_VERSION_VERDICT.md § (d)`:

- Host: `tcl8.6.14+dfsg-1build1` (Ubuntu noble).
- All P1.0 + P1.1 deliverables verified: parser, walker, 18
  fixtures, ensemble probe over 823 files, body-base probe over
  382 files. 0 disassembly failures.
- The `tcl::unsupported::disassemble` entrypoint, the regex pair in
  `tcl_disasm_parser.tcl`, the 30-row STACK_EFFECTS table, and the
  10-row ensemble pre-rename table are all empirically exact for
  8.6.14.

### 9.2 Untested but expected stable: Tcl 8.6.10–8.6.13

Per `TCL_VERSION_VERDICT.md § (d)`:

- 8.6.x patch versions are documented as format-stable across this
  range.
- `tcl::unsupported::disassemble` was added in 8.5 and remained
  stable through all 8.6.x.
- The opcode set the walker recognizes (invokeStk1/4, invokeReplace,
  invokeExpanded, expandStart/Top, push1/4, loadStk, strcat,
  storeStk) is core 8.6 bytecode and pre-dates 8.6.10.
- Per user direction, aggressive reachability hunting was
  out of scope. Re-verification path documented in
  `TCL_VERSION_VERDICT.md § (d) Re-verification path`.

### 9.3 Unverified follow-on: Tcl 9.0

Per `TCL_VERSION_VERDICT.md § (e) + R26 + R34`. Recorded cost:
**UNVERIFIED follow-on of unknown size — NOT "small."** Five named
risks:

1. **Disassemble entrypoint rename:** Tcl 9 reportedly renames
   `tcl::unsupported::disassemble` (per public Tcl Wiki). LoC
   impact: ~10 lines for guarded dispatch.
2. **Output text-format drift:** 9.0 may revise per-command line
   shapes, pc-range packing, instruction operand formatting.
   Drift forces regex revision and per-fixture re-verification.
3. **Opcode renames or additions:** 9.0 may rename `invokeStk1` →
   `invoke` or introduce new dispatch opcodes. The walker's
   terminal detection is enumerative; new opcodes need explicit
   recognition (one row per opcode).
4. **Ensemble pre-rename table drift:** 9.0 may reduce or expand
   the `::tcl::ENSEMBLE::*` literal set. The 10-row table
   (post P1.1f) is exact for 8.6.14; 9.0 might require partial
   re-enumeration.
5. **Stable-API guarantees:** `tcl::unsupported::disassemble` is
   explicitly unsupported. Tcl 9 may demote/remove without notice.
   The R33 C-extension fallback (§9.4) is the recovery path — but
   the walker substrate would need partial redesign because
   `Tcl_ParseCommand` returns a parse tree, not bytecode.

**Decision point:** revisit when bluice's RHEL/Tcl modernization
timeline firms up. Re-run the probe suite against the targeted 9.0
binary (`TCL_VERSION_VERDICT.md § (e) Rerun reproducer`).

### 9.4 R33 C-extension recovery path

Per `PLAN_v2.1 §4.2 [R33]`. If P1.0 body-base probe surfaces
walker corner cases the pure-Tcl implementation cannot crack
cleanly OR if Tcl 9.0 demotes/removes `disassemble`, the bridge
swaps in a 115-LoC C extension wrapping `Tcl_ParseCommand` (public
stub-table API at `/usr/include/tcl/tcl.h:2021`). Empirical
prototype at `/tmp/parsewords.c` correctly handles all 15 v2.1
recursion-table constructs including the four edge cases (identical
bodies, escape sequences, backslash-newline continuation,
quote-balance defeat).

**Trade-off:** deployment adds gcc + Tcl headers as install-time
prerequisites on DCS hosts. The pure-Tcl path remains preferred
(no build dependency); the C ext is named recovery, not the design
baseline. Decision point: end of P1.0 (now passed; pure-Tcl path
holds).

---

## 10. Validation architecture

Per `PLAN_v2.1 §2.7`. Four-signal cross-check plus an internal
sanity check.

### 10.1 Signal 1 — Bridge

- Captures Pattern A / B / A2 / callback / ensemble / apply-lambda /
  namespace-eval, plus inferred edges from opcode shapes (§3).
- Driven by `disassemble script` + recursion (§4).

### 10.2 Signal 2 — Definition-capture sandbox

Loads each .tcl file in a fresh interpreter where definition
commands are **overridden as recorders**. They capture
`{NAME, ARGS, BODY, source_position}` into a recorder data
structure WITHOUT evaluating the body.

**Override list:**

- `proc`
- `method`, `public method`, `private method`, `protected method`
- `body` (out-of-line method definition)
- `configbody`
- `constructor`, `destructor`
- `itcl::class`
- `namespace eval`
- `itk_component add`
- `itk_option define`
- `inherit` (record as inheritance edge, no body)
- `package require` (record as static dependency, no body)
- `oo::class create`, `oo::define` (forward-compat for iTcl 4 / TclOO)

**Sandbox setup mechanics** (R28; required for the sandbox to
survive real bluice files):

1. **Sandbox init isolation:** create the fresh interp via
   `interp create`, allow Tcl's startup to complete normally (so
   `::tcl::tm::add` and other Tcl-internal procs aren't captured by
   our overrides), THEN install the definition-command overrides.
2. **`source` override:** file-scope `source other.tcl` is real in
   bluice. The sandbox overrides `source` to either no-op (if
   running per-file) or to recursively process the sourced file
   via the same sandbox.
3. **`unknown` override:** file-scope code that's NOT a definition
   (e.g., `::DCS::Component::register $obj` at top level) hits
   "invalid command name" and the sandbox aborts mid-eval, silently
   dropping all definitions after that point. The override redirects
   unknown command lookups to a no-op recorder. **Top-level call
   edges become Signal 1's responsibility, not Signal 2's** —
   Signal 2 captures definitions; Signal 1's bytecode walker
   captures top-level calls.
4. **Per-file `catch` wrapping:** wrap `interp eval $sandbox $src`
   in `catch` so a single file's failure doesn't poison the run.
   Errors logged with file + position context.

**Why this is permitted under §0.2 rule 3** (no-runtime-faking
sandbox): definition-capture does not stub Tk/DCSS/iTcl, does not
evaluate file-scope code as the runtime would, does not need bluice
deps. The `unknown` and `source` overrides are minimal scaffolding
to keep the sandbox alive through file scope; they DO NOT simulate
behavior.

**Implementation budget:** ~200–300 LoC total (R28).

**Independence:** Tcl itself does the source parsing (via the
override mechanism). Signal 1 parses the file as bytecode; Signal 2
parses it as Tcl-command-grammar-level invocations. Both signals
can be wrong, but they cannot be wrong in correlated ways through
the same parser-substrate mechanism.

### 10.3 Signal 3 — LLM-adjudicated oracle

The existing 357-symbol oracle, refined via P1.4 LLM-adjudication
session into a citation-backed reference. Independent of Signals 1
and 2 (different reasoning substrate).

### 10.4 Signal 4 — Hand-curated golden set

- 80–120 edges across 6–8 representative bluice files, each entry
  with `{file, line, caller_qname, callee_name, pattern_kind,
  evidence_citation}`.
- **Verdict rule:** golden-set miss = bridge bug, no LLM
  adjudication needed. Golden-set false-positive in bridge = bridge
  bug, no adjudication. The golden set is the deterministic gate.

### 10.5 Reconciliation rules per edge (R16)

| Edge appears in | Verdict |
|---|---|
| Signals 1 + 2 + 3 + golden | High-confidence accepted |
| Golden set | Authoritative; bridge MUST match |
| Signals 1 + 2 + 3 (no golden coverage) | Accepted |
| Signal 1 only (bridge inference) | Cross-check against Signal 2; accept if both agree |
| Signal 2 + 3 but not Signal 1 | High-priority bridge miss |
| Signal 3 only | LLM-only; requires adjudication; likely oracle noise |
| Signal 1 only, no others | Potential FP; flagged for adjudication |

### 10.6 Internal sanity check (NOT a named signal)

The disassembly-walking bytecode-direct verifier (basically the
bridge with the minimal ruleset) runs alongside Signal 1 on the
same files. Any discrepancy between it and Signal 1 indicates a
rule-application bug in the bridge, not a substrate issue.

### 10.7 Corpus recognition gate (P1.2 deliverable)

Per `WALKER_CONTRACT §8`:

```
File: validation/probes/p1_2_corpus_recognition_probe.tcl
Args: --bluice-root PATH (default /home/giles/bluice)
      --no-synthetic (skip synthetic forcing fixture)
Behavior:
  1. Walk every .tcl in BLUICE_ROOT scope.
  2. Parse via parser::disassemble_and_parse.
  3. Walk via walker::walk.
  4. Count events of kind == "unrecognized".
  5. Track first 10 unrecognized for triage output.
Exit code:
  0 iff total unrecognized count == 0.
  1 if any unrecognized events found.
```

Counts ALL FOUR cases of `unrecognized` events: dispatch fall-
through, `orphan_pc`, `stack_underflow`, `unknown_opcode`. This is
stricter than P1.1's gate (cases 2–4 didn't exist as event types).

---

## 11. Success criteria

Per `PLAN_v2.1 §6.1 (R22–R25 + R30)`. Phase 1 completion gates:

1. **Golden set capture:** 100% (any retired entries have written
   rationale).
2. **Test suite:** 83/83 green + 4 new schema-field tests = 87
   passing (retired tests have rationale).
3. **Performance bound:** indexing ≤ 1.5× current bridge wall-clock.
4. **Bridge LoC (R24):** Soft target — bridge driver
   ≤1600 LoC typical; >1600 requires written rationale. Total
   bridge layer (driver + JSON + post-passes + recursion_tables +
   body_base + walker + parser + unresolved + pragma) is
   **informational, not gated**; reduction from v1's 1925 LoC is
   meaningful at any aggregate under ~5000. Per user direction:
   "> 1200 LoC is acceptable to achieve accurate results." LoC is
   secondary to correctness, organization, and human readability.
   The cap was loosened from 1500 → 1600 post-P1.3-bundle to
   accommodate the CRITICAL #0 body-recursion fix + dispatch_c B
   refactor + dual-validate scaffolding, which together added ~120
   LoC of load-bearing logic that did not warrant churn-extraction.
5. **Four-signal validation:** P1.4 produces validated oracle for
   all 24 files.
6. **F1 against validated oracle:** ≥ 95% **(HARD GATE) (R23).**
7. **Install posture:** Linux x86_64 with stock Tcl 8.6 + iTcl 3.4 —
   no new build dependencies (pure-Tcl path).
8. **Layer 4 partial bonus:** `parent_classes` populated on class
   symbols (R22 + §Δ0.2).
9. **Layer 5 partial bonus:** `package_requires` populated on
   `__script__` (R22 + §Δ0.2).
10. **§6.1.10 — Code organization, elegance, human readability
    (R25; FIRST-CLASS criterion per user direction).** Specific
    checks at P1.2 exit, in an explicit code-reviewer pass:
    - Each rule (opcode pattern, recursion-table entry, sandbox
      override) lives in a named, declarative location — adding a
      new construct is one row in one table, not new code paths.
    - Module boundaries are clean: parser, walker, recursion
      dispatcher, body-base helper, Signal 2 sandbox, JSON emitter
      are separate files, each with a single responsibility.
    - Comments document the *why* (especially for non-obvious Tcl
      compiler behavior); identifier names document the *what*.
    - **A future maintainer (years from now, possibly not the
      original author) can read the bridge cold and understand the
      architecture in under an hour.**
    - This criterion is the user's primary durability requirement;
      Phase 1 fails if the bridge produces correct output via
      impenetrable code.
11. **Phase 2 handoff doc:** catalog of Phase-2-surfaced issues
    delivered as P1.4 output.
12. **Cut-over policy:** written-down decision delivered as P1.3
    output.

### 11.1 Re-run reproducer (post-P1.2)

Per `WALKER_CONTRACT §8 + §9`:

```bash
cd /home/giles/git/jcodemunch-mcp-fork

# Existing P1.0 + P1.1 regression guards
tclsh validation/probes/body_base_probe.tcl --bluice
    # expect: 382/382 + 5/5 synthetic, exit 0
python3 validation/golden_set/validate_golden.py
    # expect: 92/95 + 3 requires_v2_1, exit 0
tclsh validation/probes/ensemble_enumeration_probe.tcl
    # expect: 10 ensembles, exit 0

# 22-fixture suite (18 carry-forward + 4 new for Strategy A)
tclsh validation/fixtures/disasm/run.tcl
    # expect: 22/22 PASS, exit 0

# NEW corpus recognition probe (P1.2 deliverable)
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl
    # expect: 0 unrecognized events across 12,010 corpus events

# Bridge end-to-end on a representative bluice file
tclsh src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl \
    /home/giles/bluice/BluIceWidgets/Anneal.tcl > /tmp/bridge_out.json
jq '.symbols[] | select(.kind=="class") | .parent_classes | type' \
    /tmp/bridge_out.json
    # expect: every class symbol prints "array"
jq '.symbols[] | select(.name=="__script__") | .package_requires | type' \
    /tmp/bridge_out.json
    # expect: "array"

# 83 ported tests + 4 new schema-field tests
uv run --no-project --with pytest --with-editable . pytest \
    tests/test_tcl_parser.py -q
    # expect: 87 passed
```

---

## 12. Phase 2 handoff

What's deferred (per `PLAN_v2.1 §0.1`, `§0.2 rule 5`,
`PLAN_v2_2_PATCH §Δ0.2 carried-forward items`):

### 12.1 Runtime augmentation

- Executing file-scope code in a faked env to capture runtime
  symbol/edge information.
- Tk widget / DCSS command / iTcl method runtime stubs.
- Runs in parallel to Phase-1 static parse; emits `runtime_*`
  schema fields (`runtime_parent_classes`, `runtime_package_requires`,
  etc.) that consumers merge with `parent_classes` /
  `package_requires` at read time.

### 12.2 Tk / DCSS / iTcl runtime stubs

Out of scope for Phase 1 (`PLAN_v2.1 §0.2 rule 3`). Phase 2
revisits the trade-off if a runtime-augmentation lane is approved.

### 12.3 Cross-repo edge wiring

`get_cross_repo_map` consumer concern. Phase 1 produces
`package_requires` data per file; Phase 2 wires it into
cross-repo dependency graphs.

### 12.4 Pragma-suppression semantics

Phase 1 records pragmas as advisory metadata (§8.5). Phase 2:

- `# JCM:ignore` over a `package require` SUPPRESSES the
  `kind=import` symbol (currently does not).
- `# JCM:ignore` over a definition removes the symbol from the
  index entirely.
- `# JCM:export` cross-references surface the symbol in
  `find_references` etc. as if it were declared public.

### 12.5 ROI vs continued patching question

Per `PLAN_v2.1 §5.7`. With v2.1's clarified scope (4–5 weeks, with
body-base offset addressed upfront), is the rewrite investment
justified given the multi-year horizon? User's stated position:
yes. Phase 2 planning revisits if F1 floor is hit early or if
post-P1.4 metrics suggest continued patching of the v1.x bridge
would have been cheaper.

### 12.6 Tcl 9.0 migration

Out of Phase 1 scope per §9.3. Phase 2 includes a 9.0 probe pass
when bluice's RHEL/Tcl modernization timeline firms up.

### 12.7 Phase 2 handoff document

Deliverable of P1.4 (per `PLAN_v2.1 §3 P1.4 step 6`):
`HUMAN_ESCALATIONS.md` + `SPEC_GAPS.md` cataloguing every issue
surfaced during four-signal validation that does not reach a
verdict in Phase 1.

P1.4 oracle-building uses the env var
`JCODEMUNCH_TCL_DUAL_VALIDATE` (P1.3 bundle (12) — Cut-over
policy C″) to surface where the v1.x and v2.x bridges diverge:

- **Off (default)**: runtime path is single-substrate new-bridge
  only.
- **On (`JCODEMUNCH_TCL_DUAL_VALIDATE=1`)**: extractor runs the
  legacy bridge in parallel (fetched via
  `git show tcl-native-parser:src/jcodemunch_mcp/parser/tcl_parser_bridge.tcl`
  to a process-cached temp file) on every TCL parse, computes
  per-symbol presence/absence + shape divergence, and writes a
  JSON diff under `~/.code-index/dual_validate_diffs/`. The
  legacy bridge's output is diagnostic only — the canonical
  result is the new bridge. Legacy bridge failures are recorded
  in the diff but do not affect the runtime parse.

The diff files are P1.4's primary input for building the
behavioural oracle: any non-empty `only_in_legacy` /
`only_in_new` set on a real-world file is a candidate for the
oracle's "expected behaviour" verdict.

---

## 13. Open spec gaps surfaced for user decision

These items emerged during SPEC_v2 integration and need explicit
user adjudication before SPEC_v2 ships at the P1.3 cut-over. The
draft does not unilaterally decide.

### 13.1 SPEC.md ↔ SPEC_v2.md relationship

The existing `/SPEC.md` covers the JCM tool surface (MCP tools,
data models, transports), NOT the TCL bridge. SPEC_v2.md is
specifically the TCL bridge spec. Two interpretations:

- **(A)** SPEC_v2.md replaces a TCL-bridge-specific predecessor
  spec (which lives implicitly on the `tcl-native-parser` branch
  + `validation/RULE_INVENTORY.md`); the existing `/SPEC.md`
  remains untouched.
- **(B)** SPEC_v2.md becomes the v2 of the broader project SPEC
  and absorbs the TCL bridge details into a TCL-bridge section.

This draft assumes **(A)** and lives at `dev-docs/specs/SPEC_v2.md`
(moved at P1.3 close from `docs/SPEC_v2.md`, which was gitignored
upstream). The P1.3 cut-over policy decides where SPEC_v2.md
ultimately lives (`SPEC.md` at root vs permanent under
`dev-docs/specs/` vs other). **User decision still open at P1.3
close** — the P1.3 reorganization moved the spec to a tracked
location but did NOT decide its long-term canonical home.

### 13.2 Empty `package_requires` on non-script symbols

Per §7.2.2, `package_requires` lives on `__script__` only. The
schema decision (§7.3 #6) is settled. But the consumer-brittleness
pattern (§7.5) says "always present, always list, empty → `[]`."
Question: do non-script symbols (procs, classes, etc.) carry an
empty `package_requires: []`, or is the field omitted on
non-`__script__` symbols?

- **(A)** Always present everywhere → consistent shape but bloated.
- **(B)** Present only on `__script__` → smaller payload but
  violates "never omit" rule.

The PATCH §Δ0.2 (C2) resolves to (B) implicitly; this draft adopts
(B) per the patch text. **DECIDED**: (B). `package_requires` is
present only on `__script__`. The Δ0.2 C3 "always present, always
list" rule applies WITHIN the host symbol type — every `__script__`
carries `package_requires` (empty if no requires); other symbols
don't carry the field at all.

### 13.3 `parent_classes` on non-class symbols

Same question as §13.2 for `parent_classes`. The PATCH text says
"`parent_classes` lives on the class symbol (one list per class,
one entry per Base)." Implies (B) — only on classes. **DECIDED**:
(B). `parent_classes` is present only on class symbols (every class
carries it, empty if no inherit/superclass); procs/methods/etc. do
not carry the field.

### 13.4 `class NAME BODY` custom DSL alongside `itcl::class`

Q2 from P1.1 (`P1_1_VERDICT.md`): the custom DSL `class NAME BODY`
construct (used in `Anneal.tcl`, `AutoSample.tcl`, etc.) is added
to sub-table A alongside `itcl::class NAME BODY`. This draft
includes it (§4.1). The PLAN_v2.1 §2.4 sub-table A originally
listed `itcl::class` only; PATCH §Δ§3 confirms the row addition.
**No user decision needed; spec recorded for clarity.**

### 13.5 `var_command` event kind under Strategy A (§6.1)

The v1.x bridge has both `var_command` and `var_method` unresolved
categories. Strategy A's dispatch table (§3.2) has `var_method`
only (priority 10). Cases where `slot 0 == VAR` and `slot 1 != VAR`
fall through to `pattern_b` (priority 11) when `slot 1 == LITERAL`
or to fallthrough `pattern_a` otherwise. Question: should
`var_command` survive as a distinct event kind under Strategy A,
or is it correctly subsumed by the dispatch fallthrough?

**DECIDED**: (A). Add `var_command` row at priority 10.5 between
`var_method` (priority 10) and `pattern_b` (priority 11). Predicate:
`op==invokeStk{1,4} AND slot 0 VAR AND N==1` (the `$var` no-args
case where slot 0 is the only slot). Reasoning: v1 SPEC §4.3 + v1
TestUnresolvedDispatch test the category as distinct; subsuming
would force test retirements with rationale per §11.1 quality
gate. Avoids spurious `unrecognized` events that would break the
§10.7 corpus-recognition gate. The N≥2 case where `$var arg` is
indistinguishable from `$obj method arg` at bytecode level is
accepted as a Strategy A precision-floor limitation (matches the
P1.1 0.017% miss rate); pattern_b classification stands for that
shape.

### 13.6 Computed namespace dispatch (`namespace eval $ns body`)

`WALKER_CONTRACT §3.3 + §5 decision 6`: when `invokeReplace` fires
with last slot != LITERAL `"::tcl::namespace::eval"` (computed
namespace name), the walker falls through to `pattern_a` with
`name="(computed-ns)"`. Two interpretations:

- **(A)** Fallthrough to `pattern_a` (current draft) — preserves
  edge for downstream tools.
- **(B)** Tag as `unrecognized` with `reason="computed_namespace"`
  for visibility — explicit but breaks the "0 unrecognized" gate
  unless the corpus-recognition probe is updated.
- **(C)** Add a distinct `computed_namespace` event kind alongside
  the existing 5 §6 unresolved categories. Same priority slot as
  the rejected (A) (just before `pattern_a` fallthrough). Counts as
  a recognized event (NOT `unrecognized`), so the corpus-recognition
  gate is preserved. Powers Phase-2 runtime-namespace resolution.

**DECIDED**: (C). Adds `computed_namespace` to the dispatch table
with predicate `op==invokeReplace AND last slot != LITERAL
"::tcl::namespace::eval"`. Event payload `{kind computed_namespace
cmd N src_start S src_end E}` matches the 5-kind unresolved family
(eval_var, var_method, uplevel_var, interp_eval, eval_brackets).
The synthetic `name="(computed-ns)"` would have polluted
`find_references`; explicit categorization is the cleaner path and
mirrors how the other §6 unresolved categories work.

### 13.7 `superclass` source-line attribution

`parent_classes` carries `{name, line}` per entry (§7.2.1). For
TclOO, multiple `superclass` declarations can appear in different
`oo::define` blocks for the same class. Question: do we emit one
entry per declaration (preserving multi-site lines) or coalesce
into one entry per parent class with the FIRST line seen?

This draft assumes **one entry per source-form occurrence**
(matches iTcl `inherit Base1 Base2` semantic). **DECIDED**: (A).
One entry per source-form occurrence. iTcl `inherit Base1 Base2`
emits one entry per Base, all sharing the same line. TclOO
multi-site `superclass` declarations preserve every site's line
number — `[{name=A, line=5}, {name=A, line=8}]` is valid for a
class declared with `superclass A` in two `oo::define` blocks.
Consumers wanting class-hierarchy graph rendering can dedup on
`name` post-read; preserving multi-site information is forward-
compatible with developer tooling that wants jump-to-line for any
declaration site.

### 13.8 LoC budget for Worker 2/3 deliverables not in WALKER_CONTRACT

`WALKER_CONTRACT §7` notes walker LoC realism (+85–150 LoC over
P1.1's 569). PLAN_v2.1 §6.1.4 + §2.7 give estimates for body-base
infrastructure (130–170 LoC) and Signal 2 sandbox (200–300 LoC).
Aggregate soft target is 900–1200 LoC for the bridge as a whole.
**No user decision needed; tracked here for transparency at the
§6.1.10 reviewer pass.**

### 13.9 Contradictions during integration

**None found.** The three primary plan documents (`PLAN_v2.1.md`,
`PLAN_v2_2_PATCH.md`, `WALKER_CONTRACT_v2_2.md`) are consistent:

- `PLAN_v2.1 §2.3` claimed "string does NOT need rename-table
  treatment"; `ENSEMBLE_VERDICT.md` retracts this (R32). The
  retraction is recorded as the 10th row in §3.3 and explicitly
  documented as a §Δ0.2-equivalent revision in the PATCH read-
  through. Not a contradiction; an empirical correction.
- `PLAN_v2.1 §0.2 rule 5` originally specified `static_inheritance`
  / `static_package_requires` field names. `PLAN_v2_2_PATCH §Δ0.2
  M1` drops the `static_` prefix. The PATCH supersedes; SPEC_v2
  records the bare names per §7.2 + §7.3 decision #1.
- `PLAN_v2.1 §2.1 walker pseudocode` per-command framing is
  REPLACED by `PLAN_v2_2_PATCH §Δ2.1` Strategy A. SPEC_v2 records
  Strategy A per §3.1.

---

## Appendix A — Cross-reference index

| SPEC_v2 §  | Source document                                    | Section                  |
|------------|----------------------------------------------------|--------------------------|
| §1.1–§1.4  | PLAN_v2.1                                          | §0.1, §0.2, §6           |
| §2.1       | PLAN_v2.1                                          | §0.2 rules 1–5, §0.3     |
| §2.2       | WALKER_CONTRACT v2.2                               | §1, §10 module map       |
| §2.3       | PLAN_v2.1, WALKER_CONTRACT                         | §7, §10                  |
| §2.4       | PLAN_v2_2_PATCH, P1_2_QUESTIONS_EVIDENCE           | §Δ2.1, §Q6               |
| §3.1       | WALKER_CONTRACT v2.2                               | §3.1                     |
| §3.2       | WALKER_CONTRACT v2.2                               | §3.3                     |
| §3.3       | ENSEMBLE_VERDICT, PLAN_v2.1                        | full doc, §2.3           |
| §3.4       | WALKER_CONTRACT v2.2                               | §3.2                     |
| §3.5       | WALKER_CONTRACT v2.2                               | §2                       |
| §3.6       | WALKER_CONTRACT v2.2                               | §1, §3.1.3, §3.1.4, §3.1.5 |
| §3.7       | WALKER_CONTRACT v2.2                               | §3.1.1                   |
| §4.1       | PLAN_v2.1, PLAN_v2_2_PATCH, P1_1_VERDICT           | §2.4 sub-A, §Δ§3, Q2     |
| §4.2       | PLAN_v2.1, P1_2_QUESTIONS_EVIDENCE                 | §2.4 sub-B, §Q6          |
| §4.3       | PLAN_v2.1, PLAN_v2_2_PATCH                         | §2.4 sub-C, §Δ0.2        |
| §5         | PLAN_v2.1                                          | §2.2 (R6 + R27)          |
| §6         | PLAN_v2.1, WALKER_CONTRACT                         | §4, §3.3                 |
| §7         | PLAN_v2_2_PATCH                                    | §Δ0.2 (M1–M4, C1–C3)     |
| §8         | PLAN_v2.1, WALKER_CONTRACT                         | §3 (R31), §4.3           |
| §9         | TCL_VERSION_VERDICT, PLAN_v2.1                     | full doc, §4.1, §4.2     |
| §10        | PLAN_v2.1, WALKER_CONTRACT                         | §2.7 (R14, R15, R16, R28), §8 |
| §11        | PLAN_v2.1                                          | §6.1 (R22–R25, R30)      |
| §12        | PLAN_v2.1, PLAN_v2_2_PATCH                         | §0.1, §Δ0.2 carried-forward |
| §13        | (this document)                                    | (gaps surfaced)          |

---

## Appendix B — Glossary

- **Strategy A**: flat-pc-stream walk with anchor by src range,
  every-invoke-pops-N-pushes-1. Per `PLAN_v2_2_PATCH §Δ2.1`.
- **Strategy B**: rejected pre-pass merger that detects sub-table B
  inlining and concatenates inner Command's instructions into outer
  Command's frame. Rejected because Tcl 8.6 doesn't always nest
  cleanly.
- **Hybrid Strategy C**: rejected — preserves the wrong mental
  model, doesn't dissolve Q5.
- **Innermost-wins**: `lookup_src_range` returns the cmd_idx whose
  `(src_start, src_end)` range is the **smallest** range containing
  the source offset. Tiebreaker: largest cmd_idx (innermost in
  pc-emission order).
- **Sub-table A / B / C**: literal-recursion / outer-bytecode-
  inlined / mixed body structures. Per `PLAN_v2.1 §2.4`.
- **Signal 1 / 2 / 3 / 4**: bridge / definition-capture sandbox /
  LLM oracle / golden set. Per `PLAN_v2.1 §2.7`.
- **`__script__`**: synthetic file-scope symbol holding top-level
  call edges and file-level fields (e.g., `package_requires`).
- **`compute_body_base`**: §5 helper extracting body content from
  parent command source via word-position walker.
- **R-revisions**: numbered revisions in `PLAN_v2.1.md §0.4`. R31
  (pragma scanner), R32 (ensemble enumeration), R33 (C-extension
  fallback), R34 (Tcl 9.0 deferral) are the most cited in this
  spec.
- **§Δ0.2 / §Δ2.1 / §Δ§5.8**: PATCH delta sections in
  `PLAN_v2_2_PATCH.md`. §Δ0.2 = schema additions; §Δ2.1 = walker
  rewrite; §Δ§5.8 = consumer audit.

---

**End of SPEC_v2.md (draft).**
