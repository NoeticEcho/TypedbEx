defmodule TypeDB.TransactionLifetimeIntegrationTest do
  @moduledoc """
  What `transaction_timeout_millis` actually is, and what it does to a walk.

  The driver documented it as an idle timer for four releases. It is not one: it
  is a lifetime counted from the moment the transaction opens, and requests do
  not reset it. That distinction is invisible to `query/4`, which opens and
  closes a transaction per call, and decisive for `TypeDB.stream/4`, which holds
  one open for the whole walk — so the claim is pinned here rather than left in
  a docstring for the next reader to re-derive.

  Every test in this file spends real wall-clock time waiting for a server-side
  timer. That is the measurement; there is no faster way to take it.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.{Database, Transaction}

  # Enough rows that a slow consumer spends longer walking than the budget it is
  # given, and few enough that the whole file stays under half a minute.
  @rows 3_000
  @page_size 200

  @schema "define attribute name, value string; entity person, owns name @key;"
  @walk "match $p isa person, has name $n; sort $n; select $n;"

  setup_all do
    {:ok, _pid} = TypeDB.start_link([name: :typedb_lifetime_integration] ++ connection_options())

    database = TypeDB.Case.unique_name("lifetime_test")
    :ok = Database.create(:typedb_lifetime_integration, database)
    {:ok, _} = TypeDB.query(:typedb_lifetime_integration, database, @schema)
    insert(:typedb_lifetime_integration, database, @rows)

    # The connection is linked to the process running `setup_all`, and that
    # process is gone by the time `on_exit` runs — so the cleanup cannot use it.
    # One throwaway connection of its own is what makes the drop actually
    # happen instead of logging two failed attempts and leaving the database
    # behind.
    on_exit(fn ->
      {:ok, cleanup} = TypeDB.start_link([name: :typedb_lifetime_cleanup] ++ connection_options())
      Database.delete(:typedb_lifetime_cleanup, database)
      TypeDB.stop(cleanup)
    end)

    {:ok, conn: :typedb_lifetime_integration, database: database}
  end

  defp connection_options do
    [
      url: System.fetch_env!("TYPEDB_INTEGRATION_URL"),
      username: System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin"),
      password: System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password"),
      timeout: 60_000,
      http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
    ]
  end

  defp insert(conn, database, count) do
    rows = for i <- 1..count, do: %{"n" => "p#{String.pad_leading("#{i}", 6, "0")}"}

    {:ok, _} =
      TypeDB.query(conn, database, "given $n: string; insert $p isa person, has name == $n;",
        transaction_type: :write,
        given_rows: rows,
        timeout: 60_000
      )
  end

  test "the budget is a lifetime, and a request does not reset it", %{
    conn: conn,
    database: database
  } do
    {:ok, tx} = Transaction.open(conn, database, :read, transaction_timeout_millis: 5_000)
    opened_at = System.monotonic_time(:millisecond)

    # Every gap is two seconds, so the transaction is never idle for anything
    # like five. An idle timer would keep it alive indefinitely.
    outcome =
      Enum.reduce_while(1..6, :alive, fn _, _ ->
        Process.sleep(2_000)

        case Transaction.query(tx, "match $p isa person, has name $n; select $n; limit 1;") do
          {:ok, _} -> {:cont, :alive}
          {:error, error} -> {:halt, {:dead, System.monotonic_time(:millisecond) - opened_at, error}}
        end
      end)

    _ = Transaction.close(tx)

    assert {:dead, elapsed, %TypeDB.Error{code: "TSV12"}} = outcome

    assert elapsed >= 5_000,
           "the transaction died at #{elapsed} ms, before its own 5,000 ms budget"

    assert elapsed < 12_000,
           "the transaction survived #{elapsed} ms of a 5,000 ms budget, so the timer did reset"
  end

  test "a walk slower than its budget dies mid-stream with TSV12", %{
    conn: conn,
    database: database
  } do
    error =
      assert_raise TypeDB.Error, fn ->
        conn
        |> TypeDB.stream(database, @walk, page_size: @page_size, transaction_timeout_millis: 4_000)
        # Two milliseconds a row over 3,000 rows is six seconds of consumer, in
        # a transaction allowed four.
        |> Stream.map(fn row -> Process.sleep(2) && row end)
        |> Enum.count()
      end

    assert error.code == "TSV12"
    assert error.kind == :server
  end

  test "the same walk finishes when the budget covers it", %{conn: conn, database: database} do
    walked =
      conn
      |> TypeDB.stream(database, @walk, page_size: @page_size, transaction_timeout_millis: 30_000)
      |> Stream.map(fn row -> Process.sleep(2) && row end)
      |> Enum.count()

    assert walked == @rows
  end

  test "a fast consumer never meets the budget at all", %{conn: conn, database: database} do
    walked =
      conn
      |> TypeDB.stream(database, @walk, page_size: @page_size, transaction_timeout_millis: 4_000)
      |> Enum.count()

    assert walked == @rows
  end
end
