"""Tests for §5.4.2 P3.1 DSL-implementation-file rule (Phase 5.2a.4)."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("tclsh") is None,
    reason="tclsh not found on PATH",
)

REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE = REPO_ROOT / "src" / "jcodemunch_mcp" / "parser" / "tcl" / "disasm_bridge.tcl"
IMPL_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "tcl" / "dsl_impl_file.tcl"
USE_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "tcl" / "dsl_use_file.tcl"


def _run_bridge(fixture_path):
    result = subprocess.run(
        ["tclsh", str(BRIDGE), str(fixture_path)],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, f"bridge failed: {result.stderr!r}"
    return json.loads(result.stdout)


def test_dsl_impl_file_suppresses_inner_class():
    """The `class FooBar { ... }` literal inside `proc class`'s body must
    NOT produce a class symbol or a method child symbol — per convention
    §5.4.2 P3.1, those are data the impl proc consumes."""
    symbols = _run_bridge(IMPL_FIXTURE)
    names_kinds = {(s["name"], s["kind"]) for s in symbols if s["kind"] != "module"}
    # The impl proc itself MUST be emitted.
    assert ("class", "function") in names_kinds, (
        f"expected (class, function) impl proc, got {names_kinds}"
    )
    # The data literal MUST NOT produce a class or method symbol.
    assert ("FooBar", "class") not in names_kinds, (
        f"FooBar leaked as class symbol from DSL-impl body: {names_kinds}"
    )
    assert ("m", "method") not in names_kinds, (
        f"m leaked as method symbol from DSL-impl body: {names_kinds}"
    )


def test_dsl_use_file_emits_class_and_method():
    """A USE file's top-level `class FooBar { ... }` MUST emit both the
    class symbol and its method children — the §5.4.2 suppression only
    applies INSIDE a DSL-impl proc body, not at file scope."""
    symbols = _run_bridge(USE_FIXTURE)
    names_kinds = {(s["name"], s["kind"]) for s in symbols if s["kind"] != "module"}
    assert ("FooBar", "class") in names_kinds, (
        f"USE-file class symbol missing: {names_kinds}"
    )
    assert ("m", "method") in names_kinds, (
        f"USE-file method symbol missing: {names_kinds}"
    )
