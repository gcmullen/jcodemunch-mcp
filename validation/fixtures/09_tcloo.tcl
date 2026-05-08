# Fixture: Tcl 8.6 TclOO classes (optional — many parsers skip this).
# Diagnostic probe; 0 symbols is a legitimate outcome.
# Expected symbols: 1 class (Shape), constructor + 2 methods (describe, rename).

oo::class create Shape {
    variable name
    constructor {shapeName} {
        set name $shapeName
    }
    method describe {} {
        return "This is a $name"
    }
    method rename {newName} {
        set name $newName
    }
}
