# Ensemble enumeration probe — verdict (P1.1, R32)

**Date**: 2026-05-08
**Plan**: `PLAN_v2.1.md §2.3` (ensemble pre-rename table) and `§3 P1.1`
**Probe**: `validation/probes/ensemble_enumeration_probe.tcl`
**Reference table**: 9 ensembles, 43 subcommands derived from the
24-file oracle subset.

---

## Verdict: **ONE NEW ENSEMBLE ROW REQUIRED.**

The full bluice corpus (823 files probed, 0 disassembly failures)
surfaces a 10th ensemble that PLAN_v2.1 §2.3 explicitly excluded:
`::tcl::string::*`. The exclusion claim was based on the 24-file
oracle subset and was **incomplete**.

The other 9 reference ensembles close cleanly. New subcommands within
those ensembles are absorbed by the existing `(ensemble *)` wildcard
rules and do **not** require new table rows.

## Numbers

| Signal | Result |
|---|---|
| Files probed | 823 (BluIceWidgets, DcsWidgets, dcs-lib-tcl/main/scripts, dhs-tcl, dcss/scripts/**) + 1 synthetic |
| Disassembly failures | **0** |
| Distinct `::tcl::*::*` literals | **66** |
| Distinct ensembles | **10** (reference: 9) |
| Subcommands corpus-natural | **18** |
| Subcommands synthetic-only | **48** (force-coverage, not bluice usage) |

## New ensemble: `string`

**Empirical evidence** — `string repeat` compiles to
`::tcl::string::repeat` on Tcl 8.6.14:

```
::tcl::string::*  ->  string *   (1 subcommand)
  string repeat           CORPUS      (simpleClient.tcl)
```

`simpleClient.tcl` (in `dcs-lib-tcl/main/scripts/` or `dcss/scripts/**/`,
exact path captured by re-running the probe) uses `string repeat`
naturally. The compiler does **not** specialize `string repeat` the
way it does `string length` (`strlen`), `string compare` (`strcmp`),
`string match` (`strmatch`), or `string range` (`strrangeImm`). It
flows through the `::tcl::string::*` ensemble dispatch and emits the
literal.

This contradicts PLAN_v2.1 §2.3's "Notable empirical finding":

> `string` does NOT need rename-table treatment. Tcl 8.6 compiles
> `string length`/`compare`/`match`/`range` to specialized opcodes
> ... so the bridge never sees a `::tcl::string::*` literal to rename.

The claim is **partly correct and overgeneralized**. Specialized
opcodes ARE emitted for `length`/`compare`/`match`/`range` (the
probe surfaces zero `::tcl::string::length` etc. literals). But
*at least* `string repeat` falls through to ensemble dispatch and
generates a `::tcl::string::*` literal. Other unspecialized `string`
subcommands (`map`, `replace`, `reverse`, etc.) likely behave the
same way — bluice just doesn't exercise them naturally; this is
covered by the synthetic constructs but the corpus-natural sample
in this probe is 1.

## Required table addition

PLAN_v2.1 §2.3 pre-rename table grows from 9 rows to 10:

| Compiler-emitted literal | Source form |
|---|---|
| `::tcl::array::*` | `array *` |
| `::tcl::binary::*` | `binary *` |
| `::tcl::chan::*` | `chan *` |
| `::tcl::clock::*` | `clock *` |
| `::tcl::dict::*` | `dict *` |
| `::tcl::encoding::*` | `encoding *` |
| `::tcl::file::*` | `file *` |
| `::tcl::info::*` | `info *` |
| `::tcl::namespace::*` | `namespace *` |
| **`::tcl::string::*`** | **`string *`** **(NEW per R32)** |

## Subcommand-level findings (informational)

The corpus uses 18 ensemble subcommands naturally (others appear
only via the synthetic forcing fixture). The corpus-natural set
that exceeds the §2.3 43-subcommand oracle estimate:

- `info tclversion` (`IamDone.tcl`)
- `namespace children` (`all.tcl`)
- `file tempfile` (`keytest1.tcl`)
- `string repeat` (`simpleClient.tcl`)

These are absorbed by the wildcard rename pass and do not require
explicit table rows. They are recorded here as evidence the §2.3
"43 subcommands" enumeration was a lower bound, not the upper.

## Subcommands NOT used by bluice

(But still represented via synthetic-only attribution.)

The corpus does not naturally use any `dict::*`, `chan::*`, `clock::*`,
`encoding::*`, or `binary::*` subcommands beyond `binary scan`. This
matches the codebase's age — bluice predates `dict` (Tcl 8.5+) and
predates the `chan` ensemble's modernization. The bridge will still
correctly handle them when newer code lands; the rename rule applies
regardless.

## Q3 answer (open question carried from P1.0)

**Q3 — Ensemble enumeration probe results**: corpus-extended scan
beyond the 24-file oracle subset reveals **one new ensemble row**
(`string`). All other reference rows hold. New subcommands within
existing ensembles are wildcard-matched and need no new rows.

§2.3's "string does not need rename-table treatment" claim is
**retracted**; it should be replaced by:

> Tcl 8.6 compiles `string length`/`compare`/`match`/`range`/`equal`
> /`first`/`last`/`index`/`map`/`trim`/`toupper`/`tolower` to
> specialized opcodes (`strlen`, `strcmp`, `strmatch`, `strrangeImm`,
> `streq`, etc.). Other `string` subcommands — at least `string
> repeat` (corpus-verified) and likely `string replace`, `string
> reverse`, `string is`, `string totitle` — fall through to the
> `::tcl::string::*` ensemble dispatch and emit a literal the bridge
> must rename. The wildcard rename rule covers all of them.

## Re-run reproducer

```bash
# Default: BLUICE_ROOT=/home/giles/bluice, includes synthetic
tclsh validation/probes/ensemble_enumeration_probe.tcl

# Corpus only (no synthetic forcing fixture)
tclsh validation/probes/ensemble_enumeration_probe.tcl --no-synthetic

# Different bluice tree
tclsh validation/probes/ensemble_enumeration_probe.tcl \
    --bluice-root /path/to/bluice
```

Exit code is 0 iff the corpus closes cleanly under the reference
table (no new ensembles). On this run: exit 1 (one new ensemble:
`string`). After §2.3's table is updated to 10 rows, the probe will
need its `REFERENCE_ENSEMBLES` constant bumped accordingly so the
exit-code semantic stays meaningful as a regression guard.
