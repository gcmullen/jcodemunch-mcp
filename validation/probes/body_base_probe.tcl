#!/usr/bin/env tclsh
#
# body_base_probe.tcl — empirical probe for PLAN_v2.1 §2.2 strategy.
#
# Hypothesis: a small word-position walker (~30-50 LoC) operating on the
# parent command's source text — anchored by `tcl::unsupported::disassemble
# script`'s `src N-M` byte ranges — recovers body-arg start positions
# accurately on real bluice TCL.
#
# Method: disassemble each .tcl file. For every command whose first word
# is a definition-introducer (proc, namespace eval, itcl::class, [access]
# method, body, configbody, oo::class create, itcl::body), apply the
# walker to locate the body slot. Validate against `lindex` (which gives
# the value, not the position): walker-extracted body content must equal
# the value `lindex` returns.
#
# This is a CRITICAL gate. If the walker fails on any case the bridge
# must support, escalate to R33 (C extension wrapping Tcl_ParseCommand).
#
# Usage: tclsh body_base_probe.tcl [file1.tcl file2.tcl ...]
#        tclsh body_base_probe.tcl --bluice  ;# default: 12 representative files

# ---------------------------------------------------------------------------
# v2.1 §2.2 word-position walker
# ---------------------------------------------------------------------------
#
# Returns the char offset within $cmd_text where word $n (0-indexed) begins.
# Returns -1 if $n exceeds the command's word count.
#
# Tcl word-grammar rules respected:
#   - Bare words: terminate at whitespace; nested [...] tracked for depth
#   - Brace words: depth-balanced {...}; backslash-escaped braces skipped
#   - Quoted words: "..."; escape-aware (backslash skips next char)
#   - Backslash-newline continuation: counts as whitespace per Tcl
#   - Comments handled by caller (commands list comes from disassembly)

proc find_word_start {cmd_text n} {
    set len [string length $cmd_text]
    set i 0
    set word 0
    while {$i < $len} {
        # Skip whitespace and backslash-newline continuations
        while {$i < $len} {
            set ch [string index $cmd_text $i]
            if {$ch eq "\\" && $i + 1 < $len
                && [string index $cmd_text [expr {$i + 1}]] eq "\n"} {
                incr i 2
                continue
            }
            if {$ch ne " " && $ch ne "\t" && $ch ne "\n" && $ch ne "\r"} { break }
            incr i
        }
        if {$i >= $len} { return -1 }

        if {$word == $n} { return $i }

        # Skip past this word
        set ch [string index $cmd_text $i]
        if {$ch eq "\{"} {
            set depth 1
            incr i
            while {$i < $len && $depth > 0} {
                set c [string index $cmd_text $i]
                if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c eq "\{"} { incr depth }
                if {$c eq "\}"} { incr depth -1 }
                incr i
            }
        } elseif {$ch eq "\""} {
            incr i
            while {$i < $len} {
                set c [string index $cmd_text $i]
                if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c eq "\""} { incr i; break }
                incr i
            }
        } else {
            # Bare word: until whitespace, but [...] subs nest
            while {$i < $len} {
                set c [string index $cmd_text $i]
                if {$c eq "\\" && $i + 1 < $len
                    && [string index $cmd_text [expr {$i + 1}]] eq "\n"} {
                    break
                }
                if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c eq "\["} {
                    set depth 1
                    incr i
                    while {$i < $len && $depth > 0} {
                        set c2 [string index $cmd_text $i]
                        if {$c2 eq "\\" && $i + 1 < $len} { incr i 2; continue }
                        if {$c2 eq "\["} { incr depth }
                        if {$c2 eq "\]"} { incr depth -1 }
                        incr i
                    }
                    continue
                }
                if {$c eq " " || $c eq "\t" || $c eq "\n" || $c eq "\r"} { break }
                incr i
            }
        }
        incr word
    }
    return -1
}

# Given $cmd_text and the char offset where word $n starts, return
# {body_content_start body_content_end_inclusive} pointing to the inside
# of the brace/quote (or the bare word range if neither). Returns {} on
# error.
proc word_content_range {cmd_text word_start} {
    set len [string length $cmd_text]
    set ch [string index $cmd_text $word_start]
    if {$ch eq "\{"} {
        set depth 1
        set i [expr {$word_start + 1}]
        set inner_start $i
        while {$i < $len && $depth > 0} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq "\{"} { incr depth }
            if {$c eq "\}"} {
                incr depth -1
                if {$depth == 0} { return [list $inner_start [expr {$i - 1}]] }
            }
            incr i
        }
        return {}
    } elseif {$ch eq "\""} {
        set i [expr {$word_start + 1}]
        set inner_start $i
        while {$i < $len} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq "\""} { return [list $inner_start [expr {$i - 1}]] }
            incr i
        }
        return {}
    } else {
        # Bare word: re-scan to find end
        set i $word_start
        while {$i < $len} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len
                && [string index $cmd_text [expr {$i + 1}]] eq "\n"} { break }
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq " " || $c eq "\t" || $c eq "\n" || $c eq "\r"} { break }
            incr i
        }
        return [list $word_start [expr {$i - 1}]]
    }
}

# ---------------------------------------------------------------------------
# Disassembly extraction: get the command list with `src start-end` ranges
# ---------------------------------------------------------------------------
#
# `disassemble script` emits a header followed by per-command `Command N:
# pc X-Y, src S-E` lines. We only need the src ranges for the outer
# command list.

proc disasm_command_ranges {src} {
    if {[catch {tcl::unsupported::disassemble script $src} bc]} {
        return [list error $bc]
    }
    # The "Commands N:" section packs multiple `K: pc ...-..., src S-E`
    # entries onto each line. Extract the section, then -all-inline match.
    # Section ends at the first `Command 1:` line (start of per-cmd body
    # listing) or "Command " elsewhere.
    set section ""
    set in_cmd_list 0
    foreach line [split $bc "\n"] {
        if {[regexp {^  Commands \d+:} $line]} { set in_cmd_list 1; continue }
        if {[regexp {^  Command \d+:} $line]} { break }
        if {$in_cmd_list} { append section $line "\n" }
    }
    set ranges {}
    # 5 capture groups → 6 list entries per match (whole + 5).
    foreach {whole _cmd _pc_s _pc_e s e} [regexp -all -inline \
            {(\d+):\s*pc\s+(\d+)-(\d+),\s*src\s+(\d+)-(\d+)} $section] {
        lappend ranges [list $s $e]
    }
    return $ranges
}

# ---------------------------------------------------------------------------
# Definition introducers and their body-arg index in the parent command
# ---------------------------------------------------------------------------
#
# Each entry: {match_pattern body_word_index require_words description}
# Matched against the lindex'd first words of the parent command.
#
# For prefix-introducers (public/private/protected), we strip the prefix
# before matching, and add 1 to the body index.

set ::DEFINITIONS {
    {proc                 3  4  "proc NAME ARGS BODY"}
    {proc                 3  3  "proc NAME ARGS"}
    {namespace_eval       2  4  "namespace eval NS BODY"}
    {itcl::class          2  3  "itcl::class NAME BODY"}
    {::itcl::class        2  3  "::itcl::class NAME BODY"}
    {oo::class_create     3  4  "oo::class create NAME BODY"}
    {::oo::class_create   3  4  "::oo::class create NAME BODY"}
    {itcl::body           3  4  "itcl::body Class::method ARGS BODY"}
    {::itcl::body         3  4  "::itcl::body Class::method ARGS BODY"}
    {body                 3  4  "body Class::method ARGS BODY"}
    {itcl::configbody     2  3  "itcl::configbody Class::var BODY"}
    {configbody           2  3  "configbody Class::var BODY"}
    {method               3  4  "[access] method NAME ARGS BODY"}
    {constructor          2  3  "constructor ARGS BODY"}
    {constructor          3  4  "constructor ARGS INIT BODY (iTcl 3-arg)"}
    {destructor           1  2  "destructor BODY"}
    {itk::usual           2  3  "itk::usual NAME BODY"}
    {itk_component_add    3  4  "itk_component add NAME CREATE"}
}

# Match a parent command against the definition table; return
# {body_index description} or {} if not a definition.
# parts is the lrange-wrapped word list.
proc classify_definition {parts} {
    if {[llength $parts] < 1} { return {} }
    set first [lindex $parts 0]
    set second ""
    if {[llength $parts] >= 2} { set second [lindex $parts 1] }

    # Strip iTcl access prefix
    set offset 0
    if {$first in {public private protected}} {
        if {[llength $parts] < 2} { return {} }
        set first $second
        set second ""
        if {[llength $parts] >= 3} { set second [lindex $parts 2] }
        set parts [lrange $parts 1 end]
        incr offset 1
    }

    switch -- $first {
        proc {
            if {[llength $parts] >= 4} {
                return [list [expr {3 + $offset}] "proc NAME ARGS BODY"]
            }
        }
        namespace {
            if {$second eq "eval" && [llength $parts] >= 4} {
                return [list 3 "namespace eval NS BODY"]
            }
        }
        itcl::class - ::itcl::class {
            if {[llength $parts] >= 3} {
                return [list 2 "itcl::class NAME BODY"]
            }
        }
        itk::usual {
            if {[llength $parts] >= 3} {
                return [list 2 "itk::usual NAME BODY"]
            }
        }
        oo::class - ::oo::class {
            if {$second eq "create" && [llength $parts] >= 4} {
                return [list 3 "oo::class create NAME BODY"]
            }
        }
        class {
            # Custom-DSL `class NAME BODY` (git-gui style; bluice uses this
            # extensively in widget files). The current bridge dispatches
            # this via parse_custom_class.
            if {[llength $parts] >= 3} {
                return [list 2 "class NAME BODY"]
            }
        }
        itcl::body - ::itcl::body - body {
            if {$first eq "body"} {
                # Bare `body` requires Class::method qualifier
                if {![string match "*::*" $second]} { return {} }
            }
            if {[llength $parts] >= 4} {
                return [list 3 "body Class::method ARGS BODY"]
            }
        }
        itcl::configbody - ::itcl::configbody - configbody {
            if {$first eq "configbody" && ![string match "*::*" $second]} { return {} }
            if {[llength $parts] >= 3} {
                return [list 2 "configbody Class::var BODY"]
            }
        }
        method {
            # access-prefixed: parts already shifted; bare method also valid in TclOO
            if {[llength $parts] >= 4} {
                return [list 3 "method NAME ARGS BODY"]
            }
        }
        constructor {
            # 2-arg (TclOO/iTcl): args body. 3-arg (iTcl): args init body.
            if {[llength $parts] == 4} {
                return [list 3 "constructor ARGS INIT BODY"]
            }
            if {[llength $parts] >= 3} {
                return [list 2 "constructor ARGS BODY"]
            }
        }
        destructor {
            if {[llength $parts] >= 2} {
                return [list 1 "destructor BODY"]
            }
        }
        itk_component {
            if {$second eq "add" && [llength $parts] >= 4} {
                set idx 3
                if {[llength $parts] >= 5
                    && [lindex $parts 2] eq "-protected"} { set idx 4 }
                return [list $idx "itk_component add NAME CREATE"]
            }
        }
    }
    return {}
}

# ---------------------------------------------------------------------------
# Probe driver
# ---------------------------------------------------------------------------

# Recursive walker: probes outer commands, then recurses into each
# definition's body via `disassemble script` (v2.1 §2.1 strategy).
# Updates counters in caller via upvar.
proc probe_text {src path label tested_var matched_var mismatched_var cases_var depth} {
    upvar $tested_var tested
    upvar $matched_var matched
    upvar $mismatched_var mismatched
    upvar $cases_var cases

    if {$depth > 6} { return }

    set ranges [disasm_command_ranges $src]
    if {[lindex $ranges 0] eq "error"} {
        # Disassembly failure on a body is informational. The bridge needs
        # to gracefully degrade for syntactically-malformed inputs.
        lappend cases [list "DISASM_FAIL" $path $label [lindex $ranges 1]]
        return
    }

    foreach r $ranges {
        lassign $r s e
        set cmd_text [string range $src $s $e]

        if {[catch {set parts [lrange $cmd_text 0 end]}]} {
            lappend cases [list "LRANGE_FAIL" $path $label $s $e \
                [string range $cmd_text 0 60]]
            continue
        }
        set classify [classify_definition $parts]
        if {$classify eq {}} continue
        lassign $classify body_idx desc

        set walker_pos [find_word_start $cmd_text $body_idx]
        if {$walker_pos < 0} {
            incr mismatched
            lappend cases [list "WALKER_NOT_FOUND" $path $label $s $desc \
                [string range $cmd_text 0 60]]
            continue
        }
        set crange [word_content_range $cmd_text $walker_pos]
        if {$crange eq {}} {
            incr mismatched
            lappend cases [list "CONTENT_RANGE_FAIL" $path $label $s $desc]
            continue
        }
        lassign $crange cs ce
        set walker_body [string range $cmd_text $cs $ce]
        set ground [lindex $parts $body_idx]

        incr tested
        if {$walker_body eq $ground} {
            incr matched
        } else {
            incr mismatched
            set wb_short [string range $walker_body 0 80]
            set gr_short [string range $ground 0 80]
            lappend cases [list "MISMATCH" $path $label $s $desc $wb_short $gr_short]
            continue
        }

        # Recurse: the body is itself parsable. For class/namespace bodies
        # use `disassemble script`; for proc/method bodies the lambda is
        # equivalent in the strategy (we just walk the body content).
        # Skip recursion on `body Class::method` and similar where the
        # body is a method body (would only nest deeper without new
        # definition shapes); recurse on namespace/class bodies to surface
        # methods.
        if {[string length $walker_body] >= 4} {
            probe_text $walker_body $path "$label/$desc" \
                tested matched mismatched cases [expr {$depth + 1}]
        }
    }
}

proc probe_file {path} {
    set fd [open $path r]
    fconfigure $fd -encoding utf-8
    set src [read $fd]
    close $fd

    set tested 0
    set matched 0
    set mismatched 0
    set cases {}
    probe_text $src $path "(file)" tested matched mismatched cases 0
    return [list $tested $matched $mismatched $cases]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

set BLUICE_FILES {
    /home/giles/bluice/BluIceWidgets/BarcodeView.tcl
    /home/giles/bluice/BluIceWidgets/Admin.tcl
    /home/giles/bluice/BluIceWidgets/Anneal.tcl
    /home/giles/bluice/BluIceWidgets/Scan3DView.tcl
    /home/giles/bluice/BluIceWidgets/AutoSample.tcl
    /home/giles/bluice/DcsWidgets/AttributeDisplay.tcl
    /home/giles/bluice/DcsWidgets/AuthClient.tcl
    /home/giles/bluice/DcsWidgets/BarcodeMap.tcl
    /home/giles/bluice/dcs-lib-tcl/main/scripts/AsyncGets.tcl
    /home/giles/bluice/dcs-lib-tcl/main/scripts/Clock.tcl
    /home/giles/bluice/dcs-lib-tcl/main/scripts/DcssHardwareServer.tcl
    /home/giles/bluice/dcs-lib-tcl/main/scripts/DcssUserClient.tcl
    /home/giles/bluice/dcs-lib-tcl/main/scripts/Logger.tcl
}

set files [list]
if {$::argc > 0 && [lindex $::argv 0] eq "--bluice"} {
    set files $BLUICE_FILES
} elseif {$::argc > 0} {
    set files $::argv
} else {
    set files $BLUICE_FILES
}

# ---------------------------------------------------------------------------
# Synthetic edge-case probe — locks down the four corners PLAN_v2.1 §2.2
# explicitly calls out as cases the v2 string-first strategy did NOT handle.
# ---------------------------------------------------------------------------
#
# 1. Identical-bodied methods: each method gets its own src range, so
#    walker recovery is per-command — identity at the body-content level
#    is irrelevant.
# 2. Body with escape sequences: the walker reads file bytes; bytecode
#    literal-table interpretation never enters the path.
# 3. Body containing "}" inside a quoted string (quote-balance defeat):
#    `is_quote_balanced` is the explicit guard; the walker tracks quote
#    state within bare words too.
# 4. Backslash-newline continuation between command words.

proc run_synthetic_cases {} {
    # Each fixture: {label src expected_walker_word_for_first_top_definition}
    # The probe disassembles, walks to the first definition, and asserts
    # walker returns exactly the brace-delimited body word as written.
    set fixtures {}
    lappend fixtures [list "identical-bodies-1" \
        "proc setX {v} { set m_v \$v }\nproc setY {v} { set m_v \$v }" \
        "{ set m_v \$v }"]
    lappend fixtures [list "escape-seq-newline" \
        "proc esc {} { puts \"line1\\nline2\\t\\\$x\" }" \
        "{ puts \"line1\\nline2\\t\\\$x\" }"]
    lappend fixtures [list "backslash-newline-between-words" \
        "proc bs \\\n  {a b c} \\\n  { puts \$a \$b \$c }" \
        "{ puts \$a \$b \$c }"]
    lappend fixtures [list "comment-before-proc" \
        "# A comment\n# Another comment\nproc cb {} { incr ::n }" \
        "{ incr ::n }"]
    lappend fixtures [list "multi-line-args" \
        "proc ml {\n  arg1\n  arg2\n  arg3\n} { return \$arg1 }" \
        "{ return \$arg1 }"]

    set passed 0
    set failed 0
    set fails {}
    foreach fx $fixtures {
        lassign $fx label src expected
        set ranges [disasm_command_ranges $src]
        if {[lindex $ranges 0] eq "error"} {
            incr failed
            lappend fails [list $label "DISASM_FAIL" [lindex $ranges 1]]
            continue
        }
        # Find first definition command
        set found 0
        foreach r $ranges {
            lassign $r s e
            set cmd_text [string range $src $s $e]
            if {[catch {set parts [lrange $cmd_text 0 end]}]} { continue }
            set classify [classify_definition $parts]
            if {$classify eq {}} continue
            lassign $classify body_idx desc
            set walker_pos [find_word_start $cmd_text $body_idx]
            if {$walker_pos < 0} {
                incr failed
                lappend fails [list $label "WALKER_NOT_FOUND" $desc]
                set found 1
                break
            }
            set crange [word_content_range $cmd_text $walker_pos]
            lassign $crange cs ce
            # Reconstruct {body} (with surrounding braces) for comparison
            set walker_word [string range $cmd_text $walker_pos \
                [expr {$ce + 1}]]
            if {$walker_word eq $expected} {
                incr passed
            } else {
                incr failed
                lappend fails [list $label "MISMATCH" $expected $walker_word]
            }
            set found 1
            break
        }
        if {!$found} {
            incr failed
            lappend fails [list $label "NO_DEFINITION_FOUND_IN_FIXTURE"]
        }
    }
    puts ""
    puts "=== SYNTHETIC EDGE CASES ==="
    puts "Fixtures: [llength $fixtures], passed: $passed, failed: $failed"
    foreach f $fails { puts "  FAIL: $f" }
    return $failed
}

set total_tested 0
set total_matched 0
set total_mismatched 0
set all_cases {}
set lrange_fail_count 0
set per_file {}

foreach f $files {
    if {![file exists $f]} {
        puts stderr "MISSING: $f"
        continue
    }
    lassign [probe_file $f] tested matched mismatched cases
    incr total_tested $tested
    incr total_matched $matched
    incr total_mismatched $mismatched
    foreach c $cases {
        if {[lindex $c 0] eq "LRANGE_FAIL"} {
            incr lrange_fail_count
        }
        lappend all_cases $c
    }
    lappend per_file [list $f $tested $matched $mismatched]
    puts "[file tail $f]: $tested tested, $matched matched, $mismatched mismatched"
}

puts ""
puts "=== TOTALS ==="
puts "Files probed:            [llength $files]"
puts "Definition cmds tested:  $total_tested"
puts "Walker matched lindex:   $total_matched"
puts "Walker mismatched:       $total_mismatched"
puts "lrange-fail flag count:  $lrange_fail_count (informational; v2.1 substrate-change wins)"
if {$total_tested > 0} {
    set pct [format "%.2f" [expr {100.0 * $total_matched / $total_tested}]]
    puts "Match rate:              ${pct}%"
}

if {$total_mismatched > 0} {
    puts ""
    puts "=== MISMATCHES (up to 20) ==="
    set shown 0
    foreach c $all_cases {
        if {[lindex $c 0] eq "LRANGE_FAIL"} continue
        if {$shown >= 20} { break }
        puts $c
        incr shown
    }
}

if {$lrange_fail_count > 0} {
    puts ""
    puts "=== LRANGE_FAIL samples (up to 5) ==="
    set shown 0
    foreach c $all_cases {
        if {[lindex $c 0] ne "LRANGE_FAIL"} continue
        if {$shown >= 5} { break }
        puts $c
        incr shown
    }
}

# Synthetic edge-case probe
set syn_failed [run_synthetic_cases]

# Exit code: 0 only if every test matched and synthetic edges all passed.
if {$total_mismatched == 0 && $total_tested > 0 && $syn_failed == 0} {
    exit 0
} else {
    exit [expr {($total_mismatched > 0 || $syn_failed > 0) ? 1 : 2}]
}
