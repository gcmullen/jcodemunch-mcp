# Phase 5 Bridge Enrichment — Spike Note

**Status:** PROPOSAL (not yet ratified into a Phase 5 plan)
**Date:** 2026-05-16
**Author context:** generated during Phase 4 P4.2 design, after the bridge-vs-gold diff hit the structural gap below.
**Owner:** TBD (Phase 5 lead)
**Predecessor:** `PHASE4_PLAN.md` — Lane B (refactor-tool consumers) was deferred to Phase 5 with the user-approved Path 1 architecture (additive `Symbol` fields, TCL-only-on-wire). This note enumerates the bridge-side work that has to land alongside Lane B for the data to actually flow.

---

## 1. The structural gap (why this spike exists)

**Convention v1.3 §4.2 callee schema:**
```json
{ "name": "<callee>", "line": <int>, "kind": "static|qualified|ensemble|method_dispatch|callback|lambda|unresolved", "receiver_hint": "<str>", "note": "<str>" }
```

**Current bridge (jcm `Symbol`) shape:**
```python
@dataclass
class Symbol:
    call_references: list[str]              # bare names only
    unresolved_dispatches: list[dict]       # has structure but slightly different field names than §4
```

`call_references` is a flat list of names with no per-call-site:
- `line` — convention requires int, 1-indexed source-relative
- `kind` — convention enumerates 7 kinds (`static | qualified | ensemble | method_dispatch | callback | lambda | unresolved`)
- `receiver_hint` — convention requires on `method_dispatch` (the verbatim `"$obj"` form)
- `note` — optional but recommended on `method_dispatch` and `callback`

**Consequence for Phase 4 P4.2:** the diff was relaxed to **name-only multiset** comparison (per the user-approved 2026-05-16 design decision). `line_drift` classification was dropped; `kind_mismatch` reduced to "gold has kind, bridge has nothing." Precision/recall numbers in `BRIDGE_VS_GOLD_VALIDATION.md` are reported on the relaxed shape and explicitly flag this in their footer.

---

## 2. What the bridge needs to emit for the planned (name, kind, line) diff

The bridge currently runs through `src/jcodemunch_mcp/parser/opcode_walker.tcl` + `tcl_disasm_bridge.tcl` and produces a flat `Symbol` array per file. To deliver the §4-shaped callees, the bridge needs to **emit one structured record per call site** instead of a single name into `call_references`.

### Minimum new emission shape (additive; non-breaking)

Add a new field to the `Symbol` dataclass:

```python
callees: list[dict] = field(default_factory=list)
# Per-call-site structured records (TCL only on the wire; dataclass defaults [] for
# safe consumer access). Each entry:
#   {"name": str, "line": int, "kind": str,
#    "receiver_hint": Optional[str],     # populated on method_dispatch only
#    "note": Optional[str]}              # optional
```

`call_references` stays. **Don't remove it** — it's used by every existing cross-language consumer (`_call_graph.py`, `get_call_hierarchy.py`, etc.). Phase 5 has two delivery options:

| Option | Description | Consumer impact |
|---|---|---|
| **5a — Parallel field, gradual migration** | `Symbol.callees` (new) coexists with `call_references` (old). TCL bridge populates BOTH. New consumers prefer `callees`; old consumers untouched. | Zero breakage; double bookkeeping inside the bridge. ~30 LOC bridge change. |
| **5b — Migrate all consumers** | `Symbol.callees` becomes canonical; `call_references` deprecated then removed across all 13+ tool files. | Larger change; requires cross-language buy-in. ~250 LOC across consumers. |

**Recommendation: ship 5a in Phase 5, defer 5b indefinitely.** Path-1 architecture decision (2026-05-16) accepted additive Symbol fields; this is just the next instance.

### Same precedent already in this branch

The branch already added 3 TCL-specific additive fields to `Symbol` (P1.3 work, committed in `5133c10`):
- `unresolved_dispatches: list[dict]` (per-line, per-dispatch records)
- `parent_classes: list[dict]`
- `package_requires: list[dict]`

Adding `callees: list[dict]` is the same pattern. No architectural objection should land.

---

## 3. Per-kind emission rules (where the bridge must change)

The 7 §4 callee kinds map to bridge code paths. For each, the bridge must determine the kind at walk time:

| Convention kind | Bridge walker context | What to emit |
|---|---|---|
| `static` | First word is literal identifier (Tcl rule [11]) | `name`, `kind: "static"`, `line` (call site) |
| `qualified` | First word contains `::` | `name` (preserve verbatim), `kind: "qualified"`, `line` |
| `ensemble` | First word is documented ensemble (`string`, `dict`, etc.) AND default-keep ensembles like `grid`, `pack`, `wm`, `winfo` — see §5.10 / §7.5 / §7.1 Tier 2 | `name: "<ens> <sub>"`, `kind: "ensemble"`, `line` |
| `method_dispatch` | First word is `$var` or `${var}` substitution | `name: <2nd word>`, `kind: "method_dispatch"`, `line`, `receiver_hint: <verbatim 1st word source form>` |
| `callback` | Inside a script-accepting site (`bind`, `after`, `trace add ...`, `-command` flag, etc.) | `name: <method word from callback prefix>`, `kind: "callback"`, `line` |
| `lambda` | Inside an `apply {args body}` site | `name: <lambda qualified_name>`, `kind: "lambda"`, `line` |
| `unresolved` | First word is `$cmd`, `eval $var`, `apply $fn`, etc. | `name: <"?" or method word if available>`, `kind: "unresolved"`, `line` |

The walker (`src/jcodemunch_mcp/parser/tcl/opcode_walker.tcl`) is the single point where this classification lives.

### Estimated walker change (re-baselined per OMC critic 2026-05-17)

**Earlier draft assumed "the inclusion path is largely a refactor of the existing exclusion path." This is factually wrong.** Per `BRIDGE_VS_GOLD_VALIDATION.md` §8: `method_dispatch` is at ~1% hit rate, `callback` ~3%, 2-word ensembles ~20%. The bridge today emits bare names into `call_references` for the kinds it doesn't recognize at all — there's no existing inclusion logic to refactor; most of this is new code.

**Per-bug breakdown (referencing `BRIDGE_VS_GOLD_VALIDATION.md` §6):**

| P4.3 bug # | Walker addition | LOC |
|---|---|---|
| #1 method_dispatch on `$obj method` | Detect variable-substitution at command position; emit `kind: "method_dispatch"`, `receiver_hint` per §5.3 | ~80 |
| #2 Tier 1/2/3/5 filter pass | New pass in `bridge_postpasses.tcl` reading §7.1 denylist | ~50 |
| #3 Callback emission from §6.9/§6.12 | Recognize `bind`/`after`/`-command`/`trace add` script sites; extract method word from CMDPREFIX | ~40 |
| #4 Qualified-name preservation (`mc` vs `msgcat::mc`) | Token-level fix in `disasm_parser.tcl` to keep `::` qualifications verbatim per §5.2 | ~10 |
| #6 Visibility-prefix recognition | `public`/`private`/`protected` as method modifier (not callee word) | ~10 |
| #8 2-word kept-ensembles | `grid rowconfigure` / `winfo exists` / `wm title` 2-word emission per §5.10 / §7.5 | ~20 |
| #9 Operator exclusion | Don't emit `==` / `&&` / `>` / `ne` / `eq` from expr-bracket operand expressions | ~10 |

**Walker delta total: ~200-220 LOC**, all in `parser/tcl/opcode_walker.tcl` + `parser/tcl/bridge_postpasses.tcl` (existing files; no new files for these bugs).

**Plus:** ~30 LOC in `parser/tcl/disasm_bridge_json.tcl` for the per-call structured-emit shape, ~30 LOC in `parser/extractor.py::_parse_tcl_native` to thread `callees` + `args` through to `Symbol`.

**Total walker + bridge-side emit + extractor threading: ~260-280 LOC** (revised from earlier ~100 estimate; corrected per OMC critic 2026-05-17).

---

## 4. Schema migration (index storage)

`src/jcodemunch_mcp/storage/sqlite_store.py` already serializes `Symbol` as a dict. Adding `callees` to the dict is automatic if the dataclass has the field.

**Use the existing fork-only version axis — DO NOT bump the global `INDEX_VERSION`.** The codebase already has the architect-locked split:

| Axis | Variable | Storage | Bumped when |
|---|---|---|---|
| Upstream-compatible shared schema | `INDEX_VERSION = 9` (`index_store.py`) | Main index tables | Cross-language Symbol shape changes |
| Fork-only TCL extension | **`JCM_TCL_INDEX_VERSION = 1`** (`sqlite_store.py:134`) | `jcm_tcl_extensions` side-table + meta key `jcm_tcl_writer_version` | TCL-only side-table shape changes |

The TCL-specific fields (`callees: list[dict]`, `args: list[str]`) belong on the **fork axis** — they live in the `jcm_tcl_extensions` side-table (the same machinery P1.3 used for `unresolved_dispatches`, `parent_classes`, `package_requires`). Upstream stays bit-compatible; non-TCL languages never see the new fields.

1. **Backward compat:** old indexes (built before Phase 5) have `JCM_TCL_INDEX_VERSION = 1` in the meta key. Consumers MUST default `callees` / `args` to `[]` on absence; the dataclass field defaults handle in-memory access. The side-table SELECT path needs explicit NULL handling for new columns when reading v1-era rows — covered by a backward-compat read test in §7.6.
2. **Version bump:** **`JCM_TCL_INDEX_VERSION = 1 → 2`** in `src/jcodemunch_mcp/storage/sqlite_store.py:134`. Per the existing mismatch logic at `sqlite_store.py:1107-1146`, this forces fresh reindex of every fork-built repo — exactly what we want when the side-table shape changes. (Corrected in P5.0: earlier "all TCL-bearing repos" was inaccurate. `_initialize_jcm_tcl_extensions` stamps `jcm_tcl_writer_version` on every `save_index` and every v4→v9 migration regardless of language, so the Strict-A gate is language-agnostic. `tests/test_storage_jcm_tcl_extensions.py::TestVersionBumpPath::test_non_tcl_index_also_refused_after_bump` locks this.)
3. **Side-table column strategy (REVISED per OMC critic 2026-05-17).** Earlier draft said "mirror the existing `unresolved_dispatches` pattern in the side-table." That was wrong: `unresolved_dispatches` lives on `Symbol` DIRECTLY (`symbols.py:33`), NOT in the side-table. The actual side-table (`jcm_tcl_extensions`) has 3 columns: `parent_classes` (typed), `package_requires` (typed), `extras_json` (escape valve, comment-tagged as "Phase-2 prototype" at `sqlite_store.py:175`).

   **Decision: add typed columns** `callees_json TEXT NULL` + `args_json TEXT NULL` to `jcm_tcl_extensions`. Each holds a JSON-encoded list (list-of-dicts isn't a natural SQLite shape, but typed columns keep them out of `extras_json`'s "prototype escape valve" and allow future migrations to introspect/index each independently).

   **Migration mechanics.** SQLite `ALTER TABLE jcm_tcl_extensions ADD COLUMN callees_json TEXT NULL` + same for `args_json`. SQLite doesn't support `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so use the existing migration pattern at `sqlite_store.py:293` (check `meta.jcm_tcl_writer_version`, conditionally add columns). The `JCM_TCL_INDEX_VERSION 1 → 2` bump triggers fresh reindex of all existing v1 DBs, so the migration only needs to handle the v1 → v2 case once at write time.

~50 LOC total: ~30 in `sqlite_store.py` (DDL + serialize/deserialize for new columns + migration trigger) + ~5 in `symbols.py` (dataclass fields with default `[]`) + ~15 in tests (backward-compat read). **`index_store.py` is NOT touched** — the global `INDEX_VERSION` axis stays at 9.

---

## 5. Consumer wiring (Lane B work)

Per the Path-1 architecture decision, consumers that benefit from per-call structure get TCL-aware branches with graceful fallback:

| Consumer | What v1.3 fields enable |
|---|---|
| `tools/plan_refactoring.py` | Arity-mismatch warnings on rename (uses `Symbol.arity` once added; or `param_count` as proxy). Receiver-clustering on method_dispatch renames (uses `receiver_hint`). |
| `tools/get_call_hierarchy.py` | Filter callers/callees by call-site `kind` (e.g., "only show method_dispatch sites for this method"). |
| `tools/_call_graph.py` | Per-edge `kind` + `line` metadata. |
| `tools/get_impact_preview.py` | Distinguish architectural calls (`static`, `qualified`, `method_dispatch`) from filtered noise (already filtered out, but the kind tag makes intent explicit). |

Each consumer needs ~20-30 LOC of additive logic, gated on `symbol.get("callees")` truthiness (falls back to existing `call_references` behavior when absent).

Total consumer wiring: ~100 LOC across 4 files + ~50 LOC of tests.

---

## 6. Total Phase 5 footprint (revised vs. earlier 110-LOC estimate)

| Area | LOC | Files |
|---|---|---|
| Bridge walker + emit + extractor.py threading | **~280** (re-baselined per OMC critic 2026-05-17; see §3 per-bug breakdown) | `parser/tcl/opcode_walker.tcl`, `parser/tcl/bridge_postpasses.tcl`, `parser/tcl/disasm_bridge_json.tcl`, `parser/tcl/disasm_parser.tcl`, `parser/extractor.py` |
| Symbol + serialization + side-table typed columns | **~50** (was ~20; +30 for migration + backward-compat read) | `symbols.py`, `sqlite_store.py` (typed `callees_json`/`args_json` columns + ALTER migration) |
| Consumer wiring | ~100 | `plan_refactoring.py`, `get_call_hierarchy.py`, `_call_graph.py`, `get_impact_preview.py` |
| **Generic class-DSL walker + per-package config (annotations approach)** | **~160** | **new `parser/tcl/dsl_annotations.tcl` (~50 LOC config for 5 Tcl-dev-maintained DSLs: iTcl, iTk, TclOO, Snit, Clay — Snit/Clay covered by convention v1.5 §5.4.7) + new `parser/tcl/dsl_walker.tcl` (~80 LOC generic walker) + integration in `disasm_bridge.tcl` (~30 LOC)** |
| **Strict-diff v2 tooling** | **~100** (NEW per OMC critic; was missing from prior draft) | new `validation/bridge_outputs/tools/bridge_diff_v2.py` (or `--strict` flag on existing) doing strict `(name, kind, line ±2)` Jaccard |
| **B1 spurious-warning bug fix** | **~30** (NEW; bundled into 5.0 per OMC critic) | `sqlite_store.py:1107-1146` (trace which value `stored_version` reads; reconcile with meta-table) |
| Tests (incl. backward-compat, perf budget, strict-diff, per-bug regression) | **~250** (was ~110; expanded per OMC critic) | new `test_v1_5_callees_schema.py`, `test_dsl_walker.py`, `test_bridge_diff_v2.py`, `test_backward_compat_v1_index.py`; extend `test_call_hierarchy.py`, `test_plan_refactoring.py`, `test_tcl_parser.py` |
| **Total** | **~970 LOC** (rounded to **~700-900 range** acknowledging estimate uncertainty; original ~490 was materially under-baselined per critic) | 11-14 files |

This is **larger than the Lane-B-agent's 110 LOC estimate** because that estimate covered only the consumer wiring half and assumed the bridge already emitted v1.3 fields. The bridge actually has to be enriched too. Phase 5 must own both halves.

---

## 7. Phase 5 work-order proposal

1. **5.0 (gating only — B1 dropped):** confirm `JCM_TCL_INDEX_VERSION` bump path (`1 → 2`) — NOT the global `INDEX_VERSION` (per §4). Tests in `tests/test_storage_jcm_tcl_extensions.py::TestVersionBumpPath` monkeypatch the constant to simulate the post-bump state and lock: (i) a v1-stamped DB is refused, (ii) a freshly saved DB under bumped v2 round-trips, (iii) the gate is language-agnostic (non-TCL DBs are also refused). **Production constant stays at 1**; the actual `1 → 2` bump lands in 5.1 alongside the schema changes that justify it. B1 (spike §10) is closed-not-fixed — see §10 resolution note: warning is not reproducible at HEAD `e89d29c`.
2. **5.1 (schema):** add `Symbol.callees` + `Symbol.args` fields + `jcm_tcl_extensions` side-table typed columns (`callees_json`, `args_json` per §4) + serialization roundtrip + **backward-compat read test for v1-era indexes** + unit tests.
3. **5.2 (walker rules, NO class-DSL handling here):** wire `parser/tcl/opcode_walker.tcl` + `parser/tcl/bridge_postpasses.tcl` to emit `callees` per-call-site records (parallel to `call_references`, not replacing it). Specifically:
   - §7.1 Tier 1/2/3/5 filter pass (new pass in `bridge_postpasses.tcl`)
   - §5.3 method_dispatch emission on `$obj method` patterns
   - §6.9/§6.12 callback emission from script-accepting sites
   - §5.10/§7.5 2-word kept-ensemble emission
   - §5.2 qualified-name preservation (`mc` → `msgcat::mc`)
   - §5.5 visibility-prefix recognition (`public`/`private`/`protected` not callee word)
   - §6.8 operator exclusion (no `==` / `&&` / `>` / `ne` / `eq` from `expr {...}` operands)
   - **EXCLUDES** class-DSL handling — TclOO (`oo::class create`/`oo::define`), iTcl, iTk, Snit, Clay are 5.2a's domain (corrected per OMC critic 2026-05-17; earlier draft over-scoped 5.2 to include `oo::define`).
4. **STAGED GATE between 5.2 and 5.2a (per OMC critic):** after 5.2 lands, run the §7.5 disposition matrix's strict-diff check. **5.2 must achieve recall ≥ 0.65 (~0.39 + bug-1 + bug-2 + bug-3 deltas) on the v2 diff before 5.2a starts.** If 5.2 alone is below 0.65, hold for triage — the walker rules might not be capturing what we expected; investigating before adding DSL handling is cheaper than debugging both layers at once.
5. **5.2a (generic class-DSL walker + annotations — Tcl-dev-maintained packages only):** new modules `parser/tcl/dsl_annotations.tcl` (declarative config) + `parser/tcl/dsl_walker.tcl` (generic walker that consults annotations). 5.2a OWNS **all Tier 4 class-DSL declarations**: iTcl (`itcl::class`/`itcl::widget`/`itcl::extendedclass` + bare aliases via §5.4.2 by-analogy), iTk (`itk_component add` per §5.4.6, `itk_option define` per §6.11 — sister-project to iTcl, separate `package require Itk`), TclOO (`oo::class create` + **`oo::define`/`oo::objdefine` augmenting forms** — fully owned by 5.2a, not 5.2), Snit (`snit::type`/`snit::widget`/`snit::widgetadapter` + bare `type` alias — covered by **convention v1.5 §5.4.7 by-analogy** per P5.0a edit), Clay (`clay::define` — also covered by §5.4.7). 3rd-party DSLs (XOTcl, vendor-specific) explicitly out of scope. Annotations declare each DSL's outer command name(s), aliases, body grammar (which directives produce method/proc/option/variable records), and §4 kind mapping. Closes the 35 gold-only symbols in `validate.tcl` (snit gap) + 16 in `clay.tcl` (`oo::define` augmenting form) + ~3 iTk component symbols. **Auto-derivation of grammar from package bytecode is deferred to Phase 6** — see §11.
6. **5.3 (reindex + strict diff):** (a) **Reindex all 39 corpora into `~/.code-index/p4-validation/` from a clean wipe** (per the established "reindex = wipe + rebuild" practice; user feedback 2026-05-17). The `JCM_TCL_INDEX_VERSION 1 → 2` bump should also trigger this automatically; verify mismatch handling end-to-end. (b) Build/extend `validation/bridge_outputs/tools/bridge_diff_v2.py` (or add `--strict` flag to existing tool) doing strict `(name, kind, line ±2)` Jaccard per the §7.5 disposition matrix. (c) Run v2 diff; surface any unexpected new miss/extra categories to the matrix for explicit FIX/DEFER/ACCEPT decision before Phase 5 closes.
7. **5.4 (consumer wiring — Lane B proper):** `plan_refactoring`, `get_call_hierarchy`, `_call_graph`, `get_impact_preview`. TCL-aware branches gated on `symbol.get("callees")` truthiness (fallback to `call_references` behavior when absent). Tests cover both populated-callees and empty-fallback paths.
8. **5.5 (verdict doc + closeout):** `dev-docs/verdicts/BRIDGE_VS_GOLD_VALIDATION_v2.md` with strict-diff numbers + per-category disposition outcomes from §7.5 matrix. `CHANGELOG.md` + `CLAUDE.md` updates per project maintenance rule #1.

**Estimated wall time:** 7-10 days for a single contributor (was 4-6; revised per OMC critic given walker LOC re-baseline, the staged gate's potential triage delay, and the reindex + strict-diff-tool deltas).

---

## 7.5 Miss-category disposition matrix

Every miss + extra category from `BRIDGE_VS_GOLD_VALIDATION.md` is explicitly dispositioned below — **FIX in named Phase 5 work item**, **DEFER to a later phase with reason**, or **ACCEPT (won't fix, documented)**. This matrix IS the exit criteria. Phase 5 cannot close until every category has been addressed per its disposition.

### Misses (gold has it, bridge doesn't — 1464 total)

| Category | Approx count | Root cause | Disposition | Work item |
|---|---|---|---|---|
| Tk widget `method_dispatch` (`$widget pack/configure/insert/add/tag/grid/conf/config/...`) | ~600 | Bridge walker has no §5.3 method_dispatch emission | **FIX** | 5.2 walker — §5.3 rule |
| Qualified-name shortening (`mc` vs `msgcat::mc`) | ~50 | Bridge drops `::` qualification during tokenization | **FIX** | 5.2 walker — preserve `::` per §5.2 |
| Callback names from §6.9/§6.12 sites (`register`/`cb`/`unregister`/method words from `bind`/`after`/`-command`) | ~150 | Bridge emits dispatcher (`bind`, `after`) and ignores SCRIPT | **FIX** | 5.2 walker — §6.9/§6.12 rules |
| 2-word kept-ensembles (`grid rowconfigure`/`winfo exists`/`wm title`) | ~50 | Bridge emits 1-word `grid`/`winfo`/`wm` instead | **FIX** | 5.2 walker — §5.10/§7.5 |
| Snit symbol declarations (35 gold-only in `validate.tcl`) | 35 | Bridge doesn't recognize `snit::type`/`snit::widget`/`snit::widgetadapter` | **FIX** | 5.2a — Snit annotation entry |
| TclOO `oo::define` augmenting symbols (16 gold-only in `clay.tcl`) | 16 | Bridge sees `oo::class create` but not `oo::define` augmenting form | **FIX** | 5.2a — TclOO annotation (F2 alignment) |
| `itk_initialize` + iTk component bodies | 13 | Bridge doesn't walk `itk_component add NAME { BODY }` | **FIX** | 5.2a — iTk annotation entry |
| Domain method dispatch (`addInput`/`createAttributeFromField`/`updateRegisteredComponents`) | ~80 | Subset of #1; captured by general method_dispatch rule | **FIX** (via 5.2 #1) | 5.2 walker |
| `?` (gold's unresolved placeholder for genuinely dynamic dispatch) | 28 | Bridge can't statically resolve `$cmd $args` patterns; matches gold's own gap | **ACCEPT** (won't fix — fundamentally unresolvable static) | n/a; document in verdict v2 |
| `tcl::mathfunc::*` (math function refs inside `expr {...}`) | small | Convention §6.8 says optional recording | **ACCEPT** (convention says optional) | n/a |
| Misc long-tail patterns (specific names with <10 occurrences each) | ~50 | Likely subsumed by the above structural fixes once they land | **FIX** (expected automatic via 5.2 + 5.2a) | re-evaluate in 5.3 v2 diff |

### Extras (bridge has it, gold doesn't — 686 total)

| Category | Approx count | Root cause | Disposition | Work item |
|---|---|---|---|---|
| §7.1 Tier 2/3 denylist hits (`puts`/`variable`/`global`/`close`/`lsearch`/`split`/`dict set`/...) | 398 | Bridge has no Tier filter pass | **FIX** | 5.2 walker — Tier 1/2/3/5 filter in `bridge_postpasses.tcl` |
| §5.5 visibility prefixes (`public`/`private`/`protected`) | 42 | Bridge treats visibility prefix as callee word | **FIX** | 5.2 walker — recognize visibility modifier |
| §7.1 Tier 5 structural (`inherit`/`namespace export`) | 37 | Bridge emits as callee when it should populate `parent_classes`/structural fields | **FIX** | 5.2 walker — Tier 5 routing |
| 1-word kept-ensemble emission (`winfo`/`wm`/`grid` 1-word forms) | ~50 | Bridge emits dispatcher when 2-word form is convention | **FIX** (paired with miss #4) | 5.2 walker — §5.10 |
| §6.9 dispatchers (`after`/`bind`/`fileevent`/`trace add ...`) as static callees | ~30 | Bridge records dispatcher; convention says SCRIPT's callee only | **FIX** | 5.2 walker — §6.9 (paired with callback emission) |
| `tailcall` as static callee | 4 | Convention doesn't address `tailcall` — defer.tcl ambiguity source | **DEFER** to convention v1.5 (Phase 6 spec track) | n/a Phase 5 |
| 1-word `trace` as callee (NOT `trace add variable/command/execution`) | 8 | Convention §6.9 only denylists `trace add ...`; bare `trace info`/`trace remove` ambiguous | **DEFER** to convention v1.5 (Phase 6 spec track) | n/a Phase 5 |
| Tcl operators (`==`/`&&`/`>`/`ne`/`eq`) as static callees | 25 | Bridge emits from `expr {...}` operand expressions | **FIX** | 5.2 walker — exclude expr-bracket operands |
| `.0` / numeric fragments | 3 | Tokenization bug — emitting operand fragments | **FIX** | 5.2 walker — tokenization fix |
| `clay` as callee (legitimate clay command) | 9 | Possible gold-side under-emission per P4.3 §7 bridge-win candidate #3 | **DEFER** — investigate during 5.3 v2 diff; route gold-side concern to Phase 6 | tagged for 5.3 review |
| `tailcall` / `delete`-class operators | small | Various — convention-silent | **DEFER** (Phase 6 convention v1.5 candidates) | n/a Phase 5 |

### Per-call schema gap

| Category | Disposition | Work item |
|---|---|---|
| Bridge emits `call_references: list[str]` only; gold uses §4 `callees: list[{name,line,kind,receiver_hint?}]` | **FIX** | 5.1 schema — `Symbol.callees` additive field + side-table |
| Bridge has no per-call `line` → wrong-scope attribution inflates apparent miss count by ~50% per P4.3 §10 analysis | **FIX** (via 5.1 + 5.2) | 5.1 schema + 5.2 walker emits per-call line |
| `args` (formal parameter names) absent on Symbol | **FIX** | 5.1 schema — `Symbol.args` additive field |

### Symbol-set divergence

| Category | Count | Disposition | Work item |
|---|---|---|---|
| Gold-only symbols (58 total) | most subsumed by walker/annotation fixes above (snit 35, clay::oo::define 16, iTk components ~3, custom-DSL stragglers ~4) | **FIX** (via 5.2 + 5.2a) | 5.2 + 5.2a |
| Bridge-only symbols (16 total) | 8 in clay (legitimate proc emissions), 5 `__script__` module wrappers (cosmetic), 2 procs inside `namespace eval` that gold annotators missed (bridge wins per P4.3 §7) | **ACCEPT** (bridge correct; gold may need re-arbitration in Phase 6) | document in verdict v2; flag bridge-wins for Phase 6 gold re-arbitration |

### Phase 5 exit criteria (revised)

Phase 5 cannot close until **every** row above has been addressed per its disposition:

- **All FIX rows shipped and tested** with the corresponding work item
- **All DEFER rows have a target phase + tracking entry** (Phase 6 convention v1.5 track for `tailcall`/`trace`/`clay`-as-callee; Phase 6 gold re-arbitration for bridge-wins)
- **All ACCEPT rows documented in verdict v2** with explicit "won't fix" rationale (the 28 `?` unresolveds; `tcl::mathfunc::*`)
- **Strict (name, kind, line ±2) diff in 5.3** must show NO unexpected new categories — if 5.3 surfaces a category not in this matrix, Phase 5 holds for triage before closing
- Per-corpus recall variance must close significantly (from current 1.00→0.19 spread to a target spread ≤0.40), driven by `method_dispatch` + filter fixes

**The matrix IS the contract.** Aggregate recall / precision numbers in v2 verdict become byproducts of executing the FIX list correctly, not negotiated targets.

---

## 7.6 Risk register + missing pieces (per OMC critic 2026-05-17)

The OMC critic review surfaced six items the spike must address during Phase 5 implementation. None are blockers; all should land in 5.0 / 5.1 / 5.4 / 5.5 as appropriate.

### R1 — Backward-compat read test (REQUIRED in 5.1)

Old indexes with `jcm_tcl_writer_version = 1` must load cleanly under the new dataclass + side-table schema. Dataclass field defaults (`callees=[]`, `args=[]`) handle in-memory access; the side-table SELECT path needs explicit NULL handling for `callees_json` / `args_json` when reading v1-era rows. Add a test (`test_backward_compat_v1_index.py`) that constructs a v1-era DB and reads it under v2 code; must return symbols with empty `callees`/`args`, not crash.

### R2 — Performance budget (REQUIRED in 5.5, tracked from 5.2)

P1.3 perf was 0.758× of pre-P1.x baseline (per project memory). Per-call structured-dict emission could inflate per-symbol JSON 5-10×. Phase 5 must stay within **±10% of P1.3 baseline** wall time. After 5.2 + 5.2a land, re-run the 37-file bridge sweep; compare against the 6.0s / 737-symbols baseline from P4.2's run (`validation/bridge_outputs/tools/run_bridge_on_gold.py`). If perf drops > 10%, hold 5.5 closeout for optimization triage.

### R3 — Per-call-site `line` tolerance contract (REQUIRED in 5.2)

Convention §4.2 says "1-indexed line of the call site." Bridge maps via `char_offset_to_line` in `disasm_bridge.tcl:75-82`. The P4.2 strict diff uses `±2` tolerance per `apply_arbiter.py` T2 setting. Phase 5 must verify this tolerance survives — write a test asserting bridge-emitted `line` is within ±2 of gold-recorded line for shared callees in the 37 gold files.

### R4 — Strict-diff v2 tooling ownership (NEW work item in 5.3)

Existing `validation/bridge_outputs/tools/bridge_diff.py` is relaxed-diff (name-only multiset). Phase 5 5.3 needs a v2 variant that does strict `(name, kind, line ±2)` Jaccard. Either: (a) extend `bridge_diff.py` with a `--strict` flag, or (b) write a new `bridge_diff_v2.py`. ~100 LOC delta — already in revised §6 LOC table.

### R5 — Rollback path (REQUIRED before merging 5.2 to main branch)

If 5.2 lands and recall regresses on currently-high-recall corpora (`bluice-dcss` 1.00, `bluice-dhs-tcl` 0.889), how do we roll back without losing other 5.2 work? Recommended:

- Stage 5.2 changes as a sub-branch off `tcl-disasm-bridge`
- Merge to `tcl-disasm-bridge` only after 5.3 v2 diff confirms no per-corpus regression
- The 39-corpus reindex from 5.3 step (a) is the checkpoint — if any procedural corpus drops by > 5 percentage points (e.g., bluice-dcss 1.00 → 0.94), 5.2 holds for triage before merge

### R6 — `CHANGELOG.md` + `CLAUDE.md` updates (REQUIRED in 5.5)

Per project maintenance rule #1 (CLAUDE.md "Maintenance Practices"): "Every PR adding a new tool to `server.py` must simultaneously update README, CLAUDE.md, CHANGELOG, and at least one test." Phase 5 doesn't add server.py tools but DOES change schema and bridge output; 5.5 must:

- Update `CHANGELOG.md` with the next version (likely v1.84.0) summary
- Update `CLAUDE.md` if any new public surface is exposed (CLI flags, env vars, MCP tools) — no new MCP tools currently planned, but verify
- Update CLAUDE.md test-count line (current `3724 passed, 7 skipped`; Phase 5 will add tests)
- Keep `INDEX_VERSION` line accurate (stays at 9; only `JCM_TCL_INDEX_VERSION` changes)

---

## 8. Open questions for Phase 5 kickoff

| ID | Decision | Default |
|---|---|---|
| P5-D1 | Convert `call_references` → derived view of `callees`, or maintain both as independent fields? | **Maintain both** (5a). `call_references` stays as `[c["name"] for c in callees]` for backward compat. |
| P5-D2 | Should `args` (parameter names) also land in Phase 5, or stay deferred? | **Land with 5.1.** Same precedent — additive Symbol field, ~5 LOC, paid off by `plan_refactoring.py` rename-arity checking. |
| P5-D3 | Re-arbitrate any v1.3 gold files where neither_correct verdicts cluster on the new bridge-output shape? | **No** — keep v1.3 gold frozen. Use it as ground truth for the v2 diff; any disagreements about gold itself are Phase 5+ scope. |
| P5-D4 | Migrate cross-language consumers to `callees` (5b path)? | **No.** Stay on 5a indefinitely. TCL-only-on-wire is the established pattern. |

---

## 9. Future-hygiene-pass note — fence the TCL section harder

**Status:** NOT scheduled. Recorded here as a forward-looking option per 2026-05-17 design discussion.

**Motivation:** make upstream-jcm merges materially easier. Today the TCL bridge is a hybrid plugin — pure-`.tcl` files live in `parser/tcl/` (cleaned up 2026-05-17) but several pieces of TCL-specific logic still sit inside files that are otherwise shared cross-language:

- `parser/symbols.py` — `Symbol` dataclass carries 3 TCL-only fields (`unresolved_dispatches`, `parent_classes`, `package_requires`) added in P1.3, and Phase 5 will add 2 more (`callees`, `args`). Each field is defaulted `[]` for non-TCL languages — non-load-bearing but a real merge-friction surface.
- `parser/extractor.py` — `_parse_tcl_native` and its supporting `_TCL_*` helpers live inside the cross-language extractor module.
- `storage/sqlite_store.py` — the `jcm_tcl_extensions` side-table machinery + `JCM_TCL_INDEX_VERSION` constant + read/write helpers live inside the cross-language storage module.
- 6 consumer tools (`find_references.py`, `get_call_hierarchy.py`, `get_class_hierarchy.py`, `get_dependency_graph.py`, `_class_helpers.py`, `package_registry.py`) have P1.3 TCL-aware branches inline alongside cross-language logic.

Every one of these is a potential merge-conflict zone when rebasing on upstream.

### Proposed cleanup (Phase 6 or later)

1. **Strip Symbol of ALL TCL fields.** Move `parent_classes`, `package_requires`, `unresolved_dispatches`, plus Phase-5-added `callees` and `args`, off the `Symbol` dataclass entirely. TCL bridge writes to `jcm_tcl_extensions` side-table directly. Consumers query the side-table when language=tcl. ~100-200 LOC across 6 consumer files.
2. **Extract `_parse_tcl_native` and helpers from `extractor.py`** into a new `parser/tcl/extension.py` (or similar). Cross-language `extractor.py` keeps only the dispatch shim: `if language == "tcl": return tcl_extension.parse(...)`. Side benefit: `parser/tcl/` becomes a single-stop directory for everything TCL.
3. **Extract `jcm_tcl_extensions` machinery from `sqlite_store.py`** into a new `storage/tcl_extension_store.py`. Cross-language `sqlite_store.py` keeps zero TCL references.
4. **Audit & refactor consumer tools** — pull P1.3's TCL branches out of `find_references.py` / `get_call_hierarchy.py` / `get_class_hierarchy.py` / `get_dependency_graph.py` / `_class_helpers.py` / `package_registry.py` into language-dispatched helpers. The shared tool stays cross-language pure; a `tcl_enrichment.py` (or similar) module supplies the TCL-specific augmentation when language=tcl.

### Outcome if shipped

The cross-language source tree becomes 100% upstream-compatible — `symbols.py`, `extractor.py`, `sqlite_store.py`, all 6 consumer tools could merge upstream changes byte-for-byte. All TCL extension logic lives inside `parser/tcl/` + `storage/tcl_extension_store.py` + `tools/tcl_enrichment.py`. Cleaner architecture, painless rebases on upstream's main jcm.

### Cost estimate

~300-450 LOC of refactor across:
- 6 consumer tools (audit + extract TCL branches)
- `extractor.py` (extract `_parse_tcl_native`)
- `sqlite_store.py` (extract side-table machinery)
- `symbols.py` (strip 5 fields)
- New modules: `parser/tcl/extension.py`, `storage/tcl_extension_store.py`, `tools/tcl_enrichment.py`
- Test suite updates (TCL-aware tests get redirected through the new entry points)

Wall time estimate: 2-4 days for a contributor familiar with the codebase. Substantially less than the original Phase 1-3 TCL build-out.

### When to do this

Defer until **after Phase 5 lands the schema enrichment**. Rationale: Phase 5 follows the existing P1.3 pattern (additive Symbol fields + side-table) so its consumer wiring lives alongside P1.3's. Doing the hygiene pass FIRST means migrating Phase 5's work twice. Doing it AFTER means one consolidated migration covering both P1.3 and P5 fields.

Suggested trigger: the first time upstream-jcm makes a substantive change to `Symbol`, `extractor.py`, `sqlite_store.py`, or one of the 6 consumer tools that creates a non-trivial merge conflict. That conflict becomes the forcing function — pay the refactor cost once instead of merge-conflict tax forever.

---

## 10. Known small bugs filed during Phase 4 (not blocking)

### B1 — Spurious `Index version 10 > current 9` warning

**Filed:** 2026-05-17 during Phase 4 closeout.

**Location:** `src/jcodemunch_mcp/storage/sqlite_store.py:1108-1109`.

**Symptom:** When reading certain index DBs (observed on `dcsconfig`, `dcsmsg`, `dcs_tcl_packages`, `dhs`, `dali`, `tcl_clibs`, `auth`, `auth_client`, `autochooch`, `bl831-dhs-tcl`, `diffimage`, `di-tcl`, `imgsrv`, `impdhs`, `logging`, `simdetector`, `simdhs`, `xos` — 18 of the 39 bluice/p4-validation indexes), jcm emits:

```
Index version 10 > current 9 for local/<repo-slug>-<hash>
```

**Evidence the warning is wrong:** direct SQLite probe of the same DBs shows `meta.index_version = '9'` (matches the source `INDEX_VERSION = 9`). The stored value IS correct; only the warning logic is reading the wrong number.

**Hypothesis:** the version-comparison at `sqlite_store.py:1108` may be reading from a different meta key (possibly `jcm_tcl_writer_version`, which is `1`, or some cached `_INDEX_VERSION` that got mutated) and reporting it as `stored_version`. Or there's an off-by-one / wrong-column read.

**Impact:** read still proceeds; data is returned correctly (verified by manual SQLite queries). This is **log noise only**, not data corruption. But it creates confusion during diagnostics (e.g., "are these indexes stale?" when they aren't).

**Cleanup:** ~30 min diagnostic + fix. Trace which value `stored_version` is actually reading at line 1108, reconcile with the meta-table contents. Add a regression test that exercises both axes.

**Priority:** **Bundled into Phase 5.0 gating** per OMC critic review 2026-05-17. Same code path (`sqlite_store.py:1107-1146`) is being touched by the `JCM_TCL_INDEX_VERSION 1 → 2` bump in 5.0, so fixing the warning at the same time avoids two passes. ~30 LOC fix included in revised §6 total.

### Resolution (P5.0 — closed, not fixed)

**Date:** 2026-05-17 (Phase 5 entry).
**Verdict:** the warning is **not reproducible at HEAD `e89d29c`** and there is nothing to fix in code.

**Evidence collected during 5.0 investigation:**
- Direct SQLite probe of all 18 originally-listed affected DBs (`dcsconfig`, `dcsmsg`, `bl831-dhs-tcl`, `clay`, `BluIceWidgets`, et al.) shows `meta.index_version = '9'` and `meta.jcm_tcl_writer_version = '1'` — both fields are correct.
- Scripted `SQLiteIndexStore.load_index(owner, name)` across all 39 P4.1 indexes returns `39/39` successfully with **zero warnings** logged.
- The only warning site is `sqlite_store.py:1109`; the comparison `stored_version (9) > _INDEX_VERSION (9)` is `False`, so the warning correctly never fires.
- Validation tooling under `validation/bridge_outputs/tools/` does not reference the warning string.

**Likely root cause of the original report:** during a brief P1.2 window, `INDEX_VERSION` was temporarily bumped `9 → 10` (commit `02646c5`) and reverted back to `9` in P1.3 (commit `5133c10`). DBs written during that window would have been stamped `meta.index_version = '10'` and legitimately triggered the warning under post-revert code. The P4.1 reindex on 2026-05-16 wiped `~/.code-index/p4-validation/` and rebuilt every DB under post-revert code, which incidentally cleared the affected DBs without the spike noting that the bug had thereby been resolved.

**Action:** none in 5.0. The B1 bundling clause in §7 step 1 has been dropped accordingly. If the warning ever resurfaces against a real DB, file a new B-numbered bug.

---

## 11. Phase 6 candidate — auto-derive DSL grammar from package bytecode

**Status:** RESEARCH IDEA, not Phase 5 scope.
**Date filed:** 2026-05-17.

### Goal

Eliminate manual DSL annotations by deriving body grammar automatically from each package's source bytecode. The bridge already uses `tcl::unsupported::disassemble script` (pure static, no execution, no sandbox) on user code — extending this to package source files lets us derive DSL grammar from the macro's dispatch logic itself.

### Mechanism (sketch)

When the bridge encounters `package require Foo`:
1. Resolve Foo's source path via `auto_path` / `TCLLIBPATH`
2. Run the existing `disassemble_and_parse` pipeline on Foo's source (no new bridge code)
3. Identify which procs are DSL-outer-commands by their bytecode signature: `proc dsl::cmd {name body} { foreach over $body tokens, switch on first word, dispatch }`
4. Extract the switch case literals (these ARE the directive names: `method`, `option`, `variable`, etc.) from the bytecode constant pool
5. Inspect each branch's bytecode to derive what each directive produces (a `proc` opcode → method symbol, an assignment → variable, etc.)
6. Cache the derived grammar in `jcm_tcl_extensions` side-table per (package, version)

### What works and doesn't

| Pattern | Auto-derivable? |
|---|---|
| Standard `foreach + switch` macro dispatch (snit, clay, most tcllib DSLs) | YES |
| Multi-level dispatch (`snit::macro` indirection) | Hard but tractable with chain-following |
| Regex-based body parsing (`regexp` to split body) | NO — directive list encoded in regex |
| `interp alias` dispatch set up at runtime | NO — dispatch wiring isn't in static bytecode |
| C extensions (iTcl, TclOO) | NO — no Tcl source; manual annotation remains |

For real-world Tcl ecosystem (tcllib pure-Tcl DSLs + vendor DSLs that follow the standard macro idiom), this approach is high-coverage. Exotic DSLs degrade gracefully to opaque-command treatment.

### Phase 6 cost estimate

- Package-path resolver (`auto_path` / `TCLLIBPATH` lookup): ~30 LOC
- Index packages using existing bridge: ~20 LOC orchestration, zero new parsing code
- Bytecode-pattern recognizer for macro dispatch: ~100 LOC (this is the new work)
- Grammar derivation logic (switch case extraction, branch-effect classification): ~80 LOC
- Cache layer in `jcm_tcl_extensions`: ~30 LOC
- Tests including pathological DSLs: ~80 LOC
- **Total: ~340 LOC** to fully replace Phase 5's manual annotation with auto-derivation

### Why deferred to Phase 6 (not Phase 5)

Phase 5 needs to ship the schema + bridge enrichment first. The manual annotation path (4 Tcl-dev-maintained DSLs, ~40 LOC of config) is small, bounded, and ships fast. Auto-derivation is a substantial research project (~340 LOC including pattern detection). Once Phase 5 lands and the strict P4.2 v2 diff numbers exist, we can prioritize auto-derivation against other Phase 6 items.

**Phase 5 keeps the manual annotations for the 4 known DSLs.**
**Phase 6 attempts to auto-derive grammar from package bytecode, retiring the annotations over time.**
**Annotations for C extensions (iTcl, TclOO) stay manual forever — no Tcl source to disassemble.**

### Open Phase 6 question

If auto-derivation lands, does the convention v1.x ever need to formalize the macro-dispatch idiom as a documented pattern? Probably not — the convention is about gold annotation semantics, not bridge implementation. But it's worth noting that Phase 6 success ratifies the convention's §5.4.2 by-analogy stance.

---

End of spike.
