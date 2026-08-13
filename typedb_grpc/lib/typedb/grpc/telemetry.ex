defmodule TypeDB.GRPC.Telemetry do
  @moduledoc """
  What this driver reports about itself.

  ## The event names are the sibling's, on purpose

  `[:typedb, :operation, …]`, `[:typedb, :transaction, …]` and
  `[:typedb, :sign_in, …]` are exactly the events `TypeDB.Telemetry` emits, and
  they mean the same things. That is the same argument as the shared
  `%TypeDB.Error{}`: an application that switches transports should keep its
  dashboards, and telemetry is precisely the sort of thing that breaks quietly
  when it does not.

  Both drivers put `:transport` in the metadata — `:grpc` here, `:http` there —
  so an application running both can break a metric down by it, and one running
  either can ignore it.

  | event | emitted for | use it for |
  | --- | --- | --- |
  | `[:typedb, :operation, …]` | one call into the public API | request rates and latency |
  | `[:typedb, :transaction, …]` | one bracketed transaction | how long work holds a transaction |
  | `[:typedb, :sign_in, …]` | one sign-in | token churn |
  | `[:typedb, :grpc, :stream, :batch]` | one batch of a streamed read | back pressure, and whether it is working |

  ## What is missing, and why

  There is no `[:typedb, :request, …]` here. Over HTTP that span is one attempt
  on the wire, and it exists because the driver retries: several spans per call
  is the interesting fact. This transport has no per-request retry — a request
  lives on a transaction stream whose failure destroys the transaction, so there
  is nothing a retry could correctly re-send — and a span per message on the
  stream would report the same duration as the operation that contains it.
  Emitting it would be noise dressed as parity.

  There is no `[:typedb, :retry, :exhausted]` for the same reason.

  ## `[:typedb, :operation, :start | :stop | :exception]`

  One span per call into the public API: `TypeDB.GRPC.query/4`,
  `TypeDB.GRPC.Database.list/2`, `TypeDB.GRPC.Transaction.commit/2` and so on.

  Metadata:

    * `:transport` — always `:grpc`
    * `:connection` — the connection name
    * `:operation` — a low-cardinality atom such as `:query`, `:commit`,
      `:databases_all`. Safe as a metric tag; this is the one to tag on
    * `:database` — present whenever the call names one
    * `:transaction_type` — `:read`, `:write` or `:schema`, where the call has one
    * `:queries` — how many queries a call carried, on `query_many/3` and
      `execute_many/3`
    * `:error` — the `TypeDB.Error`, on `:stop` only, when the call failed

  ## `[:typedb, :transaction, :start | :stop | :exception]`

  One span per `TypeDB.GRPC.Transaction.transaction/5`, from opening the
  transaction to the commit or close that ends it.

  Metadata: `:transport`, `:connection`, `:database`, `:type`, and on `:stop` an
  `:outcome` of `:commit`, `:close` or `:commit_failed`, plus `:error` when
  there was one. A block that raises produces `:exception`.

  ## `[:typedb, :sign_in, :start | :stop | :exception]`

  One span per sign-in. Metadata: `:transport`, `:connection`, and `:error` on
  failure.

  ## `[:typedb, :grpc, :stream, :batch]`

  Not a span, and with no counterpart on the other transport: one event per
  batch handed to a consumer of `TypeDB.GRPC.stream/4`.

  Measurements: `:rows` in the batch, and `:wait` — native time units the
  consumer spent waiting for it. Metadata: `:transport`, `:connection` and
  `:database`.

  It is here because back pressure is invisible otherwise. A `:wait` near zero
  every time means the server is ahead of the consumer and the batch size could
  be larger; a `:wait` that dominates means the consumer is waiting on TypeDB,
  which is the shape a healthy streamed read has.

  ## Just show me what it is doing

      TypeDB.GRPC.Telemetry.attach_default_logger(:info)
  """

  require Logger

  @operation [:typedb, :operation]
  @transaction [:typedb, :transaction]
  @sign_in [:typedb, :sign_in]
  @stream_batch [:typedb, :grpc, :stream, :batch]

  @transport :grpc

  @doc "The event prefix for operation spans. The sibling's, deliberately."
  @spec operation_event() :: [atom()]
  def operation_event, do: @operation

  @doc "The event prefix for bracketed-transaction spans."
  @spec transaction_event() :: [atom()]
  def transaction_event, do: @transaction

  @doc "The event prefix for sign-in spans."
  @spec sign_in_event() :: [atom()]
  def sign_in_event, do: @sign_in

  @doc "The event emitted for each batch of a streamed read."
  @spec stream_batch_event() :: [atom()]
  def stream_batch_event, do: @stream_batch

  @doc "The value this driver puts in `:transport`."
  @spec transport() :: atom()
  def transport, do: @transport

  @doc false
  @spec span_operation(map(), (-> {term(), map()})) :: term()
  def span_operation(metadata, fun), do: span(@operation, metadata, fun)

  @doc false
  @spec span_transaction(map(), (-> {term(), map()})) :: term()
  def span_transaction(metadata, fun), do: span(@transaction, metadata, fun)

  @doc false
  @spec span_sign_in(map(), (-> {term(), map()})) :: term()
  def span_sign_in(metadata, fun), do: span(@sign_in, metadata, fun)

  @doc false
  @spec stream_batch(map(), map()) :: :ok
  def stream_batch(measurements, metadata) do
    :telemetry.execute(@stream_batch, measurements, tagged(metadata))
  end

  # Both ends, not just the start. `:telemetry.span/3` takes the `:stop`
  # metadata from what the function returns rather than carrying the start's
  # forward, so tagging only the argument leaves `:stop` — the event everybody
  # actually builds metrics on — without a `:transport`.
  defp span(event, metadata, fun) do
    :telemetry.span(event, tagged(metadata), fn ->
      {result, stop_metadata} = fun.()
      {result, tagged(stop_metadata)}
    end)
  end

  defp tagged(metadata), do: Map.put(metadata, :transport, @transport)

  # ----------------------------------------------------------------------------
  # Default logger
  # ----------------------------------------------------------------------------

  @handler_id "typedb-grpc-default-logger"

  @logged [
    @operation ++ [:stop],
    @operation ++ [:exception],
    @transaction ++ [:stop],
    @sign_in ++ [:stop]
  ]

  @doc """
  Attaches a handler that logs one line per operation, transaction and sign-in.

  It filters on `:transport` so that attaching it alongside
  `TypeDB.Telemetry.attach_default_logger/1` does not log the sibling's spans
  twice — they share event names, which is the point, and this is the cost.
  """
  @spec attach_default_logger(Logger.level()) :: :ok | {:error, :already_exists}
  def attach_default_logger(level \\ :debug) do
    :telemetry.attach_many(@handler_id, @logged, &__MODULE__.handle_event/4, level)
  end

  @doc "Removes the handler `attach_default_logger/1` installed."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(_event, _measurements, %{transport: transport}, _level)
      when transport != @transport do
    :ok
  end

  def handle_event([:typedb, :operation, :stop], %{duration: duration}, metadata, level) do
    log(level, fn ->
      [
        "TypeDB gRPC ",
        to_string(metadata[:operation] || "call"),
        database(metadata),
        " in ",
        ms(duration),
        outcome(metadata)
      ]
    end)
  end

  def handle_event([:typedb, :operation, :exception], %{duration: duration}, metadata, level) do
    log(level, fn ->
      ["TypeDB gRPC ", to_string(metadata[:operation] || "call"), " raised after ", ms(duration)]
    end)
  end

  def handle_event([:typedb, :transaction, :stop], %{duration: duration}, metadata, level) do
    log(level, fn ->
      [
        "TypeDB gRPC ",
        to_string(metadata[:type] || "transaction"),
        " transaction on ",
        to_string(metadata[:database] || "?"),
        " ",
        to_string(metadata[:outcome] || "ended"),
        " after ",
        ms(duration)
      ]
    end)
  end

  def handle_event([:typedb, :sign_in, :stop], %{duration: duration}, metadata, level) do
    log(level, fn -> ["TypeDB gRPC signed in in ", ms(duration), outcome(metadata)] end)
  end

  def handle_event(_event, _measurements, _metadata, _level), do: :ok

  defp log(level, fun), do: Logger.log(level, fun)

  defp database(%{database: database}) when is_binary(database), do: [" on ", database]
  defp database(_), do: []

  defp outcome(%{error: %TypeDB.Error{} = error}), do: [" — failed: ", error.message]
  defp outcome(_), do: []

  defp ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
    |> Float.round(1)
    |> Float.to_string()
    |> Kernel.<>("ms")
  end
end
