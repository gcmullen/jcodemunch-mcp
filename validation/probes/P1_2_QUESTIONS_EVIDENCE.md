# P1.2 questions — empirical evidence pre-architect

**Date**: 2026-05-08
**Context**: P1.1 closed at `P1_1_VERDICT.md` with 7 P1.2 questions
surfaced. Q3 and Q6 are empirical (probe-driven); evidence captured
here before routing Q1+Q5 to the architect agent and Q7 to the
critic agent.

This document is the input bundle the architect/critic agents read.

---

## Q3 — `{*}` over a literal-but-multi-element brace list

### Verdict: **NO ACTION REQUIRED. Walker is correct.**

Probe (`/tmp/p11_q3_probe.tcl`) disassembled six `{*}`-with-literal
shapes through tclsh 8.6.14. Tcl 8.6's compiler **constant-folds
literal brace lists in `{*}` expansion entirely** — the `{*}`
operator vanishes from the bytecode and the literal list elements
become ordinary push slots:

| Source | Compiled bytecode | Walker output |
|---|---|---|
| `foo {*}{a b c}` | `push "foo"; push "a"; push "b"; push "c"; invokeStk1 4` | `pattern_a name=foo arg_count=4` ✓ |
| `foo {*}{a}` | `push "foo"; push "a"; invokeStk1 2` | `pattern_a name=foo arg_count=2` ✓ |
| `foo {*}{}` | `push "foo"; invokeStk1 1` | `pattern_a name=foo arg_count=1` ✓ |
| `foo {*}{a {b c} d}` | `push "foo"; push "a"; push "b c"; push "d"; invokeStk1 4` | `pattern_a name=foo arg_count=4` ✓ |
| `set xs {a b c}; foo {*}$xs` | (var form, distinct) | `expand_args name=foo` ✓ |

The walker correctly emits `pattern_a` for the constant-folded case
and `expand_args` only for the genuinely-runtime expansion. The
`arg_count` reflects the post-expansion length, which is the right
answer for downstream symbol-graph analysis.

**Action**: none. Optionally add a fixture to lock down the
behavior; the existing `05_expand_args.test` covers the var-form.

---

## Q6 — Walker `unrecognized` audit on full bluice corpus

### Verdict: **2 / 12,010 unrecognized (0.017%). Both are sub-table B inlining cases — Q1's territory.**

Probe (`/tmp/p11_q6_probe.tcl`) walked every `.tcl` file in the
P1.1(f) corpus scope (BluIceWidgets, DcsWidgets, dcs-lib-tcl/main/
scripts, dhs-tcl, dcss/scripts/**) — 822 files, 0 disassembly
failures, 12,010 walker events emitted.

### Event-kind histogram

| Kind | Count | % of total |
|---|--:|--:|
| `pattern_a` | 11,525 | 95.96% |
| `ensemble` | 376 | 3.13% |
| `callback` | 70 | 0.58% |
| `pattern_a2` | 18 | 0.15% |
| `namespace_eval` | 9 | 0.07% |
| `pattern_b` | 8 | 0.07% |
| `apply_lambda` | 1 | 0.01% |
| `eval_brackets` | 1 | 0.01% |
| **`unrecognized`** | **2** | **0.017%** |

This is the §2.3 dispatch table's accuracy claim, on real bluice
code: **99.98% recognized.** The walker's design holds.

### The 2 unrecognized cases — both sub-table B bracket inlining

#### Case 1: `if [catch "unlockAllSil $gUserName $gSessionID 1" errMsg] { ... }`

- File: `dcss/scripts/engine/scriptingEngine.tcl` (and 2 other
  occurrences across `SequenceDevice*.tcl`)
- Source-form: `if` with a bracket-substituted condition.
- Bytecode-level: the `[catch ...]` substitution is its own command
  (sub-table B inlining). Disassembled in isolation, `catch ... err`
  is `pattern_a name=catch arg_count=3` — the walker handles it
  correctly when it's the OUTER command. In the corpus context, the
  catch is the BRACKET sub of `if`, and its terminal `invokeStk1` is
  attributed to the outer `if`'s pc range. The walker's per-command
  analysis loses the slot context.

#### Case 2: `lindex $argv 0`

- Files: `BluIceWidgets/bluice.tcl`, `bluice_remote.tcl`, etc.
- Source-form: `lindex $argv 0` at file scope.
- Bytecode-level: `lindex` with a small literal integer index is
  specialized to `listIndexImm` (a direct opcode, NO invokeStk).
  In isolation the walker emits NO event (correctly silenced, like
  the `string length` / `dict get` cases in fixture 17). The
  unrecognized event must come from a multi-pc shape where the
  walker sees a partial slot stack.

Both cases share a root cause: **bytecode produced for the
bracket/specialized form is not cleanly attributable to a single
"Command N:" in the disassembly output.** This is precisely Q1
(bracket-inlining cross-pc attribution) and Q5 (interior invokeStk
stack-effect bookkeeping).

### Implication for Q1 + Q5

**Resolving Q1 closes the corpus unrecognized set.** No new dispatch
rows are required for the 99.98% covered. The remaining 0.017% is
not "missing dispatch rows"; it's "the per-command framing
mis-attributes opcode boundaries in two specific compilation
patterns."

This shifts the architect's question from *"what new patterns to
add?"* to *"which strategy for cross-pc attribution?"* The plan
already lists the two candidates:

- **Strategy A (flat-pc-stream walk)**: walk the bytecode as a flat
  pc stream once, attributing each terminal invoke to the source
  command whose `src N-M` range contains the start of the terminal's
  preceding push chain. The "Command N:" headers become metadata
  rather than the walker's per-frame boundary.
- **Strategy B (pre-pass merger)**: detect sub-table B inlining
  during disassembly post-processing — when Command K's
  instructions appear within Command J's pc range, merge K's
  instructions into J's frame before the walker runs.

Strategy A is closer to PLAN_v2.1's §2.1 "single-pass walker"
description; Strategy B preserves the per-command analysis but
needs careful boundary detection.

---

## Carry-forward for routing

- **Q1 + Q5**: routed to architect. The corpus evidence above is
  the input bundle.
- **Q7**: routed to critic. R22 schema additions
  (`static_inheritance`, `static_package_requires`) are
  consumer-facing JSON-shape decisions; critic evaluates against
  the JCM consumer-brittleness memory.
- **Q2**: scope. Add to P1.2 fixture suite during build; no
  recommendation needed.
- **Q3**: resolved here. No action.
- **Q4**: scope. Bluice has no user-defined ensembles; mechanism
  to extend is in `ensemble_enumeration_probe.tcl` — document and
  move on.
- **Q6**: resolved here. The 2 unrecognized cases are Q1's
  territory; resolving Q1 closes them.
