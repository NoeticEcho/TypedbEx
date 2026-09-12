defmodule TypeDB.GRPC.LateServerIntegrationTest do
  @moduledoc """
  That a connection started before TypeDB is reachable starts working once it is.

  `ConnectionStartTest` proves the first half without a server: the process
  starts, the tree boots, and every call says `:transport` at once instead of
  waiting. That half alone would be satisfied by a connection that starts and
  then never works, which is not the promise — the promise is that the
  application boots now and talks to TypeDB when TypeDB arrives.

  The server arriving at an address that refused a moment ago is staged with a
  plain TCP relay: the test picks a port, leaves it closed, points a connection
  at it, and only then starts forwarding that port to the real server. Bytes are
  bytes, so HTTP/2 and gRPC travel over it unchanged, and the connection sees
  exactly what it would see if an operator had started TypeDB.

  Skipped unless `TYPEDB_GRPC_ADDRESS` is set.
  """

  use TypeDB.GRPC.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag timeout: 60_000

  alias TypeDB.Error

  setup_all do
    if address(), do: :ok, else: {:ok, skip: true}
  end

  # A port that was bound and released: nothing is listening, so a connection
  # attempt is refused rather than left to time out.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp upstream do
    [host, port] = String.split(address(), ":")
    {String.to_charlist(host), String.to_integer(port)}
  end

  # A relay, not a mock: every byte is passed through to the real TypeDB, so
  # what the driver negotiates over it is the server's own protocol.
  defp start_relay(port) do
    {upstream_host, upstream_port} = upstream()

    test_process = self()

    # A plain process rather than a `Task`: `Task.shutdown/2` may only be called
    # by the owner, and `on_exit` runs somewhere else entirely.
    pid =
      spawn(fn ->
        {:ok, listener} =
          :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

        send(test_process, :listening)
        accept_loop(listener, upstream_host, upstream_port)
      end)

    # Killing the process closes the listener it owns, which is the whole
    # teardown: the relayed connections die with their own sockets.
    on_exit(fn -> Process.exit(pid, :kill) end)

    receive do
      :listening -> :ok
    after
      5_000 -> flunk("the relay never started listening on #{port}")
    end

    pid
  end

  defp accept_loop(listener, host, port) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        # The upstream socket is opened *inside* the relay process, not here.
        # A socket's messages go to its controlling process, and the first
        # version of this connected upstream in the accepting process — so every
        # byte TypeDB sent arrived in a mailbox nobody was reading, and the
        # handshake never completed. The relay owns both ends or it relays
        # nothing.
        pid = spawn(fn -> pump(client, host, port) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :take_over)
        accept_loop(listener, host, port)

      {:error, :closed} ->
        :ok
    end
  end

  defp pump(client, host, port) do
    receive do: (:take_over -> :ok)
    {:ok, server} = :gen_tcp.connect(host, port, [:binary, active: true], 5_000)
    :ok = :inet.setopts(client, active: true)
    relay(client, server)
  end

  defp relay(client, server) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(server, data)
        relay(client, server)

      {:tcp, ^server, data} ->
        :gen_tcp.send(client, data)
        relay(client, server)

      {:tcp_closed, _} ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)

      {:tcp_error, _, _} ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)
    end
  end

  test "a connection that started against nothing works once the server appears", context do
    if context[:skip] do
      :ok
    else
      port = free_port()
      name = :"late_server_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:ok, pid} =
                   Connection.start_link([name: name, address: "127.0.0.1:#{port}"] ++ credentials())

          Process.unlink(pid)
          on_exit(fn -> if Process.alive?(pid), do: Connection.stop(pid) end)
        end)

      assert log =~ "could not open its transport at start-up"

      # Nothing is listening yet, so the driver's answer is the honest one.
      assert {:error, %Error{kind: :transport}} = TypeDB.GRPC.health(name)

      # Now TypeDB is reachable at that address, which is all the operator did.
      up_log =
        capture_log(fn ->
          start_relay(port)

          assert eventually(fn -> TypeDB.GRPC.health(name) == :ok end),
                 "the connection never came up after the server became reachable"
        end)

      # A connection that never had a transport did not *re-establish* one. The
      # word matters: an operator reading "re-established" concludes something
      # dropped, and goes looking for a fault that did not happen.
      assert up_log =~ "opened its transport"
      refute up_log =~ "re-established"

      # And it is a working connection, not merely a health check: the token and
      # the connection id are minted on the transport that finally came up.
      assert {:ok, databases} = TypeDB.GRPC.Database.list(name)
      assert is_list(databases)
      assert is_binary(Connection.connection_id(name))
    end
  end

  # The backoff runs to five seconds, so a walk of about ten covers a couple of
  # attempts after the relay opens without pinning the test to one of them.
  defp eventually(fun, deadline \\ 10_000) do
    started = System.monotonic_time(:millisecond)

    Enum.reduce_while(Stream.cycle([:tick]), false, fn _, _ ->
      cond do
        fun.() -> {:halt, true}
        System.monotonic_time(:millisecond) - started > deadline -> {:halt, false}
        true -> Process.sleep(200) && {:cont, false}
      end
    end)
  end
end
