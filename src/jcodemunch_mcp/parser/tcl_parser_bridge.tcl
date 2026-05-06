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

# Return the absolute char offset in the source where the body content
# inside the first brace group of a class / namespace command begins.
# Used by body-recursing parsers (parse_class_body, parse_body) to assign
# accurate line/byte numbers to symbols emitted from nested constructs.
# Without this, inline methods of `class Admin {...}` are offset by the
# length of the `class Admin {` header.
# Find every brace-quoted word in a command text. Returns a list of
# {start_idx end_idx} pairs (positions of the OUTER `{` and `}` chars).
# Used by parse_body to recurse into bodies of `if` / `while` / `for` /
# `foreach` / `catch` / `try` so conditionally-defined procs are visible.
# Skips backslash-escaped braces and braces inside quoted strings.
proc find_brace_words {text} {
    set words {}
    set len [string length $text]
    set i 0
    set in_quote 0
    while {$i < $len} {
        set ch [string index $text $i]
        if {$ch eq "\\" && $i + 1 < $len} { incr i 2; continue }
        if {$in_quote} {
            if {$ch eq "\""} { set in_quote 0 }
            incr i
            continue
        }
        if {$ch eq "\""} { set in_quote 1; incr i; continue }
        if {$ch eq "\{"} {
            set start $i
            set depth 1
            incr i
            while {$i < $len && $depth > 0} {
                set c2 [string index $text $i]
                if {$c2 eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c2 eq "\{"} { incr depth }
                if {$c2 eq "\}"} { incr depth -1 }
                incr i
            }
            if {$depth == 0} {
                lappend words [list $start [expr {$i - 1}]]
            }
            continue
        }
        incr i
    }
    return $words
}

proc compute_body_base {cmd_text start_char} {
    set idx [string first "\{" $cmd_text]
    if {$idx < 0} { return $start_char }
    return [expr {$start_char + $idx + 1}]
}

# Returns 1 iff $s has balanced { }, [ ], and " ", treating characters
# inside double-quoted strings as literal (so braces inside a string do
# not affect the brace depth). TCL's own `info complete` does NOT have
# this property: it counts raw braces even inside quoted strings, so
# commands like `set s "}"` appear complete earlier than they really are.
# Used alongside `info complete` to avoid slicing a command short when it
# quotes a lone open or close brace.
proc is_quote_balanced {s} {
    # Lexer-aware completion check mirroring TCL's word rules.
    # Three contexts: bare, quoted, and brace-word.
    # See jcm_info_complete_brace_bug memory note for background.
    set bd 0
    set sd 0
    set in_quote 0
    set at_cmd_pos 1
    set len [string length $s]
    set i 0
    while {$i < $len} {
        set ch [string index $s $i]

        # Inside brace word: only `\<newline>` and matching `{`/`}` matter.
        if {$bd > 0 && !$in_quote} {
            if {$ch eq "\\"} {
                # Skip 1 char (the next one), regardless of what it is.
                # `\<newline>` joins lines; `\<other>` is literal inside
                # braces but we still skip to keep parity with the bare/quote
                # branches' escape-skip behavior.
                incr i 2
                continue
            }
            if {$ch eq "\{"} { incr bd; incr i; continue }
            if {$ch eq "\}"} { incr bd -1; incr i; continue }
            incr i
            continue
        }

        # Inside double-quoted string.
        if {$in_quote} {
            if {$ch eq "\\" && $i + 1 < $len} {
                incr i 2
                continue
            }
            if {$ch eq "\""} {
                set in_quote 0
                set at_cmd_pos 0
                incr i
                continue
            }
            # Bracket commands ARE evaluated inside quotes — track depth.
            if {$ch eq "\["} { incr sd }
            if {$ch eq "\]"} { incr sd -1 }
            incr i
            continue
        }

        # Bare context.
        # Line comments: only at command position. Run to newline.
        if {$at_cmd_pos && $ch eq "#"} {
            while {$i < $len && [string index $s $i] ne "\n"} { incr i }
            # Leave $at_cmd_pos true; the newline will handle position state.
            continue
        }
        if {$ch eq "\\" && $i + 1 < $len} {
            incr i 2
            set at_cmd_pos 0
            continue
        }
        if {$ch eq "\""} {
            set in_quote 1
            set at_cmd_pos 0
            incr i
            continue
        }
        if {$ch eq "\{"} { incr bd; set at_cmd_pos 0; incr i; continue }
        if {$ch eq "\}"} { incr bd -1; set at_cmd_pos 0; incr i; continue }
        if {$ch eq "\["} { incr sd; set at_cmd_pos 0; incr i; continue }
        if {$ch eq "\]"} { incr sd -1; set at_cmd_pos 0; incr i; continue }

        # Whitespace / separator handling for command position.
        if {$ch eq "\n" || $ch eq ";"} {
            set at_cmd_pos 1
        } elseif {$ch ne " " && $ch ne "\t"} {
            set at_cmd_pos 0
        }
        incr i
    }
    return [expr {$bd == 0 && $sd == 0 && !$in_quote}]
}

# Split source into top-level commands, tracking their character offsets.
# Returns a list of {command_text start_char_idx end_char_idx}.
# Uses `info complete` AND `is_quote_balanced` together — both must agree
# that the buffer is complete before emitting a command. That avoids
# slicing a command at an unbalanced `"}"` inside a method body.
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

        # Check if the buffer forms a complete command.
        if {$ch eq "\n" && [info complete $buf] && [is_quote_balanced $buf]} {
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
    set skip {
        proc namespace set if else elseif while for foreach switch
        return break continue catch try throw finally
        expr string list lindex lappend llength lrange lsearch
        lsort dict array info puts gets open close read
        variable global upvar uplevel eval source package
        after vwait update error rename unset append incr
        format scan regexp regsub split join concat
        file glob cd pwd exec pid
        eq ne lt gt le ge in ni
        and or not true false
    }

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
        if {$call in $skip} { continue }
        if {$call ne "" && ![dict exists $seen $call]} {
            dict set seen $call 1
            lappend calls $call
        }
    }

    # Pattern: iTcl / TclOO method dispatch — `$var method args` appearing as
    # a statement (line start, after `[`, or after `;`). Also accepts the
    # iTk array form `$var(key) method`. Critical for bluice where the
    # dominant call form is `$self methodName` (or `$itk_option(-X) method`),
    # rather than bare `methodName`.
    foreach {match sub} [regexp -all -inline {(?:^|[\[;\n])\s*\$\w+(?:\([^)]*\))?\s+([a-zA-Z_][\w]*)} $body] {
        set call [string trim $sub]
        if {$call in $skip} { continue }
        if {$call ne "" && ![dict exists $seen $call]} {
            dict set seen $call 1
            lappend calls $call
        }
    }

    # Pattern: Tk-callback idiom — `-option "$var method …"` or
    # `-option "$var(key) method …"`. The leading `-word` requirement
    # scopes this to option-value strings (Tk widget callbacks, iwidgets
    # -command / -onClick / -yscrollcommand / etc.) and avoids catching
    # arbitrary interpolated strings like "user $u name".
    foreach {match sub} [regexp -all -inline -- \
            {-[a-zA-Z][\w-]*\s+"\s*\$\w+(?:\([^)]*\))?\s+([a-zA-Z_][\w]*)} $body] {
        set call [string trim $sub]
        if {$call in $skip} { continue }
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
# Registry for per-method dedup: maps qualified_name -> {position is_decl}.
# When a pure-decl method emission is followed by an out-of-line body (iTcl
# `body Class::method`), the body replaces the decl instead of duplicating.
variable method_registry
array set method_registry {}

# Helper: emit a symbol JSON object with correct byte offsets.
# start_char/end_char are character indices; char_to_byte_map translates them.
proc emit_symbol {name qualified kind sig docstring start_char end_char
                  line_offsets char_byte_map parent cyclomatic max_nesting
                  param_count calls annotations keywords} {
    variable symbols
    variable method_registry

    set start_line [expr {[char_to_line $line_offsets $start_char] + 1}]
    set end_line   [expr {[char_to_line $line_offsets $end_char] + 1}]
    set byte_off   [char_to_byte $char_byte_map $start_char]
    # end_char is inclusive, so byte_length = byte(end_char+1) - byte(start_char)
    set byte_end   [char_to_byte $char_byte_map [expr {$end_char + 1}]]
    set byte_len   [expr {$byte_end - $byte_off}]

    if {[string length $sig] > 200} {
        set sig [string range $sig 0 196]...
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

    # Dedup method-kind emissions. A method can appear as both a pure-decl
    # inside a class body (`public method foo {args}`) and later as an
    # out-of-line body (`body Class::foo {args} {...}`). The body has real
    # code, calls, cyclomatic, etc. — replace the decl with the body.
    if {$kind eq "method"} {
        set is_decl [expr {"method_decl" in $keywords || "class_proc_decl" in $keywords}]
        if {[info exists method_registry($qualified)]} {
            lassign $method_registry($qualified) prev_pos prev_is_decl
            if {$prev_is_decl && !$is_decl} {
                # Body supersedes prior decl — replace in place.
                lset symbols $prev_pos $sym
                set method_registry($qualified) [list $prev_pos 0]
            }
            # Else: duplicate. Skip (either both decls, or prev is already
            # a body — TCL redefinition last-wins, but for static analysis
            # we keep the first body emission to preserve source order).
            return
        }
        lappend symbols $sym
        set method_registry($qualified) [list [expr {[llength $symbols] - 1}] $is_decl]
        return
    }

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

proc parse_package {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Emit `package provide NAME VERSION` / `package require NAME ?VERSION?`
    # as `import` kind symbols. Matches upstream 1.24.2's behaviour and lets
    # reverse lookup ("which files require NAME?") work across languages.
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return }
    if {[llength $parts] < 3} { return }
    if {[lindex $parts 0] ne "package"} { return }
    set sub [lindex $parts 1]
    if {$sub ni {"provide" "require"}} { return }
    set pkg_name [lindex $parts 2]
    if {$pkg_name eq ""} { return }

    set version ""
    if {[llength $parts] >= 4} { set version [lindex $parts 3] }

    set sig "package $sub $pkg_name"
    if {$version ne ""} { set sig "$sig $version" }

    emit_symbol $pkg_name "${sub}:${pkg_name}" "import" \
        $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list "package_$sub"]
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

    emit_symbol [namespace tail $ns_name] $qualified "namespace" \
        "namespace eval $qualified" "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} $exports $keywords

    parse_body $body [compute_body_base $cmd_text $start_char] \
        $line_offsets $char_byte_map $qualified
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

    set sig "$class_cmd create $class_name"
    set parents [find_inherit_parents $body]
    if {[llength $parents] > 0} {
        set sig "$sig : [join $parents {, }]"
    }

    emit_symbol $class_name $qualified "class" \
        $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list "oo_class"]

    parse_oo_body $body [compute_body_base $cmd_text $start_char] \
        $line_offsets $char_byte_map $qualified
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

    set sig "class $class_name"
    set parents [find_inherit_parents $body]
    if {[llength $parents] > 0} {
        set sig "$sig : [join $parents {, }]"
    }

    emit_symbol $class_name $qualified "class" \
        $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list "custom_class"]

    parse_class_body $body [compute_body_base $cmd_text $start_char] \
        $line_offsets $char_byte_map $qualified
}

# Collect parent class names from an inherit / superclass statement at the
# top level of a class body. Returns the parent list or {} if none. Only
# inspects top-level commands — inherit nested inside a method/conditional
# isn't a real class parent.
proc find_inherit_parents {body} {
    set cmds [split_commands $body]
    foreach cmd_entry $cmds {
        set cmd_text [lindex $cmd_entry 0]
        set trimmed [string trim $cmd_text]
        if {[catch {set parts [lrange $trimmed 0 end]}]} { continue }
        if {[llength $parts] < 2} { continue }
        set kw [lindex $parts 0]
        if {$kw in {"inherit" "superclass"}} {
            return [lrange $parts 1 end]
        }
    }
    return {}
}

proc parse_class_body {body base_offset line_offsets char_byte_map scope} {
    # Parses class bodies for TclOO (oo::class create), iTcl (itcl::class),
    # and custom DSLs (git-gui style `class name { ... }`). Recognizes:
    #   [public|private|protected] method name params body
    #   [public|private|protected] proc name args body
    #   [public|private|protected] variable name ?default?
    #   [public|private|protected] common name ?default?
    #   constructor name params body   (custom DSL, 4 args after kw)
    #   constructor params body        (TclOO / iTcl, 3 args after kw)
    #   destructor body
    #   field name ?default?
    #   inherit Parent1 Parent2 ...    (not a symbol; consumed here for
    #                                   class-level signature elsewhere)
    #   itk_option define -name ...
    set cmds [split_commands $body]
    foreach cmd_entry $cmds {
        set cmd_text [lindex $cmd_entry 0]
        set rel_start [lindex $cmd_entry 1]
        set rel_end [lindex $cmd_entry 2]
        set abs_start [expr {$base_offset + $rel_start}]
        set abs_end [expr {$base_offset + $rel_end}]

        set trimmed [string trim $cmd_text]
        if {$trimmed eq "" || [string index $trimmed 0] eq "#"} { continue }

        if {[catch {set parts [lrange $trimmed 0 end]}]} {
            # lrange parses its argument as a TCL list; list parsing counts
            # literal open/close braces inside double-quoted strings when
            # those strings sit inside a brace group. A method body that
            # quotes either a lone open or close brace as a string literal
            # will unbalance the surrounding braces and list parsing fails.
            # Fall back to a regex matching the common shape
            # "[access] (method or proc) NAME (args) (body)" and synthesise
            # a parts list. Constructor/destructor with inline-brace strings
            # remain uncovered (rarer in practice).
            set _pat {^\s*(?:(public|private|protected)\s+)?(method|proc)\s+(\w+)\s+\{([^{}]*)\}\s+\{(.*)\}\s*$}
            if {[regexp $_pat $trimmed -> _access _kw _name _args _body]} {
                set parts {}
                if {$_access ne ""} { lappend parts $_access }
                lappend parts $_kw $_name $_args $_body
            } else {
                continue
            }
        }
        if {[llength $parts] < 1} { continue }

        # Peel off an access-modifier prefix (iTcl).
        set access ""
        set head [lindex $parts 0]
        if {$head in {"public" "private" "protected"}} {
            if {[llength $parts] < 2} { continue }
            set access $head
            set parts [lrange $parts 1 end]
        }

        set kw [lindex $parts 0]

        if {$kw eq "method" && [llength $parts] >= 2} {
            # Accept three forms:
            #   [access] method NAME {args} {body}   - full inline definition
            #   [access] method NAME {args}          - rare declaration-only
            #   [access] method NAME                 - iTcl pure declaration;
            #       the body is defined out-of-line via `body ClassName::NAME`.
            set method_name [lindex $parts 1]
            set args_str ""
            set method_body ""
            if {[llength $parts] >= 3} { set args_str [lindex $parts 2] }
            if {[llength $parts] >= 4} { set method_body [lindex $parts 3] }

            set prefix "method"
            if {$access ne ""} { set prefix "$access method" }
            set sig "$prefix $method_name"
            if {[llength $parts] >= 3} { set sig "$sig \{$args_str\}" }

            if {$method_body ne ""} {
                emit_symbol $method_name "${scope}::${method_name}" "method" \
                    $sig "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    [count_cyclomatic $method_body] [count_max_nesting $method_body] \
                    [count_params $args_str] [extract_calls $method_body] \
                    [detect_annotations $method_body] [list "method"]
            } else {
                emit_symbol $method_name "${scope}::${method_name}" "method" \
                    $sig "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    0 0 [count_params $args_str] {} {} [list "method_decl"]
            }

        } elseif {$kw eq "constructor"} {
            # Custom DSL: constructor name params body (4 args after kw)
            # TclOO/iTcl: constructor params body      (3 args after kw)
            set prefix "constructor"
            if {$access ne ""} { set prefix "$access constructor" }
            if {[llength $parts] >= 5} {
                set con_name [lindex $parts 1]
                set args_str [lindex $parts 2]
                set con_body [lindex $parts 3]
                emit_symbol $con_name "${scope}::${con_name}" "method" \
                    "$prefix $con_name \{$args_str\}" "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    [count_cyclomatic $con_body] [count_max_nesting $con_body] \
                    [count_params $args_str] [extract_calls $con_body] \
                    [detect_annotations $con_body] [list "constructor"]
            } elseif {[llength $parts] >= 3} {
                set args_str [lindex $parts 1]
                set con_body [lindex $parts 2]
                emit_symbol "constructor" "${scope}::constructor" "method" \
                    "$prefix \{$args_str\}" "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    [count_cyclomatic $con_body] [count_max_nesting $con_body] \
                    [count_params $args_str] [extract_calls $con_body] \
                    [detect_annotations $con_body] [list "constructor"]
            }

        } elseif {$kw eq "destructor" && [llength $parts] >= 2} {
            set dest_body [lindex $parts 1]
            set prefix "destructor"
            if {$access ne ""} { set prefix "$access destructor" }

            emit_symbol "destructor" "${scope}::destructor" "method" \
                $prefix "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                [count_cyclomatic $dest_body] [count_max_nesting $dest_body] \
                0 [extract_calls $dest_body] \
                [detect_annotations $dest_body] [list "destructor"]

        } elseif {$kw eq "field" && [llength $parts] >= 2} {
            set field_name [lindex $parts 1]
            set field_name [string trimright $field_name ";"]

            emit_symbol $field_name "${scope}::${field_name}" "constant" \
                "field $field_name" "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                0 0 0 {} {} [list "field"]

        } elseif {$kw eq "proc"} {
            # `public proc` inside an iTcl class is a class-scope (static)
            # method; emit under class scope. Bare `proc` with no access
            # modifier is a nested proc, handled by parse_proc. Declaration-
            # only forms (no body) are also recognized, matching the iTcl
            # pattern where `body ClassName::proc` defines the body later.
            if {$access ne ""} {
                if {[llength $parts] < 2} { continue }
                set pname [lindex $parts 1]
                set args_str ""
                set pbody ""
                if {[llength $parts] >= 3} { set args_str [lindex $parts 2] }
                if {[llength $parts] >= 4} { set pbody [lindex $parts 3] }
                set sig "$access proc $pname"
                if {[llength $parts] >= 3} { set sig "$sig \{$args_str\}" }
                if {$pbody ne ""} {
                    emit_symbol $pname "${scope}::${pname}" "function" \
                        $sig "" \
                        $abs_start $abs_end $line_offsets $char_byte_map $scope \
                        [count_cyclomatic $pbody] [count_max_nesting $pbody] \
                        [count_params $args_str] [extract_calls $pbody] \
                        [detect_annotations $pbody] [list "class_proc" $access]
                } else {
                    emit_symbol $pname "${scope}::${pname}" "function" \
                        $sig "" \
                        $abs_start $abs_end $line_offsets $char_byte_map $scope \
                        0 0 [count_params $args_str] {} {} [list "class_proc_decl" $access]
                }
            } elseif {[llength $parts] >= 4} {
                parse_proc $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            }

        } elseif {$kw in {"variable" "common"} && [llength $parts] >= 2} {
            set vname [lindex $parts 1]
            set vname [string trimright $vname ";"]
            set prefix $kw
            if {$access ne ""} { set prefix "$access $kw" }

            emit_symbol $vname "${scope}::${vname}" "constant" \
                "$prefix $vname" "" \
                $abs_start $abs_end $line_offsets $char_byte_map $scope \
                0 0 0 {} {} [list $kw]

        } elseif {$kw eq "inherit"} {
            # Consumed by find_inherit_parents at class-decl time; not a
            # symbol on its own.
            continue

        } elseif {$kw eq "itk_option" && [llength $parts] >= 3} {
            # itk_option define -switchName resourceName ClassName default ?config?
            # The -switch form (with leading dash) is the canonical iTk
            # identifier — call sites use `widget configure -switchName`
            # and `$itk_option(-switchName)`. Preserve the dash in name
            # and qualified_name so lexical lookup matches every use.
            set sub [lindex $parts 1]
            if {$sub eq "define" && [llength $parts] >= 5} {
                set option_token [lindex $parts 2]
                if {$option_token eq ""} { continue }

                emit_symbol $option_token "${scope}::${option_token}" "constant" \
                    "itk_option define $option_token" "" \
                    $abs_start $abs_end $line_offsets $char_byte_map $scope \
                    0 0 0 {} {} [list "itk_option"]
            }
        }
    }
}

# Legacy alias for TclOO — both paths now use the unified class body parser.
proc parse_oo_body {body base_offset line_offsets char_byte_map scope} {
    parse_class_body $body $base_offset $line_offsets $char_byte_map $scope
}

proc parse_itcl_class {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Handles: itcl::class Name { body } / ::itcl::class Name { body } /
    #          itk::usual Name { body }
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return }
    if {[llength $parts] < 3} { return }
    set kw [lindex $parts 0]
    set class_name [lindex $parts 1]
    set body [lindex $parts 2]

    if {[string match "::*" $class_name]} {
        set qualified [string trimleft $class_name ":"]
    } elseif {$scope ne ""} {
        set qualified "${scope}::${class_name}"
    } else {
        set qualified $class_name
    }

    set short_name [namespace tail $class_name]
    if {$short_name eq ""} { set short_name $class_name }

    set keyword_tag "itcl_class"
    set sym_kind "class"
    if {$kw eq "itk::usual"} {
        set keyword_tag "itk_usual"
        # itk::usual declares an option-set / config schema for a megawidget,
        # not a class. Closest LSP match is "interface" (a contract / property
        # set without implementation). Keeps OOP class enumeration clean.
        set sym_kind "interface"
    }

    set sig "$kw $class_name"
    set parents [find_inherit_parents $body]
    if {[llength $parents] > 0} {
        set sig "$sig : [join $parents {, }]"
    }

    emit_symbol $short_name $qualified $sym_kind \
        $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $scope \
        0 0 0 {} {} [list $keyword_tag]

    parse_class_body $body [compute_body_base $cmd_text $start_char] \
        $line_offsets $char_byte_map $qualified
}

proc parse_itcl_body {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Handles: itcl::body Class::method args body (out-of-line method definition)
    #          ::itcl::body and bare `body` (dispatcher guards bare form to
    #          require a Class::method target).
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return }
    if {[llength $parts] < 4} { return }
    set kw [lindex $parts 0]
    set target [lindex $parts 1]
    set args_str [lindex $parts 2]
    set body [lindex $parts 3]

    if {![string match "*::*" $target]} { return }

    set qualified [string trimleft $target ":"]
    set short_name [namespace tail $target]
    if {$short_name eq ""} { set short_name $target }

    # Method belongs to the class encoded in the qualified target, not
    # the dispatch scope. The earlier `*::*` guard ensures a qualifier
    # exists, so namespace qualifiers always returns the class name.
    set class_scope [namespace qualifiers $qualified]

    set sig "$kw $target \{$args_str\}"
    set annotations [detect_annotations $body]

    emit_symbol $short_name $qualified "method" $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $class_scope \
        [count_cyclomatic $body] [count_max_nesting $body] \
        [count_params $args_str] [extract_calls $body] \
        $annotations [list "itcl_body"]
}

proc parse_itcl_configbody {cmd_text start_char end_char line_offsets char_byte_map scope} {
    # Handles: itcl::configbody Class::var body (3-word form: target + body,
    #          no args list). Emits kind=method since it's a callable code block.
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return }
    if {[llength $parts] < 3} { return }
    set kw [lindex $parts 0]
    set target [lindex $parts 1]
    set body [lindex $parts 2]

    if {![string match "*::*" $target]} { return }

    set qualified [string trimleft $target ":"]
    set short_name [namespace tail $target]
    if {$short_name eq ""} { set short_name $target }

    # Configbody belongs to the class encoded in the qualified target.
    set class_scope [namespace qualifiers $qualified]

    set sig "$kw $target"
    set annotations [detect_annotations $body]

    emit_symbol $short_name $qualified "method" $sig "" \
        $start_char $end_char $line_offsets $char_byte_map $class_scope \
        [count_cyclomatic $body] [count_max_nesting $body] \
        0 [extract_calls $body] \
        $annotations [list "configbody"]
}

# Parse a body string for nested procs and namespace evals.
proc parse_body {body base_offset line_offsets char_byte_map scope {emit_script 1}} {
    set cmds [split_commands $body]
    set comment_lines {}

    # Accumulator for script-top-level (file-root) commands that aren't
    # captured by any defining-construct parser (e.g. `startBluIce ::config`
    # at file scope, calls inside a top-level `switch` arm). Only used when
    # scope == "" so we don't synthesize symbols inside namespace bodies.
    set script_cmd_texts {}
    set script_first_start -1
    set script_last_end -1

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

        set dispatched 0
        if {$first_word eq "proc"} {
            parse_proc $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        } elseif {$first_word eq "package"} {
            set second ""
            catch {set second [lindex $trimmed 1]}
            if {$second in {"provide" "require"}} {
                parse_package $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
                set dispatched 1
            }
        } elseif {$first_word eq "namespace"} {
            if {[catch {set second [lindex $trimmed 1]}]} {
                set second ""
            }
            if {$second eq "eval"} {
                parse_namespace_eval $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
                set dispatched 1
            }
        } elseif {$first_word in {"oo::class" "::oo::class"}} {
            parse_oo_class $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        } elseif {$first_word in {"itcl::class" "::itcl::class" "itk::usual"}} {
            parse_itcl_class $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        } elseif {$first_word in {"itcl::body" "::itcl::body"}} {
            parse_itcl_body $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        } elseif {$first_word in {"itcl::configbody" "::itcl::configbody"}} {
            parse_itcl_configbody $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        } elseif {$first_word eq "body"} {
            # Bare `body Class::method args body` — iTcl out-of-line definition.
            # Only dispatch when the target is qualified (contains ::), so we
            # don't misfire on arbitrary commands that happen to be named body.
            set second ""
            catch {set second [lindex $trimmed 1]}
            if {[string match "*::*" $second]} {
                parse_itcl_body $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
                set dispatched 1
            }
        } elseif {$first_word eq "class"} {
            parse_custom_class $trimmed $abs_start $abs_end $line_offsets $char_byte_map $scope
            set dispatched 1
        }

        # Control-flow recursion: procs and classes can be conditionally
        # defined inside `if`, `while`, `for`, `foreach`, `catch`, `try`
        # bodies (e.g. platform-specific `proc open` inside
        # `if {[is_Windows]} { ... }`). Recurse into every brace-quoted
        # word so nested definitions are visible. Does NOT mark dispatched,
        # so the script accumulator still captures the outer call too.
        if {$first_word in {if elseif while for foreach catch try after}} {
            foreach w [find_brace_words $cmd_text] {
                lassign $w bs be
                set inner_body [string range $cmd_text [expr {$bs + 1}] [expr {$be - 1}]]
                set inner_abs [expr {$abs_start + $bs + 1}]
                parse_body $inner_body $inner_abs $line_offsets $char_byte_map $scope 0
            }
        }

        # If this command wasn't a defining construct and we're at file
        # root, save its text for the synthetic __script__ symbol so its
        # outbound calls become indexable (find_references / call graph).
        if {!$dispatched && $scope eq ""} {
            lappend script_cmd_texts $trimmed
            if {$script_first_start < 0} {
                set script_first_start $abs_start
            }
            set script_last_end $abs_end
        }

        set comment_lines {}
    }

    # Emit synthetic file-scope symbol if we collected any top-level calls.
    if {$emit_script && $scope eq "" && [llength $script_cmd_texts] > 0} {
        set joined [join $script_cmd_texts "\n"]
        set script_calls [extract_calls $joined]
        if {[llength $script_calls] > 0} {
            emit_symbol "__script__" "__script__" "module" \
                "" "" $script_first_start $script_last_end \
                $line_offsets $char_byte_map "" 0 0 0 \
                $script_calls {} {}
        }
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
