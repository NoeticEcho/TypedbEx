defmodule TypeDB.TransactionProcessIntegrationTest do
  @moduledoc """
  Checks the promise `TypeDB.Transaction`'s moduledoc opens with:

  > A transaction is a lightweight handle: an id plus the connection it belongs
  > to. It is a plain struct, not a process, so it can be passed between
  > processes freely — TypeDB tracks the transaction server-side.

  That sentence is load-bearing. It is why a transaction can be handed to a
  `Task`, why a `GenServer` can hold one open across calls, and why the driver
  does not have to own a process per transaction. Nothing checked it: the unit
  suite runs every transaction in the process that opened it, so the stub would
  have agreed with the claim no matter what the server does.

  It is also not the driver's promise alone to keep. Even though the handle is
  plainly a struct with no pid in it, the server could bind a transaction to the
  connection that opened it, or to the socket a request arrived on, and any of
  the three adapters could hold per-process state below us. Those are the things
  this file rules out, against a live server, once per version in the matrix.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set; see `TypeDB.IntegrationTest`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias TypeDB.{Answer, ConceptRow, Database, Transaction}

  @concurrent 20

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_transaction_processes

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    Process.unlink(pid)

    database = "tx_processes_#{System.unique_integer([:positive])}"
    :ok = Database.create(name, database)

    {:ok, _} =
      TypeDB.query(name, database, "define attribute name, value string; entity person, owns name @key;")

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

  setup %{conn: conn, database: database} do
    # Each test asserts on the whole table, so each starts from an empty one.
    on_exit(fn ->
      {:ok, _} =
        TypeDB.query(conn, database, "match $p isa person; delete $p;", transaction_type: :write)
    end)

    :ok
  end

  test "a handle opened here can be used, and committed, elsewhere", %{
    conn: conn,
    database: database
  } do
    {:ok, tx} = Transaction.open(conn, database, :write)

    # Three different processes, none of them the one that opened it.
    assert {:ok, _} =
             Task.async(fn -> Transaction.query(tx, "insert $p isa person, has name 'passed';") end)
             |> Task.await()

    assert :ok = Task.async(fn -> Transaction.commit(tx) end) |> Task.await()

    assert names(conn, database) == ["passed"]
  end

  test "one handle used concurrently by many processes", %{conn: conn, database: database} do
    # The interesting half: not "another process" but "several at once", which
    # is what a `Task.async_stream` over a transaction actually does. If the
    # server serialised requests per transaction we would still expect them all
    # to succeed — this fails when one of them is rejected for arriving on the
    # wrong connection, or when an adapter loses a response under concurrency.
    {:ok, tx} = Transaction.open(conn, database, :write)

    results =
      1..@concurrent
      |> Task.async_stream(
        fn n -> Transaction.query(tx, "insert $p isa person, has name 'c#{n}';") end,
        max_concurrency: @concurrent,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> elem(result, 0) end)
      |> Enum.frequencies()

    assert results == %{ok: @concurrent}
    assert :ok = Transaction.commit(tx)
    assert length(names(conn, database)) == @concurrent
  end

  test "a transaction outlives the process that opened it", %{conn: conn, database: database} do
    # The case a supervised worker hits: it opens a transaction, hands it on and
    # dies before the commit point. Requests run in the caller's process, so
    # there is nothing left of the opener by the time we commit — if the
    # transaction were tied to it, this is where that would show.
    test = self()

    opener =
      spawn(fn ->
        {:ok, tx} = Transaction.open(conn, database, :write)
        {:ok, _} = Transaction.query(tx, "insert $p isa person, has name 'orphan';")
        send(test, {:tx, tx})
        Process.sleep(:infinity)
      end)

    assert_receive {:tx, tx}, 30_000

    reference = Process.monitor(opener)
    Process.exit(opener, :kill)
    assert_receive {:DOWN, ^reference, :process, ^opener, :killed}, 5_000

    assert :ok = Transaction.commit(tx)
    assert names(conn, database) == ["orphan"]
  end

  defp names(conn, database) do
    {:ok, answer} =
      TypeDB.query(conn, database, "match $p isa person, has name $n; select $n; sort $n;",
        transaction_type: :read
      )

    Enum.map(Answer.rows(answer), &ConceptRow.value(&1, "n"))
  end
end
