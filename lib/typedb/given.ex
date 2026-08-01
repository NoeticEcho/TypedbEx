defmodule TypeDB.Given do
  @moduledoc """
  Encodes input rows for TypeQL's `given` stage (TypeDB 3.12+).

  A `given` stage binds variables to rows supplied *beside* the query, and runs
  the rest of the pipeline once per row. That makes it both the fast way to write
  many rows — one request, one query compilation — and the only safe way to put
  user input into a query.

      TypeDB.query(conn, "social", \"""
        given $n: string;
        insert $p isa person, has name == $n;
      \""", given_rows: [%{"n" => "Alice"}, %{"n" => "Bob"}])

  ## Why the driver encodes values

  The HTTP API accepts a bare JSON string for a row entry, but TypeDB then parses
  it as a TypeQL *literal*, so a value containing a quote is a parse error — and
  the escaping rules are TypeQL's, not JSON's. The tagged form
  (`%{"kind" => "value", "value" => …, "valueType" => …}`) is quoted by JSON
  itself and is therefore exact for arbitrary content.

  This module always emits the tagged form, so `given_rows` is safe against
  TypeQL injection for any input, including quotes, semicolons and newlines. Pass
  plain Elixir terms and let it do the encoding.

  ## Supported terms

  | Elixir | TypeDB |
  | --- | --- |
  | `String.t()` | `string` |
  | `integer()` | `integer` |
  | `float()` | `double` |
  | `boolean()` | `boolean` |
  | `Date.t()` | `date` |
  | `NaiveDateTime.t()` | `datetime` |
  | `DateTime.t()` / `TypeDB.DateTimeTZ.t()` | `datetime-tz` |
  | `TypeDB.Duration.t()` | `duration` |
  | `Decimal.t()` | `decimal` |
  | `nil` | an unbound optional column |
  | `TypeDB.Concept.Entity` / `Relation` / `Attribute` / `Value` | the concept itself |

  Concepts returned by a previous query can be fed straight back in, which is how
  you bind a `given $p: person;` column.

  A map that already carries a `"kind"` key is passed through untouched, as an
  escape hatch for wire forms this module does not build. That escape hatch is
  *not* injection-safe — it is the one input this module does not tag — so build
  it from your own code, never from a user's value.

  ## Examples

      iex> TypeDB.Given.encode("Alice")
      %{"kind" => "value", "value" => "Alice", "valueType" => "string"}

  A value that would end a TypeQL string literal is data here, not syntax, which
  is the whole point:

      iex> TypeDB.Given.encode(~S|Robert"); drop|)
      %{"kind" => "value", "value" => ~S|Robert"); drop|, "valueType" => "string"}
  """

  alias TypeDB.{Concept, DateTimeTZ, Duration, Error}

  @compile {:no_warn_undefined, Decimal}

  @typedoc "One input row: variable name to value."
  @type row :: %{optional(String.t() | atom()) => term()}

  @doc """
  Encodes a list of rows into the HTTP wire format.

  Returns `nil` for `nil`, so it can be applied unconditionally to an optional
  `:given_rows` option.
  """
  @spec encode_rows([row()] | nil) :: [map()] | nil
  def encode_rows(nil), do: nil

  def encode_rows(rows) when is_list(rows) do
    Enum.map(rows, &encode_row/1)
  end

  def encode_rows(other) do
    raise Error.new(
            :encode,
            "invalid :given_rows #{inspect(other)}, expected a list of maps of variable name to value"
          )
  end

  @doc """
  Encodes a single row.
  """
  @spec encode_row(row()) :: map()
  def encode_row(row) when is_map(row) and not is_struct(row) do
    Map.new(row, fn {variable, value} -> {to_string(variable), encode(value)} end)
  end

  def encode_row(other) do
    raise Error.new(
            :encode,
            "invalid given row #{inspect(other)}, expected a map of variable name to value"
          )
  end

  @doc """
  Encodes a single value into its tagged wire form.
  """
  @spec encode(term()) :: map() | nil
  def encode(nil), do: nil

  # Already in wire form: pass through so callers can hand back anything the
  # server produced, or hand-build a payload this module does not cover.
  def encode(%{"kind" => _} = wire), do: wire

  def encode(%Concept.Entity{iid: iid}), do: %{"kind" => "entity", "iid" => iid}
  def encode(%Concept.Relation{iid: iid}), do: %{"kind" => "relation", "iid" => iid}

  def encode(%Concept.Attribute{iid: iid, value: value, value_type: value_type}) do
    %{"kind" => "attribute", "iid" => iid, "value" => value, "valueType" => value_type}
  end

  def encode(%Concept.Value{value: value, value_type: value_type}), do: value(value, value_type)

  def encode(value) when is_boolean(value), do: value(value, "boolean")
  def encode(value) when is_binary(value), do: value(value, "string")
  def encode(value) when is_integer(value), do: value(value, "integer")
  def encode(value) when is_float(value), do: value(value, "double")

  def encode(%Date{} = date), do: value(Date.to_iso8601(date), "date")
  def encode(%NaiveDateTime{} = naive), do: value(NaiveDateTime.to_iso8601(naive), "datetime")
  def encode(%DateTimeTZ{} = datetime), do: value(DateTimeTZ.to_iso8601(datetime), "datetime-tz")
  def encode(%Duration{} = duration), do: value(Duration.to_iso8601(duration), "duration")

  def encode(%DateTime{} = datetime) do
    # TypeQL's datetime-tz literal is a naive timestamp followed by an offset or
    # an IANA zone name; ISO-8601's "Z" is not one of its accepted forms.
    naive = datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    value(naive <> offset(datetime), "datetime-tz")
  end

  def encode(%struct{} = decimal) when struct == Decimal do
    value(Decimal.to_string(decimal, :normal), "decimal")
  end

  def encode(other) do
    raise Error.new(
            :encode,
            "cannot encode #{inspect(other)} as a TypeDB value. " <>
              "Supported: string, integer, float, boolean, Date, NaiveDateTime, DateTime, " <>
              "TypeDB.DateTimeTZ, TypeDB.Duration, Decimal, TypeDB concepts, and nil."
          )
  end

  defp value(value, value_type), do: %{"kind" => "value", "value" => value, "valueType" => value_type}

  defp offset(%DateTime{utc_offset: utc_offset, std_offset: std_offset}) do
    total = utc_offset + std_offset
    sign = if total < 0, do: "-", else: "+"
    total = abs(total)

    hours = total |> div(3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = total |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{hours}:#{minutes}"
  end
end
