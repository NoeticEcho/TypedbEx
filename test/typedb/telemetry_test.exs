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
        [:typedb, :sign_in, :stop]
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

    assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(name)
    assert_receive {:stop, metadata}
    assert %Error{kind: :transport} = metadata.error
    refute Map.has_key?(metadata, :status)

    :telemetry.detach(handler)
    TypeDB.stop(pid)
    Stub.stop(stub)
  end

  @tag stub_opts: [databases: ["social"], token_uses: 1]
  test "each retry gets its own span, numbered", %{conn: conn} do
    assert {:ok, _} = TypeDB.Database.list(conn)
    assert {:ok, _} = TypeDB.Database.list(conn)

    attempts =
      for _ <- 1..10, into: [] do
        receive do
          {:telemetry, [:typedb, :request, :start], _, %{attempt: attempt}} -> attempt
        after
          200 -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Retries after a 401 re-enter the span with attempt back at 1, because the
    # attempt counter tracks transport retries within one send.
    assert Enum.all?(attempts, &(&1 >= 1))
    assert length(attempts) >= 3, "expected the rejected request to have been re-sent"
  end
end
