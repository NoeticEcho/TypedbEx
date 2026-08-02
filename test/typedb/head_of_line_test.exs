defmodule TypeDB.HeadOfLineTest do
  use ExUnit.Case, async: true

  # "Requests run in the calling process, so N processes issue N concurrent
  # requests" is the driver's central claim, and it was true of two adapters out
  # of three. `:httpc` defaulted to queueing up to 100 requests onto a socket
  # that was already busy, so a query TypeDB was slow to answer — one waiting on
  # the schema lock, a long analytical read — held up every request behind it.
  # Against a live server, a 500ms wait on one query made a concurrent one wait
  # the full 500ms and then fail on the request timeout.
  #
  # Every adapter is checked here rather than only the one that was broken:
  # this is a property of the driver, not of `:httpc`.

  alias TypeDB.Stub

  @slow_ms 400

  setup do
    # One path the stub is slow to answer, one it is not.
    handler = fn _method, path, _headers, _body ->
      if String.contains?(path, "/health"), do: Process.sleep(@slow_ms)

      {200, [{"content-type", "application/json"}], ~s({"databases":[]})}
    end

    {:ok, stub} = Stub.start_link(handler: handler)
    {:ok, stub: stub}
  end

  for {name, adapter} <- [
        {"Finch", {TypeDB.HTTP.Finch, []}},
        {"Req", {TypeDB.HTTP.Req, []}},
        {":httpc", {TypeDB.HTTP.Httpc, []}}
      ] do
    @adapter adapter

    test "a slow request does not delay a concurrent one under #{name}", %{stub: stub} do
      name = :"hol_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: Stub.url(stub),
          token: "t",
          max_retries: 0,
          timeout: 10_000,
          http: @adapter
        )

      on_exit(fn ->
        try do
          TypeDB.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Establish the keep-alive session first. `:httpc` reuses an existing
      # session in preference to opening another *even while it is busy*, so
      # without this warm-up the bug does not reproduce: the second request
      # opens a fresh socket and nothing is queued behind anything.
      assert {:ok, _} = TypeDB.Database.list(name)

      slow = Task.async(fn -> :timer.tc(fn -> TypeDB.Server.health(name) end) end)

      # Long enough for the slow request to be on the socket, short enough to
      # leave most of its sleep still to run.
      Process.sleep(50)

      {fast_us, fast} = :timer.tc(fn -> TypeDB.Database.list(name) end)
      {slow_us, _slow_result} = Task.await(slow, 30_000)

      assert {:ok, _} = fast

      assert slow_us > @slow_ms * 500,
             "the slow request finished in #{div(slow_us, 1000)}ms, so this test proves nothing"

      assert fast_us < @slow_ms * 500,
             "a concurrent request took #{div(fast_us, 1000)}ms behind one that took " <>
               "#{div(slow_us, 1000)}ms — it was queued behind it rather than running beside it"
    end
  end
end
