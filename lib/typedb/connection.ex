defmodule TypeDB.Connection do
  @moduledoc """
  A supervised connection to a TypeDB server.

  A connection process owns exactly two things: the configuration and the current
  access token. It does **not** proxy requests — HTTP calls run in the caller's
  process, reading configuration from a
  `:read_concurrency` ETS table owned by this process. A slow query therefore
  never blocks anything else.

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

  TypeDB issues expiring JWTs. This driver:

    * acquires one lazily, on the first request that needs it;
    * reads the token's own lifetime from its JWT claims and renews it
      *before* it expires, so ordinary traffic never spends a round trip
      discovering a `401`;
    * still renews reactively when a `401` arrives anyway — a clock skew, a
      revoked token, a restarted server — and retries the failed request;
    * collapses concurrent renewals: whoever reaches the connection first signs
      in, and everyone queued behind takes that token.

  `:max_auth_renewals` bounds how many times a single request will go around the
  renew-and-retry loop before surfacing the error.

  When a connection is configured with a pre-issued `:token` there is nothing to
  renew, and expiry surfaces as `%TypeDB.Error{kind: :unauthenticated}`.
  """

  use GenServer

  alias TypeDB.{Config, Error, JSON, Log, Telemetry, Token, Transport}

  @typedoc "A connection: the registered name of a `TypeDB.Connection` process."
  @type t :: atom()

  @config_key :config
  @token_key :token
  @adapter_key :http_state

  # Renew this long before a token actually expires, capped at a quarter of the
  # token's lifetime so that a short-lived token never looks permanently stale.
  @refresh_margin_ms :timer.seconds(30)
  @max_margin_fraction 4

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

  Accepts the registered name or the pid — unlike every other function here,
  which needs the name because it reads the connection's ETS table.
  """
  @spec stop(t() | pid(), term(), timeout()) :: :ok
  def stop(conn, reason \\ :normal, timeout \\ :infinity), do: GenServer.stop(conn, reason, timeout)

  @doc """
  Returns `true` when `conn` can serve a request.

  Every other function in this driver raises `%TypeDB.Error{kind: :config}`
  against a connection that is not running — deliberately, since the name is
  nearly always a typo or a missing child spec. This is for the callers who
  cannot let that happen: a health endpoint, a supervisor deciding whether to
  start work, a module that maps driver failures onto its own error type and
  has nowhere to put an exception.

  **`Process.whereis/1` is not the same question.** `GenServer.start_link/3`
  registers the name *before* `init/1` runs, so a pid exists under the name
  before the connection can do anything with it — and a call in that window
  raises. This checks what a request actually needs.

      if TypeDB.running?(conn), do: TypeDB.query(conn, "social", query)

  It answers about *this node's connection process*, not about TypeDB: a
  connection whose server is unreachable is still running. `TypeDB.Server.health/2`
  is the question about the server, and it needs a running connection to ask.

  Inherently racy, as any such predicate is — the connection can stop between
  this call and the next one. It narrows the window; it does not remove it.
  """
  @spec running?(t()) :: boolean()
  def running?(conn) do
    match?([{@config_key, _config}], :ets.lookup(conn, @config_key))
  rescue
    # No table under that name: never started, already stopped, or `conn` is not
    # a registered name at all. All three are "cannot serve a request".
    ArgumentError -> false
  end

  @doc """
  Returns the validated configuration of a running connection.
  """
  @spec config(t()) :: Config.t()
  def config(conn), do: lookup!(conn, @config_key)

  @doc false
  @spec adapter_state(t()) :: term()
  def adapter_state(conn), do: lookup!(conn, @adapter_key)

  defp lookup!(conn, key) do
    case :ets.lookup(conn, key) do
      [{^key, value}] -> value
      [] -> raise not_running(conn)
    end
  rescue
    ArgumentError -> reraise not_running(conn), __STACKTRACE__
  end

  # Two different situations reach here and the driver cannot tell them apart:
  # the name was never started — a typo or a missing child spec, which is what
  # this used to be the whole message about — or the connection went down and
  # its supervisor has not brought it back yet. The second is transient, and a
  # message that only offers "add it to your supervision tree" sends whoever
  # reads it looking for a child spec that is already there.
  defp not_running(conn) do
    Error.new(
      :config,
      "TypeDB connection #{inspect(conn)} is not running. Either it was never " <>
        "started — add {TypeDB, name: #{inspect(conn)}, ...} to your supervision " <>
        "tree — or it went down and has not been restarted yet, in which case " <>
        "this is transient and the next call will work."
    )
  end

  @doc """
  Returns a token that is not about to expire, minting one if needed.
  """
  @spec token(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def token(conn) do
    case :ets.lookup(conn, @token_key) do
      [{@token_key, token, deadline}] ->
        if usable?(deadline), do: {:ok, token}, else: renew_token(conn, :any)

      [] ->
        renew_token(conn, :any)
    end
  rescue
    ArgumentError -> reraise not_running(conn), __STACKTRACE__
  end

  @doc """
  Renews the access token.

  `failed_at` is the monotonic millisecond at which the caller's request was
  sent, or `:any` when the caller simply has no usable token. Passing the send
  time is what lets the connection tell "my token really is stale" from "another
  process already replaced it while I was queued".
  """
  @spec renew_token(t(), :any | integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def renew_token(conn, failed_at) do
    timeout = call_timeout(config(conn))

    try do
      GenServer.call(conn, {:renew_token, failed_at}, timeout)
    catch
      :exit, {:timeout, {GenServer, :call, _args}} ->
        {:error, renewal_timeout_error(conn, timeout)}

      # The connection stopped while we were queued on it. Every other entry
      # point answers a connection that is not running by raising, so this one
      # does too rather than inventing an error kind for it.
      :exit, {_reason, {GenServer, :call, _args}} ->
        reraise not_running(conn), __STACKTRACE__
    end
  end

  # Renewals are serialised through the connection process, so the wait is
  # bounded by what a *sign-in* costs — connecting plus one round trip — not by
  # the per-request timeout, which describes something else entirely and used to
  # expire before a single slow sign-in could even finish. Doubled because a
  # caller may have to wait out a sign-in already in flight before its own is
  # attempted, plus a fixed margin for queueing.
  @renewal_queue_margin_ms :timer.seconds(1)

  defp call_timeout(%Config{timeout: :infinity}), do: :infinity
  defp call_timeout(%Config{connect_timeout: :infinity}), do: :infinity

  defp call_timeout(%Config{timeout: timeout, connect_timeout: connect_timeout}) do
    2 * (timeout + connect_timeout) + @renewal_queue_margin_ms
  end

  defp renewal_timeout_error(conn, timeout) do
    Error.new(
      :timeout,
      "TypeDB connection #{inspect(conn)} did not renew its access token within #{timeout}ms. " <>
        "Sign-in is serialised through the connection process, so either sign-in itself is slower " <>
        "than :timeout and :connect_timeout allow for, or the HTTP adapter is ignoring them.",
      reason: :renewal_timeout
    )
  end

  defp usable?(:unknown), do: true
  defp usable?(deadline), do: System.monotonic_time(:millisecond) < deadline

  @typedoc """
  Options for `request/4`:

    * `:body` — term to encode as the JSON request body
    * `:expect` — `:json` (default), `:text` or `:empty`
    * `:versioned` — prefix the path with the API version. Defaults to `true`
    * `:authenticated` — send a bearer token. Defaults to `true`
    * `:idempotent` — allow retries. Defaults to `true` for `:get` and
      `:delete`, but the method is a poor proxy for the question and every
      caller in this driver answers it for itself: a read query is safe to
      re-send and a commit is not, though both are `POST`
    * `:timeout` — overrides the connection timeout for this request
    * `:deadline` — overrides the connection's wall-clock budget for the whole
      call, retries included
    * `:metadata` — a map merged into the telemetry metadata of this call, for
      what the path cannot say: the database of a `/query` is in its body
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
  defdelegate request(conn, method, path, opts \\ []), to: Transport

  # ----------------------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------------------

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    with {:ok, http_state} <- init_adapter(config) do
      table = :ets.new(config.name, [:named_table, :protected, :set, read_concurrency: true])

      # `:protected` means every process in the VM can read this table — which is
      # the point, since it is what lets requests run in the caller's process
      # rather than through the connection. So the copy published here carries no
      # credentials: nothing outside this process ever needed them, and
      # `:ets.lookup(:my_conn, :config)` should not be a way to read a password.
      # `state.config` below keeps the full struct for sign-in.
      :ets.insert(table, [{@config_key, redact(config)}, {@adapter_key, http_state}])

      state = %{
        config: config,
        table: table,
        http_state: http_state,
        issued_at: nil,
        transport: adapter_owner(config.http_adapter, http_state)
      }

      {:ok, cache_static_token(state)}
    end
  end

  defp redact(%Config{} = config), do: %{config | password: nil, static_token: nil}

  # The process the transport cannot work without, if it has one. Adapters that
  # hold no process of their own answer nil.
  #
  # The link is made here rather than assumed. `TypeDB.HTTP.Finch` happens to be
  # linked already — `Finch.start_link/1` runs inside this process's `init/1` and
  # links to its caller — but an adapter that adopts an existing pool or starts
  # one with `GenServer.start/3` would not be, and would silently lose the
  # supervision behaviour `c:TypeDB.HTTP.owner/1` documents. Linking twice is a
  # no-op, and linking to a pid that is already dead delivers `{:EXIT, pid,
  # :noproc}`, which the clause below turns into the same clean stop.
  defp adapter_owner(adapter, http_state) do
    with true <- function_exported?(adapter, :owner, 1),
         pid when is_pid(pid) <- adapter.owner(http_state) do
      Process.link(pid)
      pid
    else
      _ -> nil
    end
  end

  defp init_adapter(%Config{http_adapter: adapter, http_opts: opts, name: name} = config) do
    # Adapters that configure connecting at pool-build time — Finch does — cannot
    # see the connection's `:connect_timeout` any other way, because `init/2` runs
    # long before the first request. Injected with put_new so an adapter option of
    # the same name still wins.
    opts = Keyword.put_new(opts, :connect_timeout, config.connect_timeout)

    case adapter.init(name, opts) do
      {:ok, state} ->
        {:ok, state}

      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop, Error.new(:config, "HTTP adapter #{inspect(adapter)} failed to start", reason: reason)}
    end
  end

  defp cache_static_token(%{config: %Config{static_token: nil}} = state), do: state

  defp cache_static_token(%{config: %Config{static_token: token}} = state) do
    # A pre-issued token cannot be renewed, so it is cached without a deadline:
    # its expiry can only ever be discovered from a 401.
    :ets.insert(state.table, {@token_key, token, :unknown})
    %{state | issued_at: System.monotonic_time(:millisecond)}
  end

  @impl true
  def handle_call({:renew_token, failed_at}, _from, state) do
    cond do
      reusable?(state, failed_at) ->
        {:reply, {:ok, current_token(state)}, state}

      is_binary(state.config.static_token) ->
        {:reply, {:error, static_token_error()}, state}

      true ->
        sign_in_and_cache(state)
    end
  end

  # `trap_exit` is on so that terminate/2 runs and the adapter can clean up. That
  # makes every linked process's death arrive here instead of killing us, so the
  # transport's death has to be acted on explicitly: without this the connection
  # survives its own pool and answers every later request with a raw exception
  # raised from inside the adapter, and nothing ever restarts it.
  @impl true
  def handle_info({:EXIT, pid, reason}, %{transport: pid} = state) when is_pid(pid) do
    Log.log(
      state.config,
      :error,
      "TypeDB connection #{inspect(state.config.name)}: transport died (#{inspect(reason)})",
      typedb_connection: state.config.name
    )

    {:stop, {:transport_down, reason}, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Log.log(
      state.config,
      :debug,
      fn -> "TypeDB connection #{inspect(state.config.name)}: ignoring #{inspect(message)}" end,
      typedb_connection: state.config.name
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    adapter = state.config.http_adapter

    # `TypeDB.HTTP` is a public extension point, so this is somebody else's code
    # running on the way out. The driver contains adapter faults everywhere else
    # — see `TypeDB.Transport` — and shutdown is the place where containing them
    # matters most: whatever the pool does, the connection is going away, and a
    # crash report from a process that was asked to stop helps nobody.
    if function_exported?(adapter, :terminate, 1) do
      try do
        adapter.terminate(state.http_state)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  # The cached token can be reused when it is still valid *and* it was minted
  # after the caller's request failed — otherwise the caller would retry with a
  # token that was already stale when it was cached, burning its renewal budget
  # on a request that cannot succeed.
  defp reusable?(state, failed_at) do
    case :ets.lookup(state.table, @token_key) do
      [{@token_key, _token, deadline}] -> usable?(deadline) and minted_after?(state.issued_at, failed_at)
      [] -> false
    end
  end

  defp minted_after?(_issued_at, :any), do: true
  defp minted_after?(nil, _failed_at), do: false
  defp minted_after?(issued_at, failed_at), do: issued_at > failed_at

  defp current_token(state) do
    [{@token_key, token, _deadline}] = :ets.lookup(state.table, @token_key)
    token
  end

  defp static_token_error do
    Error.new(
      :unauthenticated,
      "the pre-issued :token was rejected by TypeDB and cannot be renewed; " <>
        "configure :username and :password for automatic renewal"
    )
  end

  defp sign_in_and_cache(state) do
    case sign_in(state) do
      {:ok, token} ->
        now = System.monotonic_time(:millisecond)
        :ets.insert(state.table, {@token_key, token, deadline(token, now)})
        {:reply, {:ok, token}, %{state | issued_at: now}}

      {:error, error} ->
        :ets.delete(state.table, @token_key)
        {:reply, {:error, error}, %{state | issued_at: nil}}
    end
  end

  # Only the token's own lifetime is used, never its absolute timestamps: both
  # come from the server's clock, so their difference is meaningful where a
  # comparison against the local clock would not be.
  defp deadline(token, now) do
    case Token.lifetime_ms(token) do
      :unknown -> :unknown
      lifetime -> now + lifetime - min(@refresh_margin_ms, div(lifetime, @max_margin_fraction))
    end
  end

  defp sign_in(%{config: config} = state) do
    Telemetry.span_sign_in(%{connection: config.name}, fn ->
      case do_sign_in(state) do
        {:ok, token} -> {{:ok, token}, %{connection: config.name}}
        {:error, error} -> {{:error, error}, %{connection: config.name, error: error}}
      end
    end)
  end

  defp do_sign_in(%{config: config, http_state: http_state}) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    http_opts = [timeout: config.timeout, connect_timeout: config.connect_timeout]
    url = Config.url(config, "/signin")

    # The whole body is inside `Transport.contain/3`, not just the adapter call.
    # This runs *inside* the connection process, so anything that escapes takes
    # the connection down and leaves every caller with "connection is not
    # running", naming neither the fault nor where it came from. The JSON encode
    # and decode are as able to raise as the adapter is — a configured codec is
    # a plug-in point too, and `:password` admits any binary, so a secret that
    # is not valid UTF-8 raises out of the encoder.
    result =
      Transport.contain(config.http_adapter, "POST #{url}", fn ->
        body = JSON.encode_to_iodata!(%{username: config.username, password: config.password})

        config.http_adapter.request(http_state, :post, url, headers, body, http_opts)
      end)

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 -> decode_token(response_body)
      {:ok, response} -> {:error, Transport.error_from(response)}
      {:error, error} -> {:error, error}
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
