# Fixture: Snit types (optional — many parsers skip this).
# Diagnostic probe; 0 symbols is a legitimate outcome.
# Expected symbols: 1 type (Counter), 2 methods (increment, reset).

package require snit

snit::type Counter {
    variable count 0
    method increment {} {
        incr count
        return $count
    }
    method reset {} {
        set count 0
    }
}
