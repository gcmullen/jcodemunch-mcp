# Annotator subagent meta-prompt template

**Version:** v1.0
**Date:** 2026-05-16
**Used by:** `validation/gold_annotations/pipeline/run.py` (phase `prepare`)
**Placeholders:** `{PROMPT_PATH}`, `{OUTPUT_PATH}`, `{N_FILES}` — substituted verbatim by the pipeline before each Agent dispatch.

After substitution, the body below is the exact text passed as the `prompt` argument to the Agent tool. Two annotator dispatches (Opus + Sonnet) per batch receive byte-identical meta-prompts (verified by sha256).

---

You are a Tcl call-graph annotator subagent. Follow these steps EXACTLY:

1. Read the prompt file at {PROMPT_PATH}. It contains the complete annotator instructions, the inlined convention, and a FILES TO ANNOTATE section listing {N_FILES} anonymized Tcl source path(s).
2. Read EACH anonymized source file listed in FILES TO ANNOTATE (Read tool exactly once per listed path). The line numbers returned by the Read tool are 1-indexed source-relative line numbers; use them verbatim in your annotation.
3. Apply the convention from the prompt body verbatim. Produce a single JSON object `{"files": [<annotation>, ...]}` with one annotation per source in input order, matching the schema given in the prompt body (file, language, symbols, file_level, compliance_audit per annotation).
4. CRITICAL emission discipline: every callee object MUST include all three required keys `name` (string), `line` (int, source-relative, 1-indexed), `kind` (string). The optional `note` field MAY follow. Worked example: `{"name": "register", "line": 87, "kind": "method_dispatch"}`. Emitting a callee without `line` (or with `line: null`) is a schema violation that causes rejection.
5. Emit COMPACT JSON (single spaces after colons/commas, no indentation) to stay within the output token budget.
6. Write the JSON object to {OUTPUT_PATH} using the Write tool. The file content MUST be a single valid JSON object with no markdown fences, no prose, no preamble. Do NOT include the JSON in your text response.
7. Emit ONLY a short text ack of the form: SAVED: {N_FILES} annotations → {OUTPUT_PATH}

Constraints:
- Do NOT read any files other than the prompt path and the listed anon source path(s).
- Do NOT include the JSON in your text response — only via the Write tool.
- Do NOT add commentary, explanation, or markdown fences in either the file or the ack.
