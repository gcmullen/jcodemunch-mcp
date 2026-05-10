# P1.3 closing verdict — TCL bridge rewrite (storage redesign + consumer wire-ups + corpus / perf / cut-over)

**Date**: 2026-05-09
**Branch**: `tcl-disasm-bridge` (continuing from P1.2 at `02646c5`)
**Plan**: `dev-docs/plans/PLAN_v2.1.md §3 P1.3` + `dev-docs/plans/PLAN_v2_2_PATCH.md` (post-architect-revision storage approach + critic-driven bundle)
**Predecessor verdicts**: `BODY_BASE_VERDICT.md` (P1.0); `P1_1_VERDICT.md` (walker spike + 18 fixtures); `ENSEMBLE_VERDICT.md` (R32); `TCL_VERSION_VERDICT.md`; `P1_2_VERDICT.md` (bridge driver + Strategy A walker + recursion tables + body-base + schema additions + 86-test port)

---

## Verdict: **P1.3 ALL DELIVERABLES + ARCHITECT-DRIVEN ADDITIONS MET. READY FOR P1.4.**

P1.3 substantially exceeded its original 3-4-day budget. Architect review of P1.2 surfaced 3 CRITICAL + 4 MAJOR storage-layer findings (the schema additions had been emitted in-memory but never persisted to disk); a P1.3 critic-driven bundle added 12 items (CRITICAL #0 computed_namespace body recursion fix, NIT cleanup); Stream 1 (the original P1.3 plan) ran the full 5-repo corpus + perf bench + cut-over policy; a verifier 5-finding repair closed the loop. All deliverables green; substantive work + verifier follow-ups complete; pytest **3,802 passed**; perf parse-only median **0.758×** (gate ≤1.5× — PASS by 2× margin).

---

## Per-deliverable status

### Stream 2 (Task #16) — T14 NITs cleanup — **DONE.**

7 PASS-WITH-NITS items from the P1.2 T14 review:
- Extracted `bridge_postpasses.tcl` + `tcl_disasm_bridge_json.tcl` from the 1898-LoC bridge driver.
- Moved recursion handlers (`_recurse_switch`/`_recurse_try`/`_recurse_generic_bodies`/`_recurse_dict_body`) into `recursion_tables.tcl` C-row handlers; bridge driver now passes a `walk_recursive` callback.
- Added the 3 missing tests (always-list invariant on non-host symbols; pragma_* end-to-end; dynamic_body tag end-to-end).
- Tightened CHANGELOG line 51 vs 54-55 contradiction.
- Added `_TCL_BRIDGE_SCRIPT` existence check + configurable `JCODEMUNCH_TCL_PARSE_TIMEOUT` env var in `extractor.py`.
- Resolved garbled comment block at `opcode_walker.tcl:200-211`.

### Stream 3 (Task #15) — Dynamic opcodes + `computed_namespace` — **DONE.**

3-tier opcode coverage:
- **Tier 1**: 62 hand-classified rows in walker `STACK_EFFECTS` (dispatch + stack effects).
- **Tier 2**: 129 additional opcodes auto-extracted from stock Tcl 8.6.14 `generic/tclCompile.c` (`tclInstructionTable[]`); loaded lazily on first miss; canonical pop/push counts; no dispatch event emit. Delta-correct, not shape-correct (documented in `WALKER_CONTRACT_v2_2 §3.2` and SPEC_v2 §3.4).
- **Tier 3**: opcode in neither table → `unknown_opcode` boundary recovery. Empty for stock Tcl 8.6 with both tables present.
- Cross-codebase recognition on `/usr/share/tcltk` improved from **39 unrecognized / 14,215 events** (P1.2 baseline) to **0 unrecognized / 14,187 events** after Stream 3.

§13.6 C-2 split (two new invokeReplace dispatch rows fired BEFORE `namespace_eval` first-match-wins):
- **`computed_namespace`** (Shape A) — `namespace eval $var BODY` → `kind=computed_namespace`; consumed by the bridge driver's existing unresolved-family handler. Two new fixtures (`23_computed_namespace.test`, `25_computed_namespace_body_recursion.test`).
- **`ensemble_fqn_rewrite`** (Shape B) — stock ensembles routed via invokeReplace (`::tcl::clock::format`, `::tcl::dict::for`, etc.) → `kind=ensemble`; existing ensemble handler runs unchanged; events carry `bytecode_form=invokeReplace` for audit. Fixture `24_ensemble_fqn_rewrite.test`.

One walker-only orphan vs the Tcl 8.6.14 instruction table: `pushString` (Tier 1 hand-classified `PUSH_LITERAL` over a `string` operand). Documented inline in `opcode_walker.tcl`.

### Critic-driven bundle (12 items) — **DONE.**

Load-bearing item: **CRITICAL #0** — `computed_namespace` body recursion regression fix. Stream 3's `kind=computed_namespace` event was initially routed only through the unresolved-dispatch tagging path in the bridge driver, which silently dropped every proc / method / class / call edge declared inside `namespace eval $var BODY` blocks (a real-world idiom in tcllib's `dns/dns.tcl`, `oo/build.tcl`, etc.). The bundle adds `_handle_computed_namespace_body_recurse` so the body is walked alongside the unresolved tag — both signals are orthogonal and now both fire. Two new fixtures (`25_computed_namespace_body_recursion.test`, `26_namespace_mixing.test`) plus pytest `TestComputedNamespaceBodyRecursion` (2 tests) lock the regression. Bluice was unaffected (corpus probe still 0/12,256) but the gap was visible on `/usr/share/tcltk` once the cross-codebase coverage came online.

### DB side-table redesign (Option C+D, post-architect verdict) — **DONE.**

Architect review found that P1.2's `_migrate_v9_to_v10` was a pure version-stamp; the `_SCHEMA_SQL` column adds never landed; serialization paths (`_symbol_to_row`, `_row_to_symbol_dict`, `_symbol_to_dict`, `_symbol_to_dict_for_delta`) silently dropped both `parent_classes` and `package_requires`; and no round-trip storage test existed to catch the gap. Option C+D shipped:

- **`INDEX_VERSION` returns to 9** (lockstep with upstream). The speculative bump to 10 is reverted; `_migrate_v9_to_v10` deleted; ladder cleaned.
- **`JCM_TCL_INDEX_VERSION = 1`** stored under `meta.jcm_tcl_writer_version` as a separate version axis for fork-extension data.
- **Side-table `jcm_tcl_extensions`** with hybrid typed columns (`parent_classes TEXT`, `package_requires TEXT`, `extras_json TEXT`). Created via per-call `CREATE TABLE IF NOT EXISTS` (mirroring `embedding_store.py`); intentionally NOT in `_SCHEMA_SQL` to avoid the `_initialized_dbs` cache trap.
- **Strict-A load gate** ("failures rather than fallbacks" directive). Any DB without an exact-match stamp is refused with a clear WARNING. Legacy v4→v9 migrations stamp transparently. Branch-delta wire intentionally omits fork-extension data; locked by `test_branch_delta_does_not_carry_fork_extension_data`.
- **Cascade is explicit**: `incremental_save` issues `DELETE FROM jcm_tcl_extensions WHERE symbol_id IN (SELECT id FROM symbols WHERE file IN (…))` ahead of the symbols delete; `PRAGMA foreign_keys` is not set globally.

### Consumer wire-ups (cross-language preservation) — **DONE.**

`tools/_class_helpers.py` holds the dual-path `_get_bases()` dispatch:
- **Tcl** → side-table read.
- **Non-Tcl** (Python / JS / Java / C# / Ruby / Go / Rust) → `_parse_bases` signature regex (the path that has always served those languages).

Three downstream tools wired through:
- **`get_class_hierarchy`** uses `_class_helpers.get_bases` indirectly via the same dispatch formerly inlined as `_get_bases`. Behavior unchanged; helper extraction collapses three duplicate copies into one.
- **`package_registry`** — `extract_package_names` accepts an optional `symbols=` iterable. Tcl handler reads `package_requires` from the synthetic `__script__` symbol (Tcl has no manifest file format); first declared package name picked, multi-package repos surface additional names via existing iteration. `index_folder` passes `symbols=all_symbols` automatically; legacy file-only callers see no behavior change.
- **`find_references`** — new optional `include_descendants=True` flag. When `identifier` names a class symbol, response gains `descendants` + `descendant_count` listing every class S whose `get_bases(S)` chain transitively includes the target. Cross-language: works for Tcl + Python/JS/Java/etc.
- **`get_call_hierarchy`** — when querying a method symbol whose parent is a class C, callers and callees of same-named methods on kin classes (ancestors + descendants of C, walked via `collect_class_kin`) are merged into the result; tagged with `inheritance_via=<kin_class_name>`. `_meta` envelope gains `inheritance_aliases` documenting which kin methods were treated as additional resolution targets.

The MCP wire-level `server.py` does not yet expose the new `find_references(include_descendants=...)` flag; Python tools API is wired end-to-end. Surfacing in JSON-RPC schema is left for a follow-up.

### Stream 1 (corpus + perf + cut-over) — **DONE.**

Original PLAN_v2.1 §3 P1.3 deliverables:

- **Per-repo corpus recognition.** All 5 bluice repos (BluIceWidgets, DcsWidgets, dcs-lib-tcl, dhs-tcl, dcss/scripts) probed individually under `validation/probes/p1_2_corpus_recognition_probe.tcl` — **0 unrecognized events / 12,256 corpus events**. Cross-codebase: **0 unrecognized / 14,187 events** on `/usr/share/tcltk`.
- **Real indexing per repo.** All 5 repos indexed end-to-end via `jcodemunch-mcp index`; no crashes; symbol counts plausible (BluIce 4,592 / 332 classes; DcsWidgets 3,810 / 225; dhs-tcl 1,624 / 178; dcss 4,848 symbols; dcs-lib-tcl 116 / 10).
- **Schema-pop SQL sanity check** (`validation/probes/p1_3_schema_pop_check.py`) — corpus-scale verification of the architect CRITICAL #1 fix. Apples-to-apples coverage near-perfect:
  - parent_classes: BluIce 373/368 (101.4%), DcsWidgets 204/188 (108.5%), dhs-tcl 165/162 (101.9%), dcs-lib-tcl 6/6 (100%), dcss 0/0 (procedural). >100% means bridge correctly captures non-anchored `inherit` inside class bodies that `^inherit` grep misses.
  - package_requires: BluIce 956/967 (98.9%), dcss 83/85 (97.6%), DcsWidgets 290/330 (87.9%), dhs-tcl 37/52 (71.2%), dcs-lib-tcl 17/24 (70.8%). Smaller-repo bands surface a real capture-rate variance for P1.4 follow-up — likely conditional `package require` inside `if`/`catch`/`namespace eval $var` bodies.
- **Downstream-tool spot-checks** (`validation/probes/p1_3_downstream_spotcheck.py`). `get_class_hierarchy` returns plausible ancestors / descendants for top-of-tree iTcl classes (`Dhs::OperationInstance` 66 descendants, `DCS::Component` 16). `package_registry` Tcl handler reads top-5 packages from `__script__.package_requires` (Iwidgets, DCSUtil, Itcl, etc.). No crashes across 4 tools × 5 repos.
- **Performance bench** (`validation/probes/p1_3_perf_bench.py` → `dev-docs/verdicts/P1_3_PERF_BENCH.md`). 36 bluice files stratified small/medium/large, N=5 warm runs per file, first run discarded. Two-number policy: parse-only ratio (new / legacy) ≤ 1.5×, end-to-end ratio ≤ 2.0×. **Verdict: PASS by 2× margin** — parse-only median **0.758×**, end-to-end median **0.766×**. New bridge is FASTER than the legacy bridge on real-world file sizes (medium 0.59×, large 0.54×). Small-bucket median (1.79×) is dominated by subprocess startup tax — structural, not a parsing-logic regression.
- **Cut-over policy** (`dev-docs/verdicts/P1_3_CUT_OVER_POLICY.md`). Decision: **hard cut**. New bridge is the only TCL parser at runtime; legacy bridge lives only on `tcl-native-parser` branch. `JCODEMUNCH_TCL_DUAL_VALIDATE=1` is the diagnostic-only opt-in for P1.4 oracle building. Revisit only triggered by F1 < 95% at P1.4 oracle.

### Perf debugger root-cause fix (mid-Stream-1) — **DONE.**

First bench reported parse-only median **1.533×** (failing the gate by 2%). Profile revealed two issues:
- `byte_to_char` did O(N) forward linear-scan per call over a per-body char→byte map. On 100% ASCII corpora (bluice) the map is identity overhead. Fix: ASCII fast-path via `string is ascii` returns identity mapping; multi-byte path retained with linear scan replaced by binary search for O(log N).
- Stream 2's "extract" of `bridge_postpasses` + `tcl_disasm_bridge_json` was incomplete: helper procs (~322 LoC) defined in BOTH the bridge driver AND the extracted modules; every bridge invocation parsed and re-defined them twice. The dedup (`+210/-532`) added missing `source` directives and removed the duplicates from the bridge driver.

Together: 1.533× → 0.758× on the same bench. JSON output byte-identical pre/post on all three outliers. Remaining outlier `BluIceWidgets/pkgIndex.tcl` at 3.68× is structural (`package ifneeded` inlined script bodies; ~5% of typical bluice files share this shape) — P1.4 follow-up candidate.

### `get_dependency_graph` Tcl wire-up — **DONE.**

Stream 1 spot-check found `get_dependency_graph` returned `{nodes: 1, edges: 0}` for 25/25 sampled Tcl files because Tcl `package require X` is a package-name lookup, not a file-path import. Fixed:
- `get_dependency_graph` now reads the indexed `__script__.package_requires` and emits **virtual `package:NAME` nodes** for each declared package.
- Cross-language base behavior fully preserved — Python / JS / Java / Go / Rust / C# / etc. continue to use unchanged `resolve_specifier` against `index.imports`.
- When `cross_repo=True`, `cross_repo_edges` are emitted with shape `{from, to: "package:NAME", from_repo, to_repo, package_name, cross_repo: True}` matching the existing cross-repo edge schema.
- Known limitation: Tcl `package provide NAME` not yet captured by the bridge, so intra-repo file→file resolution (file A provides X, file B requires X) is deferred. Same-repo `package require` always resolves to a virtual `package:NAME` node today.

### Verifier 5-finding repair — **DONE.**

Five findings surfaced in a final verification pass:
- **Spot-check regen** — re-ran `validation/probes/p1_3_downstream_spotcheck.py` against the corpus indexes after the `get_dependency_graph` fix; results re-baselined.
- **CHANGELOG dedup paragraph** — duplicate "Schema additions wired through to storage" preamble collapsed into a single coherent paragraph.
- **Corrected schema-pop check** — original Stream 1 spot-check was a unit-mismatch error: it compared row count (109 files-with-requires) against grep line count (967 total statements). The corrected check compares entries-summed-from-JSON-arrays against grep, which is the right shape. CHANGELOG entry rewritten with the corrected numbers (`/tmp/p1_3_corpus_indexes/schema_pop_check_v2.json`).
- **CHANGELOG path drift** — stream paragraphs that had pointed at `validation/probes/P1_3_PERF_BENCH.md` updated to `dev-docs/verdicts/P1_3_PERF_BENCH.md` post-reorg (this verdict).
- **Storage-shape clarity** — CHANGELOG `[Unreleased]` "Storage shape" section rewritten to lead with the side-table architecture before mentioning the upstream-lockstep version revert, matching the read order in SPEC_v2 §7.4.

---

## Stable APIs (consumed by future phases)

Bridge entrypoints (Tcl, unchanged from P1.2):
```tcl
::jcm::bridge::bridge_main file_path → JSON string
::jcm::disasm::parser::disassemble_and_parse src → parsed-dict
::jcm::disasm::walker::walk parsed → list[event-dict]
```

Side-table read path (Python, new in P1.3):
```python
storage.sqlite_store.load_jcm_tcl_extension(symbol_id) -> dict | None
storage.sqlite_store.save_jcm_tcl_extension(symbol_id, parent_classes, package_requires, extras_json) -> None
```

Cross-language dispatch (Python, new in P1.3):
```python
tools._class_helpers.get_bases(symbol, index) -> list[str]    # routes Tcl→side-table, others→regex
tools._class_helpers.collect_class_kin(class_symbol, index) -> set[str]  # ancestors ∪ descendants
```

Tcl deps virtual nodes (Python, new in P1.3):
```python
get_dependency_graph(file, ...) -> dict   # Tcl: emits package:NAME virtual nodes; non-Tcl: file→file as before
get_dependency_graph(..., cross_repo=True) -> dict  # cross_repo_edges with package:NAME shape
```

---

## Late P1.3 fixes log

| Fix | Trigger | Location |
|---|---|---|
| `_migrate_v9_to_v10` reverted; INDEX_VERSION 9→10 undone | Architect CRITICAL #1 (storage drop) | `storage/sqlite_store.py` (deleted migration; ladder cleaned) |
| `jcm_tcl_extensions` side-table created per-call | Architect CRITICAL #1 (cache trap) | `storage/sqlite_store.py:_ensure_jcm_tcl_extensions_table` (new) |
| Strict-A load gate added | Architect CRITICAL #2 ("failures-not-fallbacks") | `storage/sqlite_store.py:_check_jcm_tcl_writer_version` |
| Branch-delta no-op test locked | Architect CRITICAL #3 (regression risk) | `tests/test_branch_delta_does_not_carry_fork_extension_data.py` |
| `_class_helpers.get_bases` extracted from `get_class_hierarchy` | Architect MAJOR #4 (3 duplicate copies) | `tools/_class_helpers.py` (new) |
| Cross-language `_parse_bases` preserved | Architect MAJOR #5 (regression risk) | `tools/_class_helpers.py:_get_bases_via_regex` |
| `find_references include_descendants` flag | Architect MAJOR #6 (consumer wire-up) | `tools/find_references.py` |
| `get_call_hierarchy` parent-class kin merging | Architect MAJOR #7 (consumer wire-up) | `tools/get_call_hierarchy.py` |
| `_handle_computed_namespace_body_recurse` | Bundle CRITICAL #0 (regression in tcllib) | `tcl_disasm_bridge.tcl` + 2 new fixtures |
| `byte_to_char` ASCII fast-path + binary search | Perf debugger | `tcl_disasm_bridge.tcl` |
| Bridge driver dedup (helper procs only in extracted modules) | Perf debugger (1.533× → 0.758×) | `tcl_disasm_bridge.tcl` (`+210/-532`) |
| `get_dependency_graph` Tcl wire-up | Stream 1 spot-check (25/25 empty graphs) | `tools/get_dependency_graph.py` (virtual `package:NAME` nodes) |
| Spot-check regen | Verifier 5-finding | `/tmp/p1_3_corpus_indexes/spotcheck_v2.json` |
| CHANGELOG dedup paragraph | Verifier 5-finding | `CHANGELOG.md` |
| Corrected schema-pop check | Verifier 5-finding | `validation/probes/p1_3_schema_pop_check.py` (rewritten); `CHANGELOG.md` |
| CHANGELOG path drift | Verifier 5-finding (post-reorg) | `CHANGELOG.md` (refs → `dev-docs/verdicts/`) |
| Storage-shape clarity | Verifier 5-finding | `CHANGELOG.md` "Storage shape" section |

---

## §13 decisions (carry P1.2 decisions forward; all DECIDED)

| § | Decision | P1.3 state |
|---|---|---|
| 13.2 | (B) `package_requires` only on `__script__` | Wire-omit on non-host; Python view always `[]`. Side-table mirrors. |
| 13.3 | (B) `parent_classes` only on class symbols | Same shape. Side-table mirrors. |
| 13.5 | (A) `var_command` distinct dispatch row at priority 10.5 | Unchanged. |
| 13.6 | (C) `computed_namespace` distinct event kind | C-2 split shipped — Shape A `computed_namespace`, Shape B `ensemble_fqn_rewrite`. |
| 13.7 | (A) one entry per source-form occurrence | Unchanged. |

---

## Gate sweep results (final)

| Gate | Baseline | Result |
|---|---|---|
| `validation/fixtures/disasm/run.tcl` | 22/22 | **26/26 PASS** ✓ (4 new fixtures: 23 computed_namespace, 24 ensemble_fqn_rewrite, 25 computed_namespace body recursion, 26 namespace_mixing) |
| `validation/probes/p1_2_corpus_recognition_probe.tcl --bluice` | 0 unrecognized / 12,256 events | **0 / 12,256** ✓ |
| `validation/probes/p1_2_corpus_recognition_probe.tcl --root /usr/share/tcltk` | 39 unrecognized (P1.2 baseline) | **0 / 14,187** ✓ |
| `validation/probes/opcode_coverage_probe.tcl` | T1 hand-classified only | **T1=62, T2=129, T3=0** ✓ |
| `validation/probes/body_base_probe.tcl --bluice` | 382/382 + 5/5 | 382/382 + 5/5 ✓ |
| `validation/golden_set/validate_golden.py` | 92/95 + 3 | 92/95 + 3 ✓ (P1.0 baseline) |
| `validation/probes/ensemble_enumeration_probe.tcl` | clean (10 ensembles) | clean ✓ |
| Full pytest suite | 3,749 passed (P1.2) | **3,802 passed, 7 skipped, 0 failed** ✓ (delta = 53 new tests across schema-storage + consumer wire-ups + Stream 3 + bundle CRITICAL #0) |
| Bridge end-to-end smoke (Anneal.tcl) | 39 syms + 11 imports + 11 package_requires | unchanged ✓ |
| Perf bench (parse-only median) | gate ≤ 1.5× | **0.758×** ✓ (PASS by 2× margin; 1.533× → 0.758× post-debugger) |
| Perf bench (end-to-end median) | gate ≤ 2.0× | **0.766×** ✓ |

---

## LoC inventory (post-cleanup; bridge driver final LoC)

```
src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl      bridge driver (1898 → ~1480 LoC after Stream 2 extract + perf dedup)
src/jcodemunch_mcp/parser/bridge_postpasses.tcl      ~200 LoC (extracted Stream 2)
src/jcodemunch_mcp/parser/tcl_disasm_bridge_json.tcl ~250 LoC (extracted Stream 2)
src/jcodemunch_mcp/parser/opcode_walker.tcl          ~1060 → ~1100 LoC (Stream 3 dispatch rows)
src/jcodemunch_mcp/parser/recursion_tables.tcl       377 → 414 LoC (RECURSION_HANDLERS table; C-row routing)
src/jcodemunch_mcp/parser/compute_body_base.tcl      466 LoC (unchanged + ASCII fast-path)
src/jcodemunch_mcp/parser/unresolved_detector.tcl    192 LoC (unchanged)
src/jcodemunch_mcp/parser/pragma_scanner.tcl         117 LoC (unchanged)
```

---

## File inventory (delta on top of P1.2 at `02646c5`)

```
M  CHANGELOG.md                                                (storage redesign + Stream 1 + Stream 2 + Stream 3 + bundle + verifier paragraphs)
M  CLAUDE.md                                                  (no-op or minor refresh)
M  src/jcodemunch_mcp/parser/extractor.py                      (RuntimeError + multi-platform install hint; bridge dispatch unchanged)
M  src/jcodemunch_mcp/parser/opcode_walker.tcl                 (Stream 3 dispatch rows; Tier-2 lazy-load wiring)
M  src/jcodemunch_mcp/parser/recursion_tables.tcl              (RECURSION_HANDLERS table; C-row routing per Stream 2)
M  src/jcodemunch_mcp/parser/symbols.py                        (no-op or minor refresh)
M  src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl             (Stream 2 extracts + perf dedup + bundle CRITICAL #0)
M  src/jcodemunch_mcp/server.py                                (no-op or minor refresh; new find_references flag NOT yet exposed)
M  src/jcodemunch_mcp/storage/index_store.py                   (Strict-A load gate)
M  src/jcodemunch_mcp/storage/sqlite_store.py                  (side-table + JCM_TCL_INDEX_VERSION + cascade DELETE; v9→v10 reverted)
M  src/jcodemunch_mcp/tools/find_references.py                 (include_descendants flag)
M  src/jcodemunch_mcp/tools/get_call_hierarchy.py              (parent-class kin merging)
M  src/jcodemunch_mcp/tools/get_class_hierarchy.py             (uses _class_helpers.get_bases)
M  src/jcodemunch_mcp/tools/get_dependency_graph.py            (virtual package:NAME nodes; cross-repo edges)
M  src/jcodemunch_mcp/tools/index_folder.py                    (passes symbols=all_symbols to extract_package_names)
M  src/jcodemunch_mcp/tools/package_registry.py                (Tcl handler in extract_package_names)
M  tests/test_branch_indexing.py + test_call_hierarchy.py + ... (assertions for the new flags + storage shape)
M  validation/probes/p1_3_perf_bench.py                       (output target updated to dev-docs/verdicts/)
M  validation/probes/p1_3_schema_pop_check.py                 (verifier-corrected unit comparison)
M  src/jcodemunch_mcp/parser/{pragma_scanner,unresolved_detector,recursion_tables,opcode_walker,tcl_disasm_bridge}.tcl  (header path refs → dev-docs/verdicts/)

??  src/jcodemunch_mcp/parser/bridge_postpasses.tcl           (Stream 2 extract, ~200 LoC)
??  src/jcodemunch_mcp/parser/tcl_disasm_bridge_json.tcl      (Stream 2 extract, ~250 LoC)
??  src/jcodemunch_mcp/tools/_class_helpers.py                (cross-language dispatch, dual-path get_bases)
??  validation/fixtures/disasm/23_computed_namespace.test
??  validation/fixtures/disasm/24_ensemble_fqn_rewrite.test
??  validation/fixtures/disasm/25_computed_namespace_body_recursion.test
??  validation/fixtures/disasm/26_namespace_mixing.test
??  validation/probes/INSTRUCTION_TABLE_8_6_14.tcl            (auto-extracted Tier 2 table)
??  validation/probes/extract_instruction_table.tcl           (extractor for the above)
??  validation/probes/opcode_coverage_probe.tcl               (T1 vs T2 vs T3 reporting)
??  validation/probes/p1_3_perf_bench.py
??  validation/probes/p1_3_schema_pop_check.py
??  validation/probes/p1_3_downstream_spotcheck.py

D   docs/SPEC_v2.md                                            (moved → dev-docs/specs/SPEC_v2.md)
A   dev-docs/README.md                                         (NEW)
A   dev-docs/specs/SPEC_v2.md                                  (moved + §7 storage layer rewrite)
A   dev-docs/plans/PLAN_v2.1.md                                (moved + §3 P1.3 status update)
A   dev-docs/plans/PLAN_v2_2_PATCH.md                          (moved + §Δ0.2 + M3 strike + side-table redesign note)
A   dev-docs/verdicts/P1_3_VERDICT.md                          (this file)
A   dev-docs/verdicts/P1_3_PERF_BENCH.md                       (moved)
A   dev-docs/verdicts/P1_3_CUT_OVER_POLICY.md                  (moved)
R   validation/probes/{P1_1,P1_2,BODY_BASE,ENSEMBLE,TCL_VERSION,WALKER_CONTRACT_v2_2}.md → dev-docs/verdicts/
```

---

## P1.4 work carried forward

PLAN_v2.1 §3 P1.4 deliverables:

1. **4-signal validation** for each of the 24 oracle files: bridge (1), definition-capture sandbox (2), LLM oracle (3), golden set (4).
2. **F1 ≥ 95% HARD GATE** against the validated oracle.
3. **Per-edge reconciliation rules** per §2.7 R16; disagreement adjudication via dual independent LLM sessions.
4. **Oracle adjudication outputs**: `validated_oracle_<file>.json`, `SPEC_GAPS.md`, `HUMAN_ESCALATIONS.md`.
5. **Phase-2 handoff doc**: catalog of Phase-2 issues surfaced during P1.4 for the next planning round.

Open follow-ups for P1.4:

- Schema-pop variance on smaller repos (87.9% / 71.2% / 70.8% on package_requires in DcsWidgets / dhs-tcl / dcs-lib-tcl) — likely conditional `package require` inside `if`/`catch`/`namespace eval $var` bodies.
- `BluIceWidgets/pkgIndex.tcl` 3.68× perf outlier (`package ifneeded` script bodies inlined; would require disassembler-result caching to address).
- Tcl `package provide NAME` capture (intra-repo file→file resolution currently deferred).
- MCP wire-level surfacing of `find_references(include_descendants=...)` in `server.py` (Python tools API is wired; JSON-RPC schema is not).
- Tcl 9.0 reachability — accepted as UNVERIFIED follow-on per P1.1; revisit when bluice's RHEL/Tcl modernization timeline firms up.

---

## Re-run reproducer (full P1.3 verification)

```bash
cd /home/giles/git/jcodemunch-mcp-fork

# P1.0 + P1.1 + P1.2 regression baselines
tclsh validation/probes/body_base_probe.tcl --bluice                   # 382/382 + 5/5
python3 validation/golden_set/validate_golden.py                       # 92/95 + 3
tclsh validation/probes/ensemble_enumeration_probe.tcl                 # clean

# P1.3 deliverables (walker / bridge / corpus / opcode coverage)
tclsh validation/fixtures/disasm/run.tcl                                # 26/26 PASS
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl               # 0 / 12,256
tclsh validation/probes/p1_2_corpus_recognition_probe.tcl --root /usr/share/tcltk  # 0 / 14,187
tclsh validation/probes/opcode_coverage_probe.tcl                       # T1=62, T2=129, T3=0

# Anneal smoke
tclsh src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl /home/giles/bluice/BluIceWidgets/Anneal.tcl > /tmp/anneal.json
python3 -c "import json; d=json.load(open('/tmp/anneal.json')); print(f'symbols: {len(d.get(\"symbols\", []))}')"

# Full Python suite
uv run --no-project --with pytest --with-editable . pytest tests/ -q   # 3,802 passed

# Stream 1 — corpus + perf + spot-checks
python3 validation/probes/p1_3_perf_bench.py                            # writes dev-docs/verdicts/P1_3_PERF_BENCH.md
python3 validation/probes/p1_3_schema_pop_check.py                      # JSON-array vs grep, per repo
python3 validation/probes/p1_3_downstream_spotcheck.py                  # 4 tools × 5 repos
```

All commands exit 0 on the verified configuration (tclsh 8.6.14, bluice corpus at the timestamp of this verdict).

---

## Posture for P1.4

P1.3 leaves a clean, end-to-end-wired substrate:

- Bridge is the only TCL parser at runtime (hard cut policy); legacy lives only on `tcl-native-parser`.
- Walker handles bluice cleanly (0 unrecognized / 12,256) and degrades gracefully on cross-codebase use (0 unrecognized / 14,187 on `/usr/share/tcltk` after Tier-2 lazy load + computed_namespace + ensemble_fqn_rewrite + bundle CRITICAL #0).
- Side-table storage persists `parent_classes` + `package_requires` end-to-end; Strict-A load gate refuses any DB without an exact-match stamp; cross-language `_parse_bases` preserved in `_class_helpers.py`.
- Three downstream consumers (`get_class_hierarchy`, `package_registry`, `find_references`/`get_call_hierarchy`) read the new fields via the shared dispatch; `get_dependency_graph` emits virtual `package:NAME` nodes.
- Perf bench passes by 2× margin (parse-only median 0.758×; end-to-end median 0.766×) after the debugger fix.

P1.4 picks up:
1. Build the validated oracle across the 24 files (4-signal cross-check).
2. Adjudicate disagreements (dual LLM, per-edge citation).
3. Hit the F1 ≥ 95% hard gate.
4. Catalog Phase-2 issues for the next planning round.
5. Address P1.3 follow-ups (schema-pop variance on smaller repos; pkgIndex.tcl perf outlier; `package provide`; MCP wire-level surface for `include_descendants`).

Cross-language base-code preservation (Python / JS / Java / C# / Ruby / Go / Rust via `_parse_bases` regex) is sacrosanct; the Tcl side-table is purely additive. Any future schema field added to the bridge MUST follow the same dispatch pattern via `_class_helpers.py` to keep the cross-language path intact.
