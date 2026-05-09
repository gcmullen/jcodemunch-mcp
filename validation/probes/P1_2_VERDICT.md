# P1.2 closing verdict — bridge driver + walker rewrite + recursion tables + body-base + schema additions + 86-test port

**Date**: 2026-05-08
**Branch**: `tcl-disasm-bridge` (continuing from P1.1 at `efce5c1`; P1.2 commit at `<P1.2 SHA — fill in after commit>`)
**Plan**: `PLAN_v2.1.md §3 P1.2` + `PLAN_v2_2_PATCH.md` (6-8 days budgeted)
**Predecessor verdicts**: `P1_0_VERDICT.md` (P1.0 body-base gate); `P1_1_VERDICT.md` (P1.1 walker spike + 18 fixtures); `BODY_BASE_VERDICT.md` (P1.0 walker viability); `ENSEMBLE_VERDICT.md` (R32); `TCL_VERSION_VERDICT.md`

---

## Verdict: **P1.2 ALL DELIVERABLES MET. READY FOR P1.3.**

The bridge is end-to-end functional: parser → walker → recursion tables → body-base helper → unresolved detector → pragma scanner → bridge driver → JSON output, replacing the v1 `tcl_parser_bridge.tcl` (1925 LoC string-level parser, lives only on `tcl-native-parser` branch). T14 §6.1.10 reviewer verdict: **PASS-WITH-NITS** (0 CRITICAL, 2 MAJOR, ~10 MINOR/NIT — all non-blocking; cleanup items captured in task #16 for P1.3). Full pytest suite green; 22-fixture suite 22/22; corpus probe 0 unrecognized across 12,256 events.

---

## Per-deliverable status

### (a) `tcl_disasm_bridge.tcl` — **WORKING. 1898 LoC.**
- Bridge driver wires parser + walker + recursion_tables + compute_body_base + unresolved_detector + pragma_scanner into a single tclsh-callable pipeline.
- 4 post-passes: `_resolve_file_offset_tags`, `_attach_pragmas`, `_attribute_out_of_line_bodies`, metrics finalization.
- Pure-Tcl JSON serialization (no tcllib dependency).
- LoC overage (1898 vs 900-1200 soft target) acknowledged; T14 reviewer recommends extracting `bridge_postpasses.tcl` (~200 LoC) + `tcl_disasm_bridge_json.tcl` (~250 LoC) in P1.3 cleanup → bridge driver lands in 1200-1400 band.

### (b) `recursion_tables.tcl` — **WORKING. 377 LoC.**
- Sub-table A: 26 declarative rows (proc/method/itcl::class/`class NAME BODY`/oo::class create/etc.).
- Sub-table B: handled by walker rewrite (no rows; bracket-inlined commands appear inline in flat-pc events).
- Sub-table C: 6 row handlers (inherit, superclass, package_require, try, switch, dict).
- Adding a new construct = one declarative row.

### (c) `compute_body_base.tcl` — **WORKING. 466 LoC.**
- 5-component helper: word-position walker (~80 LoC), `is_quote_balanced` (~45 LoC fixing the `info complete` brace-blindness bug), body extraction (~60 LoC), 2-pass cross-file index for `body Widget::method` attribution (~45 LoC), driver/plumbing (~20 LoC).
- Re-derived from `validation/probes/body_base_probe.tcl` (P1.0 substrate; 100% match on 382 bluice definitions) per §0.2 rule 4.

### (d) `unresolved_detector.tcl` — **WORKING. 192 LoC.**
- 8-row UNRESOLVED_MAP: `eval_var`, `eval_brackets`, `var_command`, `var_method`, `uplevel_var`, `interp_eval`, `computed_namespace`, `dynamic_body`.
- Always-list semantics per §Δ0.2 C3.

### (e) Walker rewrite Strategy A — **WORKING. ~1060 LoC.**
- Replaces P1.1's per-command iteration with forward stack simulation + per-opcode 62-row STACK_EFFECTS table + anchor-by-src-range with innermost-wins tiebreaker.
- 14-row DISPATCH: 12 P1.1 carryforward + explicit `eval_brackets` row + `var_command` (§13.5 decided=A; predicate `op==invokeStk{1,4} AND slot 0 VAR AND N==1`).
- `computed_namespace` dispatch row deferred to P1.3 task #15 — predicate needs empirical validation against FQN-dispatch invokeReplace shapes (rfc2822.tcl evidence).
- Boundary recovery (NG-5): unknown_opcode + stack_underflow + dead-code (jump1/jump4) all share the `in_dead_code` reset-and-suppress-until-startCommand path. Empirically validated against `/usr/share/tcltk` (40 clean per-event unrecognized counts across 14,215 events from 788 files; no cascade noise).
- Closes P1.1's 2/12,010 unrecognized cases (bracket inlining) by construction via Strategy A's flat-pc walk.

### (e2) Re-baseline 18 fixtures + add 4 new (19-22) — **22/22 PASS.**
- 18 P1.1 carryforward fixtures re-baselined for added `src_start`/`src_end` fields + flat-pc emission order shifts (notably fixture 15: gc cmd=3 fires BEFORE eval cmd=2 per §6 re-baseline policy).
- 4 new fixtures lock Strategy A correctness: `19_bracket_inline_if.test`, `20_bracket_inline_specialized.test`, `21_nested_brackets.test`, `22_interior_invoke.test`.

### (f) Schema additions + INDEX_VERSION 9→10 + CHANGELOG — **WORKING.**
- `parent_classes: list[{name STRING, line INT}]` on class symbols only (per §13.2/§13.3 decided=B). Empty `[]` if no inherit/superclass.
- `package_requires: list[{name STRING, version STRING|null}]` on file's `__script__` symbol only. Empty `[]` if no requires. `version` is `null` when source omits it.
- `package require` emits BOTH a `kind=import` symbol AND populates `package_requires` field per §Δ0.2 C1.
- INDEX_VERSION 9 → 10 with `_migrate_v9_to_v10()` migration path (old indexes load with empty new fields; v10 indexes rejected by older versions per existing version gate).
- CHANGELOG `[Unreleased]` section includes BREAKING CHANGE callout (no-fallback policy) + reindex requirement + multi-platform tclsh install instructions.

### (g) 83-test port + 4 schema tests + extractor.py wiring — **86/86 PASS.**
- 83 ported from `tcl-native-parser:tests/test_tcl_parser.py` (20 test classes covering basic procs, namespaces, OO, callbacks, switch/try, itk DSL, Tk flag values, dispatch+continuation, unresolved, parent_classes, package_requires).
- 4 new schema-field tests: `TestParentClassesField` (×2) + `TestPackageRequiresField` (×2).
- 1 retired: `TestFallback.test_fallback_still_extracts_symbols` — rationale: tree-sitter fallback removed per no-fallback architectural decision; test exercised behavior that no longer exists.
- `extractor.py:_parse_tcl_native` dispatches through tclsh subprocess; **no fallback** — missing tclsh raises `RuntimeError` with multi-platform install instructions (`sudo apt install tcl8.6` / `sudo dnf install tcl` / `brew install tcl-tk`).

### (h) R31 pragma scanner + dynamic-body regex — **WORKING. 117 LoC.**
- TCL pre-pass scanner exposing `::jcm::pragma::scan_file path` → `{pragmas LIST dynamic_sites LIST}`.
- 3 pragma kinds: `# JCM:dynamic resolves_to=foo`, `# JCM:export`, `# JCM:ignore`.
- Symbol-attachment per NG-1 fix: `pragma.target_line == symbol.declaration_line` (multi-line proc bodies handled correctly).
- Phase-1 semantic per §Δ0.2 carried-forward: `# JCM:ignore` over `package require` does NOT suppress the kind=import symbol — adds `pragma_ignore` to unresolved_dispatches only.
- Dynamic-body regex `\bproc\s+\S+\s+\S+\s+\[` cross-validates walker's `unresolved_dispatches: dynamic_body` tagging.

### (i) SPEC_v2.md draft — **WORKING. 1499 LoC, 16 sections.**
- Comprehensive bridge spec authored by planner agent in parallel with implementation.
- §13.1-§13.7 entries are all DECIDED (§13.2/§13.3 host-only fields; §13.5 var_command distinct row; §13.6 computed_namespace distinct event kind; §13.7 superclass per-occurrence attribution; §13.4 informational; §13.1 P1.3 docs cut-over; §13.8/§13.9 informational).
- Currently lives at `docs/SPEC_v2.md` — gitignored by upstream `673c03e` rule (Marius Stanciu, 2026-04-18). Reorganization deferred to post-P1.2 per memory `docs_reorganization.md`.

---

## Stable APIs (consumed by future phases)

```tcl
::jcm::disasm::parser::disassemble_and_parse src → parsed-dict
::jcm::disasm::walker::walk parsed → list[event-dict]
::jcm::disasm::rectbl::classify_a name slots arg_count → row|""
::jcm::disasm::rectbl::classify_c name slots → handler-proc|""
::jcm::disasm::body::extract_body cmd_text body_arg_idx parent_src_offset → {start end content}
::jcm::disasm::body::build_class_index symbols → index-dict
::jcm::disasm::body::attribute_out_of_line_body class_index method_qname → class_qname|""
::jcm::disasm::unresolved::detect event ctx → entry-dict|""
::jcm::disasm::unresolved::append_to_sym sym entry → sym
::jcm::pragma::scan_file path → {pragmas LIST dynamic_sites LIST}
::jcm::bridge::bridge_main file_path → JSON string
```

Python:
```python
extractor._parse_tcl_native(source_bytes, filename) -> list[Symbol]   # raises RuntimeError if tclsh missing
extractor._tcl_install_instructions(detail) -> str                    # multi-platform install help
```

---

## Late P1.2 fixes (caught during T13/T14 + integration)

| Fix | Trigger | Location |
|---|---|---|
| Double-emission of kind=import for `package require` (was 2, should be 1) | T14 reviewer Open Question #1; verified empirically | `tcl_disasm_bridge.tcl:_handle_pattern_a` (removed special branch) + deleted unused `_emit_import_for_package` proc |
| Walker boundary recovery on unknown_opcode (cascade prevention) | NG-5 from cross-codebase audit | `opcode_walker.tcl:_simulate_stack` (extended dead-code suppression) |
| Corpus probe generalized for cross-codebase (`--root PATH`, per-opcode breakdown) | NG-6 | `validation/probes/p1_2_corpus_recognition_probe.tcl` |
| `unresolved_detector.tcl` UNRESOLVED_MAP missing `computed_namespace` row | Audit before T14 launched | Added 1-row + matching event-kind |
| Tree-sitter fallback `_parse_tcl_symbols` removed (no-fallback policy) | User decision after T13 surfaced v143 test mismatch | `extractor.py` 4 fallback returns → raise; `_parse_tcl_symbols` deleted (~85 LoC); `TestFallback` retired |
| v143 `test_tcl_parsing` kind=class → kind=namespace | T13 surfaced; semantic correction per PLAN_v2.1 §2.4 | `tests/test_new_languages_v143.py:250` |
| SyntaxWarning at `\<` escape | Pytest warning during T13 | `tests/test_tcl_parser.py:1053` (`\<` → `\\<`) |
| `.gitignore` adds `.omc/` (session artifacts) | User request | `.gitignore` |
| `tclCompile.h` citation | User request | `opcode_walker.tcl` header comment |
| STACK_EFFECTS doc drift (contract sketch 30 vs shipped 62) | Audit | Contract §3.2 + SPEC_v2 §3.2 patched to cite shipped table as source-of-truth |

---

## §13 decisions (all DECIDED in SPEC_v2.md §13.1-§13.7 and contract §11)

| § | Decision | Rationale |
|---|---|---|
| 13.2 | (B) `package_requires` only on `__script__` | Δ0.2 C2 host-symbol-type; non-host symbols don't carry the field |
| 13.3 | (B) `parent_classes` only on class symbols | Same shape; classes have inherit/superclass, procs don't |
| 13.5 | (A) `var_command` distinct dispatch row at priority 10.5 | v1 SPEC §4.3 + v1 TestUnresolvedDispatch pin the category; predicate `slot 0 VAR AND N==1` |
| 13.6 | (C) `computed_namespace` distinct event kind | Avoids polluting find_references with synthetic "(computed-ns)"; mirrors eval_var/uplevel_var/interp_eval pattern. **Walker dispatch row deferred to P1.3 task #15** — predicate needs empirical validation vs FQN dispatch. |
| 13.7 | (A) one entry per source-form occurrence | iTcl `inherit Base1 Base2` semantic; multi-site TclOO `superclass` preserves every line for jump-to-line tooling |

---

## Regression checks (all green)

| Gate | Baseline | Result |
|---|---|---|
| `body_base_probe.tcl --bluice` | 382/382 + 5/5 synthetic | 382/382 + 5/5 ✓ |
| `validate_golden.py` | 92/95 + 3 requires_v2_1 | 92/95 + 3 ✓ (P1.0 baseline) |
| `ensemble_enumeration_probe.tcl` | 10 ensembles | clean ✓ (REFERENCE_ENSEMBLES bumped 9→10) |
| `validation/fixtures/disasm/run.tcl` | 22/22 | 22/22 PASS ✓ |
| `validation/probes/p1_2_corpus_recognition_probe.tcl` | 0 unrecognized | 0/12,256 events ✓ |
| Full pytest suite | 3,659 passed (pre-P1.2) | **3,749 passed, 12 skipped, 0 failed** ✓ (post-P1.2 with TestFallback retired) |
| Bluice end-to-end smoke (Anneal.tcl) | n/a | 39 syms, 11 kind=import (post-fix), 11 package_requires, 0 duplicates ✓ |

---

## P1.3 work carried forward (tasks #15 + #16)

**Task #15 — Dynamic stack-effect inference (3-tier walker)**:
- Parse `tclInstructionTable[]` from Tcl source (apt-get source tcl8.6 OR upstream tarball at core.tcl-lang.org; `tcl8.6-dev` ships only the .h, not .c).
- 3-tier dispatch: Tier 1 (hand-classified, full handling, may emit dispatch events); Tier 2 (Tcl-known but no walker handler — apply pop/push only, no dispatch emit); Tier 3 (truly novel — current boundary-recovery path).
- Hand-classify the 12 unhandled opcodes from `/usr/share/tcltk` cross-codebase probe: `strneq`, `arrayExistsStk`, `add`/`sub`/`mult`/`div`/`lshift`, `over`, `strindex`, `listNotIn`, `verifyDict`, `evalStk`, `invokeReplace`-other.
- Build opcode-coverage probe (~50 LoC) reading `tclCompile.h` 190-opcode list + diff against walker's STACK_EFFECTS keys.
- `computed_namespace` dispatch row — empirical predicate design vs FQN dispatch shapes (rfc2822.tcl evidence).

**Task #16 — T14 reviewer's 7 PASS-WITH-NITS items**:
1. Extract `bridge_postpasses.tcl` (~200 LoC out of bridge driver).
2. Extract `tcl_disasm_bridge_json.tcl` (~250 LoC out of bridge driver).
3. Move `_recurse_switch`/`_recurse_try`/`_recurse_generic_bodies`/`_recurse_dict_body` into `recursion_tables.tcl` C-row handlers (driver passes `walk_recursive` callback). Closes §2 module-boundary leak.
4. Add 3 missing tests: (a) always-list invariant on non-host symbols, (b) pragma_* end-to-end (R31 wiring only standalone-tested), (c) dynamic_body tag end-to-end.
5. Tighten CHANGELOG line 51 vs 54-55 contradiction.
6. Add `_TCL_BRIDGE_SCRIPT` existence check + configurable `JCODEMUNCH_TCL_PARSE_TIMEOUT` env var in `extractor.py`.
7. Resolve duplicate/garbled comment block at `opcode_walker.tcl:200-211`.

Plus secondary NITs from T14: extract RECURSION_HANDLERS table parallel to SUBTABLE_C; extract dict-body subcommand list; rename `_src_offset_to_line` → `_tag_unresolved_file_offset`; cryptic `cs`/`ce` shorthand in bridge hot paths; magic 2/3 in `_constructor_dispatch:193-200`.

**Plus PLAN_v2.1 §3 P1.3 deliverables (3-4 days budgeted)**:
- Run on full bluice 5-repo corpus.
- Performance bound: ≤1.5× current bridge wall-clock.
- Cut-over policy decision (hard cut vs side-by-side; old bridge stays shippable through P1.4).
- docs/ reorganization (per memory `docs_reorganization.md`).

---

## File inventory (P1.2 delta on top of P1.1's `efce5c1`)

```
M  CHANGELOG.md                                                (BREAKING CHANGE + schema additions)
M  .gitignore                                                  (.omc/ added)
M  src/jcodemunch_mcp/parser/extractor.py                      (_parse_tcl_native + no-fallback)
M  src/jcodemunch_mcp/parser/imports.py                        (_extract_tcl_imports)
M  src/jcodemunch_mcp/parser/languages.py                      (TCL_SPEC comment refresh)
M  src/jcodemunch_mcp/parser/opcode_walker.tcl                 (P1.1 569 → P1.2 ~1060 LoC, Strategy A rewrite)
M  src/jcodemunch_mcp/parser/symbols.py                        (3 new fields)
M  src/jcodemunch_mcp/storage/index_store.py                   (INDEX_VERSION 9 → 10)
M  src/jcodemunch_mcp/storage/sqlite_store.py                  (_migrate_v9_to_v10)
M  tests/test_branch_indexing.py + test_call_references_model.py + test_file_summaries.py + test_hardening.py  (INDEX_VERSION assertions)
M  tests/test_new_languages_v143.py                            (kind=class → kind=namespace)
M  validation/fixtures/disasm/01-15.test, 18.test              (re-baselined)
M  validation/probes/ensemble_enumeration_probe.tcl            (REFERENCE_ENSEMBLES 9 → 10)
?? src/jcodemunch_mcp/parser/compute_body_base.tcl             (466 LoC)
?? src/jcodemunch_mcp/parser/pragma_scanner.tcl                (117 LoC)
?? src/jcodemunch_mcp/parser/recursion_tables.tcl              (377 LoC)
?? src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl             (1898 LoC)
?? src/jcodemunch_mcp/parser/unresolved_detector.tcl           (192 LoC)
?? tests/test_tcl_parser.py                                    (1294 LoC, 86 tests)
?? validation/fixtures/disasm/19_bracket_inline_if.test
?? validation/fixtures/disasm/20_bracket_inline_specialized.test
?? validation/fixtures/disasm/21_nested_brackets.test
?? validation/fixtures/disasm/22_interior_invoke.test
?? validation/probes/WALKER_CONTRACT_v2_2.md                   (~900 LoC, rev5 contract)
?? validation/probes/p1_2_corpus_recognition_probe.tcl         (~190 LoC, cross-codebase)
?? validation/probes/P1_2_VERDICT.md                           (this file)
?? docs/SPEC_v2.md                                             (1499 LoC; gitignored upstream)
```

Net delta: 32 modified + 13 untracked = 45 files; +3,127 / -2,174 LoC = net +953.

---

## Open questions / scope items for P1.3

1. **Coverage comparison vs old bridge** — deferred to P1.4 per user direction (needs validated oracle for accuracy comparison; raw coverage diff alone is misleading without F1 ground truth).
2. **F1 measurement** — P1.4 deliverable per PLAN_v2.1 §3 P1.4 (4-signal validation + oracle adjudication). Hard gate ≥95%.
3. **Tcl 9.0 reachability** — accepted as UNVERIFIED follow-on per P1.1 verdict; revisit when bluice's RHEL/Tcl modernization timeline firms up.
4. **Q2 callback-method recovery in nested brackets** — fixture 22 covers the simple case; verify no regressions on `after 100 "$obj method [getArg]"` shapes during P1.3 corpus run.
5. **Q4 user-defined `namespace ensemble create -compile 1`** — bluice has none; mechanism via `ensemble_enumeration_probe.tcl` is in place. P1.3 documents how to extend.

---

## Re-run reproducer (full P1.2 verification)

```bash
cd /home/giles/git/jcodemunch-mcp-fork

# P1.0 + P1.1 regression baselines
tclsh validation/probes/body_base_probe.tcl --bluice          # 382/382 + 5/5
python3 validation/golden_set/validate_golden.py              # 92/95 + 3
tclsh validation/probes/ensemble_enumeration_probe.tcl        # 10 ensembles, exit 0

# P1.2 deliverables
tclsh validation/fixtures/disasm/run.tcl                      # 22/22 PASS
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl     # 0 unrecognized / 12,256 events
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl --root /usr/share/tcltk
                                                              # 40 unrecognized / 14,215 events (12 distinct opcodes; P1.3 expansion)

# Full Python suite
uv run --no-project --with pytest --with-editable . pytest tests/ -q   # 3,749 passed, 12 skipped

# Bridge end-to-end smoke
tclsh src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl /home/giles/bluice/BluIceWidgets/Anneal.tcl > /tmp/bridge_smoke.json
jq '.symbols[] | select(.kind=="class") | {name, parent_classes}' /tmp/bridge_smoke.json | head -30
jq '.symbols[] | select(.name=="__script__") | .package_requires' /tmp/bridge_smoke.json
```

All commands exit 0 on the verified configuration (tclsh 8.6.14, bluice corpus at the timestamp of this verdict).

---

## Posture for P1.3

P1.2 leaves a clean substrate:

- The bridge driver is the canonical TCL parser (no fallback).
- Walker handles bluice cleanly (0 unrecognized / 12,256 events) and degrades gracefully on cross-codebase use (40 clean per-event unrecognized counts on `/usr/share/tcltk`).
- Schema v10 is shipped with migration; consumers (`get_class_hierarchy`, `get_dependency_graph`, `find_importers`, `package_registry`) will get richer data on next reindex.
- T14 review surfaced architectural cleanups (recursion-routing leak; LoC overage from JSON + post-passes) that are P1.3 work, not P1.2 blockers.
- Two empirical research items deferred to P1.3: dynamic stack-effect inference + computed_namespace predicate design.

P1.3 picks up:
1. The 7-item cleanup (task #16) — refactor the bridge driver into smaller modules.
2. The dynamic-inference work (task #15) — extend coverage to non-bluice TCL codebases.
3. PLAN_v2.1 §3 P1.3 deliverables — full corpus run + cut-over policy + performance bound.
4. docs/ reorganization (memory `docs_reorganization.md`).
5. Decisions stay with the user. The orchestrator surfaces decision points rather than guessing.

P1.4 (4-signal validation + F1 ≥95% hard gate + coverage comparison vs old bridge) is the next major phase after P1.3.
