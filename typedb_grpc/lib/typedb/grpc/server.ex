defmodule TypeDB.GRPC.Server do
  @moduledoc """
  What the server is, and whether this driver was built for it.
  """

  use TypeDB.GRPC.Bang
  alias TypeDB.Error
  alias TypeDB.GRPC.{Connection, Protocol}
  alias Typedb.Protocol, as: Proto

  @doc """
  The server's distribution and version, as it reports them.

      {:ok, %{distribution: "TypeDB CE", version: "3.12.1"}}
  """
  @spec version(Connection.t(), keyword()) ::
          {:ok, %{distribution: String.t(), version: String.t()}} | {:error, Error.t()}
  def version(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.server_version(channel, %Proto.Server.Version.Req{},
                 metadata: md,
                 timeout: Keyword.get(opts, :timeout, Connection.config(conn).timeout)
               )
             end,
             "reading the server version",
             operation: :server_version
           ) do
      {:ok, %{distribution: reply.distribution, version: reply.version}}
    end
  end

  @doc """
  Whether the server is reachable and answering.

  There is no dedicated health RPC in the protocol, so this asks for the version
  — the cheapest call that proves a round trip, and the same thing TypeDB's own
  drivers use for the purpose.
  """
  @spec health(Connection.t(), keyword()) :: :ok | {:error, Error.t()}
  def health(conn, opts \\ []) do
    with {:ok, _} <- version(conn, opts), do: :ok
  end

  @typedoc """
  One server in the cluster, in the shape `TypeDB.Server.servers/2` returns.

  String keys rather than atoms, and `"address"` rather than `:address`,
  because the sibling hands back TypeDB's JSON decoded as-is and a caller that
  switches transports should not have to rewrite its pattern matches. A stock
  single-server CE deployment reports `%{"address" => nil}` on both.

  `"replication_status"` is present only when the server sends one — the HTTP
  API has no such field at all, so inventing a `nil` for it would be a
  difference between the transports rather than a fact about the server.
  """
  @type server :: %{optional(String.t()) => term()}

  @doc """
  Lists the servers in the cluster.

  A single-server deployment reports one entry. The same caveat as the
  sibling's `TypeDB.Server.servers/2`: fields vary by distribution, so what the
  server said is what you get.
  """
  @spec servers(Connection.t(), keyword()) :: {:ok, [server()]} | {:error, Error.t()}
  def servers(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.servers_all(channel, %Proto.ServerManager.All.Req{},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "listing the servers in the cluster",
             operation: :servers_all
           ) do
      {:ok, Enum.map(reply.servers, &decode_server/1)}
    end
  end

  @doc """
  The one server this connection is talking to.

  `servers/2` asks about the cluster; this asks about the node on the other end
  of this channel, which is the one whose replication role decides whether a
  write here is a write at all. The sibling has no counterpart — the HTTP API
  exposes only the list.
  """
  @spec server(Connection.t(), keyword()) :: {:ok, server()} | {:error, Error.t()}
  def server(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.servers_get(channel, %Proto.ServerManager.Get.Req{},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading this server",
             operation: :servers_get
           ) do
      {:ok, decode_server(reply.server)}
    end
  end

  defp decode_server(nil), do: %{}

  defp decode_server(%Proto.Server{} = server) do
    case server.replication_status do
      nil -> %{"address" => server.address}
      status -> %{"address" => server.address, "replication_status" => replication_status(status)}
    end
  end

  defp replication_status(%Proto.Server.ReplicationStatus{} = status) do
    %{"id" => status.id, "role" => role(status.role), "term" => status.term}
  end

  # The enum arrives as an atom named exactly as the protocol spells it, and the
  # protocol spells it `Primary`. Passing the atom through would make callers
  # write `:Primary`, which nobody expects in Elixir; a string keeps it in the
  # same register as every other value in this map.
  defp role(nil), do: nil
  defp role(role) when is_atom(role), do: Atom.to_string(role)
  defp role(role), do: role

  defp timeout(conn, opts), do: Keyword.get(opts, :timeout, Connection.config(conn).timeout)

  @doc """
  Checks the server against the protocol version this driver was generated from.

  Returns `:ok`, or `{:error, %TypeDB.Error{kind: :config}}` naming both
  versions. Nothing calls this on the hot path: it is for a boot-time check and
  for the integration suite, which is where a mismatch should be found.

  A mismatch is not proof of breakage — protobuf tolerates a client built from
  an older schema — but it is proof that nobody has checked.

  Since `connection_open` carries the protocol version, the server now performs
  the authoritative version check itself and refuses a driver it cannot speak
  to. This one compares the two strings, which is a different and weaker
  question — it catches a *generated* protocol that has drifted from the server
  even when both ends still interoperate — and it is why the integration suite
  keeps calling it.
  """
  @spec check_protocol(Connection.t(), keyword()) :: :ok | {:error, Error.t()}
  def check_protocol(conn, opts \\ []) do
    with {:ok, %{version: version}} <- version(conn, opts) do
      if Protocol.compatible?(version) do
        :ok
      else
        {:error,
         Error.new(
           :config,
           "this driver's protocol modules were generated from typedb-protocol " <>
             "#{Protocol.version()}, and the server reports #{version}. Regenerate with " <>
             "`mix typedb.grpc.gen`, or point the connection at a matching server."
         )}
      end
    end
  end

  # -- `!` twins ---------------------------------------------------------------
  #
  # The convention `CLAUDE.md` states and the sibling enforces mechanically:
  # every failing operation has a twin that raises. Generated through macros
  # rather than a shared function so each keeps its own success typing — see
  # `TypeDB.GRPC.Bang`.

  @doc "The server's version, raising on failure."
  @spec version!(term(), term()) :: %{distribution: String.t(), version: String.t()}
  def version!(conn, opts \\ []), do: unwrap!(version(conn, opts))

  @doc "Server reachability, raising on failure."
  @spec health!(term(), term()) :: :ok
  def health!(conn, opts \\ []), do: ok!(health(conn, opts))

  @doc "Checks the protocol version, raising on a mismatch."
  @spec check_protocol!(term(), term()) :: :ok
  def check_protocol!(conn, opts \\ []), do: ok!(check_protocol(conn, opts))

  @doc "The servers in the cluster, raising on failure."
  @spec servers!(term(), term()) :: [server()]
  def servers!(conn, opts \\ []), do: unwrap!(servers(conn, opts))

  @doc "This server, raising on failure."
  @spec server!(term(), term()) :: server()
  def server!(conn, opts \\ []), do: unwrap!(server(conn, opts))
end
