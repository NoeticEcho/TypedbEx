defmodule TypeDB.ShutdownTest do
  use ExUnit.Case, async: true

  # Stopping a connection runs the adapter's `terminate/1`, which is somebody
  # else's code — `TypeDB.HTTP` is a public extension point — and which for the
  # built-in Finch adapter stops a supervisor.
  #
  # That call can *raise*, not merely exit: on OTP 29 `proc_lib:stop/3` works
  # out the remaining timeout after `sys:terminate` returns, and a value at or
  # below zero reaches `receive ... after NegativeTimeout`, which raises
  # `ErlangError :timeout_value`. The Finch adapter caught exits only, so the
  # error propagated out of `Connection.terminate/2` and a connection that had
  # been asked to stop crashed instead. Seen while stopping several connections
  # at once against sockets that were not answering.

  alias TypeDB.Stub

  defmodule HostileTerminate do
    @moduledoc false
    @behaviour TypeDB.HTTP

    @impl true
    def init(_name, opts), do: {:ok, Keyword.fetch!(opts, :on_terminate)}

    @impl true
    def owner(_state), do: nil

    @impl true
    def terminate(:raise), do: raise(ArgumentError, "terminate raised")
    def terminate(:throw), do: throw(:terminate_threw)
    def terminate(:exit), do: exit(:terminate_exited)
    def terminate(:error), do: :erlang.error(:timeout_value)

    # Enough of a server to sign in and answer one call: this adapter is here
    # for what its `terminate/1` does, not for what it fetches.
    @impl true
    def request(_state, _method, url, _headers, _body, _opts) do
      body =
        if String.ends_with?(url, "/signin"),
          do: ~s({"token":"t"}),
          else: ~s({"databases":[]})

      {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
    end
  end

  setup do
    # The stub checks credentials, so a pre-issued token is not enough.
    {:ok, stub} = Stub.start_link(databases: [])
    {:ok, stub: stub}
  end

  for fault <- [:raise, :throw, :exit, :error] do
    @fault fault

    test "an adapter whose terminate/1 #{fault}s does not stop the connection stopping", %{
      stub: stub
    } do
      name = :"shutdown_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: Stub.url(stub),
          username: "admin",
          password: "password",
          http: {HostileTerminate, [on_terminate: @fault]}
        )

      assert {:ok, _} = TypeDB.Database.list(name)
      assert :ok = TypeDB.stop(pid)
      refute Process.alive?(pid)
    end
  end

  test "stopping the real Finch adapter is still clean", %{stub: stub} do
    name = :"shutdown_finch_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: Stub.url(stub),
        username: "admin",
        password: "password",
        http: {TypeDB.HTTP.Finch, []}
      )

    assert {:ok, _} = TypeDB.Database.list(name)

    # The pool goes away with the connection rather than being left behind.
    [{:http_state, %TypeDB.HTTP.Finch{supervisor: pool}}] = :ets.lookup(name, :http_state)
    assert Process.alive?(pool)

    assert :ok = TypeDB.stop(pid)
    refute Process.alive?(pid)
    refute Process.alive?(pool)
  end
end
