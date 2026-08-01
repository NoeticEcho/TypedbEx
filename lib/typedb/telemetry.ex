defmodule TypeDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the driver.

  Attach to these to get request rates, latency and error breakdowns without
  instrumenting call sites.

  There are three levels, and which one you want depends on the question:

  | event | one span per | answers |
  | --- | --- | --- |
  | `[:typedb, :transaction, …]` | bracketed transaction | how long a unit of work held a transaction |
  | `[:typedb, :operation, …]` | API call | how long a query took, retries included |
  | `[:typedb, :request, …]` | HTTP attempt | how the network behaved |

  Nest them: `:request` spans sit inside an `:operation` span, and `:operation`
  spans sit inside a `:transaction` span. Measuring rates and latency from
  `:request` alone overcounts, because a retried call emits several.

  ## `[:typedb, :operation, :start | :stop | :exception]`

  One span per call into the public API — `TypeDB.query/4`,
  `TypeDB.Database.list/1`, `TypeDB.Transaction.commit/2` and so on — covering
  every retry and every token renewal it needed. This is the event to build
  request rates and latency on.

  Metadata:

    * `:connection` — the connection name
    * `:method` — `:get`, `:post`, `:put` or `:delete`
    * `:route` — a low-cardinality template such as `"/transactions/:id/query"`,
      safe to use as a metric tag
    * `:path` — the concrete path, which contains database, user and transaction
      names and is therefore high-cardinality
    * `:database` — present whenever the call names one, whether in the path or
      in the request body
    * `:transaction_type` — `:read`, `:write` or `:schema`, on transaction and
      query calls
    * `:transaction_id` — on calls against an open transaction
    * `:attempts` — how many HTTP requests it took, on `:stop` only. `1` on the
      happy path; more means the driver retried or renewed a token
    * `:error` — the `TypeDB.Error`, on `:stop` only, when the call failed

  ## `[:typedb, :transaction, :start | :stop | :exception]`

  One span per `TypeDB.transaction/5`, from opening the transaction to the
  commit, rollback or close that ends it. The only span that covers more than
  one request.

  Metadata: `:connection`, `:database`, `:type` (`:read`, `:write` or
  `:schema`), and on `:stop` an `:outcome` of `:commit`, `:rollback`, `:close`
  or `:commit_failed`, plus `:error` when there was one. A block that raises
  produces `:exception` rather than `:stop`.

  ## `[:typedb, :request, :start | :stop | :exception]`

  One span per HTTP request, including each retry and each renew-and-retry
  attempt — so a single `TypeDB.query/4` can produce several spans.

  Measurements follow `:telemetry.span/3`: `:system_time` on start,
  `:duration` (native units) on stop and exception.

  Metadata:

    * `:connection` — the connection name
    * `:method` — `:get`, `:post`, `:put` or `:delete`
    * `:path` — the API path, e.g. `"/transactions/open"`. Database and user
      names are *not* stripped, so treat it as potentially high-cardinality
    * `:attempt` — 1-based attempt number within this request
    * `:route`, `:database`, `:transaction_type`, `:transaction_id` — as above
    * `:status` — HTTP status, on `:stop` only
    * `:error` — the `TypeDB.Error` when one was produced, on `:stop` only

  ## `[:typedb, :retry, :exhausted]`

  Not a span: a single event, emitted when a call stops retrying and returns
  the failure — because `:max_retries` ran out or because `:deadline` left no
  room for another attempt. Measurements: `:attempts`. Metadata: the operation
  span's, plus `:error`.

  This is the one to alert on. A retry that succeeds is the driver doing its
  job; a retry that runs out is something upstream being broken for longer than
  the configuration was willing to wait.

  ## `[:typedb, :sign_in, :start | :stop | :exception]`

  One span per sign-in. A healthy connection produces one on start-up and one
  per token lifetime; a spike means tokens are being rejected.

  Metadata: `:connection`, and `:error` on failure.

  ## Just show me what it is doing

  `attach_default_logger/1` writes a line per operation, transaction, sign-in
  and give-up, and is one call from your application's `start/2`:

      TypeDB.Telemetry.attach_default_logger(:info)

  ## Prometheus / `telemetry_metrics`

  Tag on `:route`, never on `:path` — the latter contains database, user and
  transaction names, and a metric tagged by it grows without bound.

      Telemetry.Metrics.distribution("typedb.operation.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :route]
      )

      Telemetry.Metrics.counter("typedb.retry.exhausted.attempts", tags: [:route])
  """

  require Logger

  @operation [:typedb, :operation]
  @request [:typedb, :request]
  @retry_exhausted [:typedb, :retry, :exhausted]
  @sign_in [:typedb, :sign_in]
  @transaction [:typedb, :transaction]

  @doc "The event prefix for operation spans."
  @spec operation_event() :: [atom()]
  def operation_event, do: @operation

  @doc "The event prefix for request spans."
  @spec request_event() :: [atom()]
  def request_event, do: @request

  @doc "The event prefix for bracketed-transaction spans."
  @spec transaction_event() :: [atom()]
  def transaction_event, do: @transaction

  @doc "The event prefix for sign-in spans."
  @spec sign_in_event() :: [atom()]
  def sign_in_event, do: @sign_in

  @doc "The event emitted when a call stops retrying."
  @spec retry_exhausted_event() :: [atom()]
  def retry_exhausted_event, do: @retry_exhausted

  @doc false
  @spec span_operation(map(), (-> {term(), map()})) :: term()
  def span_operation(metadata, fun), do: :telemetry.span(@operation, metadata, fun)

  @doc false
  @spec span_request(map(), (-> {term(), map()})) :: term()
  def span_request(metadata, fun), do: :telemetry.span(@request, metadata, fun)

  @doc false
  @spec span_transaction(map(), (-> {term(), map()})) :: term()
  def span_transaction(metadata, fun), do: :telemetry.span(@transaction, metadata, fun)

  @doc false
  @spec retry_exhausted(map(), map()) :: :ok
  def retry_exhausted(measurements, metadata) do
    :telemetry.execute(@retry_exhausted, measurements, metadata)
  end

  @doc false
  @spec span_sign_in(map(), (-> {term(), map()})) :: term()
  def span_sign_in(metadata, fun), do: :telemetry.span(@sign_in, metadata, fun)

  # ----------------------------------------------------------------------------
  # Default logger
  # ----------------------------------------------------------------------------

  @handler_id "typedb-default-logger"

  @logged [
    @operation ++ [:stop],
    @operation ++ [:exception],
    @transaction ++ [:stop],
    @retry_exhausted,
    @sign_in ++ [:stop]
  ]

  @doc """
  Logs one line per operation, transaction, sign-in and give-up.

  The gap between "the driver emits telemetry" and "I can see what my
  application is doing" is otherwise an afternoon of handler plumbing per
  project. Call this once, from your application's `start/2`:

      TypeDB.Telemetry.attach_default_logger(:info)

  Give-ups are always logged at `:warning`, whatever level you pass, because
  they mean something upstream is broken.

  This is independent of the driver's own logging, which `:log_level` on the
  connection controls; silencing one does not silence the other. Nothing is
  attached unless you ask, so a library that depends on this driver does not
  make your logs noisier.

  ## Options

    * `:level` — the level for ordinary lines. Defaults to `:info`.

  Returns `{:error, :already_exists}` if it is already attached.
  """
  @spec attach_default_logger(Logger.level() | keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(level_or_opts \\ :info)

  def attach_default_logger(level) when is_atom(level) do
    attach_default_logger(level: level)
  end

  def attach_default_logger(opts) when is_list(opts) do
    level = Keyword.get(opts, :level, :info)

    # A remote capture rather than an anonymous function: telemetry logs a
    # performance warning for local handlers, and it is right to.
    :telemetry.attach_many(@handler_id, @logged, &__MODULE__.handle_event/4, %{level: level})
  end

  @doc "Removes the handler `attach_default_logger/1` installed."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@handler_id)

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, config)

  def handle_event([:typedb, :operation, :stop], %{duration: duration}, metadata, config) do
    log(config, metadata, fn ->
      [
        "TypeDB ",
        metadata.method |> Atom.to_string() |> String.upcase(),
        " ",
        metadata.route,
        " ",
        ms(duration),
        attempts(metadata),
        outcome(metadata)
      ]
    end)
  end

  def handle_event([:typedb, :operation, :exception], %{duration: duration}, metadata, config) do
    log(config, metadata, fn ->
      ["TypeDB ", metadata.route, " raised after ", ms(duration)]
    end)
  end

  def handle_event([:typedb, :transaction, :stop], %{duration: duration}, metadata, config) do
    log(config, metadata, fn ->
      [
        "TypeDB transaction ",
        Atom.to_string(metadata.type),
        " on ",
        metadata.database,
        " ",
        ms(duration),
        " outcome=",
        metadata |> Map.get(:outcome, :error) |> Atom.to_string()
      ]
    end)
  end

  def handle_event([:typedb, :sign_in, :stop], %{duration: duration}, metadata, config) do
    log(config, metadata, fn -> ["TypeDB sign-in ", ms(duration), outcome(metadata)] end)
  end

  def handle_event([:typedb, :retry, :exhausted], %{attempts: attempts}, metadata, _config) do
    Logger.warning(
      fn ->
        [
          "TypeDB gave up on ",
          metadata.route,
          " after ",
          Integer.to_string(attempts),
          " attempts",
          outcome(metadata)
        ]
      end,
      typedb_connection: metadata[:connection]
    )
  end

  defp log(%{level: level}, metadata, message) do
    Logger.log(level, message, typedb_connection: metadata[:connection])
  end

  defp ms(duration) do
    [duration |> System.convert_time_unit(:native, :microsecond) |> div(100) |> divide_by_ten(), "ms"]
  end

  defp divide_by_ten(tenths),
    do: [Integer.to_string(div(tenths, 10)), ".", Integer.to_string(rem(tenths, 10))]

  defp attempts(%{attempts: attempts}) when attempts > 1, do: [" attempts=", Integer.to_string(attempts)]
  defp attempts(_metadata), do: []

  defp outcome(%{error: %{kind: kind} = error}),
    do: [" ", Atom.to_string(kind), ": ", Exception.message(error)]

  defp outcome(_metadata), do: []
end
