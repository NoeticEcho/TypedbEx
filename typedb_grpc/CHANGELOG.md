# Changelog

All notable changes to this package are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-30

A minor under the 0.x rule, and for one reason: an error that used to arrive as
`kind: :server` now arrives as `kind: :transport`. No signature changes.

### Changed

- **A gRPC `INTERNAL` carrying no details is now `:transport`, not `:server`.**
  It is what a connection-level protocol failure looks like — the peer hung up,
  TLS did not come up, the stream broke — and TypeDB's own failures always carry
  details, because that is where the `TSVn`/`TQLn` code lives. Classifying the
  empty case as `:server` said "the server considered your request and refused
  it" about a request the server may never have seen.

  It was found as a flaky test, not as a code review: the TLS suite failed about
  one run in four, reproducibly 5 times in 20, because a connection that failed
  during the handshake reported as a server answer. After the change, 25 runs in
  a row are clean.

  **Callers branching on `kind`** — a supervisor that retries `:transport` and
  gives up on `:server`, say — will see this class move, which is the point.
  Callers matching on `code` are unaffected: an `INTERNAL` with no details has no
  code either way.

- **The requirement on `typedb` is pinned to its minor: `~> 0.10.0`.** It was
  `~> 0.8`, which admits every 0.x minor of the sibling — and this repository's
  own rule is that while `typedb` is in 0.x a minor carries anything a 1.x would
  call breaking. This package pattern-matches the sibling's structs, so that is
  precisely the kind of change it would meet. Pinning it means a sibling release
  is a deliberate bump here rather than a silent resolution.

  It also brings in `TypeDB.stream/4`, new in `typedb` 0.10.0.

  The cost of the pin is an ordering rule: **`typedb` has to be on hex.pm before
  this package is tagged**, because until it is, the publishable shape does not
  resolve at all. Written down in CONTRIBUTING and in the release workflow's own
  header, because the thing it costs is a spent tag.

### Fixed

- **Every "source" link in this package's published documentation was a 404**,
  and doubly so: `source_ref` was `v0.1.0`, which is not this package's tag —
  its tags are prefixed `typedb_grpc-v` — and the path lacked the
  `typedb_grpc/` subdirectory that a two-package repository puts it behind.
  `test/typedb/grpc/release_test.exs` fails now if either regresses.

### Documentation

- **The comparison against the HTTP sibling is honest about `stream/4`.** The
  README's case for this transport included "over HTTP only after raising the
  limit, since the default truncates at 10 000", which was written when the
  sibling had no way past the cap. It has one now. The advantage that remains is
  measured rather than asserted: a real stream with no cap and no per-page round
  trip, against paging inside one transaction.

## [0.1.0] - 2026-08-13

The first release: TypeDB over gRPC, the protocol TypeDB's own Rust, Java,
Python and Node drivers speak.

It is the sibling of [`typedb`](https://hex.pm/packages/typedb) and depends on
it. Concepts decode into the same `TypeDB.Concept` structs and failures arrive
as the same `%TypeDB.Error{}`, so an application that switches transports
changes the module it calls and not the code that reads what comes back — a
claim a shared behaviour suite runs through both drivers on every push rather
than leaving to good intentions.

### Why this transport

Three things the HTTP API cannot do. The first it cannot do at all; the other
two are measured against TypeDB 3.12.1 with driver and server on one machine.

- **A database can be exported and imported.** `Database.export_to_files/5` and
  `import_from_files/5`, plus `TypeDB.GRPC.export_database/5` and
  `import_database/5`. TypeDB's HTTP API has no such endpoint —
  `/v1/databases/x/export` answers 404 to a token that gets 200 from `/schema` —
  so a graph written through the sibling can only be read back by replaying
  whatever the application logged.

  The files are TypeDB's own format, not this driver's: a dump taken by
  `typedb console` and one taken here are **byte-identical**, and each restores
  through the other. CI checks that on every push, over a database holding every
  value type TypeDB has.

- **Answers have no ceiling, and reads can stream.** `answer_count_limit` exists
  only in the HTTP API. `TypeDB.GRPC.stream/4` hands the answer to the caller as
  it arrives and asks the server for the next batch only when the consumer wants
  it: 50 000 rows in 753 ms retaining nothing, against 1439 ms and 80 MiB
  collected. `Enum.take(5)` over them costs one batch.

- **Reads pipeline.** Requests are correlated by `req_id`, so several are in
  flight at once: 200 reads sent together answer in 47 ms. Writes cannot be —
  TypeDB aborts a write's answer stream when the next write in the same
  transaction starts, with `TSV13` — and `Transaction.query_many/3` returns that
  failure rather than committing work the server reported as failed.

### Why not this transport

- **Many small independent queries are slower.** The protocol has no one-shot
  query, so 200 independent point reads take 249 ms here against 213 ms over
  HTTP. That is the shape a request-serving web application has.
- **Hard dependencies.** `grpc`, `protobuf`, `gun` and their transitive
  dependencies, against `typedb`'s single optional one.
- **HTTP/2 end to end.** Anything between the application and TypeDB has to
  speak it.

### The rest of the surface

Databases, users, transactions, `analyze/3`, `include_query_structure`,
`connection_open` with the protocol-version check the server performs itself,
server and cluster listings, telemetry under the same event names as the
sibling with a `:transport` tag, and a `!` twin for every failing function —
enforced mechanically, as in the sibling.

TLS is off by default, matching TypeDB CE, and **`url: "https://…"` turns it
on**. With TLS on, certificates are verified against this machine's trust store
unless `:tls_root_ca` names a private CA; the driver says so once, at start-up,
when it is about to send credentials in clear text to a server that is not on
this machine.

There is deliberately no `on_close` callback: a transaction is a process, so
`Process.monitor(tx.pid)` does the same and more, and
`TypeDB.GRPC.Transaction`'s documentation explains why it is the better answer.

### Known limits

- **No cluster support.** One address, no failover, no routing. TypeDB CE is
  single-node and the machinery cannot be tested against it, which is the
  argument for not shipping it untested.
- **`Value::Struct`** decodes to `{:struct, type_name}` — the type's name and
  not its fields. The protocol carries only the name. Rust returns an error
  here, so this is ahead rather than behind.
- **Raising `:prefetch_size` makes a streamed read slower**, not faster: the
  server produces the whole batch before sending any of it. Measured, and
  documented where the option is.

### Provenance

Two audits before the first release — Audit V of this package and Audit VI of
both — are in the repository's `AUDIT.md`, findings, measurements and one
withdrawn finding included.

[Unreleased]: https://github.com/NoeticEcho/TypedbEx/compare/typedb_grpc-v0.2.0...HEAD
[0.2.0]: https://github.com/NoeticEcho/TypedbEx/compare/typedb_grpc-v0.1.0...typedb_grpc-v0.2.0
[0.1.0]: https://github.com/NoeticEcho/TypedbEx/releases/tag/typedb_grpc-v0.1.0
