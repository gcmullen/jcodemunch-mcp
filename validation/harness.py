"""jcodemunch A/B capture harness.

Modes:
    python harness.py capture A --binary <path>
    python harness.py capture B --binary <path>

Both modes:
    - connect to an MCP jcodemunch-mcp server over stdio
    - index the fixture directory (creates a repo named 'jcm-fixtures')
    - run the frozen query set from queries.py
    - write canonical JSON responses under out_{A,B}/

B mode additionally:
    - expects ~/.code-index to be empty / fresh
    - drives index_folder for every known source_root from
      out_A/repo_source_roots.json (captured by A mode)

Writes only under /home/giles/bluice/.omc/jcm-test/. Never modifies source.
"""
from __future__ import annotations

import argparse
import asyncio
import copy
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

BASE = Path("/home/giles/bluice/.omc/jcm-test")
FIXTURE_DIR = BASE / "jcm-fixtures"
SOURCE_ROOTS_FILE = BASE / "out_A" / "repo_source_roots.json"

sys.path.insert(0, str(BASE))
from queries import build_queries, FIXTURE_REPO  # noqa: E402


# ----- canonicalization: deterministic ordering for diff-ability ---------

def _sort_list(lst, key):
    try:
        return sorted(lst, key=key)
    except Exception:
        return lst


def _canonicalize(value):
    """Recursively sort list elements that look like records with IDs or
    file/line fields, so diff between A/B is stable."""
    if isinstance(value, dict):
        return {k: _canonicalize(v) for k, v in value.items()}
    if isinstance(value, list):
        c = [_canonicalize(v) for v in value]
        if not c:
            return c
        first = c[0]
        if isinstance(first, dict):
            if "id" in first:
                return _sort_list(c, lambda x: str(x.get("id", "")))
            if "symbol_id" in first:
                return _sort_list(c, lambda x: str(x.get("symbol_id", "")))
            if "file" in first and "line" in first:
                return _sort_list(
                    c, lambda x: (str(x.get("file", "")), int(x.get("line") or 0))
                )
            if "file" in first:
                return _sort_list(c, lambda x: str(x.get("file", "")))
            if "name" in first:
                return _sort_list(c, lambda x: str(x.get("name", "")))
        return c
    return value


def _maybe_parse_json(text: str):
    """Try to parse a text content block as JSON; return dict on success
    else None. jcodemunch returns JSON wrapped in a text content block."""
    try:
        return json.loads(text)
    except Exception:
        return None


def _decode_munch(text: str):
    """Decode the fork's #MUNCH/1 enc=ss1 compact table encoding into a
    dict that mirrors the pre-#MUNCH JSON shape. Returns None on non-match.

    Format: header line "#MUNCH/1 tool=X enc=ss1", blank, metadata line with
    `key=value` pairs plus `__stypes=k:type,...`, `__tables=prefix:name:cols`,
    `@N=value` interns; blank; data rows prefixed by table prefix, comma-
    separated values in column order. Values may be `@N` intern references.
    """
    if not text or not text.startswith("#MUNCH/1"):
        return None
    lines = text.split("\n")
    # Strip header
    lines = lines[1:]
    # Sections split on blank lines
    sections = []
    cur = []
    for ln in lines:
        if not ln.strip():
            if cur:
                sections.append(cur)
                cur = []
        else:
            cur.append(ln)
    if cur:
        sections.append(cur)
    if not sections:
        return {}
    scalars = {}
    stypes = {}
    tables = {}  # prefix -> (name, cols)
    interns = {}

    # A MUNCH/1 response may have one OR more leading meta sections before
    # the data rows begin: typically either just `<scalars> __tables=...`
    # or `<interns>` then `<scalars> __tables=...`. We iterate from the top
    # and keep processing sections as meta until we hit one whose first
    # line looks like a data row (matches `<prefix>,...` with no `=`).
    meta_end_idx = 0
    for i, section in enumerate(sections):
        first = section[0] if section else ""
        # Heuristic for a data row: starts with a short alphanumeric
        # prefix followed by a comma, and has no `=` in the first token.
        head = first.split(",", 1)[0] if "," in first else first
        looks_like_data = (
            "," in first
            and "=" not in head
            and head.replace("_", "").isalnum()
            and len(head) <= 3
        )
        if looks_like_data:
            meta_end_idx = i
            break
        meta_end_idx = i + 1

    meta_lines = []
    for i in range(meta_end_idx):
        meta_lines.extend(sections[i])

    for ln in meta_lines:
        tokens = _tokenize_meta(ln)
        for tok in tokens:
            if tok.startswith("@") and "=" in tok:
                k, v = tok.split("=", 1)
                interns[k] = v
                continue
            if "=" not in tok:
                continue
            k, v = tok.split("=", 1)
            # Strip surrounding double-quotes from quoted values. The fork
            # quotes values that contain commas (e.g. fo1's
            # __tables="s:symbols:...,b:results:..."). Without this, the
            # table-prefix lookup below sees `"s` instead of `s` and every
            # data row fails to match.
            if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
                v = v[1:-1]
            if k == "__stypes":
                for p in v.split(","):
                    if ":" in p:
                        kk, tt = p.split(":", 1)
                        stypes[kk] = tt
            elif k == "__tables":
                for part in v.split(","):
                    segs = part.split(":")
                    if len(segs) >= 3:
                        tables[segs[0]] = (segs[1], segs[2].split("|"))
            else:
                scalars[k] = v

    def _resolve(val):
        if not isinstance(val, str) or not val.startswith("@"):
            return val
        # Bare intern reference (whole value is a single intern key).
        if val in interns:
            return interns[val]
        # Intern-prefixed value: `@N<rest>` where `@N` is the intern and
        # `<rest>` is an un-interned suffix (typically `::...`). Split at
        # the first non-intern character and expand the prefix.
        import re as _re
        m = _re.match(r"^(@\d+)(.*)$", val)
        if m and m.group(1) in interns:
            return interns[m.group(1)] + m.group(2)
        return val

    result = {}
    for k, v in scalars.items():
        t = stypes.get(k, "str")
        rv = _resolve(v)
        # JSON-blob scalars are encoded with the `__json.` prefix by the
        # schema-driven encoder. Decode back to the real Python object and
        # store under the un-prefixed key.
        if k.startswith("__json."):
            real_key = k[len("__json."):]
            try:
                result[real_key] = json.loads(rv)
            except Exception:
                result[real_key] = rv
            continue
        if t == "int":
            try:
                result[k] = int(rv)
            except Exception:
                result[k] = rv
        elif t == "float":
            try:
                result[k] = float(rv)
            except Exception:
                result[k] = rv
        elif t == "bool":
            result[k] = rv in ("1", "true", "True")
        else:
            result[k] = rv
    for prefix, (name, cols) in tables.items():
        result[name] = []
    for section in sections[meta_end_idx:]:
        for row in section:
            if not row.strip():
                continue
            parts = row.split(",")
            prefix = parts[0]
            if prefix in tables:
                name, cols = tables[prefix]
                values = parts[1:1 + len(cols)]
                # If fewer values than cols, pad; if we ran out of cols
                # but still have extra commas, rejoin trailing into last col
                if len(parts[1:]) > len(cols):
                    values = parts[1:len(cols)] + [",".join(
                        parts[len(cols):]
                    )]
                values = (values + [""] * len(cols))[:len(cols)]
                values = [_resolve(v) for v in values]
                result[name].append(dict(zip(cols, values)))
    return result


def _tokenize_meta(line: str):
    """Split a metadata line into tokens by whitespace, but treat
    `__tables=...` and `__stypes=...` as single tokens even if the value
    contains spaces (it doesn't, in practice). Simple whitespace split
    works for current server output."""
    return line.split()


def _normalize_content(blocks):
    """Extract the JSON payload from jcodemunch's text content blocks,
    canonicalize ordering. Returns list of {type, text_raw?, json?} dicts."""
    out = []
    for b in blocks or []:
        try:
            d = b.model_dump()
        except Exception:
            d = dict(getattr(b, "__dict__", {}) or {})
        if d.get("type") == "text" and isinstance(d.get("text"), str):
            txt = d["text"]
            parsed = _maybe_parse_json(txt)
            if parsed is None:
                parsed = _decode_munch(txt)
            if parsed is not None:
                out.append({"type": "text+json",
                            "json": _canonicalize(parsed)})
                continue
        out.append({"type": d.get("type", "unknown"), "raw": d})
    return out


# ----- MCP session wrappers --------------------------------------------

async def _call(session, tool, args, timeout=90):
    t0 = time.perf_counter()
    try:
        resp = await asyncio.wait_for(session.call_tool(tool, args),
                                       timeout=timeout)
        ms = (time.perf_counter() - t0) * 1000
        return {
            "ok": True,
            "isError": bool(getattr(resp, "isError", False)),
            "ms": round(ms, 1),
            "content": _normalize_content(resp.content),
        }
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout_{timeout}s",
                "ms": round((time.perf_counter() - t0) * 1000, 1)}
    except Exception as e:
        return {"ok": False, "error": repr(e),
                "ms": round((time.perf_counter() - t0) * 1000, 1)}


async def _resolve_symbol_id(session, repo, query):
    """Look up a symbol_id for an identifier via search_symbols.

    Strategy: request a broad result set, then pick the first result whose
    `name` exactly equals the query. Falls back to the top-ranked result.
    Using max_results=1 can race with server session-state and produce
    empty results even when the symbol exists, so we widen the search.
    """
    r = await _call(
        session, "search_symbols",
        {"repo": repo, "query": query, "max_results": 25}, timeout=30,
    )
    if not r.get("ok") or r.get("isError"):
        return None, r.get("error") or "search_failed"
    try:
        payload = r["content"][0]["json"]
        results = payload.get("results") or []
        if not results:
            return None, "no_results"
        # Prefer exact name match
        for res in results:
            if res.get("name") == query:
                return res.get("id"), None
        # Fallback to top-ranked (first) result
        return results[0].get("id"), None
    except Exception as e:
        return None, f"parse_failed: {e!r}"


async def _preresolve_all(binary, queries, resolve_log):
    """Resolve every _resolve directive upfront in a dedicated fresh session.

    Server-side session state (plan_turn cache, turn_budget_tokens) can make
    the same search_symbols call return 0 results after many queries run in
    the same session. Resolving upfront keeps session state clean.

    Returns a dict keyed by (repo, query) -> symbol_id or None.
    """
    tuples = set()
    for q in queries:
        resolve = q["args"].get("_resolve")
        if resolve:
            tuples.add((resolve["repo"], resolve["query"]))
    if not tuples:
        return {}
    cache = {}
    params = StdioServerParameters(command=binary, args=[], env={})
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for repo, ident in sorted(tuples):
                sid, err = await _resolve_symbol_id(session, repo, ident)
                cache[(repo, ident)] = sid
                resolve_log.append({
                    "repo": repo, "identifier": ident,
                    "resolved_symbol_id": sid, "error": err,
                })
    return cache


async def _run_query(session, q, resolve_cache):
    args = copy.deepcopy(q["args"])
    resolve = args.pop("_resolve", None)
    if resolve:
        sid = resolve_cache.get((resolve["repo"], resolve["query"]))
        if sid is None:
            return {
                "ok": False,
                "error": "resolve_failed_in_preresolve",
                "resolve": {**resolve, "resolved_to": None},
            }
        args[resolve["into"]] = sid
    result = await _call(session, q["tool"], args)
    result["effective_args"] = args
    return result


# ----- index driving ----------------------------------------------------

async def _index_folder(session, path):
    return await _call(
        session, "index_folder",
        {"path": path, "use_ai_summaries": False, "incremental": False},
        timeout=600,
    )


async def _ensure_fixture_repo(session, manifest):
    """Index the fixture dir so queries against 'jcm-fixtures' work."""
    r = await _index_folder(session, str(FIXTURE_DIR))
    manifest["fixture_index_result"] = {
        "ok": r.get("ok"), "isError": r.get("isError"),
        "ms": r.get("ms"),
    }
    return r


async def _reindex_source_roots(session, manifest):
    """Reindex all known source_roots (B mode only)."""
    if not SOURCE_ROOTS_FILE.exists():
        manifest["source_roots_error"] = (
            f"missing {SOURCE_ROOTS_FILE}; run A capture first"
        )
        return
    roots = json.loads(SOURCE_ROOTS_FILE.read_text())
    log = []
    for entry in roots:
        p = entry["source_root"]
        print(f"  indexing: {p}")
        r = await _index_folder(session, p)
        log.append({
            "path": p, "display_name": entry.get("display_name"),
            "ok": r.get("ok"), "isError": r.get("isError"),
            "ms": r.get("ms"),
        })
    manifest["reindex_log"] = log


# ----- capture orchestration --------------------------------------------

async def _capture(label, binary, reindex):
    out_dir = BASE / f"out_{label}"
    (out_dir / "queries").mkdir(parents=True, exist_ok=True)
    manifest = {
        "label": label,
        "binary": binary,
        "started_at": time.time(),
        "reindex": reindex,
    }
    queries = build_queries()

    # Pre-pass 1: set up indexes + capture source_roots (A mode)
    params = StdioServerParameters(command=binary, args=[], env={})
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            if label == "A":
                r = await _call(session, "list_repos", {})
                if r.get("ok"):
                    try:
                        repos = r["content"][0]["json"]["repos"]
                        roots = [
                            {"display_name": x.get("display_name"),
                             "source_root": x.get("source_root"),
                             "repo": x.get("repo"),
                             "git_head": x.get("git_head")}
                            for x in repos if x.get("source_root")
                        ]
                        SOURCE_ROOTS_FILE.parent.mkdir(parents=True,
                                                       exist_ok=True)
                        SOURCE_ROOTS_FILE.write_text(
                            json.dumps(roots, indent=2)
                        )
                        manifest["source_roots_written"] = len(roots)
                    except Exception as e:
                        manifest["source_roots_error"] = repr(e)
            if reindex:
                print("Reindexing source roots…")
                await _reindex_source_roots(session, manifest)
            print("Indexing fixtures…")
            await _ensure_fixture_repo(session, manifest)

    # Pre-pass 2: resolve all symbol_ids upfront in a fresh session
    print("Pre-resolving symbol IDs…")
    resolve_log = []
    resolve_cache = await _preresolve_all(binary, queries, resolve_log)
    manifest["preresolve"] = {
        "count": len(resolve_cache),
        "unresolved": [
            {"repo": k[0], "query": k[1]}
            for k, v in resolve_cache.items() if v is None
        ],
    }
    for k, v in resolve_cache.items():
        print(f"  {'OK  ' if v else 'MISS'} {k[0]}::{k[1]} -> {v}")

    # Main pass: run queries in a fresh session
    print(f"Running {len(queries)} queries…")
    summary = {"label": label, "queries": [], "resolve_log": resolve_log}
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for q in queries:
                r = await _run_query(session, q, resolve_cache)
                entry = {
                    "name": q["name"], "tool": q["tool"],
                    "dimension": q["dimension"], "repo": q.get("repo"),
                    "ms": r.get("ms"),
                    "ok": r.get("ok"), "isError": r.get("isError"),
                    "error": r.get("error"),
                    "args": q["args"],
                }
                summary["queries"].append(entry)
                (out_dir / "queries" / f"{q['name']}.json").write_text(
                    json.dumps({**entry, "result": r}, indent=2,
                               default=str)
                )
                status = (
                    "FAIL" if not r.get("ok")
                    or r.get("isError") else "OK"
                )
                print(f"  [{status}] {q['name']:60s} "
                      f"{r.get('ms', '-')!s:>8} ms")
            manifest["query_count"] = len(summary["queries"])
            manifest["finished_at"] = time.time()

    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nWrote {len(queries)} query responses + summary to {out_dir}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["capture"])
    ap.add_argument("label", choices=["A", "B"])
    ap.add_argument("--binary",
                    default="/home/giles/tools/jcodemunch-venv/bin/"
                            "jcodemunch-mcp",
                    help="Path to jcodemunch-mcp binary")
    ap.add_argument("--reindex", action="store_true",
                    help="Drive index_folder for all known source_roots "
                         "(default on for B, off for A)")
    ap.add_argument("--no-reindex", action="store_true")
    args = ap.parse_args()

    reindex = args.label == "B"
    if args.reindex:
        reindex = True
    if args.no_reindex:
        reindex = False

    if not Path(args.binary).exists():
        print(f"ERROR: binary not found: {args.binary}", file=sys.stderr)
        sys.exit(2)

    asyncio.run(_capture(args.label, args.binary, reindex))


if __name__ == "__main__":
    main()
