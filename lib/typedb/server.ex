defmodule TypeDB.Server do
  @moduledoc """
  Server introspection: health, version and cluster membership.

  `health/1` and `version/1` are unauthenticated, so they work before (and
  independently of) sign-in — which is what makes `health/1` usable as a
  readiness probe.
  """

  use TypeDB.Bang

  alias TypeDB.{Connection, Error}

  @doc """
  Returns `:ok` when the server is up and serving the HTTP API.

  Unauthenticated. Use it to wait for a server to become ready:

      TypeDB.Server.health(conn)
  """
  @spec health(Connection.t()) :: :ok | {:error, Error.t()}
  def health(conn) do
    case Connection.request(conn, :get, "/health", authenticated: false, expect: :empty) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns `:ok` when the server is up, raising otherwise.
  """
  @spec health!(Connection.t()) :: :ok
  def health!(conn), do: ok!(health(conn))

  @doc """
  Returns the server's distribution and version.

      {:ok, %{distribution: "TypeDB CE", version: "3.12.1"}}

  Unauthenticated.
  """
  @typedoc "What TypeDB reports about itself."
  @type version :: %{distribution: String.t(), version: String.t()}

  @spec version(Connection.t()) :: {:ok, version()} | {:error, Error.t()}
  def version(conn) do
    case Connection.request(conn, :get, "/version", authenticated: false) do
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
  @spec version!(Connection.t()) :: version()
  def version!(conn), do: unwrap!(version(conn))

  @doc """
  Lists the servers in the cluster.

  A single-server deployment reports one entry. Fields vary by distribution, so
  the decoded maps are returned as-is.
  """
  @spec servers(Connection.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def servers(conn) do
    case Connection.request(conn, :get, "/servers") do
      {:ok, %{"servers" => servers}} when is_list(servers) -> {:ok, servers}
      {:ok, other} -> {:error, Error.new(:decode, "unexpected servers response", body: other)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Lists the servers in the cluster, raising on failure.
  """
  @spec servers!(Connection.t()) :: [map()]
  def servers!(conn), do: unwrap!(servers(conn))
end
