defmodule TypeDB.TransactionTest do
  use TypeDB.Case, async: true

  @moduletag stub_opts: [databases: ["social"]]

  describe "open/4" do
    test "opens a transaction and returns a handle", %{conn: conn, stub: stub} do
      assert {:ok, %Transaction{id: id, database: "social", type: :write}} =
               Transaction.open(conn, "social", :write)

      assert is_binary(id)

      assert [request] = requests(stub, "/transactions/open")
      payload = JSON.decode!(request.body)
      assert payload["databaseName"] == "social"
      assert payload["transactionType"] == "write"
      refute Map.has_key?(payload, "transactionOptions")
    end

    test "forwards transaction options", %{conn: conn, stub: stub} do
      assert {:ok, _tx} = Transaction.open(conn, "social", :schema, schema_lock_acquire_timeout_millis: 5_000)

      payload = stub |> requests("/transactions/open") |> hd() |> Map.fetch!(:body) |> JSON.decode!()
      assert payload["transactionOptions"] == %{"schemaLockAcquireTimeoutMillis" => 5_000}
    end

    test "reports an unknown database", %{conn: conn} do
      # 400, not the 404 the shape of the request suggests, and SRV3 rather than
      # a transaction code. Verified against TypeDB 3.12.1 — see
      # test/integration/error_code_integration_test.exs.
      assert {:error, %Error{status: 400, code: "SRV3"}} = Transaction.open(conn, "nope", :read)
    end

    test "rejects an unknown transaction type by name", %{conn: conn} do
      # Computed so the compile-time type checker does not flag the bad call.
      type = String.to_atom("sideways")

      assert_raise ArgumentError, ~r/invalid transaction type :sideways/, fn ->
        Transaction.open(conn, "social", type)
      end
    end
  end

  describe "query/3" do
    setup %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :write)
      {:ok, tx: tx}
    end

    test "runs against the transaction endpoint", %{tx: tx, stub: stub} do
      assert {:ok, %Answer.ConceptRows{}} = Transaction.query(tx, "insert $p isa person;")

      assert [request] = requests(stub, "/query")
      assert request.path == "/v1/transactions/#{tx.id}/query"
    end

    test "forwards query options", %{tx: tx, stub: stub} do
      assert {:ok, _} = Transaction.query(tx, "match $p isa person;", answer_count_limit: 3)

      payload = stub |> requests("/query") |> hd() |> Map.fetch!(:body) |> JSON.decode!()
      assert payload["queryOptions"] == %{"answerCountLimit" => 3}
    end

    test "forwards given_rows, tagging values so they cannot be parsed as TypeQL", %{tx: tx, stub: stub} do
      rows = [%{"name" => "Alice"}, %{"name" => ~s(evil "; delete $p isa person;)}]
      assert {:ok, _} = Transaction.query(tx, "insert $p isa person, has name == $name;", given_rows: rows)

      payload = stub |> requests("/query") |> hd() |> Map.fetch!(:body) |> JSON.decode!()

      assert payload["givenRows"] == [
               %{"name" => %{"kind" => "value", "value" => "Alice", "valueType" => "string"}},
               %{
                 "name" => %{
                   "kind" => "value",
                   "value" => ~s(evil "; delete $p isa person;),
                   "valueType" => "string"
                 }
               }
             ]
    end

    test "query!/3 raises", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :read)
      :ok = Transaction.close(tx)

      assert_raise Error, fn -> Transaction.query!(tx, "match $p isa person;") end
    end
  end

  describe "lifecycle" do
    test "commit finishes the transaction", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.commit(tx)
      assert {:error, %Error{status: 404, code: "TSV12"}} = Transaction.query(tx, "match $p isa person;")
    end

    test "commit on a read transaction is rejected by the server", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :read)
      assert {:error, %Error{status: 400, code: "TSV2"}} = Transaction.commit(tx)
    end

    test "commit! raises on failure", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :read)
      assert_raise Error, ~r/TSV2/, fn -> Transaction.commit!(tx) end
    end

    test "rollback leaves the transaction usable", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.rollback(tx)
      assert {:ok, _} = Transaction.query(tx, "insert $p isa person;")
      assert :ok = Transaction.commit(tx)
    end

    test "close is idempotent", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :read)
      assert :ok = Transaction.close(tx)
      assert :ok = Transaction.close(tx)
    end

    test "analyze returns the pipeline structure", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :read)
      assert {:ok, %{"query" => %{"stages" => []}}} = Transaction.analyze(tx, "match $p isa person;")
    end
  end

  describe "TypeDB.transaction/5" do
    test "commits when the block succeeds", %{conn: conn, stub: stub} do
      assert :ok =
               TypeDB.transaction(conn, "social", :write, fn tx ->
                 {:ok, _} = Transaction.query(tx, "insert $p isa person;")
                 :ok
               end)

      assert length(requests(stub, "/commit")) == 1
      assert requests(stub, "/rollback") == []
    end

    test "returns the block's value", %{conn: conn} do
      assert 42 = TypeDB.transaction(conn, "social", :write, fn _tx -> 42 end)
    end

    test "rolls back and propagates when the block returns an error", %{conn: conn, stub: stub} do
      assert {:error, :nope} = TypeDB.transaction(conn, "social", :write, fn _tx -> {:error, :nope} end)

      assert length(requests(stub, "/rollback")) == 1
      assert requests(stub, "/commit") == []
    end

    test "rolls back and re-raises when the block raises", %{conn: conn, stub: stub} do
      assert_raise RuntimeError, "boom", fn ->
        TypeDB.transaction(conn, "social", :write, fn _tx -> raise "boom" end)
      end

      assert length(requests(stub, "/rollback")) == 1
      assert requests(stub, "/commit") == []
    end

    test "rolls back and re-throws when the block throws", %{conn: conn, stub: stub} do
      assert catch_throw(TypeDB.transaction(conn, "social", :write, fn _tx -> throw(:bail) end)) == :bail
      assert length(requests(stub, "/rollback")) == 1
    end

    test "closes rather than commits a read transaction", %{conn: conn, stub: stub} do
      assert {:ok, _} =
               TypeDB.transaction(conn, "social", :read, fn tx ->
                 Transaction.query(tx, "match $p isa person;")
               end)

      assert requests(stub, "/commit") == []
      assert length(requests(stub, "/close")) == 1
    end

    test "commit, rollback and close each take their own :timeout", %{conn: conn, stub: stub} do
      # A commit is where the server does the work, so it is the request most
      # likely to want more time than an ordinary query — and until now the only
      # way to give it any was to raise the whole connection's :timeout.
      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.commit(tx, timeout: 30_000)

      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.rollback(tx, timeout: 30_000)
      assert :ok = Transaction.close(tx, timeout: 30_000)

      # And the arity-1 forms still work, so this stayed additive.
      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.rollback(tx)
      assert :ok = Transaction.close(tx)

      assert length(requests(stub, "/commit")) == 1
      assert length(requests(stub, "/rollback")) == 2
      assert length(requests(stub, "/close")) == 2
    end

    test "the bang forms take :timeout too", %{conn: conn} do
      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.rollback!(tx, timeout: 30_000)
      assert :ok = Transaction.close!(tx, timeout: 30_000)

      {:ok, tx} = Transaction.open(conn, "social", :write)
      assert :ok = Transaction.commit!(tx, timeout: 30_000)
    end

    test "returns an error when the transaction cannot be opened", %{conn: conn} do
      assert {:error, %Error{code: "SRV3"}} =
               TypeDB.transaction(conn, "nope", :write, fn _tx -> :never_runs end)
    end

    @tag stub_opts: [databases: ["social"], fail_commit: true]
    test "a failed commit wins over the block's return value", %{conn: conn} do
      assert {:error, %Error{code: "TSV6"}} =
               TypeDB.transaction(conn, "social", :write, fn _tx -> :all_good end)
    end

    @tag stub_opts: [databases: ["social"], fail_commit: true]
    test "a commit the server rejected needs no close", %{conn: conn, stub: stub} do
      assert {:error, %Error{code: "TSV6"}} =
               TypeDB.transaction(conn, "social", :write, fn _tx -> :all_good end)

      # The server finished the transaction when it rejected the commit.
      assert requests(stub, "/close") == []
    end

    # Delegates everything to the real adapter except the commit, which never
    # reaches the server — the one case where the transaction is still open
    # afterwards and nobody but this driver can close it.
    defmodule CommitLosingAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(name, opts) do
        {inner, inner_opts} = Keyword.fetch!(opts, :inner)

        with {:ok, state} <- inner.init(name, inner_opts), do: {:ok, {inner, state}}
      end

      def request({inner, state}, method, url, headers, body, opts) do
        if String.ends_with?(url, "/commit") do
          {:error, TypeDB.Error.new(:transport, "the commit never left the building")}
        else
          inner.request(state, method, url, headers, body, opts)
        end
      end

      def owner({inner, state}) do
        if function_exported?(inner, :owner, 1), do: inner.owner(state), else: nil
      end

      def terminate({inner, state}) do
        if function_exported?(inner, :terminate, 1), do: inner.terminate(state), else: :ok
      end
    end

    test "a commit that never reached the server still closes the transaction", %{stub: stub} do
      name = :"lost_commit_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: TypeDB.Stub.url(stub),
          username: "admin",
          password: "password",
          http: {CommitLosingAdapter, [inner: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}]}
        )

      assert {:error, %Error{kind: :transport}} =
               TypeDB.transaction(name, "social", :write, fn _tx -> :all_good end)

      # Otherwise it stays open, holding its locks, until TypeDB's own
      # transaction timeout expires.
      assert length(requests(stub, "/close")) == 1

      TypeDB.stop(pid)
    end
  end
end
