#!/usr/bin/env tclsh
#
# bridge_postpasses.tcl — extracted from tcl_disasm_bridge.tcl in P1.3 Stream 2
# (Task #16 (D)).
#
# Owns the post-pass procs the bridge driver runs after the recursive walk
# finishes:
#
#   _resolve_file_offset_tags   — replace {__file_offset__ N} sentinels emitted
#                                 by recursion_tables C-row handlers with real
#                                 1-based line numbers via the file line map.
#   _resolve_offset_in_entry    — single-entry helper used by the resolver.
#   _attach_pragmas             — NG-1 pragma → symbol attachment by line.
#   _attribute_out_of_line_bodies — cross-file iTcl `body Class::method` warning
#                                 sweep (compute_body_base owns the lookup).
#   _ensure_file_field          — populate `file` field on every symbol that
#                                 lacks one. Single sweep, runs near the end.
#   _maybe_drop_script          — elide the synthetic __script__ symbol when
#                                 it carries no signal (matches v1 elide
#                                 policy; Δ0.2 keeps it whenever
#                                 package_requires has content).
#
# All procs live in the existing ::jcm::bridge:: namespace so call sites in
# the bridge driver are unchanged. This file is sourced from
# tcl_disasm_bridge.tcl after the other workers' files; sourcing order matters
# only insofar as ::jcm::bridge state variables are declared in the driver
# (we use `variable` lookups, not direct access).

namespace eval ::jcm::bridge {}

# ---------------------------------------------------------------------------
# P5.2.1 — convention §7.1 Tier 1/2/3/5 denylist.
#
# These are commands the convention says are NOT callees: control-flow
# keywords (Tier 1), value/list manipulation + ensemble dispatchers
# (Tier 2), I/O / event-loop primitives (Tier 3), and structural / loader
# commands (Tier 5).  Tier 4 (declarations) produces symbol records, not
# callees, so it's outside this filter's concern.  §6.9 dispatchers
# (bind / after / fileevent / trace add) get suppressed by the callback
# emission rule in 5.2.7, not here.
#
# Per convention §5.10 the Tk geometry / window-management ensembles
# (grid / pack / place / wm / winfo / image / font) are KEPT as
# architectural callees — they are NOT on this denylist.
#
# Lookup is O(1) via the `_tier_deny_set` array; populated once at
# source-load time (below).
# ---------------------------------------------------------------------------

namespace eval ::jcm::bridge {
    variable _tier_deny_set
    array unset _tier_deny_set
    array set _tier_deny_set {}

    # Tier 1 — control flow (§7.1)
    foreach _n {
        if else elseif while for foreach lmap time
        switch catch try on trap finally
        return break continue yield yieldto
    } { set _tier_deny_set($_n) 1 }

    # Tier 2 — value / list / scope (§7.1).  Note: every documented
    # ensemble dispatcher (string / dict / info / array / clock / chan /
    # file / binary / namespace / package / encoding) is on this list
    # — Tier 2's "ALL subcommands of these documented ensembles" rule
    # is enforced by simply denying the dispatcher word; when 5.2.5
    # emits 2-word phrases the dispatcher is the first word and the
    # phrase still hits the deny set on the dispatcher prefix check
    # below.  upvar lives here too per §5.13.
    foreach _n {
        set incr unset lappend lassign lset lreplace llength
        lrange lsearch lsort lindex linsert lrepeat lreverse list
        split join format scan expr regexp regsub subst concat
        eof seek tell flush global variable upvar
        string dict info array clock chan file binary namespace
        package encoding
    } { set _tier_deny_set($_n) 1 }

    # Tier 3 — I/O / error / event-loop (§7.1)
    foreach _n {
        puts gets read open close update vwait error throw
    } { set _tier_deny_set($_n) 1 }

    # Tier 5 — structural / loader (§7.1).  `package require`,
    # `package provide`, `source`, `namespace import`, `namespace export`
    # are caught by the Tier 2 dispatcher (`package` / `namespace`)
    # or by `source` below.  `inherit` / `superclass` are recorded
    # via parent_classes and must NOT also surface as callees.
    foreach _n {
        source inherit superclass auto_load auto_import tm
    } { set _tier_deny_set($_n) 1 }

    # §5.5 visibility modifiers — public / private / protected are
    # method-declaration modifiers, NOT callees.  The disasm walker
    # sees the first word of `public method foo args body` and emits
    # `public` as a static callee on the enclosing class; the
    # convention says visibility prefixes don't surface as callees
    # (only the `method` / `proc` / `variable` Tier 4 declarations
    # produce records).  Net: filter all three modifiers.
    foreach _n {
        public private protected
    } { set _tier_deny_set($_n) 1 }

    # §6.8 expr operators — comparison, logical, arithmetic, bitwise,
    # ternary, and named string/boolean operators that can leak from
    # the walker's expr-bracket operand expressions.  Convention §6.8
    # says math-function calls (tcl::mathfunc::*) are OPTIONAL records,
    # operators themselves are NOT callees.  Bridge today emits a small
    # set of operator tokens as static callees (BRIDGE_VS_GOLD §4a:
    # ne x8, > x5, == x4, && x4, eq x3, != x2, < x2, >= x1); filter
    # the full operator vocabulary so future expressions don't introduce
    # new operator leakage.
    # NOTE: `tailcall` and `delete` ARE on the convention's deferred-
    # decisions list (§7.5 disposition matrix: DEFER to v1.5 spec track
    # for tailcall; 5.2.5 2-word ensemble emission will resolve `delete`
    # by upgrading the 1-word emission to `delete object` / `delete class`
    # / `delete namespace`).  Neither is filtered here.
    foreach _n {
        == != < > <= >=
        eq ne lt gt le ge in ni
        && || ! and or not xor
        + - * / % **
        & | ^ ~ << >>
        ? :
    } { set _tier_deny_set($_n) 1 }

    unset _n
}

# Return 1 if `name` is on the Tier 1/2/3/5 denylist (post-§5.10 carve-out
# for kept Tk ensembles).  Accepts both single-word names (`puts`,
# `string`) and 2-word ensemble phrases (`string length`, `dict set`,
# `namespace export`) — for the 2-word case the first word's denial
# implies the phrase is denied too.
proc ::jcm::bridge::_is_tier_denied {name} {
    variable _tier_deny_set
    if {$name eq ""} { return 0 }
    set first [lindex [split $name " "] 0]
    return [info exists _tier_deny_set($first)]
}

# Post-pass: strip Tier 1/2/3/5 denylist hits from every symbol's
# call_references list and callees list.  Run after the walker has
# emitted everything; before _maybe_drop_script (which makes elide
# decisions based on filtered call_references).
proc ::jcm::bridge::_filter_tier_denylist {} {
    variable symbols
    set new [list]
    foreach sym $symbols {
        # call_references — flat list of names
        set keep_calls [list]
        foreach c [dict get $sym call_references] {
            if {![_is_tier_denied $c]} {
                lappend keep_calls $c
            }
        }
        dict set sym call_references $keep_calls
        # callees — list of dicts; consult the `name` field.  Walker
        # doesn't populate this yet (5.2.6+ work) but the filter is
        # ready the day it turns on.
        if {[dict exists $sym callees]} {
            set keep_callees [list]
            foreach entry [dict get $sym callees] {
                set cname ""
                if {[dict exists $entry name]} { set cname [dict get $entry name] }
                if {![_is_tier_denied $cname]} {
                    lappend keep_callees $entry
                }
            }
            dict set sym callees $keep_callees
        }
        lappend new $sym
    }
    set symbols $new
}

# ---------------------------------------------------------------------------
# File-offset post-resolution pass — replace {__file_offset__ N} tagged
# tuples (produced by recursion_tables::_handle_inherit /
# _handle_superclass / _handle_package_require) with concrete 1-based line
# numbers via the file's line map.
#
# Per §11 row "Worker 2 `__file_offset__` tag (rev4 user-decided=keep)":
# the bridge owns the line map; handlers stay pure.
#
# Walks each symbol once after the dispatch phase finishes.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_resolve_file_offset_tags {} {
    variable symbols
    variable line_offsets
    set new [list]
    foreach sym $symbols {
        if {[dict exists $sym parent_classes]} {
            set pc [list]
            foreach entry [dict get $sym parent_classes] {
                lappend pc [_resolve_offset_in_entry $entry $line_offsets]
            }
            dict set sym parent_classes $pc
        }
        if {[dict exists $sym package_requires]} {
            set pr [list]
            foreach entry [dict get $sym package_requires] {
                lappend pr [_resolve_offset_in_entry $entry $line_offsets]
            }
            dict set sym package_requires $pr
        }
        lappend new $sym
    }
    set symbols $new
}

# An entry is a dict like {name X line {__file_offset__ N}}. Replace the
# tagged-tuple line with the actual 1-based line number.
proc ::jcm::bridge::_resolve_offset_in_entry {entry line_offsets} {
    if {![dict exists $entry line]} { return $entry }
    set v [dict get $entry line]
    if {[llength $v] >= 2 && [lindex $v 0] eq "__file_offset__"} {
        set off [lindex $v 1]
        dict set entry line [char_offset_to_line $line_offsets $off]
    }
    return $entry
}

# ---------------------------------------------------------------------------
# Pragma attachment per NG-1 — attach pragmas to symbols whose
# declaration_line == pragma.target_line.
#
# Implementation note: walks all symbols and all pragmas; cost is O(S*P)
# where S/P are tiny in practice. A line-keyed dict would be faster but
# this is simpler and the cost is negligible on bluice scale.
#
# Phase-1 semantics: every matched pragma adds an entry into the symbol's
# unresolved_dispatches list with kind=pragma_<TYPE>. Suppression is Phase 2.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_attach_pragmas {pragmas} {
    variable symbols
    set new [list]
    set sym_pragmas [dict create]
    foreach pr $pragmas {
        set tgt [dict get $pr target_line]
        if {![dict exists $sym_pragmas $tgt]} {
            dict set sym_pragmas $tgt [list]
        }
        set lst [dict get $sym_pragmas $tgt]
        lappend lst $pr
        dict set sym_pragmas $tgt $lst
    }
    foreach sym $symbols {
        set decl_line [dict get $sym line]
        if {[dict exists $sym_pragmas $decl_line]} {
            set ud [list]
            if {[dict exists $sym unresolved_dispatches]} {
                set ud [dict get $sym unresolved_dispatches]
            }
            foreach pr [dict get $sym_pragmas $decl_line] {
                set kind [dict get $pr kind]
                set entry [dict create kind "pragma_$kind" \
                    line [dict get $pr line] \
                    file [dict get $sym file]]
                if {[dict exists $pr extra]} {
                    foreach {ek ev} [dict get $pr extra] {
                        dict set entry $ek $ev
                    }
                }
                lappend ud $entry
            }
            dict set sym unresolved_dispatches $ud
        }
        lappend new $sym
    }
    set symbols $new
}

# ---------------------------------------------------------------------------
# Cross-file class index — `body Widget::method` attribution.
#
# Worker 2's compute_body_base::build_class_index + attribute_out_of_line_body
# do the actual lookup. The bridge's job is to:
#   1. Build the index after all symbols are emitted.
#   2. Walk every kind=method symbol whose qualified_name contains "::"
#      and whose keywords contains "itcl_body" — those are out-of-line.
#   3. For each, attribute to the class symbol; if no match, log a warning.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_attribute_out_of_line_bodies {} {
    variable symbols
    variable file_path
    set class_index [::jcm::disasm::body::build_class_index $symbols]
    foreach sym $symbols {
        if {![dict exists $sym keywords]} continue
        if {"itcl_body" ni [dict get $sym keywords]} continue
        set qname [dict get $sym qualified_name]
        set match [::jcm::disasm::body::attribute_out_of_line_body $class_index $qname]
        if {$match eq {}} {
            puts stderr "OUT_OF_LINE_BODY_NO_CLASS file=$file_path qname=$qname"
        }
    }
}

# ---------------------------------------------------------------------------
# `file` field sweep — every symbol must carry a `file` field for unresolved
# entry serialization. Set anywhere it's missing.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_ensure_file_field {} {
    variable symbols
    variable file_path
    set new [list]
    foreach sym $symbols {
        if {![dict exists $sym file] || [dict get $sym file] eq ""} {
            dict set sym file $file_path
        }
        lappend new $sym
    }
    set symbols $new
}

# ---------------------------------------------------------------------------
# __script__ elide — drop the synthetic script symbol when it carries no
# signal (no calls, no unresolved, no package_requires). Matches v1 elide
# policy; Δ0.2 keeps it whenever package_requires has content so the
# always-present field stays queryable.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_maybe_drop_script {} {
    variable symbols
    variable script_sym_idx
    if {$script_sym_idx < 0} return
    set sym [lindex $symbols $script_sym_idx]
    set has_calls [expr {[llength [dict get $sym call_references]] > 0}]
    set has_unres [expr {[dict exists $sym unresolved_dispatches]
                          && [llength [dict get $sym unresolved_dispatches]] > 0}]
    set has_pkg [expr {[dict exists $sym package_requires]
                        && [llength [dict get $sym package_requires]] > 0}]
    if {!$has_calls && !$has_unres && !$has_pkg} {
        # Drop the symbol; renumber by rebuilding the list.
        set new [list]
        set i 0
        foreach s $symbols {
            if {$i != $script_sym_idx} { lappend new $s }
            incr i
        }
        set symbols $new
        set script_sym_idx -1
    }
}
