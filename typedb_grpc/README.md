# TypeDB over gRPC, for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/typedb_grpc.svg)](https://hex.pm/packages/typedb_grpc)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/typedb_grpc)
[![License](https://img.shields.io/hexpm/l/typedb_grpc.svg)](LICENSE)

A driver for TypeDB 3.12+ built on the gRPC API — the protocol TypeDB's own
Rust, Java, Python and Node drivers speak.

It is the sibling of [`typedb`](https://hex.pm/packages/typedb), which speaks
the HTTP API, and it depends on it: concepts decode into the same
`TypeDB.Concept` structs and failures arrive as the same `%TypeDB.Error{}`. An
application switching transports changes the module it calls, not the code that
reads what comes back.

## Why this one

Three things the HTTP API cannot do. The first is a capability it does not have
at all; the other two are measured against TypeDB 3.12.1 with driver and server
on the same machine.

**A database can be exported and imported.** TypeDB's HTTP API has no such
endpoint — `/v1/databases/x/export` answers 404 with a token that gets 200 from
`/schema` — so a graph written through the sibling can only be read back by
replaying whatever the application logged. Here the server streams the schema
and then every entity, attribute and relation:

```elixir
:ok = TypeDB.GRPC.export_database(conn, "social", "social.tql", "social.data")
:ok = TypeDB.GRPC.import_database(conn, "social_restored", "social.tql", "social.data")
```

The files are TypeDB's own, not this driver's: exporting the same database with
`typedb console` produces byte-identical data, and dumps move in both
directions. Nothing is held in memory on either side.

**Answers stream, with no ceiling.** TypeDB's `answerCountLimit` exists only in
the HTTP API; over gRPC answers arrive in flow-controlled parts and there is no
cap to raise. A read of 20 000 answers takes 248 ms here against 1004 ms over
HTTP — and over HTTP only after raising the limit, since the default truncates
at 10 000 and sets a warning.

`TypeDB.GRPC.stream/4` gives that stream to the caller rather than collecting
it:

```elixir
TypeDB.GRPC.stream(conn, "social", "match $p isa person, has name $n; select $n;")
|> Stream.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
|> Enum.each(&IO.puts/1)
```

The continuation signal TypeDB waits on is sent by the consumer's demand, so
50 000 rows stream in 753 ms retaining nothing where collecting them costs
1439 ms and 80 MiB — and `Enum.take(5)` reads one batch rather than all of it.

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
    {:typedb_grpc, "~> 0.1.0"}
  ]
end
```

`typedb` comes with it.

## Quick start

Add a connection to your supervision tree — it validates the options and starts
the process, and does **not** contact the server, so your application boots
whether or not TypeDB is up yet:

```elixir
children = [
  {TypeDB.GRPC,
   name: :graph,
   address: "127.0.0.1:1729",
   username: "admin",
   password: System.fetch_env!("TYPEDB_PASSWORD")}
]
```

`url: "https://typedb.example.com"` works too, and turns TLS on because the
scheme says so.

```elixir
:ok = TypeDB.GRPC.create_database(:graph, "social")

{:ok, _} =
  TypeDB.GRPC.query(:graph, "social", """
    define
      attribute name, value string;
      entity person, owns name;
  """)

{:ok, _} =
  TypeDB.GRPC.query(:graph, "social", "given $n: string; insert $p isa person, has name == $n;",
    transaction_type: :write,
    given_rows: [%{"n" => "Alice"}, %{"n" => "Bo"}]
  )

TypeDB.GRPC.stream(:graph, "social", "match $p isa person, has name $n; select $n;")
|> Stream.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
|> Enum.each(&IO.puts/1)
```

`given_rows` is how a value reaches a query without being spliced into its text,
and it is the only way this driver offers — a value can never be read as syntax.

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
