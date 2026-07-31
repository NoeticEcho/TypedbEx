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
    * `:max_retries` — how many times to retry *idempotent* requests after a
      transport failure. Defaults to `1`.
    * `:max_auth_renewals` — how many times a single request will renew its
      token and retry after a `401`. Defaults to `2`; more than one matters only
      when a burst of requests is wide enough for the freshly minted token to
      expire before every one of them has used it.
    * `:answer_count_limit` — a default cap on answers per query, applied unless
      the query passes its own. Unset by default. The HTTP API is not streaming
      and TypeDB does not cap results itself, so an unbounded `match` really does
      materialise the whole match set on the server and ship it; setting this
      once per connection is the cheap guard against that.
    * `:retry_backoff` — either `{:exponential, base_ms}` or a
      `(attempt -> ms)` function. Defaults to `{:exponential, 100}`.

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
          retry_backoff: {:exponential, pos_integer()} | (pos_integer() -> non_neg_integer())
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
    :retry_backoff
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
         {:ok, answer_count_limit} <- parse_limit(opts, :answer_count_limit) do
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
         retry_backoff: backoff
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
    :retry_backoff
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
  """
  @spec backoff(t(), pos_integer()) :: non_neg_integer()
  def backoff(%__MODULE__{retry_backoff: {:exponential, base}}, attempt) do
    trunc(base * :math.pow(2, attempt - 1))
  end

  # `parse_backoff` can only check the arity of a function, so the value it
  # returns is checked here, at the one place it is used. `Transport` hands it
  # straight to `Process.sleep/1`, which is a BIF that takes a non-negative
  # integer and nothing else — so without this, a typo in a documented option
  # raises FunctionClauseError in the *caller's* process, outside `contain/3`,
  # and escapes as a bare exception rather than a `%TypeDB.Error{}`.
  def backoff(%__MODULE__{retry_backoff: fun}, attempt) when is_function(fun, 1) do
    case fun.(attempt) do
      delay when is_integer(delay) and delay >= 0 ->
        delay

      other ->
        raise TypeDB.Error.new(
                :config,
                ":retry_backoff returned #{inspect(other)} for attempt #{attempt}, " <>
                  "but it must return a non-negative integer number of milliseconds"
              )
    end
  end

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
    {:ok, {adapter, adapter_opts}}
  end

  defp parse_http(adapter) when is_atom(adapter), do: {:ok, {adapter, []}}

  defp parse_http(other) do
    {:error, config_error("invalid :http #{inspect(other)}, expected {module, keyword}")}
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
