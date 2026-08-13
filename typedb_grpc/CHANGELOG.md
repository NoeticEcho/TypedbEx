# Changelog

All notable changes to this package are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Telemetry, a TLS suite, and Audit V — the package's first, which found nine
things including two critical ones that every existing test was blind to:
`datetime-tz` decoded to a different type *and* a different instant than the
sibling, and two processes sharing one transaction handle lost one of them.
Both are fixed, with tests that fail when the defect is put back.

Then the four things neither driver had:

  * **Database export and import.** `Database.export_to_files/5` and
    `import_from_files/5`, plus `TypeDB.GRPC.export_database/5` and
    `import_database/5`. The capability the HTTP API does not have at all, and
    the strongest reason to have this package beyond speed. The files are
    TypeDB's own format, not this driver's: a dump taken by `typedb console` and
    one taken here are byte-identical, and each restores through the other —
    checked on every push by CI's `grpc_migration_interop` job, over a database
    holding every value type TypeDB has.
  * **`connection_open`.** The RPC every official driver makes first and this one
    skipped, going straight to `authentication_token_create`. The first sign-in
    is now the open — no extra round trip, since the open carries the token — so
    the server sees the protocol version and refuses an incompatible driver
    itself, and `Connection.connection_id/1` reports the id the server logs.
    Renewals stay on the plain token call.
  * **`Transaction.analyze/3`**, the sibling's since 0.x, wired here at last. The
    rendering follows the HTTP API's conventions where that costs nothing, and
    the docs say plainly where the two trees still differ.
  * **`Server.servers/2` and `server/2`**, in the shape the sibling's `/servers`
    returns.

Then a pass against the Rust driver, taken as the reference for coverage:

  * **`tls: true` now verifies against the machine's trust store.** It could not
    connect to a server with a publicly-signed certificate before, because
    `:ssl` has no default store — measured, not assumed. `:tls_root_ca` names a
    private CA's PEM file, and `:tls_opts` still overrides both.
  * **`include_query_structure`**, with the analysed pipeline on
    `%TypeDB.Answer.ConceptRows{}` and `involved_blocks` on each row — the
    sibling has had it since 0.x; this side ignored the option and dropped the
    header the server was already sending.
  * **`User.get/3` and `User.current/2`**, and **`Database.get/3`** — absence as
    an error carrying the server's code, rather than a boolean.
  * **No `on_close` callback**, deliberately: a transaction is a process, so
    `Process.monitor(tx.pid)` is the answer, and `TypeDB.GRPC.Transaction`'s docs
    explain why it is the better one.

Nothing released yet. The package is being built; see the repository's
`AUDIT.md` and the `Монорепо и gRPC-драйвер` epic in `bd` for what is done and
what is not.
