# dsl_walker.tcl — Phase 5.2a.2 truly-generic class-DSL walker.
#
# Driven entirely by ::jcm::dsl::ANNOTATIONS + ::jcm::dsl::BODY_GRAMMARS.
# Zero per-DSL handler procs. Adding a new DSL requires only annotation rows
# + a grammar entry in BODY_GRAMMARS — no walker code changes.
#
# Context tracking: BODY_GRAMMAR_STACK records which DSL body we're currently
# walking. The pre-pass checks the stack-top grammar BEFORE the outer-command
# table, so directives only get DSL-aware treatment inside a known DSL body.

namespace eval ::jcm::dsl::walker {
    # Stack of body-grammar keys (e.g. "snit", "itcl"). Top = active grammar.
    variable BODY_GRAMMAR_STACK {}
}

# Try to handle a pattern_a-shaped command via the DSL annotations table.
#
# Returns 1 if a DSL annotation owned this command (caller must `return`
# immediately to skip SUBTABLE_C / A dispatch). Returns 0 otherwise so the
# caller falls through to the existing dispatch chain.
proc ::jcm::dsl::walker::try_dispatch {ev cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    variable BODY_GRAMMAR_STACK
    set first  [::jcm::bridge::_first_word_of_cmd $cmd_text]
    set second [::jcm::bridge::_nth_word_of_cmd  $cmd_text 1]
    # 1) Inside a DSL body? Look up first_word in the stack-top grammar.
    if {[llength $BODY_GRAMMAR_STACK] > 0} {
        set grammar_key [lindex $BODY_GRAMMAR_STACK end]
        if {[dict exists $::jcm::dsl::BODY_GRAMMARS $grammar_key $first]} {
            set action_spec [dict get $::jcm::dsl::BODY_GRAMMARS $grammar_key $first]
            return [_emit_directive $action_spec $cmd_text $abs_start $abs_end \
                    $parent_sym_idx $parent_qname]
        }
        # Directive not in grammar — fall through to outer table + SUBTABLE_*.
    }

    # 2) Top-level outer commands (snit::type, itcl::class, proc class, ...).
    set row [::jcm::dsl::lookup $first $second]
    if {[llength $row] == 0} { return 0 }
    return [_apply_outer_row $row $cmd_text $abs_start $abs_end \
            $parent_sym_idx $parent_qname]
}

# Apply one ANNOTATIONS row. Handles synth / augment / slot actions, then
# recurses each body word in body_indices with grammar pushed on the stack.
proc ::jcm::dsl::walker::_apply_outer_row {row cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    variable BODY_GRAMMAR_STACK
    lassign $row first second action kind grammar name_idx body_indices

    set sym_name [::jcm::bridge::_nth_word_of_cmd $cmd_text $name_idx]
    if {$sym_name eq ""} { return 0 }

    set new_sym_idx -1
    set new_qname $parent_qname

    switch -- $action {
        synth {
            set qname [::jcm::bridge::_qualify $sym_name $parent_qname]
            set sig "$first $sym_name"
            set keywords [::jcm::bridge::_keywords_for_kind $kind {}]
            set sym [::jcm::bridge::_make_symbol \
                name $sym_name qualified_name $qname kind $kind \
                signature $sig parent $parent_qname keywords $keywords]
            set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
            set new_sym_idx [::jcm::bridge::_append_symbol $sym]
            set new_qname $qname
        }
        augment {
            # Find the existing class symbol by qname. Gold-first: if not
            # found, skip body recursion entirely — no wrong-scope attribution.
            set qname [::jcm::bridge::_qualify $sym_name $parent_qname]
            set found_idx [_find_class_by_qname $qname]
            if {$found_idx < 0} {
                set found_idx [_find_class_by_qname $sym_name]
            }
            if {$found_idx < 0} {
                # G9 — augment target is dynamic (e.g. `oo::define $class {...}`)
                # or refers to a class declared in another file the bridge hasn't
                # seen yet. Emit the augment command itself ($first, e.g.
                # "::oo::define") as a qualified callee on the parent so the
                # call edge is recorded. Body is NOT walked — directives inside
                # would attribute to the wrong scope without a known augmented
                # class.
                namespace upvar ::jcm::bridge line_offsets line_offsets
                set line [::jcm::bridge::char_offset_to_line $line_offsets $abs_start]
                ::jcm::bridge::_add_callee_to_parent $parent_sym_idx \
                    [::jcm::bridge::_make_static_or_qualified_entry $first $line]
                return 1
            }
            namespace upvar ::jcm::bridge symbols symbols
            set new_sym_idx $found_idx
            set new_qname [dict get [lindex $symbols $found_idx] qualified_name]
        }
        slot {
            # Component slot — no symbol; recurse with parent context.
        }
    }

    set recur_parent_idx $parent_sym_idx
    set recur_parent_qname $parent_qname
    if {$new_sym_idx >= 0} {
        set recur_parent_idx $new_sym_idx
        set recur_parent_qname $new_qname
    }

    set total_words [::jcm::bridge::_count_cmd_words $cmd_text]
    foreach body_idx $body_indices {
        set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx $body_idx $total_words]
        if {![_body_is_brace_literal $cmd_text $resolved_idx]} continue
        set extracted [::jcm::disasm::body::extract_from_event \
            $cmd_text $resolved_idx $abs_start]
        if {[dict get $extracted dynamic]} continue
        if {![dict get $extracted ok]} continue
        if {$grammar ne ""} {
            lappend BODY_GRAMMAR_STACK $grammar
        }
        if {[catch {
            ::jcm::bridge::walk_recursive [dict get $extracted body_src] \
                [dict get $extracted body_offset] $recur_parent_idx $recur_parent_qname
        } err opts]} {
            if {$grammar ne ""} {
                set BODY_GRAMMAR_STACK [lrange $BODY_GRAMMAR_STACK 0 end-1]
            }
            return -options $opts $err
        }
        if {$grammar ne ""} {
            set BODY_GRAMMAR_STACK [lrange $BODY_GRAMMAR_STACK 0 end-1]
        }
    }

    return 1
}

# Dispatch one body-grammar action_spec for a directive inside a DSL body.
proc ::jcm::dsl::walker::_emit_directive {action_spec cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    # Check optional conditional before anything else.
    if {[dict exists $action_spec conditional]} {
        set cond [dict get $action_spec conditional]
        if {[dict exists $cond second_word_must_be]} {
            set required [dict get $cond second_word_must_be]
            set actual   [::jcm::bridge::_nth_word_of_cmd $cmd_text 1]
            if {$actual ne $required} {
                return 1  ;# conditional failed — suppress
            }
        }
    }

    set action [dict get $action_spec action]
    switch -- $action {
        suppress {
            return 1
        }
        parent_classes {
            return [_handle_parent_classes $action_spec $cmd_text $abs_start $parent_sym_idx]
        }
        emit -
        emit_no_recurse {
            # Resolve NAME from name_source.
            set name_source [dict get $action_spec name_source]
            set name_kind   [lindex $name_source 0]
            if {$name_kind eq "idx"} {
                set sym_name [::jcm::bridge::_nth_word_of_cmd $cmd_text [lindex $name_source 1]]
            } elseif {$name_kind eq "literal"} {
                set sym_name [lindex $name_source 1]
            } else {
                return 0
            }
            if {$sym_name eq ""} { return 1 }

            set kind     [dict get $action_spec kind]
            set qname    [::jcm::bridge::_qualify $sym_name $parent_qname]
            set keywords [dict get $action_spec keywords]
            set first_word [::jcm::bridge::_first_word_of_cmd $cmd_text]
            set sig "$first_word $sym_name"

            set sym_args [list \
                name $sym_name qualified_name $qname kind $kind \
                signature $sig parent $parent_qname keywords $keywords]

            if {[dict exists $action_spec note_template]} {
                set note [_substitute_template \
                    [dict get $action_spec note_template] $cmd_text]
                # Append note to signature — the standard convention.
                lappend sym_args signature "$sig — $note"
            }

            set sym [::jcm::bridge::_make_symbol {*}$sym_args]
            set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
            set new_sym_idx [::jcm::bridge::_append_symbol $sym]

            # Recurse body for `emit` only.
            if {$action eq "emit" && [dict exists $action_spec body_idx]} {
                set body_idx   [dict get $action_spec body_idx]
                set total_words [::jcm::bridge::_count_cmd_words $cmd_text]
                set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx \
                    $body_idx $total_words]
                if {![::jcm::dsl::walker::_body_is_brace_literal $cmd_text $resolved_idx]} {
                    return 1
                }
                set extracted [::jcm::disasm::body::extract_from_event \
                    $cmd_text $resolved_idx $abs_start]
                if {[dict get $extracted ok] && ![dict get $extracted dynamic]} {
                    set body_src [dict get $extracted body_src]
                    ::jcm::bridge::walk_recursive $body_src \
                        [dict get $extracted body_offset] $new_sym_idx $qname
                    # Attach param_count / cyclomatic / nesting. Pass a synthetic
                    # SUBTABLE_A-shaped row so _extract_args_for_row can resolve
                    # the args word by first-word (constructor/destructor/method).
                    set metric_row [list $first_word "" $resolved_idx lambda $kind {}]
                    ::jcm::bridge::_attach_metrics $new_sym_idx $cmd_text $body_src $metric_row
                }
            }
            return 1
        }
    }
    return 0
}

# Append parent-class names from the command words to the enclosing class
# symbol's parent_classes field.
proc ::jcm::dsl::walker::_handle_parent_classes {action_spec cmd_text abs_start parent_sym_idx} {
    if {$parent_sym_idx < 0} { return 1 }
    set start_idx [dict get $action_spec start_idx]
    set total [::jcm::bridge::_count_cmd_words $cmd_text]
    if {$total <= $start_idx} { return 1 }
    namespace upvar ::jcm::bridge symbols symbols line_offsets line_offsets
    set sym [lindex $symbols $parent_sym_idx]
    if {![dict exists $sym parent_classes]} {
        dict set sym parent_classes [list]
    }
    set pc   [dict get $sym parent_classes]
    set line [::jcm::bridge::char_offset_to_line $line_offsets $abs_start]
    for {set i $start_idx} {$i < $total} {incr i} {
        set c [::jcm::bridge::_nth_word_of_cmd $cmd_text $i]
        if {$c ne ""} {
            lappend pc [dict create name $c line $line]
        }
    }
    dict set sym parent_classes $pc
    lset symbols $parent_sym_idx $sym
    return 1
}

# Returns 1 if the body word at $resolved_idx in $cmd_text starts with '{',
# i.e. it's a real code-body brace literal and NOT a quoted-string default
# value. Mirrors the SUBTABLE_A guard at _apply_a_row lines 1080-1086 so
# DSL annotation rows can safely declare optional trailing bodies without
# walking string defaults as code (the `::dcss` regression).
proc ::jcm::dsl::walker::_body_is_brace_literal {cmd_text resolved_idx} {
    set start [::jcm::disasm::body::find_word_start $cmd_text $resolved_idx]
    if {$start < 0} { return 0 }
    return [expr {[string index $cmd_text $start] eq "\{"}]
}

# Scan symbols for a class with the given qualified_name.
proc ::jcm::dsl::walker::_find_class_by_qname {qname} {
    namespace upvar ::jcm::bridge symbols symbols
    set n [llength $symbols]
    for {set i 0} {$i < $n} {incr i} {
        set s [lindex $symbols $i]
        if {[dict get $s kind] eq "class" && [dict get $s qualified_name] eq $qname} {
            return $i
        }
    }
    return -1
}

# Replace ${cmd_word_N} tokens in tmpl with the Nth word of cmd_text.
proc ::jcm::dsl::walker::_substitute_template {tmpl cmd_text} {
    set result $tmpl
    while {[regexp {\$\{cmd_word_([0-9]+)\}} $result -> idx]} {
        set word [::jcm::bridge::_nth_word_of_cmd $cmd_text $idx]
        regsub {\$\{cmd_word_[0-9]+\}} $result $word result
    }
    return $result
}
