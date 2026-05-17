# P4.0 Preflight Verdict

**Status:** GREEN — Phase 4 unblocked
**Date:** 2026-05-16
**Branch:** `tcl-disasm-bridge`
**HEAD:** `3b09fb0` (P3 closeout) + worktree edits (P4.0a F1+F2+F3 + .gitignore + this doc)
**Audit purpose:** record the environment state at Phase 4 validation time per `PHASE4_PLAN.md §3` discipline — bridge output produced under P4.1 is only trusted relative to the versions pinned below.

---

## 1. Pinned versions

| Component | Pinned to | Source of truth |
|---|---|---|
| TCL call-graph convention | **v1.4** | `dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md` (P4.0a F2+F3 bumped from v1.3) |
| Gold-annotation prompt | **v1.4** | `dev-docs/specs/GOLD_PROMPT_v1.md` (P4.0a F1 bumped from v1.3) |
| jcodemunch-mcp checkout | `tcl-disasm-bridge` @ `3b09fb0` (+ worktree) | `git log -1` |
| Python | 3.12 | `/home/giles/git/jcodemunch-mcp-fork/.venv/bin/python3.12` |
| Tcl interpreter | **8.6.14** | `/usr/bin/tclsh8.6` |
| `JCODEMUNCH_TCL_PARSE_TIMEOUT` | default 30s (no override) | CLAUDE.md env-var table |

---

## 2. Preflight checklist (per PHASE4_PLAN.md §3)

| Check | Result | Evidence |
|---|---|---|
| Python env active | ✓ | `.venv/bin/python3 -c "import jcodemunch_mcp"` resolves to `src/jcodemunch_mcp/__init__.py` in this checkout |
| Editable install fresh | ✓ (no action needed) | `.venv` is uv-managed and already symlinked to this checkout |
| Test suite green | ✓ | `.venv/bin/pytest -x --tb=short` → **3802 passed / 13 skipped / 0 failed** in 491.45s (above CLAUDE.md baseline 3724/7 — P1.x added tests) |
| Tcl interpreter | ✓ | `tclsh8.6 << 'EOF'\nputs [info patchlevel]\nEOF` → `8.6.14` |
| Disasm bridge invokable | ✓ | Canary file produced 11 symbols of valid JSON; see §3 |
| Canary index | ✓ | `CODE_INDEX_PATH=~/.code-index/p4-validation .venv/bin/jcodemunch-mcp index /tmp/tcl_canary` → 1 file, 11 symbols, 0.29s, no_symbols_count=0 |
| Bridge env vars | ✓ | Default `JCODEMUNCH_TCL_PARSE_TIMEOUT=30` sufficient for canary; may need raising on larger generated files (per CLAUDE.md note) |
| Disk space | ✓ | `~/.code-index/` mount has 35 TB free |
| Fresh index dir for P4 (per P4-D1) | ✓ | `CODE_INDEX_PATH=~/.code-index/p4-validation/` adopted for all P4 invocations; everyday `~/.code-index/` untouched |
| `--selftest` mode in bridge | n/a (deliberately skipped) | User-approved skip; real-file canary probe used instead. The plan listed `--selftest` as optional |

---

## 3. Canary probe — fixture and findings

**Fixture:** `/tmp/tcl_canary/canary.tcl` (40 lines, 1198 bytes) exercising:

- `package require Itcl` (Tier 5 import)
- `namespace eval ::canary`
- `proc greet` (basic proc)
- `itcl::class Widget` with `constructor` + `public method show`
- `oo::class create Logger` with `constructor` + `method log` (TclOO inline form)
- **`oo::define Logger { method warn ...; method error ...; forward shout error; mixin SomeMixin }`** (F2 v1.4 canary — augmenting form)
- **`trace add variable ::canary::flag write [list $obj onChange]`** (F3 v1.4 canary — trace callback)
- `$obj show` method_dispatch (v1.3 schema canary — receiver should be `$obj`)

**Bridge JSON output:** 11 symbols, valid JSON, exit code 0, ~0.29s.

**Prompt-build canary:** `build_prompt.py --convention dev-docs/specs/TCL_CALLGRAPH_CONVENTION.md --anon-source canary.tcl:/tmp/tcl_canary/canary.tcl --out /tmp/tcl_canary/canary_prompt.txt`

- Output: 79,689 bytes, sha256 `0542ba5f2f8018fee2ae8af264507c4ad7f276b45f618774eb982651a6aeb35d`
- v1.4 clauses reachable in prompt body: "v1.4", "Trace forcing example", "oo::define emission shape" all present
- No template-substitution errors, no markdown corruption

---

## 4. Known v1.4 divergences in bridge output (anticipates P4.2 diff)

Recording these here to set the P4.1 reindex expectation. The bridge is at v1.0-era schema/filtering; v1.3/v1.4 alignment is Phase 5 work. **Phase 4 measures the gap — it does not fix it.**

| Convention rule | Spec says | Bridge currently does | Phase 4 disposition |
|---|---|---|---|
| §7.1 Tier 3 (`puts`, `error`, `throw`, `open`, `close`, `update`, `vwait`, `gets`, `read`) | filtered | emitted as `call_references` | P4.2 will count as `bridge_extra` |
| §7.1 Tier 5 structural (`package require`) | populate `package_requires` only | both `package_requires` AND `call_references` populated (double-recorded) | P4.2 will count as `bridge_extra` |
| §5.5 visibility prefix (`public`, `private`, `protected`) | not a callee | emitted as `call_references` (e.g. `Widget.call_references = ["public"]`) | P4.2 will count as `bridge_extra` |
| F2: `oo::define CLASS BODY` augmenting form | `oo::define` NOT a callee; BODY directives produce additional records on the canonical class | `oo::define` emitted as `call_references` on the enclosing namespace; augmenting BODY directives produce NO additional symbols on the canonical class | P4.2 will count as `bridge_miss` (additive records) + `bridge_extra` (`oo::define` itself) |
| F3: `trace add variable VAR OPS COMMAND_PREFIX` | only COMMAND_PREFIX's first word is a `callback` callee | `trace` emitted as a callee; COMMAND_PREFIX's first word (`onChange`) missing | P4.2 will count as `bridge_miss` (callback name) + `bridge_extra` (`trace`) |
| v1.3 `receiver_hint` per method_dispatch | structured per-callee field carrying `"$obj"` etc. | bridge emits `call_references: list[str]` only (no per-call-site struct) | Phase 5 plumbing — Path 1 (additive Symbol fields, TCL-only-on-wire) per user-approved 2026-05-16 architecture decision |
| v1.3 `args` (list of formal parameter names) | per-symbol list[str] of parameter names | bridge emits `param_count: int` (arity-equivalent count but no names) | Phase 5 additive |

---

## 5. Decisions in effect for P4.1+

- **CODE_INDEX_PATH = `~/.code-index/p4-validation/`** for all P4 indexing invocations (P4-D1).
- **All 37 gold files in P4.1** — no per-corpus staging (P4-D2).
- **Strictly serial P4.0 → P4.1 → P4.2 → P4.3** (P4-D3).
- **Per-pkg index for tcl-corpus** (tcllib is huge; only the 7 files in gold should be in the bridge output) (P4-D4).
- **Bridge-side bug fixes deferred to Phase 5** (P4-D6).
- **Phase 5 schema-plumbing pattern:** additive Symbol fields with TCL-only-on-wire semantics (matches the P1.3 precedent — `unresolved_dispatches`, `parent_classes`, `package_requires` already on Symbol). User-approved 2026-05-16.
- **Lane A (eval-resolution / bytecode) deferred — maybe never.** Volume too small (36 unresolved entries across 37 files) to justify the engineering cost.
- **Lane B (refactor-tool consumers of v1.3 fields) deferred to Phase 5b** and co-located with bridge schema work.

---

## 6. Next step

P4.1 — reindex all 37 gold-corpus files via jcm under `CODE_INDEX_PATH=~/.code-index/p4-validation/`. Output bridge JSON per file at `validation/bridge_outputs/conv-v1.3/tcl-8.6/<corpus>-<id>/<basename>.bridge.json`. See `PHASE4_PLAN.md §4`.

End of P4.0 verdict.
