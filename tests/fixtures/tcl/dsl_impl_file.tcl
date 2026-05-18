# A minimal DSL-implementation file. The `proc class` here implements a
# custom class DSL; the `class FooBar { ... }` literal inside an `if` branch
# is DATA being passed to the impl, NOT a class declaration.
# Per convention §5.4.2 P3.1 the bridge must NOT synthesize FooBar / m.
proc class {name body} {
    if {[llength $body] > 0} {
        class FooBar { method m {} { puts hi } }
    }
}
