defmodule TypeDB.Behaviour.Adapter do
  @moduledoc """
  The narrow surface the shared behaviour suite drives both drivers through.

  Not an attempt to unify the two APIs — that is the thing the repository's
  README says cannot honestly be done, because one materialises an answer and
  the other streams it. This is the *overlap*: connect, manage a database, run
  a query in a transaction, read the answer. Everything the suite asserts about
  is expressed in those terms, and everything outside them is tested in each
  package's own suite.

  Two implementations follow, one per transport. They are deliberately thin: if
  an adapter had logic of its own, a passing suite would be evidence about the
  adapter rather than about the driver.
  """

  @type conn :: term()

  @callback name() :: String.t()
  @callback available?() :: boolean()
  @callback connect(atom()) :: {:ok, conn()} | {:error, term()}
  @callback create_database(conn(), String.t()) :: :ok | {:error, TypeDB.Error.t()}
  @callback delete_database(conn(), String.t()) :: :ok | {:error, TypeDB.Error.t()}
  @callback database_exists?(conn(), String.t()) :: boolean()

  @doc "Runs one query in its own transaction of `type`, committing a write."
  @callback query(conn(), String.t(), String.t(), :read | :write | :schema) ::
              {:ok, TypeDB.Answer.t()} | {:error, TypeDB.Error.t()}

  @doc "Runs `fun` inside one transaction; the callback takes a driver-specific handle."
  @callback transaction(conn(), String.t(), :read | :write | :schema, (term() -> term())) :: term()

  @doc "Runs a query on an open transaction handle."
  @callback tx_query(term(), String.t()) :: {:ok, TypeDB.Answer.t()} | {:error, TypeDB.Error.t()}

  @doc "Commits an open transaction handle."
  @callback tx_commit(term()) :: :ok | {:error, TypeDB.Error.t()}

  @doc "Opens a transaction and returns the handle, for tests about lifetimes."
  @callback tx_open(conn(), String.t(), :read | :write | :schema) ::
              {:ok, term()} | {:error, TypeDB.Error.t()}

  @doc "Closes an open transaction handle."
  @callback tx_close(term()) :: :ok

  @doc "The servers in the cluster, as the driver reports them."
  @callback servers(conn()) :: {:ok, [map()]} | {:error, TypeDB.Error.t()}

  @doc """
  Runs a read with `include_query_structure` and returns the answer.

  Its own callback rather than an option on `query/4`: the structure is the
  thing under test, and a caller that forgot the option would get `nil` and a
  passing test.
  """
  @callback query_with_structure(conn(), String.t(), String.t()) ::
              {:ok, TypeDB.Answer.t()} | {:error, TypeDB.Error.t()}

  @doc """
  Whether `variable` names a server to run against.

  Empty is unset. `System.get_env/1` returns `""` for a variable exported with
  no value, and treating that as configured made the suite report sixteen
  failures where it meant to skip — which is worse than either outcome, because
  it buries a real failure in noise.
  """
  @spec configured?(String.t()) :: boolean()
  def configured?(variable) do
    case System.get_env(variable) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end

defmodule TypeDB.Behaviour.Adapter.HTTP do
  @moduledoc "The shared suite, driven through `typedb`."

  @behaviour TypeDB.Behaviour.Adapter

  @impl true
  def name, do: "typedb (HTTP)"

  @impl true
  def available?, do: TypeDB.Behaviour.Adapter.configured?("TYPEDB_INTEGRATION_URL")

  @impl true
  def connect(name) do
    with {:ok, pid} <-
           TypeDB.start_link(
             name: name,
             url: System.fetch_env!("TYPEDB_INTEGRATION_URL"),
             username: System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin"),
             password: System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")
           ) do
      Process.unlink(pid)
      {:ok, name}
    end
  end

  @impl true
  def create_database(conn, database), do: TypeDB.Database.create(conn, database)

  @impl true
  def delete_database(conn, database), do: TypeDB.Database.delete(conn, database)

  @impl true
  def database_exists?(conn, database), do: TypeDB.Database.exists?(conn, database)

  @impl true
  def query(conn, database, query, type) do
    TypeDB.query(conn, database, query, transaction_type: type)
  end

  @impl true
  def query_with_structure(conn, database, query) do
    TypeDB.query(conn, database, query, transaction_type: :read, include_query_structure: true)
  end

  @impl true
  def transaction(conn, database, type, fun) do
    TypeDB.transaction(conn, database, type, fun)
  end

  @impl true
  def tx_query(tx, query), do: TypeDB.Transaction.query(tx, query)

  @impl true
  def tx_commit(tx), do: TypeDB.Transaction.commit(tx)

  @impl true
  def tx_open(conn, database, type), do: TypeDB.Transaction.open(conn, database, type)

  @impl true
  def servers(conn), do: TypeDB.Server.servers(conn)

  @impl true
  def tx_close(tx) do
    _ = TypeDB.Transaction.close(tx)
    :ok
  end
end

defmodule TypeDB.Behaviour.Adapter.GRPC do
  @moduledoc "The shared suite, driven through `typedb_grpc`."

  @behaviour TypeDB.Behaviour.Adapter

  alias TypeDB.GRPC.{Connection, Database, Server, Transaction}

  @impl true
  def name, do: "typedb_grpc (gRPC)"

  @impl true
  def available?, do: TypeDB.Behaviour.Adapter.configured?("TYPEDB_GRPC_ADDRESS")

  @impl true
  def connect(name) do
    with {:ok, pid} <-
           Connection.start_link(
             name: name,
             address: System.fetch_env!("TYPEDB_GRPC_ADDRESS"),
             username: System.get_env("TYPEDB_GRPC_USERNAME", "admin"),
             password: System.get_env("TYPEDB_GRPC_PASSWORD", "password")
           ) do
      Process.unlink(pid)
      {:ok, name}
    end
  end

  @impl true
  def create_database(conn, database), do: Database.create(conn, database)

  @impl true
  def delete_database(conn, database), do: Database.delete(conn, database)

  @impl true
  def database_exists?(conn, database), do: Database.exists?(conn, database)

  # There is no one-shot query on this transport, so the equivalent is a
  # transaction of one — which is exactly what the HTTP API does server-side for
  # its one-shot, and the reason the two are comparable at all.
  @impl true
  def query(conn, database, query, type) do
    Transaction.transaction(conn, database, type, fn tx -> Transaction.query(tx, query) end)
  end

  @impl true
  def query_with_structure(conn, database, query) do
    Transaction.transaction(conn, database, :read, fn tx ->
      Transaction.query(tx, query, include_query_structure: true)
    end)
  end

  @impl true
  def transaction(conn, database, type, fun) do
    Transaction.transaction(conn, database, type, fun)
  end

  @impl true
  def tx_query(tx, query), do: Transaction.query(tx, query)

  @impl true
  def tx_commit(tx), do: Transaction.commit(tx)

  @impl true
  def tx_open(conn, database, type), do: Transaction.open(conn, database, type)

  @impl true
  def tx_close(tx), do: Transaction.close(tx)

  @impl true
  def servers(conn), do: Server.servers(conn)
end
