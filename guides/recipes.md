# Recipes

The other guides explain how the driver behaves. This one is the things an
application actually needs and has to work out for itself: paging, bulk loading,
upsert, counting, mapping rows onto your own structs, and getting a schema in
place at boot.

Every recipe here was run against a live TypeDB 3.12.1, and the numbers are from
that run. `conn` below is a connection name.

## Read a match that is bigger than one answer

TypeDB caps a read at **10,000 answers** and attaches a warning rather than
failing, so the naive version of this is wrong in a way you will not notice:

```elixir
# Wrong for any table that might grow. You get the first 10,000 rows and a
# warning that the driver logs and your code ignores.
{:ok, answer} = TypeDB.query(conn, "social", "match $p isa person, has name $n; select $n;",
  transaction_type: :read)
```

Page it. TypeQL has `offset` and `limit`, and **`sort` is not optional** — a
`match` makes no promise about order, so paging without one is free to skip rows
and repeat others between calls:

```elixir
defp page(conn, offset, size) do
  {:ok, answer} =
    TypeDB.query(conn, "social", """
      match $p isa person, has name $n;
      select $n;
      sort $n;
      offset #{offset};
      limit #{size};
    """, transaction_type: :read)

  Enum.map(answer, &TypeDB.ConceptRow.value(&1, "n"))
end
```

`offset` interpolated into the query is safe — it is a number you computed, not
input. Anything that came from a user belongs in `given_rows`; see
[Parameterised queries](readme.html#parameterised-queries).

A whole result set as a `Stream`, so the caller decides how much to hold:

```elixir
def stream(conn, size \\ 1_000) do
  Stream.resource(
    fn -> 0 end,
    fn offset ->
      case page(conn, offset, size) do
        [] -> {:halt, offset}
        names -> {names, offset + length(names)}
      end
    end,
    fn _offset -> :ok end
  )
end
```

20,000 rows, in pages of 1,000: **1019ms**, and constant memory rather than the
[897 bytes per row](readme.html#limitations) that arriving whole would cost.

**A deep offset is not expensive here**, which is worth saying because SQL
teaches the opposite. Paging 20,000 sorted rows: 53ms at offset 0, 41ms at
10,000, 38ms at 19,900. Flat, not linear.

Each page is its own transaction, so a write between two pages can be seen by
one and not the other. When that matters, page inside a single `:read`
transaction, which holds one snapshot:

```elixir
TypeDB.transaction(conn, "social", :read, fn tx ->
  Enum.flat_map(0..9, fn n ->
    {:ok, answer} =
      TypeDB.Transaction.query(tx, """
        match $p isa person, has name $n;
        select $n;
        sort $n;
        offset #{n * 1_000};
        limit 1000;
      """)

    Enum.map(answer, &TypeDB.ConceptRow.value(&1, "n"))
  end)
end)
```

## Count without fetching

`reduce` counts on the server, which is the difference between one number and
ten thousand rows over the wire:

```elixir
{:ok, answer} = TypeDB.query(conn, "social", "match $p isa person; reduce $n = count;",
  transaction_type: :read)

answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("n")
#=> 20000
```

This is also the honest way to check a truncated read: `count` says 20,000 where
the `match` gave you 10,000.

For "does this exist", stop at one rather than counting everything:

```elixir
{:ok, answer} =
  TypeDB.query(conn, "social", """
    given $e: string;
    match $p isa person, has email == $e;
    limit 1;
  """, transaction_type: :read, given_rows: [%{"e" => email}])

TypeDB.Answer.rows(answer) != []
```

## Load a lot of rows

One request with a `given` stage, in batches. Not one request per row, and not
one enormous query string — see [the numbers](readme.html#parameterised-queries)
for why the middle option is the one people reach for and the wrong one:

```elixir
people
|> Stream.map(fn person -> %{"n" => person.name, "a" => person.age} end)
|> Stream.chunk_every(2_000)
|> Enum.each(fn batch ->
  {:ok, _} =
    TypeDB.query(conn, "social", """
      given $n: string, $a: integer;
      insert $p isa person, has name == $n, has age == $a;
    """, transaction_type: :write, given_rows: batch)
end)
```

20,000 rows in batches of 2,000: **2468ms**, about 8,100 rows a second.

**The ceiling is bytes, not rows.** TypeDB refuses a request body over
**2 MiB** — bisected against 3.12.1, 2047 KiB is accepted and 2048 KiB is not —
and there is no server flag for it. 2,000 rows of two short attributes is
620 KiB and comfortable; the same 2,000 rows carrying a kilobyte of text each is
not. Batch on the size of what you are sending:

```elixir
people
|> Stream.map(&%{"n" => &1.name, "t" => &1.note})
|> Stream.chunk_while(
     {[], 0},
     fn row, {batch, bytes} ->
       size = byte_size(row["n"]) + byte_size(row["t"]) + 64

       # Well under 2 MiB: the tagged wire form and the query travel with it,
       # and being wrong here is expensive — see below.
       if bytes + size > 1_500_000,
         do: {:cont, Enum.reverse(batch), {[row], size}},
         else: {:cont, {[row | batch], bytes + size}}
     end,
     fn {[], _bytes} -> {:cont, []}
        {batch, _bytes} -> {:cont, Enum.reverse(batch), {[], 0}}
     end
   )
|> Enum.each(fn batch ->
  {:ok, _} =
    TypeDB.query(conn, "social", """
      given $n: string, $t: string;
      insert $p isa person, has name == $n, has note == $t;
    """, transaction_type: :write, given_rows: batch)
end)
```

Being wrong about it fails in two different ways, and only one of them is
obvious. A body a little over the line comes back as `400 HSR2` — *"Failed to
buffer the request body: length limit exceeded"* — which says what happened. A
body far over it (15 MiB, say) makes the server close the socket instead, and
the driver can only report that as a `:transport` failure, which
`TypeDB.Error.retryable?/1` calls retryable, so `:max_retries` will send the
whole thing again to no purpose. **A bulk load that "times out" or reports a
closed socket, reproducibly, is a batch that is too big rather than a network
problem.**

Batch size is otherwise a trade between round trips and blast radius: each
request is its own transaction, so a batch that fails takes its rows with it
and leaves the ones before it committed. If the whole load has to be
all-or-nothing, open one `:write` transaction and send the batches through it —
but a transaction held open that long is also a transaction holding locks that
long.

## Upsert

**`put` inserts only if the whole pattern does not already match.** That makes
it the right tool for "make sure this exists" and the wrong one for "change
this":

```elixir
# Idempotent. Run it twice, get one person.
TypeDB.query(conn, "social", ~s(put $p isa person, has name "Alice", has age 30;),
  transaction_type: :write)
```

Run it again with `has age 31` and it does *not* update the age — the pattern no
longer matches, so `put` tries to insert a second Alice, and TypeDB rejects that
with `400 CNT9`:

    Constraint '@unique' has been violated: there is a conflict for value '"Alice"'.

To change an attribute, delete the old ownership and insert the new one in the
same query:

```elixir
TypeDB.query(conn, "social", """
  given $name: string, $age: integer;
  match $p isa person, has name == $name, has age $old;
  delete has $old of $p;
  insert $p has age == $age;
""", transaction_type: :write, given_rows: [%{"name" => "Alice", "age" => 31}])
```

Note `delete has $old of $p` rather than `delete $old`: the second deletes the
attribute itself, and attributes are values shared by everything that owns them,
so it would take the age off everyone who happened to be 30.

## Delete a lot of rows

`limit` inside the delete, until nothing comes back:

```elixir
Stream.repeatedly(fn ->
  {:ok, answer} =
    TypeDB.query(conn, "social", "match $p isa person; limit 2000; delete $p;",
      transaction_type: :write)

  length(TypeDB.Answer.rows(answer))
end)
|> Enum.take_while(&(&1 > 0))
```

20,000 rows: **1447ms**. One unbounded `delete` would have been one transaction
holding every lock it touched.

## Map rows onto your own structs

`to_struct/3` matches variable names to field names, and **the `select` stage is
what makes that possible** — a `match` binds the entity variable too, and `$p`
names no field of your struct:

```elixir
defmodule Person do
  defstruct [:name, :age]
end

conn
|> TypeDB.query!("social", """
     match $p isa person, has name $name, has age $age;
     select $name, $age;
   """, transaction_type: :read)
|> Enum.map(&TypeDB.ConceptRow.to_struct(&1, Person, typed: true))
#=> [%Person{name: "Alice", age: 30}, ...]
```

`typed: true` is what you want whenever a field holds a `decimal`, a `duration`
or a timestamp; without it those arrive as the strings TypeDB sent. A variable
with no matching field raises rather than being dropped, which is the whole
reason not to use `Kernel.struct/2` here.

## Get the schema in place at boot

**`define` is idempotent** — running it against a database that already has the
schema succeeds and changes nothing. So a migration on start-up is this, and
nothing more:

```elixir
defmodule MyApp.Schema do
  def migrate!(conn, database) do
    :ok = TypeDB.Database.create_if_not_exists(conn, database)
    {:ok, _} = TypeDB.query(conn, database, File.read!("priv/schema.tql"))
    :ok
  end
end
```

Two things to know before you run that on every boot of every node. A `define`
runs in a `:schema` transaction, which takes an exclusive database-wide lock, so
concurrent boots serialise rather than conflict — correct, but slow if there are
many of them. And `define` only adds; removing a type is `undefine`, and
changing one is neither. Treat `priv/schema.tql` as append-only and keep the
destructive steps somewhere a person has to run them.

`mix typedb.check` validates `.tql` files without a server, which is worth a CI
step if your schema lives in the repository.

## Retry a transaction that lost a race

Two concurrent `:write` transactions touching the same data end with the loser's
commit rejected. It is the one failure that is certain to be worth another
attempt, and it has its own recipe in
[Errors and retries](errors-and-retries.html#what-it-does-not-and-cannot).

## Read your own writes

A one-shot write commits before it returns, so the next read sees it. Inside
`transaction/5` the block sees its own writes and nobody else does until it
commits:

```elixir
TypeDB.transaction(conn, "social", :write, fn tx ->
  {:ok, _} = TypeDB.Transaction.query(tx, ~s(insert $p isa person, has name "Carol";))

  # Visible here, because it is the same transaction.
  {:ok, answer} = TypeDB.Transaction.query(tx, ~s(match $p isa person, has name "Carol";))
  1 = length(TypeDB.Answer.rows(answer))
end)
```

A `:read` transaction opened before that commit will not see it however long it
is held: it is a snapshot, which is what makes paging inside one safe.
