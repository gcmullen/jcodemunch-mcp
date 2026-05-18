#!/usr/bin/env tclsh
#
# recursion_tables.tcl — P1.2 deliverable (b) per PLAN_v2.1 §3 P1.2.
#
# Declarative sub-tables A / B / C consumed by the bridge driver (T8).
# Every body-introducing construct in TCL appears here as exactly ONE row.
# Adding a new construct is a one-row table addition — no new code paths.
#
# Quality posture (§6.1.10): declarative rows, comments explain WHY each
# row exists in its form. Identifier names document WHAT.
#
# Contract reference: dev-docs/verdicts/WALKER_CONTRACT_v2_2.md §4.1
# (Worker 2 view), dev-docs/plans/PLAN_v2.1.md §2.4 (sub-tables A/B/C),
# dev-docs/plans/PLAN_v2_2_PATCH.md §Δ0.2 (schema).

source [file join [file dirname [info script]] disasm_parser.tcl]
source [file join [file dirname [info script]] compute_body_base.tcl]

namespace eval ::jcm::disasm::rectbl {
    namespace export classify_a classify_c
    namespace export SUBTABLE_A SUBTABLE_C
    namespace export DICT_BODY_SUBS
    # P1.3 bundle (2) — single C-row entrypoint. The bridge driver routes
    # all switch/try/dict/inherit/superclass/package events plus the
    # generic brace-body sweep for if/while/for/foreach/lmap through
    # `dispatch_c`. The previous public helpers (recurse_brace_bodies,
    # recurse_dict_body) are now private (`_recurse_*`) and invoked from
    # within the C-row handlers / dispatch_c fallback.
    namespace export dispatch_c
}

# ---------------------------------------------------------------------------
# Constructor slot constants (used by _constructor_dispatch).
#
# WHY two forms: the iTcl 3-arg constructor `constructor ARGS INIT BODY`
# adds an INIT slot between ARGS and BODY that the basic 2-arg form
# (TclOO + iTcl-basic) does not. The walker reports arg_count (which
# includes the command word itself), so:
#   2-arg: `constructor ARGS BODY`           → arg_count == 3, body at idx 2
#   3-arg: `constructor ARGS INIT BODY`      → arg_count == 4, body at idx 3
# Slot counts are inclusive of the command word; word index is 0-based.
set ::jcm::disasm::rectbl::CONSTRUCTOR_TWO_ARG_SLOT_COUNT 3
set ::jcm::disasm::rectbl::CONSTRUCTOR_THREE_ARG_SLOT_COUNT 4

# `dict for / with / update / map` carry an inline script body the walker
# does not surface as nested events (the bytecode compiler inlines it into
# a sub-context the disasm parser doesn't expand). The bridge driver
# explicitly recurses into the last-word body for these subcommands.
#
# WHY a named constant: the same list lived as a hard-coded `in {for with
# update map}` literal in the bridge driver hot path; pulling it out keeps
# the supported-subcommand whitelist in the same file as the recursion-
# routing handlers.
set ::jcm::disasm::rectbl::DICT_BODY_SUBS {for with update map}

# ---------------------------------------------------------------------------
# Sub-table A — Literal-recursion bodies (~22 rows)
#
# Each row: {first_word ?second_word? body_arg_index recurse_via kind ?extra?}
#
#   first_word   — command name to match on (pattern_a event "name" field)
#   second_word  — second literal word required (e.g. "add" in itk_component add),
#                  or "" to skip the check
#   body_arg_index — 0-based word index of the body argument in the command source
#   recurse_via  — "lambda" (disassemble lambda {ARGS BODY}) or "script"
#                  (disassemble script BODY)
#   kind         — symbol kind to emit, or "" for anonymous (no symbol)
#   extra        — additional key-value pairs for the emitted symbol dict
#
# WHY "lambda" vs "script": proc/method bodies are compiled as lambdas;
# namespace/class bodies are scripts.  The recursive parser call differs:
# lambda form receives {{args} body}; script form receives just the body.
#
# WHY body_arg_index is the word index in the parent command's source text:
# The bridge driver calls compute_body_base::find_word_start on the parent
# command's src_start..src_end substring to locate the body.  See §2.2.
#
# Row notes:
#   - "class NAME BODY" (custom DSL): confirmed Q2 verdict from P1.1;
#     bluice uses this pattern extensively in widget files.
#   - itk_component add: body_arg_index is the CREATE slot; the CONFIG
#     slot (optional 5th word) is iTk DSL that Tcl's compiler does NOT
#     see as commands — explicitly skipped by keeping body_arg at the
#     CREATE position.  If -protected is present, index shifts by 1;
#     the dispatch handler compensates via _itk_component_body_idx.
#   - itk_option define: last arg is optional CONFIG body.  The bridge
#     checks whether the trailing arg is a brace-word before recursing.
#   - apply LAMBDA args: body_arg_index points to the whole LAMBDA literal
#     (which is a list {ARGS BODY}); recurse_via=lambda handles extraction
#     of the body sub-word from the list.
#   - constructor 3-arg form (iTcl): ARGS INIT BODY — body is at index 3.
#     The 2-arg form (TclOO/iTcl basic): ARGS BODY — body is at index 2.
#     These are distinguished at dispatch time by word count.
#   - bind ?tag? window SCRIPT: last arg; no symbol emitted.  The bridge
#     driver uses _last_word_index to locate it.
#   - foreach / lmap / catch / eval / uplevel / time: no symbol; recurse
#     to capture Layer-2 call edges inside the body.
#   - eval BODY (when literal): the "when literal" guard is applied in the
#     dispatch handler — a VAR second slot is already handled by the walker
#     as eval_var (unresolved).

# {first second body_idx recurse_via kind extra}
set ::jcm::disasm::rectbl::SUBTABLE_A {
    {proc           ""        3   lambda  function    {}}
    {method         ""        3   lambda  method      {}}
    {public         method    4   lambda  method      {visibility public}}
    {private        method    4   lambda  method      {visibility private}}
    {protected      method    4   lambda  method      {visibility protected}}
    {body           ""        3   lambda  method      {out_of_line 1}}
    {configbody     ""        2   script  configbody  {}}
    {constructor    ""        2   lambda  constructor {}}
    {destructor     ""        1   lambda  destructor  {}}
    {namespace      eval      2   script  namespace   {}}
    {apply          ""        1   lambda  ""          {anonymous 1}}
    {foreach        ""        -1  script  ""          {}}
    {lmap           ""        -1  script  ""          {}}
    {catch          ""        1   script  ""          {}}
    {eval           ""        1   script  ""          {literal_only 1}}
    {uplevel        ""        -1  script  ""          {literal_only 1}}
    {time           ""        1   script  ""          {}}
    {coroutine      ""        2   script  ""          {}}
    {bind           ""        -1  script  ""          {}}
}
# NOTE: body_arg_index = -1 means "last word"; a positive int is the absolute
# 0-based word index.
# constructor 3-arg form (body at index 3) is handled by _constructor_dispatch.

# ---------------------------------------------------------------------------
# Sub-table B — Outer-bytecode-inlined bodies (no recursion needed)
#
# WHY no rows are needed here: under Strategy A (WALKER_CONTRACT_v2_2 §4.1),
# inner commands for these constructs appear as events with src_start falling
# INSIDE the outer command's src_start..src_end range.  The flat-pc walker
# already emits them; Worker 2 has nothing extra to do.
#
# Worker 3 (bridge driver) uses containment checks to decide whether a given
# event belongs inside a body it just recursed into.  Events for sub-table B
# constructs arrive inline and are attributed to their enclosing symbol by
# the driver's stack of open symbol ranges.
#
# Constructs covered by this table (documentation only):
#   if cond body ?elseif cond body? ?else body?
#   while cond body
#   for init cond next body
#   [bracket] substitution
#
# These four construct types have their bytecode inlined into the outer
# command stream.  The 2/12,010 unrecognized cases from P1.1 that Strategy A
# closes are exactly this: bracket-substitution invokes that P1.1's per-command
# walker attributed to the wrong command.  Strategy A closes them by
# construction — no handler needed here.
# ---------------------------------------------------------------------------

# Sub-table B is intentionally empty (documentation only — see comment above).

# ---------------------------------------------------------------------------
# Sub-table C — Mixed / conditional rows
#
# These constructs require per-row handlers because they either:
#   (a) have bodies inlined like B but with data positions that must be
#       skipped (try, switch, dict for/with/update), or
#   (b) carry no body at all but modify schema fields on the enclosing symbol
#       (inherit, superclass, package require).
#
# Row format for schema-only entries:
#   {cmd_name  handler_proc}
#
# The handler procs below receive: cmd_text, src_start, enclosing_sym_dict,
# parent_file, parent_src_offset and return an updated enclosing_sym_dict.

set ::jcm::disasm::rectbl::SUBTABLE_C {
    {try             _handle_try}
    {switch          _handle_switch}
    {dict            _handle_dict}
    {inherit         _handle_inherit}
    {superclass      _handle_superclass}
    {package         _handle_package_require}
}

# ---------------------------------------------------------------------------
# Sub-table A dispatch
# ---------------------------------------------------------------------------

# Look up a pattern_a event name in SUBTABLE_A.  Returns the matching row
# list or {} if not matched.  Handles multi-word commands (public method,
# namespace eval, oo::class create, itk_component add) by checking the
# optional second-word field.
#
# Parameters:
#   name        — "name" field from pattern_a event
#   slots       — full slot list from the walker event (for second-word check)
#   arg_count   — arg_count from the walker event
proc ::jcm::disasm::rectbl::classify_a {name slots arg_count} {
    foreach row $::jcm::disasm::rectbl::SUBTABLE_A {
        lassign $row first second body_idx recurse_via kind extra
        if {$first ne $name} continue

        # Second-word check
        if {$second ne ""} {
            # slot 1 is the second word in the command
            set s1 [lindex $slots 1]
            if {$s1 eq "" || [dict get $s1 kind] ne "LITERAL"} continue
            if {[dict get $s1 value] ne $second} continue
        }

        # constructor: pick 2-arg vs 3-arg form by arg_count
        if {$first eq "constructor"} {
            set row [_constructor_dispatch $arg_count $row]
        }

        return $row
    }
    return {}
}

# constructor 3-arg form: when the walker sees 4 slots
# (`constructor ARGS INIT BODY`, iTcl extended form), body is at word
# index 3. Two-arg form (`constructor ARGS BODY`, TclOO + iTcl basic): body
# at word index 2.
#
# arg_count from walker includes the command word itself, so the slot
# counts are 3 and 4 respectively (see CONSTRUCTOR_TWO_ARG_SLOT_COUNT /
# CONSTRUCTOR_THREE_ARG_SLOT_COUNT named at the top of this file).
proc ::jcm::disasm::rectbl::_constructor_dispatch {arg_count base_row} {
    if {$arg_count == $::jcm::disasm::rectbl::CONSTRUCTOR_THREE_ARG_SLOT_COUNT} {
        lset base_row 2 3
    }
    return $base_row
}

# Resolve body_arg_index=-1 (last word) and -2 (second-to-last)
# given the total word count of the command.
proc ::jcm::disasm::rectbl::resolve_body_idx {body_idx total_words} {
    if {$body_idx >= 0} { return $body_idx }
    # -1 = last, -2 = second-to-last, etc.
    return [expr {$total_words + $body_idx}]
}

# ---------------------------------------------------------------------------
# Sub-table C handlers
# ---------------------------------------------------------------------------
#
# P1.3 bundle (2) — Module boundary B. C-row handlers now own body
# recursion for their own construct. Each handler receives:
#
#   cmd_text             — full source of the dispatched command (chars).
#   src_start            — file-absolute char offset of cmd's first char.
#   enclosing_sym        — current parent symbol dict (for inherit /
#                          superclass / package_require to mutate fields).
#   parent_file          — file path (for the {__file_offset__ N} tag).
#   parent_src_offset    — historical 0; offset arithmetic is owned by
#                          the bridge post-resolution pass.
#   walk_cb              — callback prefix (e.g.
#                          `[list ::jcm::bridge::walk_recursive]`) used to
#                          recurse body slots without naming the bridge
#                          namespace from this file.
#   parent_qname         — fully-qualified name of the enclosing symbol;
#                          forwarded to walk_cb so call edges inside the
#                          body attribute correctly.
#   parent_sym_idx       — bridge-side index of the enclosing symbol in
#                          its `symbols` list; passed to walk_cb so inner
#                          call edges land on the right parent.
#   ev_extra             — handler-specific event metadata (e.g. dict
#                          subcommand). Empty dict for handlers that
#                          don't need it.
#
# Body-recursion C-rows (try/switch/dict) replace the historical
# bridge-driver call to recurse_brace_bodies / recurse_dict_body.
# Schema-only rows (inherit / superclass / package_require) ignore the
# walk_cb parameters.

# try BODY ?on/trap errcode varlist BODY?* ?finally BODY?
# Bodies are inlined in the outer bytecode (Strategy A handles them).
# errcode and varlist are data positions — they appear as literal pushes
# in the event stream but are NOT bodies; they are identified by position.
# The bridge driver ignores events at those word positions when accumulating
# call edges inside a try.
#
# Body recursion (P1.3 bundle 2): walk the main body + each on/trap/finally
# clause body so call edges + nested defs inside survive.
proc ::jcm::disasm::rectbl::_handle_try {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return $enclosing_sym }
    _recurse_try $cmd_text $src_start $parts $parent_sym_idx $parent_qname $walk_cb
    return $enclosing_sym
}

# switch ?opts? string ?pat body ...? (multi-arg form): bodies inlined.
# switch ?opts? string {?pat body ...?} (all-in-one form): brace block is a
# literal that the driver must recurse into via disassemble script.
#
# Body recursion (P1.3 bundle 2): switch's bodies are not surfaced as
# nested events — the bytecode compiler inlines them. Recurse the brace
# bodies so call edges + nested defs survive.
proc ::jcm::disasm::rectbl::_handle_switch {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return $enclosing_sym }
    _recurse_switch $cmd_text $src_start $parts $parent_sym_idx $parent_qname $walk_cb
    return $enclosing_sym
}

# dict for/with/update/map: bodies inlined into outer bytecode.
# The dict ensemble is pre-renamed to ::tcl::dict::for etc by the compiler,
# so these arrive as ensemble events. dispatch_c routes them here with the
# subcommand carried in ev_extra.
proc ::jcm::disasm::rectbl::_handle_dict {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    set sub ""
    if {[dict exists $ev_extra subcommand]} {
        set sub [dict get $ev_extra subcommand]
    }
    if {$sub ni $::jcm::disasm::rectbl::DICT_BODY_SUBS} {
        return $enclosing_sym
    }
    _recurse_dict_body $cmd_text $src_start $sub $parent_sym_idx $parent_qname $walk_cb
    return $enclosing_sym
}

# inherit Base1 Base2 ... — iTcl inheritance declaration.
# No body.  Records each base name into parent_classes field on the enclosing
# class symbol.  Verbatim base names preserved (no namespace stripping) per
# PLAN_v2_2_PATCH.md §Δ0.2 carried-forward items.
#
# WHY verbatim: the developer reads and writes the name as written; stripping
# "::namespace::" qualifications would require re-qualifying at query time
# and introduces ambiguity when two different namespaces define a class with
# the same bare name.
proc ::jcm::disasm::rectbl::_handle_inherit {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    # cmd_text is the full "inherit Base1 Base2 ..." command source.
    # Extract base names as words 1..end.
    if {[catch {set words [lrange $cmd_text 0 end]} err]} {
        return $enclosing_sym
    }
    set bases [lrange $words 1 end]
    set line [_tag_unresolved_file_offset $parent_file $parent_src_offset $src_start]
    if {![dict exists $enclosing_sym parent_classes]} {
        dict set enclosing_sym parent_classes [list]
    }
    set pc [dict get $enclosing_sym parent_classes]
    foreach base $bases {
        lappend pc [dict create name $base line $line]
    }
    dict set enclosing_sym parent_classes $pc
    return $enclosing_sym
}

# superclass Base1 Base2 ... — TclOO inheritance declaration.
# Folds into parent_classes alongside iTcl inherit per §Δ0.2 carried-forward
# items.  Same field, same shape: {name STRING, line INT}.
#
# WHY same field: from the caller's perspective (get_class_hierarchy),
# "this class extends these bases" is a single concept regardless of whether
# the TCL dialect spells it "inherit" or "superclass".
proc ::jcm::disasm::rectbl::_handle_superclass {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    # Reuse the inherit handler — same logic, different keyword.
    # Replace "superclass" with "inherit" in position 0 so the lrange word
    # extraction is identical.
    return [_handle_inherit $cmd_text $src_start $enclosing_sym \
                $parent_file $parent_src_offset $walk_cb $parent_qname \
                $parent_sym_idx $ev_extra]
}

# package require NAME ?VERSION? — static dependency declaration.
# No body.  Records into package_requires field on the file's __script__
# symbol per §Δ0.2 C2 (host symbol = __script__).
# Also emits a kind=import symbol (C1: both sources populated).
#
# WHY both: find_importers uses kind=import for cross-language queries;
# get_dependency_graph uses package_requires for version-aware edges.
# Emitting only one would regress either consumer.
proc ::jcm::disasm::rectbl::_handle_package_require {cmd_text src_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    if {[catch {set words [lrange $cmd_text 0 end]} err]} {
        return $enclosing_sym
    }
    # words: {package require NAME ?VERSION?}
    if {[llength $words] < 3} { return $enclosing_sym }
    if {[lindex $words 1] ne "require"} { return $enclosing_sym }
    set pkg_name [lindex $words 2]
    set version  ""
    if {[llength $words] >= 4} {
        set version [lindex $words 3]
    }
    set line [_tag_unresolved_file_offset $parent_file $parent_src_offset $src_start]
    # Populate package_requires field (lives on __script__ symbol).
    if {![dict exists $enclosing_sym package_requires]} {
        dict set enclosing_sym package_requires [list]
    }
    set pr [dict get $enclosing_sym package_requires]
    set entry [dict create name $pkg_name version $version]
    if {$version eq ""} { dict set entry version null }
    lappend pr $entry
    dict set enclosing_sym package_requires $pr
    # The kind=import symbol is emitted by the bridge driver separately
    # after this handler returns (it checks for the import flag below).
    dict set enclosing_sym _emit_import [dict create \
        name $pkg_name version $version line $line]
    return $enclosing_sym
}

# ---------------------------------------------------------------------------
# Sub-table C dispatch
# ---------------------------------------------------------------------------

# Look up a pattern_a event name in SUBTABLE_C. Returns the handler proc name
# or "" if not matched.
proc ::jcm::disasm::rectbl::classify_c {name slots} {
    foreach row $::jcm::disasm::rectbl::SUBTABLE_C {
        lassign $row cmd_name handler
        if {$cmd_name ne $name} continue
        # Multi-word commands (package require, dict for etc.) need
        # second-word check.
        if {$name eq "dict"} {
            # dict for/with/update — all are sub-table C (inlined).
            return $handler
        }
        if {$name eq "package"} {
            set s1 [lindex $slots 1]
            if {$s1 eq "" || [dict get $s1 kind] ne "LITERAL"} continue
            if {[dict get $s1 value] ne "require"} continue
        }
        return $handler
    }
    return ""
}

# ---------------------------------------------------------------------------
# Single C-row entrypoint (P1.3 bundle (2) — Module boundary B).
#
# `dispatch_c` is the ONLY name the bridge driver should reach for
# C-row + brace-body sweep work. It performs three jobs:
#
#   1. SUBTABLE_C lookup — for a known C-row construct (try/switch/dict/
#      inherit/superclass/package), invoke the matching handler with the
#      walk callback + parent metadata so the handler can both mutate
#      schema fields AND recurse bodies as one unit.
#   2. Brace-body sweep fallback — for if/while/for/foreach/lmap (which
#      don't appear in SUBTABLE_C because they don't carry schema
#      mutations), invoke the private `_recurse_brace_bodies` helper.
#   3. Schema-handler return — schema-only handlers (inherit/superclass/
#      package) mutate `enclosing_sym` and return the new dict; the
#      driver applies the returned dict back to its symbols list. Body-
#      recursion handlers return enclosing_sym unchanged.
#
# Parameters:
#   ev_name           — first-word name (pattern_a name field, or
#                       ensemble's "dict" for the dict ensemble path).
#   cmd_text          — full command source.
#   abs_start         — file-absolute char offset of cmd_text[0].
#   enclosing_sym     — current parent symbol dict (mutated by inherit/
#                       superclass/package handlers; passed through by
#                       body-recursion handlers).
#   parent_file       — file path forwarded to handlers.
#   parent_src_offset — historical 0; offset arithmetic owned by bridge.
#   walk_cb           — `[list ::jcm::bridge::walk_recursive]` callback
#                       prefix; handlers invoke it as
#                       `{*}$walk_cb body_src body_offset parent_idx parent_qname`.
#   parent_qname      — fully-qualified name of the enclosing symbol.
#   parent_sym_idx    — bridge-side index of the enclosing symbol.
#   ev_extra          — handler-specific extras (e.g. dict subcommand).
#                       Empty dict {} when not needed.
#
# Returns:
#   (possibly mutated) enclosing_sym, or {} when ev_name has no matching
#   row and no brace-body fallback applies (caller leaves enclosing_sym
#   alone — there's a sentinel `_dispatched 0` in the returned dict so
#   the caller can distinguish "handler ran but didn't change anything"
#   from "no handler ran").
proc ::jcm::disasm::rectbl::dispatch_c {ev_name cmd_text abs_start enclosing_sym parent_file parent_src_offset walk_cb parent_qname parent_sym_idx ev_extra} {
    # Slots are only used by classify_c's `package require` second-word
    # check today. dispatch_c receives the synthesized slots when the
    # bridge has them (encoded inside ev_extra under "slots") — otherwise
    # we fall back to a one-element slot list so classify_c won't hit a
    # nil. Schema-only callers (inherit/superclass) don't need slot[1].
    set slots [list]
    if {[dict exists $ev_extra slots]} {
        set slots [dict get $ev_extra slots]
    }
    set handler [classify_c $ev_name $slots]
    if {$handler ne ""} {
        # SUBTABLE_C row — invoke handler. Schema-only handlers ignore
        # walk_cb/parent_*; body-recursion handlers use them.
        return [$handler $cmd_text $abs_start $enclosing_sym \
            $parent_file $parent_src_offset $walk_cb $parent_qname \
            $parent_sym_idx $ev_extra]
    }
    # Brace-body sweep fallback for if/while/for/foreach/lmap. The
    # bridge previously called `recurse_brace_bodies` directly for
    # these; folding the call here keeps every C-row + brace-sweep
    # entry inside dispatch_c.
    if {$ev_name in {if while for foreach lmap}} {
        _recurse_brace_bodies $cmd_text $abs_start $ev_name \
            $parent_sym_idx $parent_qname $walk_cb
    }
    return $enclosing_sym
}

# ---------------------------------------------------------------------------
# Utility: tag a file offset for later resolution.
#
# Despite the historical name, this proc does NOT compute a line number.
# It returns a `{__file_offset__ N}` tagged tuple that the bridge driver
# replaces with a 1-based line number in the post-resolution pass
# (bridge_postpasses.tcl::_resolve_file_offset_tags). Handlers stay pure —
# they don't see the line map; the driver owns it per §11 row "Worker 2
# `__file_offset__` tag (rev4 user-decided=keep)".
#
# Renamed in P1.3 Stream 2 from `_src_offset_to_line` (which suggested
# this returned a line number; it never did) to make the post-resolution
# contract obvious to a future maintainer reading the C-row handlers.
# ---------------------------------------------------------------------------
proc ::jcm::disasm::rectbl::_tag_unresolved_file_offset {parent_file parent_src_offset src_start} {
    set file_offset [expr {$parent_src_offset + $src_start}]
    return [list __file_offset__ $file_offset]
}

# ---------------------------------------------------------------------------
# Recursion-routing helpers (P1.3 Stream 2 — Task #16 (F);
# refactored under P1.3 bundle (2) — Module boundary B).
# ---------------------------------------------------------------------------
#
# Body-traversal substance for switch/try/dict/generic-brace bodies. Lives
# here (the recursion-table file) rather than the bridge driver so each
# rule has exactly one declarative location: the SUBTABLE_C row identifies
# the dispatcher; the handler proc above performs schema mutation AND body
# recursion as one unit.
#
# Visibility (post-bundle 2): these helpers are PRIVATE (`_recurse_*`).
# The bridge driver no longer calls them by name — it routes everything
# through `dispatch_c`. Only the C-row handlers in this file invoke them.
#
# Module-boundary contract: helpers receive a `walk_cb` callback PREFIX
# (e.g. `[list ::jcm::bridge::walk_recursive]`) which they invoke via
# `{*}$walk_cb body_src body_offset parent_sym_idx parent_qname`. This
# keeps the recursion-table file free of any direct dependency on the
# bridge driver namespace; only the driver knows how to resolve a body
# back into walker events.

# Recurse into bodies of compound commands the walker can't decompile.
# Per-command body-position knowledge keeps us from misinterpreting data
# positions (errcode lists, var lists) as code.
#
# Supported shapes:
#   switch ?opts? VALUE pat body ?pat body ...?
#       — strip leading -opts (start with '-'); the value word; then alternating
#         pattern (skip), body (recurse).  `-` continuation bodies skipped.
#   switch ?opts? VALUE {pat body pat body ...}    (block form)
#       — single block argument; flatten and recurse the inner odd words.
#   try BODY ?on errcode varlist BODY?* ?trap pat varlist BODY?* ?finally BODY?
#       — first arg is BODY; thereafter scan for keywords on/trap/finally
#         and recurse the trailing brace-word.
#   if/while/for/foreach/lmap fall through to a generic brace-body sweep —
#         the walker DOES emit events for these in most cases; the sweep
#         here covers compile-context fallbacks where the walker missed.
proc ::jcm::disasm::rectbl::_recurse_brace_bodies {cmd_text abs_start name parent_sym_idx parent_qname walk_cb} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} return
    switch -- $name {
        switch {
            _recurse_switch $cmd_text $abs_start $parts \
                $parent_sym_idx $parent_qname $walk_cb
        }
        try {
            _recurse_try $cmd_text $abs_start $parts \
                $parent_sym_idx $parent_qname $walk_cb
        }
        default {
            _recurse_generic_bodies $cmd_text $abs_start $parts $name \
                $parent_sym_idx $parent_qname $walk_cb
        }
    }
}

proc ::jcm::disasm::rectbl::_recurse_switch {cmd_text abs_start parts parent_sym_idx parent_qname walk_cb} {
    set total [llength $parts]
    # Strip leading -opt words.
    set i 1
    while {$i < $total && [string match "-*" [lindex $parts $i]]} { incr i }
    # Skip the value word.
    incr i
    if {$i >= $total} return
    # Block form: single brace word containing pat/body pairs.
    if {[expr {$total - $i}] == 1} {
        set inner [lindex $parts $i]
        # Recurse into the odd-index words inside inner (split into list).
        if {[catch {set inner_parts [lrange $inner 0 end]}]} return
        # Find the body's char offset within cmd_text via word_start.
        set body_idx $i
        set extracted [::jcm::disasm::body::extract_from_event $cmd_text $body_idx $abs_start]
        if {![dict get $extracted ok]} return
        set base [dict get $extracted body_offset]
        # Walk pat/body pairs inside the inner block.  Each body's offset
        # within the inner string is approximated by find_word_start.
        set inner_text [dict get $extracted body_src]
        set j 0
        set n [llength $inner_parts]
        while {$j < $n} {
            set body_word [lindex $inner_parts [expr {$j + 1}]]
            if {$body_word eq "-"} { incr j; continue }
            set start_off [::jcm::disasm::body::find_word_start $inner_text [expr {$j + 1}]]
            if {$start_off < 0} break
            set crange [::jcm::disasm::body::word_content_range $inner_text $start_off]
            if {$crange eq {}} { incr j 2; continue }
            lassign $crange content_start content_end
            set body_src [string range $inner_text $content_start $content_end]
            {*}$walk_cb $body_src [expr {$base + $content_start}] $parent_sym_idx $parent_qname
            incr j 2
        }
        return
    }
    # Inline form: switch VALUE pat body pat body ...
    # Note: "PAT - PAT BODY" means PAT-1 inherits PAT-2's body. Skip past
    # the `-` continuation slot entirely so we don't treat the next pattern
    # word as a body.
    set j $i
    while {$j < $total} {
        if {[expr {$j + 1}] >= $total} break
        set body_word [lindex $parts [expr {$j + 1}]]
        if {$body_word eq "-"} {
            # PAT - : skip both PAT and `-`, the next iteration's PAT shares
            # this group's body.
            incr j 2
            continue
        }
        set body_idx [expr {$j + 1}]
        set extracted [::jcm::disasm::body::extract_from_event $cmd_text $body_idx $abs_start]
        if {[dict get $extracted ok]} {
            {*}$walk_cb [dict get $extracted body_src] \
                [dict get $extracted body_offset] $parent_sym_idx $parent_qname
        }
        incr j 2
    }
}

proc ::jcm::disasm::rectbl::_recurse_try {cmd_text abs_start parts parent_sym_idx parent_qname walk_cb} {
    set total [llength $parts]
    if {$total < 2} return
    # First brace word is the main body.
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text 1 $abs_start]
    if {[dict get $extracted ok]} {
        {*}$walk_cb [dict get $extracted body_src] \
            [dict get $extracted body_offset] $parent_sym_idx $parent_qname
    }
    # Scan for clause keywords; the BODY word follows after the clause's
    # data slots (errcode + varlist for on/trap; nothing for finally).
    set i 2
    while {$i < $total} {
        set kw [lindex $parts $i]
        switch -- $kw {
            on - trap {
                # on errcode varlist BODY  -> body at i+3
                set body_idx [expr {$i + 3}]
                if {$body_idx < $total} {
                    set ext [::jcm::disasm::body::extract_from_event $cmd_text $body_idx $abs_start]
                    if {[dict get $ext ok]} {
                        {*}$walk_cb [dict get $ext body_src] \
                            [dict get $ext body_offset] $parent_sym_idx $parent_qname
                    }
                }
                incr i 4
            }
            finally {
                # finally BODY -> body at i+1
                set body_idx [expr {$i + 1}]
                if {$body_idx < $total} {
                    set ext [::jcm::disasm::body::extract_from_event $cmd_text $body_idx $abs_start]
                    if {[dict get $ext ok]} {
                        {*}$walk_cb [dict get $ext body_src] \
                            [dict get $ext body_offset] $parent_sym_idx $parent_qname
                    }
                }
                incr i 2
            }
            default { incr i }
        }
    }
}

proc ::jcm::disasm::rectbl::_recurse_generic_bodies {cmd_text abs_start parts name parent_sym_idx parent_qname walk_cb} {
    # Sweep every brace-word; recurse into it. Used for if/while/for/foreach/lmap
    # as a safety net when the walker doesn't surface body events from a
    # nested compile context.
    set total [llength $parts]
    for {set j 1} {$j < $total} {incr j} {
        set word [lindex $parts $j]
        # Skip non-brace words and obvious var/option references.
        if {[string index $word 0] eq "-"} continue
        # Locate the word in the cmd source; check if it was brace-delimited.
        set start_off [::jcm::disasm::body::find_word_start $cmd_text $j]
        if {$start_off < 0} continue
        if {[string index $cmd_text $start_off] ne "\{"} continue
        set ext [::jcm::disasm::body::extract_from_event $cmd_text $j $abs_start]
        if {[dict get $ext ok]} {
            {*}$walk_cb [dict get $ext body_src] \
                [dict get $ext body_offset] $parent_sym_idx $parent_qname
        }
    }
}

# Recurse into the body argument of `dict for/with/update/map`. Body word
# index varies by subcommand:
#   dict for VARLIST DICT BODY    -> body at index 4
#   dict with DICTVAR BODY        -> body at index 3 (no VARLIST)
#   dict with DICTVAR ?KEY ...? BODY -> body is last word
#   dict update DICTVAR KEY VAR ?KEY VAR ...? BODY -> body is last word
#   dict map VARLIST DICT BODY    -> body at index 4
#
# We use the last-word heuristic uniformly; it's correct for all four
# subcommands listed in DICT_BODY_SUBS at the top of this file.
proc ::jcm::disasm::rectbl::_recurse_dict_body {cmd_text abs_start sub parent_sym_idx parent_qname walk_cb} {
    set total [_count_cmd_words $cmd_text]
    if {$total < 4} return
    set body_idx [expr {$total - 1}]    ;# default: last word
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text $body_idx $abs_start]
    if {[dict get $extracted ok]} {
        {*}$walk_cb [dict get $extracted body_src] \
            [dict get $extracted body_offset] $parent_sym_idx $parent_qname
    }
}

# Local word-count helper (cheap; mirrors the bridge driver's helper).
# Lives here so recurse_dict_body has no cross-file dependency beyond
# compute_body_base + this file itself.
proc ::jcm::disasm::rectbl::_count_cmd_words {cmd_text} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return [llength [regexp -all -inline {\S+} $cmd_text]]
    }
    return [llength $parts]
}
