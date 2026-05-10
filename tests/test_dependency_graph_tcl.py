"""Tests for Tcl `package require` edges in get_dependency_graph.

P1.3 wire-up: Tcl `package require X` is a package-name lookup, not a file
path. Stream 1's spot-check showed 25/25 Tcl files returning {nodes:1,
edges:0} from get_dependency_graph because resolve_specifier could never
map a package name to a source file. This module locks the additive Tcl
edge path that emits virtual ``package:NAME`` nodes from the indexed
``__script__`` symbol's ``package_requires`` field, plus the cross-repo
file-to-package resolution against other indexed repos' ``package_names``.

Cross-language base behavior (Python / JS / Java file-to-file edges via
``index.imports``) is intentionally unchanged — these tests also assert
that base behavior to guard against regressions.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from jcodemunch_mcp.parser.symbols import Symbol
from jcodemunch_mcp.storage.index_store import IndexStore
from jcodemunch_mcp.tools.get_dependency_graph import (
    _collect_tcl_package_edges,
    _file_tcl_package_requires,
    get_dependency_graph,
)
from jcodemunch_mcp.tools.package_registry import invalidate_registry_cache


# ──────────────────────────────────────────────────────────────────────────────
# Unit tests for the new helpers (no DB / no indexer)
# ──────────────────────────────────────────────────────────────────────────────

class TestCollectTclPackageEdges:
    """_collect_tcl_package_edges should emit virtual edges only for Tcl scripts."""

    def test_returns_empty_for_no_symbols(self):
        assert _collect_tcl_package_edges([]) == {}

    def test_returns_empty_for_non_tcl_symbols(self):
        # Python __script__-style symbol must NOT produce package: edges.
        symbols = [
            {
                "file": "main.py",
                "name": "__script__",
                "language": "python",
                "package_requires": [{"name": "Tk", "version": None}],
            }
        ]
        assert _collect_tcl_package_edges(symbols) == {}

    def test_returns_empty_for_non_script_tcl_symbols(self):
        # Tcl class/function symbols must NOT produce package: edges
        # (only __script__ carries package_requires per the schema).
        symbols = [
            {
                "file": "foo.tcl",
                "name": "MyClass",
                "language": "tcl",
                "package_requires": [{"name": "Tk", "version": None}],
            }
        ]
        assert _collect_tcl_package_edges(symbols) == {}

    def test_emits_virtual_package_node_for_tcl_script(self):
        symbols = [
            {
                "file": "foo.tcl",
                "name": "__script__",
                "language": "tcl",
                "package_requires": [
                    {"name": "Tk", "version": "8.6"},
                    {"name": "Itcl", "version": None},
                ],
            }
        ]
        adj = _collect_tcl_package_edges(symbols)
        assert adj == {"foo.tcl": ["package:Tk", "package:Itcl"]}

    def test_dedupes_repeated_packages(self):
        symbols = [
            {
                "file": "foo.tcl",
                "name": "__script__",
                "language": "tcl",
                "package_requires": [
                    {"name": "Tk", "version": None},
                    {"name": "Tk", "version": "8.6"},
                ],
            }
        ]
        adj = _collect_tcl_package_edges(symbols)
        assert adj == {"foo.tcl": ["package:Tk"]}

    def test_handles_multiple_files(self):
        symbols = [
            {
                "file": "a.tcl", "name": "__script__", "language": "tcl",
                "package_requires": [{"name": "Tk"}],
            },
            {
                "file": "b.tcl", "name": "__script__", "language": "tcl",
                "package_requires": [{"name": "Itcl"}],
            },
        ]
        adj = _collect_tcl_package_edges(symbols)
        assert adj == {"a.tcl": ["package:Tk"], "b.tcl": ["package:Itcl"]}

    def test_skips_entries_without_name(self):
        symbols = [
            {
                "file": "foo.tcl",
                "name": "__script__",
                "language": "tcl",
                "package_requires": [{"version": "1.0"}, {"name": "Tk"}],
            }
        ]
        adj = _collect_tcl_package_edges(symbols)
        assert adj == {"foo.tcl": ["package:Tk"]}


class TestFileTclPackageRequires:
    """_file_tcl_package_requires returns the per-file Tcl package list."""

    def test_returns_empty_for_unknown_file(self):
        symbols = [
            {
                "file": "a.tcl", "name": "__script__", "language": "tcl",
                "package_requires": [{"name": "Tk"}],
            }
        ]
        assert _file_tcl_package_requires(symbols, "b.tcl") == []

    def test_returns_packages_for_matching_file(self):
        symbols = [
            {
                "file": "a.tcl", "name": "__script__", "language": "tcl",
                "package_requires": [
                    {"name": "Tk", "version": "8.6"},
                    {"name": "Itcl"},
                ],
            }
        ]
        assert _file_tcl_package_requires(symbols, "a.tcl") == ["Tk", "Itcl"]

    def test_ignores_non_tcl_symbols_for_same_file(self):
        symbols = [
            {
                "file": "a.tcl", "name": "__script__", "language": "python",
                "package_requires": [{"name": "Tk"}],
            }
        ]
        assert _file_tcl_package_requires(symbols, "a.tcl") == []


# ──────────────────────────────────────────────────────────────────────────────
# Integration: end-to-end via IndexStore (round-trips package_requires)
# ──────────────────────────────────────────────────────────────────────────────

def _make_tcl_script_symbol(
    file: str,
    package_requires: list[dict],
) -> Symbol:
    return Symbol(
        id=f"{file}::__script__#function",
        file=file,
        name="__script__",
        qualified_name="__script__",
        kind="function",
        language="tcl",
        signature="(file-level script)",
        package_requires=package_requires,
    )


def _save_tcl_repo(
    tmp_path: Path,
    *,
    owner: str = "local",
    name: str = "tclrepo",
    files_with_pkgs: dict[str, list[dict]],
    package_names: list[str] | None = None,
) -> tuple[IndexStore, str]:
    """Save a synthetic Tcl repo with __script__ symbols carrying package_requires."""
    store = IndexStore(base_path=str(tmp_path))
    symbols = [
        _make_tcl_script_symbol(file, pkgs) for file, pkgs in files_with_pkgs.items()
    ]
    raw_files = {f: "# placeholder Tcl content\n" for f in files_with_pkgs}
    store.save_index(
        owner=owner,
        name=name,
        source_files=list(files_with_pkgs.keys()),
        symbols=symbols,
        raw_files=raw_files,
        languages={"tcl": len(files_with_pkgs)},
        file_languages={f: "tcl" for f in files_with_pkgs},
        source_root=str(tmp_path),
        package_names=package_names or [],
    )
    return store, f"{owner}/{name}"


class TestGetDependencyGraphTclSameRepo:
    """Tcl `package require` edges show up in same-repo dependency_graph results."""

    def test_tcl_file_with_package_requires_emits_virtual_edges(self, tmp_path):
        store_path = tmp_path / "store"
        store_path.mkdir()
        _save_tcl_repo(
            store_path,
            files_with_pkgs={
                "Admin.tcl": [
                    {"name": "Tk", "version": "8.6"},
                    {"name": "Itcl", "version": None},
                ],
            },
        )

        result = get_dependency_graph(
            repo="local/tclrepo",
            file="Admin.tcl",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )

        assert "error" not in result, result
        assert result["node_count"] >= 3, (
            f"expected >=3 nodes (Admin.tcl + 2 packages), got {result['node_count']}: {result['nodes']}"
        )
        assert "package:Tk" in result["nodes"]
        assert "package:Itcl" in result["nodes"]
        # Edge shape: [from, to]
        edges_set = {tuple(e) for e in result["edges"]}
        assert ("Admin.tcl", "package:Tk") in edges_set
        assert ("Admin.tcl", "package:Itcl") in edges_set

    def test_tcl_file_without_package_requires_returns_singleton(self, tmp_path):
        """Empty package_requires should produce the legacy {1, 0} shape."""
        store_path = tmp_path / "store"
        store_path.mkdir()
        _save_tcl_repo(
            store_path,
            files_with_pkgs={"Admin.tcl": []},
        )

        result = get_dependency_graph(
            repo="local/tclrepo",
            file="Admin.tcl",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "error" not in result, result
        assert result["node_count"] == 1
        assert result["edge_count"] == 0


class TestGetDependencyGraphCrossLanguageUnchanged:
    """Non-Tcl base behavior (Python file-to-file edges) must NOT regress."""

    def test_python_imports_still_resolve_to_files(self, tmp_path):
        store_path = tmp_path / "store"
        store_path.mkdir()

        store = IndexStore(base_path=str(store_path))
        py_sym_a = Symbol(
            id="a.py::a#function",
            file="a.py",
            name="a",
            qualified_name="a",
            kind="function",
            language="python",
            signature="def a(): ...",
        )
        py_sym_b = Symbol(
            id="b.py::b#function",
            file="b.py",
            name="b",
            qualified_name="b",
            kind="function",
            language="python",
            signature="def b(): ...",
        )
        # a.py imports b.py via `import b` — the indexer extracts this.
        # We synthesize the imports map directly to keep the test hermetic.
        store.save_index(
            owner="local",
            name="pyrepo",
            source_files=["a.py", "b.py"],
            symbols=[py_sym_a, py_sym_b],
            raw_files={"a.py": "import b\n", "b.py": "def b(): pass\n"},
            languages={"python": 2},
            file_languages={"a.py": "python", "b.py": "python"},
            source_root=str(store_path),
            imports={"a.py": [{"specifier": "b", "names": []}]},
        )

        result = get_dependency_graph(
            repo="local/pyrepo",
            file="a.py",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "error" not in result, result
        assert "b.py" in result["nodes"], result
        edges_set = {tuple(e) for e in result["edges"]}
        assert ("a.py", "b.py") in edges_set
        # No virtual package: nodes should appear for non-Tcl files
        assert not any(n.startswith("package:") for n in result["nodes"]), result["nodes"]

    def test_java_imports_unchanged_no_package_prefix_nodes(self, tmp_path):
        """Java import edges (java.util.List → unresolved) should not pull in `package:` nodes."""
        store_path = tmp_path / "store"
        store_path.mkdir()
        store = IndexStore(base_path=str(store_path))
        sym = Symbol(
            id="App.java::App#class",
            file="App.java",
            name="App",
            qualified_name="App",
            kind="class",
            language="java",
            signature="class App",
        )
        store.save_index(
            owner="local",
            name="javarepo",
            source_files=["App.java"],
            symbols=[sym],
            raw_files={"App.java": "import java.util.List;\nclass App {}\n"},
            languages={"java": 1},
            file_languages={"App.java": "java"},
            source_root=str(store_path),
            imports={"App.java": [{"specifier": "java.util.List", "names": ["List"]}]},
        )

        result = get_dependency_graph(
            repo="local/javarepo",
            file="App.java",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "error" not in result, result
        # java.util.List is not a file in the index → unresolved → no edge
        # Crucially: no `package:` virtual node should appear for Java.
        assert not any(n.startswith("package:") for n in result["nodes"]), result["nodes"]


class TestGetDependencyGraphTclMixedLanguageRepo:
    """Tcl edges and Python edges coexist in a mixed-language repo."""

    def test_mixed_repo_emits_both_edge_types(self, tmp_path):
        store_path = tmp_path / "store"
        store_path.mkdir()
        store = IndexStore(base_path=str(store_path))

        tcl_sym = _make_tcl_script_symbol(
            "Admin.tcl", [{"name": "Tk", "version": "8.6"}]
        )
        py_sym = Symbol(
            id="a.py::a#function",
            file="a.py",
            name="a",
            qualified_name="a",
            kind="function",
            language="python",
            signature="def a(): ...",
        )
        py_sym_b = Symbol(
            id="b.py::b#function",
            file="b.py",
            name="b",
            qualified_name="b",
            kind="function",
            language="python",
            signature="def b(): ...",
        )

        store.save_index(
            owner="local",
            name="mixed",
            source_files=["Admin.tcl", "a.py", "b.py"],
            symbols=[tcl_sym, py_sym, py_sym_b],
            raw_files={
                "Admin.tcl": "package require Tk\n",
                "a.py": "import b\n",
                "b.py": "def b(): pass\n",
            },
            languages={"tcl": 1, "python": 2},
            file_languages={"Admin.tcl": "tcl", "a.py": "python", "b.py": "python"},
            source_root=str(store_path),
            imports={"a.py": [{"specifier": "b", "names": []}]},
        )

        # Tcl side: virtual package node
        tcl_result = get_dependency_graph(
            repo="local/mixed",
            file="Admin.tcl",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "package:Tk" in tcl_result["nodes"], tcl_result

        # Python side: file-to-file edge, no `package:` nodes
        py_result = get_dependency_graph(
            repo="local/mixed",
            file="a.py",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "b.py" in py_result["nodes"], py_result
        assert not any(n.startswith("package:") for n in py_result["nodes"]), py_result["nodes"]


class TestGetDependencyGraphTclCrossRepo:
    """When cross_repo=True, Tcl `package require X` resolves against package_names of other repos."""

    def test_cross_repo_tcl_edge_emitted_when_provider_publishes_package(self, tmp_path):
        store_path = tmp_path / "store"
        store_path.mkdir()

        # Provider repo declares package "Tk" via package_names
        _save_tcl_repo(
            store_path,
            owner="local",
            name="provider",
            files_with_pkgs={"Tk_pkg.tcl": []},
            package_names=["Tk"],
        )
        # Consumer repo has Admin.tcl that requires Tk
        _save_tcl_repo(
            store_path,
            owner="local",
            name="consumer",
            files_with_pkgs={"Admin.tcl": [{"name": "Tk", "version": "8.6"}]},
        )
        invalidate_registry_cache()

        result = get_dependency_graph(
            repo="local/consumer",
            file="Admin.tcl",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=True,
        )

        assert "error" not in result, result
        # Same-repo virtual edge must still appear (additive path)
        assert "package:Tk" in result["nodes"], result["nodes"]
        # Cross-repo edge must list the provider repo
        cross_edges = result.get("cross_repo_edges", [])
        matching = [
            e for e in cross_edges
            if e.get("package_name") == "Tk" and e.get("to_repo") == "local/provider"
        ]
        assert matching, f"expected a Tk cross_repo edge to local/provider, got {cross_edges}"
        edge = matching[0]
        assert edge["from"] == "Admin.tcl"
        assert edge["from_repo"] == "local/consumer"
        assert edge["cross_repo"] is True

    def test_cross_repo_false_omits_cross_repo_edges(self, tmp_path):
        store_path = tmp_path / "store"
        store_path.mkdir()
        _save_tcl_repo(
            store_path,
            owner="local",
            name="provider",
            files_with_pkgs={"Tk_pkg.tcl": []},
            package_names=["Tk"],
        )
        _save_tcl_repo(
            store_path,
            owner="local",
            name="consumer",
            files_with_pkgs={"Admin.tcl": [{"name": "Tk", "version": "8.6"}]},
        )
        invalidate_registry_cache()

        result = get_dependency_graph(
            repo="local/consumer",
            file="Admin.tcl",
            direction="imports",
            depth=1,
            storage_path=str(store_path),
            cross_repo=False,
        )
        assert "cross_repo_edges" not in result
        # Same-repo virtual edge is still emitted regardless of cross_repo
        assert "package:Tk" in result["nodes"]
