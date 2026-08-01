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
    * `:status` — HTTP status, on `:stop` only
    * `:error` — the `TypeDB.Error` when one was produced, on `:stop` only

  ## `[:typedb, :sign_in, :start | :stop | :exception]`

  One span per sign-in. A healthy connection produces one on start-up and one
  per token lifetime; a spike means tokens are being rejected.

  Metadata: `:connection`, and `:error` on failure.

  ## Example

      :telemetry.attach_many(
        "typedb-logger",
        [[:typedb, :request, :stop], [:typedb, :sign_in, :stop]],
        fn event, %{duration: duration}, metadata, _config ->
          Logger.info("\#{inspect(event)} \#{System.convert_time_unit(duration, :native, :millisecond)}ms " <>
                        "\#{inspect(Map.take(metadata, [:method, :path, :status]))}")
        end,
        nil
      )

  ## Prometheus / `telemetry_metrics`

      Telemetry.Metrics.distribution("typedb.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :status]
      )
  """

  @operation [:typedb, :operation]
  @request [:typedb, :request]
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
  @spec span_sign_in(map(), (-> {term(), map()})) :: term()
  def span_sign_in(metadata, fun), do: :telemetry.span(@sign_in, metadata, fun)
end
