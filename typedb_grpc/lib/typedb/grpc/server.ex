defmodule TypeDB.GRPC.Server do
  @moduledoc """
  What the server is, and whether this driver was built for it.
  """

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
             "reading the server version"
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

  @doc """
  Checks the server against the protocol version this driver was generated from.

  Returns `:ok`, or `{:error, %TypeDB.Error{kind: :config}}` naming both
  versions. Nothing calls this on the hot path: it is for a boot-time check and
  for the integration suite, which is where a mismatch should be found.

  A mismatch is not proof of breakage — protobuf tolerates a client built from
  an older schema — but it is proof that nobody has checked.
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
end
