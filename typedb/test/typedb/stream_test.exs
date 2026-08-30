defmodule TypeDB.StreamTest do
  use TypeDB.Case, async: true

  # `TypeDB.stream/4` walks a read query a page at a time, so that an answer
  # larger than the server's cap can be consumed at all. The stub answers by the
  # exact query string and the stream appends its own `offset`/`limit` stages,
  # so every page below is keyed deterministically.

  @query "match $p isa person, has name $n; sort $n; select $n;"

  # Built at compile time because `@tag` takes a value, not a call.
  page = fn names ->
    %{
      queryType: "read",
      answerType: "conceptRows",
      warning: nil,
      query: nil,
      answers:
        for name <- names do
          %{data: %{"n" => %{kind: "value", value: name, valueType: "string"}}, involvedBlocks: nil}
        end
    }
  end

  paged = fn pages, size ->
    pages
    |> Enum.with_index()
    |> Map.new(fn {names, index} ->
      {"#{@query} offset #{index * size}; limit #{size};", page.(names)}
    end)
  end

  # Two full pages then a short one: the short page is what says "no more".
  @three_pages paged.([~w(a b), ~w(c d), ~w(e)], 2)
  # A full page then an empty one: the stream must not spin.
  @exact_pages paged.([~w(a b), []], 2)
  @one_page paged.([~w(a b c)], 10)

  defp names(stream), do: Enum.map(stream, &TypeDB.ConceptRow.typed_value(&1, "n"))
  defp paths(stub), do: Enum.map(TypeDB.Stub.requests(stub), & &1.path)
  defp queries(stub), do: for(r <- TypeDB.Stub.requests(stub), q = query_of(r.body), do: q)

  defp query_of(body) do
    case TypeDB.JSON.decode(body) do
      {:ok, %{"query" => query}} -> query
      _ -> nil
    end
  end

  describe "stream/4" do
    @tag stub_opts: [databases: ["social"], answers: @three_pages]
    test "walks every page and stops on a short one", %{conn: conn, stub: stub} do
      assert names(TypeDB.stream(conn, "social", @query, page_size: 2)) == ~w(a b c d e)

      # Three pages asked for, and no fourth: a short page ends it.
      assert length(Enum.filter(queries(stub), &String.contains?(&1, "offset"))) == 3
    end

    @tag stub_opts: [databases: ["social"], answers: @exact_pages]
    test "a full last page costs one more request, and then stops", %{conn: conn, stub: stub} do
      assert names(TypeDB.stream(conn, "social", @query, page_size: 2)) == ~w(a b)
      assert length(Enum.filter(queries(stub), &String.contains?(&1, "offset"))) == 2
    end

    @tag stub_opts: [databases: ["social"], answers: @one_page]
    test "the appended stages are offset and limit, in that order", %{conn: conn, stub: stub} do
      assert names(TypeDB.stream(conn, "social", @query, page_size: 10)) == ~w(a b c)

      assert Enum.any?(queries(stub), &(&1 == "#{@query} offset 0; limit 10;"))
    end

    @tag stub_opts: [databases: ["social"], answers: @three_pages]
    test "closes the transaction when the consumer stops early", %{conn: conn, stub: stub} do
      assert conn |> TypeDB.stream("social", @query, page_size: 2) |> Enum.take(3) |> length() == 3

      assert Enum.any?(paths(stub), &String.ends_with?(&1, "/close")),
             "a stream abandoned mid-page must still close its transaction"
    end

    @tag stub_opts: [databases: ["social"], answers: @three_pages]
    test "runs in one read transaction, not one per page", %{conn: conn, stub: stub} do
      _ = names(TypeDB.stream(conn, "social", @query, page_size: 2))

      opens = Enum.count(paths(stub), &String.ends_with?(&1, "/transactions/open"))
      assert opens == 1, "expected one transaction for the whole walk, got #{opens}"
    end

    @tag stub_opts: [databases: [], answers: @one_page]
    test "a failure while walking raises the driver's own error", %{conn: conn} do
      # No such database, so opening the transaction fails.
      assert_raise TypeDB.Error, fn ->
        names(TypeDB.stream(conn, "nope", @query, page_size: 10))
      end
    end

    @tag stub_opts: [databases: ["social"], answers: @one_page]
    test "an option it does not accept is rejected rather than ignored", %{conn: conn} do
      assert_raise ArgumentError, ~r/unknown option :pagesize/, fn ->
        TypeDB.stream(conn, "social", @query, pagesize: 10)
      end
    end

    @tag stub_opts: [databases: ["social"], answers: @one_page]
    test "a page size that is not a positive integer is refused", %{conn: conn} do
      assert_raise ArgumentError, ~r/:page_size/, fn ->
        TypeDB.stream(conn, "social", @query, page_size: 0)
      end
    end
  end
end
