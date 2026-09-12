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

  test "the failure is said out loud, with the address and the reason" do
    assert {:ok, _name, _pid, log} = start_against_nothing()

    assert log =~ "127.0.0.1:"
    assert log =~ "econnrefused"
  end

  test "there is no connection id until a connection has actually been opened" do
    assert {:ok, name, _pid, _log} = start_against_nothing()

    assert Connection.connection_id(name) == nil
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
