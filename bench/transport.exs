# The three HTTP adapters, against a real server. This is where the driver's
# request rate comes from — one connection pool, N callers, no work in the
# connection process itself.
#
#     docker compose up -d
#     TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/transport.exs
#
# The numbers in CHANGELOG.md's "Verified under load" section come from here.

url = System.get_env("TYPEDB_BENCH_URL", "http://127.0.0.1:8000")
username = System.get_env("TYPEDB_BENCH_USERNAME", "admin")
password = System.get_env("TYPEDB_BENCH_PASSWORD", "password")

requests = String.to_integer(System.get_env("TYPEDB_BENCH_REQUESTS", "400"))
concurrencies = [1, 50, 200]

defmodule Bench do
  # Percentiles rather than a mean: the whole point of the comparison is that
  # one of the three adapters has a tail an order of magnitude longer than its
  # median, which an average hides.
  def report(label, elapsed_us, latencies) do
    sorted = Enum.sort(latencies)
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(n - 1, trunc(n * p))) / 1000 end

    IO.puts([
      String.pad_trailing(label, 22),
      String.pad_leading("#{round(n / (elapsed_us / 1_000_000))} req/s", 12),
      String.pad_leading("p50 #{Float.round(at.(0.50), 1)}ms", 16),
      String.pad_leading("p99 #{Float.round(at.(0.99), 1)}ms", 16),
      String.pad_leading("max #{Float.round(at.(1.0), 1)}ms", 16)
    ])
  end

  def burst(conn, database, concurrency, requests) do
    per_task = max(1, div(requests, concurrency))

    run = fn ->
      Task.async_stream(
        1..concurrency,
        fn _ ->
          for _ <- 1..per_task do
            {us, {:ok, _}} =
              :timer.tc(fn -> TypeDB.query(conn, database, "match $p isa person; limit 1;") end)

            us
          end
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, latencies} -> latencies end)
    end

    # One warm burst first: the pool is cold, and the driver signs in on its
    # first request, so an unwarmed run measures the handshake.
    _ = run.()
    {elapsed, latencies} = :timer.tc(run)
    {elapsed, latencies}
  end
end

adapters = [
  {"Finch", {TypeDB.HTTP.Finch, []}},
  {"Req", {TypeDB.HTTP.Req, []}},
  {":httpc", {TypeDB.HTTP.Httpc, []}}
]

IO.puts("#{requests} requests per run against #{url}\n")

for {label, adapter} <- adapters do
  # A registered name, not the pid: the config lives in an ETS table named
  # after the connection, so that requests run in the caller's process.
  conn = :"bench_#{System.unique_integer([:positive])}"

  {:ok, pid} =
    TypeDB.start_link(
      name: conn,
      url: url,
      username: username,
      password: password,
      http: adapter
    )

  database = "bench_#{System.unique_integer([:positive])}"
  :ok = TypeDB.Database.create(conn, database)

  {:ok, _} =
    TypeDB.query(conn, database, "define attribute name, value string; entity person, owns name;")

  {:ok, _} =
    TypeDB.query(conn, database, "insert $p isa person, has name 'bench';",
      transaction_type: :write
    )

  IO.puts(label)

  for concurrency <- concurrencies do
    {elapsed, latencies} = Bench.burst(conn, database, concurrency, requests)
    Bench.report("  #{concurrency}-way", elapsed, latencies)
  end

  IO.puts("")

  :ok = TypeDB.Database.delete(conn, database)
  :ok = TypeDB.stop(pid)
end
