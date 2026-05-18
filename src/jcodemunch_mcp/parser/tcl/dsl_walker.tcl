# dsl_walker.tcl — Phase 5.2a generic class-DSL walker.
#
# Sits as a sibling to recursion_tables.tcl's SUBTABLE_A/B/C dispatch.
# Called from disasm_bridge::_handle_pattern_a as a pre-pass: when the
# command's first word (optionally + second word) matches a row in
# ::jcm::dsl::ANNOTATIONS, this walker takes over symbol emission + body
# recursion using the bridge's existing emit helpers. When no row matches,
# returns 0 so the caller falls through to the existing SUBTABLE_C / A
# dispatch — preserving all behavior for non-DSL commands.
#
# Context tracking: BODY_GRAMMAR_STACK records which DSL body we're
# currently walking. The pre-pass consults the stack-top body grammar
# BEFORE the top-level outer-commands table, so directives like
# `typemethod` / `option` / `delegate method` only get DSL-aware treatment
# when they appear inside a known DSL body. Outside a DSL body those same
# words fall through to the bridge's normal dispatch.

namespace eval ::jcm::dsl::walker {
    # Stack of body-grammar keys (e.g. "snit"). Top = active grammar.
    # Pushed by _apply_outer_row before recursing into the DSL body; popped
    # after. Snit / Clay / iTcl don't nest in real code, but the stack
    # discipline keeps the design correct if they ever do.
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

    # 1) Inside a DSL body? Check the active grammar's directive table.
    if {[llength $BODY_GRAMMAR_STACK] > 0} {
        set grammar_key [lindex $BODY_GRAMMAR_STACK end]
        variable ::jcm::dsl::BODY_GRAMMARS
        if {[dict exists $::jcm::dsl::BODY_GRAMMARS $grammar_key $first]} {
            set rule [dict get $::jcm::dsl::BODY_GRAMMARS $grammar_key $first]
            return [_apply_body_rule $rule $cmd_text $abs_start $abs_end \
                    $parent_sym_idx $parent_qname]
        }
        # Directive not in DSL grammar — fall through to top-level + SUBTABLE_*.
    }

    # 2) Top-level outers (snit::type, ::snit::type, ...).
    set row [::jcm::dsl::lookup $first $second]
    if {[llength $row] == 0} { return 0 }
    return [_apply_outer_row $row $cmd_text $abs_start $abs_end \
            $parent_sym_idx $parent_qname]
}

# Emit the DSL outer symbol (typically a class), then recurse into its
# body with the row's body_grammar pushed onto BODY_GRAMMAR_STACK so
# directive-aware dispatch fires inside.
proc ::jcm::dsl::walker::_apply_outer_row {row cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    variable BODY_GRAMMAR_STACK
    lassign $row first second name_idx body_idx kind body_grammar

    set sym_name [::jcm::bridge::_nth_word_of_cmd $cmd_text $name_idx]
    if {$sym_name eq ""} { return 0 }

    set new_sym_idx -1
    set new_qname $parent_qname
    if {$kind ne ""} {
        set qname [::jcm::bridge::_qualify $sym_name $parent_qname]
        set sig [::jcm::bridge::_build_signature $cmd_text $first $sym_name $kind]
        set keywords [::jcm::bridge::_keywords_for_kind $kind {}]
        set sym [::jcm::bridge::_make_symbol \
            name           $sym_name \
            qualified_name $qname \
            kind           $kind \
            signature      $sig \
            parent         $parent_qname \
            keywords       $keywords]
        set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
        set new_sym_idx [::jcm::bridge::_append_symbol $sym]
        set new_qname $qname
    }

    # Extract the body word.
    set total_words [::jcm::bridge::_count_cmd_words $cmd_text]
    set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx $body_idx $total_words]
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text $resolved_idx $abs_start]

    # Dynamic body — tag and skip recursion (mirrors _apply_a_row's
    # treatment in disasm_bridge.tcl).
    if {[dict get $extracted dynamic]} {
        if {$new_sym_idx >= 0} {
            namespace upvar ::jcm::bridge symbols symbols file_path file_path
            set sym [lindex $symbols $new_sym_idx]
            set entry [dict create kind dynamic_body \
                line [dict get $sym line] \
                file $file_path]
            set sym [::jcm::disasm::unresolved::append_to_sym $sym $entry]
            lset symbols $new_sym_idx $sym
        }
        return 1
    }
    if {![dict get $extracted ok]} { return 1 }

    # Recurse into the body with the DSL's grammar active.
    set recur_parent_idx $parent_sym_idx
    set recur_parent_qname $parent_qname
    if {$new_sym_idx >= 0} {
        set recur_parent_idx $new_sym_idx
        set recur_parent_qname $new_qname
    }
    lappend BODY_GRAMMAR_STACK $body_grammar
    if {[catch {
        ::jcm::bridge::walk_recursive [dict get $extracted body_src] \
            [dict get $extracted body_offset] $recur_parent_idx $recur_parent_qname
    } err opts]} {
        # Always pop the stack even if recursion blew up.
        set BODY_GRAMMAR_STACK [lrange $BODY_GRAMMAR_STACK 0 end-1]
        return -options $opts $err
    }
    set BODY_GRAMMAR_STACK [lrange $BODY_GRAMMAR_STACK 0 end-1]

    return 1
}

# Apply a body-grammar rule for one directive inside a DSL body. Returns
# 1 (handled) or 0 (fall through — used when a "rule" actually wants the
# default dispatch to run, currently unused).
proc ::jcm::dsl::walker::_apply_body_rule {rule cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set emit [dict get $rule emit]
    switch -- $emit {
        suppress {
            # Slot / data declaration — consume the directive; emit nothing.
            return 1
        }
        class_method {
            return [_emit_class_method $rule $cmd_text $abs_start $abs_end \
                    $parent_sym_idx $parent_qname]
        }
        ctor {
            return [_emit_ctor_or_dtor $rule constructor $cmd_text \
                    $abs_start $abs_end $parent_sym_idx $parent_qname]
        }
        dtor {
            return [_emit_ctor_or_dtor $rule destructor $cmd_text \
                    $abs_start $abs_end $parent_sym_idx $parent_qname]
        }
        delegate_dispatch {
            return [_emit_delegate $cmd_text $abs_start $abs_end \
                    $parent_sym_idx $parent_qname]
        }
        parent_classes {
            return [_append_parent_classes $cmd_text $abs_start $parent_sym_idx]
        }
    }
    return 0
}

# typemethod / proc inside a snit body -> class_method symbol; recurse body
# for inner callees attributed to the new method symbol.
proc ::jcm::dsl::walker::_emit_class_method {rule cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set name_idx [dict get $rule name_idx]
    set body_idx [dict get $rule body_idx]
    set sym_name [::jcm::bridge::_nth_word_of_cmd $cmd_text $name_idx]
    if {$sym_name eq ""} { return 1 }

    set qname [::jcm::bridge::_qualify $sym_name $parent_qname]
    set sig "[::jcm::bridge::_first_word_of_cmd $cmd_text] $sym_name"
    set sym [::jcm::bridge::_make_symbol \
        name           $sym_name \
        qualified_name $qname \
        kind           class_method \
        signature      $sig \
        parent         $parent_qname \
        keywords       [list class_method]]
    set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
    set new_sym_idx [::jcm::bridge::_append_symbol $sym]

    set total_words [::jcm::bridge::_count_cmd_words $cmd_text]
    set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx $body_idx $total_words]
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text $resolved_idx $abs_start]
    if {![dict get $extracted ok]} { return 1 }
    if {[dict get $extracted dynamic]} { return 1 }

    # Recurse into the method body without pushing onto the DSL stack —
    # method bodies are plain Tcl, not nested DSL bodies.
    ::jcm::bridge::walk_recursive [dict get $extracted body_src] \
        [dict get $extracted body_offset] $new_sym_idx $qname
    return 1
}

# constructor / destructor inside a DSL body where gold expects
# kind=constructor (not kind=method which is the bridge's broader wire
# convention from _apply_a_row). Scoped to DSL contexts to avoid changing
# the iTcl/TclOO emission shape; gold-first audit may later expand this.
proc ::jcm::dsl::walker::_emit_ctor_or_dtor {rule kind cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set body_idx [dict get $rule body_idx]
    set qname [::jcm::bridge::_qualify $kind $parent_qname]
    set sig $kind
    if {$kind eq "constructor"} {
        set args [::jcm::bridge::_nth_word_of_cmd $cmd_text 1]
        set sig "constructor \{$args\}"
    }
    set sym [::jcm::bridge::_make_symbol \
        name           $kind \
        qualified_name $qname \
        kind           $kind \
        signature      $sig \
        parent         $parent_qname \
        keywords       [list $kind]]
    set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
    set new_sym_idx [::jcm::bridge::_append_symbol $sym]

    set total_words [::jcm::bridge::_count_cmd_words $cmd_text]
    set resolved_idx [::jcm::disasm::rectbl::resolve_body_idx $body_idx $total_words]
    set extracted [::jcm::disasm::body::extract_from_event $cmd_text $resolved_idx $abs_start]
    if {[dict get $extracted ok] && ![dict get $extracted dynamic]} {
        ::jcm::bridge::walk_recursive [dict get $extracted body_src] \
            [dict get $extracted body_offset] $new_sym_idx $qname
    }
    return 1
}

# `delegate method NAME to COMPONENT` -> emit a method symbol with empty
# body and note "delegate to <component>", per convention §5.4.7 (analogous
# to TclOO `forward`). `delegate option ...` is suppressed (slot only).
proc ::jcm::dsl::walker::_emit_delegate {cmd_text abs_start abs_end parent_sym_idx parent_qname} {
    set kind_word [::jcm::bridge::_nth_word_of_cmd $cmd_text 1]
    if {$kind_word ne "method"} { return 1 }
    set sym_name [::jcm::bridge::_nth_word_of_cmd $cmd_text 2]
    if {$sym_name eq ""} { return 1 }
    set component [::jcm::bridge::_nth_word_of_cmd $cmd_text 4]

    set qname [::jcm::bridge::_qualify $sym_name $parent_qname]
    set sig "delegate method $sym_name to $component"
    set sym [::jcm::bridge::_make_symbol \
        name           $sym_name \
        qualified_name $qname \
        kind           method \
        signature      $sig \
        parent         $parent_qname \
        keywords       [list method delegate]]
    set sym [::jcm::bridge::_attach_offsets $sym $abs_start $abs_end]
    ::jcm::bridge::_append_symbol $sym
    return 1
}

# `superclass CLASS ?CLASS...?` -> append each class to the enclosing
# DSL class symbol's parent_classes field. NOT a callee. Entry shape
# {name STRING line INT} per recursion_tables::_handle_superclass.
proc ::jcm::dsl::walker::_append_parent_classes {cmd_text abs_start parent_sym_idx} {
    if {$parent_sym_idx < 0} { return 1 }
    set total [::jcm::bridge::_count_cmd_words $cmd_text]
    if {$total < 2} { return 1 }
    namespace upvar ::jcm::bridge symbols symbols line_offsets line_offsets
    set sym [lindex $symbols $parent_sym_idx]
    if {![dict exists $sym parent_classes]} {
        dict set sym parent_classes [list]
    }
    set pc [dict get $sym parent_classes]
    set line [::jcm::bridge::char_offset_to_line $line_offsets $abs_start]
    for {set i 1} {$i < $total} {incr i} {
        set c [::jcm::bridge::_nth_word_of_cmd $cmd_text $i]
        if {$c ne ""} {
            lappend pc [dict create name $c line $line]
        }
    }
    dict set sym parent_classes $pc
    lset symbols $parent_sym_idx $sym
    return 1
}
