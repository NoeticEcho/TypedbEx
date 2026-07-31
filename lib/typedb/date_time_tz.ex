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
  """
  @spec to_iso8601(t()) :: String.t()
  def to_iso8601(%__MODULE__{raw: raw}), do: raw

  defimpl String.Chars do
    def to_string(value), do: value.raw
  end
end
