#!/usr/bin/env tclsh
#
# tcl_disasm_parser.tcl — P1.1 deliverable (a) per PLAN_v2.1 §3 P1.1.
#
# Parses `tcl::unsupported::disassemble script $src` text output into a
# structured dict the §2.3 opcode walker can consume.
#
# Quality posture (per PLAN_v2.1 §6.1.10): pure function, no I/O, no
# semantic interpretation. Module boundary: parsing only. The walker
# applies §2.3 dispatch-table rules; the parser just shapes the data.
#
# Output dict shape (one canonical form):
#
#   stats:   {cmds, src, inst, lit_objs, aux, stk_depth, code_src_ratio}
#   source_preview: string  (Tcl's truncated header preview, informational)
#   commands: [
#       {idx, pc_start, pc_end, src_start, src_end, body_preview,
#        instructions: [{pc, op, operand, comment}, ...]}
#   ]
#   literals: dict {idx -> comment_text}   (reconstructed from push opcodes)
#
# Notes on disassembly format (Tcl 8.6.14, empirically verified):
#   - Header: `ByteCode 0xADDR, refCt N, epoch N, interp 0xADDR (epoch N)`
#   - Source preview: `  Source "...truncated..."`
#   - Stats: `  Cmds N, src N, inst N, litObjs N, aux N, stkDepth N, code/src X.XX`
#   - Cmd table: `  Commands N:` followed by lines packing
#       `K: pc X-Y, src S-E   K2: pc ...   ...` (multiple per line)
#   - Per-command body: `  Command K: "...truncated..."` then indented
#       `(pc) opcode operand [\t# comment]`
#   - Literals: not dumped as a section; appear inline as `# "value"` on
#     push1/push4 instructions where the operand is the literal index.
#   - Literal comments truncate at ~40 chars (the §2.2 walker uses src
#     ranges + parent source for body content; comments are sufficient
#     for short string literals like command names and method names).
#
# Reuses the regex pattern from validation/verify.tcl:88-115 and the
# `Commands N:` packing pattern from validation/probes/body_base_probe.tcl.
# Per §0.2 rule 4: this is helper-pattern re-derivation, not copy-paste of
# the retired tcl_parser_bridge.tcl.

namespace eval ::jcm::disasm::parser {
    namespace export parse parse_text disassemble_and_parse
}

# ---------------------------------------------------------------------------
# Top-level driver
# ---------------------------------------------------------------------------

# Disassemble $src and parse the result. Returns the canonical dict.
# On disassembly failure returns: {error MESSAGE}.
proc ::jcm::disasm::parser::disassemble_and_parse {src} {
    if {[catch {tcl::unsupported::disassemble script $src} bc]} {
        return [dict create error $bc]
    }
    return [parse_text $bc]
}

# Parse already-disassembled text. Useful for fixtures with canned output.
proc ::jcm::disasm::parser::parse_text {bc_text} {
    set parsed [dict create \
        source_preview "" \
        stats          [dict create] \
        commands       [list] \
        literals       [dict create]]

    set lines    [split $bc_text "\n"]
    set n        [llength $lines]

    # Phase 1: header (source preview, stats, command table).
    # Phase 2: per-command bodies (instruction streams).
    # Find the boundary: first `  Command K:` line ends phase 1.
    set phase1_end [_find_phase1_end $lines]

    _parse_header parsed [lrange $lines 0 [expr {$phase1_end - 1}]]
    _parse_command_bodies parsed [lrange $lines $phase1_end end]
    _build_literal_index parsed

    return $parsed
}

# Convenience alias matching the user's spec.
proc ::jcm::disasm::parser::parse {src} {
    return [disassemble_and_parse $src]
}

# ---------------------------------------------------------------------------
# Phase boundary detection
# ---------------------------------------------------------------------------

# Returns line index of the first `  Command K:` line, or len if none.
proc ::jcm::disasm::parser::_find_phase1_end {lines} {
    set i 0
    foreach line $lines {
        if {[regexp {^  Command \d+:} $line]} { return $i }
        incr i
    }
    return [llength $lines]
}

# ---------------------------------------------------------------------------
# Phase 1: header, stats, command table
# ---------------------------------------------------------------------------

proc ::jcm::disasm::parser::_parse_header {parsed_var lines} {
    upvar $parsed_var parsed

    set in_cmd_table 0
    set cmd_table_lines [list]

    foreach line $lines {
        # Source preview: Source "..."
        if {[regexp {^\s+Source\s+"(.*)"\s*$} $line -> preview]} {
            dict set parsed source_preview $preview
            continue
        }
        # Stats: Cmds N, src N, inst N, litObjs N, aux N, stkDepth N, code/src X.XX
        if {[regexp {^\s+Cmds\s+(\d+),\s*src\s+(\d+),\s*inst\s+(\d+),\s*litObjs\s+(\d+),\s*aux\s+(\d+),\s*stkDepth\s+(\d+),\s*code/src\s+([\d.]+)} \
                $line -> c s i l a sd cs]} {
            dict set parsed stats [dict create \
                cmds            $c \
                src             $s \
                inst            $i \
                lit_objs        $l \
                aux             $a \
                stk_depth       $sd \
                code_src_ratio  $cs]
            continue
        }
        # Command table header: Commands N:
        if {[regexp {^\s+Commands\s+\d+:} $line]} {
            set in_cmd_table 1
            continue
        }
        if {$in_cmd_table} { lappend cmd_table_lines $line }
    }

    # Parse packed command table entries: K: pc X-Y, src S-E
    # Use -all -inline so multiple matches per line work uniformly.
    set table_text [join $cmd_table_lines "\n"]
    set commands [list]
    foreach {whole idx pc_s pc_e src_s src_e} [regexp -all -inline \
            {(\d+):\s*pc\s+(\d+)-(\d+),\s*src\s+(\d+)-(\d+)} $table_text] {
        lappend commands [dict create \
            idx            $idx \
            pc_start       $pc_s \
            pc_end         $pc_e \
            src_start      $src_s \
            src_end        $src_e \
            body_preview   "" \
            instructions   [list]]
    }
    dict set parsed commands $commands
}

# ---------------------------------------------------------------------------
# Phase 2: per-command instruction streams
# ---------------------------------------------------------------------------

proc ::jcm::disasm::parser::_parse_command_bodies {parsed_var lines} {
    upvar $parsed_var parsed

    set commands [dict get $parsed commands]
    set cur_idx -1
    set cur_insns [list]

    foreach line $lines {
        # Command body header: `  Command K: "..."`
        if {[regexp {^\s+Command\s+(\d+):\s*"(.*)"\s*$} \
                $line -> kidx preview]} {
            # Flush previous command's instructions
            if {$cur_idx >= 0} {
                set commands [_attach_instructions $commands \
                    $cur_idx $cur_insns]
            }
            set cur_idx $kidx
            set cur_insns [list]
            # Attach preview to its command immediately
            set commands [_attach_preview $commands $kidx $preview]
            continue
        }
        # Instruction: `(pc) opcode operand   # comment` (comment optional)
        # The operand may be empty for nullary opcodes like `pop` and `done`.
        # Reuses verify.tcl:88-115 regex pattern (inclusive trailing-comment form).
        if {[regexp \
                {^\s*\(\d+\)\s+(\S+)(?:\s+([^#]*?))?(?:\s*#\s*(.*))?$} \
                $line -> op operand comment]} {
            # The above regex doesn't capture the pc; pull it separately
            if {[regexp {^\s*\((\d+)\)} $line -> pc]} {
                lappend cur_insns [dict create \
                    pc       $pc \
                    op       [string trim $op] \
                    operand  [string trim $operand] \
                    comment  [string trim $comment]]
            }
        }
    }
    # Flush last command
    if {$cur_idx >= 0} {
        set commands [_attach_instructions $commands $cur_idx $cur_insns]
    }
    dict set parsed commands $commands
}

# Replace the instructions slot for command idx in the commands list.
proc ::jcm::disasm::parser::_attach_instructions {commands idx insns} {
    set out [list]
    foreach c $commands {
        if {[dict get $c idx] eq $idx} {
            dict set c instructions $insns
        }
        lappend out $c
    }
    return $out
}

# Attach a body preview (truncated source from `Command K: "..."`) to cmd idx.
proc ::jcm::disasm::parser::_attach_preview {commands idx preview} {
    set out [list]
    foreach c $commands {
        if {[dict get $c idx] eq $idx} {
            dict set c body_preview $preview
        }
        lappend out $c
    }
    return $out
}

# ---------------------------------------------------------------------------
# Literal index reconstruction
# ---------------------------------------------------------------------------
#
# Disassembly does not emit a literals section, but every push1/push4 to
# literal index N carries the literal text in its `# "..."` comment. Walk
# all instructions across all commands, indexing operand -> comment text.
# Where the same index appears multiple times (which it should not, but
# guard anyway), keep the first-seen comment.

proc ::jcm::disasm::parser::_build_literal_index {parsed_var} {
    upvar $parsed_var parsed
    set literals [dict create]
    foreach c [dict get $parsed commands] {
        foreach insn [dict get $c instructions] {
            set op [dict get $insn op]
            if {[string match push* $op] && [dict get $insn operand] ne ""} {
                set idx     [dict get $insn operand]
                set comment [dict get $insn comment]
                # Comments are quoted: # "VALUE" — strip surrounding quotes.
                set lit $comment
                if {[regexp {^"(.*)"$} $comment -> inner]} { set lit $inner }
                if {![dict exists $literals $idx]} {
                    dict set literals $idx $lit
                }
            }
        }
    }
    dict set parsed literals $literals
}

# ---------------------------------------------------------------------------
# Pretty-printer (for fixture authoring + debugging)
# ---------------------------------------------------------------------------

proc ::jcm::disasm::parser::format_pretty {parsed} {
    set out ""
    if {[dict exists $parsed error]} {
        return "ERROR: [dict get $parsed error]"
    }
    append out "source_preview: [dict get $parsed source_preview]\n"
    append out "stats:          [dict get $parsed stats]\n"
    append out "literals:       [dict get $parsed literals]\n"
    append out "commands ([llength [dict get $parsed commands]]):\n"
    foreach c [dict get $parsed commands] {
        append out [format "  Command %s: pc %s-%s, src %s-%s\n" \
            [dict get $c idx] \
            [dict get $c pc_start] [dict get $c pc_end] \
            [dict get $c src_start] [dict get $c src_end]]
        append out [format "    body_preview: %s\n" \
            [dict get $c body_preview]]
        foreach insn [dict get $c instructions] {
            append out [format "    (%s) %s %s    # %s\n" \
                [dict get $insn pc] \
                [dict get $insn op] \
                [dict get $insn operand] \
                [dict get $insn comment]]
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# CLI entrypoint (only when invoked as a script)
# ---------------------------------------------------------------------------

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {$::argc < 1} {
        puts stderr "Usage: tcl_disasm_parser.tcl FILE.tcl"
        exit 2
    }
    set path [lindex $::argv 0]
    set fp [open $path r]
    fconfigure $fp -encoding utf-8
    set src [read $fp]
    close $fp
    set parsed [::jcm::disasm::parser::disassemble_and_parse $src]
    puts [::jcm::disasm::parser::format_pretty $parsed]
}
