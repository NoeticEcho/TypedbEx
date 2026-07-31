defmodule TypeDB.HTTP.Httpc do
  @moduledoc """
  Default `TypeDB.HTTP` adapter, built on OTP's `:httpc`.

  Each connection gets its own `:httpc` profile, so connection pooling, keep-alive
  and socket limits are isolated from the rest of the application (and from other
  `TypeDB` connections).

  ## Options

    * `:profile` — profile name. Defaults to one derived from the connection name.
    * `:max_sessions` — max simultaneous sockets per host. Defaults to `50`.
    * `:max_keep_alive_length` — max requests queued per keep-alive socket.
      Defaults to `100`.
    * `:keep_alive_timeout` — idle keep-alive socket lifetime, ms. Defaults to
      `120_000`.
    * `:ssl` — TLS options passed to `:ssl`. Merged over the secure defaults
      below, so you only need to override what differs.
    * `:cacertfile` — convenience shortcut for a custom CA bundle path.

  ## TLS

  Certificate verification is **on** by default and cannot be disabled by
  accident: the defaults are `verify: :verify_peer`, the OS trust store via
  `:public_key.cacerts_get/0`, hostname checking via
  `:public_key.pkix_verify_hostname_match_fun(:https)`, and TLS 1.2/1.3.

  To pin a private CA:

      TypeDB.start_link(
        url: "https://typedb.internal:8000",
        http: {TypeDB.HTTP.Httpc, cacertfile: "/etc/ssl/private-ca.pem"}
      )
  """

  @behaviour TypeDB.HTTP

  require Logger

  @default_max_sessions 50
  @default_max_keep_alive_length 100
  @default_keep_alive_timeout :timer.minutes(2)

  defstruct [:profile, :ssl_opts]

  @type t :: %__MODULE__{profile: atom(), ssl_opts: keyword()}

  @impl true
  def init(name, opts) do
    profile = Keyword.get(opts, :profile) || :"#{name}.HTTP"

    with :ok <- start_profile(profile),
         :ok <- set_profile_options(profile, opts) do
      {:ok, %__MODULE__{profile: profile, ssl_opts: ssl_opts(opts)}}
    end
  end

  @impl true
  def owner(%__MODULE__{}), do: nil

  @impl true
  def terminate(%__MODULE__{profile: profile}) do
    _ = :inets.stop(:httpc, profile)
    :ok
  end

  @impl true
  def request(%__MODULE__{} = state, method, url, headers, body, opts) do
    http_opts = [
      timeout: Keyword.get(opts, :timeout, :infinity),
      connect_timeout: Keyword.get(opts, :connect_timeout, :infinity),
      autoredirect: false,
      ssl: state.ssl_opts
    ]

    request = build_request(method, url, headers, body)
    client_opts = [body_format: :binary, full_result: true]

    case :httpc.request(method, request, http_opts, client_opts, state.profile) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        {:ok,
         %{
           status: status,
           headers: normalise_headers(resp_headers),
           body: resp_body
         }}

      {:error, :timeout} ->
        {:error, TypeDB.Error.new(:timeout, "request to #{url} timed out", reason: :timeout)}

      # httpc buries a connect timeout inside :failed_connect instead of
      # reporting :timeout. Unwrapped here so that a host that never answers is
      # `:timeout` under every adapter, not just under Finch.
      {:error, {:failed_connect, _} = reason} ->
        if connect_timeout?(reason) do
          {:error, TypeDB.Error.new(:timeout, "connecting to #{url} timed out", reason: reason)}
        else
          message = "could not connect to #{url}: #{format_reason(reason)}"
          {:error, TypeDB.Error.new(:transport, message, reason: reason)}
        end

      {:error, reason} ->
        {:error,
         TypeDB.Error.new(:transport, "request to #{url} failed: #{format_reason(reason)}", reason: reason)}
    end
  end

  # `{:failed_connect, [{:to_address, {host, port}}, {:inet, [:inet], :timeout}]}`
  # is the shape today, but the list is documented as opaque diagnostics, so the
  # reason is searched for rather than positionally matched.
  defp connect_timeout?({:failed_connect, info}) when is_list(info) do
    Enum.any?(info, fn
      {_transport, _opts, :timeout} -> true
      _other -> false
    end)
  end

  defp connect_timeout?(_reason), do: false

  # httpc distinguishes requests with and without an entity body by tuple arity,
  # and rejects the bodyless form for methods that take one — so POST and PUT
  # always get a body, even an empty one.
  defp build_request(method, url, headers, nil) when method in [:post, :put] do
    build_request(method, url, headers, "")
  end

  defp build_request(_method, url, headers, nil) do
    {to_charlist(url), charlist_headers(headers)}
  end

  defp build_request(_method, url, headers, body) do
    {content_type, rest} = pop_content_type(headers)
    {to_charlist(url), charlist_headers(rest), to_charlist(content_type), body}
  end

  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {name, _} -> String.downcase(name) == "content-type" end) do
      {[{_, value} | _], rest} -> {value, rest}
      {[], rest} -> {"application/json", rest}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
  end

  defp normalise_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp start_profile(profile) do
    case :inets.start(:httpc, [{:profile, profile}]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, TypeDB.Error.new(:config, "could not start httpc profile", reason: reason)}
    end
  end

  defp set_profile_options(profile, opts) do
    options = [
      max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
      max_keep_alive_length: Keyword.get(opts, :max_keep_alive_length, @default_max_keep_alive_length),
      keep_alive_timeout: Keyword.get(opts, :keep_alive_timeout, @default_keep_alive_timeout),
      cookies: :disabled
    ]

    case :httpc.set_options(options, profile) do
      :ok -> :ok
      {:error, reason} -> {:error, TypeDB.Error.new(:config, "invalid httpc options", reason: reason)}
    end
  end

  @doc false
  @spec ssl_opts(keyword()) :: keyword()
  def ssl_opts(opts) do
    overrides =
      case Keyword.fetch(opts, :cacertfile) do
        {:ok, path} -> Keyword.merge([cacertfile: to_charlist(path)], Keyword.get(opts, :ssl, []))
        :error -> Keyword.get(opts, :ssl, [])
      end

    defaults()
    |> Keyword.merge(overrides)
    |> drop_conflicting_ca_source(overrides)
  end

  defp defaults do
    [
      verify: :verify_peer,
      depth: 4,
      versions: protocol_versions(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ default_ca_source()
  end

  # A caller-supplied :cacertfile or :cacerts must fully replace ours, otherwise
  # :ssl errors on receiving both.
  defp drop_conflicting_ca_source(opts, overrides) do
    cond do
      Keyword.has_key?(overrides, :cacertfile) -> Keyword.delete(opts, :cacerts)
      Keyword.has_key?(overrides, :cacerts) -> Keyword.delete(opts, :cacertfile)
      true -> opts
    end
  end

  defp default_ca_source do
    [cacerts: :public_key.cacerts_get()]
  rescue
    _ ->
      Logger.warning("""
      TypeDB: no operating system CA trust store found. HTTPS connections will \
      fail until you pass :cacertfile or :cacerts, e.g.

          http: {TypeDB.HTTP.Httpc, cacertfile: "/etc/ssl/certs/ca-certificates.crt"}
      """)

      []
  end

  defp protocol_versions do
    available = :ssl.versions()[:available] || []
    Enum.filter([:"tlsv1.3", :"tlsv1.2"], &(&1 in available))
  end

  defp format_reason(reason), do: inspect(reason)
end
