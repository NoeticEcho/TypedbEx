defmodule TypeDB.GRPC.Case do
  @moduledoc """
  A case template for tests that need a live TypeDB over gRPC.

  There is no in-process stub here, and that is deliberate rather than
  unfinished. The sibling driver has one because HTTP can be spoken by a small
  Plug router, and even there the project's own rule is that the stub has
  repeatedly been wrong about the server and proves nothing on its own. A stub
  for this transport would have to reimplement a bidirectional stream, its
  request multiplexing and its flow control — that is, the exact machinery most
  likely to be wrong — and it would be testing my model of TypeDB rather than
  TypeDB.

  So the interesting tests here are integration tests, skipped unless
  `TYPEDB_GRPC_ADDRESS` is set.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import TypeDB.GRPC.Case

      alias TypeDB.GRPC.{Connection, Database, Server, User}
    end
  end

  @doc "The address under test, or nil when the suite should skip."
  def address, do: System.get_env("TYPEDB_GRPC_ADDRESS")

  @doc "Credentials, defaulting to a stock local server."
  def credentials do
    [
      username: System.get_env("TYPEDB_GRPC_USERNAME", "admin"),
      password: System.get_env("TYPEDB_GRPC_PASSWORD", "password")
    ]
  end

  @doc """
  Starts a connection under a unique name and stops it when the test ends.
  """
  def start_connection(opts \\ []) do
    name = :"grpc_case_#{System.unique_integer([:positive])}"

    # `Keyword.merge/2` rather than `++`: appending puts the caller's overrides
    # *after* the defaults, and `Keyword.get/2` reads the first match — so a
    # test asking for a wrong password would silently get the right one, and
    # pass by testing nothing.
    opts = Keyword.merge([name: name, address: address()] ++ credentials(), opts)

    {:ok, pid} = TypeDB.GRPC.Connection.start_link(opts)

    # `start_link` links to the test process, which dies before `on_exit`
    # callbacks run — so a database cleanup registered later would find the
    # connection already gone. Unlinking is what lets teardown happen in the
    # order it was written.
    Process.unlink(pid)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          TypeDB.GRPC.Connection.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    name
  end

  @doc """
  Creates a database for the duration of the test.
  """
  def start_database(conn, prefix \\ "grpc") do
    name = "#{prefix}_#{System.unique_integer([:positive])}"
    :ok = TypeDB.GRPC.Database.create(conn, name)

    ExUnit.Callbacks.on_exit(fn ->
      _ = TypeDB.GRPC.Database.delete(conn, name)
    end)

    name
  end
end
