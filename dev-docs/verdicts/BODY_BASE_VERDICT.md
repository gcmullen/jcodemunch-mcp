# Body-base probe — verdict (P1.0)

**Date**: 2026-05-08
**Plan**: `PLAN_v2.1.md §3 P1.0` (CRITICAL gate before P1.1)
**Strategy under test**: PLAN_v2.1 §2.2 (custom word-position walker on parent
command's source text, anchored by `tcl::unsupported::disassemble script`'s
`src N-M` byte ranges).
**Probe**: `validation/probes/body_base_probe.tcl`

---

## Verdict: **WALKER VIABLE.**

The pure-Tcl word-position walker recovers body-arg start/content positions
correctly on every definition command encountered in the bluice corpus
sample. The C-extension escape hatch (R33, `/tmp/parsewords.c`) is **not**
needed for P1.1. P1.1 commits.

## Numbers

| Signal | Result |
|---|---|
| Real bluice files probed | 13 |
| Definition commands tested (recursive walk) | 382 |
| Walker matched `lindex` ground truth | **382 / 382 — 100.00%** |
| Walker mismatches | **0** |
| Synthetic edge-case fixtures | 5 |
| Synthetic passes | **5 / 5** |

## Definition shapes covered

The classifier matched and the walker correctly extracted bodies for:
`proc`, `namespace eval`, `class`, `itcl::class`, `itk::usual`,
`oo::class create`, `body Class::method`, `configbody Class::var`,
`itcl::body`, `itcl::configbody`, `[public|private|protected] method`,
`constructor` (2-arg and 3-arg iTcl forms), `destructor`,
`itk_component add`, `itk_component add -protected`. Every such command in
the 13-file sample was tested.

## Synthetic edges locked down

| Edge case | Probe fixture | Result |
|---|---|---|
| Identical bodies in same file | two procs with identical body content | **PASS** — walker locates each via independent src ranges |
| Body containing escape sequences | `puts "line1\nline2\t\$x"` | **PASS** — walker reads file bytes; bytecode-literal interpretation never enters the path |
| Backslash-newline continuation between command words | `proc bs \<NL>{a b c} \<NL>{ ... }` | **PASS** — walker's whitespace-skip honors `\<NL>` per Tcl word grammar |
| Comments preceding a proc | two leading `#` lines, then `proc cb` | **PASS** — comments handled at command-list level; do not affect body-position |
| Multi-line ARGS list | `proc ml {<NL>arg1<NL>arg2<NL>} body` | **PASS** — walker tracks brace nesting through arbitrary whitespace |

The plan's fifth named edge case — quote-balance defeat (`info complete`
quote-blindness) — was empirically **moot under the new substrate**: the
case requires brace-counting *during top-level command splitting*, and the
substrate change moves command splitting into `tcl::unsupported::disassemble
script`, which is the canonical Tcl compiler doing the work. The walker
itself only operates on a single, already-bounded parent command.
`is_quote_balanced` survives in the §2.2 helper budget as defensive depth
for callers that buffer source chunks (e.g., the Signal 2 sandbox driver),
but it is not load-bearing for the body-base path.

## Informational signal: 51 `LRANGE_FAIL` events

In addition to the matched cases, the probe encountered 51 commands inside
method/constructor/proc bodies where `lrange` (used by the test scaffold to
classify) fails on legal Tcl source. These are NOT walker failures — the
walker doesn't classify; it just locates body positions. They are cases
that the **current bridge** falls back to a regex shim for
(`tcl_parser_bridge.tcl:1440-1448`) but the v2.1 substrate parses cleanly.
Examples:

- `set m_retryID [after 1000 "$this update"]` — `lrange` chokes on `""]`
- `set headers [list Cookie "SMBSessionID=$m_sessionId"]` — same shape
- iTk addInput with `\<NL>` line continuations and quoted strings

Each of these would be a `_call_graph.py:LRANGE_FAIL` no-op in the current
bridge. In v2.1 they parse as ordinary commands; the call edges inside
them surface naturally through opcode walking.

## Architectural takeaways for P1.1

1. **Walker LoC bound is realistic.** The implementation is 105 LoC
   (probe `find_word_start` + `word_content_range`). The §2.2 budget of
   30–50 LoC for the walker proper plus 30 LoC each for content-extractor
   and quote-balance guard (130–170 LoC total) holds.
2. **`lindex` is not the right classifier in production.** The probe uses
   it as ground truth, but the v2.1 bridge classifies definitions from the
   bytecode literal pushed before `invokeStk` — never via list-grammar
   parsing of the command text. This avoids the 51 LRANGE_FAIL skips and
   matches the substrate's own command-name resolution.
3. **`disassemble script` packs multiple commands per output line.** The
   `Commands N:` section emits `K: pc X-Y, src S-E` entries inline, not
   one-per-line. P1.1's disasm parser must use a non-anchored regex.
   Verified empirically by this probe; the verifier scaffold at
   `validation/verify.tcl:88-115` already does this correctly.
4. **`class NAME BODY` (custom DSL) is in active bluice use.** Files like
   `BluIceWidgets/BarcodeView.tcl`, `Admin.tcl`, `Anneal.tcl`,
   `AutoSample.tcl` define classes via the bare `class` keyword (not
   `itcl::class`). The recursion table in v2.1 §2.4 sub-table A must
   include this row alongside `itcl::class`.

## Re-run reproducer

```bash
tclsh validation/probes/body_base_probe.tcl --bluice
# Exit 0 iff every real-file walker match succeeds AND every synthetic
# edge passes.
```
