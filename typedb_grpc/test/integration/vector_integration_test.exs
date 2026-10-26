defmodule TypeDB.GRPC.VectorIntegrationTest do
  @moduledoc """
  Vector values against a live server — experimental, and only meaningful
  against a TypeDB build with vector support, which a stock release is not.

  Tagged `:vector_preview` and *not* `:integration`: ExUnit runs a test that
  matches any `--include`, so the second tag would pull this into every
  ordinary integration run, where a server without vectors fails the schema
  below. To run it:

      TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 \\
      TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 \\
        mix test --include vector_preview test/integration/vector_integration_test.exs

  With `TYPEDB_INTEGRATION_URL` set as well, the same value is also read over
  HTTP and compared, which is the claim that matters: an application reads the
  same term whichever transport it is on.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :vector_preview

  alias TypeDB.{Answer, Concept, ConceptRow}
  alias TypeDB.GRPC.Transaction

  @type4 ~s|vector(4, "float32")|

  setup_all do
    if address(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip] do
      :ok
    else
      conn = start_connection()
      database = start_database(conn, "grpc_vec")

      {:ok, _} =
        Transaction.transaction(conn, database, :schema, fn tx ->
          Transaction.query(tx, """
            define
              attribute content, value string;
              attribute embedding, value vector(4, "float32");
              entity memory, owns content, owns embedding;
          """)
        end)

      {:ok, conn: conn, database: database}
    end
  end

  defp vector(values), do: %Concept.Value{value: values, value_type: @type4}

  defp insert(conn, database, rows) do
    {:ok, _} =
      Transaction.transaction(conn, database, :write, fn tx ->
        Transaction.query(
          tx,
          ~s|given $c: string, $v: vector(4, "float32"); insert $m isa memory, has content == $c, has embedding == $v;|,
          given_rows: Enum.map(rows, fn {content, values} -> %{"c" => content, "v" => vector(values)} end)
        )
      end)
  end

  defp read(conn, database, query, opts \\ []) do
    {:ok, answer} = Transaction.transaction(conn, database, :read, &Transaction.query(&1, query, opts))
    Answer.rows(answer)
  end

  test "the schema reports the attribute's dimension and dtype", %{conn: conn, database: database} do
    assert [row] = read(conn, database, "match $t label embedding;")
    assert %Concept.AttributeType{label: "embedding", value_type: @type4} = ConceptRow.get(row, "t")
  end

  test "a vector given as a row comes back as the same list", %{conn: conn, database: database} do
    insert(conn, database, [{"a", [1.0, 0.0, 0.5, -2]}])

    assert [row] = read(conn, database, "match $m isa memory, has embedding $e; select $e;")

    assert %Concept.Attribute{value: [1.0, +0.0, 0.5, -2.0], value_type: @type4} = ConceptRow.get(row, "e")
  end

  test "cosine similarity search takes its query vector as a given row", %{conn: conn, database: database} do
    insert(conn, database, [{"x", [1, 0, 0, 0]}, {"near-x", [0.9, 0.1, 0, 0]}, {"y", [0, 1, 0, 0]}])

    rows =
      read(
        conn,
        database,
        """
        given $q: vector(4, "float32");
        match let $e in cosine_similarity_search(embedding, $q, 0.8);
          $m isa memory, has content $c, has embedding $e;
        select $c;
        """,
        given_rows: [%{"q" => vector([1, 0, 0, 0])}]
      )

    assert rows |> Enum.map(&ConceptRow.typed_value(&1, "c")) |> Enum.sort() == ["near-x", "x"]
  end

  test "a vector of the wrong length never leaves the caller, and the transaction survives", %{
    conn: conn,
    database: database
  } do
    {:ok, tx} = Transaction.open(conn, database, :read)
    on_exit(fn -> Transaction.close(tx) end)

    assert {:error, %TypeDB.Error{kind: :encode}} =
             Transaction.query(tx, ~s|given $q: vector(4, "float32"); match $m isa memory;|,
               given_rows: [%{"q" => %Concept.Value{value: [1.0, 0.0], value_type: @type4}}]
             )

    assert {:ok, _} = Transaction.query(tx, "match $m isa memory;")
  end

  test "both transports read the same value", %{conn: conn, database: database} do
    url = System.get_env("TYPEDB_INTEGRATION_URL")

    if url in [nil, ""] do
      IO.puts("\n  skipped the HTTP comparison: TYPEDB_INTEGRATION_URL is not set")
    else
      insert(conn, database, [{"a", [0.1, 0.2, 0.3, 0.4]}])
      query = "match $m isa memory, has embedding $e; select $e;"

      http = :"vector_http_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link([name: http, url: url] ++ credentials())
      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, answer} = TypeDB.query(http, database, query, transaction_type: :read)
      [over_http] = Answer.rows(answer)
      [over_grpc] = read(conn, database, query)

      assert ConceptRow.get(over_grpc, "e").value == ConceptRow.get(over_http, "e").value
      assert ConceptRow.get(over_grpc, "e").value_type == ConceptRow.get(over_http, "e").value_type

      assert ConceptRow.get(over_grpc, "e").value == [
               0.10000000149011612,
               0.20000000298023224,
               0.30000001192092896,
               0.4000000059604645
             ]
    end
  end
end
