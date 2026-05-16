# Layer A audit — TCL_CALLGRAPH_CONVENTION.md §5 + §6

## Overall verdict: PASS_WITH_NOTES
Layer A rules are substantively faithful to the official Tcl 8.6 / iTcl 4.x reference
pages. All semantic claims I spot-checked match the spec. The notes below cover a 404
citation, two minor wording/edge-case omissions, and one classification borderline
where a rule labeled Layer A also bakes in a convention-level choice that already has
an explicit Layer B home elsewhere in the document.

## Per-section findings

### §5.1 Direct call (Pattern A)
- Verdict: conforms
- Notes: Tcl(n) rule [2] ("the first word is used to locate a command procedure")
  and rule [11] (substitution order) support the claim that a literal first word is
  statically identifiable. The wording "after backslash and (where applicable)
  variable/command substitution" is consistent with rules [3], [7], [8], [11] on
  https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm. The self-method clarification
  (bare literal inside a method body recorded as `static` rather than as
  self-dispatch on `$this`) is a convention choice but is appropriately labeled as
  such ("The convention does not distinguish implicit self-dispatch from a global
  proc call") and is not advanced as a spec claim.

### §5.2 Qualified call (Pattern A2)
- Verdict: conforms
- Notes: The namespace.htm resolution description ("Fully-qualified name beginning
  with `::` unambiguously refers to..."; "Command names are always resolved by
  looking in the current namespace first... command path... global namespace")
  matches the rule exactly. Preserving the source-form verbatim is correctly noted
  as a static-analysis constraint, not a spec claim.

### §5.3 Object dispatch (Pattern B)
- Verdict: conforms
- Notes: ItclCmd/class.html confirms that `objName method` invokes a method named
  `method` on the object. Tcl(n) rule [8] (variable substitution) supports the
  claim that `$obj` is statically unresolvable in the general case. The
  bracketed-receiver carve-out (`[$itk_component(eu) childsite]`) is a
  convention-level static-analysis rule, not a spec claim, and the doc presents it
  that way.

### §5.4.1 `itcl::class NAME { BODY }`
- Verdict: conforms
- Notes: class.html lists exactly the directives the rule names (`inherit`,
  `constructor`, `destructor`, `method`, `proc`, `variable`, `common`,
  `public/protected/private`).

### §5.4.2 Custom `class NAME { BODY }` DSL (D9)
- Verdict: misclassified (minor)
- Notes: This is labeled Layer A but is a project-policy alias decision — the spec
  does NOT define a bare `class` command. The rationale ("the DSL is documented in
  those ecosystems as a 1:1 alias for `itcl::class`") is ecosystem-specific
  (bluice/dcss), not a Tcl/iTcl language specification. Recommend either moving
  this to Layer B with a clear `Rationale:` line or adding a "Layer A by analogy
  to §5.4.1, conditional on the alias being lexically present" qualifier.

### §5.4.3 `itcl::widget` / `itcl::extendedclass`
- Verdict: conforms
- Notes: itclwidget.html confirms the directive list. Note that the iTcl 4 widget
  page treats `component` and `option` as cross-referenced (delegated to the
  `itclcomponent.html` / `itcloption.html` pages); the convention's claim that
  these directives apply is correct.

### §5.4.4 `namespace eval NS { BODY }`
- Verdict: conforms
- Notes: namespace.htm confirms the form `namespace eval namespaceName scriptBody`
  and that additional args are concatenated. The `computed_namespace` bucket for
  `namespace eval $name {...}` is consistent with the spec's note about argument
  concatenation prior to evaluation.

### §5.4.5 `oo::class create NAME { BODY }` (TclOO)
- Verdict: conforms
- Notes: TclOO contents page confirms the existence of `oo::class create`. The
  convention's choice to treat it as semantically equivalent to `itcl::class` for
  symbol-extraction purposes is faithful — both produce a class command with
  method/constructor/destructor directives, and §5.3 dispatch applies uniformly.

### §5.4.6 `itk_component add` and `itcl::component`
- Verdict: conforms
- Notes: itclcomponent.html (cross-ref from itclwidget.html) supports the
  "component slot, not callable" interpretation. The claim that the BODY of
  `itk_component add` is a creation script (and is walked) matches the iTk
  documented behavior. Layer A status is appropriate.

### §5.5 Method declarations and visibility
- Verdict: conforms with one note
- Notes: class.html confirms the recognized directives and the visibility
  prefixes. Spec drift note: the convention says "The iTcl 3.x default is
  `private` for variables and `public` for methods; this convention does NOT
  infer defaults". The class.html page I fetched does not state defaults
  explicitly, so the convention's choice to emit `null` (rather than commit to a
  contested default) is defensible and well-justified. No change needed.

### §5.6 Inheritance (`inherit`, `superclass`)
- Verdict: conforms
- Notes: class.html confirms `inherit`; TclOO's `oo::define ... superclass` (from
  the TclOO contents) supports the parallel rule. Treating these as NOT-callees
  is a convention choice that lines up with Tier 5 in §7.1; the spec claim
  (these introduce inheritance, not call edges at definition time) is correct.

### §5.7 Imports (`package require`, `package provide`, `source`)
- Verdict: conforms
- Notes: package.htm confirms `package require NAME ?VERSION?` and
  `package provide NAME ?VERSION?`. source.htm confirms that PATH is read and
  evaluated as a Tcl script. The "NOT a callee" decisions are Tier-5 routing
  (Layer B), and that is correctly cross-referenced. The repurposing of the
  `computed_namespace` `subkind` for dynamic `source $path` is a small convention
  smell — recommend a dedicated `subkind` like `computed_source` for clarity, but
  it does not contradict the spec.

### §5.8.1 `eval LITERAL ARGS` (D1)
- Verdict: conforms
- Notes: eval.htm: "concatenates all its arguments in the same fashion as the
  **concat** command, passes the concatenated string to the Tcl interpreter
  recursively". With a literal first word and value-only remaining args, the
  resulting concat is deterministically a call to that word. The Tier-filter
  composition language ("Record the call as though the `eval` wrapper were not
  present — Tier filters then apply normally") is appropriate and consistent with
  the spec.

### §5.8.2 `eval $script ...` (D3)
- Verdict: conforms
- Notes: When the first effective argument is a variable substitution, eval.htm's
  concatenate-and-reparse semantics make the callee identity statically
  unknowable; the convention correctly surfaces it as `unresolved` with
  `subkind: "eval_var"`.

### §5.8.3 `eval [foo ...] ARGS`
- Verdict: conforms
- Notes: Per Tcl(n) rule [7] (command substitution returns a value), the value is
  not statically identifiable as a command. The rule that the bracketed script's
  callee (`foo`) IS recorded as a call is correct under rule [7] — that command
  runs regardless of how its result is used.

### §5.9 `apply LAMBDA ARGS`
- Verdict: conforms
- Notes: apply.htm confirms `{args body}` or `{args body namespace}`. The
  `__lambda_<line>` naming is a convention choice but is correctly framed as
  such; the body-walking rule is faithful to the spec.

### §5.10 Ensemble subcommands (D2)
- Verdict: conforms (with Layer A/B split correctly flagged)
- Notes: info.htm clearly documents `info` as an ensemble ("The legal _option_s
  (which may be abbreviated) are..." with a subcommand list including `args`,
  `body`, `class`, `commands`, `complete`, `coroutine`, `default`, `errorstack`,
  `exists`, `frame`, `level`, `script`, etc.). The convention correctly notes
  that the runtime may compile ensembles to bytecode/FQN/dispatch — that detail
  is below the convention. The "kept ensembles" carve-out (Tk geometry +
  iTcl `delete`) is a Layer B filtering choice and is cross-referenced to §7.5.
  This section explicitly says the 2-word naming choice is Layer B (§7.5),
  which keeps the layer split clean.

### §5.11 Bracket substitution `[foo arg]`
- Verdict: conforms
- Notes: Tcl(n) rule [7] is the direct citation; the rule that each bracketed
  script is recursively walked is the standard interpretation.

### §5.12 Callback/script sites — see §6.12
- Verdict: conforms (pointer)

### §5.13 `uplevel` and `upvar`
- Verdict: conforms
- Notes: uplevel.htm: "All of the _arg_ arguments are concatenated as if they had
  been passed to **concat**; the result is then evaluated in the variable context
  indicated by _level_." Treating SCRIPT analogously to `eval` semantics is
  correct. `upvar` is variable aliasing only — no command-position evaluation —
  so emitting no callee is faithful to the spec.

### §5.14 Other unresolved variants
- Verdict: conforms
- Notes: Table is internally consistent. Note the same `computed_namespace`
  reuse concern as §5.7 if `source $path` is mapped here in practice; consider a
  distinct `computed_source` subkind. Not a spec conflict.

### §6.1 `itcl::body`, `itcl::configbody`
- Verdict: conforms
- Notes: body.html confirms that `itcl::body` defines/redefines a class member's
  body and works in tandem with in-class forward declarations
  (`method NAME` without body). The forward-declaration dedup (emit ONE symbol,
  use the body's `line`/`end_line` as canonical) is a convention choice and is
  appropriately framed. configbody.html confirms configbody applies only to
  PUBLIC variables, which matches the rule's `visibility = "public"` claim
  exactly.

### §6.2 `proc`
- Verdict: conforms
- Notes: proc.htm matches: "BODY is stored, not evaluated at definition time".
  Walking BODY for inner callees is the correct static treatment.

### §6.3 Coroutines (D8)
- Verdict: conforms
- Notes: coroutine.htm: "creates a new coroutine context (with associated
  command) named _name_ and executes that context by calling _command_". The
  rule's "If COMMAND is a literal command word, record it as a static callee" is
  correct. The rule additionally says "If COMMAND is a script (a brace literal),
  walk it as the coroutine body" — strictly, the spec says
  `coroutine NAME COMMAND ARGS...` invokes a COMMAND, not an arbitrary script;
  treating a brace-literal in COMMAND position as a walkable script is a
  convention-level analogy (resembling apply-lambda) more than a direct spec
  claim. Recommend a half-sentence noting this is by-analogy. The yield/yieldto
  Tier-1 routing is consistent with the page's description that yield "pauses
  execution" — flow control, not a call edge.

### §6.5 `try` / `on` / `trap` / `finally`
- Verdict: conforms
- Notes: try.htm matches: `try _body_ ?_handler..._? ?finally _script_?`, with
  `on code variableList script` and `trap pattern variableList script` handlers.
  Walking each as a Tcl script is faithful.

### §6.6 `switch` bodies
- Verdict: conforms
- Notes: switch.htm confirms both spread and grouped forms and the "-"
  fall-through semantic. Walking each non-"-" body for inner callees is the
  correct treatment.

### §6.7 `if` / `while` / `for` / `foreach` bodies
- Verdict: conforms
- Notes: Final-argument-is-a-body semantics is canonical control flow. The doc
  cites foreach.htm explicitly and relies on Tcl(n) for the rest, which is
  reasonable. Walking bodies is correct.

### §6.8 `expr {EXPR}` and `expr EXPR`
- Verdict: conforms
- Notes: expr.htm matches: math functions resolve to `tcl::mathfunc::*` commands,
  and bracketed substitution timing differs between braced and unbraced forms.
  The rule's "MAY be recorded as `tcl::mathfunc::sin` (optional)" stance is
  defensible and explicitly Layer A optional. Treating `expr` itself as Tier-2
  utility (not a callee) is consistent with §7.1.

### §6.9 Tk script-accepting commands
- Verdict: conforms
- Notes: bind.htm, after.htm, fileevent.htm, trace.htm, socket.htm all confirm
  the cited callback shapes and append-arg behaviors. Specifically:
  - after.htm: multiple SCRIPT args are "concatenated in the same fashion as the
    **concat** command" — matches.
  - trace.htm: `trace add variable` appends `name1 name2 op`, `trace add command`
    appends `oldName newName op`, `trace add execution` appends
    `command-string ?code result? op` — matches.
  - socket.htm: `-server` callback receives `(channel, address, port)` — matches.
  - bind.htm: SCRIPT runs at global level, with `%`-substitution — matches; the
    convention's choice to ignore `%` substitution at the static layer is a
    convention call and is reasonable (any `%X` substitution produces data, not a
    new call edge).
  The convention's rule that the DISPATCHER (`bind`/`after`/`fileevent`/
  `trace add ...`/`socket -server`) is NOT itself a static callee is a Layer B
  choice; here it is presented under Layer A. Since the layer note at the end of
  §6.12 acknowledges the naming is Layer B, consider explicitly tagging the
  "dispatcher is not a callee" rule as Layer B as well. Functionally this is
  already covered by §7.1's "How to apply" prose, so the impact is small.

### §6.10 Tk widget creation and configure callbacks
- Verdict: conforms
- Notes: TkCmd index supports the option-flag callback model. The rule is
  appropriately a pointer to §6.12.

### §6.11 `itk_option define` / `itcl::option`
- Verdict: conforms
- Notes: itcloption.html confirms `-validatemethod`, `-configuremethod`,
  `-cgetmethod`, plus the `-*methodvar` runtime-variable variants. The rule
  covers the three direct method-name flags. Suggest adding a sentence noting
  the `-cgetmethodvar`/`-configuremethodvar`/`-validatemethodvar` variants as
  `callback_var` analogs (dynamic-method-name flags), to round out the surface.
  This is a small gap, not a contradiction.

### §6.12 Callback / script sites
- Verdict: conforms (Layer A semantics + Layer B naming, correctly flagged)
- Notes: Each cited man page (bind, after, fileevent, trace, coroutine,
  `itk_initialize`) supports the "script evaluated at event/configure time"
  basis. The four classifications (pure callback / multi-command / variable /
  bracket) align with the substitution rules in Tcl(n). The rule explicitly
  notes that the method-as-callback naming is Layer B (§7.2), which keeps the
  layer split clean.

## Layer A/B classification audit

- §5.4.2 (custom `class NAME BODY` DSL) is the most defensible candidate for
  reclassification as Layer B (or as a Layer A rule explicitly conditioned on
  the alias being lexically introduced by `interp alias`/`rename`/equivalent in
  the file). The Tcl/iTcl spec does NOT define a bare `class` command at the
  language level; this is purely a vendor-DSL convention. The doc cites
  class.html for the BODY grammar, which is fine for the BODY semantics, but
  treating the bare token `class` as a class definer is a project-policy
  decision.
- §6.9 contains an embedded Layer B choice ("the dispatcher itself is NOT
  recorded as a static callee") that is also expressed in §7.1's
  "How to apply" prose. Consider adding an explicit pointer
  ("Naming choice is Layer B — see §7.1 Tier-1 handling") so a reader applying
  Layer A alone is not led to record the dispatcher.
- §5.10 mostly avoids this: it explicitly tags the 2-word naming as Layer B
  (§7.5). The carve-out language ("kept ensembles") is appropriately scoped.
- Everything else in §5 and §6 cleanly separates the spec claim from the
  annotation choice and points at the relevant Layer B section for the latter.

## Citations cross-check

Pages fetched and verified:

- https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm — rules [2][3][7][8][10][11]
  cited in §5.1, §5.2, §5.11, §7.7 all align with the page text.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/eval.htm — concat-then-reparse
  semantics support §5.8.1, §5.8.2, §5.8.3.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/namespace.htm — resolution rules
  (current namespace → command path → global; leading `::` absolute) support
  §5.2; `namespace eval namespaceName scriptBody` syntax supports §5.4.4.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/apply.htm — `{args body}` /
  `{args body namespace}` form supports §5.9.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/coroutine.htm — NAME/COMMAND
  semantics and yield/yieldto descriptions support §6.3 (with the by-analogy
  note above about script-body COMMAND).
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/uplevel.htm — concat-then-eval
  supports §5.13.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/expr.htm — `tcl::mathfunc::*`
  resolution and braced-vs-unbraced bracket timing support §6.8.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/trace.htm — appended-arg patterns
  for `trace add variable / command / execution` support §6.9.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/after.htm — multi-script
  concatenation and `after idle` semantics support §6.9.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/fileevent.htm — global-level
  script evaluation supports §6.9.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/socket.htm — `(channel, host,
  port)` callback args support §6.9.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/source.htm — read-and-evaluate
  semantics support §5.7.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/package.htm — `require`/`provide`
  forms and `package`-as-ensemble subcommands support §5.7 and §5.10.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/switch.htm — both syntactic forms
  and `"-"` fall-through support §6.6.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/try.htm — body/on/trap/finally
  support §6.5.
- https://www.tcl-lang.org/man/tcl8.6/TclCmd/info.htm — ensemble status and
  subcommand list support §5.10.
- https://www.tcl-lang.org/man/tcl8.6/TkCmd/bind.htm — global-level script
  evaluation supports §6.9.
- https://www.tcl-lang.org/man/tcl/ItclCmd/class.html — body directives and
  dispatch semantics support §5.3, §5.4.1, §5.5, §5.6.
- https://www.tcl-lang.org/man/tcl/ItclCmd/body.html — forward-declaration
  relationship supports §6.1.
- https://www.tcl-lang.org/man/tcl/ItclCmd/configbody.html — public-only
  applicability supports §6.1.
- https://www.tcl-lang.org/man/tcl/ItclCmd/itclwidget.html — directives
  support §5.4.3.
- https://www.tcl-lang.org/man/tcl/ItclCmd/itcloption.html — handler-method
  options and their `*methodvar` variants support §6.11 (with the variant gap
  noted).

Broken citation:

- https://www.tcl-lang.org/man/tcl/ItclCmd/itcldelete.html — the URL cited in
  §5.10 for `delete object / class / namespace` returned HTTP 404 at audit time.
  The §10 references section already acknowledges that some iTk-specific pages
  are 404 and substitutes are used; the §5.10 inline citation should either
  point at the ItclCmd index (https://www.tcl-lang.org/man/tcl/ItclCmd/index.html)
  or note the 404 alongside a substitute (e.g., the Tcler's Wiki
  https://wiki.tcl-lang.org/page/itcl%3A%3Adelete or the ItclCmd index).

## Recommendations

- Replace the 404 `itcldelete.html` citation in §5.10 with the ItclCmd index or
  a working substitute, mirroring the substitution pattern already used in §10.4
  for iTk pages.
- Reclassify §5.4.2 (bare `class NAME BODY` DSL) as Layer B with an explicit
  `Rationale:` line, OR add a half-sentence clarifying that it is Layer A only
  by analogy to §5.4.1 conditional on the ecosystem alias being present in the
  source (it is not a Tcl/iTcl spec construct).
- Introduce a dedicated `subkind` for dynamic `source $path` (e.g.,
  `computed_source`) instead of repurposing `computed_namespace` in §5.7 and the
  §5.14 table; document the new value alongside the existing eight in the §4.3
  enum.
- §6.3: add one sentence noting that "if COMMAND is a brace-literal script,
  walk it" is a by-analogy extension of the spec's `coroutine NAME COMMAND
  ARGS...` form (the spec's COMMAND is a command word; the brace-literal-as-
  body interpretation is convention-level).
- §6.11: extend the rule to mention `-cgetmethodvar` / `-configuremethodvar` /
  `-validatemethodvar`, treating their dynamic method names as `callback_var`
  unresolved entries; itcloption.html documents these as runtime-variable
  variants of the corresponding `*method` flags.
- §6.9: tag the "the dispatcher is NOT a callee" choice as Layer B (it is a
  filtering decision already in §7.1) so a reader applying Layer A alone is not
  misled into recording `bind`/`after`/etc.
