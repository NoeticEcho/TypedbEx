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
  `TypeDB.HTTP.Httpc` is still supported for environments that must run on OTP
  alone, and the numbers above are the price.

  ## Options

    * `:size` — connections per pool. Defaults to `50`.
    * `:count` — pools per host. Defaults to `1`.
    * `:pools` — a full Finch `:pools` map, which takes precedence over `:size`
      and `:count` when you need per-host tuning.
    * `:conn_opts` — `Mint.HTTP.connect/4` options, merged into the default pool.
      TLS options go here as `transport_opts`.
    * `:pool_timeout` — how long a request waits for a free connection when the
      pool is saturated, in ms. Defaults to Finch's own default of `5_000`.
    * `:name` — an existing Finch instance to use instead of starting one. The
      adapter neither starts nor stops it.

  The connection's `:connect_timeout` is applied as `transport_opts[:timeout]` on
  the default pool, which is the only place Mint reads a connect timeout from.
  Pass your own `conn_opts: [transport_opts: [timeout: …]]` to override it, or a
  full `:pools` map to take over pool configuration entirely.

  ## TLS

  Finch verifies certificates by default through `Mint`, which uses the OS trust
  store and checks hostnames. To pin a private CA:

      http: {TypeDB.HTTP.Finch, conn_opts: [transport_opts: [cacertfile: "/etc/ssl/private-ca.pem"]]}
  """

  @behaviour TypeDB.HTTP

  @compile {:no_warn_undefined, [Finch, Finch.Request, Finch.Response]}

  @default_size 50
  @default_count 1

  defstruct [:name, :owned?, :supervisor, :pool_timeout]

  @type t :: %__MODULE__{
          name: atom(),
          owned?: boolean(),
          supervisor: pid() | nil,
          pool_timeout: timeout() | nil
        }

  @impl true
  def init(connection_name, opts) do
    cond do
      not Code.ensure_loaded?(Finch) ->
        {:error,
         TypeDB.Error.new(
           :config,
           ~s(TypeDB.HTTP.Finch requires the :finch package. Add {:finch, "~> 0.23"} to your dependencies, ) <>
             ~s(or select http: {TypeDB.HTTP.Httpc, []} to run on OTP's own HTTP client instead.)
         )}

      existing = opts[:name] ->
        {:ok, %__MODULE__{name: existing, owned?: false, supervisor: nil, pool_timeout: opts[:pool_timeout]}}

      true ->
        start_pool(pool_name(connection_name), opts)
    end
  end

  # Unique per *instance*, not per connection name. Finch does not release its
  # registered name synchronously when a pool dies, so a connection restarted by
  # its supervisor would otherwise collide with the corpse of its predecessor —
  # and `Finch.start_link/1` answers `{:error, {:already_started, _}}` for a name
  # whose registry is already gone for good. The connection name stays as the
  # prefix so pools remain identifiable in Finch's own telemetry.
  defp pool_name(connection_name) do
    :"#{connection_name}.Finch.#{System.unique_integer([:positive])}"
  end

  defp start_pool(name, opts) do
    case Finch.start_link(name: name, pools: pools(opts)) do
      {:ok, pid} ->
        {:ok, %__MODULE__{name: name, owned?: true, supervisor: pid, pool_timeout: opts[:pool_timeout]}}

      {:error, reason} ->
        {:error, TypeDB.Error.new(:config, "could not start the Finch pool for TypeDB", reason: reason)}
    end
  end

  @doc false
  @spec pools(keyword()) :: map()
  def pools(opts) do
    Keyword.get_lazy(opts, :pools, fn -> %{default: default_pool(opts)} end)
  end

  defp default_pool(opts) do
    [
      size: Keyword.get(opts, :size, @default_size),
      count: Keyword.get(opts, :count, @default_count),
      conn_opts: conn_opts(opts)
    ]
  end

  # Mint reads the connect timeout from transport_opts, and a pool is built once —
  # so this is the only chance the connection's :connect_timeout gets to apply.
  # put_new throughout: whatever the caller wrote in :conn_opts wins.
  defp conn_opts(opts) do
    conn_opts = Keyword.get(opts, :conn_opts, [])

    case Keyword.get(opts, :connect_timeout) do
      nil ->
        conn_opts

      timeout ->
        transport_opts = Keyword.put_new(Keyword.get(conn_opts, :transport_opts, []), :timeout, timeout)
        Keyword.put(conn_opts, :transport_opts, transport_opts)
    end
  end

  @impl true
  def owner(%__MODULE__{owned?: true, supervisor: pid}) when is_pid(pid), do: pid
  def owner(%__MODULE__{}), do: nil

  @impl true
  def terminate(%__MODULE__{owned?: false}), do: :ok

  # The supervisor pid `Finch.start_link/1` returned, not `Process.whereis(name)`
  # — under that name Finch registers its *Registry*, and stopping a registry
  # leaves the supervisor to restart it, so the pool never actually goes away.
  def terminate(%__MODULE__{owned?: true, supervisor: pid}) when is_pid(pid) do
    Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  def terminate(%__MODULE__{}), do: :ok

  @impl true
  def request(%__MODULE__{name: name, pool_timeout: pool_timeout}, method, url, headers, body, opts) do
    request = Finch.build(method, url, headers, body)

    # `:connect_timeout` is *not* `:pool_timeout` — connecting is configured on
    # the pool, in `conn_opts/1`, and waiting for a free connection has its own
    # knob so that saturation and an unreachable host stay distinguishable.
    finch_opts =
      []
      |> put_opt(:receive_timeout, Keyword.get(opts, :timeout))
      |> put_opt(:pool_timeout, pool_timeout)

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
    if Map.get(exception, :reason) in [:timeout, :pool_timeout] do
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
