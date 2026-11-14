defmodule TypeDB.VectorIntegrationTest do
  @moduledoc """
  Vector values and cosine search over HTTP, against a TypeDB build with
  vector support — experimental, and no release is one yet.

  Tagged `:vector_preview` and not `:integration`, so an ordinary integration
  run against a stock server does not pull it in. Pinned against the build
  `3.14.1-dev` at commit `11ab292c`, started with
  `--experimental-vector-search-enabled=true`:

      TYPEDB_VECTOR_URL=http://127.0.0.1:8010 mix test --include vector_preview \\
        test/integration/vector_integration_test.exs

  Nothing here sends a search inside `not { }` or `or { }`: on that build
  either one panics the server (see `TypeDB.Vector`).
  """

  use ExUnit.Case, async: false

  @moduletag :vector_preview
  @moduletag timeout: 120_000

  alias TypeDB.{Answer, Concept, ConceptRow, Database, Vector}

  @type4 ~s|vector(4, "float32")|

  setup_all do
    {:ok, pid} =
      TypeDB.start_link(
        name: :typedb_vector,
        url: System.fetch_env!("TYPEDB_VECTOR_URL"),
        username: System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin"),
        password: System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")
      )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, conn: :typedb_vector}
  end

  setup %{conn: conn} do
    database = "vec_#{System.unique_integer([:positive])}"
    :ok = Database.create(conn, database)
    on_exit(fn -> Database.delete(:typedb_vector, database) end)

    {:ok, _} =
      TypeDB.query(
        conn,
        database,
        """
        define
          attribute content, value string;
          attribute owner, value string;
          attribute embedding, value vector(4, "float32") @index(hnsw:cosine);
          entity memory, owns content @key, owns owner, owns embedding;
          relation replaces, relates new, relates old;
          memory plays replaces:new, plays replaces:old;
        """,
        transaction_type: :schema
      )

    insert = fn rows ->
      {:ok, _} =
        TypeDB.query(
          conn,
          database,
          ~s|given $c: string, $o: string, $v: vector(4, "float32"); insert $m isa memory, has content == $c, has owner == $o, has embedding == $v;|,
          transaction_type: :write,
          given_rows: Enum.map(rows, fn {c, o, v} -> %{"c" => c, "o" => o, "v" => Vector.value!(v)} end)
        )
    end

    insert.([
      {"x", "a", [1, 0, 0, 0]},
      {"near-x", "a", [0.9, 0.1, 0, 0]},
      {"x-of-b", "b", [1, 0, 0, 0.01]},
      {"y", "a", [0, 1, 0, 0]}
    ])

    {:ok, conn: conn, database: database}
  end

  defp read(conn, database, query, rows) do
    {:ok, answer} =
      TypeDB.query(conn, database, query, transaction_type: :read, given_rows: rows)

    Answer.rows(answer)
  end

  defp q(v), do: Vector.value!(v)

  test "the attribute type reports its dimension and dtype", %{conn: conn, database: database} do
    assert [row] = read(conn, database, "match $t label embedding;", nil)
    assert %Concept.AttributeType{value_type: @type4} = ConceptRow.get(row, "t")
  end

  test "a stored vector comes back as the list it was", %{conn: conn, database: database} do
    [row] =
      read(conn, database, ~s|match $m has content "near-x", has embedding $e; select $e;|, nil)

    assert %Concept.Attribute{value: [a, b, +0.0, +0.0], value_type: @type4} =
             ConceptRow.get(row, "e")

    assert_in_delta a, 0.9, 1.0e-6
    assert_in_delta b, 0.1, 1.0e-6
  end

  test "the score binds as a double, sorts and limits", %{conn: conn, database: database} do
    rows =
      read(
        conn,
        database,
        """
        given $q: vector(4, "float32");
        match let $e, $s in cosine_similarity_search(embedding, $q, -1.0);
          $m isa memory, has content $c, has embedding $e;
        select $c, $s; sort $s desc; limit 2;
        """,
        [%{"q" => q([1, 0, 0, 0])}]
      )

    assert Enum.map(rows, &ConceptRow.typed_value(&1, "c")) == ["x", "x-of-b"]
    assert [s1, s2] = Enum.map(rows, &ConceptRow.typed_value(&1, "s"))
    assert is_float(s1) and s1 >= s2
  end

  test "the threshold, an owner filter and a negation join the search in one query", %{
    conn: conn,
    database: database
  } do
    {:ok, _} =
      TypeDB.query(
        conn,
        database,
        ~s|match $n has content "near-x"; $o has content "x"; insert replaces (new: $n, old: $o);|,
        transaction_type: :write
      )

    rows =
      read(
        conn,
        database,
        """
        given $q: vector(4, "float32"), $owner: string;
        match let $e, $s in cosine_similarity_search(embedding, $q, 0.8);
          $m isa memory, has content $c, has owner == $owner, has embedding $e;
          not { replaces (old: $m); };
        select $c; sort $c;
        """,
        [%{"q" => q([1, 0, 0, 0]), "owner" => "a"}]
      )

    assert Enum.map(rows, &ConceptRow.typed_value(&1, "c")) == ["near-x"]
  end

  test "several given rows run once each, and sort and limit span them", %{
    conn: conn,
    database: database
  } do
    rows =
      read(
        conn,
        database,
        """
        given $q: vector(4, "float32"), $owner: string;
        match let $e, $s in cosine_similarity_search(embedding, $q, -1.0);
          $m isa memory, has content $c, has owner == $owner, has embedding $e;
        select $c, $s; sort $s desc; limit 2;
        """,
        [%{"q" => q([1, 0, 0, 0]), "owner" => "b"}, %{"q" => q([1, 0, 0, 0]), "owner" => "a"}]
      )

    assert Enum.map(rows, &ConceptRow.typed_value(&1, "c")) == ["x", "x-of-b"]
  end

  test "the server refuses a zero-norm query vector", %{conn: conn, database: database} do
    assert {:error, %TypeDB.Error{}} =
             TypeDB.query(
               conn,
               database,
               ~s|given $q: vector(4, "float32"); match let $e, $s in cosine_similarity_search(embedding, $q, 0.5); select $s;|,
               transaction_type: :read,
               given_rows: [%{"q" => q([0, 0, 0, 0])}]
             )
  end
end
