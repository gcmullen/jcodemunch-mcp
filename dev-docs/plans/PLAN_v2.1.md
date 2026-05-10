# JCM TCL Bridge — Architecture Plan v2.1 (disassemble-recursive, revised)

**Date**: 2026-05-08
**Status**: IMPLEMENTATION-READY DRAFT (post-R27-R30 revisions)
**Branch**: `tcl-disasm-bridge` (greenfield from `upstream/main`)
**Supersedes**: PLAN_v2.md (first draft); PLAN_v1.md (rejected)

This is the v2 plan with R1-R30 revisions applied per
`PLAN_v2_REVIEW.md` and `PLAN_v2.1_REVIEW.md` syntheses. The most
consequential revisions are §2.2 (body extraction via custom word-
position walker), §2.3 (ensemble pre-rename), and §2.7 (Signal 2
sandbox mechanics with `source`/`unknown` overrides). All revisions
are responses to empirical evidence from review-cycle probes.

**Quality posture**: code organization, elegance, and human
readability are first-class concerns alongside correctness. LoC is
secondary — accuracy and maintainability over the multi-year
BluIce/DCS horizon outweigh raw line-count targets.

Revision markers `[Rxx]` flag where each revision lands.

---

## 0. Scope and posture

### 0.1 What this plan covers

**Phase 1 only** — Layer 1 (Symbols) and Layer 2 (Call edges) for
bluice TCL via recursive bytecode disassembly.

Phase 2 (runtime augmentation) is unchanged from v1 and **deferred
to its own planning round**. Reviewers should defer Phase 2
questions, not answer them.

### 0.2 Hard rules (revised)

1. **Single extraction substrate.** [R1] Recursive bytecode
   disassembly (`tcl::unsupported::disassemble`) is the one parsing
   mechanism. Rule application happens declaratively on opcode
   streams. The claim is "single substrate, declarative rules" —
   NOT "fewer rules than today." Rule count is similar; correctness
   substrate is materially better.
2. **NO C extension.** Bytecode access via stock 8.6 disassemble.
3. **No runtime-faking sandbox.** [R3] No stubs for Tk widgets, DCSS
   commands, hardware drivers; no execution of file-scope code in a
   fake env. **However, definition-capture-only sandboxes** (overrides
   on `proc`/`method`/`itcl::class`/`namespace eval` that record
   bodies without evaluating) **are explicitly permitted** as
   validation infrastructure. The verifier scaffold at
   `validation/verify.tcl:68-80 (in jcodemunch-mcp-fork after consolidation)` already uses this pattern. The
   distinction: definition-capture records bodies into a recorder; it
   does not invoke them, does not simulate Tk/DCSS, does not need
   bluice deps to load.
4. **No code copy-paste from old bridge.** [R2] Behavioral matching
   against SPEC.md is fine and required (the spec is the contract).
   Helper-pattern reuse — re-deriving a known approach (e.g.,
   "find first `{` in parent command's source range" for body-base
   recovery) — is fine. The discipline is against importing the
   parser-layer hodgepodge, not against re-deriving the same SPEC
   rules.
5. **Same JSON output schema as today, with one named exception:**
   [R22] Phase 1 captures static `inherit` declarations and literal
   `package require` statements. These need a home. Specification:
   add two minor schema fields in Phase 1, marked
   `static_inheritance: list[str]` and `static_package_requires:
   list[str]`. Phase 2 augments with `runtime_*` versions per v1 plan
   §2.4. The schema additions are documented and kept minimal.
   **Consumer wiring** (i.e., updating `get_class_hierarchy` and
   `get_dependency_graph` to USE these fields) **is explicitly
   Phase 2 work.** Phase 1 produces the data; downstream JCM tools
   consume it later. This avoids Phase-1 scope creep into consumer
   integration.

### 0.3 Anti-patterns rejected (unchanged from v2)

| Pattern | Why rejected |
|---|---|
| C extension via TEA | Empirically unjustified per v1 critic findings |
| Pure-Python static parser | Re-introduces parser corner cases; loses bytecode access |
| Hybrid (parser + bytecode + regex) | User's single-substrate requirement |
| Runtime-faking sandbox | Phase 1 hard rule (definition-capture is distinct, see §0.2 rule 3) |
| Bytecode as a secondary signal | Empirical: bytecode walks the entire pattern space |
| Old bridge as a base for incremental edits | Greenfield discipline (§0.2 rule 4) |

### 0.4 What's new in v2.1 vs v2

[R1-R34 applied — final research pass adds R31-R34]

**R31-R34** are responses to the final pre-commit research pass
(`PLAN_v2.1_FINAL_RESEARCH.md`) which evaluated whether C API
access (`tcl.h`, `tclInt.h`) and/or alternative extraction
strategies (regex, tree-sitter, ctags, ast-grep, pragma comments)
could selectively augment the disassemble-recursive design. The
core verdict: confirm v2.1 architecture; four small additions:

- **R31** — 15-LoC pragma scanner (`# JCM:dynamic`/`# JCM:export`/
  `# JCM:ignore`) plus 5-10 LoC dynamic-body regex pre-scan as
  cross-check on `unresolved_dispatches` opcode tagging. P1.2
  deliverables.
- **R32** — Convert §2.3 ensemble pre-rename table from a guessed
  list to an empirically measured list. P1.1 deliverable: probe
  enumerates `::tcl::*::*` literals Tcl 8.6 actually generates.
- **R33** — Document C-extension-as-escape-hatch in §4.2 risk
  mitigation. Pure-Tcl walker is primary; if P1.0 body-base probe
  shows intractable corner cases, the 115-LoC C extension wrapping
  `Tcl_ParseCommand` (empirically verified at `/tmp/parsewords.c`)
  is the named recovery path.
- **R34** — DEFERRED per user direction. Tcl 9.0 disassemble probe
  is acknowledged as desirable for multi-decade-horizon claim but
  is not in Phase 1 scope. §4.1 retains the "probe-if-reachable;
  document as unverified follow-on of unknown size" framing.
  Revisit when bluice's RHEL/Tcl modernization plan firms up.

**Earlier R-revisions (v2 → v2.1 cycle)**:

- §2.2 rewritten: body extraction uses a custom word-position walker
  on the parent command's source text. `lindex`/`info complete` give
  word values not byte positions, and `info complete` is quote-blind
  for brace counting (per memory `jcm_info_complete_brace_bug.md`);
  the custom walker handles both. [R27, empirically confirmed]
- §2.3 ensemble pre-rename: explicit static lookup table for
  `::tcl::ENSEMBLE::*` → `ENSEMBLE *` (`chan close`, `dict for`,
  `namespace eval`, etc.). [R29]
- §2.7 Signal 2 sandbox spec: explicit `source` and `unknown`
  overrides, per-file `catch` wrapping, sandbox init isolation
  (overrides applied AFTER Tcl startup, only on user-facing
  definition commands). Without these, a top-level non-definition
  call in real bluice files aborts the sandbox eval and silently
  drops subsequent definitions. [R28, empirically confirmed]
- §2.4 split into three sub-tables: literal-recursion / outer-
  bytecode-inlined / mixed.
- Golden set promoted to a named fourth signal.
- §0.2 rule 4 reworded to forbid copy-paste, allow behavioral
  matching against SPEC.
- §0.2 rule 5 amended: small Phase-1 schema additions
  (`static_inheritance`, `static_package_requires`); consumer wiring
  for these fields is explicitly Phase 2 work.
- Budgets rebudgeted: P1.0 to 4-5 days; total 4-5 weeks. [R30]
- §6 success criteria revised: LoC is a soft target; emphasis on
  code organization, elegance, and human readability over raw line
  counts. F1 ≥ 95% remains a hard gate.
- §4 risks updated: Tcl 9.0 is "probe-if-reachable; document as
  unverified follow-on of unknown size."

---

## 1. Problem statement

(Unchanged from v2 §1. JCM tools need accurate Layer 1-2 for the
bluice codebase, which will be maintained over a multi-year horizon.
Robustness matters more than speed-to-ship. Current bridge at F1
93.8% with parser-corner-case bug history; we retire the parser layer
by delegating to Tcl's compiler.)

---

## 2. Architecture

### 2.1 Single extraction substrate: recursive disassembly

(Walker pseudocode unchanged from v2 §2.1.)

```
walk_file(path):
    src       = read_file(path)
    bc        = tcl::unsupported::disassemble script $src
    line_map  = build_line_offsets(src)
    walk(bc, base_offset=0, parent="__script__", line_map, src)

walk(bc, base_offset, parent, line_map, parent_src):
    for cmd in bc.commands:
        cmd_offset_in_parent = cmd.src_start
        cmd_file_offset      = base_offset + cmd_offset_in_parent
        cmd_line             = lookup_line(line_map, cmd_file_offset)
        cmd_text             = parent_src[cmd.src_start..cmd.src_end]
        match opcode_pattern(cmd.instructions):
          PatternA(CMDNAME, args):
              emit_call(parent, CMDNAME, cmd_line)
              if CMDNAME in DEFINITION_TABLE:
                  recurse_definition(cmd_text, base_offset + ...)
              elif CMDNAME in CONTROL_FLOW_TABLE:
                  recurse_body_arg(cmd_text, base_offset + ...)
          ...
```

Key change vs v2: the walker carries `parent_src` (the source string
of the parent command range), not just the disassembly output. This
is required to extract body content correctly (§2.2 below).

### 2.2 File / line / byte-offset tracking [REWRITTEN per R4-R6]

The walker reconstructs file:line:offset for every command and symbol
without trusting disassembly comment text.

**The disassembly comment-text problem (CRITICAL, verified empirically):**
`tcl::unsupported::disassemble` outputs literal operands as `# "..."`
comments, but truncates them at approximately 40 characters with
`...`. A 60-character proc body shows as `"    callA arg1 arg2; callB
arg1 arg2; ca..."`. Comments are informational; **the walker cannot
extract body content from them.**

**The literal-vs-source mismatch problem (CRITICAL, verified
empirically):** the bytecode literal table stores Tcl's *interpreted*
form of strings: escape sequences resolved (`\n` becomes a literal
newline byte), `\$` becomes `$`. The source file still contains the
unresolved byte sequence. Naive `string first $literal $source` fails
on any body containing escape sequences.

**The strategy v2.1 adopts** [R27, empirically grounded] — the
current bridge's approach (per memory `jcm_body_base_offset.md`) re-
derived per §0.2 rule 4. Critically, `lindex`/`info complete` alone
do NOT solve this; they return word values, not byte positions, and
`info complete` is quote-blind for brace counting (`set s "}"`
defeats it without a separate `is_quote_balanced` guard, per memory
`jcm_info_complete_brace_bug.md`). A small custom word-position
walker is needed.

1. **Use `src N-M` byte ranges** from disassembly to identify each
   command's start/end positions in the parent source string. These
   are reliable; only comment text is truncated.

2. **Custom word-position walker** (~30-50 LoC) operates directly on
   the parent command's source text. Walks left-to-right, tracking:
   - Current word boundary (whitespace transitions, respecting
     backslash-newline continuation per Tcl's word-grammar rules)
   - Brace nesting (`{...}` words, with depth counting)
   - Quote state (`"..."` words, with backslash escape handling)
   - Quote-balance guard (the `is_quote_balanced` pattern from
     current bridge — `info complete` cannot be trusted alone)
   - Returns the byte position where the Nth word begins.
   
   This is NOT a full Tcl-command-grammar parser. It is a focused
   word-boundary walker, equivalent in scope to the current bridge's
   helpers. The Tcl compiler still does the parsing for command
   boundaries (via disassembly's src ranges); the walker only needs
   to skip past N-1 words within an already-bounded command.

3. **For body-arg extraction**: given the parent command's source
   text and the body-arg index (e.g., 4 for `proc NAME ARGS BODY`):
   - Walker returns the byte position where the Nth word begins.
   - Body's file offset = `parent_base_offset + walker_result`.
   - Body content is the substring from that position through the
     matching close-brace/quote (walker tracks this naturally).

4. **For inline class/namespace bodies**, recurse with
   `disassemble script $body_content`, passing the body's file
   offset as the new `base_offset`.

5. **For proc/method bodies**, recurse with `disassemble lambda
   {{args} body}`, same base_offset propagation.

6. **`compute_body_base` infrastructure, realistically 130-170 LoC
   total** [R6 + R27]:
   - Word-position walker: 30-50 LoC
   - `is_quote_balanced` guard: ~30 LoC (re-derived from current
     bridge per §0.2 rule 4)
   - Body-content extraction (substring through matching delimiter):
     ~30 LoC
   - Two-pass cross-file index for `body Widget::method` attribution
     (where class is in a different file than the body): ~30-50 LoC
   - Driver + plumbing: ~10 LoC

Per-symbol output stays unchanged: `file`, `line`, `end_line`,
`byte_offset`, `byte_length`, `name`, `qualified_name`, `kind`,
`signature`, `docstring`, `call_references`,
`unresolved_dispatches`, plus `static_inheritance` /
`static_package_requires` per R22.

**Edge cases this strategy handles correctly** (which the v2
string-first strategy did not):
- Identical-bodied methods (each setX/setY/setZ in a class body
  parses to its own `public method NAME ARGS BODY` command with
  distinct src ranges).
- Bodies with escape sequences (we walk the source, not the
  interpreted literal).
- Body content appearing in earlier comments (we walk word
  boundaries, comments are skipped by `lindex`).

**Edge cases that remain unresolved**, tagged accordingly:
- Dynamic body construction (`proc foo {} [getBody]`): the body arg
  is itself a `[bracket]` substitution at the source level.
  Recursion is infeasible (the body string is a runtime expression).
  Same gap as today; tagged as `dynamic_body` in
  `unresolved_dispatches`.

### 2.3 Opcode pattern dispatch table [EXPANDED per R7-R10]

| SPEC pattern | Opcode shape | Emit |
|---|---|---|
| Pattern A (`foo arg`) | `push CMD; ...; invokeStk N` | call `CMD` |
| Pattern A2 (`::ns method arg`) | invokeStk where CMD is single-segment `::X` | call `::X` AND `method` |
| Pattern B (`$obj method arg`) | `push VAR; loadStk; push METHOD; ...; invokeStk N` | method `METHOD` |
| Callback (`-flag "$this method"`) | `push VAR; loadStk; push " METHOD"; strcat 2` | call `METHOD` (kind=callback) |
| **`{*}` argument expansion** [R7] | `expandStart; ...; expandStkTop N; ...; invokeExpanded` | call CMD (first push); arg-expanded sites are still resolvable for the command name |
| **`apply` literal lambda** [R8] | invokeStk to `apply` with a list-shaped literal as arg 2 | recurse into the lambda's body slot |
| **`namespace eval`** [R9] | `push args; push "::tcl::namespace::eval"; invokeReplace N M` | call `namespace eval`; recurse into body slot |
| **Command ensembles (chan, dict, etc.)** [R10 + R29] | `push "::tcl::chan::close"; ...; invokeStk N` (literal pre-renamed by compiler) | un-rename via static lookup table (see below); attribute as `chan close` for symbol/edge consistency |
| eval $var | invokeStk to `eval` with `loadScalar`, no string literal | unresolved `eval_var` |
| $obj $methodvar | `loadStk; loadStk; ...; invokeStk` (two loads, no method push) | unresolved `var_method` |
| uplevel $script | invokeStk to `uplevel` with `loadScalar` | unresolved `uplevel_var` |
| interp eval $other $cmd | invokeStk to `interp` with `eval` arg + `loadScalar` | unresolved `interp_eval` |
| eval [bracket] | invokeStk to `eval` with bracket-result | unresolved `eval_brackets` |

**13 distinct opcode patterns, declared in one table.** Adding a new
pattern is one row.

#### Ensemble pre-rename table [R29 + R32 — empirically populated]

Tcl 8.6's compiler resolves common ensemble subcommands at compile
time, replacing the literal command name with a fully-qualified
internal name. The bridge un-renames these via a static lookup so
captured edges match the source-form name developers actually write.

**Empirically derived from `tclsh 8.6.14` disassembly of the 24 oracle
files plus a synthetic constructs probe (`/tmp/ensemble_probe.tcl`).
Result: 9 ensembles, 43 distinct subcommands observed.**

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

**Notable empirical finding**: `string` does NOT need rename-table
treatment. Tcl 8.6 compiles `string length`/`compare`/`match`/`range`
to specialized opcodes (`strlen`, `strcmp`, `strmatch`,
`strrangeImm`) instead of dispatching through the ensemble — so
the bridge never sees a `::tcl::string::*` literal to rename.

**Scope**: this rename table is **generic to stock Tcl 8.6**, not
bluice-specific. The 9 ensembles above are built into the core
Tcl interpreter; they appear in any TCL codebase using these
stock commands. bluice and DCS define no user-level
`namespace ensemble create` declarations (verified empirically),
so no codebase-specific extensions to the table are needed.
A future codebase that defines its own compile-time-renamed
ensembles via `namespace ensemble create -compile 1` would need
additional rows; the P1.1 enumeration probe is the mechanism for
detecting that.

Implementation: ~20-line lookup table, applied at edge-emission time.
Re-run the enumeration probe in P1.1 against the full bluice corpus
to catch any rare ensemble subcommands the oracle subset missed; add
new rows if any surface.

The strategy: rewrite to source form (`chan close`, not
`::tcl::chan::close`) so that `find_references("chan close")` and
`get_call_hierarchy` produce intuitive results aligned with what a
developer reading the source expects.

### 2.4 Recursion tables [SPLIT per R11-R13]

The walker treats different body structures differently. Three
sub-tables:

#### Sub-table A — Literal-recursion bodies

Body is opaque literal at the outer level. Walker extracts body
content per §2.2 and recurses with `disassemble lambda` or
`disassemble script`.

| Construct | Body slot | Recurse via | Layer 1 effect |
|---|---|---|---|
| `proc NAME ARGS BODY` | arg 4 | `disassemble lambda {ARGS BODY}` | symbol kind=function |
| `namespace eval NS BODY` | arg 3 | `disassemble script BODY` | symbol kind=namespace |
| `itcl::class NAME BODY` | arg 3 | `disassemble script BODY` | symbol kind=class |
| `public method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=public |
| `private method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=private |
| `protected method NAME ARGS BODY` | arg 4 | `disassemble lambda` | kind=method, visibility=protected |
| `method NAME ARGS BODY` (bare) | arg 4 | `disassemble lambda` | kind=method (default) |
| `body NAME ARGS BODY` (out-of-line) | arg 4 | `disassemble lambda` | attaches to existing class |
| `configbody NAME BODY` | arg 3 | `disassemble script` | kind=configbody |
| `constructor ARGS BODY ?INIT?` | arg 3 | `disassemble lambda` | kind=constructor |
| `destructor BODY` | arg 2 | `disassemble lambda` | kind=destructor |
| `apply LAMBDA args` [R8] | inside lambda | `disassemble lambda` | anonymous, attached to call site |
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

#### Sub-table B — Outer-bytecode inlined bodies

Body is jump-compiled INTO the outer bytecode. Calls already visible
at the outer command list. **No recursion needed** — the walker just
processes the outer command stream.

| Construct | How visible |
|---|---|
| `if cond body ?elseif cond body? ?else body?` | each branch is its own command in outer bytecode |
| `while cond body` | body's commands inlined after `startCommand` |
| `for init cond next body` | similar |
| `[bracket]` substitution | the bracketed call is its own command in outer bytecode |

The walker treats these uniformly with bracket substitution: each
inner command appears in the outer command stream with its own
src-range; nothing special.

#### Sub-table C — Mixed / conditional

Walker behavior depends on the construct's compilation form. Each
needs its own handler.

| Construct | Behavior |
|---|---|
| `try BODY ?on/trap errcode varlist BODY?* ?finally BODY?` | BODYs are inlined in outer bytecode; errcode/varlist are NOT bodies (recognized as data positions) |
| `switch ?opts? string ?pat body ...?` (multi-arg form) | bodies inlined |
| `switch ?opts? string {?pat body ...?}` (all-in-one form) | the brace block is a literal; recurse with `disassemble script` then process pat/body pairs |
| `dict for {k v} dict body` | body inlined |
| `dict with var ?keypath? body` | body inlined |
| `dict update var key1 var1 ?key2 var2 ...? body` | body inlined |
| `inherit Base1 Base2 ...` [R12] | no body; record each Base as static-inheritance edge in `static_inheritance` field |
| `package require NAME ?VERSION?` [R13] | no body; record in `static_package_requires` |

### 2.5-2.6 What disappears / stays from SPEC.md

(Unchanged from v2 §2.5-2.6. Skip-list, value-eating-builtin rule,
Tk-flag value guard, bracket-substitution walker, manual
offset-arithmetic — all gone. Pattern A/B/A2 definitions, recursion
table, callback rule, itk_component/option grammar handlers,
unresolved-dispatch categories — stay, re-expressed as opcode
shapes.)

### 2.7 Validation signals [REWRITTEN per R14-R16]

P1.4 cross-validates the bridge against three genuinely-independent
signals plus a hand-curated reference. The disassembly-walking
bytecode-direct verifier is a fourth internal sanity check, not a
named signal (since it shares substrate with Signal 1).

**Signal 1 — Bridge** (full SPEC.md ruleset):
- Captures Pattern A, B, A2, callback, plus inferred edges from
  opcode shapes.
- Driven by `disassemble script` + recursion.

**Signal 2 — Definition-capture sandbox** [R14 + R28]:

- Loads each .tcl file in a fresh interpreter where definition
  commands are overridden as recorders. They capture
  `{NAME, ARGS, BODY, source_position}` into a recorder data
  structure WITHOUT evaluating the body.

**Override list** (definition commands captured as recorders):
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

**Sandbox setup mechanics** [R28 — required for the sandbox to
survive real bluice files]:

1. **Sandbox init isolation**: create the fresh interp via
   `interp create`, allow Tcl's startup to complete normally
   (so `::tcl::tm::add` and other Tcl-internal procs aren't
   captured by our overrides), THEN install the definition-command
   overrides. Without this isolation, the override on `proc` captures
   Tcl's own startup procs and produces self-referential recursion.

2. **`source` override**: file-scope `source other.tcl` is real in
   bluice. The sandbox overrides `source` to either no-op (if we're
   running per-file) or to recursively process the sourced file via
   the same sandbox. Without an override, `source` fails on file
   path resolution and aborts the eval.

3. **`unknown` override**: file-scope code that's NOT a definition
   (e.g., `::DCS::Component::register $obj` at top level — real
   bluice pattern, empirically verified) hits "invalid command name"
   and the sandbox aborts mid-eval, silently dropping all definitions
   after that point. The override redirects unknown command lookups
   to a no-op recorder. **Top-level call edges become Signal 1's
   responsibility, not Signal 2's** — Signal 2 captures definitions;
   Signal 1's bytecode walker captures top-level calls.

4. **Per-file `catch` wrapping**: wrap `interp eval $sandbox $src`
   in `catch` so a single file's failure doesn't poison the run.
   Errors logged with file + position context.

**Why this is now permitted under the no-sandbox rule** (§0.2 rule
3): definition-capture does not stub Tk/DCSS/iTcl, does not evaluate
file-scope code as the runtime would, does not need bluice deps.
The `unknown` and `source` overrides are minimal scaffolding to
keep the sandbox alive through file scope; they DO NOT simulate
behavior. The verifier scaffold at `validation/verify.tcl:68-80`
(jcodemunch-mcp-fork after consolidation) is the starting point; v2.1 extends it.

**This signal is structurally independent of Signal 1** because
Tcl itself does the source parsing (via the override mechanism).
Signal 1 parses the file as bytecode; Signal 2 parses it as
Tcl-command-grammar-level invocations. Both signals can be wrong,
but they cannot be wrong in correlated ways through the same
parser-substrate mechanism.

**Implementation budget**: ~200-300 LoC total [R28]. Components:
- Sandbox init isolation + `interp create`/alias setup: ~30 LoC
- Override implementations (definition recorders): ~80 LoC for the
  full list above
- `source` override (recursive processing variant): ~30 LoC
- `unknown` override + per-file catch: ~30 LoC
- Recorder data structure + extraction: ~40 LoC
- Tests + golden-set integration: ~30 LoC

Larger than v2's "~100 LoC additional" estimate, but justified by
the empirical sandbox-abort findings.

**Signal 3 — LLM-adjudicated oracle**:
- The existing 357-symbol oracle, refined via P1.4 LLM-adjudication
  session into a citation-backed reference.
- Independent of Signals 1 and 2 (different reasoning substrate).

**Signal 4 — Hand-curated golden set** [R15]:
- 80-120 edges across 6-8 representative bluice files, each entry
  with `{file, line, caller_qname, callee_name, pattern_kind,
  evidence_citation}`.
- **Verdict rule**: golden-set miss = bridge bug, no LLM
  adjudication needed. Golden-set false-positive in bridge = bridge
  bug, no adjudication. The golden set is the deterministic gate.

**Reconciliation rules per edge** [R16]:
| Edge appears in | Verdict |
|---|---|
| Signals 1 + 2 + 3 + golden | High-confidence accepted |
| Golden set | Authoritative; bridge MUST match |
| Signals 1 + 2 + 3 (no golden coverage) | Accepted |
| Signal 1 only (bridge inference, e.g., Pattern B method name) | Cross-check against Signal 2 (which can also see method-name pushes if its bodies are walked the same way); accept if both agree |
| Signal 2 + 3 but not Signal 1 | High-priority bridge miss |
| Signal 3 only | LLM-only, requires adjudication; likely oracle noise |
| Signal 1 only, no others | Potential false positive; flagged for adjudication |

**Internal sanity check (NOT a named signal)**: the disassembly-walking
bytecode-direct verifier (basically the bridge with the minimal
ruleset) runs alongside Signal 1 on the same files. Any discrepancy
between it and Signal 1 indicates a rule-application bug in the
bridge, not a substrate issue.

---

## 3. Phase plan [REBUDGETED per R17-R21]

### P1.0 — Branch + rule inventory + golden set + body-base probe (4-5 days) [R30]

**Branching**: greenfield from `upstream/main`. Document the
22-commit upstream divergence; flag bridge-integration-point
(`extractor.py:9088`) for inspection.

**Rule inventory** (`RULE_INVENTORY.md`): every rule in current
`tcl_parser_bridge.tcl` with line range, corresponding test, SPEC
section, fate under v2.1 (gone / opcode-pattern / recursion-table-
entry / kept-as-helper-pattern).

**Golden set** (`golden_set/edges_v1.jsonl`): 80-120 edges.
Per-pattern coverage requirement: ≥10 edges per pattern kind
(Pattern A, B, A2, callback, FQN dispatch, multi-line `-text`,
line continuation, bind callback, itk_component, etc.).

**Body-base probe** [NEW per Critic]: write a small probe that takes
10+ real bluice files, applies the proposed §2.2 strategy
(`compute_body_base` via Tcl list-word grammar on parent source),
verifies recovered line numbers against grep on the source. **Must
pass before P1.1 commits.** If probe finds edge cases the strategy
doesn't handle, iterate before moving on.

### P1.1 — Disasm walker spike + Tcl version probes (3-4 days)

Build the core walker:
- `tcl_disasm_parser.tcl` — parses disassembly textual output into
  structured commands+instructions+literals+src ranges. **Reuse
  `validation/verify.tcl:88-115`** (jcodemunch-mcp-fork after consolidation) as the starting parser — it already works on
  8.6.14.
- `opcode_walker.tcl` — typed event stream from §2.3 patterns.
- Fixture suite ~25 cases.
- **Tcl 8.6.x patch-version regression**: probe across 8.6.10 →
  8.6.14 if available locally. Document any output-format variance.
- **Tcl 9.0 probe** [R26]: if a Tcl 9.0 binary is reachable
  (system-installed, container, etc.), run the probe suite. If 9.0
  output differs, document the deltas and demote 9.0 support to
  "follow-on of size X." If 9.0 is not reachable, document that
  9.0 cost is **unverified**, not "small."

### P1.2 — Rule porting + recursion tables + body-base helper (6-8 days)

Build the bridge proper:
- `tcl_disasm_bridge.tcl` — driver.
- `recursion_tables.tcl` — sub-tables A, B, C from §2.4.
- `compute_body_base.tcl` — full helper, 80-120 LoC + two-pass
  cross-file index for `body Widget::method` attribution.
- `unresolved_detector.tcl` — opcode shapes for §2.3 unresolved
  categories.
- Port of 83 tests; goal 83/83 green.

**LoC bound check at P1.2 exit** [R24]: hard fail at >1200 LoC; soft
target 700-900 (revised up from v2's 500-700 to reflect realistic
body-base helper sizing).

**SPEC_v2 authoring** [Planner]: as part of P1.2, draft `SPEC_v2.md`
documenting the simplified rule layer. Replaces SPEC.md when v2.1
ships.

**[R31] Pragma scanner + dynamic-body regex pre-scan** (~25 LoC total):

- **15-LoC pragma scanner**: pre-pass over each file's source extracts
  `# JCM:KIND args...` markers. Initial conventions documented in
  SPEC_v2:
  - `# JCM:dynamic resolves_to=foo` — explicitly tags a runtime-
    constructed body site (e.g., `proc foo {} [getBody]`) with the
    developer-asserted target.
  - `# JCM:export` — marks an internal symbol as intentionally
    public (cross-references will surface it).
  - `# JCM:ignore` — opts a definition out of indexing.
  Results emitted into the existing `unresolved_dispatches` records
  with `kind=pragma_*`. Zero developers use these today; the cost
  is trivial; the optionality value over a multi-decade horizon is
  real. Ignored cleanly when absent.
- **5-10-LoC dynamic-body regex pre-scan**: matches `\bproc\s+\S+\s+\S+\s+\[`
  shape across each file's source. Output cross-checks against
  opcode-derived `unresolved_dispatches: dynamic_body` tags.
  Disagreement is a bridge bug. Narrow scope: this is a
  cross-validation signal for one specific pattern, NOT a return
  to broad regex extraction (which the v2 review rejected as
  1.56× over-counting).

Inner-loop verification:
- Golden set: 100% capture (or specific entries retired with
  written rationale).
- 83 tests: 83/83 green.

### P1.3 — Cleanup + corpus run + cut-over policy (3-4 days)

> **STATUS — P1.3 closed. Actual scope expanded materially.**
> Original budget was 3-4 days for the bullets below. Architect review
> after P1.2 surfaced 3 CRITICAL + 4 MAJOR storage-layer findings; a
> P1.3 critic-driven bundle added 12 items (CRITICAL #0
> computed_namespace body recursion regression, NIT cleanup, etc.).
> Final P1.3 deliverables and the close-out verdict live at
> `dev-docs/verdicts/P1_3_VERDICT.md`. The bullets in this section
> are the original plan; the verdict documents what actually shipped.

- Run on full bluice 5-repo corpus.
- Performance bound: ≤1.5× current bridge wall-clock.
- **Cut-over policy decision** [Planner]: written-down deliverable
  before Phase 1 closes. Hard cut vs. side-by-side. Old bridge stays
  shippable through P1.4 in either case.

**P1.3 actual delivered scope (close-out summary):**

1. **Stream 2** (Task #16) — T14 reviewer's PASS-WITH-NITS items
   cleaned up (extraction of `bridge_postpasses.tcl` /
   `tcl_disasm_bridge_json.tcl`; recursion-handler routing; missing
   tests; CHANGELOG tightening; `_TCL_BRIDGE_SCRIPT` existence check;
   garbled comment block).
2. **Stream 3** (Task #15) — Dynamic stack-effect inference; 3-tier
   walker with `tclInstructionTable[]` extraction and lazy load;
   `computed_namespace` (Shape A) + `ensemble_fqn_rewrite` (Shape B)
   invokeReplace dispatch rows; cross-codebase recognition on
   `/usr/share/tcltk` 39 unrecognized → 0 unrecognized.
3. **Critic-driven bundle** — 12 items spanning the bridge driver,
   walker, recursion tables, and consumer wire-ups; load-bearing
   item is **CRITICAL #0** computed_namespace body recursion fix
   (`_handle_computed_namespace_body_recurse`) so bodies inside
   `namespace eval $var BODY` are walked alongside the unresolved tag.
4. **DB side-table redesign** (Option C+D, post-architect verdict) —
   `_migrate_v9_to_v10` reverted, `INDEX_VERSION` returns to 9
   in lockstep with upstream, `JCM_TCL_INDEX_VERSION = 1` stored
   under `meta`, fork extension data lives in `jcm_tcl_extensions`
   side-table with hybrid typed columns, Strict-A load gate refuses
   missing/mismatched stamps. Cross-language `_parse_bases` extractor
   preserved for Python/JS/Java/C#/Ruby/Go.
5. **Consumer wire-ups** — `package_registry` Tcl handler,
   `find_references include_descendants`, `get_call_hierarchy`
   parent-class kin merging, plus `tools/_class_helpers.py`
   dual-path dispatch shared across all consumers.
6. **Stream 1** (the original plan bullets) — corpus run on all 5
   bluice repos (12,256 events; 0 unrecognized), perf bench
   stratified small/medium/large with two-number policy
   (parse-only median **0.758×**; end-to-end median **0.766×**;
   PASS by 2× margin), and cut-over policy documented as **hard
   cut**.
7. **Perf debugger root-cause fix** (mid-Stream-1) — `byte_to_char`
   ASCII fast-path + binary search; bridge driver dedup
   `+210/-532` (Stream 2 had left helper procs defined in BOTH the
   bridge driver and the extracted modules, doubling parse time).
   Together: 1.533× → 0.758× on the same bench.
8. **`get_dependency_graph` Tcl wire-up** — virtual `package:NAME`
   nodes; cross-repo edges via `package_names` matching; preserves
   the file-to-file path for non-Tcl languages.
9. **Verifier 5-finding repair** — spot-check regen, CHANGELOG
   dedup paragraph, corrected schema-pop check (the original was a
   row-count vs grep-line-count unit mismatch).

All deliverables green; substantive work + verifier follow-ups
complete; pytest **3,802 passed**; perf parse-only median 0.758×
(gate ≤1.5×).

### P1.4 — Four-signal validation + oracle adjudication (4-5 days) [REBUDGETED per R20]

For each of the 24 oracle files:

1. Produce four signals: bridge (1), definition-capture sandbox (2),
   LLM oracle (3), golden set (4) where coverage exists.
2. Compute disagreement set per §2.7 rules.
3. Run focused LLM-adjudication session on each disagreement:
   source file + four signals + SPEC + entry. Each verdict
   includes citation `file:line`.
4. Two independent LLM sessions per disagreement; agreement
   required.
5. Outputs: `validated_oracle_<file>.json`, `SPEC_GAPS.md`,
   `HUMAN_ESCALATIONS.md`.
6. **Phase 2 handoff doc** [Planner]: catalog all Phase-2 issues
   surfaced during P1.4 for the next planning round.

**Phase exit gates**:
- Bridge F1 against validated oracle: **≥ 95% (HARD GATE, not
  reporting target)** [R23].
- Golden set: 100% bridge capture.
- All disagreements adjudicated or escalated to human review.

### Phase 1 total: 20-26 working days = 4-5 weeks [R21 + R30]

Headline updated. Critic's worst-case (5-6 weeks) bounds the upper
estimate; Planner's revised (3.8-5 weeks) bounds the lower; v2.1's
4-5 day P1.0 absorbs the upstream-rebase risk explicitly. Realistic
mid-case: **4.5 weeks of focused work**.

---

## 4. Risks

(Mostly unchanged from v2; one revision per R26.)

### 4.1 Disassemble text-format stability

8.6.x patch versions: stable in practice; verifier scaffold has
been parsing it. Document any variance found in P1.1 probe.

**Tcl 9.0**: [R26] disassemble entrypoint renames; output format
preserved per public discussion but **not empirically verified by
this plan.** P1.1 includes a 9.0 probe; if probe is impossible,
document 9.0 cost as **unverified follow-on**, not "small."

### 4.2 Body-base offset (CRITICAL, addressed in §2.2 revision)

Realistically 130-170 LoC of pure Tcl (word-position walker +
`is_quote_balanced` guard + body-content extraction + cross-file
index). Was 30 LoC in v2 — that estimate was wrong. P1.0 body-base
probe is the gate.

**[R33] Documented recovery path if pure-Tcl walker proves
intractable**: a 115-LoC C extension wrapping `Tcl_ParseCommand`
(`/usr/include/tcl/tcl.h:2021`, public stub-table API) is a
verified-working fallback. Empirical evidence from final research
pass: prototype at `/tmp/parsewords.c` (115 C LoC + 25 Tcl wrapper
LoC) correctly handles all 15 v2.1 recursion-table constructs
including the four edge cases (identical bodies, escape sequences,
backslash-newline continuation, quote-balance defeat).

If P1.0 body-base probe surfaces walker corner cases the pure-Tcl
implementation cannot crack cleanly, the bridge swaps in the C
extension as the body-position primitive. Trade-off: deployment
adds gcc + Tcl headers as install-time prerequisites on DCS hosts.
The pure-Tcl path remains preferred (no build dependency); the C
ext is named recovery, not the design baseline. Decision point:
end of P1.0.

### 4.3 - 4.7 (unchanged from v2 §4)

iTcl 3.4 grammar coverage, dynamic body construction, Tcl 9.0
migration window, three-signal validation acknowledged-non-independent
(now four-signal per §2.7 — this risk is reduced), validation cost.

### 4.8 Phase 1 stalls

Same risk; same mitigation. Phases independently useful: P1.0 golden
set + P1.1 walker are durable infrastructure even if P1.2 stalls.

---

## 5. Open questions for review

These remain for the v2.1 review pass. v2's questions that have been
resolved are noted.

**RESOLVED in v2.1**:
- ~~5.1 walker pattern coverage~~ → addressed by R7-R10
- ~~5.2 recursion-table completeness~~ → addressed by R11-R13
- ~~5.5 SPEC.md handling~~ → SPEC_v2 in P1.2 deliverable

**Remaining open**:

### 5.3 Reconciliation policy edge cases — P1
With four signals (§2.7 R16), is the reconciliation table complete?
What about edge that appears in Signal 2 + golden set but not bridge?
(Currently implies bridge bug AND adjudication-not-needed; consistent.)

### 5.4 Golden set sizing — P1
80-120 edges with ≥10 per pattern kind. Reviewers should confirm this
is enough. Alternative: 200+ edges? More takes time but durable.

### 5.6 Old-bridge retirement — P1
Same as v2 §5.6. P1.3 names the cut-over policy as a deliverable; the
specific policy is open.

### 5.7 ROI vs. continued patching — P1
Critic raised this in v1 and v2. With v2.1's clarified scope (3.5-5
weeks, with body-base offset addressed upfront), is the rewrite
investment justified given the multi-year horizon? User's stated
position: yes. Reviewers may challenge.

### 5.8 Schema additions for static inheritance/package-requires — P1 [NEW]
Per R22, two new fields. Reviewers verify the additions are minimal
and don't disrupt downstream JCM consumer parsing
(per memory `jcm_munch_response_shape.md` on consumer brittleness).

---

## 6. Success criteria [TIGHTENED per R22-R25]

### 6.1 Phase 1 completion gates

1. **Golden set capture**: 100% (any retired entries have written
   rationale).
2. **Test suite**: 83/83 green (retired tests have rationale).
3. **Performance bound**: indexing ≤ 1.5× current bridge wall-clock.
4. **Bridge LoC at P1.2 exit** [R24, revised]: soft target 900-1200
   (revised up from v2's 700-900 to reflect realistic body-base
   helper sizing and Signal 2 sandbox infrastructure). **No hard LoC
   ceiling.** Per user direction: ">1200 LoC is acceptable to achieve
   accurate results." LoC is secondary to correctness, organization,
   and human readability. The reduction from 1925 (current bridge)
   is a meaningful improvement at any number under ~1500; below
   1200 is the soft success bar.
5. **Four-signal validation**: P1.4 produces validated oracle for
   all 24 files.
6. **F1 against validated oracle**: ≥ 95% **(HARD GATE)** [R23].
7. **Install posture**: Linux x86_64 with stock Tcl 8.6 + iTcl 3.4 —
   no new build dependencies.
8. **Layer 4 partial bonus**: static `inherit` declarations captured
   in `static_inheritance` field [R22].
9. **Layer 5 partial bonus**: literal `package require` captured in
   `static_package_requires` [R22].
10. **Code organization, elegance, human readability** [R25,
    elevated per user direction]: at P1.2 exit, an explicit code-
    reviewer pass against this standard. **First-class success
    criterion**, not subjective afterthought. Specific checks:
    - Each rule (opcode pattern, recursion-table entry, sandbox
      override) lives in a named, declarative location — adding a
      new construct is one row in one table, not new code paths.
    - Module boundaries are clean: parser, walker, recursion
      dispatcher, body-base helper, Signal 2 sandbox, JSON emitter
      are separate files, each with a single responsibility.
    - Comments document the *why* (especially for non-obvious Tcl
      compiler behavior); identifier names document the *what*.
    - A future maintainer (years from now, possibly not the original
      author) can read the bridge cold and understand the
      architecture in under an hour.
    
    This criterion is the user's primary durability requirement;
    Phase 1 fails if the bridge produces correct output via
    impenetrable code.
11. **Phase 2 handoff doc**: catalog of Phase-2-surfaced issues
    delivered as P1.4 output.
12. **Cut-over policy**: written-down decision delivered as P1.3
    output.

### 6.2 Layer coverage delivered

Same table as v2 §6.2.

---

## 7. Files

(File list unchanged from v2 §7, plus:)
- **This plan**: `dev-docs/plans/PLAN_v2.1.md` (moved from
  `/home/giles/bluice/.omc/jcm-test/PLAN_v2.1.md` at P1.3 close)
- **v2 review synthesis**: `/home/giles/bluice/.omc/jcm-test/PLAN_v2_REVIEW.md`
  (untracked working artifact; not moved)
- **Per-agent v2 reviews**: `PLAN_v2_REVIEW_PLANNER.md`,
  `PLAN_v2_REVIEW_ARCHITECT.md`, `PLAN_v2_REVIEW_CRITIC.md`
  (untracked working artifacts in `~/.omc/jcm-test/`; not moved)
- **Empirical probes from v2 review** (reproducible):
  - Body-base failure: `/tmp/v2_body_base_probe.tcl`
  - Comment truncation: `/tmp/v2_check_truncation.tcl`
  - Opcode shapes: `/tmp/v2_check_opcodes.tcl`
  - Format stability: `/tmp/v2_disasm_format_probe.tcl`

---

## 8. Standing rules

(Unchanged from v2 §8.)

---

## 9. End notes

v2.1 differs from v2 in implementation-detail tightening, not
architecture. Three review cycles with empirical probes have
narrowed the open questions to implementation-level concerns. The
disassemble-recursive substrate stands; the rule application is
carefully specified.

**Empirical findings that drove revisions across cycles**:

1. **v1 cycle** (Critic): `tcl::unsupported::disassemble lambda`
   works on 100% of bluice bodies in stock tclsh — killed v1's
   C-extension premise.
2. **v2 cycle** (Architect): disassembly comment-text truncates at
   ~40 chars — the walker must use src N-M byte ranges, not
   comment text.
3. **v2 cycle** (Critic): naive string-search body-base strategy
   fails on identical bodies and escape-sequence mismatches —
   adopted the current bridge's "find body via Tcl word-grammar
   on parent source" approach.
4. **v2.1 cycle** (Architect + Critic): `lindex`/`info complete`
   alone don't give byte positions, and `info complete` is
   quote-blind; need a custom word-position walker (~30-50 LoC)
   plus `is_quote_balanced` guard. [R27]
5. **v2.1 cycle** (Architect + Critic): Signal 2 sandbox aborts
   on file-scope non-definition calls and `source` calls; needs
   `unknown` override, `source` override, init isolation, per-file
   `catch` wrapping. [R28]

Each finding was reproducible via probe; revisions are
empirically grounded, not speculative.

**Quality posture**: code organization, elegance, human readability
(§6.1.10) are first-class success criteria. The bridge is for the
multi-year BluIce/DCS horizon; a maintainer years from now must be
able to read it cold. LoC is secondary; clarity is primary.

**Validation architecture**: four-signal cross-check (bridge,
definition-capture sandbox, LLM-adjudicated oracle, hand-curated
golden set) plus internal bytecode-direct sanity check. Signals 1
and 2 are genuinely independent (different parser substrates: Tcl's
compiler vs. Tcl's command-grammar interpreter). The user's
bytecode-validation endorsement is preserved through both Signal 1's
extraction and the internal sanity check.

**Status**: this plan is implementation-ready. R27-R30 applied
in-place per the v2.1 review synthesis. After a sanity-check pass
from the omc reviewers (focused, NOT a full re-review), P1.0 is
clear to start.
