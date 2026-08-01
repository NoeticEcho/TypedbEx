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

  alias TypeDB.{Connection, Error, Wire}

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
    case Connection.request(conn, :get, "/databases/#{Wire.path_segment(name)}") do
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

  Raises `TypeDB.Error` for anything other than a clean "not found" — an
  unreachable server, a rejected token, a 500. A boolean cannot express "I could
  not ask", and answering `false` to that question is the answer that makes a
  caller do the wrong thing: `unless exists?(conn, x), do: create(conn, x)` would
  try to create while the server is down. Use `get/2` if you would rather branch
  on the error yourself.
  """
  @spec exists?(Connection.t(), String.t()) :: boolean()
  def exists?(conn, name) when is_binary(name) do
    case get(conn, name) do
      {:ok, _} -> true
      {:error, %Error{status: 404}} -> false
      {:error, error} -> raise error
    end
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
    case Connection.request(conn, :post, "/databases/#{Wire.path_segment(name)}",
           expect: :empty,
           # Creating a database that already exists is a no-op on TypeDB 3.x,
           # which is what makes a re-send safe. Creating a *user* is not.
           idempotent: true
         ) do
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
        # `get/2` rather than `exists?/2`: this function's contract is to return
        # the error, and `exists?/2` raises on anything but a clean 404.
        case get(conn, name) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, error}
        end
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
    case Connection.request(conn, :delete, "/databases/#{Wire.path_segment(name)}", expect: :empty) do
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
    Connection.request(conn, :get, "/databases/#{Wire.path_segment(name)}/schema", expect: :text)
  end

  @doc """
  Returns only the type definitions of a database's schema, without functions.
  """
  @spec type_schema(Connection.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_schema(conn, name) when is_binary(name) do
    Connection.request(conn, :get, "/databases/#{Wire.path_segment(name)}/type-schema", expect: :text)
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
end
