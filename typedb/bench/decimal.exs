# The decimal path, which is the one cast whose cost depends on a dependency
# being installed.
#
#     mix run bench/decimal.exs
#
# `TypeDB.Concept.cast/2` used to ask `:persistent_term` once per value whether
# `Decimal` was available. That answer is now resolved when the module is
# compiled, in the direction where it cannot change afterwards — see
# `TypeDB.Concept` for why only that direction. This measures what that is
# worth, and the number is small and real rather than large and imagined.
#
# Run it in both configurations. The second needs the consumer application,
# which is the only place the optional dependencies are genuinely absent:
#
#     mix run bench/decimal.exs
#     cd test/support/consumer && mix deps.get && \
#       mix run ../../../bench/decimal.exs

Code.require_file("machine.exs", __DIR__)
Bench.Machine.puts()

n = 500_000
trials = 5

decimals = for i <- 1..n, do: "#{i}.#{rem(i, 997)}dec"

# The median of several trials, not one run: a single pass over half a million
# values lands within a few percent of its neighbours, and quoting the fastest
# would be quoting the weather.
median = fn label, fun ->
  fun.()

  us =
    1..trials
    |> Enum.map(fn _ -> elem(:timer.tc(fun), 0) end)
    |> Enum.sort()
    |> Enum.at(div(trials, 2))

  IO.puts([
    String.pad_trailing(label, 40),
    String.pad_leading("#{div(us, 1000)}ms", 8),
    String.pad_leading("#{Float.round(us / n, 4)}µs/value", 18),
    String.pad_leading("#{round(n / (us / 1_000_000))}/s", 14)
  ])
end

IO.puts("#{n} values, #{trials} trials, median reported")

# Observed rather than asked: the per-value branch writes this cache key on its
# first call and the compile-time branch never does. Reading it this way also
# lets the script run against an older checkout, which is how the before/after
# in CHANGELOG.md was measured.
:persistent_term.erase({TypeDB.Concept, :decimal?})
_ = TypeDB.Concept.cast("1.5dec", "decimal")

resolution =
  case :persistent_term.get({TypeDB.Concept, :decimal?}, :absent) do
    :absent -> "resolved at compile time"
    _ -> "resolved per value"
  end

IO.puts(
  "Decimal #{if Code.ensure_loaded?(Decimal), do: "present", else: "ABSENT"}, #{resolution}\n"
)

median.("cast decimal", fn -> Enum.each(decimals, &TypeDB.Concept.cast(&1, "decimal")) end)

# The two components, so the total above can be read rather than trusted.
median.("  String.trim_trailing/2 alone", fn ->
  Enum.each(decimals, &String.trim_trailing(&1, "dec"))
end)

median.("  :persistent_term.get/2 alone", fn ->
  Enum.each(decimals, fn _ -> :persistent_term.get({TypeDB.Concept, :decimal?}, :unasked) end)
end)

IO.puts("""

The third line is what the compile-time resolution removes from the first when
`Decimal` is present at compile time. When it is absent at compile time the
dynamic check stays, and that line is part of every decimal cast.
""")
