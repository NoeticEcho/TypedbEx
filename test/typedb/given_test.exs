defmodule TypeDB.GivenTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Concept, DateTimeTZ, Duration, Error, Given}

  doctest TypeDB.Given

  describe "encode/1 values" do
    test "strings are tagged, never inlined" do
      assert Given.encode("Alice") == %{"kind" => "value", "value" => "Alice", "valueType" => "string"}
    end

    test "a string containing TypeQL stays data" do
      injection = ~s(x"; delete $p isa person; insert $q isa person, has name "pwned)

      assert Given.encode(injection) == %{
               "kind" => "value",
               "value" => injection,
               "valueType" => "string"
             }
    end

    test "numbers" do
      assert Given.encode(42) == %{"kind" => "value", "value" => 42, "valueType" => "integer"}
      assert Given.encode(3.5) == %{"kind" => "value", "value" => 3.5, "valueType" => "double"}
    end

    test "booleans are booleans, not strings" do
      assert Given.encode(true) == %{"kind" => "value", "value" => true, "valueType" => "boolean"}
      assert Given.encode(false) == %{"kind" => "value", "value" => false, "valueType" => "boolean"}
    end

    test "temporal types" do
      assert Given.encode(~D[2024-03-01]) == %{
               "kind" => "value",
               "value" => "2024-03-01",
               "valueType" => "date"
             }

      assert Given.encode(~N[2024-03-01 10:30:00]) == %{
               "kind" => "value",
               "value" => "2024-03-01T10:30:00",
               "valueType" => "datetime"
             }
    end

    test "DateTime renders an explicit offset, because TypeQL does not accept Z" do
      datetime = DateTime.from_naive!(~N[2024-03-01 10:30:00], "Etc/UTC")

      assert Given.encode(datetime) == %{
               "kind" => "value",
               "value" => "2024-03-01T10:30:00+00:00",
               "valueType" => "datetime-tz"
             }
    end

    test "DateTimeTZ keeps its wire form" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00.000000000+02:00")

      assert Given.encode(value) == %{
               "kind" => "value",
               "value" => "2024-03-01T10:30:00.000000000+02:00",
               "valueType" => "datetime-tz"
             }
    end

    test "Duration keeps its wire form" do
      assert Given.encode(Duration.parse("P1Y2M3DT4H")) == %{
               "kind" => "value",
               "value" => "P1Y2M3DT4H",
               "valueType" => "duration"
             }
    end

    test "nil marks an unbound optional column" do
      assert Given.encode(nil) == nil
    end
  end

  describe "encode/1 concepts" do
    test "an entity becomes an iid reference" do
      entity = %Concept.Entity{iid: "0x1e00", type: %Concept.EntityType{label: "person"}}
      assert Given.encode(entity) == %{"kind" => "entity", "iid" => "0x1e00"}
    end

    test "a relation becomes an iid reference" do
      assert Given.encode(%Concept.Relation{iid: "0x1f00"}) == %{"kind" => "relation", "iid" => "0x1f00"}
    end

    test "an attribute carries its value, as the server requires" do
      attribute = %Concept.Attribute{iid: "0x2000", value: "Alice", value_type: "string"}

      assert Given.encode(attribute) == %{
               "kind" => "attribute",
               "iid" => "0x2000",
               "value" => "Alice",
               "valueType" => "string"
             }
    end

    test "a value concept keeps its declared value type" do
      value = %Concept.Value{value: "12.345", value_type: "decimal"}

      assert Given.encode(value) == %{"kind" => "value", "value" => "12.345", "valueType" => "decimal"}
    end

    test "an already-encoded wire map passes through" do
      wire = %{"kind" => "value", "value" => "x", "valueType" => "string"}
      assert Given.encode(wire) == wire
    end
  end

  describe "encode_rows/1" do
    test "nil stays nil so the option can be applied unconditionally" do
      assert Given.encode_rows(nil) == nil
    end

    test "encodes every entry of every row" do
      assert Given.encode_rows([%{"n" => "Alice", "a" => 30}, %{"n" => "Bob", "a" => nil}]) == [
               %{
                 "n" => %{"kind" => "value", "value" => "Alice", "valueType" => "string"},
                 "a" => %{"kind" => "value", "value" => 30, "valueType" => "integer"}
               },
               %{
                 "n" => %{"kind" => "value", "value" => "Bob", "valueType" => "string"},
                 "a" => nil
               }
             ]
    end

    test "atom variable names are stringified" do
      assert [%{"n" => %{"value" => "Alice"}}] = Given.encode_rows([%{n: "Alice"}])
    end

    test "rejects a non-list" do
      error = assert_raise Error, ~r/invalid :given_rows/, fn -> Given.encode_rows(%{"n" => "Alice"}) end
      assert error.kind == :encode
    end

    test "rejects a row that is not a map" do
      assert_raise Error, ~r/invalid given row/, fn -> Given.encode_rows([["n", "Alice"]]) end
    end

    test "rejects a term it cannot represent" do
      error = assert_raise Error, ~r/cannot encode/, fn -> Given.encode_rows([%{"n" => {:tuple, :value}}]) end
      assert error.kind == :encode
    end
  end
end
