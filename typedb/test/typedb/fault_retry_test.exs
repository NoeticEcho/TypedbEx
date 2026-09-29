defmodule TypeDB.FaultRetryTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Database, Error, FaultAdapter}

  # `TypeDB.FaultMatrixTest` asks the blunt question — whatever the adapter does,
  # does a caller get a `%TypeDB.Error{}` and does the connection survive — with
  # retries switched off so that the matrix stays fast and deterministic.
  #
  # This file asks the two questions that leaves: whether the error says the
  # *right* thing about what went wrong, and whether the driver retries the
  # failure or gives up on it. Those are the same question seen twice, because
  # the kind is what the retry policy decides on: `:transport` and `:timeout`
  # mean the request may never have arrived, and `:decode` means it did.
  #
  # Retrying a `:decode` failure would be a bug with no symptom short of a load
  # graph: the answer came back, it was simply not one the driver understands,
  # and asking again produces the same bytes at three times the cost.

  # Measured, not assumed: every fault, through a call that decodes a JSON body.
  @kinds %{
    # The adapter itself misbehaving. Nothing came back at all, so nothing can
    # be said about the request beyond "the transport did not deliver".
    raise: :transport,
    throw: :transport,
    exit: :transport,
    nonsense_return: :transport,
    missing_keys: :transport,
    # A response arrived; it is the body that is not what it claims to be.
    truncated_body: :decode,
    malformed_json: :decode,
    wrong_content_type: :decode,
    empty_body: :decode,
    huge_body: :decode,
    # A response that is honestly a failure, and says so with a status.
    server_error: :server,
    html_error_page: :server,
    # The request may or may not have arrived. That is what a timeout means.
    timeout_error: :timeout,
    stall: :timeout
  }

  # Which failures are worth another attempt, straight out of `TypeDB.Transport`.
  # Two rules, not one, and they are asked in this order:
  #
  #   * by kind — `:transport` and `:timeout` may have lost a request that never
  #     arrived, so there may be nothing on the server to repeat;
  #   * by status — a `:server` failure is an answer, and only the statuses in
  #     `:retry_on_status` are answers worth asking again (429, 502, 503, 504 by
  #     default: all of them "not now" rather than "no").
  #
  # `:decode` is in neither, and that is the interesting half: the answer
  # arrived and the driver could not read it. Asking again produces the same
  # bytes at three times the cost.
  @retryable_kinds [:transport, :timeout]

  defp connect(fault, opts) do
    name = :"fault_retry_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      TypeDB.start_link(
        [
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          retry_backoff: fn _attempt -> 1 end,
          http: {FaultAdapter, [fault: fault]}
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

  # How many HTTP requests the driver actually made, taken from the telemetry
  # the driver publishes for exactly this — rather than by instrumenting the
  # adapter, which would test the instrument.
  defp attempts(conn, fun) do
    handler = :"attempts_#{System.unique_integer([:positive])}"

    # A capture of a named function rather than a closure: `:telemetry` logs an
    # info paragraph about local handlers on every attach, and this attaches
    # once per measurement.
    :telemetry.attach(handler, [:typedb, :operation, :stop], &__MODULE__.report_attempts/4, {self(), conn})

    try do
      result = fun.()

      receive do
        {:attempts, ^conn, count} -> {count, result}
      after
        1_000 -> flunk("no [:typedb, :operation, :stop] arrived for #{conn}")
      end
    after
      # Detached here rather than in `on_exit`: a test that measures twice would
      # otherwise have two handlers attached for the second measurement, and
      # would read the extra event as the third measurement's answer. That is
      # not a hypothetical — it is how this helper was written first, and the
      # result was a retry count off by a whole test.
      :telemetry.detach(handler)
    end
  end

  # Telemetry handlers are global: every connection in a concurrently running
  # suite publishes into this one, so the event has to be matched to the
  # connection that was being measured. Without that filter the helper reads
  # another test's retry count as its own, which is exactly what it did — and
  # only under `mix test`, never when the file was run alone.
  @doc false
  def report_attempts(_event, _measurements, %{connection: conn} = metadata, {parent, conn}) do
    send(parent, {:attempts, conn, metadata[:attempts]})
  end

  def report_attempts(_event, _measurements, _metadata, _config), do: :ok

  describe "the kind names what actually happened" do
    for {fault, kind} <- @kinds do
      @fault fault
      @kind kind

      test "#{fault} is a #{kind} failure" do
        conn = connect(@fault, max_retries: 0, timeout: 100)

        assert {:error, %Error{kind: @kind}} = Database.list(conn),
               "the #{@fault} fault did not produce a #{@kind} error"
      end
    end

    test "a status failure carries the status the server sent" do
      # The distinction the kind alone cannot make: 503 is worth retrying and
      # 502 through a proxy is the same shape with a different number, and a
      # caller deciding between them needs both.
      assert {:error, %Error{kind: :server, status: 503}} =
               Database.list(connect(:server_error, max_retries: 0))

      assert {:error, %Error{kind: :server, status: 502}} =
               Database.list(connect(:html_error_page, max_retries: 0))
    end
  end

  describe "retries stop where the policy says" do
    for {fault, kind} <- @kinds, kind in @retryable_kinds do
      @fault fault

      test "#{fault} is retried, up to :max_retries and no further" do
        conn = connect(@fault, max_retries: 2, timeout: 50)

        assert {3, {:error, %Error{}}} = attempts(conn, fn -> Database.list(conn) end)
      end
    end

    for {fault, kind} <- @kinds, kind == :decode do
      @fault fault

      test "#{fault} is not retried: the answer arrived, it is just not one" do
        conn = connect(@fault, max_retries: 3, timeout: 50)

        assert {1, {:error, %Error{}}} = attempts(conn, fn -> Database.list(conn) end)
      end
    end

    test "a server failure is decided by its status, not by its kind" do
      # Both of these are `:server`, and they part company on the number. 502
      # and 503 are in the default `:retry_on_status`; the same kind with a
      # status outside it is a verdict, and asking again would only repeat it.
      for fault <- [:server_error, :html_error_page] do
        conn = connect(fault, max_retries: 2, timeout: 50)
        assert {3, {:error, %Error{kind: :server}}} = attempts(conn, fn -> Database.list(conn) end)

        opted_out = connect(fault, max_retries: 2, timeout: 50, retry_on_status: [])
        assert {1, {:error, %Error{kind: :server}}} = attempts(opted_out, fn -> Database.list(opted_out) end)
      end
    end

    test "max_retries: 0 means one attempt, whatever the failure" do
      for fault <- FaultAdapter.faults() do
        conn = connect(fault, max_retries: 0, timeout: 50)

        assert {1, _result} = attempts(conn, fn -> Database.list(conn) end),
               "the #{fault} fault was attempted more than once with max_retries: 0"
      end
    end

    test "a non-idempotent call is never retried, however retryable the failure" do
      # A write that reached the server and lost its answer must not be sent
      # again, and a `:transport` error cannot tell that case from one where it
      # never arrived. So the decision is made before the kind is looked at.
      conn = connect(:raise, max_retries: 3, timeout: 50)

      assert {1, {:error, %Error{kind: :transport}}} =
               attempts(conn, fn -> TypeDB.query(conn, "social", "insert $p isa person;") end)
    end

    test "an idempotent read query is retried, though it is a POST" do
      conn = connect(:raise, max_retries: 2, timeout: 50)

      assert {3, {:error, %Error{kind: :transport}}} =
               attempts(conn, fn ->
                 TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)
               end)
    end

    test "the deadline ends the retries before :max_retries is spent" do
      # `:stall` sleeps twice the timeout it is handed and then answers. Nothing
      # can interrupt an attempt that is already running — an adapter is a
      # function call — so what the deadline buys is that the *next* one is not
      # started. With a budget of 300ms and attempts costing 100ms each, three
      # of the ten allowed fit.
      conn = connect(:stall, max_retries: 9, timeout: 50, deadline: 300)

      started = System.monotonic_time(:millisecond)
      {attempts, result} = attempts(conn, fn -> Database.list(conn) end)
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, %Error{kind: :timeout}} = result

      assert attempts > 1, "the deadline stopped the retries before any of them happened"
      assert attempts < 10, "the deadline did not stop the retries at all"

      # The budget is a budget: overrun by one attempt's worth is the most the
      # arithmetic allows, because the check happens between attempts.
      assert elapsed < 300 + 200,
             "the call took #{elapsed}ms against a 300ms deadline"
    end

    test "the last failure is the one the caller sees" do
      # Not a generic "it was retried" error: the reason the final attempt gave
      # is what a reader needs, and it used to be replaced by the deadline's own
      # message with nothing left of the cause.
      conn = connect(:server_error, max_retries: 2, timeout: 50)

      assert {:error, %Error{kind: :server, status: 503, code: "SRV9"}} = Database.list(conn)
    end
  end
end
