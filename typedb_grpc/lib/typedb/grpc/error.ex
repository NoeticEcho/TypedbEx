defmodule TypeDB.GRPC.Error do
  @moduledoc """
  Turning gRPC failures into the `%TypeDB.Error{}` the sibling driver returns.

  This module exists so that the two transports are interchangeable at the call
  site. An application that routes failures by `kind`, by `code`, or through
  `TypeDB.Error.retryable?/1` keeps every branch it wrote when it switches, and
  that is the whole reason `typedb_grpc` depends on `typedb` rather than
  defining error types of its own.

  ## Where a TypeDB error code lives on this transport

  Nowhere obvious, which is why this is a module and not a function. A gRPC
  failure arrives as a `GRPC.RPCError` whose `message` is a category
  (`"Unauthenticated"`, `"Request generated error"`) rather than anything about
  the request. The useful parts are in `details`, as two `google.rpc` messages
  that TypeDB attaches by hand:

    * `ErrorInfo.reason` — the TypeDB code, `"AUT1"`, `"DBD1"`, `"STC2"`. The
      same codes the HTTP API puts in its JSON body.
    * `DebugInfo.stack_entries` — the human messages, most specific first.

  Measured against 3.12.1: deleting a database that does not exist arrives as
  gRPC status 3 with `reason: "DBD1"` and stack entries
  `["[DBD1] Cannot delete database since it does not exist.", "[SRV13] Unable
  to delete database."]`.

  ## Why `:status` carries an HTTP status on a transport that has none

  `%TypeDB.Error{}` documents `:status` as the HTTP status, and there is no HTTP
  here. It is filled anyway, with the standard gRPC-to-HTTP equivalence that
  grpc-gateway and every other bridge uses, because `TypeDB.Error.retryable?/1`
  judges `:server` errors by status — and a `nil` there would quietly make the
  same failure retryable over one transport and terminal over the other. That
  divergence is exactly what sharing the struct is meant to prevent.

  The gRPC status is not lost: it is in `:reason`, as `{:grpc_status, integer}`.
  """

  alias TypeDB.Error

  # The mapping grpc-gateway publishes, restricted to the codes TypeDB actually
  # returns plus the ones any gRPC stack can raise on its own.
  @http_status %{
    # CANCELLED — the caller went away; 499 is nginx's, and the closest thing
    # to a status for "nobody is waiting for this any more".
    1 => 499,
    2 => 500,
    3 => 400,
    4 => 504,
    5 => 404,
    6 => 409,
    7 => 403,
    8 => 429,
    9 => 400,
    10 => 409,
    11 => 400,
    12 => 501,
    13 => 500,
    14 => 503,
    15 => 500,
    16 => 401
  }

  @doc """
  The HTTP status this driver reports for a gRPC status code.

      iex> TypeDB.GRPC.Error.http_status(16)
      401

      iex> TypeDB.GRPC.Error.http_status(14)
      503

  Unknown codes become `500`: a gRPC status this driver has not seen is the
  server behaving in a way nobody predicted, which is what `500` means.
  """
  @spec http_status(integer()) :: pos_integer()
  def http_status(grpc_status), do: Map.get(@http_status, grpc_status, 500)

  @doc """
  Converts a `GRPC.RPCError` into a `%TypeDB.Error{}`.

  `context` is prepended to the message when the server gave nothing better —
  it names the operation, so that a bare `"Request generated error"` still tells
  the reader what was being attempted.
  """
  @spec from_rpc_error(GRPC.RPCError.t(), String.t()) :: Error.t()
  def from_rpc_error(%GRPC.RPCError{} = error, context) do
    code = error_code(error)
    status = http_status(error.status)

    Error.new(kind(error.status), message(error, context),
      code: code,
      status: status,
      reason: {:grpc_status, error.status},
      body: error.details
    )
  end

  @doc """
  Converts anything else a gRPC call can fail with.

  The adapter reports a connection that could not be established, or a stream
  that died, as plain terms rather than as `GRPC.RPCError`. They are transport
  failures in the sense `%TypeDB.Error{}` means: the request produced no answer,
  and trying again could produce one.
  """
  @spec from_reason(term(), String.t()) :: Error.t()
  def from_reason(reason, context) do
    Error.new(:transport, "#{context}: #{inspect(reason)}", reason: reason)
  end

  # UNAUTHENTICATED and PERMISSION_DENIED are about credentials; DEADLINE_EXCEEDED
  # is a timeout by any name; UNAVAILABLE is the server not being there. Everything
  # else reached TypeDB and came back with TypeDB's opinion of it.
  defp kind(16), do: :unauthenticated
  defp kind(7), do: :unauthenticated
  defp kind(4), do: :timeout
  defp kind(14), do: :transport
  defp kind(_), do: :server

  # The code is in ErrorInfo.reason. Everything else in the envelope is either a
  # category or a rendering of the same thing.
  defp error_code(%GRPC.RPCError{details: details}) when is_list(details) do
    Enum.find_value(details, fn detail ->
      case decode_detail(detail) do
        %Google.Rpc.ErrorInfo{reason: reason} when is_binary(reason) and reason != "" -> reason
        _ -> nil
      end
    end)
  end

  defp error_code(%GRPC.RPCError{}), do: nil

  defp message(%GRPC.RPCError{} = error, context) do
    case stack_entries(error) do
      [] -> "#{context}: #{error.message}"
      entries -> Enum.join(entries, "\n")
    end
  end

  defp stack_entries(%GRPC.RPCError{details: details}) when is_list(details) do
    Enum.find_value(details, [], fn detail ->
      case decode_detail(detail) do
        %Google.Rpc.DebugInfo{stack_entries: [_ | _] = entries} -> entries
        _ -> nil
      end
    end)
  end

  defp stack_entries(%GRPC.RPCError{}), do: []

  # A detail that will not decode is a detail from a newer server that this
  # build has no schema for. It is not worth failing over: the caller is already
  # holding an error, and turning "the request was rejected" into "the rejection
  # could not be parsed" loses the only useful half.
  defp decode_detail(%Google.Protobuf.Any{type_url: url, value: value}) do
    case url do
      "type.googleapis.com/google.rpc.ErrorInfo" -> safe_decode(Google.Rpc.ErrorInfo, value)
      "type.googleapis.com/google.rpc.DebugInfo" -> safe_decode(Google.Rpc.DebugInfo, value)
      _ -> nil
    end
  end

  defp decode_detail(_), do: nil

  defp safe_decode(module, value) do
    module.decode(value)
  rescue
    _ -> nil
  end
end
