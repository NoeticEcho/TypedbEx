defmodule TypeDB.Duration do
  @moduledoc """
  A TypeDB `duration` value.

  TypeDB durations are ISO-8601 durations. They are *not* a fixed number of
  seconds: a month is a calendar month and a day is a calendar day, so they are
  kept as three independent components exactly as TypeDB stores them.

      iex> TypeDB.Duration.parse("P1Y2M3DT4H5M6.5S")
      %TypeDB.Duration{months: 14, days: 3, nanos: 14_706_500_000_000, raw: "P1Y2M3DT4H5M6.5S"}

  `raw` always holds the original wire representation, so nanosecond precision is
  never lost even when converting to coarser Elixir types.
  """

  @type t :: %__MODULE__{
          months: integer(),
          days: integer(),
          nanos: integer(),
          raw: String.t() | nil
        }

  defstruct months: 0, days: 0, nanos: 0, raw: nil

  @nanos_per_second 1_000_000_000

  @doc """
  Parses an ISO-8601 duration.

  Returns the original string unchanged if it cannot be parsed, so that an
  unexpected server-side format degrades instead of crashing.
  """
  @spec parse(String.t()) :: t() | String.t()
  def parse(string) when is_binary(string) do
    case do_parse(string) do
      {:ok, duration} -> %{duration | raw: string}
      :error -> string
    end
  end

  @doc """
  Parses an ISO-8601 duration, returning `{:ok, duration}` or `:error`.
  """
  @spec from_iso8601(String.t()) :: {:ok, t()} | :error
  def from_iso8601(string) when is_binary(string) do
    case do_parse(string) do
      {:ok, duration} -> {:ok, %{duration | raw: string}}
      :error -> :error
    end
  end

  @doc """
  Renders the duration back to ISO-8601.

  A duration that came off the wire renders as the exact string TypeDB sent, so
  nanosecond precision and TypeDB's own choice of units survive the round trip —
  but only while `raw` still describes the components. Edit any of `:months`,
  `:days` or `:nanos` and the components win, because otherwise a
  read-modify-write would silently send the *original* value back.

  Raises `TypeDB.Error` with kind `:encode` for a negative component — a
  deliberate, frozen choice, not an oversight. Rendering functions in Elixir
  raise on a value they cannot render (`Date.to_iso8601/1` does), returning
  `{:ok, string}` here would make every caller handle a case no driver-produced
  duration can be in, and normalising silently would send a value nobody asked
  for. TypeDB has no negative durations: TypeQL's grammar rejects `P-1Y`, `-P1Y` and every other form, and
  `P-1Y-2M` is misread as a *type label*, so the server answers "Type label
  'P-1Y-2M' not found". Failing here says what is actually wrong. Note this is a
  deliberate divergence from Elixir's own `Duration`, which does render
  `"P-14M"` — that type does calendar arithmetic, where a negative duration is
  meaningful; this one is a wire value for a database that has no such thing.
  """
  @spec to_iso8601(t()) :: String.t()
  def to_iso8601(%__MODULE__{raw: raw} = duration) when is_binary(raw) do
    # `raw` is set by `parse/1` on every duration the driver hands back, so
    # returning it unconditionally discarded every edit a caller made — with no
    # error, and no way to notice short of reading the database afterwards.
    if describes?(raw, duration), do: raw, else: render(duration)
  end

  def to_iso8601(%__MODULE__{} = duration), do: render(duration)

  # Whether the wire string still says what the components say.
  defp describes?(raw, %__MODULE__{months: months, days: days, nanos: nanos}) do
    case do_parse(raw) do
      {:ok, %__MODULE__{months: ^months, days: ^days, nanos: ^nanos}} -> true
      _other -> false
    end
  end

  defp render(%__MODULE__{months: months, days: days, nanos: nanos})
       when months < 0 or days < 0 or nanos < 0 do
    raise TypeDB.Error.new(
            :encode,
            "cannot render a negative duration as ISO-8601 " <>
              "(months: #{months}, days: #{days}, nanos: #{nanos}). " <>
              "TypeDB has no negative durations — TypeQL's grammar rejects every form of one."
          )
  end

  defp render(%__MODULE__{months: months, days: days, nanos: nanos}) do
    date_part =
      [{div(months, 12), "Y"}, {rem(months, 12), "M"}, {days, "D"}]
      |> Enum.reject(fn {value, _} -> value == 0 end)
      |> Enum.map_join(fn {value, unit} -> "#{value}#{unit}" end)

    time_part = time_part(nanos)

    case {date_part, time_part} do
      {"", ""} -> "PT0S"
      {date, ""} -> "P" <> date
      {date, time} -> "P" <> date <> "T" <> time
    end
  end

  defp time_part(0), do: ""

  defp time_part(nanos) do
    seconds_total = div(nanos, @nanos_per_second)
    remainder = rem(nanos, @nanos_per_second)

    hours = div(seconds_total, 3600)
    minutes = div(rem(seconds_total, 3600), 60)
    seconds = rem(seconds_total, 60)

    [{hours, "H"}, {minutes, "M"}]
    |> Enum.reject(fn {value, _} -> value == 0 end)
    |> Enum.map_join(fn {value, unit} -> "#{value}#{unit}" end)
    |> Kernel.<>(seconds_component(seconds, remainder))
  end

  defp seconds_component(0, 0), do: ""

  defp seconds_component(seconds, 0), do: "#{seconds}S"

  defp seconds_component(seconds, remainder) do
    fraction = remainder |> Integer.to_string() |> String.pad_leading(9, "0") |> String.trim_trailing("0")
    "#{seconds}.#{fraction}S"
  end

  @doc """
  Returns the time component in nanoseconds.

  Calendar components (`months`, `days`) are deliberately excluded — their length
  depends on the date they are applied to.
  """
  @spec time_in_nanoseconds(t()) :: integer()
  def time_in_nanoseconds(%__MODULE__{nanos: nanos}), do: nanos

  defp do_parse("P" <> rest) when rest != "" do
    case String.split(rest, "T", parts: 2) do
      [date] -> with {:ok, m, d} <- parse_date(date), do: {:ok, %__MODULE__{months: m, days: d}}
      ["", time] -> with {:ok, nanos} <- parse_time(time), do: {:ok, %__MODULE__{nanos: nanos}}
      [date, time] -> parse_both(date, time)
    end
  end

  defp do_parse(_other), do: :error

  defp parse_both(date, time) do
    with {:ok, months, days} <- parse_date(date),
         {:ok, nanos} <- parse_time(time) do
      {:ok, %__MODULE__{months: months, days: days, nanos: nanos}}
    end
  end

  defp parse_date(""), do: {:ok, 0, 0}

  defp parse_date(date) do
    with {:ok, components} <- components(date, ~w(Y M W D)) do
      months = get(components, "Y") * 12 + get(components, "M")
      days = get(components, "W") * 7 + get(components, "D")

      if integral?(months) and integral?(days) do
        {:ok, trunc(months), trunc(days)}
      else
        :error
      end
    end
  end

  defp parse_time(""), do: :error

  defp parse_time(time) do
    with {:ok, components} <- components(time, ~w(H M S)) do
      nanos =
        round(get(components, "H") * 3600 * @nanos_per_second) +
          round(get(components, "M") * 60 * @nanos_per_second) +
          round(get(components, "S") * @nanos_per_second)

      {:ok, nanos}
    end
  end

  defp integral?(value) when is_integer(value), do: true
  defp integral?(value) when is_float(value), do: Float.round(value) == value

  # Walks "1Y2M3D"-style segments left to right. Units must appear at most once
  # and in the canonical order; anything else is rejected rather than guessed at.
  defp components(string, allowed), do: components(string, allowed, %{})

  defp components("", _allowed, acc), do: {:ok, acc}

  defp components(string, allowed, acc) do
    with {:ok, value, unit, rest} <- take_component(string),
         true <- unit in allowed do
      remaining = allowed |> Enum.drop_while(&(&1 != unit)) |> Enum.drop(1)
      components(rest, remaining, Map.put(acc, unit, value))
    else
      _ -> :error
    end
  end

  # Was `Regex.run(~r/^(\d+(?:[.,]\d+)?)([A-Z])(.*)$/, string)`, which is the
  # obvious way to write this and cost 16µs a duration — forty times every other
  # cast in `bench/decode.exs`, because it ran once per component and its `(.*)`
  # copied the remainder each time. Measuring the number's length and slicing
  # does the same job for 1.6µs. The arithmetic is deliberately still
  # `Integer.parse/1` and `Float.parse/1` over the same substring: accumulating
  # the digits by hand would be faster again and would change which float a
  # fractional second rounds to, which is a nanosecond nobody asked to move.
  defp take_component(string) do
    with {:ok, length, separator} <- number_length(string, 0, false, nil),
         <<number::binary-size(^length), unit, rest::binary>> <- string,
         true <- unit in ?A..?Z,
         {:ok, value} <- parse_number(number, separator) do
      {:ok, value, <<unit>>, rest}
    else
      _ -> :error
    end
  end

  # Digits, then at most one `.` or `,`, then digits, reporting which separator
  # it saw so that the number can be parsed without being scanned again.
  # `digits?` is reset by the separator so that "1." and "1.Y" are rejected
  # rather than read as 1.
  defp number_length(<<digit, rest::binary>>, length, _digits?, separator)
       when digit in ?0..?9,
       do: number_length(rest, length + 1, true, separator)

  defp number_length(<<separator, rest::binary>>, length, true, nil)
       when separator in [?., ?,],
       do: number_length(rest, length + 1, false, separator)

  defp number_length(_rest, length, true, separator), do: {:ok, length, separator}
  defp number_length(_rest, _length, false, _separator), do: :error

  defp parse_number(number, nil) do
    case Integer.parse(number) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_number(number, ?.) do
    case Float.parse(number) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  # `Float.parse/1` stops at the comma, so ISO-8601's other decimal mark is the
  # one case that has to allocate.
  defp parse_number(number, ?,), do: parse_number(String.replace(number, ",", "."), ?.)

  defp get(components, unit), do: Map.get(components, unit, 0)
end
