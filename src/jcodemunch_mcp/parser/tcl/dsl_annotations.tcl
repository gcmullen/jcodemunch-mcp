# dsl_annotations.tcl — Phase 5.2a.2 fully-generic DSL annotation tables.
#
# Two tables drive the generic walker in dsl_walker.tcl:
#
#   ANNOTATIONS  — outer commands (e.g. snit::type, itcl::class).
#   BODY_GRAMMARS — per-DSL directive rules (e.g. typemethod, method, delegate).
#
# Row format for ANNOTATIONS (7 columns):
#   {first second action kind grammar name_idx body_indices}
#
#   first         first word of outer cmd (e.g. "snit::type")
#   second        required second word; "" matches any
#   action        synth | augment | slot
#   kind          symbol kind for synth (e.g. "class", "function"); "" otherwise
#   grammar       BODY_GRAMMARS key to push during body walk; "" = plain script
#   name_idx      0-based word index of NAME
#   body_indices  list of body word indices (supports multi-body cmds like
#                 itk_component add); negative indices count from end (-1 = last)
#
# action semantics:
#   synth    — emit a new symbol of the given kind, then recurse body
#   augment  — find an existing class symbol by qname, recurse body into it
#   slot     — no symbol emitted; recurse body with parent context

namespace eval ::jcm::dsl {
    variable ANNOTATIONS {
        {snit::type            ""     synth   class    snit       1 {-1}}
        {snit::widget          ""     synth   class    snit       1 {-1}}
        {snit::widgetadapter   ""     synth   class    snit       1 {-1}}
        {::snit::type          ""     synth   class    snit       1 {-1}}
        {::snit::widget        ""     synth   class    snit       1 {-1}}
        {::snit::widgetadapter ""     synth   class    snit       1 {-1}}

        {clay::define          ""     synth   class    clay       1 {-1}}
        {::clay::define        ""     synth   class    clay       1 {-1}}

        {oo::define            ""     augment ""       oo_define  1 {-1}}
        {::oo::define          ""     augment ""       oo_define  1 {-1}}
        {oo::objdefine         ""     augment ""       oo_define  1 {-1}}
        {::oo::objdefine       ""     augment ""       oo_define  1 {-1}}

        {itk_component         add    slot    ""       itk        2 {-2 -1}}

        {itcl::class           ""     synth   class    itcl       1 {-1}}
        {::itcl::class         ""     synth   class    itcl       1 {-1}}
        {class                 ""     synth   class    itcl       1 {-1}}

        {proc  class       synth   function dsl_impl   1 {3}}
        {proc  field       synth   function dsl_impl   1 {3}}
        {proc  method      synth   function dsl_impl   1 {3}}
        {proc  constructor synth   function dsl_impl   1 {3}}
        {proc  type        synth   function dsl_impl   1 {3}}
        {proc  widget      synth   function dsl_impl   1 {3}}

        {itk_option           define slot    ""       itk        2 {-1}}
        {itcl::component      ""     slot    ""       itk        1 {-1}}
        {itcl::option         ""     slot    ""       itk        1 {-1}}
        {oo::class            create synth   class    oo_inline  2 {3}}
    }
}

# BODY_GRAMMARS dict — keyed by grammar name.
# Each value is a dict: directive_first_word -> action_spec dict.
#
# action_spec keys:
#   action         required: emit | emit_no_recurse | parent_classes | suppress
#   kind           symbol kind (emit / emit_no_recurse)
#   name_source    {idx N} or {literal STRING}
#   body_idx       word index of body (emit only)
#   keywords       list of keywords
#   note_template  string with ${cmd_word_N} substitution (optional)
#   conditional    {second_word_must_be VALUE} (optional)
#   start_idx      for parent_classes only; word index to start collecting from

namespace eval ::jcm::dsl {
    variable BODY_GRAMMARS [dict create \
        snit [dict create \
            typemethod   {action emit            kind class_method name_source {idx 1} body_idx 3 keywords {class_method}} \
            proc         {action emit            kind class_method name_source {idx 1} body_idx 3 keywords {class_method}} \
            method       {action emit            kind method       name_source {idx 1} body_idx 3 keywords {method}} \
            constructor  {action emit            kind constructor  name_source {literal constructor} body_idx 2 keywords {constructor}} \
            destructor   {action emit            kind destructor   name_source {literal destructor}  body_idx 1 keywords {destructor}} \
            option       {action suppress} \
            variable     {action suppress} \
            typevariable {action suppress} \
            component    {action suppress} \
            delegate     {action emit_no_recurse kind method       name_source {idx 2} keywords {method delegate} note_template {delegate to ${cmd_word_4}} conditional {second_word_must_be method}} \
            superclass   {action parent_classes start_idx 1} \
        ] \
        clay [dict create \
            method       {action emit kind method       name_source {idx 1} body_idx 3 keywords {method}} \
            proc         {action emit kind class_method name_source {idx 1} body_idx 3 keywords {class_method}} \
            constructor  {action emit kind constructor  name_source {literal constructor} body_idx 2 keywords {constructor}} \
            destructor   {action emit kind destructor   name_source {literal destructor}  body_idx 1 keywords {destructor}} \
            option       {action suppress} \
            variable     {action suppress} \
            superclass   {action parent_classes start_idx 1} \
        ] \
        oo_define [dict create \
            method       {action emit            kind method       name_source {idx 1} body_idx 3 keywords {method}} \
            constructor  {action emit            kind constructor  name_source {literal constructor} body_idx 2 keywords {constructor}} \
            destructor   {action emit            kind destructor   name_source {literal destructor}  body_idx 1 keywords {destructor}} \
            forward      {action emit_no_recurse kind method       name_source {idx 1} keywords {method forward} note_template {forward to ${cmd_word_2}}} \
            mixin        {action parent_classes start_idx 1} \
            superclass   {action parent_classes start_idx 1} \
        ] \
        itk [dict create \
            keep   {action suppress} \
            ignore {action suppress} \
            usual  {action suppress} \
            rename {action suppress} \
        ] \
        itcl [dict create \
            method      {action emit kind method       name_source {idx 1} body_idx 3 keywords {method}} \
            proc        {action emit kind class_method name_source {idx 1} body_idx 3 keywords {class_method}} \
            constructor {action emit kind constructor  name_source {literal constructor} body_idx -1 keywords {constructor}} \
            destructor  {action emit kind destructor   name_source {literal destructor}  body_idx 1 keywords {destructor}} \
            variable    {action suppress} \
            common      {action suppress} \
        ] \
        dsl_impl [dict create \
            class         {action suppress} \
            method        {action suppress} \
            constructor   {action suppress} \
            destructor    {action suppress} \
            body          {action suppress} \
            configbody    {action suppress} \
            public        {action suppress} \
            private       {action suppress} \
            protected     {action suppress} \
            namespace     {action suppress} \
            itk_component {action suppress} \
            itk_option    {action suppress} \
            oo::class     {action suppress} \
            itcl::class   {action suppress} \
        ] \
        oo_inline [dict create \
            method       {action emit            kind method       name_source {idx 1} body_idx 3 keywords {method}} \
            constructor  {action emit            kind method       name_source {literal constructor} body_idx 2 keywords {constructor}} \
            destructor   {action emit            kind method       name_source {literal destructor}  body_idx 1 keywords {destructor}} \
            forward      {action emit_no_recurse kind method       name_source {idx 1} keywords {method forward} note_template {forward to ${cmd_word_2}}} \
            mixin        {action parent_classes start_idx 1} \
            superclass   {action parent_classes start_idx 1} \
        ] \
    ]
}

# Look up the first annotation row whose first matches `first` AND whose
# second is either empty or equal to `second`. Returns the row as a list,
# or an empty list when no row applies.
#
# The new 7-column format uses `first` and `second` (columns 0 and 1)
# for matching — identical semantics to the old 6-column format.
proc ::jcm::dsl::lookup {first second} {
    variable ANNOTATIONS
    foreach row $ANNOTATIONS {
        set r_first  [lindex $row 0]
        set r_second [lindex $row 1]
        if {$r_first ne $first} continue
        if {$r_second ne "" && $r_second ne $second} continue
        return $row
    }
    return {}
}
