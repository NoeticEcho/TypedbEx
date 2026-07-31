defmodule TypeDB.Case do
  @moduledoc """
  Test case template that boots a `TypeDB.Stub` and a connection pointed at it.

  Each test gets its own stub, its own connection name and its own ETS table, so
  the suite runs `async: true` without interference.

      use TypeDB.Case

      test "lists databases", %{conn: conn} do
        assert {:ok, []} = TypeDB.Database.list(conn)
      end

  `@stub_opts` on a test or describe block is forwarded to `TypeDB.Stub.start_link/1`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import TypeDB.Case
      alias TypeDB.{Answer, Concept, ConceptRow, Database, Error, Transaction}
    end
  end

  @doc """
  The HTTP adapter the suite runs against.

  Defaults to the driver's own default; set `TYPEDB_TEST_ADAPTER` to `finch`,
  `req` or `httpc` to run the whole suite through a specific one. CI runs all
  three, because an adapter that is never exercised end to end is an adapter
  that is quietly broken.
  """
  @spec adapter() :: {module(), keyword()} | nil
  def adapter do
    case System.get_env("TYPEDB_TEST_ADAPTER") do
      "finch" -> {TypeDB.HTTP.Finch, []}
      "req" -> {TypeDB.HTTP.Req, []}
      "httpc" -> {TypeDB.HTTP.Httpc, []}
      nil -> nil
      "" -> nil
      other -> raise ArgumentError, "unknown TYPEDB_TEST_ADAPTER #{inspect(other)}"
    end
  end

  setup context do
    stub_opts = Map.get(context, :stub_opts, [])
    conn_opts = Map.get(context, :conn_opts, [])

    {:ok, stub} = TypeDB.Stub.start_link(stub_opts)

    name = :"typedb_test_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        url: TypeDB.Stub.url(stub),
        username: Keyword.get(stub_opts, :username, "admin"),
        password: Keyword.get(stub_opts, :password, "password"),
        timeout: 5_000,
        connect_timeout: 2_000
      ]
      |> then(fn opts -> if adapter = adapter(), do: Keyword.put(opts, :http, adapter), else: opts end)
      |> Keyword.merge(conn_opts)

    {:ok, conn_pid} = start_connection(opts)

    on_exit(fn ->
      # The connection is linked to the test process, so it may already be on its
      # way out by the time this runs.
      try do
        TypeDB.stop(conn_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, stub: stub, conn: name, conn_pid: conn_pid, conn_opts: opts}
  end

  @doc """
  Starts a connection, linked to the test process.
  """
  @spec start_connection(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_connection(opts), do: TypeDB.start_link(opts)

  @doc """
  Returns the requests the stub received, filtered by path substring.
  """
  @spec requests(pid(), String.t() | nil) :: [TypeDB.Stub.request()]
  def requests(stub, path_contains \\ nil) do
    stub
    |> TypeDB.Stub.requests()
    |> then(fn requests ->
      if path_contains, do: Enum.filter(requests, &String.contains?(&1.path, path_contains)), else: requests
    end)
  end
end
