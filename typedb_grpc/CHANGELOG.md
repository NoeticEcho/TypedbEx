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
    one taken here are byte-identical, and each restores through the other.
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

Nothing released yet. The package is being built; see the repository's
`AUDIT.md` and the `Монорепо и gRPC-драйвер` epic in `bd` for what is done and
what is not.
