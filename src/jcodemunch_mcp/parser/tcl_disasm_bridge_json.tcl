#!/usr/bin/env tclsh
#
# tcl_disasm_bridge_json.tcl — extracted from tcl_disasm_bridge.tcl in P1.3
# Stream 2 (Task #16 (E)).
#
# Owns the JSON encoding of the bridge's symbol list:
#
#   ::jcm::bridge::json::*    — pure-Tcl JSON primitives (escape, scalar,
#                               list, object). No tcllib dependency.
#   emit_json                 — top-level array emitter consumed by bridge_main.
#   _symbol_to_json           — render one symbol dict.
#   _unresolved_entry_to_json — render one unresolved_dispatches entry.
#   _class_entry_to_json      — render one parent_classes entry.
#   _pkg_entry_to_json        — render one package_requires entry.
#
# Sourcing order: must come AFTER tcl_disasm_bridge.tcl declares the
# ::jcm::bridge state vars (variable symbols / etc.), since the procs read
# them via `variable`. Sourced from the bridge driver itself.

namespace eval ::jcm::bridge {}

# ---------------------------------------------------------------------------
# JSON encoding helpers — pure Tcl, no external deps.
# ---------------------------------------------------------------------------
#
# WHY pure Tcl: the bridge runs inside arbitrary tclsh installations (system
# 8.6, ActiveTcl, vendor builds). Pulling tcllib's `json` package would add
# a runtime dependency the existing P1.0 bridge avoided. Same posture here.
#
# Numbers, "null", and pre-encoded JSON values pass through json_raw.

namespace eval ::jcm::bridge::json {
    namespace export escape string_v int_v null_v list_v object_v raw_v string_list
}

proc ::jcm::bridge::json::escape {s} {
    return [string map [list \
        \\  \\\\  \
        \"  \\\"  \
        \n  \\n   \
        \r  \\r   \
        \t  \\t   \
        \x08 \\b  \
        \x0c \\f  \
    ] $s]
}

proc ::jcm::bridge::json::string_v {s} {
    return "\"[escape $s]\""
}

proc ::jcm::bridge::json::int_v {n} {
    if {$n eq "" || ![string is integer -strict $n]} { return 0 }
    return $n
}

proc ::jcm::bridge::json::null_v {} { return "null" }

proc ::jcm::bridge::json::raw_v {v} { return $v }

proc ::jcm::bridge::json::list_v {items} {
    return "\[[join $items ", "]\]"
}

proc ::jcm::bridge::json::string_list {items} {
    set out [list]
    foreach it $items {
        lappend out [string_v $it]
    }
    return [list_v $out]
}

# Build a JSON object from a flat key,value-as-already-JSON list.
# Caller is responsible for pre-encoding values via string_v / int_v / list_v / etc.
proc ::jcm::bridge::json::object_v {pairs} {
    set parts [list]
    foreach {k v} $pairs {
        lappend parts "[string_v $k]: $v"
    }
    return "\{[join $parts ", "]\}"
}

# ---------------------------------------------------------------------------
# JSON emission — serialize the symbol list to a single JSON array string.
# ---------------------------------------------------------------------------

proc ::jcm::bridge::emit_json {} {
    variable symbols
    set rows [list]
    foreach sym $symbols {
        lappend rows [_symbol_to_json $sym]
    }
    return [::jcm::bridge::json::list_v $rows]
}

proc ::jcm::bridge::_symbol_to_json {sym} {
    set name [dict get $sym name]
    set qname [dict get $sym qualified_name]
    set kind [dict get $sym kind]
    set sig [dict get $sym signature]
    set doc [dict get $sym docstring]
    set line [dict get $sym line]
    set end_line [dict get $sym end_line]
    set boff [dict get $sym byte_offset]
    set blen [dict get $sym byte_length]
    set parent [dict get $sym parent]
    set cyclo [dict get $sym cyclomatic]
    set nest  [dict get $sym max_nesting]
    set pcount [dict get $sym param_count]
    set calls [dict get $sym call_references]
    set udisp [dict get $sym unresolved_dispatches]
    set decorators [dict get $sym decorators]
    set keywords [dict get $sym keywords]
    set parent_classes [dict get $sym parent_classes]
    set package_requires [dict get $sym package_requires]

    set udisp_json [list]
    foreach e $udisp { lappend udisp_json [_unresolved_entry_to_json $e] }
    set parent_json [list]
    foreach e $parent_classes { lappend parent_json [_class_entry_to_json $e] }
    set pr_json [list]
    foreach e $package_requires { lappend pr_json [_pkg_entry_to_json $e] }

    set pairs [list \
        name             [::jcm::bridge::json::string_v $name] \
        qualified_name   [::jcm::bridge::json::string_v $qname] \
        kind             [::jcm::bridge::json::string_v $kind] \
        signature        [::jcm::bridge::json::string_v $sig] \
        docstring        [::jcm::bridge::json::string_v $doc] \
        line             [::jcm::bridge::json::int_v $line] \
        end_line         [::jcm::bridge::json::int_v $end_line] \
        byte_offset      [::jcm::bridge::json::int_v $boff] \
        byte_length      [::jcm::bridge::json::int_v $blen] \
        parent           [::jcm::bridge::json::string_v $parent] \
        cyclomatic       [::jcm::bridge::json::int_v $cyclo] \
        max_nesting      [::jcm::bridge::json::int_v $nest] \
        param_count      [::jcm::bridge::json::int_v $pcount] \
        call_references  [::jcm::bridge::json::string_list $calls] \
        unresolved_dispatches [::jcm::bridge::json::list_v $udisp_json] \
        decorators       [::jcm::bridge::json::string_list $decorators] \
        keywords         [::jcm::bridge::json::string_list $keywords]]

    # P1.3 bundle (1) — Wire shape C: emit parent_classes / package_requires
    # ONLY on host symbols. The Python `Symbol` dataclass keeps
    # default_factory=list so consumers see [] for non-host kinds without
    # a kind check; absence on the wire is encoder-internal (SPEC §7.5.1
    # "Wire vs Python model"). Bundle decision: parent_classes lives on
    # class symbols; package_requires lives on the synthetic __script__
    # module symbol (kind=module, name=__script__).
    if {$kind eq "class"} {
        lappend pairs parent_classes [::jcm::bridge::json::list_v $parent_json]
    }
    if {$kind eq "module" && $name eq "__script__"} {
        lappend pairs package_requires [::jcm::bridge::json::list_v $pr_json]
    }

    return [::jcm::bridge::json::object_v $pairs]
}

proc ::jcm::bridge::_unresolved_entry_to_json {entry} {
    set kind [dict get $entry kind]
    set line 0
    if {[dict exists $entry line]} { set line [dict get $entry line] }
    set file ""
    if {[dict exists $entry file]} { set file [dict get $entry file] }
    set snippet ""
    if {[dict exists $entry snippet]} { set snippet [dict get $entry snippet] }
    set pairs [list \
        kind    [::jcm::bridge::json::string_v $kind] \
        line    [::jcm::bridge::json::int_v $line] \
        file    [::jcm::bridge::json::string_v $file]]
    if {$snippet ne ""} {
        lappend pairs snippet [::jcm::bridge::json::string_v $snippet]
    }
    # Pass through any other keys (e.g. resolves_to from pragma_dynamic).
    foreach {k v} $entry {
        if {$k in {kind line file snippet}} continue
        lappend pairs $k [::jcm::bridge::json::string_v $v]
    }
    return [::jcm::bridge::json::object_v $pairs]
}

proc ::jcm::bridge::_class_entry_to_json {entry} {
    set name [dict get $entry name]
    set line 0
    if {[dict exists $entry line]} { set line [dict get $entry line] }
    return [::jcm::bridge::json::object_v [list \
        name [::jcm::bridge::json::string_v $name] \
        line [::jcm::bridge::json::int_v $line]]]
}

proc ::jcm::bridge::_pkg_entry_to_json {entry} {
    set name [dict get $entry name]
    set version_v [::jcm::bridge::json::null_v]
    if {[dict exists $entry version]} {
        set ver [dict get $entry version]
        if {$ver ne "" && $ver ne "null"} {
            set version_v [::jcm::bridge::json::string_v $ver]
        }
    }
    return [::jcm::bridge::json::object_v [list \
        name    [::jcm::bridge::json::string_v $name] \
        version [::jcm::bridge::json::raw_v $version_v]]]
}
