#!/usr/bin/env tclsh
#
# opcode_walker.tcl — P1.2 Strategy A flat-pc-stream rewrite per
# dev-docs/verdicts/WALKER_CONTRACT_v2_2.md.
#
# Replaces the P1.1 per-command terminal-invoke walker with a single
# flat-pc-ordered simulation that:
#   - Tracks a value stack across the whole pc stream.
#   - Anchors each event to the cmd whose src range INNERMOST contains
#     the bottom-most consumed slot's src_offset (innermost-wins).
#   - Emits events in flat pc order — bracket-inlined inner commands fire
#     before their outer parents.
#
# Quality posture (per WALKER_CONTRACT_v2_2 §6.1.10): one row per opcode
# in STACK_EFFECTS; one row per pattern in DISPATCH. Adding either is
# one entry.
#
# Three-tier opcode coverage (P1.3 Stream 3):
#   Tier 1 — STACK_EFFECTS (this file): hand-classified rows used for
#            stack effects AND dispatch matching.
#   Tier 2 — TCL_INSTRUCTION_TABLE (validation/probes/INSTRUCTION_TABLE_8_6_14.tcl):
#            auto-extracted from tclInstructionTable[] in tcl8.6.14
#            generic/tclCompile.c. Used when STACK_EFFECTS misses —
#            applies canonical pop/push from the Tcl compiler so the
#            walker's abstract stack stays sound. NO dispatch event
#            emitted (semantic context unknown).
#   Tier 3 — opcode in neither table: unknown_opcode boundary recovery
#            (reset stack + suppress until next startCommand). With
#            both tables present, Tier 3 is empty for stock Tcl 8.6.
#
# Canonical opcode reference: /usr/include/tcl8.6/tcl-private/generic/
# tclCompile.h defines all 190 INST_* opcodes for stock Tcl 8.6.14
# (`#define INST_DONE 0` ... `LAST_INST_OPCODE 189`). The mnemonic
# names emitted by `tcl::unsupported::disassemble` come from
# `tclInstructionTable[].name` in the matching tclCompile.c (NOT
# shipped with `tcl8.6-dev`; available via `apt-get source tcl8.6` or
# upstream tarball at core.tcl-lang.org).
#
# Cross-codebase coverage gaps are surfaced empirically by
# `validation/probes/p1_2_corpus_recognition_probe.tcl --root PATH` with
# frequency-ranked per-opcode breakdown. Coverage tier breakdown is
# reported by `validation/probes/opcode_coverage_probe.tcl`.
#
# Event types (post-v2.2 — every event carries src_start/src_end of its
# anchored cmd):
#
#   {kind pattern_a       cmd N src_start S src_end E name STRING arg_count INT}
#   {kind pattern_a2      cmd N src_start S src_end E fqn STRING method STRING arg_count INT}
#   {kind pattern_b       cmd N src_start S src_end E method STRING arg_count INT}
#   {kind callback        cmd N src_start S src_end E method STRING}
#   {kind expand_args     cmd N src_start S src_end E name STRING}
#   {kind apply_lambda    cmd N src_start S src_end E lambda STRING}
#   {kind namespace_eval  cmd N src_start S src_end E ns STRING body STRING}
#   {kind ensemble        cmd N src_start S src_end E ensemble STRING subcommand STRING arg_count INT}
#   {kind eval_var        cmd N src_start S src_end E}
#   {kind var_method      cmd N src_start S src_end E}
#   {kind uplevel_var     cmd N src_start S src_end E}
#   {kind interp_eval     cmd N src_start S src_end E}
#   {kind eval_brackets   cmd N src_start S src_end E}
#   {kind computed_namespace cmd N src_start S src_end E}
#   {kind unrecognized    cmd N src_start S src_end E reason ... terminal_op ... terminal_arg ... body_preview ...}
#
# Note: the `ensemble` kind is also emitted by the ensemble_fqn_rewrite
# dispatch row when the bytecode compiler routes a stock ensemble through
# invokeReplace — those events carry an extra `bytecode_form invokeReplace`
# field for auditability but are otherwise identical in shape to
# invokeStk-routed ensemble events.
#
# Stack slot shape:
#   {kind LITERAL|VAR|EXPR|EXPAND_MARKER value STRING method STRING src_offset INT}
#
# Method field is set only by STRCAT when the top-of-stack at the time
# of strcat is a LITERAL — recovers " METHOD" suffix for callback shape.

source [file join [file dirname [info script]] disasm_parser.tcl]

namespace eval ::jcm::disasm::walker {
    namespace export walk format_events
    variable ENSEMBLES
    variable STACK_EFFECTS
    variable DISPATCH
}

# ---------------------------------------------------------------------------
# Ensemble pre-rename table — 10 entries (P1.1(f) ENSEMBLE_VERDICT).
# ---------------------------------------------------------------------------

set ::jcm::disasm::walker::ENSEMBLES {
    array binary chan clock dict encoding file info namespace string
}

# ---------------------------------------------------------------------------
# Stack-effect table — declarative source of truth for every opcode the
# walker tolerates. Format:
#
#   opcode -> {pop_count push_count effect_class operand_form}
#
# pop_count special values:
#   - integer N: fixed
#   - "N":       read from operand per operand_form
#   - "*":       dynamic (pop until EXPAND_MARKER, consume marker)
#
# operand_form: int1 | int4 | int | string | two-int | none
#
# effect_class drives the stack mutation in _apply_stack_effect:
#   PUSH_LITERAL, LOAD_VAR, STRCAT, EXPAND_START, EXPAND_STK_TOP,
#   INVOKE, INVOKE_REPLACE, INVOKE_EXPANDED, SPECIALIZED_OP, JUMP, NOP
#
# Bluice corpus inventory (R1-R3 probe, 47 distinct opcodes); rows below
# cover all of them. New opcodes from later Tcl versions land as one row.
# ---------------------------------------------------------------------------

# NOTE (P1.3 bundle 5 — `pushString` walker-orphan opcode):
# `pushString` is the lone walker row that has no peer in the Tcl 8.6.14
# `tclInstructionTable[]` (Tier 2). The
# `validation/probes/opcode_coverage_probe.tcl` `Walker rows orphaned vs
# Tcl table` count surfaces it explicitly. Empirical disasm output across
# `/home/giles/bluice` (12,256 events) and `/usr/share/tcltk` (14,187
# events) NEVER produces a `pushString` opcode — the row is defensive
# cover for older Tcl variants / third-party builds that may emit a
# string-form push opcode. Removing it would be safe today; leaving it in
# costs one row and gives one less reason to revisit on a Tcl-9 upgrade.
# Comment lives OUTSIDE the dict literal because Tcl's dict syntax
# doesn't tolerate `#`-comments inside the braced body.
set ::jcm::disasm::walker::STACK_EFFECTS {
    push1            {0 1 PUSH_LITERAL    int1}
    push4            {0 1 PUSH_LITERAL    int4}
    pushString       {0 1 PUSH_LITERAL    string}
    loadStk          {1 1 LOAD_VAR        none}
    loadScalarStk    {1 1 LOAD_VAR        none}
    loadArrayStk     {2 1 SPECIALIZED_OP  none}
    strcat           {N 1 STRCAT          int}
    expandStart      {0 1 EXPAND_START    none}
    expandStkTop     {1 1 EXPAND_STK_TOP  int}
    invokeStk1       {N 1 INVOKE          int}
    invokeStk4       {N 1 INVOKE          int}
    invokeReplace    {N 1 INVOKE_REPLACE  two-int}
    invokeExpanded   {* 1 INVOKE_EXPANDED none}
    listIndexImm     {1 1 SPECIALIZED_OP  int}
    listIndex        {2 1 SPECIALIZED_OP  none}
    listLength       {1 1 SPECIALIZED_OP  none}
    listRangeImm     {1 1 SPECIALIZED_OP  two-int}
    listConcat       {N 1 SPECIALIZED_OP  int}
    list             {N 1 SPECIALIZED_OP  int}
    storeStk         {2 1 SPECIALIZED_OP  none}
    storeArrayStk    {3 1 SPECIALIZED_OP  none}
    unsetStk         {1 0 SPECIALIZED_OP  none}
    pop              {1 0 SPECIALIZED_OP  none}
    dup              {1 2 SPECIALIZED_OP  none}
    reverse          {N N SPECIALIZED_OP  int}
    nop              {0 0 NOP             none}
    done             {0 0 NOP             none}
    startCommand     {0 0 NOP             two-int}
    jump1            {0 0 JUMP            int}
    jump4            {0 0 JUMP            int}
    jumpFalse1       {1 0 JUMP            int}
    jumpFalse4       {1 0 JUMP            int}
    jumpTrue1        {1 0 JUMP            int}
    jumpTrue4        {1 0 JUMP            int}
    jumpTable        {1 0 JUMP            int}
    strlen           {1 1 SPECIALIZED_OP  none}
    strcmp           {2 1 SPECIALIZED_OP  none}
    strmatch         {2 1 SPECIALIZED_OP  int}
    strrangeImm      {1 1 SPECIALIZED_OP  two-int}
    streq            {2 1 SPECIALIZED_OP  none}
    strcaseLower     {1 1 SPECIALIZED_OP  none}
    dictGet          {N 1 SPECIALIZED_OP  int}
    incrStk          {1 1 SPECIALIZED_OP  none}
    incrStkImm       {1 1 SPECIALIZED_OP  int}
    eq               {2 1 SPECIALIZED_OP  none}
    neq              {2 1 SPECIALIZED_OP  none}
    lt               {2 1 SPECIALIZED_OP  none}
    gt               {2 1 SPECIALIZED_OP  none}
    le               {2 1 SPECIALIZED_OP  none}
    ge               {2 1 SPECIALIZED_OP  none}
    existStk         {1 1 SPECIALIZED_OP  none}
    existArrayStk    {2 1 SPECIALIZED_OP  none}
    exprStk          {1 1 SPECIALIZED_OP  none}
    lappendListStk   {2 1 SPECIALIZED_OP  none}
    beginCatch4      {0 0 NOP             int}
    endCatch         {0 0 NOP             none}
    pushResult       {0 1 PUSH_LITERAL    none}
    pushReturnCode   {0 1 PUSH_LITERAL    none}
    returnImm        {2 0 SPECIALIZED_OP  two-int}
    resolveCmd       {1 1 SPECIALIZED_OP  none}
    clockRead        {0 1 PUSH_LITERAL    int}
    evalStk          {1 1 EVAL_STK        none}
}

# ---------------------------------------------------------------------------
# Tier 2 — auto-loaded TCL_INSTRUCTION_TABLE (P1.3 Stream 3)
# ---------------------------------------------------------------------------
#
# Source-of-truth fallback for opcodes that exist in stock Tcl 8.6 but
# aren't hand-classified above. Loaded lazily by _ensure_tier2_loaded
# the first time _lookup_effect misses on STACK_EFFECTS. The Tier 2 row
# format is the auto-extractor's `{numBytes stackEffect numOperands
# operand_types_csv}`; _lookup_effect maps it into the walker's normal
# `{pop_count push_count effect_class operand_form}` shape using the
# canonical signed stackEffect from tclInstructionTable[].
#
# Tier 2 hits emit NO dispatch event (the walker has authoritative
# pop/push but no semantic shape — the opcode is bytecode-internal and
# anchored to whatever cmd the next invokeStk fires for). They keep the
# abstract stack sound across previously-unrecognized opcodes; the
# §3.1.4 unknown_opcode boundary-recovery path now fires only for
# Tier 3 (opcode in neither table).

namespace eval ::jcm::disasm::tcltable {
    # Don't clobber if a caller already sourced INSTRUCTION_TABLE_8_6_14.tcl
    # before us (e.g., opcode_coverage_probe.tcl loads the table first to
    # diff Tier 1 vs Tier 2). The lazy-load path in _ensure_tier2_loaded
    # also populates this variable on first miss.
    if {![info exists TCL_INSTRUCTION_TABLE]} {
        variable TCL_INSTRUCTION_TABLE [dict create]
    }
}
set ::jcm::disasm::walker::_TIER2_LOADED 0
# P1.3 bundle (8) — Tier 2 lazy-load failure mode.
#
# Status enum (`_TIER2_STATUS`):
#   unloaded  — initial state; first call attempts to source the table.
#   loaded    — source $candidate succeeded; lookups consult the dict.
#   missing   — table file absent on disk; permanent miss (single warn).
#   failed    — source $candidate raised; permanent miss (single warn).
#
# Why a status enum: the prior code set `_TIER2_LOADED 1` BEFORE the
# `source` so a corrupt / partial table left the loader stuck — Tier 3
# boundary recovery ran for every opcode forever. The new state machine
# keeps `_TIER2_LOADED 0` until the source actually succeeds, while the
# `missing` / `failed` terminal states prevent infinite retry warnings.
set ::jcm::disasm::walker::_TIER2_STATUS unloaded

# Capture this file's directory AT SOURCE TIME — `[info script]` inside a
# proc returns the *currently-being-sourced* file (often empty when the
# proc is called from top-level tclsh), so deferring path resolution to
# proc-call time silently broke Tier 2 lookup. Pinning the directory at
# source time gives us a stable anchor regardless of how/when
# _ensure_tier2_loaded is invoked.
set ::jcm::disasm::walker::_WALKER_DIR [file dirname [file normalize [info script]]]

proc ::jcm::disasm::walker::_ensure_tier2_loaded {} {
    variable _TIER2_LOADED
    variable _TIER2_STATUS
    variable _WALKER_DIR
    if {$_TIER2_LOADED} { return }
    # Terminal-state guard: missing/failed states already emitted their
    # warning. Don't retry on every miss (the bridge would print
    # thousands of warnings on a long file).
    if {$_TIER2_STATUS in {missing failed}} { return }
    # Walk up from src/jcodemunch_mcp/parser/ to repo root, then descend
    # into validation/probes/. _WALKER_DIR was captured at source time.
    set repo_root [file normalize [file join $_WALKER_DIR .. .. ..]]
    set candidate [file join $repo_root validation probes \
        INSTRUCTION_TABLE_8_6_14.tcl]
    if {![file exists $candidate]} {
        set _TIER2_STATUS missing
        puts stderr "WARN: Tier 2 instruction table not found at $candidate; falling through to Tier 3 boundary recovery for unrecognized opcodes."
        return
    }
    if {[catch {source $candidate} err]} {
        # Tier 2 unavailable; fall through to Tier 3 boundary recovery.
        # Surface for diagnostics once and don't retry.
        set _TIER2_STATUS failed
        puts stderr "WARN: Tier 2 load failed for $candidate: $err"
        return
    }
    # Source succeeded — only NOW mark as loaded so any future call
    # short-circuits the file-system / source dance.
    set _TIER2_LOADED 1
    set _TIER2_STATUS loaded
}

# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------

# Walk a parser dict (from ::jcm::disasm::parser::disassemble_and_parse)
# and emit a list of typed events in flat pc order.
proc ::jcm::disasm::walker::walk {parsed} {
    if {[dict exists $parsed error]} {
        return [list [dict create kind disasm_error \
            reason [dict get $parsed error]]]
    }
    return [_simulate_stack $parsed]
}

# ---------------------------------------------------------------------------
# Strategy A simulation — flat pc walk over union of all command insns
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_simulate_stack {parsed} {
    set commands [dict get $parsed commands]
    if {[llength $commands] == 0} { return [list] }

    # Build (pc-sorted) flat instruction stream and helper lookups.
    set flat_insns [_build_flat_insns $commands]
    set src_ranges [_build_src_ranges $commands]
    set pc_to_cmd  [_build_pc_to_cmd $commands]

    # cmd_idx → body_preview / src_start / src_end accessors via index_by
    array set cmd_meta {}
    foreach c $commands {
        set i [dict get $c idx]
        set cmd_meta($i,src_start)    [dict get $c src_start]
        set cmd_meta($i,src_end)      [dict get $c src_end]
        set cmd_meta($i,body_preview) [dict get $c body_preview]
    }

    set stack [list]
    set events [list]
    # Dead-code / unknown-opcode suppression flag.
    #
    # Triggers (set in_dead_code = 1):
    #   1. Unconditional `jump1` / `jump4` — fall-through is unreachable;
    #      subsequent instructions belong to catch handlers reached only
    #      via exception-range entries, not via linear pc flow.
    #   2. `unknown_opcode` — unknown stack effect, so any further opcode
    #      processing could cascade-corrupt the abstract stack. The walker
    #      also resets `stack` to empty when this trigger fires.
    #
    # Recovery (clear in_dead_code = 0): the next instruction whose pc
    # equals a startCommand boundary (any pc in cmd_pc_starts). At that
    # point a fresh command starts, the abstract stack model re-enters
    # cleanly, and normal opcode processing resumes.
    #
    # Empirical justification: without this guard, the flat-pc walk through
    # tcltls catch-handler pops corrupts the stack across loop bodies (2
    # false stack-underflow `unrecognized` events in /usr/share/tcltk
    # validation runs). Per WALKER_CONTRACT_v2_2 §3.1.4 ("drop slots until
    # next startCommand boundary"), the contract permits this aggressive
    # drop-until-boundary recovery as long as we re-enter the stack model
    # at the next cmd start.
    set in_dead_code 0
    array set cmd_pc_starts {}
    foreach c $commands {
        set cmd_pc_starts([dict get $c pc_start]) 1
    }

    foreach insn $flat_insns {
        set op      [dict get $insn op]
        set operand [dict get $insn operand]
        set comment [dict get $insn comment]
        set pc      [dict get $insn pc]

        # If this pc starts a new cmd, exit dead-code zone.
        if {[info exists cmd_pc_starts($pc)]} { set in_dead_code 0 }

        # Map pc → containing innermost src_offset (anchor of insn's src loc).
        set src_offset [_pc_to_src_offset $pc $pc_to_cmd cmd_meta]

        # Look up stack effect for this opcode.
        set effect [_lookup_effect $op]
        if {$effect eq ""} {
            if {$in_dead_code} { continue }
            # Unknown opcode — emit unrecognized + reset and continue.
            set anchor [_lookup_src_range $src_offset $src_ranges]
            lassign [_anchor_meta $anchor cmd_meta] cmd_idx anchor_start anchor_end
            set body_preview ""
            if {$cmd_idx >= 0 && [info exists cmd_meta($cmd_idx,body_preview)]} {
                set body_preview $cmd_meta($cmd_idx,body_preview)
            }
            lappend events [dict create \
                kind          unrecognized \
                cmd           $cmd_idx \
                src_start     $anchor_start \
                src_end       $anchor_end \
                reason        "unknown_opcode" \
                terminal_op   $op \
                terminal_arg  $operand \
                body_preview  $body_preview]
            # Boundary recovery: we have no canonical stack-effect data for
            # this opcode, so any further mutation could cascade-corrupt the
            # walker's abstract stack. Reset stack and re-use the dead-code
            # suppression flag (semantics: "skip stack mutations until next
            # startCommand boundary"). Triggered by jump1/jump4 (intentionally
            # unreachable) AND by unknown_opcode (unknown stack effect) — both
            # cases share the same recovery path.
            set stack [list]
            set in_dead_code 1
            continue
        }
        lassign $effect pop_spec push_spec class operand_form

        # In dead-code zone: skip stack mutations entirely. (We exited the
        # zone above if pc is a new cmd start; everything between an
        # unconditional jump and the next cmd is unreachable in linear walk.)
        if {$in_dead_code} {
            # Track jump1/jump4 that terminates dead-code zone is unnecessary —
            # the next startCommand resets us. NOP class still no-ops.
            continue
        }

        # Apply effect — sometimes emits an event (INVOKE family), always
        # mutates the stack.
        set apply_result [_apply_stack_effect stack $op $operand $comment \
            $class $pop_spec $push_spec $operand_form $src_offset \
            $src_ranges cmd_meta]

        # apply_result is "" or a list of events to append (in order).
        if {$apply_result ne ""} {
            foreach ev $apply_result { lappend events $ev }
        }

        # Set dead-code flag after unconditional jumps (jump1/jump4 only;
        # conditional jumps fall through to reachable code).
        if {$op eq "jump1" || $op eq "jump4"} { set in_dead_code 1 }
    }

    return $events
}

# ---------------------------------------------------------------------------
# Build helpers: flat insns / src ranges / pc → cmd lookup
# ---------------------------------------------------------------------------

# Flatten union of all cmd.instructions; sort by pc ascending; deduplicate
# (an instruction can appear in multiple cmds' instruction lists when the
# parser's per-command bodies overlap, but in practice each pc appears
# once because the disassembler emits each pc under exactly one
# `Command N:` header).
proc ::jcm::disasm::walker::_build_flat_insns {commands} {
    set all [list]
    foreach c $commands {
        foreach insn [dict get $c instructions] {
            lappend all $insn
        }
    }
    # Sort by pc (stable; identical pcs unlikely).
    return [_sort_by_pc $all]
}

proc ::jcm::disasm::walker::_sort_by_pc {insns} {
    # Build aux list of {pc insn} pairs, sort numerically, project back.
    set aux [list]
    foreach insn $insns {
        lappend aux [list [dict get $insn pc] $insn]
    }
    set sorted [lsort -integer -index 0 $aux]
    set out [list]
    foreach pair $sorted {
        lappend out [lindex $pair 1]
    }
    return $out
}

# Build src-range tuples: list of {cmd_idx src_start src_end}, sorted by
# src_start ascending. Used by _lookup_src_range innermost-wins logic.
proc ::jcm::disasm::walker::_build_src_ranges {commands} {
    set out [list]
    foreach c $commands {
        lappend out [list \
            [dict get $c idx] \
            [dict get $c src_start] \
            [dict get $c src_end]]
    }
    return [lsort -integer -index 1 $out]
}

# Build pc → cmd_idx map: list of {pc_start pc_end cmd_idx}, sorted by
# pc_start ascending. _pc_to_src_offset uses innermost-wins on this.
proc ::jcm::disasm::walker::_build_pc_to_cmd {commands} {
    set out [list]
    foreach c $commands {
        lappend out [list \
            [dict get $c pc_start] \
            [dict get $c pc_end] \
            [dict get $c idx] \
            [dict get $c src_start]]
    }
    return [lsort -integer -index 0 $out]
}

# ---------------------------------------------------------------------------
# pc → src offset (uses innermost-wins on pc range)
# ---------------------------------------------------------------------------
#
# The src_offset returned is the src_start of the innermost cmd whose
# pc range contains $pc. For PUSH ops this pins the slot's source
# location; the slot's anchor cmd is then resolved via _lookup_src_range
# at INVOKE time using slot[0].src_offset.

proc ::jcm::disasm::walker::_pc_to_src_offset {pc pc_to_cmd cmd_meta_var} {
    upvar 1 $cmd_meta_var cmd_meta
    set best_idx -1
    set best_size 0
    set best_src_start -1
    foreach entry $pc_to_cmd {
        lassign $entry s e idx src_start
        if {$pc < $s} { break }
        if {$pc <= $e} {
            set size [expr {$e - $s + 1}]
            if {$best_idx < 0 || $size < $best_size
                || ($size == $best_size && $idx > $best_idx)} {
                set best_idx       $idx
                set best_size      $size
                set best_src_start $src_start
            }
        }
    }
    return $best_src_start
}

# ---------------------------------------------------------------------------
# src offset → cmd_idx (innermost-wins; smallest containing range,
# tie-break on largest cmd_idx)
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_lookup_src_range {src_offset src_ranges} {
    if {$src_offset < 0} { return "" }
    set best_idx -1
    set best_start -1
    set best_end -1
    set best_range_size 0
    foreach entry $src_ranges {
        lassign $entry idx start end
        if {$src_offset < $start} { break }
        if {$src_offset <= $end} {
            set size [expr {$end - $start + 1}]
            if {$best_idx < 0 || $size < $best_range_size
                || ($size == $best_range_size && $idx > $best_idx)} {
                set best_idx        $idx
                set best_start      $start
                set best_end        $end
                set best_range_size $size
            }
        }
    }
    if {$best_idx < 0} { return "" }
    return [list $best_idx $best_start $best_end]
}

# Resolve cmd_idx + src_start/src_end from an anchor; "" anchor → -1/-1/-1.
proc ::jcm::disasm::walker::_anchor_meta {anchor cmd_meta_var} {
    upvar 1 $cmd_meta_var cmd_meta
    if {$anchor eq ""} { return [list -1 -1 -1] }
    lassign $anchor idx start end
    return [list $idx $start $end]
}

# ---------------------------------------------------------------------------
# Stack-effect application
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_apply_stack_effect {stack_var op operand comment \
        class pop_spec push_spec operand_form src_offset \
        src_ranges cmd_meta_var} {
    upvar 1 $stack_var stack
    upvar 1 $cmd_meta_var cmd_meta
    set events [list]

    switch -- $class {
        PUSH_LITERAL {
            set lit [_unquote_comment $comment]
            lappend stack [dict create kind LITERAL value $lit \
                method "" src_offset $src_offset]
        }
        LOAD_VAR {
            # The previous push was the var name; replace top with VAR
            # slot, preserving its src_offset.
            if {[llength $stack] > 0} {
                set last [lindex $stack end]
                set varname [dict get $last value]
                set s_off [dict get $last src_offset]
                lset stack end [dict create kind VAR value $varname \
                    method "" src_offset $s_off]
            }
            # else: silent stack underflow — defensive.
        }
        STRCAT {
            set n [_decode_operand_int $operand]
            if {$n eq ""} { set n 2 }
            set len [llength $stack]
            if {$len < $n} {
                # Underflow: emit unrecognized and reset.
                set ev [_emit_underflow $op $operand $src_offset \
                    $src_ranges cmd_meta]
                set stack [list]
                lappend events $ev
                return $events
            }
            set top_n [lrange $stack end-[expr {$n - 1}] end]
            set keep [expr {$len - $n}]
            set stack [lrange $stack 0 [expr {$keep - 1}]]
            # Capture method literal if n=2 and top-of-stack at strcat
            # time was a LITERAL (callback shape).
            set method ""
            if {$n == 2} {
                set top [lindex $top_n end]
                if {[dict get $top kind] eq "LITERAL"} {
                    set method [string trim [dict get $top value]]
                }
            }
            # Anchor EXPR to bottom-most consumed slot's src_offset (so
            # cmd_anchor lookup finds the correct innermost cmd).
            set bottom_src [dict get [lindex $top_n 0] src_offset]
            lappend stack [dict create kind EXPR value strcat \
                method $method src_offset $bottom_src]
        }
        EXPAND_START {
            lappend stack [dict create kind EXPAND_MARKER value "" \
                method "" src_offset $src_offset]
        }
        EXPAND_STK_TOP {
            # Replace top (the loaded list) with EXPR(expanded_args);
            # marker stays on the stack as sentinel for invokeExpanded.
            set len [llength $stack]
            if {$len < 1} {
                set ev [_emit_underflow $op $operand $src_offset \
                    $src_ranges cmd_meta]
                set stack [list]
                lappend events $ev
                return $events
            }
            # Anchor EXPR to most-recent EXPAND_MARKER's src_offset (so
            # the resulting expand_args event anchors to the calling cmd).
            set marker_off [_find_expand_marker_offset $stack]
            if {$marker_off < 0} {
                set marker_off [dict get [lindex $stack end] src_offset]
            }
            lset stack end [dict create kind EXPR value expanded_args \
                method "" src_offset $marker_off]
        }
        INVOKE {
            # invokeStk1/invokeStk4 — pop N, push 1, emit dispatch event.
            set n [_decode_operand_int $operand]
            if {$n eq ""} { set n 0 }
            set ev_or_under [_invoke_and_emit stack $op $operand $n \
                $src_offset $src_ranges cmd_meta]
            foreach ev $ev_or_under { lappend events $ev }
        }
        INVOKE_REPLACE {
            # Operand is "N M". N = stack pop count.
            lassign [split $operand " "] N _M
            if {$N eq ""} { set N 0 }
            set ev_or_under [_invoke_and_emit stack $op $operand $N \
                $src_offset $src_ranges cmd_meta]
            foreach ev $ev_or_under { lappend events $ev }
        }
        INVOKE_EXPANDED {
            # Pop until EXPAND_MARKER (consume marker too); push EXPR.
            set ev_or_under [_invoke_expanded_and_emit stack $op $operand \
                $src_offset $src_ranges cmd_meta]
            foreach ev $ev_or_under { lappend events $ev }
        }
        SPECIALIZED_OP {
            # Generic specialized ops: pop pop_spec, push push_spec EXPR.
            set n_pop [_resolve_count $pop_spec $operand $operand_form]
            set n_push [_resolve_count $push_spec $operand $operand_form]
            set len [llength $stack]
            if {$n_pop > $len} {
                # Drop any partial slots silently — specialized ops are
                # bytecode-internal; underflow here is benign and the
                # outer command's startCommand reset will restore us.
                set stack [list]
            } elseif {$n_pop > 0} {
                set keep [expr {$len - $n_pop}]
                set stack [lrange $stack 0 [expr {$keep - 1}]]
            }
            for {set i 0} {$i < $n_push} {incr i} {
                lappend stack [dict create kind EXPR value specialized \
                    method "" src_offset $src_offset]
            }
        }
        JUMP {
            set n_pop [_resolve_count $pop_spec $operand $operand_form]
            set len [llength $stack]
            if {$n_pop > 0 && $n_pop <= $len} {
                set keep [expr {$len - $n_pop}]
                set stack [lrange $stack 0 [expr {$keep - 1}]]
            }
        }
        NOP {
            # No stack effect. (startCommand resets nothing — Strategy A
            # accumulates across cmd boundaries by design.)
        }
        EVAL_STK {
            # evalStk pops the script value at TOS and evaluates it via
            # Tcl_EvalObj at runtime (see tclCompile.c INST_EVAL_STK).
            # Pop=1, push=1 (the result of the eval'd script). Emit a
            # distinct eval_stk event — parallel to eval_var/eval_brackets
            # — anchored to the cmd whose src range innermost-contains
            # the popped slot's src_offset.
            set len [llength $stack]
            if {$len < 1} {
                set ev [_emit_underflow $op $operand $src_offset \
                    $src_ranges cmd_meta]
                set stack [list]
                lappend events $ev
                return $events
            }
            set top [lindex $stack end]
            set bottom_src [dict get $top src_offset]
            set stack [lrange $stack 0 [expr {$len - 2}]]
            # Anchor by popped slot's src_offset; innermost-wins.
            set anchor [_lookup_src_range $bottom_src $src_ranges]
            if {$anchor eq ""} {
                set anchor [_lookup_src_range $src_offset $src_ranges]
            }
            if {$anchor eq ""} {
                set ev [dict create kind unrecognized cmd -1 \
                    src_start -1 src_end -1 reason "orphan_pc" \
                    terminal_op $op terminal_arg $operand body_preview ""]
                lappend stack [dict create kind EXPR value invoke_result \
                    method "" src_offset $src_offset]
                lappend events $ev
                return $events
            }
            lassign $anchor cmd_idx anchor_start anchor_end
            lappend events [dict create kind eval_stk cmd $cmd_idx \
                src_start $anchor_start src_end $anchor_end]
            lappend stack [dict create kind EXPR value invoke_result \
                method "" src_offset $src_offset]
        }
        TIER2_AUTO {
            # Auto-classified opcode from tclInstructionTable[]. We have
            # canonical pop/push counts but no semantic dispatch shape.
            # Apply the stack delta and push synthetic EXPR slots; do
            # NOT emit any dispatch event.
            set n_pop [_resolve_count $pop_spec $operand $operand_form]
            set n_push [_resolve_count $push_spec $operand $operand_form]
            set len [llength $stack]
            if {$n_pop > $len} {
                # Underflow on Tier 2 — drop slots silently. Bytecode-
                # internal opcodes can underflow the abstract stack at
                # cmd boundaries; the next startCommand is the recovery
                # boundary. Same posture as SPECIALIZED_OP underflow.
                set stack [list]
            } elseif {$n_pop > 0} {
                set keep [expr {$len - $n_pop}]
                set stack [lrange $stack 0 [expr {$keep - 1}]]
            }
            for {set i 0} {$i < $n_push} {incr i} {
                lappend stack [dict create kind EXPR value tier2_op \
                    method "" src_offset $src_offset]
            }
        }
    }
    return $events
}

# ---------------------------------------------------------------------------
# Invoke + dispatch
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_invoke_and_emit {stack_var op operand n \
        src_offset src_ranges cmd_meta_var} {
    upvar 1 $stack_var stack
    upvar 1 $cmd_meta_var cmd_meta

    set len [llength $stack]
    if {$n > $len} {
        # Stack underflow: emit unrecognized and drop slots.
        set ev [_emit_underflow $op $operand $src_offset \
            $src_ranges cmd_meta]
        set stack [list]
        # Push EXPR result anyway so the outer continuation sees a value.
        lappend stack [dict create kind EXPR value invoke_result \
            method "" src_offset $src_offset]
        return [list $ev]
    }

    # Pop N slots in source order (slot[0] = bottom-most consumed).
    set slots [lrange $stack end-[expr {$n - 1}] end]
    set keep [expr {$len - $n}]
    set stack [lrange $stack 0 [expr {$keep - 1}]]

    # Anchor by slot[0].src_offset; innermost-wins.
    set anchor [_lookup_src_range \
        [dict get [lindex $slots 0] src_offset] $src_ranges]
    if {$anchor eq ""} {
        # Orphan pc — slot[0] has no containing cmd src range.
        set ev [dict create \
            kind          unrecognized \
            cmd           -1 \
            src_start     -1 \
            src_end       -1 \
            reason        "orphan_pc" \
            terminal_op   $op \
            terminal_arg  $operand \
            body_preview  ""]
        lappend stack [dict create kind EXPR value invoke_result \
            method "" src_offset $src_offset]
        return [list $ev]
    }
    lassign $anchor cmd_idx anchor_start anchor_end

    set body_preview ""
    if {[info exists cmd_meta($cmd_idx,body_preview)]} {
        set body_preview $cmd_meta($cmd_idx,body_preview)
    }

    set ev [_dispatch_match $cmd_idx $anchor_start $anchor_end \
        $body_preview $slots $op $operand]

    # Push EXPR result regardless of dispatch outcome (an invoke always
    # produces 1 result in Tcl 8.6 bytecode).
    lappend stack [dict create kind EXPR value invoke_result \
        method "" src_offset $src_offset]

    return [list $ev]
}

proc ::jcm::disasm::walker::_invoke_expanded_and_emit {stack_var op operand \
        src_offset src_ranges cmd_meta_var} {
    upvar 1 $stack_var stack
    upvar 1 $cmd_meta_var cmd_meta

    # Pop until EXPAND_MARKER; consume the marker too. Slots come back
    # in pop order (top-most first); reverse to source order.
    set slots [list]
    set found_marker 0
    set len [llength $stack]
    for {set i [expr {$len - 1}]} {$i >= 0} {incr i -1} {
        set s [lindex $stack $i]
        if {[dict get $s kind] eq "EXPAND_MARKER"} {
            # Drop marker and everything above; keep the rest.
            set stack [lrange $stack 0 [expr {$i - 1}]]
            set found_marker 1
            break
        }
        lappend slots $s
    }
    if {!$found_marker} {
        set ev [_emit_underflow $op $operand $src_offset \
            $src_ranges cmd_meta]
        set stack [list]
        lappend stack [dict create kind EXPR value invoke_result \
            method "" src_offset $src_offset]
        return [list $ev]
    }
    # Reverse pop-order to source-order: slot[0] = bottom-most consumed.
    set source_order [list]
    for {set i [expr {[llength $slots] - 1}]} {$i >= 0} {incr i -1} {
        lappend source_order [lindex $slots $i]
    }
    set slots $source_order

    if {[llength $slots] == 0} {
        set anchor [_lookup_src_range $src_offset $src_ranges]
    } else {
        set anchor [_lookup_src_range \
            [dict get [lindex $slots 0] src_offset] $src_ranges]
    }
    if {$anchor eq ""} {
        set ev [dict create \
            kind unrecognized cmd -1 src_start -1 src_end -1 \
            reason "orphan_pc" terminal_op $op terminal_arg $operand \
            body_preview ""]
        lappend stack [dict create kind EXPR value invoke_result \
            method "" src_offset $src_offset]
        return [list $ev]
    }
    lassign $anchor cmd_idx anchor_start anchor_end
    set body_preview ""
    if {[info exists cmd_meta($cmd_idx,body_preview)]} {
        set body_preview $cmd_meta($cmd_idx,body_preview)
    }

    set ev [_dispatch_match $cmd_idx $anchor_start $anchor_end \
        $body_preview $slots $op $operand]
    lappend stack [dict create kind EXPR value invoke_result \
        method "" src_offset $src_offset]
    return [list $ev]
}

proc ::jcm::disasm::walker::_emit_underflow {op operand src_offset \
        src_ranges cmd_meta_var} {
    upvar 1 $cmd_meta_var cmd_meta
    set anchor [_lookup_src_range $src_offset $src_ranges]
    lassign [_anchor_meta $anchor cmd_meta] cmd_idx anchor_start anchor_end
    set body_preview ""
    if {$cmd_idx >= 0 && [info exists cmd_meta($cmd_idx,body_preview)]} {
        set body_preview $cmd_meta($cmd_idx,body_preview)
    }
    return [dict create \
        kind          unrecognized \
        cmd           $cmd_idx \
        src_start     $anchor_start \
        src_end       $anchor_end \
        reason        "stack_underflow" \
        terminal_op   $op \
        terminal_arg  $operand \
        body_preview  $body_preview]
}

proc ::jcm::disasm::walker::_find_expand_marker_offset {stack} {
    for {set i [expr {[llength $stack] - 1}]} {$i >= 0} {incr i -1} {
        set s [lindex $stack $i]
        if {[dict get $s kind] eq "EXPAND_MARKER"} {
            return [dict get $s src_offset]
        }
    }
    return -1
}

# ---------------------------------------------------------------------------
# Dispatch table — 13 rows (12 P1.1 + explicit eval_brackets)
# ---------------------------------------------------------------------------

proc ::jcm::disasm::walker::_dispatch_match {cmd_idx src_start src_end \
        body_preview slots op operand} {

    foreach row [_dispatch_table] {
        lassign $row name match_proc emit_proc
        set match_qual ::jcm::disasm::walker::$match_proc
        set emit_qual  ::jcm::disasm::walker::$emit_proc
        if {[$match_qual $slots $op $operand]} {
            return [$emit_qual $cmd_idx $src_start $src_end $slots \
                $op $operand]
        }
    }

    # Fallthrough: no row matched — unrecognized.
    return [dict create \
        kind          unrecognized \
        cmd           $cmd_idx \
        src_start     $src_start \
        src_end       $src_end \
        reason        "no dispatch row matched" \
        terminal_op   $op \
        terminal_arg  $operand \
        body_preview  $body_preview]
}

proc ::jcm::disasm::walker::_dispatch_table {} {
    # Order matters: first-match wins. The two invokeReplace-routed rows
    # must fire BEFORE namespace_eval / ensemble fallthrough so the more
    # specific shapes anchor correctly:
    #
    #   * computed_namespace (P1.3 §13.6 Shape A) — `namespace eval $ns BODY`
    #     where the namespace word is a VAR. Last slot is the literal
    #     "::tcl::namespace::eval" but with a VAR somewhere in the
    #     interior args, so namespace_eval would over-claim it as the
    #     literal-namespace shape and lose the dynamic-ns signal. Catching
    #     it earlier emits a `kind computed_namespace` event consumed by
    #     unresolved_detector (same handler as eval_var / interp_eval).
    #
    #   * ensemble_fqn_rewrite (P1.3 §13.6 Shape B) — invokeReplace where
    #     the last slot is a stock ensemble subcommand FQN
    #     ("::tcl::clock::format", "::tcl::dict::for", etc.). The
    #     bytecode compiler routes some ensembles through invokeReplace
    #     when arity matches a known subcommand; the existing `ensemble`
    #     row only matches invokeStk1/4, so without this row those calls
    #     fall through to "no dispatch row matched". Emit `kind ensemble`
    #     so the bridge driver's existing ensemble handler runs unchanged
    #     (downstream parity with invokeStk-routed ensembles).
    return {
        {computed_namespace    _match_computed_namespace    _emit_computed_namespace}
        {ensemble_fqn_rewrite  _match_ensemble_fqn_rewrite  _emit_ensemble_fqn_rewrite}
        {namespace_eval        _match_namespace_eval        _emit_namespace_eval}
        {expand_args           _match_expand_args           _emit_expand_args}
        {callback              _match_callback              _emit_callback}
        {apply_lambda          _match_apply_lambda          _emit_apply_lambda}
        {ensemble              _match_ensemble              _emit_ensemble}
        {eval_var              _match_eval_var              _emit_eval_var}
        {eval_brackets         _match_eval_brackets         _emit_eval_brackets}
        {uplevel_var           _match_uplevel_var           _emit_uplevel_var}
        {interp_eval           _match_interp_eval           _emit_interp_eval}
        {var_method            _match_var_method            _emit_var_method}
        {var_command           _match_var_command           _emit_var_command}
        {pattern_b             _match_pattern_b             _emit_pattern_b}
        {pattern_a2            _match_pattern_a2            _emit_pattern_a2}
        {pattern_a             _match_pattern_a             _emit_pattern_a}
    }
}

# ---------------------------------------------------------------------------
# Predicates and emitters — preserved verbatim from P1.1 with minor
# signature changes (they receive cmd_idx + src_start + src_end).
# ---------------------------------------------------------------------------

# --- computed_namespace (P1.3 §13.6 Shape A) ---
# `namespace eval $ns BODY` — the bytecode compiler emits the SAME
# invokeReplace shape as a literal `namespace eval ::foo BODY` (last
# slot LITERAL "::tcl::namespace::eval"), but with a VAR somewhere in
# the interior arg slots (typically slot[2] for the standard form).
# Without this row, the namespace_eval row over-claims it and the
# bridge driver loses the signal that the ns target is dynamic.
#
# Predicate: op==invokeReplace AND last slot LITERAL==::tcl::namespace::eval
# AND at least one interior slot is VAR.
#
# Empirical examples from /usr/share/tcltk/tcllib1.21:
#   * namespace eval $name { ... }           — many places
#   * namespace eval ::dns::$dns::token { ... } — dns/dns.tcl
#   * namespace eval ::oo::Helpers::$ns { ... } — oo/build.tcl
#
# The event `kind computed_namespace` is already an unresolved-family
# event handled by the bridge driver at _dispatch_event line ~485
# (eval_var - eval_brackets - var_method - uplevel_var - interp_eval -
# var_command - computed_namespace) — same treatment as other dynamic
# dispatches.
proc ::jcm::disasm::walker::_match_computed_namespace {slots op arg} {
    if {$op ne "invokeReplace"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    if {[dict get $last kind] ne "LITERAL"} { return 0 }
    if {[dict get $last value] ne "::tcl::namespace::eval"} { return 0 }
    # At least one interior slot must be VAR (otherwise the literal
    # namespace_eval row should handle it).
    set n [llength $slots]
    if {$n < 2} { return 0 }
    for {set i 0} {$i < [expr {$n - 1}]} {incr i} {
        set s [lindex $slots $i]
        if {[dict get $s kind] eq "VAR"} { return 1 }
    }
    return 0
}
proc ::jcm::disasm::walker::_emit_computed_namespace {cmd_idx s e slots op arg} {
    return [dict create kind computed_namespace cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- ensemble_fqn_rewrite (P1.3 §13.6 Shape B) ---
# Stock ensemble subcommands routed via invokeReplace. The bytecode
# compiler picks invokeReplace over invokeStk for some ensembles when
# arity is a known subcommand of a built-in ensemble — concretely,
# `clock format $x` compiles to `push "::tcl::clock::format"` +
# `invokeReplace 3 2`, while `clock format` (no arg) goes through the
# existing invokeStk1 ensemble path.
#
# Predicate: op==invokeReplace AND last slot LITERAL matches
# ^::tcl::ENS::SUB$ where ENS is one of the 10 stock ensembles (post-R32
# ensemble pre-rename table; matches `ENSEMBLE_VERDICT.md` and SPEC_v2
# §3.3) AND the literal is NOT exactly "::tcl::namespace::eval" — the
# namespace_eval and computed_namespace rows own that shape. We can't
# rely on first-match-wins ordering alone here because the namespace_eval
# row's predicate is *more general* than this one (it matches any
# invokeReplace ending in ::tcl::namespace::eval, with no interior-slot
# requirement) — so this row would over-claim literal-namespace shapes
# if not explicitly excluded.
#
# Empirical examples from /usr/share/tcltk/tcllib1.21:
#   * clock format $x                       — clock/rfc2822.tcl:211,213
#   * dict for {k v} $d { ... }            — many tcllib modules
#   * dict update $d k1 v1 ...             — dict-heavy code paths
#
# Event payload uses `kind ensemble` (NOT a new kind) so the bridge
# driver's existing ensemble handler runs unchanged — downstream
# semantics are identical to invokeStk-routed ensembles (emits an
# "ensemble subcommand" call edge).
proc ::jcm::disasm::walker::_match_ensemble_fqn_rewrite {slots op arg} {
    if {$op ne "invokeReplace"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    if {[dict get $last kind] ne "LITERAL"} { return 0 }
    set v [dict get $last value]
    # Exclude ::tcl::namespace::eval — owned by namespace_eval /
    # computed_namespace rows.
    if {$v eq "::tcl::namespace::eval"} { return 0 }
    # P1.3 bundle (9): regex aligned to the existing `ensemble` row's
    # `^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$` shape so both rows
    # accept the same vocabulary (stock Tcl 8.6 ensemble subcommand
    # naming). `[a-zA-Z0-9_]+` (vs the prior `[a-zA-Z_][a-zA-Z0-9_]*`)
    # tolerates a leading-digit subcommand if a future Tcl variant or
    # third-party ensemble produces one — vanishingly unlikely in
    # stock 8.6 but free at this regex level.
    if {![regexp {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$} \
            $v -> ens sub]} { return 0 }
    expr {$ens in $::jcm::disasm::walker::ENSEMBLES}
}
proc ::jcm::disasm::walker::_emit_ensemble_fqn_rewrite {cmd_idx s e slots op arg} {
    set v [_slot_value [lindex $slots end]]
    regexp {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$} \
        $v -> ens sub
    set N [_slot_count_for_op $op $arg]
    return [dict create kind ensemble cmd $cmd_idx \
        src_start $s src_end $e \
        ensemble $ens subcommand $sub arg_count $N \
        bytecode_form invokeReplace]
}

# --- namespace_eval (R9) ---
proc ::jcm::disasm::walker::_match_namespace_eval {slots op arg} {
    if {$op ne "invokeReplace"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    expr {[dict get $last kind] eq "LITERAL"
          && [dict get $last value] eq "::tcl::namespace::eval"}
}
proc ::jcm::disasm::walker::_emit_namespace_eval {cmd_idx s e slots op arg} {
    set ns_slot   [lindex $slots end-2]
    set body_slot [lindex $slots end-1]
    set ns   [_slot_value $ns_slot]
    set body [_slot_value $body_slot]
    return [dict create kind namespace_eval cmd $cmd_idx \
        src_start $s src_end $e ns $ns body $body]
}

# --- expand_args (R7) ---
proc ::jcm::disasm::walker::_match_expand_args {slots op arg} {
    expr {$op eq "invokeExpanded"}
}
proc ::jcm::disasm::walker::_emit_expand_args {cmd_idx s e slots op arg} {
    set first [lindex $slots 0]
    set name  [_slot_value $first]
    return [dict create kind expand_args cmd $cmd_idx \
        src_start $s src_end $e name $name]
}

# --- callback (Tk-style "$obj method" string-concat shape) ---
proc ::jcm::disasm::walker::_match_callback {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    set last [lindex $slots end]
    if {$last eq ""} { return 0 }
    expr {[dict get $last kind] eq "EXPR"
          && [dict get $last value] eq "strcat"}
}
proc ::jcm::disasm::walker::_emit_callback {cmd_idx s e slots op arg} {
    set last [lindex $slots end]
    set method ""
    if {[dict exists $last method]} { set method [dict get $last method] }
    if {$method eq ""} { set method "(strcat-collapsed)" }
    return [dict create kind callback cmd $cmd_idx \
        src_start $s src_end $e method $method]
}

# --- apply_lambda (R8) ---
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
proc ::jcm::disasm::walker::_emit_apply_lambda {cmd_idx s e slots op arg} {
    set lambda [_slot_value [lindex $slots 1]]
    return [dict create kind apply_lambda cmd $cmd_idx \
        src_start $s src_end $e lambda $lambda]
}

# --- ensemble (R10/R29 + R32 string addition) ---
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
proc ::jcm::disasm::walker::_emit_ensemble {cmd_idx s e slots op arg} {
    set v [_slot_value [lindex $slots 0]]
    regexp {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$} $v -> ens sub
    set N [_slot_count_for_op $op $arg]
    return [dict create kind ensemble cmd $cmd_idx \
        src_start $s src_end $e \
        ensemble $ens subcommand $sub arg_count $N]
}

# --- eval $var (§4.1) ---
proc ::jcm::disasm::walker::_match_eval_var {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "LITERAL" && [dict get $s0 value] eq "eval"
          && [dict get $s1 kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_eval_var {cmd_idx s e slots op arg} {
    return [dict create kind eval_var cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- eval_brackets (Strategy A explicit row; replaces P1.1 heuristic) ---
# Match: slot 0 LITERAL "eval", slot 1 EXPR with value invoke_result.
proc ::jcm::disasm::walker::_match_eval_brackets {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    if {[dict get $s0 kind] ne "LITERAL"
        || [dict get $s0 value] ne "eval"} { return 0 }
    expr {[dict get $s1 kind] eq "EXPR"
          && [dict get $s1 value] eq "invoke_result"}
}
proc ::jcm::disasm::walker::_emit_eval_brackets {cmd_idx s e slots op arg} {
    return [dict create kind eval_brackets cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- uplevel $var (§4.5) ---
proc ::jcm::disasm::walker::_match_uplevel_var {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    if {[dict get $s0 kind] ne "LITERAL"
        || [dict get $s0 value] ne "uplevel"} { return 0 }
    set last [lindex $slots end]
    expr {[dict get $last kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_uplevel_var {cmd_idx s e slots op arg} {
    return [dict create kind uplevel_var cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- interp eval (§4.6) ---
proc ::jcm::disasm::walker::_match_interp_eval {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 3} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "LITERAL" && [dict get $s0 value] eq "interp"
          && [dict get $s1 kind] eq "LITERAL" && [dict get $s1 value] eq "eval"}
}
proc ::jcm::disasm::walker::_emit_interp_eval {cmd_idx s e slots op arg} {
    return [dict create kind interp_eval cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- $obj $method (§4.4 var_method) ---
proc ::jcm::disasm::walker::_match_var_method {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "VAR" && [dict get $s1 kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_var_method {cmd_idx s e slots op arg} {
    return [dict create kind var_method cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- var_command (§4.3 + §13.5): $var (no-args dispatch via variable) ---
# Predicate: op==invokeStk{1,4} AND slot 0 VAR AND N==1 (only one slot;
# the variable holds a command name and is invoked with no arguments).
# Fires BEFORE pattern_b (which needs slot 1 LITERAL, requires N>=2).
# Resolves §13.5 (rev4 user-decided=A); v1 SPEC §4.3 + v1 TestUnresolvedDispatch
# pin this category. Avoids spurious unrecognized for the no-args $var case.
proc ::jcm::disasm::walker::_match_var_command {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] != 1} { return 0 }
    set s0 [lindex $slots 0]
    expr {[dict get $s0 kind] eq "VAR"}
}
proc ::jcm::disasm::walker::_emit_var_command {cmd_idx s e slots op arg} {
    return [dict create kind var_command cmd $cmd_idx \
        src_start $s src_end $e]
}

# --- pattern_b (§2.2): $obj method arg ---
proc ::jcm::disasm::walker::_match_pattern_b {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    expr {[dict get $s0 kind] eq "VAR" && [dict get $s1 kind] eq "LITERAL"}
}
proc ::jcm::disasm::walker::_emit_pattern_b {cmd_idx s e slots op arg} {
    set method [_slot_value [lindex $slots 1]]
    set N [_slot_count_for_op $op $arg]
    return [dict create kind pattern_b cmd $cmd_idx \
        src_start $s src_end $e method $method arg_count $N]
}

# --- pattern_a2 (§2.3): ::ns method — single-segment FQN dispatch ---
proc ::jcm::disasm::walker::_match_pattern_a2 {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 2} { return 0 }
    set s0 [lindex $slots 0]
    set s1 [lindex $slots 1]
    if {[dict get $s0 kind] ne "LITERAL"} { return 0 }
    if {[dict get $s1 kind] ne "LITERAL"} { return 0 }
    set v [dict get $s0 value]
    expr {[string match "::*" $v]
          && [string first "::" [string range $v 2 end]] < 0}
}
proc ::jcm::disasm::walker::_emit_pattern_a2 {cmd_idx s e slots op arg} {
    set fqn    [_slot_value [lindex $slots 0]]
    set method [_slot_value [lindex $slots 1]]
    set N [_slot_count_for_op $op $arg]
    return [dict create kind pattern_a2 cmd $cmd_idx \
        src_start $s src_end $e fqn $fqn method $method arg_count $N]
}

# --- pattern_a (§2.1): bare/multi-segment call (fallback) ---
proc ::jcm::disasm::walker::_match_pattern_a {slots op arg} {
    if {$op ne "invokeStk1" && $op ne "invokeStk4"} { return 0 }
    if {[llength $slots] < 1} { return 0 }
    set s0 [lindex $slots 0]
    expr {[dict get $s0 kind] eq "LITERAL"}
}
proc ::jcm::disasm::walker::_emit_pattern_a {cmd_idx s e slots op arg} {
    set name [_slot_value [lindex $slots 0]]
    set N [_slot_count_for_op $op $arg]
    return [dict create kind pattern_a cmd $cmd_idx \
        src_start $s src_end $e name $name arg_count $N]
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

proc ::jcm::disasm::walker::_lookup_effect {op} {
    variable STACK_EFFECTS
    if {[dict exists $STACK_EFFECTS $op]} {
        return [dict get $STACK_EFFECTS $op]
    }
    # Tier 2: consult the canonical tclInstructionTable[] extract.
    # Returns a synthesized {pop push TIER2_AUTO operand_form} effect
    # using authoritative pop/push counts from the Tcl compiler. NO
    # dispatch event is emitted for TIER2_AUTO — the walker just keeps
    # its abstract stack sound across previously-unrecognized opcodes.
    _ensure_tier2_loaded
    if {[dict exists $::jcm::disasm::tcltable::TCL_INSTRUCTION_TABLE $op]} {
        set row [dict get $::jcm::disasm::tcltable::TCL_INSTRUCTION_TABLE $op]
        lassign $row numbytes stackeff numoperands optypes_csv
        return [_tier2_synthesize $op $numbytes $stackeff $numoperands \
            $optypes_csv]
    }
    return ""
}

# Synthesize a Tier-1-shaped stack-effect tuple from the canonical
# tclInstructionTable[] row. Returns {pop_count push_count effect_class
# operand_form}.
#
# stackEffect is signed (push - pop). For numeric stackEffect the canonical
# semantics from tclCompile.c is: pop = max(0, -stackEffect + (push-only
# delta)); but at the level of "keep the abstract stack consistent" we
# only need (pop, push) such that push - pop == stackEffect. The walker's
# downstream consumers (_apply_stack_effect TIER2_AUTO branch) treat
# every Tier 2 push as an opaque EXPR slot, so we pick the simplest
# decomposition: if stackEffect >= 0, pop = numOperands... no — that
# conflates stack with operand bytes. Use this rule instead:
#   * stackEffect == INT_MIN  → operand-driven (pop_count="N", read from
#     operand per operand_form). Map operand_types to operand_form.
#   * stackEffect >= 0        → pop = 0, push = stackEffect.
#   * stackEffect <  0        → pop = -stackEffect, push = 0. (Most
#     binary ops in tclInstructionTable have stackEffect=-1 i.e. pop 2,
#     push 1; see comments in §3.2 of WALKER_CONTRACT_v2_2.) For walker
#     purposes the EXPR push is restored synthetically — the abstract
#     stack tracks only kind, not arity-equivalence.
#
# This loses the exact pop=2/push=1 distinction for binary ops (we
# emit pop=1/push=0 instead, then push back a synthetic EXPR), but the
# net effect on the stack height matches and dispatch doesn't fire on
# Tier 2 anyway. Strictly: Tier 2's contract is "delta-correct" not
# "shape-correct".
proc ::jcm::disasm::walker::_tier2_synthesize {op numbytes stackeff \
        numoperands optypes_csv} {
    set operand_form [_tier2_operand_form $optypes_csv]
    if {$stackeff eq "INT_MIN"} {
        # Operand-driven; pop_count = N from operand. invokeStk1/4 etc.
        # already have hand-classified Tier 1 rows, so reaching this path
        # means a less-common variadic op (e.g., callFunc1, lsetFlat).
        return [list N 1 TIER2_AUTO $operand_form]
    }
    if {![string is integer -strict $stackeff]} {
        # Defensive — extractor only emits signed ints or INT_MIN.
        return ""
    }
    if {$stackeff >= 0} {
        return [list 0 $stackeff TIER2_AUTO $operand_form]
    }
    set pop [expr {-$stackeff}]
    return [list $pop 0 TIER2_AUTO $operand_form]
}

# Map the comma-joined operand_types string from the extractor to the
# walker's operand_form vocabulary. Conservative: when in doubt, use
# "none" (operand_form is only consulted by _resolve_count for "N"
# pop_specs, and Tier 2 emits "N" pop_spec only for INT_MIN cases).
proc ::jcm::disasm::walker::_tier2_operand_form {optypes_csv} {
    set parts [split $optypes_csv ","]
    set first [lindex $parts 0]
    set count [llength $parts]
    if {$count >= 2} {
        # Two-operand ops (typically OPERAND_UINT4 + OPERAND_UINT1 for
        # invokeReplace, OPERAND_LVT4 + OPERAND_AUX4 for dictUpdate*).
        return two-int
    }
    switch -- $first {
        OPERAND_LIT1 -
        OPERAND_LVT1 -
        OPERAND_INT1 -
        OPERAND_UINT1 -
        OPERAND_OFFSET1 { return int1 }
        OPERAND_LIT4 -
        OPERAND_LVT4 -
        OPERAND_INT4 -
        OPERAND_UINT4 -
        OPERAND_OFFSET4 -
        OPERAND_AUX4 -
        OPERAND_IDX4 { return int4 }
        OPERAND_NONE -
        ""           { return none }
        default      { return int }
    }
}

proc ::jcm::disasm::walker::_decode_operand_int {operand} {
    if {$operand eq ""} { return "" }
    # Operands may be "+N", "-N", or plain "N".
    if {[string index $operand 0] eq "+"} {
        return [string range $operand 1 end]
    }
    return $operand
}

proc ::jcm::disasm::walker::_resolve_count {spec operand operand_form} {
    if {$spec eq "N"} {
        if {$operand_form eq "two-int"} {
            lassign [split $operand " "] a _b
            if {$a eq ""} { return 0 }
            return [_decode_operand_int $a]
        }
        set n [_decode_operand_int $operand]
        if {$n eq ""} { return 0 }
        return $n
    }
    if {[string is integer -strict $spec]} { return $spec }
    return 0
}

proc ::jcm::disasm::walker::_unquote_comment {comment} {
    if {[regexp {^"(.*)"$} $comment -> inner]} { return $inner }
    return $comment
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
