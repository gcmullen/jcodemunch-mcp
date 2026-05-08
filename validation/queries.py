"""Frozen query set for jcodemunch A/B comparison.

Each query is a dict with:
    name       - unique identifier (used as filename)
    tool       - MCP tool name
    args       - dict of args; may contain a "_resolve" key telling the harness
                 to first run search_symbols(repo, ident), take the top hit's
                 symbol_id, and substitute it into the target arg.
    dimension  - one of: repo_level, file_outline, symbol_search, xref,
                 source_fetch, fixture
    repo       - optional short-form repo tag used by diff.py to filter
                 TCL-only analysis (None = cross-repo query)

Query design rules:
- Use short-form display_names as `repo` args (e.g. "BluIceWidgets") — these
  resolve on both A and B regardless of hash suffix.
- Prefer name/identifier inputs over symbol_id inputs so queries are stable
  across parser implementations; when symbol_id is required, use _resolve.
- Fixtures live in their own logical repo "jcm-fixtures" indexed from
  /home/giles/bluice/.omc/jcm-test/fixtures.
"""

TCL_REPOS = ["BluIceWidgets", "DcsWidgets", "dcss", "dhs-tcl", "dcs-lib-tcl"]
FIXTURE_REPO = "jcm-fixtures"
FIXTURE_PATH = "/home/giles/bluice/.omc/jcm-test/jcm-fixtures"

# Representative TCL files per subrepo, covering different patterns.
FILES = {
    "BluIceWidgets": [
        "Admin.tcl",                 # class X { inherit ... }
        "ScreeningTask.tcl",         # complex methods, high cyclomatic
        "CollectView.tcl",           # large file, many methods
        "DirectoryView.tcl",         # itcl::class + itcl::body
        "SequenceActions.tcl",       # multiple classes + bodies
    ],
    "DcsWidgets": [
        "BluIceShell.tcl",
        "GridGroup4BluIce.tcl",
    ],
    "dcss": [
        "scripts/operations/SequenceDevice.tcl",
        "scripts/operations/collectGrid.tcl",
    ],
    "dhs-tcl": [
        "main/scripts/chain/devices/ChainMotorBase.tcl",
        "main/scripts/robot/controller/RobotController.tcl",
    ],
    "dcs-lib-tcl": [
        "main/scripts/DcssHardwareClient.tcl",
        "main/scripts/ImpWriteFiles.tcl",
    ],
}

# Symbol names we expect to find in the current index (harvested from Pass A).
# Used for search + find_references + resolve targets.
KNOWN_NAMES = {
    "BluIceWidgets": [
        ("handleSend", "method"),
        ("startBluIce", "function"),
        ("Admin", "class"),
        ("ScreeningActionList", "class"),
        ("DirectoryView", "class"),
        ("DCS", None),                # namespace token
        ("sendContentsToServer", "method"),
        ("refresh", "method"),
        ("getResolutionRings", "method"),
    ],
    "DcsWidgets": [
        ("BluIceShell", None),
    ],
    "dcss": [
        ("main", "function"),
    ],
    "dhs-tcl": [],
    "dcs-lib-tcl": [],
}

# Classes that definitely inherit (per grep) — cross-ref probes.
CLASSES_WITH_INHERITANCE = [
    ("BluIceWidgets", "Admin"),
    ("BluIceWidgets", "ScreeningActionList"),
    ("BluIceWidgets", "DirectoryView"),
    ("BluIceWidgets", "RobotCalibrationWidget"),
    ("BluIceWidgets", "CryojetWidget"),
]


def build_queries():
    """Return the flat list of queries to execute in order."""
    q = []

    # ----- repo-level -----
    q.append({
        "name": "repo_list", "tool": "list_repos", "args": {},
        "dimension": "repo_level", "repo": None,
    })
    for r in TCL_REPOS + [FIXTURE_REPO]:
        q.append({
            "name": f"repo_outline__{r}", "tool": "get_repo_outline",
            "args": {"repo": r}, "dimension": "repo_level", "repo": r,
        })
        q.append({
            "name": f"repo_health__{r}", "tool": "get_repo_health",
            "args": {"repo": r}, "dimension": "repo_level", "repo": r,
        })
    for r in TCL_REPOS:
        q.append({
            "name": f"suggest_queries__{r}", "tool": "suggest_queries",
            "args": {"repo": r}, "dimension": "repo_level", "repo": r,
        })

    # ----- file outline -----
    for repo, files in FILES.items():
        for f in files:
            short = f.replace("/", "_").replace(".tcl", "")
            q.append({
                "name": f"file_outline__{repo}__{short}",
                "tool": "get_file_outline",
                "args": {"repo": repo, "file_path": f},
                "dimension": "file_outline", "repo": repo,
            })

    # ----- fixture file outlines -----
    fixture_files = [
        "01_hex_in_expr.tcl", "02_nested_namespace.tcl",
        "03_continued_proc.tcl", "04_inline_braces.tcl",
        "05_itcl_configbody.tcl", "06_multi_inherit.tcl",
        "07_xotcl.tcl", "08_snit.tcl", "09_tcloo.tcl",
    ]
    for fx in fixture_files:
        q.append({
            "name": f"fixture_outline__{fx.replace('.tcl', '')}",
            "tool": "get_file_outline",
            "args": {"repo": FIXTURE_REPO, "file_path": fx},
            "dimension": "fixture", "repo": FIXTURE_REPO,
        })

    # ----- symbol search (by name) -----
    for repo, names in KNOWN_NAMES.items():
        for name, kind in names:
            safe = name.replace("::", "_")
            q.append({
                "name": f"sym_search__{repo}__{safe}",
                "tool": "search_symbols",
                "args": {"repo": repo, "query": name, "max_results": 25},
                "dimension": "symbol_search", "repo": repo,
            })
    # kind-filtered searches (with a non-empty query since empty query+filter
    # is known to break; we use a common prefix as the probe string)
    for repo in ["BluIceWidgets", "DcsWidgets", "dcss"]:
        q.append({
            "name": f"sym_kind_class__{repo}",
            "tool": "search_symbols",
            "args": {"repo": repo, "query": "a", "kind": "class",
                     "max_results": 25, "fuzzy": True},
            "dimension": "symbol_search", "repo": repo,
        })
        q.append({
            "name": f"sym_kind_fn__{repo}",
            "tool": "search_symbols",
            "args": {"repo": repo, "query": "a", "kind": "function",
                     "max_results": 25, "fuzzy": True},
            "dimension": "symbol_search", "repo": repo,
        })

    # ----- cross-reference -----
    xref_targets = [
        ("BluIceWidgets", "handleSend"),
        ("BluIceWidgets", "startBluIce"),
        ("BluIceWidgets", "sendContentsToServer"),
        ("BluIceWidgets", "refresh"),
        ("BluIceWidgets", "getResolutionRings"),
    ]
    for repo, ident in xref_targets:
        q.append({
            "name": f"refs__{repo}__{ident}",
            "tool": "find_references",
            "args": {"repo": repo, "identifier": ident, "max_results": 50},
            "dimension": "xref", "repo": repo,
        })
        q.append({
            "name": f"check_refs__{repo}__{ident}",
            "tool": "check_references",
            "args": {"repo": repo, "identifier": ident},
            "dimension": "xref", "repo": repo,
        })
    for repo, cls in CLASSES_WITH_INHERITANCE:
        q.append({
            "name": f"class_hierarchy__{repo}__{cls}",
            "tool": "get_class_hierarchy",
            "args": {"repo": repo, "class_name": cls},
            "dimension": "xref", "repo": repo,
        })

    # call hierarchy (needs symbol_id → resolve)
    call_targets = [
        ("BluIceWidgets", "handleSend"),
        ("BluIceWidgets", "startBluIce"),
        ("BluIceWidgets", "sendContentsToServer"),
    ]
    for repo, ident in call_targets:
        q.append({
            "name": f"call_hier__{repo}__{ident}",
            "tool": "get_call_hierarchy",
            "args": {"repo": repo, "depth": 2, "direction": "both",
                     "_resolve": {"repo": repo, "query": ident,
                                   "into": "symbol_id"}},
            "dimension": "xref", "repo": repo,
        })

    # ----- source fetch (via resolved symbol_id) -----
    src_targets = [
        ("BluIceWidgets", "Admin"),
        ("BluIceWidgets", "handleSend"),
        ("BluIceWidgets", "startBluIce"),
        ("BluIceWidgets", "ScreeningActionList"),
        ("BluIceWidgets", "DirectoryView"),
    ]
    for repo, ident in src_targets:
        q.append({
            "name": f"src__{repo}__{ident}",
            "tool": "get_symbol_source",
            "args": {"repo": repo,
                     "_resolve": {"repo": repo, "query": ident,
                                   "into": "symbol_id"}},
            "dimension": "source_fetch", "repo": repo,
        })

    return q


if __name__ == "__main__":
    qs = build_queries()
    print(f"{len(qs)} queries")
    from collections import Counter
    c = Counter(q["dimension"] for q in qs)
    for k, v in sorted(c.items()):
        print(f"  {k:16s} {v}")
