defmodule TypeDB.Database do
  @moduledoc """
  Database administration.

      {:ok, names} = TypeDB.Database.list(conn)
      :ok = TypeDB.Database.create(conn, "social")
      {:ok, schema} = TypeDB.Database.schema(conn, "social")
      :ok = TypeDB.Database.delete(conn, "social")

  `delete/3` destroys the database and everything in it, irreversibly.

  Every function here takes `:timeout` and `:deadline` as trailing options,
  bounding one attempt and the whole call respectively — a schema fetch over a
  large database is the call most likely to want more than the connection's
  default.
  """

  use TypeDB.Bang

  alias TypeDB.{CallOptions, Connection, Error, Wire}

  @doc """
  Lists the names of all databases the authenticated user can see.
  """
  @spec list(Connection.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.list/2")

    case Connection.request(conn, :get, "/databases", request_opts(opts)) do
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
  @spec list!(Connection.t(), keyword()) :: [String.t()]
  def list!(conn, opts \\ []), do: unwrap!(list(conn, opts))

  @doc """
  Returns the name of a database, or `{:error, %TypeDB.Error{status: 404}}` if it
  does not exist.
  """
  @spec get(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.get/3")

    case Connection.request(conn, :get, "/databases/#{Wire.path_segment(name)}", request_opts(opts)) do
      {:ok, %{"name" => name}} -> {:ok, name}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected database response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns a database name, raising on failure.
  """
  @spec get!(Connection.t(), String.t(), keyword()) :: String.t()
  def get!(conn, name, opts \\ []), do: unwrap!(get(conn, name, opts))

  @doc """
  Returns whether a database exists.

  Raises `TypeDB.Error` for anything other than a clean "not found" — an
  unreachable server, a rejected token, a 500. A boolean cannot express "I could
  not ask", and answering `false` to that question is the answer that makes a
  caller do the wrong thing: `unless exists?(conn, x), do: create(conn, x)` would
  try to create while the server is down. Use `get/2` if you would rather branch
  on the error yourself.
  """
  @spec exists?(Connection.t(), String.t(), keyword()) :: boolean()
  def exists?(conn, name, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.exists?/3")

    case get(conn, name, opts) do
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
  @spec create(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.create/3")

    case Connection.request(
           conn,
           :post,
           "/databases/#{Wire.path_segment(name)}",
           [
             expect: :empty,
             # Creating a database that already exists is a no-op on TypeDB 3.x,
             # which is what makes a re-send safe. Creating a *user* is not.
             idempotent: true
           ] ++ request_opts(opts)
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates a database, raising on failure.
  """
  @spec create!(Connection.t(), String.t(), keyword()) :: :ok
  def create!(conn, name, opts \\ []), do: ok!(create(conn, name, opts))

  @doc """
  Creates a database unless it already exists.

  Two callers racing here is safe: whoever loses sees the database already
  present and returns `:ok`.
  """
  @spec create_if_not_exists(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create_if_not_exists(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    # Validated here as well as in `create/3`, so a misspelled option names the
    # function the caller actually wrote.
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.create_if_not_exists/3")

    case create(conn, name, opts) do
      :ok ->
        :ok

      {:error, error} ->
        # `get/3` rather than `exists?/3`: this function's contract is to return
        # the error, and `exists?/3` raises on anything but a clean 404.
        #
        # Both calls get the caller's `:timeout` and `:deadline`, so the pair
        # can cost twice the budget. `:deadline` bounds a call, not a function
        # that makes two of them; the alternative is to give the second call
        # what the first did not spend, which is arithmetic this driver does not
        # do anywhere else.
        case get(conn, name, opts) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, error}
        end
    end
  end

  @doc """
  Creates a database unless it already exists, raising on failure.
  """
  @spec create_if_not_exists!(Connection.t(), String.t(), keyword()) :: :ok
  def create_if_not_exists!(conn, name, opts \\ []), do: ok!(create_if_not_exists(conn, name, opts))

  @doc """
  Deletes a database and all of its data. This cannot be undone.

  Deleting a database that does not exist is an error (`DBD1`), unlike
  `create/2` — the asymmetry is TypeDB's, not this driver's.
  """
  @spec delete(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.delete/3")

    case Connection.request(
           conn,
           :delete,
           "/databases/#{Wire.path_segment(name)}",
           [expect: :empty] ++ request_opts(opts)
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Deletes a database, raising on failure.
  """
  @spec delete!(Connection.t(), String.t(), keyword()) :: :ok
  def delete!(conn, name, opts \\ []), do: ok!(delete(conn, name, opts))

  @doc """
  Returns the full schema of a database as TypeQL source: types *and* functions.

  Round-trips: feeding the result to a `define` query in an empty database
  reproduces the schema.
  """
  @spec schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def schema(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.schema/3")

    Connection.request(
      conn,
      :get,
      "/databases/#{Wire.path_segment(name)}/schema",
      [expect: :text] ++ request_opts(opts)
    )
  end

  @doc """
  Returns only the type definitions of a database's schema, without functions.
  """
  @spec type_schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_schema(conn, name, opts \\ []) do
    name = Wire.string!(name, "database name")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Database.type_schema/3")

    Connection.request(
      conn,
      :get,
      "/databases/#{Wire.path_segment(name)}/type-schema",
      [expect: :text] ++ request_opts(opts)
    )
  end

  @doc """
  Returns the full schema of a database, raising on failure.
  """
  @spec schema!(Connection.t(), String.t(), keyword()) :: String.t()
  def schema!(conn, name, opts \\ []), do: unwrap!(schema(conn, name, opts))

  @doc """
  Returns a database's type definitions, raising on failure.
  """
  @spec type_schema!(Connection.t(), String.t(), keyword()) :: String.t()
  def type_schema!(conn, name, opts \\ []), do: unwrap!(type_schema(conn, name, opts))

  # `:timeout` and `:deadline` only. Everything else a caller might pass is
  # rejected by `CallOptions.validate!/3` before this is reached, and `nil` for
  # an unset one is what `TypeDB.Transport` already treats as absent.
  defp request_opts(opts), do: [timeout: opts[:timeout], deadline: opts[:deadline]]
end
