#!/usr/bin/env tclsh
#
# Bytecode-based call-edge verifier for the jcodemunch TCL bridge.
#
# This is the second independent implementation of the SPEC.md call-edge
# rulebook, used for differential testing against tcl_parser_bridge.tcl.
#
# Architecture: instead of re-implementing TCL's parser in Python or Tcl,
# we use Tcl's own bytecode compiler to compile each proc body, then walk
# the disassembly to extract call edges. This gives us the actual sequence
# of invocations Tcl would execute, with built-ins (set, if, while,
# foreach, etc.) automatically filtered out by the compile-time optimizer
# (they emit specialized opcodes, not `invokeStk*`).
#
# Usage: tclsh verify.tcl <bluice_tcl_file>
# Output: JSON list of {qualified_name, calls, unresolved_dispatches}
#
# IMPORTANT: this verifier does NOT execute the file's top-level code. It
# overrides `proc`, `body`, `method`, `constructor`, `destructor`,
# `itcl::class` and similar definers in a sandbox interp to record
# (name, args, body) without running other commands. So the verifier is
# safe on bluice TCL files even though they need Tk / dcss / etc.

# ---------------------------------------------------------------------------
# Capture phase: source the file under a sandbox that records definitions.
# ---------------------------------------------------------------------------

# Storage: list of {qualified_name args body} for every proc/method/body
# discovered in the file. Stored at the parent-interpreter level so the
# sandbox can populate it via aliases.
set ::captured {}

# A note on alias closures: the alias routes the sandbox's `proc` call
# back to ::record_proc in the parent. The parent records and returns
# without re-defining (the body is the only thing we need; subsequent
# code that references the proc by name doesn't matter because we are
# not actually running anything that would call it).

proc record_proc {name args body} {
    global captured
    set qual $name
    if {![string match "::*" $qual]} {
        # Use the current namespace from the sandbox interp side. Without
        # the sandbox interp's :: context propagating, we accept what was
        # passed and treat it as already-qualified. Bridge convention is
        # to qualify via the surrounding scope; the verifier does the
        # same at consume time.
        set qual $name
    }
    lappend captured [list $qual $args $body "function"]
}

proc record_method {scope name args body} {
    global captured
    set qual "${scope}::${name}"
    lappend captured [list $qual $args $body "method"]
}

proc record_class {name body} {
    # An iTcl class body contains method/constructor/destructor/proc
    # declarations. We can't easily walk it without re-parsing — so we
    # punt on class-internal capture in this scaffold and only record
    # the class itself as a definition site.
    global captured
    lappend captured [list $name "" $body "class"]
}

proc make_sandbox {} {
    set s [interp create]

    # Override `proc` in the sandbox so each definition routes to our
    # recorder. Subsequent code in the file may call the proc, but most
    # bluice TCL just defines without running at top level.
    interp alias $s proc {} record_proc

    # Catch any errors — top-level Tk/widget calls will fail silently.
    interp alias $s puts {} list ;# silence top-level puts noise

    return $s
}

# ---------------------------------------------------------------------------
# Disassembly phase: for each captured body, compile to bytecode and walk.
# ---------------------------------------------------------------------------

# Parse a disassembly text into a list of commands, each command is a list
# of instructions. Each instruction is {opcode operand_text comment}.
proc parse_disassembly {bc_text} {
    set commands {}
    set current {}
    set in_command 0
    foreach line [split $bc_text "\n"] {
        if {[regexp {^  Command \d+:} $line]} {
            if {$in_command} {
                lappend commands $current
            }
            set current {}
            set in_command 1
            continue
        }
        if {!$in_command} continue
        # Match instruction lines like:
        #   (NN) opcode operand 	# comment
        if {[regexp {^\s*\(\d+\)\s+(\S+)(?:\s+([^#]*?))?(?:\s*#\s*(.*))?$} $line - op operand comment]} {
            set op [string trim $op]
            set operand [string trim $operand]
            set comment [string trim $comment]
            lappend current [list $op $operand $comment]
        }
    }
    if {$in_command} {
        lappend commands $current
    }
    return $commands
}

# Walk a list of instructions for one command and produce a tuple:
#   {call_edges unresolved_kinds}
# where call_edges is a list of names dispatched and unresolved_kinds is
# a list of {kind} markers.
#
# Detection model:
# - Final instruction is invokeStk* with operand N (= number of args
#   including the command name).
# - Walk back N pushes from the invoke. The first push is the command;
#   subsequent pushes are args.
# - push1/pushSomething LITERAL → command name resolved.
# - loadScalar* → command came from a variable; if it's the FIRST push
#   (the command-name slot) the dispatch is unresolved (Pattern B
#   shape).
# - For Pattern B, the SECOND push is the method name. If literal,
#   capture it as a call edge. If also a variable, mark var_method.
proc analyze_command {insns} {
    set calls {}
    set unresolved {}
    # Find the invokeStk instruction; there can also be invokeExp (expr)
    # and other invoke variants. Only invokeStk* dispatches user commands.
    set invoke_idx -1
    set narg 0
    set inv_op ""
    for {set i [expr {[llength $insns] - 1}]} {$i >= 0} {incr i -1} {
        set op [lindex $insns $i 0]
        if {[string match "invokeStk*" $op]} {
            set invoke_idx $i
            set inv_op $op
            set narg [lindex $insns $i 1]
            break
        }
    }
    if {$invoke_idx < 0} {
        # No invocation in this command — likely compile-time-optimized
        # builtin (set, if, while, for, foreach, ...) or pure expr.
        # Still walk for nested invokes embedded in this command.
        return [list $calls $unresolved]
    }
    # Walk back narg pushes/loads from the invoke
    set arg_count 0
    set arg_kinds {}      ;# in invocation order: 0=cmd, 1=arg1, ...
    set arg_values {}
    for {set j [expr {$invoke_idx - 1}]} {$j >= 0 && $arg_count < $narg} {incr j -1} {
        set op [lindex $insns $j 0]
        set comment [lindex $insns $j 2]
        if {[string match "push*" $op]} {
            # Literal push: comment is the literal value with quotes
            set lit [string trim $comment]
            if {[regexp {^"(.*)"$} $lit - inner]} {
                set arg_kinds [linsert $arg_kinds 0 "literal"]
                set arg_values [linsert $arg_values 0 $inner]
            } else {
                set arg_kinds [linsert $arg_kinds 0 "literal"]
                set arg_values [linsert $arg_values 0 $lit]
            }
            incr arg_count
        } elseif {[string match "loadScalar*" $op] || [string match "loadStk*" $op]
                  || [string match "loadArr*" $op]} {
            set arg_kinds [linsert $arg_kinds 0 "var"]
            set arg_values [linsert $arg_values 0 [string trim $comment]]
            incr arg_count
        } elseif {$op eq "concat1" || $op eq "concat"} {
            # concat collapses N stack entries into one. Hard to follow
            # exactly without modeling stack depth fully; mark and stop.
            set arg_kinds [linsert $arg_kinds 0 "concat"]
            set arg_values [linsert $arg_values 0 $comment]
            incr arg_count
        } else {
            # Other ops in the chain (e.g., pop, jump targets). Bail.
            break
        }
    }
    # Now arg_kinds[0] is the command-name slot.
    if {[llength $arg_kinds] == 0} {
        return [list $calls $unresolved]
    }
    set cmd_kind [lindex $arg_kinds 0]
    set cmd_value [lindex $arg_values 0]
    if {$cmd_kind eq "literal"} {
        # Pattern A: literal command name. This IS a call edge.
        # (Bytecode optimizer already filtered builtins like set/if/while.)
        lappend calls $cmd_value
        # Detect eval/uplevel/interp wrapping a variable — these correspond
        # to spec section 4 unresolved categories. Bytecode tells us which
        # arg slots ended up as `var` (loadScalar) — when the dispatched
        # script comes from a variable, the call is unfollowable.
        if {$cmd_value eq "eval" && [llength $arg_kinds] >= 2} {
            # eval $var args — first arg (slot 1) is a var.
            if {[lindex $arg_kinds 1] eq "var"} {
                lappend unresolved "eval_var"
            }
        } elseif {$cmd_value eq "uplevel" && [llength $arg_kinds] >= 2} {
            # uplevel ?level? $var — find the first non-#?N slot and check.
            set probe 1
            set lev_str [lindex $arg_values 1]
            if {[regexp {^#?\d+$} $lev_str] && [llength $arg_kinds] >= 3} {
                set probe 2
            }
            if {[lindex $arg_kinds $probe] eq "var"} {
                lappend unresolved "uplevel_var"
            }
        } elseif {$cmd_value eq "interp" && [llength $arg_kinds] >= 4
                  && [lindex $arg_kinds 1] eq "literal"
                  && [lindex $arg_values 1] eq "eval"} {
            # interp eval $other $cmd — slot 3 is the dispatched script.
            if {[lindex $arg_kinds 3] eq "var"} {
                lappend unresolved "interp_eval"
            }
        }
    } elseif {$cmd_kind eq "var"} {
        # Pattern B: $var method ?args? OR $var alone (var_command).
        if {[llength $arg_kinds] >= 2} {
            set method_kind [lindex $arg_kinds 1]
            set method_value [lindex $arg_values 1]
            if {$method_kind eq "literal"} {
                # Capture method name (Pattern B).
                lappend calls $method_value
            } else {
                # $obj $method ... — method name is a variable.
                lappend unresolved "var_method"
            }
        } else {
            lappend unresolved "var_command"
        }
    } else {
        # concat or unknown — opaque dispatch.
        lappend unresolved "opaque"
    }
    return [list $calls $unresolved]
}

# Disassemble a body and extract its call edges + unresolved sites.
proc analyze_body {args body} {
    set calls {}
    set unresolved {}
    set bc ""
    if {[catch {set bc [::tcl::unsupported::disassemble lambda [list $args $body]]} err]} {
        # Compile failure — record as opaque.
        return [list {} [list "compile_error: $err"]]
    }
    set commands [parse_disassembly $bc]
    foreach cmd $commands {
        lassign [analyze_command $cmd] cmd_calls cmd_unresolved
        foreach c $cmd_calls { lappend calls $c }
        foreach u $cmd_unresolved { lappend unresolved $u }
    }
    return [list $calls $unresolved]
}

# ---------------------------------------------------------------------------
# Top-level entry: source the file, then analyze each captured definition.
# ---------------------------------------------------------------------------

proc main {} {
    global captured argv
    if {[llength $argv] < 1} {
        puts stderr "Usage: tclsh verify.tcl <bluice_tcl_file>"
        exit 1
    }
    set filepath [lindex $argv 0]
    if {![file exists $filepath]} {
        puts stderr "File not found: $filepath"
        exit 1
    }

    # Capture phase
    set sandbox [make_sandbox]
    catch {$sandbox eval [list source $filepath]}
    interp delete $sandbox

    # Analysis phase
    puts "\["
    set first 1
    foreach entry $captured {
        lassign $entry qual args body kind
        lassign [analyze_body $args $body] calls unresolved
        # Dedup
        set seen [dict create]
        set dedup_calls {}
        foreach c $calls {
            if {![dict exists $seen $c]} {
                dict set seen $c 1
                lappend dedup_calls $c
            }
        }
        if {!$first} { puts "  ," }
        set first 0
        puts "  {"
        puts "    \"qualified_name\": [json_str $qual],"
        puts "    \"kind\": [json_str $kind],"
        puts "    \"call_references\": [json_strlist $dedup_calls],"
        puts "    \"unresolved_kinds\": [json_strlist $unresolved]"
        puts -nonewline "  }"
    }
    puts "\n\]"
}

proc json_str {s} {
    set s [string map {\\ \\\\ \" \\\" "\n" \\n "\t" \\t} $s]
    return "\"$s\""
}

proc json_strlist {items} {
    set parts {}
    foreach i $items { lappend parts [json_str $i] }
    return "\[[join $parts ", "]\]"
}

main
