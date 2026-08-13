defmodule TypeDB.GRPC.Connection do
  @moduledoc """
  A supervised connection to TypeDB over gRPC.

  The same shape as `TypeDB.Connection`, and for the same reason: the process
  owns the channel and the access token, and **calls run in the caller's
  process**. The connection is consulted only when a token has to be minted or
  renewed, so it never becomes the throughput bottleneck — which matters more
  here than it does over HTTP, since a transaction on this transport is a
  long-lived stream and funnelling every message through one process would
  serialise every transaction in the VM.

  What is published to ETS is the channel and a redacted config. The password
  never leaves this process.

      {:ok, _pid} = TypeDB.GRPC.Connection.start_link(
        name: :graph,
        address: "127.0.0.1:1729",
        username: "admin",
        password: "password"
      )

  ## Opening

  The first call on a connection performs `connection_open`, the RPC every
  official driver makes first: it tells the server which protocol version, which
  language and which driver version are on this end, and the server answers with
  a connection id and the token. So an incompatible driver is refused by the
  server at the connection rather than discovered later by something that failed
  to decode, and the id in this driver's telemetry is the id in the server's log.

  It happens on the first call rather than in `start_link/1`, which is what keeps
  a supervision tree from failing to boot because TypeDB is not up yet.

  ## Tokens

  TypeDB issues expiring JWTs, and this driver renews one *before* it expires by
  reading the lifetime out of its claims, exactly as the sibling driver does —
  it uses the sibling's reader rather than a second copy of it, which is what
  the dependency on `typedb` is for. A token minted with `:token` is never
  renewed; its expiry surfaces as `%TypeDB.Error{kind: :unauthenticated}`.

  Concurrent renewals collapse: whoever reaches the process first signs in and
  everyone queued behind takes that token.
  """

  use GenServer

  require Logger

  alias TypeDB.Error
  alias TypeDB.GRPC.{Config, Telemetry}
  alias TypeDB.GRPC.Error, as: GRPCError
  alias Typedb.Protocol, as: Proto

  @type t :: atom()

  @config_key :config
  @channel_key :channel
  @token_key :token
  @connection_id_key :connection_id

  # Renew this long before the token actually expires, capped at a quarter of
  # its lifetime so a short-lived token never looks permanently stale. The same
  # numbers the sibling uses, for the same reason.
  @renewal_margin_ms 30_000

  # Who the server is told it is talking to. `connection_open` carries this, and
  # it is the only place TypeDB learns which driver is on the other end — it
  # turns up in the server's log and in its connection list, so an operator can
  # tell an Elixir application apart from a console session.
  @driver_lang "elixir"
  @driver_version Mix.Project.config()[:version]

  @doc """
  Starts a connection. See `TypeDB.GRPC.Config.new/1` for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    config = Config.new!(opts)
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Stops a connection."
  @spec stop(t() | pid(), term(), timeout()) :: :ok
  def stop(conn, reason \\ :normal, timeout \\ :infinity), do: GenServer.stop(conn, reason, timeout)

  @doc """
  Whether `conn` can serve a call.

  The same question — and the same caveat — as `TypeDB.running?/1`: it answers
  about this node's connection process, not about TypeDB. A connection whose
  server is unreachable is still running.
  """
  @spec running?(t()) :: boolean()
  def running?(conn) do
    match?([{@config_key, _}], :ets.lookup(conn, @config_key))
  rescue
    ArgumentError -> false
  end

  @doc "The connection's config, with credentials redacted."
  @spec config(t()) :: Config.t()
  def config(conn), do: lookup!(conn, @config_key)

  @typedoc """
  A gRPC channel. `GRPC.Channel` defines the struct but no `t/0`, so this names
  it here rather than referring to a type that does not exist.
  """
  @type channel :: %GRPC.Channel{}

  @doc "The gRPC channel. Safe to use from any process."
  @spec channel(t()) :: channel()
  def channel(conn), do: lookup!(conn, @channel_key)

  @doc """
  The id the server gave this connection, or `nil` before it has been opened.

  A UUID, and the same one the server writes in its own log, so it is what
  connects a slow query on this side to a session on that side. `nil` until the
  first call makes the connection sign in — this driver opens lazily — and
  permanently `nil` for a connection configured with a `:token`, which has no
  credentials to open with.
  """
  @spec connection_id(t()) :: String.t() | nil
  def connection_id(conn) do
    case :ets.lookup(conn, @connection_id_key) do
      [{@connection_id_key, id}] -> id
      [] -> nil
    end
  rescue
    ArgumentError -> reraise not_running(conn), __STACKTRACE__
  end

  @doc """
  A token that is not about to expire, minting one if needed.
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

  `minted_before` is the monotonic millisecond at which the caller obtained the
  token it found wanting, or `:any`. Passing it is what distinguishes "my token
  really is stale" from "somebody already replaced it while I was queued", and
  it is why a burst of concurrent 401s costs one sign-in rather than one each.
  """
  @spec renew_token(t(), :any | integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def renew_token(conn, minted_before) do
    timeout = config(conn).call_timeout

    try do
      GenServer.call(conn, {:renew_token, minted_before}, timeout)
    catch
      :exit, {:timeout, {GenServer, :call, _}} ->
        {:error,
         Error.new(:timeout, "renewing the access token on #{inspect(conn)} took longer than #{timeout}ms")}

      :exit, {_reason, {GenServer, :call, _}} ->
        reraise not_running(conn), __STACKTRACE__
    end
  end

  @doc """
  Metadata carrying a usable token, for a unary call or a transaction stream.
  """
  @spec metadata(t()) :: {:ok, map(), integer()} | {:error, Error.t()}
  def metadata(conn) do
    with {:ok, token} <- token(conn) do
      {:ok, %{"authorization" => "Bearer " <> token}, System.monotonic_time(:millisecond)}
    end
  end

  @doc """
  Runs `fun` with fresh metadata, renewing the token once if the call comes back
  unauthenticated.

  One retry, not a loop: a token this connection has just minted being rejected
  means the credentials or the clock are wrong, and going round again would only
  spend another round trip discovering the same thing.
  """
  @spec authenticated(t(), (map() -> {:ok, term()} | {:error, Error.t()})) ::
          {:ok, term()} | {:error, Error.t()}
  def authenticated(conn, fun) when is_function(fun, 1) do
    with {:ok, md, minted_at} <- metadata(conn) do
      case fun.(md) do
        {:error, %Error{kind: :unauthenticated}} = rejected -> retry_once(conn, fun, minted_at, rejected)
        result -> result
      end
    end
  end

  defp retry_once(conn, fun, minted_at, rejected) do
    case renew_token(conn, minted_at) do
      {:ok, token} -> fun.(%{"authorization" => "Bearer " <> token})
      # The renewal failed for its own reason, but what the caller asked about
      # is the call — so it gets the call's rejection, not the renewal's.
      {:error, _} -> rejected
    end
  end

  @doc """
  Performs a unary RPC, converting failures into `%TypeDB.Error{}`.

  `context` names the operation for the message when the server supplies
  nothing better.
  """
  @spec unary(t(), (channel(), map() -> {:ok, term()} | {:error, term()}), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def unary(conn, call, context, span_metadata \\ []) when is_function(call, 2) do
    metadata = span_metadata |> Map.new() |> Map.put(:connection, conn)

    Telemetry.span_operation(metadata, fn ->
      result = do_unary(conn, call, context)
      {result, Map.merge(metadata, error_metadata(result))}
    end)
  end

  defp error_metadata({:error, %Error{} = error}), do: %{error: error}
  defp error_metadata(_), do: %{}

  defp do_unary(conn, call, context) do
    channel = channel(conn)

    authenticated(conn, fn md ->
      case safe_call(call, channel, md, context) do
        {:ok, reply} -> {:ok, reply}
        {:error, %GRPC.RPCError{} = error} -> {:error, GRPCError.from_rpc_error(error, context)}
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, GRPCError.from_reason(reason, context)}
      end
    end)
  end

  # The adapter talks to gun through a `GenServer.call`, so a channel whose
  # connection process has gone — this connection stopped, the supervisor
  # restarted it, the server dropped the socket — reaches the caller as an exit
  # rather than as a return value. An application asking this driver for a list
  # of databases should get an error it can match on, not an exit signal from a
  # process it has never heard of.
  defp safe_call(call, channel, md, context) do
    call.(channel, md)
  catch
    :exit, reason ->
      {:error,
       Error.new(:transport, "#{context}: the gRPC channel is gone (#{inspect(reason, limit: 3)})",
         reason: reason
       )}
  end

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    warn_if_plaintext(config)

    case connect(config) do
      {:ok, channel} ->
        table = :ets.new(config.name, [:named_table, :protected, :set, read_concurrency: true])

        # The published copy carries no credentials: every process in the VM can
        # read this table, which is the point, and a password should not be one
        # `:ets.lookup/2` away.
        :ets.insert(table, [{@config_key, redact(config)}, {@channel_key, channel}])

        state = %{config: config, table: table, channel: channel, connection_id: nil}
        {:ok, cache_static_token(state)}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call({:renew_token, minted_before}, _from, state) do
    case :ets.lookup(state.table, @token_key) do
      # Somebody else already replaced the token this caller was holding.
      [{@token_key, token, deadline}] when minted_before != :any ->
        if minted_before < deadline - @renewal_margin_ms or usable?(deadline) do
          {:reply, {:ok, token}, state}
        else
          sign_in_and_reply(state)
        end

      _ ->
        sign_in_and_reply(state)
    end
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{channel: channel}) do
    _ = GRPC.Stub.disconnect(channel)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Said once per connection, at start-up, and only for a server that is not on
  # this machine. The default is not changed: it matches TypeDB CE's own, and a
  # driver that refused to connect the way the server ships would be wrong more
  # often than right. What it must not do is stay quiet while a password crosses
  # a network — Audit VI, VI-8.
  defp warn_if_plaintext(%Config{} = config) do
    if Config.plaintext_to_remote?(config) do
      Logger.warning(
        "TypeDB.GRPC is connecting to #{config.address} without TLS, so the username and " <>
          "password will cross the network in clear text. Pass `tls: true` — and `:tls_root_ca` " <>
          "if the server's certificate comes from a private CA. If the server has no encryption " <>
          "enabled, this is the only place that will be said.",
        typedb_connection: config.name
      )
    end

    :ok
  end

  defp connect(%Config{} = config) do
    adapter_opts = [retry: config.connect_retries, connect_timeout: config.connect_timeout]

    with {:ok, credential} <- credential(config) do
      case GRPC.Stub.connect(config.address, [adapter_opts: adapter_opts] ++ credential) do
        {:ok, channel} ->
          {:ok, channel}

        {:error, reason} ->
          {:error,
           Error.new(
             :transport,
             "could not open a gRPC channel to #{config.address}: #{inspect(reason)}",
             reason: reason
           )}
      end
    end
  end

  # `GRPC.Credential.new(ssl: opts)` hands `opts` straight to `:ssl`, whose
  # default is `verify_peer` — so a connection to a server this machine does not
  # trust fails rather than succeeding quietly. Measured against a TypeDB with a
  # self-signed certificate: without a trusted CA the handshake ends in
  # `Unknown CA`, and it takes one or an explicit `verify_none` to get through.
  # That posture is pinned by the TLS suite.
  #
  # Which CAs those are is `Config.ssl_options/1`'s business, including reading
  # the machine's trust store when nothing more specific was configured.
  defp credential(%Config{tls: false}), do: {:ok, []}

  defp credential(%Config{} = config) do
    with {:ok, ssl_opts} <- Config.ssl_options(config) do
      {:ok, [cred: GRPC.Credential.new(ssl: ssl_opts)]}
    end
  end

  defp sign_in_and_reply(state) do
    case sign_in(state) do
      {:ok, token, deadline, state} ->
        :ets.insert(state.table, {@token_key, token, deadline})
        {:reply, {:ok, token}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp sign_in(%{config: config} = state) do
    Telemetry.span_sign_in(%{connection: config.name}, fn ->
      case do_sign_in(state) do
        {:ok, _token, _deadline, _state} = ok -> {ok, %{connection: config.name}}
        {:error, error} = failed -> {failed, %{connection: config.name, error: error}}
      end
    end)
  end

  # A connection configured with a pre-issued token has nothing to sign in with,
  # so the expiry of that token is the caller's problem and surfaces as an
  # authentication failure rather than as a renewal that cannot happen.
  defp do_sign_in(%{config: %Config{static_token: token}}) when is_binary(token) do
    {:error,
     Error.new(
       :unauthenticated,
       "the token this connection was configured with was rejected, and there are no " <>
         "credentials to mint another — configure :username and :password to renew automatically"
     )}
  end

  # The first sign-in is a `connection_open`, which is the RPC every official
  # driver makes first and this one used to skip. It costs no extra round trip
  # — the open carries the token that `authentication_token_create` would have
  # returned — and it buys two things a bare token call does not:
  #
  #   * the server sees the protocol version, the driver's language and its
  #     version, so an incompatible driver is refused *by the server*, at the
  #     connection, rather than surfacing later as something that failed to
  #     decode. `TypeDB.GRPC.Server.check_protocol/2` predates this and is a
  #     client-side approximation of it;
  #   * a connection id, which is what ties this side's logs to that side's.
  #
  # The response also carries the cluster's server list. It is deliberately not
  # cached: `TypeDB.GRPC.Server.servers/2` asks, and a list captured at open
  # would be a snapshot that goes stale silently.
  defp do_sign_in(%{connection_id: nil, config: config, channel: channel} = state) do
    request = %Proto.Connection.Open.Req{
      version: :VERSION,
      extension_version: :EXTENSION,
      driver_lang: @driver_lang,
      driver_version: @driver_version,
      authentication: token_request(config)
    }

    case Proto.TypeDB.Stub.connection_open(channel, request, timeout: config.timeout) do
      {:ok, %Proto.Connection.Open.Res{authentication: %{token: token}} = res} ->
        id = connection_id_of(res.connection_id)
        if id, do: :ets.insert(state.table, {@connection_id_key, id})
        {:ok, token, deadline_for(token), %{state | connection_id: id}}

      {:ok, other} ->
        {:error, Error.new(:decode, "opening the connection returned no token: #{inspect(other, limit: 5)}")}

      {:error, error} ->
        {:error, open_error(error, config)}
    end
  end

  # Renewals go back to the plain token call: the connection is already open,
  # and re-opening it would mint a second one server-side. This is what the
  # official drivers do too — open once, renew many times.
  defp do_sign_in(%{config: config, channel: channel} = state) do
    request = token_request(config)

    case Proto.TypeDB.Stub.authentication_token_create(channel, request, timeout: config.timeout) do
      {:ok, %{token: token}} ->
        {:ok, token, deadline_for(token), state}

      {:error, %GRPC.RPCError{} = error} ->
        {:error, GRPCError.from_rpc_error(error, "signing in as #{inspect(config.username)}")}

      {:error, reason} ->
        {:error, GRPCError.from_reason(reason, "signing in as #{inspect(config.username)}")}
    end
  end

  defp token_request(config) do
    %Proto.Authentication.Token.Create.Req{
      credentials:
        {:password,
         %Proto.Authentication.Token.Create.Req.Password{
           username: config.username,
           password: config.password
         }}
    }
  end

  defp open_error(%GRPC.RPCError{} = error, config) do
    GRPCError.from_rpc_error(error, "opening a connection as #{inspect(config.username)}")
  end

  defp open_error(reason, config) do
    GRPCError.from_reason(reason, "opening a connection as #{inspect(config.username)}")
  end

  # The server sends sixteen bytes and means a UUID by them, so this renders the
  # UUID — the same text the server's own log carries, which is the only reason
  # to hand a caller an id at all. Anything else is hex, because guessing at a
  # shape the server did not send would be worse than showing the bytes.
  defp connection_id_of(%Proto.ConnectionID{id: <<a::32, b::16, c::16, d::16, e::48>>}) do
    [
      Integer.to_string(a, 16),
      Integer.to_string(b, 16),
      Integer.to_string(c, 16),
      Integer.to_string(d, 16),
      Integer.to_string(e, 16)
    ]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} -> String.pad_leading(part, width, "0") end)
    |> String.downcase()
  end

  defp connection_id_of(%Proto.ConnectionID{id: id}) when is_binary(id) and byte_size(id) > 0 do
    Base.encode16(id, case: :lower)
  end

  defp connection_id_of(_), do: nil

  defp cache_static_token(%{config: %Config{static_token: token}} = state) when is_binary(token) do
    :ets.insert(state.table, {@token_key, token, deadline_for(token)})
    state
  end

  defp cache_static_token(state), do: state

  # `TypeDB.Token` is `@moduledoc false` in the sibling package — internal on
  # purpose, because when to renew is not a promise it wants to make. Using it
  # across the package boundary is a deliberate choice of this monorepo over a
  # second copy of the same JWT reading, and it is held in place by a test:
  # test/typedb/grpc/token_contract_test.exs fails here if that module's
  # behaviour moves, rather than letting this driver quietly stop renewing.
  defp deadline_for(token) do
    case TypeDB.Token.lifetime_ms(token) do
      :unknown ->
        # Nothing to be proactive about; renew reactively when a call is
        # rejected. Always correct, one round trip slower.
        :unknown

      lifetime ->
        margin = min(@renewal_margin_ms, div(lifetime, 4))
        System.monotonic_time(:millisecond) + lifetime - margin
    end
  end

  defp usable?(:unknown), do: true
  defp usable?(deadline), do: System.monotonic_time(:millisecond) < deadline

  defp redact(%Config{} = config), do: %{config | password: nil, static_token: nil}

  defp lookup!(conn, key) do
    case :ets.lookup(conn, key) do
      [{^key, value}] -> value
      [] -> raise not_running(conn)
    end
  rescue
    ArgumentError -> reraise not_running(conn), __STACKTRACE__
  end

  defp not_running(conn) do
    Error.new(
      :config,
      "TypeDB gRPC connection #{inspect(conn)} is not running. Either it was never " <>
        "started — add {TypeDB.GRPC, name: #{inspect(conn)}, ...} to your supervision " <>
        "tree — or it went down and has not been restarted yet."
    )
  end
end
