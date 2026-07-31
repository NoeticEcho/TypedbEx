defmodule TypeDB.Database do
  @moduledoc """
  Database administration.

      {:ok, names} = TypeDB.Database.list(conn)
      :ok = TypeDB.Database.create(conn, "social")
      {:ok, schema} = TypeDB.Database.schema(conn, "social")
      :ok = TypeDB.Database.delete(conn, "social")

  `delete/2` destroys the database and everything in it, irreversibly.
  """

  use TypeDB.Bang

  alias TypeDB.{Connection, Error}

  @doc """
  Lists the names of all databases the authenticated user can see.
  """
  @spec list(Connection.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn) do
    case Connection.request(conn, :get, "/databases") do
      {:ok, %{"databases" => databases}} when is_list(databases) ->
        {:ok, Enum.map(databases, &Map.get(&1, "name"))}

      {:ok, other} ->
        {:error, Error.new(:decode, "unexpected database list response", body: other)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Lists database names, raising on failure.
  """
  @spec list!(Connection.t()) :: [String.t()]
  def list!(conn), do: unwrap!(list(conn))

  @doc """
  Returns the name of a database, or `{:error, %TypeDB.Error{status: 404}}` if it
  does not exist.
  """
  @spec get(Connection.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, name) when is_binary(name) do
    case Connection.request(conn, :get, "/databases/#{encode(name)}") do
      {:ok, %{"name" => name}} -> {:ok, name}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected database response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns a database name, raising on failure.
  """
  @spec get!(Connection.t(), String.t()) :: String.t()
  def get!(conn, name), do: unwrap!(get(conn, name))

  @doc """
  Returns whether a database exists.
  """
  @spec exists?(Connection.t(), String.t()) :: boolean()
  def exists?(conn, name) when is_binary(name) do
    match?({:ok, _}, get(conn, name))
  end

  @doc """
  Creates a database.

  Creating a database that already exists is a no-op on TypeDB 3.x: the call
  succeeds and the existing data is left untouched. `create_if_not_exists/2`
  states that intent explicitly and also copes with a server that rejects the
  duplicate.
  """
  @spec create(Connection.t(), String.t()) :: :ok | {:error, Error.t()}
  def create(conn, name) when is_binary(name) do
    case Connection.request(conn, :post, "/databases/#{encode(name)}", expect: :empty, idempotent: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates a database, raising on failure.
  """
  @spec create!(Connection.t(), String.t()) :: :ok
  def create!(conn, name), do: ok!(create(conn, name))

  @doc """
  Creates a database unless it already exists.

  Two callers racing here is safe: whoever loses sees the database already
  present and returns `:ok`.
  """
  @spec create_if_not_exists(Connection.t(), String.t()) :: :ok | {:error, Error.t()}
  def create_if_not_exists(conn, name) when is_binary(name) do
    case create(conn, name) do
      :ok ->
        :ok

      {:error, error} ->
        if exists?(conn, name), do: :ok, else: {:error, error}
    end
  end

  @doc """
  Creates a database unless it already exists, raising on failure.
  """
  @spec create_if_not_exists!(Connection.t(), String.t()) :: :ok
  def create_if_not_exists!(conn, name), do: ok!(create_if_not_exists(conn, name))

  @doc """
  Deletes a database and all of its data. This cannot be undone.

  Deleting a database that does not exist is an error (`DBD1`), unlike
  `create/2` — the asymmetry is TypeDB's, not this driver's.
  """
  @spec delete(Connection.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(conn, name) when is_binary(name) do
    case Connection.request(conn, :delete, "/databases/#{encode(name)}", expect: :empty) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Deletes a database, raising on failure.
  """
  @spec delete!(Connection.t(), String.t()) :: :ok
  def delete!(conn, name), do: ok!(delete(conn, name))

  @doc """
  Returns the full schema of a database as TypeQL source: types *and* functions.

  Round-trips: feeding the result to a `define` query in an empty database
  reproduces the schema.
  """
  @spec schema(Connection.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def schema(conn, name) when is_binary(name) do
    Connection.request(conn, :get, "/databases/#{encode(name)}/schema", expect: :text)
  end

  @doc """
  Returns only the type definitions of a database's schema, without functions.
  """
  @spec type_schema(Connection.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_schema(conn, name) when is_binary(name) do
    Connection.request(conn, :get, "/databases/#{encode(name)}/type-schema", expect: :text)
  end

  @doc """
  Returns the full schema of a database, raising on failure.
  """
  @spec schema!(Connection.t(), String.t()) :: String.t()
  def schema!(conn, name), do: unwrap!(schema(conn, name))

  @doc """
  Returns a database's type definitions, raising on failure.
  """
  @spec type_schema!(Connection.t(), String.t()) :: String.t()
  def type_schema!(conn, name), do: unwrap!(type_schema(conn, name))

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
