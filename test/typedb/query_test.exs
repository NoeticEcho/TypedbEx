defmodule TypeDB.QueryTest do
  use TypeDB.Case, async: true

  @moduletag stub_opts: [databases: ["social"]]

  describe "query/4" do
    test "runs a one-shot query and decodes concept rows", %{conn: conn} do
      assert {:ok, %Answer.ConceptRows{} = answer} =
               TypeDB.query(conn, "social", "match $p isa person, has name $name;")

      assert answer.query_type == :read
      assert [row] = answer.rows
      assert %Concept.Entity{iid: "0x1e00000000000000000000"} = row["p"]
      assert %Concept.Attribute{value: "Alice", value_type: "string"} = row["name"]
    end

    test "sends the query, database and transaction type", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :read)

      assert [request] = requests(stub, "/v1/query")
      payload = JSON.decode!(request.body)

      assert payload["query"] == "match $p isa person;"
      assert payload["databaseName"] == "social"
      assert payload["transactionType"] == "read"
    end

    test "defaults to a schema transaction so any query is accepted", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.query(conn, "social", "define entity person;")

      assert [request] = requests(stub, "/v1/query")
      assert JSON.decode!(request.body)["transactionType"] == "schema"
    end

    test "forwards commit: false", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.query(conn, "social", "insert $p isa person;", commit: false)

      assert [request] = requests(stub, "/v1/query")
      assert JSON.decode!(request.body)["commit"] == false
    end

    test "forwards query options in camelCase", %{conn: conn, stub: stub} do
      assert {:ok, _} =
               TypeDB.query(conn, "social", "match $p isa person;",
                 include_instance_types: false,
                 answer_count_limit: 25,
                 include_query_structure: true
               )

      assert [request] = requests(stub, "/v1/query")

      assert JSON.decode!(request.body)["queryOptions"] == %{
               "includeInstanceTypes" => false,
               "answerCountLimit" => 25,
               "includeQueryStructure" => true
             }
    end

    test "forwards transaction options in camelCase", %{conn: conn, stub: stub} do
      assert {:ok, _} =
               TypeDB.query(conn, "social", "match $p isa person;",
                 transaction_timeout_millis: 1_000,
                 schema_lock_acquire_timeout_millis: 2_000
               )

      assert [request] = requests(stub, "/v1/query")

      assert JSON.decode!(request.body)["transactionOptions"] == %{
               "transactionTimeoutMillis" => 1_000,
               "schemaLockAcquireTimeoutMillis" => 2_000
             }
    end

    test "omits option objects when no options were given", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.query(conn, "social", "match $p isa person;")

      payload = stub |> requests("/v1/query") |> hd() |> Map.fetch!(:body) |> JSON.decode!()
      refute Map.has_key?(payload, "queryOptions")
      refute Map.has_key?(payload, "transactionOptions")
      refute Map.has_key?(payload, "commit")
    end

    test "rejects an invalid transaction type before making a request", %{conn: conn, stub: stub} do
      assert_raise ArgumentError, ~r/invalid :transaction_type/, fn ->
        TypeDB.query(conn, "social", "match $p isa person;", transaction_type: :readonly)
      end

      assert requests(stub, "/v1/query") == []
    end

    test "decodes an ok answer", %{conn: conn} do
      assert {:ok, %Answer.Ok{query_type: :schema}} = TypeDB.query(conn, "social", "define entity person;")
    end

    test "decodes concept documents", %{conn: conn} do
      assert {:ok, %Answer.ConceptDocuments{documents: [%{"name" => "Alice"}], query_type: :read}} =
               TypeDB.query(conn, "social", "match $p isa person; fetch { 'name': $p.name };")
    end

    test "reports an unknown database", %{conn: conn} do
      assert {:error, %Error{kind: :server, status: 400, code: "SRV3"}} =
               TypeDB.query(conn, "nonexistent", "match $p isa person;")
    end

    test "query!/4 raises on error", %{conn: conn} do
      assert_raise Error, ~r/SRV3/, fn -> TypeDB.query!(conn, "nonexistent", "match $p isa person;") end
    end
  end

  describe "answers" do
    @tag stub_opts: [
           databases: ["social"],
           answers: %{
             "warned" => %{
               queryType: "read",
               answerType: "conceptRows",
               answers: [],
               warning: "answer count limit reached"
             }
           }
         ]
    test "expose server warnings", %{conn: conn} do
      assert {:ok, answer} = TypeDB.query(conn, "social", "warned")
      assert Answer.warning(answer) == "answer count limit reached"
    end

    test "are enumerable", %{conn: conn} do
      assert {:ok, answer} = TypeDB.query(conn, "social", "match $p isa person;")

      assert Enum.count(answer) == 1
      assert [%ConceptRow{}] = Enum.to_list(answer)
      assert ["Alice"] = Enum.map(answer, &ConceptRow.value(&1, "name"))
    end

    # Both answer types used to delegate `slice/1` to `Enumerable.List`, which
    # declines and sends `Enum` into `Enumerable.List.reduce/3` with the struct —
    # a FunctionClauseError out of `Enum.at/2` and `Enum.slice/2`. The whole
    # protocol is exercised here so no part of it can quietly stop working.
    for {label, build} <- [
          {"ConceptRows", quote(do: fn items -> %Answer.ConceptRows{query_type: :read, rows: items} end)},
          {"ConceptDocuments",
           quote(do: fn items -> %Answer.ConceptDocuments{query_type: :read, documents: items} end)}
        ] do
      test "#{label} supports the whole Enumerable protocol" do
        build = unquote(build)
        answer = build.([:a, :b, :c, :d, :e])

        assert Enum.count(answer) == 5
        assert Enum.to_list(answer) == [:a, :b, :c, :d, :e]
        assert Enum.at(answer, 2) == :c
        assert Enum.at(answer, -1) == :e
        assert Enum.at(answer, 99) == nil
        assert Enum.slice(answer, 1..3) == [:b, :c, :d]
        assert Enum.slice(answer, 1, 2) == [:b, :c]
        assert Enum.slice(answer, 0..4//2) == [:a, :c, :e]
        assert Enum.take(answer, 2) == [:a, :b]
        assert Enum.drop(answer, 3) == [:d, :e]
        assert Enum.member?(answer, :c)
        refute Enum.member?(answer, :z)
        refute Enum.empty?(answer)
        assert Enum.reverse(answer) == [:e, :d, :c, :b, :a]

        empty = build.([])
        # count/1 asserted on its own so credo does not read it as a slow empty?/1
        assert 0 = Enum.count(empty)
        assert Enum.empty?(empty)
        assert Enum.at(empty, 0) == nil
        assert Enum.slice(empty, 0..3) == []
      end
    end

    @tag stub_opts: [
           databases: ["social"],
           answers: %{"bad" => %{queryType: "read", answerType: "spaceship"}}
         ]
    test "an unknown answer type is a decode error, not a crash", %{conn: conn} do
      assert {:error, %Error{kind: :decode, message: message}} = TypeDB.query(conn, "social", "bad")
      assert message =~ "spaceship"
    end

    @tag stub_opts: [databases: ["social"], answers: %{"bad" => %{queryType: "sideways", answerType: "ok"}}]
    test "an unknown query type is a decode error", %{conn: conn} do
      assert {:error, %Error{kind: :decode}} = TypeDB.query(conn, "social", "bad")
    end

    @tag stub_opts: [
           databases: ["social"],
           answers: %{
             "weird" => %{
               queryType: "read",
               answerType: "conceptRows",
               answers: [%{data: %{"x" => %{kind: "wormhole"}}}]
             }
           }
         ]
    test "an unknown concept kind is a decode error", %{conn: conn} do
      assert {:error, %Error{kind: :decode, message: message}} = TypeDB.query(conn, "social", "weird")
      assert message =~ "wormhole"
    end
  end
end
