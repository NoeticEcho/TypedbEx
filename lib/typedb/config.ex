defmodule TypeDB.Config do
  @moduledoc """
  Validated connection configuration.

  You normally never build this yourself — pass the options below to
  `TypeDB.start_link/1` and they are validated into a `%TypeDB.Config{}`.

  ## Options

    * `:url` — server URL, e.g. `"http://localhost:8000"`. A bare
      `"host:port"` or `"host"` is accepted and defaults to `http`.
      Defaults to `"http://localhost:8000"`.
    * `:username` / `:password` — credentials used against `POST /v1/signin`.
      Required unless `:token` is given.
    * `:token` — a pre-issued bearer token, used instead of signing in. When the
      token expires it cannot be renewed, so prefer credentials for long-lived
      connections.
    * `:name` — registered name of the connection process. Defaults to `TypeDB`.
    * `:timeout` — per-request receive timeout in ms. Defaults to `60_000`.
    * `:connect_timeout` — TCP/TLS connect timeout in ms. Defaults to `10_000`.
    * `:http` — `{adapter_module, adapter_opts}`. Defaults to
      `{TypeDB.HTTP.Finch, []}`. See `TypeDB.HTTP` for the alternatives and why
      this is the default.
    * `:max_retries` — how many times to retry a request that is safe to
      re-send, after a transport failure, a timeout or a status in
      `:retry_on_status`. Defaults to `1`.

      Safety is decided per operation, not per HTTP method: reads, `analyze`,
      `rollback`, `close`, `Database.create/2` and `User.set_password/3` are
      retried; writes, schema changes, `commit` and `User.create/3` are not.
    * `:max_auth_renewals` — how many times a single request will renew its
      token and retry after a `401`. Defaults to `2`; more than one matters only
      when a burst of requests is wide enough for the freshly minted token to
      expire before every one of them has used it.
    * `:answer_count_limit` — how many answers a query may materialise, applied
      unless the query passes its own. Unset by default, which means TypeDB's
      own default of **10,000 answers per read** applies: a bigger `match` comes
      back truncated with a warning attached rather than failing. Set this to
      raise that ceiling for every query on the connection, or to lower it —
      the HTTP API is not streaming, so an unbounded `match` is materialised
      whole at both ends.
    * `:retry_backoff` — either `{:exponential, base_ms}` or a
      `(attempt -> ms)` function. Defaults to `{:exponential, 100}`.
      The `{:exponential, _}` form is **jittered**: the delay before retry `n`
      is drawn uniformly from `0..base_ms * 2 ** (n - 1)`, so that callers who
      failed together do not retry together. Pass a function when you need a
      delay you can predict.
    * `:retry_max_delay` — the ceiling on any single backoff, in ms, whichever
      form produced it. Defaults to `5_000`; `:infinity` opts out. Exponential
      growth is otherwise unbounded, and the sleep happens in the calling
      process — with `max_retries: 10` and the default base, the last wait would
      be over fifty seconds.
    * `:retry_on_status` — response statuses to treat as retryable, in addition
      to transport failures and timeouts. Defaults to `[429, 502, 503, 504]`;
      `[]` opts out. These are what a proxy, an ingress or a load balancer
      answers while TypeDB restarts, and what the server answers when it is
      shedding load — the failures retrying exists for. A `retry-after` header
      is honoured when it carries a number of seconds, still bounded by
      `:retry_max_delay`. The same idempotence rule applies as to any other
      retry, so a write is never re-sent.
    * `:log_level` — the quietest level this connection will log at, one of
      `:debug`, `:info`, `:warning`, `:error` or `:none`. Defaults to `:debug`,
      which logs everything the driver has to say; `:none` silences it.
      A library that cannot be turned down gets turned off, and filtering the
      global Logger by module is a blunt instrument when an application has
      several connections. See the "Logging" section of `TypeDB` for every line
      the driver can emit.
    * `:deadline` — a wall-clock budget in ms for a whole call, across every
      retry and every wait between them. Defaults to `:infinity`.

      `:timeout` bounds one attempt; this bounds the operation. Without it a
      caller who asks for `timeout: 5_000` can still block for
      `5_000 * (max_retries + 1)` plus the backoffs, because each retry gets the
      full timeout again. Each attempt is given whichever is smaller, its own
      timeout or the budget that is left, and a retry that could not finish
      inside the budget is not started.

      **It cannot cut short a connect that is already blocking.** The budget is
      enforced between attempts and by shortening each attempt's `:timeout`,
      which is the *receive* timeout; opening the socket is bounded by
      `:connect_timeout` alone. So a call to a host that accepts nothing —
      a black-holed address, a dropped route — can outlive its `:deadline` by up
      to one `:connect_timeout`. Size the two together. Making this exact would
      mean deriving the connect timeout per request, which `TypeDB.HTTP.Finch`
      cannot do: Mint reads it from the pool, and the pool is built once.

  ## Reading configuration from the environment

      TypeDB.start_link(
        url: System.fetch_env!("TYPEDB_URL"),
        username: System.fetch_env!("TYPEDB_USERNAME"),
        password: System.fetch_env!("TYPEDB_PASSWORD")
      )
  """

  @api_version "v1"

  @default_url "http://localhost:8000"
  @default_timeout :timer.seconds(60)
  @default_connect_timeout :timer.seconds(10)
  @default_retry_max_delay :timer.seconds(5)

  @type t :: %__MODULE__{
          base_url: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          static_token: String.t() | nil,
          name: atom(),
          timeout: timeout(),
          connect_timeout: timeout(),
          http_adapter: module(),
          http_opts: keyword(),
          max_retries: non_neg_integer(),
          max_auth_renewals: non_neg_integer(),
          answer_count_limit: pos_integer() | nil,
          retry_backoff: {:exponential, pos_integer()} | (pos_integer() -> non_neg_integer()),
          retry_max_delay: timeout(),
          retry_on_status: [pos_integer()],
          deadline: timeout(),
          log_level: atom()
        }

  # Credentials must not reach logs, crash reports or LiveDashboard through an
  # incidental inspect of the config or the connection's state.
  #
  # `:http_opts` is redacted wholesale rather than by key name: it is opaque
  # adapter data whose shape this driver does not own, and it is exactly where
  # `TypeDB.HTTP.Finch`'s own documentation tells users to put TLS material — a
  # mutual-TLS deployment puts the client private key and its passphrase there.
  # `:http_adapter` stays visible, and anyone who genuinely wants the options can
  # ask for them deliberately with `TypeDB.Connection.config/1`.
  @derive {Inspect, except: [:password, :static_token, :http_opts]}
  defstruct [
    :base_url,
    :username,
    :password,
    :static_token,
    :name,
    :timeout,
    :connect_timeout,
    :http_adapter,
    :http_opts,
    :max_retries,
    :max_auth_renewals,
    :answer_count_limit,
    :retry_backoff,
    :retry_max_delay,
    :retry_on_status,
    :deadline,
    :log_level
  ]

  @doc "The HTTP API version this driver speaks."
  @spec api_version() :: String.t()
  def api_version, do: @api_version

  @doc """
  Validates connection options.

  Returns `{:ok, config}` or `{:error, %TypeDB.Error{kind: :config}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, TypeDB.Error.t()}
  def new(opts) when is_list(opts) do
    with :ok <- reject_unknown(opts),
         {:ok, base_url} <- parse_url(Keyword.get(opts, :url, @default_url)),
         {:ok, name} <- parse_name(Keyword.get(opts, :name, TypeDB)),
         {:ok, {username, password, token}} <- parse_credentials(opts),
         {:ok, {adapter, adapter_opts}} <- parse_http(Keyword.get(opts, :http, {TypeDB.HTTP.Finch, []})),
         {:ok, backoff} <- parse_backoff(Keyword.get(opts, :retry_backoff, {:exponential, 100})),
         {:ok, timeout} <- parse_timeout(opts, :timeout, @default_timeout),
         {:ok, connect_timeout} <- parse_timeout(opts, :connect_timeout, @default_connect_timeout),
         {:ok, max_retries} <- parse_count(opts, :max_retries, 1),
         {:ok, max_auth_renewals} <- parse_count(opts, :max_auth_renewals, 2),
         {:ok, answer_count_limit} <- parse_limit(opts, :answer_count_limit),
         {:ok, retry_max_delay} <- parse_timeout(opts, :retry_max_delay, @default_retry_max_delay),
         {:ok, retry_on_status} <- parse_statuses(opts, :retry_on_status),
         {:ok, deadline} <- parse_timeout(opts, :deadline, :infinity),
         {:ok, log_level} <- parse_log_level(opts) do
      {:ok,
       %__MODULE__{
         base_url: base_url,
         username: username,
         password: password,
         static_token: token,
         name: name,
         timeout: timeout,
         connect_timeout: connect_timeout,
         http_adapter: adapter,
         http_opts: adapter_opts,
         max_retries: max_retries,
         max_auth_renewals: max_auth_renewals,
         answer_count_limit: answer_count_limit,
         retry_backoff: backoff,
         retry_max_delay: retry_max_delay,
         retry_on_status: retry_on_status,
         deadline: deadline,
         log_level: log_level
       }}
    end
  end

  @known_opts [
    :url,
    :username,
    :password,
    :token,
    :name,
    :timeout,
    :connect_timeout,
    :http,
    :max_retries,
    :max_auth_renewals,
    :answer_count_limit,
    :retry_backoff,
    :retry_max_delay,
    :retry_on_status,
    :deadline,
    :log_level
  ]

  @doc """
  The option keys `new/1` accepts. Anything else is rejected.
  """
  @spec known_options() :: [atom()]
  def known_options, do: @known_opts

  # A misspelled option used to be accepted in silence and the default applied,
  # so `timout: 5_000` produced a connection that looked configured and was not.
  # This function exists to reject bad configuration, and a key it has never
  # heard of is bad configuration.
  defp reject_unknown(opts) do
    case Keyword.keys(opts) -- @known_opts do
      [] ->
        :ok

      unknown ->
        {:error,
         config_error(
           "unknown option#{if length(unknown) > 1, do: "s"} " <>
             "#{Enum.map_join(unknown, ", ", &inspect/1)}. " <>
             "Accepted: #{Enum.map_join(@known_opts, ", ", &inspect/1)}."
         )}
    end
  end

  # The numeric options went through a bare `Keyword.get/3`, so a string from
  # `System.get_env/1` — the usual way these arrive — booted a green application
  # that then failed every single request, deep inside the HTTP adapter, with a
  # message naming Finch and `:prim_inet` rather than the typo.
  defp parse_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      :infinity -> {:ok, :infinity}
      other -> {:error, numeric_error(key, other, "a positive integer in milliseconds, or :infinity")}
    end
  end

  defp parse_count(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      other -> {:error, numeric_error(key, other, "a non-negative integer")}
    end
  end

  defp parse_statuses(opts, key) do
    case Keyword.get(opts, key, TypeDB.Error.retryable_statuses()) do
      statuses when is_list(statuses) ->
        if Enum.all?(statuses, &(is_integer(&1) and &1 in 100..599)) do
          {:ok, statuses}
        else
          {:error, numeric_error(key, statuses, "a list of HTTP status codes")}
        end

      other ->
        {:error, numeric_error(key, other, "a list of HTTP status codes")}
    end
  end

  defp parse_log_level(opts) do
    case Keyword.get(opts, :log_level, :debug) do
      level when is_atom(level) ->
        if level in TypeDB.Log.levels() do
          {:ok, level}
        else
          {:error, numeric_error(:log_level, level, "one of #{inspect(TypeDB.Log.levels())}")}
        end

      other ->
        {:error, numeric_error(:log_level, other, "one of #{inspect(TypeDB.Log.levels())}")}
    end
  end

  defp parse_limit(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, numeric_error(key, other, "a positive integer, or unset")}
    end
  end

  defp numeric_error(key, value, expected) do
    config_error("invalid #{inspect(key)} #{inspect(value)}, expected #{expected}")
  end

  @doc """
  Same as `new/1` but raises `TypeDB.Error` on invalid options.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Builds the absolute URL for a versioned API path.

      iex> config = TypeDB.Config.new!(url: "http://localhost:8000", token: "t")
      iex> TypeDB.Config.url(config, "/databases/social")
      "http://localhost:8000/v1/databases/social"
  """
  @spec url(t(), String.t()) :: String.t()
  def url(%__MODULE__{base_url: base}, "/" <> _ = path), do: base <> "/" <> @api_version <> path

  @doc """
  Builds the absolute URL for an unversioned API path, such as `/health`.
  """
  @spec raw_url(t(), String.t()) :: String.t()
  def raw_url(%__MODULE__{base_url: base}, "/" <> _ = path), do: base <> path

  @doc """
  Computes the backoff delay, in milliseconds, before retry `attempt` (1-based).

  `{:exponential, base}` is jittered: the delay is drawn uniformly from
  `0..base * 2 ** (attempt - 1)`. A function is used as it returns. Either way
  the result is capped by `:retry_max_delay`.
  """
  @spec backoff(t(), pos_integer()) :: non_neg_integer()
  def backoff(%__MODULE__{retry_backoff: {:exponential, base}} = config, attempt) do
    base |> exponential(attempt) |> cap(config.retry_max_delay) |> jitter()
  end

  # `parse_backoff` can only check the arity of a function, so the value it
  # returns is checked here, at the one place it is used. `Transport` hands it
  # straight to `Process.sleep/1`, which is a BIF that takes a non-negative
  # integer and nothing else — so without this, a typo in a documented option
  # raises FunctionClauseError in the *caller's* process, outside `contain/3`,
  # and escapes as a bare exception rather than a `%TypeDB.Error{}`.
  def backoff(%__MODULE__{retry_backoff: fun} = config, attempt) when is_function(fun, 1) do
    case fun.(attempt) do
      delay when is_integer(delay) and delay >= 0 ->
        cap(delay, config.retry_max_delay)

      other ->
        raise TypeDB.Error.new(
                :config,
                ":retry_backoff returned #{inspect(other)} for attempt #{attempt}, " <>
                  "but it must return a non-negative integer number of milliseconds"
              )
    end
  end

  # An integer shift rather than :math.pow/2, which loses precision above 2^53
  # and raises on the overflow to infinity. The exponent is clamped because
  # `attempt` is bounded only by :max_retries, and 1 <<< 100_000 is a twelve-
  # kilobyte integer computed only to be capped away. 2^63 ms is 300 million
  # years, so nothing below the clamp is reachable in practice either.
  defp exponential(base, attempt), do: base * Bitwise.bsl(1, min(attempt, 64) - 1)

  # `:retry_max_delay` is a ceiling on the delay, not on the growth: it is
  # applied to whatever produced the number, including a caller's own function,
  # so that one option answers "how long can this sleep for" completely.
  defp cap(delay, :infinity), do: delay
  defp cap(delay, max_delay), do: min(delay, max_delay)

  # Full jitter, drawn from 0..delay rather than centred on it.
  #
  # Without this, every caller that failed in the same instant — which is what a
  # server restart, a network blip or a rolling deploy produces — waits exactly
  # the same number of milliseconds and retries in lockstep, for as many attempts
  # as :max_retries allows. The driver then amplifies the outage it is meant to
  # ride out. Drawing from the whole interval is what AWS's own analysis found
  # best both for the number of clients in flight and for total work done, and it
  # is what Finch, Tesla and Oban do for the same reason.
  #
  # Anyone who needs a delay they can predict passes a function instead, which is
  # used verbatim; the test suite does exactly that.
  defp jitter(0), do: 0
  defp jitter(delay), do: :rand.uniform(delay + 1) - 1

  # Anything before "://" is a scheme. Note that URI.parse/1 reads
  # "localhost:8000" as scheme "localhost", so the scheme cannot be taken from
  # the parsed URI — it has to be detected first.
  @scheme_regex ~r{^[a-zA-Z][a-zA-Z0-9+.\-]*://}

  defp parse_url(url) when is_binary(url) do
    if Regex.match?(@scheme_regex, url) do
      parse_absolute_url(url, url)
    else
      parse_absolute_url("http://" <> url, url)
    end
  end

  defp parse_url(other) do
    {:error, config_error("invalid :url #{inspect(other)}, expected a string")}
  end

  # `URI.parse/1` never fails: it launders a mistyped port into the scheme's
  # default, mangles an unbalanced bracket into a plausible host and drops
  # embedded credentials without a word. This function exists to reject bad
  # configuration, so every one of those is an error instead.
  defp parse_absolute_url(candidate, original) do
    with {:ok, uri} <- parse_uri(candidate, original),
         :ok <- check_scheme_and_host(uri, original),
         :ok <- check_port(uri, original),
         :ok <- check_userinfo(uri, original) do
      {:ok, "#{uri.scheme}://#{host(uri)}#{port_suffix(uri)}#{trim_path(uri.path)}"}
    end
  end

  defp parse_uri(candidate, original) do
    case URI.new(candidate) do
      {:ok, uri} ->
        {:ok, uri}

      {:error, part} ->
        {:error,
         config_error(
           "invalid :url #{inspect(original)}: unexpected #{inspect(part)}. A port must be numeric, " <>
             "and a host must contain no spaces and no unbalanced brackets."
         )}
    end
  end

  defp check_scheme_and_host(uri, original) do
    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, config_error("invalid :url #{inspect(original)}, expected an http(s) URL")}
    end
  end

  defp check_port(%URI{port: port}, _original) when port in 1..65_535, do: :ok

  defp check_port(%URI{port: port}, original) do
    {:error, config_error("invalid :url #{inspect(original)}: port #{inspect(port)} is outside 1..65535")}
  end

  defp check_userinfo(%URI{userinfo: nil}, _original), do: :ok

  defp check_userinfo(%URI{}, original) do
    {:error,
     config_error(
       "invalid :url #{inspect(original)}: credentials must not be embedded in the URL, because " <>
         "TypeDB signs in over its own endpoint. Pass :username and :password instead."
     )}
  end

  # `URI` strips the brackets from an IPv6 literal, and putting the host back
  # without them yields an unusable "http://::1:8000".
  defp host(%URI{host: host}) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp port_suffix(%URI{scheme: "http", port: 80}), do: ""
  defp port_suffix(%URI{scheme: "https", port: 443}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"

  defp trim_path(nil), do: ""
  defp trim_path("/"), do: ""
  defp trim_path(path), do: String.trim_trailing(path, "/")

  defp parse_name(name) when is_atom(name) and not is_nil(name), do: {:ok, name}

  defp parse_name(other) do
    {:error,
     config_error(
       "invalid :name #{inspect(other)}. A connection must be registered under an atom name; " <>
         ":via and :global tuples are not supported because the driver keeps a named ETS table."
     )}
  end

  defp parse_credentials(opts) do
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)
    token = Keyword.get(opts, :token)

    cond do
      is_binary(token) ->
        {:ok, {username, password, token}}

      is_binary(username) and is_binary(password) ->
        {:ok, {username, password, nil}}

      true ->
        {:error, config_error("missing credentials: pass :username and :password, or a pre-issued :token")}
    end
  end

  defp parse_http({adapter, adapter_opts}) when is_atom(adapter) and is_list(adapter_opts) do
    check_adapter(adapter, adapter_opts)
  end

  defp parse_http(adapter) when is_atom(adapter), do: check_adapter(adapter, [])

  defp parse_http(other) do
    {:error, config_error("invalid :http #{inspect(other)}, expected {module, keyword}")}
  end

  # `:http` is the only option that names *code*, and it was the only one this
  # module did not check — `is_atom/1` accepts `nil`, a module that does not
  # exist and a module that is not an adapter alike. All three then failed at
  # `TypeDB.Connection.init/1` as `{:error, {:undef, …}}`, which names neither
  # the option nor the module, and is not the `%TypeDB.Error{kind: :config}` this
  # driver documents for a misconfigured connection.
  #
  # Only the required callbacks are demanded. `owner/1` and `terminate/1` are
  # optional and the connection already probes for them with
  # `function_exported?/3`.
  @required_adapter_callbacks [init: 2, request: 6]

  defp check_adapter(adapter, adapter_opts) do
    cond do
      not Code.ensure_loaded?(adapter) ->
        {:error,
         config_error(
           "invalid :http #{inspect(adapter)}, which could not be loaded as a module. " <>
             "Expected a module implementing the TypeDB.HTTP behaviour, such as " <>
             "TypeDB.HTTP.Finch, TypeDB.HTTP.Req or TypeDB.HTTP.Httpc."
         )}

      missing = missing_callbacks(adapter) ->
        {:error,
         config_error(
           "invalid :http #{inspect(adapter)}, which does not implement the TypeDB.HTTP " <>
             "behaviour: it is missing #{missing}."
         )}

      true ->
        {:ok, {adapter, adapter_opts}}
    end
  end

  defp missing_callbacks(adapter) do
    case Enum.reject(@required_adapter_callbacks, fn {fun, arity} ->
           function_exported?(adapter, fun, arity)
         end) do
      [] -> nil
      missing -> Enum.map_join(missing, " and ", fn {fun, arity} -> "#{fun}/#{arity}" end)
    end
  end

  defp parse_backoff({:exponential, base} = backoff) when is_integer(base) and base > 0, do: {:ok, backoff}
  defp parse_backoff(fun) when is_function(fun, 1), do: {:ok, fun}

  defp parse_backoff(other) do
    {:error,
     config_error(
       "invalid :retry_backoff #{inspect(other)}, expected {:exponential, ms} or a 1-arity function"
     )}
  end

  defp config_error(message), do: TypeDB.Error.new(:config, message)
end
