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
# Contract reference: WALKER_CONTRACT_v2_2.md §4.1 (Worker 2 view),
# PLAN_v2.1 §2.4 (sub-tables A/B/C), PLAN_v2_2_PATCH.md §Δ0.2 (schema).

source [file join [file dirname [info script]] tcl_disasm_parser.tcl]
source [file join [file dirname [info script]] compute_body_base.tcl]

namespace eval ::jcm::disasm::rectbl {
    namespace export dispatch_event classify_a classify_c
    namespace export SUBTABLE_A SUBTABLE_C
}

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
    {itcl::class    ""        2   script  class       {}}
    {::itcl::class  ""        2   script  class       {}}
    {class          ""        2   script  class       {}}
    {oo::class      create    3   script  class       {}}
    {::oo::class    create    3   script  class       {}}
    {apply          ""        1   lambda  ""          {anonymous 1}}
    {foreach        ""        -1  script  ""          {}}
    {lmap           ""        -1  script  ""          {}}
    {catch          ""        1   script  ""          {}}
    {eval           ""        1   script  ""          {literal_only 1}}
    {uplevel        ""        -1  script  ""          {literal_only 1}}
    {time           ""        1   script  ""          {}}
    {coroutine      ""        2   script  ""          {}}
    {bind           ""        -1  script  ""          {}}
    {itk_component  add       -2  script  ""          {}}
    {itk_option     define    -1  script  ""          {}}
}
# NOTE: body_arg_index = -1 means "last word"; -2 means "second-to-last" (for
# itk_component add: CREATE is next-to-last; CONFIG last is skipped).
# A positive int is the absolute 0-based word index.
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

# constructor 3-arg form: when the walker sees 4 slots (constructor ARGS INIT BODY),
# body is at index 3.  Two-arg form (constructor ARGS BODY): body at index 2.
proc ::jcm::disasm::rectbl::_constructor_dispatch {arg_count base_row} {
    # arg_count from walker includes the command word itself.
    # 4-slot constructor = "constructor ARGS INIT BODY"
    if {$arg_count == 4} {
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

# try BODY ?on/trap errcode varlist BODY?* ?finally BODY?
# Bodies are inlined in the outer bytecode (Strategy A handles them).
# errcode and varlist are data positions — they appear as literal pushes
# in the event stream but are NOT bodies; they are identified by position.
# The bridge driver ignores events at those word positions when accumulating
# call edges inside a try.
#
# WHY we need this row: the driver must know that words 2 and 3 after each
# "on"/"trap" keyword are data, not code, so it doesn't misattribute
# literal pushes at those positions as command names.
proc ::jcm::disasm::rectbl::_handle_try {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
    # Bodies inlined; no recursion needed from this handler.
    # Return enclosing_sym unchanged — driver handles the event stream.
    return $enclosing_sym
}

# switch ?opts? string ?pat body ...? (multi-arg form): bodies inlined.
# switch ?opts? string {?pat body ...?} (all-in-one form): brace block is a
# literal that the driver must recurse into via disassemble script.
# The all-in-one detection: arg_count == 3 (switch + string + {pat body...}).
proc ::jcm::disasm::rectbl::_handle_switch {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
    # Multi-arg: bodies inlined — no action.
    # All-in-one: detected by the driver when it sees a pattern_a event for
    # "switch" with the body arg being a brace-word literal.  The driver
    # calls compute_body_base to extract and recurse into that literal.
    return $enclosing_sym
}

# dict for/with/update: bodies inlined into outer bytecode.
# The dict ensemble is pre-renamed to ::tcl::dict::for etc by the compiler,
# so these arrive as ensemble events, not pattern_a.  The bridge driver
# handles them via the event stream; no recursion needed here.
proc ::jcm::disasm::rectbl::_handle_dict {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
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
proc ::jcm::disasm::rectbl::_handle_inherit {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
    # cmd_text is the full "inherit Base1 Base2 ..." command source.
    # Extract base names as words 1..end.
    if {[catch {set words [lrange $cmd_text 0 end]} err]} {
        return $enclosing_sym
    }
    set bases [lrange $words 1 end]
    set line [_src_offset_to_line $parent_file $parent_src_offset $src_start]
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
proc ::jcm::disasm::rectbl::_handle_superclass {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
    # Reuse the inherit handler — same logic, different keyword.
    # Replace "superclass" with "inherit" in position 0 so the lrange word
    # extraction is identical.
    return [_handle_inherit $cmd_text $src_start $enclosing_sym \
                $parent_file $parent_src_offset]
}

# package require NAME ?VERSION? — static dependency declaration.
# No body.  Records into package_requires field on the file's __script__
# symbol per §Δ0.2 C2 (host symbol = __script__).
# Also emits a kind=import symbol (C1: both sources populated).
#
# WHY both: find_importers uses kind=import for cross-language queries;
# get_dependency_graph uses package_requires for version-aware edges.
# Emitting only one would regress either consumer.
proc ::jcm::disasm::rectbl::_handle_package_require {cmd_text src_start enclosing_sym parent_file parent_src_offset} {
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
    set line [_src_offset_to_line $parent_file $parent_src_offset $src_start]
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
# Utility: src offset to line number
# ---------------------------------------------------------------------------
#
# The line map is a list of byte offsets of newline characters in the file
# source, built by the bridge driver.  We receive only the parent_src_offset
# (byte offset of the command's containing body start within the file) and
# the src_start relative to that body.  Together they give a file byte offset;
# we convert that to a 1-based line number.
#
# WHY the bridge driver builds the line map: the map is per-file and reused
# across many events; it's cheaper to build once than to rebuild per command.
# This helper is called only from the C-row handlers that need line numbers.
proc ::jcm::disasm::rectbl::_src_offset_to_line {parent_file parent_src_offset src_start} {
    set file_offset [expr {$parent_src_offset + $src_start}]
    # Line-map lookup is done by the bridge driver; here we return the
    # raw file offset and let the driver resolve it.  The C-row handlers
    # set a sentinel that the driver replaces with the real line number
    # after calling lookup_line(line_map, file_offset).
    # Return the raw offset tagged so the driver knows to resolve it.
    return [list __file_offset__ $file_offset]
}
