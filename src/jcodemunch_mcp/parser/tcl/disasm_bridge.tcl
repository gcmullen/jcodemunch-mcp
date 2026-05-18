#!/usr/bin/env tclsh
#
# tcl_disasm_bridge.tcl — P1.2(a) deliverable per
# dev-docs/verdicts/WALKER_CONTRACT_v2_2.md §4.2 (Worker 3 driver loop).
#
# THE driver that wires together Workers 1/2/3a's deliverables:
#   - opcode_walker.tcl + tcl_disasm_parser.tcl  (Worker 1) — bytecode parse
#   - recursion_tables.tcl + compute_body_base.tcl (Worker 2) — sub-tables A/C +
#     body extraction + cross-file class index
#   - unresolved_detector.tcl                    (Worker 2) — walker → schema
#   - pragma_scanner.tcl                          (Worker 3a) — JCM:pragma + dynamic
#     body sites
#
# Output: JSON array of symbol objects on stdout (same wire shape the Python
# wrapper extractor.py::_parse_tcl_native expects). Errors/warnings to stderr.
#
# Usage (from extractor.py via subprocess):
#   tclsh tcl_disasm_bridge.tcl <filepath>
#
# Quality posture (§6.1.10): the file is structured around the per-event
# dispatch loop. Each handler is one focused proc; comments explain WHY a
# given decision was made (mostly tied to §13 user-decided rows in the v2.2
# contract).

source [file join [file dirname [info script]] disasm_parser.tcl]
source [file join [file dirname [info script]] opcode_walker.tcl]
source [file join [file dirname [info script]] recursion_tables.tcl]
source [file join [file dirname [info script]] compute_body_base.tcl]
source [file join [file dirname [info script]] unresolved_detector.tcl]
source [file join [file dirname [info script]] pragma_scanner.tcl]
source [file join [file dirname [info script]] bridge_postpasses.tcl]
source [file join [file dirname [info script]] disasm_bridge_json.tcl]

namespace eval ::jcm::bridge {
    namespace export bridge_main parse_file emit_json
}

# NOTE: JSON encoding helpers (::jcm::bridge::json::*) and the symbol-list
# emitter (emit_json + _symbol_to_json + _unresolved_entry_to_json +
# _class_entry_to_json + _pkg_entry_to_json) live in
# tcl_disasm_bridge_json.tcl as of P1.3 Stream 2.

# ---------------------------------------------------------------------------
# File I/O + line map
# ---------------------------------------------------------------------------

# Read the source file as UTF-8.
proc ::jcm::bridge::read_source {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8 -translation auto
    set src [read $fh]
    close $fh
    return $src
}

# Build a line map: list of byte offsets where each newline character lives in
# the file source. unresolved_detector::_offset_to_line consumes this directly.
# Note Tcl's `string index` works on chars; for ASCII this matches bytes.
# UTF-8 byte offsets for multi-byte input require a per-char byte map (see
# build_char_to_byte) — we keep one map per concept and compose at lookup
# time so the consumers stay simple.
proc ::jcm::bridge::build_line_offsets {src} {
    set offsets [list]
    set len [string length $src]
    for {set i 0} {$i < $len} {incr i} {
        if {[string index $src $i] eq "\n"} {
            lappend offsets $i
        }
    }
    return $offsets
}

# Convert a CHAR offset (the unit used by Tcl's `string index` and the
# disassembler's `src S-E`) to a 1-based line number.
proc ::jcm::bridge::char_offset_to_line {line_offsets char_off} {
    set count 0
    foreach nl $line_offsets {
        if {$nl >= $char_off} { break }
        incr count
    }
    return [expr {$count + 1}]
}

# Build a char-index → cumulative-byte-offset map for the file source. Used
# only when emitting Symbol byte_offset / byte_length so multi-byte UTF-8
# input lands on the right Python byte position.
#
# PERF (P1.3 outlier fix): for ASCII input the map is the identity
# [0..N]; building and traversing the list dominated parse-only time on
# bluice (>40% on pkgIndex.tcl, >70% on RasterGroupBase.tcl). We now
# return the sentinel `IDENTITY <len>` for ASCII strings; char_to_byte /
# byte_to_char short-circuit on that marker. Multi-byte input still
# builds the full map (correctness preserved). Detection uses
# `string is ascii` which is a single C-level scan.
proc ::jcm::bridge::build_char_to_byte {src} {
    set len [string length $src]
    if {[string is ascii $src]} {
        # Identity sentinel — char N maps to byte N for all N in [0..len].
        return [list IDENTITY $len]
    }
    set map [list]
    set byte_pos 0
    for {set i 0} {$i < $len} {incr i} {
        lappend map $byte_pos
        set ch [string index $src $i]
        incr byte_pos [string length [encoding convertto utf-8 $ch]]
    }
    lappend map $byte_pos
    return $map
}

proc ::jcm::bridge::char_to_byte {char_byte_map char_off} {
    if {$char_off < 0} { return 0 }
    # ASCII identity fast path.
    if {[lindex $char_byte_map 0] eq "IDENTITY"} {
        set len [lindex $char_byte_map 1]
        if {$char_off > $len} { return $len }
        return $char_off
    }
    set last [llength $char_byte_map]
    if {$char_off >= $last} { return [lindex $char_byte_map [expr {$last - 1}]] }
    return [lindex $char_byte_map $char_off]
}

# Reverse map: byte offset → char index.  The disassembler's `src S-E` are
# BYTE offsets (per WALKER_CONTRACT_v2_2 §2 — verified empirically against
# tclsh 8.6.14 with UTF-8 input).  Tcl's `string index` / `string range`
# operate on CHARS, so when the file contains multi-byte characters we
# must translate disasm-byte offsets to char offsets before slicing.
#
# PERF (P1.3 outlier fix): the previous linear forward scan dominated
# total runtime on the bluice corpus (4146 calls × ~1.8 ms each on the
# 7 kLoC RasterGroupBase outlier). Two-tier fast path:
#   1. ASCII identity: byte == char by construction.
#   2. Multi-byte: binary search instead of O(n) linear scan.
proc ::jcm::bridge::byte_to_char {char_byte_map byte_off} {
    if {$byte_off <= 0} { return 0 }
    # ASCII identity fast path.
    if {[lindex $char_byte_map 0] eq "IDENTITY"} {
        set len [lindex $char_byte_map 1]
        if {$byte_off > $len} { return [expr {$len - 1}] }
        return $byte_off
    }
    set n [llength $char_byte_map]
    if {$n == 0} { return 0 }
    # Binary search: find largest i such that map[i] <= byte_off.
    set lo 0
    set hi [expr {$n - 1}]
    while {$lo < $hi} {
        set mid [expr {($lo + $hi + 1) / 2}]
        if {[lindex $char_byte_map $mid] <= $byte_off} {
            set lo $mid
        } else {
            set hi [expr {$mid - 1}]
        }
    }
    return $lo
}

# ---------------------------------------------------------------------------
# Bridge state — populated incrementally during the recursive walk.
# ---------------------------------------------------------------------------

namespace eval ::jcm::bridge {
    # symbols  — list of symbol dicts (each is the dict shape emit_json reads).
    # method_registry — dedup map per qualified_name for method/proc decl-vs-body
    #     replacement (out-of-line iTcl `body Class::method` supersedes prior decl).
    # script_sym_idx — index of the synthetic __script__ symbol in `symbols` so
    #     handlers can mutate its `package_requires` field in place.
    variable symbols
    variable method_registry
    variable script_sym_idx
    variable file_src
    variable file_path
    variable line_offsets
    variable char_byte_map
}

proc ::jcm::bridge::_reset_state {path src} {
    variable symbols
    variable method_registry
    variable script_sym_idx
    variable file_src
    variable file_path
    variable line_offsets
    variable char_byte_map
    set symbols [list]
    array unset method_registry
    array set method_registry {}
    set script_sym_idx -1
    set file_src $src
    set file_path $path
    set line_offsets [build_line_offsets $src]
    set char_byte_map [build_char_to_byte $src]
}

# Append a symbol dict; return its position. Performs method/proc
# dedup (decl→body replacement) by qualified_name.
#
# The dedup mirrors the v1 bridge's policy (out-of-line iTcl body supersedes
# prior pure-decl) so the test_tcl_parser.py port keeps the same shape.
proc ::jcm::bridge::_append_symbol {sym} {
    variable symbols
    variable method_registry
    set kind [dict get $sym kind]
    set qname [dict get $sym qualified_name]
    set keywords [dict get $sym keywords]
    set is_decl [expr {"method_decl" in $keywords || "class_proc_decl" in $keywords}]
    set dedup_kind ""
    if {$kind eq "method"} {
        set dedup_kind method
    } elseif {$kind eq "function" && (
        "class_proc" in $keywords
        || "class_proc_decl" in $keywords
        || "class_proc_body" in $keywords
    )} {
        set dedup_kind function
    }
    if {$dedup_kind ne "" && [info exists method_registry($qname)]} {
        lassign $method_registry($qname) prev_pos prev_is_decl prev_kind
        if {$prev_is_decl && !$is_decl} {
            lset symbols $prev_pos $sym
            set method_registry($qname) [list $prev_pos 0 $prev_kind]
        }
        # Else: keep first body / drop duplicate decl.
        return -1
    }
    lappend symbols $sym
    set pos [expr {[llength $symbols] - 1}]
    if {$dedup_kind ne ""} {
        set method_registry($qname) [list $pos $is_decl $dedup_kind]
    }
    return $pos
}

# Mutate a symbol dict in place at $pos with a new value for $key.
proc ::jcm::bridge::_set_symbol_field {pos key value} {
    variable symbols
    if {$pos < 0} return
    set sym [lindex $symbols $pos]
    dict set sym $key $value
    lset symbols $pos $sym
}

proc ::jcm::bridge::_get_symbol {pos} {
    variable symbols
    return [lindex $symbols $pos]
}

# ---------------------------------------------------------------------------
# Symbol construction — produces the dict shape emit_json serializes.
# ---------------------------------------------------------------------------
#
# Default fields enforce the v2.2 always-present invariants:
#   parent_classes / package_requires / unresolved_dispatches start as [].
#
# parent_classes is emitted on every symbol (Δ0.2 says it lives on classes,
# but emitting [] for non-classes keeps the wire shape uniform; the Python
# wrapper passes it through and consumers ignore it on non-classes).
#
# package_requires is only ever populated on the __script__ symbol per §13.3
# decided=B. We still default it to [] on every symbol so the field exists
# uniformly — Python ignores it elsewhere.

proc ::jcm::bridge::_make_symbol {args} {
    set defaults [dict create \
        name             "" \
        qualified_name   "" \
        kind             "function" \
        signature        "" \
        docstring        "" \
        line             1 \
        end_line         1 \
        byte_offset      0 \
        byte_length      0 \
        parent           "" \
        cyclomatic       0 \
        max_nesting      0 \
        param_count      0 \
        call_references  [list] \
        unresolved_dispatches [list] \
        decorators       [list] \
        keywords         [list] \
        parent_classes   [list] \
        package_requires [list] \
        callees          [list] \
        args             [list] \
    ]
    foreach {k v} $args {
        dict set defaults $k $v
    }
    return $defaults
}

# Translate a CHAR-offset src range (start..end-inclusive in file source) to
# the Symbol field set: line / end_line / byte_offset / byte_length.
proc ::jcm::bridge::_attach_offsets {sym start_char end_char} {
    variable line_offsets
    variable char_byte_map
    set start_line [char_offset_to_line $line_offsets $start_char]
    set end_line   [char_offset_to_line $line_offsets $end_char]
    set byte_off   [char_to_byte $char_byte_map $start_char]
    set byte_end   [char_to_byte $char_byte_map [expr {$end_char + 1}]]
    set byte_len   [expr {$byte_end - $byte_off}]
    dict set sym line $start_line
    dict set sym end_line $end_line
    dict set sym byte_offset $byte_off
    dict set sym byte_length $byte_len
    return $sym
}

# ---------------------------------------------------------------------------
# Synthetic __script__ symbol — host for file-level package_requires.
# ---------------------------------------------------------------------------
#
# Always emitted, even when the file has no top-level top-of-script calls
# (Δ0.2 §13.3 decided=B: package_requires must always be present on
# __script__). The Python wrapper drops the synthetic if it has no signal
# (no calls, no unresolved, no package_requires) — matching the v1 bridge's
# elide policy. With Δ0.2 we keep it whenever package_requires has content.
#
# Returns the index of the symbol within the symbols list.

proc ::jcm::bridge::_synth_script_symbol {} {
    variable file_src
    set len [string length $file_src]
    set end_char [expr {$len > 0 ? $len - 1 : 0}]
    set sym [_make_symbol \
        name __script__ \
        qualified_name __script__ \
        kind module]
    set sym [_attach_offsets $sym 0 $end_char]
    return [_append_symbol $sym]
}

# ---------------------------------------------------------------------------
# Source utilities — extract text within a parent body.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_substr {start_char end_char} {
    variable file_src
    set len [string length $file_src]
    if {$start_char < 0} { set start_char 0 }
    if {$end_char >= $len} { set end_char [expr {$len - 1}] }
    if {$end_char < $start_char} { return "" }
    return [string range $file_src $start_char $end_char]
}

# NOTE: Post-pass procs (_resolve_file_offset_tags, _resolve_offset_in_entry,
# _attach_pragmas, _attribute_out_of_line_bodies, _ensure_file_field,
# _maybe_drop_script) live in bridge_postpasses.tcl as of P1.3 Stream 2.

# ---------------------------------------------------------------------------
# Main recursive walker — drives the whole bridge pass.
#
# walk_recursive consumes a script source plus its file-relative parent
# offset, parses + walks it, and dispatches every event:
#
#   - sub-table A literal-recursion targets (proc, method, namespace eval,
#     class declarations, lambdas) become symbols with recursive sub-walks.
#   - sub-table C handlers (inherit, superclass, package require, try/switch/
#     dict) modify the enclosing symbol or emit data fields.
#   - unresolved kinds (eval_var, var_method, uplevel_var, interp_eval,
#     eval_brackets, var_command, computed_namespace) are routed through
#     unresolved_detector::detect.
#   - pattern_a / pattern_a2 / pattern_b / callback / ensemble / etc.
#     contribute a call-reference name to the parent symbol.
# ---------------------------------------------------------------------------

# Recursively walk a body source. parent_src_offset is the body's CHAR
# offset within the file; parent_sym_idx is the index of the enclosing
# symbol in the global symbols list (or -1 for top-level / __script__).
#
# The walker emits event src_start/src_end as BYTE offsets within
# body_src (per WALKER_CONTRACT_v2_2 §2). We build a per-body
# byte→char map so absolute file offsets stay char-based (which is what
# Tcl's `string index`/`string range` operate on).
proc ::jcm::bridge::walk_recursive {body_src parent_src_offset parent_sym_idx parent_qname} {
    variable file_path
    set parsed [::jcm::disasm::parser::disassemble_and_parse $body_src]
    if {[dict exists $parsed error]} {
        # Disassembly failure — log via stderr and bail. The wrapper falls
        # back to tree-sitter, so bridge failure here is non-fatal.
        puts stderr "DISASM_ERROR file=$file_path msg=[dict get $parsed error]"
        return
    }
    set events [::jcm::disasm::walker::walk $parsed]
    set body_byte_map [build_char_to_byte $body_src]
    foreach ev $events {
        _dispatch_event $ev $body_src $parent_src_offset $parent_sym_idx \
            $parent_qname $body_byte_map
    }
}

# Dispatch one walker event.
proc ::jcm::bridge::_dispatch_event {ev body_src parent_src_offset parent_sym_idx parent_qname body_byte_map} {
    variable file_path
    variable line_offsets

    set kind [dict get $ev kind]

    # Common: file-absolute char offsets for the event's anchored cmd.
    # Walker emits src_start/src_end as BYTE offsets within body_src;
    # convert to char offsets, then add the parent's char-based offset.
    set src_start_b [dict get $ev src_start]
    set src_end_b   [dict get $ev src_end]
    if {$src_start_b < 0} {
        # orphan_pc / unknown anchor — log & skip.
        return
    }
    set src_start [byte_to_char $body_byte_map $src_start_b]
    set src_end   [byte_to_char $body_byte_map $src_end_b]
    set abs_start [expr {$parent_src_offset + $src_start}]
    set abs_end   [expr {$parent_src_offset + $src_end}]
    set cmd_text  [_substr $abs_start $abs_end]

    switch -- $kind {
        disasm_error {
            puts stderr "DISASM_ERROR file=$file_path msg=[dict get $ev reason]"
            return
        }
        unrecognized {
            # Walker boundary recovery — try to recover a call edge from
            # the cmd source. Pattern B `$var(...) method ...` shapes show
            # up as unrecognized because loadArrayStk produces an EXPR
            # specialized slot rather than VAR; the walker's pattern_b
            # predicate misses them. Recover by extracting the second
            # word when the first is variable-shaped.
            set head [_first_word_of_cmd $cmd_text]
            if {[_is_var_word $head]} {
                set second [_nth_word_of_cmd $cmd_text 1]
                if {$second ne "" && ![_is_var_word $second]} {
                    _add_call_to_parent $parent_sym_idx $second
                    # P5.2.6: method_dispatch via pattern_b-shaped recovery
                    # (`$itk_component(eu) method ...` arrives here).
                    set line [char_offset_to_line $line_offsets $abs_start]
                    _add_callee_to_parent $parent_sym_idx \
                        [_make_method_dispatch_entry $second $head $line]
                }
            } else {
                if {$head ne ""} {
                    _add_call_to_parent $parent_sym_idx \
                        [_maybe_two_word_ensemble $head $cmd_text]
                }
            }
            return
        }
        pattern_a {
            _handle_pattern_a $ev $cmd_text $abs_start $abs_end \
                $parent_sym_idx $parent_qname
            return
        }
        pattern_a2 {
            _handle_pattern_a2 $ev $cmd_text $abs_start $abs_end \
                $parent_sym_idx $parent_qname
            return
        }
        pattern_b {
            set method [dict get $ev method]
            _add_call_to_parent $parent_sym_idx $method
            # P5.2.6: structured §5.3 method_dispatch record into callees.
            # call_references stays for cross-language backward compat;
            # callees is the per-call-site multiset for strict diff.
            set receiver [_first_word_of_cmd $cmd_text]
            if {$receiver ne "" && [_is_var_word $receiver]
                    && $method ne "" && ![_is_var_word $method]} {
                set line [char_offset_to_line $line_offsets $abs_start]
                _add_callee_to_parent $parent_sym_idx \
                    [_make_method_dispatch_entry $method $receiver $line]
            }
            return
        }
        callback {
            # Callback events fire when the strcat slot collapses an arg
            # into a single EXPR. Two complementary call shapes exist:
            #   1. Pattern_a-style:   `cmd "$x foo bar"` — head is the call.
            #   2. Pattern_b-style:   `$obj method "$x ..."` — head is var,
            #      so 2nd word is the method.
            #   3. Tk callback shape: `bind $w <Cfg> "$this handleResize"` —
            #      head=bind (a real call), AND the strcat tail's leading
            #      literal (handleResize) is also dispatched at run-time.
            # Rule: always emit the head (as call OR var-derived 2nd word).
            # Emit the strcat method ONLY when head is var-shaped OR when
            # the head is the well-known callback dispatcher (bind etc.) —
            # plain pattern_a shapes shouldn't pull the strcat tail in.
            set head [_first_word_of_cmd $cmd_text]
            if {$head ne "" && ![_is_var_word $head]} {
                _add_call_to_parent $parent_sym_idx \
                    [_maybe_two_word_ensemble $head $cmd_text]
            } else {
                set second [_nth_word_of_cmd $cmd_text 1]
                if {$second ne "" && ![_is_var_word $second]} {
                    _add_call_to_parent $parent_sym_idx $second
                    # P5.2.6: pattern_b-style `$obj method "$x ..."` shape
                    # also produces a §5.3 method_dispatch record.
                    if {[_is_var_word $head]} {
                        set line [char_offset_to_line $line_offsets $abs_start]
                        _add_callee_to_parent $parent_sym_idx \
                            [_make_method_dispatch_entry $second $head $line]
                    }
                }
            }
            set method [dict get $ev method]
            # Method may carry trailing args (e.g. "handleResize %W %w %h").
            # The actual call is the first token; strip the rest.
            if {[regexp {^(\S+)} $method -> first_tok]} { set method $first_tok }
            set is_callback_dispatcher [expr {$head in {bind after fileevent trace}}]
            if {$method ne "" && $method ne $head
                    && $method ne "(strcat-collapsed)"
                    && ![_is_var_word $method]
                    && ($is_callback_dispatcher || [_is_var_word $head])} {
                _add_call_to_parent $parent_sym_idx $method
            }
            return
        }
        ensemble {
            set ens [dict get $ev ensemble]
            set sub [dict get $ev subcommand]
            _add_call_to_parent $parent_sym_idx "${ens} ${sub}"
            # dict for / dict with / dict update / dict map carry a script
            # body that the bytecode compiler inlines — but the walker
            # doesn't surface those inner events because the body is in a
            # nested compile context the disasm parser doesn't expand.
            # Re-extract and recurse so call edges inside the body are
            # captured against the parent symbol.
            #
            # P1.3 bundle (2): all C-row + brace-sweep work goes through
            # the single `dispatch_c` entrypoint. The dict subcommand is
            # passed in `ev_extra` so `_handle_dict` can route correctly.
            if {$ens eq "dict"} {
                _dispatch_c_via_rectbl $ens $cmd_text $abs_start \
                    $parent_sym_idx $parent_qname [dict create subcommand $sub]
            }
            return
        }
        expand_args {
            _add_call_to_parent $parent_sym_idx \
                [_maybe_two_word_ensemble [dict get $ev name] $cmd_text]
            return
        }
        apply_lambda {
            # Inline lambda — recurse if the literal looks parseable.
            set lambda [dict get $ev lambda]
            _maybe_recurse_lambda $lambda $cmd_text $abs_start $parent_sym_idx $parent_qname
            return
        }
        namespace_eval {
            _handle_namespace_eval $ev $cmd_text $abs_start $abs_end \
                $parent_sym_idx $parent_qname
            return
        }
        eval_var - eval_brackets - var_method - uplevel_var - \
        interp_eval - var_command - computed_namespace {
            _handle_unresolved $ev $cmd_text $abs_start $parent_sym_idx
            # eval / uplevel prefix-dispatch shape: `eval $obj method args`
            # concatenates and re-evaluates — surface the literal method
            # word past the var so the static call edge isn't lost.
            if {$kind in {eval_var uplevel_var}} {
                set head [_first_word_of_cmd $cmd_text]
                if {$head in {eval uplevel}} {
                    # Skip leading-uplevel #N levels if present.
                    set start_idx 1
                    if {$head eq "uplevel"} {
                        set second [_nth_word_of_cmd $cmd_text 1]
                        if {[regexp {^[#0-9]} $second]} { set start_idx 2 }
                    }
                    # Skip the var, then the next literal word is the method.
                    set after_var [_nth_word_of_cmd $cmd_text [expr {$start_idx + 1}]]
                    if {$after_var ne "" && ![_is_var_word $after_var]
                            && ![regexp {^[\[\{]} $after_var]} {
                        _add_call_to_parent $parent_sym_idx $after_var
                    }
                }
            }
            # P1.3 bundle (0): `namespace eval $ns BODY` lands here as
            # kind=computed_namespace. The body literal is still parseable —
            # only the namespace NAME is dynamic. Without this recurse the
            # body's inner procs / nested namespaces are silently dropped,
            # which is the data-loss regression closed by the bundle.
            #
            # Cmd shape:  namespace eval NAME-OR-VAR BODY  -> body word idx 3.
            # We recurse against the EXISTING parent (parent_sym_idx /
            # parent_qname) because we don't have a resolved namespace name to
            # synthesize a host symbol — anything emitted inside the body will
            # attribute to the enclosing scope, which is correct for static
            # call-graph + symbol-discovery purposes (the dynamic ns is
            # already reflected via the unresolved_dispatches entry above).
            if {$kind eq "computed_namespace"} {
                _handle_computed_namespace_body_recurse \
                    $cmd_text $abs_start $parent_sym_idx $parent_qname
            }
            return
        }
    }
}

# Framework-lifecycle calls that aren't user-meaningful callees. The v1
# bridge maintains the same skip list so the test suite's "framework calls
# don't count" assertions hold (e.g., `itk_initialize`, `itk_component`).
set ::jcm::bridge::CALL_SKIP_LIST {
    itk_initialize
    itk_component
    itk_option
}

# Add a callee name to the parent symbol's call_references list.
proc ::jcm::bridge::_add_call_to_parent {parent_sym_idx callee} {
    if {$callee eq ""} return
    if {$parent_sym_idx < 0} return
    if {$callee in $::jcm::bridge::CALL_SKIP_LIST} return
    variable symbols
    set sym [lindex $symbols $parent_sym_idx]
    set calls [list]
    if {[dict exists $sym call_references]} {
        set calls [dict get $sym call_references]
    }
    if {$callee ni $calls} {
        lappend calls $callee
        dict set sym call_references $calls
        lset symbols $parent_sym_idx $sym
    }
}

# Append a structured callee record (convention v1.5 §4.2) to the parent
# symbol's callees list.  Unlike call_references which is deduped by name,
# callees keeps one entry per call site — gold corpus / strict diff
# matches multiset semantics.
#
# P5.2.6: invoked from the three pattern_b-shaped emission sites
# (pattern_b, callback when head is $var, unrecognized when head is $var)
# to record method_dispatch callees per §5.3.
proc ::jcm::bridge::_add_callee_to_parent {parent_sym_idx entry} {
    if {$parent_sym_idx < 0} return
    if {![dict exists $entry name]} return
    if {[dict get $entry name] eq ""} return
    variable symbols
    set sym [lindex $symbols $parent_sym_idx]
    set callees [list]
    if {[dict exists $sym callees]} {
        set callees [dict get $sym callees]
    }
    lappend callees $entry
    dict set sym callees $callees
    lset symbols $parent_sym_idx $sym
}

# Build a §5.3 method_dispatch callee entry.  receiver_hint is the
# verbatim source-form of the receiver expression ("$obj", "${obj}",
# "$itk_component(eu)", etc.).  line is the 1-based file line of the
# call site (resolved from char offsets via char_offset_to_line).
proc ::jcm::bridge::_make_method_dispatch_entry {method receiver_hint line} {
    return [dict create \
        name           $method \
        line           $line \
        kind           method_dispatch \
        receiver_hint  $receiver_hint \
        note           "$receiver_hint $method"]
}

# Route an unresolved-kind event through unresolved_detector::detect and
# append the result to the enclosing parent symbol.
#
# cmd_text + parent_src_offset are in CHARS (caller has already done the
# byte→char translation) — the unresolved_detector receives them and
# computes the line via the line_map, which is also char-based.
proc ::jcm::bridge::_handle_unresolved {ev cmd_text abs_start parent_sym_idx} {
    variable file_path
    variable line_offsets
    # Detector expects parent_src_offset + ev.src_start = file offset for
    # line resolution. We've already translated to absolute char offset
    # `abs_start`; pass that as parent_src_offset and zero the event's
    # src_start so the detector's arithmetic recovers the right value.
    set ev_zero $ev
    dict set ev_zero src_start 0
    set ctx [dict create \
        file              $file_path \
        parent_src_offset $abs_start \
        line_map          $line_offsets \
        cmd_text          $cmd_text]
    set entry [::jcm::disasm::unresolved::detect $ev_zero $ctx]
    if {$entry eq {}} return
    if {$parent_sym_idx < 0} return
    variable symbols
    set sym [lindex $symbols $parent_sym_idx]
    set sym [::jcm::disasm::unresolved::append_to_sym $sym $entry]
    lset symbols $parent_sym_idx $sym
}

# ---------------------------------------------------------------------------
# pattern_a / pattern_a2 / namespace_eval handlers.
#
# pattern_a is the workhorse: it covers proc/method/class/namespace/inherit/
# package require/etc. — everything that comes through with a literal head
# word. We classify via Worker 2's recursion tables and dispatch.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_handle_pattern_a {ev cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set name [dict get $ev name]
    set arg_count [dict get $ev arg_count]
    set slots [_synth_slots_from_cmd $cmd_text]

    # Sub-table C first — schema-only handlers (inherit/superclass/
    # package require/try/switch/dict). They mutate the enclosing symbol
    # rather than introducing a new one.
    set c_handler [::jcm::disasm::rectbl::classify_c $name $slots]
    if {$c_handler ne ""} {
        _apply_c_handler $c_handler $name $cmd_text $abs_start \
            $parent_sym_idx $parent_qname
    }

    # Sub-table A — definition forms. Multiple matches possible (e.g. C
    # handler ran for `package require` AND we still want the import symbol).
    set a_row [::jcm::disasm::rectbl::classify_a $name $slots $arg_count]
    if {[llength $a_row] > 0} {
        _apply_a_row $a_row $name $cmd_text $abs_start $abs_end \
            $parent_sym_idx $parent_qname
        return
    }

    # NOTE: `package require / provide` does NOT need a special direct-emit
    # branch here. The C handler at line 731-734 above (classify_c → routes
    # to recursion_tables::_handle_package_require) sets the _emit_import
    # marker on __script__; _apply_c_handler realises it via
    # _emit_import_record, producing exactly one kind=import symbol per
    # `package require` per Δ0.2 C1 (BOTH the field AND the import symbol).
    # An earlier draft of this branch double-emitted; removed in P1.2 fix.

    # if / while / for / foreach / lmap: walker doesn't see body events
    # because the bytecode compiler inlines them into a sub-context the
    # disasm parser doesn't expand.  Recurse into each brace-delimited body
    # word so calls inside surface against the parent symbol.
    #
    # P1.3 bundle (2): all C-row + brace-sweep work goes through the
    # single `dispatch_c` entrypoint. switch/try are SUBTABLE_C rows
    # whose handlers now perform body recursion themselves (already run
    # via _apply_c_handler above); the names below fall to dispatch_c's
    # brace-sweep fallback because they don't carry schema mutations and
    # therefore don't appear in SUBTABLE_C.
    if {$name in {if while for foreach lmap}} {
        _dispatch_c_via_rectbl $name $cmd_text $abs_start \
            $parent_sym_idx $parent_qname [dict create]
        return
    }

    # iTcl out-of-line method body: bare `body Class::method args body`.
    if {$name eq "body" || $name eq "::itcl::body" || $name eq "itcl::body"} {
        _emit_itcl_body $cmd_text $abs_start $abs_end $parent_sym_idx $parent_qname
        return
    }
    if {$name eq "configbody" || $name eq "::itcl::configbody" || $name eq "itcl::configbody"} {
        _emit_itcl_configbody $cmd_text $abs_start $abs_end $parent_sym_idx $parent_qname
        return
    }

    # Tk-style `-command "..."` / `-script "..."` flag values carry
    # script bodies that should be recursed for call-edge capture. The
    # walker sees the cmd as one pattern_a with the body as a quoted-arg
    # literal — no event surfaces inside. Sweep the cmd words for known
    # script flags and recurse manually into the next word's content.
    _sweep_script_flags $cmd_text $abs_start $parent_sym_idx $parent_qname

    # Otherwise — treat the head as a callee on the parent.
    # P5.2.5: for kept-ensemble dispatchers (grid / pack / wm / winfo /
    # image / font / delete) upgrade the 1-word emission to the 2-word
    # (or 3-word for `image create TYPE`) phrase per convention §5.10
    # when the next cmd_text word is a documented subcommand literal.
    _add_call_to_parent $parent_sym_idx \
        [_maybe_two_word_ensemble $name $cmd_text]
}

# Tk command flags whose value is a script body the bridge should recurse
# into for call-graph capture. -text / -label / etc. are excluded so prose
# doesn't leak as code.
set ::jcm::bridge::SCRIPT_FLAGS {
    -command -script -yscrollcommand -xscrollcommand
    -postcommand -menucommand -invalidcommand -validatecommand
    -bind
}

proc ::jcm::bridge::_sweep_script_flags {cmd_text abs_start parent_sym_idx parent_qname} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} return
    set total [llength $parts]
    for {set i 1} {$i < $total - 1} {incr i} {
        # Backslash-newline continuations leave leading whitespace inside
        # word boundaries when lrange parses; trim before matching against
        # the script-flag whitelist.
        set w [string trim [lindex $parts $i]]
        if {$w in $::jcm::bridge::SCRIPT_FLAGS} {
            set value_idx [expr {$i + 1}]
            set ext [::jcm::disasm::body::extract_from_event $cmd_text $value_idx $abs_start]
            if {[dict get $ext ok]} {
                walk_recursive [dict get $ext body_src] \
                    [dict get $ext body_offset] $parent_sym_idx $parent_qname
            }
            incr i
        }
    }
}

proc ::jcm::bridge::_handle_pattern_a2 {ev cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    # ::ns method form — record both the qualified ns and the method as
    # callees on the parent. Mirrors the v1 bridge `::config getImageUrl`
    # treatment so test_fqn_global_dispatch_captures_method passes.
    set fqn [dict get $ev fqn]
    set method [dict get $ev method]
    _add_call_to_parent $parent_sym_idx $fqn
    if {$method ne ""} {
        _add_call_to_parent $parent_sym_idx $method
    }
}

# ---------------------------------------------------------------------------
# Sub-table A application — emit a symbol AND recurse into its body.
# ---------------------------------------------------------------------------
#
# Body extraction goes through compute_body_base::extract_from_event so
# multi-line / quoted / brace bodies all resolve consistently. A dynamic
# body (bracket-substitution at the body slot) tags the symbol's
# unresolved_dispatches with kind=dynamic_body and skips recursion.
#
# Recursion happens for `recurse_via in {script lambda}`. Lambda re-disasm
# is identical to script for our purposes (the lambda's body is what the
# walker emits events for, and disassemble_and_parse handles both forms).

proc ::jcm::bridge::_apply_a_row {row name cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    lassign $row first second body_idx recurse_via kind extra
    # Resolve the body word index using the cmd's word count.
    set total_words [_count_cmd_words $cmd_text]
    set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx $body_idx $total_words]
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text $resolved_idx $abs_start]

    # Emit symbol (most rows do) — anonymous rows leave kind == "".
    set new_sym_idx -1
    set new_qname $parent_qname
    if {$kind ne ""} {
        set sym_name [_extract_symbol_name $cmd_text $name $row $extra]
        set qname [_qualify $sym_name $parent_qname]
        set sig [_build_signature $cmd_text $name $sym_name $kind]
        set keywords [_keywords_for_kind $kind $extra]
        # constructor / destructor / configbody surface as kind=method on the
        # wire (v1 emit_symbol convention; tests pin kind=method but check
        # name=constructor / name=destructor).
        set wire_kind $kind
        if {$kind in {constructor destructor configbody}} { set wire_kind method }
        set sym [_make_symbol \
            name $sym_name \
            qualified_name $qname \
            kind $wire_kind \
            signature $sig \
            parent $parent_qname \
            keywords $keywords]
        set sym [_attach_offsets $sym $abs_start $abs_end]
        set new_sym_idx [_append_symbol $sym]
        set new_qname $qname
    }

    # itk_option define has its body as the OPTIONAL trailing config block.
    # Only recurse when the body slot is a real brace-word; the default-
    # value slot (a quoted string) must NOT be recursed (e.g.
    # `itk_option define -switch resname Class "::dcss"` — `::dcss` is data).
    if {$first eq "itk_option"} {
        set body_word_start [::jcm::disasm::body::find_word_start $cmd_text $resolved_idx]
        if {$body_word_start < 0
                || [string index $cmd_text $body_word_start] ne "\{"} {
            return
        }
    }

    # eval / uplevel literal_only guard: when the body is a VAR (e.g.
    # `eval $itk_component(x) method args`), don't try to recurse into it
    # as a script. Instead surface the next literal word as a call edge
    # (matching v1's prefix-dispatch behavior). Walker would normally
    # emit eval_var for this shape, but loadArrayStk reduces the var to
    # an EXPR slot so the eval_var predicate misses; we recover here.
    if {[dict exists $extra literal_only] && [dict get $extra literal_only]} {
        set body_word [_nth_word_of_cmd $cmd_text $resolved_idx]
        if {$body_word ne "" && [_is_var_word $body_word]} {
            set after_var [_nth_word_of_cmd $cmd_text [expr {$resolved_idx + 1}]]
            if {$after_var ne "" && ![_is_var_word $after_var]
                    && ![regexp {^[\[\{]} $after_var]} {
                _add_call_to_parent $parent_sym_idx $after_var
            }
            return
        }
    }

    # Dynamic body — tag and skip recursion.
    if {[dict get $extracted dynamic]} {
        if {$new_sym_idx >= 0} {
            variable symbols
            variable file_path
            set sym [lindex $symbols $new_sym_idx]
            # The `file` field on the symbol is populated by
            # _ensure_file_field in the post-pass, so it isn't available
            # here yet. Use the bridge's file_path state directly.
            set entry [dict create kind dynamic_body \
                line [dict get $sym line] \
                file $file_path]
            set sym [::jcm::disasm::unresolved::append_to_sym $sym $entry]
            lset symbols $new_sym_idx $sym
        }
        return
    }

    # If body extraction failed, the symbol is still emitted (declaration-
    # only methods etc.) but we don't recurse.
    if {![dict get $extracted ok]} return

    set body_src [dict get $extracted body_src]
    set body_offset [dict get $extracted body_offset]

    # Compute call-graph + unresolved + sub-symbols by re-entering the walker
    # against the body. Pass the new symbol as parent if we emitted one;
    # otherwise events accumulate against the outer parent.
    set recur_parent_idx $parent_sym_idx
    set recur_parent_qname $parent_qname
    if {$new_sym_idx >= 0} {
        set recur_parent_idx $new_sym_idx
        set recur_parent_qname $new_qname
    }
    walk_recursive $body_src $body_offset $recur_parent_idx $recur_parent_qname

    # Compute complexity / nesting / param_count if this is a code-bearing
    # symbol. Procs/methods get a real param count from the args slot when
    # available; classes/namespaces leave it 0.
    if {$new_sym_idx >= 0 && $kind in {function method constructor destructor configbody}} {
        _attach_metrics $new_sym_idx $cmd_text $body_src $row
    }
}

# Apply a sub-table C handler. Handlers mutate the enclosing symbol's
# parent_classes / package_requires fields and may set _emit_import.
proc ::jcm::bridge::_apply_c_handler {handler_proc name cmd_text abs_start parent_sym_idx parent_qname} {
    variable symbols
    variable file_path
    if {$parent_sym_idx < 0} {
        # No enclosing symbol — for `package require` / file-scope
        # `inherit`, this is __script__. Use the synthesized __script__.
        set parent_sym_idx [_get_or_synth_script]
    }
    set sym [lindex $symbols $parent_sym_idx]
    # Call the handler — under P1.3 bundle (2) handlers also receive
    # walk_cb + parent_qname + parent_sym_idx + ev_extra so body-recursion
    # rows (try/switch/dict) can re-enter the bridge walker. Schema-only
    # rows (inherit/superclass/package_require) ignore the new params.
    set walk_cb [list ::jcm::bridge::walk_recursive]
    if {[catch {
        set sym_after [::jcm::disasm::rectbl::$handler_proc $cmd_text \
            $abs_start $sym $file_path 0 $walk_cb $parent_qname \
            $parent_sym_idx [dict create]]
    } err]} {
        puts stderr "C_HANDLER_ERROR proc=$handler_proc msg=$err"
        return
    }
    # Merge schema-only handler outputs (parent_classes / package_requires
    # / _emit_import marker) into the LIVE symbol — body-recursion handlers
    # may have already mutated `symbols` via walk_recursive while we held a
    # snapshot, so we must NOT overwrite with the pre-handler $sym. Re-read
    # the live symbol and copy the handler-owned schema keys forward.
    set live [lindex $symbols $parent_sym_idx]
    foreach k {parent_classes package_requires _emit_import} {
        if {[dict exists $sym_after $k]} {
            dict set live $k [dict get $sym_after $k]
        }
    }
    lset symbols $parent_sym_idx $live
    # If the handler set _emit_import (package require), realise it.
    if {[dict exists $live _emit_import]} {
        _emit_import_record $live $abs_start
        # Strip the marker so it doesn't ride out in the JSON.
        set sym2 [lindex $symbols $parent_sym_idx]
        dict unset sym2 _emit_import
        lset symbols $parent_sym_idx $sym2
    }
}

# P1.3 bundle (2) — Module boundary B. Single bridge-side entrypoint that
# wraps recursion_tables::dispatch_c so the bridge driver only ever names
# ONE recursion-table proc. Handles enclosing_sym lookup + post-call
# write-back and the _emit_import marker realization. Used for:
#   - dict ensemble events (subcommand carried in ev_extra)
#   - switch / try / if / while / for / foreach / lmap pattern_a events
#     (no extras needed; falls through to brace-body sweep)
proc ::jcm::bridge::_dispatch_c_via_rectbl {ev_name cmd_text abs_start parent_sym_idx parent_qname ev_extra} {
    variable symbols
    variable file_path
    if {$parent_sym_idx < 0} {
        # No enclosing symbol — for `package require` / file-scope
        # `inherit`, this is __script__. Use the synthesized __script__.
        set parent_sym_idx [_get_or_synth_script]
    }
    set sym [lindex $symbols $parent_sym_idx]
    set walk_cb [list ::jcm::bridge::walk_recursive]
    if {[catch {
        set sym_after [::jcm::disasm::rectbl::dispatch_c $ev_name $cmd_text \
            $abs_start $sym $file_path 0 $walk_cb $parent_qname \
            $parent_sym_idx $ev_extra]
    } err]} {
        puts stderr "DISPATCH_C_ERROR ev=$ev_name msg=$err"
        return
    }
    # Merge schema-only mutations forward without clobbering call edges
    # added by walk_recursive during dispatch_c (see _apply_c_handler).
    set live [lindex $symbols $parent_sym_idx]
    foreach k {parent_classes package_requires _emit_import} {
        if {[dict exists $sym_after $k]} {
            dict set live $k [dict get $sym_after $k]
        }
    }
    lset symbols $parent_sym_idx $live
    if {[dict exists $live _emit_import]} {
        _emit_import_record $live $abs_start
        set sym2 [lindex $symbols $parent_sym_idx]
        dict unset sym2 _emit_import
        lset symbols $parent_sym_idx $sym2
    }
}

# Get an existing __script__ symbol index, or synthesize one if absent.
proc ::jcm::bridge::_get_or_synth_script {} {
    variable script_sym_idx
    if {$script_sym_idx < 0} {
        set script_sym_idx [_synth_script_symbol]
    }
    return $script_sym_idx
}

# Emit a kind=import symbol from a marker placed by _handle_package_require.
# The Δ0.2 C1 rule: package require populates BOTH the package_requires
# field AND a kind=import symbol.
proc ::jcm::bridge::_emit_import_record {script_sym abs_start} {
    set marker [dict get $script_sym _emit_import]
    set pkg [dict get $marker name]
    set ver [dict get $marker version]
    set sig "package require $pkg"
    if {$ver ne "" && $ver ne "null"} { set sig "$sig $ver" }
    set sym [_make_symbol \
        name $pkg \
        qualified_name "require:$pkg" \
        kind import \
        signature $sig \
        keywords [list package_require]]
    set sym [_attach_offsets $sym $abs_start [expr {$abs_start + [string length $sig] - 1}]]
    _append_symbol $sym
}

# NOTE: _emit_import_for_package was removed in P1.2 (fixed
# double-emission of kind=import symbols for `package require`). The
# canonical emission path is the marker set by recursion_tables::_handle_package_require
# and realised by _apply_c_handler → _emit_import_record above.

# ---------------------------------------------------------------------------
# Out-of-line iTcl body: `body Class::method args body` and `configbody`.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_emit_itcl_body {cmd_text abs_start abs_end parent_sym_idx parent_qname} {
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
    set class_scope [namespace qualifiers $qualified]
    set sig "$kw $target \{$args_str\}"
    set sym [_make_symbol \
        name $short_name \
        qualified_name $qualified \
        kind method \
        signature $sig \
        parent $class_scope \
        param_count [_count_args $args_str] \
        keywords [list itcl_body]]
    set sym [_attach_offsets $sym $abs_start $abs_end]
    set sym_idx [_append_symbol $sym]
    if {$sym_idx >= 0} {
        # Recurse into the body to capture nested calls.
        set body_offset [_find_word_in_cmd_abs $cmd_text $abs_start 3]
        if {$body_offset >= 0} {
            walk_recursive $body $body_offset $sym_idx $qualified
        }
    }
}

proc ::jcm::bridge::_emit_itcl_configbody {cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return }
    if {[llength $parts] < 3} { return }
    set kw [lindex $parts 0]
    set target [lindex $parts 1]
    set body [lindex $parts 2]
    if {![string match "*::*" $target]} { return }
    set qualified [string trimleft $target ":"]
    set short_name [namespace tail $target]
    if {$short_name eq ""} { set short_name $target }
    set class_scope [namespace qualifiers $qualified]
    set sig "$kw $target"
    set sym [_make_symbol \
        name $short_name \
        qualified_name $qualified \
        kind method \
        signature $sig \
        parent $class_scope \
        keywords [list configbody]]
    set sym [_attach_offsets $sym $abs_start $abs_end]
    set sym_idx [_append_symbol $sym]
    if {$sym_idx >= 0} {
        set body_offset [_find_word_in_cmd_abs $cmd_text $abs_start 2]
        if {$body_offset >= 0} {
            walk_recursive $body $body_offset $sym_idx $qualified
        }
    }
}

# ---------------------------------------------------------------------------
# namespace_eval handler — special-cases the v2.2 walker namespace_eval
# event (which carries the resolved ns + body slots directly).
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_handle_namespace_eval {ev cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set ns [dict get $ev ns]
    if {$ns eq ""} {
        # Computed-namespace fallback shouldn't happen here (v2.2 emits a
        # distinct computed_namespace event for that case) — guard anyway.
        return
    }
    # The walker's body field is a truncated literal preview from the
    # disassembler comment; we must re-extract from the source text via the
    # body-base helper to capture the full body for recursion + export scan.
    # Body word index for "namespace eval NAME BODY" is 3.
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text 3 $abs_start]
    set body ""
    if {[dict get $extracted ok]} {
        set body [dict get $extracted body_src]
    }
    set qname [_qualify $ns $parent_qname]
    set sig "namespace eval $qname"
    set exports [_extract_namespace_exports $body]
    set keywords [list]
    if {[llength $exports] > 0} { lappend keywords has_exports }
    set sym [_make_symbol \
        name [namespace tail $ns] \
        qualified_name $qname \
        kind namespace \
        signature $sig \
        parent $parent_qname \
        decorators $exports \
        keywords $keywords]
    set sym [_attach_offsets $sym $abs_start $abs_end]
    set sym_idx [_append_symbol $sym]
    if {$sym_idx >= 0 && [dict get $extracted ok]} {
        walk_recursive $body [dict get $extracted body_offset] $sym_idx $qname
    }
}

# P1.3 bundle (0) — body recursion for computed_namespace events.
#
# `namespace eval $ns BODY` arrives as a computed_namespace walker event.
# The unresolved_detector tags it; previously dispatch fell off here and the
# BODY's inner procs / nested namespaces were lost (the critic-flagged data
# regression). We can't synthesize a namespace symbol because the name is
# dynamic, but the body literal is parseable — recurse against the enclosing
# parent so call-graph + nested-symbol discovery survives.
#
# Failure modes (all soft, mirroring the disasm-error / orphan-pc posture):
#   - body word also non-literal (computed BODY): extract_from_event returns
#     ok=0 with dynamic=1 — we silently skip (the unresolved tag carries the
#     diagnostic).
#   - body slot present but unparseable (brace mismatch within): walk_recursive
#     emits its own DISASM_ERROR via stderr.
#   - any uncaught error: reported via stderr + return; bridge stays healthy.
proc ::jcm::bridge::_handle_computed_namespace_body_recurse {cmd_text abs_start parent_sym_idx parent_qname} {
    # `namespace eval NAME-OR-VAR BODY` — BODY is the 4th word (index 3).
    if {[catch {
        set extracted [::jcm::disasm::body::extract_from_event $cmd_text 3 $abs_start]
    } err]} {
        puts stderr "COMPUTED_NS_RECURSE_FAIL stage=extract msg=$err"
        return
    }
    if {![dict get $extracted ok]} {
        # Body is itself dynamic / unbalanced — graceful skip.
        return
    }
    if {[catch {
        walk_recursive [dict get $extracted body_src] \
            [dict get $extracted body_offset] $parent_sym_idx $parent_qname
    } err]} {
        puts stderr "COMPUTED_NS_RECURSE_FAIL stage=walk msg=$err"
    }
}

proc ::jcm::bridge::_extract_namespace_exports {body} {
    set out [list]
    foreach line [split $body "\n"] {
        set trim [string trim $line]
        if {[regexp {^namespace\s+export\s+(?:-clear\s+)?(.*)} $trim -> exports]} {
            foreach token [split $exports] {
                set t [string trim $token]
                if {$t eq "" || $t eq "-clear"} continue
                if {[regexp {^[A-Za-z_][\w*?\[\]]*$} $t]} {
                    lappend out $t
                }
            }
        }
    }
    return $out
}

proc ::jcm::bridge::_find_namespace_body_offset {cmd_text abs_start} {
    # Body is the 4th word (namespace eval NAME BODY) — index 3.
    return [_find_word_in_cmd_abs $cmd_text $abs_start 3]
}

# ---------------------------------------------------------------------------
# Lambda re-entry (apply form).
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_maybe_recurse_lambda {lambda cmd_text abs_start parent_sym_idx parent_qname} {
    # The lambda is a list {ARGS BODY ?NS?}. Extract BODY (index 1) and
    # recurse if it looks parseable. We accept failures silently — apply
    # with a $-var lambda is unresolvable at static time.
    if {[catch {set body [lindex $lambda 1]}]} return
    if {$body eq ""} return
    if {[catch {
        walk_recursive $body 0 $parent_sym_idx $parent_qname
    } err]} {
        puts stderr "LAMBDA_RECURSE_FAIL msg=$err"
    }
}

# ---------------------------------------------------------------------------
# Helpers — slot synthesis for classify_a/c, name extraction, signatures.
# ---------------------------------------------------------------------------

# classify_a/c expect a slot list (the same shape opcode_walker.tcl uses).
# When we only have the cmd text, we can derive a minimal slot list from
# the first words. This is sufficient because the classifier only checks
# slot[1].kind/value (second-word match for multi-word commands).
proc ::jcm::bridge::_synth_slots_from_cmd {cmd_text} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return [list] }
    set slots [list]
    foreach p $parts {
        lappend slots [dict create kind LITERAL value $p method "" src_offset 0]
    }
    return $slots
}

# NOTE: Recursion-routing for switch/try/dict/generic-brace bodies
# (recurse_brace_bodies, recurse_dict_body, _recurse_switch, _recurse_try,
# _recurse_generic_bodies) lives in recursion_tables.tcl as of P1.3 Stream
# 2 (Task #16 (F)). The bridge calls them via the table-driven dispatchers
# and passes `[list ::jcm::bridge::walk_recursive]` as the walker
# callback so the recursion-table file stays free of bridge-namespace
# dependencies.

# ---------------------------------------------------------------------------
# P5.2.5 — convention §5.10 / §7.5 kept-ensemble 2-word emission.
#
# Tk geometry / window-management ensembles (grid, pack, place, wm,
# winfo, image, font) and the iTcl `delete` command are NOT on the
# Tier 2 filter — they ARE recorded as architectural callees.  Per
# §5.10 / §7.5 they use the 2-word naming convention when the second
# word is a documented subcommand: `grid rowconfigure` instead of
# bare `grid`, `winfo exists` instead of bare `winfo`, etc.  Bare
# single-word forms (`grid $w`, `pack $w`) stay 1-word when the
# second word is a value, not a subcommand.
#
# The bytecode walker emits these as pattern_a 1-word calls because
# the Tcl compiler treats them as ordinary invocations (not specialized
# ensemble dispatch).  This helper inspects cmd_text post-hoc and
# upgrades to the 2-word form when the second word is a recognized
# subcommand literal.
#
# The `image create TYPE` 3-word form (§5.10) is also recognized.
# ---------------------------------------------------------------------------

namespace eval ::jcm::bridge {
    variable _kept_ensemble_subs
    array unset _kept_ensemble_subs
    array set _kept_ensemble_subs {}

    # grid — Tk [grid.htm]
    foreach _sub {
        anchor bbox columnconfigure configure forget info location
        propagate remove rowconfigure size slaves
    } { set _kept_ensemble_subs(grid:$_sub) 1 }

    # pack — Tk [pack.htm]
    foreach _sub {
        configure forget info propagate slaves
    } { set _kept_ensemble_subs(pack:$_sub) 1 }

    # place — Tk [place.htm]
    foreach _sub {
        configure forget info slaves
    } { set _kept_ensemble_subs(place:$_sub) 1 }

    # wm — Tk [wm.htm]
    foreach _sub {
        aspect attributes client colormapwindows command deiconify
        focusmodel forget frame geometry group iconbitmap iconify
        iconmask iconname iconphoto iconposition iconwindow manage
        maxsize minsize overrideredirect positionfrom protocol
        resizable sizefrom stackorder state title transient withdraw
    } { set _kept_ensemble_subs(wm:$_sub) 1 }

    # winfo — Tk [winfo.htm]
    foreach _sub {
        atom atomname cells children class colormapfull containing depth
        exists fpixels geometry height id interps ismapped manager name
        parent pathname pixels pointerx pointerxy pointery reqheight
        reqwidth rgb rootx rooty screen screencells screendepth
        screenheight screenmmheight screenmmwidth screenvisual
        screenwidth server toplevel viewable visual visualid
        visualsavailable vrootheight vrootwidth vrootx vrooty width x y
    } { set _kept_ensemble_subs(winfo:$_sub) 1 }

    # image — Tk [image.htm].  `image create TYPE` (3-word) is handled
    # specially in _maybe_two_word_ensemble.
    foreach _sub {
        create delete height inuse names type types width
    } { set _kept_ensemble_subs(image:$_sub) 1 }

    # font — Tk [font.htm]
    foreach _sub {
        actual configure create delete families measure metrics names
    } { set _kept_ensemble_subs(font:$_sub) 1 }

    # iTcl delete — [ItclCmd/index]
    foreach _sub {
        object class namespace
    } { set _kept_ensemble_subs(delete:$_sub) 1 }

    unset _sub
}

# Return the multi-word phrase if $name is a kept-ensemble dispatcher
# whose next cmd_text word is a recognized subcommand; otherwise
# return $name unchanged.  Also handles the `image create TYPE` 3-word
# form per convention §5.10 (v1.3 P3.1) when TYPE is a literal.
proc ::jcm::bridge::_maybe_two_word_ensemble {name cmd_text} {
    variable _kept_ensemble_subs
    if {$name ni {grid pack place wm winfo image font delete}} {
        return $name
    }
    set sub [_nth_word_of_cmd $cmd_text 1]
    if {$sub eq "" || [_is_var_word $sub]} { return $name }
    if {[string index $sub 0] eq "\["} { return $name }
    if {![info exists _kept_ensemble_subs($name:$sub)]} { return $name }
    # `image create TYPE`: when TYPE is a literal word, emit 3-word
    # phrase per §5.10 (v1.3 P3.1 — image create photo, image create
    # bitmap, etc.).  When TYPE is variable-substituted, stay 2-word.
    if {$name eq "image" && $sub eq "create"} {
        set type [_nth_word_of_cmd $cmd_text 2]
        if {$type ne "" && ![_is_var_word $type] \
                && [string index $type 0] ne "\["} {
            return "image create $type"
        }
    }
    return "$name $sub"
}

# First word of a command source — used to recover the call name when the
# walker reduces the cmd to a strcat callback.
proc ::jcm::bridge::_first_word_of_cmd {cmd_text} {
    return [_nth_word_of_cmd $cmd_text 0]
}

# Nth word (0-based) of a command source. Uses lrange when the cmd parses
# as a Tcl list, otherwise falls back to compute_body_base's word walker
# (which handles backslash-newline continuations + unbalanced brace-in-
# string idioms that defeat list parsing).
proc ::jcm::bridge::_nth_word_of_cmd {cmd_text n} {
    if {![catch {set parts [lrange $cmd_text 0 end]}]} {
        if {$n >= [llength $parts]} { return "" }
        return [string trim [lindex $parts $n]]
    }
    set start [::jcm::disasm::body::find_word_start $cmd_text $n]
    if {$start < 0} { return "" }
    set crange [::jcm::disasm::body::word_content_range $cmd_text $start]
    if {$crange eq {}} { return "" }
    lassign $crange cs ce
    return [string trim [string range $cmd_text $cs $ce]]
}

# Variable-shaped word: starts with `$` (Pattern B receiver) — used to
# distinguish callable head words from runtime values.
proc ::jcm::bridge::_is_var_word {w} {
    if {$w eq ""} { return 0 }
    expr {[string index $w 0] eq "\$"}
}

proc ::jcm::bridge::_count_cmd_words {cmd_text} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        # Fallback: rough whitespace tokenization.
        return [llength [regexp -all -inline {\S+} $cmd_text]]
    }
    return [llength $parts]
}

# Pick the symbol's display name for an A-row.
#   - proc / method / public proc / etc.: word at index 1 (or 2 for `public method`).
#   - namespace eval NAME body: NAME at index 2 — but the namespace_eval
#     handler runs separately; this is for non-namespace A rows.
#   - itcl::class NAME body: NAME at index 1.
#   - oo::class create NAME body: NAME at index 2.
#   - itk_component add NAME create-body config-body: NAME at index 2.
#   - constructor / destructor: kind-name itself.
proc ::jcm::bridge::_extract_symbol_name {cmd_text head row extra} {
    lassign $row first second body_idx recurse_via kind row_extra
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return $head }
    set total [llength $parts]
    switch -- $first {
        proc - method - body - configbody - coroutine {
            if {$total >= 2} { return [lindex $parts 1] }
        }
        public - private - protected {
            # `public method NAME args body` -> NAME at index 2
            if {$total >= 3} { return [lindex $parts 2] }
        }
        constructor { return constructor }
        destructor  { return destructor }
        namespace {
            if {$total >= 3} { return [lindex $parts 2] }
        }
        itcl::class - ::itcl::class - class {
            if {$total >= 2} { return [lindex $parts 1] }
        }
        oo::class - ::oo::class {
            # oo::class create NAME body
            if {$total >= 3} { return [lindex $parts 2] }
        }
        itk_component {
            # itk_component add ?-protected? NAME body config
            if {$total >= 3} {
                set candidate [lindex $parts 2]
                if {[string match "-*" $candidate] && $total >= 4} {
                    set candidate [lindex $parts 3]
                }
                return $candidate
            }
        }
        itk_option {
            # itk_option define -switch resname ClassName default ?config?
            if {$total >= 3} { return [lindex $parts 2] }
        }
        apply { return "(lambda)" }
    }
    return $head
}

proc ::jcm::bridge::_qualify {name parent_qname} {
    # Preserve leading "::" so test-pinned qualified names like "::app::config"
    # round-trip; the v1 bridge intentionally kept absolute namespace paths.
    if {[string match "::*" $name]} { return $name }
    if {$parent_qname eq "" || $parent_qname eq "__script__"} { return $name }
    return "${parent_qname}::${name}"
}

# Build the signature string — kept simple, matches v1 emit_symbol shape
# enough to keep test_proc_has_signature passing.
proc ::jcm::bridge::_build_signature {cmd_text head sym_name kind} {
    if {[catch {set parts [lrange $cmd_text 0 end]}]} {
        return "$head $sym_name"
    }
    switch -- $kind {
        function {
            set args ""
            if {[llength $parts] >= 3} { set args [lindex $parts 2] }
            return "proc $sym_name \{$args\}"
        }
        method {
            set args ""
            set name $sym_name
            # public/private/protected method NAME args
            if {[lindex $parts 0] in {public private protected} && [llength $parts] >= 4} {
                set args [lindex $parts 3]
                set prefix [lindex $parts 0]
                return "$prefix method $name \{$args\}"
            }
            # body Class::method args body
            if {[lindex $parts 0] eq "body" && [llength $parts] >= 3} {
                set args [lindex $parts 2]
                return "body [lindex $parts 1] \{$args\}"
            }
            if {[llength $parts] >= 3} { set args [lindex $parts 2] }
            return "method $name \{$args\}"
        }
        constructor {
            set args ""
            if {[llength $parts] >= 2} { set args [lindex $parts 1] }
            return "constructor \{$args\}"
        }
        destructor { return "destructor" }
        namespace { return "namespace eval $sym_name" }
        class {
            set head_kw [lindex $parts 0]
            return "$head_kw $sym_name"
        }
        component { return "itk_component add $sym_name" }
        interface { return "itk_option define $sym_name" }
        coroutine { return "coroutine $sym_name" }
        configbody { return "configbody $sym_name" }
    }
    return "$head $sym_name"
}

# Map A-row kind into the keywords list expected by tests / dedup logic.
proc ::jcm::bridge::_keywords_for_kind {kind extra} {
    set kw [list]
    switch -- $kind {
        method      { lappend kw method }
        constructor { lappend kw constructor }
        destructor  { lappend kw destructor }
        class       { lappend kw class }
        namespace   { lappend kw namespace }
        component   { lappend kw itk_component }
        interface   { lappend kw itk_option }
    }
    foreach {k v} $extra {
        lappend kw $k
    }
    return $kw
}

proc ::jcm::bridge::_count_args {args_str} {
    if {$args_str eq ""} { return 0 }
    if {[catch {set parts [lrange $args_str 0 end]}]} {
        return [llength [regexp -all -inline {\S+} $args_str]]
    }
    return [llength $parts]
}

# Find the absolute char offset of the n-th word inside cmd_text whose
# absolute start is abs_start.
proc ::jcm::bridge::_find_word_in_cmd_abs {cmd_text abs_start word_idx} {
    set rel [::jcm::disasm::body::find_word_start $cmd_text $word_idx]
    if {$rel < 0} { return -1 }
    # word_content_range returns the inside of the delimiter (brace/quote)
    # for body words — that's the offset we want for the body's char 0.
    set crange [::jcm::disasm::body::word_content_range $cmd_text $rel]
    if {$crange eq {}} { return [expr {$abs_start + $rel}] }
    lassign $crange cs _ce
    return [expr {$abs_start + $cs}]
}

# ---------------------------------------------------------------------------
# Metrics — cyclomatic, max nesting, param_count.
#
# Re-derived from first principles per §0.2 rule 4. The implementations
# match v1's keyword-counting heuristics; they're deliberately simple
# because the index value of these metrics is for triage, not precision.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::_attach_metrics {sym_idx cmd_text body_src row} {
    variable symbols
    set sym [lindex $symbols $sym_idx]
    # param_count from args slot (cmd word index varies by row form).
    set args_str [_extract_args_for_row $cmd_text $row]
    set param_count [_count_args $args_str]
    set cyclo [_count_cyclomatic $body_src]
    set nest  [_count_max_nesting $body_src]
    dict set sym param_count $param_count
    dict set sym cyclomatic $cyclo
    dict set sym max_nesting $nest
    # Annotations (uplevel/upvar/global_access/dynamic_eval) on decorators.
    set ann [_detect_annotations $body_src]
    set decorators $ann
    if {[dict exists $sym decorators]} {
        set existing [dict get $sym decorators]
        foreach a $ann { if {$a ni $existing} { lappend existing $a } }
        set decorators $existing
    }
    dict set sym decorators $decorators
    lset symbols $sym_idx $sym
}

proc ::jcm::bridge::_extract_args_for_row {cmd_text row} {
    lassign $row first second body_idx recurse_via kind extra
    if {[catch {set parts [lrange $cmd_text 0 end]}]} { return "" }
    switch -- $first {
        proc - method - coroutine {
            if {[llength $parts] >= 3} { return [lindex $parts 2] }
        }
        public - private - protected {
            if {[llength $parts] >= 4} { return [lindex $parts 3] }
        }
        constructor {
            if {[llength $parts] >= 2} { return [lindex $parts 1] }
        }
        body {
            if {[llength $parts] >= 3} { return [lindex $parts 2] }
        }
    }
    return ""
}

# Strip out string literals AND comments before counting keywords. Comments
# are removed line-by-line so the multi-line metric heuristics never count
# `# ... if ...` keyword references that are documentation, not code.
proc ::jcm::bridge::_strip_strings {body_src} {
    # First pass: drop "..." regions while respecting backslash escapes.
    set out ""
    set i 0
    set len [string length $body_src]
    set in_str 0
    while {$i < $len} {
        set c [string index $body_src $i]
        if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
        if {$c eq "\""} { set in_str [expr {!$in_str}]; incr i; continue }
        if {!$in_str} { append out $c }
        incr i
    }
    # Second pass: drop lines that begin with `#` (after leading whitespace).
    set lines [list]
    foreach line [split $out "\n"] {
        set trimmed [string trimleft $line]
        if {[string index $trimmed 0] eq "#"} {
            lappend lines ""
        } else {
            lappend lines $line
        }
    }
    return [join $lines "\n"]
}

proc ::jcm::bridge::_count_cyclomatic {body_src} {
    set body [_strip_strings $body_src]
    set count 1
    set keywords {if elseif while for foreach catch try switch}
    foreach kw $keywords {
        set n [regexp -all "\\m${kw}\\M" $body]
        incr count $n
    }
    # Conservative cap to avoid runaway counts on huge bodies.
    if {$count > 200} { set count 200 }
    return $count
}

proc ::jcm::bridge::_count_max_nesting {body_src} {
    # Walk braces; track depth ignoring contents inside "..." strings.
    set depth 0
    set max 0
    set len [string length $body_src]
    set i 0
    set in_str 0
    while {$i < $len} {
        set c [string index $body_src $i]
        if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
        if {$c eq "\""} { set in_str [expr {!$in_str}]; incr i; continue }
        if {!$in_str} {
            if {$c eq "\{"} {
                incr depth
                if {$depth > $max} { set max $depth }
            } elseif {$c eq "\}"} {
                incr depth -1
                if {$depth < 0} { set depth 0 }
            }
        }
        incr i
    }
    return $max
}

proc ::jcm::bridge::_detect_annotations {body_src} {
    set body [_strip_strings $body_src]
    set out [list]
    if {[regexp {\muplevel\M} $body]}  { lappend out uplevel }
    if {[regexp {\mupvar\M}   $body]}  { lappend out upvar }
    if {[regexp {\mglobal\M}  $body]}  { lappend out global_access }
    if {[regexp {\meval\s+\$} $body]}  { lappend out dynamic_eval }
    return $out
}

# ---------------------------------------------------------------------------
# Top-level entry — bridge_main reads the file and runs the full pipeline.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::bridge_main {filepath} {
    if {[catch {set src [read_source $filepath]} err]} {
        puts stderr "READ_ERROR file=$filepath msg=$err"
        return ""
    }
    _reset_state $filepath $src

    # Pre-pass: pragma scan.
    set pragma_result {pragmas {} dynamic_sites {}}
    if {[catch {set pragma_result [::jcm::pragma::scan_file $filepath]} err]} {
        puts stderr "PRAGMA_SCAN_FAIL file=$filepath msg=$err"
    }
    set pragmas [dict get $pragma_result pragmas]
    set dynamic_sites [dict get $pragma_result dynamic_sites]

    # Synthesize __script__ first so package_requires has a host. Per §13.3
    # decided=B, the field is always present on __script__.
    set script_idx [_get_or_synth_script]

    # Recursive walk over the whole file source. parent_sym_idx defaults
    # to script_idx so unresolved/call-refs at file scope attach correctly.
    # parent_qname is "" so top-level procs get parent=None (not __script__);
    # the script symbol exists for call-attachment but isn't a scope qualifier.
    walk_recursive $src 0 $script_idx ""

    # Post-pass A: resolve {__file_offset__ N} tagged tuples.
    _resolve_file_offset_tags

    # Post-pass B: ensure every symbol carries a `file` field BEFORE any
    # later post-pass that reads it (pragma attachment + dynamic_body
    # tagging both copy `file` onto unresolved_dispatches entries; running
    # the sweep first means handlers see a populated field).
    _ensure_file_field

    # Post-pass C: pragma → symbol attachment per NG-1.
    _attach_pragmas $pragmas

    # Post-pass D: cross-file class attribution warnings.
    _attribute_out_of_line_bodies

    # Post-pass D2 (P5.2.1): convention §7.1 Tier 1/2/3/5 filter — strip
    # control-flow / value-manipulation / I/O / structural commands from
    # call_references + callees so the elide decision in D3 sees the
    # post-filter signal.  Tk geometry ensembles (grid/pack/wm/winfo/...)
    # are kept; §6.9 dispatchers (bind/after/fileevent/trace) are
    # suppressed separately by 5.2.7 (callback emission).
    _filter_tier_denylist

    # Post-pass E: drop __script__ if it has no useful signal — matches the
    # v1 elide policy. Keep it whenever package_requires has content so the
    # Δ0.2 always-present field is queryable.
    _maybe_drop_script

    return [emit_json]
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {$::argc < 1} {
        puts stderr "Usage: tclsh tcl_disasm_bridge.tcl <filepath>"
        exit 2
    }
    set out [::jcm::bridge::bridge_main [lindex $::argv 0]]
    puts $out
}
