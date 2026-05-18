# Phase 5.4+ — Session handoff

State at handoff (this session closed at the end of Phase 5.3 reindex).
Read this first; everything you need to resume is here or one click away.

---

## Where we are

- **Branch:** `tcl-disasm-bridge`
- **HEAD:** `3181730` (G14 qualified static receiver method-dispatch)
- **Working tree:** clean after 5.3 reindex completes
- **Aggregate strict recall:** `0.8674` (started Phase 5.2a at 0.7187 — +0.148 over the session)
- **Tests:** 256+ pass across the project-memory bundle (231 test_tcl_parser + 19 storage + 3 dsl_walker_skeleton + 2 dsl_impl + new G14 case)

### Per-corpus snapshot

| Corpus | Recall |
|---|---|
| bluice-dcss | 1.000 |
| bluice-dhs-tcl | 0.981 |
| snit | 0.947 |
| BluIceWidgets | 0.938 |
| git-gui | 0.880 |
| **DcsWidgets** | **0.831** (was 0.290 pre-session — +0.54) |
| BWidget | 0.769 |
| dcs-lib-tcl | 0.714 |
| tcllib | 0.706 |
| clay | 0.650 |

### What landed this session (commits in chronological order)

```
bf64003  P5.2a.0  DSL walker skeleton + empty annotations (byte-equal no-op)
5d73e4d  P5.2a.1  Snit class-DSL dispatch (snit/validate.tcl 0.000 → 0.972)
41c18728 P5.2a.2-4 Generic DSL engine + brace-guard + full DSL config
383541c  fix      _append_symbol out_of_line discriminator (0.65 → 0.85; pre-existing bug exposed by 5.2a kind alignment)
097b008  fix      G9 oo::define unresolved-target emits ::oo::define callee
b1d8629  refactor Drop 7 dead SUBTABLE_A rows shadowed by DSL pre-pass
5b038fc  fix      tkwait kept-ensemble subcommands
e1034dd  docs     Reclassify gaps to Phase 5.6/5.7/5.8 sub-phases
3181730  fix      G14 ::global single-segment 2-word qualified + method_dispatch
```

---

## Sub-phase roadmap (per session policy: Phase 6 = sandbox-only)

| Sub-phase | Theme | Status |
|---|---|---|
| **5.4** | Consumer wiring — Lane B downstream tool integration | NOT STARTED — next |
| **5.5** | Verdict + closeout + small architectural cleanups (G2, G11, G12) | NOT STARTED |
| **5.6** | Gold re-arbitration + convention v1.5 + per-pattern bridge fixes (G1, G3, G7, G8, G13, tailcall/uplevel/trace) | NOT STARTED |
| **5.7** | Cross-file orchestration in extractor.py (G5, G10) | NOT STARTED |
| **5.8** | Auto-derive DSL grammar from package bytecode (spike §11) | NOT STARTED |
| Phase 6 | RESERVED — sandbox-needing investigations only | empty |

---

## Hard rules — carry forward, do not violate

1. **No commits without explicit user yes** — propose message, wait for "yes commit"
2. **No Co-Authored-By trailer** on any commit, push, or PR (see `~/.claude/projects/-home-giles-git-jcodemunch-mcp-fork/memory/feedback_no_coauthor.md`)
3. **Gold is source of truth** — bridge tracks gold, never expand bridge without gold-side verification (see `feedback_gold_is_source_of_truth.md`)
4. **Agent delegation discipline** — focused scope, 100% successful or HOLD, ask don't invent, no fallback shims (see `feedback_agent_delegation_discipline.md`)
5. **Spike rule still respected**: SUBTABLE_A in `recursion_tables.tcl` only modified when deleting verified dead code; behavior-changing migrations stay in Phase 5.5
6. **Bridge stays purely static** — no `interp create`, no `exec tclsh`, no `source` of user files; `tcl::unsupported::disassemble script` is the only allowed disassembly entry

---

## 5.4 — Consumer wiring (Lane B)

**Goal:** Make downstream MCP tools consume the new `Symbol.callees` field
(populated by Phase 5.2 + 5.2a + bug fixes) for richer call-graph queries.

**Files to wire:**
- `src/jcodemunch_mcp/tools/plan_refactoring.py`
- `src/jcodemunch_mcp/tools/get_call_hierarchy.py`
- `src/jcodemunch_mcp/tools/_call_graph.py`
- `src/jcodemunch_mcp/tools/get_impact_preview.py`

**Pattern:** TCL-aware branches gated on `symbol.get("callees")` truthiness, with
graceful fallback to the existing `call_references` behavior when `callees` is
empty (cross-language compat: non-TCL languages don't populate `callees`).
Both populated-callees AND empty-fallback paths must be tested.

**Estimated scope:** ~100 LOC across 4 tool files + ~50 LOC test additions.
~1-2 sessions of work.

---

## 5.5 — Verdict + closeout

**Verdict doc:** `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION_v2_1.md` — already
exists as a skeleton with 55 TBD placeholders. Fill in:
- §0 two-pass summary (pre-5.2a 0.7187 → post-5.2a + bug fixes 0.8674)
- §1 headline numbers from `validation/bridge_outputs/conv-v1.3/tcl-8.6/AGGREGATE_v2.json`
- §2 miss breakdown by kind (run a Python script to aggregate from per-file diffs)
- §3 extras breakdown
- §4 per-corpus table (use the snapshot above)
- §5 disposition matrix re-evaluation (cross-reference `PHASE5_2A_GAPS.md`)
- §6 verdict: PASS or HOLD
- §7 recommendation: proceed to 5.6 / hold / etc.
- §8 ledger (sub-step commits)

**Architectural cleanups for 5.5:**
- **G2** — global constructor wire-kind convention (`_apply_a_row:1063` remaps
  constructor/destructor → kind=method; gold expects kind=constructor/destructor
  globally). Touches existing tests — needs explicit re-baseline.
- **G11** — `oo_inline` grammar constructor inconsistency (currently emits
  kind=method to preserve `test_constructor_extracted`; should emit
  kind=constructor like the other DSL grammars once G2 is unblocked).
- **G12** — class-body primitives still in SUBTABLE_A (method, body, configbody,
  constructor, destructor, public/private/protected method, namespace eval).
  Migration requires extending the ANNOTATIONS row format with an 8th column
  `extra_keywords` to preserve `out_of_line` for the dedup fix. See gap entry
  for full requirements.

---

## 5.6 — Gold re-arbitration + convention v1.5 + per-pattern bridge fixes

Owns the convention-ambiguous gaps surfaced by 5.2a measurement:

- **G1** — gold double-emission `::snit` / `::snit::` (audit across corpora)
- **G3** — DcsWidgets callback shapes (mostly closed by dedup fix + G14; residual is per-pattern)
- **G7** — 28 `?` dynamic-dispatch placeholders (gold consistency audit, then bridge fix in `_handle_unresolved`)
- **G8** — `tcl::mathfunc::*` (gold audit + small bridge fix in expr-operand handling)
- **G13** — Pattern B dual-form symbol emission (gold audit — likely annotator quirk)
- **Convention v1.5** — formalize `tailcall TARGET args`, `uplevel SCRIPT`, 1-word `trace info`/`trace remove` callee emission

Most of these need gold-side audit BEFORE bridge changes. Gold-first principle.

---

## 5.7 — Cross-file orchestration

- **G5** — `oo::define ClassA` cross-file: requires extractor.py to pre-scan all corpus files for class declarations, build a registry, pass into per-file bridge invocations
- **G10** — `namespace import` cross-file: same orchestration; tracks bare-alias bindings across the corpus

Both need indexer-level changes in `src/jcodemunch_mcp/parser/extractor.py`,
not in the bridge itself. Could share infrastructure (pre-scan pass that
builds multiple cross-file maps).

---

## 5.8 — Auto-derive DSL grammar (spike §11)

Disassemble package source files (e.g., snit, clay, oo) to infer DSL outer
commands + body grammars automatically. ~340 LOC per spike estimate. Retires
manual ANNOTATIONS over time. Uses existing `tcl::unsupported::disassemble`
on package source — pure static, no sandbox needed.

---

## Verification commands (the runbook)

### Pytest bundle (project-memory standard)

```bash
.venv/bin/pytest tests/test_tcl_parser.py tests/test_storage_jcm_tcl_extensions.py \
    tests/test_call_extraction.py tests/test_call_references_model.py \
    tests/test_call_hierarchy.py tests/test_class_hierarchy.py \
    tests/test_dependency_graph_tcl.py tests/test_find_importers.py \
    tests/test_blast_radius.py -q 2>&1 | tail -5
```

Expected: 524 passed (231 test_tcl_parser + 19 storage + 274 adjacent). Adds
3 for dsl_walker_skeleton + 2 for dsl_impl + 1 for G14 = 530 with the 5.2a tests.

### Lint

```bash
ruff check
```

### Strict-recall re-measurement (~8 seconds)

```bash
.venv/bin/python3 validation/bridge_outputs/tools/run_bridge_on_gold.py 2>&1 | tail -3
.venv/bin/python3 validation/bridge_outputs/tools/bridge_diff_v2.py 2>&1 | tail -5
.venv/bin/python3 -c "
import json
d = json.load(open('validation/bridge_outputs/conv-v1.3/tcl-8.6/AGGREGATE_v2.json'))
print(f'aggregate: recall={d[\"totals\"][\"recall\"]:.4f}')
for k in sorted(d['per_corpus'].keys()):
    v = d['per_corpus'][k]
    print(f'  {k:<55} recall={v[\"recall\"]:.4f} matches={v[\"strict_matches\"]:>4} miss={v[\"strict_miss\"]:>4}')
"
```

Expected post-5.3-reindex: aggregate 0.8674, per-corpus matches the snapshot above.

### p4-validation reindex (Phase 5.3 — done end of this session)

```bash
bash /tmp/p4_reindex_5_3.sh    # ~10-15 min wall time for 39 corpora
```

The script wipes `/home/giles/.code-index/p4-validation/local-*` and rebuilds.
Log at `/tmp/p4_reindex_5_3.log`. Output indices use `jcm_tcl_writer_version=2`
(post-5.1 schema with `Symbol.callees` + `Symbol.args`).

---

## Files to read on entry (in order, ~15 min)

1. **This file** — start here
2. `dev-docs/plans/PHASE5_BRIDGE_ENRICHMENT_SPIKE.md` §7 (work-order), §7.5 (disposition matrix), §11 (Phase 6 deferred)
3. `dev-docs/plans/PHASE5_2A_GAPS.md` — full gap tracker with sub-phase labels
4. `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION_v2_1.md` — verdict skeleton (5.5 work)
5. `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` §5 + §6 + §7 — convention reference
6. `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION_v2.md` — Phase 5.2.X verdict for baseline numbers
7. Project memory: `~/.claude/projects/-home-giles-git-jcodemunch-mcp-fork/memory/MEMORY.md`

---

## Open questions deferred for the next session

1. **Should G2 / G11 land in 5.5 closeout, or as their own sub-step?**
   The constructor-kind global remap touches existing tests; needs explicit
   user yes on the wire-convention change.
2. **Should 5.6 batch all gold-audit work into one pass, or per-gap?**
   The G7/G8/G13 gold audits could share infrastructure (script that surveys
   all 39 corpora for a given pattern).
3. **5.7 cross-file orchestration — extractor.py is the right home, or
   should the bridge wrapper add a pre-scan pass?**
   Architectural decision; lean toward extractor.py since it already owns
   per-file orchestration via `_parse_tcl_native`.

---

End of handoff. Resume with 5.4 unless a different sub-phase is urgent.
