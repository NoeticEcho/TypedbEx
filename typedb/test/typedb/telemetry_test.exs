defmodule TypeDB.TelemetryTest do
  use TypeDB.Case, async: true

  alias TypeDB.Stub

  setup context do
    handler = "typedb-telemetry-test-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      handler,
      [
        [:typedb, :request, :start],
        [:typedb, :request, :stop],
        [:typedb, :request, :exception],
        [:typedb, :sign_in, :start],
        [:typedb, :sign_in, :stop],
        [:typedb, :operation, :start],
        [:typedb, :operation, :stop],
        [:typedb, :operation, :exception],
        [:typedb, :transaction, :start],
        [:typedb, :transaction, :stop],
        [:typedb, :transaction, :exception]
      ],
      fn event, measurements, metadata, _config ->
        if metadata[:connection] == context.conn do
          send(test, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @tag stub_opts: [databases: ["social"]]
  test "a successful request emits a start/stop span", %{conn: conn} do
    assert {:ok, _} = TypeDB.Database.list(conn)

    assert_receive {:telemetry, [:typedb, :request, :start], %{system_time: _}, start_metadata}
    assert start_metadata.method == :get
    assert start_metadata.path == "/databases"
    assert start_metadata.attempt == 1

    assert_receive {:telemetry, [:typedb, :request, :stop], %{duration: duration}, stop_metadata}
    assert is_integer(duration)
    assert stop_metadata.status == 200
    refute Map.has_key?(stop_metadata, :error)
  end

  @tag stub_opts: [databases: ["social"]]
  test "sign-in is its own span", %{conn: conn} do
    assert {:ok, _} = TypeDB.Database.list(conn)

    assert_receive {:telemetry, [:typedb, :sign_in, :start], _, %{connection: ^conn}}
    assert_receive {:telemetry, [:typedb, :sign_in, :stop], %{duration: _}, metadata}
    refute Map.has_key?(metadata, :error)
  end

  test "a server error is reported on the stop event", %{conn: conn} do
    assert {:error, _} = TypeDB.Database.get(conn, "nope")

    assert_receive {:telemetry, [:typedb, :request, :stop], _, %{status: 404}}
  end

  test "a transport failure carries the error rather than a status", %{stub: stub} do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    name = :"telemetry_dead_#{System.unique_integer([:positive])}"
    test = self()
    handler = "typedb-telemetry-dead-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:typedb, :request, :stop],
      fn _event, _measurements, metadata, _config ->
        if metadata[:connection] == name, do: send(test, {:stop, metadata})
      end,
      nil
    )

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: "http://127.0.0.1:#{port}",
        token: "t",
        max_retries: 0,
        connect_timeout: 500
      )

    error = assert_unreachable(TypeDB.Database.list(name))
    assert_receive {:stop, metadata}
    assert metadata.error == error
    refute Map.has_key?(metadata, :status)

    :telemetry.detach(handler)
    TypeDB.stop(pid)
    Stub.stop(stub)
  end

  # Fails the first two /databases requests at transport level so the retry path
  # actually runs. Without this the attempt counter never leaves 1 and the test
  # asserting on it asserts nothing.
  defmodule TwiceFailingAdapter do
    @moduledoc false
    @behaviour TypeDB.HTTP

    def init(name, opts) do
      {inner, inner_opts} = Keyword.fetch!(opts, :inner)
      counter = :counters.new(1, [:atomics])

      with {:ok, state} <- inner.init(name, inner_opts), do: {:ok, {inner, state, counter}}
    end

    def request({inner, state, counter}, method, url, headers, body, opts) do
      if String.ends_with?(url, "/databases") do
        attempt = :counters.get(counter, 1) + 1
        :counters.add(counter, 1, 1)

        if attempt <= 2 do
          {:error, TypeDB.Error.new(:transport, "failing attempt #{attempt}")}
        else
          inner.request(state, method, url, headers, body, opts)
        end
      else
        inner.request(state, method, url, headers, body, opts)
      end
    end

    def owner({inner, state, _c}) do
      if function_exported?(inner, :owner, 1), do: inner.owner(state), else: nil
    end

    def terminate({inner, state, _c}) do
      if function_exported?(inner, :terminate, 1), do: inner.terminate(state), else: :ok
    end
  end

  @tag stub_opts: [databases: ["social"]]
  test "each transport retry gets its own span, numbered", %{stub: stub} do
    name = :"telemetry_retry_#{System.unique_integer([:positive])}"
    test = self()
    handler = "typedb-telemetry-retry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:typedb, :request, :start],
        [:typedb, :request, :stop],
        [:typedb, :operation, :start],
        [:typedb, :operation, :stop]
      ],
      fn [_, level, phase], _measurements, metadata, _config ->
        if metadata[:connection] == name and metadata[:path] == "/databases" do
          send(test, {level, phase, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: Stub.url(stub),
        username: "admin",
        password: "password",
        max_retries: 2,
        retry_backoff: {:exponential, 1},
        http: {TwiceFailingAdapter, [inner: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}]}
      )

    assert {:ok, _} = TypeDB.Database.list(name)

    # Three attempts: two that failed in transport, then the one that reached
    # the server. Each is its own span, and the number counts up.
    assert_receive {:request, :start, %{attempt: 1}}
    assert_receive {:request, :stop, %{attempt: 1, error: %Error{kind: :transport}}}
    assert_receive {:request, :start, %{attempt: 2}}
    assert_receive {:request, :stop, %{attempt: 2, error: %Error{kind: :transport}}}
    assert_receive {:request, :start, %{attempt: 3}}
    assert_receive {:request, :stop, %{attempt: 3, status: 200} = final}
    refute Map.has_key?(final, :error)

    refute_receive {:request, :start, %{attempt: 4}}, 100

    # And exactly one operation span around all three, which is the difference
    # between "how many HTTP requests" and "how many calls the caller made".
    assert_receive {:operation, :start, _}
    assert_receive {:operation, :stop, %{attempts: 3} = operation}
    refute Map.has_key?(operation, :error)
    refute_receive {:operation, :start, _}, 100

    TypeDB.stop(pid)
  end

  describe "operation spans" do
    @tag stub_opts: [databases: ["social"]]
    test "a successful call emits one span whatever the path did", %{conn: conn} do
      assert {:ok, _} = TypeDB.Database.get(conn, "social")

      assert_receive {:telemetry, [:typedb, :operation, :start], %{system_time: _}, start_metadata}
      assert start_metadata.method == :get
      assert start_metadata.path == "/databases/social"
      # The template, not the name: a metric tagged by :path grows without bound.
      assert start_metadata.route == "/databases/:name"

      assert_receive {:telemetry, [:typedb, :operation, :stop], %{duration: _}, stop_metadata}
      assert stop_metadata.attempts == 1
      refute Map.has_key?(stop_metadata, :error)
    end

    @tag stub_opts: [databases: ["social"]]
    test "a transaction id does not leak into the route", %{conn: conn} do
      {:ok, tx} = TypeDB.Transaction.open(conn, "social", :read)
      assert {:ok, _} = TypeDB.Transaction.query(tx, "match $p isa person;")

      assert_receive {:telemetry, [:typedb, :operation, :stop], _,
                      %{route: "/transactions/:id/query", path: path}}

      assert path =~ tx.id
    end

    @tag stub_opts: [databases: ["social"]]
    test "the database is in the metadata even when the path does not name it", %{conn: conn} do
      # /v1/query carries the database in its body, so grouping metrics by
      # database used to mean not grouping them at all.
      assert {:ok, _} =
               TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)

      assert_receive {:telemetry, [:typedb, :operation, :stop], _, metadata}
      assert metadata.route == "/query"
      assert metadata.database == "social"
      assert metadata.transaction_type == :read
    end

    test "a percent-encoded database name is reported as it was written", %{conn: conn} do
      # Whether the server knows this database is beside the point; the span
      # fires either way, and it must not report the escaped form.
      _ = TypeDB.Database.get(conn, "my db")

      assert_receive {:telemetry, [:typedb, :operation, :stop], _, %{database: "my db", path: path}}
      assert path =~ "%20"
    end

    @tag stub_opts: [databases: ["social"]]
    test "transaction calls carry the id, the database and the type", %{conn: conn} do
      {:ok, tx} = TypeDB.Transaction.open(conn, "social", :write)
      assert :ok = TypeDB.Transaction.commit(tx)

      assert_receive {:telemetry, [:typedb, :operation, :stop], _,
                      %{
                        route: "/transactions/:id/commit",
                        database: "social",
                        transaction_type: :write,
                        transaction_id: id
                      }}

      assert id == tx.id
    end

    test "a failed call carries the error", %{conn: conn} do
      assert {:error, _} = TypeDB.Database.get(conn, "nope")

      assert_receive {:telemetry, [:typedb, :operation, :stop], _, %{error: %Error{status: 404}}}
    end
  end

  describe "transaction spans" do
    @describetag stub_opts: [databases: ["social"]]

    test "a committed block reports :commit", %{conn: conn} do
      assert :ok = TypeDB.transaction(conn, "social", :write, fn _tx -> :ok end)

      assert_receive {:telemetry, [:typedb, :transaction, :start], _, %{database: "social", type: :write}}

      assert_receive {:telemetry, [:typedb, :transaction, :stop], %{duration: _}, %{outcome: :commit}}
    end

    test "a block that returns an error reports :rollback", %{conn: conn} do
      assert {:error, :nope} = TypeDB.transaction(conn, "social", :write, fn _ -> {:error, :nope} end)

      assert_receive {:telemetry, [:typedb, :transaction, :stop], _, %{outcome: :rollback}}
    end

    test "a read block reports :close", %{conn: conn} do
      assert :ok = TypeDB.transaction(conn, "social", :read, fn _tx -> :ok end)

      assert_receive {:telemetry, [:typedb, :transaction, :stop], _, %{outcome: :close}}
    end

    test "a read block that fails reports :close too, and sends no rollback", %{
      conn: conn,
      stub: stub
    } do
      # TypeDB answers 400 TSV3 to a rollback on a read transaction, so sending
      # one spends a round trip to be told off.
      assert {:error, :nope} = TypeDB.transaction(conn, "social", :read, fn _ -> {:error, :nope} end)

      assert_receive {:telemetry, [:typedb, :transaction, :stop], _, %{outcome: :close}}
      assert requests(stub, "/rollback") == []
      assert length(requests(stub, "/close")) == 1
    end

    test "a block that raises produces an exception event", %{conn: conn} do
      assert_raise RuntimeError, fn ->
        TypeDB.transaction(conn, "social", :write, fn _tx -> raise "boom" end)
      end

      assert_receive {:telemetry, [:typedb, :transaction, :exception], _, %{kind: :error}}
    end

    @tag stub_opts: [databases: ["social"], fail_commit: true]
    test "a rejected commit reports :commit_failed", %{conn: conn} do
      assert {:error, %Error{}} = TypeDB.transaction(conn, "social", :write, fn _ -> :ok end)

      assert_receive {:telemetry, [:typedb, :transaction, :stop], _,
                      %{outcome: :commit_failed, error: %Error{}}}
    end

    test "opening the transaction failing still closes the span", %{conn: conn} do
      assert {:error, %Error{}} = TypeDB.transaction(conn, "nope", :write, fn _ -> :ok end)

      assert_receive {:telemetry, [:typedb, :transaction, :stop], _, %{error: %Error{}}}
    end
  end
end
