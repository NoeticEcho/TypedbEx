defmodule TypeDB.StreamIntegrationTest do
  @moduledoc """
  `TypeDB.stream/4` against a real server.

  The unit suite drives it through the stub, which answers canned pages by the
  exact query string — that proves the walking, and nothing about the server.
  What only a server can settle is here: that the answer really does exceed the
  cap `query/4` stops at, and that one read transaction really does hold a
  snapshot while somebody else writes.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.{Answer, ConceptRow, Database}

  # Above TypeDB's own 10,000-answer cap, so `query/4` is provably short.
  @rows 25_000

  @schema "define attribute name, value string; entity person, owns name @key;"
  @walk "match $p isa person, has name $n; sort $n; select $n;"

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")

    {:ok, pid} =
      TypeDB.start_link(
        name: :typedb_stream_integration,
        url: url,
        username: System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin"),
        password: System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password"),
        timeout: 60_000,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    on_exit(fn ->
      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: :typedb_stream_integration}
  end

  setup %{conn: conn} do
    database = TypeDB.Case.unique_name("stream_test")
    :ok = Database.create(conn, database)
    on_exit(fn -> Database.delete(conn, database) end)
    {:ok, _} = TypeDB.query(conn, database, @schema)
    insert(conn, database, 1, @rows)
    {:ok, database: database}
  end

  defp insert(conn, database, from, to) do
    from
    |> Range.new(to)
    |> Stream.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      rows = for i <- chunk, do: %{"n" => "p#{String.pad_leading("#{i}", 6, "0")}"}

      {:ok, _} =
        TypeDB.query(conn, database, "given $n: string; insert $p isa person, has name == $n;",
          transaction_type: :write,
          given_rows: rows
        )
    end)
  end

  defp name_of(row), do: ConceptRow.typed_value(row, "n")

  test "walks past the cap that query/4 stops at", %{conn: conn, database: database} do
    {:ok, capped} = TypeDB.query(conn, database, @walk, transaction_type: :read)

    # The premise: this answer is bigger than one request can carry.
    assert length(Answer.rows(capped)) == 10_000
    assert Answer.truncated?(capped)

    walked = conn |> TypeDB.stream(database, @walk, page_size: 2_000) |> Enum.map(&name_of/1)

    assert length(walked) == @rows
    assert walked == Enum.sort(walked), "the walk must preserve the query's own order"
    assert hd(walked) == "p000001"
    assert List.last(walked) == "p0#{@rows}"
  end

  test "one read transaction holds a snapshot while another writes", %{
    conn: conn,
    database: database
  } do
    parent = self()

    walker =
      Task.async(fn ->
        conn
        |> TypeDB.stream(database, @walk, page_size: 1_000)
        |> Enum.reduce(0, fn _row, seen ->
          if seen == 3_000, do: send(parent, :midway)
          seen + 1
        end)
      end)

    # Write into the database from a different transaction, part-way through.
    receive do
      :midway -> insert(conn, database, @rows + 1, @rows + 5_000)
    after
      120_000 -> flunk("the walk never reached the halfway mark")
    end

    assert Task.await(walker, 240_000) == @rows,
           "the walk must see the snapshot it opened on, not the rows written during it"

    {:ok, counted} =
      TypeDB.query(conn, database, "match $p isa person; reduce $c = count;", transaction_type: :read)

    assert counted |> Answer.rows() |> hd() |> ConceptRow.typed_value("c") == @rows + 5_000,
           "and the writes must really have landed, or this test proves nothing"
  end

  test "is lazy: taking a few rows does not walk the answer", %{conn: conn, database: database} do
    taken = conn |> TypeDB.stream(database, @walk, page_size: 1_000) |> Enum.take(5)

    assert Enum.map(taken, &name_of/1) == ~w(p000001 p000002 p000003 p000004 p000005)
  end

  test "agrees with query/4 on an answer that fits in one", %{conn: conn, database: database} do
    query = "match $p isa person, has name $n; sort $n; limit 100; select $n;"

    {:ok, answer} = TypeDB.query(conn, database, query, transaction_type: :read)
    via_query = answer |> Answer.rows() |> Enum.map(&name_of/1)

    # A page size that does not divide the answer, so the last page is short.
    via_stream = conn |> TypeDB.stream(database, query, page_size: 7) |> Enum.map(&name_of/1)

    assert via_stream == via_query
    assert length(via_stream) == 100
  end

  test "a fetch pipeline cannot be paged, and says so", %{conn: conn, database: database} do
    fetch = ~s|match $p isa person, has name $n; sort $n; fetch { "name": $n };|

    # `offset` and `limit` after a `fetch` stage are a syntax error. The caller
    # sees the server's own TQL0 rather than anything this driver invented.
    error =
      assert_raise TypeDB.Error, fn ->
        conn |> TypeDB.stream(database, fetch, page_size: 10) |> Enum.take(1)
      end

    assert error.code == "TQL0"
  end
end
