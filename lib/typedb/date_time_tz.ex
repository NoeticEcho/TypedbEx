defmodule TypeDB.DateTimeTZ do
  @moduledoc """
  A TypeDB `datetime-tz` value.

  TypeDB stores a wall-clock timestamp together with either an IANA time zone
  name or a fixed UTC offset, and renders them differently on the wire:

      "2024-03-01T10:30:00.000000000 Europe/London"   # IANA zone
      "2024-03-01T10:30:00.000000000+01:00"           # fixed offset

  Both parse into this struct. The distinction matters — an IANA zone survives
  daylight-saving transitions, a fixed offset does not — so the driver keeps it
  rather than flattening both into a `DateTime`.

      iex> tz = TypeDB.DateTimeTZ.parse("2024-03-01T10:30:00.000000000 Europe/London")
      iex> tz.time_zone
      "Europe/London"

  `raw` holds the original string; TypeDB renders nanoseconds, while
  `NaiveDateTime` only keeps microseconds.
  """

  @type t :: %__MODULE__{
          naive: NaiveDateTime.t(),
          time_zone: String.t() | nil,
          utc_offset: integer() | nil,
          raw: String.t()
        }

  @enforce_keys [:naive, :raw]
  defstruct [:naive, :time_zone, :utc_offset, :raw]

  @doc """
  Builds a value for writing, from a wall-clock time and a zone or offset.

  `parse/1` is how you get one *out* of TypeDB; this is how you make one to send
  back in, which otherwise meant formatting TypeDB's wire string yourself and
  putting it in `:raw`.

  The second argument is either an IANA zone name or a fixed UTC offset in
  seconds — the distinction TypeDB itself keeps, and the reason this module
  exists rather than a plain `DateTime`:

      iex> ~N[2024-03-01 10:30:00] |> TypeDB.DateTimeTZ.new("Europe/London") |> to_string()
      "2024-03-01T10:30:00.000000000 Europe/London"

      iex> ~N[2024-03-01 10:30:00] |> TypeDB.DateTimeTZ.new(3600) |> to_string()
      "2024-03-01T10:30:00.000000000+01:00"

  Rendered at nanosecond precision because that is what TypeDB stores and echoes
  back, so a value written this way and read again compares equal to itself.
  Pass the result straight to `given_rows`; see `TypeDB.Given`.
  """
  @spec new(NaiveDateTime.t(), String.t() | integer()) :: t()
  def new(%NaiveDateTime{} = naive, time_zone) when is_binary(time_zone) do
    %__MODULE__{naive: naive, time_zone: time_zone, raw: render(naive) <> " " <> time_zone}
  end

  def new(%NaiveDateTime{} = naive, utc_offset) when is_integer(utc_offset) do
    %__MODULE__{naive: naive, utc_offset: utc_offset, raw: render(naive) <> offset(utc_offset)}
  end

  # TypeDB renders nine fractional digits; NaiveDateTime keeps six at most.
  defp render(%NaiveDateTime{microsecond: {microsecond, _precision}} = naive) do
    fraction = microsecond |> Integer.to_string() |> String.pad_leading(6, "0")

    NaiveDateTime.to_iso8601(%{naive | microsecond: {0, 0}}) <> "." <> fraction <> "000"
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(seconds)
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))

    sign <> pad.(div(total, 3600)) <> ":" <> pad.(div(rem(total, 3600), 60))
  end

  @doc """
  Parses a TypeDB `datetime-tz` string.

  Returns the original string unchanged when it cannot be parsed.
  """
  @spec parse(String.t()) :: t() | String.t()
  def parse(string) when is_binary(string) do
    case from_iso8601(string) do
      {:ok, value} -> value
      :error -> string
    end
  end

  @doc """
  Parses a TypeDB `datetime-tz` string, returning `{:ok, value}` or `:error`.
  """
  @spec from_iso8601(String.t()) :: {:ok, t()} | :error
  def from_iso8601(string) when is_binary(string) do
    case String.split(string, " ", parts: 2) do
      [timestamp, zone] -> parse_zoned(string, timestamp, zone)
      [timestamp] -> parse_offset(string, timestamp)
    end
  end

  defp parse_zoned(raw, timestamp, zone) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, naive} -> {:ok, %__MODULE__{naive: naive, time_zone: zone, raw: raw}}
      {:error, _} -> :error
    end
  end

  defp parse_offset(raw, timestamp) do
    # NaiveDateTime.from_iso8601/1 accepts and then discards a trailing offset,
    # so the offset is extracted separately.
    with {:ok, naive} <- naive_from_iso8601(timestamp),
         {:ok, offset} <- extract_offset(timestamp) do
      {:ok, %__MODULE__{naive: naive, utc_offset: offset, raw: raw}}
    end
  end

  defp naive_from_iso8601(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, naive} -> {:ok, naive}
      {:error, _} -> :error
    end
  end

  defp extract_offset(timestamp) do
    case Regex.run(~r/(?:Z|([+-])(\d{2}):?(\d{2}))$/, timestamp) do
      ["Z"] ->
        {:ok, 0}

      [_, sign, hours, minutes] ->
        seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
        {:ok, if(sign == "-", do: -seconds, else: seconds)}

      nil ->
        # No offset at all: TypeDB always renders one for datetime-tz.
        :error
    end
  end

  @doc """
  Converts to a `DateTime`.

  Fixed-offset values convert without help. IANA-zoned values need a time zone
  database — pass one with `:time_zone_database`, or configure a global default
  via `Calendar.put_time_zone_database/1` (for example
  [tz](https://hex.pm/packages/tz) or [tzdata](https://hex.pm/packages/tzdata)).

  Ambiguous local times (the repeated hour when clocks go back) return
  `{:ambiguous, first, second}`; skipped times return `{:gap, before, after}`.
  """
  @spec to_datetime(t(), keyword()) ::
          {:ok, DateTime.t()}
          | {:ambiguous, DateTime.t(), DateTime.t()}
          | {:gap, DateTime.t(), DateTime.t()}
          | {:error, term()}
  def to_datetime(value, opts \\ [])

  def to_datetime(%__MODULE__{naive: naive, time_zone: nil, utc_offset: offset}, _opts)
      when is_integer(offset) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-offset, :second)
    |> DateTime.shift_zone("Etc/UTC")
  end

  def to_datetime(%__MODULE__{naive: naive, time_zone: zone}, opts) when is_binary(zone) do
    database = Keyword.get(opts, :time_zone_database, Calendar.get_time_zone_database())
    DateTime.from_naive(naive, zone, database)
  end

  def to_datetime(%__MODULE__{}, _opts), do: {:error, :incomplete}

  @doc """
  Renders back to the TypeDB wire format.

  Returns `:raw` verbatim — the exact string TypeDB sent, or the one `new/2`
  built. This struct is a decoded value, not a builder: editing `:naive`,
  `:time_zone` or `:utc_offset` on one you already have does not change what
  this renders. Build a new one with `new/2` instead.
  """
  @spec to_iso8601(t()) :: String.t()
  def to_iso8601(%__MODULE__{raw: raw}), do: raw

  defimpl String.Chars do
    def to_string(value), do: value.raw
  end
end
