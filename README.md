# TypeDB for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/typedb.svg)](https://hex.pm/packages/typedb)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/typedb)
[![License](https://img.shields.io/hexpm/l/typedb.svg)](LICENSE)

An Elixir driver for [TypeDB](https://typedb.com) 3.x, built on the TypeDB HTTP API.

- **No runtime dependencies.** JSON comes from Elixir's built-in `JSON`; HTTP from OTP's `:httpc`. Swap either out if you'd rather use `Req` or `Jason`.
- **Concurrent by construction.** Requests run in the calling process. The connection process only mints and renews the auth token, so it is never a bottleneck.
- **Tokens handled for you.** Sign-in is lazy, renewal on expiry is transparent, and the request that hit the expired token is retried once.
- **Typed answers.** Concept rows and documents decode into structs, with TypeDB's temporal and decimal types available as native Elixir terms.
- **Errors you can branch on.** Every failure is a `TypeDB.Error` carrying TypeDB's stable error code.

Verified against **TypeDB 3.12.1** on **Elixir 1.20 / OTP 29**.

## Installation

```elixir
def deps do
  [{:typedb, "~> 0.1.0"}]
end
```

Requires Elixir 1.18+ and OTP 25+. JSON is handled by Elixir's built-in `JSON`
module; to route it through a different codec, configure one:

```elixir
config :typedb, :json_codec, TypeDB.JSON.Jason
```

## Quick start

Start a TypeDB server:

```shell
docker compose up -d     # or: typedb server
```

Add a connection to your supervision tree:

```elixir
children = [
  {TypeDB,
   url: "http://localhost:8000",
   username: "admin",
   password: System.fetch_env!("TYPEDB_PASSWORD")}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Define a schema, insert some data, read it back:

```elixir
TypeDB.create_database(TypeDB, "social")

TypeDB.query!(TypeDB, "social", """
  define
    attribute name, value string;
    attribute age, value integer;
    entity person, owns name, owns age;
""")

TypeDB.query!(TypeDB, "social", """
  insert
    $alice isa person, has name "Alice", has age 30;
    $bob isa person, has name "Bob", has age 41;
""")

TypeDB.query!(TypeDB, "social", """
  match $p isa person, has name $name;
  select $name;
""", transaction_type: :read)
|> Enum.map(&TypeDB.ConceptRow.value(&1, "name"))
#=> ["Alice", "Bob"]
```

## Queries

### One-shot

`TypeDB.query/4` runs a query in a transaction of its own — TypeDB opens it, runs
the query, and commits or closes it, all in a single round trip.

```elixir
{:ok, answer} = TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)
```

Reads never commit. Writes and schema changes commit by default; pass
`commit: false` for a dry run.

### Multi-statement transactions

```elixir
TypeDB.transaction(conn, "social", :write, fn tx ->
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Alice";))
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Bob";))
  :ok
end)
```

The block commits on success, and rolls back if it returns `{:error, _}`, raises,
throws or exits. A `:read` block is closed rather than committed.

For a commit point that isn't lexically scoped, drive it yourself with
`TypeDB.Transaction.open/4`, `commit/1`, `rollback/1` and `close/1`.

### Parameterised queries

Never interpolate user input into a query string. TypeQL injection is as real
as SQL injection, and TypeDB 3.12's `given` stage is the fix: values travel
beside the query rather than inside it, so they can never be parsed as TypeQL.

```elixir
TypeDB.query(conn, "social", """
  given $n: string;
  insert $p isa person, has name == $n;
""", given_rows: [%{"n" => "Alice"}, %{"n" => "Bob"}])
```

The pipeline runs once per row, so this is also the fast way to write many rows
— one request and one query compilation instead of N. Declare every input
variable in the `given` stage, marking optional columns with `?`:

```typeql
given $name: string, $age: integer?;
```

Pass plain Elixir terms — strings, numbers, booleans, `Date`, `NaiveDateTime`,
`DateTime`, `TypeDB.DateTimeTZ`, `TypeDB.Duration`, `Decimal`, `nil` for an
unbound optional column — or concepts from an earlier answer, which is how you
bind a `given $p: person;` column:

```elixir
TypeDB.query(conn, "social", """
  given $p: person;
  match $p has name $n;
  select $n;
""", given_rows: [%{"p" => row["p"]}], transaction_type: :read)
```

The driver encodes these into TypeDB's tagged wire form. That matters: the HTTP
API also accepts a bare JSON string, but TypeDB parses *that* as a TypeQL
literal, so a value containing a quote is a parse error. Going through
`given_rows` is exact for any input — quotes, semicolons, newlines — which is
what makes it injection-safe. See `TypeDB.Given`.

### Transaction types

| Type | Use for | Notes |
| --- | --- | --- |
| `:read` | queries | Concurrent, never commits |
| `:write` | data changes | Concurrent; conflicting commits fail at commit time |
| `:schema` | schema changes | Takes an exclusive, database-wide lock |

## Answers

Every query returns one of three shapes:

```elixir
case TypeDB.query!(conn, "social", query) do
  %TypeDB.Answer.ConceptRows{rows: rows} -> rows          # match / insert / update
  %TypeDB.Answer.ConceptDocuments{documents: docs} -> docs # fetch
  %TypeDB.Answer.Ok{} -> :ok                               # define / undefine
end
```

`ConceptRows` and `ConceptDocuments` are `Enumerable`, so they pipe straight into
`Enum` and `Stream`.

Rows implement `Access`:

```elixir
row["person"]  #=> %TypeDB.Concept.Entity{iid: "0x1e0...", type: %TypeDB.Concept.EntityType{label: "person"}}
row["name"]    #=> %TypeDB.Concept.Attribute{value: "Alice", value_type: "string"}

TypeDB.ConceptRow.value(row, "name")        #=> "Alice"
TypeDB.ConceptRow.typed_value(row, "born")  #=> ~D[1994-03-01]
TypeDB.ConceptRow.to_map(row)               #=> %{"name" => "Alice", "age" => 30}
```

### Values

Values arrive exactly as the HTTP API defines them: JSON primitives for
`boolean`, `integer`, `double` and `string`, and strings for `decimal`, `date`,
`datetime`, `datetime-tz` and `duration`. `TypeDB.Concept.typed_value/1` converts:

| TypeDB | Elixir |
| --- | --- |
| `boolean`, `integer`, `double`, `string` | `boolean`, `integer`, `float`, `String.t()` |
| `date` | `Date.t()` |
| `datetime` | `NaiveDateTime.t()` |
| `datetime-tz` | `TypeDB.DateTimeTZ.t()` |
| `duration` | `TypeDB.Duration.t()` |
| `decimal` | `Decimal.t()` if `:decimal` is loaded, otherwise the string |

`TypeDB.DateTimeTZ` and `TypeDB.Duration` keep the original wire string, so
TypeDB's nanosecond precision survives conversion to Elixir's coarser types.

## Query options

```elixir
TypeDB.query(conn, "social", "match $p isa person;",
  transaction_type: :read,
  include_instance_types: false,  # skip a type lookup per concept on hot paths
  answer_count_limit: 1_000,      # the HTTP API is not streaming — cap the result set
  timeout: 120_000                # for long analytical reads
)
```

`answer_count_limit` matters: the HTTP API materialises the whole answer set
before responding, so an unbounded `match` against a large database will try to
build all of it. Exceeding the limit sets a warning on the answer rather than
failing — check it with `TypeDB.Answer.warning/1`.

## Administration

```elixir
TypeDB.Database.list(conn)
TypeDB.Database.create(conn, "social")           # a no-op if it already exists
TypeDB.Database.schema(conn, "social")           # TypeQL source, round-trips through `define`
TypeDB.Database.delete(conn, "social")           # irreversible

TypeDB.User.list(conn)
TypeDB.User.create(conn, "alice", password)
TypeDB.User.set_password(conn, "alice", new_password)
TypeDB.User.delete(conn, "alice")

TypeDB.Server.health(conn)                       # unauthenticated readiness probe
TypeDB.Server.version(conn)
```

## Errors

```elixir
case TypeDB.query(conn, "social", query) do
  {:ok, answer} ->
    answer

  {:error, %TypeDB.Error{kind: :server, code: code}} ->
    Logger.error("TypeDB rejected the query: #{code}")

  {:error, %TypeDB.Error{kind: :transport}} ->
    :retry_later
end
```

`:kind` is one of `:server`, `:transport`, `:timeout`, `:unauthenticated`,
`:decode`, `:config` or `:closed`. For `:server` errors, `:code` holds TypeDB's
own error code (`"TSV11"`, `"AUT3"`, …), which is stable across releases — branch
on that, not on messages.

## Configuration

| Option | Default | |
| --- | --- | --- |
| `:url` | `"http://localhost:8000"` | `"host:port"` is accepted and assumes `http` |
| `:username` / `:password` | — | required unless `:token` is given |
| `:token` | — | pre-issued bearer token; cannot be renewed on expiry |
| `:name` | `TypeDB` | registered name; start several connections under different names |
| `:timeout` | `60_000` | per-request receive timeout, ms |
| `:connect_timeout` | `10_000` | TCP/TLS connect timeout, ms |
| `:http` | `{TypeDB.HTTP.Httpc, []}` | adapter and its options |
| `:max_retries` | `1` | transport-failure retries for idempotent requests |
| `:retry_backoff` | `{:exponential, 100}` | or a `(attempt -> ms)` function |

### TLS

Certificate verification is on by default and cannot be switched off by accident:
`verify_peer`, the OS trust store, hostname checking, TLS 1.2/1.3. To pin a
private CA:

```elixir
{TypeDB,
 url: "https://typedb.internal:8000",
 username: "admin",
 password: password,
 http: {TypeDB.HTTP.Httpc, cacertfile: "/etc/ssl/private-ca.pem"}}
```

### Using Req instead of :httpc

```elixir
# mix.exs
{:req, "~> 0.5"}

# supervision tree
{TypeDB, url: "...", username: "...", password: "...", http: {TypeDB.HTTP.Req, finch: MyApp.Finch}}
```

Any module implementing the `TypeDB.HTTP` behaviour works.

## Validating TypeQL

Install [`typeql-check`](https://typedb.com/docs/home/install/typeql-check/) and
lint your `.tql` files without a server:

```shell
mix typedb.check                 # checks priv/**/*.tql
mix typedb.check "test/**/*.tql"
```

It exits non-zero on a parse error, so it drops straight into CI. It checks
syntax only — for schema-aware validation, run
`TypeDB.Transaction.analyze/3` against a real database.

If you use an AI coding agent, TypeDB's
[configure-coding-agent](https://typedb.com/docs/home/configure-coding-agent/)
guide pairs `typeql-check` with the
[`typedb-skills`](https://github.com/typedb/typedb-skills) TypeQL skill file.

## What is not covered

The HTTP API does not expose database import/export or streaming answers; those
are gRPC-only in TypeDB 3.x. Everything else in HTTP API v1 is here: sign-in and
token renewal, databases, users, servers, version and health, transactions,
one-shot queries, and query analysis.

## Development

```shell
mix deps.get
mix test                              # unit tests, no server required
docker compose up -d                  # TypeDB 3.12.1 on :8000
TYPEDB_INTEGRATION_URL=http://localhost:8000 mix test --include integration
```

The unit suite runs the whole driver against `TypeDB.Stub`, a real HTTP/1.1
server that speaks the TypeDB API — so transport, encoding and error mapping are
exercised without a database. The integration suite runs the same paths against a
real TypeDB server.

## License

Apache-2.0. See [LICENSE](LICENSE).

TypeDB is a trademark of TypeDB Ltd. This driver is not an official TypeDB
product.
