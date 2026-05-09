#!/usr/bin/env tclsh
#
# unresolved_detector.tcl — P1.2 deliverable (d) per PLAN_v2.1 §3 P1.2.
#
# Thin mapping layer: walker event kinds → per-symbol unresolved_dispatches
# schema entries.  Each of the 5 unresolved event kinds the walker emits maps
# to exactly one entry shape.  A sixth kind (var_command) is reserved for
# future walker work and documented as a no-op stub.
#
# Quality posture (§6.1.10): one walker kind = one row in UNRESOLVED_MAP.
# Adding a new unresolved kind is a one-row change.  The dispatcher is a
# trivial loop; the rows carry all the knowledge.
#
# Contract reference: WALKER_CONTRACT_v2_2.md §4.1 (dispatch to detector
# after recursion-table classifier), PLAN_v2.1 §4 (tag conventions §4.1-§4.6),
# PLAN_v2.1 §2.3 (unresolved rows in the opcode dispatch table).
#
# Walker event kinds handled here (SPEC §4 numbering):
#   eval_var       → §4.1  {kind eval_var       line N file F snippet S}
#   eval_brackets  → §4.2  {kind eval_brackets   line N file F snippet S}
#   var_command    → §4.3  reserved; not yet emitted by walker
#   var_method     → §4.4  {kind var_method      line N file F snippet S}
#   uplevel_var    → §4.5  {kind uplevel_var     line N file F snippet S}
#   interp_eval    → §4.6  {kind interp_eval     line N file F snippet S}
#
# Extra kind handled here (not in SPEC §4 but arising from sub-table A):
#   dynamic_body   → tagged by compute_body_base::extract_body when the body
#                    slot is a bracket-substitution (e.g. `proc foo {} [getBody]`).
#                    Schema: {kind dynamic_body line N file F snippet S}
#
# All walker unresolved event kinds also accept pragma_* entries injected by
# the pragma scanner (Worker 3, T8).  Those entries arrive pre-formed and are
# appended directly by the bridge driver without passing through this module.
# This module handles opcode-derived unresolved entries only.

namespace eval ::jcm::disasm::unresolved {
    namespace export detect append_to_sym
}

# ---------------------------------------------------------------------------
# UNRESOLVED_MAP — one row per SPEC §4 unresolved kind
#
# Format: {walker_kind schema_kind needs_snippet}
#
#   walker_kind   — the "kind" field value in the walker event dict
#   schema_kind   — the "kind" value written into the unresolved_dispatches entry
#   needs_snippet — 1 if a source snippet should be included; 0 if not
#                   (snippet is omitted when the event carries no useful
#                   source preview — e.g. var_method has only a VAR slot,
#                   which gives no callee information)
#
# WHY separate schema_kind from walker_kind: the walker names events by their
# opcode-dispatch shape (e.g. "eval_var" = "slot 0 is LITERAL eval, slot 1
# is VAR").  The schema names them by what the dispatch ambiguity means to
# a developer reading the index.  In Phase 1 these happen to be the same
# strings, but keeping them explicit means the mapping is auditable and can
# diverge if SPEC §4 numbering changes without touching the walker.

set ::jcm::disasm::unresolved::UNRESOLVED_MAP {
    {eval_var            eval_var            1}
    {eval_brackets       eval_brackets       1}
    {var_command         var_command         0}
    {var_method          var_method          0}
    {uplevel_var         uplevel_var         1}
    {interp_eval         interp_eval         0}
    {computed_namespace  computed_namespace  0}
    {dynamic_body        dynamic_body        1}
}

# ---------------------------------------------------------------------------
# detect — main entry point
# ---------------------------------------------------------------------------
#
# detect event context
#
# Parameters:
#   event   — walker event dict (kind, cmd, src_start, src_end, ...)
#   context — dict carrying caller-provided metadata needed to build the
#             schema entry; required keys:
#               file            PATH of the file being indexed
#               parent_src_offset INT byte offset of the containing body
#                               within the file (0 for top-level)
#               line_map        list of newline byte offsets in the file
#                               (for offset-to-line resolution)
#               cmd_text        source text of the anchored command
#                               (for snippet extraction)
#
# Returns a schema entry dict {kind schema_kind line N file F snippet S},
# or {} if the event's kind is not in UNRESOLVED_MAP.
#
# The bridge driver (Worker 3) appends the returned dict to the enclosing
# symbol's unresolved_dispatches list.
proc ::jcm::disasm::unresolved::detect {event context} {
    set walker_kind [dict get $event kind]

    foreach row $::jcm::disasm::unresolved::UNRESOLVED_MAP {
        lassign $row wk schema_kind needs_snippet

        if {$wk ne $walker_kind} continue

        # Resolve file offset to line number.
        set src_start       [dict get $event src_start]
        set parent_offset   [dict get $context parent_src_offset]
        set file_offset     [expr {$parent_offset + $src_start}]
        set line_map        [dict get $context line_map]
        set line            [_offset_to_line $line_map $file_offset]

        set file            [dict get $context file]

        # Build the base entry.
        set entry [dict create \
            kind    $schema_kind \
            line    $line \
            file    $file]

        # Attach snippet when useful.
        if {$needs_snippet} {
            set cmd_text [dict get $context cmd_text]
            dict set entry snippet [_truncate $cmd_text 80]
        }

        return $entry
    }

    # Event kind not in the map (e.g. a walker event that the recursion-table
    # classifier already handled, or an ensemble event).
    return {}
}

# ---------------------------------------------------------------------------
# append_to_sym — accumulate into a symbol dict
# ---------------------------------------------------------------------------
#
# append_to_sym sym_dict entry
#
# Appends $entry (from detect) to the unresolved_dispatches list on $sym_dict.
# Returns the updated sym_dict.
#
# Always-list invariant: unresolved_dispatches is initialised to [] when
# absent, never to null or omitted.  This mirrors the empty-list semantics
# required by §Δ0.2 C3 for parent_classes and package_requires.
proc ::jcm::disasm::unresolved::append_to_sym {sym_dict entry} {
    if {$entry eq {}} { return $sym_dict }
    if {![dict exists $sym_dict unresolved_dispatches]} {
        dict set sym_dict unresolved_dispatches [list]
    }
    set ud [dict get $sym_dict unresolved_dispatches]
    lappend ud $entry
    dict set sym_dict unresolved_dispatches $ud
    return $sym_dict
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _offset_to_line line_map file_offset
#
# Converts a byte offset within the file to a 1-based line number.
# line_map is a list of byte offsets at which newline characters appear
# (built by the bridge driver's build_line_offsets helper).
#
# WHY 1-based: IDEs, editors, and the existing JCM schema all use 1-based
# line numbers.  The bridge driver builds line_map with 1-based semantics.
proc ::jcm::disasm::unresolved::_offset_to_line {line_map file_offset} {
    # Binary search: find how many newlines appear before file_offset.
    # That count + 1 is the 1-based line number.
    set lo 0
    set hi [expr {[llength $line_map] - 1}]
    set line 1
    while {$lo <= $hi} {
        set mid [expr {($lo + $hi) / 2}]
        set nl_offset [lindex $line_map $mid]
        if {$nl_offset < $file_offset} {
            set line [expr {$mid + 2}]   ;# +2: 1-based + one past this newline
            set lo [expr {$mid + 1}]
        } else {
            set hi [expr {$mid - 1}]
        }
    }
    return $line
}

# _truncate text max_len
#
# Returns $text truncated to at most $max_len characters, with "..." appended
# if truncation occurred.  Newlines folded to spaces for single-line snippet.
proc ::jcm::disasm::unresolved::_truncate {text max_len} {
    # Fold newlines for readability in the snippet field.
    set text [string map {"\n" " " "\r" ""} $text]
    if {[string length $text] <= $max_len} { return $text }
    return [string range $text 0 [expr {$max_len - 4}]]...
}
