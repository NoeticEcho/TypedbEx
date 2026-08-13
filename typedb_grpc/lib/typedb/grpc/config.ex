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
          # Both are nil on a connection configured with a `:token` and nothing
          # else, which is what `TypeDB.GRPC.User.current/2` has to answer for.
          username: String.t() | nil,
          password: String.t() | nil,
          static_token: String.t() | nil,
          tls: boolean(),
          tls_root_ca: Path.t() | nil,
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
    :tls_root_ca,
    tls: false,
    tls_opts: [],
    timeout: 60_000,
    call_timeout: 30_000,
    connect_timeout: 10_000,
    connect_retries: 0
  ]

  @keys ~w(name address url username password token tls tls_root_ca tls_opts timeout call_timeout connect_timeout connect_retries)a

  @doc """
  Builds a config from `start_link/1` options.

  ## Options

    * `:name` — the registered name, required; it is also the ETS table
    * `:address` — `"host:port"`, TypeDB's gRPC port being 1729. `:url` is
      accepted as a synonym and parsed, so the same configuration that feeds the
      HTTP driver can feed this one
    * `:username` / `:password` — credentials to sign in with
    * `:token` — a pre-issued token, instead of credentials. Nothing renews it
    * `:tls` — TLS for the channel. With nothing else set, the certificate is
      verified against **this machine's trust store**, which is what makes
      `tls: true` enough for a server whose certificate a public CA signed. The
      option exists because `:ssl` does not do that on its own: `verify_peer`
      with no `cacerts` refuses every certificate, including good ones
    * `:tls_root_ca` — a PEM file to verify against instead of the machine's
      store, for a private CA. The counterpart of Rust's
      `DriverTlsConfig::enabled_with_root_ca/1`; checked at start-up, so a path
      that is not there fails the connection rather than the handshake
    * `:tls_opts` — options passed straight to `:ssl`, and the last word: what
      it sets is never overwritten by the two above. The escape hatch for
      client certificates, a pinned cipher list, or `verify: :verify_none`
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
         {:ok, connect_retries} <- fetch_retries(opts),
         {:ok, tls_root_ca} <- fetch_tls_root_ca(opts) do
      {username, password, token} = credentials

      {:ok,
       %__MODULE__{
         name: name,
         address: address,
         username: username,
         password: password,
         static_token: token,
         tls: Keyword.get(opts, :tls, false),
         tls_root_ca: tls_root_ca,
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

  @doc """
  The options this config hands to `:ssl`.

  Where `:tls`, `:tls_root_ca` and `:tls_opts` become one keyword list, and the
  place the machine's trust store is read. Separate from the struct on purpose:
  the store is a hundred and fifty certificates, and putting them in a struct
  that lives in ETS and gets inspected in error messages would be a poor trade
  for something `:ssl` wants once per connection.
  """
  @spec ssl_options(t()) :: {:ok, keyword()} | {:error, Error.t()}
  def ssl_options(%__MODULE__{tls: false}), do: {:ok, []}

  def ssl_options(%__MODULE__{tls_opts: opts} = config) do
    cond do
      # The caller said how to verify. Nothing here second-guesses that — it is
      # also how `verify: :verify_none` stays possible.
      trust_configured?(opts) -> {:ok, opts}
      is_binary(config.tls_root_ca) -> {:ok, Keyword.put(opts, :cacertfile, config.tls_root_ca)}
      true -> native_trust_store(opts)
    end
  end

  @doc """
  Whether this connection would send credentials in clear text to another
  machine.

  `tls: false` is the default and it is the right one for TypeDB CE, which ships
  with encryption off and is usually on the same host. It is the wrong one the
  moment the server is somewhere else, and nothing else in the driver is in a
  position to notice — Rust cannot have this problem because
  `DriverOptions::new/1` takes the TLS configuration as a required argument.

  So the default stays and `TypeDB.GRPC.Connection` says so once, at start-up,
  for an address that is not loopback.
  """
  @spec plaintext_to_remote?(t()) :: boolean()
  def plaintext_to_remote?(%__MODULE__{tls: true}), do: false
  def plaintext_to_remote?(%__MODULE__{address: address}), do: not loopback?(host(address))

  defp host(address), do: address |> String.split(":") |> hd()

  # The whole of 127.0.0.0/8, not just 127.0.0.1: `127.0.0.2` is as local as its
  # neighbour and a warning that fired on it would be noise.
  defp loopback?("localhost"), do: true
  defp loopback?("::1"), do: true
  defp loopback?("[::1]"), do: true
  defp loopback?("127." <> _), do: true
  defp loopback?(_host), do: false

  defp trust_configured?(opts) do
    Keyword.has_key?(opts, :cacerts) or Keyword.has_key?(opts, :cacertfile) or
      Keyword.get(opts, :verify) == :verify_none
  end

  # `:ssl` has no default trust store: `verify: :verify_peer` with no `cacerts`
  # fails against a certificate a public CA signed, which is measured rather
  # than assumed — see test/typedb/grpc/tls_options_test.exs. So this driver
  # supplies the store, which is what `tls: true` means everywhere else and what
  # Rust's `DriverTlsConfig::enabled_with_native_root_ca/0` does.
  defp native_trust_store(opts) do
    case :public_key.cacerts_get() do
      [] -> {:error, no_trust_store("it is empty")}
      certs -> {:ok, Keyword.put(opts, :cacerts, certs)}
    end
  rescue
    # `cacerts_get/0` raises rather than returning an error when the platform
    # has no store or it cannot be parsed.
    exception -> {:error, no_trust_store(Exception.message(exception))}
  end

  defp no_trust_store(why) do
    Error.new(
      :config,
      "tls: true verifies the server against this machine's trust store, and it could not be " <>
        "read (#{why}). Point :tls_root_ca at the CA's PEM file, or pass the store yourself " <>
        "through :tls_opts."
    )
  end

  defp fetch_tls_root_ca(opts) do
    case Keyword.fetch(opts, :tls_root_ca) do
      :error ->
        {:ok, nil}

      {:ok, path} when is_binary(path) ->
        # Checked now rather than at the handshake: a typo in a path is a
        # configuration mistake, and it should read as one.
        if File.regular?(path),
          do: {:ok, path},
          else: error("invalid :tls_root_ca #{inspect(path)}, no such file")

      {:ok, other} ->
        error("invalid :tls_root_ca #{inspect(other)}, expected a path to a PEM file")
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

  # Parsed once, and the port decided from the parsed URI rather than from a
  # substring of the raw string. The old version asked
  # `String.contains?(url, ":80")`, which matches a path segment, an IPv6 host
  # and userinfo just as happily as a port — Audit V, V-4.
  defp from_url(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        {:ok, "#{host}:#{grpc_port(uri, url)}"}

      _ ->
        error("invalid :url #{inspect(url)}, expected something like \"http://localhost:1729\"")
    end
  end

  # `URI.new/1` fills in the scheme's default port, so 80 and 443 have to be told
  # from a port the caller actually wrote — and the struct cannot say which it
  # was, since `http://h` and `http://h:80` parse identically and `:authority` is
  # deprecated and comes back nil.
  #
  # So the authority is taken from the string, but *only* the authority: the old
  # version asked `String.contains?(url, ":80")` and matched a path segment
  # (`http://h/a:80`), userinfo (`http://user:80@h`) and an IPv6 host just as
  # happily — Audit V, V-4.
  defp grpc_port(%URI{port: port}, url) when port in [80, 443] do
    if explicit_port?(url, port), do: port, else: 1729
  end

  defp grpc_port(%URI{port: nil}, _url), do: 1729
  defp grpc_port(%URI{port: port}, _url), do: port

  @authority ~r{^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/?#]*)}

  defp explicit_port?(url, port) do
    case Regex.run(@authority, url) do
      [_, authority] ->
        # Userinfo can contain a colon and a number of its own, so it goes first.
        authority
        |> String.split("@")
        |> List.last()
        |> String.ends_with?(":#{port}")

      _ ->
        false
    end
  end

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
