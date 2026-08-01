# Telemetry and logging

## Just show me what it is doing

```elixir
TypeDB.Telemetry.attach_default_logger(:info)
```

One line per operation, transaction, sign-in and give-up. Off unless you ask, so
a library that depends on this driver does not make your logs noisier.

```
[info] TypeDB GET /databases/:name 4.1ms
[info] TypeDB transaction write on social 12.7ms outcome=commit
[warning] TypeDB gave up on /query after 3 attempts server: [server 503] SRV9: unavailable
```

## Three levels, and which one answers your question

| event | one span per | answers |
| --- | --- | --- |
| `[:typedb, :transaction, …]` | bracketed transaction | how long a unit of work held a transaction |
| `[:typedb, :operation, …]` | API call | how long a query took, retries included |
| `[:typedb, :request, …]` | HTTP attempt | how the network behaved |

They nest. Building request rates on `[:typedb, :request, :stop]` overcounts,
because a retried call emits several — that is the event for "how is the network
today", not "how many queries did we run".

`[:typedb, :retry, :exhausted]` is not a span but a single event, fired when a
call stops retrying. It is the one to alert on: a retry that succeeds is the
driver doing its job, and a retry that runs out is something upstream broken for
longer than the configuration was willing to wait.

## Metrics

Tag on `:route`, never on `:path`. The route is a template —
`"/transactions/:id/query"` — while the path contains the transaction id, so a
metric tagged by it grows without bound.

```elixir
def metrics do
  [
    Telemetry.Metrics.distribution("typedb.operation.stop.duration",
      unit: {:native, :millisecond},
      tags: [:route, :database]
    ),
    Telemetry.Metrics.counter("typedb.operation.stop.count", tags: [:route]),
    Telemetry.Metrics.counter("typedb.retry.exhausted.attempts", tags: [:route]),
    Telemetry.Metrics.distribution("typedb.transaction.stop.duration",
      unit: {:native, :millisecond},
      tags: [:database, :type, :outcome]
    )
  ]
end
```

`:database` is on every event that names one, including `/v1/query`, which
carries it in the request body rather than the path.

`:outcome` on a transaction span is `:commit`, `:rollback`, `:close` or
`:commit_failed`. A ratio of `:commit_failed` to `:commit` is a contention
graph, and it is the number that tells you whether to widen a transaction or
narrow it.

## Counting retries without counting attempts

The `:attempts` measurement on an operation span is `1` on the happy path. Two
useful things fall out of it:

```elixir
Telemetry.Metrics.distribution("typedb.operation.stop.attempts", tags: [:route])
```

A p99 above 1 means the network is unreliable. A rising `retry.exhausted` count
means retrying is no longer enough.

## Logging

The driver logs sparingly and nothing at all on the happy path:

| level | when |
| --- | --- |
| `debug` | a request is about to be retried |
| `debug` | a connection received a message it does not understand |
| `warning` | retries were exhausted and the call is giving up |
| `warning` | a token renewal failed |
| `error` | a connection's transport died and the connection is stopping |

Every line carries `:typedb_connection`; retries and give-ups also carry
`:typedb_method`, `:typedb_path`, `:typedb_attempt` and `:typedb_error_kind`.
Keep them:

```elixir
config :logger, :default_formatter,
  metadata: [:typedb_connection, :typedb_error_kind, :typedb_attempt]
```

`:log_level` raises the floor for one connection, and `:none` silences it —
which is worth reaching for before you filter the whole application's Logger by
module:

```elixir
TypeDB.start_link(url: ..., log_level: :warning)   # keeps give-ups, drops retries
```

That is separate from `attach_default_logger/1`: one is the driver talking about
its own trouble, the other is you asking for a trace. Silencing one does not
silence the other.

Credentials never appear in a log line, in Logger metadata, or in a crash
report — see `TypeDB.Config` for how the connection keeps them out.

## Attaching by hand

```elixir
:telemetry.attach(
  "typedb-slow-queries",
  [:typedb, :operation, :stop],
  &MyApp.Telemetry.handle_typedb/4,
  nil
)

def handle_typedb(_event, %{duration: duration}, metadata, _config) do
  if System.convert_time_unit(duration, :native, :millisecond) > 500 do
    Logger.warning("slow TypeDB call",
      typedb_route: metadata.route,
      typedb_database: metadata[:database]
    )
  end
end
```

A remote capture rather than an anonymous function: telemetry logs a performance
warning for local handlers, and it is right to.
