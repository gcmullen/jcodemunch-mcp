#!/usr/bin/env python3
"""Build the substituted arbiter prompt for a single file with disputes.

Per GOLD_ARBITER_PROMPT_v1.md v1.0: the arbiter receives convention text +
source + A raw + B raw + dispute list, and emits per-callee verdicts. To keep
the prompt below the orchestrator's tool-result truncation threshold, source /
A-raw / B-raw are NOT inlined; the arbiter reads them from anonymized paths
under /tmp/gold_arbiter/. The dispute list is small and IS inlined.

Convention text IS inlined verbatim (the arbiter applies it as authority).

Usage:
  build_arbiter_prompt.py \\
    --convention dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md \\
    --basename DcssHardwareServer.tcl \\
    --source /tmp/gold_arbiter/DcssHardwareServer.tcl \\
    --a-raw /tmp/gold_arbiter/DcssHardwareServer.A.opus.raw.json \\
    --b-raw /tmp/gold_arbiter/DcssHardwareServer.B.sonnet.raw.json \\
    --disputes /tmp/gold_arbiter/DcssHardwareServer.disputes.json \\
    --out /tmp/gold_arbiter/DcssHardwareServer.arbiter_prompt.txt
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path


PROMPT_TEMPLATE = """You are arbitrating disagreements between two LLM annotators (A=Opus, B=Sonnet) on a single Tcl source file's call-graph annotation. Both annotators applied the convention below; their disagreements are listed in DISPUTES. For each dispute, decide which annotator (if either) correctly applied the convention, and emit a one-line justification citing the controlling spec section.

You do NOT re-annotate. You pick among the existing emissions.

Constraints:
- Read EXACTLY these four anonymized paths (no other files):
    1. __SOURCE_PATH__   (the Tcl source file; line numbers in its Read output are source-relative)
    2. __A_RAW_PATH__    (annotator A's raw JSON)
    3. __B_RAW_PATH__    (annotator B's raw JSON)
    4. __DISPUTES_PATH__ (the dispute list JSON; alternatively, the DISPUTES section below is identical and you MAY skip this read)
- Do NOT write any file. Do NOT use external tools or web fetches.
- Output ONLY a single JSON object with the schema given below — no markdown fences, no prose, no preamble.
- Justifications must be ONE sentence and cite a section number from the convention (e.g. "§5.3 — receiver is literal qualified, not $var, so §5.2 applies and B's method_dispatch is wrong").
- A verdict of `convention_ambiguous` means the spec genuinely under-specifies this case — use sparingly.

Patterns where prior arbitrations drifted — read the listed sections in the inlined convention VERY carefully before deciding: §5.2 (preserve `::` qualifiers verbatim — stripping them is always wrong), §5.3 (bracketed receivers `[$obj method]` ARE method_dispatch; `name` is the literal method word, never `"method"` placeholder), §6.9 + §6.12 (script-accepting dispatcher `bind`/`after`/`fileevent`/`trace add ...` is NEVER a callee — only the SCRIPT's callback per §6.12; callback `name` field is the method word, never the dispatcher or the flag name), §7.1 (Tier 1 / Tier 2 filters AND the NOT-Tier-2 Tk widget callout — Tk widget/geometry commands ARE legitimate static callees). The full rules + worked examples are below in the convention; this prompt does not restate them.

HARD DENYLIST OVERRIDE — apply this FIRST, before any other reasoning. If a disputed callee.name matches any of the following, rule against whichever model emitted it. The verdict is forced; `convention_ambiguous` and `both_correct` are NOT allowed for these cases.
- §7.1 Tier 1 control flow: `if`, `else`, `elseif`, `while`, `for`, `foreach`, `switch`, `catch`, `try`, `on`, `trap`, `finally`, `return`, `break`, `continue`, `yield`, `yieldto`. `rule_basis = "§7.1 Tier 1"`.
- §7.1 Tier 2 utilities: `set`, `incr`, `unset`, `lappend`, `lassign`, `lset`, `lreplace`, `llength`, `lrange`, `lsearch`, `lsort`, `lindex`, `linsert`, `lrepeat`, `lreverse`, `split`, `join`, `format`, `scan`, `expr`, `regexp`, `regsub`, `subst`. `rule_basis = "§7.1 Tier 2"`.
- §7.1 Tier 2 ensembles (2-word phrase whose first word is): `string`, `dict`, `info`, `array`, `clock`, `chan`, `file`, `binary`, `namespace`, `package`, `encoding`. `rule_basis = "§7.1 Tier 2"`. (Tk geometry ensembles `grid`, `pack`, `place`, `wm`, `winfo` and iTcl `delete` are NOT denylisted — see §5.10 carve-out.)
- §7.1 Tier 3 I/O: `puts`, `gets`, `read`, `error`, `throw`. `rule_basis = "§7.1 Tier 3"`.
- §6.9 script-accepting dispatchers: `after`, `bind`, `fileevent`, `trace add variable`, `trace add command`, `trace add execution`, `socket -server`. `rule_basis = "§6.9"`.

For each denylisted callee: if A emitted it and B did not → verdict = "B_correct"; if B emitted it and A did not → verdict = "A_correct"; if both emitted it → verdict = "neither_correct". `justification` cites the denylist rule (e.g. "§7.1 Tier 2 — `lappend` is a pure list utility and must NEVER appear as a callee").

Output schema:
{
  "file": "__BASENAME__",
  "verdicts": [
    {"symbol": "<qn>", "callee_name": "<n>", "callee_kind_A": "<k|null>", "callee_kind_B": "<k|null>", "line": <int>, "verdict": "A_correct|B_correct|both_correct|neither_correct|convention_ambiguous", "rule_basis": "<spec section>", "justification": "<one sentence>"}, ...
  ],
  "summary": {"n_disputes": <int>, "a_correct": <int>, "b_correct": <int>, "both_correct": <int>, "neither_correct": <int>, "convention_ambiguous": <int>}
}

The `verdicts` array MUST have exactly the same length as DISPUTES, and each entry MUST reference a (symbol, callee_name, line) triple from DISPUTES.

========================================
CONVENTION (apply verbatim):
========================================

__CONVENTION_DOC__

========================================
DISPUTES TO ARBITRATE (this is also at __DISPUTES_PATH__ — you may read either):
========================================

__DISPUTES_JSON__

Emit the JSON object. Nothing else.
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--convention", required=True, type=Path)
    ap.add_argument("--basename", required=True)
    ap.add_argument("--source", required=True, type=Path,
                    help="Anon path to the source file (e.g. /tmp/gold_arbiter/<basename>).")
    ap.add_argument("--a-raw", required=True, type=Path)
    ap.add_argument("--b-raw", required=True, type=Path)
    ap.add_argument("--disputes", required=True, type=Path,
                    help="Path to the disputes JSON file (a list of dispute entries).")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    for p in (args.source, args.a_raw, args.b_raw, args.disputes):
        if not p.exists():
            print(f"error: anon path does not exist: {p}", file=sys.stderr)
            return 2

    convention = args.convention.read_text()
    disputes_text = args.disputes.read_text().strip()
    # Validate disputes parses
    try:
        n_disputes = len(json.loads(disputes_text))
    except json.JSONDecodeError as e:
        print(f"error: disputes JSON invalid: {e}", file=sys.stderr)
        return 2

    body = (
        PROMPT_TEMPLATE
        .replace("__CONVENTION_DOC__", convention)
        .replace("__BASENAME__", args.basename)
        .replace("__SOURCE_PATH__", str(args.source))
        .replace("__A_RAW_PATH__", str(args.a_raw))
        .replace("__B_RAW_PATH__", str(args.b_raw))
        .replace("__DISPUTES_PATH__", str(args.disputes))
        .replace("__DISPUTES_JSON__", disputes_text)
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(body)
    sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
    print(
        f"prompt_path={args.out}\n"
        f"prompt_bytes={len(body.encode('utf-8'))}\n"
        f"prompt_sha256={sha}\n"
        f"basename={args.basename}\n"
        f"n_disputes={n_disputes}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
