defmodule TypeDB.AdapterParityTest do
  use ExUnit.Case, async: true

  # The three adapters are interchangeable by design, and one of them silently
  # was not: `:httpc` queued every request behind a slow one while the other two
  # did not, which nothing noticed for three releases because each adapter was
  # only ever exercised against a well-behaved server.
  #
  # So: the same odd-but-legal server responses, through all three, asserting
  # they agree. A difference here is a bug wherever it is — in the adapter, in
  # the library under it, or in the driver's expectations of both.

  alias TypeDB.Stub

  @adapters [
    {"Finch", {TypeDB.HTTP.Finch, []}},
    {"Req", {TypeDB.HTTP.Req, []}},
    {":httpc", {TypeDB.HTTP.Httpc, []}}
  ]

  # What every adapter answered, reduced to something comparable: the shape of
  # the result rather than a message, since messages are each library's own.
  defp through_every_adapter(handler, call) do
    {:ok, stub} = Stub.start_link(handler: handler)

    on_exit(fn ->
      try do
        Stub.stop(stub)
      catch
        :exit, _ -> :ok
      end
    end)

    for {name, adapter} <- @adapters, into: %{} do
      conn = :"parity_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: conn,
          url: Stub.url(stub),
          token: "t",
          max_retries: 0,
          timeout: 5_000,
          http: adapter
        )

      result =
        case call.(conn) do
          {:ok, value} -> {:ok, value}
          :ok -> {:ok, :ok}
          {:error, %TypeDB.Error{kind: kind, status: status}} -> {:error, kind, status}
        end

      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end

      {name, result}
    end
  end

  defp assert_agree(results) do
    distinct = results |> Map.values() |> Enum.uniq()

    assert length(distinct) == 1,
           "the adapters disagree: " <>
             Enum.map_join(results, ", ", fn {name, result} -> "#{name} #{inspect(result)}" end)

    results |> Map.values() |> hd()
  end

  defp list(conn), do: TypeDB.Database.list(conn)

  test "a redirect is not followed by any adapter" do
    # Req follows redirects by default and `:httpc` has `autoredirect`; both are
    # turned off deliberately. A driver that followed one would send its bearer
    # token to whatever host the `location` header named.
    handler = fn _method, _path, _headers, _body ->
      {302, [{"location", "http://127.0.0.1:1/v1/databases"}], ""}
    end

    assert {:error, :server, 302} = through_every_adapter(handler, &list/1) |> assert_agree()
  end

  test "a 204 with no body" do
    handler = fn _method, _path, _headers, _body -> {204, [], ""} end

    # Whatever it is, it is the same everywhere: `Database.list/1` wants a
    # payload it did not get.
    assert {:error, kind, _status} = through_every_adapter(handler, &list/1) |> assert_agree()
    assert kind == :decode
  end

  test "header names are matched without regard to case" do
    # `:httpc` lowercases, Finch preserves, Req lowercases. Anything the driver
    # reads out of a response header has to survive all three.
    handler = fn _method, _path, _headers, _body ->
      {200, [{"CONTENT-TYPE", "application/json"}], ~s({"databases":[{"name":"social"}]})}
    end

    assert {:ok, ["social"]} = through_every_adapter(handler, &list/1) |> assert_agree()
  end

  test "a duplicated header does not confuse the decode" do
    handler = fn _method, _path, _headers, _body ->
      {200, [{"content-type", "application/json"}, {"content-type", "text/plain"}],
       ~s({"databases":[{"name":"social"}]})}
    end

    assert {:ok, ["social"]} = through_every_adapter(handler, &list/1) |> assert_agree()
  end

  test "a JSON body under the wrong content type is still decoded" do
    # The driver decodes by what it asked for, not by what the server labelled
    # the answer — a proxy that rewrites content-type should not break a query.
    handler = fn _method, _path, _headers, _body ->
      {200, [{"content-type", "text/plain"}], ~s({"databases":[{"name":"social"}]})}
    end

    assert {:ok, ["social"]} = through_every_adapter(handler, &list/1) |> assert_agree()
  end

  test "a 503 with a TypeDB error body" do
    handler = fn _method, _path, _headers, _body ->
      {503, [], ~s({"code":"SRV9","message":"unavailable"})}
    end

    assert {:error, :server, 503} = through_every_adapter(handler, &list/1) |> assert_agree()
  end

  test "an empty body on a 200" do
    handler = fn _method, _path, _headers, _body -> {200, [], ""} end

    assert {:error, :decode, _} = through_every_adapter(handler, &list/1) |> assert_agree()
  end
end
