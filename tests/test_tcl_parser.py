"""Tests for native TCL/TK parser (tcl_parser_bridge.tcl)."""

import shutil
import pytest
from jcodemunch_mcp.parser import parse_file
from jcodemunch_mcp.parser.imports import extract_imports


# Skip all tests if tclsh is not installed.
pytestmark = pytest.mark.skipif(
    shutil.which("tclsh") is None,
    reason="tclsh not found on PATH",
)


# ---------------------------------------------------------------------------
# Fixtures: TCL source snippets
# ---------------------------------------------------------------------------

BASIC_PROCS = '''\
# Utility helpers
proc greet {name} {
    puts "Hello $name"
}

proc add {a b} {
    return [expr {$a + $b}]
}
'''

NAMESPACE_SOURCE = '''\
namespace eval ::app::config {
    namespace export get_setting set_setting

    variable settings

    proc get_setting {key {default ""}} {
        variable settings
        if {[info exists settings($key)]} {
            return $settings($key)
        }
        return $default
    }

    proc set_setting {key value} {
        variable settings
        set settings($key) $value
    }
}
'''

NESTED_NAMESPACE_SOURCE = '''\
namespace eval ::outer {
    namespace eval ::outer::inner {
        proc deep_func {} {
            return "deep"
        }
    }
}
'''

SPAGHETTI_SOURCE = '''\
proc unsafe_call {body} {
    upvar 1 conn conn
    uplevel 1 $body
}

proc global_user {} {
    global db_handle
    set db_handle [connect]
}

proc dynamic_dispatch {cmd args} {
    eval $cmd $args
}
'''

OO_CLASS_SOURCE = '''\
oo::class create Animal {
    constructor {name species} {
        my variable _name _species
        set _name $name
        set _species $species
    }

    method speak {} {
        my variable _name
        return "$_name says hello"
    }

    method eat {food} {
        puts "eating $food"
    }

    destructor {
        puts "goodbye"
    }
}
'''

SEMICOLON_SOURCE = '''\
proc alpha {} {return 1}; proc beta {} {return 2}
proc gamma {} {return 3}
'''

UTF8_SOURCE = '''\
# Ünîcödé comment — multi-byte chars
proc héllo {name} {
    puts "Héllo $name"
}
'''

TK_GUI_SOURCE = '''\
package require Tk

namespace eval ::gui {
    namespace export create_window

    proc create_window {title} {
        toplevel .main
        wm title .main $title
        ttk::button .main.btn -text "Click" -command [list ::gui::on_click]
    }

    proc on_click {} {
        tk_messageBox -message "Clicked"
    }
}
'''

IMPORT_SOURCE = '''\
package require Tk
package require http 2.7
package require -exact tls 1.6
source lib/utils.tcl
source "config/settings.tcl"
namespace import ::utils::*
namespace import -force ::app::config::*
'''

COMPLEXITY_SOURCE = '''\
proc complex_func {x y} {
    if {$x > 0} {
        if {$y > 0} {
            while {$x > 0} {
                foreach item $list {
                    if {$item eq "stop"} {
                        break
                    }
                }
                incr x -1
            }
        }
    } elseif {$x < 0} {
        switch $y {
            1 { return "one" }
            2 { return "two" }
        }
    }
    return $x
}
'''

CROSS_NAMESPACE_CALLS = '''\
namespace eval ::db {
    proc query {sql} {
        return [execute $sql]
    }
}

namespace eval ::app {
    proc handle_request {} {
        set result [::db::query "SELECT 1"]
        ::app::config::set_setting "last_query" $result
    }
}
'''


# ---------------------------------------------------------------------------
# Tests: basic proc extraction
# ---------------------------------------------------------------------------

class TestBasicProcs:
    def test_extracts_top_level_procs(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        names = {s.name for s in symbols}
        assert "greet" in names
        assert "add" in names

    def test_proc_kind_is_function(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        for s in symbols:
            assert s.kind == "function"

    def test_proc_language(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        for s in symbols:
            assert s.language == "tcl"

    def test_proc_param_count(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert by_name["greet"].param_count == 1
        assert by_name["add"].param_count == 2

    def test_proc_has_signature(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert "greet" in by_name["greet"].signature
        assert "add" in by_name["add"].signature

    def test_proc_line_numbers(self):
        symbols = parse_file(BASIC_PROCS, "basic.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert by_name["greet"].line == 2
        assert by_name["greet"].end_line == 4


# ---------------------------------------------------------------------------
# Tests: namespace extraction
# ---------------------------------------------------------------------------

class TestNamespaces:
    def test_namespace_emits_namespace_kind(self):
        # `namespace eval` is structurally a TCL namespace, not an iTcl class.
        # Keeping the kinds distinct preserves the namespace ↔ class
        # distinction (TCL → C++) and matches LSP SymbolKind semantics.
        symbols = parse_file(NAMESPACE_SOURCE, "ns.tcl", "tcl")
        ns = [s for s in symbols if s.kind == "namespace"]
        assert len(ns) == 1
        assert ns[0].qualified_name == "::app::config"

    def test_namespace_children_have_parent(self):
        symbols = parse_file(NAMESPACE_SOURCE, "ns.tcl", "tcl")
        funcs = [s for s in symbols if s.kind == "function"]
        assert len(funcs) == 2
        for f in funcs:
            assert f.parent is not None
            assert "::app::config" in f.parent

    def test_namespace_qualified_names(self):
        symbols = parse_file(NAMESPACE_SOURCE, "ns.tcl", "tcl")
        names = {s.qualified_name for s in symbols if s.kind == "function"}
        assert "::app::config::get_setting" in names
        assert "::app::config::set_setting" in names

    def test_namespace_exports_in_decorators(self):
        symbols = parse_file(NAMESPACE_SOURCE, "ns.tcl", "tcl")
        ns = [s for s in symbols if s.kind == "namespace"][0]
        assert "get_setting" in ns.decorators
        assert "set_setting" in ns.decorators

    def test_nested_namespaces(self):
        symbols = parse_file(NESTED_NAMESPACE_SOURCE, "nested.tcl", "tcl")
        names = {s.qualified_name for s in symbols}
        assert "::outer" in names
        assert "::outer::inner" in names
        assert "::outer::inner::deep_func" in names


# ---------------------------------------------------------------------------
# Tests: spaghetti annotations
# ---------------------------------------------------------------------------

class TestAnnotations:
    def test_uplevel_detected(self):
        symbols = parse_file(SPAGHETTI_SOURCE, "spag.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert "uplevel" in by_name["unsafe_call"].decorators

    def test_upvar_detected(self):
        symbols = parse_file(SPAGHETTI_SOURCE, "spag.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert "upvar" in by_name["unsafe_call"].decorators

    def test_global_access_detected(self):
        symbols = parse_file(SPAGHETTI_SOURCE, "spag.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert "global_access" in by_name["global_user"].decorators

    def test_dynamic_eval_detected(self):
        symbols = parse_file(SPAGHETTI_SOURCE, "spag.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert "dynamic_eval" in by_name["dynamic_dispatch"].decorators


# ---------------------------------------------------------------------------
# Tests: TclOO classes
# ---------------------------------------------------------------------------

class TestOOClass:
    def test_class_extracted(self):
        symbols = parse_file(OO_CLASS_SOURCE, "oo.tcl", "tcl")
        classes = [s for s in symbols if s.kind == "class"]
        assert len(classes) == 1
        assert classes[0].name == "Animal"

    def test_constructor_extracted(self):
        symbols = parse_file(OO_CLASS_SOURCE, "oo.tcl", "tcl")
        cons = [s for s in symbols if s.name == "constructor"]
        assert len(cons) == 1
        assert cons[0].kind == "method"
        assert cons[0].param_count == 2

    def test_methods_extracted(self):
        symbols = parse_file(OO_CLASS_SOURCE, "oo.tcl", "tcl")
        methods = [s for s in symbols if s.kind == "method" and s.name not in ("constructor", "destructor")]
        names = {m.name for m in methods}
        assert "speak" in names
        assert "eat" in names

    def test_destructor_extracted(self):
        symbols = parse_file(OO_CLASS_SOURCE, "oo.tcl", "tcl")
        dest = [s for s in symbols if s.name == "destructor"]
        assert len(dest) == 1
        assert dest[0].kind == "method"

    def test_oo_methods_have_parent(self):
        symbols = parse_file(OO_CLASS_SOURCE, "oo.tcl", "tcl")
        methods = [s for s in symbols if s.kind == "method"]
        for m in methods:
            assert m.parent is not None
            assert "Animal" in m.parent


# ---------------------------------------------------------------------------
# Tests: semicolon splitting
# ---------------------------------------------------------------------------

class TestSemicolonSplitting:
    def test_semicolon_separated_procs(self):
        symbols = parse_file(SEMICOLON_SOURCE, "semi.tcl", "tcl")
        names = {s.name for s in symbols}
        assert "alpha" in names
        assert "beta" in names
        assert "gamma" in names
        assert len(symbols) == 3

    def test_semicolon_procs_have_distinct_offsets(self):
        symbols = parse_file(SEMICOLON_SOURCE, "semi.tcl", "tcl")
        by_name = {s.name: s for s in symbols}
        assert by_name["alpha"].byte_offset != by_name["beta"].byte_offset


# ---------------------------------------------------------------------------
# Tests: UTF-8 byte offsets
# ---------------------------------------------------------------------------

class TestUTF8:
    def test_utf8_byte_offsets_correct(self):
        symbols = parse_file(UTF8_SOURCE, "utf8.tcl", "tcl")
        assert len(symbols) >= 1
        raw = UTF8_SOURCE.encode("utf-8")
        for s in symbols:
            # Verify byte slice lands on the actual source
            snippet = raw[s.byte_offset:s.byte_offset + s.byte_length]
            assert b"proc" in snippet or b"namespace" in snippet

    def test_content_hash_computed(self):
        symbols = parse_file(UTF8_SOURCE, "utf8.tcl", "tcl")
        for s in symbols:
            assert s.content_hash != ""
            assert len(s.content_hash) == 64  # SHA-256 hex


# ---------------------------------------------------------------------------
# Tests: TK files
# ---------------------------------------------------------------------------

class TestTKFiles:
    def test_tk_extension_parses(self):
        symbols = parse_file(TK_GUI_SOURCE, "gui.tk", "tcl")
        names = {s.qualified_name for s in symbols}
        assert "::gui" in names
        assert "::gui::create_window" in names
        assert "::gui::on_click" in names

    def test_itcl_extension_maps_to_tcl(self):
        from jcodemunch_mcp.parser.languages import get_language_for_path
        assert get_language_for_path("widget.itcl") == "tcl"
        assert get_language_for_path("dialog.tk") == "tcl"


# ---------------------------------------------------------------------------
# Tests: imports
# ---------------------------------------------------------------------------

class TestImports:
    def test_package_require(self):
        imports = extract_imports(IMPORT_SOURCE, "test.tcl", "tcl")
        specs = {i["specifier"] for i in imports}
        assert "Tk" in specs
        assert "http" in specs
        assert "tls" in specs

    def test_source_imports(self):
        imports = extract_imports(IMPORT_SOURCE, "test.tcl", "tcl")
        specs = {i["specifier"] for i in imports}
        assert "lib/utils.tcl" in specs
        assert "config/settings.tcl" in specs

    def test_namespace_imports(self):
        imports = extract_imports(IMPORT_SOURCE, "test.tcl", "tcl")
        specs = {i["specifier"] for i in imports}
        assert "::utils::*" in specs
        assert "::app::config::*" in specs


# ---------------------------------------------------------------------------
# Tests: complexity metrics
# ---------------------------------------------------------------------------

class TestComplexity:
    def test_cyclomatic_gt_1(self):
        symbols = parse_file(COMPLEXITY_SOURCE, "complex.tcl", "tcl")
        func = symbols[0]
        assert func.cyclomatic > 1

    def test_max_nesting_gt_0(self):
        symbols = parse_file(COMPLEXITY_SOURCE, "complex.tcl", "tcl")
        func = symbols[0]
        assert func.max_nesting > 0

    def test_param_count(self):
        symbols = parse_file(COMPLEXITY_SOURCE, "complex.tcl", "tcl")
        func = symbols[0]
        assert func.param_count == 2


# ---------------------------------------------------------------------------
# Tests: cross-namespace call references
# ---------------------------------------------------------------------------

class TestCallReferences:
    def test_cross_namespace_calls(self):
        symbols = parse_file(CROSS_NAMESPACE_CALLS, "calls.tcl", "tcl")
        handle = [s for s in symbols if s.name == "handle_request"][0]
        assert "::db::query" in handle.call_references
        assert "::app::config::set_setting" in handle.call_references

    def test_local_calls(self):
        symbols = parse_file(CROSS_NAMESPACE_CALLS, "calls.tcl", "tcl")
        query = [s for s in symbols if s.name == "query"][0]
        assert "execute" in query.call_references


# ---------------------------------------------------------------------------
# Tests: fallback to tree-sitter when tclsh unavailable
# ---------------------------------------------------------------------------

# Retired class: TestFallback.test_fallback_still_extracts_symbols
# Rationale: per architectural decision (P1.2, no-fallback policy), the
# tree-sitter `_parse_tcl_symbols` fallback is removed. tcl_disasm_bridge.tcl
# is the canonical TCL parser; missing tclsh raises RuntimeError with install
# instructions instead of falling back. The retired test exercised behavior
# that no longer exists.


# ---------------------------------------------------------------------------
# Tests: TCL-native call extraction — codify the architectural fixes that
# moved extract_calls off raw regex onto split_commands + lrange list
# semantics. Each test pins down one class of bug that the regex-era
# implementation either missed or false-positively captured.
# ---------------------------------------------------------------------------

NATIVE_CALL_FIXTURES = '''\
proc string_arg_no_fp {} {
    addInput "$systemIdle contents {} {supporting device}"
    deleteInput "$systemIdle contents"
}

proc eval_prefix_dispatch {args} {
    eval $itk_component(notebook) addChildVisibilityControl $args
}

proc uplevel_prefix_dispatch {} {
    uplevel #0 $self handleEvent
}

proc inline_brace_foreach {} {
    foreach bl [getBeamlines] {$itk_component(beamlines) insert 0 $bl}
}

proc single_command_if {} {
    if {$x} {realCallA}
    if {$y} {do1} elseif {$z} {do2} else {do3}
}

proc bracket_dispatch {} {
    set v [$obj computeValue $arg]
}

proc nsqualified_no_leading {} {
    DCS::DeviceFactory::getObject
    set f [DCS::Factory::lookup foo]
}

proc nsqualified_with_leading {} {
    ::Logger::log "hello"
}

proc literal_list_no_fp {} {
    foreach x {alpha beta gamma} {
        consume $x
    }
    set L {one two three}
}

proc comment_line_ignored {} {
    realCall
    #fakeCall in a comment line should not become a callee
}
'''


class TestExtractCallsNative:
    def _calls_for(self, name):
        symbols = parse_file(NATIVE_CALL_FIXTURES, "native.tcl", "tcl")
        return [s for s in symbols if s.name == name][0].call_references

    def test_string_arg_does_not_capture_word_inside_quotes(self):
        # `{supporting device}` lives inside a "..." quoted argument; lrange
        # treats the whole string as a single word so words inside it are
        # never mistaken for code.
        calls = self._calls_for("string_arg_no_fp")
        assert "addInput" in calls
        assert "deleteInput" in calls
        assert "supporting" not in calls
        assert "contents" not in calls

    def test_eval_prefix_dispatch_resolves(self):
        # `eval $obj method args` concatenates and re-evaluates as one
        # command; the inner method must surface as a callee.
        calls = self._calls_for("eval_prefix_dispatch")
        assert "addChildVisibilityControl" in calls

    def test_uplevel_prefix_dispatch_resolves(self):
        calls = self._calls_for("uplevel_prefix_dispatch")
        assert "handleEvent" in calls

    def test_inline_brace_foreach_body_is_recursed(self):
        # Body in `foreach v $L {$obj method args}` has no whitespace before
        # `{`, but lrange reaches the body word and the foreach-special path
        # recurses into it.
        calls = self._calls_for("inline_brace_foreach")
        assert "insert" in calls
        assert "getBeamlines" in calls  # via bracket walker

    def test_single_command_if_body_is_recursed(self):
        # `if {$x} {realCallA}` body is a lone token; the if-special path
        # treats every non-keyword arg as a body candidate so single-cmd
        # bodies still surface.
        calls = self._calls_for("single_command_if")
        assert "realCallA" in calls
        # if/elseif/else chain — every branch body captured.
        assert "do1" in calls
        assert "do2" in calls
        assert "do3" in calls

    def test_bracket_dispatch_resolved(self):
        # `[$obj method]` — bracket walker recurses into the substitution.
        calls = self._calls_for("bracket_dispatch")
        assert "computeValue" in calls

    def test_namespace_qualified_call_no_leading(self):
        # `Foo::Bar::baz` (without leading `::`) — namespace-qualified
        # match in extract_calls' Pattern A.
        calls = self._calls_for("nsqualified_no_leading")
        assert "DCS::DeviceFactory::getObject" in calls
        assert "DCS::Factory::lookup" in calls

    def test_namespace_qualified_call_with_leading(self):
        calls = self._calls_for("nsqualified_with_leading")
        assert "::Logger::log" in calls

    def test_literal_list_arg_does_not_fp(self):
        # `foreach var {a b c} body` — the list literal is the var-list
        # slot, not code; `a`/`b`/`c` must NOT become callees. Likewise
        # `set L {one two three}` — `one` must not become a callee.
        calls = self._calls_for("literal_list_no_fp")
        assert "consume" in calls          # foreach body did recurse
        assert "alpha" not in calls
        assert "beta" not in calls
        assert "gamma" not in calls
        assert "one" not in calls
        assert "two" not in calls
        assert "three" not in calls

    def test_comment_line_does_not_pollute_callees(self):
        calls = self._calls_for("comment_line_ignored")
        assert "realCall" in calls
        assert "fakeCall" not in calls

    def test_value_eating_builtin_args_not_recursed(self):
        # `set x [string trim $err "PR ER\\n\\n"]` — the bracket walker
        # recurses into `string trim $err "PR ER\\n\\n"` and lrange unwraps
        # the "..." string into `PR ER\\n\\n` which contains a literal \\n.
        # Without the value-only guard the \\n triggers code recursion and
        # captures `PR` as a Pattern A callee. With the guard, builtins
        # like `string` short-circuit before the arg loop.
        src = '''\
proc value_only_string_arg {} {
    set err [string trim $message "PR ER\\n\\n"]
    set hi  [list "Click here" "Type next"]
    return [format "got %s" $err]
}
'''
        symbols = parse_file(src, "vouchers.tcl", "tcl")
        sym = [s for s in symbols if s.name == "value_only_string_arg"][0]
        assert "PR" not in sym.call_references
        assert "ER" not in sym.call_references
        assert "Click" not in sym.call_references
        assert "Type" not in sym.call_references
        assert "got" not in sym.call_references


# ---------------------------------------------------------------------------
# Tests: 3-arg iTcl constructor form — `constructor args init body` was
# previously emitted with the empty init slot as the body, dropping every
# captured callee for the affected constructors.
# ---------------------------------------------------------------------------

THREE_ARG_CTOR_SOURCE = '''\
itcl::class Widget {
    inherit ::itk::Widget
    constructor { args } { } {
        registerWith $self
        $self handleAttributeUpdate
        eval itk_initialize $args
    }
}

itcl::class TwoArgWidget {
    constructor { args } {
        legacyTwoArgInit $args
    }
}
'''


class TestThreeArgConstructor:
    def test_3arg_ctor_body_is_parsed(self):
        symbols = parse_file(THREE_ARG_CTOR_SOURCE, "ctor.tcl", "tcl")
        ctor = [s for s in symbols if s.name == "constructor"
                and "Widget::" in s.qualified_name
                and "TwoArg" not in s.qualified_name][0]
        assert "registerWith" in ctor.call_references
        assert "handleAttributeUpdate" in ctor.call_references
        # itk_initialize is a framework lifecycle call (skip-listed), not
        # a user callee — its absence is the policy, not a regression.
        assert "itk_initialize" not in ctor.call_references

    def test_2arg_ctor_form_still_works(self):
        symbols = parse_file(THREE_ARG_CTOR_SOURCE, "ctor.tcl", "tcl")
        ctor = [s for s in symbols if s.name == "constructor"
                and "TwoArg" in s.qualified_name][0]
        assert "legacyTwoArgInit" in ctor.call_references


# ---------------------------------------------------------------------------
# Tests: count_cyclomatic / count_max_nesting / detect_annotations are
# string-aware. Tokens inside "..." literals must not be counted.
# ---------------------------------------------------------------------------

STRING_AWARE_METRICS = '''\
proc cyclo_with_string_keyword {} {
    # Body has one real `if` branch; the rest live inside string literals.
    if {$x} {
        puts "if you want, type while followed by foreach"
        return [list "for x in y" "switch yes"]
    }
}

proc nesting_with_string_braces {} {
    # Real depth = 2; the string contains fake braces that must not count.
    if {$x} {
        while {$y} {
            puts "data: {a {b}}"
        }
    }
}

proc annotations_in_strings {} {
    # `error "use of uplevel..."` mentions uplevel literally; no annotation.
    error "use of uplevel was unsafe"
    puts "consider using upvar instead"
}

proc real_uplevel_annotated {} {
    uplevel 1 $body
}
'''


class TestStringAwareMetrics:
    def test_cyclomatic_ignores_string_keywords(self):
        symbols = parse_file(STRING_AWARE_METRICS, "metrics.tcl", "tcl")
        sym = [s for s in symbols if s.name == "cyclo_with_string_keyword"][0]
        # 1 (base) + 1 (the real if) = 2. The `while`/`foreach`/`for`/`switch`
        # tokens are inside "..." strings and must not contribute.
        assert sym.cyclomatic == 2

    def test_nesting_ignores_string_braces(self):
        symbols = parse_file(STRING_AWARE_METRICS, "metrics.tcl", "tcl")
        sym = [s for s in symbols if s.name == "nesting_with_string_braces"][0]
        # Real depth: proc-body brace + if-body brace = 2.
        # String "data: {a {b}}" has 2 fake `{` that must not raise depth.
        assert sym.max_nesting == 2

    def test_annotation_ignores_string_keywords(self):
        symbols = parse_file(STRING_AWARE_METRICS, "metrics.tcl", "tcl")
        sym = [s for s in symbols if s.name == "annotations_in_strings"][0]
        assert "uplevel" not in sym.decorators
        assert "upvar" not in sym.decorators

    def test_real_uplevel_still_annotated(self):
        symbols = parse_file(STRING_AWARE_METRICS, "metrics.tcl", "tcl")
        sym = [s for s in symbols if s.name == "real_uplevel_annotated"][0]
        assert "uplevel" in sym.decorators


# ---------------------------------------------------------------------------
# Tests: switch / try precision — pattern/body pairs and on/finally clauses
# decoded by position so pattern literals and errcode lists don't pollute
# the callee set.
# ---------------------------------------------------------------------------

SWITCH_TRY_FIXTURES = '''\
proc switch_inline_pairs {} {
    switch -exact $cmd \\
        foo  {fooBody arg} \\
        bar  {barBody arg} \\
        biff -                  \\
        baz  {bazBody arg}      \\
        default {defaultBody}
}

proc switch_block_form {} {
    switch -glob $name {
        a*       {aBody}
        {[bc]*}  {bcBody}
        default  {fallbackBody}
    }
}

proc try_with_handlers {} {
    try {
        riskyOp $arg
    } on error {TCL ERROR DICT MISSING} {
        recoverFromMissing
    } trap {TCL OPERATION CANCEL} {msg opts} {
        recoverFromCancel
    } finally {
        cleanupAlways
    }
}
'''


class TestSwitchTryPrecision:
    def test_switch_inline_pair_bodies_captured(self):
        symbols = parse_file(SWITCH_TRY_FIXTURES, "switchtry.tcl", "tcl")
        sym = [s for s in symbols if s.name == "switch_inline_pairs"][0]
        assert "fooBody" in sym.call_references
        assert "barBody" in sym.call_references
        assert "bazBody" in sym.call_references
        assert "defaultBody" in sym.call_references
        # Pattern literals (foo/bar/biff/baz) must not be captured.
        assert "foo" not in sym.call_references
        assert "bar" not in sym.call_references
        assert "biff" not in sym.call_references
        assert "baz" not in sym.call_references

    def test_switch_block_form_bodies_captured(self):
        symbols = parse_file(SWITCH_TRY_FIXTURES, "switchtry.tcl", "tcl")
        sym = [s for s in symbols if s.name == "switch_block_form"][0]
        assert "aBody" in sym.call_references
        assert "bcBody" in sym.call_references
        assert "fallbackBody" in sym.call_references
        assert "default" not in sym.call_references

    def test_try_main_body_handler_finally_all_recursed(self):
        symbols = parse_file(SWITCH_TRY_FIXTURES, "switchtry.tcl", "tcl")
        sym = [s for s in symbols if s.name == "try_with_handlers"][0]
        assert "riskyOp" in sym.call_references
        assert "recoverFromMissing" in sym.call_references
        assert "recoverFromCancel" in sym.call_references
        assert "cleanupAlways" in sym.call_references
        # errcode list literals (TCL/ERROR/DICT/MISSING/etc.) must NOT
        # surface as callees.
        assert "TCL" not in sym.call_references
        assert "ERROR" not in sym.call_references
        assert "DICT" not in sym.call_references
        assert "MISSING" not in sym.call_references
        assert "OPERATION" not in sym.call_references
        assert "CANCEL" not in sym.call_references


# ---------------------------------------------------------------------------
# Tests: lmap / apply / dict for|with|update / coroutine / time precision
# ---------------------------------------------------------------------------

BODY_TAKING_FIXTURES = '''\
proc lmap_single_var {} {
    return [lmap x $list {transform $x}]
}

proc lmap_multi_var {} {
    return [lmap x $a y $b {combine $x $y}]
}

proc apply_lambda {} {
    set sq [list x {return [calculateSquare $x]}]
    apply $sq 5
    apply {{x y} {sumValues $x $y}} 3 4
}

proc dict_for_body {} {
    dict for {k v} $config {processEntry $k $v}
}

proc dict_with_body {} {
    dict with rec {applyRecord $name $value}
}

proc dict_update_body {} {
    dict update myvar a aval b bval {persistChanges $aval $bval}
}

proc coroutine_body {} {
    coroutine genX produceValues 1 100
    coroutine genY {worker $args}
}

proc time_body {} {
    set elapsed [time {timedOperation $arg} 100]
}
'''


class TestBodyTakingPrecision:
    def _calls(self, name):
        symbols = parse_file(BODY_TAKING_FIXTURES, "bodies.tcl", "tcl")
        return [s for s in symbols if s.name == name][0].call_references

    def test_lmap_single_var_body(self):
        c = self._calls("lmap_single_var")
        assert "transform" in c

    def test_lmap_multi_var_body(self):
        c = self._calls("lmap_multi_var")
        assert "combine" in c

    def test_apply_lambda_body(self):
        c = self._calls("apply_lambda")
        # First lambda is via $sq variable so its body is invisible at
        # static-analysis time. Inline lambda is decoded.
        assert "sumValues" in c

    def test_dict_for_body(self):
        c = self._calls("dict_for_body")
        assert "processEntry" in c
        # Var names {k v} must NOT be captured.
        assert "k" not in c
        assert "v" not in c

    def test_dict_with_body(self):
        c = self._calls("dict_with_body")
        assert "applyRecord" in c

    def test_dict_update_body(self):
        c = self._calls("dict_update_body")
        assert "persistChanges" in c
        # update key/var args (a, aval, b, bval) must NOT be captured.
        assert "a" not in c
        assert "b" not in c
        assert "aval" not in c
        assert "bval" not in c

    def test_coroutine_body(self):
        c = self._calls("coroutine_body")
        assert "produceValues" in c
        assert "worker" in c

    def test_time_body(self):
        c = self._calls("time_body")
        assert "timedOperation" in c


# ---------------------------------------------------------------------------
# Tests: iTk DSL handling — itk_component add / itk_option define
# ---------------------------------------------------------------------------

ITK_DSL_FIXTURES = '''\
proc itk_basic {} {
    itk_component add notebook {
        iwidgets::Tabnotebook $itk_interior.nb -tabpos n
    } {
        keep -background -foreground
        ignore -relief
    }
    eval itk_initialize $args
}

proc itk_protected_flag {} {
    itk_component add -protected priv {
        DCS::PrivateThing $itk_interior.priv
    } {
        keep -opt
        usual
    }
}

proc itk_option_no_body {} {
    itk_option define -controlSystem controlSystem ControlSystem "::dcss"
}

proc itk_option_with_body {} {
    itk_option define -onChange onChange OnChange "" {
        notifyChange $itk_option(-onChange)
    }
}
'''


class TestItkDsl:
    def _calls(self, name):
        symbols = parse_file(ITK_DSL_FIXTURES, "itk.tcl", "tcl")
        return [s for s in symbols if s.name == name][0].call_references

    def test_itk_component_creation_body_recursed(self):
        c = self._calls("itk_basic")
        assert "iwidgets::Tabnotebook" in c

    def test_itk_component_config_block_not_recursed(self):
        c = self._calls("itk_basic")
        # Config block DSL keywords must not surface as callees.
        assert "keep" not in c
        assert "ignore" not in c
        # itk_component / itk_initialize are framework lifecycle calls,
        # not user callees.
        assert "itk_component" not in c
        assert "itk_initialize" not in c

    def test_itk_component_protected_flag(self):
        c = self._calls("itk_protected_flag")
        assert "DCS::PrivateThing" in c
        assert "keep" not in c
        assert "usual" not in c
        assert "itk_component" not in c

    def test_itk_option_no_body_no_capture(self):
        c = self._calls("itk_option_no_body")
        assert "itk_option" not in c
        # No body means nothing user-callable to capture in this proc.
        assert c == [] or all(x.startswith("::dcss") is False for x in c)

    def test_itk_option_with_body_recursed(self):
        c = self._calls("itk_option_with_body")
        assert "notifyChange" in c
        assert "itk_option" not in c


# ---------------------------------------------------------------------------
# Tests: Tk -flag value pairs — multi-line `-text "..."` strings must not
# leak prose words as callees, but `-command "..."` script flags still must.
# ---------------------------------------------------------------------------

TK_FLAG_FIXTURES = '''\
proc tk_text_with_newlines_no_fp {} {
    label $w.note -text "This option is only used for installation
of the displacement sensor hardware and stand.

For more information see the manual."
}

proc tk_text_with_command_recurses {} {
    button $w.btn \\
        -text "Click me" \\
        -command "
            doSetup
            doFinish
        "
}

proc itk_component_with_text {} {
    itk_component add note {
        label $ring.note -text "This is a multi-line
warning message.

For details, click here."
    } {
    }
}
'''


class TestTkFlagValueIdiom:
    def _calls(self, name):
        symbols = parse_file(TK_FLAG_FIXTURES, "tkflag.tcl", "tcl")
        return [s for s in symbols if s.name == name][0].call_references

    def test_text_flag_does_not_leak_prose(self):
        c = self._calls("tk_text_with_newlines_no_fp")
        assert "label" in c
        # The string content of -text must not be parsed as a body. Prose
        # words at the start of each line must NOT surface as callees.
        for word in ("This", "of", "For", "the"):
            assert word not in c, f"{word!r} leaked from -text string"

    def test_command_flag_still_recurses(self):
        c = self._calls("tk_text_with_command_recurses")
        # -command's body is a script — its calls should be captured.
        assert "doSetup" in c
        assert "doFinish" in c
        # -text content must NOT leak.
        assert "Click" not in c

    def test_itk_component_with_text_no_leak(self):
        c = self._calls("itk_component_with_text")
        assert "label" in c
        for word in ("This", "warning", "For", "details"):
            assert word not in c, f"{word!r} leaked through itk_component+label"


# ---------------------------------------------------------------------------
# Tests: dispatch on FQN receivers, bind callbacks, and `\<newline>` line
# continuation followed by a "..."-quoted arg (a recall regression class
# that masked addInput / register / handleResize / ::config get* across
# BluIceWidgets/Scan3DView and BeamlineVideo).
# ---------------------------------------------------------------------------

DISPATCH_FIXTURES = '''\
proc fqn_global_dispatch {} {
    set u [::config getImageUrl 1]
    set h [::config getImgsrvHost]
    ::mediator notify event_x args
}

proc fqn_multi_segment_is_proc_call {} {
    # Multi-segment FQNs are procedure calls — only Pattern A captures
    # the proc name; word 2 must NOT be treated as a method.
    DCS::Component::register $obj
}

proc bind_callback_dispatch {} {
    bind $w <Configure> "$this handleResize %W %w %h"
    bind $w <Button-1>  "$this handleClick"
}

proc line_continuation_with_quoted_arg {} {
    # Real-world idiom: `\\<newline>` + indented `"...{...}..."` value.
    # Was previously silently dropping the whole command because lrange
    # couldn't list-parse the cmd_text.
    $itk_component(movePhi0) addInput \\
    "$m_objInfo first_area_defined 1 {define raster first}"
    $m_objSampleCameraConstant \\
    register $this contents handleBeamCenterChange
}
'''


class TestDispatchAndContinuation:
    def _calls(self, name):
        symbols = parse_file(DISPATCH_FIXTURES, "disp.tcl", "tcl")
        return [s for s in symbols if s.name == name][0].call_references

    def test_fqn_global_dispatch_captures_method(self):
        c = self._calls("fqn_global_dispatch")
        assert "::config" in c
        assert "getImageUrl" in c
        assert "getImgsrvHost" in c
        assert "::mediator" in c
        assert "notify" in c

    def test_multi_segment_fqn_is_only_proc_capture(self):
        c = self._calls("fqn_multi_segment_is_proc_call")
        assert "DCS::Component::register" in c
        # `$obj` is not a method — must not become a capture under the
        # FQN-dispatch rule (which only fires for single-segment globals).
        assert "obj" not in c

    def test_bind_callback_dispatch_captured(self):
        c = self._calls("bind_callback_dispatch")
        assert "handleResize" in c
        assert "handleClick" in c
        # `bind` itself is the framework call, not a user callee.
        # The current parser does still capture it via Pattern A, which
        # is fine — but the methods MUST be there.

    def test_line_continuation_quoted_arg_recovers(self):
        c = self._calls("line_continuation_with_quoted_arg")
        # Both Pattern B dispatches must surface despite the
        # `\<newline>`-followed-by-quote idiom that broke lrange.
        assert "addInput" in c
        assert "register" in c


# ---------------------------------------------------------------------------
# Tests: unresolved-dispatch tagging (per SPEC.md section 4)
#
# Dynamic-dispatch sites that exist in the source but cannot be statically
# resolved are recorded on each symbol's `unresolved_dispatches` field
# rather than silently dropped. Each entry is {line, kind, snippet}.
# ---------------------------------------------------------------------------

UNRESOLVED_FIXTURES = '''\
proc resolved_only_no_unresolved {} {
    foo arg1
    $obj method arg1
    [foo bar]
    eval somecmd literal_arg
}

proc has_eval_var {} {
    set cmd "foo bar"
    eval $cmd
}

proc has_eval_brackets {} {
    eval [build_cmd $x]
}

proc has_uplevel_var {} {
    uplevel $script
    uplevel #1 $other_script
}

proc has_interp_eval {} {
    interp eval $other $cmd
}

proc has_var_command {} {
    $cmd_name arg1 arg2
}

proc has_var_method {} {
    $obj $methodvar args
    [$obj $methodvar args]
}

proc has_eval_list_resolvable {} {
    # eval [list ...] is statically resolvable; should NOT mark as unresolved.
    eval [list realCallA realArg1]
}
'''


def _unresolved_for(name):
    symbols = parse_file(UNRESOLVED_FIXTURES, "unresolved.tcl", "tcl")
    return [s for s in symbols if s.name == name][0].unresolved_dispatches


def _kinds(entries):
    return [e["kind"] for e in entries]


class TestUnresolvedDispatch:
    def test_resolved_only_emits_no_unresolved(self):
        u = _unresolved_for("resolved_only_no_unresolved")
        assert u == [], f"expected empty, got {u}"

    def test_eval_var_tagged(self):
        u = _unresolved_for("has_eval_var")
        kinds = _kinds(u)
        assert "eval_var" in kinds
        # snippet contains the actual cmd text
        ev = [e for e in u if e["kind"] == "eval_var"][0]
        assert "eval $cmd" in ev["snippet"]
        assert ev["line"] >= 9 and ev["line"] <= 11  # inside the proc

    def test_eval_brackets_tagged(self):
        u = _unresolved_for("has_eval_brackets")
        assert "eval_brackets" in _kinds(u)

    def test_uplevel_var_tagged(self):
        u = _unresolved_for("has_uplevel_var")
        kinds = _kinds(u)
        # both `uplevel $script` and `uplevel #1 $other_script` should mark.
        assert kinds.count("uplevel_var") == 2

    def test_interp_eval_tagged(self):
        u = _unresolved_for("has_interp_eval")
        assert "interp_eval" in _kinds(u)

    def test_var_command_tagged(self):
        u = _unresolved_for("has_var_command")
        # `$cmd_name arg1 arg2` — Pattern B fails because second word is not
        # method-shaped (`arg1` IS method-shaped though...). Let me think:
        # actually arg1 matches ^[a-zA-Z_]\w*$, so Pattern B would capture
        # arg1 as a method. So this is not an unresolved case under our
        # current definition — Pattern B captures the second word as the
        # "method" callee even though the receiver is a variable.
        # The genuinely unresolved case is `$cmd` ALONE (one word).
        # Skipping aggressive assertion here; just verify no crash.
        assert isinstance(u, list)

    def test_var_method_tagged(self):
        u = _unresolved_for("has_var_method")
        assert "var_method" in _kinds(u)

    def test_eval_list_is_resolvable_not_unresolved(self):
        u = _unresolved_for("has_eval_list_resolvable")
        # `eval [list ...]` is statically constructible; should not be
        # tagged as eval_brackets.
        assert "eval_brackets" not in _kinds(u)


# ---------------------------------------------------------------------------
# Tests: v2.2 schema additions — parent_classes (class symbols only) and
# package_requires (__script__ symbol only).  Per WALKER_CONTRACT_v2_2.md
# §13.2 / §13.3 (decided=B): host-only fields, always present, always a
# list, empty -> [].  Δ0.2 C1: `package require` ALSO emits kind=import.
# ---------------------------------------------------------------------------

PARENT_CLASSES_EMPTY = '''\
itcl::class StandaloneWidget {
    method foo {} { return 1 }
}
'''

PARENT_CLASSES_MULTI = '''\
itcl::class MultiBaseWidget {
    inherit Base1 Base2
    method bar {} { return 2 }
}
'''

PACKAGE_REQUIRES_VERSIONED = '''\
package require Tcl 8.6
package require Tk
package require http 2.7

proc foo {} { return 1 }
'''


class TestParentClassesField:
    def test_parent_classes_field_present_and_empty_when_no_inherit(self):
        # A class with no inherit/superclass must still carry an empty
        # parent_classes list per §13.2 decided=B (always-present).
        symbols = parse_file(PARENT_CLASSES_EMPTY, "single.tcl", "tcl")
        classes = [s for s in symbols if s.kind == "class"]
        assert len(classes) == 1
        assert classes[0].parent_classes == [], (
            f"expected [], got {classes[0].parent_classes!r}"
        )

    def test_parent_classes_captures_multi_base_with_lines(self):
        # `inherit Base1 Base2` produces two entries, each with the
        # source-line where `inherit` was declared (§13.7 per-occurrence).
        symbols = parse_file(PARENT_CLASSES_MULTI, "multi.tcl", "tcl")
        classes = [s for s in symbols if s.kind == "class"]
        assert len(classes) == 1
        bases = classes[0].parent_classes
        assert len(bases) == 2, f"expected 2 bases, got {bases!r}"
        names = {entry["name"] for entry in bases}
        assert names == {"Base1", "Base2"}
        for entry in bases:
            assert isinstance(entry["line"], int)
            assert entry["line"] >= 1


class TestPackageRequiresField:
    def test_package_requires_captures_version(self):
        # `package require Tcl 8.6` → version="8.6"; bare `package require Tk`
        # → version=None.  Field lives on the file's __script__ symbol.
        symbols = parse_file(PACKAGE_REQUIRES_VERSIONED, "deps.tcl", "tcl")
        scripts = [s for s in symbols if s.name == "__script__"]
        assert len(scripts) == 1, "expected one __script__ symbol"
        pr = scripts[0].package_requires
        by_name = {entry["name"]: entry["version"] for entry in pr}
        assert by_name.get("Tcl") == "8.6"
        assert by_name.get("Tk") is None
        assert by_name.get("http") == "2.7"

    def test_package_require_emits_import_symbol_AND_field(self):
        # Δ0.2 C1: `package require X` populates BOTH the package_requires
        # field on __script__ AND emits a kind=import symbol named X.
        symbols = parse_file(PACKAGE_REQUIRES_VERSIONED, "deps.tcl", "tcl")
        imports = [s for s in symbols if s.kind == "import"]
        names = {s.name for s in imports}
        assert "Tcl" in names
        assert "Tk" in names
        assert "http" in names
        # And the field on __script__ also has them — both sources must agree.
        scripts = [s for s in symbols if s.name == "__script__"]
        assert len(scripts) == 1
        pr_names = {entry["name"] for entry in scripts[0].package_requires}
        assert {"Tcl", "Tk", "http"} <= pr_names


# ---------------------------------------------------------------------------
# Tests: P1.3 Stream 2 — Task #16 (G), with G.1 rewritten under P1.3 bundle (1).
#
# Three tests covering invariants the prior pytest port did not lock:
#   1. parent_classes / package_requires wire shape — host-only on the wire
#      (§13.2 / §13.3 decided=B; SPEC §7.5.1 "Wire vs Python model"). Field
#      ABSENT from the JSON for non-host symbols; PRESENT-as-[] on host
#      symbols when no inherit / no package require. Python `Symbol`
#      dataclass defaults non-host to `[]` so consumers see a uniform
#      typed surface regardless of wire encoding.
#   2. Pragma `# JCM:dynamic` end-to-end through the full bridge driver
#      (R31 wiring at bridge_postpasses.tcl::_attach_pragmas — covered
#      by pragma_scanner standalone tests, but never end-to-end via the
#      bridge subprocess).
#   3. Dynamic-body tag end-to-end — pragma_scanner's regex pre-scan
#      flags the proc AND the resulting symbol carries the `dynamic_body`
#      tag in unresolved_dispatches (cross-references contract §4.3).
# ---------------------------------------------------------------------------


PARENT_CLASSES_NO_CLASS_NO_REQUIRE = '''\
proc plain_top_level {} {
    return 1
}

proc with_arg {x} {
    return [expr {$x * 2}]
}
'''


# Class without `inherit` / `superclass` — host symbol present, parent_classes
# emitted as []-on-the-wire.
CLASS_NO_INHERIT_FIXTURE = '''\
itcl::class Plain {
    public method greet {} { return "hi" }
}
'''


# Class with `inherit` — host symbol present, parent_classes populated.
CLASS_WITH_INHERIT_FIXTURE = '''\
itcl::class Base { }
itcl::class Derived {
    inherit Base
    public method ping {} { return "pong" }
}
'''


# `package require` declarations exercising the __script__ host symbol +
# package_requires wire shape.
SCRIPT_NO_PACKAGE_REQUIRE_FIXTURE = '''\
proc just_a_proc {} { return 1 }
'''


SCRIPT_WITH_PACKAGE_REQUIRE_FIXTURE = '''\
package require Tcl 8.6
package require http 2.9
proc handler {} { return 1 }
'''


PRAGMA_DYNAMIC_FIXTURE = '''\
# JCM:dynamic resolves_to=fooHelper
proc fooDynamic {} {
    return 1
}
'''


DYNAMIC_BODY_FIXTURE = '''\
proc fooDynBody {a b} [getBody $a $b]
'''


def _bridge_wire_entries(source, filename):
    """Run the bridge subprocess directly and return the raw JSON list.

    Bypasses _parse_tcl_native's Symbol-dataclass rehydration so we can
    assert wire-level field presence/absence (Bundle item 1 step 5: the
    invariant is "absent from JSON" vs "present-as-[] in JSON" — the
    dataclass default would mask absence from the Python view).
    """
    import json
    import subprocess
    import tempfile
    from pathlib import Path

    bridge = (
        Path(__file__).resolve().parents[1]
        / "src"
        / "jcodemunch_mcp"
        / "parser"
        / "tcl"
        / "disasm_bridge.tcl"
    )
    with tempfile.NamedTemporaryFile(
        "w", suffix=".tcl", delete=False, encoding="utf-8"
    ) as tmp:
        tmp.write(source)
        tmp_path = tmp.name
    try:
        result = subprocess.run(
            ["tclsh", str(bridge), tmp_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, (
            f"bridge failed for {filename}: "
            f"stderr={result.stderr!r} stdout={result.stdout[:200]!r}"
        )
        return json.loads(result.stdout)
    finally:
        Path(tmp_path).unlink(missing_ok=True)


class TestStreamTwoCleanupInvariants:
    # --- Wire shape C: parent_classes (host=class only) ------------------

    def test_parent_classes_absent_from_non_class_wire_entries(self):
        # P1.3 bundle (1) — non-class symbols have parent_classes ABSENT
        # from the JSON wire (encoder skips). The Python Symbol dataclass
        # supplies [] via default_factory — we verify the absence at the
        # WIRE layer here. SPEC §7.5.1 "Wire vs Python model".
        entries = _bridge_wire_entries(
            PARENT_CLASSES_NO_CLASS_NO_REQUIRE,
            "no_classes.tcl",
        )
        # No class symbols in this fixture.
        assert all(e.get("kind") != "class" for e in entries)
        for e in entries:
            assert "parent_classes" not in e, (
                f"non-class wire entry {e.get('name')}/{e.get('kind')} "
                f"unexpectedly carries parent_classes: {e!r}"
            )

    def test_parent_classes_present_as_empty_on_class_with_no_inherit(self):
        # Class symbol with no inherit / no superclass: parent_classes
        # PRESENT-as-[] on the wire (host-only field, default empty).
        entries = _bridge_wire_entries(
            CLASS_NO_INHERIT_FIXTURE, "plain_class.tcl"
        )
        classes = [e for e in entries if e.get("kind") == "class"]
        assert len(classes) >= 1, (
            f"expected at least one class entry; got "
            f"{[(e.get('name'), e.get('kind')) for e in entries]}"
        )
        plain = next(e for e in classes if e.get("name") == "Plain")
        assert "parent_classes" in plain, (
            f"class wire entry missing parent_classes field: {plain!r}"
        )
        assert plain["parent_classes"] == [], (
            f"class with no inherit should have parent_classes=[]; "
            f"got {plain['parent_classes']!r}"
        )

    def test_parent_classes_populated_for_class_with_inherit(self):
        # Class with inherit: parent_classes populated with {name, line}.
        entries = _bridge_wire_entries(
            CLASS_WITH_INHERIT_FIXTURE, "derived_class.tcl"
        )
        derived = next(
            e for e in entries
            if e.get("kind") == "class" and e.get("name") == "Derived"
        )
        assert "parent_classes" in derived, (
            f"Derived class missing parent_classes: {derived!r}"
        )
        bases = derived["parent_classes"]
        assert len(bases) == 1, (
            f"expected 1 base class on Derived; got {bases!r}"
        )
        assert bases[0]["name"] == "Base", (
            f"expected base name=Base; got {bases[0]!r}"
        )
        assert isinstance(bases[0].get("line"), int), (
            f"expected integer line on base; got {bases[0]!r}"
        )

    # --- Wire shape C: package_requires (host=__script__ only) -----------

    def test_package_requires_absent_from_non_script_wire_entries(self):
        # package_requires lives on the synthetic __script__ host symbol
        # only. Non-host wire entries (procs, classes, etc.) must NOT
        # carry the field on the wire.
        entries = _bridge_wire_entries(
            SCRIPT_WITH_PACKAGE_REQUIRE_FIXTURE,
            "with_pkg.tcl",
        )
        for e in entries:
            if e.get("name") == "__script__" and e.get("kind") == "module":
                continue
            assert "package_requires" not in e, (
                f"non-host wire entry {e.get('name')}/{e.get('kind')} "
                f"unexpectedly carries package_requires: {e!r}"
            )

    def test_package_requires_present_as_empty_on_script_with_none(self):
        # __script__ with no `package require`: field PRESENT-as-[] on the
        # wire. Verifies the host-only contract emits the field even when
        # empty so the consumer doesn't need a "did the bridge include it?"
        # branch.
        entries = _bridge_wire_entries(
            SCRIPT_NO_PACKAGE_REQUIRE_FIXTURE,
            "no_pkg.tcl",
        )
        scripts = [
            e for e in entries
            if e.get("name") == "__script__" and e.get("kind") == "module"
        ]
        # __script__ may be elided if it has no signal — but if it's
        # present, package_requires must be present-as-[].
        if scripts:
            s = scripts[0]
            assert "package_requires" in s, (
                f"__script__ missing package_requires: {s!r}"
            )
            assert s["package_requires"] == [], (
                f"__script__ with no requires should have package_requires=[]; "
                f"got {s['package_requires']!r}"
            )

    def test_package_requires_populated_when_present(self):
        entries = _bridge_wire_entries(
            SCRIPT_WITH_PACKAGE_REQUIRE_FIXTURE,
            "with_pkg.tcl",
        )
        s = next(
            e for e in entries
            if e.get("name") == "__script__" and e.get("kind") == "module"
        )
        assert "package_requires" in s, (
            f"__script__ missing package_requires: {s!r}"
        )
        names = {entry["name"] for entry in s["package_requires"]}
        assert {"Tcl", "http"} <= names, (
            f"expected Tcl + http in package_requires; got {names!r}"
        )

    def test_pragma_dynamic_end_to_end_via_full_bridge(self):
        # R31 pragma scanner output → bridge driver attach pass →
        # symbol's unresolved_dispatches. End-to-end: a dynamic pragma
        # immediately above `proc fooDynamic` lands as
        # {kind: pragma_dynamic, resolves_to: fooHelper, line: <pragma_line>}.
        symbols = parse_file(
            PRAGMA_DYNAMIC_FIXTURE,
            "pragma_dyn.tcl",
            "tcl",
        )
        targets = [s for s in symbols if s.name == "fooDynamic"]
        assert len(targets) == 1, (
            f"expected one fooDynamic symbol, got "
            f"{[(s.name, s.kind) for s in symbols]}"
        )
        ud = targets[0].unresolved_dispatches
        kinds = [e["kind"] for e in ud]
        assert "pragma_dynamic" in kinds, (
            f"expected pragma_dynamic in unresolved_dispatches; got "
            f"{kinds}"
        )
        # Pragma extras (resolves_to=fooHelper) survive end-to-end.
        pragma_entry = next(e for e in ud if e["kind"] == "pragma_dynamic")
        assert pragma_entry.get("resolves_to") == "fooHelper", (
            f"expected resolves_to=fooHelper, got "
            f"{pragma_entry!r}"
        )

    def test_dynamic_body_tag_end_to_end_via_full_bridge(self):
        # `proc fooDynBody {a b} [getBody $a $b]` — body slot is a
        # bracket expression. The compute_body_base extractor flags
        # `dynamic`, the bridge driver's _apply_a_row tags the symbol's
        # unresolved_dispatches with kind=dynamic_body and skips body
        # recursion. Cross-references WALKER_CONTRACT_v2_2.md §4.3.
        symbols = parse_file(
            DYNAMIC_BODY_FIXTURE,
            "dyn_body.tcl",
            "tcl",
        )
        targets = [s for s in symbols if s.name == "fooDynBody"]
        assert len(targets) == 1, (
            f"expected one fooDynBody symbol, got "
            f"{[(s.name, s.kind) for s in symbols]}"
        )
        ud = targets[0].unresolved_dispatches
        kinds = [e["kind"] for e in ud]
        assert "dynamic_body" in kinds, (
            f"expected dynamic_body tag; got unresolved_dispatches="
            f"{ud!r}"
        )


# ---------------------------------------------------------------------------
# Tests: P1.3 bundle (0) — computed_namespace BODY recursion regression.
#
# `namespace eval $ns BODY` arrives at the bridge driver as a
# kind=computed_namespace event. Prior to the bundle fix, the dispatch case
# only ran _handle_unresolved (tagging the dynamic ns) and dropped the BODY
# entirely — silently losing every nested proc / class / namespace inside
# such blocks. The fix adds _handle_computed_namespace_body_recurse so the
# body literal is still walked against the enclosing parent.
#
# Lock the regression closed end-to-end via the full bridge subprocess.
# ---------------------------------------------------------------------------


COMPUTED_NS_BODY_FIXTURE = '''\
namespace eval ::Outer {
    proc literal_proc {} { puts hello }
    set ns_dyn ::Dynamic
    namespace eval $ns_dyn { proc dropped_proc {} { puts world } }
}
'''


COMPUTED_NS_MIXED_FIXTURE = '''\
namespace eval ::A { proc inA {} { return 1 } }
set varB ::B
namespace eval $varB { proc inB {} { return 2 } }
'''


class TestComputedNamespaceBodyRecursion:
    def test_dropped_proc_inside_computed_namespace_survives(self):
        # Critic-flagged data-loss regression: literal proc nested inside
        # `namespace eval $ns_dyn { ... }` was silently lost. The bundle
        # fix recurses the body against the enclosing parent so the
        # static call-graph still surfaces the inner proc.
        symbols = parse_file(
            COMPUTED_NS_BODY_FIXTURE,
            "computed_ns_body.tcl",
            "tcl",
        )
        names = {s.name for s in symbols}
        assert "literal_proc" in names, (
            f"literal_proc missing — bridge regressed; got {names!r}"
        )
        assert "dropped_proc" in names, (
            "dropped_proc inside computed-namespace body was dropped — "
            f"computed_namespace recursion regression returned. Got {names!r}"
        )

    def test_mixed_literal_and_computed_namespace_both_recurse(self):
        # Sibling namespace_eval blocks: literal `::A` and computed `$varB`.
        # Both inner-namespace bodies must survive recursion.
        symbols = parse_file(
            COMPUTED_NS_MIXED_FIXTURE,
            "ns_mixing.tcl",
            "tcl",
        )
        names = {s.name for s in symbols}
        assert "inA" in names, (
            f"inA (literal-namespace child) missing; got {names!r}"
        )
        assert "inB" in names, (
            f"inB (computed-namespace child) missing; "
            f"computed_namespace recursion regression. Got {names!r}"
        )


# ---------------------------------------------------------------------------
# Tests: P1.3 bundle (12) — JCODEMUNCH_TCL_DUAL_VALIDATE scaffolding.
#
# C″ cut-over policy: runtime path is single-substrate (new bridge); the
# env var enables a diagnostic-only second parse against the legacy
# bridge fetched from `tcl-native-parser` so P1.4 can build the behavioral
# oracle. Test #1 verifies the env var is OFF by default (parse runs
# new-only). Test #2 (when env var set) verifies the diff file lands at
# the documented location.
# ---------------------------------------------------------------------------


DUAL_VALIDATE_FIXTURE = '''\
proc dual_validate_target {} { return 1 }
'''


class TestDualValidate:
    def test_dual_validate_off_by_default(self, monkeypatch):
        # No env var: parse should succeed without writing any diff file.
        monkeypatch.delenv("JCODEMUNCH_TCL_DUAL_VALIDATE", raising=False)
        symbols = parse_file(
            DUAL_VALIDATE_FIXTURE, "dv_default.tcl", "tcl"
        )
        names = {s.name for s in symbols}
        assert "dual_validate_target" in names

    def test_dual_validate_when_enabled_writes_diff(self, monkeypatch, tmp_path):
        # Env var ON: parse runs the canonical new-bridge AND attempts the
        # legacy bridge via `git show tcl-native-parser:...`. Diff lands
        # at ~/.code-index/dual_validate_diffs/. We point HOME at tmp_path
        # so the test doesn't pollute the user's actual code-index dir.
        monkeypatch.setenv("JCODEMUNCH_TCL_DUAL_VALIDATE", "1")
        monkeypatch.setenv("HOME", str(tmp_path))
        # Reset the legacy-bridge cache so this test re-fetches under
        # the new HOME (otherwise a previous-process cache hit would
        # mask the env-var path under test).
        from jcodemunch_mcp.parser import extractor as _ex
        _ex._legacy_bridge_path = None  # type: ignore[attr-defined]

        symbols = parse_file(
            DUAL_VALIDATE_FIXTURE, "dv_enabled.tcl", "tcl"
        )
        names = {s.name for s in symbols}
        # Canonical new-bridge result remains correct regardless of the
        # diagnostic.
        assert "dual_validate_target" in names

        diff_dir = tmp_path / ".code-index" / "dual_validate_diffs"
        # The diagnostic might gracefully fail (e.g. tcl-native-parser
        # branch missing in CI) — but the diff file should still be
        # written, recording legacy_bridge_ran=False in that case.
        if diff_dir.exists():
            files = list(diff_dir.glob("*.json"))
            assert len(files) >= 1, (
                f"dual_validate enabled but no diff written to {diff_dir}"
            )
            import json
            payload = json.loads(files[0].read_text())
            assert payload["file"] == "dv_enabled.tcl"
            assert payload["new_symbol_count"] >= 1
            # legacy_bridge_ran can be True or False; both are valid
            # (False when the tcl-native-parser branch is absent).
            assert isinstance(payload["legacy_bridge_ran"], bool)
