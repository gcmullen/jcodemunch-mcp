# Layer B + schema audit — TCL_CALLGRAPH_CONVENTION.md §4 + §7

## Overall verdict: PASS_WITH_NOTES
The Layer B tier filters and schema are internally coherent and serve the §1 consumer goal, but a small number of well-known Tcl 8.6 script-bearing commands (notably `lmap`, `time`, and several `dict` script-body subcommands) are absent from the tier scheme, and a few schema fields are under-specified in ways that mechanical validators will need to second-guess.

## §4 schema findings
- Required-key coverage: complete for the stated consumer goals — `qualified_name`, `line`, `end_line`, `kind`, `visibility`, `parent_classes`, `package_requires`, `package_provides`, `imports`, `callees`, `unresolved_dispatches` are all present, and per-kind applicability is spelled out in §4.1.
- Strictness: mostly sufficient. The schema is reasonably strict (closed enums for `language`, `kind`, callee `kind`, unresolved `subkind`; "always array, never null" invariant in §7.3; explicit bare-string vs object shape for `package_requires`/`package_provides`/`imports`). Mechanical validation against the prose is feasible.
- Ambiguities or under-specifications:
  - `qualified_name` for global procs is "<NAME>" per §6.2 ("or just <NAME> at global level"), but the file-level `symbols[]` shape never says whether a leading `::` is required, forbidden, or allowed. Two annotators reading §5.2's "preserve leading `::` if present" rule could split on whether a top-level `proc ::foo` symbol becomes `"::foo"` or `"foo"`.
  - The `note` field on the callee object is "optional-string, human-readable detail" with no canonical form, yet §5.3, §6.9, §6.12, and §7.2 all prescribe specific note text (`"$obj <method>"`, `"-command $cb"`, `"-validatemethod"`, etc.). It is unclear whether downstream tools may rely on those strings or treat them as freeform. A mechanical validator cannot enforce them.
  - `kind: "configbody"` appears in §4.1's `kind` enum and is referenced in §6.1, but `configbody` is NOT listed in §4.1's applicability rule for `visibility` ("populated for `method`, `class_method`, `constructor`, `destructor`, `configbody`" — actually it IS listed; on re-read this is fine, retracted). However, `configbody`'s relationship to `parent_classes` is unspecified: a configbody belongs to a class lexically but emits as a top-level out-of-line declaration; the schema does not say whether to populate `parent_classes` on it.
  - `unresolved_dispatches.subkind` enum lists 8 values; §5.14's table also lists 8. The two lists agree, but §5.7 re-purposes `computed_namespace` for dynamic `source` paths — a single subkind covering two distinct phenomena (computed namespace name + computed source path). A validator that wants to route on subkind will conflate them.
  - `lambda` qualified-name pattern `<enclosing>::__lambda_<line>` is convention but is not formally surfaced as a schema constraint (it appears in §5.9 and §8.3 narratively). If a validator wants to detect lambda symbols by name pattern alone, the rule should be in §4 or §7.
  - `file` field has type "<path-or-identifier>" with no further specification (absolute vs relative, normalization, case). Mechanical equality checks across annotation runs require this.
- Missing fields a consumer tool would obviously want:
  - **`schema_version`** on the top-level object. Convention is v1.1 and will continue to evolve; without a version field, consumers cannot detect/reject annotations produced under an older convention.
  - **`args` / `arity`** on the symbol object. Refactor tooling that wants to mechanically rename callsites needs to know parameter count to detect arity mismatches; cyclomatic-style analyzers need parameter count. Currently no field captures this even though it is trivially available from `proc NAME ARGS BODY`.
  - **`receiver_hint`** as a first-class field on `method_dispatch` callees. §5.3 stuffs it into `note: "$obj <method>"`; promoting it to a structured field would let blast-radius tools cluster method_dispatch callees by receiver-variable name without note-string parsing.
  - **`call_count`** or `occurrences` on a callee. Two calls to the same name from the same enclosing symbol currently produce two separate entries (implied but never stated) — or possibly one (also not stated). Either choice should be made explicit and a count surfaced for `find_references` density.
  - **`namespace_imports` / `namespace_exports`** is mentioned in §7.1 Tier 5 as MAY but is not in the schema in §4. If implementations opt to populate it, validators cannot know the field name or shape.

## §7.1 Tier filter findings

### Tier 1 (control flow)
- Completeness: `if`, `else`, `elseif`, `while`, `for`, `foreach`, `switch`, `catch`, `try`, `on`, `trap`, `finally`, `return`, `break`, `continue`, `yield`, `yieldto` covers the canonical control-flow keywords. **Missing** from Tier 1 / unclassified:
  - `lmap` — Tcl 8.6 script-bearing iterator; semantically a sibling of `foreach`. Currently it falls through to "ordinary static callee" treatment, which contradicts the convention's stated symmetry with `foreach`.
  - `time` — `time { script } N` evaluates a script `N` times. Its body should be walked but the dispatcher should not be a callee (like `expr`).
  - `error` is in Tier 3, but `throw` is also in Tier 3; `return -code error` is in Tier 3. `return` alone is in Tier 1. The split is fine, just inconsistent enough to note.
  - `update` and `vwait` (event-loop primitives) are not listed; they are not script-bearing but they ARE flow-control. They probably belong in Tier 3 (effectively I/O-shaped) but are currently unclassified.
- Carve-outs respected: yes — `coroutine` is correctly NOT in Tier 1 because it is a Tier-4 declaration (§7.1 Tier 4 list includes `coroutine`).

### Tier 2 (utilities + ensembles)
- Completeness: Tier 2 ensembles list is `string`, `dict`, `info`, `array`, `clock`, `chan`, `file`, `binary`, `namespace`, `package`, `encoding`. §7.5 reuses a similar list. Verified against tcl-lang.org:
  - `string` subcommands (cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, bytelength, wordend, wordstart) — all pure value ops; Tier 2 filtering is correct (verified at https://www.tcl-lang.org/man/tcl8.6/TclCmd/string.htm).
  - `dict` subcommands include `for`, `update`, `with`, `filter` (script form), `map` — all take a script body (verified at https://www.tcl-lang.org/man/tcl8.6/TclCmd/dict.htm). The convention's "How to apply" line for Tier 2 only names `dict for` and `dict update` as walked; **`dict with`, `dict map`, and `dict filter` (script form) are not mentioned** and their bodies will be silently dropped. This is the most concrete Tier-2 gap.
  - `file` subcommands (verified at https://www.tcl-lang.org/man/tcl8.6/TclCmd/file.htm) — all pure ops; Tier 2 is correct.
- Tier 2 also lists `regexp`, `regsub`, `subst` correctly as scalar utilities. **Missing single-word utilities** that fit Tier 2's "pure data operations" rationale:
  - `concat`, `eof`, `tell`, `seek`, `flush` — pure data / channel-state ops with no script bodies.
  - `global`, `variable`, `my` (TclOO self-call helper). `global`/`variable` are scoping declarations; arguably they belong in Tier 5 or Tier 2 but are currently unclassified.
  - `tcl::prefix`, `lmap` — see Tier 1 note for `lmap`.
- Carve-outs respected: yes — §7.5 plus §5.10 explicitly say `grid`, `pack`, `place`, `wm`, `winfo`, and iTcl `delete` are NOT on Tier 2 and ARE kept as `static` 2-word callees. The Tier 2 prose also includes a "NOT Tier 2" callout for Tk widget creation. Consistent.

### Tier 3 (I/O and error)
- Completeness: `puts`, `gets`, `read`, `error`, `throw`, `return -code error ...`. Missing: `flush`, `close`, `open`, `socket` (non `-server` form), `chan` ensemble already in Tier 2. `open` and `close` are particularly notable — they appear constantly in real-world code and currently fall through to `static` callees, which clutters call graphs without architectural value.
- The carve-out for `socket -server CMDPREFIX` (§6.9) is good; bare `socket` falls through to static, which is arguably correct (it's an I/O constructor) but inconsistent with `open`.

### Tier 4 (declarations)
- Completeness: covers `proc`, all method-kinds, `itcl::body`, `itcl::configbody`, `constructor`, `destructor`, `namespace eval`, `itcl::class`, `itcl::widget`, `itcl::extendedclass`, custom `class` DSL, `oo::class create`, `coroutine`, `itk_component add`, `itk_option define`, `itcl::option`, `itcl::component`. Missing:
  - `oo::define` (used for `mixin`, `forward`, adding methods to existing classes — see §8.8). It is mentioned in Limitations but not in Tier 4's declaration list, leaving its callee/symbol treatment unspecified.
  - `oo::objdefine` — same family; not mentioned anywhere.
  - `interp create` — declares a callable subordinate interpreter; arguably a Tier-4 symbol. Currently treated as ordinary static callee.
- Carve-outs respected: yes.

### Tier 5 (imports / structural)
- Completeness: `package require`, `package provide`, `source`, `inherit`, `superclass`, `namespace import`, `namespace export`. Note that `namespace import`/`export` are listed in Tier 5 but §7.1 says implementers MAY add a `namespace_imports` array — that field is not in §4 schema. Either (a) the field should be added to §4 with shape spec, or (b) the MAY clause should be deferred to "Out of scope" §9.
- Missing: `auto_load`, `auto_import`, `tm path add` — these participate in the dependency / loading surface and produce no useful callee, but currently fall through.
- Carve-outs respected: yes.

## §7.2 Unresolved-pattern naming
- Consistency: good. The four naming rules (method-word, "?", "?"+subkind, method-word-or-?) are coherent and each carries a Rationale line. The rules track §5.14's table.
- Refactor-utility: strong. The choice to preserve the method-word as `name` (rather than "?") for `$obj method` is the right call for find-references and is explicitly justified.
- One ambiguity: §7.2 says callback-flag with `$var` value gets `name = "?"`, while §6.12 says variable-bound callback also gets `name = "?"`, but the `note` for both is `-command $cb`. Two paths to the same outcome — fine, but worth a single normative source.

## §7.5 Ensemble 2-word naming
- Coherence with §5.10 carve-outs: yes. §7.5 explicitly addresses the Tk geometry / window-management carve-out (`grid forget`, `pack configure`, `wm title`, `winfo children`, `delete object`) and pins `kind: "static"` for kept ensembles while reserving `kind: "ensemble"` for opt-in ensembles. The split is principled and load-bearing.
- One minor inconsistency: §7.5 lists the documented-ensemble set as `string, dict, info, array, chan, file, clock, namespace, package, binary, encoding`. §7.1 Tier 2 lists the same set. §5.10 lists `string, dict, info, array, chan, namespace, file, clock, package` — same set in different order, but **missing `binary` and `encoding`** at §5.10. Cosmetic but it triggers reader doubt about whether §5.10 is canonical. Either normalize §5.10 to include all 11 ensembles or have it explicitly defer to §7.1/§7.5.

## Layer B rationale audit
Every §7 rule has a `Rationale:` line. Quality varies:
- §7.1 Tier 1 rationale ("primitives structure execution but say nothing about what is being called") — load-bearing and clear.
- §7.1 Tier 2 rationale ("pure data operations") — clear, but does not explain why `dict for`/`dict update` bodies ARE walked (the asymmetry is justified only by parenthetical aside in "How to apply"). Removing that aside would silently change the semantics. Promote it to a Rationale clause.
- §7.1 Tier 3 rationale ("not architectural call edges. Excluding them mirrors what a human reader skims past") — adequate but weaker than Tier 1/2. The "human skims past" framing is subjective; a stronger framing would be "the actual I/O target (channel, file) is the architectural fact, recorded elsewhere".
- §7.1 Tier 4 rationale ("each names a callable, container, or component") — clear and load-bearing.
- §7.1 Tier 5 rationale ("structural facts belong in dedicated fields") — clear and load-bearing.
- §7.2 four sub-rationales — each is load-bearing.
- §7.3 schema-consistency rationale — explicitly load-bearing (cites consumer-iteration patterns).
- §7.4 FQN-preservation rationale — strongly load-bearing; explicitly enumerates why resolution is impossible statically.
- §7.5 ensemble-naming rationale — load-bearing.
- §7.6 empty-bodies rationale — load-bearing.
- §7.7 comments-ignored rationale — purely restates spec; not load-bearing in the convention sense (could be moved to Layer A or deleted with no semantic loss). Removing it would not degrade the convention's consumer goal.

## Recommendations
- **Schema:** add `schema_version` to top-level object; specify `qualified_name` normalization for global symbols (leading `::` or not); promote `note` strings to a named enum or formally mark freeform; add `args`/`arity` field to symbol object for refactor tooling; split `computed_namespace` subkind into `computed_namespace` + `computed_source` to disambiguate §5.7's re-purposing.
- **Tier 1:** add `lmap` and `time` (script-bearing iterators not in any tier today).
- **Tier 2:** extend "bodies walked" exceptions to include `dict with`, `dict map`, `dict filter` (script form) to match the official `dict` man page. Add `flush`, `close`, `concat`, `eof`, `seek`, `tell` for completeness.
- **Tier 3:** add `open`, `close` (high-frequency I/O ops cluttering call graphs).
- **Tier 4:** clarify treatment of `oo::define`, `oo::objdefine`, `interp create` (currently only `oo::define mixin`/`forward` is touched in §8.8 Limitations).
- **§5.10 ensemble list:** add `binary` and `encoding` to match §7.1 / §7.5 lists, or explicitly say "see §7.1 Tier 2 for the canonical set".
- **§7.7:** either delete or move to Layer A (it is spec-restatement, not a Layer-B convention choice).
- **§4 schema text:** add an explicit "absent fields are an error" sentence so mechanical validators have an unambiguous closed-schema posture (currently §4.1 says "all fields are mandatory unless marked optional" but `note` on callees is "optional-string" while §4.2's callee object lists it as a key — clarify whether `note` may be absent or must be `""`/`null`).
- **`namespace_imports` field:** either add to §4 schema with a defined shape or move the MAY clause from §7.1 Tier 5 to §9 Out of scope.
