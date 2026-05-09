# Tcl version reachability — verdicts (P1.1, deliverables d + e)

**Date**: 2026-05-08
**Plan**: `PLAN_v2.1.md §3 P1.1` deliverables (d) and (e)
**Plan §4.1** (risk model): "8.6.x patch versions: stable in practice"
+ R26: "Tcl 9.0 disassemble entrypoint renames; output format preserved
per public discussion but **not empirically verified by this plan.**"

This document records what the P1.1 walker spike has been verified
against, and what remains UNVERIFIED follow-on cost per R26.

---

## Deliverable (d): Tcl 8.6.x patch-version regression probe

### Verdict: **8.6.14 verified as the floor; lower patches UNTESTED on this host.**

**Reachability survey** (fork host, 2026-05-08):

| Source | Result |
|---|---|
| `which tclsh` | `/usr/bin/tclsh` → `tclsh8.6` |
| `info patchlevel` | `8.6.14` |
| `apt list --installed | grep tcl` | `tcl8.6/noble 8.6.14+dfsg-1build1` |
| `command -v tclsh{8.6.10..15,9.0}` | none present |
| `ls /usr/local/tcl* /opt/tcl*` | absent |
| `docker images | grep -i tcl` | docker daemon not running |
| Apt cache for older patches | not surveyed (per direction: minimal) |

**What this verifies:**

- The §2.3 dispatch table, the §2.2 word-position walker (P1.0
  body-base probe, 100% match), and the P1.1 spike (parser + walker +
  18 fixtures + ensemble probe over 823 corpus files, 0 disassembly
  failures) all hold on Tcl 8.6.14.
- The `disassemble` text format is parseable by the regex in
  `tcl_disasm_parser.tcl:_parse_header` and
  `_parse_command_bodies` on this version.
- The 10-row ensemble pre-rename table is exact for 8.6.14.

**What remains UNTESTED:**

- 8.6.10 → 8.6.13 patch versions.

**Risk assessment** (per PLAN §4.1):

8.6.x patch versions are documented as format-stable across this
range. The `tcl::unsupported::disassemble` entrypoint name has not
changed in 8.6.x (it was added in 8.5 and remained stable through
all 8.6.x releases). The opcode set the walker recognizes
(invokeStk1, invokeStk4, invokeReplace, invokeExpanded, expandStart,
expandStkTop, push1, push4, loadStk, strcat, storeStk) is core 8.6
bytecode and pre-dates 8.6.10.

**Per user direction (P1.1 kickoff)**: documenting 8.6.14 as the
verified floor is acceptable; aggressive reachability hunting (apt
holds, docker pulls, build-from-tarball) is out of scope.

**Re-verification path** (if a regression surfaces on a lower 8.6.x):

```bash
# Minimal regression repro on any tclsh version reachable later
tclsh src/jcodemunch_mcp/parser/tcl_disasm_parser.tcl <SOMEFILE>.tcl \
    > /tmp/parser_8614.txt
tclsh validation/fixtures/disasm/run.tcl    # 18/18 PASS at 8.6.14
tclsh validation/probes/body_base_probe.tcl --bluice  # 382/382 + 5/5
tclsh validation/probes/ensemble_enumeration_probe.tcl  # 1 new ensemble: string
```

---

## Deliverable (e): Tcl 9.0 probe per R26

### Verdict: **Tcl 9.0 UNREACHABLE on this host. 9.0 cost recorded as UNVERIFIED follow-on of unknown size.**

**Reachability survey**:

| Source | Result |
|---|---|
| `command -v tclsh9.0` | absent |
| `command -v tclsh9` | absent |
| `ls /usr/local/tcl9*` | absent |
| `ls /opt/tcl9*` | absent |
| Docker images locally cached for `tcl:9.0` | none; daemon not running |
| `apt list | grep tcl9` | not packaged in noble |

**Per R26 + R34** (`PLAN_v2.1.md §0.4` and `§4.1`):

> R34 — DEFERRED per user direction. Tcl 9.0 disassemble probe is
> acknowledged as desirable for multi-decade-horizon claim but is not
> in Phase 1 scope. §4.1 retains the "probe-if-reachable; document as
> unverified follow-on of unknown size" framing.

**Recorded cost: UNVERIFIED follow-on of unknown size.**

This is **NOT** "small." The empirical risks the spike cannot rule
out include:

1. **Disassemble entrypoint rename**: Tcl 9 has reportedly renamed
   `tcl::unsupported::disassemble` to a different namespace path
   (per public Tcl Wiki discussion; not verified here). The walker's
   `tcl_disasm_parser.tcl:disassemble_and_parse` would need a guarded
   dispatch (try 9.0 path first, fall back to 8.6 path). LoC impact:
   ~10 lines.

2. **Output text-format drift**: 9.0 may revise per-command line
   shapes (`Command N:`), pc-range packing, instruction operand
   formatting. The two regexes in `_parse_header` and
   `_parse_command_bodies` are tight to 8.6's exact whitespace and
   token shapes. Drift here would force regex revision and
   re-verification of every fixture.

3. **Opcode renames or additions**: 9.0 may rename `invokeStk1` →
   `invoke` (long-rumored) or introduce new dispatch opcodes
   (e.g. for refactored namespace handling). The walker's terminal
   detection logic in `_find_terminal_invoke` is enumerative; new
   dispatch opcodes would need explicit recognition.

4. **Ensemble pre-rename table**: 9.0 may reduce or expand the
   `::tcl::ENSEMBLE::*` literal set as the compiler's specialization
   regime evolves. The 10-row table (post P1.1f) is exact for 8.6.14;
   9.0 might require partial re-enumeration.

5. **Stable-API guarantees**: `tcl::unsupported::disassemble` is
   explicitly unsupported. Tcl 9 may demote/remove without notice.
   The R33 C-extension fallback (`/tmp/parsewords.c`, 115 LoC) does
   NOT depend on `disassemble`; it wraps `Tcl_ParseCommand` from the
   public stub-table API. If `disassemble` is gone in 9.0, R33 is the
   recovery path — but the walker substrate would need a partial
   redesign because `Tcl_ParseCommand` returns a parse tree, not
   bytecode (a different signal with different semantics).

**Decision point** (carried to P1.4 / Phase 2):

Bluice is currently on Tcl 8.6 with no firm 9.0 migration date. The
P1.1 verdict commits the bridge to 8.6 as its support floor and
documents 9.0 as an opaque follow-on cost. Revisit when bluice's
RHEL/Tcl modernization timeline firms up — at that point, P1.x re-runs
this probe against the targeted 9.0 binary.

**Rerun reproducer** (when 9.0 is reachable later):

```bash
# Substitute tclsh9.0 (or whatever 9.0 binary path resolves)
tclsh9.0 validation/fixtures/disasm/run.tcl
tclsh9.0 validation/probes/body_base_probe.tcl --bluice
tclsh9.0 validation/probes/ensemble_enumeration_probe.tcl
```

Each command's exit code AND output diff against the 8.6.14 baseline
in this directory becomes the deliverable.
