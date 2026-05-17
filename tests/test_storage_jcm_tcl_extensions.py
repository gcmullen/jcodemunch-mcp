"""Round-trip + cross-direction guard tests for the jcm_tcl_extensions side-table.

Covers the architect P1.3-close findings:

- CRITICAL #1: parent_classes / package_requires were never persisted by save_index;
  this test suite locks the storage round-trip.
- CRITICAL #2: jcm_tcl_extensions must be (re-)created via per-call CREATE TABLE
  IF NOT EXISTS, not via the _initialized_dbs schema cache. We simulate an
  external DROP TABLE between save_index calls and assert the next save still
  succeeds.
- CRITICAL #3: cross-direction load (Strict-A, P1.3 close) — any DB without
  an exact-match jcm_tcl_writer_version stamp is refused entirely (load_index
  returns None with a clear WARNING). This covers: no stamp at all (upstream-
  built), stamp > constant (newer fork), stamp < constant (older fork).
  Legacy indexes loaded via JSON migration or the v4→v9 schema ladder are
  stamped automatically at migration time; they satisfy the gate without a
  manual re-index. Original permissive behaviour (silent degrade) retired per
  "failures rather than fallbacks" directive.
- MAJOR #4: incremental_save must emit explicit DELETE on jcm_tcl_extensions
  when files are removed (no PRAGMA foreign_keys = no FK CASCADE).
- MAJOR #5: branch-delta intentionally drops fork-extension data — locked here
  so the deferred-to-v2.0 behaviour cannot silently regress.
- MAJOR #7: this is the round-trip test that did not exist; absence of which
  masked CRITICAL #1.
"""

from __future__ import annotations

import sqlite3
import tempfile
from pathlib import Path

import pytest

from jcodemunch_mcp.parser.symbols import Symbol
from jcodemunch_mcp.storage.index_store import IndexStore
from jcodemunch_mcp.storage.sqlite_store import (
    JCM_TCL_INDEX_VERSION,
    SQLiteIndexStore,
)


# ──────────────────────────────────────────────────────────────────────────────
# Test fixtures
# ──────────────────────────────────────────────────────────────────────────────

def _make_class_symbol(
    file: str = "src/foo.tcl",
    name: str = "Derived",
    parent_classes: list[dict] | None = None,
) -> Symbol:
    return Symbol(
        id=f"{file}::{name}#class",
        file=file,
        name=name,
        qualified_name=name,
        kind="class",
        language="tcl",
        signature=f"class {name}",
        parent_classes=parent_classes or [{"name": "Base", "line": 3}],
    )


def _make_script_symbol(
    file: str = "src/foo.tcl",
    package_requires: list[dict] | None = None,
) -> Symbol:
    return Symbol(
        id=f"{file}::__script__#function",
        file=file,
        name="__script__",
        qualified_name="__script__",
        kind="function",
        language="tcl",
        signature="(file-level script)",
        package_requires=package_requires
        or [{"name": "Tk", "version": "8.6"}, {"name": "Itcl", "version": None}],
    )


def _make_other_symbol(file: str = "src/foo.tcl") -> Symbol:
    """Non-class, non-script symbol — must NOT get a row in jcm_tcl_extensions."""
    return Symbol(
        id=f"{file}::helper#function",
        file=file,
        name="helper",
        qualified_name="helper",
        kind="function",
        language="tcl",
        signature="proc helper {} {}",
    )


def _save_repo(tmp_path: Path, symbols: list[Symbol], file: str = "src/foo.tcl") -> IndexStore:
    """Save an index containing `symbols` for one synthetic Tcl file."""
    store = IndexStore(base_path=str(tmp_path))
    raw_files = {file: "# placeholder Tcl content\n"}
    store.save_index(
        owner="local",
        name="testrepo",
        source_files=[file],
        symbols=symbols,
        raw_files=raw_files,
        languages={"tcl": 1},
        file_languages={file: "tcl"},
        source_root=str(tmp_path),
    )
    return store


# ──────────────────────────────────────────────────────────────────────────────
# Test 1: round-trip regression
# ──────────────────────────────────────────────────────────────────────────────

class TestRoundTrip:
    """save_index → load_index must preserve parent_classes / package_requires.

    This is the test that did not exist (architect MAJOR #7); its absence
    masked architect CRITICAL #1.
    """

    def test_parent_classes_round_trips_through_save_and_load(self, tmp_path):
        bases = [{"name": "Base", "line": 3}, {"name": "Mixin", "line": 4}]
        sym = _make_class_symbol(parent_classes=bases)
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None, "save_index produced no loadable index"
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == bases, (
            f"expected parent_classes={bases!r}, got "
            f"{loaded_sym.get('parent_classes')!r} — fork-extension side-table "
            f"is not wired through the load path"
        )

    def test_package_requires_round_trips_through_save_and_load(self, tmp_path):
        pkgs = [{"name": "Tk", "version": "8.6"}, {"name": "Itcl", "version": None}]
        sym = _make_script_symbol(package_requires=pkgs)
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("package_requires") == pkgs, (
            f"expected package_requires={pkgs!r}, got "
            f"{loaded_sym.get('package_requires')!r} — fork-extension side-table "
            f"is not wired through the load path"
        )

    def test_non_class_non_script_symbols_default_to_empty_lists(self, tmp_path):
        """Symbols without fork-extension data load with empty defaults."""
        sym = _make_other_symbol()
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes", []) == []
        assert loaded_sym.get("package_requires", []) == []


# ──────────────────────────────────────────────────────────────────────────────
# Test 2: _initialized_dbs cache safety (architect CRITICAL #2)
# ──────────────────────────────────────────────────────────────────────────────

class TestExtensionTableRecreatedAfterDrop:
    """jcm_tcl_extensions must be created via per-call CREATE TABLE IF NOT EXISTS.

    The _initialized_dbs cache short-circuits _SCHEMA_SQL on subsequent
    connects.  If the side-table init lived in _SCHEMA_SQL, dropping the
    table out-of-band would NOT be repaired on the next save_index — the
    cache would skip schema init entirely.

    By following the embedding_store.py pattern (per-call CREATE TABLE IF
    NOT EXISTS at write time) the side-table is robust to external drops.
    """

    def test_extension_table_recreated_after_external_drop(self, tmp_path):
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        # Externally drop the side-table to simulate corruption / partial mount
        # / out-of-band schema mutation.
        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            conn.execute("DROP TABLE IF EXISTS jcm_tcl_extensions")
            conn.commit()

        # Save again — the side-table should be re-created.
        store.save_index(
            owner="local",
            name="testrepo",
            source_files=["src/foo.tcl"],
            symbols=[sym],
            raw_files={"src/foo.tcl": "# placeholder Tcl content\n"},
            languages={"tcl": 1},
            file_languages={"src/foo.tcl": "tcl"},
            source_root=str(tmp_path),
        )

        with sqlite3.connect(str(db_path)) as conn:
            cur = conn.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='jcm_tcl_extensions'"
            )
            assert cur.fetchone() is not None, (
                "jcm_tcl_extensions was not re-created after external DROP — "
                "side-table init is using the _initialized_dbs cache (architect "
                "CRITICAL #2)"
            )

        # Round-trip after drop must still work.
        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == [{"name": "Base", "line": 3}]


# ──────────────────────────────────────────────────────────────────────────────
# Test 3: cascade on file delete (architect MAJOR #4)
# ──────────────────────────────────────────────────────────────────────────────

class TestExtensionRowsDeletedOnSymbolRemoval:
    """incremental_save must explicitly DELETE side-table rows for removed files.

    PRAGMA foreign_keys is NOT set anywhere in this codebase, so FK CASCADE
    will not fire automatically. The deletion must be explicit.
    """

    def test_extension_rows_deleted_on_file_removal(self, tmp_path):
        sym = _make_class_symbol(file="src/foo.tcl")
        store = _save_repo(tmp_path, [sym])

        # Verify a row was written.
        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM jcm_tcl_extensions WHERE symbol_id = ?",
                (sym.id,),
            ).fetchone()
            assert row[0] == 1, "expected one side-table row before delete"

        # Now remove the file via incremental_save.
        store.incremental_save(
            owner="local",
            name="testrepo",
            changed_files=[],
            new_files=[],
            deleted_files=["src/foo.tcl"],
            new_symbols=[],
            raw_files={},
        )

        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM jcm_tcl_extensions WHERE symbol_id = ?",
                (sym.id,),
            ).fetchone()
            assert row[0] == 0, (
                f"expected 0 side-table rows after deleted_files=['src/foo.tcl'], "
                f"got {row[0]} — incremental_save is missing the explicit "
                f"DELETE FROM jcm_tcl_extensions (architect MAJOR #4)"
            )


# ──────────────────────────────────────────────────────────────────────────────
# Test 4: strict load gate on jcm_tcl_writer_version (P1.3-close, Strict-A)
# ──────────────────────────────────────────────────────────────────────────────

class TestStrictLoadGate:
    """load_index must refuse any DB without an exact-match fork stamp.

    Per the P1.3-close "failures rather than fallbacks" directive:
    indexes that lack jcm_tcl_writer_version, or whose stamp does not
    match JCM_TCL_INDEX_VERSION exactly (either direction), are refused
    at load time with a clear WARNING.  Caller (index_folder, watch
    loop) re-indexes on None — that is the existing graceful-failure
    behaviour, no new caller code needed.

    This replaces the original permissive Test 4 (silent degrade on
    newer writer version) and Test 5 (load-succeeds-when-no-extension-
    table-present); both locked behaviour that has been retired.
    """

    def test_load_refuses_when_no_jcm_tcl_writer_version_stamp(
        self, tmp_path, caplog
    ):
        """No stamp (upstream-built or pre-side-table fork) → return None.

        The brief: "Indexes built without the fork-extension stamp are
        refused at load time and force a re-index."
        """
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        # Strip the meta stamp to simulate an upstream-built or pre-side-
        # table fork DB.  Side-table existence is irrelevant — the gate is
        # the meta stamp.
        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            conn.execute(
                "DELETE FROM meta WHERE key = 'jcm_tcl_writer_version'"
            )
            conn.commit()

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        import logging
        with caplog.at_level(logging.WARNING):
            loaded = store.load_index("local", "testrepo")

        assert loaded is None, (
            "load_index must refuse a DB with no jcm_tcl_writer_version "
            "stamp (Strict-A: fail rather than fall back)"
        )
        warning_msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
        assert any("jcm_tcl_writer_version" in m for m in warning_msgs), (
            f"expected a warning naming jcm_tcl_writer_version; got {warning_msgs!r}"
        )

    def test_load_refuses_when_jcm_tcl_writer_version_too_new(
        self, tmp_path, caplog
    ):
        """Stamp > our constant → return None (newer fork wrote this DB)."""
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                ("jcm_tcl_writer_version", str(JCM_TCL_INDEX_VERSION + 1)),
            )
            conn.commit()

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        import logging
        with caplog.at_level(logging.WARNING):
            loaded = store.load_index("local", "testrepo")

        assert loaded is None, (
            "load_index must refuse a DB whose jcm_tcl_writer_version is "
            "newer than this build's JCM_TCL_INDEX_VERSION"
        )
        warning_msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
        assert any("jcm_tcl_writer_version" in m for m in warning_msgs), (
            f"expected a warning naming jcm_tcl_writer_version; got {warning_msgs!r}"
        )

    def test_load_refuses_when_jcm_tcl_writer_version_too_old(
        self, tmp_path, caplog
    ):
        """Stamp < our constant → return None (older fork wrote this DB)."""
        if JCM_TCL_INDEX_VERSION <= 1:
            pytest.skip(
                f"JCM_TCL_INDEX_VERSION={JCM_TCL_INDEX_VERSION}; cannot "
                f"forge a strictly-older stamp without going negative.  "
                f"Re-enable this case after the next JCM_TCL_INDEX_VERSION "
                f"bump."
            )
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                ("jcm_tcl_writer_version", str(JCM_TCL_INDEX_VERSION - 1)),
            )
            conn.commit()

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        import logging
        with caplog.at_level(logging.WARNING):
            loaded = store.load_index("local", "testrepo")

        assert loaded is None, (
            "load_index must refuse a DB whose jcm_tcl_writer_version is "
            "older than this build's JCM_TCL_INDEX_VERSION (schema may "
            "have changed; rebuild rather than risk silent stale reads)"
        )
        warning_msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
        assert any("jcm_tcl_writer_version" in m for m in warning_msgs), (
            f"expected a warning naming jcm_tcl_writer_version; got {warning_msgs!r}"
        )

    def test_load_succeeds_when_stamp_matches(self, tmp_path):
        """Happy path: stamp == JCM_TCL_INDEX_VERSION → populated CodeIndex.

        Round-trip locks that side-table data is read from the DB and
        attached to the loaded symbol.
        """
        bases = [{"name": "Base", "line": 3}]
        sym = _make_class_symbol(parent_classes=bases)
        store = _save_repo(tmp_path, [sym])

        # save_index stamps jcm_tcl_writer_version automatically — no
        # forging needed.  Verify by reading meta back directly first.
        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT value FROM meta WHERE key = 'jcm_tcl_writer_version'"
            ).fetchone()
            assert row is not None, (
                "save_index did not stamp jcm_tcl_writer_version into meta"
            )
            assert int(row[0]) == JCM_TCL_INDEX_VERSION

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None, (
            "happy-path load with matching jcm_tcl_writer_version must "
            "succeed"
        )
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == bases


# ──────────────────────────────────────────────────────────────────────────────
# Test 5: branch-delta intentionally drops fork-extension data (deferred to v2.0)
# ──────────────────────────────────────────────────────────────────────────────

class TestBranchDeltaDoesNotCarryForkExtensionData:
    """Branch-delta wire format intentionally omits parent_classes / package_requires.

    Per user-locked decision #3: branch-delta wiring is deferred to v2.0.
    This test locks the deferred behaviour so it can't silently regress.
    """

    def test_branch_delta_does_not_carry_fork_extension_data(self, tmp_path):
        # Build a base index.
        base_sym = _make_class_symbol(
            name="Base", parent_classes=[{"name": "AbstractRoot", "line": 1}],
        )
        store = _save_repo(tmp_path, [base_sym])

        # Save a branch delta that adds a new derived class on a feature branch.
        branch_sym = _make_class_symbol(
            file="src/branch.tcl",
            name="Derived",
            parent_classes=[{"name": "Base", "line": 5}],
        )
        store.save_branch_delta(
            owner="local",
            name="testrepo",
            branch="feature/x",
            changed_files=[],
            new_files=["src/branch.tcl"],
            deleted_files=[],
            new_symbols=[branch_sym],
            raw_files={"src/branch.tcl": "# branch content\n"},
            git_head="deadbeef",
            base_head="cafebabe",
            file_hashes={"src/branch.tcl": "abc123"},
            file_mtimes={"src/branch.tcl": 1_700_000_000_000_000_000},
            file_languages={"src/branch.tcl": "tcl"},
        )

        # Compose the branch-aware index and verify the branch symbol's
        # parent_classes is empty (delta path drops it; deferred to v2.0).
        loaded = store.load_index("local", "testrepo", branch="feature/x")
        assert loaded is not None
        composed = loaded.get_symbol(branch_sym.id)
        assert composed is not None, "composed branch index must include the new symbol"
        # Locks the DEFERRED behaviour: branch-delta-derived symbols carry no
        # parent_classes today.
        assert composed.get("parent_classes", []) == [], (
            "branch-delta wire format unexpectedly preserved parent_classes — "
            "if this is intentional, update the deferral docs and unlock the "
            "wiring on save_branch_delta + compose_branch_index together."
        )


# ──────────────────────────────────────────────────────────────────────────────
# Test 6: 5.0 — JCM_TCL_INDEX_VERSION bump path coverage
# ──────────────────────────────────────────────────────────────────────────────

class TestVersionBumpPath:
    """Lock the JCM_TCL_INDEX_VERSION bump path (originally P5.0; refactored
    in P5.1 to be relative to the current constant so the suite survives
    every future bump without churn).

    These tests monkeypatch the module-level constant to simulate the
    NEXT bump. They prove:

    1. A current-stamped DB is refused once the constant is bumped one
       higher (forced reindex).
    2. A DB freshly written under the bumped constant stamps the new
       version and loads.
    3. The strict-load gate applies to ALL fork-built indexes, not just
       TCL-bearing ones — locks the contract corrected in
       PHASE5_BRIDGE_ENRICHMENT_SPIKE.md §4. Bumping JCM_TCL_INDEX_VERSION
       forces a reindex of every repo the fork has indexed.
    """

    def test_current_stamped_db_refused_after_simulated_bump(
        self, tmp_path, monkeypatch, caplog
    ):
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='jcm_tcl_writer_version'"
            ).fetchone()
            assert row is not None and int(row[0]) == JCM_TCL_INDEX_VERSION, (
                "precondition: save_index must stamp the current constant "
                "before the simulated bump"
            )

        monkeypatch.setattr(
            "jcodemunch_mcp.storage.sqlite_store.JCM_TCL_INDEX_VERSION",
            JCM_TCL_INDEX_VERSION + 1,
        )
        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        import logging
        with caplog.at_level(logging.WARNING):
            loaded = store.load_index("local", "testrepo")

        assert loaded is None, (
            "after bumping JCM_TCL_INDEX_VERSION by one, a current-stamped DB "
            "must be refused (forces fresh reindex)"
        )
        msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
        assert any("jcm_tcl_writer_version" in m for m in msgs), (
            f"expected a warning naming jcm_tcl_writer_version; got {msgs!r}"
        )

    def test_freshly_written_db_under_bumped_constant_loads(
        self, tmp_path, monkeypatch
    ):
        """Post-bump save_index stamps the bumped version and round-trips cleanly."""
        target_version = JCM_TCL_INDEX_VERSION + 1
        monkeypatch.setattr(
            "jcodemunch_mcp.storage.sqlite_store.JCM_TCL_INDEX_VERSION",
            target_version,
        )
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='jcm_tcl_writer_version'"
            ).fetchone()
            assert row is not None and int(row[0]) == target_version, (
                f"save_index under bumped constant must stamp v{target_version}"
            )

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None, (
            "happy path: stamp == bumped constant must load successfully"
        )
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == [{"name": "Base", "line": 3}]

    def test_non_tcl_index_also_refused_after_bump(
        self, tmp_path, monkeypatch, caplog
    ):
        """The Strict-A gate refuses ALL fork-built DBs whose stamp doesn't
        match — not just TCL-bearing ones.

        Documents/locks the actual contract; PHASE5_BRIDGE_ENRICHMENT_SPIKE.md
        §4's "non-TCL indexes are untouched" claim is inaccurate. Every
        save_index path stamps jcm_tcl_writer_version, so bumping the
        constant forces reindex of every fork-built repo regardless of
        language.
        """
        py_sym = Symbol(
            id="src/foo.py::main#function",
            file="src/foo.py",
            name="main",
            qualified_name="main",
            kind="function",
            language="python",
            signature="def main():",
        )
        store = IndexStore(base_path=str(tmp_path))
        store.save_index(
            owner="local",
            name="pyrepo",
            source_files=["src/foo.py"],
            symbols=[py_sym],
            raw_files={"src/foo.py": "def main(): pass\n"},
            languages={"python": 1},
            file_languages={"src/foo.py": "python"},
            source_root=str(tmp_path),
        )

        monkeypatch.setattr(
            "jcodemunch_mcp.storage.sqlite_store.JCM_TCL_INDEX_VERSION",
            JCM_TCL_INDEX_VERSION + 1,
        )
        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()

        import logging
        with caplog.at_level(logging.WARNING):
            loaded = store.load_index("local", "pyrepo")

        assert loaded is None, (
            "non-TCL DB refused after bump: Strict-A gate is language-agnostic. "
            "If this assertion ever fails, the gate's scope was tightened to "
            "TCL-only — update PHASE5_BRIDGE_ENRICHMENT_SPIKE.md §4 to match."
        )
        msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
        assert any("jcm_tcl_writer_version" in m for m in msgs), (
            f"expected a warning naming jcm_tcl_writer_version; got {msgs!r}"
        )


# ──────────────────────────────────────────────────────────────────────────────
# Test 7: P5.1 — callees + args round-trip
# ──────────────────────────────────────────────────────────────────────────────

class TestCalleesAndArgsRoundTrip:
    """save_index → load_index must preserve Symbol.callees + Symbol.args.

    Both fields are TCL-only on the wire (additive Symbol fields with []
    defaults) and serialize through the jcm_tcl_extensions side-table as
    callees_json / args_json typed columns.
    """

    def test_callees_round_trips_through_save_and_load(self, tmp_path):
        callees = [
            {"name": "addListener", "line": 12, "kind": "method_dispatch",
             "receiver_hint": "$clock", "note": "$clock addListener"},
            {"name": "msgcat::mc", "line": 18, "kind": "qualified",
             "receiver_hint": None, "note": None},
            {"name": "pack", "line": 22, "kind": "method_dispatch",
             "receiver_hint": "$w", "note": "$w pack"},
        ]
        sym = Symbol(
            id="src/foo.tcl::proc1#function",
            file="src/foo.tcl",
            name="proc1",
            qualified_name="proc1",
            kind="function",
            language="tcl",
            signature="proc proc1 {} {}",
            callees=callees,
        )
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None, "save_index produced no loadable index"
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("callees") == callees, (
            f"expected callees={callees!r}, got {loaded_sym.get('callees')!r} — "
            f"side-table callees_json is not wired through the load path"
        )

    def test_args_round_trips_through_save_and_load(self, tmp_path):
        args = ["self", "name", "value", "options"]
        sym = Symbol(
            id="src/foo.tcl::configure#method",
            file="src/foo.tcl",
            name="configure",
            qualified_name="Widget::configure",
            kind="method",
            language="tcl",
            signature="method configure {self name value options} {}",
            args=args,
        )
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("args") == args, (
            f"expected args={args!r}, got {loaded_sym.get('args')!r} — "
            f"side-table args_json is not wired through the load path"
        )

    def test_callees_and_args_together_with_existing_extension_fields(self, tmp_path):
        """Symbol carrying ALL four fork-extension fields round-trips correctly."""
        sym = Symbol(
            id="src/foo.tcl::Widget#class",
            file="src/foo.tcl",
            name="Widget",
            qualified_name="Widget",
            kind="class",
            language="tcl",
            signature="itcl::class Widget",
            parent_classes=[{"name": "Base", "line": 1}],
            package_requires=[{"name": "Tk", "version": "8.6"}],
            callees=[{"name": "init", "line": 5, "kind": "static",
                      "receiver_hint": None, "note": None}],
            args=["self"],
        )
        store = _save_repo(tmp_path, [sym])

        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == [{"name": "Base", "line": 1}]
        assert loaded_sym.get("package_requires") == [{"name": "Tk", "version": "8.6"}]
        assert loaded_sym.get("callees") == [
            {"name": "init", "line": 5, "kind": "static",
             "receiver_hint": None, "note": None}
        ]
        assert loaded_sym.get("args") == ["self"]

    def test_symbol_with_no_callees_or_args_skips_side_table_row(self, tmp_path):
        """Sparse-row invariant: a symbol with no fork-extension data must
        not allocate a side-table row (regression on _jcm_tcl_extension_row's
        all-empty short-circuit)."""
        sym = Symbol(
            id="src/foo.tcl::plain#function",
            file="src/foo.tcl",
            name="plain",
            qualified_name="plain",
            kind="function",
            language="tcl",
            signature="proc plain {} {}",
        )
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM jcm_tcl_extensions WHERE symbol_id = ?",
                (sym.id,),
            ).fetchone()
            assert row[0] == 0, (
                "symbol with no fork-extension data should NOT have a "
                "jcm_tcl_extensions row (sparse-row invariant)"
            )

        # And load-side defaults are still correct.
        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("callees", []) == []
        assert loaded_sym.get("args", []) == []


# ──────────────────────────────────────────────────────────────────────────────
# Test 8: P5.1 — v1-era index backward-compat (R1 from spike §7.6)
# ──────────────────────────────────────────────────────────────────────────────

class TestV1IndexBackwardCompat:
    """v1-era indexes promoted by the ALTER TABLE migration must load
    with empty callees/args, not crash.

    Per PHASE5_BRIDGE_ENRICHMENT_SPIKE.md §7.6 R1: "Old indexes with
    jcm_tcl_writer_version = 1 must load cleanly under the new dataclass
    + side-table schema. Dataclass field defaults (callees=[], args=[])
    handle in-memory access; the side-table SELECT path needs explicit
    NULL handling for callees_json / args_json when reading v1-era rows."

    Under Strict-A, a v1-stamped DB is refused entirely. After reindex
    (or after an explicit migration) the stamp is current. The R1 contract
    here is that rows promoted by ALTER TABLE (with NULL callees_json /
    args_json) decode as empty lists on the load path.
    """

    def test_null_callees_and_args_columns_load_as_empty_lists(self, tmp_path):
        """A side-table row with explicit NULL callees_json / args_json
        loads with empty lists."""
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        # save_index just stamped the current constant + populated parent_classes;
        # callees_json / args_json are NULL on that row.
        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")
        with sqlite3.connect(str(db_path)) as conn:
            row = conn.execute(
                "SELECT callees_json, args_json FROM jcm_tcl_extensions "
                "WHERE symbol_id = ?",
                (sym.id,),
            ).fetchone()
            assert row is not None
            assert row[0] is None, "precondition: callees_json should be NULL"
            assert row[1] is None, "precondition: args_json should be NULL"

        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()
        loaded = store.load_index("local", "testrepo")
        assert loaded is not None
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        # NULL side-table columns must decode as [] (R1 contract).
        assert loaded_sym.get("callees", []) == []
        assert loaded_sym.get("args", []) == []

    def test_alter_table_migrates_v1_schema_to_v2(self, tmp_path):
        """Manually downgrade a v2 side-table to v1 (4 cols), invoke
        _initialize_jcm_tcl_extensions, and assert the missing columns
        are restored."""
        # First create a fresh DB so we have a clean v2 side-table.
        sym = _make_class_symbol(parent_classes=[{"name": "Base", "line": 3}])
        store = _save_repo(tmp_path, [sym])

        sqlite_store = SQLiteIndexStore(base_path=str(tmp_path))
        db_path = sqlite_store._db_path("local", "testrepo")

        # Manually downgrade the schema: drop and recreate with the v1
        # 4-column shape, preserving rows.
        with sqlite3.connect(str(db_path)) as conn:
            conn.execute(
                "CREATE TABLE jcm_tcl_extensions_v1_clone "
                "(symbol_id TEXT PRIMARY KEY, parent_classes TEXT, "
                "package_requires TEXT, extras_json TEXT)"
            )
            conn.execute(
                "INSERT INTO jcm_tcl_extensions_v1_clone "
                "(symbol_id, parent_classes, package_requires, extras_json) "
                "SELECT symbol_id, parent_classes, package_requires, extras_json "
                "FROM jcm_tcl_extensions"
            )
            conn.execute("DROP TABLE jcm_tcl_extensions")
            conn.execute(
                "ALTER TABLE jcm_tcl_extensions_v1_clone RENAME TO jcm_tcl_extensions"
            )
            cols_before = {
                r[1] for r in conn.execute(
                    "PRAGMA table_info(jcm_tcl_extensions)"
                ).fetchall()
            }
            assert "callees_json" not in cols_before
            assert "args_json" not in cols_before

            from jcodemunch_mcp.storage.sqlite_store import (
                _initialize_jcm_tcl_extensions,
            )
            _initialize_jcm_tcl_extensions(conn)

            cols_after = {
                r[1] for r in conn.execute(
                    "PRAGMA table_info(jcm_tcl_extensions)"
                ).fetchall()
            }
            assert "callees_json" in cols_after, (
                "_initialize_jcm_tcl_extensions must ALTER TABLE to add "
                "callees_json on v1-era tables (R1 migration contract)"
            )
            assert "args_json" in cols_after
            conn.commit()

        # After migration, the existing row's parent_classes is preserved
        # and callees/args decode as []
        from jcodemunch_mcp.storage.sqlite_store import _cache_clear
        _cache_clear()
        loaded = store.load_index("local", "testrepo")
        assert loaded is not None, (
            "after ALTER TABLE migration a current-stamped DB must still load"
        )
        loaded_sym = loaded.get_symbol(sym.id)
        assert loaded_sym is not None
        assert loaded_sym.get("parent_classes") == [{"name": "Base", "line": 3}]
        assert loaded_sym.get("callees", []) == []
        assert loaded_sym.get("args", []) == []
