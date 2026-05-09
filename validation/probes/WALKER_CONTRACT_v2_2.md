# Walker contract v2.2 — Strategy A flat-pc-stream

**Date**: 2026-05-08 (rev2 after omc:critic REVISE pass + empirical validation)
**Status**: P1.2 contract — Workers 2-3 build against this; Worker 1
implements it.
**Specs this distills**:
- `PLAN_v2.1.md §2.1, §2.3` (base walker model + dispatch table)
- `PLAN_v2_2_PATCH.md §Δ2.1` (Strategy A flat-pc-stream rewrite)
- `PLAN_v2_2_PATCH.md §Δ0.2` (parent_classes / package_requires schema)
- `validation/probes/P1_2_QUESTIONS_EVIDENCE.md` (Q5/Q6 corpus evidence)
- `src/jcodemunch_mcp/parser/opcode_walker.tcl` (P1.1 event payload shape;
  preserved by v2.2 except where called out below)
- `src/jcodemunch_mcp/parser/tcl_disasm_parser.tcl` (parser shape; the
  `src S-E` byte-offset semantic verified empirically below)

This is the **API contract** the rewritten walker exposes after P1.2(e).
Workers 2 (recursion tables / body-base / unresolved detector) and 3
(bridge driver / schema additions / test port / pragma scanner) read
against this — they do not need to wait for Worker 1 to finish.

---

## 1. Public entrypoint (unchanged from P1.1)

```tcl
::jcm::disasm::walker::walk parsed → list[event-dict]
```

Signature stable. `parsed` is the dict returned by
`::jcm::disasm::parser::disassemble_and_parse $src`. Output is a list
of event dicts in **walker emission order**, which under Strategy A is
**flat pc order**. This is NOT cmd-idx order: when a bracket sub
appears in source after its outer command but earlier in pc, the
sub's events fire FIRST. See §6 fixture re-baseline policy.

Disassembly errors flow through unchanged in shape, with one Strategy
A clarification:

```tcl
{kind disasm_error reason STRING}
```

If `parsed` carries `error`, walker returns a single-element list with
this event and **no other events**. If a corruption is detected
mid-walk (stack underflow; orphan pc; see §3.1.4 / §3.1.5), the walker
emits an `unrecognized` event for the affected invoke and continues —
errors do not abort the run.

---

## 2. Event payload schema

**11 recognized kinds + `unrecognized` retain their P1.1 dict shape**;
v2.2 adds two fields per event:

- `src_start INT` — byte offset of the anchored cmd's source range
- `src_end INT` — byte offset of the anchored cmd's source range end

Both offsets are **byte offsets relative to the source string passed
to `::jcm::disasm::parser::disassemble_and_parse`** — verified
empirically against tclsh 8.6.14 with UTF-8 input ("puts héllo" = 10
chars / 11 bytes; the disassembler's per-cmd `src 0-10` matches the
11-byte length, not the 10-char length). For top-level walker calls
the source IS the file, so file-offset == src offset. **For recursive
walker calls** (Worker 2's sub-table A handlers re-disassemble bodies
via `disassemble script $body` or `disassemble lambda {ARGS BODY}`),
the source string is the body itself; src offsets are body-relative.
See §3.1.1 for the parent-offset composition rule.

The `cmd` field stays (cmd_idx of the anchored cmd) but its
**semantic shifts**: in v2.1 it was "the cmd whose pc range contains
the terminal invoke"; in v2.2 it's "the cmd whose src range contains
the source_offset of the bottom-most slot consumed by the invoke,
breaking ties by smallest containing range (innermost-wins)". For
non-bracketed cases the two are identical; for bracket inlining they
differ — which is the whole point. See §3.1.2 for tiebreaker rules.

Event dict shapes:

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
| `var_command` | `cmd, src_start, src_end` |
| `var_method` | `cmd, src_start, src_end` |
| `uplevel_var` | `cmd, src_start, src_end` |
| `interp_eval` | `cmd, src_start, src_end` |
| `eval_brackets` | `cmd, src_start, src_end` |
| `computed_namespace` | `cmd, src_start, src_end` |
| `unrecognized` | `cmd, src_start, src_end, reason STRING, terminal_op STRING, terminal_arg STRING, body_preview STRING` |

**Why `src_start`/`src_end` are added**: Worker 2's recursion-table
handlers and Worker 3's bridge driver previously had to look up the
parsed cmd by `cmd_idx` to find its src range. With Strategy A, the
anchored cmd is already computed at emit time; passing the range
through the event eliminates one lookup hop per event. Note this does
NOT replace parent-offset bookkeeping for recursive walks — see §4 on
caller responsibilities.

**Note on stability**: the contract's "two field additions per row"
phrasing oversells stability slightly. Three things change in
practice: (1) the new fields, (2) the `cmd` field's semantic for
bracketed cases, and (3) emission order shifts to flat pc order.
Consumers that compare events ordinal-by-ordinal MUST handle (3); see
§6 re-baseline policy.

---

## 3. Walker internals (Strategy A)

Worker 1 implements; Workers 2-3 don't read this section but it's
documented here for the §6.1.10 maintainer-grasp criterion.

### 3.1 Flat-pc-stream walk

```
walk(parsed):
    flat_insns = sort by pc(union of all c.instructions for c in parsed.commands)
    src_ranges = sort by src_start(parsed.commands)   # for binary search
    pc_to_cmd  = build_pc_to_cmd_lookup(parsed.commands)
    stack      = []
    events     = []

    for insn in flat_insns:
        # Compute the src offset associated with insn's source location
        # by mapping insn.pc → containing cmd's (smallest pc range) → that
        # cmd's src_start. This is the slot's `src_offset` going forward.
        src_offset = pc_to_src_offset(insn.pc, pc_to_cmd, src_ranges)

        match opcode_class(insn.op):
          PUSH_LITERAL:
              stack.push({kind:LITERAL, value:literal_text(insn),
                          src_offset:src_offset})
          LOAD_VAR:
              # last push was the var name; replace top with VAR slot
              # preserving the var name's src_offset
              stack.replace_top({kind:VAR, value:varname,
                                 src_offset:stack[-1].src_offset})
          STRCAT n:
              top_n = stack.pop_n(n)
              method = capture_method_if_callback_shape(top_n)
              stack.push({kind:EXPR, value:strcat, method:method,
                          src_offset:top_n[0].src_offset})  # bottom-most
          EXPAND_START:
              # Push a marker; the marker's src_offset anchors the
              # expanded slot when EXPAND_STK_TOP fires.
              stack.push({kind:EXPAND_MARKER, src_offset:src_offset})
          EXPAND_STK_TOP:
              # Replace top (the loaded list) with an EXPR slot. The
              # EXPAND_MARKER stays on the stack — it is the sentinel
              # invokeExpanded uses to find its arg-count boundary.
              list_slot = stack.pop()
              # Anchor to the marker's src_offset (search down the stack
              # for the most-recent EXPAND_MARKER). Falls back to the
              # list_slot's src_offset if no marker present (defensive).
              marker_offset = find_expand_marker_offset(stack) ?? list_slot.src_offset
              stack.push({kind:EXPR, value:expanded_args,
                          src_offset:marker_offset})
          INVOKE op N:
              # terminal OR interior — same handling
              if stack_size() < N: emit_unrecognized_underflow(...); continue
              slots      = stack.pop_n(N)
              cmd_anchor = lookup_src_range(slots[0].src_offset, src_ranges)
              if cmd_anchor.miss: emit_unrecognized_orphan(...); continue
              ev         = dispatch_match(slots, op, cmd_anchor)
              events.append(ev)
              stack.push({kind:EXPR, value:invoke_result,
                          src_offset:src_offset})
          SPECIALIZED_OP:
              apply_stack_effect(stack, insn.op, insn.operand, src_offset)
          JUMP / NOP:
              pass

    return events
```

Three load-bearing changes vs P1.1:

1. **No "terminal" vs "interior" invoke distinction.** Every invoke
   pops N, pushes 1, and emits. Q5 dissolves.
2. **Anchor by src range, not pc range.** `cmd_anchor` resolves to
   the cmd whose `(src_start, src_end)` is the **smallest range
   containing** `slots[0].src_offset` (innermost-wins). The 2/12,010
   unrecognized cases close by construction (verified empirically:
   `puts [lindex [split $s ","] 0]` produces 3 ranges with overlap
   0-29, 6-28, 14-25; innermost-wins correctly attributes split's
   invoke to cmd 3, lindex's to cmd 2, puts's to cmd 1).
3. **Explicit stack-effect table** for every opcode the walker
   tolerates. Declarative, testable in isolation, evolves additively
   as new opcodes surface in later Tcl versions.

### 3.1.1 Parent-offset composition (recursive walks)

Walker events carry **body-relative** src offsets. For the file's
top-level call, body == file, so the offsets are file-relative. For
**recursive walker invocations** (Worker 2's sub-table A handlers
re-disassembling proc/method/namespace bodies), the body source is a
substring of the parent. Walker callers MUST track `parent_src_offset
INT` and `parent_file PATH` alongside each `walk` invocation:

```
file_offset = parent_src_offset + event.src_start
file_line   = lookup_line(line_map_of_file, file_offset)
```

The walker DOES NOT carry these fields on events — they're a consumer
responsibility. Rationale: keeping events stable across recursion
depths means a depth-2 method's events have the same shape as a
top-level proc's events, and the bridge driver composes file
positions at the call site (where the parent_src_offset is known).
This is explicit in the bridge driver's recursion API:

```
recurse_body(body_src, parent_src_offset, parent_file, parent_qname):
    parsed = parser::disassemble_and_parse $body_src
    events = walker::walk $parsed
    for ev in events:
        record(ev, file_offset = parent_src_offset + ev.src_start,
                   file_line   = lookup_line(line_map, file_offset),
                   qname       = derive_qname(parent_qname, ev))
```

### 3.1.2 cmd_anchor tiebreaker (innermost-wins)

`lookup_src_range(src_offset, src_ranges)` returns the cmd_idx whose
`(src_start, src_end)` range is the **smallest range containing**
`src_offset`. Implementation: binary search on src_start to locate
candidate ranges, filter by `src_start <= src_offset <= src_end`,
return the candidate with the smallest `(src_end - src_start)`. If
multiple candidates share an identical range, return the one with the
**largest cmd_idx** (innermost in pc-emission order).

Empirical example (verified):
```
src: puts [lindex [split $s ","] 0]   # 31 chars
ranges: cmd 1 (0-29), cmd 2 (6-28), cmd 3 (14-25)
slot[0].src_offset = 14 (split's push is at src offset 14)
candidates: {1, 2, 3} all contain 14
smallest range: cmd 3 (range 11), then cmd 2 (22), then cmd 1 (29)
anchor: cmd 3 ✓
```

### 3.1.3 lookup_src_range miss policy

If no src range contains the provided offset (orphan pc, or
synthetic compiler-introduced literal with no source position), the
walker emits:

```tcl
{kind unrecognized cmd -1 src_start -1 src_end -1
 reason "orphan_pc" terminal_op OP terminal_arg OPERAND
 body_preview ""}
```

The bridge driver logs orphan_pc events at `logger.warning` level
(per the project's silent-exception rule from CLAUDE.md "Maintenance
Practices") and continues. Worker 2 ignores them in recursion
handlers; Worker 3 ignores them in symbol/edge accumulation.

### 3.1.4 Boundary recovery (stack_underflow + unknown_opcode)

Strategy A has TWO scenarios where the walker can't safely process
subsequent ops in the current command and must recover at the next
`startCommand` boundary:

**Scenario 1: stack_underflow.** The "every invoke pops N" model
means underflow is possible when the disassembler produces an
`invokeStk N` whose preceding pushes are below the top of stack
(e.g., interpreter-state opcodes that affect stack size in ways the
walker's stack-effect table doesn't model). On underflow, walker
emits an `unrecognized` event with `reason="stack_underflow"`.

**Scenario 2: unknown_opcode.** Walker hits an opcode not in the
§3.2 STACK_EFFECTS table (codebase uses opcodes the walker hasn't
hand-classified, e.g., `strneq` from tcllib `clay.tcl`). Without
canonical pop/push counts, the walker can't safely mutate the stack
— silently leaving the stack untouched would cascade-corrupt every
subsequent invoke in the command. Walker emits an `unrecognized`
event with `reason="unknown_opcode"`.

**Both scenarios share the same recovery path**: emit one
`unrecognized` event for visibility, **reset stack to `[]`**, and
**suppress further stack mutations until the next `startCommand`
boundary**. The boundary reset is the bytecode's natural per-command
recovery point; downstream commands process normally.

```tcl
{kind unrecognized cmd src_offset->cmd src_start ... src_end ...
 reason "stack_underflow" | "unknown_opcode"
 terminal_op OP terminal_arg OPERAND body_preview ""}
```

This recovery is identical to the existing dead-code suppression
that fires after unconditional `jump1`/`jump4` — Worker 1's
`in_dead_code` flag is reused for both triggers (jumps and
unknown_opcode/stack_underflow), since the recovery semantics are
the same: "skip stack mutations until next cmd boundary, then resume
on a clean stack". One `unrecognized` per actual gap; no cascade.

Empirically validated: `tclsh validation/probes/p1_2_corpus_recognition_probe.tcl
--root /usr/share/tcltk` reports clean per-opcode unrecognized counts
across 14,215 events from 788 Tcl-stdlib files. Without boundary
recovery, the same input would produce hundreds of cascade-noise
events.

### 3.1.5 disasm_error flow

If `parsed` carries `error` (parser detected disassembly failure),
`walk` returns immediately with `[{kind disasm_error reason STRING}]`
and emits no other events. The bridge driver checks for this kind
explicitly and falls back to the parser's error message in its
output (no symbols emitted from a failed disassembly).

### 3.1.6 EXPAND_MARKER lifetime

In §3.1's pseudocode, EXPAND_START pushes an EXPAND_MARKER slot;
EXPAND_STK_TOP **replaces top with EXPR(expanded_args) — pop_count=1,
push_count=1** — and **the marker stays on the stack as a sentinel**.
The marker is consumed by `invokeExpanded`, whose `pop_count=*` (in
§3.2) means "pop everything above and including the most-recent
EXPAND_MARKER".

Empirical receipt (`puts {*}$xs`):
```
expandStart           # stack: [..., MARKER]
push1 "puts"          # stack: [..., MARKER, "puts"]
push1 "xs"; loadStk   # stack: [..., MARKER, "puts", VAR(xs)]
expandStkTop 2        # stack: [..., MARKER, "puts", EXPR(expanded_args)]
                      # marker NOT popped; operand "2" is informational
invokeExpanded        # pop until marker: EXPR, "puts", MARKER
                      # source-order slots = ["puts", EXPR(expanded_args)]
                      # → dispatch: expand_args, name=slot[0].value="puts"
```

The expandStkTop's operand (the "2" above) is the index Tcl uses for
internal tracking; it is **not** a stack pop count and is informational
only from the walker's perspective.

Cross-ref: §3.2's `invokeExpanded * 1 INVOKE_EXPANDED none` row pairs
with this — the `*` pop_count is implemented as "pop until marker is
encountered (and consume the marker)".

### 3.2 Stack-effect table (62 rows shipped; canonical source: opcode_walker.tcl)

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

**Operand form notes** (Worker 1 implements parsing):
- `int` / `int1` / `int4`: single integer operand.
- `string`: string operand (used by pushString).
- `two-int`: space-separated `"N M"` pair. **For invokeReplace**:
  `pop_count` is N (use `[lindex [split $operand " "] 0]`); M is the
  source-form word-count collapse used by namespace_eval dispatch.
- `none`: no operand.
- `N` in pop_count: read from operand per `operand_form`.
- `*` in pop_count: dynamic count (invokeExpanded's pops are bounded
  by the EXPAND_MARKER on stack — pop until marker is hit).
- `2` in pop_count for expandStkTop: pops the list slot and the
  marker (see §3.1.6).

**Adding a new opcode = one row.** Worker 1 shipped a 62-row table
covering the bluice-empirical surface (47 opcodes observed across
12,256 corpus events) plus ~15 safety-margin entries (`list`,
`lappendListStk`, `storeArrayStk`/`loadArrayStk`, comparison ops
`lt`/`gt`/`le`/`ge`/`eq`/`neq`, `existStk`/`existArrayStk`, `exprStk`,
`reverse`, `endCatch`/`pushResult`/`beginCatch4`/`pushReturnCode`/
`returnImm`, `jumpTrue4`/`jumpFalse4`/`jumpTable`, `clockRead`,
`resolveCmd`, `unsetStk`, `dup`, `strcaseLower`). Cross-codebase use
on `/usr/share/tcltk` (Tcl stdlib + tcllib + iTk + BWidget, 14,215
events from 788 files) surfaces 12 additional unhandled opcodes
(`strneq`, `arrayExistsStk`, `add`/`sub`/`mult`/`div`/`lshift`,
`over`, `strindex`, `listNotIn`, `verifyDict`, `evalStk`,
`invokeReplace`-other) — see P1.3 task #15 for the empirical
expansion plan.

**Source of truth: `src/jcodemunch_mcp/parser/opcode_walker.tcl`
`STACK_EFFECTS` dict** (the sketch above is illustrative — the
shipped table is the ground truth). Later Tcl versions extend the
table additively. Opcodes encountered during walk that lack a table
row trigger the §3.1.4 unknown_opcode boundary recovery (one
`unrecognized` event + reset stack + suppress until next
startCommand) — empirically validated to prevent cascade failures.

**SPECIALIZED_OP coverage**: the §2.5 GONE list (string length /
compare / match / range / equal; dict get; incr; storeStk; listIndexImm)
is captured. P1.1 fixtures 16-18 cover these silently — they should
still produce zero events under Strategy A. New SPECIALIZED_OP rows
extend the table additively.

### 3.3 Dispatch table (14 rows; +var_command per §13.5; +computed_namespace per §13.6)

Order and 11 of 12 P1.1 predicates preserved verbatim. The
eval_brackets row gains an explicit dispatch predicate (P1.1's
`_sub_table_b_heuristic` is **deleted**; its work folds into
Strategy A's stack model). Two rows added per resolved §13
decisions: `var_command` (priority 10.5) and `computed_namespace`
(priority 12.5):

```
DISPATCH (priority order, most-specific first):
    namespace_eval     match: op==invokeReplace AND last slot LITERAL "::tcl::namespace::eval"
    expand_args        match: op==invokeExpanded
    callback           match: op==invokeStk{1,4} AND last slot EXPR strcat-with-method
    apply_lambda       match: op==invokeStk{1,4} AND slot 0 LITERAL "apply" AND slot 1 LITERAL list-shaped
    ensemble           match: op==invokeStk{1,4} AND slot 0 LITERAL "::tcl::ENSEMBLE::SUB"
    eval_var           match: op==invokeStk{1,4} AND slot 0 LITERAL "eval" AND slot 1 VAR
    eval_brackets      match: op==invokeStk{1,4} AND slot 0 LITERAL "eval" AND slot 1 EXPR invoke_result
    uplevel_var        match: op==invokeStk{1,4} AND slot 0 LITERAL "uplevel" AND last slot VAR
    interp_eval        match: op==invokeStk{1,4} AND slot 0 LITERAL "interp" AND slot 1 LITERAL "eval"
    var_method         match: op==invokeStk{1,4} AND slot 0 VAR AND slot 1 VAR
    var_command        match: op==invokeStk{1,4} AND slot 0 VAR AND N==1   # §13.5
    pattern_b          match: op==invokeStk{1,4} AND slot 0 VAR AND slot 1 LITERAL
    pattern_a2         match: op==invokeStk{1,4} AND slot 0 LITERAL "::ns" (single-segment FQN) AND slot 1 LITERAL
    computed_namespace match: op==invokeReplace AND last slot != LITERAL "::tcl::namespace::eval"   # §13.6
    pattern_a          match: op==invokeStk{1,4} AND slot 0 LITERAL (fallback)
```

The `_sub_table_b_heuristic` proc at P1.1 walker.tcl:496-511 is
**deleted** under Strategy A — bracket inlining is now handled
correctly by the flat-pc walk + innermost-wins anchor + the explicit
eval_brackets dispatch row above.

**§13.5 var_command row** (resolved DECIDED=A): captures `$var`
no-args dispatch at bytecode level. Predicate fires only when
`N==1` so `$var arg` (N≥2) still classifies as pattern_b — the
N≥2 indistinguishability is the Strategy A precision floor and is
intentional. Avoids spurious `unrecognized` for the `$var` no-args
case that v1 SPEC §4.3 + v1 TestUnresolvedDispatch lock as a
distinct category.

**§13.6 computed_namespace row** (resolved DECIDED=C, supersedes §5
decision 6): when `invokeReplace` fires with the resolved literal
slot being VAR (computed namespace), emit a distinct
`computed_namespace` event. Counts as recognized, so the §8
"0 unrecognized" gate is preserved. Mirrors the eval_var /
uplevel_var / interp_eval pattern of explicit-tag-instead-of-
silently-classify for runtime-resolved dispatch.

---

## 4. What Workers 2 and 3 see

### 4.1 Worker 2 (recursion tables, body-base, unresolved detector)

- Consumes the event stream from `::jcm::disasm::walker::walk`.
- For sub-table A (literal-recursion bodies): match on
  `kind == namespace_eval` (ns + body fields), `kind == apply_lambda`
  (lambda field), or — for proc/method/itcl::class/class/etc. —
  match on `kind == pattern_a` with `name` in DEFINITION_TABLE and
  invoke `compute_body_base` on the cmd's src_range to recover the
  body src_offset. **Distinguishing inlined-inner events from outer
  events**: under Strategy A, sub-table B inner commands appear as
  events with `src_start` falling INSIDE the outer command's
  `src_start..src_end` range. Worker 2 uses this containment check
  to decide "is this event inside the body I just recursed into?" vs
  "is this event the outer parent?".
- For sub-table B (outer-bytecode-inlined bodies): no recursion
  needed; events for inner commands appear inline in flat-pc order.
  **Strategy A closes the 2 unrecognized cases here without Worker 2
  changes** (the empirical 12,010 → 12,010 recognition gain).
- For sub-table C (mixed): try/switch/dict-for/dict-with/dict-update
  bodies inlined like B. `inherit` and `package require` are matched
  on `kind == pattern_a` with name in {inherit, package} and emit
  schema field entries (parent_classes, package_requires). **TclOO
  `superclass`** (per Δ0.2 carried-forward items) is matched on
  `kind == pattern_a` with name == "superclass" and folds into the
  same `parent_classes` field as `inherit`.
- For unresolved-dispatch tagging: 5 walker event kinds
  (`eval_var`, `var_method`, `uplevel_var`, `interp_eval`,
  `eval_brackets`) map directly to schema entries; tag conventions
  per PLAN_v2.1 §4.

### 4.2 Worker 3 (bridge driver, schema, test port, pragma scanner)

- Driver loop: read source, call parser, call walker, dispatch each
  event through Worker 2's recursion-table handlers, accumulate
  symbols + call edges, emit JSON.
- **Recursive walker calls**: bridge driver carries
  `parent_src_offset INT` and `parent_file PATH` through every
  recursion (per §3.1.1). Walker events do NOT carry these.
- **Schema additions** (per `PLAN_v2_2_PATCH §Δ0.2`):
  - `parent_classes: list[{name STRING, line INT}]` on class symbols.
    Always present, always list, empty → `[]`.
  - `package_requires: list[{name STRING, version STRING|null}]` on
    file's `__script__` symbol. Always present, always list,
    empty → `[]`. `version` is `null` when source omits it.
  - Both fields populated by Worker 2's REC-C handlers for `inherit`
    / `superclass` / `package require`.
  - `package require` ALSO emits the existing `kind=import` symbol —
    both sources populated from the same parse.
- **INDEX_VERSION 9 → 10** in `sqlite_store.py`. CHANGELOG entry
  (see §10) calls out the re-index requirement.
- **Test port**: 83 tests + 4 new schema-field tests. extractor.py
  TCL branch points to `tcl_disasm_bridge.tcl`. The old bridge file
  (`tcl_parser_bridge.tcl`) lives only on `tcl-native-parser` branch
  — fetch via `git show tcl-native-parser:src/...`.

### 4.3 Pragma scanner integration (R31)

The pragma scanner is a **pre-pass over file source**, run BEFORE
the walker, producing:

```tcl
pragmas: list[{kind STRING, line INT, target_line INT}]
```

where `kind` is one of `dynamic`, `export`, `ignore`, `line` is the
pragma comment's line number, and `target_line` is the next non-blank
non-comment line (the statement the pragma applies to).

**Wiring onto walker events**: Worker 3 attaches pragmas to
**symbols, not events**. The matching rule: a pragma at line P with
`target_line = T` attaches to the symbol whose
`declaration_line == T`. The pragma then applies to ALL events
inside that symbol's body (events whose `src_start` falls within the
symbol's `byte_offset .. byte_offset + byte_length` range). This
correctly handles multi-line proc bodies (the common case in
bluice): a `# JCM:dynamic` over a `proc foo {a b} {\n ... \n}`
spanning 20 lines attaches to the proc symbol, and every dynamic
dispatch inside the body inherits the tag. Single-line constructs
(e.g., `# JCM:ignore` over a `package require` line) work the same
way: the package-require's symbol declaration is at `target_line`,
so the pragma attaches to that symbol. When no symbol's
`declaration_line == target_line` (orphan pragma above whitespace
or a non-symbol-defining statement), the pragma is logged at
`logger.warning` and dropped.

For each matched pragma the bridge driver emits an entry into the
attached symbol's `unresolved_dispatches` field with:

```tcl
{kind pragma_dynamic resolves_to "foo" line N}    # # JCM:dynamic
{kind pragma_export                  line N}     # # JCM:export
{kind pragma_ignore                  line N}     # # JCM:ignore
```

**Phase 1 semantics** (per PLAN_v2_2_PATCH §Δ0.2 carried-forward
items): `# JCM:ignore` over a `package require` does NOT suppress
the existing `kind=import` symbol — it adds a `pragma_ignore` entry
to `unresolved_dispatches` for visibility. Suppression is Phase 2.

**Dynamic-body regex pre-scan** (5-10 LoC): Worker 3's pragma scanner
also runs `\bproc\s+\S+\s+\S+\s+\[` over the file source. Any match
cross-validates against the walker's `unresolved_dispatches:
dynamic_body` tagging. **Disagreement is a bridge bug**: the scanner
sees a dynamic-body proc the walker missed, OR the walker tagged a
dynamic-body the scanner missed. Both cases log at `logger.warning`
level with file:line for triage.

---

## 5. Open implementation decisions (Worker 1 surfaces to user)

Decisions stay with the user per P1.2 kickoff. Worker 1 surfaces
these as they come up; does NOT guess:

1. **Per-opcode stack-effect rule for opcodes not yet seen in bluice
   corpus.** When walking a future Tcl version's bytecode (or a
   non-bluice codebase), opcodes not in the §3.2 table need rules.
   P1.2 lands the bluice-sufficient set; future opcodes are one-row
   additions.
2. **Strcat-method-recovery behavior across nested brackets.** P1.1
   captures method when n=2 and top-of-stack is LITERAL. v2.2 needs
   to confirm this still works when the top slot is an EXPR
   invoke_result (e.g., `after 100 "$obj method [getArg]"`). Add a
   fixture during P1.2; verify, don't pre-design (Q2 in kickoff).
3. **Slot.src_offset when STRCAT collapses N>1 slots.** §3.1
   pseudocode uses the bottom slot's src_offset (smallest offset) so
   cmd_anchor lookup picks the parent command. This is the natural
   choice; flag if counterexamples surface.
4. **expandStkTop dynamic slot count.** Operand may be 0 for
   runtime-length lists; in that case the EXPAND_MARKER's src_offset
   anchors the resulting EXPR slot. Verify with `foo {*}$xs`
   fixture.
5. **lookup_src_range miss policy across non-orphan opcodes.** §3.1.3
   defines orphan_pc handling for invokes. For PUSH/LOAD opcodes,
   src_offset miss is silenced: the slot's src_offset becomes -1
   (sentinel), and the next invoke that consumes this slot at slot[0]
   triggers an orphan_pc unrecognized event. Confirm this is
   sufficient or if intermediate logging is needed.
6. **invokeReplace with non-literal namespace slot.** When
   `namespace eval $ns body` resolves the namespace at runtime,
   the last slot is VAR (not LITERAL). Walker falls through to
   pattern_a name="(computed-ns)". Confirm this is correct vs.
   tagging as an `unrecognized` with `reason="computed_namespace"`
   for visibility.

---

## 6. Re-baseline expectations

The walker rewrite changes both the cmd field semantic AND the
emission order for fixtures that exercise bracket inlining. Worker 1
splits the 18 P1.1 fixtures into two sets:

**Re-baseline by capture (5 P1.1 + 4 new = 9 fixtures)**:

| Fixture | What changes |
|---|---|
| `11_eval_var.test` | Add src_start/src_end fields per event |
| `13_uplevel_var.test` | Add src_start/src_end fields per event |
| `14_interp_eval.test` | Add src_start/src_end fields per event |
| `15_eval_brackets.test` | **cmd value AND emission order** (eval_brackets cmd anchored to outer cmd via innermost-wins; gc's pattern_a fires BEFORE eval's eval_brackets in flat-pc order) |
| `05_expand_args.test` | Add src_start/src_end + possibly emission order if bracket sub present |
| `19_bracket_inline_if.test` (new) | Locks `if [catch ...] {body}` Strategy A correctness |
| `20_bracket_inline_specialized.test` (new) | Locks `set x [lindex $argv 0]` correctness |
| `21_nested_brackets.test` (new) | Locks 3-level innermost-wins anchor |
| `22_interior_invoke.test` (new) | Locks `foo [bar baz] qux` (Q5 case) |

Worker 1 captures with `run.tcl --capture <fixture>` for each, then
visually verifies the diff is ONLY (a) added src_start/src_end, (b)
cmd-value shifts for inlined cases, (c) emission-order shifts for
bracket-inlined cases. Any other diff (kind change for non-bracketed
events; field deletion; unexpected new fields) is a bug.

**Must-not-change (10 fixtures)**:

`01_pattern_a.test`, `02_pattern_a2.test`, `03_pattern_b.test`,
`04_callback.test`, `06_apply_lambda.test`, `07_namespace_eval.test`,
`08_ensemble_chan.test`, `09_ensemble_string.test`,
`10_ensemble_misc.test`, `12_var_method.test`,
`16_specialized_opcodes_silent.test`,
`17_specialized_ensemble_subcommands.test`,
`18_literal_eval_uplevel_resolvable.test`.

These exercise non-bracketed shapes; their event streams should be
**identical** under v2.2 modulo the additive src_start/src_end fields.
Worker 1 runs `run.tcl` (not `--capture`) on these and they MUST PASS
without re-baselining beyond the additive field. If any of these
fixtures fail, that's a Strategy A regression.

The 4 new fixtures (19-22) lock the Strategy A correctness gain that
the 2/12,010 unrecognized cases dissolve into specific events.

---

## 7. Quality criteria (§6.1.10 carryover)

- Walker file stays one file: `src/jcodemunch_mcp/parser/opcode_walker.tcl`.
- Stack-effect table and dispatch table are both declarative tcl
  lists — adding an opcode/pattern is one row.
- Comments document non-obvious Tcl compiler behavior (the
  invoke/InvokeReplace/expandStkTop semantics; why src_offset anchors
  to slot[0] not the invoke insn; why innermost-wins is the right
  tiebreaker).
- Identifier names use snake_case helpers:
  `_simulate_stack`, `_lookup_src_range`, `_pc_to_src_offset`,
  `_apply_stack_effect`, `_dispatch_match`, `_emit_*` per kind.
- **LoC realism note**: P1.1 walker is 569 LoC. Strategy A adds
  `_simulate_stack` + 30-row `STACK_EFFECTS` + `_lookup_src_range`
  binary search + `_pc_to_src_offset` + `_apply_stack_effect` +
  miss/underflow handlers. Realistic delta is +85-130 LoC, may
  reach +150 with comments. The hard cap is removed per
  PATCH §3 P1.2; +85 was an underestimate but still inside
  the 900-1200 soft target for the bridge as a whole.

---

## 8. Reproducer (post-rewrite gate)

Worker 1's exit gate before handing off T2:

```bash
cd /home/giles/git/jcodemunch-mcp-fork

# Existing P1.1 regression guards (unchanged baselines)
tclsh validation/probes/body_base_probe.tcl --bluice
    # expect: 382/382 + 5/5 synthetic, exit 0
python3 validation/golden_set/validate_golden.py
    # expect: 92/95 + 3 requires_v2_1, exit 0
tclsh validation/probes/ensemble_enumeration_probe.tcl
    # expect: 10 ensembles, exit 0

# 22-fixture suite (18 carry-forward + 4 new)
tclsh validation/fixtures/disasm/run.tcl
    # expect: 22/22 PASS, exit 0
    # NOTE: requires Worker 1 to re-baseline 11/13/14/15/05 + add 19-22

# NEW corpus recognition probe (P1.2 deliverable, ships with walker)
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl
    # expect: 0 unrecognized events across 12,010 corpus events, exit 0
    # on failure: prints first 10 unrecognized events with file:line for triage
```

**Recognition-gate strictness clarification**: under Strategy A, the
`kind=unrecognized` event is emitted in FOUR cases:
1. Dispatch table fall-through (no row matches the slot pattern) — the
   only case in P1.1.
2. orphan_pc (slot[0].src_offset has no containing src range; §3.1.3).
3. stack_underflow (invoke pops more than stack has; §3.1.4).
4. unknown_opcode (opcode lacks a §3.2 STACK_EFFECTS row).

The §8 corpus probe's "0 unrecognized" gate counts ALL FOUR cases.
This is stricter than P1.1's gate (which only counted case 1; cases
2-4 didn't exist as event types). Strategy A's "12,010/12,010 by
construction" claim therefore depends on §3.2's table covering every
opcode bluice produces (mitigated by fixture-driven discovery during
P1.2 build) AND innermost-wins anchor producing valid src ranges for
every push (verified empirically in §3.1.2).

The corpus recognition probe is a P1.2 deliverable shipped alongside
the walker rewrite. Spec:

```
File: validation/probes/p1_2_corpus_recognition_probe.tcl
Args: --bluice-root PATH (default /home/giles/bluice)
      --no-synthetic (skip synthetic forcing fixture)
Behavior:
  1. Walk every .tcl in BLUICE_ROOT scope
     (BluIceWidgets, DcsWidgets, dcs-lib-tcl/main/scripts, dhs-tcl,
     dcss/scripts/**) — same scope as ensemble_enumeration_probe.
  2. Parse each file via parser::disassemble_and_parse.
  3. Walk via walker::walk.
  4. Count events of kind=="unrecognized".
  5. Track first 10 unrecognized for triage output.
Exit code:
  0 iff total unrecognized count == 0.
  1 if any unrecognized events found.
On failure stdout:
  "FAIL: N unrecognized events across M corpus events"
  Per-event: "  FILE:LINE  reason=R terminal_op=OP terminal_arg=ARG"
```

When all five gates pass, Worker 1 marks task #2 (P1.2(e)) complete
and Worker 2/3 can drop any remaining stub-against-contract code in
favor of the real walker output.

---

## 9. Integration test plan (Worker 2/3 consume Worker 1)

A separate gate, run after Worker 1's exit gate AND Worker 2/3
complete their bundles, before the P1.2 §6.1.10 reviewer pass:

```bash
# Bridge end-to-end on a representative bluice file
tclsh src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl \
    /home/giles/bluice/BluIceWidgets/Anneal.tcl > /tmp/bridge_out.json
# Validate JSON shape
jq . /tmp/bridge_out.json | head -100
# Validate parent_classes field present and a list
jq '.symbols[] | select(.kind=="class") | .parent_classes | type' \
    /tmp/bridge_out.json
    # expect: every class symbol prints "array"
# Validate package_requires field present on __script__
jq '.symbols[] | select(.name=="__script__") | .package_requires | type' \
    /tmp/bridge_out.json
    # expect: "array"

# 83-test port
cd /home/giles/git/jcodemunch-mcp-fork
uv run --no-project --with pytest --with-editable . pytest \
    tests/test_tcl_parser.py -q 2>&1 | tail -20
    # expect: 83 passed (or 83 - retired_count + retire_rationale_doc)

# 4 new schema-field tests
uv run --no-project --with pytest --with-editable . pytest \
    tests/test_tcl_parser.py -q -k "parent_classes or package_requires" \
    2>&1 | tail -10
    # expect: 4 passed
```

Failure of any of these blocks the §6.1.10 reviewer pass.

---

## 10. CHANGELOG draft (Worker 3 finalizes)

Skeleton for the v1.84.0 (or v2.0.0 depending on release-cut policy)
CHANGELOG.md entry. Worker 3 fills in the gaps after schema work
lands:

```markdown
## [Unreleased] — TCL bridge rewrite (P1.2)

### Schema additions (INDEX_VERSION 9 → 10)
- **`parent_classes: list[{name, line}]`** on class symbols. Captures
  iTcl `inherit` and TclOO `superclass` declarations with their
  source-line numbers. Always present, always a list, empty → `[]`.
  Powers `get_class_hierarchy` runtime-free queries.
- **`package_requires: list[{name, version|null}]`** on file's
  `__script__` symbol. Captures `package require NAME ?VERSION?`
  declarations. Always present, always a list. `version` is `null`
  when source omits it. Powers version-aware
  `get_dependency_graph` queries.
- `package require` ALSO emits the existing `kind=import` symbol —
  both sources populated from the same parse for backward
  compatibility with `find_importers`.

### **Reindex required**
INDEX_VERSION bumps 9 → 10. All TCL repos must re-index on upgrade
to populate the new fields. The storage layer rejects v9 indexes
with a clear "reindex required" error.

### TCL bridge internals (no user-visible behavior change)
- Walker rewritten per Strategy A (flat pc stream, anchor by src
  range, every-invoke-pops-N-pushes-1). Closes the 2/12,010 corpus
  events that P1.1 left as `unrecognized`.
- 18-fixture suite grew to 22 fixtures locking bracket-inlining
  Strategy A correctness.
- 83 tests ported from `test_tcl_parser.py @ tcl-native-parser`
  + 4 new schema-field tests (87 total).
```

---

## 11. Cross-reference: addressed critic findings

This rev2 contract addresses the omc:critic REVISE pass:

| Finding | Section addressed |
|---|---|
| C1 (src offset semantic) | §2 (bytes; relative-to-source) + §3.1.1 (parent-offset composition) |
| C2 (cmd_anchor tiebreaker) | §3.1.2 (innermost-wins, smallest containing range) |
| C3 (cmd-shift + emission-order) | §6 (re-baseline-by-capture vs must-not-change split) |
| M1 (invokeReplace operand split) | §3.2 operand_form column + two-int note |
| M2 (pragma scanner integration) | §4.3 (pre-pass; target_line matching; JCM:ignore semantics) |
| M3 (parent-offset is caller responsibility) | §3.1.1 + §4.2 (carrier vs event field) |
| M4 (corpus-recognition gate stub) | §8 (named probe, exit code, fail output spec) |
| M5 (deferred decisions 5+6) | §5 decisions 5 (lookup_src_range miss) and 6 (computed namespace) |
| Missing: stack-underflow | §3.1.4 |
| Missing: CHANGELOG draft | §10 |
| Missing: disasm_error flow | §1 + §3.1.5 |
| Missing: _sub_table_b_heuristic | §3.3 (deleted under Strategy A) |
| Missing: EXPAND_MARKER pop | §3.1.6 |
| Missing: integration test plan | §9 |
| m1 (semantic shift framing) | §2 stability note |
| m2 (LoC delta realism) | §7 LoC realism note |
| m3 (inlined-inner/outer distinguishability) | §4.1 sentence |
| Open: TclOO superclass | §4.1 REC-C list update |
| Open: corpus root path | §8 (default `/home/giles/bluice`) |
| C1 critic char-vs-byte error | §2 corrected to bytes (verified empirically against tclsh 8.6.14 with UTF-8 input) |
| NG-1 (rev2 critic) pragma multi-line | §4.3 declaration-line attachment rule (pragma attaches to symbol, not event) |
| NG-2 (rev2 critic) stack reset aggressiveness | §3.1.4 changed to "drop slots until next startCommand" |
| NG-3 (rev2 critic) EXPAND_MARKER prose | §3.1.6 stack-direction-neutral wording + cross-ref to §3.2 pop_count |
| NG-4 (rev3 Worker 1 empirical) expandStkTop pop_count was 2; should be 1 (marker stays) | §3.1 pseudocode + §3.1.6 prose + §3.2 table corrected; empirical receipt for `puts {*}$xs` documented |
| §13.2 / §13.3 (rev4 user-decided=B) host-only fields | `parent_classes` only on class symbols; `package_requires` only on `__script__`. Δ0.2 C3 always-present rule applies WITHIN host type; non-host symbols don't carry the field. |
| §13.5 (rev4 user-decided=A) `var_command` distinct row | §3.3 row added at priority 10.5 (slot 0 VAR AND N==1); §2 event payload schema gains `var_command` row. v1 SPEC §4.3 + v1 TestUnresolvedDispatch preserved. |
| §13.6 (rev4 user-decided=C) `computed_namespace` distinct event kind | §3.3 row added at priority 12.5 (invokeReplace + last slot != LITERAL); §2 schema gains `computed_namespace` row. Replaces §5 decision-6 fallthrough-to-pattern_a default; counts as recognized so §8 gate stays clean. |
| §13.7 (rev4 user-decided=A) `superclass` per-occurrence attribution | `parent_classes` carries one `{name, line}` per source-form occurrence; multi-site TclOO `superclass` declarations preserve every site's line. iTcl `inherit Base1 Base2` already produces one entry per Base. |
| Worker 2 `__file_offset__` tag (rev4 user-decided=keep) | Recursion-table handlers return `{__file_offset__ N}` tagged tuples; Worker 3b bridge driver resolves via line_map post-pass (one O(n) walk after dispatch). Module boundary preserved: handlers stay pure, line_map ownership stays with bridge driver. |
| NG-5 (rev5 cross-codebase) unknown_opcode cascade prevention | §3.1.4 extended: unknown_opcode now triggers same boundary recovery as stack_underflow + dead-code (reset stack + suppress until next startCommand). Empirically verified on /usr/share/tcltk: 40 clean per-opcode unrecognized events across 14,215 walker events; no cascade noise. |
| NG-6 (rev5 cross-codebase) corpus probe generalized for non-bluice codebases | `--root PATH` flag (no scope filter; recursive .tcl/.itcl walk) added to `validation/probes/p1_2_corpus_recognition_probe.tcl`; `--bluice-root` retained as back-compat alias for the existing scope filter. Per-opcode breakdown sorted by frequency (with file count + first-sample) replaces the bare first-10 triage list. Tells maintainers exactly which STACK_EFFECTS rows to add to support a new codebase. |
| Open: corpus gate strictness for orphan_pc / stack_underflow / unknown_opcode | §8 recognition-gate strictness clarification (counts all 4 cases) |
