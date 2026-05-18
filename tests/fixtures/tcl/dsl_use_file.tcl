# A USE file invoking the bare `class` DSL (per §5.4.2 by-analogy with
# itcl::class). Top-level `class FooBar { ... }` IS a class declaration;
# bridge MUST emit class+method symbols.
class FooBar {
    method m {} {
        puts hi
    }
}
