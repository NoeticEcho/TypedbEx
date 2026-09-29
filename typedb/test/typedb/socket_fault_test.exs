defmodule TypeDB.SocketFaultTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Database, Error, SocketFault}

  # `TypeDB.FaultAdapter` can express every failure an adapter can *return*.
  # It cannot express the ones that are not return values at all: a connection
  # dropped halfway through a body, a server that accepts and then says nothing,
  # bytes that are not HTTP. Those happen below the adapter, to Finch, Req and
  # `:httpc` in their own ways, and the driver's promise — a `%TypeDB.Error{}`
  # with a kind a caller can act on, never a crash — has to survive all three.
  #
  # The adapters are interchangeable by design and one of them silently was not
  # (see `TypeDB.AdapterParityTest`), so agreement is asserted rather than
  # assumed: a difference here is a bug wherever it lives.
  #
  # Every kind below was measured against a real socket, not predicted.

  @adapters [
    {"Finch", {TypeDB.HTTP.Finch, []}},
    {"Req", {TypeDB.HTTP.Req, []}},
    {":httpc", {TypeDB.HTTP.Httpc, []}}
  ]

  # What the socket did, and what that has to mean to a caller.
  @kinds %{
    # A close is a close, wherever it lands. None of these say whether the
    # request was acted on, which is exactly what `:transport` means.
    closed_before_response: :transport,
    closed_mid_body: :transport,
    closed_mid_headers: :transport,
    garbage: :transport,
    accept_and_reset: :transport,
    # A connection that is open and silent is a timeout and nothing else — and
    # it must end at the timeout rather than at some library's own default.
    never_answers: :timeout
  }

  @timeout 500

  defp connect(server, adapter, opts) do
    name = :"socket_fault_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      TypeDB.start_link(
        [
          name: name,
          url: SocketFault.url(server),
          token: "t",
          timeout: @timeout,
          connect_timeout: @timeout,
          retry_backoff: fn _attempt -> 1 end,
          http: adapter
        ] ++ opts
      )

    on_exit(fn ->
      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end

  defp listener(fault) do
    {:ok, server} = SocketFault.start_link(fault: fault)

    on_exit(fn ->
      try do
        SocketFault.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    server
  end

  describe "a socket that misbehaves" do
    for {fault, kind} <- @kinds do
      @fault fault
      @kind kind

      test "#{fault}: every adapter answers #{kind}, and none of them crashes" do
        outcomes =
          for {label, adapter} <- @adapters, into: %{} do
            server = listener(@fault)
            conn = connect(server, adapter, max_retries: 0)

            {label, outcome(fn -> Database.list(conn) end)}
          end

        for {label, outcome} <- outcomes do
          assert outcome == {:error, @kind},
                 "#{label} answered #{inspect(outcome)} for the #{@fault} fault, not #{@kind}"
        end
      end
    end
  end

  describe "a socket that never answers" do
    test "the wait is the timeout the caller asked for, on every adapter" do
      # Not the adapter's own default, and not the connect timeout: a server
      # that accepted the connection and then went quiet is the case where those
      # three numbers come apart, and where an adapter that ignores the one it
      # was handed makes a call hang for a minute.
      for {label, adapter} <- @adapters do
        server = listener(:never_answers)
        conn = connect(server, adapter, max_retries: 0)

        {elapsed, result} = :timer.tc(fn -> Database.list(conn) end, :millisecond)

        assert {:error, %Error{kind: :timeout}} = result

        assert elapsed >= @timeout,
               "#{label} gave up after #{elapsed}ms, before the #{@timeout}ms it was given"

        assert elapsed < @timeout * 3,
               "#{label} waited #{elapsed}ms for a #{@timeout}ms timeout"
      end
    end
  end

  describe "retries against a real socket" do
    test "a dropped connection is retried, exactly :max_retries + 1 times" do
      # The listener counts the requests it read, so this is the request count
      # as the *server* saw it — the one number a retry bug actually moves.
      for {label, adapter} <- @adapters do
        server = listener(:closed_before_response)
        conn = connect(server, adapter, max_retries: 2)

        assert {:error, %Error{kind: :transport}} = Database.list(conn)

        assert SocketFault.requests(server) == 3,
               "#{label} made #{SocketFault.requests(server)} requests, not 3"
      end
    end

    test "a write is sent once, however the socket failed" do
      # A request that reached the server and lost its answer must not be sent
      # twice, and a dropped connection cannot tell that case from one where it
      # never arrived. The listener read the request before closing, so this is
      # precisely the dangerous case: the server saw it.
      for {label, adapter} <- @adapters do
        server = listener(:closed_before_response)
        conn = connect(server, adapter, max_retries: 3)

        assert {:error, %Error{kind: :transport}} =
                 TypeDB.query(conn, "social", "insert $p isa person;")

        assert SocketFault.requests(server) == 1,
               "#{label} re-sent a write after a dropped connection " <>
                 "(#{SocketFault.requests(server)} requests)"
      end
    end
  end

  # Only the shape: the message is each library's own, and pinning those would
  # be pinning Mint's and `:httpc`'s wording rather than the driver's promise.
  defp outcome(call) do
    case call.() do
      {:error, %Error{kind: kind}} -> {:error, kind}
      other -> {:unexpected, inspect(other, limit: 3)}
    end
  rescue
    exception -> {:raised, inspect(exception.__struct__)}
  catch
    kind, reason -> {:caught, kind, inspect(reason, limit: 3)}
  end
end
