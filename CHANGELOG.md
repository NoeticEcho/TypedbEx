# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-31

Initial release. Complete coverage of the TypeDB HTTP API v1, verified against
TypeDB 3.12.1 on Elixir 1.20 / OTP 29.

### Added

- `TypeDB` — connection supervision, one-shot queries and bracketed transactions.
- `TypeDB.Connection` — lazy sign-in, transparent token renewal with a single
  retry, and per-connection configuration held in a read-concurrent ETS table so
  requests run in the caller's process.
- `TypeDB.Database` — list, get, create, create-if-not-exists, delete, schema and
  type-schema.
- `TypeDB.User` — list, get, create, set password, delete.
- `TypeDB.Server` — health, version and cluster membership.
- `TypeDB.Transaction` — explicit `:read`, `:write` and `:schema` transactions
  with `query/3`, `analyze/3`, `commit/1`, `rollback/1` and idempotent `close/1`.
- `TypeDB.Answer` — `Ok`, `ConceptRows` and `ConceptDocuments`, all `Enumerable`.
- `TypeDB.ConceptRow` — `Access`-backed rows, plus `value/2`, `typed_value/2` and
  `to_map/1`.
- `TypeDB.Concept` — structs for entities, relations, attributes, values and
  every type kind, with conversion of TypeDB values to native Elixir terms.
- `TypeDB.Duration` and `TypeDB.DateTimeTZ` — lossless representations of
  TypeDB's `duration` and `datetime-tz` values.
- `TypeDB.Options` — transaction and query options.
- `TypeDB.Given` — encodes input rows for TypeQL's `given` stage into TypeDB's
  tagged wire form, making parameterised queries safe against TypeQL injection
  for arbitrary input. The API's raw-JSON form is not: TypeDB parses a bare
  string as a TypeQL literal, so a value containing a quote is a parse error.
- `TypeDB.Error` — a single exception type carrying TypeDB's stable error codes.
- `TypeDB.HTTP` — a transport behaviour, with a dependency-free `:httpc` adapter
  (secure TLS defaults, isolated connection pool) and an optional `Req` adapter.
- `TypeDB.JSON` — a codec behaviour resolving to the built-in `JSON`, to `Jason`,
  or to a codec you configure.
- `mix typedb.check` — validates `.tql` files with TypeDB's `typeql-check` CLI.

### Verified under load

- 200-way concurrent bursts, concurrent writes and long transactions straddling
  token expiry, against a server configured with a five-second token lifetime.
  Renewals coalesce into a single sign-in per generation, and `:max_auth_renewals`
  bounds how many times one request will renew before giving up.

### Verified against

- TypeDB 3.12.1 (HTTP API v1) on Elixir 1.20.2 / OTP 29, including an opt-in
  suite that checks the TLS defaults against a server started with
  `--server.encryption.enabled`.

[0.1.0]: https://github.com/NoeticEcho/TypedbEx/releases/tag/v0.1.0
