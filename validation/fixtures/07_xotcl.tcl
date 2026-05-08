# Fixture: XOTcl object system (optional — many parsers skip this).
# Diagnostic probe; 0 symbols is a legitimate outcome.
# Expected symbols: 2 classes (Person, Employee), 3 methods (greet, birthday, raise).

package require XOTcl

Class Person -parameter {name age}
Person instproc greet {} {
    return "Hello, my name is [my name]"
}
Person instproc birthday {} {
    my age [expr {[my age] + 1}]
}

Class Employee -superclass Person -parameter {salary}
Employee instproc raise {amount} {
    my salary [expr {[my salary] + $amount}]
}
