defmodule TypeDB.GRPC.Config do
  @moduledoc """
  A connection's settings, validated once at start-up.

  Deliberately smaller than `TypeDB.Config`. That one carries a transport
  choice, a JSON codec, a retry policy and a status list, because the HTTP
  driver has three interchangeable adapters and retries requests itself. Here
  there is one transport, and a request lives on a transaction stream whose
  failure destroys the transaction — so there is nothing a per-request retry
  could correctly re-send.
  """

  alias TypeDB.Error

  @type t :: %__MODULE__{
          name: atom(),
          address: String.t(),
          username: String.t(),
          password: String.t() | nil,
          static_token: String.t() | nil,
          tls: boolean(),
          tls_opts: keyword(),
          timeout: timeout(),
          call_timeout: timeout(),
          connect_timeout: timeout(),
          connect_retries: non_neg_integer()
        }

  @enforce_keys [:name, :address]
  defstruct [
    :name,
    :address,
    :username,
    :password,
    :static_token,
    tls: false,
    tls_opts: [],
    timeout: 60_000,
    call_timeout: 30_000,
    connect_timeout: 10_000,
    connect_retries: 0
  ]

  @keys ~w(name address url username password token tls tls_opts timeout call_timeout connect_timeout connect_retries)a

  @doc """
  Builds a config from `start_link/1` options.

  ## Options

    * `:name` — the registered name, required; it is also the ETS table
    * `:address` — `"host:port"`, TypeDB's gRPC port being 1729. `:url` is
      accepted as a synonym and parsed, so the same configuration that feeds the
      HTTP driver can feed this one
    * `:username` / `:password` — credentials to sign in with
    * `:token` — a pre-issued token, instead of credentials. Nothing renews it
    * `:tls` / `:tls_opts` — TLS for the channel
    * `:timeout` — per-call timeout in ms, default 60 s
    * `:call_timeout` — how long to wait on the connection process itself when
      it has to mint a token, default 30 s. Worth knowing because a per-call
      `:timeout` does not cover it: the first call on a connection signs in
      first, and that wait is bounded by this rather than by the option the
      caller passed
    * `:connect_timeout` — how long to wait for the channel to come up, default
      10 s, matching `TypeDB.Config`. It bounds the case a retry count cannot:
      a plaintext client against a TLS port completes its TCP connection and
      then waits, because the server is waiting for a handshake that will never
      arrive. Without this the wait is minutes
    * `:connect_retries` — how many times the transport retries establishing the
      channel, default `0`. The adapter's own default is 100, which turns a
      wrong CA or a wrong port into a wait of tens of seconds ending in
      `:timeout` — a failure that reads as "the server is slow" when it is
      really "this will never work". Raise it for a server that is expected to
      come up after the application does
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with :ok <- check_keys(opts),
         {:ok, name} <- fetch_name(opts),
         {:ok, address} <- fetch_address(opts),
         {:ok, credentials} <- fetch_credentials(opts),
         {:ok, timeout} <- fetch_timeout(opts, :timeout, 60_000),
         {:ok, call_timeout} <- fetch_timeout(opts, :call_timeout, 30_000),
         {:ok, connect_timeout} <- fetch_timeout(opts, :connect_timeout, 10_000),
         {:ok, connect_retries} <- fetch_retries(opts) do
      {username, password, token} = credentials

      {:ok,
       %__MODULE__{
         name: name,
         address: address,
         username: username,
         password: password,
         static_token: token,
         tls: Keyword.get(opts, :tls, false),
         tls_opts: Keyword.get(opts, :tls_opts, []),
         timeout: timeout,
         call_timeout: call_timeout,
         connect_timeout: connect_timeout,
         connect_retries: connect_retries
       }}
    end
  end

  @doc "Builds a config, raising on invalid options."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  defp check_keys(opts) do
    case Enum.reject(Keyword.keys(opts), &(&1 in @keys)) do
      [] ->
        :ok

      unknown ->
        error(
          "unknown option#{if length(unknown) > 1, do: "s"} #{inspect(unknown)}, expected one of #{inspect(@keys)}"
        )
    end
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) and not is_nil(name) -> {:ok, name}
      {:ok, other} -> error("invalid :name #{inspect(other)}, expected an atom")
      :error -> error("missing required option :name")
    end
  end

  # A `:url` is accepted so that one configuration block can feed both drivers,
  # but the ports differ — 8000 for HTTP, 1729 for gRPC — so a URL that carries
  # a port keeps it and one that does not gets TypeDB's gRPC default rather than
  # the scheme's.
  defp fetch_address(opts) do
    case {Keyword.fetch(opts, :address), Keyword.fetch(opts, :url)} do
      {{:ok, address}, _} when is_binary(address) -> validate_address(address)
      {{:ok, other}, _} -> error("invalid :address #{inspect(other)}, expected \"host:port\"")
      {:error, {:ok, url}} when is_binary(url) -> from_url(url)
      {:error, {:ok, other}} -> error("invalid :url #{inspect(other)}, expected a string")
      {:error, :error} -> error("missing required option :address (or :url)")
    end
  end

  defp validate_address(address) do
    case String.split(address, ":") do
      [host, port] when host != "" ->
        case Integer.parse(port) do
          {n, ""} when n > 0 and n < 65_536 -> {:ok, address}
          _ -> error("invalid port in :address #{inspect(address)}")
        end

      _ ->
        error("invalid :address #{inspect(address)}, expected \"host:port\"")
    end
  end

  defp from_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        %URI{port: port} = uri = URI.parse(url)
        {:ok, "#{uri.host}:#{grpc_port(port, url)}"}

      _ ->
        error("invalid :url #{inspect(url)}, expected something like \"http://localhost:1729\"")
    end
  end

  # URI.parse fills in the scheme's default port when the URL carries none, so
  # 80 and 443 mean "the caller said nothing about a port" rather than "the
  # caller wants TypeDB on 80".
  defp grpc_port(port, url) when port in [80, 443] do
    if String.contains?(url, ":#{port}"), do: port, else: 1729
  end

  defp grpc_port(nil, _url), do: 1729
  defp grpc_port(port, _url), do: port

  defp fetch_credentials(opts) do
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)
    token = Keyword.get(opts, :token)

    cond do
      is_binary(token) ->
        {:ok, {username, password, token}}

      is_binary(username) and is_binary(password) ->
        {:ok, {username, password, nil}}

      is_binary(username) or is_binary(password) ->
        error("both :username and :password are needed to sign in, or a :token instead")

      true ->
        error("missing credentials: give :username and :password, or a :token")
    end
  end

  defp fetch_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :infinity -> {:ok, :infinity}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> error("invalid #{inspect(key)} #{inspect(other)}, expected a positive integer or :infinity")
    end
  end

  defp fetch_retries(opts) do
    case Keyword.get(opts, :connect_retries, 0) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      other -> error("invalid :connect_retries #{inspect(other)}, expected a non-negative integer")
    end
  end

  defp error(message) do
    {:error, Error.new(:config, message)}
  end

  defimpl Inspect do
    import Inspect.Algebra

    # Never render the password. The sibling driver learned this the same way
    # everybody does: a config in a crash report is a config in a log.
    def inspect(config, opts) do
      fields = [
        address: config.address,
        username: config.username,
        name: config.name,
        tls: config.tls,
        timeout: config.timeout
      ]

      concat(["#TypeDB.GRPC.Config<", to_doc(fields, opts), ">"])
    end
  end
end
