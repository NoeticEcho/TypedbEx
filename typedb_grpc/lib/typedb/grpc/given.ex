defmodule TypeDB.GRPC.Given do
  @moduledoc false

  # Input rows for TypeQL's `given` stage, as protobuf.
  #
  # The counterpart of the sibling's `TypeDB.Given`, and called from the
  # *caller's* process rather than the transaction's. It used to run inside
  # `handle_call/3`, so a value it could not encode raised in the transaction's
  # own process: the transaction died, the caller saw the exit as `:transport`,
  # and whatever it had written so far was gone — for what was only ever a bad
  # argument. Encoding before the call means a bad value is an `:encode` error
  # and the transaction never hears of it.

  alias TypeDB.{Concept, Error}
  alias Typedb.Protocol, as: Proto

  @min_int64 -Bitwise.bsl(1, 63)
  @max_int64 Bitwise.bsl(1, 63) - 1

  @doc """
  Encodes `:given_rows` into `GivenRows`, or `nil` when there are none.

  Raises `TypeDB.Error` with kind `:encode` on anything it cannot encode.
  """
  @spec encode_rows(term()) :: Proto.Query.Req.GivenRows.t() | nil
  def encode_rows(nil), do: nil
  def encode_rows([]), do: nil

  def encode_rows(rows) when is_list(rows) do
    rows = Enum.map(rows, &row/1)
    variables = rows |> hd() |> Map.keys() |> Enum.sort()

    %Proto.Query.Req.GivenRows{
      variables: variables,
      rows:
        Enum.map(rows, fn row ->
          %Proto.Query.Req.GivenRow{entries: Enum.map(variables, &entry(Map.get(row, &1)))}
        end)
    }
  end

  def encode_rows(other) do
    raise Error.new(
            :encode,
            "invalid :given_rows #{inspect(other)}, expected a list of maps of variable name to value"
          )
  end

  # Atom keys are accepted, as the sibling accepts them; protobuf wants strings.
  defp row(row) when is_map(row) and not is_struct(row) do
    Map.new(row, fn {variable, value} -> {to_string(variable), value} end)
  end

  defp row(other) do
    raise Error.new(:encode, "invalid given row #{inspect(other)}, expected a map of variable name to value")
  end

  defp entry(nil), do: %Proto.Query.Req.GivenEntry{entry: {:empty, %Proto.Query.Req.GivenEntry.EmptyEntry{}}}
  defp entry(value), do: %Proto.Query.Req.GivenEntry{entry: {:value, value(value)}}

  @doc "Encodes one Elixir term as a protobuf `Value`."
  @spec value(term()) :: Proto.Value.t()
  def value(value) when is_boolean(value), do: %Proto.Value{value: {:boolean, value}}

  # Range-checked here because protobuf would otherwise raise on it while the
  # request is being sent — inside the transaction, which is the crash above.
  def value(value) when is_integer(value) and value in @min_int64..@max_int64,
    do: %Proto.Value{value: {:integer, value}}

  def value(value) when is_float(value), do: %Proto.Value{value: {:double, value}}

  def value(value) when is_binary(value) do
    if String.valid?(value) do
      %Proto.Value{value: {:string, value}}
    else
      raise Error.new(:encode, "cannot encode #{inspect(value)} as a TypeDB string: it is not valid UTF-8")
    end
  end

  def value(%Date{} = date) do
    %Proto.Value{value: {:date, %Proto.Value.Date{num_days_since_ce: Date.diff(date, ~D[0001-01-01]) + 1}}}
  end

  def value(%DateTime{} = datetime) do
    nanos = DateTime.to_unix(datetime, :nanosecond)

    %Proto.Value{
      value:
        {:datetime,
         %Proto.Value.Datetime{seconds: div(nanos, 1_000_000_000), nanos: rem(nanos, 1_000_000_000)}}
    }
  end

  # `NaiveDateTime` is TypeDB's `datetime`, and it is here because the sibling both writes
  # AND READS it: `TypeDB.Given` maps `NaiveDateTime.t()` to `datetime`, and
  # `TypeDB.Concept` decodes a `datetime` back into one. Without this clause a value read
  # from the graph could not be written back to it through this transport — the round trip
  # was broken in one direction only, which is the shape that survives a test suite.
  #
  # Measured 10.09.2026 in a consumer's migrator, which passes the moment a migration was
  # applied as a `given` row: `no TypeDB value for ~N[2026-09-10 18:01:03.282]`, and with
  # it every test that stands a graph up in `setup_all` — fourteen modules invalidated at
  # once, none of them about datetimes.
  #
  # Read as UTC deliberately. TypeDB's `datetime` carries no zone, so there is nothing to
  # convert *to* and nothing to guess: this encodes the wall clock it was given, which is
  # what the sibling's ISO-8601 string does as well.
  def value(%NaiveDateTime{} = naive) do
    nanos = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:nanosecond)

    %Proto.Value{
      value:
        {:datetime,
         %Proto.Value.Datetime{seconds: div(nanos, 1_000_000_000), nanos: rem(nanos, 1_000_000_000)}}
    }
  end

  def value(%TypeDB.Duration{months: months, days: days, nanos: nanos}) do
    %Proto.Value{value: {:duration, %Proto.Value.Duration{months: months, days: days, nanos: nanos}}}
  end

  # Experimental: needs a TypeDB build with vector support, and the wire format
  # may change.
  #
  # A vector is passed the way the sibling passes it, as a `TypeDB.Concept.Value`
  # whose `value_type` names the dimension and dtype, so one value works over
  # both transports. The protobuf message carries neither — only the floats — so
  # the declared dimension is checked here: over HTTP the server refuses a
  # mismatch, and over this transport it would otherwise never see one.
  def value(%Concept.Value{value: values, value_type: "vector(" <> _ = value_type}) do
    dimension = vector_dimension!(value_type)

    unless is_list(values) and length(values) == dimension and Enum.all?(values, &is_number/1) do
      raise Error.new(
              :encode,
              "cannot encode #{inspect(values, limit: 5)} as a #{value_type}: " <>
                "expected a list of #{dimension} numbers"
            )
    end

    %Proto.Value{value: {:vector, %Proto.Value.Vector{values: Enum.map(values, &(&1 * 1.0))}}}
  end

  def value(other) do
    raise Error.new(
            :encode,
            "no TypeDB value for #{inspect(other)} — supported: boolean, integer, float, string, " <>
              "Date, DateTime, NaiveDateTime, TypeDB.Duration and, experimentally, a vector as " <>
              "TypeDB.Concept.Value"
          )
  end

  # `float32` is the only dtype TypeQL accepts for a vector.
  defp vector_dimension!(value_type) do
    case Regex.run(~r/\Avector\((\d+),\s*"float32"\)\z/, value_type) do
      [_, dimension] ->
        String.to_integer(dimension)

      nil ->
        raise Error.new(
                :encode,
                ~s|unsupported vector type #{inspect(value_type)}, expected vector(N, "float32")|
              )
    end
  end
end
