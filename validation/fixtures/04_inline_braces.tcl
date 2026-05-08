# Fixture: braces inside quoted strings inside method bodies.
# Tree-sitter grammars sometimes get confused when { or } appears inside
# string literals — a correct parser counts brace pairs by TCL word boundary,
# not naive lexing.
# Expected symbols: 1 class + 2 methods.

class Tricky {
    inherit ::itk::Widget
    public method render {} {
        set templ "if {x} { return y }"
        set json {"key": "value", "nested": {"a": 1}}
        return [list $templ $json]
    }
    public method another {} {
        set s "}"
        set t "{"
        return $s$t
    }
}
