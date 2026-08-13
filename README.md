# TypeDB for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/typedb.svg)](https://hex.pm/packages/typedb)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/typedb)
[![License](https://img.shields.io/hexpm/l/typedb.svg)](LICENSE)

An Elixir driver for [TypeDB](https://typedb.com), built on the TypeDB HTTP API.

- **Fast under load.** Finch-backed by default: ~1840 req/s at 200-way concurrency, where OTP's `:httpc` manages 408 with a p99 five times longer. A swappable transport keeps `:httpc` available for deployments that must run on OTP alone. The script is in `bench/`.
- **Concurrent by construction.** Requests run in the calling process. The connection process only mints and renews the auth token, so it is never a bottleneck.
- **Tokens handled for you.** The driver reads the token's own lifetime and renews it *before* it expires, so ordinary traffic never spends a round trip on a `401` — with reactive renewal still there as the safety net. Verified with 200-way bursts against a server issuing one-second tokens.
- **Typed answers.** Concept rows and documents decode into structs, with TypeDB's temporal and decimal types available as native Elixir terms.
- **Errors you can branch on.** Every failure is a `TypeDB.Error` carrying TypeDB's stable error code.
- **Observable.** `:telemetry` spans for every operation, transaction, request and sign-in, ready for `telemetry_metrics`.

## Requirements

**TypeDB 3.12.0 or newer**, Elixir 1.18+ / OTP 25+. Linux, macOS and Windows —
CI compiles and runs the unit suite through all three HTTP adapters on Windows
as well as Linux. The one exception is the `mix typedb.check` task, which
shells out and therefore wants Git Bash, WSL or MSYS2 there.

Every release runs the full suite against TypeDB 3.12.0, 3.12.1 and `latest`,
through all three HTTP adapters. 3.12.0 is the floor because it is the oldest
release the suite passes on, bisected rather than guessed: on 3.11.5, fourteen
integration tests fail. TypeQL's `given` stage — which is how this driver makes
a parameterised query safe — is a syntax error there, so every parameterised
query, and everything that reads a typed value back, fails. `User.delete/2` on
an unknown user also answers 400 where 3.12 answers 404.

Older still is worse, not better: on 3.5.0 `/v1/servers` does not exist and
inserting then matching fails outright. If you need a release older than
3.12.0, open an issue — it would mean giving up `given`, so it is a decision
rather than a patch.

## Installation

```elixir
def deps do
  [
    {:typedb, "~> 0.8.0"},
    # The default transport. Leave it out only if you select TypeDB.HTTP.Httpc.
    {:finch, "~> 0.23"}
  ]
end
```

Requires Elixir 1.18+ and OTP 25+. Developed and tested on Linux; the driver is
pure Elixir, so it runs on anything the BEAM does.

Versioned per [SemVer](https://semver.org/spec/v2.0.0.html). While in `0.x`, a
minor bump may change the public API and a patch will not — see
[CONTRIBUTING](CONTRIBUTING.md#versioning) for exactly what counts as breaking.

[telemetry](https://hex.pm/packages/telemetry) is the only hard dependency — one
small application, no dependencies of its own. Every transport's dependency is
optional, so your footprint follows the transport you pick:

| You select | You add | Pulls in |
| --- | --- | --- |
| `TypeDB.HTTP.Finch` (default) | `{:finch, "~> 0.23"}` | finch, mint, hpax, mime, nimble_options, nimble_pool |
| `TypeDB.HTTP.Req` | `{:req, "~> 0.7"}` | req and its own dependencies |
| `TypeDB.HTTP.Httpc` | nothing | nothing — it is OTP's own client |

If you forget, `TypeDB.start_link/1` says so by name rather than failing
mysteriously later. `{:decimal, "~> 2.4 or ~> 3.0"}` is optional too: TypeDB's
`decimal` values decode to `Decimal.t()` when it is loaded and stay strings
otherwise. JSON is handled by Elixir's built-in `JSON` module and needs no
dependency; to route it through a different codec, configure one:

```elixir
config :typedb, :json_codec, TypeDB.JSON.Jason
```

## Quick start

Start a TypeDB server:

```shell
typedb server            # or, from a clone of this repository: docker compose up -d
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

`start_link/1` validates the options and starts the process; it does **not**
contact the server. A wrong password or an unreachable host starts cleanly and
fails on the first request instead, which is deliberate — the driver signs in
lazily, so your application boots whether or not TypeDB is up yet. If you would
rather find out at boot, call `TypeDB.Server.health/1` yourself once the
supervisor is running.

Run several connections by giving each a name, which is also how you address it:

```elixir
children = [
  {TypeDB, name: :analytics, url: "http://analytics:8000", username: "admin", password: pw},
  {TypeDB, name: :ingest, url: "http://ingest:8000", username: "admin", password: pw}
]

TypeDB.query(:analytics, "events", "match $e isa event;", transaction_type: :read)
```

Define a schema, insert some data, read it back. `conn` below is a connection
name — `TypeDB` is the default one:

```elixir
conn = TypeDB

TypeDB.create_database(conn, "social")

TypeDB.query!(conn, "social", """
  define
    attribute name, value string;
    attribute age, value integer;
    entity person, owns name, owns age;
""")

TypeDB.query!(conn, "social", """
  insert
    $alice isa person, has name "Alice", has age 30;
    $bob isa person, has name "Bob", has age 41;
""", transaction_type: :write)

TypeDB.query!(conn, "social", """
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

`:transaction_type` defaults to `:schema`, because that is the only type that
accepts every kind of query — including `define`. It is also the type that takes
an exclusive, database-wide lock (see the table below), so **pass `:read` or
`:write` explicitly** for anything that is not a schema change.

That lock is not theoretical. Hold a `:schema` transaction open for a second,
and a one-shot query left on the default waits the whole second for it, while
the same query with `transaction_type: :read` returns in a millisecond. An
integration test pins both halves. Left on the default, your queries queue
behind each other and behind every schema change in the system.

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

The commit itself can fail after your block succeeded — because a concurrent
`:write` transaction touched the same data and committed first, which TypeDB
answers with `400 STC2` — and that surfaces as `{:error, %TypeDB.Error{}}` from
`transaction/5`. `TypeDB.Error.retryable?/1` is true for it; re-run the whole
block to survive it. `:max_retries` does not cover this, as it retries
*transport* failures on requests that never reached the server.

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

The pipeline runs once per row, so this is also the fast way to write many rows:
one request and one query compilation instead of N. Measured by
`bench/given.exs`, writing 2,000 rows three ways against a local server:

| how | | |
| --- | --- | --- |
| one request per row | 8830ms | 226 rows/s |
| one request, 2,000 `insert` statements in the query | 1541ms | 1,298 rows/s |
| one request, 2,000 `given` rows | **101ms** | **19,647 rows/s** |

The second row is the honest competitor — it is also a single request — so the
15× between it and `given` is query compilation and string building, and the gap
widens with the row count because only one of them compiles once.

Declare every input variable in the `given` stage, marking optional columns
with `?`:

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
```

A whole row at once, either as TypeDB sent it or converted:

```elixir
TypeDB.ConceptRow.to_map(row)
#=> %{"name" => "Alice", "born" => "1994-03-01", "worked" => "P1Y2M3DT4H5M6S"}

TypeDB.ConceptRow.to_typed_map(row)
#=> %{"name" => "Alice", "born" => ~D[1994-03-01], "worked" => %TypeDB.Duration{months: 14, ...}}

TypeDB.ConceptRow.to_struct(row, Person, typed: true)
#=> %Person{name: "Alice", born: ~D[1994-03-01]}
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
  include_query_structure: false, # on by default; ~740 bytes per response, whatever the row count
  answer_count_limit: 1_000,      # the HTTP API is not streaming — cap the result set
  timeout: 120_000                # for long analytical reads
)
```

`include_query_structure` is on by TypeDB's default, so every `ConceptRows`
answer carries the analysed pipeline in `:query_structure` whether or not you
read it. Measured against TypeDB 3.12.1, a one-row answer is 1069 bytes with it
and 326 without — a fixed cost per response, not per row. Turn it off on hot
paths; leave it on if you are building query tooling. The field is raw decoded
JSON, passed through exactly as TypeDB sent it, and its shape is TypeDB's to
change.

**`answer_count_limit` raises a cap as well as lowering one.** TypeDB truncates
a read at **10,000 answers** by default. That is not a driver default and there
is no server flag for it: the request option is the only control. Measured
against 3.12.1 — a `match` over 20,000 entities returns exactly 10,000 rows,
while `reduce $n = count` over the same data says 20,000.

Truncation is not an error. The answer arrives with the rows it did produce, so
code that counts what came back is quietly wrong — ask instead:

```elixir
{:ok, answer} = TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)

if TypeDB.Answer.truncated?(answer) do
  {:error, :partial}      # page it, raise the cap, or aggregate server-side
else
  {:ok, TypeDB.Answer.rows(answer)}
end
```

**The row count cannot answer this**, in either direction. TypeDB warns only
when it really had more, so a complete answer can be exactly the size of the
cap; and a query carrying its own `limit` can come back smaller than the cap and
still be complete. `TypeDB.Answer.warning/1` gives you the server's text, which
names the limit that was hit — read it, log it, but branch on `truncated?/1`.

The driver logs the warning at `:warning` level so a truncated answer is never
silent, but the decision is yours: raise the limit, page the query yourself with
`offset`/`limit` in TypeQL, or aggregate server-side with `reduce`.

Set it once per connection to apply to every query that does not override it:

```elixir
{TypeDB, url: "...", username: "...", password: "...", answer_count_limit: 50_000}
```

## Telemetry

Every request and sign-in is a `:telemetry` span:

```elixir
:telemetry.attach("typedb", [:typedb, :request, :stop], fn _event, %{duration: d}, meta, _ ->
  Logger.info("typedb #{meta.method} #{meta.path} -> #{meta[:status]} in #{d}")
end, nil)
```

See `TypeDB.Telemetry` for the full event list and metadata.

## Administration

```elixir
TypeDB.Database.list(conn)
TypeDB.Database.create(conn, "social")           # a no-op if it already exists
TypeDB.Database.schema(conn, "social")           # TypeQL source, round-trips through `define`
TypeDB.Database.delete(conn, "social")           # irreversible

TypeDB.User.list(conn)
TypeDB.User.create(conn, "alice", password)      # 400 USC2 if alice already exists
TypeDB.User.set_password(conn, "alice", new_password)
TypeDB.User.delete(conn, "alice")

TypeDB.Database.get(conn, "social")              # 404 if it does not exist
TypeDB.Database.exists?(conn, "social")
TypeDB.Database.create_if_not_exists(conn, "social")
TypeDB.Database.type_schema(conn, "social")      # types only, without functions

TypeDB.User.get(conn, "alice")
TypeDB.User.exists?(conn, "alice")

TypeDB.Server.health(conn, timeout: 500)         # unauthenticated readiness probe
TypeDB.Server.version(conn)
TypeDB.Server.servers(conn)                      # cluster membership
```

Note the asymmetry, which is TypeDB's own: creating a database that already
exists succeeds, creating a user that already exists does not.
`TypeDB.Database.create_if_not_exists/2` states that intent explicitly for
databases and also copes with a server that rejects the duplicate; for users,
check `TypeDB.User.exists?/2` first.

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
`:decode`, `:encode` or `:config`. For `:server` errors, `:code` holds TypeDB's
own error code (`"TSV11"`, `"AUT3"`, …), which is stable across releases — branch
on that, not on messages.

Every function that can fail also has a `!` form that returns the value and
raises `TypeDB.Error` instead — `TypeDB.Database.list!/1`, `TypeDB.User.create!/3`,
`TypeDB.Transaction.commit!/1` and so on. The one exception is
`TypeDB.transaction/5`, which returns whatever your block returned — except that
a `:write` or `:schema` block that succeeded but whose *commit* failed returns
`{:error, %TypeDB.Error{}}`. Because that error can be indistinguishable from one
your own block returned, there is no `!` form to decide what to raise.

## Configuration

| Option | Default | |
| --- | --- | --- |
| `:url` | `"http://localhost:8000"` | `"host:port"` is accepted and assumes `http` |
| `:username` / `:password` | — | required unless `:token` is given |
| `:token` | — | pre-issued bearer token; cannot be renewed on expiry |
| `:name` | `TypeDB` | registered name; start several connections under different names |
| `:timeout` | `60_000` | per-request receive timeout, ms |
| `:connect_timeout` | `10_000` | TCP/TLS connect timeout, ms |
| `:http` | `{TypeDB.HTTP.Finch, []}` | adapter and its options |
| `:max_retries` | `1` | transport-failure retries for idempotent requests |
| `:max_auth_renewals` | `2` | token renewals a single request may make after a `401` |
| `:answer_count_limit` | — | default cap on answers per query; see below |
| `:retry_backoff` | `{:exponential, 100}` | or a `(attempt -> ms)` function |

`:connect_timeout` bounds *connecting*, under every adapter, and a host that
never answers fails with `kind: :timeout` — not `:transport` — whichever adapter
is in use. Waiting for a free connection when the pool is saturated is a
different thing with a different knob: `http: {TypeDB.HTTP.Finch, pool_timeout: …}`.

### TLS

Certificate verification is on by default under every adapter — peer
verification, the OS trust store and hostname checking — and turning it off takes
an explicit option. To pin a private CA:

```elixir
# Finch (default)
http: {TypeDB.HTTP.Finch, conn_opts: [transport_opts: [cacertfile: "/etc/ssl/private-ca.pem"]]}

# httpc
http: {TypeDB.HTTP.Httpc, cacertfile: "/etc/ssl/private-ca.pem"}
```

### Choosing a transport

The default is `TypeDB.HTTP.Finch`, which starts a Finch pool per connection:

```elixir
{TypeDB, url: "...", username: "...", password: "...",
 http: {TypeDB.HTTP.Finch, size: 100, count: 2}}
```

Two alternatives ship with the driver:

```elixir
# Reuse a Finch your app already runs through Req. Needs {:req, "~> 0.7"}.
http: {TypeDB.HTTP.Req, finch: MyApp.Finch}

# OTP's own client, needing nothing at runtime — see below for what that costs.
http: {TypeDB.HTTP.Httpc, max_sessions: 100}
```

Measured by `bench/transport.exs` against a local TypeDB, 400 requests per run
with a warm pool:

| Concurrency | `:httpc` | Req | Finch |
| --- | --- | --- | --- |
| 16 | 569 req/s, p50 28ms | 1656 req/s, p50 9ms | 2052 req/s, p50 7ms |
| 64 | 437 req/s, p50 146ms | 1628 req/s, p50 38ms | 1830 req/s, p50 32ms |
| 200 | 408 req/s, p50 336ms | 1675 req/s, p50 101ms | 1840 req/s, p50 100ms |

`:httpc` does not scale with concurrency: three to four times slower throughout,
with a p99 that reaches 553ms where Finch's is 112ms. Pick it deliberately, not
by default. Run the script yourself — the ratio is the point, the absolute
numbers belong to whatever machine produced them.

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

This is the one part of the project that needs a POSIX shell: each file goes to
`typeql-check` on stdin, since a schema past about a megabyte cannot be passed
as a command-line argument. On Windows, run it from Git Bash, WSL or MSYS2. The
driver itself is pure Elixir and runs anywhere the BEAM does.

If you use an AI coding agent, TypeDB's
[configure-coding-agent](https://typedb.com/docs/home/configure-coding-agent/)
guide pairs `typeql-check` with the
[`typedb-skills`](https://github.com/typedb/typedb-skills) TypeQL skill file.

## Guides

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2FNoeticEcho%2FTypedbEx%2Fmain%2Fnotebooks%2Fgetting_started.livemd)

The notebook is the fastest way to find out whether this driver fits: a
database, a schema, reads and writes, a parameterised query that survives a
hostile value, and a transaction — against a TypeDB you start with one `docker
run`.

Then five guides, for the things a reference page cannot teach:

- **[Transactions](guides/transactions.md)** — the three types, why the default
  is the expensive one, what a commit promises and what it does not.
- **[Recipes](guides/recipes.md)** — paging a `match` bigger than TypeDB's
  10,000-answer cap, bulk loading, upsert, counting without fetching, mapping
  rows onto your own structs, and getting a schema in place at boot. Every one
  of them run against a live server, with the numbers from that run.
- **[Errors and retries](guides/errors-and-retries.md)** — what the driver
  retries for you, what it cannot, and how to bound what a call can cost.
- **[Telemetry and logging](guides/observability.md)** — three levels of span,
  which one answers your question, and the metrics worth graphing.
- **[Testing an application](guides/testing.md)** — a database per test, when a
  stub is worth it, and how to make the failure paths happen on purpose.

## Where your credentials live

Worth stating plainly, since the driver is the thing holding them.

The **password**, and a pre-issued `:token`, are kept in the connection process
and nowhere else. They are stripped from the copy published to the connection's
ETS table, hidden by `TypeDB.Config`'s `Inspect`, and therefore absent from
crash reports, `:sys.get_state/1`, `:observer`, log lines and telemetry
metadata. `test/typedb/security_test.exs` asserts each of those, and a
`:passphrase` on a TLS key gets the same treatment.

The **bearer token TypeDB issues** is a different matter: it lives in the
connection's ETS table, which is `:protected` — every process on the node can
read it. That is not an oversight, it is the design. Requests run in the calling
process, which means the calling process has to be able to read the token, which
means it cannot be a secret from the rest of the VM. Any process that can read
it could have called `TypeDB.query/4` anyway, so nothing is gained by hiding it;
what matters is that it does not escape the node, and it does not — no log line
or telemetry event carries it.

## Limitations

None of these are bugs. All of them are surprises if you meet them for the
first time in production.

**Answers arrive whole.** The HTTP API does not stream, so an answer is
materialised on the server, shipped, and decoded into one term in your process.
There is no cursor to page through and none can be built on this API.
`bench/answer_size.exs` measures the cost: for rows of two attributes,
**488 bytes per row on the wire and 897 bytes decoded** — so a million rows
would be about 0.8 GiB of term memory, in one process, at once.

TypeDB caps a read at 10,000 answers by default rather than letting you find
that out, and attaches a warning saying so. Raise the cap with
`:answer_count_limit` when you need more, and treat an unbounded `match` the way
you would treat `SELECT *` without a `LIMIT` — see
[Query options](#query-options).

**A connection points at one server.** `TypeDB.Server.servers/1` will tell you
what the cluster looks like, and nothing in the driver acts on it: there is no
failover, no read-replica routing and no reconnection to a different node. Put
a load balancer in front of a cluster, or supervise one connection per node and
choose between them yourself.

This is a decision rather than an omission, and it is the one limitation here
that could plausibly change. Failover is only worth shipping if it is tested
against a real multi-node cluster, and every claim this driver makes is checked
against a live server — that is why the supported TypeDB range is what has been
measured rather than what ought to work. TypeDB CE is single-node, so there is
nothing here to test it against. Accepting `:urls` later is additive and needs
no `1.0` slot held open for it.

**Retries block the caller.** Requests run in the calling process, which is what
makes the driver concurrent — but it also means a retry and its backoff are
spent in *your* process, not in a queue behind a connection. See "How long a
call can take" in the `TypeDB` docs for the arithmetic, and set `:deadline` if a
call must not outlive a budget.

**One HTTP pool per connection.** `TypeDB.HTTP.Finch` starts a pool the
connection owns. Several connections to the same server are several pools; they
do not share sockets. That is usually what you want and occasionally is not.

**`mix typedb.check` needs a POSIX shell.** It is the only part of the project
that shells out, and on Windows it wants Git Bash, WSL or MSYS2. The driver
itself is pure Elixir and CI proves it on Windows.

**TypeDB 3.12.0 or newer**, and that is a measured floor rather than a cautious
one: 3.11.5 has no `given` stage. See [Requirements](#requirements).

**`Transaction.analyze/3` returns TypeDB's own map**, from an endpoint that is
not in the published HTTP API reference. It is the one return value this
driver's SemVer does not cover.

**Database import and export are not here**, and neither is anything else the
HTTP API does not expose — those are gRPC-only in TypeDB 3.x. Everything the
API *does* expose is covered: sign-in and token renewal, databases, users,
servers, version and health, transactions, one-shot queries, and query
analysis.

## Development

```shell
mix deps.get
mix test                              # unit tests, no server required
docker compose up -d                  # TypeDB 3.12.1 on :8000, from a clone
TYPEDB_INTEGRATION_URL=http://localhost:8000 mix test --include integration
```

The unit suite runs the whole driver against `TypeDB.Stub`, a real HTTP/1.1
server that speaks the TypeDB API — so transport, encoding and error mapping are
exercised without a database. The integration suite runs the same paths against a
real TypeDB server.

Three further opt-in suites cover things an ordinary run never reaches. They live
in the [repository](https://github.com/NoeticEcho/TypedbEx/tree/main/test/integration)
rather than in the published package, and each module's doc carries the exact
command to stand up the server it needs:

- [`TypeDB.TLSIntegrationTest`](https://github.com/NoeticEcho/TypedbEx/blob/main/test/integration/tls_integration_test.exs)
  — untrusted certificate rejected, pinned CA accepted, hostname mismatch
  refused, against a server started with `--server.encryption.enabled`.
- [`TypeDB.TokenRenewalIntegrationTest`](https://github.com/NoeticEcho/TypedbEx/blob/main/test/integration/token_renewal_integration_test.exs)
  — 200-way bursts, concurrent writes and a long transaction, all straddling
  token expiry, against a server started with
  `--server.authentication.token-expiration-seconds 5`. Set
  `TYPEDB_SHORT_TOKEN_URL` to run it; without that it reports as skipped.
- [`TypeDB.RestartIntegrationTest`](https://github.com/NoeticEcho/TypedbEx/blob/main/test/integration/restart_integration_test.exs)
  — a server stopped mid-traffic and started again, on every adapter: what
  callers see during the outage and that the connection recovers with no help
  from them. Set `TYPEDB_RESTART_URL`, `TYPEDB_RESTART_STOP` and
  `TYPEDB_RESTART_START`; see
  [Errors and retries](https://hexdocs.pm/typedb/errors-and-retries.html#when-the-server-restarts)
  for what it pins.

`TYPEDB_SLOW_TESTS=1` additionally runs the tests that wait out real timeouts,
and `TYPEDB_TEST_ADAPTER=finch|req|httpc` runs the whole suite through one
transport. CI runs all of them.

## License

Apache-2.0. See [LICENSE](LICENSE).

TypeDB is a trademark of TypeDB Ltd. This driver is not an official TypeDB
product.
