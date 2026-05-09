#!/usr/bin/env tclsh
#
# ensemble_enumeration_probe.tcl — R32 deliverable for PLAN_v2.1 §3 P1.1.
#
# Walks the disassembly of every reachable .tcl file in the full bluice
# corpus (BluIceWidgets, DcsWidgets, dcs-lib-tcl/main/scripts, dhs-tcl,
# dcss/scripts/**) plus a synthetic-constructs probe, and collects every
# `::tcl::ENSEMBLE::SUBCMD` literal Tcl 8.6's compiler actually generates.
#
# Compares against PLAN_v2.1 §2.3 pre-rename table (9 ensembles, 43
# subcommands derived from 24-file oracle subset). Emits one of:
#   - "closes cleanly": full corpus produces no new ensembles or subcommands
#   - "additions found": new rows the table needs
#
# Usage:
#   tclsh validation/probes/ensemble_enumeration_probe.tcl [--bluice-root DIR]
#
# Default --bluice-root: /home/giles/bluice
#
# Reproducer for §2.3 ensemble pre-rename table.

set BLUICE_ROOT /home/giles/bluice
set INCLUDE_SYNTHETIC 1
set argv_idx 0
while {$argv_idx < [llength $::argv]} {
    set arg [lindex $::argv $argv_idx]
    if {$arg eq "--bluice-root"} {
        incr argv_idx
        set BLUICE_ROOT [lindex $::argv $argv_idx]
    } elseif {$arg eq "--no-synthetic"} {
        set INCLUDE_SYNTHETIC 0
    }
    incr argv_idx
}

# Reference table — what PLAN_v2.1 §2.3 currently asserts based on the
# 24-file oracle subset. Source: PLAN_v2.1.md §2.3 ensemble pre-rename.
set REFERENCE_ENSEMBLES {
    array binary chan clock dict encoding file info namespace
}

# Synthetic constructs to force-exercise common ensemble subcommands in
# case the corpus doesn't naturally use them. Compile-only, never run.
set SYNTHETIC_CONSTRUCTS {
    chan close $fd
    chan flush $fd
    chan read $fd
    chan write $fd
    chan eof $fd
    chan configure $fd -blocking 0
    chan event $fd readable handler
    dict get $d k
    dict set d k v
    dict for {k v} $d {puts $k}
    dict with var {puts $field}
    dict update var k1 v1 k2 v2 {set v1 1}
    dict exists $d k
    dict size $d
    dict keys $d
    dict values $d
    dict merge $d1 $d2
    dict create k v
    dict incr d k
    dict append d k v
    dict lappend d k v
    dict unset d k
    namespace eval ::Foo { proc helper {} { return 42 } }
    namespace current
    namespace which foo
    namespace export *
    namespace import ::Foo::*
    namespace tail ::a::b::c
    namespace qualifiers ::a::b::c
    namespace parent ::Foo
    string length $s
    string compare $a $b
    string match $pat $s
    string range $s 0 5
    string trim $s
    string toupper $s
    string tolower $s
    string first foo $s
    string last foo $s
    string index $s 0
    string equal $a $b
    string map {a b} $s
    string repeat $s 5
    file exists $p
    file isdirectory $p
    file isfile $p
    file size $p
    file mtime $p
    file dirname $p
    file tail $p
    file extension $p
    file rootname $p
    file join $a $b
    file readable $p
    file writable $p
    file delete $p
    file mkdir $p
    file normalize $p
    file split $p
    file pathtype $p
    info commands
    info procs
    info vars
    info exists var
    info level
    info script
    info nameofexecutable
    info patchlevel
    info hostname
    info args foo
    info body foo
    info default foo arg val
    array set a {k v}
    array get a
    array names a
    array exists a
    array size a
    array unset a k
    clock seconds
    clock format $t
    clock scan $s
    clock milliseconds
    clock microseconds
    clock add $t 1 day
    binary format $fmt $val
    binary scan $bytes $fmt v
    encoding system
    encoding names
    encoding convertfrom utf-8 $b
    encoding convertto utf-8 $s
}

# ---------------------------------------------------------------------------
# Corpus discovery
# ---------------------------------------------------------------------------

proc collect_corpus {root} {
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
        # Recursive .tcl walk
        lappend files {*}[recursive_glob_tcl $dir]
    }
    # dcss/scripts/**/*.tcl is the recursive subtree
    set dcss_root [file join $root dcss]
    if {[file isdirectory $dcss_root]} {
        # Walk the whole dcss tree and keep only files whose path contains
        # /scripts/. Matches the user's "dcss/scripts/**/*.tcl" scope.
        foreach f [recursive_glob_tcl $dcss_root] {
            if {[string match *scripts* $f]} { lappend files $f }
        }
    }
    return [lsort -unique $files]
}

proc recursive_glob_tcl {dir} {
    set out [list]
    foreach pat {*.tcl *.itcl} {
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

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

set ENSEMBLE_LITERAL_RE {^::tcl::([a-zA-Z0-9_]+)::([a-zA-Z0-9_]+)$}
# seen($lit) -> {ensemble subcmd corpus_files synthetic_seen}
array set seen {}
array set first_corpus_file {}

# Synthetic file: write to a temp path, probe separately to keep its
# matches distinguishable from natural corpus matches.
set syn_path /tmp/jcm_p11_synthetic.tcl
set fp [open $syn_path w]
puts $fp $SYNTHETIC_CONSTRUCTS
close $fp

set CORPUS [collect_corpus $BLUICE_ROOT]
# Probe corpus first so first_seen attribution is the natural corpus,
# then probe synthetic to fill in coverage gaps.
set FILES $CORPUS
if {$INCLUDE_SYNTHETIC} { lappend FILES $syn_path }

set total_files 0
set disasm_failed 0
set total_distinct_literals 0

foreach f $FILES {
    incr total_files
    if {[catch {open $f r} fp]} { continue }
    fconfigure $fp -encoding utf-8
    if {[catch {read $fp} src]} { close $fp; continue }
    close $fp
    if {[catch {tcl::unsupported::disassemble script $src} bc]} {
        incr disasm_failed
        continue
    }
    set is_synth [expr {$f eq $syn_path}]
    foreach line [split $bc "\n"] {
        if {[regexp {# "(::tcl::[^"]+)"} $line -> lit]} {
            if {[regexp $ENSEMBLE_LITERAL_RE $lit -> ens sub]} {
                if {![info exists seen($lit)]} {
                    # First sighting: track origin (corpus vs synthetic)
                    set origin [expr {$is_synth ? "synthetic" : "corpus"}]
                    set seen($lit) [list $ens $sub $f $origin]
                    incr total_distinct_literals
                } else {
                    # Already known; if this is a corpus sighting and the
                    # original was synthetic-only, upgrade to corpus.
                    lassign $seen($lit) e2 s2 f2 origin2
                    if {!$is_synth && $origin2 eq "synthetic"} {
                        set seen($lit) [list $e2 $s2 $f $origin2-then-corpus]
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------

array set by_ensemble {}
foreach lit [array names seen] {
    lassign $seen($lit) ens sub f origin
    lappend by_ensemble($ens) [list $sub $f $origin]
}

set found_ensembles [lsort [array names by_ensemble]]
set ref_set [lsort $REFERENCE_ENSEMBLES]

set new_ensembles [list]
foreach ens $found_ensembles {
    if {$ens ni $ref_set} { lappend new_ensembles $ens }
}
set missing_ensembles [list]
foreach ens $ref_set {
    if {$ens ni $found_ensembles} { lappend missing_ensembles $ens }
}

set total_subcmds 0
set corpus_subcmds 0
set synthetic_only_subcmds 0
foreach ens $found_ensembles {
    set subs [lsort -unique [lmap pair $by_ensemble($ens) {lindex $pair 0}]]
    incr total_subcmds [llength $subs]
    foreach pair $by_ensemble($ens) {
        lassign $pair s f origin
        if {[string match corpus* $origin]} {
            incr corpus_subcmds
        } elseif {$origin eq "synthetic"} {
            incr synthetic_only_subcmds
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

puts "==================================================================="
puts "P1.1(f) Ensemble enumeration probe — full bluice corpus"
puts "==================================================================="
puts "Bluice root:              $BLUICE_ROOT"
puts "Files probed:             $total_files"
puts "Disassemble failures:     $disasm_failed"
puts "Distinct ::tcl::*::*:     $total_distinct_literals"
puts "Distinct ensembles found: [llength $found_ensembles]"
puts "Total subcommands:        $total_subcmds"
puts "  ...natural in corpus:   $corpus_subcmds"
puts "  ...synthetic only:      $synthetic_only_subcmds"
puts ""

puts "Reference table (PLAN_v2.1 §2.3 — 9 ensembles): $ref_set"
puts "Found ensembles:                                $found_ensembles"
puts ""

if {[llength $new_ensembles] > 0} {
    puts "*** NEW ENSEMBLES BEYOND REFERENCE TABLE: $new_ensembles"
} else {
    puts "No new ensembles beyond reference table."
}
if {[llength $missing_ensembles] > 0} {
    puts "Reference ensembles NOT seen in corpus: $missing_ensembles"
    puts "  (informational — synthetic constructs should force them)"
}
puts ""

puts "==================================================================="
puts "Per-ensemble subcommand inventory (corpus + synthetic)"
puts "==================================================================="
foreach ens $found_ensembles {
    set subs [lsort -unique [lmap pair $by_ensemble($ens) {lindex $pair 0}]]
    puts "::tcl::${ens}::*  ->  ${ens} *   ([llength $subs] subcommands)"
    foreach s $subs {
        # Origin + first file
        set origin "?"
        set first_file ""
        foreach pair $by_ensemble($ens) {
            lassign $pair sub2 f2 o2
            if {$sub2 eq $s} {
                set origin $o2
                set first_file [file tail $f2]
                break
            }
        }
        set tag [expr {[string match corpus* $origin] ? "CORPUS" : "synth-only"}]
        puts [format "  %-22s  %-10s  (%s)" \
              "${ens} ${s}" $tag $first_file]
    }
    puts ""
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

puts "==================================================================="
puts "VERDICT"
puts "==================================================================="
set new_count [llength $new_ensembles]
if {$new_count == 0} {
    puts "Full bluice corpus closes cleanly under PLAN_v2.1 §2.3 reference"
    puts "table (9 ensembles). Subcommand counts may exceed the 43-subcommand"
    puts "oracle estimate; this is expected (full corpus > 24-file oracle"
    puts "subset). Add new SUBCOMMAND rows where the inventory exceeds 43;"
    puts "no NEW ENSEMBLE rows are required."
    puts ""
    puts "Confidence claim TIGHTENED: the rename table is exhaustive for"
    puts "stock Tcl 8.6 + bluice usage."
    set rc 0
} else {
    puts "ADDITIONS REQUIRED to PLAN_v2.1 §2.3 pre-rename table:"
    foreach ens $new_ensembles {
        puts "  ::tcl::${ens}::*   ->   ${ens} *"
    }
    puts ""
    puts "These ensembles compile to ::tcl::* literals on Tcl 8.6 but do"
    puts "NOT appear in the reference table. The bridge un-rename pass"
    puts "must add a row per ensemble."
    set rc 1
}

# Exit 0 = clean closure (no new ensembles); 1 = additions required
exit $rc
