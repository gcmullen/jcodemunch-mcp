"""Tests for Phase 5.2a.0 DSL walker skeleton.

Validates that the new dsl_annotations.tcl + dsl_walker.tcl files load
cleanly into the bridge and that the empty ANNOTATIONS table is a
true no-op vs the HEAD snapshot (commit 582fbec). 5.2a.1+ tests will
exercise the actual annotation rows.
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
SNAPSHOT = REPO_ROOT / "tests" / "fixtures" / "tcl" / "canary_bridge_output_5_2a_0.json"


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


def test_empty_annotations_is_noop_byte_equal():
    """Empty ANNOTATIONS table => bridge output bit-identical vs HEAD snapshot.

    The snapshot was captured at commit 582fbec (Phase 5.2 close) by running
    `tclsh disasm_bridge.tcl tests/fixtures/tcl/canary.tcl`. With the 5.2a.0
    DSL pre-pass wired in but ANNOTATIONS empty, the pre-pass must return 0
    on every command and the output must match the pre-skeleton bytes
    exactly.
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
        "5.2a.0 pre-pass perturbed bridge output vs HEAD snapshot. "
        "The DSL walker must be a no-op with empty ANNOTATIONS."
    )


def test_dsl_lookup_empty_table_returns_empty():
    """::jcm::dsl::lookup returns {} when ANNOTATIONS is empty (5.2a.0)."""
    script = f"""
source [list {DSL_ANNOTATIONS}]
set r [::jcm::dsl::lookup foo bar]
if {{[llength $r] == 0}} {{ puts EMPTY }} else {{ puts NONEMPTY }}
"""
    result = subprocess.run(
        ["tclsh"],
        input=script,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"tclsh failed: {result.stderr!r}"
    assert result.stdout.strip() == "EMPTY", (
        f"expected EMPTY, got stdout={result.stdout!r} stderr={result.stderr!r}"
    )
