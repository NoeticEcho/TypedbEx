defmodule TypeDB.GRPC.User do
  @moduledoc """
  Users, over the unary half of the protocol.

  Mirrors `TypeDB.User`. `list/2`, `get/3` and `current/2` return names rather
  than richer records: the protocol's `User` message carries only a name and an
  optional password, and the password is never populated on the way out.
  """

  use TypeDB.GRPC.Bang
  alias TypeDB.Error
  alias TypeDB.GRPC.Connection
  alias Typedb.Protocol, as: Proto

  @doc "Every user on the server."
  @spec list(Connection.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.users_all(channel, %Proto.UserManager.All.Req{},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "listing users",
             operation: :users_all
           ) do
      {:ok, Enum.map(reply.users, & &1.name)}
    end
  end

  @doc """
  A username, or an error when the user does not exist.

  The same contract as `TypeDB.User.get/3`: the answer to "is this user there"
  that can also say "I could not ask", which `exists?/3` cannot.
  """
  @spec get(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, username, opts \\ []) when is_binary(username) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.users_get(channel, %Proto.UserManager.Get.Req{name: username},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading user #{inspect(username)}",
             operation: :users_get
           ) do
      {:ok, reply.user.name}
    end
  end

  @doc """
  The user this connection signed in as.

  Rust's `users().get_current()`, and the same implementation: there is no RPC
  for it, so the name comes from the connection's own credentials and is then
  looked up — which means it also answers "does the account I am using still
  exist".

  A connection configured with a pre-issued `:token` has no username to look up,
  and says so rather than guessing.
  """
  @spec current(Connection.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def current(conn, opts \\ []) do
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
  Whether `username` exists.

  Raises `TypeDB.Error` for anything but a clean answer — the same contract as
  `TypeDB.User.exists?/3` and `TypeDB.GRPC.Database.exists?/3`. This used to
  return `{:ok, boolean()}`, which agreed with neither.
  """
  @spec exists?(Connection.t(), String.t(), keyword()) :: boolean()
  def exists?(conn, username, opts \\ []) when is_binary(username) do
    case Connection.unary(
           conn,
           fn channel, md ->
             Proto.TypeDB.Stub.users_contains(
               channel,
               %Proto.UserManager.Contains.Req{name: username},
               metadata: md,
               timeout: timeout(conn, opts)
             )
           end,
           "checking whether user #{inspect(username)} exists",
           operation: :user_exists
         ) do
      {:ok, reply} -> reply.contains
      {:error, error} -> raise error
    end
  end

  @doc "Creates a user."
  @spec create(Connection.t(), String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create(conn, username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    with {:ok, _} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.users_create(
                 channel,
                 %Proto.UserManager.Create.Req{
                   user: %Proto.User{name: username, password: password}
                 },
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "creating user #{inspect(username)}",
             operation: :user_create
           ) do
      :ok
    end
  end

  @doc "Sets a user's password."
  @spec set_password(Connection.t(), String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set_password(conn, username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    with {:ok, _} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.users_update(
                 channel,
                 %Proto.User.Update.Req{
                   name: username,
                   user: %Proto.User{name: username, password: password}
                 },
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "setting the password for #{inspect(username)}",
             operation: :user_set_password
           ) do
      :ok
    end
  end

  @doc "Deletes a user."
  @spec delete(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(conn, username, opts \\ []) when is_binary(username) do
    with {:ok, _} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.users_delete(channel, %Proto.User.Delete.Req{name: username},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "deleting user #{inspect(username)}",
             operation: :user_delete
           ) do
      :ok
    end
  end

  defp timeout(conn, opts), do: Keyword.get(opts, :timeout, Connection.config(conn).timeout)

  # -- `!` twins ---------------------------------------------------------------
  #
  # The convention `CLAUDE.md` states and the sibling enforces mechanically:
  # every failing operation has a twin that raises. Generated through macros
  # rather than a shared function so each keeps its own success typing — see
  # `TypeDB.GRPC.Bang`.

  @doc "Every user on the server, raising on failure."
  @spec list!(term(), term()) :: [String.t()]
  def list!(conn, opts \\ []), do: unwrap!(list(conn, opts))

  @doc "A username, raising when the user does not exist."
  @spec get!(term(), term(), term()) :: String.t()
  def get!(conn, username, opts \\ []), do: unwrap!(get(conn, username, opts))

  @doc "The user this connection signed in as, raising on failure."
  @spec current!(term(), term()) :: String.t()
  def current!(conn, opts \\ []), do: unwrap!(current(conn, opts))

  @doc "Creates a user, raising on failure."
  @spec create!(term(), term(), term(), term()) :: :ok
  def create!(conn, username, password, opts \\ []), do: ok!(create(conn, username, password, opts))

  @doc "Sets a user's password, raising on failure."
  @spec set_password!(term(), term(), term(), term()) :: :ok
  def set_password!(conn, username, password, opts \\ []),
    do: ok!(set_password(conn, username, password, opts))

  @doc "Deletes a user, raising on failure."
  @spec delete!(term(), term(), term()) :: :ok
  def delete!(conn, username, opts \\ []), do: ok!(delete(conn, username, opts))
end
