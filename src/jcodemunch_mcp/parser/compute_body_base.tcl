#!/usr/bin/env tclsh
#
# compute_body_base.tcl — P1.2 deliverable (c) per PLAN_v2.1 §3 P1.2.
#
# Body-base helper: recovers the byte offset and content of a body argument
# within a parent command's source text, using a custom word-position walker.
#
# Re-derived from first principles per §0.2 rule 4 (no copy-paste from the
# retired bridge).  The probe at validation/probes/body_base_probe.tcl is
# the substrate; this module production-packages that approach with the four
# components listed in PLAN_v2.1 §2.2:
#
#   1. Word-position walker        (30-50 LoC)
#   2. is_quote_balanced guard     (~30 LoC)
#   3. Body-content extraction     (~30 LoC)
#   4. Two-pass cross-file index   (~40 LoC)
#   5. Driver + plumbing           (~10 LoC)
#
# Quality posture (§6.1.10): each component is a named, focused proc.
# Comments document the WHY.  Identifier names document the WHAT.
#
# Edge cases handled:
#   - Identical-bodied methods: each has its own src range; no conflict.
#   - Bodies with escape sequences: we walk file bytes, not interpreted literals.
#   - Body content appearing in earlier comments: walker skips non-word bytes.
#   - Backslash-newline continuation between words: treated as whitespace.
#
# Edge case TAGGED (not solved):
#   - Dynamic body construction: `proc foo {} [getBody]` — the body slot
#     is a bracket-substitution result, not a literal.  Callers detect this
#     (the word at body_idx starts with "[") and emit:
#       unresolved_dispatches: {kind dynamic_body ...}
#     instead of recursing.  See dynamic_body_p in this module.

namespace eval ::jcm::disasm::body {
    namespace export find_word_start word_content_range is_quote_balanced \
                     extract_body dynamic_body_p \
                     build_class_index attribute_out_of_line_body
}

# ---------------------------------------------------------------------------
# Component 1 — Word-position walker
# ---------------------------------------------------------------------------
#
# find_word_start cmd_text n
#
# Returns the char (byte) offset within $cmd_text where 0-based word $n begins.
# Returns -1 if $n exceeds the command's word count.
#
# Tcl word-grammar rules respected (per §2.2, re-derived from Tcl manual):
#   - Leading/trailing whitespace and backslash-newline continuations skipped.
#   - Brace words {}: depth-balanced; backslash-escaped braces counted.
#   - Quoted words "": double-quote delimited; backslash escapes one char.
#   - Bare words: terminated by whitespace; nested [...] tracked for depth.
#
# WHY a custom walker rather than lindex: lindex returns the word VALUE
# (with escapes resolved), not the byte POSITION in the source.  We need
# the byte position to reconstruct file offsets for the body argument.
proc ::jcm::disasm::body::find_word_start {cmd_text n} {
    set len [string length $cmd_text]
    set i 0
    set word 0
    while {$i < $len} {
        # ---- skip inter-word whitespace and backslash-newline continuations ----
        while {$i < $len} {
            set ch [string index $cmd_text $i]
            # Backslash-newline is Tcl's line-continuation; counts as whitespace.
            if {$ch eq "\\" && $i + 1 < $len
                    && [string index $cmd_text [expr {$i + 1}]] eq "\n"} {
                incr i 2
                continue
            }
            if {$ch ne " " && $ch ne "\t" && $ch ne "\n" && $ch ne "\r"} break
            incr i
        }
        if {$i >= $len} { return -1 }

        # ---- found the start of word $word ----
        if {$word == $n} { return $i }

        # ---- skip past this word ----
        set ch [string index $cmd_text $i]
        if {$ch eq "\{"} {
            # Brace word: depth-balance, escaped braces skipped.
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
            # Quoted word: backslash escapes one char.
            incr i
            while {$i < $len} {
                set c [string index $cmd_text $i]
                if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c eq "\""} { incr i; break }
                incr i
            }
        } else {
            # Bare word: stops at whitespace; nested [...] tracked for depth.
            # Backslash-newline terminates a bare word (it begins the next
            # continuation line, which starts a new word boundary).
            while {$i < $len} {
                set c [string index $cmd_text $i]
                if {$c eq "\\" && $i + 1 < $len
                        && [string index $cmd_text [expr {$i + 1}]] eq "\n"} {
                    break
                }
                if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
                if {$c eq "\["} {
                    # Enter bracket nesting.
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
                if {$c eq " " || $c eq "\t" || $c eq "\n" || $c eq "\r"} break
                incr i
            }
        }
        incr word
    }
    return -1
}

# ---------------------------------------------------------------------------
# Component 2 — is_quote_balanced guard
# ---------------------------------------------------------------------------
#
# is_quote_balanced cmd_text
#
# Returns 1 if the command source text has balanced quote context; 0 otherwise.
#
# WHY this guard is needed: `info complete` has a known brace-blindness bug
# for code like `set s "}"` — it reports the string as complete after the
# closing brace inside the quote, before the actual closing quote.  This
# was documented in jcm_info_complete_brace_bug.md and is why PLAN_v2.1 §2.2
# mandates a custom guard rather than delegating to `info complete`.
#
# Strategy (re-derived from SPEC §0.2 rule 4):
#   Walk the source byte by byte, tracking three mutually-exclusive contexts:
#     BARE:   between words; default context
#     QUOTED: inside "..."; entered on '"', exited on unescaped '"'
#     BRACE:  inside {...}; entered on '{', depth-balanced
#   A source is balanced if it ends in BARE context with brace depth == 0.
#
# NOTE: this guard operates on a *command* text (already bounded by the
# disassembler's src range), not a full file.  It is not a general Tcl
# lexer; it only needs to answer "does this command boundary look sane?"
proc ::jcm::disasm::body::is_quote_balanced {cmd_text} {
    set len [string length $cmd_text]
    set i 0
    set ctx BARE     ;# BARE | QUOTED | BRACE
    set brace_depth 0

    while {$i < $len} {
        set c [string index $cmd_text $i]

        if {$ctx eq "BARE"} {
            if {$c eq "\\"} {
                incr i 2; continue          ;# backslash: skip next char
            }
            if {$c eq "\""} {
                set ctx QUOTED; incr i; continue
            }
            if {$c eq "\{"} {
                set ctx BRACE
                set brace_depth 1
                incr i; continue
            }
            # Other bare chars: just advance.

        } elseif {$ctx eq "QUOTED"} {
            if {$c eq "\\"} {
                incr i 2; continue          ;# escape inside quote
            }
            if {$c eq "\""} {
                set ctx BARE; incr i; continue
            }
            # Braces inside quotes are NOT structural — the guard doesn't
            # track them.  This is the key fix vs. `info complete`.

        } elseif {$ctx eq "BRACE"} {
            if {$c eq "\\"} {
                incr i 2; continue          ;# escape inside brace word
            }
            if {$c eq "\{"} {
                incr brace_depth; incr i; continue
            }
            if {$c eq "\}"} {
                incr brace_depth -1
                if {$brace_depth == 0} { set ctx BARE }
                incr i; continue
            }
        }
        incr i
    }

    # Balanced: ended in BARE context with no open braces.
    expr {$ctx eq "BARE" && $brace_depth == 0}
}

# ---------------------------------------------------------------------------
# Component 3 — Body-content extraction
# ---------------------------------------------------------------------------
#
# word_content_range cmd_text word_start
#
# Given the byte offset of a word's start within cmd_text, returns a two-
# element list {content_start content_end_inclusive} pointing to the INSIDE
# of the delimiter (brace or quote), or the bare word range if neither.
# Returns {} if the delimiter is unmatched (malformed input).
#
# WHY content_start/end point inside the delimiter: the bridge driver uses
# the content as the body source for disassemble; passing the braces would
# make disassemble choke on the outer delimiters.
proc ::jcm::disasm::body::word_content_range {cmd_text word_start} {
    set len [string length $cmd_text]
    set ch  [string index $cmd_text $word_start]

    if {$ch eq "\{"} {
        # Brace word: return the content inside the outermost { ... }.
        set depth 1
        set i [expr {$word_start + 1}]
        set inner_start $i
        while {$i < $len && $depth > 0} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq "\{"} { incr depth }
            if {$c eq "\}"} {
                incr depth -1
                if {$depth == 0} {
                    return [list $inner_start [expr {$i - 1}]]
                }
            }
            incr i
        }
        return {}  ;# unmatched brace

    } elseif {$ch eq "\""} {
        # Quoted word: return the content inside the outer "..." .
        set i [expr {$word_start + 1}]
        set inner_start $i
        while {$i < $len} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq "\""} {
                return [list $inner_start [expr {$i - 1}]]
            }
            incr i
        }
        return {}  ;# unmatched quote

    } else {
        # Bare word: scan to the end (whitespace or backslash-newline).
        set i $word_start
        while {$i < $len} {
            set c [string index $cmd_text $i]
            if {$c eq "\\" && $i + 1 < $len
                    && [string index $cmd_text [expr {$i + 1}]] eq "\n"} {
                break
            }
            if {$c eq "\\" && $i + 1 < $len} { incr i 2; continue }
            if {$c eq " " || $c eq "\t" || $c eq "\n" || $c eq "\r"} break
            incr i
        }
        return [list $word_start [expr {$i - 1}]]
    }
}

# dynamic_body_p cmd_text word_start
#
# Returns 1 if the word at word_start is a bracket-substitution (dynamic body
# construction like `proc foo {} [getBody]`).  The bridge driver calls this
# before extract_body to decide whether to tag the site as dynamic_body in
# unresolved_dispatches instead of recursing.
proc ::jcm::disasm::body::dynamic_body_p {cmd_text word_start} {
    if {$word_start < 0 || $word_start >= [string length $cmd_text]} {
        return 0
    }
    expr {[string index $cmd_text $word_start] eq "\["}
}

# extract_body cmd_text body_arg_idx parent_src_offset
#
# Main extraction entry point.  Combines find_word_start, dynamic_body_p,
# is_quote_balanced, and word_content_range.
#
# Returns a dict:
#   ok           1 | 0
#   body_src     — the body content string (inside delimiters)
#   body_offset  — byte offset of body_src relative to the START of the file
#                  (= parent_src_offset + cmd_src_start + word_content_start)
#   body_length  — byte length of body_src
#   dynamic      — 1 if the body slot is a dynamic bracket expression
#   error        — error message if ok==0
#
# Callers must supply:
#   cmd_text          — source text of the parent command (from src range)
#   body_arg_idx      — 0-based word index of the body argument
#   parent_src_offset — byte offset of cmd_text[0] within the file
proc ::jcm::disasm::body::extract_body {cmd_text body_arg_idx parent_src_offset} {
    # Guard: is the command source well-formed?
    if {![is_quote_balanced $cmd_text]} {
        return [dict create ok 0 error "unbalanced_quote_or_brace" \
            dynamic 0 body_src "" body_offset -1 body_length 0]
    }

    set word_start [find_word_start $cmd_text $body_arg_idx]
    if {$word_start < 0} {
        return [dict create ok 0 error "word_not_found" \
            dynamic 0 body_src "" body_offset -1 body_length 0]
    }

    # Dynamic body: bracket-substitution in the body slot.
    if {[dynamic_body_p $cmd_text $word_start]} {
        return [dict create ok 0 error "" dynamic 1 \
            body_src "" body_offset -1 body_length 0]
    }

    set crange [word_content_range $cmd_text $word_start]
    if {$crange eq {}} {
        return [dict create ok 0 error "delimiter_unmatched" \
            dynamic 0 body_src "" body_offset -1 body_length 0]
    }

    lassign $crange cs ce
    set body_src    [string range $cmd_text $cs $ce]
    set body_offset [expr {$parent_src_offset + $cs}]
    set body_length [expr {$ce - $cs + 1}]

    return [dict create ok 1 error "" dynamic 0 \
        body_src $body_src body_offset $body_offset body_length $body_length]
}

# ---------------------------------------------------------------------------
# Component 4 — Two-pass cross-file index for `body Class::method` attribution
# ---------------------------------------------------------------------------
#
# In iTcl, `body Widget::method ARGS BODY` defines a method out-of-line.
# The class `Widget` may be declared in a different file than the body.
# The bridge driver needs to attribute the body symbol to the right class.
#
# Pass 1 (build_class_index): walks the symbol list accumulated so far and
# builds a dict mapping qualified-class-name → symbol dict.
#
# Pass 2 (attribute_out_of_line_body): given a `body` command's qualified
# method name (e.g. "Widget::setX"), looks up the class in the index and
# returns the parent class symbol.  If no match is found, the body is
# attributed to a synthetic "(unresolved)" class and logged.
#
# WHY two passes: the body command may appear before or after the class
# declaration within a single file, and may appear in a different file
# entirely.  A single-pass forward walk cannot handle the "body before class"
# case without holding deferred state.  Two passes fix both orderings.
#
# API consumed by bridge driver (Worker 3, T8):
#   build_class_index symbols_list → class_index_dict
#   attribute_out_of_line_body class_index method_qname → class_sym | {}

# build_class_index symbols_list
#
# Returns a dict: {qualified_class_name → class_symbol_dict}.
# "qualified_class_name" is the symbol's "name" field (or "qualified_name"
# if present) for symbols of kind "class".
proc ::jcm::disasm::body::build_class_index {symbols_list} {
    set idx [dict create]
    foreach sym $symbols_list {
        if {![dict exists $sym kind]} continue
        if {[dict get $sym kind] ne "class"} continue
        # Prefer qualified_name; fall back to name.
        set qname [dict get $sym name]
        if {[dict exists $sym qualified_name] && [dict get $sym qualified_name] ne ""} {
            set qname [dict get $sym qualified_name]
        }
        dict set idx $qname $sym
    }
    return $idx
}

# attribute_out_of_line_body class_index method_qname
#
# method_qname examples: "Widget::setX", "::BluIce::Anneal::configure"
# Extracts the class part (everything before the last "::name") and looks
# it up in class_index.
#
# Returns the class symbol dict, or {} if no match.
# On multiple matches (two classes with the same unqualified name in different
# namespaces), returns the first match and the caller is expected to log a
# warning — this is a known ambiguity surfaced as a decision point per the
# task spec.
proc ::jcm::disasm::body::attribute_out_of_line_body {class_index method_qname} {
    # Strip the final "::methodname" to get the class qualifier.
    set sep_pos [string last "::" $method_qname]
    if {$sep_pos < 0} {
        # No "::" — bare method name; cannot attribute.
        return {}
    }
    set class_part [string range $method_qname 0 [expr {$sep_pos - 1}]]

    # Direct lookup by qualified name.
    if {[dict exists $class_index $class_part]} {
        return [dict get $class_index $class_part]
    }

    # Try bare (unqualified) name: strip leading "::".
    set bare [string trimleft $class_part ":"]
    dict for {key sym} $class_index {
        set key_bare [string trimleft $key ":"]
        if {$key_bare eq $bare} {
            return $sym
        }
    }

    # No match — caller logs warning and uses synthetic unresolved parent.
    return {}
}

# ---------------------------------------------------------------------------
# Component 5 — Driver / plumbing
# ---------------------------------------------------------------------------
#
# Convenience proc for the bridge driver: given a walker event dict,
# the command source text, and the body word index, do the full extraction
# and return the result dict from extract_body.
#
# Also resolves the -1 / -2 sentinel indices from SUBTABLE_A:
#   -1 → last word
#   -2 → second-to-last word
proc ::jcm::disasm::body::extract_from_event {cmd_text body_arg_idx parent_src_offset} {
    if {$body_arg_idx < 0} {
        # Resolve last-word sentinels.
        if {![is_quote_balanced $cmd_text]} {
            return [dict create ok 0 error "unbalanced_quote_or_brace" \
                dynamic 0 body_src "" body_offset -1 body_length 0]
        }
        # Count words to resolve negative index.
        set total_words [_count_words $cmd_text]
        set body_arg_idx [expr {$total_words + $body_arg_idx}]
        if {$body_arg_idx < 0} {
            return [dict create ok 0 error "word_not_found" \
                dynamic 0 body_src "" body_offset -1 body_length 0]
        }
    }
    return [extract_body $cmd_text $body_arg_idx $parent_src_offset]
}

# _count_words cmd_text — count the number of Tcl words in a command source.
# Uses find_word_start in a binary-search-like loop.
proc ::jcm::disasm::body::_count_words {cmd_text} {
    set n 0
    while {[find_word_start $cmd_text $n] >= 0} {
        incr n
    }
    return $n
}
