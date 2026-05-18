"""Unit tests for tools/_tcl_callees.py — TCL per-call-site enrichment."""
import pytest
from jcodemunch_mcp.tools._tcl_callees import (
    enrich_callees_from_references,
    enrich_find_direct_callees,
    enrich_rename_plan,
)


# ---------------------------------------------------------------------------
# enrich_callees_from_references / enrich_find_direct_callees
# ---------------------------------------------------------------------------

class TestEnrichCalleesFromReferences:

    def test_empty_callees_returns_result_unchanged(self):
        result = [{"id": "a::foo", "name": "foo", "kind": "proc", "resolution": "ast_resolved"}]
        sym = {"name": "bar", "callees": []}
        out = enrich_callees_from_references(result, sym)
        assert out == result
        # identity: no copy was made for empty callees
        assert out is result

    def test_missing_callees_key_returns_result_unchanged(self):
        result = [{"id": "a::foo", "name": "foo", "resolution": "ast_resolved"}]
        sym = {"name": "bar"}
        out = enrich_callees_from_references(result, sym)
        assert out is result

    def test_populated_callees_adds_tcl_call_sites(self):
        result = [{"id": "a::foo", "name": "foo", "kind": "proc", "resolution": "ast_resolved"}]
        sym = {
            "name": "bar",
            "callees": [
                {"name": "foo", "line": 5, "kind": "static", "receiver_hint": None, "note": None},
            ],
        }
        out = enrich_callees_from_references(result, sym)
        assert len(out) == 1
        assert "tcl_call_sites" in out[0]
        assert out[0]["tcl_call_sites"] == [
            {"line": 5, "kind": "static", "receiver_hint": None, "note": None}
        ]

    def test_non_matching_name_leaves_entry_unchanged(self):
        result = [{"id": "a::baz", "name": "baz", "resolution": "ast_inferred"}]
        sym = {
            "name": "bar",
            "callees": [
                {"name": "foo", "line": 3, "kind": "static", "receiver_hint": None, "note": None},
            ],
        }
        out = enrich_callees_from_references(result, sym)
        assert "tcl_call_sites" not in out[0]

    def test_multiple_call_sites_for_same_name_all_aggregated(self):
        result = [{"id": "a::foo", "name": "foo", "resolution": "ast_resolved"}]
        sym = {
            "name": "bar",
            "callees": [
                {"name": "foo", "line": 2, "kind": "static", "receiver_hint": None, "note": None},
                {"name": "foo", "line": 7, "kind": "callback", "receiver_hint": None, "note": "via after"},
            ],
        }
        out = enrich_callees_from_references(result, sym)
        assert len(out[0]["tcl_call_sites"]) == 2
        lines = [s["line"] for s in out[0]["tcl_call_sites"]]
        assert 2 in lines
        assert 7 in lines

    def test_receiver_hint_preserved_verbatim(self):
        result = [{"id": "a::mymethod", "name": "mymethod", "resolution": "ast_resolved"}]
        sym = {
            "name": "caller",
            "callees": [
                {"name": "mymethod", "line": 10, "kind": "method_dispatch",
                 "receiver_hint": "$obj", "note": None},
            ],
        }
        out = enrich_callees_from_references(result, sym)
        assert out[0]["tcl_call_sites"][0]["receiver_hint"] == "$obj"

    def test_existing_fields_not_mutated(self):
        original = {"id": "a::foo", "name": "foo", "kind": "proc", "resolution": "ast_resolved"}
        result = [original]
        sym = {
            "name": "bar",
            "callees": [{"name": "foo", "line": 1, "kind": "static", "receiver_hint": None, "note": None}],
        }
        out = enrich_callees_from_references(result, sym)
        # Original dict must not be mutated
        assert "tcl_call_sites" not in original
        # New dict has the enrichment
        assert "tcl_call_sites" in out[0]

    def test_multiple_result_entries_independently_enriched(self):
        result = [
            {"id": "a::foo", "name": "foo", "resolution": "ast_resolved"},
            {"id": "a::bar2", "name": "bar2", "resolution": "ast_inferred"},
        ]
        sym = {
            "name": "caller",
            "callees": [
                {"name": "foo", "line": 3, "kind": "static", "receiver_hint": None, "note": None},
            ],
        }
        out = enrich_callees_from_references(result, sym)
        assert "tcl_call_sites" in out[0]
        assert "tcl_call_sites" not in out[1]


class TestEnrichFindDirectCallees:
    """enrich_find_direct_callees delegates to enrich_callees_from_references — verify same contract."""

    def test_empty_callees_identity(self):
        result = [{"id": "x::fn", "name": "fn", "resolution": "text_matched"}]
        out = enrich_find_direct_callees(result, {"name": "g", "callees": []})
        assert out is result

    def test_populated_callees_enriched(self):
        result = [{"id": "x::fn", "name": "fn", "resolution": "text_matched"}]
        sym = {
            "name": "g",
            "callees": [{"name": "fn", "line": 4, "kind": "ensemble", "receiver_hint": None, "note": None}],
        }
        out = enrich_find_direct_callees(result, sym)
        assert out[0]["tcl_call_sites"][0]["kind"] == "ensemble"


# ---------------------------------------------------------------------------
# enrich_rename_plan
# ---------------------------------------------------------------------------

class TestEnrichRenamePlan:

    def _make_plan(self):
        return {
            "type": "rename",
            "edits": [{"file": "a.tcl", "blocks": []}],
            "warnings": [],
            "collision_check": {},
            "summary": {"files": 1, "edit_blocks": 0, "warnings": 0},
        }

    def test_no_callee_data_returns_plan_unchanged(self):
        plan = self._make_plan()
        sym = {"name": "foo"}
        out = enrich_rename_plan(plan, sym)
        assert out is plan

    def test_empty_callees_returns_plan_unchanged(self):
        plan = self._make_plan()
        sym = {"name": "foo", "callees": []}
        out = enrich_rename_plan(plan, sym)
        assert out is plan

    def test_matching_callee_adds_tcl_call_sites(self):
        plan = self._make_plan()
        sym = {
            "name": "foo",
            "callees": [
                {"name": "foo", "line": 12, "kind": "qualified", "receiver_hint": None, "note": None},
            ],
        }
        out = enrich_rename_plan(plan, sym)
        assert "tcl_call_sites" in out
        assert out["tcl_call_sites"][0]["line"] == 12

    def test_caller_syms_sites_included(self):
        plan = self._make_plan()
        sym = {"name": "foo", "callees": []}
        caller = {
            "name": "other",
            "callees": [
                {"name": "foo", "line": 7, "kind": "static", "receiver_hint": None, "note": None},
            ],
        }
        out = enrich_rename_plan(plan, sym, caller_syms=[caller])
        assert "tcl_call_sites" in out
        assert out["tcl_call_sites"][0]["line"] == 7

    def test_existing_plan_fields_preserved(self):
        plan = self._make_plan()
        sym = {
            "name": "foo",
            "callees": [{"name": "foo", "line": 1, "kind": "static", "receiver_hint": None, "note": None}],
        }
        out = enrich_rename_plan(plan, sym)
        assert out["type"] == "rename"
        assert out["edits"] == plan["edits"]
        assert out["summary"] == plan["summary"]
