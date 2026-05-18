# dsl_annotations.tcl — Phase 5.2a class-DSL annotations table.
#
# Declarative configuration for the generic class-DSL walker
# (dsl_walker.tcl). Each row in ANNOTATIONS describes how the bridge should
# treat one outer command of a Tcl-dev-maintained class DSL (iTcl, iTk,
# TclOO oo::define augmenting form, Snit, Clay).
#
# At 5.2a.0 the table is INTENTIONALLY EMPTY. The skeleton wires the
# annotations + walker into disasm_bridge.tcl as a non-disruptive pre-pass
# so that subsequent 5.2a.1+ commits can append rows without further
# integration work. Empty table => walker pre-pass falls through =>
# bit-identical bridge output vs HEAD.
#
# Each annotation row is a list of six elements:
#   {outer_first outer_second name_idx body_idx kind body_grammar}
#
#   outer_first   first word of the outer command (e.g. "snit::type")
#   outer_second  second word required for a match, or "" for any
#                 (e.g. "create" for "oo::class create", "" for "snit::type")
#   name_idx      0-based word index of the class/object name
#   body_idx      0-based word index of the body word, or -1 for last word,
#                 -2 for second-to-last, etc. (mirrors recursion_tables A-row
#                 convention so 5.2a.3+ can re-use compute_body_base helpers)
#   kind          symbol kind to emit ("class", or "" to suppress synthesis
#                 — used by oo::define augmenting form which attributes
#                 records to an existing class)
#   body_grammar  key into BODY_GRAMMARS dict, or "" for plain script
#                 recurse (5.2a.0 default; richer grammars added in
#                 5.2a.1+ for delegate / forward / mixin handling)
#
# BODY_GRAMMARS is the per-DSL directive table used by dsl_walker when a
# row has a non-empty body_grammar key. Empty at 5.2a.0.

namespace eval ::jcm::dsl {
    variable ANNOTATIONS {}
    variable BODY_GRAMMARS [dict create]
}

# Look up the first annotation row whose outer_first matches `first` AND
# whose outer_second is either empty or equal to `second`. Returns the row
# as a list, or an empty list when no row applies.
#
# Linear scan is fine: at 5.2a's full scope the table is ~10 rows.
proc ::jcm::dsl::lookup {first second} {
    variable ANNOTATIONS
    foreach row $ANNOTATIONS {
        set r_first  [lindex $row 0]
        set r_second [lindex $row 1]
        if {$r_first ne $first} continue
        if {$r_second ne "" && $r_second ne $second} continue
        return $row
    }
    return {}
}
