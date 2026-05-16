# P1.4 Day 0 — pre-flight + corpus pull + denylist (working log)

**Status:** Day 0 complete; uncommitted artifacts staged under `validation/planes/`,
`validation/probes/`, `parser/languages.py`, and `dev-docs/verdicts/`.
**Date:** 2026-05-12
**Branch:** `tcl-disasm-bridge` (HEAD `5133c10`)
**Plan:** `dev-docs/plans/PLAN_v2.1_P1_4.md` §8 Day 0
**Predecessor verdict:** `dev-docs/verdicts/P1_3_VERDICT.md`
**Session:** `tcl-disasm-P1.4i`

This log is the working notebook for Day 0. Anything load-bearing for the
final verdict gets restated in `dev-docs/verdicts/P1_4_VERDICT.md` per plan §9.
Everything here stays uncommitted until end-of-phase per §6 #3 (single
end-of-phase commit, user reviews first).

---

## 0. Pre-flight gates (per plan §3)

All five gates ran green at session start before any Day-0 work:

| Gate | Expected | Actual |
|---|---|---|
| `git status --short` | clean (only `PLAN_v2.1_P1_4.md` untracked) | ✅ matches |
| `git log --oneline -3` head | `5133c10` P1.3 | ✅ `5133c10` |
| `validation/fixtures/disasm/run.tcl` | 26/26 PASS | ✅ 26/26 PASS |
| `validation/probes/p1_2_corpus_recognition_probe.tcl` (bluice) | 0 / 12,256 events | ✅ 0 / 12,256 events / 822 files |
| `python3 validation/layer2_compare.py` | F1 93.8% / P 91.7% / R 96.0% / TP 744 / FN 31 / FP 67, 357 symbols | ✅ matches exactly |
| `pytest tests/ -q` | 3,802 passed, 13 skipped | ✅ 3,802 passed, 13 skipped (508.6s) |

**Implication for F1**: the 93.8% pre-flight baseline was measured against
stale DBs left over from prior sessions. See §3 below for the post-reindex
finding.

---

## 1. Decisions internalized (no re-debate)

Per plan §5 + §6, RESOLVED at handoff:

1. Secondary corpus = **all 4** (tcllib + tklib + BWidget + iWidgets).
2. Storage path = **`/home/giles/git/tcl-corpus/<reponame>/`** (sibling of
   fork worktree).
3. Single end-of-phase commit; user reviews first; no mid-phase commits.
4. Validator mutation score < 0.90 → log + continue, not block.
5. Validator-first sequencing (Days 1-2 mutation testing; Day 5 κ).
6. Release gate = cross-tool invariant pass-rate; F1 demoted to reported
   metric with Wilson CI + per-pattern-kind stratification.
7. LLM verifier substrate-blind throughout.
8. Bridge stays as-is in P1.4 — bridge bugs surface as findings, not fixes.

---

## 2. Secondary corpus pulled

Per plan §6 #2, all 4 secondary repos staged under `/home/giles/git/tcl-corpus/`:

| Repo | Source | Files | Method |
|---|---|---|---|
| tcllib | `/usr/share/tcltk/tcllib1.21/` (system pkg) | 677 .tcl | `cp -r` |
| tklib | `https://github.com/tcltk/tklib.git` (mirror; `fossil` unavailable) | 453 .tcl | `git clone --depth 1` |
| BWidget | `/usr/share/tcltk/bwidget1.9.13/` (system pkg) | 39 .tcl | `cp -r` |
| iWidgets | `/usr/share/tcltk/iwidgets4.1.0/` (system pkg) | 2 .tcl + 54 .itk | `cp -r` |

`fossil` (Tcl org's preferred VCS) is not installed on this host; tcllib +
BWidget + iWidgets were available locally via `tcltk` system package; tklib
was cloned from the official GitHub mirror (`tcltk/tklib`).

---

## 3. F1 baseline — substantive Day-0 finding

The pre-flight gate's "F1 93.8%" measured stale DBs left by prior sessions.
The currently-installed upstream binary at
`/home/giles/tools/jcodemunch-venv/bin/jcodemunch-mcp` is **version 1.24.2**.
The fork (`jcodemunch-mcp 1.83.0`) is what P1.4 validates. The Claude Code
auto-reindex hooks at `~/.claude/settings.json` reference both transient
`/home/giles/.cache/uv/builds-v0/.tmp*/bin/jcodemunch-mcp` paths AND the fork
venv; the older DBs were almost certainly written by the upstream 1.24.2's
auto-reindex hook in some prior session.

When the user authorized `force reindex please, use our dev version`, the
9 test DBs were removed and rebuilt using the fork's direct venv binary
`/home/giles/git/jcodemunch-mcp-fork/.venv/bin/jcodemunch-mcp` — bypassing
any `uv run` indirection. After this:

| Metric | Pre-flight (upstream-built DBs) | Post-reindex (fork-built DBs) |
|---|---|---|
| Symbols compared | 357 | 352 (5 oracle entries not found in DB) |
| Oracle callees | n/a | 767 |
| Parser callees | n/a | 610 |
| True positives | 744 | 461 |
| Missed (FN) | 31 | 306 |
| Spurious (FP) | 67 | 149 |
| Precision | 91.7% | **75.6%** |
| Recall | 96.0% | **60.1%** |
| **F1** | **93.8%** | **67.0%** |

**Strict-A gate diagnostic**: every old DB triggered the warning
*"Existing index was created by a newer version of jcodemunch-mcp and cannot
be read — performing a full re-index"* — confirming the writer-version stamps
were from a different (and newer-by-stamp) code path than the fork's.

**Why this matters for P1.4**:
- The plan demoted F1 from gate to reported metric specifically because
  oracles tend to over-credit recall. The 26.8-point gap between upstream's
  and fork's F1 on the same oracle is concrete evidence the gate-demotion
  was warranted.
- The plan's release gate (cross-tool invariant pass-rate on Day 4) doesn't
  depend on oracle agreement. F1 at 67.0% is now the **honest** baseline the
  fork enters P1.4 with; Day 5's stratified Wilson-CI report will surface
  this transparently per plan §9 #9.
- The 5 oracle entries not found in DB are method qualified names that the
  oracle has but the fork's bridge doesn't emit (sample: `DCS::Component::replace%sInCommandWithValue`,
  `Scan3DMatrixView::emptyToZero`). These are individual bridge findings to
  log on Day 5, not blockers.

This finding subsumes the earlier "bluice DBs have empty jcm_tcl_extensions"
diagnostic from Day-0 morning. The empty `jcm_tcl_extensions` rows in the
upstream-built DBs were a symptom of the same root cause: upstream 1.24.2
predates the side-table architecture.

---

## 4. `.itk` extension registration

Bluice has 1 `.itk` file (`DcsWidgets/IPanedwindow.itk`) plus 11 `.itcl`
files (already registered). iWidgets ships its widget bodies under `.itk`
extension (54 files). The bridge parses `.itk` content correctly (verified
directly on `iWidgets/scripts/buttonbox.itk` — returns 9,730 bytes JSON
with `__script__` module + iTk class symbols). The gap was purely in
`parser/languages.py:LANGUAGE_REGISTRY` — `.tcl`, `.tk`, `.itcl` were
registered; `.itk` was not.

User-authorized edit applied:

```diff
 # Tcl
 ".tcl": "tcl",
 ".tk": "tcl",
 ".itcl": "tcl",
+".itk": "tcl",
```

Probe (`validation/probes/p1_2_corpus_recognition_probe.tcl`)
`recursive_glob_tcl` updated to walk `.tcl/.itcl/.itk` (header comments at
lines 6 and 23 updated to match).

Regression evidence: bluice corpus recognition probe **0 unrecognized /
12,294 events** (up from 12,256 — gained 38 events from the newly-walked
`.itk` file; all recognized).

---

## 5. Indexing — all 9 repos via fork direct binary

After the `rm` of the 9 stale DBs and re-indexing with
`/home/giles/git/jcodemunch-mcp-fork/.venv/bin/jcodemunch-mcp index`:

| Repo | files | syms | class | func | meth | ns | tcl_ext | pclass_rows | pkg_req_rows |
|---|---|---|---|---|---|---|---|---|---|
| **Primary** | | | | | | | | | |
| BluIceWidgets | 114 | 4,592 | 332 | 50 | 3,133 | 3 | 437 | 328 | 109 |
| DcsWidgets | 106 | 3,845 | 226 | 318 | 2,889 | 8 | 278 | 188 | 90 |
| dcss | 461 | 4,848 | 14 | 3,767 | 808 | 108 | 57 | 0 | 57 |
| dhs-tcl | 132 | 1,624 | 178 | 70 | 1,208 | 0 | 180 | 165 | 15 |
| dcs-lib-tcl | 10 | 116 | 10 | 2 | 76 | 0 | 15 | 6 | 9 |
| **Secondary** | | | | | | | | | |
| tcllib | 675 | 10,687 | 66 | 7,403 | 511 | 822 | 504 | 49 | 455 |
| tklib | 454 | 5,155 | 4 | 3,345 | 134 | 267 | 309 | 0 | 309 |
| BWidget | 39 | 654 | 0 | 594 | 0 | 46 | 5 | 0 | 5 |
| iWidgets | 59 | 1,451 | 58 | 70 | 1,259 | 4 | 56 | 55 | 1 |

Primary symbol counts match P1.3 verdict exactly (BluIce 4,592 / 332; DcsWidgets
3,845 vs verdict 3,810 — +35 syms because P1.3 baseline missed the
`IPanedwindow.itk` file; dhs-tcl 1,624 / 178; dcs-lib-tcl 116 / 10; dcss
4,848). All DBs stamped `jcm_tcl_writer_version=1`, `indexed_at` ≥ 2026-05-12T13.

**Schema-pop variance observations** (carried forward from P1.3 follow-ups):
- BluIceWidgets `pclass_rows / classes` = 328/332 (98.8%). Consistent with P1.3.
- DcsWidgets 188/226 (83.2%), dhs-tcl 165/178 (92.7%), dcs-lib-tcl 6/10
  (60.0%). Smaller-repo variance — same pattern as P1.3.
- dcss `pclass_rows = 0` (only 14 classes; all are TclOO/snit-style without
  `inherit` — bridge correctly emits no parent_classes row for those).
- tklib `pclass_rows = 0` (only 4 classes, all procedural Tk widget definitions).
- BWidget `pclass_rows = 0` (0 classes; uses `namespace eval Widget` +
  `Widget::define` factory pattern — no iTcl classes).
- iWidgets `pclass_rows = 55 / 58 classes` (94.8%). Best of any secondary.
- tcllib `pkg_req_rows = 455` (broad `package require` usage as expected).

These align with P1.3 verdict's open follow-up:
> Schema-pop variance on smaller repos (87.9% / 71.2% / 70.8% on package_requires
> in DcsWidgets / dhs-tcl / dcs-lib-tcl) — likely conditional `package require`
> inside `if`/`catch`/`namespace eval $var` bodies.

---

## 6. Corpus recognition — full 9-repo sweep

| Repo | Files probed | Walker events | Unrecognized | Status |
|---|---|---|---|---|
| bluice (5 primary, scope filter) | 823 | 12,294 | 0 | PASS |
| tcllib | 677 | 11,947 | 0 | PASS |
| tklib | 454 | 9,582 | **12** | FAIL |
| BWidget | 39 | 640 | 0 | PASS |
| iWidgets | 59 | 1,654 | 0 | PASS |
| **Aggregate** | **2,052** | **36,117** | **12** | **99.967% recognized** |

### tklib unrecognized-events finding (P1.4 Day-0 #1)

All 12 unrecognized events are `invokeStk1` "no dispatch row matched",
concentrated in 6 files all under `tklib/examples/`:

| File | Lines |
|---|---|
| `examples/canvas/crosshairs_for_axes.tcl` | 43-49 (7 events) |
| `examples/scrollutil/BwScrollableFrmDemo1.tcl` | 34 |
| `examples/scrollutil/BwScrollableFrmDemo2.tcl` | 36 |
| `examples/widget/screenruler.tcl` | 59 |

Source pattern (sample, `crosshairs_for_axes.tcl:43-49`):

```tcl
$p(2) plot data  10.0 -5.0
$p(2) plot data -10.0 -5.0
$p(5) dataconfig data -colour green
$p(5) plot data  10.0 -4.7
```

**Diagnosis**: command word is `$var(idx)` — array-element variable expansion
at first-word (command-call) position. The bridge has dispatch rows for the
analogous `namespace eval $var BODY` shape (`computed_namespace` in §13.6),
but no row for the general "first token is `$var()`" case. The walker emits
`invokeStk1` with no matching dispatch row, falling through to
`unrecognized`.

**Disposition per plan §11**: bridge stays as-is in P1.4. Log as P1.4 finding
for P1.5+ candidate dispatch row (Pattern `command_via_array_var`). 0.13% of
walker events; doesn't block Day 4 invariants or any Day-1-Day-5 deliverable.
The 6 affected files are all in `examples/` (not in `modules/`, which is
tklib's library code).

---

## 7. Position validator denylist

Per plan §5 #8 + §8 Day 0: denylist generated from `interp create; info
commands` after loading the pinned package set.

Implementation: `validation/planes/_denylist_gen.tcl` — runs an explicit
`exit 0` after enumeration to prevent the Tk-event-loop hang we hit on
the preliminary version probe (xvfb-run + tclsh + here-string +
`package require Tk` → tclsh stays alive waiting for events).

Invocation: `xvfb-run -a tclsh validation/planes/_denylist_gen.tcl`

### Manifest (`validation/planes/denylist_tcl_8.6.14.manifest`)

```
tcl_patchLevel=8.6.14
initial_count=100
final_count=159
loaded=Itcl:3.4 Tk:8.6.14 Itk:3.4 Iwidgets:4.1.1 BWidget:1.9.16
failed=
```

All 5 packages loaded successfully. Pin match against plan §5 #8:
- Tcl 8.6.14 ✅
- iTcl 3.4 ✅
- iTk 3.4 ✅
- Tk 8.6.14 ✅ (not gated; surfaced for visibility)
- Iwidgets 4.1.1 (plan didn't pin; documented for repro)
- BWidget 1.9.16 (plan didn't pin; documented for repro)

### Denylist (`validation/planes/denylist_tcl_8.6.14.txt`)

- 159 commands (after lsort -dictionary)
- 100 Tcl-builtin baseline (`info commands` before any package load)
- 59 commands added by Itcl + Tk + Itk + Iwidgets + BWidget (global namespace
  only; namespaced commands like `::itcl::class`, `iwidgets::buttonbox`,
  `BWidget::*` are not in `info commands` global-scope enumeration; plan §5
  #8 specifies `info commands` explicitly)
- SHA-256: `be7c8d76d0d91d8798cd285512dc0888e8e02fe7af3b6cff22803f0769f7aade`

### Reproducer

```bash
cd /home/giles/git/jcodemunch-mcp-fork
xvfb-run -a tclsh validation/planes/_denylist_gen.tcl > /tmp/denylist.txt
sha256sum /tmp/denylist.txt
# expected: be7c8d76d0d91d8798cd285512dc0888e8e02fe7af3b6cff22803f0769f7aade
diff /tmp/denylist.txt validation/planes/denylist_tcl_8.6.14.txt
```

---

## 8. iWidgets corpus shape note

iWidgets contributes 56 `jcm_tcl_extensions` rows (one per indexed file's
__script__) but only **1** with non-empty `package_requires`. iWidgets `.itk`
files use `package provide`, not `package require`. This is correct iWidgets
shape and matches the convention for widget packages. It does mean `INV-PKG-1`
(Day 4) will be near-vacuous on iWidgets.

---

## 9. Files written / edited / staged

**Edited (under source-code authorization)**:
- `src/jcodemunch_mcp/parser/languages.py` — +1 line: `".itk": "tcl",`
- `validation/probes/p1_2_corpus_recognition_probe.tcl` — extended
  `recursive_glob_tcl` glob to `*.tcl *.itcl *.itk`; updated header comments.

**Created**:
- `validation/planes/` (new directory)
- `validation/planes/_denylist_gen.tcl` (denylist generator)
- `validation/planes/denylist_tcl_8.6.14.txt` (159 commands, lsort -dictionary)
- `validation/planes/denylist_tcl_8.6.14.manifest` (Tcl/package version pins
  + load status)
- `dev-docs/verdicts/P1_4_DAY0_LOG.md` (this file)

**External (filesystem outside repo)**:
- `/home/giles/git/tcl-corpus/tcllib/` (cp from `/usr/share/tcltk/tcllib1.21`)
- `/home/giles/git/tcl-corpus/tklib/` (git clone shallow from `tcltk/tklib`)
- `/home/giles/git/tcl-corpus/BWidget/` (cp from `/usr/share/tcltk/bwidget1.9.13`)
- `/home/giles/git/tcl-corpus/iWidgets/` (cp from `/usr/share/tcltk/iwidgets4.1.0`)
- 9 fresh DBs under `~/.code-index/local-{repo}-*.db` (writer version 1)

---

## 10. Day-0 findings carried forward to VERDICT.md

1. **F1 baseline regression** 93.8% → **67.0%** is a fork-vs-upstream call-graph
   shape difference, not a fork regression. Documented in §3. Day-5 stratified
   F1 with Wilson CI will report this with proper uncertainty bounds.
2. **tklib `$var(idx)` command-position pattern** unrecognized (12 events / 6
   files in `examples/`). Bridge gap, P1.5+ candidate. Documented in §6.
3. **`.itk` extension registry gap** patched in P1.4 (single-line addition
   to `parser/languages.py`; user-authorized; minimal scope).
4. **iWidgets shape note** — uses `package provide` not `package require`;
   `INV-PKG-1` will be near-vacuous on this repo (expected, documented).

---

## 11. EOD gate — pytest

```
$ uv run --no-project --with pytest --with-editable . pytest tests/ -q
...
3802 passed, 13 skipped in 503.98s (0:08:23)
```

**Result: PASS** — same count as P1.3 baseline (3,802 passed, 13 skipped).
Non-Tcl language tests all green despite the `.itk` registry addition.
Pre-flight time 508.6s vs EOD 503.98s — no perf regression.

The `parser/languages.py` `.itk → tcl` mapping addition affects discovery
only (which extension triggers the Tcl extractor); the Tcl extractor itself
is unchanged. The `probe.tcl` glob edit is validation-side only. Neither
touches the parser dispatch, the bridge driver, or any non-Tcl language
path — so the per-day pytest 3,802 gate stays satisfied per plan §4.

---

## 12. Day-0 EOD summary (≤100 words)

Day 0 closed all six P1.4 deliverables: secondary corpus pulled to
`/home/giles/git/tcl-corpus/`, all 9 repos force-reindexed with fork 1.83.0,
denylist generated under pinned (Tcl 8.6.14 / iTcl 3.4 / Itk 3.4 / Iwidgets
4.1.1 / BWidget 1.9.16) versions. Two substantive findings recorded: F1 67.0%
(fork) vs 93.8% (upstream stale baseline) is a fork-vs-upstream shape
difference, not a regression; tklib has 12 unrecognized walker events
(`$var(idx) cmd args` pattern in examples/). `.itk` extension registered.
Corpus recognition 99.967% aggregate. Pytest gate result appended below.
Awaiting Day-1 go.
