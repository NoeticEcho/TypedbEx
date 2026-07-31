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
      [[:typedb, :request, :start], [:typedb, :request, :stop]],
      fn event, _measurements, metadata, _config ->
        if metadata[:connection] == name and metadata[:path] == "/databases" do
          send(test, {:span, List.last(event), metadata})
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
    assert_receive {:span, :start, %{attempt: 1}}
    assert_receive {:span, :stop, %{attempt: 1, error: %Error{kind: :transport}}}
    assert_receive {:span, :start, %{attempt: 2}}
    assert_receive {:span, :stop, %{attempt: 2, error: %Error{kind: :transport}}}
    assert_receive {:span, :start, %{attempt: 3}}
    assert_receive {:span, :stop, %{attempt: 3, status: 200} = final}
    refute Map.has_key?(final, :error)

    refute_receive {:span, :start, %{attempt: 4}}, 100

    TypeDB.stop(pid)
  end
end
