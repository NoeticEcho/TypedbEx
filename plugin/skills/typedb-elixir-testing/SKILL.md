---
name: typedb-elixir-testing
description: Test Elixir code that talks to TypeDB — an ExUnit case template with a database per test, deciding between a real server and a stub, faking at your own boundary instead of faking the driver, and provoking timeouts and transport failures through a custom TypeDB.HTTP adapter. Use when writing or fixing tests for code that queries TypeDB, setting up CI for it, or when such tests are flaky or order-dependent.
---

# Testing Elixir code that uses TypeDB

Two honest approaches, answering different questions: a real server tells the
truth, and a stub is fast and lies when you are not looking. Most suites want
both, plus a seam of your own so that most tests need neither.

## A database per test, against a real server

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

    {:ok, _} =
      TypeDB.query(MyApp.TypeDB, database, File.read!("priv/schema.tql"),
        transaction_type: :schema
      )

    on_exit(fn -> TypeDB.Database.delete(MyApp.TypeDB, database) end)

    {:ok, database: database}
  end
end
```

Creating a database is cheap; sharing one is what makes tests ordered. The two
facts that are specific to TypeDB, and that decide how fast the suite runs:

- A `:schema` transaction takes a **database-wide** lock, so schema-loading tests
  serialise with each other however `async` is set.
- `TypeDB.query/4` defaults to `:schema`, so tests left on the default serialise
  **even when they contain no schema at all**. Pass `transaction_type: :read` or
  `:write` in tests, for the same reason you do in production code.

Bring the server up with Docker locally and a service container in CI:

```shell
docker run --name typedb -p 1729:1729 -p 8000:8000 -d typedb/typedb:3.12.1
```

TypeDB 3.12 is the floor for the `typedb` package: 3.11.5 has no `given` stage,
which is what makes parameterised queries safe.

## Two traps that cost a morning each

**A connection is a named process with a named ETS table.** Two async tests that
both start a connection called `TypeDB` will fight. Name them uniquely:

```elixir
name = :"conn_#{System.unique_integer([:positive])}"
```

**`capture_log/1` captures the whole VM.** A test asserting the driver logged
nothing will read the log lines of every async test running beside it. Put
logging assertions in an `async: false` module.

## Fake at your own boundary, not at the driver

For unit tests of the code *around* the queries, the cheapest seam is a
behaviour of your own:

```elixir
defmodule MyApp.People do
  @callback fetch(String.t()) :: {:ok, [map()]} | {:error, term()}

  def fetch(name), do: impl().fetch(name)
  defp impl, do: Application.get_env(:my_app, :people, MyApp.People.TypeDB)
end
```

Those tests then assert on your own domain shapes rather than on
`%TypeDB.ConceptRow{}`, and the TypeDB-shaped tests stay in one module that runs
against a real server. This is almost always better than mocking the driver:
a mock of `TypeDB.query/4` asserts that you called a function, not that the
query is correct.

## If you stub, keep it honest

A stub that speaks TypeDB's HTTP API in-process makes a suite hermetic and fast.
It also drifts. In this driver's own history five stubbed error codes turned out
to be **invented**, and every one was asserted by a passing test — so the suite
agreed with itself and with nothing else. They were found by running the same
assertions against a live server.

So: if you stub, keep an integration suite that checks the stub's claims, and
when they disagree, the server is right.

## Provoke the failure paths

Most bugs live in what happens when TypeDB does not answer, and those paths are
unreachable against a healthy server. The transport is a behaviour, so you can
arrange the failure:

```elixir
defmodule FlakyAdapter do
  @behaviour TypeDB.HTTP

  def init(name, opts) do
    {inner, inner_opts} = Keyword.fetch!(opts, :inner)

    with {:ok, state} <- inner.init(name, inner_opts) do
      {:ok, {inner, state, :counters.new(1, [])}}
    end
  end

  def request({inner, state, counter}, method, url, headers, body, opts) do
    :counters.add(counter, 1, 1)

    if :counters.get(counter, 1) <= 2 do
      {:error, TypeDB.Error.new(:transport, "the network ate it")}
    else
      inner.request(state, method, url, headers, body, opts)
    end
  end

  def terminate({inner, state, _counter}), do: inner.terminate(state)
  def owner({inner, state, _counter}), do: inner.owner(state)
end

TypeDB.start_link(
  name: :flaky,
  url: "http://localhost:8000",
  username: "admin",
  password: System.fetch_env!("TYPEDB_PASSWORD"),
  # Two injected failures need two retries. The default is one, which would
  # make this test exercise the give-up path instead — count the failures you
  # inject against `:max_retries`, not against attempts.
  max_retries: 2,
  http: {FlakyAdapter, [inner: {TypeDB.HTTP.Finch, []}]}
)
```

Two failures then a success exercises the retry path end to end. Failing every
time exercises the give-up path, including the warning and the
`[:typedb, :retry, :exhausted]` telemetry event.

`TypeDB.HTTP` requires `init/2`, `request/6`, `terminate/1` and `owner/1`. An
adapter may also raise, throw or exit: the driver contains all three and turns
them into a `%TypeDB.Error{}`, and asserting that it does is a test worth having
if you write your own adapter.

## What to assert

- Branch and assert on `%TypeDB.Error{}`'s `:code` (TypeDB's own) or `:kind`
  (`:server`, `:transport`, `:timeout`, `:unauthenticated`, `:decode`,
  `:encode`, `:config`). **Never assert on the message text** — it is explicitly
  outside the driver's version promise.
- Assert that user input goes through `given_rows`, not through interpolation.
  A test that inserts a name containing `"` and a `;` and still reads it back is
  the one that catches an interpolated query.
- For telemetry, attach a handler in `setup`, **detach it in `on_exit`**, and
  match on the connection name — a global handler otherwise reads another
  test's events.

## Reference

- Testing guide: <https://hexdocs.pm/typedb/testing.html>
- Errors and retries: <https://hexdocs.pm/typedb/errors-and-retries.html>
- `TypeDB.HTTP` behaviour: <https://hexdocs.pm/typedb/TypeDB.HTTP.html>
