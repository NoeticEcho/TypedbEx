defmodule TypeDB.LogLevelTest do
  # `capture_log/1` captures the whole VM's Logger output, so these tests would
  # otherwise see the log lines of every async test running beside them — and
  # they did: an assertion that the driver logged nothing failed on another
  # test's connection giving up. Logging assertions belong in a sync module.
  use TypeDB.Case, async: false

  import ExUnit.CaptureLog

  alias TypeDB.{Error, Stub}

  setup do
    handler = fn _method, _path, _headers, _body ->
      {503, [], ~s({"code":"SRV9","message":"nope"})}
    end

    {:ok, failing} = Stub.start_link(handler: handler)
    on_exit(fn -> stop_quietly(fn -> Stub.stop(failing) end) end)

    {:ok, failing: failing}
  end

  defp stop_quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp connection_to(stub, opts) do
    name = :"log_level_#{System.unique_integer([:positive])}"
    {:ok, pid} = TypeDB.start_link([name: name, url: Stub.url(stub), token: "t"] ++ opts)
    on_exit(fn -> stop_quietly(fn -> TypeDB.stop(pid) end) end)
    name
  end

  test "the default level says what it is doing", %{failing: failing} do
    conn = connection_to(failing, max_retries: 1, retry_backoff: fn _ -> 1 end)

    log = capture_log(fn -> TypeDB.Database.list(conn) end)

    assert log =~ "retrying in"
    assert log =~ "giving up"
  end

  test ":log_level silences a connection without touching the global Logger", %{failing: failing} do
    conn =
      connection_to(failing, max_retries: 1, retry_backoff: fn _ -> 1 end, log_level: :none)

    assert capture_log(fn -> TypeDB.Database.list(conn) end) == ""
  end

  test ":log_level: :error keeps the give-up but drops the retries", %{failing: failing} do
    # The give-up is a :warning and the retries are :debug, so a floor between
    # them is a real setting and not just on/off.
    conn =
      connection_to(failing,
        max_retries: 2,
        retry_backoff: fn _ -> 1 end,
        log_level: :warning
      )

    log = capture_log(fn -> TypeDB.Database.list(conn) end)

    assert log =~ "giving up"
    refute log =~ "retrying in"
  end

  test "giving up is warned about and counted", %{failing: failing} do
    conn = connection_to(failing, max_retries: 2, retry_backoff: fn _ -> 1 end)

    test = self()
    handler = "exhausted-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:typedb, :retry, :exhausted],
      fn _event, measurements, metadata, _ -> send(test, {:exhausted, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log = capture_log(fn -> assert {:error, _} = TypeDB.Database.list(conn) end)

    # Retrying and failing used to leave nothing behind but a debug line nobody
    # had enabled.
    assert log =~ "[warning]"
    assert log =~ "giving up"
    assert log =~ "after 3 attempts"

    assert_received {:exhausted, %{attempts: 3}, %{route: "/databases", error: %Error{}}}
  end

  test "a call that is not retried at all is not warned about" do
    handler = fn _method, _path, _headers, _body ->
      {400, [], ~s({"code":"DBD1","message":"no"})}
    end

    {:ok, rejecting} = Stub.start_link(handler: handler)
    on_exit(fn -> stop_quietly(fn -> Stub.stop(rejecting) end) end)

    conn = connection_to(rejecting, max_retries: 2)

    # One attempt, one honest error; nothing was exhausted.
    refute capture_log(fn -> TypeDB.Database.list(conn) end) =~ "giving up"
  end
end
