# dsl_annotations.tcl — Phase 5.2a class-DSL annotations table.
#
# Declarative configuration for the generic class-DSL walker
# (dsl_walker.tcl). Each row in ANNOTATIONS describes how the bridge should
# treat one outer command of a Tcl-dev-maintained class DSL (iTcl, iTk,
# TclOO oo::define augmenting form, Snit, Clay).
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
#                 convention so dispatch can re-use compute_body_base helpers)
#   kind          symbol kind to emit ("class", or "" to suppress synthesis
#                 — the latter used by oo::define augmenting form which
#                 attributes records to an existing class)
#   body_grammar  key into BODY_GRAMMARS dict, or "" for plain script
#                 recurse (no DSL-aware directive interception)
#
# BODY_GRAMMARS is a dict keyed by grammar name (e.g. "snit") whose value is
# itself a dict mapping directive first-word -> rule dict. Rule dict shape:
#   {emit <action> ?name_idx N? ?body_idx N? ?note "text"?}
#
#   emit actions:
#     suppress         — consume the command; emit nothing (slot / data declaration)
#     class_method     — emit a class_method symbol (NAME at name_idx, recurse body at body_idx)
#     delegate_method  — emit a method symbol with empty body + note "delegate to <component>"
#     parent_classes   — append each word from index 1..end onto class's parent_classes
#
# Directives NOT in the body grammar for a given DSL fall through to the
# bridge's default dispatch (SUBTABLE_C / SUBTABLE_A / bare static). This is
# how `method`/`constructor`/`destructor` inside a snit body get their
# child-symbol emission with class-qualified names — SUBTABLE_A already
# handles them correctly once the parent_qname is set by the DSL walker.

namespace eval ::jcm::dsl {
    variable ANNOTATIONS {
        {snit::type           "" 1 -1 class snit}
        {snit::widget         "" 1 -1 class snit}
        {snit::widgetadapter  "" 1 -1 class snit}
        {::snit::type           "" 1 -1 class snit}
        {::snit::widget         "" 1 -1 class snit}
        {::snit::widgetadapter  "" 1 -1 class snit}
    }
    variable BODY_GRAMMARS [dict create snit [dict create \
        typemethod   {emit class_method name_idx 1 body_idx 3} \
        proc         {emit class_method name_idx 1 body_idx 3} \
        constructor  {emit ctor body_idx 2} \
        destructor   {emit dtor body_idx 1} \
        option       {emit suppress} \
        variable     {emit suppress} \
        typevariable {emit suppress} \
        component    {emit suppress} \
        delegate     {emit delegate_dispatch} \
        superclass   {emit parent_classes} \
    ]]
}

# Look up the first annotation row whose outer_first matches `first` AND
# whose outer_second is either empty or equal to `second`. Returns the row
# as a list, or an empty list when no row applies.
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
