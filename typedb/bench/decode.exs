# Decoding and casting, which happen once per value in every answer — so they
# are the part of the driver that scales with the size of your result set
# rather than with the number of requests.
#
#     mix run bench/decode.exs

defmodule Bench do
  def time(label, count, fun) do
    fun.()
    {us, _} = :timer.tc(fun)
    per = us / count

    IO.puts([
      String.pad_trailing(label, 38),
      String.pad_leading("#{div(us, 1000)}ms", 8),
      String.pad_leading("#{Float.round(per, 3)}µs/value", 18),
      String.pad_leading("#{round(count / (us / 1_000_000))}/s", 14)
    ])
  end
end

n = 50_000

IO.puts("#{n} values each, Decimal #{if Code.ensure_loaded?(Decimal), do: "present", else: "ABSENT"}\n")

strings = for i <- 1..n, do: "value-#{i}"
integers = Enum.to_list(1..n)
decimals = for i <- 1..n, do: "#{i}.#{rem(i, 997)}dec"
durations = for i <- 1..n, do: "P#{rem(i, 12) + 1}Y2M3DT4H5M#{rem(i, 60)}S"
datetimes = for i <- 1..n, do: "2024-03-01T10:30:#{String.pad_leading("#{rem(i, 60)}", 2, "0")}.000000000 Europe/London"

Bench.time("cast string", n, fn -> Enum.each(strings, &TypeDB.Concept.cast(&1, "string")) end)
Bench.time("cast integer", n, fn -> Enum.each(integers, &TypeDB.Concept.cast(&1, "integer")) end)
Bench.time("cast decimal", n, fn -> Enum.each(decimals, &TypeDB.Concept.cast(&1, "decimal")) end)
Bench.time("cast duration", n, fn -> Enum.each(durations, &TypeDB.Concept.cast(&1, "duration")) end)
Bench.time("cast datetime-tz", n, fn -> Enum.each(datetimes, &TypeDB.Concept.cast(&1, "datetime-tz")) end)

# The control for the decimal path: `Code.ensure_loaded?/1` is a cached lookup
# for a module that is loaded and a code-server round trip for one that is not.
# `TypeDB.Concept` asks it once per VM for exactly this reason — without that,
# `cast decimal` above costs this much *per value* for anyone without Decimal.
Bench.time("Code.ensure_loaded?(Decimal)", n, fn ->
  Enum.each(1..n, fn _ -> Code.ensure_loaded?(Decimal) end)
end)

rows =
  for i <- 1..2_000 do
    %{
      "data" => %{
        "p" => %{"kind" => "entity", "iid" => "0x1e0#{i}", "type" => %{"kind" => "entityType", "label" => "person"}},
        "name" => %{"kind" => "attribute", "iid" => "0x8f#{i}", "value" => "Alice #{i}", "valueType" => "string"},
        "age" => %{"kind" => "attribute", "iid" => "0x9f#{i}", "value" => 30, "valueType" => "integer"}
      }
    }
  end

answer = %{"answerType" => "conceptRows", "queryType" => "read", "answers" => rows}

IO.puts("")
Bench.time("decode a 2,000-row answer", 2_000, fn -> {:ok, _} = TypeDB.Answer.decode(answer) end)

{:ok, decoded} = TypeDB.Answer.decode(answer)

Bench.time("to_map over 2,000 rows", 2_000, fn ->
  Enum.each(decoded, &TypeDB.ConceptRow.to_map/1)
end)
