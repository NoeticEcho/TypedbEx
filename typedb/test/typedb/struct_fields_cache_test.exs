defmodule TypeDB.StructFieldsCacheTest do
  # `async: false`: this redefines a module and toggles a global compiler
  # option to do it, neither of which is safe beside a concurrent test.
  use ExUnit.Case, async: false

  alias TypeDB.{Concept, ConceptRow}

  # `to_struct/3` maps a row's string variable names onto a struct's atom
  # fields, and works that mapping out from the module. Doing it once per row is
  # a third of the call's cost, so the mapping is cached — and a cache keyed on
  # a module is only correct while the module is the one it was built from.
  # These pin the two ways such a cache goes wrong.

  defp row(data), do: %ConceptRow{data: data}
  defp value(v), do: %Concept.Value{value: v, value_type: "string"}

  defp define!(module, fields) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Code.compile_string("defmodule #{inspect(module)}, do: defstruct(#{inspect(fields)})")
      :ok
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  test "a struct redefined with a new field is not answered from a stale mapping" do
    module = TypeDB.StructFieldsCacheTest.Redefined

    define!(module, [:name])
    assert %{name: "Alice"} = Map.from_struct(ConceptRow.to_struct(row(%{"name" => value("Alice")}), module))

    define!(module, [:name, :nickname])

    built = ConceptRow.to_struct(row(%{"name" => "Bob" |> value(), "nickname" => value("Bo")}), module)

    assert %{name: "Bob", nickname: "Bo"} = Map.from_struct(built)
  end

  test "two struct modules used from one process do not share a mapping" do
    a = TypeDB.StructFieldsCacheTest.A
    b = TypeDB.StructFieldsCacheTest.B

    define!(a, [:only_in_a])
    define!(b, [:only_in_b])

    assert %{only_in_a: "x"} = Map.from_struct(ConceptRow.to_struct(row(%{"only_in_a" => value("x")}), a))
    assert %{only_in_b: "y"} = Map.from_struct(ConceptRow.to_struct(row(%{"only_in_b" => value("y")}), b))

    # And back again: the second module must not have evicted the first.
    assert %{only_in_a: "z"} = Map.from_struct(ConceptRow.to_struct(row(%{"only_in_a" => value("z")}), a))
  end

  test "a variable that names no field is still reported after the mapping is cached" do
    module = TypeDB.StructFieldsCacheTest.Reported

    define!(module, [:name])
    _ = ConceptRow.to_struct(row(%{"name" => value("Alice")}), module)

    error =
      assert_raise ArgumentError, fn ->
        ConceptRow.to_struct(row(%{"nmae" => value("Alice")}), module)
      end

    assert error.message =~ ~s(variable "nmae")
    assert error.message =~ ":name"
  end

  test "a module that is not a struct still says so, and is not cached as one" do
    assert_raise ArgumentError, ~r/is not a struct/, fn -> ConceptRow.to_struct(row(%{}), Enum) end
    assert_raise ArgumentError, ~r/is not a struct/, fn -> ConceptRow.to_struct(row(%{}), Enum) end
  end

  test "a module that does not exist at all says the same" do
    assert_raise ArgumentError, ~r/is not a struct/, fn ->
      ConceptRow.to_struct(row(%{}), TypeDB.StructFieldsCacheTest.NoSuchModule)
    end
  end
end
