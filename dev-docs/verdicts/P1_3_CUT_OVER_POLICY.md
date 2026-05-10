# P1.3 — TCL bridge cut-over policy

**Status:** SETTLED. This document captures the user-decided policy that landed
in the P1.3 bundle (item 12). It is not up for re-litigation pre-P1.4.

## Decision

**Hard cut.** The new bridge (`src/jcodemunch_mcp/parser/tcl_disasm_bridge.tcl`)
is the only TCL parser at runtime. The legacy bridge
(`tcl_parser_bridge.tcl`) lives **only** on the `tcl-native-parser` branch — it
is not in tree on `main` / `tcl-disasm-bridge`, and it is not runtime-reachable
under any code path.

Wired by:

- `src/jcodemunch_mcp/parser/extractor.py::_parse_tcl_native` calls
  `tcl_disasm_bridge.tcl` and only that bridge for the canonical symbol list.
- `_parse_tcl_native` raises `RuntimeError` (with multi-platform install
  instructions) if `tclsh` is missing or the bridge fails. There is no
  graceful fallback. This honours PLAN_v2.1 §0.2 rule 1 (single substrate)
  and the project rule "failures rather than fallbacks".

## Rationale

1. **Single substrate per §0.2 rule 1** — two parsers running in production
   means two probability distributions of bugs to debug, two divergence
   surfaces to maintain, two perf profiles to monitor. The policy enforces
   that there is exactly one canonical TCL parser.
2. **Deterministic behaviour** — runtime fallback would mean callers can't
   reason about which parse output they're getting. Hard cut means the
   answer is always the new bridge.
3. **Coverage evidence** — Strategy A walker hits 100% recognition on:
   - bluice corpus (12,256 events across 822 files)
   - Tcl stdlib (14,187 events across 791 files in `/usr/share/tcltk`)
   - tcllib + iTk + BWidget (covered in the same probe with 0 unrecognized)
   per `validation/probes/p1_2_corpus_recognition_probe.tcl`.
4. **F1 ≥ 95% hard gate at P1.4** — the comprehensive accuracy gate is the
   safety net. If the new bridge can't clear that gate, the cut-over policy
   gets revisited (see "Revisit triggers" below); but until then the cut is
   the operating posture.

## Escape valves (NOT runtime fallbacks)

These are explicit opt-in tools for diagnostics and oracle-building. None of
them runs by default; none of them affects the canonical parse output.

### `JCODEMUNCH_TCL_DUAL_VALIDATE=1`

When set to a truthy value, `_parse_tcl_native` runs the legacy bridge in
parallel after the canonical parse:

1. New bridge produces the canonical symbol list (returned to caller, always).
2. Legacy bridge is materialised once per process via
   `git show tcl-native-parser:src/jcodemunch_mcp/parser/tcl_parser_bridge.tcl`
   to a process-cached temp file under `/tmp/jcm_dual_validate/`.
3. Per-symbol presence/absence + shape divergence is logged to
   `~/.code-index/dual_validate_diffs/<filename>.json`.
4. Legacy-bridge failures are recorded in the diff but **never** crash or
   degrade the canonical path.

This is the oracle-building hook for P1.4 (SPEC_v2 §12.7): turn it on, run
indexing across the bluice corpus + tcllib, then mine the diff JSON for
disagreement cases that need adjudication.

### Re-checkout from `tcl-native-parser`

The legacy bridge can always be fetched ad-hoc with:

```bash
git -C /path/to/jcodemunch-mcp-fork show \
  tcl-native-parser:src/jcodemunch_mcp/parser/tcl_parser_bridge.tcl \
  > /tmp/v1_bridge.tcl
```

Used during perf bench (Stream 1 Deliverable B) and any future ad-hoc
comparison. This does not make the legacy bridge runtime-active.

## Revisit triggers

The cut-over policy gets revisited **only** when one of the following holds:

- **F1 < 95% at P1.4 oracle.** The comprehensive 4-signal validation
  surfaces accuracy below the hard gate. "Revisit" here means:
  defer the cut to a future phase, accept a higher fallback policy, or
  patch the new bridge to clear the gate. It does NOT mean automatically
  reverting to the legacy bridge — the fix path is always "raise the new
  bridge to the gate", not "swap parsers".

The cut-over policy does **NOT** get revisited when:

- A single bug class is reported. P1.4 oracle is the comprehensive measure;
  individual bugs are addressed via patches to the new bridge or its walker.
- Perf bench (Stream 1 Deliverable B) misses its target. Perf is an
  independent gate; a perf miss is documented as a post-P1.4 optimisation
  candidate (subprocess pooling, persistent tclsh worker, etc.) — it does
  not justify keeping two runtime parsers.
- Schema-pop sanity checks (Stream 1 Deliverable A.3) surface anomalies in
  one repo. Anomalies trigger investigation of the bridge's symbol-emission
  logic, not a parser swap.

## Evidence base

This policy rests on:

- **Stream 1 Deliverable A** — `validation/probes/p1_3_corpus_indexes/`
  (per-repo recognition probes + real indexing + schema-pop SQL +
  downstream-tool spot-checks across the 5 bluice repos).
- **Stream 1 Deliverable B** — `dev-docs/verdicts/P1_3_PERF_BENCH.md`
  (parse-only ratio + end-to-end ratio under the two-number policy).
- **P1.3 bundle CRITICAL #0** — `computed_namespace` body recursion fix
  (was the last unrecognised event class; now recognised).
- **Architect verdict** — side-table approach for parent_classes /
  package_requires (CRITICAL #1) chosen over schema migration to keep
  the existing `Symbol` shape stable while still persisting the new fields.
- **Critic verdict** — REVISE → ACCEPT-WITH-RESERVATIONS post-bundle.

## Operating posture for P1.4 entry

- Cut is in effect. Default runtime parser is the new bridge.
- Oracle-building lane uses `JCODEMUNCH_TCL_DUAL_VALIDATE=1` to mine
  divergence cases.
- Perf gate is independent; if missed, a post-P1.4 ticket files
  subprocess-pooling work, but cut stays.
- F1 < 95% at P1.4 oracle is the only condition that re-opens this doc.
