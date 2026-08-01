# Testing an application against TypeDB

There are two honest ways to test code that talks to TypeDB, and they answer
different questions.

## A real server

The one that tells the truth. `docker compose up -d` in this repository brings up
TypeDB 3.12.1 on `:8000`; in yours, a service container in CI does the same job.

```elixir
# test/support/database_case.ex
defmodule MyApp.DatabaseCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MyApp.DatabaseCase
    end
  end

  setup do
    # A database per test, dropped afterwards. Faster than it sounds, and it
    # removes the whole class of tests that pass alone and fail together.
    database = "test_#{System.unique_integer([:positive])}"
    :ok = TypeDB.Database.create(MyApp.TypeDB, database)
    {:ok, _} = TypeDB.query(MyApp.TypeDB, database, File.read!("priv/schema.tql"))

    on_exit(fn -> TypeDB.Database.delete(MyApp.TypeDB, database) end)

    {:ok, database: database}
  end
end
```

Creating a database is cheap; sharing one between tests is what is expensive,
because it makes them ordered.

Two things to know before you point this at anything you care about: a `:schema`
transaction takes a database-wide lock, so schema-loading tests serialise; and
`TypeDB.query/4` defaults to `:schema`, so tests left on the default serialise
even when they contain no schema at all.

## A stub

The one that is fast, hermetic, and lies when you are not looking.

This repository's own suite runs against `TypeDB.Stub`, a real HTTP/1.1 server
that speaks the TypeDB API in-process — which is why `mix test` needs no
database. That approach is worth copying, and so is the discipline that goes
with it: **a stub is only useful while it behaves like the server**. Five of this
driver's stubbed error codes turned out to be invented, and every one of them was
asserted by a passing test, so the suite agreed with itself and with nothing
else. They were found by running the same assertions against a live server.

If you stub, keep an integration suite that checks the stub's claims, and treat
the server as right when they disagree.

## Faking the driver

For unit tests of code *around* the queries, the cheapest seam is a behaviour of
your own, not a fake TypeDB:

```elixir
defmodule MyApp.People do
  @callback fetch(String.t()) :: {:ok, [map()]} | {:error, term()}

  def fetch(name), do: impl().fetch(name)
  defp impl, do: Application.get_env(:my_app, :people, MyApp.People.TypeDB)
end
```

Your tests then assert on your own domain shapes rather than on
`%TypeDB.ConceptRow{}`, and the TypeDB-shaped tests stay in one module that runs
against a real server.

## Testing the failure paths

Most bugs live in what happens when TypeDB does not answer, and those paths are
hard to reach against a healthy server. The driver's transport is pluggable, so
you can arrange the failure:

```elixir
defmodule FlakyAdapter do
  @behaviour TypeDB.HTTP

  def init(name, opts) do
    {inner, inner_opts} = Keyword.fetch!(opts, :inner)
    with {:ok, state} <- inner.init(name, inner_opts), do: {:ok, {inner, state, :counters.new(1, [])}}
  end

  def request({inner, state, counter}, method, url, headers, body, opts) do
    :counters.add(counter, 1, 1)

    if :counters.get(counter, 1) <= 2 do
      {:error, TypeDB.Error.new(:transport, "the network ate it")}
    else
      inner.request(state, method, url, headers, body, opts)
    end
  end
end

TypeDB.start_link(
  name: :flaky,
  url: "http://localhost:8000",
  username: "admin",
  password: "password",
  http: {FlakyAdapter, [inner: {TypeDB.HTTP.Finch, []}]}
)
```

Two failures then a success exercises the retry path end to end. Returning the
error every time exercises the give-up path, including the `:warning` and the
`[:typedb, :retry, :exhausted]` event.

An adapter may also raise, throw or exit: the driver contains all three and turns
them into a `%TypeDB.Error{}`, and asserting that it does is a test worth having
if you write your own adapter.

## Two traps

**`capture_log/1` captures the whole VM.** A test asserting that the driver
logged nothing will read the log lines of every async test running beside it.
Put logging assertions in an `async: false` module.

**A connection is a named process with a named ETS table.** Two tests that both
start a connection called `TypeDB` will fight. Name them uniquely:

```elixir
name = :"conn_#{System.unique_integer([:positive])}"
```
