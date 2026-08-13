defmodule TypeDB.GRPC.TransactionIntegrationTest do
  @moduledoc """
  The transaction stream, against a real server.

  Everything interesting about this transport lives here: the multiplexing, the
  flow control, the absence of an answer cap, and the pipelining that makes a
  transaction of many operations worth having.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.GRPC.Transaction

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
        Transaction.transaction(conn, database, :schema, fn tx ->
          Transaction.query(tx, """
            define
              attribute name, value string;
              attribute age, value integer;
              attribute score, value double;
              attribute born, value date;
              entity person, owns name, owns age, owns score, owns born;
          """)
        end)

      {:ok, conn: conn, database: database}
    end
  end

  defp insert_people(conn, database, count) do
    {:ok, _} =
      Transaction.transaction(conn, database, :write, fn tx ->
        Transaction.query(tx, "given $n: string; insert $p isa person, has name == $n;",
          given_rows: for(i <- 1..count, do: %{"n" => "p#{i}"})
        )
      end)
  end

  describe "opening" do
    test "a type that does not exist is a caller error, not a server round trip", %{
      conn: conn,
      database: database
    } do
      assert_raise ArgumentError, ~r/invalid transaction type/, fn ->
        Transaction.open(conn, database, :readonly)
      end
    end

    test "a database that does not exist fails at open", %{conn: conn} do
      assert {:error, %TypeDB.Error{}} =
               Transaction.open(conn, "absent_#{System.unique_integer([:positive])}", :read)
    end

    test "the handle is a plain struct and works from another process", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :write)
      on_exit(fn -> Transaction.close(tx) end)

      # The property the sibling driver documents, kept: a transaction can be
      # handed to another process. Here it is a pid in a struct rather than an
      # id in one, but the handle still travels.
      task =
        Task.async(fn ->
          Transaction.query(tx, ~s|insert $p isa person, has name "from-elsewhere";|)
        end)

      assert {:ok, _} = Task.await(task)
      assert :ok = Transaction.commit(tx)
    end
  end

  describe "one transaction, several callers" do
    # Audit V, critical. The moduledoc promises the handle can be passed between
    # processes freely; the state held one `awaiting` slot, so the second caller
    # overwrote the first's `from`. The loser then waited out its timeout — and
    # the timeout path closed the transaction, so it destroyed the winner's work
    # on the way down.
    test "two processes querying one handle both get their own answer", %{
      conn: conn,
      database: database
    } do
      insert_people(conn, database, 20)

      {:ok, tx} = Transaction.open(conn, database, :read)
      on_exit(fn -> Transaction.close(tx) end)

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            Transaction.query(tx, ~s|match $p isa person, has name == "p#{i}"; select $p;|, timeout: 15_000)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      for {result, i} <- Enum.with_index(results, 1) do
        assert {:ok, answer} = result, "caller #{i} got #{inspect(result)}"
        assert length(TypeDB.Answer.rows(answer)) == 1
      end

      assert Transaction.open?(tx), "neither caller may take the transaction down"
    end

    test "many concurrent callers all answer", %{conn: conn, database: database} do
      insert_people(conn, database, 30)

      {:ok, tx} = Transaction.open(conn, database, :read)
      on_exit(fn -> Transaction.close(tx) end)

      results =
        1..12
        |> Task.async_stream(
          fn i ->
            Transaction.query(tx, ~s|match $p isa person, has name == "p#{i}"; select $p;|, timeout: 20_000)
          end,
          max_concurrency: 12,
          timeout: 40_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "#{Enum.count(results, &match?({:error, _}, &1))} of 12 concurrent callers failed"
    end
  end

  describe "answers" do
    test "a write reports what it did", %{conn: conn, database: database} do
      {:ok, answer} =
        Transaction.transaction(conn, database, :write, fn tx ->
          Transaction.query(tx, ~s|insert $p isa person, has name "solo";|)
        end)

      assert %TypeDB.Answer.ConceptRows{} = answer
      assert answer.query_type == :write
    end

    test "rows decode into the same structs the HTTP driver produces", %{conn: conn, database: database} do
      {:ok, _} =
        Transaction.transaction(conn, database, :write, fn tx ->
          Transaction.query(tx, ~s|insert $p isa person, has name "Alice", has age 30, has score 1.5;|)
        end)

      {:ok, answer} =
        Transaction.transaction(conn, database, :read, fn tx ->
          Transaction.query(
            tx,
            "match $p isa person, has name $n, has age $a, has score $s; select $n, $a, $s;"
          )
        end)

      assert [row] = TypeDB.Answer.rows(answer)

      # The whole point of depending on `typedb`: these are its structs and its
      # accessors, so an application that switches transports keeps its code.
      assert %TypeDB.ConceptRow{} = row
      assert TypeDB.ConceptRow.typed_value(row, "n") == "Alice"
      assert TypeDB.ConceptRow.typed_value(row, "a") == 30
      assert TypeDB.ConceptRow.typed_value(row, "s") == 1.5

      assert %TypeDB.Concept.Attribute{
               value_type: "string",
               type: %TypeDB.Concept.AttributeType{label: "name"}
             } =
               TypeDB.ConceptRow.get(row, "n")
    end

    test "a date survives the round trip through protobuf's day count", %{conn: conn, database: database} do
      {:ok, _} =
        Transaction.transaction(conn, database, :write, fn tx ->
          Transaction.query(tx, "given $d: date; insert $p isa person, has name 'dated', has born == $d;",
            given_rows: [%{"d" => ~D[1969-07-20]}]
          )
        end)

      {:ok, answer} =
        Transaction.transaction(conn, database, :read, fn tx ->
          Transaction.query(tx, "match $p isa person, has name 'dated', has born $b; select $b;")
        end)

      assert [row] = TypeDB.Answer.rows(answer)
      assert TypeDB.ConceptRow.typed_value(row, "b") == ~D[1969-07-20]
    end

    test "an answer from this driver is never truncated", %{conn: conn, database: database} do
      insert_people(conn, database, 12_000)

      {:ok, answer} =
        Transaction.transaction(conn, database, :read, fn tx ->
          Transaction.query(tx, "match $p isa person, has name $n; select $n;", timeout: 120_000)
        end)

      rows = TypeDB.Answer.rows(answer)

      assert length(rows) >= 12_000,
             "the HTTP API caps this at 10 000; there is no cap on this transport"

      refute TypeDB.Answer.truncated?(answer)
      assert TypeDB.Answer.warning(answer) == nil
    end
  end

  describe "pipelining" do
    test "many reads in one call all arrive and all answer in order", %{conn: conn, database: database} do
      insert_people(conn, database, 100)

      queries = for i <- 1..200, do: ~s|match $p isa person, has name == "p#{rem(i, 100) + 1}"; select $p;|

      {:ok, answers} =
        Transaction.transaction(conn, database, :read, fn tx ->
          Transaction.query_many(tx, queries, timeout: 120_000)
        end)

      assert length(answers) == 200
      assert Enum.all?(answers, &(length(TypeDB.Answer.rows(&1)) == 1)), "each read answers for itself"
    end

    # The behaviour that decides what `query_many/3` is for, and the reason its
    # doc says "for reads". TypeDB aborts a write's answer stream when the next
    # write in the same transaction starts executing.
    #
    # The dangerous part is not the error. It is that the writes begin to land
    # regardless — committing anyway puts them in the database — so a driver
    # that shrugged the errors off would commit work the server reported as
    # failed. This asserts both halves: the failure is reported, and nothing is
    # committed.
    test "pipelining writes is refused, and nothing lands", %{conn: conn, database: database} do
      queries = for i <- 1..200, do: ~s|insert $p isa person, has name "batch-#{i}";|

      assert {:error, %TypeDB.Error{code: "TSV13"} = error} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.query_many(tx, queries, timeout: 120_000)
               end)

      assert error.message =~ "concurrent write"
      assert count_like(conn, database, "^batch-") == 0, "the bracket must not commit after a failure"
    end

    # Everything below is `execute_many/3`, which exists because TSV13 turned out
    # to mean "the answer was dropped" rather than "the write failed" — measured
    # across five shapes of batch before any of it was written. The tests are
    # the measurements, kept.
    test "execute_many pipelines writes and they all land", %{conn: conn, database: database} do
      assert :ok =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.execute_many(
                   tx,
                   for(i <- 1..500, do: ~s|insert $p isa person, has name "fast-#{i}";|),
                   timeout: 120_000
                 )
               end)

      assert count_like(conn, database, "^fast-") == 500
    end

    test "writes in a pipelined batch still see each other, in order", %{conn: conn, database: database} do
      # The finding that makes the mode usable for anything but independent
      # rows: the batch is pipelined but TypeDB still executes it in order, so a
      # write that matches on an earlier one in the same batch finds it.
      queries =
        Enum.flat_map(1..50, fn i ->
          [
            ~s|insert $p isa person, has name "dep-#{i}";|,
            ~s|match $p isa person, has name == "dep-#{i}"; insert $p has age #{i};|
          ]
        end)

      assert :ok =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.execute_many(tx, queries, timeout: 120_000)
               end)

      assert count_like(conn, database, "^dep-") == 50

      {:ok, answer} =
        Transaction.transaction(conn, database, :read, fn tx ->
          Transaction.query(
            tx,
            ~s|match $p isa person, has name $n, has age $a; $n like "^dep-"; reduce $c = count;|
          )
        end)

      assert answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c") == 50,
             "every dependent write found the row the previous one had just inserted"
    end

    test "a query that does not parse is reported, not swallowed", %{conn: conn, database: database} do
      # The one failure that does NOT abort the stream: TypeDB reports TQL0,
      # keeps the transaction usable, and simply does not run that query. A mode
      # that ignored every error would commit the rest and lose this one
      # silently, which is why only TSV13 is ignored.
      queries =
        for(i <- 1..50, do: ~s|insert $p isa person, has name "tql-#{i}";|) ++
          ["this is not typeql at all"]

      assert {:error, %TypeDB.Error{code: "TQL0"}} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.execute_many(tx, queries, timeout: 120_000)
               end)

      assert count_like(conn, database, "^tql-") == 0, "the bracket must not commit past a reported failure"
    end

    test "a failure about the data aborts the whole transaction", %{conn: conn, database: database} do
      queries =
        for(i <- 1..50, do: ~s|insert $p isa person, has name "typed-#{i}";|) ++
          ["insert $x isa unicorn;"]

      assert {:error, %TypeDB.Error{}} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.execute_many(tx, queries, timeout: 120_000)
               end)

      assert count_like(conn, database, "^typed-") == 0
    end

    test "the same writes, sent one at a time, all land", %{conn: conn, database: database} do
      assert :ok =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Enum.each(1..200, fn i ->
                   {:ok, _} = Transaction.query(tx, ~s|insert $p isa person, has name "seq-#{i}";|)
                 end)

                 :ok
               end)

      assert count_like(conn, database, "^seq-") == 200
    end

    test "a failure among many is the failure returned", %{conn: conn, database: database} do
      assert {:error, %TypeDB.Error{kind: :server} = error} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 Transaction.query_many(tx, [
                   ~s|insert $p isa person, has name "fine";|,
                   "this is not typeql at all",
                   ~s|insert $p isa person, has name "also fine";|
                 ])
               end)

      assert error.code != nil
    end
  end

  describe "the bracket" do
    test "commits on success", %{conn: conn, database: database} do
      {:ok, _} =
        Transaction.transaction(conn, database, :write, fn tx ->
          Transaction.query(tx, ~s|insert $p isa person, has name "committed";|)
        end)

      assert count_named(conn, database, "committed") == 1
    end

    test "does not commit when the body returns an error", %{conn: conn, database: database} do
      assert {:error, :my_reason} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 {:ok, _} = Transaction.query(tx, ~s|insert $p isa person, has name "abandoned";|)
                 {:error, :my_reason}
               end)

      assert count_named(conn, database, "abandoned") == 0
    end

    test "does not commit when the body raises, and the raise propagates", %{conn: conn, database: database} do
      assert_raise RuntimeError, "boom", fn ->
        Transaction.transaction(conn, database, :write, fn tx ->
          {:ok, _} = Transaction.query(tx, ~s|insert $p isa person, has name "raised";|)
          raise "boom"
        end)
      end

      assert count_named(conn, database, "raised") == 0
    end

    test "closes the transaction either way", %{conn: conn, database: database} do
      pid =
        Transaction.transaction(conn, database, :write, fn tx ->
          tx.pid
        end)

      refute Process.alive?(pid)
    end
  end

  describe "rollback and close" do
    test "rollback discards writes and leaves the transaction open", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :write)
      on_exit(fn -> Transaction.close(tx) end)

      {:ok, _} = Transaction.query(tx, ~s|insert $p isa person, has name "rolled-back";|)
      assert :ok = Transaction.rollback(tx)

      # Still usable — this is the difference from close/2, and the sibling
      # documents the same thing.
      assert Transaction.open?(tx)
      assert {:ok, _} = Transaction.query(tx, ~s|insert $p isa person, has name "after-rollback";|)
      assert :ok = Transaction.commit(tx)

      assert count_named(conn, database, "rolled-back") == 0
      assert count_named(conn, database, "after-rollback") == 1
    end

    test "close honours a :timeout instead of discarding it", %{conn: conn, database: database} do
      # Audit V, V-10: the parameter existed only so the signature matched the
      # sibling's, so a caller passing a timeout got neither a timeout nor an
      # error. The observable half is that it is accepted and the transaction
      # ends; the bound itself only shows up against a wedged server.
      {:ok, tx} = Transaction.open(conn, database, :write)

      assert :ok = Transaction.close(tx, timeout: 2_000)
      refute Transaction.open?(tx)
    end

    test "close is idempotent and safe on a finished transaction", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :read)

      assert :ok = Transaction.close(tx)
      assert :ok = Transaction.close(tx)
      refute Transaction.open?(tx)
    end

    test "a query on a closed transaction is TSV12, the same code the HTTP driver reports", %{
      conn: conn,
      database: database
    } do
      {:ok, tx} = Transaction.open(conn, database, :write)
      :ok = Transaction.close(tx)

      assert {:error, %TypeDB.Error{code: "TSV12"} = error} =
               Transaction.query(tx, ~s|insert $p isa person, has name "no";|)

      assert TypeDB.Error.retryable?(error), "0.8.0 made this retryable on both transports"
    end
  end

  defp count_like(conn, database, pattern) do
    {:ok, answer} =
      Transaction.transaction(conn, database, :read, fn tx ->
        Transaction.query(tx, ~s|match $p isa person, has name $n; $n like "#{pattern}"; reduce $c = count;|)
      end)

    answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c")
  end

  defp count_named(conn, database, name) do
    {:ok, answer} =
      Transaction.transaction(conn, database, :read, fn tx ->
        Transaction.query(tx, ~s|match $p isa person, has name == "#{name}"; reduce $c = count;|)
      end)

    answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c")
  end
end
