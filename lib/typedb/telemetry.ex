defmodule TypeDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the driver.

  Attach to these to get request rates, latency and error breakdowns without
  instrumenting call sites.

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

  @request [:typedb, :request]
  @sign_in [:typedb, :sign_in]

  @doc "The event prefix for request spans."
  @spec request_event() :: [atom()]
  def request_event, do: @request

  @doc "The event prefix for sign-in spans."
  @spec sign_in_event() :: [atom()]
  def sign_in_event, do: @sign_in

  @doc false
  @spec span_request(map(), (-> {term(), map()})) :: term()
  def span_request(metadata, fun), do: :telemetry.span(@request, metadata, fun)

  @doc false
  @spec span_sign_in(map(), (-> {term(), map()})) :: term()
  def span_sign_in(metadata, fun), do: :telemetry.span(@sign_in, metadata, fun)
end
