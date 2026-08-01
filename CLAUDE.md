# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
mix deps.get
mix test                              # hermetic unit suite, no server needed
mix format --check-formatted
mix credo --strict
mix dialyzer
```

The full gate — what CI runs and what must pass before a commit — additionally
runs the suite once per HTTP adapter, because the three are interchangeable by
design and only the matrix proves it:

```bash
for a in finch req httpc; do TYPEDB_TEST_ADAPTER=$a mix test || break; done
```

Two suites are opt-in: `TYPEDB_INTEGRATION=1` needs a live TypeDB 3.x on
`http://127.0.0.1:8000`, and `TYPEDB_SLOW_TESTS=1` waits out real timeouts.

## Architecture Overview

An HTTP driver for TypeDB 3.x, one module per area of the API.

`TypeDB` is the facade. `TypeDB.Connection` is a `GenServer` that owns nothing
but the token and the adapter state: the connection's config lives in a
read-concurrent ETS table, so **requests run in the caller's process** and the
connection is never a throughput bottleneck. `TypeDB.Transport` builds requests,
retries them, contains adapter faults and decodes responses.
`TypeDB.HTTP` is a behaviour with three adapters — Finch (default), Req, httpc.

Answers decode into `TypeDB.Answer.{Ok, ConceptRows, ConceptDocuments}` and
concepts into `TypeDB.Concept` structs. `TypeDB.Given` encodes input rows for
TypeQL's `given` stage in the tagged wire form, which is what makes
parameterised queries injection-safe.

`AUDIT.md` records the state of the code at 0.1.0 and why several things are the
way they are; read it before proposing to change one of them.

## Conventions & Patterns

- Every failing operation returns `{:error, %TypeDB.Error{}}` and has a `!`
  twin that raises. `test/typedb/api_convention_test.exs` enforces the pairing
  mechanically, including the one recorded exemption.
- The `!` variants are macros in `TypeDB.Bang`, not a shared function — a shared
  `unwrap!/1` widens every caller's success type to their union and Dialyzer
  reports `missing_range` on all of them.
- Optional dependencies must never be named in a compile-time expansion (struct
  patterns above all). `@compile {:no_warn_undefined, …}` does not cover those,
  and the package then fails to compile for anyone who left the dependency out.
- The test stub is not the server. It has been wrong about error codes more than
  once; anything it asserts about TypeDB's behaviour is unproven until the
  integration suite has run it against a live server.
- Public API changes are SemVer events. The driver is past 1.0's predecessor and
  the surface is meant to be frozen at 1.0 — see the `Freeze the public API`
  epic in `bd ready`.
