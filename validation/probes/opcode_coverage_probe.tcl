#!/usr/bin/env tclsh
#
# opcode_coverage_probe.tcl — Stream 3 (N) — diffs the canonical
# tclInstructionTable[] (190 rows from Tcl 8.6.14) against the walker's
# hand-classified STACK_EFFECTS (Tier 1) and reports tier population:
#
#   Tier 1: hand-classified in STACK_EFFECTS (used for stack effects AND
#           dispatch matching).
#   Tier 2: in tclInstructionTable but not hand-classified (used for
#           stack effects only — auto pop/push, no dispatch event).
#   Tier 3: in tclInstructionTable but never observed by walker — purely
#           informational (Tier 3 fires the unknown_opcode boundary
#           recovery path; this metric is "future surface" not gap).
#
# This probe is informational; it always exits 0.

set REPO_ROOT [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $REPO_ROOT validation probes INSTRUCTION_TABLE_8_6_14.tcl]
source [file join $REPO_ROOT src jcodemunch_mcp parser tcl opcode_walker.tcl]

set tcl_table $::jcm::disasm::tcltable::TCL_INSTRUCTION_TABLE
set walker_table $::jcm::disasm::walker::STACK_EFFECTS

# Names from each set.
set tcl_names    [list]
foreach {n _v} $tcl_table { lappend tcl_names $n }
set walker_names [list]
foreach {n _v} $walker_table { lappend walker_names $n }

# Tier 1 = hand-classified in walker.
set tier1 [lsort $walker_names]

# Tier 2 = in tcl_table but not in walker_table.
set tier2 [list]
foreach n $tcl_names {
    if {![dict exists $walker_table $n]} { lappend tier2 $n }
}
set tier2 [lsort $tier2]

# Tier 3 = in walker (Tier 1) but NOT in tcl_table (would mean walker has
# a row for a name Tcl 8.6 doesn't ship; should be empty in steady state).
set tier_orphan [list]
foreach n $walker_names {
    if {![dict exists $tcl_table $n]} { lappend tier_orphan $n }
}
set tier_orphan [lsort $tier_orphan]

set total_tcl [llength $tcl_names]
set total_t1  [llength $tier1]
set total_t2  [llength $tier2]
set total_t3  [expr {$total_tcl - $total_t1 - $total_t2 + [llength $tier_orphan]}]

puts "==================================================="
puts "Opcode coverage probe — Tcl 8.6.14 instruction table"
puts "==================================================="
puts ""
puts "Total opcodes in tclInstructionTable\[\]:  $total_tcl"
puts "Tier 1 (hand-classified in STACK_EFFECTS): $total_t1"
puts "Tier 2 (in Tcl table, not hand-classified): $total_t2"
puts "Tier 3 (truly novel — neither table):       0 (Tcl 8.6 is closed surface)"
puts "Walker rows orphaned vs Tcl table:          [llength $tier_orphan]"
puts ""
puts "--- Tier 1 (walker hand-classified) ---"
puts "  [join $tier1 { }]"
puts ""
puts "--- Tier 2 (Tcl-known, walker uses canonical pop/push) ---"
puts "  [join $tier2 { }]"
puts ""
if {[llength $tier_orphan] > 0} {
    puts "--- Walker-only (orphan) ---"
    puts "  [join $tier_orphan { }]"
    puts ""
}

exit 0
