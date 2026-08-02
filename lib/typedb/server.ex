defmodule TypeDB.Server do
  @moduledoc """
  Server introspection: health, version and cluster membership.

  `health/2` and `version/2` are unauthenticated, so they work before (and
  independently of) sign-in — which is what makes `health/2` usable as a
  readiness probe. Every function here takes `:timeout` and `:deadline`, which
  a readiness probe wants: waiting the connection's default sixty seconds to
  learn that a server is down is not a probe.
  """

  use TypeDB.Bang

  alias TypeDB.{CallOptions, Connection, Error}

  @doc """
  Returns `:ok` when the server is up and serving the HTTP API.

  Unauthenticated. Use it to wait for a server to become ready:

      TypeDB.Server.health(conn)
  """
  @spec health(Connection.t(), keyword()) :: :ok | {:error, Error.t()}
  def health(conn, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Server.health/2")

    case Connection.request(conn, :get, "/health",
           authenticated: false,
           expect: :empty,
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns `:ok` when the server is up, raising otherwise.
  """
  @spec health!(Connection.t(), keyword()) :: :ok
  def health!(conn, opts \\ []), do: ok!(health(conn, opts))

  @doc """
  Returns the server's distribution and version.

      {:ok, %{distribution: "TypeDB CE", version: "3.12.1"}}

  Unauthenticated.
  """
  @typedoc "What TypeDB reports about itself."
  @type version :: %{distribution: String.t(), version: String.t()}

  @spec version(Connection.t(), keyword()) :: {:ok, version()} | {:error, Error.t()}
  def version(conn, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Server.version/2")

    case Connection.request(conn, :get, "/version",
           authenticated: false,
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, %{"distribution" => distribution, "version" => version}} ->
        {:ok, %{distribution: distribution, version: version}}

      {:ok, other} ->
        {:error, Error.new(:decode, "unexpected version response", body: other)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns the server's distribution and version, raising on failure.
  """
  @spec version!(Connection.t(), keyword()) :: version()
  def version!(conn, opts \\ []), do: unwrap!(version(conn, opts))

  @doc """
  Lists the servers in the cluster.

  A single-server deployment reports one entry. Fields vary by distribution, so
  the decoded maps are returned as-is.
  """
  @spec servers(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def servers(conn, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Server.servers/2")

    case Connection.request(conn, :get, "/servers",
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, %{"servers" => servers}} when is_list(servers) -> {:ok, servers}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected servers response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Lists the servers in the cluster, raising on failure.
  """
  @spec servers!(Connection.t(), keyword()) :: [map()]
  def servers!(conn, opts \\ []), do: unwrap!(servers(conn, opts))
end
