# Gold Arbiter Prompt v1.0 — atomic operation (per-file)

**Status:** DRAFT v1.0
**Date:** 2026-05-15
**Convention pinned:** `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (latest committed).
**Purpose:** When the two annotator outputs (A=Opus, B=Sonnet) disagree on call-edge content for a file, an arbiter agent reads (source file, A raw, B raw, convention, list of disputed callees) and emits per-dispute verdicts with a one-line spec-cited justification. Arbiter is run AFTER both annotators have produced clean (§7/§8) raws and a discrepancy list has been computed by `build_gold.py`.

The arbiter does **not** re-annotate. It picks among the existing annotator outputs and explains why.

---

## Inputs (orchestrator substitutes verbatim into the prompt)

- `{{CONVENTION_DOC}}` — full verbatim text of `TCL_CALLGRAPH_CONVENTION.md`.
- `{{FILENAME}}` — basename of the source file (e.g., `AutoSample.tcl`).
- `{{FILE_CONTENT}}` — verbatim Tcl source.
- `{{A_RAW}}` — verbatim JSON of `<basename>.A.opus.raw.json`.
- `{{B_RAW}}` — verbatim JSON of `<basename>.B.sonnet.raw.json`.
- `{{DISPUTES}}` — JSON array of disputed callee entries computed by `build_gold.py`. Each entry has shape:
  ```json
  {
    "symbol": "<qualified_name>",
    "symbol_kind": "<class|method|...>",
    "name": "<callee-name>",
    "callee_kind": "<static|qualified|...>",
    "line": <int>,
    "source": "A_only | B_only | kind_mismatch | line_drift_>2"
  }
  ```

Caller-side: arbiter agent uses `model = opus` (per user direction), `subagent_type = general-purpose`, `run_in_background = true`.

---

## Output schema (strict)

A single JSON object:

```json
{
  "file": "<basename>",
  "verdicts": [
    {
      "symbol": "<qualified_name>",
      "callee_name": "<name>",
      "callee_kind_A": "<kind from A or null>",
      "callee_kind_B": "<kind from B or null>",
      "line": <int>,
      "verdict": "A_correct" | "B_correct" | "both_correct" | "neither_correct" | "convention_ambiguous",
      "rule_basis": "<spec section, e.g. §5.3, §7.1 Tier 2>",
      "justification": "<one sentence: what the spec says + why this verdict>"
    },
    ...
  ],
  "summary": {
    "n_disputes": <int>,
    "a_correct": <int>,
    "b_correct": <int>,
    "both_correct": <int>,
    "neither_correct": <int>,
    "convention_ambiguous": <int>
  }
}
```

Nothing outside the JSON object. No markdown fences. No prose.

Verdict semantics:
- `A_correct` — A's emission (or non-emission) is the spec-correct call; B's is wrong per the cited rule.
- `B_correct` — mirror.
- `both_correct` — the spec admits both interpretations (e.g. optional ensemble surfacing per §7.5).
- `neither_correct` — both annotators are wrong; neither matches what the spec requires.
- `convention_ambiguous` — the spec text doesn't unambiguously decide. Flag for human review + potential convention tightening.

---

## Prompt template (substitute placeholders and dispatch)

```
You are arbitrating disagreements between two LLM annotators (A=Opus, B=Sonnet) on a single Tcl source file's call-graph annotation. Both annotators applied the convention below; their disagreements are listed in DISPUTES. For each dispute, decide which annotator (if either) correctly applied the convention, and emit a one-line justification citing the controlling spec section.

You do NOT re-annotate. You pick among the existing emissions.

Constraints:
- Do NOT read any files; everything is inlined.
- Output ONLY a single JSON object with the schema given.
- No markdown fences, no prose.
- Justifications must be ONE sentence and cite a section number from the convention (e.g. "§5.3 — receiver is literal qualified, not $var, so §5.2 applies and B's method_dispatch is wrong").
- A verdict of `convention_ambiguous` means the spec genuinely under-specifies this case — use sparingly and only when no section unambiguously decides.

HARD DENYLIST OVERRIDE — apply this FIRST, before any other reasoning. If a disputed callee.name matches any of the following, rule against whichever model emitted it. The verdict is forced; `convention_ambiguous` and `both_correct` are NOT allowed for these cases.
- §7.1 Tier 1 control flow: `if`, `else`, `elseif`, `while`, `for`, `foreach`, `switch`, `catch`, `try`, `on`, `trap`, `finally`, `return`, `break`, `continue`, `yield`, `yieldto`. `rule_basis = "§7.1 Tier 1"`.
- §7.1 Tier 2 utilities: `set`, `incr`, `unset`, `lappend`, `lassign`, `lset`, `lreplace`, `llength`, `lrange`, `lsearch`, `lsort`, `lindex`, `linsert`, `lrepeat`, `lreverse`, `split`, `join`, `format`, `scan`, `expr`, `regexp`, `regsub`, `subst`. `rule_basis = "§7.1 Tier 2"`.
- §7.1 Tier 2 ensembles (2-word phrase whose first word is): `string`, `dict`, `info`, `array`, `clock`, `chan`, `file`, `binary`, `namespace`, `package`, `encoding`. `rule_basis = "§7.1 Tier 2"`. (Tk geometry ensembles `grid`, `pack`, `place`, `wm`, `winfo` and iTcl `delete` are NOT denylisted — see §5.10 carve-out.)
- §7.1 Tier 3 I/O: `puts`, `gets`, `read`, `error`, `throw`. `rule_basis = "§7.1 Tier 3"`.
- §6.9 script-accepting dispatchers: `after`, `bind`, `fileevent`, `trace add variable`, `trace add command`, `trace add execution`, `socket -server`. `rule_basis = "§6.9"`.

For each denylisted callee: if A emitted it and B did not → verdict = "B_correct"; if B emitted it and A did not → verdict = "A_correct"; if both emitted it → verdict = "neither_correct". `justification` cites the denylist rule (e.g. "§7.1 Tier 2 — `lappend` is a pure list utility and must NEVER appear as a callee").

Output schema:
{
  "file": "<basename>",
  "verdicts": [
    {"symbol": "<qn>", "callee_name": "<n>", "callee_kind_A": "<k|null>", "callee_kind_B": "<k|null>", "line": <int>, "verdict": "A_correct|B_correct|both_correct|neither_correct|convention_ambiguous", "rule_basis": "<spec section>", "justification": "<one sentence>"}, ...
  ],
  "summary": {"n_disputes": <int>, "a_correct": <int>, "b_correct": <int>, "both_correct": <int>, "neither_correct": <int>, "convention_ambiguous": <int>}
}

========================================
CONVENTION (apply verbatim):
========================================

{{CONVENTION_DOC}}

========================================
SOURCE FILE (filename: {{FILENAME}}):
========================================

```tcl
{{FILE_CONTENT}}
```

========================================
ANNOTATOR A RAW (Opus):
========================================

{{A_RAW}}

========================================
ANNOTATOR B RAW (Sonnet):
========================================

{{B_RAW}}

========================================
DISPUTES TO ARBITRATE:
========================================

{{DISPUTES}}

Emit the JSON object. Nothing else.
```

---

## Post-processing contract

1. JSON parse. If fences/prose present, orchestrator strips once; if still invalid, REJECT and re-dispatch once.
2. Schema validation: `verdicts` array length equals `len(DISPUTES)`; each entry references a `(symbol, callee_name, line)` triple from DISPUTES; `verdict` is one of the five enum values; `rule_basis` is a non-empty string starting with `§`.
3. Store result as `<basename>.arbiter.json` alongside the existing per-file gold artifacts.
4. The orchestrator MAY use the arbiter's verdicts to build a `<basename>.corrected_gold.json` overlay, but the raw `.A.opus.raw.json` / `.B.sonnet.raw.json` / `.gold.json` artifacts are NEVER mutated.

---

## What this prompt does NOT do

- Re-annotate symbols or callees from scratch.
- Decide on schema/audit violations (those are caught earlier by `audit_check.py`).
- Adjudicate disputes that have no spec rule (those return `convention_ambiguous`; humans decide downstream).

End of spec.
