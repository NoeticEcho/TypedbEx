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

  @impl true
  def message(%__MODULE__{kind: kind, code: nil, message: message}) do
    "[#{kind}] #{message}"
  end

  def message(%__MODULE__{kind: kind, code: code, message: message}) do
    "[#{kind}] #{code}: #{message}"
  end
end
