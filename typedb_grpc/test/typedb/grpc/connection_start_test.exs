defmodule TypeDB.GRPC.ConnectionStartTest do
  @moduledoc """
  That a connection starts whether or not TypeDB is up.

  The README says so in bold — *"it validates the options and starts the
  process, and does **not** contact the server, so your application boots
  whether or not TypeDB is up yet"* — and `TypeDB.GRPC.Connection`'s moduledoc
  says it again. Until this suite existed neither was true: `init/1` opened the
  transport and answered `{:stop, error}` when it could not, so a supervision
  tree containing a connection failed to boot while TypeDB was restarting.
  Measured against a closed port: `Supervisor.start_link` returned
  `{:error, {:shutdown, …}}` where the HTTP sibling returned `{:ok, pid}`.

  What makes that a defect rather than a design is that the machinery to do
  better had already landed: 0.2.1 gave this process a reconnect loop with
  backoff, and a channel that reads `:reconnecting` from ETS until it is back.
  A server that is not up *yet* is the same situation as a server that went
  away, and the process simply never lived long enough to treat it that way.

  No server needed: the address is a port nothing is listening on, which is
  the situation under test.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TypeDB.Error
  alias TypeDB.GRPC.Connection
  alias TypeDB.GRPC.Error, as: GRPCError

  # A port that was bound and released. Nothing is listening on it, so the
  # connection attempt is refused rather than left hanging — which is the fast,
  # deterministic half of "TypeDB is not up".
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_against_nothing(extra \\ []) do
    name = :"start_test_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          address: "127.0.0.1:#{closed_port()}",
          username: "admin",
          password: "password"
        ],
        extra
      )

    {result, log} = with_log(fn -> Connection.start_link(opts) end)

    case result do
      {:ok, pid} ->
        Process.unlink(pid)
        stop_on_exit(pid)
        {:ok, name, pid, log}

      other ->
        {other, name, nil, log}
    end
  end

  defp stop_on_exit(pid) do
    on_exit(fn -> if Process.alive?(pid), do: Connection.stop(pid) end)
  end

  test "start_link succeeds when there is no server to connect to" do
    assert {:ok, name, pid, _log} = start_against_nothing()

    assert Process.alive?(pid)
    assert Connection.running?(name)
  end

  test "a supervision tree containing a connection boots" do
    name = :"start_test_sup_#{System.unique_integer([:positive])}"

    child =
      {TypeDB.GRPC,
       name: name, address: "127.0.0.1:#{closed_port()}", username: "admin", password: "password"}

    {result, _log} =
      with_log(fn -> Supervisor.start_link([child], strategy: :one_for_one, max_restarts: 0) end)

    assert {:ok, sup} = result

    # The supervisor is linked to the test process, which is gone by the time
    # `on_exit` runs — so stopping it there races with its own shutdown and
    # exits the callback. Unlink, and tolerate having lost the race anyway.
    Process.unlink(sup)

    on_exit(fn ->
      if Process.alive?(sup) do
        try do
          Supervisor.stop(sup)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert [{_, child_pid, _, _}] = Supervisor.which_children(sup)
    assert is_pid(child_pid)
  end

  test "the channel says :transport rather than handing out one that is not there" do
    assert {:ok, name, _pid, _log} = start_against_nothing()

    assert {:error, %Error{kind: :transport} = error} = Connection.fetch_channel(name)
    assert error.message =~ "re-establish"
  end

  test "a call fails at once with :transport instead of waiting out its timeout" do
    assert {:ok, name, _pid, _log} = start_against_nothing()

    {elapsed, result} =
      :timer.tc(fn -> capture_log(fn -> send(self(), TypeDB.GRPC.health(name)) end) end)
      |> then(fn {us, _log} -> {us, receive(do: (r -> r))} end)

    assert {:error, %Error{kind: :transport}} = result

    assert div(elapsed, 1000) < 1_000,
           "the call took #{div(elapsed, 1000)} ms; it should not wait on a channel that is known to be missing"
  end

  test "the failure is said out loud, with the address and what happened" do
    assert {:ok, _name, _pid, log} = start_against_nothing()

    assert log =~ "127.0.0.1:"

    # Not `econnrefused`: that word is there only when gun got round to
    # reporting it, and whether it does is a race — see the describe block
    # below, which forces both outcomes. What the driver promises is the
    # sentence, and the sentence is the same either way.
    assert log =~ "the transport went down"
  end

  test "there is no connection id until a connection has actually been opened" do
    assert {:ok, name, _pid, _log} = start_against_nothing()

    assert Connection.connection_id(name) == nil
  end

  describe "one refused connection, two reasons from gun" do
    # CI caught this once on main at 99c5851: this file's start-up test expected
    # the log to say `econnrefused` and it said `{:down, :noproc}`. A re-run
    # passed, which is what a race looks like.
    #
    # The race is in `gun:await_up/2` (gun.erl), which the gRPC adapter calls
    # from its connection process:
    #
    #     await_up(ServerPid, Timeout) ->
    #         MRef = monitor(process, ServerPid),
    #         ...
    #
    # The monitor goes on *after* `gun:open` has returned. A connection refused
    # on loopback can be refused and the gun process gone before that line runs,
    # and `monitor/2` on a process that is already dead delivers `:noproc` — at
    # which point why it died is gone, because nobody was watching.
    #
    # So one event has two reasons, decided by scheduling. Neither is the
    # driver's to change; what is the driver's is not passing the coin-flip on
    # to whoever reads the log.

    defp refused_port do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)
      port
    end

    defp await_up_after(port, delay_ms) do
      {:ok, pid} = :gun.open(~c"127.0.0.1", port, %{retry: 0, connect_timeout: 5_000})
      if delay_ms > 0, do: Process.sleep(delay_ms)
      :gun.await_up(pid, 2_000)
    end

    test "gun reports the reason when its process is still alive" do
      assert {:error, {:down, {:shutdown, :econnrefused}}} = await_up_after(refused_port(), 0)
    end

    test "gun reports :noproc when its process has already exited" do
      assert {:error, {:down, :noproc}} = await_up_after(refused_port(), 200)
    end

    test "the driver says the same thing about both" do
      context = "could not open a gRPC channel to 127.0.0.1:1"

      told = GRPCError.from_reason({:down, {:shutdown, :econnrefused}}, context)
      lost = GRPCError.from_reason({:down, :noproc}, context)

      for error <- [told, lost] do
        assert error.kind == :transport
        assert error.message =~ context
        assert error.message =~ "the transport went down"
      end

      # The detail survives where there is one, and where there is not the
      # message says that rather than printing an atom nobody can act on.
      assert told.message =~ "econnrefused"
      assert lost.message =~ "did not report why"

      # `:reason` stays exactly what the adapter handed over. Normalising it
      # too would hide the difference from anyone debugging the adapter, and
      # the message is what a human reads.
      assert told.reason == {:down, {:shutdown, :econnrefused}}
      assert lost.reason == {:down, :noproc}
    end
  end

  test "the process keeps trying rather than sitting on the first refusal" do
    assert {:ok, _name, pid, _log} = start_against_nothing()

    # The first backoff is 100 ms, so by a second in there have been several
    # attempts. What is under test is that none of them took the process down:
    # a reconnect loop that crashes on its own failure is worse than none.
    log = capture_log(fn -> Process.sleep(1_000) end)

    assert Process.alive?(pid)

    assert log =~ "could not re-establish",
           "the connection made no further attempt after the first refusal"
  end
end
