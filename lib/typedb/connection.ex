defmodule TypeDB.Connection do
  @moduledoc """
  A supervised connection to a TypeDB server.

  A connection process owns exactly two things: the configuration and the current
  authentication token. It does **not** proxy requests — HTTP calls run in the
  caller's process, reading configuration from a `:read_concurrency` ETS table
  owned by this process. A slow query therefore never blocks anything else.

  The process is consulted only when the token has to be minted or renewed, and
  it collapses concurrent renewals into a single sign-in.

  ## Starting

  Put it in your supervision tree:

      children = [
        {TypeDB,
         url: "http://localhost:8000",
         username: "admin",
         password: System.fetch_env!("TYPEDB_PASSWORD")}
      ]

  Or start several, each under its own name:

      {TypeDB, name: :analytics, url: "http://analytics:8000", ...}
      {TypeDB, name: :ingest,    url: "http://ingest:8000",    ...}

  Every API function takes that name as its first argument.

  ## Token lifecycle

  TypeDB issues expiring bearer tokens. This driver acquires one lazily on the
  first request, caches it, and renews it transparently when the server answers
  `401` with an `AUT*` code — the failed request is then retried once. Callers
  never see token churn.

  When a connection is configured with a pre-issued `:token` there is nothing to
  renew, and expiry surfaces as `%TypeDB.Error{kind: :unauthenticated}`.
  """

  use GenServer

  require Logger

  alias TypeDB.{Config, Error, JSON}

  @typedoc "A connection: the registered name of a `TypeDB.Connection` process."
  @type t :: atom()

  @config_key :config
  @token_key :token

  @doc """
  Starts a connection. See `TypeDB.Config` for the supported options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Config.new(opts) do
      {:ok, config} -> GenServer.start_link(__MODULE__, config, name: config.name)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, TypeDB),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Stops a connection.
  """
  @spec stop(t(), term(), timeout()) :: :ok
  def stop(conn, reason \\ :normal, timeout \\ :infinity), do: GenServer.stop(conn, reason, timeout)

  @doc """
  Returns the validated configuration of a running connection.
  """
  @spec config(t()) :: Config.t()
  def config(conn) do
    case :ets.lookup(conn, @config_key) do
      [{@config_key, config}] ->
        config

      [] ->
        raise Error.new(:config, "TypeDB connection #{inspect(conn)} is not running")
    end
  rescue
    ArgumentError ->
      reraise Error.new(
                :config,
                "TypeDB connection #{inspect(conn)} is not running. " <>
                  "Add {TypeDB, name: #{inspect(conn)}, ...} to your supervision tree."
              ),
              __STACKTRACE__
  end

  # ----------------------------------------------------------------------------
  # Request execution (runs in the caller process)
  # ----------------------------------------------------------------------------

  @typedoc """
  Options for `request/4`:

    * `:body` — term to encode as the JSON request body
    * `:expect` — `:json` (default), `:text` or `:empty`
    * `:versioned` — prefix the path with the API version. Defaults to `true`
    * `:authenticated` — send a bearer token. Defaults to `true`
    * `:idempotent` — allow transport-level retries. Defaults to `true` for
      `:get` and `:delete`
    * `:timeout` — overrides the connection timeout for this request
  """
  @type request_opts :: keyword()

  @doc """
  Performs an authenticated request against the TypeDB HTTP API.

  This is the escape hatch used by every other module in this library. Reach for
  it directly only to call an endpoint the driver does not wrap yet.

      TypeDB.Connection.request(conn, :get, "/databases")
  """
  @spec request(t(), TypeDB.HTTP.method(), String.t(), request_opts()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(conn, method, path, opts \\ []) do
    config = config(conn)
    do_request(conn, config, method, path, opts, _renewed? = false)
  end

  defp do_request(conn, config, method, path, opts, renewed?) do
    authenticated? = Keyword.get(opts, :authenticated, true)

    with {:ok, token} <- maybe_token(conn, config, authenticated?),
         {:ok, response} <- send_request(conn, config, method, path, opts, token) do
      case handle_status(response, opts) do
        {:retry_unauthenticated, error} when authenticated? and not renewed? ->
          case renew_token(conn, config, token) do
            {:ok, _new_token} -> do_request(conn, config, method, path, opts, true)
            {:error, renew_error} -> {:error, auth_error(error, renew_error)}
          end

        # A 401 we cannot act on: an unauthenticated endpoint rejected us, or the
        # renewed token was rejected too.
        {:retry_unauthenticated, error} ->
          {:error, error}

        other ->
          other
      end
    end
  end

  # A renewal that failed for authentication reasons explains the problem better
  # than the 401 that triggered it ("bad password", "static token cannot be
  # renewed"), so it wins — but it inherits the server's stable error code. A
  # renewal that failed for transport reasons says nothing about authentication,
  # so the original 401 stands.
  defp auth_error(original, %Error{kind: :unauthenticated} = renew_error) do
    %{renew_error | code: renew_error.code || original.code, status: renew_error.status || original.status}
  end

  defp auth_error(original, _renew_error), do: original

  defp maybe_token(_conn, _config, false), do: {:ok, nil}

  defp maybe_token(conn, config, true) do
    case :ets.lookup(conn, @token_key) do
      [{@token_key, token}] when is_binary(token) -> {:ok, token}
      _ -> renew_token(conn, config, nil)
    end
  end

  defp renew_token(conn, config, stale_token) do
    GenServer.call(conn, {:renew_token, stale_token}, call_timeout(config))
  end

  defp call_timeout(%Config{timeout: :infinity}), do: :infinity
  defp call_timeout(%Config{timeout: timeout}), do: timeout + :timer.seconds(5)

  defp send_request(conn, config, method, path, opts, token) do
    url = build_url(config, path, opts)
    headers = build_headers(token, opts)
    body = encode_body(opts)

    http_opts = [
      # `timeout: nil` reaches here whenever a caller forwards an absent option.
      timeout: opts[:timeout] || config.timeout,
      connect_timeout: config.connect_timeout
    ]

    adapter = config.http_adapter
    adapter_state = adapter_state(conn)
    attempts = if idempotent?(method, opts), do: config.max_retries + 1, else: 1

    attempt(adapter, adapter_state, method, url, headers, body, http_opts, config, 1, attempts)
  end

  defp attempt(adapter, state, method, url, headers, body, http_opts, config, attempt_no, attempts) do
    case adapter.request(state, method, url, headers, body, http_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Error{kind: kind}} when kind in [:transport, :timeout] and attempt_no < attempts ->
        delay = Config.backoff(config, attempt_no)

        Logger.debug(fn ->
          "TypeDB: #{kind} on #{method} #{url} (attempt #{attempt_no}/#{attempts}), retrying in #{delay}ms"
        end)

        Process.sleep(delay)
        attempt(adapter, state, method, url, headers, body, http_opts, config, attempt_no + 1, attempts)

      {:error, error} ->
        {:error, error}
    end
  end

  defp idempotent?(method, opts) do
    Keyword.get_lazy(opts, :idempotent, fn -> method in [:get, :delete] end)
  end

  defp adapter_state(conn) do
    case :ets.lookup(conn, :http_state) do
      [{:http_state, state}] -> state
      [] -> raise Error.new(:config, "TypeDB connection #{inspect(conn)} has no HTTP adapter state")
    end
  end

  defp build_url(config, path, opts) do
    if Keyword.get(opts, :versioned, true) do
      Config.url(config, path)
    else
      Config.raw_url(config, path)
    end
  end

  defp build_headers(token, opts) do
    headers = [{"accept", "application/json, text/plain"}]

    headers =
      if Keyword.has_key?(opts, :body), do: [{"content-type", "application/json"} | headers], else: headers

    if is_binary(token), do: [{"authorization", "Bearer " <> token} | headers], else: headers
  end

  defp encode_body(opts) do
    case Keyword.fetch(opts, :body) do
      {:ok, body} -> JSON.encode_to_iodata!(body)
      :error -> nil
    end
  end

  # ----------------------------------------------------------------------------
  # Response handling
  # ----------------------------------------------------------------------------

  defp handle_status(%{status: status} = response, opts) when status in 200..299 do
    decode_success(response, Keyword.get(opts, :expect, :json))
  end

  defp handle_status(%{status: 401} = response, _opts) do
    {:retry_unauthenticated, error_from(response)}
  end

  defp handle_status(response, _opts), do: {:error, error_from(response)}

  defp decode_success(%{status: 204}, _expect), do: {:ok, :ok}
  defp decode_success(%{body: ""}, :json), do: {:ok, :ok}
  defp decode_success(_response, :empty), do: {:ok, :ok}
  defp decode_success(%{body: body}, :text), do: {:ok, body}

  defp decode_success(%{body: body}, :json) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         Error.new(:decode, "TypeDB returned a body that is not valid JSON", reason: reason, body: body)}
    end
  end

  defp error_from(%{status: status, body: body}) do
    case JSON.decode(body) do
      {:ok, decoded} -> Error.from_response(status, decoded)
      {:error, _} -> Error.from_response(status, body)
    end
  end

  # ----------------------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------------------

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    with {:ok, http_state} <- init_adapter(config) do
      table =
        :ets.new(config.name, [
          :named_table,
          :protected,
          :set,
          read_concurrency: true
        ])

      :ets.insert(table, [{@config_key, config}, {:http_state, http_state}])

      if is_binary(config.static_token) do
        :ets.insert(table, {@token_key, config.static_token})
      end

      {:ok, %{config: config, table: table, http_state: http_state, token: config.static_token}}
    end
  end

  defp init_adapter(%Config{http_adapter: adapter, http_opts: opts, name: name}) do
    opts = Keyword.put_new(opts, :profile, :"#{name}.HTTP")

    case adapter.init(opts) do
      {:ok, state} ->
        {:ok, state}

      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop, Error.new(:config, "HTTP adapter #{inspect(adapter)} failed to start", reason: reason)}
    end
  end

  @impl true
  def handle_call({:renew_token, stale_token}, _from, state) do
    cond do
      # Someone else already renewed while this caller was queued.
      is_binary(state.token) and state.token != stale_token ->
        {:reply, {:ok, state.token}, state}

      is_binary(state.config.static_token) ->
        {:reply,
         {:error,
          Error.new(
            :unauthenticated,
            "the pre-issued :token was rejected by TypeDB and cannot be renewed; " <>
              "configure :username and :password for automatic renewal"
          )}, state}

      true ->
        case sign_in(state) do
          {:ok, token} ->
            :ets.insert(state.table, {@token_key, token})
            {:reply, {:ok, token}, %{state | token: token}}

          {:error, error} ->
            :ets.delete(state.table, @token_key)
            {:reply, {:error, error}, %{state | token: nil}}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    adapter = state.config.http_adapter

    if function_exported?(adapter, :terminate, 1) do
      adapter.terminate(state.http_state)
    end

    :ok
  end

  defp sign_in(%{config: config, http_state: http_state}) do
    body = JSON.encode_to_iodata!(%{username: config.username, password: config.password})
    url = Config.url(config, "/signin")

    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    http_opts = [timeout: config.timeout, connect_timeout: config.connect_timeout]

    case config.http_adapter.request(http_state, :post, url, headers, body, http_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        decode_token(response_body)

      {:ok, response} ->
        {:error, error_from(response)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_token(body) do
    case JSON.decode(body) do
      {:ok, %{"token" => token}} when is_binary(token) ->
        {:ok, token}

      {:ok, other} ->
        {:error, Error.new(:decode, "sign-in response did not contain a token", body: other)}

      {:error, reason} ->
        {:error, Error.new(:decode, "sign-in response was not valid JSON", reason: reason, body: body)}
    end
  end
end
