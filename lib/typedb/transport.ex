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
    defstruct [:conn, :config, :method, :path, :opts, :url, :body, :token, :deadline]
  end

  @doc """
  Executes a request, renewing the token and retrying as configured.
  """
  @spec request(Connection.t(), TypeDB.HTTP.method(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(conn, method, path, opts) do
    config = Connection.config(conn)

    %Request{conn: conn, config: config, method: method, path: path, opts: opts}
    |> put_deadline()
    |> put_url()
    |> put_body()
    |> send_with_renewal(0)
  end

  # Stamped before anything else, so that acquiring a token — which can block on
  # a sign-in — is spent out of the caller's budget rather than on top of it.
  defp put_deadline(%Request{config: config, opts: opts} = request) do
    deadline =
      case opts[:deadline] || config.deadline do
        :infinity -> :infinity
        budget -> System.monotonic_time(:millisecond) + budget
      end

    %{request | deadline: deadline}
  end

  defp remaining(%Request{deadline: :infinity}), do: :infinity
  defp remaining(%Request{deadline: deadline}), do: deadline - System.monotonic_time(:millisecond)

  defp within_deadline(%Request{deadline: :infinity}), do: :ok

  defp within_deadline(%Request{} = request) do
    if remaining(request) > 0, do: :ok, else: {:error, deadline_error(request, nil)}
  end

  defp deadline_error(%Request{config: config, opts: opts} = request, last_error) do
    budget = opts[:deadline] || config.deadline
    detail = if last_error, do: " The last failure was: #{Exception.message(last_error)}", else: ""

    Error.new(
      :timeout,
      "the :deadline of #{budget}ms for #{request.method} #{request.url} was reached.#{detail}",
      reason: last_error
    )
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
    with {:ok, token} <- acquire_token(request),
         :ok <- within_deadline(request) do
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

    if affordable?(request, delay) do
      wait_and_retry(request, attempt_no, attempts, error, delay)
    else
      # Sleeping the backoff would consume the rest of the budget and leave no
      # time to send anything, so the retry is not started. The deadline error
      # carries the failure that prompted it: "deadline reached" alone would
      # hide whether the server was down or merely slow.
      {:error, deadline_error(request, error)}
    end
  end

  defp affordable?(%Request{deadline: :infinity}, _delay), do: true
  defp affordable?(%Request{} = request, delay), do: remaining(request) > delay

  defp wait_and_retry(%Request{} = request, attempt_no, attempts, error, delay) do
    # Metadata as well as message text, so a log backend can filter and group on
    # these rather than parse the sentence. See "Logging" in `TypeDB`.
    Logger.debug(
      fn ->
        "TypeDB: #{error.kind} on #{request.method} #{request.url} " <>
          "(attempt #{attempt_no}/#{attempts}), retrying in #{delay}ms"
      end,
      typedb_connection: request.config.name,
      typedb_method: request.method,
      typedb_path: request.path,
      typedb_attempt: attempt_no,
      typedb_error_kind: error.kind
    )

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

  # `timeout: nil` reaches here whenever a caller forwards an absent option.
  #
  # An attempt gets whichever is smaller, its own timeout or what is left of the
  # deadline, which is what stops N retries from costing N times the timeout.
  # The floor of 1ms covers the sliver between the affordability check and this
  # line: a sleep can overrun, and `timeout: 0` means something different to
  # every adapter.
  defp attempt_timeout(%Request{config: config, opts: opts} = request) do
    timeout = opts[:timeout] || config.timeout

    case {timeout, remaining(request)} do
      {timeout, :infinity} -> timeout
      {:infinity, remaining} -> max(1, remaining)
      {timeout, remaining} -> max(1, min(timeout, remaining))
    end
  end

  defp do_adapter_request(%Request{config: config} = request) do
    http_opts = [
      timeout: attempt_timeout(request),
      connect_timeout: config.connect_timeout
    ]

    contain(config.http_adapter, "#{request.method} #{request.url}", fn ->
      config.http_adapter.request(
        Connection.adapter_state(request.conn),
        request.method,
        request.url,
        headers(request),
        request.body,
        http_opts
      )
    end)
  end

  @doc """
  Invokes an HTTP adapter, containing everything it can do wrong.

  An adapter is a plug-in point: `TypeDB.HTTP` is public and anyone may
  implement it, and even the shipped ones raise — Finch raises rather than
  returns when its pool is exhausted. Every call into an adapter goes through
  here, so that a raise, a throw, an exit or a nonsense return value all become
  the `{:ok, response} | {:error, %TypeDB.Error{}}` the rest of the driver
  documents. `where` names the call for the error message.
  """
  @spec contain(module(), String.t(), (-> term())) :: {:ok, TypeDB.HTTP.response()} | {:error, Error.t()}
  def contain(adapter, where, fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, %{status: status, headers: headers, body: body}} = ok
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        ok

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(
           :transport,
           "HTTP adapter #{inspect(adapter)} on #{where} returned #{inspect(other)}, " <>
             "which is not a TypeDB.HTTP response",
           reason: other
         )}
    end
  rescue
    exception ->
      {:error, adapter_fault(adapter, where, "raised", exception, __STACKTRACE__)}
  catch
    :exit, reason ->
      {:error, adapter_fault(adapter, where, "exited", reason, __STACKTRACE__)}

    :throw, value ->
      {:error, adapter_fault(adapter, where, "threw", value, __STACKTRACE__)}
  end

  # Finch signals pool exhaustion by raising, and a checkout that never completes
  # is a timeout in every sense the caller cares about.
  defp adapter_fault(adapter, where, verb, %{__exception__: true} = exception, stacktrace) do
    message = Exception.message(exception)
    kind = if message =~ "unable to provide a connection", do: :timeout, else: :transport

    Error.new(kind, "HTTP adapter #{inspect(adapter)} on #{where} #{verb}: #{message}",
      reason: {exception, redact(stacktrace, adapter)}
    )
  end

  defp adapter_fault(adapter, where, verb, reason, stacktrace) do
    Error.new(:transport, "HTTP adapter #{inspect(adapter)} on #{where} #{verb}: #{inspect(reason)}",
      reason: {reason, redact(stacktrace, adapter)}
    )
  end

  # On a `function_clause` or `badarg` the BEAM puts the failing frame's
  # *arguments* into the stacktrace, and argument 5 of `c:TypeDB.HTTP.request/6`
  # is the encoded request body — which for `POST /v1/signin` is the password,
  # and for `TypeDB.User.create/3` is the user's new one. That term would then
  # travel in `%TypeDB.Error{reason: ...}` into logs and into telemetry metadata.
  #
  # Only the adapter's own frames are stripped, and only down to an arity, so
  # every other frame keeps the detail that makes a stacktrace worth having.
  defp redact(stacktrace, adapter) do
    Enum.map(stacktrace, fn
      {^adapter, function, args, location} when is_list(args) ->
        {adapter, function, length(args), location}

      frame ->
        frame
    end)
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
