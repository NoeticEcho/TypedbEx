# What "answers arrive whole" costs. The HTTP API does not stream, so a `match`
# is materialised on the server, shipped, and decoded into one term in your
# process — and the README's first limitation says so without saying how much.
#
#     docker compose up -d
#     TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/answer_size.exs
#
# Measures the wire bytes and the decoded term for the same answer, at a row
# count big enough that the per-answer overhead does not dominate.

url = System.get_env("TYPEDB_BENCH_URL", "http://127.0.0.1:8000")
username = System.get_env("TYPEDB_BENCH_USERNAME", "admin")
password = System.get_env("TYPEDB_BENCH_PASSWORD", "password")
rows = String.to_integer(System.get_env("TYPEDB_BENCH_ROWS", "20000"))

conn = :answer_size
{:ok, pid} = TypeDB.start_link(name: conn, url: url, username: username, password: password)

database = "answer_size_#{System.unique_integer([:positive])}"
:ok = TypeDB.Database.create(conn, database)

TypeDB.query!(conn, database, """
  define
    attribute name, value string;
    attribute age, value integer;
    entity person, owns name, owns age;
""")

IO.puts("inserting #{rows} rows")

# In batches: one insert of 20,000 statements is a query TypeDB has to parse in
# one go, and this is measuring answers rather than inserts.
1..rows
|> Enum.chunk_every(500)
|> Enum.each(fn chunk ->
  statements =
    Enum.map_join(chunk, " ", fn i ->
      ~s($p#{i} isa person, has name "person-#{i}", has age #{rem(i, 90)};)
    end)

  {:ok, _} = TypeDB.query(conn, database, "insert #{statements}", transaction_type: :write)
end)

query = "match $p isa person, has name $name, has age $age;"

# The raw response, straight from the adapter: what crossed the network, before
# any of it became an Elixir term. The connection publishes its adapter state
# and its token in its ETS table — which is what lets requests run in the
# caller's process, and what lets this script borrow both rather than
# re-implementing sign-in.
[{:http_state, adapter_state}] = :ets.lookup(conn, :http_state)
[{:token, token, _issued_at}] = :ets.lookup(conn, :token)

{:ok, %{body: body}} =
  TypeDB.HTTP.Finch.request(
    adapter_state,
    :post,
    "#{url}/v1/query",
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> token}
    ],
    JSON.encode_to_iodata!(%{
      "query" => query,
      "databaseName" => database,
      "transactionType" => "read"
    }),
    timeout: 120_000
  )

{query_us, {:ok, answer}} = :timer.tc(fn -> TypeDB.query(conn, database, query, transaction_type: :read) end)

wire = byte_size(body)
term = :erts_debug.size(answer) * :erlang.system_info(:wordsize)
maps = answer |> Enum.map(&TypeDB.ConceptRow.to_map/1) |> then(&(:erts_debug.size(&1) * :erlang.system_info(:wordsize)))
count = length(TypeDB.Answer.rows(answer))

report = fn label, bytes ->
  IO.puts([
    String.pad_trailing(label, 34),
    String.pad_leading("#{div(bytes, 1024)} KiB", 12),
    String.pad_leading("#{Float.round(bytes / count, 1)} B/row", 16)
  ])
end

IO.puts("\n#{count} rows, two attributes each\n")
report.("JSON on the wire", wire)
report.("decoded answer", term)
report.("the same rows as plain maps", maps)

# The whole call, not just the decode: the round trip and JSON parsing of a
# multi-megabyte body are the part that scales with the answer.
IO.puts("\nthe query took #{div(query_us, 1000)}ms end to end, #{Float.round(query_us / count, 1)}µs/row")

IO.puts("""

A million-row match, extrapolated: #{Float.round(term / count * 1_000_000 / 1024 / 1024 / 1024, 2)} GiB decoded.
:answer_count_limit is what stands between you and that.
""")

:ok = TypeDB.Database.delete(conn, database)
:ok = TypeDB.stop(pid)
