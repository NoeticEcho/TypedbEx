# Getting started

From an empty `mix.exs` to a query whose answer you can read, with a note at
each step about the thing that surprises people.

Everything on this page is checked. The code blocks are extracted and run
against the test stub by `test/typedb/guide_test.exs`, so an example that stops
working fails the suite rather than a reader. Where a sentence makes a claim
about **TypeDB's** behaviour rather than the driver's, it says which test
measured it — and where nothing has, it says that instead.

## What you need

A TypeDB **3.12 or newer** server. That floor is measured rather than cautious:
3.11.5 has no `given` stage, which is what makes parameterised queries safe
here, so the driver would have to silently stop protecting you. See
*Requirements* in the README.

The fastest server to get:

```shell
docker run --name typedb -p 1729:1729 -p 8000:8000 -d typedb/typedb:3.12.1
```

TypeDB CE ships with `admin` / `password` and serves HTTP on port 8000. This
driver speaks the HTTP API; port 1729 is gRPC, which the sibling package
`typedb_grpc` speaks.

## Add the dependency

```elixir
def deps do
  [
    {:typedb, "~> 0.10.2"},
    {:finch, "~> 0.23"}
  ]
end
```

Finch is a **separate line on purpose**. Every HTTP adapter's dependency is
optional, so the driver's footprint follows the transport you pick, and leaving
Finch out is what makes `TypeDB.HTTP.Httpc`'s "runs on OTP alone" true rather
than aspirational. Finch is the default and is what nearly everyone wants — it
is faster than `:httpc` by a wide margin under concurrency, and `TypeDB.HTTP`
has the numbers. Add it unless you have a reason not to.

`Decimal` is optional too, and it is the one optional dependency that changes
the *type of your data*: TypeDB's `decimal` values decode to `Decimal.t()` when
it is loaded and stay strings when it is not. Add `{:decimal, "~> 2.4"}` if your
schema has any.

## Start the connection

```elixir
children = [
  {TypeDB,
   url: "http://localhost:8000",
   username: "admin",
   password: System.fetch_env!("TYPEDB_PASSWORD")}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

`start_link/1` validates the options and starts the process. It does **not**
contact the server: no socket is opened and no sign-in happens until your first
request. A wrong password or an unreachable host therefore starts cleanly and
fails on that first request instead.

That is deliberate, and it is the behaviour you want in a supervision tree — an
application whose boot depends on TypeDB being up already cannot start while
TypeDB is restarting. If you would rather find out at boot, ask:

```elixir
:ok = TypeDB.Server.health!(TypeDB)
```

The connection registers itself under a **name**, which is also how you address
it. `TypeDB` is the default, so `TypeDB.query(TypeDB, …)` works out of the box;
give `:name` to run several.

```elixir
children = [
  {TypeDB, name: :analytics, url: "http://analytics:8000", username: "admin", password: pw},
  {TypeDB, name: :ingest, url: "http://ingest:8000", username: "admin", password: pw}
]
```

The name must be a plain atom. `:via` and `:global` tuples are refused, with an
error saying so, because the connection keeps a named ETS table — see
*Limitations* in the README.

## Your first query

A database, a schema, two people, and reading them back.

```elixir
TypeDB.create_database!(conn, "social")

TypeDB.query!(conn, "social", """
  define
    attribute name, value string;
    attribute age, value integer;
    entity person, owns name @key, owns age;
""")

TypeDB.query!(conn, "social", """
  insert
    $alice isa person, has name "Alice", has age 30;
    $bob isa person, has name "Bob", has age 41;
""", transaction_type: :write)

answer =
  TypeDB.query!(conn, "social", """
    match $p isa person, has name $name;
    select $name;
  """, transaction_type: :read)

names = Enum.map(answer, &TypeDB.ConceptRow.value(&1, "name"))
```

`conn` is the connection's name — `TypeDB` unless you chose another.

Three things in there are worth pausing on.

**`transaction_type` is the single highest-value option in this driver.**
`query/4` defaults to `:schema`, because that is the only type that accepts
every kind of query and a default rejecting half of them would be a trap of a
different sort. But `:schema` takes TypeDB's exclusive, database-wide lock, so
a one-shot read left on the default serialises against every other query in the
system. Pass the type. Narrowing also buys you a check: TypeDB answers
`400 TSV9` to a write in a read transaction and `400 TSV8` to a schema change in
a write transaction — both measured in
`test/integration/error_code_integration_test.exs` — so a query that drifts out
of its type fails loudly instead of taking a lock nobody intended.

**`@key` is doing real work.** It makes `name` unique, and the violation surfaces
on the `insert` with `400 CNT9`, inside the transaction, before any commit — not
at commit time. See [Transactions](transactions.md) for what that means for code
that expects to learn about bad data from a failed commit.

**The `!` form raises; the plain form returns a tuple.** Every function that can
fail has both, and `test/typedb/api_convention_test.exs` enforces the pairing
mechanically. Use whichever suits the call site.

## Reading the answer

An answer is one of three shapes, and the query decides which:

| TypeQL | answer | what you get |
| --- | --- | --- |
| `define`, `insert` without `select` | `TypeDB.Answer.Ok` | success and nothing else |
| `match … select` | `TypeDB.Answer.ConceptRows` | rows of named concepts |
| `… fetch { … }` | `TypeDB.Answer.ConceptDocuments` | plain maps, JSON-shaped |

`ConceptRows` is `Enumerable`, which is why `Enum.map/2` worked above. Each row
is a `TypeDB.ConceptRow`, and there are three ways to get at what is in it:

```elixir
row = answer |> Enum.to_list() |> hd()

TypeDB.ConceptRow.value(row, "name")
TypeDB.ConceptRow.typed_value(row, "name")
TypeDB.ConceptRow.get(row, "p")
```

`value/2` gives the **wire** value — exactly what TypeDB sent. `typed_value/2`
gives the **natively typed** one: a `Date` for a `date`, a `NaiveDateTime` for a
`datetime`, a `TypeDB.DateTimeTZ` for a `datetime-tz`, a `TypeDB.Duration` for a
`duration`, a `Decimal` for a `decimal`. For a `string` the two agree, which is
why the example above could use either. For anything else, `typed_value/2` is
almost always the one you want — `value/2` on a `decimal` hands you
`"12.345dec"`, TypeQL's literal suffix included.

`get/2` hands back the whole `TypeDB.Concept`, which is what you want for an
entity: it carries the `iid` you feed back in later.

**A value the driver cannot parse comes back unchanged** rather than raising, so
a future TypeDB value type never breaks a running application. It does mean a
decode surprise looks like a string where you expected a struct, so match on the
struct if you would rather find out loudly.

## Pass user input as data, not as text

This is the part worth getting right on day one.

```elixir
TypeDB.query!(conn, "social", """
  given $n: string;
  match $p isa person, has name == $n;
  select $p;
""", transaction_type: :read, given_rows: [%{"n" => user_supplied}])
```

`given_rows` binds variables to rows supplied *beside* the query. The driver
encodes each value in TypeDB's tagged wire form, so TypeQL is never asked to
parse it and no value can escape into your query — quotes, semicolons and
newlines included. Interpolating a user's value into the query string instead is
the injection this exists to prevent, and it is also simply broken: the escaping
rules are TypeQL's, not Elixir's.

It is the fast path too. One request and one query compilation covers every row,
which is why `given_rows` is also how you bulk load — see
[Recipes](recipes.md).

`TypeDB.Given` documents which Elixir terms map to which TypeDB types, and the
one case where `given` is not a safety boundary: a column declared as a
*concept* (`given $p: person;`) accepts any iid, so whoever chose the iid chose
which entity the query reads. Bind those from concepts your own code fetched.

## When something goes wrong

Every failure is a `TypeDB.Error`, and the field to branch on is `:code` —
TypeDB's own, stable, documented error code:

```elixir
case TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read) do
  {:ok, answer} -> {:ok, Enum.to_list(answer)}
  {:error, %TypeDB.Error{code: "SRV3"}} -> {:error, :no_such_database}
  {:error, %TypeDB.Error{kind: :transport} = error} -> {:error, error}
end
```

`:kind` is the driver's own coarser classification — `:server`, `:transport`,
`:timeout`, `:unauthenticated`, `:decode`, `:encode`, `:config` — and it is what
the retry policy decides on. The driver retries `:transport` and `:timeout` failures, and
`:server` ones whose status says "not now", but only for requests that are safe
to repeat: a write is never sent twice. [Errors and
retries](errors-and-retries.md) has the whole table, and
`test/typedb/fault_retry_test.exs` pins every line of it.

## Where to go next

- **[Transactions](transactions.md)** — the three types, one-shot versus
  explicit, and what a commit does and does not promise.
- **[Errors and retries](errors-and-retries.md)** — what the driver retries for
  you, what it cannot, and how to bound what a call can cost.
- **[Recipes](recipes.md)** — paging a `match` past TypeDB's 10,000-answer cap,
  bulk loading, upsert, counting without fetching, schema at boot.
- **[Telemetry and logging](observability.md)** — three levels of span and which
  one answers your question.
- **[Testing an application](testing.md)** — a database per test, when a stub is
  worth it, and making failures happen on purpose.
- **Limitations**, in the README — the things worth knowing before you meet them
  in production.
