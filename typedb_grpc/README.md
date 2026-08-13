# TypeDB over gRPC, for Elixir

A driver for TypeDB 3.12+ built on the gRPC API — the protocol TypeDB's own
Rust, Java, Python and Node drivers speak.

It is the sibling of [`typedb`](https://hex.pm/packages/typedb), which speaks
the HTTP API, and it depends on it: concepts decode into the same
`TypeDB.Concept` structs and failures arrive as the same `%TypeDB.Error{}`. An
application switching transports changes the module it calls, not the code that
reads what comes back.

> **Status: in development.** The public surface is not settled and there is no
> released version yet.

## Why this one

Two things the HTTP API cannot do, both measured against TypeDB 3.12.1 with
driver and server on the same machine.

**Answers stream, with no ceiling.** TypeDB's `answerCountLimit` exists only in
the HTTP API; over gRPC answers arrive in flow-controlled parts and there is no
cap to raise. A read of 20 000 answers takes 248 ms here against 1004 ms over
HTTP — and over HTTP only after raising the limit, since the default truncates
at 10 000 and sets a warning.

**Reads pipeline.** `Transaction.Client` carries a repeated field, so requests
go out without waiting for the previous reply: 200 reads sent together answer in
47 ms. Writes cannot be pipelined — TypeDB aborts a write's answer stream when
the next write in the same transaction starts, with `TSV13` — so they go one at
a time, and a thousand of them in one transaction take 622 ms here against
861 ms over HTTP.

## Why not this one

**Many small independent queries are slower.** The protocol has no one-shot
query — every read goes through a transaction stream — so 200 independent point
reads take 249 ms here against 213 ms over HTTP. That is the shape a
request-serving web application has, and `typedb` is the better fit for it.

**Seven mandatory dependencies against one.** `typedb` needs only `:telemetry`,
and on its `:httpc` adapter runs on OTP alone. This one needs `grpc`,
`protobuf`, `gun` and their transitive dependencies, plus 3 000 lines of
generated protocol modules.

**It needs HTTP/2 end to end.** Anything between the application and TypeDB has
to speak it.

## Installation

```elixir
def deps do
  [
    {:typedb_grpc, "~> 0.1"}
  ]
end
```

`typedb` comes with it.

## The generated protocol modules

`lib/protocol/` is generated from
[typedb-protocol](https://github.com/typedb/typedb-protocol) and committed, so
that installing this package does not require `protoc`. Regenerate with:

```sh
mix escript.install hex protobuf   # once, and put ~/.mix/escripts on PATH
mix typedb.grpc.gen 3.12.0
```

`TypeDB.GRPC.Protocol.version/0` records which version those modules came from,
and the integration suite compares it against the server it is pointed at — so
falling behind is a failing test rather than a decoding bug in an application.

## License

Apache-2.0. See [LICENSE](LICENSE).
