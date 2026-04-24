#!/usr/bin/env tclsh
# tcl_parser_bridge.tcl — Native TCL parser for jCodeMunch
#
# Uses TCL's own interpreter for 100% accurate parsing of TCL source files.
# Called by _parse_tcl_native() in extractor.py via:
#   tclsh tcl_parser_bridge.tcl <filepath>
#
# Output: JSON array of symbol objects on stdout.
# Errors/warnings go to stderr (non-fatal; Python wrapper handles gracefully).

package require Tcl 8.5

# ---------------------------------------------------------------------------
# JSON encoding helpers (no external deps — pure Tcl)
# ---------------------------------------------------------------------------

proc json_escape {s} {
    set s [string map {
        \\ \\\\
        \" \\\"
        \n \\n
        \r \\r
        \t \\t
        \x08 \\b
        \x0c \\f
    } $s]
    return $s
}

proc json_string {s} {
    return "\"[json_escape $s]\""
}

proc json_int {n} {
    if {![string is integer -strict $n]} { return "0" }
    return $n
}

proc json_list {items} {
    return "\[[join $items ", "]\]"
}

proc json_string_list {items} {
    set out {}
    foreach item $items {
        lappend out [json_string $item]
    }
    return [json_list $out]
}

proc json_object {pairs} {
    set parts {}
    foreach {key value} $pairs {
        lappend parts "[json_string $key]: $value"
    }
    return "\{[join $parts ", "]\}"
}

# ---------------------------------------------------------------------------
# Source reading and line/byte offset mapping
# ---------------------------------------------------------------------------

proc read_source {filepath} {
    set fd [open $filepath r]
    fconfigure $fd -encoding utf-8
    set content [read $fd]
    close $fd
    return $content
}

# Build a char-index-to-byte-offset map.
# Returns a list where index i = cumulative UTF-8 byte offset of character i.
# Entry [llength] = total byte count (for end-of-file).
proc build_char_to_byte {content} {
    set map {}
    set byte_pos 0
    set len [string length $content]
    for {set i 0} {$i < $len} {incr i} {
        lappend map $byte_pos
        set ch [string index $content $i]
        set byte_len [string length [encoding convertto utf-8 $ch]]
        incr byte_pos $byte_len
    }
    lappend map $byte_pos
    return $map
}

# Build a list mapping line number (0-indexed) to char offset of that line start.
proc build_line_offsets {content} {
    set offsets [list 0]
    set len [string length $content]
    for {set i 0} {$i < $len} {incr i} {
        if {[string index $content $i] eq "\n"} {
            lappend offsets [expr {$i + 1}]
        }
    }
    return $offsets
}

# Convert a character index to line number (0-indexed).
proc char_to_line {line_offsets char_idx} {
    set lo 0
    set hi [expr {[llength $line_offsets] - 1}]
    while {$lo < $hi} {
        set mid [expr {($lo + $hi + 1) / 2}]
        if {[lindex $line_offsets $mid] <= $char_idx} {
            set lo $mid
        } else {
            set hi [expr {$mid - 1}]
        }
    }
    return $lo
}

# Look up byte offset for a character index using the char-to-byte map.
proc char_to_byte {char_to_byte_map char_idx} {
    return [lindex $char_to_byte_map $char_idx]
}

# ---------------------------------------------------------------------------
# Command splitting using `info complete`
# ---------------------------------------------------------------------------

# Split a complete command chunk on unquoted top-level semicolons.
# Returns a list of sub-command strings. Respects brace and quote nesting.
proc split_on_semicolons {cmd_text} {
    set results {}
    set buf ""
    set brace_depth 0
    set in_quotes 0
    set len [string length $cmd_text]

    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $cmd_text $i]

        if {$ch eq "\\" && $i + 1 < $len} {
            # Escaped character — consume both
            append buf $ch
            incr i
            append buf [string index $cmd_text $i]
            continue
        }

        if {$in_quotes} {
            append buf $ch
            if {$ch eq "\""} { set in_quotes 0 }
            continue
        }

        if {$ch eq "\""} {
            set in_quotes 1
            append buf $ch
            continue
        }

        if {$ch eq "\{"} {
            incr brace_depth
            append buf $ch
            continue
        }

        if {$ch eq "\}"} {
            incr brace_depth -1
            append buf $ch
            continue
        }

        if {$ch eq ";" && $brace_depth == 0} {
            set trimmed [string trim $buf]
            if {$trimmed ne ""} {
                lappend results $trimmed
            }
            set buf ""
            continue
        }

        append buf $ch
    }

    set trimmed [string trim $buf]
    if {$trimmed ne ""} {
        lappend results $trimmed
    }
    return $results
}

# Split source into top-level commands, tracking their character offsets.
# Returns a list of {command_text start_char_idx end_char_idx}.
# Uses `info complete` for command boundary detection, then splits on
# top-level semicolons to handle `proc foo {} {}; proc bar {} {}`.
proc split_commands {content} {
    set commands {}
    set len [string length $content]
    set start 0
    set buf ""

    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $content $i]
        append buf $ch

        # Skip full-line comments as standalone commands
        set trimmed [string trimleft $buf]
        if {$trimmed eq "" || ($ch eq "\n" && [string index $trimmed 0] eq "#")} {
            if {$trimmed ne ""} {
                lappend commands [list $buf $start $i]
            }
            set start [expr {$i + 1}]
            set buf ""
            continue
        }

        # Check if the buffer forms a complete command
        if {$ch eq "\n" && [info complete $buf]} {
            set trimcmd [string trim $buf]
            if {$trimcmd ne ""} {
                # Split on top-level semicolons
                set subcmds [split_on_semicolons $trimcmd]
                if {[llength $subcmds] <= 1} {
                    # Common case: no semicolons, emit as-is with exact offsets
                    lappend commands [list $trimcmd $start $i]
                } else {
                    # Multiple commands joined by semicolons.
                    # Approximate sub-offsets by scanning for each subcmd in the buffer.
                    set search_from $start
                    foreach subcmd $subcmds {
                        set sub_pos [string first $subcmd $content $search_from]
                        if {$sub_pos >= 0} {
                            set sub_end [expr {$sub_pos + [string length $subcmd] - 1}]
                            lappend commands [list $subcmd $sub_pos $sub_end]
                            set search_from [expr {$sub_end + 1}]
                        } else {
                            # Fallback: use chunk boundaries
                            lappend commands [list $subcmd $start $i]
                        }
                    }
                }
            }
            set start [expr {$i + 1}]
            set buf ""
        }
    }

    # Handle trailing content (no final newline)
    set trimcmd [string trim $buf]
    if {$trimcmd ne ""} {
        set subcmds [split_on_semicolons $trimcmd]
        if {[llength $subcmds] <= 1} {
            lappend commands [list $trimcmd $start [expr {$len - 1}]]
        } else {
            set search_from $start
            foreach subcmd $subcmds {
                set sub_pos [string first $subcmd $content $search_from]
                if {$sub_pos >= 0} {
                    set sub_end [expr {$sub_pos + [string length $subcmd] - 1}]
                    lappend commands [list $subcmd $sub_pos $sub_end]
                    set search_from [expr {$sub_end + 1}]
                } else {
                    lappend commands [list $subcmd $start [expr {$len - 1}]]
                }
            }
        }
    }

    return $commands
}

# ---------------------------------------------------------------------------
# Complexity analysis
# ---------------------------------------------------------------------------

# Count cyclomatic complexity branches in a TCL body.
proc count_cyclomatic {body} {
    set complexity 1
    # Count branching keywords
    foreach kw {if elseif while for foreach switch catch try} {
        # Match keyword at word boundary (preceded by whitespace/newline/brace or start)
        set count [llength [regexp -all -inline "(?:^|\\s)$kw\\s" $body]]
        incr complexity $count
    }
    # Count boolean operators (short-circuit branches)
    incr complexity [llength [regexp -all -inline {&&|\|\|} $body]]
    return $complexity
}

# Count maximum brace nesting depth in a body.
proc count_max_nesting {body} {
    set max_depth 0
    set depth 0
    set len [string length $body]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $body $i]
        if {$ch eq "\{"} {
            incr depth
            if {$depth > $max_depth} { set max_depth $depth }
        } elseif {$ch eq "\}"} {
            incr depth -1
        }
    }
    return $max_depth
}

# Count parameters in a TCL argument list string.
proc count_params {args_str} {
    set trimmed [string trim $args_str "{}"]
    if {$trimmed eq ""} { return 0 }
    # Split on whitespace, but respect braces for default values
    set count 0
    set depth 0
    set in_param 0
    set len [string length $trimmed]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $trimmed $i]
        if {$ch eq "\{"} {
            incr depth
            set in_param 1
        } elseif {$ch eq "\}"} {
            incr depth -1
        } elseif {$depth == 0 && ($ch eq " " || $ch eq "\t" || $ch eq "\n")} {
            if {$in_param} {
                incr count
                set in_param 0
            }
        } else {
            set in_param 1
        }
    }
    if {$in_param} { incr count }
    return $count
}

# ---------------------------------------------------------------------------
# Call reference extraction
# ---------------------------------------------------------------------------

# Extract called proc/command names from a body.
proc extract_calls {body} {
    set calls {}
    set seen [dict create]

    # Pattern: namespace-qualified calls like ::foo::bar or foo::bar
    foreach {match sub} [regexp -all -inline {(?:^|[\s\[;])(:?:[\w:]+)} $body] {
        set call [string trim $sub]
        if {$call ne "" && ![dict exists $seen $call]} {
            dict set seen $call 1
            lappend calls $call
        }
    }

    # Pattern: simple command calls at start of line or after [ or ;
    foreach {match sub} [regexp -all -inline {(?:^|[\[;\n])\s*([a-zA-Z_][\w]*)} $body] {
        set call [string trim $sub]
        # Skip TCL builtins and control flow keywords
        if {$call in {proc namespace set if else elseif while for foreach switch
                       return break continue catch try throw finally
                       expr string list lindex lappend llength lrange lsearch
                       lsort dict array info puts gets open close read
                       variable global upvar uplevel eval source package
                       after vwait update error rename unset append incr
                       format scan regexp regsub split join concat
                       file glob cd pwd exec pid}} {
            continue
        }
        if {$call ne "" && ![dict exists $seen $call]} {
            dict set seen $call 1
            lappend calls $call
        }
    }

    return $calls
}

# ---------------------------------------------------------------------------
# Annotation / spaghetti detection
# ---------------------------------------------------------------------------

# Detect spaghetti-indicating patterns in a proc body.
proc detect_annotations {body} {
    set annotations {}

    # uplevel — executes code in caller's stack frame
    if {[regexp {(?:^|[\s\[\{;])uplevel\s} $body]} {
        lappend annotations "uplevel"
    }

    # upvar — aliases variables from caller's frame
    if {[regexp {(?:^|[\s\[\{;])upvar\s} $body]} {
        lappend annotations "upvar"
    }

    # global variable access
    if {[regexp {(?:^|[\s\[\{;])global\s} $body]} {
        lappend annotations "global_access"
    }

    # Dynamic command construction via eval
    if {[regexp {(?:^|[\s\[\{;])eval\s} $body]} {
        lappend annotations "dynamic_eval"
    }

    # Variable command dispatch ($cmd or [set cmd] patterns)
    if {[regexp {\$\w+\s} $body] && [regexp {(?:^|[\s\[;])\$\w+\s} $body]} {
        # More specific: variable used as command name
        if {[regexp {(?:^|[\[;\n])\s*\$\w+} $body]} {
            lappend annotations "dynamic_dispatch"
        }
    }

    # Variable traces
    if {[regexp {(?:^|[\s\[\{;])trace\s+add\s+variable} $body]} {
        lappend annotations "variable_trace"
    }

    # Coroutine usage
    if {[regexp {(?:^|[\s\[\{;])coroutine\s} $body]} {
        lappend annotations "coroutine"
    }

    # rename — can redefine built-in commands
    if {[regexp {(?:^|[\s\[\{;])rename\s} $body]} {
        lappend annotations "command_rename"
    }

    # interp — nested interpreter manipulation
    if {[regexp {(?:^|[\s\[\{;])interp\s} $body]} {
        lappend annotations "interp_manipulation"
    }

    return $annotations
}

# ---------------------------------------------------------------------------
# Docstring extraction
# ---------------------------------------------------------------------------

# Collect preceding comment lines as docstring.
# comments_before is a list of comment line strings.
proc collect_docstring {comments_before} {
    if {[llength $comments_before] == 0} { return "" }
    set lines {}
    foreach line $comments_before {
        # Strip leading # and whitespace
        set stripped [string trimleft $line "# "]
        lappend lines $stripped
    }
    return [join $lines "\n"]
}

# ---------------------------------------------------------------------------
# Main parser: extract symbols from command list
# ---------------------------------------------------------------------------

# Global state
variable symbols {}

# Helper: emit a symbol JSON object with correct byte offsets.
# start_char/end_char are character indices; char_to_byte_map translates them.
proc emit_symbol {name qualified kind sig docstring start_char end_char
                  line_offsets char_byte_map parent cyclomatic max_nesting
                  param_count calls annotations keywords} {
    variable symbols

    set start_line [expr {[char_to_line $line_offsets $start_char] + 1}]
    set end_line   [expr {[char_to_line $line_offsets $end_char] + 1}]
    set byte_off   [char_to_byte $char_byte_map $start_char]
    # end_char is inclusive, so byte_length = byte(end_char+1) - byte(start_char)
    set byte_end   [char_to_byte $char_byte_map [expr {$end_char + 1}]]
    set byte_len   [expr {$byte_end - $byte_off}]

    if {[string length $sig] > 120} {
        set sig [string range $sig 0 116]...
    }

    set sym [json_object [list \
        name          [json_string $name] \
        qualified_name [json_string $qualified] \
        kind          [json_string $kind] \
        signature     [json_string $sig] \
        docstring     [json_string $docstring] \
        line          [json_int $start_line] \
        end_line      [json_int $end_line] \
        byte_offset   [json_int $byte_off] \
        byte_length   [json_int $byte_len] \
        parent        [json_string $parent] \
        cyclomatic    [json_int $cyclomatic] \
        max_nesting   [json_int $max_nesting] \
        param_count   [json_int $param_count] \
        call_references [json_string_list $calls] \
        decorators    [json_string_list $annotations] \
        keywords      [json_string_list $keywords] \
    ]]

    lappend symbols $sym
}

proc parse_proc {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Parse: proc name args body
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return
    }
    if {[llength $parts] < 4} { return }
    if {[lindex $parts 0] ne "proc"} { return }
    set name [lindex $parts 1]
    set args_str [lindex $parts 2]
    set body [lindex $parts 3]

    # Compute qualified name
    if {[string match "::*" $name]} {
        set qualified $name
    } elseif {$scope ne ""} {
        set qualified "${scope}::${name}"
    } else {
        set qualified $name
    }

    set short_name [namespace tail $name]
    if {$short_name eq ""} { set short_name $name }

    set sig "proc $qualified \{$args_str\}"
    set annotations [detect_annotations $body]
    set keywords $annotations
    if {[regexp {(?:^|[\s\[;])package\s+require} $body]} {
        lappend keywords "package_require"
    }

    emit_symbol $short_name $qualified "function" $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        [count_cyclomatic $body] [count_max_nesting $body] \
        [count_params $args_str] [extract_calls $body] \
        $annotations $keywords

    # Recursively parse nested procs in the body
    parse_body $body $start_char $line_offsets $char_byte_map $qualified
}

proc parse_namespace_eval {cmd_text start_char end_char line_offsets char_byte_map scope} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return
    }
    if {[llength $parts] < 4} { return }
    if {[lindex $parts 0] ne "namespace" || [lindex $parts 1] ne "eval"} { return }

    set ns_name [lindex $parts 2]
    set body [lindex $parts 3]

    if {[string match "::*" $ns_name]} {
        set qualified $ns_name
    } elseif {$scope ne ""} {
        set qualified "${scope}::${ns_name}"
    } else {
        set qualified $ns_name
    }

    # Detect namespace exports (public API)
    set exports {}
    foreach line [split $body "\n"] {
        set trimline [string trim $line]
        if {[regexp {^namespace\s+export\s+(?:-clear\s+)?(.*)} $trimline -> exp_names]} {
            foreach token [split $exp_names] {
                set t [string trim $token]
                if {$t ne "" && $t ne "-clear" && [regexp {^\w+$} $t]} {
                    lappend exports $t
                }
            }
        }
    }

    set keywords {}
    if {[llength $exports] > 0} {
        lappend keywords "has_exports"
    }

    emit_symbol [namespace tail $ns_name] $qualified "class" \
        "namespace eval $qualified" "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} $exports $keywords

    parse_body $body $start_char $line_offsets $char_byte_map $qualified
}

proc parse_oo_class {cmd_text start_char end_char line_offsets char_byte_map scope} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return
    }
    if {[llength $parts] < 4} { return }
    set class_cmd [lindex $parts 0]
    set create [lindex $parts 1]
    set class_name [lindex $parts 2]
    set body [lindex $parts 3]

    if {$create ne "create"} { return }

    if {$scope ne ""} {
        set qualified "${scope}::${class_name}"
    } else {
        set qualified $class_name
    }

    emit_symbol $class_name $qualified "class" \
        "$class_cmd create $class_name" "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list "oo_class"]

    parse_oo_body $body $start_char $line_offsets $char_byte_map $qualified
}

proc parse_custom_class {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Handles custom class DSLs: class <name> { body }
    # Common pattern in pre-TclOO codebases (e.g., git-gui).
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return
    }
    if {[llength $parts] < 3} { return }
    if {[lindex $parts 0] ne "class"} { return }

    set class_name [lindex $parts 1]
    set body [lindex $parts 2]

    if {$scope ne ""} {
        set qualified "${scope}::${class_name}"
    } else {
        set qualified $class_name
    }

    emit_symbol $class_name $qualified "class" \
        "class $class_name" "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list "custom_class"]

    parse_class_body $body $start_char $line_offsets $char_byte_map $qualified
}

proc parse_class_body {body base_offset line_offsets char_byte_map scope} {
    # Parses class bodies for both TclOO (oo::class create) and custom DSLs
    # (git-gui style `class name { ... }`). Recognizes:
    #   method name params body
    #   constructor name params body  (custom DSL: 4 args)
    #   constructor params body       (TclOO: 3 args)
    #   destructor body
    #   field name ?default?
    #   proc name args body           (nested procs inside class)
    set cmds [split_commands $body]
    foreach cmd_entry $cmds {
        set cmd_text [lindex $cmd_entry 0]
        set rel_start [lindex $cmd_entry 1]
        set rel_end [lindex $cmd_entry 2]
        set abs_start [expr {$base_offset + $rel_start}]
        set abs_end [expr {$base_offset + $rel_end}]

        set trimmed [string trim $cmd_text]
        if {$trimmed eq "" || [string index $trimmed 0] eq "#"} { continue }

        if {[catch {set parts [lrange $trimmed 0 end]}]} { continue }
        if {[llength $parts] < 1} { continue }

        set kw [lindex $parts 0]

        if {$kw eq "method" && [llength $parts] >= 4} {
            set method_name [lindex $parts 1]
            set args_str [lindex $parts 2]
            set method_body [lindex $parts 3]

            emit_symbol $method_name "${scope}::${method_name}" "method" \
                "method $method_name \{$args_str\}" "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                [count_cyclomatic $method_body] [count_max_nesting $method_body] \
                [count_params $args_str] [extract_calls $method_body] \
                [detect_annotations $method_body] [list "method"]

        } elseif {$kw eq "constructor"} {
            # Custom DSL: constructor name params body (4 args after kw)
            # TclOO:      constructor params body      (3 args after kw: no name)
            if {[llength $parts] >= 5} {
                # Custom DSL: constructor name params body
                set con_name [lindex $parts 1]
                set args_str [lindex $parts 2]
                set con_body [lindex $parts 3]
                emit_symbol $con_name "${scope}::${con_name}" "method" \
                    "constructor $con_name \{$args_str\}" "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    [count_cyclomatic $con_body] [count_max_nesting $con_body] \
                    [count_params $args_str] [extract_calls $con_body] \
                    [detect_annotations $con_body] [list "constructor"]
            } elseif {[llength $parts] >= 3} {
                # TclOO: constructor params body
                set args_str [lindex $parts 1]
                set con_body [lindex $parts 2]
                emit_symbol "constructor" "${scope}::constructor" "method" \
                    "constructor \{$args_str\}" "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    [count_cyclomatic $con_body] [count_max_nesting $con_body] \
                    [count_params $args_str] [extract_calls $con_body] \
                    [detect_annotations $con_body] [list "constructor"]
            }

        } elseif {$kw eq "destructor" && [llength $parts] >= 2} {
            set dest_body [lindex $parts 1]

            emit_symbol "destructor" "${scope}::destructor" "method" \
                "destructor" "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                [count_cyclomatic $dest_body] [count_max_nesting $dest_body] \
                0 [extract_calls $dest_body] \
                [detect_annotations $dest_body] [list "destructor"]

        } elseif {$kw eq "field" && [llength $parts] >= 2} {
            set field_name [lindex $parts 1]
            # Strip trailing semicolons (field name ; # comment)
            set field_name [string trimright $field_name ";"]

            emit_symbol $field_name "${scope}::${field_name}" "constant" \
                "field $field_name" "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                0 0 0 {} {} [list "field"]

        } elseif {$kw eq "proc" && [llength $parts] >= 4} {
            parse_proc $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
        }
    }
}

# Legacy alias for TclOO — both paths now use the unified class body parser.
proc parse_oo_body {body base_offset line_offsets char_byte_map scope} {
    parse_class_body $body $base_offset $line_offsets $char_byte_map $scope
}

# Parse a body string for nested procs and namespace evals.
proc parse_body {body base_offset line_offsets char_byte_map scope} {
    set cmds [split_commands $body]
    set comment_lines {}

    foreach cmd_entry $cmds {
        set cmd_text [lindex $cmd_entry 0]
        set rel_start [lindex $cmd_entry 1]
        set rel_end [lindex $cmd_entry 2]
        set abs_start [expr {$base_offset + $rel_start}]
        set abs_end [expr {$base_offset + $rel_end}]

        set trimmed [string trim $cmd_text]

        if {[string match "#*" $trimmed]} {
            lappend comment_lines $trimmed
            continue
        }

        if {$trimmed eq ""} {
            set comment_lines {}
            continue
        }

        set first_word ""
        if {[catch {set first_word [lindex $trimmed 0]}]} {
            regexp {^\s*(\S+)} $trimmed -> first_word
        }

        if {$first_word eq "proc"} {
            parse_proc $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
        } elseif {$first_word eq "namespace"} {
            if {[catch {set second [lindex $trimmed 1]}]} {
                set second ""
            }
            if {$second eq "eval"} {
                parse_namespace_eval $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            }
        } elseif {$first_word in {"oo::class" "::oo::class"}} {
            parse_oo_class $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
        } elseif {$first_word eq "class"} {
            parse_custom_class $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
        }

        set comment_lines {}
    }
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

proc main {} {
    variable symbols

    if {$::argc < 1} {
        puts stderr "Usage: tclsh tcl_parser_bridge.tcl <filepath>"
        exit 1
    }

    set filepath [lindex $::argv 0]

    if {![file exists $filepath]} {
        puts stderr "File not found: $filepath"
        exit 1
    }

    # Read and parse
    set content [read_source $filepath]
    set line_offsets [build_line_offsets $content]
    set char_byte_map [build_char_to_byte $content]

    # Parse top-level commands
    parse_body $content 0 $line_offsets $char_byte_map ""

    # Output JSON array
    puts [json_list $symbols]
}

# Run
main
