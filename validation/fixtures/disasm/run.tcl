#!/usr/bin/env tclsh
#
# run.tcl — driver for the §2.3 dispatch-table fixture suite.
#
# Each `*.test` file in this directory has the form:
#
#     # leading comment lines (kept as Tcl comments inside the source)
#     SOURCE_LINES...
#     ---
#     EXPECTED_EVENT_LINES...
#
# The driver disassembles the SOURCE through tcl_disasm_parser, walks
# it through opcode_walker, formats the events with format_events, and
# compares against EXPECTED. Mismatches are printed; the exit code is
# non-zero iff any fixture fails.
#
# Usage:
#   tclsh validation/fixtures/disasm/run.tcl           # check
#   tclsh validation/fixtures/disasm/run.tcl --capture # rewrite expecteds
#   tclsh validation/fixtures/disasm/run.tcl FILE.test # one fixture

set HERE [file dirname [file normalize [info script]]]
set ROOT [file normalize [file join $HERE .. .. ..]]
source [file join $ROOT src jcodemunch_mcp parser opcode_walker.tcl]

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

set CAPTURE 0
set ONE_FILE ""
foreach arg $::argv {
    if {$arg eq "--capture"} {
        set CAPTURE 1
    } else {
        set ONE_FILE $arg
    }
}

if {$ONE_FILE ne ""} {
    set fixtures [list $ONE_FILE]
} else {
    set fixtures [lsort [glob -nocomplain [file join $HERE *.test]]]
}

# ---------------------------------------------------------------------------
# Per-fixture run
# ---------------------------------------------------------------------------

proc _normalize_block {block} {
    set lines [split $block "\n"]
    # Drop trailing empty/whitespace-only lines
    while {[llength $lines] > 0
           && [string trim [lindex $lines end]] eq ""} {
        set lines [lrange $lines 0 end-1]
    }
    return [join $lines "\n"]
}

proc split_fixture {content} {
    set src ""
    set expected ""
    set in_expected 0
    foreach line [split $content "\n"] {
        if {[string trim $line] eq "---"} {
            set in_expected 1
            continue
        }
        if {$in_expected} {
            append expected $line "\n"
        } else {
            append src $line "\n"
        }
    }
    return [list $src $expected]
}

proc run_fixture {path capture} {
    set fp [open $path r]
    fconfigure $fp -encoding utf-8
    set content [read $fp]
    close $fp

    lassign [split_fixture $content] src expected

    set parsed [::jcm::disasm::parser::disassemble_and_parse $src]
    set events [::jcm::disasm::walker::walk $parsed]
    set actual [::jcm::disasm::walker::format_events $events]

    if {$capture} {
        # Rewrite expected with actual.
        set new_content "${src}---\n${actual}"
        set fp [open $path w]
        fconfigure $fp -encoding utf-8
        puts -nonewline $fp $new_content
        close $fp
        return [list captured $path]
    }

    # Normalize: strip leading/trailing whitespace per line + drop empty
    # tail lines. This keeps the comparison resilient to trailing
    # newlines from the file's final empty split chunk.
    set norm_expected [_normalize_block $expected]
    set norm_actual   [_normalize_block $actual]
    if {$norm_actual eq $norm_expected} {
        return [list pass $path]
    }
    return [list fail $path $norm_expected $norm_actual]
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

set total 0
set passed 0
set failed 0
set fail_details [list]

foreach fx $fixtures {
    incr total
    set result [run_fixture $fx $CAPTURE]
    set status [lindex $result 0]
    set name [file tail [lindex $result 1]]
    switch -- $status {
        pass {
            incr passed
            puts "PASS  $name"
        }
        fail {
            incr failed
            puts "FAIL  $name"
            lappend fail_details $result
        }
        captured {
            puts "CAP   $name"
        }
    }
}

puts ""
puts "Total: $total  Passed: $passed  Failed: $failed"

if {$failed > 0} {
    puts ""
    puts "=== FAIL DETAILS ==="
    foreach detail $fail_details {
        lassign $detail _ path expected actual
        puts ""
        puts "--- [file tail $path] ---"
        puts "expected:"
        puts $expected
        puts "actual:"
        puts $actual
    }
    exit 1
}
exit 0
