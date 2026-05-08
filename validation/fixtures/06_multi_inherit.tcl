# Fixture: multiple inheritance via itcl's `inherit A B C` form.
# A correct class-hierarchy builder should pick up all three parents.
# Expected symbols: 1 class with 3 parents, 1 method.

itcl::class Composite {
    inherit ::itk::Widget DCS::Component DCS::Observable

    public method sync {} { return "synced" }
}
