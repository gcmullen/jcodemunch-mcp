# Fixture: classes and procs defined inside a namespace eval block.
# A correct parser should pick up every symbol, properly qualified by ::foo::.
# Expected symbols: 2 classes, 4 methods, 3 procs.

namespace eval ::foo {
    itcl::class FooWidget {
        inherit ::itk::Widget
        public method doIt {} {
            return "done"
        }
        public method doItAgain {args} {
            return [lindex $args 0]
        }
    }

    class BarWidget {
        inherit ::itk::Widget
        public method render {} { }
        public method refresh {} { }
    }

    proc utility1 {} { return 1 }
    proc utility2 {x} { return [expr {$x * 2}] }
    proc utility3 {} { return 3 }
}
