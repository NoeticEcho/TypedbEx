defmodule TypeDB.GRPC.Database do
  @moduledoc """
  Databases, over the unary half of the protocol.

  Mirrors `TypeDB.Database` — same names, same return shapes, same
  `%TypeDB.Error{}` — so that switching transports does not rewrite the code
  that manages databases either.

  Creating a database that already exists succeeds here, and — contrary to what
  this module used to claim — it succeeds over the HTTP API too. TypeDB 3.x
  treats it as a no-op on both. `create_if_not_exists/3` exists so that callers
  who mean the idempotent thing say so, not because the two transports disagree;
  the shared behaviour suite asserts that they do not.
  """

  use TypeDB.GRPC.Bang
  alias TypeDB.Error
  alias TypeDB.GRPC.Connection
  alias Typedb.Protocol, as: Proto

  @doc "Every database on the server."
  @spec list(Connection.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_all(channel, %Proto.DatabaseManager.All.Req{},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "listing databases",
             operation: :databases_all
           ) do
      {:ok, Enum.map(reply.databases, & &1.name)}
    end
  end

  @doc """
  Whether `name` exists.

  Raises `TypeDB.Error` for anything other than a clean answer — the same
  contract as `TypeDB.Database.exists?/3`, and for the reason recorded there: a
  boolean cannot express "I could not ask", and answering `false` to that is
  what makes `unless exists?(conn, x), do: create(conn, x)` try to create while
  the server is down.
  """
  @spec exists?(Connection.t(), String.t(), keyword()) :: boolean()
  def exists?(conn, name, opts \\ []) when is_binary(name) do
    case Connection.unary(
           conn,
           fn channel, md ->
             Proto.TypeDB.Stub.databases_contains(
               channel,
               %Proto.DatabaseManager.Contains.Req{name: name},
               metadata: md,
               timeout: timeout(conn, opts)
             )
           end,
           "checking whether database #{inspect(name)} exists",
           operation: :database_exists,
           database: name
         ) do
      {:ok, reply} -> reply.contains
      {:error, error} -> raise error
    end
  end

  @doc """
  Creates a database.

  A no-op for one that already exists, on this transport and over HTTP alike.
  """
  @spec create(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, _reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_create(
                 channel,
                 %Proto.DatabaseManager.Create.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "creating database #{inspect(name)}",
             operation: :database_create,
             database: name
           ) do
      :ok
    end
  end

  @doc "Creates a database unless it is already there."
  @spec create_if_not_exists(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create_if_not_exists(conn, name, opts \\ []) when is_binary(name) do
    if exists?(conn, name, opts), do: :ok, else: create(conn, name, opts)
  end

  @doc "Deletes a database and everything in it."
  @spec delete(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, _reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_delete(channel, %Proto.Database.Delete.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "deleting database #{inspect(name)}",
             operation: :database_delete,
             database: name
           ) do
      :ok
    end
  end

  @doc "The database's full schema as TypeQL."
  @spec schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def schema(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_schema(channel, %Proto.Database.Schema.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading the schema of #{inspect(name)}",
             operation: :database_schema,
             database: name
           ) do
      {:ok, reply.schema}
    end
  end

  @doc "The type part of the schema, without the functions."
  @spec type_schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_schema(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_type_schema(
                 channel,
                 %Proto.Database.TypeSchema.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading the type schema of #{inspect(name)}",
             operation: :database_type_schema,
             database: name
           ) do
      {:ok, reply.schema}
    end
  end

  defp timeout(conn, opts), do: Keyword.get(opts, :timeout, Connection.config(conn).timeout)

  # -- `!` twins ---------------------------------------------------------------
  #
  # The convention `CLAUDE.md` states and the sibling enforces mechanically:
  # every failing operation has a twin that raises. Generated through macros
  # rather than a shared function so each keeps its own success typing — see
  # `TypeDB.GRPC.Bang`.

  @doc "Every database on the server, raising on failure."
  @spec list!(term(), term()) :: [String.t()]
  def list!(conn, opts \\ []), do: unwrap!(list(conn, opts))

  @doc "Creates a database, raising on failure."
  @spec create!(term(), term(), term()) :: :ok
  def create!(conn, name, opts \\ []), do: ok!(create(conn, name, opts))

  @doc "Creates a database unless it is there, raising on failure."
  @spec create_if_not_exists!(term(), term(), term()) :: :ok
  def create_if_not_exists!(conn, name, opts \\ []), do: ok!(create_if_not_exists(conn, name, opts))

  @doc "Deletes a database, raising on failure."
  @spec delete!(term(), term(), term()) :: :ok
  def delete!(conn, name, opts \\ []), do: ok!(delete(conn, name, opts))

  @doc "The database's schema, raising on failure."
  @spec schema!(term(), term(), term()) :: String.t()
  def schema!(conn, name, opts \\ []), do: unwrap!(schema(conn, name, opts))

  @doc "The type schema, raising on failure."
  @spec type_schema!(term(), term(), term()) :: String.t()
  def type_schema!(conn, name, opts \\ []), do: unwrap!(type_schema(conn, name, opts))
end
