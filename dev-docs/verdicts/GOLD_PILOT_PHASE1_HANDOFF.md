# GOLD_EXPERIMENT_v1 Phase 1 — Handoff state

**Date:** 2026-05-15
**Branch:** `tcl-disasm-bridge`
**Convention pin:** v1.1 (uncommitted; six clarifications layered on the v1.0 baseline at `a2747c3`)
**Status:** mid-Phase-1, paused for harness rerun on AutoSample. 7 of 8 files have raw annotations; 3 files fully arbitrated.

---

## What's been done

### Convention v1.1 — `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md`
Six clarifications applied (all generic to all Tcl/Tk/iTcl/iTk):
1. §5.1 — bare literal first words inside method bodies are `static`, even for implicit self-dispatch on `$this`.
2. §5.3 — `<METHOD>` placeholder explicit; rule fires ONLY on `$var` receiver; literal qualified names (`::config getStr`) fall under §5.2.
3. §5.8.1 — D1 collapse respects Tier filters; `eval lappend` → no callee (Tier 2).
4. §6.1 — forward-declaration dedup: forward decl + `itcl::body` for same qualified_name → one symbol, body line/end_line canonical.
5. §6.12 — callback recognition is value-shape-driven; vendor flags like `-onClick` qualify when their value matches the pure-callback pattern.
6. §7.1 — Tier 2 ensemble list harmonized with §7.5 (adds `namespace`, `package`, `encoding`).

§4 also tightened: `language` derived from file extension (case-insensitive); `package_requires` and `imports` are arrays of bare strings (only `package_provides` uses `{name, version}`); top-level imports MUST NOT bleed onto enclosing class/namespace symbols.

### Prompt updates
- `dev-docs/specs/GOLD_PROMPT_v1.md` → **v1.1**. Multi-file aware. Inputs take a `{{FILES}}` list; output always wrapped as `{"files": [<annotation>, ...]}`.
- `dev-docs/specs/GOLD_EXPERIMENT_v1.md` → **§6.0 batching rules added**. Files <400 lines and <15 KB can batch up to 4 per agent if combined ≤25 KB.
- `dev-docs/specs/GOLD_ARBITER_PROMPT_v1.md` → **NEW v1.0**. Per-file arbiter agent (Opus) ingests source + A raw + B raw + convention + disputes list, emits per-callee verdict + one-line justification citing a spec section.

### Tools — `validation/gold_annotations/tools/`
- `audit_check.py` — §7/§8 schema + audit-vs-output cross-check.
- `build_gold.py` — merge A+B raws into per-file `.gold.json`, `.discrepancies.json`, `.audit.json` with §10.3 provenance.
- `unwrap.py` — unwrap batched `{"files": [...]}` agent responses; normalize language by extension; coerce `package_requires`/`imports` from objects/string-with-version to bare strings; default-fill missing array fields; drop typo'd audit keys.
- `run_audit.sh` — wrapper around `audit_check.py`.

### Annotation artifacts — `validation/gold_annotations/conv-v1.0/<corpus>/`
6 files have `.A.opus.raw.json` + `.B.sonnet.raw.json` (all audit-clean):
- `bluice-BluIceWidgets/`: BarcodeView, AutoSample (skip — see below), BeamlineAuthView
- `bluice-dhs-tcl/`: ControllerBase, MotorBase
- `bluice-DcsWidgets/`: Component
- `bluice-dcs-lib-tcl/`: DcssHardwareServer
- `bluice-dcss/`: MFX_MOTOR

Per-file `.gold.json` + `.discrepancies.json` + `.audit.json` exist for the batch-1 files (BarcodeView, ControllerBase, MotorBase) and AutoSample (stale — needs rebuild after AutoSample rerun).

### Arbiter verdicts — `<basename>.arbiter.json`
| File | Disputes | A correct | B correct | Notes |
|---|---:|---:|---:|---|
| BarcodeView | 1 | 1 | 0 | §6.12 vendor `-onClick` is a callback per value-shape rule |
| ControllerBase | 2 | 1 | 1 | §5.8.1 Tier-2 filter blocks `eval lappend`; §5.8.2 D3 → unresolved kind |
| MotorBase | 2 | 0 | 2 | §7.1 `namespace current` is Tier 2; §5.1 bare literal in method body is static |
| **Subtotal** | **5** | **2** | **3** | All citations point to v1.1-clarified sections |

---

## Next-session work plan

### Step 1 — re-run AutoSample under v1.1 harness
The existing AutoSample raws were produced under the **compressed v1.0 prompt** that dropped the §5.3 "literal method word" clarification. Opus fell into the `"method"` placeholder trap on ~30 method_dispatch sites, dragging file Jaccard to 0.55. Re-dispatch both annotators using the full canonical v1.1 convention inlined verbatim (no compression), single-file dispatch per the multi-file prompt's `{"files": [annotation]}` 1-element shape.

Source path: `/home/giles/bluice/BluIceWidgets/AutoSample.tcl` (744 lines)
Corpus: `bluice-BluIceWidgets`

### Step 2 — arbitrate the remaining 4 files
For each, build the dispute list from raws (use `python3 -c` snippet or add `tools/disputes.py`), then dispatch the arbiter (Opus, per spec). Expected counts:
- BeamlineAuthView — moderate disputes, mostly `grid`/`pack` coverage differences.
- Component — likely many disputes still after the forward-decl dedup rule; Opus's raw still has 27 duplicate qualified_names that the new convention rule eliminates. Recommend: re-run Component too OR mechanically dedup before arbiter.
- DcssHardwareServer — small (~3 disputes).
- MFX_MOTOR — very small (probably 0–1 dispute).

### Step 3 — build `corrected_gold.json` overlays
For each file with arbiter verdicts, produce `<basename>.corrected_gold.json`: start from raw consensus, apply arbiter verdicts (A_correct → use A's entry; B_correct → B's; both_correct → keep both with marker; neither_correct → drop; convention_ambiguous → flag for human). Add a new tool: `tools/apply_arbiter.py`.

### Step 4 — Phase 1 verdict
Write `dev-docs/verdicts/GOLD_PILOT_PHASE1_VERDICT.md` covering §11 acceptance gates (symbol agreement ≥90%, Jaccard ≥0.85, audit + discrepancies preserved). Include the convention-bug findings the experiment surfaced (each of the six v1.1 edits maps to a real failure caught during the run).

### Step 5 — tooling additions worth doing first
- `tools/save_arbiter.py` — reads JSON from stdin, writes to `<corpus>/<basename>.arbiter.json`. Cuts the verbose Write tool burn per arbiter dispatch.
- `tools/disputes.py <basename>` — prints the dispute list (callee `(name, kind)` divergences) from existing raws, in the schema the arbiter prompt expects. Eliminates ad-hoc Python in Bash.

---

## Known caveats

- The 5 v1.0/early-v1.1 files (BarcodeView, ControllerBase, MotorBase, BeamlineAuthView, Component) were annotated before the v1.1 convention tightening. Their raws are frozen; arbiter verdicts apply v1.1 rules to v1.0-era emissions. The `.corrected_gold.json` overlay is the v1.1 canonical interpretation.
- AutoSample raws should be **regenerated**, not arbitrated — the Opus `"method"` literal trap is a prompt-engineering artifact, not a real annotator disagreement.
- Convention is uncommitted. The `provenance.convention_version` in existing gold files says `"v1.0"` and the `convention_commit` field points at `a2747c3` (v1.0). When committing v1.1, bump the provenance values in rebuild.
- Tools dir is `validation/gold_annotations/tools/` (renamed from `_tools/`).
- All run with `git config` user `gcmullen` and no `Co-Authored-By` trailers per project policy.
