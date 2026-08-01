# Contributing

## Finding something to work on

Issues live in the repository, not in a tracker you need an account for. This
project uses [beads](https://github.com/gastownhall/beads) (`bd`), a
dependency-aware issue graph stored in a Dolt database under `.beads/`.

```shell
brew install beads          # or: npm install -g @beads/bd
bd ready                    # every issue whose blockers are all closed
bd show tdb-ojs.1           # one issue, with its dependencies and history
bd list --status open
```

The roadmap to 1.0.0 is ten epics; `bd ready` sorts what is actionable by
priority, so the top of that list is the answer to "what should I do next".

A fresh clone has no local database yet — `bd` says so rather than showing an
empty list. Seed it from the committed export:

```shell
bd init -p tdb
bd import .beads/issues.jsonl
```

Once the issue history has been published to the git remote (`bd dolt push`,
which needs write access), `bd bootstrap` replaces both of those and clones the
full history instead of a snapshot.

When you pick something up:

```shell
bd update <id> --claim           # sets assignee and in_progress
bd close <id>                    # when it is done
```

Name the issue id at the end of the commit message — `Add jitter to the default
backoff (tdb-ojs.1)` — so `bd doctor` can tell landed work from work that was
merely committed.

`.beads/issues.jsonl` is a passive export kept for readers and for seeding
fresh clones. It is not the source of truth: cross-machine sync is
`bd dolt push` / `bd dolt pull` against `refs/dolt/data` on the git remote.
Don't hand-edit it.

## Getting set up

```shell
mix deps.get
mix test          # hermetic: runs the whole driver against an in-process HTTP server
```

`mix test` never needs a database. The unit suite drives the driver against
`TypeDB.Stub`, a real HTTP/1.1 server that speaks the TypeDB API, so transport,
encoding, token renewal and error mapping are all exercised without one.

## Running against a real server

```shell
docker compose up -d
TYPEDB_INTEGRATION_URL=http://localhost:8000 mix test --include integration

# Opt-in suites that an ordinary run skips:
#   TYPEDB_SLOW_TESTS=1              tests that wait out real timeouts
#   TYPEDB_SHORT_TOKEN_URL=...       token renewal, see the moduledoc of
#                                    TypeDB.TokenRenewalIntegrationTest
#   TYPEDB_TLS_URL=...               the TLS suite, see TypeDB.TLSIntegrationTest
```

The integration suite creates and drops its own databases, so it is safe against
a scratch server — and only a scratch server.

`TypeDB.TLSIntegrationTest` additionally checks the TLS defaults. Its module doc
carries the `openssl` invocations and the server flags needed to run it.

## Before opening a pull request

```shell
mix format
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix typedb.check          # validates priv/**/*.tql, needs the typeql-check CLI and a POSIX shell
```

The suite runs against whichever transport `TYPEDB_TEST_ADAPTER` names, and CI
runs all of them. Anything touching `lib/typedb/http/` should be checked the same
way, because an adapter exercised only by its own unit tests is an adapter that
is quietly broken:

```shell
for adapter in finch req httpc; do TYPEDB_TEST_ADAPTER=$adapter mix test; done
```

## Fidelity to the server

The stub in `test/support/` is only useful while it behaves like TypeDB. Where
its behaviour is not the obvious guess, it carries a comment naming the version
it was checked against — for example, creating a database that already exists
succeeds, while deleting one that does not exist fails; closing an unknown
transaction succeeds, while committing one does not.

If you change the stub to make a test pass, check the real server first and
record what you found.

## Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

It is in `0.x`, which under SemVer means the public API may change in any
release. That is an accurate description of where it stands: the driver is
tested against a live TypeDB 3.12.1 and used as though it were finished, but no
application has yet met the API, and a shape that has never had a user is not a
shape worth freezing. `1.0.0` is the promise that it is, and it will be made
once the API has survived real use rather than before.

Until then, a **minor** bump carries anything a `1.x` would call breaking, and a
**patch** carries anything it would not.

The public API is every documented module and function on
[hexdocs](https://hexdocs.pm/typedb). Modules marked `@moduledoc false` and
functions marked `@doc false` are internal: they are callable, but they are not
promises, and they change in patch releases.

### What the version number covers

More than the function signatures, because more than the function signatures
ends up in someone's code:

- **Signatures and struct fields** — everything in `test/api_snapshot.txt`.
- **`TypeDB.Error`'s `:kind`s.** Callers branch on them. TypeDB's own `:code`s
  are the *server's* to change, and the driver passes them through.
- **Telemetry event names and metadata keys.** A renamed event silently empties
  a dashboard, which is worse than a compile error. Removing a metadata key or
  renaming an event is breaking; adding one is not.
- **The connection option set and its defaults.** Removing an option, or
  changing what one defaults to, is breaking — `:max_retries`,
  `:transaction_type`, the default adapter, the shape of `:retry_backoff`.
- **The `TypeDB.HTTP` and `TypeDB.JSON` behaviours.** Adding a required callback
  breaks every adapter anyone else has written.
- **Elixir and OTP floors, and whether a dependency is optional.**

### What it does not cover

- Internal modules and `@doc false` functions.
- The exact text of a message — log lines, `Exception.message/1`, error
  messages. Match on `:kind` and `:code`, never on prose.
- The return of `TypeDB.Transaction.analyze/3`, which is TypeDB's own map from
  an endpoint that is not in the published HTTP API reference. Its shape tracks
  the server, so it can change in a patch release of the driver. This is the one
  documented exemption, and it is stated on the function too.
- TypeDB's own wire format, error codes, and behaviour. When the server changes
  what it returns, the driver reports the change rather than absorbing it.
- Which HTTP requests a given call makes. Retry policy, token renewal and
  connection reuse are all free to change; only the observable result is not.

Breaking, for this project, includes all of:

- removing or renaming a public function, module, struct field, or `:kind` of
  `TypeDB.Error`
- adding a required argument, or changing what a function returns on success
- turning something that returned `{:error, _}` into something that raises,
  or the reverse
- a new mandatory dependency, or raising the floor of an existing one
- raising the minimum Elixir or OTP version
- changing a default — `:transaction_type`, `:max_retries`, the default adapter

Widening an upstream constraint (`~> 0.23` to `~> 0.23 or ~> 1.0`) is a patch,
and is done *after* testing against the new version, never in anticipation.

### The API snapshot

`test/api_snapshot.txt` records the whole published surface — every module,
struct field, type, callback and spec — and `test/typedb/api_snapshot_test.exs`
fails when the code and the file disagree. Attention does not scale; this does.

A failure is a question, not a verdict. Read the diff, decide what it means for
the version number, then:

```shell
TYPEDB_UPDATE_API_SNAPSHOT=1 mix test test/typedb/api_snapshot_test.exs
```

and commit the regenerated file alongside the change that caused it. A pull
request that changes the snapshot without saying why in its description will be
asked why.

The test only runs on the newest Elixir in the matrix, and skips elsewhere:
Elixir's typespec rendering is not stable across versions — 1.18 writes
`__exception__: true` where 1.20 writes `__exception__: term()` — and comparing
on every version would report Elixir upgrades as API breaks.

## Releasing

1. Bump `@version` in `mix.exs` per the rules above.
2. Add the matching `## [X.Y.Z]` section to `CHANGELOG.md` and its link at the
   bottom. The release workflow refuses to publish a tag the CHANGELOG does not
   document.
3. Update the version in the README's installation snippet.
4. `mix hex.build` and read the file list.
5. Tag `vX.Y.Z` and push it.

The release workflow then re-runs the gate — format, `--warnings-as-errors`,
credo, dialyzer, and the suite through all three adapters — checks the tag
against `mix.exs` and the CHANGELOG, publishes to hex.pm with the `HEX_API_KEY`
secret, and creates the GitHub Release. Documentation is built by `ex_doc` and
published to hexdocs.pm as part of `mix hex.publish`.

To publish by hand instead, run the gate yourself first, then:

```shell
mix hex.publish
```
