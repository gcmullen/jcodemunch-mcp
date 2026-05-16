# Arbiter subagent meta-prompt template

**Version:** v1.0
**Date:** 2026-05-16
**Used by:** `validation/gold_annotations/pipeline/run.py` (phase `post-annotate` — stages arbiter dispatches when a file's discrepancies are non-empty)
**Placeholders:** `{ARBITER_PROMPT_PATH}`, `{OUTPUT_PATH}`, `{N_DISPUTES}`, `{BASENAME}` — substituted verbatim by the pipeline before each Agent dispatch.

After substitution, the body below is the exact text passed as the `prompt` argument to the Agent tool. Arbiters always run with model=opus.

---

You are a Tcl call-graph annotation arbiter. Follow these steps EXACTLY:

1. Read the arbiter prompt file at {ARBITER_PROMPT_PATH}. It contains the complete arbiter instructions, the inlined convention, the source file, A and B raws, and a DISPUTES list ({N_DISPUTES} disputes).
2. For each dispute, decide A_correct / B_correct / both_correct / neither_correct / convention_ambiguous with a one-sentence justification citing the controlling spec section.
3. Produce a single JSON object matching the schema in the arbiter prompt: `{"file": "{BASENAME}", "verdicts": [...], "summary": {...}}`. The verdicts array MUST have exactly the same length as the DISPUTES list ({N_DISPUTES}).
4. CRITICAL: every verdict object MUST include `line` (int, source-relative) — never null. Use the dispute's line number from the input DISPUTES list directly if needed.
5. Emit COMPACT JSON (no extra whitespace beyond single spaces after colons/commas) to stay within the output budget.
6. Write the JSON object to {OUTPUT_PATH} using the Write tool. The file content MUST be a single valid JSON object with no markdown fences, no prose, no preamble. Do NOT include the JSON in your text response.
7. Emit ONLY a short text ack of the form: SAVED: {N_DISPUTES} verdicts → {OUTPUT_PATH}

Constraints:
- Do NOT read any files other than the arbiter prompt path.
- Do NOT include the JSON in your text response — only via the Write tool.
- Do NOT add commentary, explanation, or markdown fences.
