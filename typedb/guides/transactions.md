# Transactions

## Three types, and why the default is the expensive one

| type | accepts | concurrency |
| --- | --- | --- |
| `:read` | `match`, `fetch`, `reduce` | concurrent with everything |
| `:write` | data changes and reads | concurrent with other writes |
| `:schema` | `define`, `undefine`, `redefine`, and everything above | **exclusive, database-wide** |

`TypeDB.query/4` defaults to `:schema`, because it is the only type that accepts
every kind of query and a default that rejects half of them would be a trap of a
different sort. It is also the type that takes TypeDB's exclusive schema lock, so
a one-shot query left on the default serialises against every other one.

Pass the type. It is the single highest-value option in this driver:

```elixir
TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)
TypeDB.query(conn, "social", ~s(insert $p isa person, has name "Alice";), transaction_type: :write)
TypeDB.query(conn, "social", "define entity dog;")   # :schema, deliberately
```

Narrowing also buys you a check: TypeDB answers `400 TSV9` to a write in a read
transaction and `400 TSV8` to a schema change in a write transaction, so a query
that drifted out of its type fails loudly instead of taking a lock nobody
intended.

`:schema_lock_acquire_timeout_millis` bounds how long a `:schema` transaction
waits for that lock — see `TypeDB.Options`.

## One-shot or explicit

`TypeDB.query/4` is one HTTP round trip: TypeDB opens the transaction, runs the
query, and commits or closes it. Nothing else can join it, which is what makes it
cheap.

`TypeDB.transaction/5` is at least three — open, your queries, commit — and buys
you the thing that matters: several statements that succeed or fail together.

```elixir
TypeDB.transaction(conn, "social", :write, fn tx ->
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Alice";))
  TypeDB.Transaction.query!(tx, ~s(insert $p isa person, has name "Bob";))
end)
```

The block commits on success and abandons on failure — any of `{:error, _}`,
a raise, a throw or an exit. A `:read` block is closed rather than rolled back,
because TypeDB rejects a rollback on a read transaction outright.

## What commit promises, and when it does not

Two things are worth knowing, and the second one surprises people.

**Constraint violations surface at query time, not at commit.** Inserting a
second entity that breaks a `@key` fails on the `insert` with `400 CNT9`, inside
the block, before you ever reach the commit. So a commit failing is *not* the
normal way you learn your data was wrong.

**A commit can still fail after your block succeeded**, because a concurrent
`:write` transaction touched the same data and committed first. TypeDB answers
the loser with `400 STC2` — "Transaction uses a lock held by a concurrent
commit" — and that surfaces as `{:error, %TypeDB.Error{}}` from `transaction/5`
even though your block returned happily.

`:max_retries` does not cover this, and cannot: it retries a request that never
reached the server, and a rejected commit reached it. The unit of retry here is
the whole block, which only you can re-run — against the state that won the
race, which is why re-running is the right answer rather than a hopeful one:

```elixir
defp with_retry(fun, attempts \\ 3)
defp with_retry(fun, 1), do: fun.()

defp with_retry(fun, attempts) do
  case fun.() do
    {:error, %TypeDB.Error{} = error} ->
      # `retryable?/1` covers STC2 as well as transport failures and timeouts.
      if TypeDB.Error.retryable?(error),
        do: with_retry(fun, attempts - 1),
        else: {:error, error}

    result ->
      result
  end
end

with_retry(fn ->
  TypeDB.transaction(conn, "social", :write, &move_money/1)
end)
```

## A transaction you opened yourself

`TypeDB.Transaction.open/4` hands you the handle and the responsibility.

```elixir
{:ok, tx} = TypeDB.Transaction.open(conn, "social", :write)

try do
  {:ok, _} = TypeDB.Transaction.query(tx, ~s(insert $p isa person;))
  :ok = TypeDB.Transaction.commit(tx)
after
  TypeDB.Transaction.close(tx)
end
```

`close/2` is idempotent and never fails on an already-finished transaction, which
is what makes it safe in an `after`. Everything *else* on a finished transaction
answers `404 TSV12`.

Note that `rollback/2` does not finish a transaction: it discards the writes and
leaves it open, so you can retry inside it. Cleanup is `close/2`.

Prefer `transaction/5` unless the transaction has to outlive a single function —
it does the `after` correctly, and it emits a `[:typedb, :transaction, …]` span
that tells you how long the unit of work held the transaction open.

## A timeout ends the transaction, not just the query

A request to a transaction that fails with `:timeout` or `:transport` takes the
transaction with it. The driver hangs up; TypeDB discards the transaction along
with the client that vanished. Afterwards:

```elixir
{:ok, tx} = TypeDB.Transaction.open(conn, "social", :write)
{:ok, _} = TypeDB.Transaction.query(tx, ~s(insert $p isa person, has name "Alice";))

TypeDB.Transaction.query(tx, slow_query, timeout: 300)
#=> {:error, %TypeDB.Error{kind: :timeout}}

TypeDB.Transaction.commit(tx)
#=> {:error, %TypeDB.Error{code: "TSV12", status: 404}}   # and Alice is gone
```

Nothing the transaction wrote is committed — the rollback happened server-side
without being asked for — and that is the useful half: a timeout mid-transaction
leaves no partial write to clean up. `close/2` still answers `:ok`.

**It is the hanging up that does this, not the slowness.** Measured against
3.12.1: the query above kills its transaction at `timeout: 300`, and the
identical query given `timeout: 120_000` runs for 80 seconds, returns its rows,
and commits. So a transaction that "does not survive" a long unit of work is a
`:timeout` set too tight rather than a server limit — raise the per-call
`:timeout`, and raise `transaction_timeout_millis` if the transaction as a whole
is the thing running long.

Cleanup is not free either: the server finishes the abandoned query before
answering, so the `close/2` after that timeout blocked for about 3.6 s. Worth
knowing if the `after` block runs under a deadline of its own.

`transaction/5` needs none of this. It reports the error from your block rather
than from its own cleanup, so you get the `:timeout` — which
`TypeDB.Error.retryable?/1` calls retryable, correctly: the transaction is gone
and nothing it did survived, so re-running the block is exactly right.

## The transaction is not a process

A `%TypeDB.Transaction{}` is a struct holding an id. It is not linked to
anything, it holds no state of its own, and it can be passed between processes
freely. The consequence worth remembering: nothing on the client side stops two
processes using the same transaction concurrently, and TypeDB will not thank you
for it. Keep a transaction in one process.
