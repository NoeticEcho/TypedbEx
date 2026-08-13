# TypedbEx

TypeDB 3.x drivers for Elixir. Two packages, one repository.

| package | transport | when to reach for it |
| --- | --- | --- |
| [`typedb`](typedb/) | HTTP API v1 | one dependency, works through anything that speaks HTTP/1.1, debuggable with `curl` |
| [`typedb_grpc`](typedb_grpc/) | gRPC | large reads, long transactions with many operations, no answer cap, database export and import |

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
| 50 000 answers, streamed | not possible | **753 ms**, no memory retained | — |
| 1 000 writes in one transaction | 861 ms | **622 ms** | gRPC 1.4× |
| 200 reads pipelined in one transaction | not possible | **47 ms** | — |
| 200 independent point reads | **213 ms** | 249 ms | HTTP 1.17× |

The last row is the shape a request-serving application has, and gRPC loses it:
the protocol has no one-shot query, so every independent query pays to set up a
transaction stream. The first rows are the shape a batch job has, and HTTP loses
them — it materialises one answer, caps it at 10 000, and spends a third of the
wall clock turning JSON into terms.

Pipelining is the third row and it is **reads only**. TypeDB aborts a write's
answer stream when the next write in the same transaction starts, with `TSV13`,
so writes go one at a time — which is what the second row measures.

Export and import are the difference that is not a difference in degree.
TypeDB's HTTP API has no endpoint for either — `/v1/databases/x/export` answers
404 to a token that gets 200 from `/schema` — so a graph written through
`typedb` can only be read back by replaying whatever the application logged.
`typedb_grpc` writes the schema as TypeQL and the data as TypeDB's own binary
format: dumps taken by `typedb console` restore through the driver, dumps taken
by the driver restore through the console, and the two are byte-identical.

The cap is the other difference that is not about speed. TypeDB's own
`answerCountLimit` exists only in the HTTP API; over gRPC answers arrive as a
flow-controlled stream with no ceiling to raise — and `TypeDB.GRPC.stream/4`
hands that stream to the caller, asking the server for the next batch only when
the consumer wants it. The same 50 000 rows collected into a list retain 80 MiB
and take 1439 ms; streamed they retain nothing and take 753 ms, and
`Enum.take(5)` over them costs one batch rather than all of it.

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
pass before a commit, [`typedb_grpc/CONTRIBUTING.md`](typedb_grpc/CONTRIBUTING.md)
for what is different about the second package — including how it was first
published to hex.pm — and [`AUDIT.md`](AUDIT.md) for the state of the code and
why several things are the way they are.

## Releasing

Two packages in one repository cannot both answer to `v*`, so the tags are
prefixed:

| package | tag | workflow |
| --- | --- | --- |
| `typedb` | `v0.9.0` | `.github/workflows/release.yml` |
| `typedb_grpc` | `typedb_grpc-v0.1.0` | `.github/workflows/release-grpc.yml` |

CI runs each package's gate separately, and one job on top of both: the shared
behaviour suite, against a server that speaks HTTP and gRPC at once. That job is
the reason these two live together.

## License

Apache-2.0. See [LICENSE](LICENSE).
