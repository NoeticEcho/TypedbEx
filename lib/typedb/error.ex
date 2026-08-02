defmodule TypeDB.Error do
  @moduledoc """
  The single exception type raised (or returned) by every `TypeDB` operation.

  Errors carry a `:kind` describing *where* the failure came from:

    * `:server` — TypeDB answered with a structured error body. `:code` holds the
      TypeDB error code (e.g. `"TSV11"`, `"AUT3"`, `"HSR4"`), `:status` the HTTP
      status, and `:message` the server's message, including its cause trace.
    * `:transport` — the request never produced an HTTP response (connection
      refused, DNS failure, TLS failure, socket closed).
    * `:timeout` — the request exceeded the configured timeout.
    * `:unauthenticated` — credentials were rejected, or the token expired and
      could not be renewed.
    * `:decode` — the response body was not valid JSON, or did not match the
      shape this driver expects.
    * `:encode` — the mirror of `:decode`: an Elixir term could not be turned
      into a TypeDB wire value. A `given_rows` entry of a type TypeDB has no
      equivalent for, or a `TypeDB.Duration` with a negative component, which
      TypeQL's grammar cannot express. Raised rather than returned, because it
      happens while the request is still being built and there is nothing to
      fail.
    * `:config` — the driver was configured incorrectly. Raised at start-up.

  ## Matching on TypeDB error codes

      case TypeDB.query(conn, "social", "match $x isa nonexistent;") do
        {:error, %TypeDB.Error{kind: :server, code: code}} -> {:bad_query, code}
        {:ok, answer} -> answer
      end

  Error codes are stable across TypeDB releases and are the recommended thing to
  branch on; messages are not.
  """

  @type kind ::
          :server
          | :transport
          | :timeout
          | :unauthenticated
          | :decode
          | :encode
          | :config

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          code: String.t() | nil,
          status: pos_integer() | nil,
          reason: term(),
          body: term()
        }

  defexception [:kind, :message, :code, :status, :reason, :body]

  @doc """
  Builds an error.

  Public because `TypeDB.HTTP` is a public extension point and `c:TypeDB.HTTP.request/6`
  is required to return one of these. Application code should be matching on
  errors, not constructing them.

      TypeDB.Error.new(:transport, "connection refused", reason: :econnrefused)

  ## Options

    * `:code` — TypeDB's own error code, for `:server` errors
    * `:status` — the HTTP status
    * `:reason` — the underlying term, whatever it was
    * `:body` — the response body that could not be understood
  """
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message,
      code: opts[:code],
      status: opts[:status],
      reason: opts[:reason],
      body: opts[:body]
    }
  end

  @retryable_statuses [429, 502, 503, 504]

  @doc """
  The response statuses the driver treats as retryable by default.

  `429` is a server shedding load; `502`, `503` and `504` are what a proxy, an
  ingress or a load balancer answers while TypeDB restarts. All four say "not
  now" rather than "no". This is the default of `:retry_on_status`.
  """
  @spec retryable_statuses() :: [pos_integer()]
  def retryable_statuses, do: @retryable_statuses

  @retryable_codes ["STC2"]

  @doc """
  TypeDB error codes that `retryable?/1` treats as worth another attempt,
  whatever status they arrive with.

  `STC2` is an isolation conflict: two concurrent `:write` transactions touched
  the same data and the loser's commit was rejected. It arrives as a `400`,
  which is otherwise the driver's signal that a request will fail the same way
  forever — and this one will not. Replaying the transaction against the
  committed state is the intended response, and the only one available: the
  conflict invalidates the whole transaction, so the driver cannot retry it for
  you.

  Note that this is not the same list as `:retry_on_status`. The driver never
  retries a request on one of these codes by itself, because the unit that has
  to be retried is bigger than the request.
  """
  @spec retryable_codes() :: [String.t()]
  def retryable_codes, do: @retryable_codes

  @doc """
  Whether retrying the call that produced this error could plausibly help.

      case TypeDB.transaction(conn, "social", :write, &steps/1) do
        {:error, %TypeDB.Error{} = error} ->
          if TypeDB.Error.retryable?(error), do: retry_the_whole_thing(), else: give_up(error)

        result ->
          result
      end

  Note what this is *not* for. By the time you are holding an error the driver
  has already retried whatever its configuration allowed, so a `true` here does
  not mean it gave up early. This is for the layer above — retrying a whole
  transaction, requeueing a job — where the unit of work is bigger than one HTTP
  call and the driver could not have retried it for you.

  `:server` errors are judged by `retryable_statuses/0` rather than by a
  connection's `:retry_on_status`, because an error does not carry the
  connection that produced it — plus `retryable_codes/0`, which is how an
  isolation conflict qualifies despite arriving as a `400`. That case is the
  reason this function exists: a commit rejected because a concurrent `:write`
  transaction won the race is exactly the failure a caller is meant to replay.

      iex> TypeDB.Error.retryable?(TypeDB.Error.new(:transport, "connection refused"))
      true

      iex> conflict = TypeDB.Error.new(:server, "isolation conflict", code: "STC2", status: 400)
      iex> TypeDB.Error.retryable?(conflict)
      true

      iex> TypeDB.Error.retryable?(TypeDB.Error.new(:server, "no such database", status: 404))
      false

      iex> TypeDB.Error.retryable?(TypeDB.Error.new(:unauthenticated, "bad password"))
      false
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{kind: kind}) when kind in [:transport, :timeout], do: true

  def retryable?(%__MODULE__{kind: :server, code: code}) when code in @retryable_codes, do: true

  def retryable?(%__MODULE__{kind: :server, status: status}), do: status in @retryable_statuses

  # :unauthenticated, :decode, :encode and :config all describe something that
  # will be exactly as wrong on the next attempt.
  def retryable?(%__MODULE__{}), do: false

  @doc """
  Builds an error from a TypeDB error response body.

  TypeDB error bodies are `%{"code" => code, "message" => message}`. Anything
  else is reported verbatim so that no information is lost.
  """
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, %{"code" => code, "message" => message})
      when is_binary(code) and is_binary(message) do
    new(kind_for_status(status, code), message, code: code, status: status)
  end

  def from_response(status, body) do
    new(kind_for_status(status, nil), "TypeDB returned HTTP #{status}",
      status: status,
      body: body
    )
  end

  defp kind_for_status(401, _code), do: :unauthenticated
  defp kind_for_status(408, _code), do: :timeout
  defp kind_for_status(_status, "AUT" <> _), do: :unauthenticated
  defp kind_for_status(_status, _code), do: :server

  # The rendered form is what lands in a log line, an exit reason and a
  # supervisor report, and those are read by someone who has no `%TypeDB.Error{}`
  # in front of them to inspect. Every field that narrows the failure therefore
  # goes in the string: the kind says which layer failed, the status says what
  # the server answered, and the code is the stable thing to search for.
  #
  # Not covered by SemVer — see the versioning policy in CONTRIBUTING. Match on
  # `:kind` and `:code`, never on this.
  @impl true
  def message(%__MODULE__{kind: kind, status: status, code: code, message: message}) do
    "[#{kind}#{status_suffix(status)}]#{code_prefix(code)} #{message}"
  end

  defp status_suffix(nil), do: ""
  defp status_suffix(status), do: " #{status}"

  defp code_prefix(nil), do: ""
  defp code_prefix(code), do: " #{code}:"
end
