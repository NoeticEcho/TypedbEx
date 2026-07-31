defmodule TypeDB.HTTP.Req do
  @moduledoc """
  `TypeDB.HTTP` adapter backed by [Req](https://hex.pm/packages/req) and Finch.

  Use this when your application already builds requests with Req and you want
  TypeDB to share that configuration — the same Finch instance, the same
  connect options, the same TLS setup. It is Finch underneath either way, so it
  performs like `TypeDB.HTTP.Finch`; the reason to pick it is configuration, not
  speed.

  `:req` is an *optional* dependency of this library — add it yourself:

      # mix.exs
      {:req, "~> 0.7"}

      # wherever you start the driver
      TypeDB.start_link(
        url: "http://localhost:8000",
        http: {TypeDB.HTTP.Req, finch: MyApp.Finch}
      )

  All options are forwarded to `Req.new/1`, so Finch pools, connect options and
  transport tuning are configured the Req way. The adapter pins three of them:
  redirects and Req's own retries are off, and the body is left undecoded —
  `TypeDB` decides what is safe to retry and owns JSON decoding.
  """

  @behaviour TypeDB.HTTP

  @compile {:no_warn_undefined, Req}

  # The `%Req.Request{}` carries `:connect_options`, which is where TLS material
  # goes, and this struct renders in the connection's crash reports.
  @derive {Inspect, except: [:req]}
  defstruct [:req]

  @type t :: %__MODULE__{req: term()}

  @impl true
  def init(_name, opts) do
    if Code.ensure_loaded?(Req) do
      # The connection injects :connect_timeout for adapters that configure
      # connecting at pool-build time. This one does not — it applies the value
      # per request — and Req rejects options it does not recognise, so the key
      # is dropped here rather than forwarded.
      req =
        opts
        |> Keyword.delete(:connect_timeout)
        |> Keyword.merge(retry: false, redirect: false, decode_body: false)
        |> Req.new()

      {:ok, %__MODULE__{req: req}}
    else
      {:error,
       TypeDB.Error.new(
         :config,
         ~s(TypeDB.HTTP.Req requires the :req package. Add {:req, "~> 0.7"} to your dependencies.)
       )}
    end
  end

  @impl true
  def owner(_state), do: nil

  @impl true
  def terminate(_state), do: :ok

  @impl true
  def request(%__MODULE__{req: req} = state, method, url, headers, body, opts) do
    case Req.request(req, request_options(state, method, url, headers, body, opts)) do
      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: flatten_headers(resp_headers), body: to_binary(resp_body)}}

      {:error, %{__exception__: true} = exception} ->
        {:error, transport_error(url, exception)}

      {:error, reason} ->
        {:error, TypeDB.Error.new(:transport, "request to #{url} failed: #{inspect(reason)}", reason: reason)}
    end
  end

  # Req hands back whatever Mint or Finch raised, so a timeout arrives as an
  # ordinary transport exception. It is reclassified here for the same reason the
  # Finch adapter does it: callers branch on `:timeout`, and the same event must
  # not change kind just because the adapter changed.
  defp transport_error(url, exception) do
    if Map.get(exception, :reason) in [:timeout, :pool_timeout] do
      TypeDB.Error.new(:timeout, "request to #{url} timed out", reason: exception)
    else
      TypeDB.Error.new(:transport, "request to #{url} failed: #{Exception.message(exception)}",
        reason: exception
      )
    end
  end

  @doc """
  The options this adapter hands to `Req.request/2`.

  Public so that the merge below can be asserted on directly: whether a
  per-request option quietly replaced a configured one is not observable from
  the outside of a successful request.
  """
  @spec request_options(
          t(),
          TypeDB.HTTP.method(),
          String.t(),
          TypeDB.HTTP.headers(),
          iodata() | nil,
          keyword()
        ) ::
          keyword()
  def request_options(%__MODULE__{req: req}, method, url, headers, body, opts) do
    [method: method, url: url, headers: headers]
    |> put_body(body)
    |> put_timeout(Keyword.get(opts, :timeout))
    |> put_connect_timeout(req, Keyword.get(opts, :connect_timeout))
  end

  # Req infers POST from the presence of a body, overriding an explicit
  # `method: :get`. A bodyless request must therefore carry no :body key at all,
  # not an empty string.
  defp put_body(options, nil), do: options
  defp put_body(options, body), do: Keyword.put(options, :body, IO.iodata_to_binary(body))

  defp put_timeout(options, nil), do: options
  defp put_timeout(options, timeout), do: Keyword.put(options, :receive_timeout, timeout)

  defp put_connect_timeout(options, _req, nil), do: options

  # Req merges per-request options *over* the base ones key by key, so setting
  # :connect_options here would discard whatever was configured at init —
  # including TLS options, silently turning off a pinned CA. The base is read
  # back and merged instead.
  defp put_connect_timeout(options, req, timeout) do
    base = Map.get(req.options, :connect_options, [])
    Keyword.put(options, :connect_options, Keyword.put_new(base, :timeout, timeout))
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp to_binary(nil), do: ""
  # Req decodes some content types even with decode_body: false disabled upstream;
  # anything non-binary is re-encoded so callers always see raw bytes.
  defp to_binary(body), do: TypeDB.JSON.encode!(body)

  # Req returns headers as a map of name => [values].
  defp flatten_headers(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: {String.downcase(name), value}
  end
end
