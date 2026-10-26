defmodule TypeDB.GRPC.Vector do
  @moduledoc false

  # Vector values on the wire — experimental: they need a TypeDB build with
  # vector support, and the wire format may change.
  #
  # typedb-protocol's `vector-search` branch adds field 11 to `Value` and to
  # `ValueType`, a message each. No released protocol has them, and
  # `lib/protocol` is generated from a released one and must not be edited by
  # hand, so the generated `Value` and `ValueType` do not know field 11. Protobuf
  # keeps a field it does not know in the struct's `__unknown_fields__`, as
  # `{field_number, wire_type, payload}`, and writes it back out when the struct
  # is encoded. This module reads field 11 from there and builds it for there,
  # with its own definitions of the two messages:
  #
  #     message Value     { ... Vector vector = 11; message Vector { repeated float values = 1; } }
  #     message ValueType { ... Vector vector = 11; message Vector { uint32 dimension = 1; } }
  #
  # Because none of this lives in generated code, regenerating `lib/protocol`
  # cannot remove it. When a released protocol defines field 11, the generated
  # structs take it over, it stops arriving as an unknown field, and this module
  # becomes dead code to delete.

  alias Typedb.Protocol, as: Proto

  @field 11
  @wire_delimited 2

  defmodule Values do
    @moduledoc false
    use Protobuf, full_name: "typedb.protocol.Value.Vector", syntax: :proto3

    field(:values, 1, repeated: true, type: :float, packed: true, deprecated: false)
  end

  defmodule Dimension do
    @moduledoc false
    use Protobuf, full_name: "typedb.protocol.ValueType.Vector", syntax: :proto3

    field(:dimension, 1, type: :uint32)
  end

  @doc """
  The components of a vector `Value`, or `:error` when it is not one.

  A component that is not finite comes back as the atom protobuf decodes it to.
  """
  @spec values(Proto.Value.t()) :: {:ok, [float() | :infinity | :negative_infinity | :nan]} | :error
  def values(%Proto.Value{value: nil, __unknown_fields__: unknown}) do
    with {:ok, %Values{values: values}} <- decode(unknown, Values), do: {:ok, values}
  end

  def values(%Proto.Value{}), do: :error

  @doc "The dimension of a vector `ValueType`, or `:error` when it is not one."
  @spec dimension(Proto.ValueType.t()) :: {:ok, non_neg_integer()} | :error
  def dimension(%Proto.ValueType{value_type: nil, __unknown_fields__: unknown}) do
    with {:ok, %Dimension{dimension: dimension}} <- decode(unknown, Dimension), do: {:ok, dimension}
  end

  def dimension(%Proto.ValueType{}), do: :error

  @doc """
  A vector `Value` of these components, which encodes to the bytes the
  `vector-search` protocol defines for it.

  Every component must already be a float in float32's range: protobuf's
  encoder raises on anything else, and it runs in the transaction's process.
  """
  @spec value([float()]) :: Proto.Value.t()
  def value(values) when is_list(values) do
    payload = %Values{values: values} |> Values.encode() |> IO.iodata_to_binary()
    %Proto.Value{value: nil, __unknown_fields__: [{@field, @wire_delimited, payload}]}
  end

  # An embedded message that occurs more than once is merged, and merging is
  # what decoding the occurrences' bytes concatenated does. A payload that is not
  # the message is a value kind this build does not understand, which decodes to
  # nothing rather than failing the answer — as an unset `oneof` does.
  defp decode(unknown, module) do
    case for({@field, @wire_delimited, payload} <- unknown, do: payload) do
      [] ->
        :error

      payloads ->
        try do
          {:ok, module.decode(IO.iodata_to_binary(payloads))}
        rescue
          Protobuf.DecodeError -> :error
        end
    end
  end
end
