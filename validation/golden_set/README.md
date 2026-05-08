# Golden set v1 — hand-curated call edges

**Date**: 2026-05-08
**Plan**: `PLAN_v2.1.md §2.7 Signal 4` + `§3 P1.0` + `§5.4`
**Format**: JSONL, one entry per line.

The golden set is the **deterministic gate** for v2.1 bridge correctness
(§2.7): "golden-set miss = bridge bug, no LLM adjudication needed."

## Files

- `edges_v1.jsonl` — 95 hand-curated entries across 8 representative bluice files.
- `validate_golden.py` — diff-driver that runs the current bridge against the golden set and reports captured / missed / `requires_v2_1` per entry.

## Entry schema

```json
{"file": "<path relative to /home/giles/bluice/>",
 "line": <1-indexed source line>,
 "caller_qname": "<bridge qualified_name>",
 "callee_name": "<expected name in call_references>" | null,
 "pattern_kind": "<one of the kinds below>",
 "evidence": "<short literal source citation>",
 "notes": "<optional rationale>",
 "requires_v2_1": true   // optional; current-bridge gap, v2.1 must capture
}
```

For `pattern_kind` starting with `unresolved_`, `callee_name` is `null` and
the validator checks for the matching tag in `unresolved_dispatches`.

## Pattern kinds covered

| pattern_kind | Count | SPEC reference |
|---|--:|---|
| `pattern_a`            | 34 | §2.1 (bare / multi-segment FQN cmd) |
| `pattern_b`            | 22 | §2.2 ($obj method) |
| `pattern_a_fqn_multi`  | 11 | §2.1 (multi-segment FQN proc call) |
| `bind_callback`        | 9 | §2.5 (`bind` last-arg script) |
| `callback`             | 7 | §2.6 (Tk `-flag "$var method"`) |
| `pattern_a2`           | 7 | §2.3 (`::single_segment method`) |
| `unresolved_eval_var`  | 4 | §4.1 |
| `unresolved_var_method`| 1 | §4.4 |

`pattern_a` includes itk_component creation-body recursion sites,
configbody bare proc calls, eval-prefix concat recursion, and bracket
substitution recursion. The 95 entries cumulatively exercise every
captured-pattern row in SPEC §2 plus four of the six unresolved-dispatch
rows in §4.

## Files covered

| File | Entries |
|---|--:|
| `BluIceWidgets/Anneal.tcl` | 21 |
| `BluIceWidgets/Scan3DView.tcl` | 21 |
| `DcsWidgets/BluIceShell.tcl` | 20 |
| `dcs-lib-tcl/main/scripts/DcssHardwareServer.tcl` | 10 |
| `dcs-lib-tcl/main/scripts/DcssHardwareServerConnection.tcl` | 7 |
| `DcsWidgets/AttributeDisplay.tcl` | 7 |
| `dcs-lib-tcl/main/scripts/AsyncGets.tcl` | 5 |
| `BluIceWidgets/BarcodeView.tcl` | 4 |

The eight files were chosen to span: iTcl megawidgets (Anneal,
Scan3DView, BarcodeView), file-scope script + iTcl mix (BluIceShell),
out-of-line `body` definitions and `configbody` (AttributeDisplay), and
plain iTcl utility classes (DcssHardwareServer, AsyncGets,
DcssHardwareServerConnection).

## Validation

```bash
python3 validation/golden_set/validate_golden.py
```

Current run (current bridge @ `tcl-native-parser` baseline):

| Category | Count |
|---|--:|
| Total entries | 95 |
| Currently captured | **92** |
| Currently missed (bridge bugs) | **0** |
| Marked `requires_v2_1` | 3 |

**Current-bridge capture rate excluding `requires_v2_1`: 100.0%.**
**v2.1 must reach 100.0% across all 95 entries** to satisfy P1.4 §6.1
exit gate ("Golden set: 100% bridge capture").

### `requires_v2_1` entries

Three entries are documented current-bridge gaps that v2.1 must close
via the substrate change (§2.4 sub-table B inlines control-flow bodies
into the outer bytecode stream, making `extract_unresolved` recursion
unnecessary):

1. `DcsWidgets/BluIceShell.tcl:132` — `eval $_buildingMsg` inside
   `catch { ... }`. Current `extract_unresolved` only walks top-level
   commands.
2. `dcs-lib-tcl/main/scripts/DcssHardwareServerConnection.tcl:65` —
   `eval $_hardwareNameCallback $this` inside `switch FIRST_MESSAGE` arm.
3. `dcs-lib-tcl/main/scripts/DcssHardwareServerConnection.tcl:108` —
   `$messageHandler $_textMessage $_accumulatedMessage` (var_method)
   inside `switch BINARY` arm.

These are not v2.1 deliverables in the additive sense — the substrate
change captures them automatically. They are listed here so that v2.1
correctness includes them.

## Methodology note

Each entry was produced by reading the source file, identifying a
dispatch site, and recording (file, line, caller, callee, pattern,
evidence). Entries were then run through `validate_golden.py` against
the current bridge; the three `requires_v2_1` flags surfaced organically
from miss reports.

The set is **not exhaustive** — bluice has thousands of call edges. It
is a **deterministic anchor** that v2.1 must satisfy on its way to
broader F1 ≥ 95% against the validated oracle.

## Sizing rationale (PLAN_v2.1 §5.4)

The plan asked for 80–120 edges with ≥10 per major pattern kind. v1
delivers 95 with the major kinds (pattern_a, pattern_b, pattern_a_fqn_multi)
well over 10. `bind_callback` lands at 9 and `callback`/`pattern_a2`
at 7 — these patterns occur less densely in the corpus, and pushing them
to 10 each would risk repetitive shapes from a small number of files.
P1.4 may extend the set if the validated-oracle adjudication surfaces
edge categories the v1 set under-represents.
