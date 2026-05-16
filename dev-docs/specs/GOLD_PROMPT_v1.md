# Gold Annotation Prompt v1.3 — atomic operation (batched anonymized-source-read + expanded audit)

**Status:** DRAFT v1.3
**Date:** 2026-05-15
**Changelog from v1.2:** Expanded the REQUIRED COMPLIANCE AUDIT block from six to nine sections by adding three forcing-function lists targeting the most common annotator drift seen in batch-1/v1.2 dispatches:
  - `tier1_keyword_appearances` — every occurrence of a §7.1 Tier 1 control-flow keyword (`catch`, `try`, `on`, `trap`, `finally`, `yield`, `yieldto`) the annotator chose NOT to record as a callee. Forces awareness; downstream `audit_check.py` cross-checks against callees to catch annotators that emit `catch` as a static call.
  - `tier2_ensemble_appearances` — every occurrence of a documented ensemble (`string`, `dict`, `info`, `array`, `chan`, `file`, `clock`, `namespace`, `package`, `binary`, `encoding`) subcommand the annotator filtered per §7.1 Tier 2 / §7.5 default. Catches `dict get`/`array names` emitted as ensemble callees.
  - `script_accepting_sites_seen` — every §6.9 script-accepting command (`after`, `bind`, `fileevent`, `trace add ...`) with the SCRIPT form classification and the recorded callee. Catches `after MS SCRIPT` mistakenly recorded with the dispatcher (`after`) as a static callee instead of the SCRIPT's callee.
The three new sections are OPTIONAL on raws produced under v1.2 (silently OK if missing); they are REQUIRED on v1.3+ dispatches. `audit_check.py` validates shape if present and runs the cross-checks above.
**Changelog from v1.1:** Source content is no longer inlined in the agent's prompt. Instead, the orchestrator copies each source file to an anonymized `/tmp/gold_sources/<basename>` path and the prompt instructs the agent to `Read` each anonymized path. Convention text is still inlined into the prompt verbatim (one copy per dispatch). This eliminates the inline-size cliff (large source files no longer balloon the prompt body) and produces source-relative line numbers (Read of the actual source file is 1-indexed from line 1 of the file). The "no file reads by the subagent" rule in v1.0/v1.1 is relaxed to "exactly N anonymized Reads, one per file in the batch"; path strings carry no project-origin information. Multi-turn dispatch was explored and rejected pending `SendMessage` tool availability in the runtime.
**Changelog from v1.0:** Generalized to accept 1+ Tcl source files per dispatch. Output is wrapped as `{"files": [<annotation>, ...]}` (single-file dispatches return a 1-element array). Orchestrator unwraps and stores each annotation as `<basename>.A.opus.raw.json` / `<basename>.B.sonnet.raw.json`.
**Convention pinned:** `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (latest committed v1.1).
**Purpose:** Parametric prompt that produces one annotator's JSON annotation(s) + compliance_audit(s) for one or more Tcl source files. Reusable atomic unit; invoked twice per batch (Opus + Sonnet) by the orchestrator (`GOLD_EXPERIMENT_v1.md`).

---

## Inputs

- `{{CONVENTION_DOC}}` — full verbatim text of `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (read once, cached, inlined into every dispatch).
- `{{FILES}}` — ordered list of `{basename, anon_path}` pairs. `basename` is the source file's basename (e.g., `AutoSample.tcl`); `anon_path` is a path of the form `/tmp/gold_sources/<basename>` where the orchestrator has copied the file's content. NO project-origin path is ever surfaced to the agent.
- `{{MODEL_ALIAS}}` — caller-side parameter for the Agent tool's `model` param (`opus` or `sonnet`). Not substituted into the prompt body.

## Output

A single JSON object with this shape:

```json
{
  "files": [
    {
      "file": "<basename>",
      "language": "tcl" | "itcl" | "tk" | "itk",
      "symbols": [<symbol>, ...],
      "file_level": {"package_requires": [...], "package_provides": [...], "imports": [...], "callees": [...]},
      "compliance_audit": { /* six audit sections */ }
    },
    ...
  ]
}
```

The `files` array has one entry per input file in input order. Single-file batches have exactly one element. Nothing outside the JSON object. No markdown fences. No prose.

---

## Prompt template (orchestrator substitutes placeholders verbatim and dispatches)

```
You are a Tcl call-graph annotator. Read EACH anonymized Tcl source file listed under FILES TO ANNOTATE, apply the convention below verbatim, and emit a single JSON object {"files": [<annotation>, ...]} with one annotation per file PLUS a structured compliance_audit block per annotation that proves you applied each rule.

Constraints:
- The ONLY files you may read are the anonymized source paths listed under FILES TO ANNOTATE. Use the Read tool exactly once per listed path. Do NOT read any other file (not the convention, not any project file, not any system file).
- Do NOT write any files.
- Do NOT use external tools or web fetches.
- Output ONLY a single JSON object {"files": [...]} — no markdown fences, no prose, no preamble, no trailing commentary.
- The "files" array order matches the input order.

Schema clarifications (enforced; deviations cause rejection):
- symbols is a FLAT array; do not nest child symbols inside a parent. Each symbol stands alone with qualified_name carrying the hierarchy. No "children" arrays.
- Each symbol carries exactly these keys: qualified_name, line, end_line, kind, visibility, parent_classes, package_requires, package_provides, imports, callees, unresolved_dispatches. Do NOT add fields like name, parent, signature, docstring, decorators.
- package_provides MUST be an array of objects {name, version} (version may be null). NEVER a list of strings.
- visibility MUST be JSON null (not the string "null") when absent.
- language is determined by the file's extension (case-insensitive): .tcl→tcl, .itcl→itcl, .tk→tk, .itk→itk.
- compliance_audit MUST include all six sections below, each as an array (possibly empty).
- All line numbers MUST be source-relative — i.e., the line numbers returned by the Read tool when reading the anonymized source path. The Read tool returns content prefixed with line numbers; those line numbers ARE the source file's line numbers and you should use them verbatim in your annotation's `line` / `end_line` / audit-line fields.
- Each callee object MUST include `name` (string), `line` (int, source-relative, 1-indexed), `kind` (one of `static|qualified|ensemble|method_dispatch|callback|lambda|unresolved`). When `kind == "method_dispatch"`, MUST also include `receiver_hint` (string) — the verbatim source-form of the receiver expression (e.g. `"$obj"`, `"${obj}"`, `"$itk_component(eu)"`). The optional `note` field MAY follow. Worked example: `{"name": "register", "line": 87, "kind": "method_dispatch", "receiver_hint": "$obj", "note": "$obj register"}`. Emitting a callee without the `line` field, or with `line: null`, is a schema violation that causes rejection. Every call site has a source line — use the Read tool's line-prefixed output to record it verbatim. Do not omit `line` even for callback or unresolved kinds. `receiver_hint` is required on `method_dispatch` only; absent/empty on all other kinds.
- Top-level object MUST include `schema_version: "1.3"` (convention v1.3).
- The top-level `file` field MUST be the basename only, never a path.
- Each symbol MUST include `args` (list of formal-parameter names from the declaration, drop default braces) and `arity` (`len(args)`) on callable kinds (`proc`, `method`, `class_method`, `constructor`, `lambda`). Emit `args: [], arity: 0` for `class`, `namespace`, `destructor`, `coroutine`, `configbody`. Variadic procs with a final `args` parameter include `"args"` in the list and count it in `arity`.

Hard denylist — these names MUST NEVER appear in `callees[].name` (each is filtered by §7.1 or §6.9; recording any of them is grounds for rejection):
- §7.1 Tier 1 control flow: `if`, `else`, `elseif`, `while`, `for`, `foreach`, `lmap`, `time`, `switch`, `catch`, `try`, `on`, `trap`, `finally`, `return`, `break`, `continue`, `yield`, `yieldto`. Walk the body; do NOT record the keyword.
- §7.1 Tier 2 utilities: `set`, `incr`, `unset`, `lappend`, `lassign`, `lset`, `lreplace`, `llength`, `lrange`, `lsearch`, `lsort`, `lindex`, `linsert`, `lrepeat`, `lreverse`, `list`, `split`, `join`, `format`, `scan`, `expr`, `regexp`, `regsub`, `subst`, `concat`, `eof`, `seek`, `tell`, `flush`, `global`, `variable`. Pure data ops + variable-scope binding.
- §7.1 Tier 2 ensemble prefixes (any 2-word phrase starting with these): `string`, `dict`, `info`, `array`, `clock`, `chan`, `file`, `binary`, `namespace`, `package`, `encoding`. (Tk geometry ensembles `grid`, `pack`, `place`, `wm`, `winfo` and iTcl `delete` are NOT on this denylist — see §5.10 carve-out; record them as 2-word static callees.)
- §7.1 Tier 3 I/O + event-loop: `puts`, `gets`, `read`, `open`, `close`, `update`, `vwait`, `error`, `throw`.
- §6.9 script-accepting dispatchers: `after`, `bind`, `fileevent`, `trace add variable`, `trace add command`, `trace add execution`, `socket -server`. Record the SCRIPT's callee per §6.12, NOT the dispatcher.

`itk_component add NAME { BODY }` reminder (§5.4.6): the BODY is a creation script that IS walked for inner callees, attributed to the enclosing method (typically the constructor). Every widget-creation command inside that body (`DCS::CassetteBarcodeView`, `iwidgets::labeledframe`, `button`, `frame`, `label`, …) is a real `static` or `qualified` callee per §5.1 / §5.2 and MUST appear in the enclosing constructor's callees list. Callback-flag values inside the same body follow §6.12. Skipping the walk is a recurring annotator error.

## REQUIRED COMPLIANCE AUDIT (after symbols and file_level on every annotation):

{
  "method_declarations": [
    {"line": <int>, "source_form": "public method|private method|protected method|method|proc|constructor|destructor|itcl::body|itcl::configbody",
     "context": "inside_class|top_level|inside_namespace_eval",
     "kind_recorded": "method|class_method|constructor|destructor|proc|configbody",
     "visibility_recorded": "public|private|protected|null",
     "spec_basis": "§5.5|§6.1|§6.2"}
  ],
  "flag_options_seen": [
    {"line": <int>, "flag": "-<name>", "value_form": "pure_callback_pattern|multi_command_script|variable_bound|bracket_substituted|data_value_not_callback",
     "decision": "recorded as callback callee|unresolved+subkind callback_var|walked bracket|NOT recorded (data value)",
     "spec_basis": "§6.12"}
  ],
  "tier3_keyword_appearances": [
    {"line": <int>, "keyword": "puts|gets|read|error|throw", "decision": "EXCLUDED from callees per §7.1 Tier 3"}
  ],
  "eval_sites_seen": [
    {"line": <int>, "first_word_form": "literal|variable|bracket|eval_obj_method",
     "decision": "D1 collapse|D3 unresolved+eval_var entry|D3 unresolved+eval_brackets entry",
     "callee_recorded": "<name or '?'>",
     "spec_basis": "§5.8.1 D1|§5.8.2 D3|§5.8.3"}
  ],
  "inherit_or_superclass_lines": [
    {"line": <int>, "parent_class": "<name>", "added_to_parent_classes": true, "NOT_added_to_callees": true, "spec_basis": "§5.6 Tier 5"}
  ],
  "package_lines": [
    {"line": <int>, "command": "package require|package provide|source", "value": "<verbatim>", "field_populated": "package_requires|package_provides|imports", "spec_basis": "§5.7 Tier 5"}
  ]
}

Enumerate EVERY occurrence per file. Empty list means none found for that file. A downstream script will cross-check your audit against your callees for contradictions.

========================================
CONVENTION (apply verbatim to every file you annotate):
========================================

__CONVENTION_DOC__

========================================
FILES TO ANNOTATE (read each anonymized path; one annotation per file in `files`):
========================================

__FILES_LIST__

Emit the wrapping JSON object `{"files": [<annotation>, <annotation>, ...]}` with one annotation per input file, each containing file, language, symbols, file_level, AND compliance_audit. Nothing else.
```

The `__FILES_LIST__` placeholder expands to one line per file in order:

```
- basename: <basename>
  anon_path: <anon_path>
```

Each file's `file` field in the output uses the basename (NOT the anon path).

---

## Caller-side dispatch (orchestrator workflow)

For each annotator (Opus + Sonnet, dispatched in parallel):

1. **Stage source files.** For each `(basename, source_path)` in the batch, copy `source_path → /tmp/gold_sources/<basename>` (orchestrator-side, atomic copy). Skip if the target already exists with identical content (shared across A and B dispatches in the same batch).
2. **Build the prompt** via `tools/build_prompt.py --mode full --convention <path> --anon-source <basename>:<anon_path> [--anon-source ...] --out <prompt-path>`. The builder inlines the convention text and lists the anon paths in the FILES TO ANNOTATE section.
3. **Dispatch** via Agent tool: `subagent_type=general-purpose`, `model=opus|sonnet`, `run_in_background=true`, `prompt=<verbatim prompt body>`.
4. **Wait** for both annotators to complete. Each returns a single `{"files":[...]}` JSON object.
5. **Pass to `tools/unwrap.py`** — it extracts each `files[i]` and writes `<basename>.A.opus.raw.json` / `<basename>.B.sonnet.raw.json`.
6. **Cleanup.** After both A and B raws are persisted and audit-clean, remove `/tmp/gold_sources/<basename>` files. (Keep them until both annotators succeed in case of retry.)

The orchestrator MAY dispatch multiple batches concurrently per §6.2 concurrency rules. Anonymized source files in `/tmp/gold_sources/` are shared across A and B within a batch; orchestrator handles GC.

---

## Post-processing contract (orchestrator must apply)

Every returned JSON must pass:

1. **JSON parse**: must parse as a single JSON object with a top-level `files` array. If it has prose, markdown fences, or trailing text, the orchestrator strips/repairs once; if still invalid, REJECT.
2. **Per-file unwrap**: `tools/unwrap.py` extracts each `files[i]` element and stores it as `<basename>.A.opus.raw.json` / `<basename>.B.sonnet.raw.json`.
3. **Schema validation** per `GOLD_EXPERIMENT_v1.md §7` — applied to each unwrapped annotation independently.
4. **Audit-vs-output cross-check** per `GOLD_EXPERIMENT_v1.md §8` — applied to each unwrapped annotation independently.

If any step fails: the orchestrator re-dispatches the batch once. Second failure escalates per `GOLD_EXPERIMENT_v1.md §6` step 5/6, with `<basename>.review.json` written for the offending file(s).

---

## Provenance

Every `<file>.gold.json` records `provenance.dispatch_mode = "anon_read_batched"` (v1.2 and later). Files produced under v1.0/v1.1 single-shot inline dispatch (batch-1 raws: BarcodeView, ControllerBase, MotorBase, BeamlineAuthView, Component, DcssHardwareServer, MFX_MOTOR) are grandfathered with `dispatch_mode = "inline_single_shot"` or omit the field.

---

## What this prompt does NOT cover

- File list, corpus selection, concurrency, output paths, acceptance gates, full provenance schema — all in `GOLD_EXPERIMENT_v1.md`.
- The convention itself — in `TCL_CALLGRAPH_CONVENTION.md`.

This file is just the parametric atomic operation.

End of prompt spec.
