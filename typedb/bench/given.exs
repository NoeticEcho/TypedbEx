# `TypeDB.Transaction.query/3` says a `given` stage "makes this the fast way to
# write many rows: one request and one query compilation instead of N". That is
# a performance claim, so it should have a number attached.
#
#     docker compose up -d
#     TYPEDB_BENCH_URL=http://localhost:8000 mix run bench/given.exs
#
# Three ways to write the same N rows:
#
#   * one request per row, which is what people write first
#   * one request whose query text contains N insert statements
#   * one request with a `given` stage and N rows beside the query
#
# The middle one is the honest competitor: it is also one request, so any
# difference between it and `given` is the query compilation and the string
# building, which is exactly what the claim is about.

url = System.get_env("TYPEDB_BENCH_URL", "http://127.0.0.1:8000")
username = System.get_env("TYPEDB_BENCH_USERNAME", "admin")
password = System.get_env("TYPEDB_BENCH_PASSWORD", "password")
rows = String.to_integer(System.get_env("TYPEDB_BENCH_ROWS", "2000"))

conn = :given_bench
{:ok, pid} = TypeDB.start_link(name: conn, url: url, username: username, password: password)

database = "given_bench_#{System.unique_integer([:positive])}"
:ok = TypeDB.Database.create(conn, database)

TypeDB.query!(conn, database, """
  define
    attribute name, value string;
    attribute age, value integer;
    entity person, owns name, owns age;
""")

names = fn prefix -> for i <- 1..rows, do: {"#{prefix}-#{i}", rem(i, 90)} end

time = fn label, fun ->
  {us, :ok} = :timer.tc(fun)

  IO.puts([
    String.pad_trailing(label, 30),
    String.pad_leading("#{div(us, 1000)}ms", 9),
    String.pad_leading("#{Float.round(us / rows, 1)}µs/row", 16),
    String.pad_leading("#{round(rows / (us / 1_000_000))} rows/s", 16)
  ])
end

IO.puts("#{rows} rows per strategy, against #{url}\n")

time.("one request per row", fn ->
  for {name, age} <- names.("per-request") do
    {:ok, _} =
      TypeDB.query(conn, database, ~s|insert $p isa person, has name "#{name}", has age #{age};|,
        transaction_type: :write
      )
  end

  :ok
end)

time.("one request, N statements", fn ->
  statements =
    names.("concatenated")
    |> Enum.map_join(" ", fn {name, age} ->
      ~s($#{String.replace(name, "-", "_")} isa person, has name "#{name}", has age #{age};)
    end)

  {:ok, _} = TypeDB.query(conn, database, "insert #{statements}", transaction_type: :write)
  :ok
end)

time.("one request, given rows", fn ->
  given = Enum.map(names.("given"), fn {name, age} -> %{"n" => name, "a" => age} end)

  {:ok, _} =
    TypeDB.query(
      conn,
      database,
      """
        given $n: string, $a: integer;
        insert $p isa person, has name == $n, has age == $a;
      """,
      transaction_type: :write,
      given_rows: given
    )

  :ok
end)

# Every strategy has to have written the same number of rows, or the comparison
# is between one of them and a mistake.
{:ok, total} =
  TypeDB.query(conn, database, "match $p isa person; reduce $n = count;", transaction_type: :read)

written = total |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("n")
IO.puts("\n#{written} rows written in total, expected #{rows * 3}")

:ok = TypeDB.Database.delete(conn, database)
:ok = TypeDB.stop(pid)
