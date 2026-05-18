# dsl_walker.tcl — Phase 5.2a generic class-DSL walker.
#
# Sits as a sibling to recursion_tables.tcl's SUBTABLE_A/B/C dispatch.
# Called from disasm_bridge::_handle_pattern_a as a pre-pass: when the
# command's first word (optionally + second word) matches a row in
# ::jcm::dsl::ANNOTATIONS, this walker takes over symbol emission + body
# recursion using the bridge's existing emit helpers. When no row matches,
# returns 0 so the caller falls through to the existing SUBTABLE_C / A
# dispatch — preserving all behavior for non-DSL commands.
#
# At 5.2a.0 try_dispatch is a no-op stub: even if ANNOTATIONS had rows it
# would still return 0. 5.2a.1+ will add the dispatch logic that consults
# the row's kind + body_grammar to drive emission. Wiring it as a stub
# first keeps the integration commit deletion-free.

namespace eval ::jcm::dsl::walker {}

# Try to handle a pattern_a-shaped command via the DSL annotations table.
#
# Returns 1 if a DSL annotation owned this command (caller must `return`
# immediately to skip SUBTABLE_C / A dispatch). Returns 0 otherwise so the
# caller falls through to the existing dispatch chain.
#
# At 5.2a.0: always returns 0. ANNOTATIONS is empty, so the lookup yields
# {}; even if it didn't, the stub still bails out without acting on the
# row. Real dispatch lands in 5.2a.1+.
proc ::jcm::dsl::walker::try_dispatch {ev cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set first  [::jcm::bridge::_first_word_of_cmd $cmd_text]
    set second [::jcm::bridge::_nth_word_of_cmd  $cmd_text 1]
    set row [::jcm::dsl::lookup $first $second]
    if {[llength $row] == 0} { return 0 }
    # 5.2a.1+ dispatch on $row's kind + body_grammar lands here.
    return 0
}
