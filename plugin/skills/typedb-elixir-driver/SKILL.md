---
name: typedb-elixir-driver
description: Use the typedb or typedb_grpc Elixir packages to talk to TypeDB — starting a connection under a supervisor, running queries, choosing a transaction type, passing user input safely with given_rows, reading answers, streaming past the answer cap, handling %TypeDB.Error{}, and picking between the HTTP and gRPC transports. Use when writing or reviewing Elixir that queries TypeDB, or when a TypeDB call in Elixir fails.
---

# TypeDB from Elixir

Two community packages, one API shape: **`typedb`** over TypeDB's HTTP API v1,
and **`typedb_grpc`** over gRPC. Neither is TypeDB Ltd.'s official driver.

Every function named here is in the **documented** public API of `typedb`
0.11.0. Anything not listed in the reference at
<https://hexdocs.pm/typedb> is internal and may change in a patch release, so do
not call it even if it exists.

For TypeQL itself — schemas, `match`, `fetch`, functions, and the 2.x forms that
3.x rejects — use the `typeql-3` skill.

## Install

```elixir
def deps do
  [
    {:typedb, "~> 0.11.0"},
    {:finch, "~> 0.23"},
    {:decimal, "~> 2.4"}
  ]
end
```

Finch is a **separate line on purpose**: every HTTP adapter is an optional
dependency. Finch is the default and what nearly everyone wants. `Decimal` is
optional and is the one that changes the *type of your data* — TypeDB `decimal`
values decode to `Decimal.t()` when it is loaded and stay strings when it is
not. Add it if the schema has any.

## Start a connection under a supervisor

```elixir
children = [
  {TypeDB,
   url: "http://localhost:8000",
   username: "admin",
   password: System.fetch_env!("TYPEDB_PASSWORD")}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Never hard-code a password; read it from the environment or a secrets store.

`start_link/1` validates options and starts the process — it does **not** contact
the server. No socket opens and no sign-in happens until the first request, so a
wrong password or an unreachable host starts cleanly and fails on that request.
That is what you want in a supervision tree. To fail at boot instead, ask:

```elixir
:ok = TypeDB.Server.health!(TypeDB)
```

The connection registers under a **name**, which is how you address it. `TypeDB`
is the default; pass `:name` to run several. The name must be a plain atom —
`:via` and `:global` tuples are refused, because the connection owns a named ETS
table.

```elixir
children = [
  {TypeDB, name: :analytics, url: "http://analytics:8000", username: "admin", password: pw},
  {TypeDB, name: :ingest, url: "http://ingest:8000", username: "admin", password: pw}
]
```

Requests run **in the calling process**. The connection process only mints and
renews the auth token, so it is never a throughput bottleneck — you do not need
a pool of connections.

## Always pass `transaction_type`

This is the highest-value option in the driver. `TypeDB.query/4` defaults to
`:schema`, which takes TypeDB's **exclusive, database-wide** lock, so a one-shot
read left on the default serialises against every other query in the system.

```elixir
TypeDB.query(conn, "social", "match $p isa person; select $p;", transaction_type: :read)
TypeDB.query(conn, "social", ~s(insert $p isa person, has name "Alice";), transaction_type: :write)
TypeDB.query(conn, "social", "define entity dog;")   # :schema, deliberately
```

| type | accepts | concurrency |
| --- | --- | --- |
| `:read` | `match`, `fetch`, `reduce` | concurrent with everything |
| `:write` | data changes and reads | concurrent with other writes |
| `:schema` | `define`, `undefine`, `redefine`, and all of the above | exclusive, database-wide |

Narrowing also buys a check: TypeDB answers `400 TSV9` to a write in a read
transaction and `400 TSV8` to a schema change in a write transaction, so a query
that drifts out of its type fails loudly instead of taking a lock nobody wanted.

## Pass user input as data, never as text

```elixir
TypeDB.query!(conn, "social", """
  given $n: string;
  match $p isa person, has name == $n;
  select $p;
""", transaction_type: :read, given_rows: [%{"n" => user_supplied}])
```

`given_rows` binds variables to rows supplied *beside* the query. The driver
encodes each value in TypeDB's tagged wire form, so TypeQL never parses it and
no value can escape into the query — quotes, semicolons and newlines included.
**Never interpolate a user's value into the query string.** That is the
injection this exists to prevent, and it is also simply broken: the escaping
rules are TypeQL's, not Elixir's.

It is the fast path too — one request and one query compilation covers every
row, which is why `given_rows` is also how you bulk load.

A `given` stage with no rows supplied is `400 QEX21`. And one caveat, documented
on `TypeDB.Given`: a column declared as a *concept* (`given $p: person;`) accepts
any iid, so whoever chose the iid chose which entity the query reads. Bind those
from concepts your own code fetched.

Interpolating a number **you** computed — a page offset — is fine. Interpolating
anything that came from a user is not.

## Read the answer

The query decides the shape:

| TypeQL | answer | what you get |
| --- | --- | --- |
| `define`, `insert` with no `select` | `TypeDB.Answer.Ok` | success and nothing else |
| `match … select` | `TypeDB.Answer.ConceptRows` | rows of named concepts |
| `… fetch { … }` | `TypeDB.Answer.ConceptDocuments` | plain maps, JSON-shaped |

`ConceptRows` and `ConceptDocuments` are `Enumerable`:

```elixir
{:ok, answer} = TypeDB.query(conn, "social", "match $p isa person, has name $n; select $n;",
                             transaction_type: :read)

names = Enum.map(answer, &TypeDB.ConceptRow.value(&1, "n"))
```

Three ways into a row, and the middle one is usually right:

```elixir
TypeDB.ConceptRow.value(row, "n")        # the wire value, exactly as TypeDB sent it
TypeDB.ConceptRow.typed_value(row, "n")  # natively typed
TypeDB.ConceptRow.get(row, "p")          # the whole %TypeDB.Concept{}, iid included
```

`typed_value/2` gives a `Date` for a `date`, a `NaiveDateTime` for a `datetime`,
a `TypeDB.DateTimeTZ` for a `datetime-tz`, a `TypeDB.Duration` for a `duration`,
a `Decimal` for a `decimal`. For a `string` the two agree. `value/2` on a
`decimal` hands you `"12.345dec"` — TypeQL's literal suffix included — so prefer
`typed_value/2` for anything but strings.

Whole-row helpers: `TypeDB.ConceptRow.to_map/1`, `to_typed_map/1`,
`to_struct/2,3`, `variables/1`. `TypeDB.ConceptRow` also implements `Access`.

A value the driver cannot parse **comes back unchanged** rather than raising, so
a future TypeDB value type never breaks a running application. The cost is that
a decode surprise looks like a string where you expected a struct.

`TypeDB.Answer.truncated?/1` tells you a read came back short — see *Streaming*.

## Every failure is a `%TypeDB.Error{}`

Branch on `:code`, TypeDB's own stable code, or on `:kind`, the driver's coarser
classification. **Never match on the message text.**

```elixir
case TypeDB.query(conn, "social", q, transaction_type: :read) do
  {:ok, answer} -> {:ok, Enum.to_list(answer)}
  {:error, %TypeDB.Error{code: "SRV3"}} -> {:error, :no_such_database}
  {:error, %TypeDB.Error{kind: :transport} = error} -> {:error, error}
end
```

`:kind` is one of `:server`, `:transport`, `:timeout`, `:unauthenticated`,
`:decode`, `:encode`, `:config`.

Every failing function has a `!` twin that raises instead —
`TypeDB.query!/4`, `TypeDB.Database.create!/3` and so on. Use whichever suits
the call site; the pairing is enforced by the driver's own test suite.

### What the driver retries, and what you must

The driver retries a request when the failure looks transient **and** re-sending
is safe: reads yes, writes and commits never. It never sends a write twice.

What it cannot retry is a whole unit of work. Two cases need a loop of yours:

- `STC2` — a concurrent `:write` transaction committed first, so your commit was
  rejected. Certain to be worth another attempt.
- `TSV12` — no open transaction: it expired, or a timeout made the driver hang
  up and TypeDB discarded it. Nothing it wrote was committed.

`TypeDB.Error.retryable?/1` covers both, plus transport failures and timeouts:

```elixir
defp with_retry(fun, attempts \\ 3)
defp with_retry(fun, 1), do: fun.()

defp with_retry(fun, attempts) do
  case fun.() do
    {:error, %TypeDB.Error{} = error} ->
      if TypeDB.Error.retryable?(error),
        do: with_retry(fun, attempts - 1),
        else: {:error, error}

    result ->
      result
  end
end

with_retry(fn -> TypeDB.transaction(conn, "social", :write, &move_money/1) end)
```

Back off between attempts: two processes retrying a conflict in lockstep will
conflict again.

### Bound what a call can cost

```elixir
TypeDB.start_link(
  url: ...,
  timeout: 15_000,          # one attempt
  connect_timeout: 2_000,   # opening the socket
  max_retries: 3,           # extra attempts
  retry_max_delay: 2_000,   # one wait between attempts
  deadline: 20_000          # the whole call, retries and waits included
)
```

Only `:deadline` bounds the call. Without it that configuration can spend
`4 × (2_000 + 15_000) + 3 × 2_000 = 74 s` in your process; with it, twenty. Both
are also per call: `TypeDB.Server.health(conn, timeout: 500)` is what a readiness
probe wants.

## Transactions

`TypeDB.query/4` is one round trip and commits itself. For several statements
that must succeed or fail together, use `TypeDB.transaction/5`:

```elixir
TypeDB.transaction(conn, "social", :write, fn tx ->
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Alice";))
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Bob";))
end)
```

The block commits on success and abandons on failure — `{:error, _}`, a raise, a
throw or an exit. A `:read` block is closed rather than rolled back, because
TypeDB rejects a rollback on a read transaction.

Two things surprise people:

- **Constraint violations surface at query time, not at commit.** A second
  entity breaking a `@key` fails on the `insert` with `400 CNT9`, inside the
  block. A failing commit is not how you normally learn the data was wrong.
- **A commit can fail after the block succeeded**, when a concurrent `:write`
  won the race — `400 STC2`. Retry the block, as above.

Opening one yourself hands you the cleanup:

```elixir
{:ok, tx} = TypeDB.Transaction.open(conn, "social", :write)

try do
  {:ok, _} = TypeDB.Transaction.query(tx, ~s(insert $p isa person;))
  :ok = TypeDB.Transaction.commit(tx)
after
  TypeDB.Transaction.close(tx)
end
```

`close/2` is idempotent and safe in an `after`; everything else on a finished
transaction answers `404 TSV12`. `rollback/2` discards the writes and leaves the
transaction **open** — cleanup is `close/2`, not `rollback/2`. Prefer
`transaction/5` unless the transaction must outlive a function.

A `%TypeDB.Transaction{}` is a plain struct holding an id, so it can be passed
between processes — but nothing stops two processes using it at once, and TypeDB
will not thank you. Keep a transaction in one process.

A request that fails with `:timeout` or `:transport` takes the transaction with
it: the driver hangs up and TypeDB discards it, uncommitted. That is the useful
half — no partial write to clean up — and it means a long unit of work needs a
larger `:timeout`, and a larger `transaction_timeout_millis` if the transaction
as a whole runs long.

## Streaming past the 10,000-answer cap

The HTTP API truncates a read at `answerCountLimit`, 10,000 by default.
`TypeDB.stream/4` walks the pages for you and returns a lazy `Stream`:

```elixir
conn
|> TypeDB.stream("social", "match $p isa person, has name $n; select $n; sort $n;")
|> Stream.map(&TypeDB.ConceptRow.value(&1, "n"))
|> Enum.take(50_000)
```

**`sort` is not optional.** Paging an unsorted query can repeat or skip rows,
because nothing fixes the order between pages. `stream/4` is read-only —
`:transaction_type` is not one of its options.

A `fetch` pipeline cannot be paged at all (`offset` after `fetch` is `400
TQL0`), so page the `match` and `fetch` inside it. `TypeDB.Answer.truncated?/1`
is how a plain `query/4` tells you it came back short.

## Administration

`TypeDB.Database` (`create/3`, `create_if_not_exists/3`, `delete/3`, `exists?/3`,
`list/2`, `schema/3`, `type_schema/3`), `TypeDB.User`, and `TypeDB.Server`
(`health/2`, `version/2`, `servers/2`), each with a `!` twin. The facade
`TypeDB` also carries the common ones: `TypeDB.create_database/3`,
`TypeDB.databases/2`, `TypeDB.health/2`, `TypeDB.version/2`.

## Observability

`TypeDB.Telemetry` emits spans at three levels — `[:typedb, :operation]`,
`[:typedb, :transaction]`, `[:typedb, :request]` — plus `[:typedb, :sign_in]`
and `[:typedb, :retry, :exhausted]`. Event prefixes come from
`TypeDB.Telemetry.operation_event/0` and its siblings rather than being written
out. For a quick look, `TypeDB.Telemetry.attach_default_logger/1`.

## HTTP or gRPC

Default to **`typedb`** (HTTP). Reach for `typedb_grpc` for one of three
measured reasons:

| | `typedb` (HTTP) | `typedb_grpc` |
| --- | --- | --- |
| export / import a database | not offered by the HTTP API | `export_database/5`, `import_database/5` |
| large reads | capped at `answerCountLimit`; `stream/4` pages it | streams with no cap; 20,000 answers in 248 ms against 1004 ms |
| many small independent reads | faster — 200 point reads in 213 ms | slower, 249 ms: every read goes through a transaction stream |
| dependencies | `:telemetry` only; runs on OTP alone via the httpc adapter | `grpc`, `protobuf`, `gun` and their transitive deps |
| network | HTTP/1.1 | HTTP/2 end to end |

Concepts decode into the same `TypeDB.Concept` structs and failures arrive as
the same `%TypeDB.Error{}`, so switching is not a rewrite.

## Three adapters, one behaviour

`TypeDB.HTTP` is a behaviour with `TypeDB.HTTP.Finch` (default), `TypeDB.HTTP.Req`
and `TypeDB.HTTP.Httpc`. Pass `:http` to choose:

```elixir
TypeDB.start_link(url: ..., http: {TypeDB.HTTP.Httpc, []})
```

Finch is much faster under concurrency; httpc needs nothing at runtime beyond
OTP. Req is for reusing a `Req` your application already configures. The suite
runs against all three, which is what keeps them interchangeable.

## Reference

- `typedb` on hexdocs: <https://hexdocs.pm/typedb>
- Guides — getting started, transactions, recipes, errors and retries,
  observability, testing: <https://hexdocs.pm/typedb/getting-started.html>
- `typedb_grpc`: <https://hexdocs.pm/typedb_grpc>
- Source: <https://github.com/NoeticEcho/TypedbEx>
