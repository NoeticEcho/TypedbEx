# Contributing

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
mix typedb.check          # validates priv/**/*.tql, needs the typeql-check CLI
```

## Fidelity to the server

The stub in `test/support/` is only useful while it behaves like TypeDB. Where
its behaviour is not the obvious guess, it carries a comment naming the version
it was checked against — for example, creating a database that already exists
succeeds, while deleting one that does not exist fails; closing an unknown
transaction succeeds, while committing one does not.

If you change the stub to make a test pass, check the real server first and
record what you found.

## Releasing

1. Update `@version` in `mix.exs` and add a `CHANGELOG.md` entry.
2. `mix hex.build` and read the file list.
3. Tag `vX.Y.Z` and push it. The release workflow verifies the tag against
   `mix.exs`, runs the tests, and publishes to hex.pm using the `HEX_API_KEY`
   secret.

To publish by hand instead:

```shell
mix hex.publish
```

Documentation is built by `ex_doc` and published to hexdocs.pm as part of that
step.
