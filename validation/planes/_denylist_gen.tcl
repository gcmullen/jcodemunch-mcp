#!/usr/bin/env tclsh
#
# _denylist_gen.tcl — generate position-validator command denylist
#
# Per PLAN_v2.1_P1_4 §5 #8: emit the union of `info commands` after loading
# Tcl 8.6.14 + iTcl 3.4 + iTk + BWidget + iWidgets, in lsort order, one per
# line on stdout. Used by Day 1+ position validator to distinguish "known
# command word" from "user proc / unknown token".
#
# Requires DISPLAY (Tk auto-loads when Itk requires it). Invoke via:
#     xvfb-run -a tclsh validation/planes/_denylist_gen.tcl
#
# Explicit `exit 0` at end avoids the Tk-event-loop hang we hit on the
# preliminary version probe.

set ::auto_path [linsert $::auto_path 0 \
    /home/giles/git/tcl-corpus/iWidgets \
    /home/giles/git/tcl-corpus/BWidget \
    /home/giles/git/tcl-corpus/tklib \
    /home/giles/git/tcl-corpus/tcllib \
]

# Capture baseline (after Tcl boot, before any extension package loads)
set initial [info commands]
set initial_count [llength $initial]

# Load extension packages in order. Use catch to keep going if any fails.
# Package names are CASE-SENSITIVE in Tcl: `Iwidgets` not `iwidgets`.
set loaded {}
set failed {}
foreach pkg {Itcl Tk Itk Iwidgets BWidget} {
    if {[catch {package require $pkg} ver]} {
        lappend failed "$pkg:$ver"
    } else {
        lappend loaded "$pkg:$ver"
    }
}

# Emit final union to stdout, one command per line, lsort -dictionary for
# stable diff. Manifest (loaded/failed/counts) goes to a sibling .manifest
# file passed as argv[0]; we cannot use stderr because xvfb-run merges
# streams under some configurations.
set commands [lsort -dictionary [info commands]]
foreach c $commands {
    puts $c
}

# Manifest target: argv[0] or "denylist_tcl_8.6.14.manifest" beside us.
set manifest_path [file join [file dirname [info script]] \
    denylist_tcl_8.6.14.manifest]
if {[llength $::argv] > 0} {
    set manifest_path [lindex $::argv 0]
}
set fh [open $manifest_path w]
puts $fh "tcl_patchLevel=$::tcl_patchLevel"
puts $fh "initial_count=$initial_count"
puts $fh "final_count=[llength $commands]"
puts $fh "loaded=$loaded"
puts $fh "failed=$failed"
close $fh

exit 0
