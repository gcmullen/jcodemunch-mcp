#!/usr/bin/env python3
"""Build the substituted annotator prompt for a batched anonymized-source-read dispatch.

Per GOLD_PROMPT_v1.md v1.2 (anon-read protocol):
- Convention text is inlined into the prompt verbatim (one copy per dispatch).
- Source content is NOT inlined. Instead, the orchestrator copies each source
  file to /tmp/gold_sources/<basename> ahead of dispatch, and the prompt
  lists the anonymized paths under FILES TO ANNOTATE. The agent uses the Read
  tool exactly once per listed path.

Writes the prompt body to a file and prints the SHA-256 hash + byte count for
orchestrator-side provenance tracking.

Usage:
  build_prompt.py \\
    --convention dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md \\
    --anon-source AutoSample.tcl:/tmp/gold_sources/AutoSample.tcl \\
    [--anon-source <basename>:<anon_path> ...] \\
    --out <prompt-path>

Batching is controlled by how many --anon-source flags you pass. One = solo
dispatch; many = a single batched dispatch returning a multi-entry
{"files":[...]} wrapper.
"""
import argparse
import hashlib
import sys
from pathlib import Path


PROMPT_TEMPLATE = """You are a Tcl call-graph annotator. Read EACH anonymized Tcl source file listed under FILES TO ANNOTATE, apply the convention below verbatim, and emit a single JSON object {"files": [<annotation>, ...]} with one annotation per file PLUS a structured compliance_audit block per annotation that proves you applied each rule.

Constraints:
- The ONLY files you may read are the anonymized source paths listed under FILES TO ANNOTATE. Use the Read tool exactly once per listed path. Do NOT read any other file (not the convention, not any project file, not any system file).
- Do NOT write any files.
- Do NOT use external tools or web fetches.
- Output ONLY a single JSON object {"files": [...]} — no markdown fences, no prose, no preamble, no trailing commentary.
- The "files" array order matches the input order.

Schema clarifications (enforced; deviations cause rejection):
- Top-level object MUST include `schema_version: "1.3"` (convention v1.3).
- The top-level `file` field MUST be the basename only (e.g. "AutoSample.tcl"), never a path.
- symbols is a FLAT array; do not nest child symbols inside a parent. Each symbol stands alone with qualified_name carrying the hierarchy. No "children" arrays.
- Each symbol carries exactly these keys: qualified_name, line, end_line, kind, visibility, parent_classes, args, arity, package_requires, package_provides, imports, callees, unresolved_dispatches. Do NOT add fields like name, parent, signature, docstring, decorators.
- `args` is the verbatim ordered list of formal-parameter names from the declaration (drop default-value braces: `{name default}` → `"name"`). `arity` is `len(args)`. Populated for `proc`, `method`, `class_method`, `constructor`, `lambda`. For `class`, `namespace`, `destructor`, `coroutine`, `configbody` emit `args: [], arity: 0`. Variadic procs with final `args` parameter: include `"args"` in the array and count it in `arity` (e.g. `proc foo {a b args}` → `args: ["a", "b", "args"], arity: 3`).
- package_provides MUST be an array of objects {name, version} (version may be null). NEVER a list of strings.
- visibility MUST be JSON null (not the string "null") when absent.
- language is determined by the file's extension (case-insensitive): .tcl→tcl, .itcl→itcl, .tk→tk, .itk→itk.
- compliance_audit MUST include all NINE sections below, each as an array (possibly empty).
- All line numbers MUST be source-relative — i.e., the line numbers returned by the Read tool when reading the anonymized source path. The Read tool returns content prefixed with line numbers; those line numbers ARE the source file's line numbers and you should use them verbatim in your annotation's `line` / `end_line` / audit-line fields.
- Each callee object MUST include `name` (string), `line` (int, source-relative, 1-indexed), `kind` (one of `static|qualified|ensemble|method_dispatch|callback|lambda|unresolved`). When `kind == "method_dispatch"`, MUST also include `receiver_hint` (string) — the verbatim source-form of the receiver expression (e.g. `"$obj"`, `"${obj}"`, `"$itk_component(eu)"`). The optional `note` field MAY follow. Worked example: `{"name": "register", "line": 87, "kind": "method_dispatch", "receiver_hint": "$obj", "note": "$obj register"}`. COUNTER-EXAMPLE — the `name` field is the LITERAL second word ONLY, never a 2-word phrase, even when the method takes a subcommand-shaped first argument. For `$mb add command -label "Open"` the callee is `{"name": "add", "kind": "method_dispatch", "receiver_hint": "$mb"}`, NOT `{"name": "add command", ...}`. For `$snit_obj configure -option val` the callee is `{"name": "configure", ...}`, NOT `{"name": "configure -option", ...}`. Words after the second word are data arguments per §5.3, even when the underlying method's grammar accepts a typed subcommand (D2 dispute pattern; 101 verdicts in the v1.3 gold run). Emitting a callee without the `line` field, or with `line: null`, is a schema violation that causes rejection. Every call site has a source line — use the Read tool's line-prefixed output to record it verbatim. Do not omit `line` even for callback or unresolved kinds. `receiver_hint` is required on `method_dispatch` only; absent/empty on all other kinds.

Patterns most commonly drifted on in prior runs — read the listed sections in the inlined convention VERY carefully: §5.2 (preserve `::` qualifiers), §5.3 (`$obj method` and bracketed-receiver method_dispatch; never use the placeholder `"method"`), §6.9 + §6.12 (script-accepting dispatcher is NOT a callee; callback `name` is the method word), §7.1 (Tier 1 / Tier 2 filters AND the NOT-Tier-2 Tk widget-command callout). The full rules and worked examples are below in the convention; this prompt does not restate them.

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
  "tier1_keyword_appearances": [
    {"line": <int>, "keyword": "catch|try|on|trap|finally|yield|yieldto", "decision": "EXCLUDED from callees per §7.1 Tier 1; body walked for inner callees"}
  ],
  "tier2_ensemble_appearances": [
    {"line": <int>, "ensemble": "string|dict|info|array|chan|file|clock|namespace|package|binary|encoding", "subcommand": "<verbatim subcommand>", "decision": "EXCLUDED from callees per §7.1 Tier 2 / §7.5 default"}
  ],
  "tier3_keyword_appearances": [
    {"line": <int>, "keyword": "puts|gets|read|error|throw", "decision": "EXCLUDED from callees per §7.1 Tier 3"}
  ],
  "script_accepting_sites_seen": [
    {"line": <int>, "command": "after|after idle|bind|fileevent|trace add variable|trace add command|trace add execution", "script_form": "pure_callback_pattern|multi_command_script|variable_bound|bracket_substituted", "callee_recorded": "<name or '?' or 'NONE_walked_bracket'>", "decision": "recorded callback callee|walked bracket|unresolved+callback_var", "spec_basis": "§6.9"}
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

Each file's `file` field in your output uses the BASENAME (not the anon path).

Emit the wrapping JSON object `{"files": [<annotation>, <annotation>, ...]}` with one annotation per input file, each containing file, language, symbols, file_level, AND compliance_audit. Nothing else.
"""


def build_files_list(anon_sources: list[tuple[str, str]]) -> str:
    lines: list[str] = []
    for basename, anon_path in anon_sources:
        lines.append(f"- basename: {basename}")
        lines.append(f"  anon_path: {anon_path}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--convention", required=True, type=Path)
    ap.add_argument(
        "--anon-source",
        action="append",
        required=True,
        help="<basename>:<anon-path>; repeatable. Each anon-path MUST already exist on disk (the orchestrator stages the file before dispatch).",
    )
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    anon_sources: list[tuple[str, str]] = []
    for spec in args.anon_source:
        if ":" not in spec:
            print(f"error: --anon-source must be <basename>:<anon-path>, got {spec!r}", file=sys.stderr)
            return 2
        basename, anon_path = spec.split(":", 1)
        if not Path(anon_path).exists():
            print(f"error: anon path does not exist: {anon_path}", file=sys.stderr)
            return 2
        anon_sources.append((basename, anon_path))

    convention = args.convention.read_text()
    files_list = build_files_list(anon_sources)

    body = (
        PROMPT_TEMPLATE
        .replace("__CONVENTION_DOC__", convention)
        .replace("__FILES_LIST__", files_list)
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(body)

    sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
    print(
        f"prompt_path={args.out}\n"
        f"prompt_bytes={len(body.encode('utf-8'))}\n"
        f"prompt_sha256={sha}\n"
        f"n_files={len(anon_sources)}\n"
        f"files={[bs for bs, _ in anon_sources]}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
