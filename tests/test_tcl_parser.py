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

class TestFallback:
    def test_fallback_still_extracts_symbols(self):
        """Even the tree-sitter fallback should find basic procs."""
        from jcodemunch_mcp.parser.extractor import _parse_tcl_symbols
        source = BASIC_PROCS.encode("utf-8")
        symbols = _parse_tcl_symbols(source, "basic.tcl")
        names = {s.name for s in symbols}
        assert "greet" in names
        assert "add" in names


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
        assert "itk_initialize" in ctor.call_references

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
