# Fixture: hex literals inside braced expressions.
# The current parser has a patched workaround for a tree-sitter-tcl grammar bug
# where 0xNN inside {} causes ERROR nodes. A native TCL parser should handle
# this cleanly with no special workarounds.
# Expected symbols: 2 top-level procs.

proc maskByte {val} {
    if {$val & 0xFF} {
        return 1
    }
    return 0
}

proc extractBits {val} {
    set high [expr {($val >> 24) & 0xFFFF}]
    set low  [expr {$val & 0x0000FFFF}]
    return [list $high $low]
}
