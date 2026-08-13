defmodule TypeDB.User do
  @moduledoc """
  User administration.

  Most of these endpoints require administrator rights; a non-admin user can
  generally read and update only its own record.

      {:ok, usernames} = TypeDB.User.list(conn)
      :ok = TypeDB.User.create(conn, "alice", "s3cret")
      :ok = TypeDB.User.set_password(conn, "alice", "even-more-s3cret")
      :ok = TypeDB.User.delete(conn, "alice")
  """

  use TypeDB.Bang

  alias TypeDB.{CallOptions, Connection, Error, Wire}

  @doc """
  Lists all usernames.
  """
  @spec list(Connection.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.list/2")

    case Connection.request(conn, :get, "/users", request_opts(opts)) do
      {:ok, %{"users" => users}} when is_list(users) ->
        {:ok, Enum.map(users, &Map.get(&1, "username"))}

      {:ok, other} ->
        {:error, Error.new(:decode, "unexpected user list response", body: other)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Lists all usernames, raising on failure.
  """
  @spec list!(Connection.t(), keyword()) :: [String.t()]
  def list!(conn, opts \\ []), do: unwrap!(list(conn, opts))

  @doc """
  Returns a username, or an error when the user does not exist.
  """
  @spec get(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, username, opts \\ []) do
    username = Wire.string!(username, "username")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.get/3")

    case Connection.request(conn, :get, "/users/#{Wire.path_segment(username)}", request_opts(opts)) do
      {:ok, %{"username" => username}} -> {:ok, username}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected user response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns a username, raising when the user does not exist.
  """
  @spec get!(Connection.t(), String.t(), keyword()) :: String.t()
  def get!(conn, username, opts \\ []), do: unwrap!(get(conn, username, opts))

  @doc """
  Returns the user this connection signed in as.

  Rust's `users().get_current()`, and the same implementation: there is no
  endpoint for it, so the name comes from the connection's own credentials and
  is then looked up — which means it also answers "does the account I am using
  still exist".

  A connection configured with a pre-issued `:token` has no username to look up,
  and says so rather than guessing.
  """
  @spec current(Connection.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def current(conn, opts \\ []) do
    # Validated here as well as in `get/3`, so a caller who misspells an option
    # is told which function they misspelled it to.
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.current/2")

    case Connection.config(conn).username do
      username when is_binary(username) ->
        get(conn, username, opts)

      _ ->
        {:error,
         Error.new(
           :config,
           "this connection was configured with a :token rather than credentials, so the " <>
             "driver does not know which user it is. The name is inside the token; decode it " <>
             "there, or configure :username and :password."
         )}
    end
  end

  @doc """
  Returns the user this connection signed in as, raising on failure.
  """
  @spec current!(Connection.t(), keyword()) :: String.t()
  def current!(conn, opts \\ []), do: unwrap!(current(conn, opts))

  @doc """
  Returns whether a user exists.

  Raises `TypeDB.Error` for anything other than a clean "not found" — an
  unreachable server, a rejected token, a 500. A boolean cannot express "I could
  not ask", and answering `false` to that question is the answer that makes a
  caller do the wrong thing: `unless exists?(conn, x), do: create(conn, x)` would
  try to create while the server is down. Use `get/2` if you would rather branch
  on the error yourself.
  """
  @spec exists?(Connection.t(), String.t(), keyword()) :: boolean()
  def exists?(conn, username, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.exists?/3")

    case get(conn, username, opts) do
      {:ok, _} -> true
      {:error, %Error{status: 404}} -> false
      {:error, error} -> raise error
    end
  end

  @doc """
  Creates a user with the given password.
  """
  @spec create(Connection.t(), String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create(conn, username, password, opts \\ []) do
    username = Wire.string!(username, "username")
    password = Wire.string!(password, "password")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.create/4")

    case Connection.request(
           conn,
           :post,
           "/users/#{Wire.path_segment(username)}",
           [body: %{"password" => password}, expect: :empty, idempotent: false] ++ request_opts(opts)
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates a user, raising on failure.
  """
  @spec create!(Connection.t(), String.t(), String.t(), keyword()) :: :ok
  def create!(conn, username, password, opts \\ []), do: ok!(create(conn, username, password, opts))

  @doc """
  Replaces a user's password.

  Existing tokens issued to that user are not revoked by this call; they expire
  on their own schedule.
  """
  @spec set_password(Connection.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def set_password(conn, username, password, opts \\ []) do
    username = Wire.string!(username, "username")
    password = Wire.string!(password, "password")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.set_password/4")

    case Connection.request(
           conn,
           :put,
           "/users/#{Wire.path_segment(username)}",
           [
             body: %{"password" => password},
             expect: :empty,
             # Setting the same password twice sets the same password.
             idempotent: true
           ] ++ request_opts(opts)
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Replaces a user's password, raising on failure.
  """
  @spec set_password!(Connection.t(), String.t(), String.t(), keyword()) :: :ok
  def set_password!(conn, username, password, opts \\ []),
    do: ok!(set_password(conn, username, password, opts))

  @doc """
  Deletes a user.
  """
  @spec delete(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(conn, username, opts \\ []) do
    username = Wire.string!(username, "username")
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.User.delete/3")

    case Connection.request(
           conn,
           :delete,
           "/users/#{Wire.path_segment(username)}",
           [expect: :empty] ++ request_opts(opts)
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Deletes a user, raising on failure.
  """
  @spec delete!(Connection.t(), String.t(), keyword()) :: :ok
  def delete!(conn, username, opts \\ []), do: ok!(delete(conn, username, opts))

  # See `TypeDB.Database`'s helper of the same name.
  defp request_opts(opts), do: [timeout: opts[:timeout], deadline: opts[:deadline]]
end
