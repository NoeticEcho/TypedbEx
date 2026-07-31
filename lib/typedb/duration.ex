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

  When the duration was parsed from the wire, the original string is returned
  verbatim.
  """
  @spec to_iso8601(t()) :: String.t()
  def to_iso8601(%__MODULE__{raw: raw}) when is_binary(raw), do: raw

  def to_iso8601(%__MODULE__{months: months, days: days, nanos: nanos}) do
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

  defp take_component(string) do
    case Regex.run(~r/^(\d+(?:[.,]\d+)?)([A-Z])(.*)$/, string) do
      [_, number, unit, rest] ->
        case parse_number(number) do
          {:ok, value} -> {:ok, value, unit, rest}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  defp parse_number(number) do
    normalised = String.replace(number, ",", ".")

    if String.contains?(normalised, ".") do
      case Float.parse(normalised) do
        {value, ""} -> {:ok, value}
        _ -> :error
      end
    else
      case Integer.parse(normalised) do
        {value, ""} -> {:ok, value}
        _ -> :error
      end
    end
  end

  defp get(components, unit), do: Map.get(components, unit, 0)
end
