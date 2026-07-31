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
      `{TypeDB.HTTP.Httpc, []}`.
    * `:max_retries` — how many times to retry *idempotent* requests after a
      transport failure. Defaults to `1`.
    * `:max_auth_renewals` — how many times a single request will renew its
      token and retry after a `401`. Defaults to `2`; more than one matters only
      when a burst of requests is wide enough for the freshly minted token to
      expire before every one of them has used it.
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
          retry_backoff: {:exponential, pos_integer()} | (pos_integer() -> non_neg_integer())
        }

  # Credentials must not reach logs, crash reports or LiveDashboard through an
  # incidental inspect of the config or the connection's state.
  @derive {Inspect, except: [:password, :static_token]}
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
    with {:ok, base_url} <- parse_url(Keyword.get(opts, :url, @default_url)),
         {:ok, name} <- parse_name(Keyword.get(opts, :name, TypeDB)),
         {:ok, {username, password, token}} <- parse_credentials(opts),
         {:ok, {adapter, adapter_opts}} <- parse_http(Keyword.get(opts, :http, {TypeDB.HTTP.Httpc, []})),
         {:ok, backoff} <- parse_backoff(Keyword.get(opts, :retry_backoff, {:exponential, 100})) do
      {:ok,
       %__MODULE__{
         base_url: base_url,
         username: username,
         password: password,
         static_token: token,
         name: name,
         timeout: Keyword.get(opts, :timeout, @default_timeout),
         connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout),
         http_adapter: adapter,
         http_opts: adapter_opts,
         max_retries: Keyword.get(opts, :max_retries, 1),
         max_auth_renewals: Keyword.get(opts, :max_auth_renewals, 2),
         retry_backoff: backoff
       }}
    end
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

  def backoff(%__MODULE__{retry_backoff: fun}, attempt) when is_function(fun, 1) do
    fun.(attempt)
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

  defp parse_absolute_url(candidate, original) do
    uri = URI.parse(candidate)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, "#{uri.scheme}://#{uri.host}#{port_suffix(uri)}#{trim_path(uri.path)}"}
    else
      {:error, config_error("invalid :url #{inspect(original)}, expected an http(s) URL")}
    end
  end

  defp port_suffix(%URI{port: nil}), do: ""
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
