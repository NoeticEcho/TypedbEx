defmodule TypeDB.VectorTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Concept, Given, Vector}

  doctest TypeDB.Vector

  @type3 ~s|vector(3, "float32")|

  test "a vector value encodes to the tagged wire form, its components as floats" do
    assert Given.encode(%Concept.Value{value: [1, 0.5, -2], value_type: @type3}) ==
             %{"kind" => "value", "value" => [1.0, 0.5, -2.0], "valueType" => @type3}
  end

  test "value/1 gives the term Given encodes" do
    assert {:ok, %Concept.Value{value_type: @type3} = v} = Vector.value([0.1, 0.2, 0.3])
    assert %{"valueType" => @type3, "value" => [0.1, 0.2, 0.3]} = Given.encode(v)
  end

  for {name, components} <- [
        {"the wrong length", [1.0, 2.0]},
        {"a component past float32's range", [1.0e39, 0.0, 0.0]},
        {"a component that is not a number", [1.0, nil, 0.0]},
        {"not a list", "1,2,3"}
      ] do
    test "#{name} is an :encode error before anything is sent" do
      assert_raise TypeDB.Error, ~r/cannot encode/, fn ->
        Given.encode_rows([
          %{"q" => %Concept.Value{value: unquote(Macro.escape(components)), value_type: @type3}}
        ])
      end
    end
  end

  test "a dtype other than float32 is refused" do
    assert_raise TypeDB.Error, ~r/unsupported vector type/, fn ->
      Given.encode(%Concept.Value{value: [1.0], value_type: ~s|vector(1, "float64")|})
    end
  end

  test "value/1 refuses an empty list" do
    assert {:error, %TypeDB.Error{kind: :encode}} = Vector.value([])
  end
end
