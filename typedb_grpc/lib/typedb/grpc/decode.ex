defmodule TypeDB.GRPC.Decode do
  @moduledoc """
  Protobuf concepts into the structs `typedb` already defines.

  Not a parallel set of types: an application that matches on
  `%TypeDB.Concept.Attribute{}` must keep matching after it switches transports,
  so this decodes into exactly those structs. Where the two wire formats
  disagree, this module is the side that moves.

  ## They disagree about almost every value

  The HTTP API sends values as JSON, which means everything TypeDB has no JSON
  equivalent for arrives as a string to be parsed — a decimal, a datetime, a
  duration. Protobuf sends them structured, so the work here is the opposite
  shape: assembling an Elixir term out of fields rather than parsing text.

    * a decimal is `integer` plus `fractional`, where `fractional` counts
      1/10^19ths — TypeDB's fixed scale, not a digit count
    * a date is days since 0001-01-01, day 1 being that date
    * a datetime is seconds since the epoch plus nanoseconds
    * a duration is months, days and nanos held apart, exactly as TypeQL's
      grammar keeps them, which is why `TypeDB.Duration` can be built from it
      without going through text at all

  That last one is a small win over the HTTP transport: this driver never has to
  emit or parse an ISO-8601 duration, so the negative-component problem the
  sibling documents cannot arise here.
  """

  alias TypeDB.{Concept, ConceptRow, Duration}
  alias Typedb.Protocol, as: Proto

  # TypeDB's decimal has a fixed fractional scale of 19 digits.
  @decimal_scale 19

  @doc """
  A `Typedb.Protocol.ConceptRow` and its column names into a `TypeDB.ConceptRow`.
  """
  @spec row(Proto.ConceptRow.t(), [String.t()]) :: ConceptRow.t()
  def row(%Proto.ConceptRow{row: entries, involved_blocks: blocks}, columns) do
    data =
      columns
      |> Enum.zip(entries)
      |> Map.new(fn {column, entry} -> {column, entry(entry)} end)

    %ConceptRow{data: data, involved_blocks: involved_blocks(blocks)}
  end

  @doc """
  A protobuf `Concept` into a `TypeDB.Concept` struct.

  `nil` for a `Concept` whose `oneof` is unset — which a server of a newer
  protocol can send, carrying a kind of concept this build has no schema for.
  Decoding the rest of the answer and leaving one column empty is better than
  failing the whole read.
  """
  @spec concept(Proto.Concept.t()) :: Concept.t() | nil
  def concept(%Proto.Concept{concept: {_tag, value}}), do: thing(value)
  def concept(%Proto.Concept{concept: nil}), do: nil

  @doc "A protobuf `Value` into the Elixir term it stands for."
  @spec value(Proto.Value.t()) :: term()
  def value(%Proto.Value{value: {tag, payload}}), do: scalar(tag, payload)
  def value(%Proto.Value{value: nil}), do: nil

  @doc """
  The name TypeDB gives the value type of a `Value`, matching the strings the
  HTTP API uses so that `%TypeDB.Concept.Value{value_type: ...}` reads the same
  on both transports.
  """
  @spec value_type(Proto.Value.t()) :: String.t() | nil
  def value_type(%Proto.Value{value: {tag, _}}), do: value_type_name(tag)
  def value_type(%Proto.Value{value: nil}), do: nil

  # -- rows ------------------------------------------------------------------

  defp entry(%Proto.RowEntry{entry: {:empty, _}}), do: nil
  defp entry(%Proto.RowEntry{entry: {:concept, concept}}), do: concept(concept)
  defp entry(%Proto.RowEntry{entry: {:value, value}}), do: value_concept(value)

  defp entry(%Proto.RowEntry{entry: {:concept_list, %{concepts: concepts}}}),
    do: Enum.map(concepts, &concept/1)

  defp entry(%Proto.RowEntry{entry: {:value_list, %{values: values}}}),
    do: Enum.map(values, &value_concept/1)

  defp entry(%Proto.RowEntry{entry: nil}), do: nil
  defp entry(nil), do: nil

  # `involved_blocks` is an optional bitmap of which query blocks produced the
  # row. The HTTP API sends a list of integers; this sends packed bytes, so it
  # is unpacked to the same shape rather than handed over raw.
  defp involved_blocks(nil), do: nil
  defp involved_blocks(""), do: nil

  defp involved_blocks(bytes) when is_binary(bytes) do
    for {byte, index} <- Enum.with_index(:binary.bin_to_list(bytes)),
        bit <- 0..7,
        Bitwise.band(byte, Bitwise.bsl(1, bit)) != 0,
        do: index * 8 + bit
  end

  # -- concepts --------------------------------------------------------------

  defp thing(%Proto.Entity{iid: iid, entity_type: type}) do
    %Concept.Entity{iid: iid(iid), type: entity_type(type)}
  end

  defp thing(%Proto.Relation{iid: iid, relation_type: type}) do
    %Concept.Relation{iid: iid(iid), type: relation_type(type)}
  end

  defp thing(%Proto.Attribute{iid: iid, attribute_type: type, value: value}) do
    %Concept.Attribute{
      iid: iid(iid),
      value: value(value),
      value_type: value_type(value),
      type: attribute_type(type)
    }
  end

  defp thing(%Proto.EntityType{} = type), do: entity_type(type)
  defp thing(%Proto.RelationType{} = type), do: relation_type(type)
  defp thing(%Proto.AttributeType{} = type), do: attribute_type(type)
  defp thing(%Proto.RoleType{label: label}), do: %Concept.RoleType{label: label}

  defp entity_type(nil), do: nil
  defp entity_type(%Proto.EntityType{label: label}), do: %Concept.EntityType{label: label}

  defp relation_type(nil), do: nil
  defp relation_type(%Proto.RelationType{label: label}), do: %Concept.RelationType{label: label}

  defp attribute_type(nil), do: nil

  defp attribute_type(%Proto.AttributeType{label: label, value_type: value_type}) do
    %Concept.AttributeType{label: label, value_type: declared_value_type(value_type)}
  end

  defp declared_value_type(nil), do: nil
  defp declared_value_type(%Proto.ValueType{value_type: {tag, _}}), do: value_type_name(tag)
  defp declared_value_type(%Proto.ValueType{value_type: nil}), do: nil

  defp value_concept(%Proto.Value{} = value) do
    %Concept.Value{value: value(value), value_type: value_type(value)}
  end

  # TypeDB sends an iid as raw bytes; the HTTP API renders it as lowercase hex,
  # and that rendering is what applications have stored and compared against.
  defp iid(nil), do: nil
  defp iid(""), do: nil
  defp iid(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)

  # -- values ----------------------------------------------------------------

  defp scalar(:boolean, value), do: value
  defp scalar(:integer, value), do: value
  defp scalar(:double, value), do: value
  defp scalar(:string, value), do: value

  defp scalar(:decimal, %Proto.Value.Decimal{integer: whole, fractional: fractional}) do
    decimal(whole, fractional)
  end

  defp scalar(:date, %Proto.Value.Date{num_days_since_ce: days}) do
    # Day 1 is 0001-01-01, so the count is one-based and Date.add/2 is not.
    Date.add(~D[0001-01-01], days - 1)
  end

  defp scalar(:datetime, %Proto.Value.Datetime{} = datetime), do: naive(datetime)

  defp scalar(:datetime_tz, %Proto.Value.Datetime_TZ{datetime: datetime, timezone: timezone}) do
    datetime_tz(naive(datetime), timezone)
  end

  defp scalar(:duration, %Proto.Value.Duration{months: months, days: days, nanos: nanos}) do
    %Duration{months: months, days: days, nanos: nanos}
  end

  # A struct value carries only its type name over this transport, which is not
  # enough to build anything from. Returned as the name rather than as nil, so a
  # caller can at least tell what it was.
  defp scalar(:struct, %Proto.Value.Struct{struct_type_name: name}), do: {:struct, name}

  defp naive(%Proto.Value.Datetime{seconds: seconds, nanos: nanos}) do
    DateTime.from_unix!(seconds * 1_000_000_000 + nanos, :nanosecond)
  end

  defp datetime_tz(datetime, {:named, zone}) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> shifted
      # No tzdata in the host application. The instant is right and the zone is
      # not applied, which is better than failing to decode an answer.
      {:error, _} -> datetime
    end
  end

  defp datetime_tz(datetime, {:offset, seconds}) do
    %{
      datetime
      | utc_offset: seconds,
        std_offset: 0,
        zone_abbr: offset_abbr(seconds),
        time_zone: offset_abbr(seconds)
    }
  end

  defp datetime_tz(datetime, nil), do: datetime

  defp offset_abbr(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(div(seconds, 60))
    "#{sign}#{pad(div(total, 60))}:#{pad(rem(total, 60))}"
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # `Decimal` is optional in the sibling package, and naming it in a compile-time
  # expansion is what breaks the build for anyone who left it out — so it is
  # reached for at runtime and the fallback is a float, which is what the sibling
  # does with the same value.
  defp decimal(whole, fractional) do
    if Code.ensure_loaded?(Decimal) do
      sign = if whole < 0, do: -1, else: 1
      unscaled = abs(whole) * pow10(@decimal_scale) + fractional

      # Bound to a variable rather than written literally: `Decimal` is optional
      # in the sibling package, and naming it in a compile-time expansion is
      # what breaks the build for anyone who left it out.
      decimal = Decimal
      decimal.new(sign, unscaled, -@decimal_scale)
    else
      whole + fractional / pow10(@decimal_scale)
    end
  end

  defp pow10(n), do: Integer.pow(10, n)

  # -- names -----------------------------------------------------------------

  defp value_type_name(:boolean), do: "boolean"
  defp value_type_name(:integer), do: "integer"
  defp value_type_name(:double), do: "double"
  defp value_type_name(:decimal), do: "decimal"
  defp value_type_name(:string), do: "string"
  defp value_type_name(:date), do: "date"
  defp value_type_name(:datetime), do: "datetime"
  defp value_type_name(:datetime_tz), do: "datetime-tz"
  defp value_type_name(:duration), do: "duration"
  defp value_type_name(:struct), do: "struct"
end
