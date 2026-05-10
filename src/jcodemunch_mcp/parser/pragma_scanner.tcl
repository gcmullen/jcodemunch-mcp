#!/usr/bin/env tclsh
#
# pragma_scanner.tcl — R31 pre-pass: extract JCM pragma comments + dynamic-body sites.
#
# Runs BEFORE the walker (::jcm::disasm::walker::walk) over the raw file
# source. Produces two result lists the bridge driver (T8) wires onto symbols:
#
#   pragmas       — list of {kind STRING line INT target_line INT}
#   dynamic_sites — list of {line INT}
#
# Pragma kinds: dynamic, export, ignore.
#
#   # JCM:dynamic resolves_to=foo   → kind=dynamic, extra={resolves_to foo}
#   # JCM:export                    → kind=export
#   # JCM:ignore                    → kind=ignore
#
# target_line is the next non-blank, non-comment line after the pragma comment.
# When no such line exists in the file, the pragma is dropped (bridge driver
# will log at logger.warning — logging lives in Python; we return no entry).
#
# Dynamic-body regex cross-validator: \bproc\s+\S+\s+\S+\s+\[ matches proc
# definitions whose body argument is a bracket expression (dynamic body). Each
# match is a candidate site the walker should also tag as unresolved_dispatches:
# dynamic_body. Disagreement between this list and the walker output is a bridge
# bug (§4.3 of dev-docs/verdicts/WALKER_CONTRACT_v2_2.md). The comparison and logger.warning live
# in the bridge driver; we provide the site list in a consumable shape.
#
# Phase-1 note: # JCM:ignore over a package require does NOT suppress the
# kind=import symbol — it adds pragma_ignore to unresolved_dispatches for
# visibility only. Suppression is a Phase-2 concern (Δ0.2 carried-forward).
#
# Output contract (consumed by bridge driver T8):
#   pragmas       list  — each element is a Tcl dict: kind line target_line
#                         plus optional extra key (dict, e.g. {resolves_to foo})
#   dynamic_sites list  — each element is a Tcl dict: line INT
#
# Standalone CLI (for testing):
#   tclsh pragma_scanner.tcl FILE.tcl
#   → prints "pragmas: N" then each pragma dict, then "dynamic_sites: M"

namespace eval ::jcm::pragma {

    # ── Regex patterns ────────────────────────────────────────────────────────

    # A pragma comment: optional leading whitespace, # JCM:KIND optional-args
    variable PRAGMA_RE {^[[:space:]]*#[[:space:]]*JCM:([A-Za-z_]+)(.*)}

    # Dynamic-body proc: proc NAME ARGS [  (bracket as body argument)
    # \m / \M are word-boundary anchors in Tcl's regexp.
    variable DYNAMIC_BODY_RE {\mproc\M\s+\S+\s+\S+\s+\[}

    # ── scan_file ─────────────────────────────────────────────────────────────

    proc scan_file {path} {
        # Read source; return empty results on read failure (bridge driver logs).
        if {[catch {
            set fh [open $path r]
            fconfigure $fh -encoding utf-8 -translation auto
            set src [read $fh]
            close $fh
        } err]} {
            return [list pragmas {} dynamic_sites {}]
        }

        set lines [split $src "\n"]
        set n [llength $lines]

        set pragmas {}
        set dynamic_sites {}

        for {set i 0} {$i < $n} {incr i} {
            set line_text [lindex $lines $i]
            set line_no [expr {$i + 1}]  ;# 1-based

            # ── pragma detection ─────────────────────────────────────────────
            variable PRAGMA_RE
            if {[regexp $PRAGMA_RE $line_text _ kind rest]} {
                set kind [string tolower [string trim $kind]]

                # Parse optional args (e.g. " resolves_to=foo")
                set extra {}
                set rest [string trim $rest]
                if {$rest ne ""} {
                    # key=value pairs separated by whitespace
                    foreach token [split $rest] {
                        if {[string match "*=*" $token]} {
                            lassign [split $token "="] k v
                            lappend extra [string trim $k] [string trim $v]
                        }
                    }
                }

                # Find target_line: next non-blank, non-comment line
                set target -1
                for {set j [expr {$i + 1}]} {$j < $n} {incr j} {
                    set candidate [string trim [lindex $lines $j]]
                    if {$candidate eq "" || [string match "#*" $candidate]} continue
                    set target [expr {$j + 1}]  ;# 1-based
                    break
                }

                # Drop orphan pragmas (no following statement) — bridge driver
                # would log warning; returning nothing is correct here.
                if {$target < 0} continue

                set entry [dict create kind $kind line $line_no target_line $target]
                if {[llength $extra] > 0} {
                    dict set entry extra $extra
                }
                lappend pragmas $entry
            }

            # ── dynamic-body detection ────────────────────────────────────────
            variable DYNAMIC_BODY_RE
            if {[regexp $DYNAMIC_BODY_RE $line_text]} {
                lappend dynamic_sites [dict create line $line_no]
            }
        }

        return [list pragmas $pragmas dynamic_sites $dynamic_sites]
    }

} ;# namespace ::jcm::pragma


# ── Standalone CLI ─────────────────────────────────────────────────────────────
if {[info script] eq $argv0} {
    if {[llength $argv] < 1} {
        puts stderr "Usage: tclsh pragma_scanner.tcl FILE.tcl"
        exit 1
    }
    set result [::jcm::pragma::scan_file [lindex $argv 0]]
    set pragmas      [dict get $result pragmas]
    set dyn_sites    [dict get $result dynamic_sites]
    puts "pragmas: [llength $pragmas]"
    foreach p $pragmas { puts "  $p" }
    puts "dynamic_sites: [llength $dyn_sites]"
    foreach d $dyn_sites { puts "  $d" }
}
