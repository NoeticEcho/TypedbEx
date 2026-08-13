defmodule TypeDB.GRPC.TelemetryIntegrationTest do
  @moduledoc """
  That the events are emitted, that they carry what the docs say, and — the one
  that matters most — that they are the *same event names* the sibling emits.

  An application switching transports keeps its dashboards only if that stays
  true, and nothing but a test keeps it true.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias TypeDB.GRPC.{Telemetry, Transaction}

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

      {:ok, conn: conn, database: database}
    end
  end

  defp collect(events, fun) do
    parent = self()
    ref = make_ref()
    handler = "test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

    try do
      fun.()
      drain(ref, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, event, measurements, metadata} -> drain(ref, [{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "the event names are the sibling's" do
    test "and that is asserted rather than assumed" do
      # If these ever diverge, every dashboard built on the HTTP driver breaks
      # silently on a switch. Comparing the two modules is the only way to
      # notice, and it costs nothing.
      assert Telemetry.operation_event() == [:typedb, :operation]
      assert Telemetry.transaction_event() == [:typedb, :transaction]
      assert Telemetry.sign_in_event() == [:typedb, :sign_in]

      assert Telemetry.operation_event() == TypeDB.Telemetry.operation_event()
      assert Telemetry.transaction_event() == TypeDB.Telemetry.transaction_event()
      assert Telemetry.sign_in_event() == TypeDB.Telemetry.sign_in_event()
    end

    test "and the two transports are told apart by metadata, not by name", %{
      conn: conn,
      database: database
    } do
      events =
        collect([[:typedb, :operation, :stop]], fn ->
          {:ok, _} = TypeDB.GRPC.query(conn, database, "match $p isa person;", transaction_type: :read)
        end)

      assert [_ | _] = events
      assert Enum.all?(events, fn {_, _, metadata} -> metadata.transport == :grpc end)
      assert Telemetry.transport() == :grpc
    end
  end

  describe "operation spans" do
    test "an administrative call names its operation", %{conn: conn} do
      events = collect([[:typedb, :operation, :stop]], fn -> {:ok, _} = TypeDB.GRPC.databases(conn) end)

      assert Enum.any?(events, fn {_, _, metadata} -> metadata.operation == :databases_all end)
    end

    test "a query carries its database and transaction type", %{conn: conn, database: database} do
      events =
        collect([[:typedb, :operation, :stop]], fn ->
          {:ok, _} = TypeDB.GRPC.query(conn, database, "match $p isa person;", transaction_type: :read)
        end)

      assert {_, measurements, metadata} =
               Enum.find(events, fn {_, _, m} -> m.operation == :query end)

      assert metadata.database == database
      assert metadata.transaction_type == :read
      assert is_integer(measurements.duration)
      refute Map.has_key?(metadata, :error)
    end

    test "a batch call reports how many queries it carried", %{conn: conn, database: database} do
      events =
        collect([[:typedb, :operation, :stop]], fn ->
          Transaction.transaction(conn, database, :write, fn tx ->
            Transaction.execute_many(tx, for(i <- 1..7, do: ~s|insert $p isa person, has name "t#{i}";|))
          end)
        end)

      assert {_, _, metadata} = Enum.find(events, fn {_, _, m} -> m.operation == :execute_many end)
      assert metadata.queries == 7
    end

    test "a failure attaches the error", %{conn: conn, database: database} do
      events =
        collect([[:typedb, :operation, :stop]], fn ->
          {:error, _} = TypeDB.GRPC.query(conn, database, "not typeql", transaction_type: :read)
        end)

      assert Enum.any?(events, fn {_, _, m} -> match?(%TypeDB.Error{}, m[:error]) end)
    end
  end

  describe "transaction spans" do
    test "a committed bracket reports :commit", %{conn: conn, database: database} do
      events =
        collect([[:typedb, :transaction, :stop]], fn ->
          Transaction.transaction(conn, database, :write, fn tx ->
            Transaction.query(tx, ~s|insert $p isa person, has name "spanned";|)
          end)
        end)

      assert [{_, measurements, metadata}] = events
      assert metadata.outcome == :commit
      assert metadata.type == :write
      assert metadata.database == database
      assert metadata.transport == :grpc
      assert is_integer(measurements.duration)
    end

    test "a read bracket reports :close, because it never commits", %{conn: conn, database: database} do
      events =
        collect([[:typedb, :transaction, :stop]], fn ->
          Transaction.transaction(conn, database, :read, fn tx ->
            Transaction.query(tx, "match $p isa person;")
          end)
        end)

      assert [{_, _, %{outcome: :close}}] = events
    end

    test "a block that raises produces :exception rather than :stop", %{
      conn: conn,
      database: database
    } do
      events =
        collect([[:typedb, :transaction, :stop], [:typedb, :transaction, :exception]], fn ->
          assert_raise RuntimeError, "deliberate", fn ->
            Transaction.transaction(conn, database, :write, fn _tx -> raise "deliberate" end)
          end
        end)

      assert Enum.any?(events, fn {event, _, _} -> List.last(event) == :exception end)
      refute Enum.any?(events, fn {event, _, _} -> List.last(event) == :stop end)
    end
  end

  describe "sign-in spans" do
    test "one per sign-in, and a failure carries the error" do
      events =
        collect([[:typedb, :sign_in, :stop]], fn ->
          conn = start_connection(password: "wrong")
          {:error, _} = TypeDB.GRPC.Connection.token(conn)
        end)

      assert Enum.any?(events, fn {_, _, m} ->
               m.transport == :grpc and match?(%TypeDB.Error{kind: :unauthenticated}, m[:error])
             end)
    end
  end

  describe "the stream batch event" do
    test "reports rows and how long the consumer waited", %{conn: conn, database: database} do
      {:ok, _} =
        TypeDB.GRPC.query(conn, database, "given $n: string; insert $p isa person, has name == $n;",
          transaction_type: :write,
          given_rows: for(i <- 1..500, do: %{"n" => "s#{i}"})
        )

      events =
        collect([Telemetry.stream_batch_event()], fn ->
          TypeDB.GRPC.stream(conn, database, "match $p isa person, has name $n; select $n;")
          |> Enum.count()
        end)

      assert [_ | _] = events

      total = Enum.reduce(events, 0, fn {_, %{rows: rows}, _}, acc -> acc + rows end)
      assert total >= 500

      assert Enum.all?(events, fn {_, m, meta} ->
               is_integer(m.wait) and m.wait >= 0 and meta.transport == :grpc
             end)

      # Audit V, V-5: this was the literal `nil`, so a metric grouped by
      # connection collapsed to one series while the doc promised otherwise.
      assert Enum.all?(events, fn {_, _, meta} -> meta.connection == conn end),
             "the batch event must name the connection it came from"

      assert Enum.all?(events, fn {_, _, meta} -> meta.database == database end)
    end
  end

  describe "the default logger" do
    test "attaches, filters on transport, and detaches" do
      assert :ok = Telemetry.attach_default_logger(:debug)
      assert {:error, :already_exists} = Telemetry.attach_default_logger(:debug)

      # The sibling's spans share these event names. Handing one to this
      # handler must be a no-op rather than a line claiming gRPC did it.
      assert :ok =
               Telemetry.handle_event(
                 [:typedb, :operation, :stop],
                 %{duration: 1},
                 %{transport: :http, operation: :query},
                 :debug
               )

      assert :ok = Telemetry.detach_default_logger()
      assert {:error, :not_found} = Telemetry.detach_default_logger()
    end
  end
end
