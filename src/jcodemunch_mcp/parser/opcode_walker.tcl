#!/usr/bin/env tclsh
#
# opcode_walker.tcl — P1.1 deliverable (b) per PLAN_v2.1 §3 P1.1.
#
# Typed event stream over the parser's structured output. Implements
# PLAN_v2.1 §2.3 dispatch table plus the ensemble pre-rename table per
# ENSEMBLE_VERDICT.md (10 ensembles after R32 corpus probe surfaced
# `string`).
#
# Quality posture (per PLAN_v2.1 §6.1.10): one §2.3 row = one entry in
# the declarative DISPATCH table. Adding a pattern is a one-row change.
# The dispatcher itself is a small loop; the rows are predicates.
#
# Empirical bytecode shapes verified against tclsh 8.6.14 in a probe
# session (P1.1 grounding, 2026-05-08); receipts noted per row below.
#
# Event types emitted (one per recognized pattern):
#
#   {kind pattern_a       cmd command_idx N name STRING arg_count INT}
#   {kind pattern_a2      cmd command_idx N fqn STRING method STRING arg_count INT}
#   {kind pattern_b       cmd command_idx N method STRING arg_count INT}
#   {kind callback        cmd command_idx N method STRING}
#   {kind expand_args     cmd command_idx N name STRING}
#   {kind apply_lambda    cmd command_idx N lambda STRING}
#   {kind namespace_eval  cmd command_idx N ns STRING body STRING}
#   {kind ensemble        cmd command_idx N ensemble STRING subcommand STRING arg_count INT}
#   {kind eval_var        cmd command_idx N}
#   {kind var_method      cmd command_idx N}
#   {kind uplevel_var     cmd command_idx N}
#   {kind interp_eval     cmd command_idx N}
#   {kind eval_brackets   cmd command_idx N}
#   {kind unrecognized    cmd command_idx N reason STRING}
#
# Scope note (P1.1 spike): per-command instruction analysis. Sub-table
# B "bracket inlining" cases (where an outer command's terminal invoke
# is listed under a later sibling command's pc range) are recognized
# heuristically when an outer command's only push is a known `eval`/
# `uplevel`/`interp eval` literal with no terminal invoke in its own
# pc range. Precise pc-cross-attribution is a P1.2 concern.

source [file join [file dirname [info script]] tcl_disasm_parser.tcl]

namespace eval ::jcm::disasm::walker {
    namespace export walk format_events
    variable ENSEMBLES
    variable DISPATCH
}

# ---------------------------------------------------------------------------
# Ensemble pre-rename table — 10 entries (post P1.1(f) ENSEMBLE_VERDICT).
#
# Source: PLAN_v2.1 §2.3 + R32 corpus probe (validation/probes/
# ensemble_enumeration_probe.tcl, ENSEMBLE_VERDICT.md).
# ---------------------------------------------------------------------------

set ::jcm::disasm::walker::ENSEMBLES {
    array binary chan clock dict encoding file info namespace string
}

# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------

# Walk a parser dict (from ::jcm::disasm::parser::parse) and emit a list
# of typed events. Missing terminal invokes -> unrecognized or skipped.
proc ::jcm::disasm::walker::walk {parsed} {
    if {[dict exists $parsed error]} {
        return [list [dict create kind disasm_error \
            reason [dict get $parsed error]]]
    }
    set events [list]
    foreach c [dict get $parsed commands] {
        set cmd_events [_analyze_command $c [dict get $parsed literals]]
        foreach ev $cmd_events { lappend events $ev }
    }
    return $events
}

# ---------------------------------------------------------------------------
# Per-command analysis — applies §2.3 dispatch table
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_analyze_command {c literals} {
    set insns   [dict get $c instructions]
    set cmd_idx [dict get $c idx]
    set N       [dict get $c src_start]

    if {[llength $insns] == 0} {
        return [list]
    }

    set terminal [_find_terminal_invoke $insns]
    if {$terminal eq ""} {
        # Sub-table B heuristic: outer-bytecode-inlined parent that has
        # only a push of "eval"/"uplevel"/"interp" with no terminal in
        # its own pc range. Recognize when the only pushes are these.
        return [_sub_table_b_heuristic $c]
    }
    lassign $terminal term_idx term_op term_arg

    # Walk back the data-producing operations preceding the terminal
    # invoke. The number of stack entries we need depends on the op.
    set slots [_walk_back_slots $insns $term_idx $term_op $term_arg]

    # Apply dispatch rows in priority order (variable namespace_eval and
    # callback shapes have specific terminal-op signatures, so they go
    # before the more general PatternA/A2/B rows).
    foreach row [_dispatch_table] {
        lassign $row name match_proc emit_proc
        set match_qual ::jcm::disasm::walker::$match_proc
        set emit_qual  ::jcm::disasm::walker::$emit_proc
        if {[$match_qual $slots $term_op $term_arg]} {
            return [$emit_qual $cmd_idx $slots $term_op $term_arg]
        }
    }

    # Nothing matched. Emit unrecognized for visibility.
    set body_preview [dict get $c body_preview]
    return [list [dict create \
        kind          unrecognized \
        cmd           $cmd_idx \
        reason        "no dispatch row matched" \
        terminal_op   $term_op \
        terminal_arg  $term_arg \
        body_preview  $body_preview]]
}

# ---------------------------------------------------------------------------
# Terminal-invoke detection
# ---------------------------------------------------------------------------
#
# A "terminal invoke" is the last opcode that dispatches a Tcl command.
# In Tcl 8.6 these are:
#   - invokeStk1 N    — N-arg invocation (1-byte operand)
#   - invokeStk4 N    — same, 4-byte operand
#   - invokeReplace N M — namespace eval (and other invoke-replace cases)
#   - invokeExpanded   — after {*} arg expansion
# Returns {idx op operand} or "" if no terminal invoke present.

proc ::jcm::disasm::walker::_find_terminal_invoke {insns} {
    set i [llength $insns]
    while {[incr i -1] >= 0} {
        set insn [lindex $insns $i]
        set op   [dict get $insn op]
        if {$op eq "invokeStk1" || $op eq "invokeStk4"
            || $op eq "invokeReplace" || $op eq "invokeExpanded"} {
            return [list $i $op [dict get $insn operand]]
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# Walk-back: recover the stack-producing operations before the terminal
# invoke, in source order (slot 0 = command-name slot, slot 1 = first
# arg, etc.).
#
# Each "slot" is a dict: {kind LITERAL|VAR|EXPR, value STRING-or-empty}.
#   kind=LITERAL — pushed via push1/push4; value = the literal text
#   kind=VAR     — pushed via push1+loadStk pair; value = var name (literal)
#   kind=EXPR    — anything else (strcat, dictGet result, etc.); value = ""
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_walk_back_slots {insns term_idx term_op term_arg} {
    # Determine slot count.
    set slot_count 0
    if {$term_op eq "invokeStk1" || $term_op eq "invokeStk4"} {
        set slot_count $term_arg
    } elseif {$term_op eq "invokeReplace"} {
        # Operand is "N M". N = stack pushed (incl. resolved name).
        # Source-form slots = N - 1 + 1 (the resolved name collapses M
        # leading source words into 1).
        lassign [split $term_arg " "] N M
        set slot_count $N
    } elseif {$term_op eq "invokeExpanded"} {
        # Slots = pushes between expandStart and expandStkTop. We can't
        # know the exact count without walking; the walker does a
        # bounded sweep up to expandStart.
        set slot_count -1
    }

    # Iterate forward from start of instruction list, accumulating
    # stack-producing ops. For Phase-1 simplicity we track only push
    # and loadStk; strcat collapses 2 stack items into 1.
    set stack [list]
    foreach insn [lrange $insns 0 [expr {$term_idx - 1}]] {
        set op [dict get $insn op]
        switch -- $op {
            push1 - push4 - pushString {
                set lit [_unquote_comment [dict get $insn comment]]
                lappend stack [dict create kind LITERAL value $lit]
            }
            loadStk - loadScalarStk {
                # Replace the previous stack entry (the var name) with a VAR slot
                if {[llength $stack] > 0} {
                    set last [lindex $stack end]
                    set varname [dict get $last value]
                    lset stack end [dict create kind VAR value $varname]
                }
            }
            strcat {
                # Operand = how many top stack items to concatenate.
                set n [dict get $insn operand]
                if {$n eq ""} { set n 2 }
                # Collapse top n entries into a single EXPR slot. For the
                # `loadStk; push " METHOD"; strcat 2` shape, capture the
                # method literal as metadata so callback emit can recover
                # it. Method recovery requires n=2 and the top-of-stack
                # at strcat time being a LITERAL.
                set keep [expr {[llength $stack] - $n}]
                if {$keep < 0} { set keep 0 }
                set method ""
                if {$n == 2 && [llength $stack] >= 2} {
                    set top [lindex $stack end]
                    if {[dict get $top kind] eq "LITERAL"} {
                        set method [string trim [dict get $top value]]
                    }
                }
                set stack [lrange $stack 0 [expr {$keep - 1}]]
                lappend stack [dict create kind EXPR value strcat \
                    method $method]
            }
            expandStart {
                # Phase-1 marker — slot accounting handled at emit time
            }
            expandStkTop {
                # Treat the most recent stack item (the loaded list) as
                # an EXPR for slot purposes. Operand = # of items pushed.
                if {[llength $stack] > 0} {
                    lset stack end [dict create kind EXPR value expanded_args]
                }
            }
            default {
                # Other ops (jumpFalse1, startCommand, etc.) — ignore;
                # they don't produce stack values for invokeStk slots.
            }
        }
    }

    # If slot_count is known, take the last slot_count entries.
    if {$slot_count > 0 && [llength $stack] >= $slot_count} {
        return [lrange $stack end-[expr {$slot_count - 1}] end]
    }
    return $stack
}

# Strip surrounding quotes from a literal comment (as emitted by disasm).
proc ::jcm::disasm::walker::_unquote_comment {comment} {
    if {[regexp {^"(.*)"$} $comment -> inner]} { return $inner }
    return $comment
}

# ---------------------------------------------------------------------------
# Dispatch table — one row per §2.3 pattern
# ---------------------------------------------------------------------------
#
# Each row: {name match_proc emit_proc}
# Order matters: more-specific patterns first so they win.

proc ::jcm::disasm::walker::_dispatch_table {} {
    return {
        {namespace_eval _match_namespace_eval _emit_namespace_eval}
        {expand_args    _match_expand_args    _emit_expand_args}
        {callback       _match_callback       _emit_callback}
        {apply_lambda   _match_apply_lambda   _emit_apply_lambda}
        {ensemble       _match_ensemble       _emit_ensemble}
        {eval_var       _match_eval_var       _emit_eval_var}
        {uplevel_var    _match_uplevel_var    _emit_uplevel_var}
        {interp_eval    _match_interp_eval    _emit_interp_eval}
        {var_method     _match_var_method     _emit_var_method}
        {pattern_b      _match_pattern_b      _emit_pattern_b}
        {pattern_a2     _match_pattern_a2     _emit_pattern_a2}
        {pattern_a      _match_pattern_a      _emit_pattern_a}
    }
}

# ---------------------------------------------------------------------------
# Predicates and emitters — one pair per §2.3 row
# ---------------------------------------------------------------------------

# --- namespace eval (R9) ---
# Receipt: invokeReplace N M with last push == "::tcl::namespace::eval"
proc ::jcm::disasm::walker::_match_namespace_eval {slots op arg} {
    if {$op ne "invokeReplace"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    expr {[dict get $last kind] eq "LITERAL"
          && [dict get $last value] eq "::tcl::namespace::eval"}
}
proc ::jcm::disasm::walker::_emit_namespace_eval {cmd_idx slots op arg} {
    # Slots: [..., NS, BODY, ::tcl::namespace::eval]
    set ns_slot   [lindex $slots end-2]
    set body_slot [lindex $slots end-1]
    set ns   [_slot_value $ns_slot]
    set body [_slot_value $body_slot]
    return [list [dict create kind namespace_eval cmd $cmd_idx \
        ns $ns body $body]]
}

# --- {*} arg expansion (R7) ---
# Receipt: terminal op == invokeExpanded
proc ::jcm::disasm::walker::_match_expand_args {slots op arg} {
    expr {$op eq "invokeExpanded"}
}
proc ::jcm::disasm::walker::_emit_expand_args {cmd_idx slots op arg} {
    set first [lindex $slots 0]
    set name  [_slot_value $first]
    return [list [dict create kind expand_args cmd $cmd_idx name $name]]
}

# --- callback (Tk-style "$obj method" string-concat shape) ---
# Receipt: any invokeStk where any preceding instruction is `strcat 2`
# and the strcat-collapsed slot has " METHOD" at the right offset.
# Phase-1 detection: last slot before invokeStk is an EXPR strcat slot.
# (Bind-callback row from §2.3 + R12 in current bridge.)
proc ::jcm::disasm::walker::_match_callback {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    expr {[dict get $last kind] eq "EXPR"
          && [dict get $last value] eq "strcat"}
}
proc ::jcm::disasm::walker::_emit_callback {cmd_idx slots op arg} {
    set last [lindex $slots end]
    set method ""
    if {[dict exists $last method]} { set method [dict get $last method] }
    if {$method eq ""} { set method "(strcat-collapsed)" }
    return [list [dict create kind callback cmd $cmd_idx method $method]]
}

# --- apply literal lambda (R8) ---
# Receipt: invokeStk where slot 0 == LITERAL "apply" AND slot 1 is a
# list-shaped literal (heuristic: contains "{" and "}").
proc ::jcm::disasm::walker::_match_apply_lambda {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    if {[dict get $s0 kind] ne "LITERAL"
        || [dict get $s0 value] ne "apply"} { return 0 }
    set s1 [lindex $slots 1]
    if {[dict get $s1 kind] ne "LITERAL"} { return 0 }
    set v [dict get $s1 value]
    expr {[string first "\{" $v] >= 0}
}
proc ::jcm::disasm::walker::_emit_apply_lambda {cmd_idx slots op arg} {
    set lambda [_slot_value [lindex $slots 1]]
    return [list [dict create kind apply_lambda cmd $cmd_idx \
        lambda $lambda]]
}

# --- ensemble (R10/R29 + R32 string addition) ---
# Receipt: slot 0 == LITERAL "::tcl::ENSEMBLE::SUBCMD" where ENSEMBLE
# is in ::jcm::disasm::walker::ENSEMBLES.
proc ::jcm::disasm::walker::_match_ensemble {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 1} { return 0 }
    set s0 [lindex $slots 0]
    if {[dict get $s0 kind] ne "LITERAL"} { return 0 }
    set v [dict get $s0 value]
    if {![regexp {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$} $v -> ens sub]} {
        return 0
    }
    expr {$ens in $::jcm::disasm::walker::ENSEMBLES}
}
proc ::jcm::disasm::walker::_emit_ensemble {cmd_idx slots op arg} {
    set v [_slot_value [lindex $slots 0]]
    regexp {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$} $v -> ens sub
    set N [_slot_count_for_op $op $arg]
    return [list [dict create kind ensemble cmd $cmd_idx \
        ensemble $ens subcommand $sub arg_count $N]]
}

# --- eval $var (§4.1) ---
# Receipt: slot 0 == LITERAL "eval" AND slot 1 == VAR
proc ::jcm::disasm::walker::_match_eval_var {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "LITERAL" && [dict get $s0 value] eq "eval"
          && [dict get $s1 kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_eval_var {cmd_idx slots op arg} {
    return [list [dict create kind eval_var cmd $cmd_idx]]
}

# --- uplevel $var (§4.5) ---
# Receipt: slot 0 == LITERAL "uplevel" AND last slot == VAR
proc ::jcm::disasm::walker::_match_uplevel_var {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    if {[dict get $s0 kind] ne "LITERAL"
        || [dict get $s0 value] ne "uplevel"} { return 0 }
    set last [lindex $slots end]
    expr {[dict get $last kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_uplevel_var {cmd_idx slots op arg} {
    return [list [dict create kind uplevel_var cmd $cmd_idx]]
}

# --- interp eval (§4.6) ---
# Receipt: slot 0 == LITERAL "interp", slot 1 == LITERAL "eval",
# slot 3 (or any later) is VAR.
proc ::jcm::disasm::walker::_match_interp_eval {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 3} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "LITERAL" && [dict get $s0 value] eq "interp"
          && [dict get $s1 kind] eq "LITERAL" && [dict get $s1 value] eq "eval"}
}
proc ::jcm::disasm::walker::_emit_interp_eval {cmd_idx slots op arg} {
    return [list [dict create kind interp_eval cmd $cmd_idx]]
}

# --- $obj $method (§4.4 var_method) ---
# Receipt: slot 0 == VAR AND slot 1 == VAR (both pushed via loadStk)
proc ::jcm::disasm::walker::_match_var_method {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "VAR" && [dict get $s1 kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_var_method {cmd_idx slots op arg} {
    return [list [dict create kind var_method cmd $cmd_idx]]
}

# --- Pattern B (§2.2): $obj method arg ---
# Receipt: slot 0 == VAR AND slot 1 == LITERAL (the method)
proc ::jcm::disasm::walker::_match_pattern_b {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "VAR" && [dict get $s1 kind] eq "LITERAL"}
}
proc ::jcm::disasm::walker::_emit_pattern_b {cmd_idx slots op arg} {
    set method [_slot_value [lindex $slots 1]]
    set N [_slot_count_for_op $op $arg]
    return [list [dict create kind pattern_b cmd $cmd_idx \
        method $method arg_count $N]]
}

# --- Pattern A2 (§2.3): ::ns method — single-segment FQN dispatch ---
# Receipt: slot 0 == LITERAL starting with "::" AND not containing
# inner "::" beyond the leading namespace AND slot 1 == LITERAL.
proc ::jcm::disasm::walker::_match_pattern_a2 {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    if {[dict get $s0 kind] ne "LITERAL"} { return 0 }
    if {[dict get $s1 kind] ne "LITERAL"} { return 0 }
    set v [dict get $s0 value]
    # Single-segment FQN: starts with "::" and has no further "::"
    expr {[string match "::*" $v]
          && [string first "::" [string range $v 2 end]] < 0}
}
proc ::jcm::disasm::walker::_emit_pattern_a2 {cmd_idx slots op arg} {
    set fqn    [_slot_value [lindex $slots 0]]
    set method [_slot_value [lindex $slots 1]]
    set N [_slot_count_for_op $op $arg]
    return [list [dict create kind pattern_a2 cmd $cmd_idx \
        fqn $fqn method $method arg_count $N]]
}

# --- Pattern A (§2.1): bare/multi-segment call ---
# Receipt: slot 0 == LITERAL (anything not matched by A2 above).
# This is the fallback row.
proc ::jcm::disasm::walker::_match_pattern_a {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 1} { return 0 }
    set s0 [lindex $slots 0]
    expr {[dict get $s0 kind] eq "LITERAL"}
}
proc ::jcm::disasm::walker::_emit_pattern_a {cmd_idx slots op arg} {
    set name [_slot_value [lindex $slots 0]]
    set N [_slot_count_for_op $op $arg]
    return [list [dict create kind pattern_a cmd $cmd_idx \
        name $name arg_count $N]]
}

# ---------------------------------------------------------------------------
# Sub-table B heuristic: bracket-inlined eval/uplevel/interp shells
# ---------------------------------------------------------------------------
#
# When the parent command is `eval [...]` (or `uplevel`/`interp eval`),
# the bracket's bytecode is inlined into the outer flow but listed
# under the inner command's pc range in the disassembly. The outer
# command appears with only the leading literal push and no terminal
# invoke. P1.1 emits an `eval_brackets` event for this shape; P1.2
# refines via cross-pc attribution.

proc ::jcm::disasm::walker::_sub_table_b_heuristic {c} {
    set insns [dict get $c instructions]
    if {[llength $insns] != 1} {
        return [list]
    }
    set i0 [lindex $insns 0]
    set op [dict get $i0 op]
    if {![string match push* $op]} {
        return [list]
    }
    set lit [_unquote_comment [dict get $i0 comment]]
    if {$lit eq "eval"} {
        return [list [dict create kind eval_brackets cmd [dict get $c idx]]]
    }
    return [list]
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_slot_value {slot} {
    if {$slot eq ""} { return "" }
    return [dict get $slot value]
}

proc ::jcm::disasm::walker::_slot_count_for_op {op arg} {
    if {$op eq "invokeStk1" || $op eq "invokeStk4"} {
        return $arg
    } elseif {$op eq "invokeReplace"} {
        lassign [split $arg " "] N M
        return $N
    } elseif {$op eq "invokeExpanded"} {
        return -1
    }
    return 0
}

# ---------------------------------------------------------------------------
# Pretty-printer (for fixtures + debugging)
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::format_events {events} {
    set out ""
    foreach ev $events {
        set kind [dict get $ev kind]
        set rest [list]
        foreach k [dict keys $ev] {
            if {$k eq "kind"} continue
            lappend rest "$k=[dict get $ev $k]"
        }
        append out [format "  %-16s  %s\n" $kind [join $rest " "]]
    }
    return $out
}

# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {$::argc < 1} {
        puts stderr "Usage: opcode_walker.tcl FILE.tcl"
        exit 2
    }
    set path [lindex $::argv 0]
    set fp [open $path r]
    fconfigure $fp -encoding utf-8
    set src [read $fp]
    close $fp
    set parsed [::jcm::disasm::parser::disassemble_and_parse $src]
    set events [::jcm::disasm::walker::walk $parsed]
    puts [::jcm::disasm::walker::format_events $events]
}
