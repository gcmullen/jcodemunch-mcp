#!/usr/bin/env python3
"""Read an arbiter agent's JSON response from stdin and write it to
`<out-dir>/<basename>.arbiter.json`.

Validates the schema per GOLD_ARBITER_PROMPT_v1.md §Post-processing contract:
- Top-level object with `file`, `verdicts`, `summary`.
- `verdicts` is a list; each entry has `symbol`, `callee_name`, `line`, `verdict`,
  `rule_basis`, `justification`.
- `verdict` is one of the five enum values.
- `rule_basis` is a non-empty string starting with `§`.

If `--expected-disputes <int>` is given, verify `len(verdicts) == expected`.

Usage:
  cat arbiter_response.json | save_arbiter.py \
    --out-dir validation/gold_annotations/conv-v1.0/<corpus>/ \
    --basename <basename>.tcl \
    [--expected-disputes <int>]
"""
import argparse
import json
import sys
from pathlib import Path


VALID_VERDICTS = {
    "A_correct",
    "B_correct",
    "both_correct",
    "neither_correct",
    "convention_ambiguous",
}

REQUIRED_VERDICT_KEYS = {
    "symbol",
    "callee_name",
    "line",
    "verdict",
    "rule_basis",
    "justification",
}


def strip_fences(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        first_nl = t.find("\n")
        if first_nl != -1:
            t = t[first_nl + 1 :]
        if t.endswith("```"):
            t = t[: -3]
    return t.strip()


def validate(obj: dict, expected_disputes: int | None) -> list[str]:
    errors: list[str] = []
    if not isinstance(obj, dict):
        return ["top-level is not an object"]
    for key in ("file", "verdicts", "summary"):
        if key not in obj:
            errors.append(f"missing top-level key: {key}")
    verdicts = obj.get("verdicts")
    if not isinstance(verdicts, list):
        errors.append("verdicts is not a list")
        return errors
    if expected_disputes is not None and len(verdicts) != expected_disputes:
        errors.append(
            f"verdict count {len(verdicts)} != expected {expected_disputes}"
        )
    for i, v in enumerate(verdicts):
        if not isinstance(v, dict):
            errors.append(f"verdicts[{i}] is not an object")
            continue
        missing = REQUIRED_VERDICT_KEYS - set(v.keys())
        if missing:
            errors.append(f"verdicts[{i}] missing keys: {sorted(missing)}")
        if v.get("verdict") not in VALID_VERDICTS:
            errors.append(
                f"verdicts[{i}].verdict={v.get('verdict')!r} not in {sorted(VALID_VERDICTS)}"
            )
        rb = v.get("rule_basis")
        if not (isinstance(rb, str) and rb.startswith("§")):
            errors.append(f"verdicts[{i}].rule_basis must be string starting with §")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--basename", required=True, help="e.g. AutoSample.tcl")
    ap.add_argument("--expected-disputes", type=int, default=None)
    ap.add_argument("--allow-invalid", action="store_true",
                    help="Write the file even if schema validation fails (still report).")
    args = ap.parse_args()

    raw = sys.stdin.read()
    text = strip_fences(raw)
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON: {e}", file=sys.stderr)
        return 2

    errors = validate(obj, args.expected_disputes)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{args.basename}.arbiter.json"

    if errors and not args.allow_invalid:
        print(
            json.dumps(
                {"ok": False, "errors": errors, "out_path": str(out_path)}, indent=2
            ),
            file=sys.stderr,
        )
        return 1

    with out_path.open("w") as fh:
        json.dump(obj, fh, ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")

    summary = obj.get("summary") or {}
    print(
        json.dumps(
            {
                "ok": not errors,
                "errors": errors,
                "out_path": str(out_path),
                "file": obj.get("file"),
                "n_verdicts": len(obj.get("verdicts") or []),
                "summary": summary,
            },
            indent=2,
        )
    )
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
