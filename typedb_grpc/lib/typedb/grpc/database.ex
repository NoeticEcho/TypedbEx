defmodule TypeDB.GRPC.Database do
  @moduledoc """
  Databases, over the unary half of the protocol.

  Mirrors `TypeDB.Database` — same names, same return shapes, same
  `%TypeDB.Error{}` — so that switching transports does not rewrite the code
  that manages databases either.

  One behaviour differs from the HTTP API and is *not* smoothed over here:
  creating a database that already exists succeeds over gRPC, where the HTTP
  API rejects it. Measured against 3.12.1. `create/3` therefore reports what the
  server did rather than inventing a rejection, and `create_if_not_exists/3`
  exists on both so that callers who want the idempotent behaviour ask for it
  by name.
  """

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
             "listing databases"
           ) do
      {:ok, Enum.map(reply.databases, & &1.name)}
    end
  end

  @doc "Whether `name` exists."
  @spec exists?(Connection.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, Error.t()}
  def exists?(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_contains(
                 channel,
                 %Proto.DatabaseManager.Contains.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "checking whether database #{inspect(name)} exists"
           ) do
      {:ok, reply.contains}
    end
  end

  @doc """
  Creates a database.

  Note that TypeDB accepts this for a database that already exists, unlike the
  HTTP API — see the module doc.
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
             "creating database #{inspect(name)}"
           ) do
      :ok
    end
  end

  @doc "Creates a database unless it is already there."
  @spec create_if_not_exists(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create_if_not_exists(conn, name, opts \\ []) when is_binary(name) do
    case exists?(conn, name, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> create(conn, name, opts)
      {:error, _} = error -> error
    end
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
             "deleting database #{inspect(name)}"
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
             "reading the schema of #{inspect(name)}"
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
             "reading the type schema of #{inspect(name)}"
           ) do
      {:ok, reply.schema}
    end
  end

  defp timeout(conn, opts), do: Keyword.get(opts, :timeout, Connection.config(conn).timeout)
end
