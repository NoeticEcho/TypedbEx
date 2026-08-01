defmodule TypeDB.SoakIntegrationTest do
  @moduledoc """
  Concurrency, against an ordinary server, bounded to fit in a CI job.

  The CHANGELOG has published numbers for 200-way bursts and concurrent writes
  since 0.1.0, and they were produced by hand from a scratch directory that no
  longer exists. A claim nobody re-runs is decoration.

  The wider, nastier version of this — bursts straddling a token expiry — lives
  in `TypeDB.TokenRenewalIntegrationTest`, which needs a second server whose
  tokens expire in seconds. This one needs nothing that an ordinary integration
  run does not already have, so it runs on every push.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.{Database, Transaction}

  @readers 200
  @writers 100

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_soak

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    Process.unlink(pid)

    database = "soak_#{System.unique_integer([:positive])}"
    :ok = Database.create(name, database)

    {:ok, _} =
      TypeDB.query(name, database, "define attribute name, value string; entity person, owns name;")

    on_exit(fn ->
      _ = Database.delete(name, database)

      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: name, database: database}
  end

  test "#{@readers} concurrent reads through one connection all succeed", %{
    conn: conn,
    database: database
  } do
    # Requests run in the caller's process, so this is N processes issuing N
    # requests — the connection is consulted only for the token. If it were a
    # bottleneck, or if token handling were not concurrency-safe, this is where
    # it would show.
    failures =
      1..@readers
      |> Task.async_stream(
        fn _ ->
          TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
        end,
        max_concurrency: @readers,
        timeout: 120_000
      )
      |> Enum.reject(&match?({:ok, {:ok, _}}, &1))

    assert failures == [],
           "#{length(failures)}/#{@readers} reads failed, e.g. #{inspect(Enum.take(failures, 2))}"
  end

  test "#{@writers} concurrent writes all land, exactly once each", %{
    conn: conn,
    database: database
  } do
    names = for i <- 1..@writers, do: "soak-#{i}"

    failures =
      names
      |> Task.async_stream(
        fn name ->
          TypeDB.query(conn, database, ~s|insert $p isa person, has name "#{name}";|,
            transaction_type: :write
          )
        end,
        max_concurrency: 50,
        timeout: 120_000
      )
      |> Enum.reject(&match?({:ok, {:ok, _}}, &1))

    assert failures == [],
           "#{length(failures)}/#{@writers} writes failed, e.g. #{inspect(Enum.take(failures, 2))}"

    # Not "at least once": a driver that retried a write would show up here as a
    # duplicate, which is the failure mode the per-operation retry rule exists
    # to prevent.
    written =
      conn
      |> TypeDB.query!(database, "match $p isa person, has name $n; select $n;", transaction_type: :read)
      |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
      # Filtered by prefix: the tests share one database and ExUnit orders them
      # by seed, so "every person in the database" is whichever tests ran first.
      |> Enum.filter(&String.starts_with?(&1, "soak-"))

    assert Enum.sort(written) == Enum.sort(names)
  end

  test "concurrent explicit transactions each commit or fail cleanly", %{
    conn: conn,
    database: database
  } do
    results =
      1..25
      |> Task.async_stream(
        fn i ->
          TypeDB.transaction(conn, database, :write, fn tx ->
            Transaction.query!(tx, ~s|insert $p isa person, has name "tx-#{i}";|)
            :ok
          end)
        end,
        max_concurrency: 25,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Every outcome is either a clean commit or a TypeDB.Error. Nothing crashes,
    # nothing hangs, and no transaction is left open — the server's own
    # transaction timeout would hide that, so it is asserted rather than waited
    # out.
    for result <- results do
      assert result == :ok or match?({:error, %TypeDB.Error{}}, result),
             "unexpected transaction outcome: #{inspect(result)}"
    end

    committed = Enum.count(results, &(&1 == :ok))

    landed =
      conn
      |> TypeDB.query!(database, "match $p isa person, has name $n; select $n;", transaction_type: :read)
      |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
      |> Enum.count(&String.starts_with?(&1, "tx-"))

    assert landed == committed
  end
end
