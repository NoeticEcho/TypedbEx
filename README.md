# TypedbEx

TypeDB 3.x drivers for Elixir. Two packages, one repository.

| package | transport | when to reach for it |
| --- | --- | --- |
| [`typedb`](typedb/) | HTTP API v1 | one dependency, works through anything that speaks HTTP/1.1, debuggable with `curl` |
| [`typedb_grpc`](typedb_grpc/) | gRPC | large reads, long transactions with many operations, no answer cap |

Both decode into the same `TypeDB.Concept` structs and fail with the same
`%TypeDB.Error{}`, so which one an application uses is a line in its data-access
module rather than a rewrite of everything above it. `typedb_grpc` depends on
`typedb` for exactly that reason.

## Which one

Neither is a strict improvement on the other; that is why both exist. Measured
against TypeDB 3.12.1 on one machine, driver and server on loopback:

| workload | `typedb` | `typedb_grpc` | |
| --- | ---: | ---: | --- |
| 20 000 answers in one read | 1004 ms | **248 ms** | gRPC 4× |
| 1 000 operations in one transaction | 861 ms | **141 ms** | gRPC 6.1× |
| 200 independent point reads | **213 ms** | 249 ms | HTTP 1.17× |

The last row is the shape a request-serving application has, and gRPC loses it:
the protocol has no one-shot query, so every independent query pays to set up a
transaction stream. The first two are the shape a batch job has, and HTTP loses
them — it materialises one answer, caps it at 10 000, and spends a third of the
wall clock turning JSON into terms.

The cap is the difference that is not about speed. TypeDB's own
`answerCountLimit` exists only in the HTTP API; over gRPC answers arrive as a
flow-controlled stream with no ceiling to raise.

## Working in this repository

Each package is a self-contained Mix project. There is no umbrella and no root
Mix project — `cd` into the one you are working on:

```sh
cd typedb      && mix deps.get && mix test
cd typedb_grpc && mix deps.get && mix test
```

`typedb_grpc` resolves `typedb` as a path dependency during development and as a
version requirement when published, so a change to the shared structs is visible
to both without a release.

See [`typedb/CONTRIBUTING.md`](typedb/CONTRIBUTING.md) for the gate that has to
pass before a commit, and [`AUDIT.md`](AUDIT.md) for the state of the code and
why several things are the way they are.

## License

Apache-2.0. See [LICENSE](LICENSE).
