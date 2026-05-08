# Fixture: line-continuation in proc headers.
# Expected symbols: 2 top-level procs.

proc withBackslash \
    {a b c} {
    return [expr {$a + $b + $c}]
}

proc normalProc {x y} {
    return [expr {$x - $y}]
}
