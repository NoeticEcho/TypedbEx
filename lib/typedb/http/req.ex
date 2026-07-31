defmodule TypeDB.HTTP.Req do
  @moduledoc """
  Optional `TypeDB.HTTP` adapter backed by [Req](https://hex.pm/packages/req).

  `:req` is **not** a dependency of this library; add it yourself if you want to
  use this adapter:

      # mix.exs
      {:req, "~> 0.5"}

      # wherever you start the driver
      TypeDB.start_link(
        url: "http://localhost:8000",
        http: {TypeDB.HTTP.Req, finch: MyApp.Finch}
      )

  All options are forwarded to `Req.new/1`, so Finch pools, retries and
  `:connect_options` are configured the Req way. This adapter disables Req's own
  retry and redirect handling: `TypeDB` decides what is safe to retry.
  """

  @behaviour TypeDB.HTTP

  @compile {:no_warn_undefined, Req}

  defstruct [:req]

  @type t :: %__MODULE__{req: term()}

  @impl true
  def init(opts) do
    if Code.ensure_loaded?(Req) do
      req =
        opts
        |> Keyword.merge(retry: false, redirect: false, decode_body: false)
        |> Req.new()

      {:ok, %__MODULE__{req: req}}
    else
      {:error,
       TypeDB.Error.new(
         :config,
         ~s(TypeDB.HTTP.Req requires the :req package. Add {:req, "~> 0.5"} to your dependencies.)
       )}
    end
  end

  @impl true
  def terminate(_state), do: :ok

  @impl true
  def request(%__MODULE__{req: req}, method, url, headers, body, opts) do
    options =
      [
        method: method,
        url: url,
        headers: headers,
        body: body || "",
        receive_timeout: normalise_timeout(Keyword.get(opts, :timeout))
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Req.request(req, options) do
      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok,
         %{
           status: status,
           headers: flatten_headers(resp_headers),
           body: IO.iodata_to_binary(resp_body)
         }}

      {:error, %{__exception__: true} = exception} ->
        {:error,
         TypeDB.Error.new(:transport, "request to #{url} failed: #{Exception.message(exception)}",
           reason: exception
         )}

      {:error, reason} ->
        {:error, TypeDB.Error.new(:transport, "request to #{url} failed: #{inspect(reason)}", reason: reason)}
    end
  end

  defp normalise_timeout(:infinity), do: :infinity
  defp normalise_timeout(nil), do: nil
  defp normalise_timeout(timeout) when is_integer(timeout), do: timeout

  # Req >= 0.4 returns headers as a map of name => [values].
  defp flatten_headers(headers) when is_map(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: {String.downcase(name), value}
  end

  defp flatten_headers(headers) when is_list(headers) do
    for {name, value} <- headers, do: {String.downcase(to_string(name)), to_string(value)}
  end
end
