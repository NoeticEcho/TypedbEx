defmodule TypeDB.LogTest do
  use ExUnit.Case, async: true

  # `Log.answer_warning/2` used to take the connection and look it up, and
  # `Connection.config/1` raises when the connection is gone. So a query that had
  # already succeeded — response received, answer decoded and in hand — died on
  # the way out, in the code whose only job was to log a warning about it.
  #
  # Both halves of the trigger are ordinary: a supervisor restarting the
  # connection while a request is in flight, and a read TypeDB truncated at its
  # 10,000-answer cap. Neither is exotic; together they lost a good answer.

  import ExUnit.CaptureLog

  alias TypeDB.{Answer, Config, Log}

  @warned %Answer.ConceptRows{
    query_type: :read,
    rows: [],
    warning: "Read query results limit (10000) exceeded. Not all answers are returned."
  }

  @quiet %Answer.ConceptRows{query_type: :read, rows: []}

  defp config(opts \\ []) do
    Config.new!([url: "http://example.com", token: "t", name: :log_test_conn] ++ opts)
  end

  test "logging a warning does not consult the connection" do
    # The point of the fix, stated as an assertion: nothing here is registered
    # under `:log_test_conn`, so any lookup would raise. It must not.
    log = capture_log(fn -> assert Log.answer_warning({:ok, @warned}, config()) == {:ok, @warned} end)

    assert log =~ "the server attached a warning to this answer"
    assert log =~ "Read query results limit"
  end

  test "an answer with no warning passes through untouched" do
    assert capture_log(fn -> assert Log.answer_warning({:ok, @quiet}, config()) == {:ok, @quiet} end) =~
             ""

    assert Log.answer_warning({:ok, @quiet}, config()) == {:ok, @quiet}
  end

  test "an error passes through untouched" do
    error = {:error, TypeDB.Error.new(:server, "no")}
    assert Log.answer_warning(error, config()) == error
  end

  test ":log_level still silences the warning" do
    refute capture_log(fn -> Log.answer_warning({:ok, @warned}, config(log_level: :none)) end) =~
             "attached a warning"
  end

  describe "a connection that goes away mid-request" do
    defmodule StallingAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      @impl true
      def init(_name, opts), do: {:ok, %{test: Keyword.fetch!(opts, :test)}}

      @impl true
      def owner(_state), do: nil

      @impl true
      def terminate(_state), do: :ok

      # The response is ready before the connection is stopped, which is the
      # ordering that matters: the driver has a complete, valid answer and must
      # hand it back.
      @impl true
      def request(%{test: test}, _method, url, _headers, _body, _opts) do
        if String.ends_with?(url, "/signin") do
          {:ok, %{status: 200, headers: [], body: ~s|{"token":"t"}|}}
        else
          send(test, {:answer_ready, self()})
          receive do: (:connection_is_gone -> :ok), after: (5_000 -> :ok)

          {:ok,
           %{
             status: 200,
             headers: [],
             body:
               ~s|{"answerType":"conceptRows","queryType":"read","answers":[],| <>
                 ~s|"warning":"Read query results limit (10000) exceeded."}|
           }}
        end
      end
    end

    test "a query that already succeeded still returns its answer" do
      name = :"gone_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://example.com",
          username: "admin",
          password: "password",
          http: {StallingAdapter, [test: self()]}
        )

      task = Task.async(fn -> TypeDB.query(name, "d", "match $p;", transaction_type: :read) end)

      assert_receive {:answer_ready, adapter}, 5_000
      GenServer.stop(pid, :normal)
      send(adapter, :connection_is_gone)

      # Before the fix this did not return at all: the task exited with
      # `%TypeDB.Error{kind: :config}` raised from `Connection.lookup!/2`,
      # out of `Log.answer_warning/2`.
      assert {:ok, %Answer.ConceptRows{}} = Task.await(task, 10_000)
    end
  end
end
