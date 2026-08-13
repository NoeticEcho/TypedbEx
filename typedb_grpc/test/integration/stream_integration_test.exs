defmodule TypeDB.GRPC.StreamIntegrationTest do
  @moduledoc """
  Streamed reads and the facade, against a real server.

  The assertions worth reading are the ones about *not* doing work: an early
  `Enum.take/2` must not pull the rest of the answer, and building a stream must
  not talk to the server at all. Those are what distinguish a stream from a list
  with extra steps, and they are cheap to lose silently.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.GRPC.Transaction

  @rows 25_000

  setup_all do
    if address(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip] do
      :ok
    else
      conn = start_connection()
      database = start_database(conn)

      {:ok, _} =
        TypeDB.GRPC.query(conn, database, "define attribute name, value string; entity person, owns name;")

      {:ok, _} =
        TypeDB.GRPC.query(conn, database, "given $n: string; insert $p isa person, has name == $n;",
          transaction_type: :write,
          given_rows: for(i <- 1..@rows, do: %{"n" => "p#{i}"}),
          timeout: 300_000
        )

      {:ok, conn: conn, database: database}
    end
  end

  @query "match $p isa person, has name $n; select $n;"

  describe "the facade" do
    test "query/4 runs a query in a transaction of its own", %{conn: conn, database: database} do
      assert {:ok, answer} =
               TypeDB.GRPC.query(conn, database, "match $p isa person; reduce $c = count;",
                 transaction_type: :read
               )

      assert answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c") == @rows
    end

    test "query!/4 raises rather than returning an error", %{conn: conn, database: database} do
      assert_raise TypeDB.Error, fn ->
        TypeDB.GRPC.query!(conn, database, "not typeql", transaction_type: :read)
      end
    end

    test "the administrative delegates reach the same functions", %{conn: conn} do
      name = "facade_#{System.unique_integer([:positive])}"
      on_exit(fn -> TypeDB.GRPC.delete_database(conn, name) end)

      assert {:ok, names} = TypeDB.GRPC.databases(conn)
      assert is_list(names)
      assert :ok = TypeDB.GRPC.create_database_if_not_exists(conn, name)
      assert :ok = TypeDB.GRPC.create_database_if_not_exists(conn, name)
      assert :ok = TypeDB.GRPC.health(conn)
      assert {:ok, %{version: _}} = TypeDB.GRPC.version(conn)
      assert TypeDB.GRPC.running?(conn)
      assert :ok = TypeDB.GRPC.delete_database(conn, name)
    end
  end

  describe "streaming" do
    test "reads every row", %{conn: conn, database: database} do
      assert TypeDB.GRPC.stream(conn, database, @query) |> Enum.count() == @rows
    end

    test "rows arrive decoded, as they do from a collected answer", %{conn: conn, database: database} do
      [row | _] = TypeDB.GRPC.stream(conn, database, @query) |> Enum.take(1)

      assert %TypeDB.ConceptRow{} = row
      assert is_binary(TypeDB.ConceptRow.typed_value(row, "n"))
    end

    test "building a stream talks to nobody", %{conn: conn, database: database} do
      # A stream that connected eagerly would make `stream |> Enum.take(0)` cost
      # a transaction, and would make an unconsumed stream leak one.
      before = database_count(conn)
      _stream = TypeDB.GRPC.stream(conn, database, @query)
      assert database_count(conn) == before
    end

    test "stopping early stops the server, rather than reading on", %{conn: conn, database: database} do
      # The assertion the whole design is for, and it took two attempts to write
      # honestly. Timing does not prove it: an eager implementation also answers
      # `Enum.take(5)` quickly, because the consumer stops while the server keeps
      # filling a buffer behind it. What distinguishes the two is whether the
      # server was asked for more — so this looks.
      {:ok, tx} = Transaction.open(conn, database, :read)
      on_exit(fn -> Transaction.close(tx) end)

      {:ok, ref} = Transaction.stream_start(tx, @query, [])
      assert {:rows, rows} = Transaction.stream_next(tx, ref, 60_000)
      assert rows != []

      # Long enough that an unpaused server would have sent a great deal more.
      Process.sleep(500)

      buffered = :sys.get_state(tx.pid).pending |> Map.fetch!(ref) |> Map.fetch!(:buffer) |> length()

      assert buffered <= length(rows),
             """
             After one batch of #{length(rows)} rows was taken from an answer of #{@rows}, the
             transaction is holding #{buffered} more half a second later.

             That means the continuation signal went out on arrival rather than on
             demand: the server is racing ahead and this stream is a list with extra
             steps. `serve_stream/3` is where the signal belongs.
             """
    end

    test "a stream closes its transaction, early or not", %{conn: conn, database: database} do
      # `Stream.resource/3` runs its after-fun on an early halt too, and if it
      # did not, every truncated read would leak a transaction until the server
      # timed it out.
      stream = TypeDB.GRPC.stream(conn, database, @query)
      assert [_ | _] = Enum.take(stream, 3)

      # Nothing to inspect from outside, so this asserts the observable
      # consequence: the same connection can immediately open and use another.
      assert {:ok, _} =
               TypeDB.GRPC.query(conn, database, "match $p isa person; reduce $c = count;",
                 transaction_type: :read
               )
    end

    test "a stream of a query that answers nothing ends rather than hanging", %{
      conn: conn,
      database: database
    } do
      assert TypeDB.GRPC.stream(conn, database, "match $p isa person; limit 0; select $p;")
             |> Enum.to_list() == []
    end

    test "a query that does not parse raises out of the stream", %{conn: conn, database: database} do
      assert_raise TypeDB.Error, ~r/TQL0|parse|expected/i, fn ->
        TypeDB.GRPC.stream(conn, database, "this is not typeql") |> Enum.to_list()
      end
    end

    test "streaming inside a transaction leaves the transaction open", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :read)
      on_exit(fn -> Transaction.close(tx) end)

      assert Transaction.stream(tx, @query) |> Enum.take(3) |> length() == 3
      assert Transaction.open?(tx), "Transaction.stream/3 must not close what it did not open"

      assert {:ok, _} = Transaction.query(tx, "match $p isa person; reduce $c = count;")
    end

    test "two streams on one transaction do not confuse each other", %{conn: conn, database: database} do
      # The multiplexing, exercised where it can actually go wrong: both reads
      # are in flight on one stream, correlated only by req_id.
      {:ok, tx} = Transaction.open(conn, database, :read)
      on_exit(fn -> Transaction.close(tx) end)

      a = Transaction.stream(tx, ~s|match $p isa person, has name == "p1"; select $p;|)
      b = Transaction.stream(tx, ~s|match $p isa person, has name == "p2"; select $p;|)

      assert length(Enum.to_list(a)) == 1
      assert length(Enum.to_list(b)) == 1
    end

    test "a streamed answer is not smaller than a collected one", %{conn: conn, database: database} do
      # The two paths decode differently — one row at a time against all at the
      # end — so they are compared rather than assumed equal.
      streamed =
        TypeDB.GRPC.stream(conn, database, @query) |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "n"))

      {:ok, answer} = TypeDB.GRPC.query(conn, database, @query, transaction_type: :read, timeout: 300_000)
      collected = answer |> TypeDB.Answer.rows() |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "n"))

      assert length(streamed) == length(collected)
      assert Enum.sort(streamed) == Enum.sort(collected)
    end
  end

  defp database_count(conn) do
    {:ok, names} = TypeDB.GRPC.databases(conn)
    length(names)
  end
end
