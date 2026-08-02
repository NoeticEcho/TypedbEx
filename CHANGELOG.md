# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-08-02

The driver has checked option *names* since 0.3.0 and their *values* not at all,
while `TypeDB.Config` had been checking the same values at start-up since 0.1.0.
The two levels now agree. No public API changed — `test/api_snapshot.txt` is
byte for byte 0.4.3's — but code that passes a value the driver's own typespecs
forbid will now hear about it, so this is a minor.

### Upgrading from 0.4.3

One change can be noticed by working code. `answer_count_limit: 0`,
`timeout: "5000"`, `commit: "true"` — anything whose *value* the option cannot
take — now raises `ArgumentError` where it used to reach the server and come
back as `400 HSR2`, or worse, quietly succeed. `nil` still means "unset" and is
accepted everywhere, so `answer_count_limit: maybe_a_limit` is unaffected. Run
your tests.

### Changed

- **A per-call option *value* the option cannot take now raises
  `ArgumentError`.** Since 0.3.0 the driver has checked option *names* per
  call; their values still travelled to the server unchecked, while
  `TypeDB.Config` had rejected the same values at start-up since 0.1.0. So
  `answer_count_limit: 0` came back as an empty answer, and `-1`, `"10"` and
  `1.5` came back as `400 HSR2` — the request-parse code, the same one an
  oversized body gets, naming no option at all. `transaction_timeout_millis: 0`
  opened a transaction.

  `:answer_count_limit`, `:transaction_timeout_millis`,
  `:schema_lock_acquire_timeout_millis`, `:timeout`, `:deadline`, `:commit`,
  `:include_instance_types` and `:include_query_structure` are now checked
  against the same rules `TypeDB.Config` uses, and a test drives both levels
  through the same values so they cannot drift apart again. `nil` means "unset"
  everywhere and is accepted — `answer_count_limit: maybe_a_limit` keeps
  working.

  Code passing a value the driver's own typespecs already forbade will now hear
  about it, which is why this is a minor rather than a patch.

## [0.4.3] - 2026-08-02

0.4.2's new recipes guide told people to bulk load in batches of 2,000 rows.
The real limit is on bytes, and a batch of 2,000 can exceed it. The only change
under `lib/` is six lines of `@doc`; `test/api_snapshot.txt` is byte for byte
0.4.2's.

### Fixed

- **TypeDB refuses a request body over 2 MiB**, and nothing said so. Bisected
  against 3.12.1: 2047 KiB is accepted, 2048 KiB is not, and there is no server
  flag for it. The bulk-load recipe now batches by payload size rather than row
  count — the ceiling is bytes, so 2,000 rows of two short attributes is 620 KiB
  and fine while the same 2,000 rows carrying a kilobyte of text each is not —
  and an integration test pins the boundary either side.

  The failure has two shapes, which is the part worth knowing: a body a little
  over the line comes back as `400 HSR2`, while one far over it makes the server
  close the socket, so the driver reports `:transport` — which `retryable?/1`
  calls retryable and `:max_retries` will re-send. The driver cannot tell that
  apart from a network blip, so the guides say it instead: a bulk load that
  reproducibly "times out" is a batch that is too big.

## [0.4.2] - 2026-08-02

Documentation and CI. Not one line under `lib/` changed, and
`test/api_snapshot.txt` is byte for byte 0.4.1's — the release exists because
the package ships its guides, and there is a new one worth having.

### Added

- A fifth guide, [Recipes](guides/recipes.md): paging a `match` bigger than
  TypeDB's 10,000-answer cap (and why `sort` is not optional there), streaming
  a whole result set, bulk loading, upsert and why `put` is not one, counting
  without fetching, deleting in batches, mapping rows onto your own structs,
  and a schema migration that can run on every boot. The other four guides
  explain how the driver behaves; this one is what an application has to work
  out for itself.

  Every recipe was run against a live TypeDB 3.12.1 and carries that run's
  numbers — 20,000 rows loaded in 2468ms, streamed back in pages of 1,000 in
  1019ms, deleted in 1447ms. A new integration test executes the same queries,
  because parsing a guide is not running it and a `sort` clause that stops
  being accepted parses perfectly.
- CI runs the token-renewal and TLS suites. Both verify headline claims —
  tokens renewed before they expire, and TLS verification on by default — and
  neither had ever run outside somebody's terminal, because a GitHub Actions
  service container cannot be given the server flags they need. Their jobs
  start TypeDB with `docker run` instead: one with a five-second token
  lifetime, one with encryption enabled and a CA minted in the job. The TLS
  job also adds the extra hostname the mismatch test needs, so that assertion
  stops skipping itself, and runs all three adapters.

### Fixed

- The TLS suite's hostname-mismatch test failed with "Expected truthy, got
  false" when the extra hostname did not resolve — testing DNS rather than TLS
  and saying nothing about which. It now names the real problem. Found by
  running the suite on a machine that had lost its `/etc/hosts` entry.

## [0.4.1] - 2026-08-02

A crash on the way out, and the test suite that should have found it. No public
API change — `test/api_snapshot.txt` is byte for byte 0.4.0's.

### Added

- An adapter parity suite: the same seven odd-but-legal server responses —
  a redirect, a `204`, a mis-cased header, a duplicated one, JSON under the
  wrong content type, a `503` with a TypeDB error body, an empty `200` — put
  through all three adapters, asserting they answer identically. The head-of-
  line bug in 0.4.0 survived three releases because each adapter was only ever
  exercised against a well-behaved server. Verified to catch a real divergence
  by turning Req's redirect following back on.

### Fixed

- **Stopping a connection could crash it.** `TypeDB.HTTP.Finch.terminate/1`
  stops the pool's supervisor and caught exits, and on OTP 29
  `Supervisor.stop/3` can *raise* instead: `proc_lib:stop/3` computes the
  remaining timeout after `sys:terminate` returns, and a value at or below zero
  reaches `receive … after NegativeTimeout`, which raises `ErlangError
  :timeout_value`. Seen while stopping several connections at once against
  sockets that were not answering — a crash report from a process that had been
  asked to stop.

  The adapter now catches errors as well as exits, and `TypeDB.Connection`
  contains anything an adapter's `terminate/1` does, since `TypeDB.HTTP` is a
  public extension point and shutdown is the last place a third-party fault
  should be able to matter. Covered by a test adapter that raises, throws,
  exits and errors on the way out.

## [0.4.0] - 2026-08-02

One bug, and it is the one that matters most: the driver's central claim —
requests run in the calling process, so N processes issue N concurrent
requests — was true of two HTTP adapters out of three.

A minor rather than a patch because the fix changes an option's default, which
this project counts as breaking whatever the option is. No public API changed;
`test/api_snapshot.txt` is byte for byte 0.3.1's.

### Upgrading from 0.3.1

Nothing to do unless you set `:max_keep_alive_length` on `TypeDB.HTTP.Httpc`
yourself. Its default is now `0` rather than `100`, and if you had raised it
deliberately, read the entry below before setting it back.

### Fixed

- **Under `:httpc`, one slow query stalled every other request on the
  connection.** The adapter let `:httpc` queue up to 100 requests onto a socket
  that was already busy, and `:httpc` prefers an existing session to opening
  another *even while it is in flight* — so a query TypeDB was slow to answer
  held up everything behind it. Measured against 3.12.1 with a `:schema`
  transaction held for 500ms: under Finch the waiting one-shot took 503ms and a
  concurrent `:read` took 2ms, while under `:httpc` both sat until the request
  timeout and the waiting one failed outright. That made "N processes issue N
  concurrent requests" true of two adapters out of three.

  `:max_keep_alive_length` now defaults to `0`, so a busy socket is never
  queued behind: `:httpc` opens another, bounded by `:max_sessions`. It costs
  nothing — sequential throughput is unchanged and concurrent throughput
  improved, 437 req/s against 368 at 64-way with less than half the p99 — and
  the suite now runs a slow-request-beside-a-fast-one test against all three
  adapters. Raising the option above `0` is now documented as a decision about
  head-of-line blocking rather than a tuning knob.

### Added

- `bench/given.exs`, so "a `given` stage is the fast way to write many rows"
  has a number rather than a plausible argument. 2,000 rows against a local
  server: 101ms with `given_rows`, 1541ms for a single request whose query text
  carries 2,000 `insert` statements, 8830ms for 2,000 requests. The middle one
  is the honest competitor, since it is also one round trip — so the 15×
  between them is query compilation, and it widens with the row count.
- An integration test for the `:schema` default's exclusive lock — the likeliest
  performance mistake a new user makes, warned about in two places and checked
  in none. Holding a `:schema` transaction open makes a one-shot query on the
  default wait for it, while a one-shot `:read` does not notice.

## [0.3.1] - 2026-08-02

A correctness fix in the documentation, which is where this one lived: the
README told people TypeDB does not cap answer counts, and it caps at 10,000.
No public API changed — `test/api_snapshot.txt` is byte for byte 0.3.0's — so
this is a patch, with one new log line as the only behaviour change.

### Added

- The driver now logs a `:warning` when TypeDB attaches a warning to an answer,
  which in practice means "your read was truncated". It honours `:log_level`
  like every other line, and the text is passed through rather than
  interpreted — a warning is prose, not an error code.
- `bench/answer_size.exs`, so "answers arrive whole" has a number: for rows of
  two attributes, 488 bytes on the wire and 897 decoded, per row.
- A README section on where credentials live: the password and a pre-issued
  token stay in the connection process and reach no log line, crash report or
  telemetry event; the bearer token TypeDB issues is in the connection's
  `:protected` ETS table by design, because requests run in the caller's
  process. A new test asserts no telemetry event carries either.

### Fixed

- **The README said "TypeDB applies no cap of its own" on answer counts. It
  caps at 10,000.** A `match` over 20,000 entities returns exactly 10,000 rows
  and a warning; `reduce $n = count` over the same data says 20,000. There is no
  server flag for it, so `:answer_count_limit` is the only control — and nothing
  said that it *raises* the ceiling as well as lowering it. Anyone who read that
  sentence, ran an unbounded `match` and counted the result was silently missing
  every row past the ten-thousandth. Corrected in the README, `TypeDB.Config`
  and `TypeDB.Options`, and pinned by an integration test that inserts 12,000
  entities and checks all three behaviours against a live server.
- The retry example in [Testing an application](guides/testing.md) did not
  retry. Its adapter fails the first two requests and the text claimed that
  "two failures then a success exercises the retry path end to end", but
  `:max_retries` defaults to `1`, so the published example demonstrated the
  give-up path while saying it demonstrated the other one. It now sets
  `max_retries: 2`, and the suite compiles the guide's own adapter and runs
  both outcomes through it, so the claim cannot rot back.
- Every `elixir` block in every guide and in the README is now parsed by the
  test suite, as the notebook's already was. Nothing compiles a guide, which
  makes prose edited into code invisible until a reader hits it.

## [0.3.0] - 2026-08-02

What using it finds. Everything here came from installing the published 0.2.2
package into an application that is not this repository and writing ordinary
code against it: a typo that did nothing, a documented example that raised, and
a retry helper that said no to the one error it exists for.

### Upgrading from 0.2.2

One change can be noticed by working code. **An option a function does not
accept now raises `ArgumentError`** instead of being ignored. If a call passes
a key that was quietly doing nothing, it will now say so — which is the point,
but it is a compile-clean change that fails at runtime, so run your tests.

Everything else is additive.

### Added

- `TypeDB.ConceptRow.to_typed_map/1`, and `typed: true` on
  `TypeDB.ConceptRow.to_struct/3`. `typed_value/2` returned a `Decimal`, a
  `TypeDB.Duration` or a `NaiveDateTime` one variable at a time; the two
  functions that convert a whole row returned the wire string, so the same row
  read natively or not depending on which you reached for. `to_map/1` is
  unchanged — it is the wire form on purpose, and now says so.

### Changed

- **A per-call option the driver does not accept now raises `ArgumentError`.**
  It used to be dropped in silence and the default applied, so `commmit: false`
  committed and `given: [...]` — for `given_rows: [...]` — ran the query with no
  rows at all, which surfaces as a server-side complaint about a variable being
  both an attribute and a value and names nothing that leads you to the typo.
  `TypeDB.Config` has rejected unknown *connection* options since 0.1.0 with
  this exact reasoning; this is the rest of the surface: `TypeDB.query/4`,
  `TypeDB.transaction/5`, and `TypeDB.Transaction.open/4`, `query/3`,
  `analyze/3`, `commit/2`, `rollback/2` and `close/2`. Found by running the
  published 0.2.2 package from an application that is not this repository.

  Code passing a stray option starts failing, which is the point — but it is a
  behaviour change, so it lands in a minor rather than a patch.

### Fixed

- **`TypeDB.Error.retryable?/1` said `false` for an isolation conflict**, which
  is the failure its own documentation is about. Two concurrent `:write`
  transactions touching the same data end with the loser's commit rejected as
  `400 STC2`, and a `400` was otherwise the driver's signal that a request will
  fail identically forever — so a caller following the documented retry loop
  gave up on precisely the error that re-running fixes. `retryable_codes/0` is
  the new list of codes that override the status, pinned by an integration test
  that provokes a real conflict against a live server rather than asserting the
  code from the stub.
- `TypeDB.ConceptRow.to_struct/3`'s documented example raised: its `match` binds
  the entity variable `$p`, which names no field of the struct. The example now
  carries the `select` stage that makes it true, the docs say why it is not
  optional, and the `ArgumentError` names `select` as the fix.
- `TypeDB.Transaction.query/3`'s docs said an unencodable `:given_rows` value
  raises kind `:config`. It has raised `:encode` since 0.2.0.

## [0.2.2] - 2026-08-01

Evidence. Every number this file publishes is now produced by a script in the
repository, the supported TypeDB floor was measured instead of assumed, and the
tests that found the three fixes below did not exist a release ago. No public
API changed — `test/api_snapshot.txt` is byte for byte the one 0.2.1 shipped.

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
  TypeDB in this project's container — 400 requests per run, warm pool, a
  one-row `match`. At 200-way concurrency Finch sustains ~1820 req/s and Req
  ~1640, both with a p99 under 130ms; `:httpc` manages ~375 req/s at a p99 of
  685ms. The README's table is these numbers, and now names the script that
  produced them. 0.1.0 published 77 req/s for `:httpc` at 200-way, which did
  not reproduce; the ratio is the finding and it holds, the absolute numbers
  are a property of whatever machine you run them on.

### Fixed

- `TypeDB.Transaction.analyze/3` returned `{:ok, :ok}` for a 200 with an empty
  body, where its spec promises `{:ok, map()}`. It now rejects a payload that is
  not a structure. Found by the fault matrix. (`analyze/3`'s return is the one
  documented SemVer exemption, which is why this is a patch.)
- `TypeDB.Duration.parse/1` ran a regular expression once per component, and
  its trailing `(.*)` copied the rest of the string each time. It cost 16µs a
  duration where every other cast costs under half a microsecond. Scanning the
  number's length and slicing brings it to 1.6µs — ten times faster, for the
  same values: checked by re-parsing 200,000 generated durations, well-formed
  and malformed, through both implementations.
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

[Unreleased]: https://github.com/NoeticEcho/TypedbEx/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/NoeticEcho/TypedbEx/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/NoeticEcho/TypedbEx/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/NoeticEcho/TypedbEx/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/NoeticEcho/TypedbEx/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/NoeticEcho/TypedbEx/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/NoeticEcho/TypedbEx/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/NoeticEcho/TypedbEx/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/NoeticEcho/TypedbEx/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/NoeticEcho/TypedbEx/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/NoeticEcho/TypedbEx/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/NoeticEcho/TypedbEx/releases/tag/v0.1.0
