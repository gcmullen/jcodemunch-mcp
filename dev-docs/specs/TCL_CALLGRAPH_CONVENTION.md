# TCL / iTcl / Tk / iTk Call-Graph Convention

**Status:** DRAFT
**Version:** 1.3
**Date:** 2026-05-16
**Changelog from v1.2:** §4.1 add `args` (list-of-strings) and `arity` (int) to symbol object for callable kinds; §4.2 / §5.3 add `receiver_hint` to method_dispatch callees; §7.1 Tier 1 add `lmap`, `time`; §7.1 Tier 2 add `flush`, `seek`, `tell`, `concat`, `eof`, `global`, `variable` (the last two formalize Phase 2 arbiter verdicts on Clock/DEG_HORZ); §7.1 Tier 2 body-walk exceptions extended to `dict with`, `dict map`, `dict filter` (script form); §7.1 Tier 3 add `open`, `close`, `update`, `vwait`; §7.1 Tier 4 add `oo::define`, `oo::objdefine`, `interp create`; §7.1 Tier 5 add `auto_load`, `auto_import`, `tm path add`; §5.10 / §7.5 add `image create TYPE` as a documented 3-word ensemble phrase (P3.1 — formalizes 5 Scan3DView Phase-2 `convention_ambiguous` verdicts); §5.8.2 extends D3 with `eval $cb args` recognition as `callback_var` (P3.1 — formalizes 1 AsyncGets ambiguity); §5.10 adds qualified-name-vs-ensemble precedence rule (`::dcss configure` is 1-word qualified, not 2-word ensemble) and §7.2 / §5.14 add `${var}`-in-callee-name handling rule (must emit `name: "?"`, not the interpolated literal) — both P3.1-canary follow-ups closing the 2 new ambiguous verdicts surfaced when BeamlineVideo was re-run under v1.3. §7.1 Tier 2 adds `list` (the value-constructor, sibling of `concat`/`lappend` — P3.1-canary-2 Clock.tcl follow-up). §5.4.2 clarifies that DSL-implementation files (e.g. files defining `proc class {...}`) are annotated as ordinary procedural Tcl, not as §5.4.2 class definers — P3.1-canary-2 git-gui/class.tcl follow-up. All v1.3 changes require re-annotation to populate (new schema fields) or to apply new filters (Tier changes). The remaining Phase 2 ambiguities (§5.14 null-line × 3, §5.1 dispute-record × 4) were tooling-side and resolved by T6 (forcing-example prompt) + T8 (honest dispute classifier) earlier in P3.0.
**Changelog from v1.1:** §4 add `schema_version` top-level field; §4.3 add `computed_source` subkind (split from `computed_namespace`); §5.4.2 add by-analogy qualifier; §5.7 / §5.14 retarget dynamic-source-path to `computed_source`; §5.10 fix broken `itcldelete.html` citation + normalize ensemble list with §7.1/§7.5 (add `binary`, `encoding`); §6.3 add by-analogy note for brace-literal COMMAND; §6.9 explicit Layer B tag on "dispatcher is NOT a callee"; §6.11 add `-cgetmethodvar` / `-configuremethodvar` / `-validatemethodvar` callback_var variants; §7.7 reframed as parser prerequisite (no longer a Layer B rule); §4.2 `note` field policy clarified.
**Changelog from v1.0:** §5.1 self-method clarification; §5.3 method-word literal + variable-receiver requirement; §5.8.1 Tier-filter composition with D1; §6.12 value-shape-driven callback recognition; §7.1 Tier-2 ensemble list harmonized with §7.5.
**Audience:** LLM annotators producing JSON call-graph annotations for Tcl source files; humans authoring test fixtures.

---

## 1. Mission

This document defines a two-layer convention for identifying callable symbols and call edges in Tcl 8.6, [incr Tcl], Tk 8.6, and [incr Tk] source. Given a single `.tcl` / `.itcl` / `.itk` / `.tk` source file, a reader applying this convention emits a JSON annotation listing every symbol declared in the file and every call edge attributable to that symbol's body. The annotation is intended to support call-hierarchy navigation, reference-finding for safe refactoring, bug investigation, and explanation of class hierarchies in iTcl/iTk codebases.

## 2. Independence statement

The rules below derive **only** from the official Tcl 8.6, Tk 8.6, [incr Tcl], and [incr Tk] reference docs cited inline and in §10. No project-internal parser, indexer, or tool is referenced. Two readers applying this convention to the same source MUST produce equivalent annotations modulo whitespace and key order. Where a runtime semantic admits multiple static encodings, the doc either fixes the choice (Layer B) or enumerates the unresolved variant (Layer A).

## 3. Two-layer principle

Every rule below belongs to exactly one of two layers.

**Layer A — Semantic rules.** Facts about how Tcl/iTcl/Tk/iTk constructs evaluate at runtime, per the official reference manuals. Each Layer A rule cites at least one official page. Two readers applying Layer A alone should arrive at the same annotation.

**Layer B — Filtering and utility rules.** Convention choices justified by the consumer goal in §1. NOT derivable from spec. Each Layer B rule carries an explicit `Rationale:` line.

The separation is load-bearing: if a future use case justifies a different convention, only Layer B may change without re-verification against the language spec.

## 4. JSON annotation schema

An annotation for a single source file is a JSON object with this shape. All fields are mandatory unless marked optional; absent data uses `[]` or `null` per the rule given.

```json
{
  "schema_version": "1.2",
  "file": "<basename>",
  "language": "tcl" | "itcl" | "tk" | "itk",
  "symbols": [ <symbol>, ... ],
  "file_level": {
    "package_requires": ["<pkg-name>", ...],
    "package_provides": [{"name": "<pkg-name>", "version": "<version-or-null>"}, ...],
    "imports": ["<source-path>", ...],
    "callees": [ <callee>, ... ]
  }
}
```

**`schema_version`** is the convention version this annotation was produced under (e.g. `"1.3"`). Consumers MUST check this field and reject or migrate annotations produced under an older incompatible version. Older annotations (pre-v1.2) lack this field; readers may treat missing `schema_version` as `"1.1"` for backward compatibility.

**`file`** is the source file's basename (e.g. `"AutoSample.tcl"`), not an absolute or relative path. Path-form values are rejected to avoid leaking corpus-origin info into the annotation surface.

**Field-shape requirements (strict):**
- `language` is one of `"tcl"`, `"itcl"`, `"tk"`, `"itk"` and is determined purely by the source file's **extension** (case-insensitive): `.tcl→tcl`, `.itcl→itcl`, `.tk→tk`, `.itk→itk`. Content does not override the extension — an `.tcl` file using `itcl::class` is still `"tcl"`. This is the author's declared intent; downstream consumers can detect actual dialect from content if needed. The orchestrator lower-cases before storing. Multi-flavor synonyms like `"Tcl/iTcl"` are NOT accepted.
- `package_requires` is an array of **bare strings** — just the package name, e.g. `["Itcl", "DependencyInjector"]`. Never `[{name, version}]` objects. Version requirements, if needed by the source, are recorded only inside `package_provides`.
- `imports` is an array of **bare strings** — verbatim source paths from `source PATH`. Never objects.
- `package_provides` is the only field that uses `[{name, version}, ...]` objects (`version` may be `null`).
- File-level `package_requires` / `package_provides` / `imports` apply when the declaration is lexically at top level. Inside a symbol body, those fields go on the symbol — but they MUST NOT be duplicated from `file_level` onto enclosing class/namespace symbols. A class symbol whose body contains no `package require` lines has `package_requires: []`, even if the file itself has top-level `package require` calls above the class.

### 4.1 Symbol object

```json
{
  "qualified_name": "<ns::path::symbol>",
  "line": <int, 1-indexed line where declaration begins>,
  "end_line": <int, 1-indexed line where declaration body ends>,
  "kind": "proc" | "method" | "class_method" | "constructor" | "destructor"
        | "class" | "namespace" | "coroutine" | "configbody" | "lambda",
  "visibility": "public" | "private" | "protected" | null,
  "parent_classes": ["<class-name>", ...],
  "args": ["<arg-name>", ...],
  "arity": <int>,
  "package_requires": ["<pkg-name>", ...],
  "package_provides": [{"name": "<pkg-name>", "version": "<version-or-null>"}, ...],
  "imports": ["<source-path>", ...],
  "callees": [ <callee>, ... ],
  "unresolved_dispatches": [ <unresolved>, ... ]
}
```

Field applicability by kind:

- `qualified_name`, `line`, `end_line`, `kind` — required on every symbol.
- `visibility` — populated for `method`, `class_method`, `constructor`, `destructor`, `configbody`. `null` for all other kinds.
- `parent_classes` — populated only for `class`. `[]` otherwise.
- `args` / `arity` — populated for `proc`, `method`, `class_method`, `constructor`, `lambda` (anything that takes a positional argument list at the declaration site). `args` is the verbatim ordered list of formal-parameter names from the source — without any default-value brackets (`{name default}` → `"name"`). `arity` is `len(args)`. For variadic procs whose final parameter is `args`, `arity` is the count INCLUDING the `args` parameter (e.g. `proc foo {a b args}` → `args: ["a", "b", "args"], arity: 3`); consumers detect variadic by `args[-1] == "args"`. `args: [], arity: 0` for `class`, `namespace`, `destructor`, `coroutine`, `configbody` (which take no positional list at declaration).
- `callees`, `unresolved_dispatches` — `[]` for `class` and `namespace` symbols (containers); populated for the other kinds.
- `package_requires`, `package_provides`, `imports` — populated only when those declarations occur lexically inside the symbol's body. Top-level declarations populate the `file_level` block instead.
- All array fields obey §7.3: always an array, possibly empty, never `null` and never absent.

### 4.2 Callee object

```json
{
  "name": "<callee-name>",
  "line": <int, 1-indexed line of the call site>,
  "kind": "static" | "ensemble" | "callback" | "qualified" | "method_dispatch"
        | "lambda" | "unresolved",
  "receiver_hint": "<optional-string, see below>",
  "note": "<optional-string, human-readable detail>"
}
```

**`receiver_hint` policy:** populated ONLY when `kind == "method_dispatch"`. Carries the verbatim source-form of the receiver expression: `"$obj"`, `"${obj}"`, `"$itk_component(eu)"`, `"$itk_component(notebook)"`, etc. This is the literal receiver word from the source command, copied verbatim (no normalization, no `${}` stripping). Lets refactor and blast-radius tools cluster `method_dispatch` calls by receiver variable without parsing the freeform `note`. Absent or empty on all other `kind` values.

**`note` policy:** the `note` field is optional and human-readable. Several sections (§5.3, §6.9, §6.12, §7.2) recommend a specific note shape for particular call patterns (e.g. `"$obj <method>"` for method_dispatch). Downstream tools MAY rely on the recommended shapes when present, but the field is not a closed enum — annotators MAY omit it or use the freeform form. A missing `note` is equivalent to an empty string; tools MUST tolerate either.

- `static` — first word is a literal command identifier (Pattern A).
- `qualified` — first word is a literal `::`-separated multi-segment name.
- `ensemble` — first two words form a documented ensemble subcommand (Layer B, §6.10).
- `method_dispatch` — `$obj method args` form; `name` is the method (Layer A §6.3).
- `callback` — appears as the body of a Tk/iTk script-accepting command or callback-flag option (§6.12).
- `lambda` — produced by an `apply` site with a literal lambda (§6.9).
- `unresolved` — the callee identity is not statically determinable; see §7.2 for naming conventions.

### 4.3 Unresolved dispatch object

For unresolved call sites the annotator MAY also list a richer record in `unresolved_dispatches` so downstream tools can recover more than a single name:

```json
{
  "line": <int>,
  "subkind": "var_command" | "var_method" | "callback_var"
           | "eval_var" | "eval_brackets" | "interp_eval"
           | "computed_namespace" | "computed_source" | "computed_lambda",
  "raw": "<verbatim source fragment>",
  "hints": ["<receiver-or-method-name-if-partially-known>", ...]
}
```

A call site that produces an `unresolved` callee in §4.2 SHOULD also produce a corresponding entry in `unresolved_dispatches` for the same line.

---

## 5. Layer A — Semantic rules

All Layer A rules derive from the Tcl(n) parsing rules ([Tcl.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm)) plus the cited per-command pages. Section anchors below name the runtime substitution behaviors that determine static identifiability of the first word of a command.

### 5.1 Direct call — Pattern A: `foo arg1 arg2 ...`

A word that, after backslash and (where applicable) variable/command substitution, is a bare identifier in command-position invokes the command of that name (Tcl(n) rules [2], [3], [11]; [Tcl.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm)). When the first word is a **literal** (no `$`, no `[...]`, no backslash forming substitution), the callee identity is statically determined.

- Annotation: `{name: "foo", kind: "static"}`.
- The call site line is the line on which the command begins.

If the literal contains namespace separators (`::`), see §5.2.

Bare literal first words inside an iTcl/iTk/TclOO method body are recorded as `static` per this rule even when they semantically resolve to a self-method call on `$this`. The convention does not distinguish implicit self-dispatch from a global proc call; downstream consumers that need self-method resolution can perform class-method lookup using the enclosing symbol's class.

### 5.2 Qualified call — Pattern A2: `Ns::foo`, `::Ns::foo`, `Ns::Sub::foo`

Command names containing `::` resolve hierarchically (namespace(n) §RESOLUTION; [namespace.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/namespace.htm)). A leading `::` is absolute; otherwise the resolver searches the current namespace, the command path, then the global namespace.

- Annotation: `{name: "<verbatim-qualified-name>", kind: "qualified"}`.
- Preserve every segment of the qualified name verbatim. Do not strip the leading `::` if present; do not normalize. Concrete examples: source `::mediator register $this` → `{name: "::mediator register", kind: "qualified"}` (NOT `register`); source `::DCS::ComponentGate #auto ...` → `{name: "::DCS::ComponentGate", kind: "qualified"}` (NOT `DCS::ComponentGate`); source `DCS::Component::sendUpdate $name` → `{name: "DCS::Component::sendUpdate", kind: "qualified"}` (NOT `sendUpdate`). The stripped form is a recurring annotator error and is always wrong.
- Static analyzers cannot reliably reconstruct the current namespace at every call site without simulating `namespace eval` nesting, so the convention preserves the source-form name and lets downstream consumers handle resolution.

### 5.3 Object dispatch — Pattern B: `$obj method arg1 arg2 ...`

When the first word is a variable substitution `$obj` (or `${obj}`) that yields an object command, the second word is the method name (Tcl(n) rule [8]; itcl::class object-method dispatch; [class.html](https://www.tcl-lang.org/man/tcl/ItclCmd/class.html)). The receiver `$obj` is statically unresolvable in the general case; the method name is the searchable key.

- Annotation: `{name: "<method>", kind: "method_dispatch", receiver_hint: "<receiver-source-form>", note: "$obj <method>"}` where `<method>` is the LITERAL second-word identifier from the source command (e.g., for `$clock addListener $this`, name = `"addListener"`) and `receiver_hint` is the verbatim source-form of the receiver expression (e.g. `"$clock"`, `"${obj}"`, `"$itk_component(eu)"`). Do NOT emit the placeholder string `"method"` — always substitute the actual method word. The `receiver_hint` is required on method_dispatch callees per §4.2.
- This rule fires only when the first word is a variable substitution (`$obj`, `${obj}`). A literal qualified name in command position (e.g., `::config getStr foo`) is NOT method dispatch — it is a §5.2 qualified call where `::config` is the callee and `getStr foo` are data arguments.
- The rule ALSO fires when the variable-substituted receiver is itself a bracketed expression whose first inner term is `$var` — e.g., `[$itk_component(eu) childsite]` → `{name: "childsite", kind: "method_dispatch", note: "$itk_component(...) childsite"}`. Such bracketed-receiver forms are still method_dispatch, not §5.11 bracket substitution. Failing to record them is a recurring annotator error.
- If the method-position word is itself a variable substitution (`$obj $m`), the call site is fully dynamic; emit `{name: "?", kind: "unresolved", note: "var_method on $obj"}` and add an `unresolved_dispatches` entry with `subkind: "var_method"` (§5.14).

### 5.4 Class and namespace declarations

#### 5.4.1 `itcl::class NAME { BODY }`

Declares an [incr Tcl] class ([class.html](https://www.tcl-lang.org/man/tcl/ItclCmd/class.html)). The BODY recognizes the directives `inherit`, `constructor`, `destructor`, `method`, `proc`, `variable`, `common`, and `public`/`protected`/`private` modifiers.

- Annotation: a symbol with `kind: "class"`, `qualified_name` = fully qualified class name (combine current namespace context with NAME).
- BODY is walked. Inner `method`/`proc`/`constructor`/`destructor`/`variable` declarations each produce **child** symbols whose `qualified_name` is `<class>::<name>`.
- `inherit` populates the class symbol's `parent_classes` field (§5.6).

#### 5.4.2 Custom `class NAME { BODY }` DSL (D9)

A bare `class NAME BODY` form, common in vendor DSLs that alias `itcl::class` (for example the bluice/dcss ecosystem), is treated identically to `itcl::class NAME BODY` at the static level. **This rule is Layer A by analogy** — it inherits the BODY semantics of §5.4.1 conditional on the ecosystem providing the alias (via `interp alias`, `rename`, or an equivalent). The Tcl/iTcl language spec does NOT define a bare `class` command at the language level; the BODY grammar is borrowed wholesale from `itcl::class` as documented at [class.html](https://www.tcl-lang.org/man/tcl/ItclCmd/class.html).

- Annotation: identical to §5.4.1.

**DSL-implementation files (v1.3 P3.1-canary-2 follow-up).** A file that *implements* the custom `class NAME BODY` DSL (e.g. git-gui's `lib/class.tcl`, which defines `proc class {name body} { ... }`) is **not** itself a class-definition file. The annotator MUST treat such a file as ordinary procedural Tcl:

- Annotate the `proc class { ... }` itself as a regular §6.2 proc symbol.
- Do NOT synthesize §5.4.2 class symbols from any `class NAME BODY` literal that appears inside the proc body (e.g. inside an `if` branch handling argument variants). Those are data being passed to the implementing proc, not class declarations.
- Inner `method`, `proc`, etc. calls inside the implementing proc's body are ordinary §5.1 / §5.5 calls (they reference helper procs in the implementing module, not class-body directives).

This distinction matters because §5.4.2's "treat as itcl::class" rule applies to *invocations* of the alias (`class FooBar { method m {} {...} }` as a top-level form), not to its *implementation* (`proc class { name body } { ... }`). DSL users and DSL implementers must be annotated differently.

#### 5.4.3 `itcl::widget NAME { BODY }`, `itcl::extendedclass NAME { BODY }`

Declare widget / extended-class flavors of an iTcl class ([itclwidget.html](https://www.tcl-lang.org/man/tcl/ItclCmd/itclwidget.html)). The BODY accepts the same `inherit`, `method`, `proc`, `variable`, `common`, `constructor`, `destructor`, `public`/`private`/`protected` directives as `itcl::class`, plus `component` and `option` (§5.4.6, §6.12.3).

- Annotation: same as §5.4.1 with the symbol's `kind` field still `"class"`. The widget/extendedclass distinction is not surfaced as a separate kind by this convention; downstream consumers can detect it from the declaration form when needed.

#### 5.4.4 `namespace eval NS { BODY }`

Creates or enters the namespace `NS` and evaluates BODY in that namespace context ([namespace.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/namespace.htm)).

- If `NS` is a literal, emit a `namespace` symbol with `qualified_name` reflecting the new context, and walk BODY. Inner declarations (`proc`, `itcl::class`, nested `namespace eval`) prepend the namespace prefix to their `qualified_name`.
- If `NS` is a variable substitution (`namespace eval $name {...}`), emit a `namespace` symbol with `qualified_name: "<computed>"`, walk BODY for inner callees attributed to the synthetic namespace, and add an `unresolved_dispatches` entry with `subkind: "computed_namespace"`.

#### 5.4.5 `oo::class create NAME { BODY }` (TclOO)

The Tcl 8.6 core object system also defines classes ([TclOO contents](https://www.tcl-lang.org/man/tcl8.6/TclCmd/contents.htm)). Treat `oo::class create NAME BODY` the same as `itcl::class NAME BODY` for the purposes of this convention: emit a class symbol; inner `method` / `constructor` / `destructor` produce child symbols. Receiver dispatch (§5.3) applies uniformly to TclOO and iTcl instances.

#### 5.4.6 `itk_component add NAME { BODY }` and `itcl::component NAME ...`

`itk_component add` inside a widget body creates a sub-component widget; `itcl::component` declares a component instance variable inside an extendedclass/widget body ([itclcomponent.html](https://www.tcl-lang.org/man/tcl/ItclCmd/itclcomponent.html)). These do **not** produce callable symbols themselves — they declare component slots. The BODY of `itk_component add` is a creation script and IS walked for inner callees, attributed to the enclosing method (typically the constructor). Callback-flag options inside that creation script follow §6.12.

### 5.5 Method declarations and visibility

Inside an `itcl::class` / `itcl::widget` / `itcl::extendedclass` body the recognized declaration heads are:

- `method NAME ARGS BODY` — instance method.
- `proc NAME ARGS BODY` — class procedure (no `$this`; access only `common` variables).
- `constructor ARGS ?INIT? BODY` — initialization method.
- `destructor BODY` — cleanup method.
- `public method ...`, `private method ...`, `protected method ...` — visibility-prefixed method declarations ([class.html](https://www.tcl-lang.org/man/tcl/ItclCmd/class.html)). The same prefixes apply to `proc`, `variable`, `common`.

Annotation:
- Each method/proc/constructor/destructor inside a class body becomes a child symbol with `qualified_name` = `<class>::<name>` (or `<class>::constructor` / `<class>::destructor`).
- `kind`:
  - `"method"` for `method` and visibility-prefixed `method`.
  - `"class_method"` for `proc` inside a class.
  - `"constructor"` / `"destructor"` for those two.
- `visibility`:
  - `"public"` / `"private"` / `"protected"` when the prefix is present.
  - The iTcl 3.x default is `"private"` for variables and `"public"` for methods; this convention does NOT infer defaults — emit `null` when no prefix is given so the absence is visible to downstream tools.
- BODY is walked for inner callees.

### 5.6 Inheritance: `inherit`, `superclass`

The `inherit` directive in an `itcl::class` body lists one or more base classes ([class.html](https://www.tcl-lang.org/man/tcl/ItclCmd/class.html)). TclOO uses `superclass` similarly inside a `oo::class create` body.

- Populate the enclosing class symbol's `parent_classes` field with each verbatim base-class name (preserve `::` qualifications).
- `inherit` and `superclass` are NOT emitted as callees.

### 5.7 Imports: `package require`, `package provide`, `source`

[package.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/package.htm), [source.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/source.htm).

- `package require NAME ?VERSION?` → append `NAME` to the enclosing scope's `package_requires` array. NOT a callee.
- `package provide NAME ?VERSION?` → append `{name: NAME, version: VERSION_OR_NULL}` to `package_provides`. NOT a callee.
- `source PATH` → append the verbatim PATH literal to `imports`. NOT a callee. If PATH is a variable substitution, omit the entry and add an `unresolved_dispatches` entry with `subkind: "computed_source"` and `raw` containing the source line.

Scope of attachment:
- File-level top-level declarations → `file_level` block.
- Declarations inside a symbol body → that symbol's fields.

### 5.8 `eval` semantics

`eval` concatenates its arguments via `concat` and recursively passes the resulting string to the Tcl interpreter ([eval.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/eval.htm)).

#### 5.8.1 `eval LITERAL ARGS` (D1)

When the first argument is a literal command word and the remaining arguments are values (`$var`, lists, literals), `eval foo $args` is equivalent to direct invocation of `foo`.

- Annotation: `{name: "foo", kind: "static"}`. Record the call as though the `eval` wrapper were not present — Tier filters (§7.1) then apply normally. If `foo` is Tier 2 (`set`, `incr`, `lappend`, …) or Tier 3 (`puts`, `error`, …), do NOT emit a callee.
- Worked examples: `eval lappend _all $args` → no callee emitted (Tier 2 filtering applies after collapse); `eval itk_initialize $args` → `{name: "itk_initialize", kind: "static"}` (not on any Tier filter).
- Rationale follows from spec: the concat-then-evaluate semantics, given a literal first word, deterministically produces a call to that word; filtering then proceeds as for any direct call.

#### 5.8.2 `eval $script ...` (D3 — variable first word)

When the first effective argument is a variable substitution (`eval $cmd`, `eval $obj method args`), the callee identity is determined at runtime.

- If the form is `eval $obj method args` (object dispatch through eval), emit `{name: "method", kind: "unresolved", note: "eval dispatch through dynamic receiver"}` and add an `unresolved_dispatches` entry with `subkind: "eval_var"`. The method name remains the primary searchable key.
- If the form is `eval $cb args` (callback-through-eval — a variable holding a callback prefix is dispatched with appended args; v1.3 P3.1 clarification), treat as a §6.12-style variable-bound callback site: emit `{name: "?", kind: "unresolved", note: "eval $cb args"}` and add `subkind: "callback_var"`. Rationale: the semantic match (a callback prefix is being invoked at this line) is closer to §6.12 than to a bare eval_var dispatch. Examples: `eval $_callback [list $response]`, `eval $_errorCallback $this`. The variable name (e.g. `_callback`, `_errorCallback`) is preserved verbatim in the `raw` field of the `unresolved_dispatches` entry for human reference.
- If the form is `eval $cmd` with no other static words, emit `{name: "?", kind: "unresolved"}` and add `subkind: "eval_var"`.

#### 5.8.3 `eval [foo ...] ARGS` (bracket first word)

The result of a bracket substitution is the first word. The result is a value, not statically identifiable as a command.

- Emit `{name: "?", kind: "unresolved"}` and add `subkind: "eval_brackets"`.
- DO recurse into the bracketed script and record `foo` as a callee in its own right (it is a real call regardless of how its return value is used).

### 5.9 `apply LAMBDA ARGS`

[apply.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/apply.htm). A lambda is `{args body}` or `{args body namespace}`.

- When `LAMBDA` is a brace-literal `{args body}`, emit a child symbol with `kind: "lambda"`, `qualified_name` like `<enclosing>::__lambda_<line>`, and walk `body` for inner callees. The `apply` site itself becomes `{name: "<lambda-qualified-name>", kind: "lambda"}` in the enclosing scope's callees.
- When `LAMBDA` is a variable substitution (`apply $fn ARGS`), emit `{name: "?", kind: "unresolved"}` and add `subkind: "computed_lambda"`.
- When `LAMBDA` is a bracketed expression (`apply [expr {...}] ARGS`), treat the same as the var case (`computed_lambda`).

### 5.10 Ensemble subcommands (D2)

Documented ensemble commands have a fixed set of subcommands listed in their man pages. The canonical set (matching §7.1 Tier 2 and §7.5) is `string`, `dict`, `info`, `array`, `chan`, `namespace`, `file`, `clock`, `package`, `binary`, `encoding` ([info.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/info.htm), [namespace.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/namespace.htm), [package.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/package.htm), and the TclCmd index at [contents.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/contents.htm)).

A line such as `string length $s` semantically invokes the `string` ensemble dispatcher with subcommand `length`. The runtime may internally compile this to a specialized bytecode, an FQN command rewrite, or a generic ensemble dispatch — those are implementation details below the convention.

- Annotation (Layer A statement): the call site invokes the ensemble dispatcher; the searchable callee identity is the 2-word phrase. This rule is encoded under Layer B because the choice of 2-word naming is convention. See §7.5 for the rule and rationale.

**Tk geometry and window-management ensembles.** `grid`, `pack`, `place`, `wm`, and `winfo` ([grid.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/grid.htm), [pack.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/pack.htm), [place.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/place.htm), [wm.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/wm.htm), [winfo.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/winfo.htm)) are also documented ensembles, but UNLIKE the Tier 2 ensembles above they ARE architectural callees and MUST be recorded. They use the same 2-word naming convention (`grid forget`, `grid rowconfigure`, `grid columnconfigure`, `grid propagate`, `pack configure`, `wm title`, `winfo children`, …) when the second word is a literal subcommand. A bare single-word form (`grid $w`, `pack $w`) — when the second word is a value, not a subcommand — is recorded as `static` with name `"grid"` / `"pack"` per §5.1. The distinction is whether the second word is a documented ensemble subcommand for that command. These ensembles are NOT on the §7.1 Tier 2 filter list — they are kept.

**Qualified-name-vs-ensemble precedence (v1.3 P3.1 canary follow-up).** When the first word of a command is a §5.2 qualified name (containing `::`) followed by what would otherwise look like an ensemble subcommand of a different command (e.g. `::dcss configure $name $value`), the qualified-name interpretation takes precedence: record as 1-word `{name: "::dcss", kind: "qualified"}`, NOT as 2-word `{name: "::dcss configure", kind: "qualified"}`. The 2-word ensemble naming convention applies only when the first word is itself a documented ensemble dispatcher (`string`, `dict`, `info`, etc. per §5.10's ensemble list) OR a kept Tk ensemble (`grid`, `pack`, `wm`, `winfo`, `image`). A `::namespace command` form is a §5.2 call to the `::namespace command` proc/method; the second word is data, not an ensemble subcommand.

**Tk `image create TYPE` (3-word phrase, v1.3 P3.1).** `image create TYPE NAME ?options?` ([image.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/image.htm)) is a documented exception to the 2-word ensemble naming rule. The `image` command's `create` subcommand takes the image type (e.g. `photo`, `bitmap`) as the third word; the combination is meaningful for refactor/find-references navigation. Record `image create photo`, `image create bitmap`, etc. as 3-word static callees with `kind: "static"` and `name: "image create <TYPE>"`. The 2-word fallback `image create` (when TYPE is variable-substituted) is recorded with `kind: "unresolved"` and `subkind: "var_command"`. Other `image` subcommands (`image delete`, `image height`, `image inuse`, `image names`, `image type`, `image types`, `image width`) follow the standard 2-word naming.

**iTcl `delete`.** The iTcl `delete` command (see the [ItclCmd index](https://www.tcl-lang.org/man/tcl/ItclCmd/index.html); the dedicated `itcldelete.html` page returned HTTP 404 at the time of v1.2 authoring) has subcommands `object`, `class`, `namespace`. Record as a 2-word phrase: `delete object`, `delete class`, `delete namespace` with `kind: "static"`. Not on the Tier 2 filter list.

### 5.11 Bracket substitution `[foo arg]`

Bracket substitution (Tcl(n) rule [7]; [Tcl.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm)) recursively evaluates the script between `[` and `]`. The result is substituted into the enclosing word.

- Each bracketed script is a sub-script and produces its own call sites. Walk it; record callees of its top-level commands as callees of the enclosing symbol.
- The enclosing command's own callee identity is determined separately by §5.1/§5.2 (its literal first word) or §5.3 (its `$obj method` form).

### 5.12 Callback / script sites — see §6.12

Tk/iTk callback and script handling is centralized in §6.12 (under Layer A semantics plus Layer B naming).

### 5.13 `uplevel` and `upvar`

[uplevel.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/uplevel.htm).

- `uplevel ?LEVEL? SCRIPT` — the SCRIPT argument is concatenated and evaluated. Treat SCRIPT exactly like an `eval` body (§5.8): if the first effective word is a literal command, record that as a static callee of the enclosing symbol; if it is a variable substitution or bracket expression, emit unresolved per §5.8.2 / §5.8.3 with the note "via uplevel".
- `upvar ?LEVEL? OTHERVAR LOCALVAR ...` — variable aliasing only; produces no callee.

### 5.14 Other unresolved variants

Additional patterns that yield `kind: "unresolved"` plus an `unresolved_dispatches` entry:

| Pattern | `subkind` | Example |
|---|---|---|
| `$cmd args` (first word is `$var`) | `var_command` | `$callback x y` |
| `$obj $m args` (method word is `$var`) | `var_method` | `$widget $opcode` |
| `interp eval $I SCRIPT` (dynamic interp) | `interp_eval` | `interp eval $slave $body` |
| `eval [foo ...]` (bracket first word) | `eval_brackets` | `eval [build_cmd $x]` |
| `eval $foo` (variable first word) | `eval_var` | `eval $script` |
| `apply $fn ARGS` | `computed_lambda` | `apply $h $arg` |
| `namespace eval $ns BODY` | `computed_namespace` | `namespace eval $owner {...}` |
| `source $path` (dynamic source path) | `computed_source` | `source $config_file` |
| Callback flag with `$var` value | `callback_var` | `-command $cb` |

In every case the static `callees` list also receives an entry with the best available name (the method word, the lambda result, or `"?"` if nothing is recoverable). The `note` field MAY carry the verbatim source fragment as an aid to human readers; the `unresolved_dispatches` entry's `raw` field holds the same fragment in its canonical form.

---

## 6. Layer A — Semantic rules, additional callable forms

This section continues Layer A with constructs whose annotation form is fixed by the semantic-equivalence rules in §5.

### 6.1 Methods declared out-of-line: `itcl::body`, `itcl::configbody`

[body.html](https://www.tcl-lang.org/man/tcl/ItclCmd/body.html) and [configbody.html](https://www.tcl-lang.org/man/tcl/ItclCmd/configbody.html).

- `itcl::body className::methodName ARGS BODY` — emit a `method` symbol (or `constructor`/`destructor` if the qualified name matches) with `qualified_name: "className::methodName"`. Walk BODY for inner callees. The `itcl::body` invocation itself does not appear as a callee in any enclosing scope; it is a declaration.
- **Forward-declaration dedup:** if both a class-body forward declaration (per §5.5, an in-class `method NAME` without a body) and an out-of-line `itcl::body` exist for the same `qualified_name`, emit ONE symbol — use the body's `line`/`end_line` as canonical. The forward declaration is not emitted as a separate symbol; downstream rename/refactor tools that need its location can find it via textual search of the source.
- `itcl::configbody className::varName BODY` — emit a `configbody` symbol with `qualified_name: "className::varName"`. The `visibility` field is `"public"` (configbody applies only to public variables). Walk BODY.
- The variable bound to a configbody is NOT itself a symbol in this convention; only the body is. Downstream consumers that need the variable name parse it from the `qualified_name` suffix.

### 6.2 `proc` (top-level and inside namespace eval)

[proc.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/proc.htm). `proc NAME ARGS BODY` creates a new command at the current namespace. BODY is stored, not evaluated at definition time, and re-evaluated on each invocation.

- Emit a symbol with `kind: "proc"`, `qualified_name` = `<current-namespace>::<NAME>` (or just `<NAME>` at global level).
- Walk BODY for inner callees.

### 6.3 Coroutines (D8): `coroutine NAME COMMAND ARGS...`

[coroutine.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/coroutine.htm). `NAME` becomes a callable command that resumes the coroutine; `COMMAND` is invoked once with `ARGS` as the coroutine's main body.

- Emit a symbol with `kind: "coroutine"`, `qualified_name` = the literal NAME.
- If COMMAND is a literal command word, the coroutine symbol's `callees` includes `{name: "<COMMAND>", kind: "static"}` at the `coroutine` line. Optionally walk the called proc's body in a separate annotation pass.
- If COMMAND is a script (a brace literal), walk it as the coroutine body and attribute its inner callees to the coroutine symbol. **(By-analogy extension)** — the [coroutine.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/coroutine.htm) spec describes COMMAND as a command word; treating a brace-literal in COMMAND position as a walkable body is a convention-level analogy to `apply {args body}` (§5.9), not a direct spec claim.
- `yield` and `yieldto` inside the coroutine body are flow-control primitives (Tier 1; §7.1) and are NOT recorded as callees.

### 6.4 Inline lambdas via `apply` — see §5.9

### 6.5 `try` / `on` / `trap` / `finally` bodies

[try.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/try.htm). `try BODY ?HANDLER...? ?finally SCRIPT?`. Each of BODY, each handler script, and the finally script is a Tcl script.

- Walk every body/handler/finally script for inner callees attributed to the enclosing symbol.
- `try`, `on`, `trap`, `finally` are control-flow keywords (Tier 1; §7.1) and are NOT recorded as callees.

### 6.6 `switch` bodies

[switch.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/switch.htm). Patterns and bodies appear either as spread arguments (`switch X PAT1 BODY1 PAT2 BODY2 ...`) or grouped in a single list (`switch X { PAT1 BODY1 PAT2 BODY2 }`). A body of `"-"` falls through to the next case.

- Walk every body (non-`"-"`) for inner callees attributed to the enclosing symbol.
- Patterns are data; do not record them.

### 6.7 `if` / `while` / `for` / `foreach` bodies

[foreach.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/foreach.htm). All four are documented control-flow primitives whose final argument(s) is a script body. Walk every body for inner callees.

### 6.8 `expr {EXPR}` and `expr EXPR`

[expr.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/expr.htm). `expr` evaluates an expression. Function calls inside the expression resolve to commands in the `tcl::mathfunc` namespace. Bracketed command substitutions inside the expression undergo one round of substitution before `expr` runs (when unbraced) or one round after (when braced).

- Walk bracketed `[...]` substitutions inside the expression as sub-scripts (§5.11). Each bracketed command produces a callee of the enclosing symbol.
- Math-function calls like `sin($x)` MAY be recorded as `{name: "tcl::mathfunc::sin", kind: "qualified"}`. This convention treats math-function recording as **optional**; both presence and absence are valid. When recorded, use the qualified `tcl::mathfunc::*` form.
- `expr` itself is a Tier-2 utility (§7.1); it is not recorded as a callee.

### 6.9 Tk script-accepting commands

[bind.htm](https://www.tcl-lang.org/man/tcl8.6/TkCmd/bind.htm), [after.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/after.htm), [fileevent.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/fileevent.htm), [trace.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/trace.htm).

These commands all accept a SCRIPT argument that is evaluated at event time:

- `bind TAG SEQUENCE SCRIPT` — evaluated when the event fires.
- `after MS SCRIPT ?SCRIPT...?` — evaluated after the delay; multiple scripts are concat'd.
- `after idle SCRIPT` — evaluated when the event loop idles.
- `fileevent CHAN readable|writable SCRIPT` — evaluated when the channel is ready.
- `trace add variable VAR OPS COMMAND_PREFIX` — `COMMAND_PREFIX` is a callback prefix; the trace appends `name1 name2 op` and invokes it.
- `trace add command CMD OPS COMMAND_PREFIX` — similar; appended `oldName newName op`.
- `trace add execution CMD OPS COMMAND_PREFIX` — similar; appended command-string and execution metadata.
- `socket -server CMDPREFIX ?-myaddr ADDR? PORT` ([socket.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/socket.htm)) — CMDPREFIX is a callback prefix invoked with three appended args (channel, host, port) on each accepted connection. Treat per §6.12: source `socket -server [list $this accept] -myaddr $host $port` records exactly ONE callee `{name: "accept", kind: "callback"}`; the dispatcher `socket` is NOT recorded as a callee.

For each: treat SCRIPT (or `-server` CMDPREFIX) according to §6.12 (callback site). **(Layer B filtering choice; see §7.1.)** The dispatcher command itself (`bind`, `after`, `fileevent`, `trace add ...`, `socket -server`) is NOT recorded as a `static` callee — only the SCRIPT's callee per §6.12 is recorded. Source `after 1000 [list $this listen]` produces exactly ONE callee: `{name: "listen", kind: "callback"}` — neither `after` nor `bind` may appear as a static callee. This is a recurring annotator/arbiter error.

### 6.10 Tk widget creation and configure callbacks

Widget creation commands (`button`, `entry`, `label`, `frame`, `toplevel`, `listbox`, `text`, `canvas`, `scale`, `menu`, etc.; [TkCmd contents](https://www.tcl-lang.org/man/tcl8.6/TkCmd/contents.htm)) accept option-flag callbacks on creation and on subsequent `widget configure -flag VALUE`. The flags that carry callback-shaped values are:

`-command`, `-validatecommand`, `-invalidcommand`, `-postcommand`, `-yscrollcommand`, `-xscrollcommand`, `-tearoffcommand`, `-textvariable` (variable-bound), and any vendor-defined `-flag CALLBACK` where the value is a callback prefix per the widget's man page.

Treat each callback-flag value according to §6.12.

### 6.11 `itk_option define` and `itcl::option`

[itcloption.html](https://www.tcl-lang.org/man/tcl/ItclCmd/itcloption.html). Declares a configurable option on a widget / extendedclass. The option may have `-validatemethod`, `-configuremethod`, `-cgetmethod` handler-method names; these refer to methods declared elsewhere in the class.

- The option declaration is NOT itself a symbol in this convention.
- For each handler-method value, emit a callee with `{name: "<method-name>", kind: "callback", note: "-validatemethod" | "-configuremethod" | "-cgetmethod"}` attributed to the enclosing class's `constructor` (the natural lexical container) or, if the option declaration occurs outside a constructor, to a synthetic file-level entry.
- For the dynamic-method-name variants `-validatemethodvar`, `-configuremethodvar`, `-cgetmethodvar`, the value is a variable whose contents name the actual method at runtime. Emit `{name: "?", kind: "unresolved", note: "-<flag-name>"}` and add an `unresolved_dispatches` entry with `subkind: "callback_var"`. The dynamic-variant flags themselves are documented in [itcloption.html](https://www.tcl-lang.org/man/tcl/ItclCmd/itcloption.html).

### 6.12 Callback / script sites (D5, D8 + Layer B naming)

A **callback site** is any of:

1. A script-accepting Tk/iTk command (§6.9) — `bind`, `after`, `fileevent`, `trace add variable`, `trace add command`, `trace add execution`, `coroutine` (when given a script), `itk_initialize` when given a body.
2. A flag option on widget creation or `widget configure` whose VALUE matches the pure-callback pattern (defined below) — regardless of whether the flag is on the Tk-core documented list. This covers the Tk-core flags `-command`, `-validatecommand`, `-invalidcommand`, `-postcommand`, `-yscrollcommand`, `-xscrollcommand`, `-tearoffcommand`, AND any vendor flag (`-onClick`, `-onChange`, `-selectioncommand`, etc.) whose value is shaped like a callback. Recognition is value-shape-driven, not flag-name-driven: the §6.10 Tk-core flag list is illustrative, not exhaustive.

For each callback site, classify the script form:

- **Pure callback pattern** — a single command in one of these forms:
  - `"$this method args..."` (a quoted string)
  - `[list $this method args...]`
  - `"method args..."` (no receiver; bare method literal)
  - `{method args...}` (brace-literal callback prefix)
  Annotation: `{name: "method", kind: "callback"}`. The `name` field is ALWAYS the method word from the callback prefix — NEVER the dispatcher (`bind`/`after`/etc.) or the flag name (`-command`/`-onClick`/etc.). Worked example: source `bind $w <Delete> [list $obj removeBeamline]` produces exactly ONE callee `{name: "removeBeamline", kind: "callback"}`; the dispatcher `bind` is NOT a callee (§6.9), the tag/sequence args are data, and the method word `removeBeamline` is the callback name. The `note` field MAY carry the receiver form for human readability.

- **Multi-command script** — multiple commands separated by newline or `;`, or a brace-literal containing a multi-command body.
  Annotation: walk the script as a sub-script per §5.11 / §6.7. Each top-level command becomes a separate callee with its own kind (`static`, `qualified`, `method_dispatch`, etc.).

- **Variable-bound callback** — `-command $cb`, `bind .w <X> $script`.
  Annotation: `{name: "?", kind: "unresolved", note: "-command $cb"}` plus an `unresolved_dispatches` entry with `subkind: "callback_var"`.

- **Bracket-substituted callback** — `-command [build_cb $x]`.
  Annotation: emit `{name: "?", kind: "unresolved", note: "-command [..]"}` AND walk the bracketed sub-script per §5.11 to record `build_cb` itself.

This rule is anchored in Layer A semantics: every command in this list evaluates the script at event/configure time per its respective man page. The naming choice — recording the method as a `callback` callee with the method-word as `name` — is Layer B convention (§7.2).

### 6.13 `uplevel` and `upvar` — see §5.13

### 6.14 Other unresolved variants — see §5.14

---

## 7. Layer B — Filtering and utility rules

Every rule in this section has an explicit **Rationale:** justifying it from the consumer goal in §1.

### 7.1 The 5-tier filter (D4)

Walking the Tcl/iTcl AST literally would emit `set`, `incr`, `if`, `expr`, etc. as callees on every line. The resulting graph is unusable for refactoring, hierarchy explanation, or bug investigation. The convention filters callees by tier; tier-1 and tier-4 declarations are control structures whose **bodies** are recursively walked, attributing the inner callees to the enclosing symbol.

**Tier 1 — Control flow & flow keywords (NOT callees; bodies walked).**

`if`, `else`, `elseif`, `while`, `for`, `foreach`, `lmap`, `time`, `switch`, `catch`, `try`, `on`, `trap`, `finally`, `return`, `break`, `continue`, `yield`, `yieldto`.

`lmap LIST BODY` ([lmap.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/lmap.htm)) is a sibling of `foreach`. `time { script } ?count?` ([time.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/time.htm)) evaluates a body for benchmarking; the body IS walked, the dispatcher `time` is NOT a callee.

Rationale: these primitives structure execution but say nothing about *what* is being called. Walking their bodies preserves inner calls attributed to the enclosing user-defined symbol — which is what "where does this function call X?" needs.

How to apply: do NOT add to `callees`. Walk each script-argument position (e.g. `if EXPR BODY ?elseif EXPR BODY...? ?else BODY?` per [Tcl.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm)) for inner callees.

**NOT Tier 2 — Tk widget creation and geometry commands ARE legitimate static callees per §5.1.** The commands `grid`, `pack`, `place`, `bind`, `frame`, `button`, `label`, `toplevel`, `listbox`, `text`, `canvas`, `scale`, `menu`, `entry`, `checkbutton`, `radiobutton`, `wm`, `winfo`, `tk`, `image`, `font`, `option` — and any other Tk widget/geometry primitives — are NOT on the Tier 2 list below and MUST be recorded as `static` callees when they appear as literal first words. Filtering them is a recurring annotator error. (Their callback-flag values are still handled separately per §6.12; the dispatcher itself remains a real static callee EXCEPT when listed in §6.9 as a script-accepting command — those have `bind`/`after`/`fileevent`/`trace add ...` themselves omitted, only their SCRIPT's callee recorded.)

**Tier 2 — Value and list manipulation (NOT callees; not walked).**

`set`, `incr`, `unset`, `lappend`, `lassign`, `lset`, `lreplace`, `llength`, `lrange`, `lsearch`, `lsort`, `lindex`, `linsert`, `lrepeat`, `lreverse`, `list`, `split`, `join`, `format`, `scan`, `expr`, `regexp`, `regsub`, `subst`, `concat`, `eof`, `seek`, `tell`, `flush`, `global`, `variable`. ALL subcommands of these documented ensembles: `string`, `dict`, `info`, `array`, `clock`, `chan`, `file`, `binary`, `namespace`, `package`, `encoding`.

`global` and `variable` are formalized as Tier 2 in v1.3, codifying the Phase 2 arbiter verdicts on Clock.tcl and DEG_HORZ.tcl which ruled them variable-scope utilities analogous to `upvar` (§5.13), not architectural callees.

Rationale: pure data operations and variable-scope binding. Filtering them dramatically improves signal-to-noise without losing architectural information.

How to apply: do NOT add to `callees`. Do NOT walk argument scripts — except `dict for`, `dict update`, `dict with`, `dict map`, and `dict filter` (script form), whose body IS walked (still not recorded as a callee). Bracketed substitutions inside arguments are always walked under §5.11.

**Tier 3 — I/O, error, and event-loop primitives.**

`puts`, `gets`, `read`, `open`, `close`, `update`, `vwait`, `error`, `throw`, `return -code error ...`.

`open` and `close` are added in v1.3 because they appear constantly in real-world code with no architectural value — the call edge of interest is the bytes-on-channel transfer, not the channel constructor. `update` and `vwait` are event-loop primitives whose I/O-shaped semantics align with the rest of Tier 3.

Rationale: not architectural call edges. The actual I/O target (channel, file, event) is the architectural fact, recorded elsewhere; the dispatcher is data-handling overhead.

How to apply: do NOT add to `callees`.

**Tier 4 — Declarations (produce a symbol entry; bodies walked).**

`proc`, `method` (and `public`/`private`/`protected method`), `proc` inside a class body, `itcl::body`, `itcl::configbody`, `constructor`, `destructor`, `namespace eval`, `itcl::class`, `itcl::widget`, `itcl::extendedclass`, `class` (custom DSL §5.4.2), `oo::class create`, `oo::define`, `oo::objdefine`, `coroutine`, `itk_component add`, `itk_option define`, `itcl::option`, `itcl::component`, `interp create`.

`oo::define CLASS BODY` and `oo::objdefine OBJ BODY` (TclOO) augment an existing class/object with `method`, `mixin`, `forward`, `superclass`, `constructor`, `destructor` directives. The BODY is walked as a class-body grammar; new methods produce symbol records attributed to the augmented class. `interp create NAME` introduces a subordinate-interpreter command callable as `NAME eval SCRIPT`; treat as a declaration producing a symbol with `kind: "namespace"` and `qualified_name` = NAME (the subordinate interpreter acts as a callable namespace from the parent).

Rationale: each names a callable, container, or component. Emitting symbol records is the point.

How to apply: do NOT add to `callees`. DO emit a symbol record (per §4.1) where applicable. DO walk the body for inner callees, attributed to the new symbol — or to the enclosing symbol when the declaration creates only a slot (`itcl::option`, `itcl::component`).

**Tier 5 — Imports / structural (populate dedicated fields; not callees).**

`package require`, `package provide`, `source`, `inherit`, `superclass`, `namespace import`, `namespace export`, `auto_load`, `auto_import`, `tm path add`.

`auto_load`, `auto_import`, and `tm path add` (Tcl module path manipulation) participate in the dependency/loading surface but produce no architectural call edge of interest; they are noted by their structural side-effect and not recorded as callees.

Rationale: structural facts (dependencies, provides, includes, inheritance) belong in dedicated fields, not interleaved with `callees`.

How to apply: populate `package_requires`, `package_provides`, `imports`, `parent_classes` per §5.6 / §5.7. An optional `namespace_imports` array MAY be added by implementers for `namespace import`/`export` (not formalized in §4 schema yet).

### 7.2 Unresolved-pattern naming conventions

Static analysis cannot resolve every callee. When the call is dynamic, the convention uses these names so downstream find-references and refactor tools have a useful key:

- Method-position word is literal but receiver is dynamic (`$obj method`): `name` = method word.
  **Rationale:** the method word is the most refactor-useful key; renaming the method requires touching every call site, and lexical search on the method word is the cheapest discovery path.
- Method-position word is also dynamic (`$obj $m`): `name` = `"?"`.
  **Rationale:** nothing useful is statically recoverable; the `?` literal flags the line as a known-blind spot in downstream UI.
- **Variable substitution mid-token in command-position word** (`create${tt}Tab`, `do${what}`, `process${type}Event`): `name` = `"?"`, `subkind: "var_command"` (v1.3 P3.1 canary follow-up).
  **Rationale:** the literal interpolated text (e.g. `"create${tt}Tab"`) is not the runtime command name — the variable could expand to any string. Embedding the source-form literal in `name` produces a useless search key (no proc named `create${tt}Tab` exists) and confuses find-references tooling. The `?` literal is the consistent unresolved marker; the original source fragment goes in `note` / `unresolved_dispatches.raw` for human reference.
- Callback-flag with `$var` value (`-command $cb`): `name` = `"?"`, `subkind: "callback_var"`.
  **Rationale:** same as above; the `subkind` discriminator lets a UI explain "this is a dynamic callback, not a missing call".
- `eval`-through-dynamic forms: `name` = method word if any, else `"?"`.
  **Rationale:** preserves a refactor-useful name when one is available.

### 7.3 Schema consistency (D6)

Every symbol's `callees` field is ALWAYS a JSON array. Never `null`, never absent.

- An empty body → `callees: []`.
- A skipped body (e.g. a tier-2 head with no walkable script) → still `callees: []` on the enclosing symbol.
- A symbol that is purely a container (class, namespace) → `callees: []`.

The same applies to `unresolved_dispatches`, `parent_classes`, `package_requires`, `package_provides`, `imports`: always an array, possibly empty.

**Rationale:** automated diff tools that consume this convention iterate `for c in symbol.callees:` and break on a missing/null field. Schema uniformity is a one-line invariant with high payoff in tooling reliability.

### 7.4 Multi-segment FQN preservation rule

When the source uses a qualified name (`Ns::Sub::foo`, `::Ns::foo`), the convention preserves the source-form verbatim in the callee's `name` field (§5.2). The convention does NOT attempt to resolve relative names against the current namespace.

**Rationale:** namespace resolution at a given call site depends on (a) the lexical `namespace eval` nesting and (b) the runtime `namespace path`. Resolving (a) requires correct nesting tracking; resolving (b) is impossible statically. Preserving source-form names lets find-references work as a substring/segment match — robust under most real-world Tcl, where developers tend to use unambiguous names. Downstream tools that want resolved names can layer a resolver on top.

### 7.5 Ensemble 2-word naming (D2)

For documented ensembles (`string`, `dict`, `info`, `array`, `chan`, `file`, `clock`, `namespace`, `package`, `binary`, `encoding`), the convention records call sites as the literal 2-word phrase: `"string length"`, `"dict for"`, `"namespace current"`, `"info exists"`.

**Rationale:** users navigate by 2-word phrases (`"string length"` is the search query a reader types). A strict semantic decomposition would record the dispatcher (`string`) as the callee and `length` as a data argument — but Tier 2 filters out the dispatcher itself, leaving nothing useful. The 2-word phrase is the searchable, refactor-useful key. Layer A documents the semantic of these as ensemble dispatch (§5.10); Layer B fixes the naming convention.

**How to apply:** when the first word matches a documented ensemble name and the second word is a literal, record the call as `{name: "<ensemble> <subcommand>", kind: "ensemble"}` — but only when an implementer wishes to surface ensemble calls at all. By default, Tier 2 excludes ensembles (`string`, `dict`, `info`, `array`) from `callees` entirely. Implementations that want richer ensemble visibility re-enable specific ensembles by removing them from Tier 2; the recording form is fixed by this rule.

**Exception — kept ensembles.** Per the §5.10 carve-out, the Tk geometry / window-management ensembles (`grid`, `pack`, `place`, `wm`, `winfo`) and the iTcl `delete` command are NOT on the Tier 2 filter and ARE recorded — using the same 2-word naming form (`grid forget`, `pack configure`, `wm title`, `winfo children`, `delete object`). For these, use `kind: "static"` (not `"ensemble"`) since they are kept as architectural callees and the `ensemble` kind is reserved for ensembles whose default surfacing is opt-in.

### 7.6 Empty bodies always emit a symbol

When a declaration creates a symbol with no body (`proc foo {} {}`, `method m {} {}`), still emit the symbol with `callees: []` and `end_line` equal to the line of the empty body. Never omit the symbol; never set `callees` to `null`.

**Rationale:** consumers depend on the symbol existing so that `find_references` and `get_outline` queries return predictable shapes. An empty proc is part of the architecture (often a stub awaiting implementation).

### 7.7 Comments are ignored (Layer A — parser prerequisite)

Tcl `#` comments at command position are stripped per Tcl(n) rule [10] ([Tcl.htm](https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm)). They produce no symbols and no callees. Comments inside braced strings are also ignored (they are not parsed as commands).

**Note:** this is spec-mandated parser behavior, not a Layer B convention choice. It is restated here for clarity because annotators must not record comment-line content as callees or symbols.

---

## 8. Known limitations of static convention

This convention is honest about what cannot be recovered without runtime information.

1. **`rename` and override of built-ins** — Tcl allows `rename` of any command, including built-ins. A renamed `puts` could later be a user-defined logger; a renamed `set` could be intercepted. Static analysis assumes standard semantics and cannot detect rename-rewires. Layer B Tier 2 filters become incorrect when code shadows tier-2 names — but remain correct in the overwhelming majority of code where this doesn't happen.
2. **Dynamic dispatch surfaces as `unresolved`** — `$obj method`, `eval $cmd`, `apply $fn`, `interp eval $i`, `namespace eval $ns`, and `-command $cb` callbacks all surface as `unresolved` entries. The `note` and `unresolved_dispatches.raw` fields preserve raw context for human readers; no further static recovery is attempted.
3. **Only literal lambdas have walkable bodies** — `apply {args body}` produces a `lambda` child symbol whose body is walked; `apply $fn` does not. The lambda is named `<enclosing>::__lambda_<line>` for stability across runs and should not be treated as a user-callable name in UIs.
4. **Cross-file aliasing is not detected** — `namespace import Foo::*` makes imported commands callable by their short names in the importing namespace. This convention records the call as a static call to the short name, not the imported original. Cross-file resolution is the job of an indexer layered on top.
5. **`source` paths are recorded verbatim** — including computed paths surfaced as unresolved. Resolution to a target file, deduplication, and traversal are indexer concerns.
6. **Computed namespaces** — `namespace eval $ns BODY` produces a synthetic `<computed>` namespace symbol with walkable body but no usable qualified prefix for child symbols.
7. **`uplevel`-injected commands** — a literal command injected via `uplevel` appears as a normal static call (per §5.13); the "in whose frame did it run" information is lost.
8. **TclOO mixins and forwards** — `oo::define X mixin Y` and `oo::define X forward NAME ...` are partially handled: mixin class names land in `parent_classes` if they appear textually inside the class body; `forward` declarations produce a `method` symbol with an empty body and a `note`. Full forward-target resolution exceeds this draft.

---

## 9. Out of scope for this revision

The following are deliberately not addressed here. Future revisions or separate documents may extend the convention.

- **Transitive-tool output formats** — call-hierarchy traversal, blast-radius computation, impact preview, and similar derived artifacts consume the JSON annotation defined here but format it for their own consumers. Those formats are out of scope.
- **Project-specific filter whitelists** — adding or removing terms from the 5-tier filter for a particular codebase is a project policy decision, not a language-spec convention.
- **Runtime-augmented edges** — augmenting the static graph with profiler-observed or test-coverage-observed call edges is out of scope.
- **Edges introduced by external tooling** — `Snit`, `tcl::oo::Helpers`, `XOTcl`, `TclTk-style mega-widget toolkits` other than [incr Tk], and DSL-style domain frameworks may introduce their own callable conventions. This document covers core Tcl, Tk, [incr Tcl], and [incr Tk] only.
- **Source-level diffs and patching** — the convention is read-only. Annotators emit JSON; they do not modify source.

---

## 10. References

All Layer A rules cite at least one of these official pages. URLs reflect the Tcl 8.6 reference at `tcl-lang.org` and the [incr Tcl] 4.x reference at the same host. Where the originally-named iTk-specific pages returned HTTP 404 at the time of authoring, the closest authoritative substitute on `tcl-lang.org` is cited and the substitution is flagged.

### 10.1 Tcl 8.6 core

- TclCmd index: https://www.tcl-lang.org/man/tcl8.6/TclCmd/contents.htm
- Tcl(n) parsing rules: https://www.tcl-lang.org/man/tcl8.6/TclCmd/Tcl.htm
- `eval`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/eval.htm
- `namespace`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/namespace.htm
- `proc`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/proc.htm
- `info`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/info.htm
- `package`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/package.htm
- `source`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/source.htm
- `apply`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/apply.htm
- `coroutine`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/coroutine.htm
- `uplevel`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/uplevel.htm
- `after`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/after.htm
- `fileevent`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/fileevent.htm
- `trace`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/trace.htm
- `try`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/try.htm
- `switch`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/switch.htm
- `foreach`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/foreach.htm
- `expr`: https://www.tcl-lang.org/man/tcl8.6/TclCmd/expr.htm

### 10.2 Tk 8.6

- TkCmd index: https://www.tcl-lang.org/man/tcl8.6/TkCmd/contents.htm
- `bind`: https://www.tcl-lang.org/man/tcl8.6/TkCmd/bind.htm
- Per-widget pages (`button`, `entry`, `label`, `frame`, `toplevel`, `listbox`, `text`, `canvas`, `scale`, `menu`) are reached from the TkCmd index; each lists its callback-flag options.

### 10.3 [incr Tcl]

- ItclCmd index: https://www.tcl-lang.org/man/tcl/ItclCmd/index.html
- `itcl::class`: https://www.tcl-lang.org/man/tcl/ItclCmd/class.html
- `itcl::body`: https://www.tcl-lang.org/man/tcl/ItclCmd/body.html
- `itcl::configbody`: https://www.tcl-lang.org/man/tcl/ItclCmd/configbody.html
- `itcl::widget`: https://www.tcl-lang.org/man/tcl/ItclCmd/itclwidget.html
- `itcl::option`: https://www.tcl-lang.org/man/tcl/ItclCmd/itcloption.html
- `itcl::component`: https://www.tcl-lang.org/man/tcl/ItclCmd/itclcomponent.html

### 10.4 [incr Tk]

The originally specified iTk reference at `https://incrtcl.sourceforge.net/itk/itk.html` returned HTTP 404 at the time of authoring; the working substitutes used here are the Tcler's Wiki overview and the `itcl::widget` / `itcl::component` / `itcl::option` pages on `tcl-lang.org`, which iTcl 4 documents as the canonical surface for widget/megawidget construction. References:

- Tcler's Wiki — incr Tk overview: https://wiki.tcl-lang.org/page/incr+Tk
- `itcl::widget` (mega-widget class form; substitute for `itk_class`): https://www.tcl-lang.org/man/tcl/ItclCmd/itclwidget.html
- `itcl::component` (substitute for `itk_component add`): https://www.tcl-lang.org/man/tcl/ItclCmd/itclcomponent.html
- `itcl::option` (substitute for `itk_option define`): https://www.tcl-lang.org/man/tcl/ItclCmd/itcloption.html

A future revision SHOULD replace these substitutes with the canonical `ItkCmd/` page set if/when those pages are restored.

---

## Appendix A — Decision summary (cross-reference)

| ID | Decision | Section | Layer |
|---|---|---|---|
| D1 | `eval LITERAL ARGS` → static call to LITERAL | §5.8.1 | A |
| D2 | Ensemble subcommands → 2-word name | §5.10, §7.5 | A (semantic) + B (naming) |
| D3 | `eval $obj method args` → unresolved with method name | §5.8.2 | A (semantic) + B (naming) |
| D4 | 5-tier filter list | §7.1 | B |
| D5 | Tk callback / script-accepting commands | §6.9, §6.10, §6.12 | A (semantic) + B (naming) |
| D6 | Empty bodies always emit symbol with `callees: []` | §7.6, §7.3 | B (schema) |
| D7 | Independence foundation | §2, §3 | — |
| D8 | `coroutine NAME SCRIPT` — NAME is a symbol, SCRIPT walked | §6.3 | A |
| D9 | Custom `class NAME BODY` DSL aliased to `itcl::class` | §5.4.2 | A |
