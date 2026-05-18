"""Tests for Phase 5.2a.2 generic DSL walker.

Validates that the rewritten dsl_annotations.tcl + dsl_walker.tcl files load
cleanly into the bridge and that the new fully-populated ANNOTATIONS table
produces stable output. The 5.2a.0 snapshot (commit 582fbec baseline with
empty ANNOTATIONS) is kept as historical record; the active byte-equality
test now uses the 5_2a_full snapshot captured after the generic engine rewrite.
"""

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
DSL_ANNOTATIONS = (
    REPO_ROOT / "src" / "jcodemunch_mcp" / "parser" / "tcl" / "dsl_annotations.tcl"
)
CANARY = REPO_ROOT / "tests" / "fixtures" / "tcl" / "canary.tcl"
SNAPSHOT = REPO_ROOT / "tests" / "fixtures" / "tcl" / "canary_bridge_output_5_2a_full.json"


def test_skeleton_files_load():
    """Bridge sources dsl_annotations.tcl + dsl_walker.tcl without error."""
    result = subprocess.run(
        ["tclsh", str(BRIDGE), str(CANARY)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"bridge failed: stderr={result.stderr!r} "
        f"stdout={result.stdout[:200]!r}"
    )
    assert result.stderr == "", f"unexpected stderr: {result.stderr!r}"
    # Output must be valid JSON.
    parsed = json.loads(result.stdout)
    assert isinstance(parsed, list) and len(parsed) > 0


def test_canary_snapshot_5_2a_full():
    """Bridge output is byte-equal vs the 5_2a_full snapshot.

    Captured after the generic engine rewrite (Phase 5.2a.2) with the full
    25-row ANNOTATIONS table and 6-grammar BODY_GRAMMARS active.
    """
    result = subprocess.run(
        ["tclsh", str(BRIDGE), str(CANARY)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0
    expected = SNAPSHOT.read_text(encoding="utf-8")
    assert result.stdout == expected, (
        "Bridge output changed vs 5_2a_full snapshot. "
        "If intentional, re-capture with: "
        "tclsh disasm_bridge.tcl canary.tcl > canary_bridge_output_5_2a_full.json"
    )


def test_dsl_lookup_basic():
    """::jcm::dsl::lookup returns a row for snit::type and empty for unknown."""
    script = f"""
source [list {DSL_ANNOTATIONS}]
set r [::jcm::dsl::lookup {{snit::type}} {{}}]
if {{[llength $r] > 0}} {{ puts FOUND }} else {{ puts NOTFOUND }}
set r2 [::jcm::dsl::lookup {{no_such_dsl}} {{}}]
if {{[llength $r2] == 0}} {{ puts EMPTY }} else {{ puts NONEMPTY }}
"""
    result = subprocess.run(
        ["tclsh"],
        input=script,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"tclsh failed: {result.stderr!r}"
    lines = result.stdout.strip().splitlines()
    assert lines == ["FOUND", "EMPTY"], (
        f"unexpected output: stdout={result.stdout!r} stderr={result.stderr!r}"
    )
