defmodule TypeDB.GRPC.VectorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Vector values over protobuf — experimental, since they need a TypeDB build
  with vector support and the wire format may change.

  The fixtures are bytes rather than structs wherever the claim is about the
  wire: `Value.vector` is field 11, a message whose field 1 is a packed
  `repeated float`. Written out by hand so that a regenerated protocol that
  moved either number would fail here rather than in somebody's application.

  The shape they decode to is the HTTP transport's — a list of floats and a
  `vector(N, "float32")` value type — because an application must not have to
  know which transport read the value.
  """

  alias TypeDB.{Concept, ConceptRow}
  alias TypeDB.GRPC.{Decode, Given}
  alias Typedb.Protocol, as: Proto

  # `Value` as it was before vectors: fields 1–10, no 11. What a driver or a
  # server that does not know vectors decodes with.
  defmodule PreVectorValue do
    @moduledoc false
    use Protobuf, full_name: "typedb_grpc.test.PreVectorValue", syntax: :proto3

    oneof(:value, 0)

    field(:boolean, 1, type: :bool, oneof: 0)
    field(:integer, 2, type: :sint64, oneof: 0)
    field(:double, 3, type: :double, oneof: 0)
    field(:string, 5, type: :string, oneof: 0)
  end

  # Value { vector (11): Vector { values (1, packed): [1.0, 0.5] } }
  @vector_bytes <<0x5A, 10, 0x0A, 8, 1.0::float-32-little, 0.5::float-32-little>>

  defp vector_value(values, dimension \\ nil) do
    %Concept.Value{value: values, value_type: ~s|vector(#{dimension || length(values)}, "float32")|}
  end

  describe "decoding" do
    test "a vector value from its wire bytes is a list of floats with the HTTP transport's value type" do
      value = Proto.Value.decode(@vector_bytes)

      assert Decode.value(value) == [1.0, 0.5]
      assert Decode.value_type(value) == ~s|vector(2, "float32")|
    end

    test "a float32 component widens to the same double the HTTP API reports" do
      value = Proto.Value.decode(<<0x5A, 6, 0x0A, 4, 0.1::float-32-little>>)

      # Over HTTP the server renders the float32 as a JSON double; this is that number.
      assert Decode.value(value) == [0.10000000149011612]
    end

    test "a non-finite component is nil, as JSON makes it over HTTP" do
      bytes =
        <<0x5A, 14, 0x0A, 12, 0x00, 0x00, 0x80, 0x7F, 0x00, 0x00, 0x80, 0xFF, 2.0::float-32-little>>

      assert Decode.value(Proto.Value.decode(bytes)) == [nil, nil, 2.0]
    end

    test "a vector in a row is a TypeDB.Concept.Value" do
      row = %Proto.ConceptRow{row: [%Proto.RowEntry{entry: {:value, Proto.Value.decode(@vector_bytes)}}]}

      assert %ConceptRow{
               data: %{"v" => %Concept.Value{value: [1.0, 0.5], value_type: ~s|vector(2, "float32")|}}
             } =
               Decode.row(row, ["v"])
    end

    test "a vector attribute and its type carry the dimension and dtype" do
      concept = %Proto.Concept{
        concept:
          {:attribute,
           %Proto.Attribute{
             iid: <<0x1E, 0, 1>>,
             value: Proto.Value.decode(@vector_bytes),
             attribute_type: %Proto.AttributeType{
               label: "embedding",
               value_type: %Proto.ValueType{value_type: {:vector, %Proto.ValueType.Vector{dimension: 2}}}
             }
           }}
      }

      concept = concept |> Proto.Concept.encode() |> Proto.Concept.decode()

      assert %Concept.Attribute{
               iid: "0x1e0001",
               value: [1.0, 0.5],
               value_type: ~s|vector(2, "float32")|,
               type: %Concept.AttributeType{label: "embedding", value_type: ~s|vector(2, "float32")|}
             } = Decode.concept(concept)
    end
  end

  describe "encoding a given value" do
    test "a vector is a TypeDB.Concept.Value, and encodes to the wire bytes" do
      assert Proto.Value.encode(Given.value(vector_value([1.0, 0.5]))) |> IO.iodata_to_binary() ==
               @vector_bytes
    end

    test "integer components are sent as floats" do
      assert %Proto.Value{value: {:vector, %Proto.Value.Vector{values: values}}} =
               Given.value(vector_value([1, 0]))

      assert values === [1.0, +0.0]
    end

    test "a vector round-trips through the given encoding and the decoder" do
      rows = Given.encode_rows([%{v: vector_value([0.25, -1.0, 3.5])}])
      decoded = rows |> Proto.Query.Req.GivenRows.encode() |> Proto.Query.Req.GivenRows.decode()

      assert %Proto.Query.Req.GivenRows{
               variables: ["v"],
               rows: [
                 %Proto.Query.Req.GivenRow{entries: [%Proto.Query.Req.GivenEntry{entry: {:value, value}}]}
               ]
             } = decoded

      assert Decode.value(value) == [0.25, -1.0, 3.5]
      assert Decode.value_type(value) == ~s|vector(3, "float32")|
    end

    test "a dimension that does not match the list is an :encode error, since the wire cannot say it" do
      assert_raise TypeDB.Error, ~r/expected a list of 3 numbers/, fn ->
        Given.value(vector_value([1.0, 0.0], 3))
      end
    end

    test "anything but numbers in a vector is an :encode error" do
      error = assert_raise TypeDB.Error, fn -> Given.value(vector_value([1.0, "x"])) end
      assert error.kind == :encode
    end

    test "a component past float32's range is an :encode error, raised in the caller" do
      for big <- [1.0e39, -1.0e39, 10 ** 400] do
        error = assert_raise TypeDB.Error, fn -> Given.value(vector_value([big, 0.0])) end
        assert error.kind == :encode
      end
    end

    test "float32's largest value is still sent" do
      <<max::float-32>> = <<0x7F7F_FFFF::32>>
      assert %{value: {:vector, %{values: [^max, 0.0]}}} = Given.value(vector_value([max, 0]))
    end

    test "a dtype other than float32 is an :encode error" do
      error =
        assert_raise TypeDB.Error, ~r/unsupported vector type/, fn ->
          Given.value(%Concept.Value{value: [1.0], value_type: ~s|vector(1, "float64")|})
        end

      assert error.kind == :encode
    end
  end

  describe "a peer that does not know vectors" do
    test "ignores the vector field: an old schema decodes it as an unset value" do
      assert %PreVectorValue{value: nil} = PreVectorValue.decode(@vector_bytes)
    end

    test "sends values this build decodes exactly as before" do
      for {old, expected, type} <- [
            {{:boolean, true}, true, "boolean"},
            {{:integer, -42}, -42, "integer"},
            {{:double, 1.5}, 1.5, "double"},
            {{:string, "Alice"}, "Alice", "string"}
          ] do
        value = %PreVectorValue{value: old} |> PreVectorValue.encode() |> Proto.Value.decode()

        assert Decode.value(value) == expected
        assert Decode.value_type(value) == type
      end
    end

    test "a value kind this build does not know decodes to nil instead of failing the answer" do
      # Field 12, length-delimited: whatever a later protocol adds after vectors.
      value = Proto.Value.decode(<<0x62, 2, 0x0A, 0>>)

      assert Decode.value(value) == nil
      assert Decode.value_type(value) == nil

      row = %Proto.ConceptRow{row: [%Proto.RowEntry{entry: {:value, value}}]}
      assert %ConceptRow{data: %{"x" => %Concept.Value{value: nil, value_type: nil}}} = Decode.row(row, ["x"])
    end
  end
end
