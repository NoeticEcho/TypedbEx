defmodule TypeDB.Transport do
  @moduledoc """
  Builds, sends and decodes a single TypeDB HTTP request.

  This is the layer between the public API modules and the `TypeDB.HTTP`
  adapter. It runs entirely in the caller's process; the only time it talks to
  the connection process is to obtain or renew an access token.

  Reach for `TypeDB.Connection.request/4` rather than calling this directly.
  """

  require Logger

  alias TypeDB.{Config, Connection, Error, JSON, Telemetry}

  defmodule Request do
    @moduledoc false

    @enforce_keys [:conn, :config, :method, :path, :opts]
    defstruct [:conn, :config, :method, :path, :opts, :url, :body, :token]
  end

  @doc """
  Executes a request, renewing the token and retrying as configured.
  """
  @spec request(Connection.t(), TypeDB.HTTP.method(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(conn, method, path, opts) do
    config = Connection.config(conn)

    %Request{conn: conn, config: config, method: method, path: path, opts: opts}
    |> put_url()
    |> put_body()
    |> send_with_renewal(0)
  end

  defp put_url(%Request{config: config, path: path, opts: opts} = request) do
    url =
      if Keyword.get(opts, :versioned, true) do
        Config.url(config, path)
      else
        Config.raw_url(config, path)
      end

    %{request | url: url}
  end

  defp put_body(%Request{opts: opts} = request) do
    case Keyword.fetch(opts, :body) do
      {:ok, body} -> %{request | body: JSON.encode_to_iodata!(body)}
      :error -> request
    end
  end

  # ----------------------------------------------------------------------------
  # Authentication
  # ----------------------------------------------------------------------------

  defp send_with_renewal(%Request{} = request, renewals) do
    with {:ok, token} <- acquire_token(request) do
      # Stamped once the token is in hand: acquiring it can block on a sign-in,
      # and an earlier timestamp would make the connection believe the token it
      # just minted is newer than this failure.
      sent_at = System.monotonic_time(:millisecond)

      case send(%{request | token: token}) do
        {:unauthenticated, error} -> renew_and_retry(request, renewals, sent_at, error)
        result -> result
      end
    end
  end

  defp acquire_token(%Request{conn: conn, opts: opts}) do
    if Keyword.get(opts, :authenticated, true) do
      Connection.token(conn)
    else
      {:ok, nil}
    end
  end

  defp renew_and_retry(%Request{} = request, renewals, sent_at, error) do
    authenticated? = Keyword.get(request.opts, :authenticated, true)

    if authenticated? and renewals < request.config.max_auth_renewals do
      case Connection.renew_token(request.conn, sent_at) do
        {:ok, _token} -> send_with_renewal(request, renewals + 1)
        {:error, renew_error} -> {:error, auth_error(error, renew_error)}
      end
    else
      # An unauthenticated endpoint rejected us, or the renewal budget is spent.
      {:error, error}
    end
  end

  # A renewal that failed for authentication reasons explains the problem better
  # than the 401 that triggered it ("bad password", "static token cannot be
  # renewed"), so it wins — but it inherits the server's stable error code. A
  # renewal that failed for transport reasons says nothing about authentication,
  # so the original 401 stands.
  defp auth_error(original, %Error{kind: :unauthenticated} = renew_error) do
    %{renew_error | code: renew_error.code || original.code, status: renew_error.status || original.status}
  end

  defp auth_error(original, _renew_error), do: original

  # ----------------------------------------------------------------------------
  # Sending
  # ----------------------------------------------------------------------------

  defp send(%Request{} = request) do
    case attempt(request, 1, attempts(request)) do
      {:ok, response} -> decode(response, request.opts)
      {:error, error} -> {:error, error}
    end
  end

  defp attempts(%Request{config: config} = request) do
    if idempotent?(request), do: config.max_retries + 1, else: 1
  end

  defp idempotent?(%Request{method: method, opts: opts}) do
    Keyword.get_lazy(opts, :idempotent, fn -> method in [:get, :delete] end)
  end

  defp attempt(%Request{} = request, attempt_no, attempts) do
    case adapter_request(request, attempt_no) do
      {:error, %Error{kind: kind} = error} when kind in [:transport, :timeout] ->
        retry_or_give_up(request, attempt_no, attempts, error)

      result ->
        result
    end
  end

  defp retry_or_give_up(_request, attempt_no, attempts, error) when attempt_no >= attempts do
    {:error, error}
  end

  defp retry_or_give_up(%Request{} = request, attempt_no, attempts, error) do
    delay = Config.backoff(request.config, attempt_no)

    Logger.debug(fn ->
      "TypeDB: #{error.kind} on #{request.method} #{request.url} " <>
        "(attempt #{attempt_no}/#{attempts}), retrying in #{delay}ms"
    end)

    Process.sleep(delay)
    attempt(request, attempt_no + 1, attempts)
  end

  defp adapter_request(%Request{} = request, attempt_no) do
    metadata = %{
      connection: request.conn,
      method: request.method,
      path: request.path,
      attempt: attempt_no
    }

    Telemetry.span_request(metadata, fn ->
      result = do_adapter_request(request)
      {result, Map.merge(metadata, outcome(result))}
    end)
  end

  defp outcome({:ok, %{status: status}}), do: %{status: status}
  defp outcome({:error, %Error{} = error}), do: %{error: error}

  # An adapter is a plug-in point: `TypeDB.HTTP` is public and anyone may
  # implement it, and even the shipped ones raise — Finch raises rather than
  # returns when its pool is exhausted. Everything an adapter can do is contained
  # here so that callers only ever see the `{:ok, _} | {:error, %TypeDB.Error{}}`
  # contract the rest of the driver documents.
  defp do_adapter_request(%Request{} = request) do
    case call_adapter(request) do
      {:ok, %{status: status, headers: headers, body: body}} = ok
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        ok

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(
           :transport,
           "HTTP adapter #{inspect(request.config.http_adapter)} returned #{inspect(other)}, " <>
             "which is not a TypeDB.HTTP response",
           reason: other
         )}
    end
  rescue
    exception ->
      {:error, adapter_fault(request, "raised", exception, __STACKTRACE__)}
  catch
    :exit, reason ->
      {:error, adapter_fault(request, "exited", reason, __STACKTRACE__)}

    :throw, value ->
      {:error, adapter_fault(request, "threw", value, __STACKTRACE__)}
  end

  # Finch signals pool exhaustion by raising, and a checkout that never completes
  # is a timeout in every sense the caller cares about.
  defp adapter_fault(request, verb, %{__exception__: true} = exception, stacktrace) do
    message = Exception.message(exception)
    kind = if message =~ "unable to provide a connection", do: :timeout, else: :transport

    Error.new(kind, "#{adapter_prefix(request)} #{verb}: #{message}", reason: {exception, stacktrace})
  end

  defp adapter_fault(request, verb, reason, stacktrace) do
    Error.new(:transport, "#{adapter_prefix(request)} #{verb}: #{inspect(reason)}",
      reason: {reason, stacktrace}
    )
  end

  defp adapter_prefix(%Request{config: config, method: method, url: url}) do
    "HTTP adapter #{inspect(config.http_adapter)} on #{method} #{url}"
  end

  defp call_adapter(%Request{config: config} = request) do
    http_opts = [
      # `timeout: nil` reaches here whenever a caller forwards an absent option.
      timeout: request.opts[:timeout] || config.timeout,
      connect_timeout: config.connect_timeout
    ]

    config.http_adapter.request(
      Connection.adapter_state(request.conn),
      request.method,
      request.url,
      headers(request),
      request.body,
      http_opts
    )
  end

  defp headers(%Request{token: token, opts: opts}) do
    []
    |> put_header("accept", "application/json, text/plain")
    |> then(fn headers ->
      if Keyword.has_key?(opts, :body),
        do: put_header(headers, "content-type", "application/json"),
        else: headers
    end)
    |> then(fn headers ->
      if is_binary(token), do: put_header(headers, "authorization", "Bearer " <> token), else: headers
    end)
  end

  defp put_header(headers, name, value), do: [{name, value} | headers]

  # ----------------------------------------------------------------------------
  # Decoding
  # ----------------------------------------------------------------------------

  defp decode(%{status: status} = response, opts) when status in 200..299 do
    decode_success(response, Keyword.get(opts, :expect, :json))
  end

  defp decode(%{status: 401} = response, _opts), do: {:unauthenticated, error_from(response)}
  defp decode(response, _opts), do: {:error, error_from(response)}

  defp decode_success(%{status: 204}, _expect), do: {:ok, :ok}
  defp decode_success(_response, :empty), do: {:ok, :ok}
  defp decode_success(%{body: ""}, :json), do: {:ok, :ok}
  defp decode_success(%{body: body}, :text), do: {:ok, body}

  defp decode_success(%{body: body}, :json) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         Error.new(:decode, "TypeDB returned a body that is not valid JSON", reason: reason, body: body)}
    end
  end

  @doc false
  @spec error_from(TypeDB.HTTP.response()) :: Error.t()
  def error_from(%{status: status, body: body}) do
    case JSON.decode(body) do
      {:ok, decoded} -> Error.from_response(status, decoded)
      {:error, _reason} -> Error.from_response(status, body)
    end
  end
end
