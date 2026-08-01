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

  alias TypeDB.{Connection, Error, Wire}

  @doc """
  Lists all usernames.
  """
  @spec list(Connection.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn) do
    case Connection.request(conn, :get, "/users") do
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
  @spec list!(Connection.t()) :: [String.t()]
  def list!(conn), do: unwrap!(list(conn))

  @doc """
  Returns a username, or an error when the user does not exist.
  """
  @spec get(Connection.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, username) when is_binary(username) do
    case Connection.request(conn, :get, "/users/#{Wire.path_segment(username)}") do
      {:ok, %{"username" => username}} -> {:ok, username}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected user response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns a username, raising when the user does not exist.
  """
  @spec get!(Connection.t(), String.t()) :: String.t()
  def get!(conn, username), do: unwrap!(get(conn, username))

  @doc """
  Returns whether a user exists.

  Raises `TypeDB.Error` for anything other than a clean "not found" — an
  unreachable server, a rejected token, a 500. A boolean cannot express "I could
  not ask", and answering `false` to that question is the answer that makes a
  caller do the wrong thing: `unless exists?(conn, x), do: create(conn, x)` would
  try to create while the server is down. Use `get/2` if you would rather branch
  on the error yourself.
  """
  @spec exists?(Connection.t(), String.t()) :: boolean()
  def exists?(conn, username) do
    case get(conn, username) do
      {:ok, _} -> true
      {:error, %Error{status: 404}} -> false
      {:error, error} -> raise error
    end
  end

  @doc """
  Creates a user with the given password.
  """
  @spec create(Connection.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def create(conn, username, password) when is_binary(username) and is_binary(password) do
    case Connection.request(conn, :post, "/users/#{Wire.path_segment(username)}",
           body: %{"password" => password},
           expect: :empty,
           idempotent: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates a user, raising on failure.
  """
  @spec create!(Connection.t(), String.t(), String.t()) :: :ok
  def create!(conn, username, password), do: ok!(create(conn, username, password))

  @doc """
  Replaces a user's password.

  Existing tokens issued to that user are not revoked by this call; they expire
  on their own schedule.
  """
  @spec set_password(Connection.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def set_password(conn, username, password) when is_binary(username) and is_binary(password) do
    case Connection.request(conn, :put, "/users/#{Wire.path_segment(username)}",
           body: %{"password" => password},
           expect: :empty,
           idempotent: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Replaces a user's password, raising on failure.
  """
  @spec set_password!(Connection.t(), String.t(), String.t()) :: :ok
  def set_password!(conn, username, password), do: ok!(set_password(conn, username, password))

  @doc """
  Deletes a user.
  """
  @spec delete(Connection.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(conn, username) when is_binary(username) do
    case Connection.request(conn, :delete, "/users/#{Wire.path_segment(username)}", expect: :empty) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Deletes a user, raising on failure.
  """
  @spec delete!(Connection.t(), String.t()) :: :ok
  def delete!(conn, username), do: ok!(delete(conn, username))
end
