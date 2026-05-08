# RULE_INVENTORY.md — current bridge → v2.1 fate map

**Date**: 2026-05-08
**Source**: `tcl_parser_bridge.tcl @ tcl-native-parser` (1925 LoC)
**Plan**: `PLAN_v2.1.md §3 P1.0`

This document maps every rule, helper, and dispatcher in the current
bridge to its corresponding SPEC.md section, the test that exercises
it, and its fate under v2.1.

## Fate legend

| Code | Meaning |
|---|---|
| **GONE** | Substrate change makes this obsolete. Bytecode disassembly + `src N-M` ranges replace it. |
| **OPCODE** | Re-expressed as an opcode pattern row in v2.1 §2.3 dispatch table. |
| **REC-A** | Re-expressed as a row in v2.1 §2.4 sub-table A (literal-recursion bodies). |
| **REC-B** | Re-expressed as a row in v2.1 §2.4 sub-table B (outer-bytecode inlined; no recursion needed). |
| **REC-C** | Re-expressed as a row in v2.1 §2.4 sub-table C (mixed/conditional). |
| **HELPER** | Kept as a helper in the new bridge (rewritten or carried forward). |
| **HELPER-§2.2** | Specifically the body-base / word-position infrastructure per v2.1 §2.2. |
| **SCHEMA** | Output-schema concern; logic kept regardless of substrate. |
| **SANDBOX** | Migrates to Signal 2 definition-capture sandbox per v2.1 §2.7. |

---

## A. Infrastructure & helpers

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 1 | `json_*` encoders | 17–57 | — | (all) | HELPER | Output utility. Same JSON shape per §0.2 rule 5 + R22. |
| 2 | `read_source` | 63–69 | — | TestUTF8 | HELPER | UTF-8 file read. |
| 3 | `build_char_to_byte` | 74–86 | — | `test_utf8_byte_offsets_correct` | HELPER | Char→byte map for `byte_offset` field. v2.1 still emits byte offsets per §2.2. |
| 4 | `build_line_offsets` / `char_to_line` / `char_to_byte` | 89–118 | — | `test_proc_line_numbers` | HELPER | Line/byte lookup. v2.1 still anchors disassembly src ranges into file:line. |
| 5 | `split_on_semicolons` | 126–185 | §2 prelude (command boundaries) | TestSemicolonSplitting | **GONE** | Tcl compiler delivers command boundaries via `disassemble` `src N-M` ranges (v2.1 §2.1). |
| 6 | `find_brace_words` | 198–231 | §2.5 (body-taking) | TestBodyTakingPrecision (indirect) | HELPER-§2.2 (partial) | Logic folds into the §2.2 word-position walker; control-flow recursion goes away (REC-B). |
| 7 | `compute_body_base` | 233–237 | §2.5 (body-taking) | (every body-recursing test) | **REWRITTEN** as HELPER-§2.2 | Naive `string first "{"`. v2.1 replaces with full word-position walker (~30–50 LoC) + `is_quote_balanced` guard + content extractor + cross-file index. Plan §2.2 totals 130–170 LoC. **Body-base probe (P1.0) gates this.** |
| 8 | `is_quote_balanced` | 246–326 | §2.5 prelude | (every body parse) | HELPER-§2.2 | Re-derived per §0.2 rule 4. Lexer-aware completion check (bare/quoted/brace contexts). |
| 9 | `split_commands` | 333–407 | §2 (command splitter) | TestSemicolonSplitting | **GONE** | Substrate change. Replaced by disassembly's command list with `src N-M` ranges. |

## B. Metric scanners

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 10 | `count_cyclomatic` / `_count_cyclo_walk` | 416–454 | (out-of-scope; complexity) | TestComplexity, `test_cyclomatic_ignores_string_keywords` | HELPER | Walks branch keywords. In v2.1 runs over the §2.2-extracted body string; same algorithm. Could later be re-expressed via opcode counting (`jumpFalse1` / `jumpTrue1`) as a future cleanup. |
| 11 | `count_max_nesting` | 459–477 | (out-of-scope; complexity) | `test_nesting_ignores_string_braces` | HELPER | Same as above. |
| 12 | `count_params` | 480–506 | (out-of-scope; symbol metadata) | `test_proc_param_count`, `test_param_count` | HELPER | Argument-list arity. Drives `param_count` field. |

## C. Call-edge extraction (the heart of SPEC §2)

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 13 | `extract_calls` skip-list | 521–536 | §3.1 (skip list) | `test_value_eating_builtin_args_not_recursed`, TestExtractCallsNative (many) | **GONE** | The skip list disappears entirely. In v2.1 the bytecode opcode stream tells us which words ARE command names (push CMD; invokeStk N) vs. which are operands of value-eating compiled-in primitives (`strlen`, `lreplaceList`, `strmatch`, etc.). Builtins emit their own opcodes; we never see them as `invokeStk` push-then-call shapes for control-structure subordinate forms. **R10/§2.3 ensemble pre-rename** absorbs the multi-word builtins (`chan close`, `dict for`, etc.). |
| 14 | `_extract_dedup` | 659–669 | (post-processing) | (implicit) | HELPER | Per-symbol callee dedup. Trivially carries over. |
| 15 | Pattern A — bare/multi-segment FQN | 701–705 | §2.1 | `test_extracts_top_level_procs`, `test_namespace_qualified_call_*`, `test_multi_segment_fqn_is_only_proc_capture` | OPCODE | v2.1 §2.3 row 1. Opcode shape: `push CMD; ...; invokeStk N`. Captured verbatim. |
| 16 | Pattern B — variable-receiver dispatch | 706–712 | §2.2 | `test_local_calls`, `test_string_arg_does_not_capture_word_inside_quotes`, `test_bind_callback_dispatch_captured` | OPCODE | v2.1 §2.3 row 3. Opcode shape: `push VAR; loadStk; push METHOD; ...; invokeStk N`. |
| 17 | Pattern A2 — single-segment FQN dispatch | 719–724 | §2.3 | `test_fqn_global_dispatch_captures_method` | OPCODE | v2.1 §2.3 row 2. Detected as Pattern A where CMD is a single-segment `::X`; the second push captured as method. |
| 18 | `concat_cmds` (eval/uplevel literal-prefix concat) | 732–743 | §2.5 | `test_eval_prefix_dispatch_resolves`, `test_uplevel_prefix_dispatch_resolves`, `test_eval_list_is_resolvable_not_unresolved` | REC-A | v2.1 sub-table A: `eval BODY` / `uplevel ?level? SCRIPT` recurse via `disassemble script BODY` when literal. Variable form is unresolved (see #36–38). |
| 19 | `foreach`/`lmap` body recursion | 750–756 | §2.5 | `test_inline_brace_foreach_body_is_recursed`, `test_lmap_single_var_body`, `test_lmap_multi_var_body` | REC-A | v2.1 sub-table A: `foreach var list BODY` / `lmap var list BODY` last-arg body. |
| 20 | `dict for|with|update` | 763–772 | §2.5 | `test_dict_for_body`, `test_dict_with_body`, `test_dict_update_body` | REC-C | v2.1 sub-table C (body inlined into outer bytecode by the compiler). Per §2.4 Sub-table B treatment in disassemble: bodies inlined; no recursion needed — just walk outer command stream. |
| 21 | `apply` lambda body | 776–784 | §2.5 | `test_apply_lambda_body` | REC-A + OPCODE row R8 | v2.1 §2.3 row R8: `apply` invokeStk with list-shaped literal arg 2 → recurse into lambda body slot via `disassemble lambda`. |
| 22 | `coroutine` script | 788–792 | §2.5 | `test_coroutine_body` | REC-A | v2.1 sub-table A: `coroutine NAME SCRIPT ?args?` arg-3 body. Emits symbol kind=coroutine. |
| 23 | `time` script | 795–799 | §2.5 | `test_time_body` | REC-A | v2.1 sub-table A: `time SCRIPT ?count?` arg-2 body. |
| 24 | `if`/`elseif`/`else` recursion | 805–813 | §2.5 | `test_single_command_if_body_is_recursed` | REC-B | v2.1 sub-table B: every branch is its own command in outer bytecode; no recursion needed. The bridge's per-arg loop becomes an outer-stream walk. |
| 25 | `try`/`on`/`trap`/`finally` | 819–842 | §2.5 | `test_try_main_body_handler_finally_all_recursed` | REC-C | v2.1 sub-table C: BODY arms inlined; errcode/varlist recognized as data positions and skipped. |
| 26 | `switch` (inline pair + all-in-one forms) | 850–882 | §2.5 | `test_switch_inline_pair_bodies_captured`, `test_switch_block_form_bodies_captured` | REC-C | v2.1 sub-table C: multi-arg form bodies inlined; all-in-one form recurses on the brace block via `disassemble script`. `-` fallthrough preserved. |
| 27 | `bind` Tk callback | 892–898 | §2.5 | `test_bind_callback_dispatch_captured` | REC-A | v2.1 sub-table A: `bind ?tag? window SCRIPT` last-arg script; no symbol but recurses for L2. |
| 28 | `itk_component add` | 905–918 | §2.7 | `test_itk_component_creation_body_recursed`, `test_itk_component_config_block_not_recursed`, `test_itk_component_protected_flag`, `test_itk_component_with_text_no_leak` | REC-A | v2.1 sub-table A: `itk_component add ?-protected? NAME CREATE ?CONFIG?` — recurse only on CREATE; CONFIG is iTk DSL, **explicitly skipped**. Emits symbol kind=component. |
| 29 | `itk_option define` | 923–930 | §2.8 | `test_itk_option_no_body_no_capture`, `test_itk_option_with_body_recursed` | REC-A | v2.1 sub-table A: `itk_option define -switch RES CLASS DEFAULT ?CONFIG?` last-arg config (optional). Emits kind=interface. |
| 30 | Value-eating builtin guard | 932–942 | §3.6 | `test_value_eating_builtin_args_not_recursed`, `test_literal_list_arg_does_not_fp` | **GONE** | No skip-list → no value-eating guard needed. Bytecode never presents a builtin's data args as candidates for "is this a call edge?". |
| 31 | Tk-flag value guard | 944–988 | §3.2 | `test_text_flag_does_not_leak_prose`, `test_command_flag_still_recurses` | **GONE** | Multi-line `-text "..."` no longer recurses because there is no string-content recursion in v2.1; bytecode never emits its content as commands. |
| 32 | Tk-callback regex pass | 990–996 | §2.6 | `test_bind_callback_dispatch_captured`, `test_line_continuation_quoted_arg_recovers` | OPCODE (callback row) | v2.1 §2.3 row 4: callback opcode shape `push VAR; loadStk; push " METHOD"; strcat 2`. The regex disappears. |
| 33 | `_extract_brackets` (bracket walker) | 1001–1025 | §2.4 | `test_bracket_dispatch_resolved` | **GONE** | Per §2.4 sub-table B: bracket substitutions are their own commands in the outer bytecode stream. Walked uniformly with everything else. |

## D. Annotations / decorators

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 34 | `detect_annotations` / `_detect_annotations_walk` | 1034–1079 | (out-of-scope; metadata) | TestAnnotations (4 tests) | HELPER | Scans body for uplevel/upvar/global/eval/coroutine/rename/interp/trace/dynamic-dispatch and `package_require`. Runs over the §2.2-extracted body. |

## E. Unresolved-dispatch detection (SPEC §4)

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 35 | `extract_unresolved` driver | 561–578 | §4 | TestUnresolvedDispatch (7 tests) | HELPER | Top-level loop over commands. Substrate-agnostic; runs on the same opcode-walker output. |
| 36 | `eval_var` / `eval_brackets` | 579–595 | §4.1, §4.2 | `test_eval_var_tagged`, `test_eval_brackets_tagged`, `test_eval_list_is_resolvable_not_unresolved` | OPCODE | v2.1 §2.3 unresolved rows: `eval $var` → `invokeStk to eval with loadScalar`; `eval [bracket]` → `invokeStk to eval with bracket-result`. |
| 37 | `uplevel_var` | 597–609 | §4.5 | `test_uplevel_var_tagged` | OPCODE | v2.1 §2.3 unresolved row: `uplevel $script` → `invokeStk to uplevel with loadScalar`. |
| 38 | `interp_eval` | 611–619 | §4.6 | `test_interp_eval_tagged` | OPCODE | v2.1 §2.3 unresolved row: `interp eval $other $cmd` → matched by ensemble pre-rename + `loadScalar` arg. |
| 39 | `var_command` / `var_method` | 621–635 | §4.3, §4.4 | `test_var_command_tagged`, `test_var_method_tagged` | OPCODE | v2.1 §2.3 unresolved rows: `$var args` (no method push) → `var_command`; `$obj $methodvar` (two `loadStk`, no method push) → `var_method`. |
| 40 | `_offset_to_line` / `_truncate` | 642–657 | (formatting) | (implicit) | HELPER | Snippet line attribution + truncation. Trivial carryover. |

## F. Symbol parsers (recursion-table sub-table A in v2.1)

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 41 | `emit_symbol` | 1117–1208 | §1 (output) | (every test) | SCHEMA | Output-record builder. **R22**: add `static_inheritance` and `static_package_requires` fields. Method-decl-vs-body dedup logic (`method_registry`) **kept** (still applies; iTcl out-of-line bodies still need decl/body merging). |
| 42 | `parse_proc` | 1210–1248 | (sym kind=function) | TestBasicProcs, TestComplexity | REC-A | v2.1 sub-table A row 1: `proc NAME ARGS BODY` → recurse via `disassemble lambda {ARGS BODY}`. |
| 43 | `parse_package` | 1250–1272 | (sym kind=import) | `test_package_require` | REC-C + SCHEMA | v2.1 sub-table C row "package require": no body; record in `static_package_requires` per **R13/R22**. Also still emits an `import`-kind symbol for cross-language consumers (`test_source_imports`, `test_namespace_imports`). |
| 44 | `parse_namespace_eval` (incl. `namespace export` collection) | 1274–1318 | (sym kind=namespace) | TestNamespaces (5 tests) | REC-A + HELPER | v2.1 sub-table A row "namespace eval" → recurse via `disassemble script BODY`. The `namespace export` rescan stays as a helper that runs over the body string. |
| 45 | `parse_oo_class` | 1320–1351 | (sym kind=class, TclOO) | (planned forward-compat) | REC-A | v2.1 sub-table A: `oo::class create NAME BODY`. Plus signal-2 sandbox override (R28 list). |
| 46 | `parse_custom_class` | 1353–1384 | (sym kind=class, custom DSL) | (gitgui-style fixture) | REC-A | v2.1 sub-table A: `class NAME BODY`. |
| 47 | `find_inherit_parents` | 1390–1403 | §5 (inheritance, downstream) | `test_class_extracted` (signature) | REC-C + SCHEMA | v2.1 sub-table C row "inherit" → record each base in `static_inheritance` per **R12/R22**. Same scan logic; data lands in the schema field. |
| 48 | `parse_class_body` (the access-modifier + method/proc/constructor/destructor/field/itk_option dispatcher) | 1405–1626 | (multiple) | TestOOClass, TestThreeArgConstructor, TestItkDsl | REC-A (multiple rows) | The largest single dispatcher in the bridge (~220 LoC). In v2.1 it decomposes cleanly into one row per construct in sub-table A: method (3 visibilities + bare), constructor (2-arg/3-arg/custom-DSL forms), destructor, field, common, variable, public/private/protected proc, inherit (REC-C), itk_option define. The fallback regex (lines 1440–1448) for `lrange`-defeating brace-content cases **goes away**: bytecode parses these correctly without lexer-level workarounds. |
| 49 | `parse_oo_body` (legacy alias) | 1629–1631 | — | — | **GONE** | Legacy alias; v2.1 has one unified class-body handler. |
| 50 | `parse_itcl_class` (incl. `itk::usual` → kind=interface) | 1633–1676 | (sym kind=class/interface) | (itcl fixture) | REC-A | v2.1 sub-table A row "itcl::class". `itk::usual` mapped to kind=interface stays. |
| 51 | `parse_itcl_body` (incl. method-vs-class-proc dedup) | 1678–1724 | (sym kind=method, out-of-line) | iTcl 3-arg constructor coverage in TestThreeArgConstructor | REC-A | v2.1 sub-table A row "body". The method-vs-class-proc tagging keeps working through `method_registry` (#41 above). |
| 52 | `parse_itcl_configbody` | 1726–1752 | (sym kind=method, configbody) | (itcl-configbody fixture) | REC-A | v2.1 sub-table A row "configbody". |

## G. File-scope dispatcher

| # | Bridge entity | Lines | SPEC | Test | Fate | Notes |
|--:|---|---:|---|---|---|---|
| 53 | `parse_body` main dispatcher | 1755–1891 | (driver) | (every test, transitively) | **REWRITTEN** | The first-word string-match dispatcher (~10 elif arms) becomes a declarative recursion table lookup in v2.1 §2.4. Adding a new construct is one row, not a new code path (per §6.1.10 elegance criterion). |
| 53a | Control-flow recursion via `find_brace_words` (1853–1860) | 1853–1860 | (top-level conditional defs) | `test_single_command_if_body_is_recursed` | **GONE** | Per §2.4 sub-table B: conditional-defined procs already appear in the outer bytecode stream (each branch's commands are inlined). No string-level brace re-scan needed. |
| 53b | `__script__` synthetic file-scope symbol | 1862–1890 | (top-level call edges) | `test_local_calls`, every fixture's file-root callees | SCHEMA | Logic kept: file-root commands not absorbed by a defining construct accumulate into a single `__script__` symbol. Substrate-independent. |
| 54 | `main` entrypoint | 1897–1925 | — | — | HELPER | Argv handling, JSON emit. Substrate-independent; v2.1 has its own driver. |

---

## H. Cross-cuts and elimination summary

The substrate change retires these bridge-internal mechanisms wholesale:

- **String-level command splitter** (`split_commands`, `split_on_semicolons`, `is_quote_balanced` as a completion guard for the splitter) — replaced by the bytecode command stream + `src N-M` ranges.
- **String-level bracket walker** (`_extract_brackets`) — replaced by §2.4 sub-table B (bracket subs are commands in the outer stream).
- **Skip list** (~40 entries, lines 522–534) — replaced by opcode-shape recognition.
- **Tk-flag-value guard** + **value-eating-builtin guard** + the **prev-word `-flag` regex** (lines 966–974) — all defenses against string-recursion false positives that don't apply when there is no string recursion.
- **Tk-callback regex** (lines 992–996) — replaced by an opcode pattern (§2.3 row 4: `push VAR; loadStk; push " METHOD"; strcat 2`).
- **`lrange` fallback regex** for brace-content cases (lines 1440–1448) — bytecode parses these correctly.
- **`find_brace_words` control-flow recursion in `parse_body`** (lines 1853–1860) — bytecode inlines branches into the outer stream.
- **Manual offset arithmetic** (`compute_body_base`'s naive `string first "{"`, `_offset_to_line`'s newline counting in body strings) — replaced by `src N-M` byte ranges + the §2.2 word-position walker for the body-arg subset.

What stays — re-expressed declaratively where possible:

- Output schema (`emit_symbol`, JSON helpers, char/byte/line maps, dedup registry).
- Metric scanners (`count_cyclomatic`, `count_max_nesting`, `count_params`).
- Annotation scanner (`detect_annotations`).
- Pattern A/A2/B + callback shapes — moved to opcode-pattern table (§2.3, rows 1–4).
- Recursion table — moved to §2.4 sub-tables A/B/C, one row per construct.
- Unresolved-dispatch categories — moved to opcode-pattern table (§2.3, unresolved rows).
- Body-base infrastructure — rewritten per §2.2 (word-position walker + `is_quote_balanced` + content extractor + cross-file index, 130–170 LoC total).
- File-scope `__script__` synthesis.
- Static `inherit` and `package require` capture — promoted to schema fields per **R22** (`static_inheritance`, `static_package_requires`).

## I. Test coverage by class (v2.1 must keep all 83 green)

| Test class | Count | Primary rules covered |
|---|--:|---|
| TestBasicProcs | 6 | #42 |
| TestNamespaces | 5 | #44 |
| TestAnnotations | 4 | #34 |
| TestOOClass | 5 | #45, #48 |
| TestSemicolonSplitting | 2 | #5 (will re-pass on substrate change without `split_on_semicolons` because the bytecode emits each cmd separately) |
| TestUTF8 | 2 | #3, #41 |
| TestTKFiles | 2 | (extension dispatch — non-bridge) |
| TestImports | 3 | #43, #44 |
| TestComplexity | 3 | #10, #11, #12 |
| TestCallReferences | 2 | #15, #17 |
| TestFallback | 1 | (extractor.py path; non-bridge) |
| TestExtractCallsNative | 11 | #15, #16, #18, #19, #24, #30, #33 |
| TestThreeArgConstructor | 2 | #48 (3-arg constructor form) |
| TestStringAwareMetrics | 4 | #10, #11, #34 (string-awareness) |
| TestSwitchTryPrecision | 3 | #25, #26 |
| TestBodyTakingPrecision | 8 | #19, #20, #21, #22, #23, #27 |
| TestItkDsl | 5 | #28, #29 |
| TestTkFlagValueIdiom | 3 | #31 (going GONE; tests still pass because v2.1 doesn't inject FPs in the first place) |
| TestDispatchAndContinuation | 4 | #15, #17, #27, #32 |
| TestUnresolvedDispatch | 8 | #35–#39 |

**Total: 83.** P1.2 exit gate: 83/83 green. Any retired test must come with written rationale per §6.1.

---

## J. Rules that gain coverage in v2.1 but had no current bridge counterpart

These v2.1 rules add capability beyond the current bridge:

- **Pragma scanner** (R31): `# JCM:dynamic`, `# JCM:export`, `# JCM:ignore` markers. P1.2 deliverable; ~15 LoC.
- **Dynamic-body regex pre-scan** (R31): cross-validates `unresolved_dispatches: dynamic_body` tagging. P1.2 deliverable; ~5–10 LoC.
- **Ensemble pre-rename table** (R29 + R32): un-renames compiler-emitted `::tcl::ENSEMBLE::*` literals to source form. P1.1 enumerated; 9 ensembles, ~43 subcommands observed.
- **Definition-capture sandbox** (Signal 2, §2.7): independent verification by overriding `proc`/`method`/`itcl::class`/`namespace eval`/`itk_component add`/`itk_option define`/`oo::class create`/`oo::define`/`source`/`unknown`. ~200–300 LoC.
- **Static-inheritance and static-package-requires fields** (R22): two new schema fields. Phase 1 produces the data; Phase 2 wires up consumers.

---

## Methodology note

This inventory is mechanical: every helper proc, dispatcher branch, and rule-resembling construct in `tcl_parser_bridge.tcl @ tcl-native-parser` was walked top-to-bottom and assigned a fate. No SPEC sections from §1–§4 are unaccounted for; no test from `test_tcl_parser.py @ tcl-native-parser` is uncovered.

Read the bridge file via `git show tcl-native-parser:src/jcodemunch_mcp/parser/tcl_parser_bridge.tcl` from the new branch.
