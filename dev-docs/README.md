# dev-docs/

Tracked engineering documentation for in-flight work. Everything in this
directory is checked into the fork repo so multi-session work, plan
revisions, and per-phase verdicts are visible to anyone reading the
fork on GitHub.

`dev-docs/` was created at P1.3 close to gather artifacts that had been
spread across `docs/` (gitignored upstream), `validation/probes/`
(runnable probes mixed with verdicts), and the user's local
`~/.omc/jcm-test/` directory (untracked).

## Layout

```
dev-docs/
├── specs/      # in-flight specifications
├── plans/      # phase + multi-phase plans
└── verdicts/   # per-phase + per-stream close-out verdicts
```

### `specs/` — in-flight specifications

Specs that are not yet ratified into the canonical user-facing
`SPEC.md` (or its successor). Today this holds `SPEC_v2.md`, the TCL
bridge spec drafted during P1.2 alongside the walker rewrite. When v2
ships and the cut-over completes, the spec is folded into the
canonical SPEC location and the v2 draft moves to historical
reference status.

### `plans/` — phase + multi-phase plans

Top-level architecture plans. Today this holds `PLAN_v2.1.md` (the
TCL bridge rewrite plan after R1-R34 review revisions) and
`PLAN_v2_2_PATCH.md` (the P1.2 schema-additions / walker-rewrite
delta on top of v2.1). Future phase plans land here as new files.

### `verdicts/` — per-phase / per-stream close-out verdicts

Per-phase / per-stream close-out documents:

- `P1_<N>_VERDICT.md` — phase close-out (P1.0, P1.1, P1.2, P1.3, ...).
- `P1_<N>_<artefact>.md` — phase sub-deliverables that warrant a
  separate write-up (`P1_3_PERF_BENCH.md`, `P1_3_CUT_OVER_POLICY.md`).
- `WALKER_CONTRACT_v2_2.md` — the rev5 walker API contract (consumed
  by `opcode_walker.tcl`, `recursion_tables.tcl`, etc.).
- Empirical evidence verdicts (`BODY_BASE_VERDICT.md`,
  `ENSEMBLE_VERDICT.md`, `TCL_VERSION_VERDICT.md`) — close-outs of
  empirical probes that drove plan revisions.

## What stays where

| Location | Owns |
|---|---|
| Repo root | `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `SPEC.md`, `ARCHITECTURE.md` (if exists) — user-facing canonical docs |
| `dev-docs/` | In-flight specs, phase plans, per-phase verdicts |
| `validation/probes/` | Runnable probes (`*.tcl`, `*.py`), data files (`INSTRUCTION_TABLE_*.tcl`, `*.json`) |
| `validation/fixtures/` | Test fixtures + their runner |
| `tests/` | pytest test suites |

When a probe drops a verdict, the verdict file goes under
`dev-docs/verdicts/`; the probe script stays under
`validation/probes/`. Cross-references between the two are by name
(`p1_3_perf_bench.py` ↔ `P1_3_PERF_BENCH.md`).

## Why this exists

Pre-P1.3, engineering artifacts lived in three places:

1. `docs/` in the fork — gitignored by upstream's `673c03e` rule, so
   the fork carried `SPEC_v2.md` invisibly.
2. `validation/probes/` — runnable probes and verdicts mixed
   together, making it hard to tell at a glance what's a script and
   what's a write-up.
3. `~/.omc/jcm-test/` — the user's local OMC working directory,
   never tracked.

P1.3 close consolidated all three into `dev-docs/` so the fork repo
is self-describing for any maintainer (human or LLM) reading it
without OMC session context.

## For OMC orchestrators

When delegating phase work, point agents at:

- Plans: `dev-docs/plans/PLAN_v2.1.md` + any successor patches in the
  same directory.
- Verdicts: `dev-docs/verdicts/P1_<N>_VERDICT.md` for the most recent
  phase close-out + the cited predecessor verdicts.
- Walker contract: `dev-docs/verdicts/WALKER_CONTRACT_v2_2.md`.

Do not point agents at `~/.omc/jcm-test/PLAN_*` paths — the
originals were moved to this directory at P1.3 close. A redirect
note lives at `~/.omc/jcm-test/REDIRECTED.md`.
