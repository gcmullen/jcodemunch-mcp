# Fixture: itcl::configbody declarations (out-of-line option handlers).
# Diagnostic probe — many parsers miss these entirely.
# Expected symbols: 1 class, 1 method (draw), 2 configbody declarations.
# (configbody may be indexed as method or skipped — both are valid answers,
#  but we want to see whether it's captured at all.)

itcl::class ConfigurableWidget {
    inherit ::itk::Widget
    itk_option define -color color Color "red"
    itk_option define -size  size  Size  10

    public method draw {} { return "drawn" }
}

itcl::configbody ConfigurableWidget::color {
    puts "color changed to $itk_option(-color)"
}

itcl::configbody ConfigurableWidget::size {
    puts "size changed to $itk_option(-size)"
}
