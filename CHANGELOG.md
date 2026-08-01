# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `TypeDB.Transaction.analyze/3` returned `{:ok, :ok}` for a 200 with an empty
  body, where its spec promises `{:ok, map()}`. It now rejects a payload that is
  not a structure. Found by the fault matrix.

### Added

- A bounded concurrency soak in the integration suite: 200 concurrent reads,
  100 concurrent writes checked for exactly-once landing, and 25 concurrent
  transactions. The numbers the CHANGELOG has published since 0.1.0 were
  produced by hand; these run on every push.
- A coverage floor, enforced by CI.
- A fault-injection matrix: thirteen ways an adapter or a server can misbehave,
  against every public call that reaches one, asserting that each produces a
  `%TypeDB.Error{}` and leaves the connection alive.
- Property-based round-trip tests over the wire boundary — `TypeDB.Duration`,
  `TypeDB.DateTimeTZ`, `TypeDB.Given` and `TypeDB.Concept` — where every
  subtle bug in this driver has actually been. `stream_data` is a test-only
  dependency and does not reach the package.
- `bench/decode.exs` and `bench/transport.exs`, the scripts behind the numbers
  quoted here. They were previously run by hand from a scratch directory that
  no longer exists, which made every figure in this file unfalsifiable.

### Changed

- **The supported TypeDB floor is 3.12.0, and it is now a measured one.** The
  suite was run down the published releases rather than reasoned about: 3.12.0
  passes whole, 3.11.5 fails fourteen integration tests, and 3.5.0 fails more
  broadly still. TypeQL's `given` stage — the driver's answer to query
  injection — is a syntax error before 3.12, so every parameterised query fails
  there, and `User.delete/2` on an unknown user answers 400 rather than 404.
  3.12.0 is in CI's integration matrix beside 3.12.1 and `latest`, so the claim
  stays true. The README said "3.12 or newer" before this and happened to be
  right; it was not evidence.
- Re-measured throughput, on the scripts now in `bench/`, against a local
  TypeDB 3.12.1 in this project's container — 400 requests per run, warmed
  pool, a one-row `match`. At 200-way concurrency Finch sustains ~1800 req/s
  and Req ~1770, both with a p99 under 120ms; `:httpc` manages ~280 req/s at a
  p99 of 960ms. 0.1.0 published 1900 against 77 for the same comparison; the
  ratio is the finding and it holds, the absolute numbers are a property of
  whatever machine you run them on.

### Fixed

- `TypeDB.Concept.cast/2` asked `Code.ensure_loaded?(Decimal)` once per value.
  For an application that *has* `Decimal` that is a cached lookup costing
  nothing; for one that does not it is a code-server round trip, and it was the
  entire cost of casting a decimal — 22µs a value, against 0.4µs with the
  dependency present. The answer is now memoised in `:persistent_term`, which
  takes 50,000 casts without `Decimal` from 1099ms to 5ms.

## [0.2.1] - 2026-08-01

Documentation only. The single change under `lib/` is six lines of moduledoc;
`test/api_snapshot.txt` is byte for byte the one 0.2.0 shipped.

These were written after 0.2.0 was tagged and were briefly listed under it in
this file, which was wrong: a published release does not grow.

### Added

- Four guides, published with the docs and shipped in the package:
  [Transactions](guides/transactions.md),
  [Errors and retries](guides/errors-and-retries.md),
  [Telemetry and logging](guides/observability.md), and
  [Testing an application](guides/testing.md).
- A Livebook notebook, with a Run in Livebook badge on the README: a database, a
  schema, reads and writes, a parameterised query that survives a hostile value,
  and a transaction. Its code blocks are parsed by the test suite, and the
  version it installs is checked against this project.
- A Limitations section in the README: answers arrive whole, a connection points
  at one server, retries block the caller, one connection is one HTTP pool.

### Changed

- The documentation's module groups are ordered for reading rather than by
  accretion, and a test now asserts every published module is filed under
  exactly one of them.

## [0.2.0] - 2026-08-01

Work towards 1.0. Retry and timeout behaviour, observability, and the shape of
the public surface — the three things 1.0 makes irreversible.

### Upgrading from 0.1.0

Four changes can be noticed by working code, and each is deliberate:

1. Backoff delays are now random within their bound. A test that asserted an
   exact wait should assert the bound, or pass a function to `:retry_backoff`.
2. More requests are retried — reads, `rollback`, `close`, `Database.create/2`,
   `User.set_password/3`, and any response with a status in the new
   `:retry_on_status`. A test counting requests to the server may see more of
   them. `max_retries: 0` and `retry_on_status: []` restore the old behaviour.
3. `TypeDB.Given` and `TypeDB.Duration.to_iso8601/1` raise `%TypeDB.Error{}`
   with kind `:encode` where they raised `:config`. Code matching on
   `kind: :config` to catch an unencodable value must match `:encode`.
4. Five documented error codes were wrong and are corrected below. Code
   matching on `TSV2`, `TSV3`, `TSV11` or `SRV5` should re-read that entry —
   the driver was reporting what its test stub had invented, not what TypeDB
   answers.

Everything else is additive.

### Added

- `:retry_max_delay` — a ceiling on any single backoff, whichever form produced
  it, including a caller's own `:retry_backoff` function. Defaults to `5_000`;
  `:infinity` opts out.
- `:deadline` — a wall-clock budget for a whole call, retries and the waits
  between them included. Defaults to `:infinity`. Each attempt is given
  whichever is smaller, its own `:timeout` or what the budget has left, and a
  retry that could not finish inside the budget is not started. Available per
  connection and on every function that already took `:timeout`.
- `:retry_on_status` — statuses to retry in addition to transport failures and
  timeouts. Defaults to `[429, 502, 503, 504]`; `[]` opts out. A numeric
  `retry-after` is honoured, bounded by `:retry_max_delay`.
- `:log_level` — the quietest level a connection will log at, `:none` to
  silence it. Every driver log line now goes through one place, and the
  `TypeDB` moduledoc lists all of them.
- `[:typedb, :operation, …]` — a span per call into the public API, with every
  retry and token renewal inside it, reporting `:attempts` and a
  low-cardinality `:route` safe to use as a metric tag.
- `[:typedb, :transaction, …]` — a span per `TypeDB.transaction/5`, from open
  to commit, with an `:outcome` of `:commit`, `:rollback`, `:close` or
  `:commit_failed`.
- `[:typedb, :retry, :exhausted]` — emitted when a call stops retrying, with
  `:attempts`. The event to alert on.
- `TypeDB.Telemetry.attach_default_logger/1` and `detach_default_logger/0` — a
  line per operation, transaction, sign-in and give-up, off unless asked for.
- `:database`, `:transaction_type` and `:transaction_id` in telemetry metadata,
  including for `/v1/query`, which carries its database in the request body.
- `TypeDB.Error.retryable?/1` and `TypeDB.Error.retryable_statuses/0` — whether
  retrying could plausibly help, for the layer above the driver: retrying a
  whole transaction or requeueing a job, where the unit of work is bigger than
  one HTTP call. Callers were otherwise copying `kind in [:transport, :timeout]`
  out of the driver's internals.
- `TypeDB.ConceptRow.to_struct/2` — builds a struct from a row, raising on a
  variable that names no field. `Kernel.struct/2` silently returns the struct's
  defaults there, which the `to_map/1` docs previously warned about at length
  instead of solving.
- An API snapshot test. `test/api_snapshot.txt` records the whole published
  surface and the suite fails when the code and the file disagree, so a SemVer
  decision is forced at the moment the API changes rather than at release.
- A versioning policy in CONTRIBUTING: what the version number covers —
  telemetry event names and metadata keys, error kinds, the option set and its
  defaults, the transport behaviour — and what it does not.

### Changed

- **The default backoff is jittered.** `{:exponential, base}` now draws
  uniformly from `0..base * 2 ** (n - 1)` instead of returning that value
  exactly, so callers that failed together no longer retry together. Pass a
  function to `:retry_backoff` for a delay you can predict.
- **Retry eligibility is decided per operation, not per HTTP method.** Read
  queries, opening a `:read` transaction, `analyze`, `rollback`, `close`,
  `Database.create/2` and `User.set_password/3` are now retried; writes, schema
  changes, `commit`, `User.create/3` and opening a `:write` or `:schema`
  transaction are not.
- Retries exhausted and token renewals that fail now log at `:warning`. Both
  were silent.
- `TypeDB.Given` and `TypeDB.Duration.to_iso8601/1` raise `%TypeDB.Error{}` with
  the new kind **`:encode`** rather than `:config`. `:config` means the driver
  was configured wrongly at start-up; these mean an Elixir term has no TypeDB
  wire value. `Error.kind()` gains `:encode`.
- CI now compiles and runs the unit suite on Windows through all three HTTP
  adapters, so the claim that the driver is pure Elixir is proven rather than
  assumed. `mix typedb.check` still wants a POSIX shell there.
- A `decimal` attribute is now stripped of TypeQL's `dec` suffix whether or not
  the optional `Decimal` library is loaded. Without it the fallback used to hand
  back `"12.345dec"` where the `Decimal` path gave `12.345`, so the value
  differed in content, not just in type, depending on which dependencies
  happened to be installed. Found by the new optional-dependency CI job.
- **The supported TypeDB range is now stated as 3.12 or newer**, where the
  README said "3.x". Measured against 3.5.0, the driver does not work at all
  there: `given` rows are rejected, `/v1/servers` does not exist, several error
  codes differ and insert-then-match fails. CI runs the integration suite
  against `3.12.1` and `latest`. The exact floor between 3.5 and 3.12 is not
  established (tdb-vtg.6).
- TypeDB.Transport and TypeDB.Token are internal and no longer published in
  the documentation. They were never meant to be called directly.
- **Five error codes were wrong.** Verified against a live TypeDB 3.12.1 and
  corrected in the stub, the unit tests and the documentation: opening a
  transaction on an unknown database answers `400 SRV3` (not `404 TSV2`);
  committing a read transaction answers `400 TSV2` (not `400 TSV3`); any
  operation on a finished transaction answers `404 TSV12` (not `404 TSV11`);
  `/v1/databases/{name}/schema` on an unknown database answers `404 SRV3` (not
  `404 SRV5`); and a one-shot query on an unknown database answers `400 SRV3`.
  Code matching on any of the old values must change.
- `TypeDB.transaction/5` no longer rolls back a failed `:read` block. TypeDB
  rejects that with `400 TSV3`, so it was a wasted round trip; the transaction
  is closed instead, and its telemetry `:outcome` is `:close`.
- `TypeDB.Transaction.open/4` raises `ArgumentError` naming the bad transaction
  type and the three accepted ones, where it raised `FunctionClauseError`.
- `Exception.message/1` on a `%TypeDB.Error{}` now includes the HTTP status:
  `[server 404] TSV2: Database not found.` The rendered form is what reaches a
  log line and an exit reason, where nobody has the struct to inspect. Message
  text remains outside SemVer — match on `:kind` and `:code`.

## [0.1.0] - 2026-07-31

Initial release. Complete coverage of the TypeDB HTTP API v1, verified against
TypeDB 3.12.1 on Elixir 1.20 / OTP 29.

### Added

- `TypeDB` — connection supervision, one-shot queries and bracketed transactions.
- `TypeDB.Connection` — lazy sign-in, transparent token renewal bounded by
  `:max_auth_renewals`, and per-connection configuration held in a
  read-concurrent ETS table so requests run in the caller's process.
- `TypeDB.Database` — list, get, create, create-if-not-exists, delete, schema
  and type-schema. `exists?/2` raises rather than answering `false` when it
  could not reach the server, since `false` is the answer that makes a caller
  create something that already exists.
- `TypeDB.User` — list, get, create, set password, delete.
- `TypeDB.Server` — health, version and cluster membership.
- `TypeDB.Transaction` — explicit `:read`, `:write` and `:schema` transactions
  with `query/3`, `analyze/3`, `commit/2`, `rollback/2` and idempotent
  `close/2`, each taking its own `:timeout`.
- `TypeDB.Answer` — `Ok`, `ConceptRows` and `ConceptDocuments`; the latter two
  are `Enumerable`.
- `TypeDB.ConceptRow` — `Access`-backed rows, plus `value/2`, `typed_value/2` and
  `to_map/1`.
- `TypeDB.Concept` — structs for entities, relations, attributes, values and
  every type kind, with conversion of TypeDB values to native Elixir terms.
- `TypeDB.Duration` and `TypeDB.DateTimeTZ` — lossless representations of
  TypeDB's `duration` and `datetime-tz` values, keeping the original wire string
  so TypeDB's nanosecond precision survives conversion to Elixir's coarser
  types. `DateTimeTZ.new/2` builds one for writing, from a `NaiveDateTime` plus
  an IANA zone name or a UTC offset.
- `TypeDB.Options` — transaction and query options.
- `TypeDB.Given` — encodes input rows for TypeQL's `given` stage into TypeDB's
  tagged wire form, making parameterised queries safe against TypeQL injection
  for arbitrary input. The API's raw-JSON form is not: TypeDB parses a bare
  string as a TypeQL literal, so a value containing a quote is a parse error.
- `TypeDB.Error` — a single exception type carrying TypeDB's stable error codes.
  Every function that can fail has both a `{:ok, _} | {:error, %TypeDB.Error{}}`
  form and a `!` form that raises, except `TypeDB.transaction/5`, which returns
  the block's own value.
- `TypeDB.HTTP` — a transport behaviour with three adapters: `TypeDB.HTTP.Finch`
  (the default, a Finch pool per connection), `TypeDB.HTTP.Req` for applications
  already running Finch through Req, and `TypeDB.HTTP.Httpc` for deployments that
  must run on OTP alone. All three verify TLS by default and are covered by the
  same test suite.
- TypeDB.Transport — request building, retries and response decoding, split out
  of the connection process.
- TypeDB.Token — reads a token's lifetime from its JWT claims so the driver can
  renew before expiry instead of discovering it from a `401`.
- `TypeDB.Telemetry` — `[:typedb, :request, …]` and `[:typedb, :sign_in, …]`
  spans. Logging is deliberately sparse and carries `:typedb_connection` in its
  Logger metadata; see the "Logging" section of `TypeDB`.
- `TypeDB.JSON` — a codec behaviour resolving to the built-in `JSON`, to `Jason`,
  or to a codec you configure.
- `mix typedb.check` — validates `.tql` files with TypeDB's `typeql-check` CLI.

### Verified under load

- 200-way concurrent bursts, concurrent writes and long transactions straddling
  token expiry, against servers configured with one- and five-second token
  lifetimes: no failures, no lost writes. Renewals coalesce into a single sign-in
  per generation, and `:max_auth_renewals` bounds how many times one request will
  renew before giving up.
- Transport throughput measured against a local TypeDB 3.12.1, 400 requests per
  run: Finch sustains ~1900 req/s at 200-way concurrency where `:httpc` manages
  77 with multi-second tail latency. Finch is the default for that reason.

### Verified against

- TypeDB 3.12.1 (HTTP API v1) on Elixir 1.20.2 / OTP 29, including an opt-in
  suite that checks the TLS defaults against a server started with
  `--server.encryption.enabled`.

[Unreleased]: https://github.com/NoeticEcho/TypedbEx/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/NoeticEcho/TypedbEx/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/NoeticEcho/TypedbEx/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/NoeticEcho/TypedbEx/releases/tag/v0.1.0
