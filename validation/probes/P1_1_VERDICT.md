# P1.1 closing verdict — disasm parser + opcode walker + 18 fixtures

**Date**: 2026-05-08
**Branch**: `tcl-disasm-bridge` (continuing from P1.0 at `0dfb035`)
**Plan**: `PLAN_v2.1.md §3 P1.1` (3-4 days budgeted)
**Predecessor**: `BODY_BASE_VERDICT.md` (P1.0 walker viability gate)

---

## Verdict: **P1.1 ALL DELIVERABLES MET. READY FOR P1.2.**

The walker spike is working end-to-end: parser → walker → fixtures.
The §2.3 dispatch table (13 rows) plus the §2.3 ensemble pre-rename
table (10 rows after R32 corpus probe) are empirically grounded
against tclsh 8.6.14 and the full bluice corpus. P1.0 regression
guards (body-base probe + golden set) remain green.

## Per-deliverable status

### (a) `tcl_disasm_parser.tcl` — **WORKING.**

- Location: `src/jcodemunch_mcp/parser/tcl_disasm_parser.tcl`
- LoC: 306 (within plan's spike scope)
- Pure function: takes Tcl source, returns canonical dict with
  `{stats, source_preview, commands, literals}`. No I/O, no semantic
  interpretation.
- Reuses regex pattern from `validation/verify.tcl:88-115` (per
  user direction) and the "Commands N:" header packing pattern from
  `body_base_probe.tcl:disasm_command_ranges`. Per §0.2 rule 4: this
  is helper-pattern re-derivation, not copy-paste of the retired
  `tcl_parser_bridge.tcl`.
- Two parse phases:
  - Phase 1: header + stats + command table (`Cmds N`, `Commands N:`)
  - Phase 2: per-command instruction streams (`Command K:` body lines)
- Literal index reconstructed from push-instruction comments
  (Tcl emits truncated literals inline as `# "..."`; no separate
  literals table is dumped).
- CLI entrypoint: `tclsh tcl_disasm_parser.tcl FILE.tcl` for
  inspection.

### (b) `opcode_walker.tcl` — **WORKING. 13/13 §2.3 rows dispatch correctly.**

- Location: `src/jcodemunch_mcp/parser/opcode_walker.tcl`
- LoC: 569 (declarative dispatch + helpers)
- One §2.3 row = one `_match_*` predicate + one `_emit_*` emitter.
  Adding a new pattern is a one-row change in `_dispatch_table`.
- Terminal-invoke detection covers `invokeStk1`, `invokeStk4`,
  `invokeReplace`, `invokeExpanded`. Walk-back over preceding
  data-producing ops (push1/push4/loadStk/strcat/expandStart/
  expandStkTop) reconstructs the source-form slot order with
  LITERAL/VAR/EXPR kind tags.
- 13 dispatch rows priority-ordered (most specific first):
  `namespace_eval`, `expand_args`, `callback`, `apply_lambda`,
  `ensemble`, `eval_var`, `uplevel_var`, `interp_eval`, `var_method`,
  `pattern_b`, `pattern_a2`, `pattern_a`. Plus `eval_brackets` via
  the sub-table B heuristic for the inlining edge case.
- Ensemble pre-rename table: 10 entries (post P1.1f).
- Empirical receipts captured during P1.1 probe session for each
  pattern; receipts referenced inline in the source comments.

### (c) Fixture suite — **18/18 PASS, ~30 events covered.**

- Location: `validation/fixtures/disasm/`
- 18 `.test` files (one per dispatch concern) + driver `run.tcl`.
- Driver: `tclsh validation/fixtures/disasm/run.tcl` (or
  `--capture` to seed expecteds, or single-file argument for one).
- Coverage:
  - Rows 1-15: positive coverage for each §2.3 pattern + sub-table B
    heuristic.
  - Rows 16-18: negative coverage. 16 verifies `set`/`incr`/`if`/
    `return` are silenced via specialized opcodes (the §2.5 GONE
    list). 17 verifies `string length`/`compare`/`match`/`range`
    and `dict get` are silenced via `strlen`/`strcmp`/`strmatch`/
    `strrangeImm`/`dictGet` opcodes. 18 verifies `eval LITERAL`
    and `uplevel 1 LITERAL` resolve to `pattern_a` (NOT to
    `eval_var`/`uplevel_var`).
- Edge case explicitly deferred to P1.2: `puts {*}[list a b]`
  (constant-folded list inlined into expand-args). The walker's
  per-command analysis cannot recover this cleanly because Tcl 8.6
  splits the resulting bytecode across "Command N:" headers in a
  way that loses the `puts` slot. Documented in fixture
  `05_expand_args.test`.

### (d) Tcl 8.6.x patch-version probe — **8.6.14 verified floor.**

- Document: `validation/probes/TCL_VERSION_VERDICT.md` § (d)
- Per user direction: aggressive reachability hunting (apt holds,
  docker pulls, source builds) was out of scope. Host has only
  `tcl8.6.14+dfsg-1build1` installed. P1.1 spike (parser, walker,
  18 fixtures, ensemble probe over 823 files, body-base 382/382)
  all confirmed against 8.6.14.

### (e) Tcl 9.0 probe — **UNREACHABLE; cost recorded as UNVERIFIED follow-on of unknown size.**

- Document: `validation/probes/TCL_VERSION_VERDICT.md` § (e)
- Per R26 + R34: 9.0 is desirable but out of Phase 1 scope. The
  doc enumerates five concrete risks (entrypoint rename, output
  format drift, opcode renames, ensemble table drift, stable-API
  guarantees) so the next 9.0-reachable session has a tight
  re-verification list. Cost is **NOT** "small."

### (f) Ensemble enumeration (R32) — **ONE NEW ROW: `string`.**

- Document: `validation/probes/ENSEMBLE_VERDICT.md`
- Probe: `validation/probes/ensemble_enumeration_probe.tcl`
- 823 files probed (BluIceWidgets + DcsWidgets + dcs-lib-tcl/main/
  scripts + dhs-tcl + dcss/scripts/**) + synthetic forcing fixture.
- Result: 10 ensembles, 66 distinct subcommands (18 corpus-natural,
  48 synthetic-forced). The 9 reference ensembles close cleanly;
  `string` is the new addition (corpus-verified via `string repeat`
  in 10+ DCS scripts).
- §2.3's "string does NOT need rename-table treatment" claim is
  **retracted** for `string repeat`-class subcommands (specialized
  opcodes still cover `length`/`compare`/`match`/`range`/etc.). See
  the verdict doc for the corrected language.

## Q1-Q4 verdicts (open questions from P1.0 commit)

| Q | Verdict |
|---|---|
| **Q1** | **CONFIRMED** — bytecode-layer classification is correct and removes the 51 LRANGE_FAIL cases the body-base probe flagged. The walker classifies via the literal pushed before `invokeStk` (or `invokeReplace`'s last push). No `lrange` over command text is needed. |
| **Q2** | **ROW ADDED** — `class NAME BODY` (custom DSL) is added to the body-base probe's DEFINITIONS table at `body_base_probe.tcl:_classify_definition`. Bluice files (Anneal.tcl, AutoSample.tcl, etc.) confirmed it. The §2.4 sub-table A in PLAN_v2.1 needs the same row alongside `itcl::class` for P1.2 rule porting. |
| **Q3** | **ANSWERED** — see `ENSEMBLE_VERDICT.md`. One new ensemble row required: `string`. Reference table grows from 9 to 10. Subcommand additions within existing ensembles (`info tclversion`, `namespace children`, `file tempfile`, `string repeat`) are absorbed by the `(ensemble *)` wildcard rules. |
| **Q4** | **ACCEPTED AS UNVERIFIED** — see `TCL_VERSION_VERDICT.md` § (e). Tcl 9.0 binary not reachable on this host; bluice's RHEL/Tcl modernization timeline drives when this gets re-probed. |

## Regression checks (P1.0 guards)

| Guard | P1.0 baseline | P1.1 result |
|---|---|---|
| `body_base_probe.tcl --bluice` | 382/382 + 5/5 synthetic | **382/382 + 5/5** ✓ |
| `validate_golden.py` | 92/95 captured + 3 requires_v2_1 | **92/95 + 3 requires_v2_1** ✓ |

No regression. The P1.1 deliverables sit alongside (do not modify)
the P1.0 infrastructure.

## P1.2 questions surfaced during P1.1

These accumulate from the spike work; carry into P1.2 kickoff.

1. **Bracket-inlining cross-pc attribution.** The walker's per-command
   analysis cannot recover `puts {*}[list a b]` cleanly because Tcl 8.6
   splits the resulting bytecode across "Command N:" headers. Two
   approaches:
   - (a) Walk the flat pc stream once and attribute opcodes to the
     command whose pc range contains the terminal invoke.
   - (b) Pre-pass merger that detects sub-table B inlining and rejoins
     bytecode chunks before the per-command walker runs.
   - Decision needed at P1.2 kickoff.

2. **Callback method recovery in nested cases.** The walker recovers
   the method literal for `bind .w <Key> "$obj method"` shape via
   strcat metadata. Edge cases like `after 100 "$obj method [getArg]"`
   (strcat with a bracket sub on top of stack) are not yet tested.
   Add to P1.2 fixture suite.

3. **`{*}` over a literal-but-multi-element list.** If a developer
   writes `foo {*}{a b c}` with a literal brace-list, Tcl 8.6
   constant-folds it into a static expanded-args sequence; the walker
   should still emit `expand_args name=foo`. Not covered in P1.1
   fixtures; verify in P1.2.

4. **`namespace ensemble create -compile 1` user-defined ensembles.**
   PLAN_v2.1 §2.3 "Scope" note: bluice/DCS define no user-level
   ensembles (verified empirically). If a future codebase defines its
   own, the rename table needs probe-driven extension. Mechanism is
   in place via `ensemble_enumeration_probe.tcl`; P1.2 documents how
   to point it at a new corpus.

5. **invokeStk inside a command (interior, not terminal).** The
   walker's `_walk_back_slots` ignores interior invokeStk*, which is
   correct for the patterns in P1.1 fixtures but wrong for the
   bracket-inlining case (#1 above). When (#1) is resolved, the
   stack-effect bookkeeping for interior invokes needs explicit
   handling: pop N, push 1.

6. **Phase-1 `unrecognized` events.** The walker emits
   `unrecognized` for any terminal-invoke shape that doesn't match
   any §2.3 row. P1.2 should run the walker on the full bluice
   corpus and audit the `unrecognized` set. Any pattern that recurs
   becomes a new dispatch row; one-off cases stay tagged.

7. **Static-inheritance and static-package-requires fields (R22).**
   Phase 1 schema additions; not yet emitted by the spike. P1.2
   recursion-table entries for `inherit Base1 Base2 ...` and
   `package require NAME ?VERSION?` produce the data; consumer
   wiring is Phase 2.

## File inventory (P1.1 delta, on top of P1.0)

```
M  uv.lock                                          (unchanged from P1.0)
?? src/jcodemunch_mcp/parser/tcl_disasm_parser.tcl  306 LoC
?? src/jcodemunch_mcp/parser/opcode_walker.tcl      569 LoC
?? validation/fixtures/disasm/                      18 .test files + run.tcl (158 LoC)
?? validation/probes/ENSEMBLE_VERDICT.md            (Q3 / R32 verdict)
?? validation/probes/TCL_VERSION_VERDICT.md         (deliverables d + e)
?? validation/probes/ensemble_enumeration_probe.tcl 368 LoC
?? validation/probes/P1_1_VERDICT.md                (this file)
```

## Re-run reproducer (full P1.1 verification)

```bash
cd /home/giles/git/jcodemunch-mcp-fork

# Regression guards (P1.0 baselines)
tclsh validation/probes/body_base_probe.tcl --bluice
python3 validation/golden_set/validate_golden.py

# P1.1 deliverables
tclsh validation/probes/ensemble_enumeration_probe.tcl
tclsh validation/fixtures/disasm/run.tcl

# Walker spike CLI inspection on a real bluice file
tclsh src/jcodemunch_mcp/parser/opcode_walker.tcl \
    /home/giles/bluice/dcs-lib-tcl/main/scripts/AsyncGets.tcl | head -40
```

All commands exit 0 on the verified configuration (tclsh 8.6.14,
bluice corpus at the timestamp of this verdict). Any non-zero exit
is a regression to investigate.

## Post-P1.1 OMC dispatch — Q1+Q5+Q7 resolutions

After this verdict was written, the user routed Q3+Q6 to in-session
empirical probes and Q1+Q5+Q7 to OMC agents. Outcomes:

- **Q3** (literal `{*}` brace list): resolved empirically — Tcl 8.6
  constant-folds; walker emits `pattern_a` correctly. No action.
  Evidence: `validation/probes/P1_2_QUESTIONS_EVIDENCE.md` § Q3.
- **Q6** (corpus `unrecognized` audit): resolved empirically — 2 of
  12,010 events unrecognized (0.017%); both are sub-table B bracket
  inlining. Resolving Q1 closes them.
  Evidence: same doc § Q6.
- **Q1 + Q5** (bracket inlining + interior invokeStk): omc:architect
  recommended **Strategy A — flat-pc-stream walk with anchor by src
  range**. The per-command framing of P1.1 walker is replaced.
  Q5 dissolves under Strategy A. LoC delta +65–85.
- **Q7** (R22 schema): omc:critic returned **REVISE** with 3 critical
  + 4 major findings. Schema decisions taken: bare names
  (`parent_classes`, `package_requires`), rich types
  (`list[{name, line}]` and `list[{name, version|null}]`), empty-list
  always-`[]`-never-omit, both-source-populated for `package require`,
  file-level `__script__` host for package_requires, INDEX_VERSION
  bump 9 → 10.

**Consolidated spec for P1.2**: `/home/giles/bluice/.omc/jcm-test/
PLAN_v2_2_PATCH.md`. P1.2 reads PLAN_v2.1 + this patch as the spec.

## Posture for P1.2

P1.1 leaves a clean substrate:
- The parser's output shape is the contract the bridge driver will
  consume. Stable API: `::jcm::disasm::parser::disassemble_and_parse`.
- The walker's event stream is the contract the recursion-table
  driver will consume. Stable API: `::jcm::disasm::walker::walk`.
- The fixture suite is the regression net for §2.3 rule changes.
- The body-base infrastructure (P1.0) is the substrate for §2.2
  body-content extraction; the walker emits enough metadata
  (`namespace_eval` ns + body, `apply_lambda` lambda) to drive
  recursion in P1.2's sub-table A handlers.

Per the user's plan: P1.2 kickoff switches to OMC orchestration
(`executor` + `code-reviewer` agents, possibly via `/team`) for the
bulk rule-porting + Signal 2 sandbox + body-base helper work.
Decisions stay with the user.
