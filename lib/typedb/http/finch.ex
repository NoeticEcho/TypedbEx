defmodule TypeDB.HTTP.Finch do
  @moduledoc """
  Default `TypeDB.HTTP` adapter, backed by [Finch](https://hex.pm/packages/finch).

  Each connection starts and supervises its own Finch instance, named after the
  connection, so pools are sized per TypeDB server and never shared by accident.
  The pool is torn down with the connection.

  ## Why this is the default

  Measured against a local TypeDB 3.12.1 with 400 requests per run:

  | Concurrency | `:httpc` | Finch |
  | --- | --- | --- |
  | 16 | 344 req/s, p50 45ms | 1729 req/s, p50 8ms |
  | 64 | 247 req/s, p50 263ms | 1773 req/s, p50 23ms |
  | 200 | 77 req/s, p50 2477ms | 1981 req/s, p50 19ms |

  `:httpc` does not degrade gracefully: throughput *falls* as concurrency rises.
  `TypeDB.HTTP.Httpc` is still supported for environments that must run without
  dependencies, and the numbers above are the price.

  ## Options

    * `:size` — connections per pool. Defaults to `50`.
    * `:count` — pools per host. Defaults to `1`.
    * `:pools` — a full Finch `:pools` map, which takes precedence over `:size`
      and `:count` when you need per-host tuning.
    * `:conn_opts` — `Mint.HTTP.connect/4` options, merged into the default pool.
      TLS options go here as `transport_opts`.
    * `:name` — an existing Finch instance to use instead of starting one. The
      adapter neither starts nor stops it.

  ## TLS

  Finch verifies certificates by default through `Mint`, which uses the OS trust
  store and checks hostnames. To pin a private CA:

      http: {TypeDB.HTTP.Finch, conn_opts: [transport_opts: [cacertfile: "/etc/ssl/private-ca.pem"]]}
  """

  @behaviour TypeDB.HTTP

  @compile {:no_warn_undefined, [Finch, Finch.Request, Finch.Response]}

  @default_size 50
  @default_count 1

  defstruct [:name, :owned?]

  @type t :: %__MODULE__{name: atom(), owned?: boolean()}

  @impl true
  def init(connection_name, opts) do
    cond do
      not Code.ensure_loaded?(Finch) ->
        {:error,
         TypeDB.Error.new(
           :config,
           ~s(TypeDB.HTTP.Finch requires the :finch package. Add {:finch, "~> 0.19"} to your dependencies, ) <>
             ~s(or select http: {TypeDB.HTTP.Httpc, []} to run without dependencies.)
         )}

      existing = opts[:name] ->
        {:ok, %__MODULE__{name: existing, owned?: false}}

      true ->
        start_pool(:"#{connection_name}.Finch", opts)
    end
  end

  defp start_pool(name, opts) do
    case Finch.start_link(name: name, pools: pools(opts)) do
      {:ok, _pid} ->
        {:ok, %__MODULE__{name: name, owned?: true}}

      {:error, {:already_started, _pid}} ->
        {:ok, %__MODULE__{name: name, owned?: true}}

      {:error, reason} ->
        {:error, TypeDB.Error.new(:config, "could not start the Finch pool for TypeDB", reason: reason)}
    end
  end

  defp pools(opts) do
    Keyword.get_lazy(opts, :pools, fn -> %{default: default_pool(opts)} end)
  end

  defp default_pool(opts) do
    pool = [size: Keyword.get(opts, :size, @default_size), count: Keyword.get(opts, :count, @default_count)]

    case Keyword.fetch(opts, :conn_opts) do
      {:ok, conn_opts} -> Keyword.put(pool, :conn_opts, conn_opts)
      :error -> pool
    end
  end

  @impl true
  def terminate(%__MODULE__{owned?: false}), do: :ok

  def terminate(%__MODULE__{name: name, owned?: true}) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def request(%__MODULE__{name: name}, method, url, headers, body, opts) do
    request = Finch.build(method, url, headers, body)

    finch_opts =
      []
      |> put_opt(:receive_timeout, Keyword.get(opts, :timeout))
      |> put_opt(:pool_timeout, Keyword.get(opts, :connect_timeout))

    case Finch.request(request, name, finch_opts) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: downcase(resp_headers), body: resp_body}}

      {:error, reason} ->
        {:error, transport_error(url, reason)}
    end
  end

  # Finch always answers with an exception struct, but which one — and whether it
  # carries a :reason — varies by failure, so the key is read rather than matched.
  defp transport_error(url, exception) do
    if Map.get(exception, :reason) == :timeout do
      TypeDB.Error.new(:timeout, "request to #{url} timed out", reason: exception)
    else
      TypeDB.Error.new(:transport, "request to #{url} failed: #{Exception.message(exception)}",
        reason: exception
      )
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp downcase(headers) do
    for {name, value} <- headers, do: {String.downcase(name), value}
  end
end
