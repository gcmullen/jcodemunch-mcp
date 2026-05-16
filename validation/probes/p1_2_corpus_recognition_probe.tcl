#!/usr/bin/env tclsh
#
# p1_2_corpus_recognition_probe.tcl — P1.2 Strategy A walker exit gate
# per WALKER_CONTRACT_v2_2 §8, generalized for cross-codebase coverage.
#
# Walks every reachable .tcl/.itcl/.itk file under ROOT through
# parser::disassemble_and_parse + walker::walk and counts events of
# kind=="unrecognized". Exit 0 iff the count is zero. On failure, prints
# the first 10 unrecognized events with file:line for triage AND a
# frequency-ranked per-opcode breakdown that tells you exactly which
# rows to add to STACK_EFFECTS to support this codebase.
#
# Strategy A's "0 unrecognized" gate counts ALL FOUR cases per §8:
#   1. dispatch fall-through (no row matched)
#   2. orphan_pc (slot[0].src_offset has no containing src range)
#   3. stack_underflow (invoke pops more than stack has)
#   4. unknown_opcode (opcode not in §3.2 STACK_EFFECTS)
#
# Usage:
#   tclsh validation/probes/p1_2_corpus_recognition_probe.tcl \
#       [--root PATH | --bluice-root PATH] [--no-synthetic]
#
# --root PATH         walks PATH recursively, ALL .tcl/.itcl/.itk files (no
#                     scope filter). Use for non-bluice codebases.
# --bluice-root PATH  back-compat alias; uses the bluice scope filter
#                     (BluIceWidgets / DcsWidgets / dcs-lib-tcl/main/scripts /
#                      dhs-tcl / dcss/scripts/**).
# Default: --bluice-root /home/giles/bluice

set HERE [file dirname [file normalize [info script]]]
set ROOT [file normalize [file join $HERE .. ..]]
source [file join $ROOT src jcodemunch_mcp parser opcode_walker.tcl]

set ROOT_DIR /home/giles/bluice
set SCOPE_FILTER 1
set INCLUDE_SYNTHETIC 1
set argv_idx 0
while {$argv_idx < [llength $::argv]} {
    set arg [lindex $::argv $argv_idx]
    if {$arg eq "--bluice-root"} {
        incr argv_idx
        set ROOT_DIR [lindex $::argv $argv_idx]
        set SCOPE_FILTER 1
    } elseif {$arg eq "--root"} {
        incr argv_idx
        set ROOT_DIR [lindex $::argv $argv_idx]
        set SCOPE_FILTER 0
    } elseif {$arg eq "--no-synthetic"} {
        set INCLUDE_SYNTHETIC 0
    }
    incr argv_idx
}

# ---------------------------------------------------------------------------
# Corpus discovery (mirrors ensemble_enumeration_probe.tcl scope)
# ---------------------------------------------------------------------------

proc collect_corpus {root scope_filter} {
    if {!$scope_filter} {
        # Cross-codebase mode: walk root recursively, all .tcl/.itcl/.itk.
        return [lsort -unique [recursive_glob_tcl $root]]
    }
    # Bluice scope filter: documented subdirs only.
    set files [list]
    set scope_dirs {
        BluIceWidgets
        DcsWidgets
        dcs-lib-tcl/main/scripts
        dhs-tcl
    }
    foreach sub $scope_dirs {
        set dir [file join $root $sub]
        if {![file isdirectory $dir]} { continue }
        lappend files {*}[recursive_glob_tcl $dir]
    }
    set dcss_root [file join $root dcss]
    if {[file isdirectory $dcss_root]} {
        foreach f [recursive_glob_tcl $dcss_root] {
            if {[string match *scripts* $f]} { lappend files $f }
        }
    }
    return [lsort -unique $files]
}

proc recursive_glob_tcl {dir} {
    set out [list]
    foreach pat {*.tcl *.itcl *.itk} {
        catch {
            foreach f [glob -nocomplain -directory $dir $pat] {
                lappend out $f
            }
        }
    }
    catch {
        foreach sub [glob -nocomplain -type d -directory $dir *] {
            lappend out {*}[recursive_glob_tcl $sub]
        }
    }
    return $out
}

# Build a line-number lookup over a source string by counting newlines
# up to a given byte offset.
proc src_offset_to_line {src offset} {
    if {$offset < 0} { return 0 }
    if {$offset > [string length $src]} {
        set offset [string length $src]
    }
    set prefix [string range $src 0 [expr {$offset - 1}]]
    return [expr {1 + [regexp -all "\n" $prefix]}]
}

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

set CORPUS [collect_corpus $ROOT_DIR $SCOPE_FILTER]
set total_files 0
set disasm_failed 0
set total_events 0
set total_unrecognized 0
set first_triage [list]
set TRIAGE_LIMIT 10

# Per-opcode breakdown: key="${reason}:${terminal_op}", value=dict {
#     count INT, files DICT (path → 1), first_sample {file line} }
array set breakdown {}

foreach f $CORPUS {
    incr total_files
    if {[catch {open $f r} fp]} { continue }
    fconfigure $fp -encoding utf-8
    if {[catch {read $fp} src]} { close $fp; continue }
    close $fp

    set parsed [::jcm::disasm::parser::disassemble_and_parse $src]
    if {[dict exists $parsed error]} {
        incr disasm_failed
        continue
    }
    set events [::jcm::disasm::walker::walk $parsed]
    foreach ev $events {
        incr total_events
        if {[dict get $ev kind] eq "unrecognized"} {
            incr total_unrecognized
            set off  [dict get $ev src_start]
            set line [src_offset_to_line $src $off]
            set reason [dict get $ev reason]
            set top [dict get $ev terminal_op]
            set ta  [dict get $ev terminal_arg]
            # First-N triage list
            if {[llength $first_triage] < $TRIAGE_LIMIT} {
                lappend first_triage [list $f $line $reason $top $ta]
            }
            # Per-opcode breakdown
            set key "${reason}:${top}"
            if {![info exists breakdown($key)]} {
                set breakdown($key) [dict create count 0 files [dict create] \
                    first_file $f first_line $line first_arg $ta]
            }
            dict incr breakdown($key) count
            dict set breakdown($key) files $f 1
        }
    }
}

# ---------------------------------------------------------------------------
# Report + verdict
# ---------------------------------------------------------------------------

puts "==================================================================="
puts "P1.2(e) Corpus recognition probe — Strategy A walker"
puts "==================================================================="
if {$SCOPE_FILTER} {
    puts "Mode:                      bluice (scope filter applied)"
} else {
    puts "Mode:                      cross-codebase (recursive, no filter)"
}
puts "Root:                      $ROOT_DIR"
puts "Files probed:              $total_files"
puts "Disassemble failures:      $disasm_failed"
puts "Total walker events:       $total_events"
puts "Unrecognized events:       $total_unrecognized"
puts ""

if {$total_unrecognized == 0} {
    puts "PASS: 0 unrecognized events across $total_events corpus events"
    exit 0
}

puts "FAIL: $total_unrecognized unrecognized events across $total_events corpus events"
puts ""

# Per-opcode breakdown — sorted by count descending. Tells you exactly
# which rows to add to STACK_EFFECTS to close the gap on this codebase.
set breakdown_rows [list]
foreach key [array names breakdown] {
    set entry $breakdown($key)
    lappend breakdown_rows [list \
        [dict get $entry count] \
        $key \
        [dict size [dict get $entry files]] \
        [dict get $entry first_file] \
        [dict get $entry first_line] \
        [dict get $entry first_arg]]
}
set breakdown_rows [lsort -decreasing -integer -index 0 $breakdown_rows]

puts "Per-opcode breakdown (ranked by frequency):"
puts ""
puts [format "  %-40s %8s %8s  %s" "REASON:TERMINAL_OP" "COUNT" "FILES" "FIRST_SAMPLE"]
foreach row $breakdown_rows {
    lassign $row count key num_files first_file first_line first_arg
    set short_file [file tail $first_file]
    puts [format "  %-40s %8d %8d  %s:%d (arg=%s)" \
        $key $count $num_files $short_file $first_line $first_arg]
}
puts ""

puts "First [llength $first_triage] for triage:"
foreach entry $first_triage {
    lassign $entry file line reason top ta
    puts "  $file:$line  reason=$reason terminal_op=$top terminal_arg=$ta"
}
exit 1
