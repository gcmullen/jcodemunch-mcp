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
