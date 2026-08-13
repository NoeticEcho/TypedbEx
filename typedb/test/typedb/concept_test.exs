defmodule TypeDB.ConceptTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Concept, ConceptRow, DateTimeTZ, Duration, Error}

  doctest TypeDB.Concept
  doctest TypeDB.ConceptRow

  describe "decode/1 instances" do
    test "entity with a type" do
      assert %Concept.Entity{iid: "0x1e00", type: %Concept.EntityType{label: "person"}} =
               Concept.decode(%{
                 "kind" => "entity",
                 "iid" => "0x1e00",
                 "type" => %{"kind" => "entityType", "label" => "person"}
               })
    end

    test "entity without a type" do
      assert %Concept.Entity{iid: "0x1e00", type: nil} =
               Concept.decode(%{"kind" => "entity", "iid" => "0x1e00"})
    end

    test "entity with an explicitly null type" do
      assert %Concept.Entity{type: nil} =
               Concept.decode(%{"kind" => "entity", "iid" => "0x1e00", "type" => nil})
    end

    test "relation" do
      assert %Concept.Relation{iid: "0x1f00", type: %Concept.RelationType{label: "employment"}} =
               Concept.decode(%{
                 "kind" => "relation",
                 "iid" => "0x1f00",
                 "type" => %{"kind" => "relationType", "label" => "employment"}
               })
    end

    test "attribute" do
      assert %Concept.Attribute{
               iid: "0x2000",
               value: "Alice",
               value_type: "string",
               type: %Concept.AttributeType{label: "name", value_type: "string"}
             } =
               Concept.decode(%{
                 "kind" => "attribute",
                 "iid" => "0x2000",
                 "value" => "Alice",
                 "valueType" => "string",
                 "type" => %{"kind" => "attributeType", "label" => "name", "valueType" => "string"}
               })
    end

    test "value" do
      assert %Concept.Value{value: 42, value_type: "integer"} =
               Concept.decode(%{"kind" => "value", "value" => 42, "valueType" => "integer"})
    end
  end

  describe "decode/1 types" do
    test "entity type" do
      assert %Concept.EntityType{label: "person"} =
               Concept.decode(%{"kind" => "entityType", "label" => "person"})
    end

    test "relation type" do
      assert %Concept.RelationType{label: "employment"} =
               Concept.decode(%{"kind" => "relationType", "label" => "employment"})
    end

    test "role type keeps its scoped label" do
      assert %Concept.RoleType{label: "employment:employee"} =
               Concept.decode(%{"kind" => "roleType", "label" => "employment:employee"})
    end

    test "abstract attribute type has no value type" do
      assert %Concept.AttributeType{label: "identifier", value_type: nil} =
               Concept.decode(%{"kind" => "attributeType", "label" => "identifier"})
    end
  end

  describe "decode/1 edge cases" do
    test "nil stays nil" do
      assert Concept.decode(nil) == nil
    end

    test "lists decode element-wise" do
      assert [%Concept.Value{value: 1}, %Concept.Value{value: 2}] =
               Concept.decode([
                 %{"kind" => "value", "value" => 1, "valueType" => "integer"},
                 %{"kind" => "value", "value" => 2, "valueType" => "integer"}
               ])
    end

    test "an unknown kind raises a decode error" do
      assert_raise Error, ~r/unrecognised TypeDB concept/, fn -> Concept.decode(%{"kind" => "quark"}) end
    end

    test "a missing required field raises a decode error" do
      assert_raise Error, ~r/missing the "iid" field/, fn -> Concept.decode(%{"kind" => "entity"}) end
    end
  end

  describe "accessors" do
    test "iid/1" do
      assert Concept.iid(%Concept.Entity{iid: "0x1"}) == "0x1"
      assert Concept.iid(%Concept.Value{value: 1, value_type: "integer"}) == nil
      assert Concept.iid(%Concept.EntityType{label: "person"}) == nil
    end

    test "label/1 on types" do
      assert Concept.label(%Concept.EntityType{label: "person"}) == "person"
      assert Concept.label(%Concept.RoleType{label: "employment:employee"}) == "employment:employee"
    end

    test "label/1 on instances reads through to the type" do
      entity = %Concept.Entity{iid: "0x1", type: %Concept.EntityType{label: "person"}}
      assert Concept.label(entity) == "person"
      assert Concept.label(%Concept.Entity{iid: "0x1"}) == nil
    end

    test "value/1" do
      assert Concept.value(%Concept.Attribute{iid: "0x1", value: "Alice", value_type: "string"}) == "Alice"
      assert Concept.value(%Concept.Value{value: 1, value_type: "integer"}) == 1
      assert Concept.value(%Concept.EntityType{label: "person"}) == nil
    end
  end

  describe "category/1 and the predicates" do
    @concepts [
      {%Concept.Entity{iid: "0x1"}, :entity},
      {%Concept.Relation{iid: "0x2"}, :relation},
      {%Concept.Attribute{iid: "0x3", value: 1, value_type: "integer"}, :attribute},
      {%Concept.EntityType{label: "person"}, :entity_type},
      {%Concept.RelationType{label: "friendship"}, :relation_type},
      {%Concept.AttributeType{label: "name"}, :attribute_type},
      {%Concept.RoleType{label: "friendship:friend"}, :role_type},
      {%Concept.Value{value: 1, value_type: "integer"}, :value}
    ]

    test "every concept struct has a category, and they are all different" do
      # The list above is the whole of `TypeDB.Concept.t()`. If a struct is
      # added and not categorised, `category/1` raises a FunctionClauseError
      # here rather than in somebody's application.
      for {concept, expected} <- @concepts do
        assert Concept.category(concept) == expected
      end

      assert @concepts |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 8
    end

    test "instance?, type? and value? partition the categories" do
      for {concept, _} <- @concepts do
        answers = [Concept.instance?(concept), Concept.type?(concept), Concept.value?(concept)]

        assert Enum.count(answers, & &1) == 1,
               "#{inspect(concept.__struct__)} is #{Enum.count(answers, & &1)} of instance/type/value"
      end
    end

    test "an attribute is an instance, not a value, even though it has one" do
      attribute = %Concept.Attribute{iid: "0x1", value: "Alice", value_type: "string"}

      assert Concept.instance?(attribute)
      refute Concept.value?(attribute)
      assert Concept.value(attribute) == "Alice"
    end
  end

  describe "typed_value/1" do
    test "primitives pass through" do
      assert cast(true, "boolean") == true
      assert cast(7, "integer") == 7
      assert cast(1.5, "double") == 1.5
      assert cast("hi", "string") == "hi"
    end

    test "an integer arriving for a double becomes a float" do
      assert cast(7, "double") === 7.0
    end

    test "date" do
      assert cast("2024-03-01", "date") == ~D[2024-03-01]
    end

    test "datetime" do
      assert cast("2024-03-01T10:30:00.000000000", "datetime") == ~N[2024-03-01 10:30:00.000000]
    end

    test "datetime-tz with an IANA zone" do
      assert %DateTimeTZ{time_zone: "Europe/London", naive: ~N[2024-03-01 10:30:00.000000]} =
               cast("2024-03-01T10:30:00.000000000 Europe/London", "datetime-tz")
    end

    test "datetime-tz with a fixed offset" do
      assert %DateTimeTZ{utc_offset: 3600, time_zone: nil} =
               cast("2024-03-01T10:30:00.000000000+01:00", "datetime-tz")
    end

    test "duration" do
      assert %Duration{months: 14, days: 3} = cast("P1Y2M3DT4H", "duration")
    end

    test "an unparseable temporal value is returned unchanged" do
      assert cast("not-a-date", "date") == "not-a-date"
      assert cast("not-a-duration", "duration") == "not-a-duration"
      assert cast("nonsense", "datetime-tz") == "nonsense"
    end

    test "an unknown value type is returned unchanged" do
      assert cast(%{"a" => 1}, "struct-of-some-kind") == %{"a" => 1}
    end

    test "typed_value/1 on non-value concepts is nil" do
      assert Concept.typed_value(%Concept.EntityType{label: "person"}) == nil
    end
  end

  describe "TypeDB.ConceptRow" do
    setup do
      row =
        ConceptRow.decode(%{
          "data" => %{
            "p" => %{"kind" => "entity", "iid" => "0x1"},
            "name" => %{"kind" => "attribute", "iid" => "0x2", "value" => "Alice", "valueType" => "string"},
            "age" => %{"kind" => "attribute", "iid" => "0x3", "value" => 30, "valueType" => "integer"},
            "missing" => nil
          },
          "involvedBlocks" => [0, 1]
        })

      {:ok, row: row}
    end

    test "implements Access", %{row: row} do
      assert %Concept.Entity{iid: "0x1"} = row["p"]
      assert row["nope"] == nil
      assert get_in(row, ["name"]).value == "Alice"
    end

    test "fetch/2 distinguishes unbound from absent", %{row: row} do
      assert ConceptRow.fetch(row, "missing") == {:ok, nil}
      assert ConceptRow.fetch(row, "nope") == :error
    end

    test "get/3 applies the default to both", %{row: row} do
      assert ConceptRow.get(row, "missing", :fallback) == :fallback
      assert ConceptRow.get(row, "nope", :fallback) == :fallback
    end

    test "variables/1", %{row: row} do
      assert Enum.sort(ConceptRow.variables(row)) == ["age", "missing", "name", "p"]
    end

    test "value/2 and typed_value/2", %{row: row} do
      assert ConceptRow.value(row, "name") == "Alice"
      assert ConceptRow.value(row, "missing") == nil
      assert ConceptRow.typed_value(row, "age") == 30
    end

    test "to_map/1 unwraps values and keeps non-values", %{row: row} do
      map = ConceptRow.to_map(row)
      assert map["name"] == "Alice"
      assert map["age"] == 30
      assert map["missing"] == nil
      assert %Concept.Entity{} = map["p"]
    end

    test "to_typed_map/1 casts every value, where to_map/1 hands back the wire form" do
      # The gap this closes: `typed_value/2` gave a native term one variable at
      # a time, and the two functions that convert a whole row did not, so the
      # same row read as %TypeDB.Duration{} or as "P1Y2M3DT4H5M6S" depending on
      # which one you reached for.
      row =
        %TypeDB.ConceptRow{
          data: %{
            "name" => %Concept.Value{value: "Alice", value_type: "string"},
            "balance" => %Concept.Value{value: "12.345dec", value_type: "decimal"},
            "worked" => %Concept.Value{value: "P1Y2M3DT4H5M6S", value_type: "duration"},
            "born" => %Concept.Value{value: "1990-03-01T10:30:00", value_type: "datetime"},
            "p" => %Concept.Entity{iid: "0x1"},
            "missing" => nil
          }
        }

      wire = ConceptRow.to_map(row)
      typed = ConceptRow.to_typed_map(row)

      assert wire["worked"] == "P1Y2M3DT4H5M6S"
      assert %TypeDB.Duration{months: 14, days: 3} = typed["worked"]

      assert wire["born"] == "1990-03-01T10:30:00"
      assert typed["born"] == ~N[1990-03-01 10:30:00]

      assert wire["balance"] == "12.345dec"
      # A Decimal when that dependency is loaded, the string without it — and
      # the suffix is gone either way. Named as a value, never as a struct
      # pattern: `%Decimal{}` in a pattern would not compile without the dep.
      assert typed["balance"] == Concept.cast("12.345dec", "decimal")

      # Unchanged by either: a string is already native, an entity has no value.
      assert wire["name"] == typed["name"]
      assert %Concept.Entity{} = typed["p"]
      assert typed["missing"] == nil
    end

    test "carries involved_blocks", %{row: row} do
      assert row.involved_blocks == [0, 1]
    end

    test "a malformed row raises a decode error" do
      assert_raise Error, ~r/unrecognised TypeDB concept row/, fn -> ConceptRow.decode(%{"nope" => 1}) end
    end
  end

  defp cast(value, value_type) do
    Concept.typed_value(%Concept.Value{value: value, value_type: value_type})
  end

  describe "to_struct/2" do
    defmodule Person do
      @moduledoc false
      defstruct [:name, :age, :nickname]
    end

    defp row(data), do: %TypeDB.ConceptRow{data: data}

    defp attribute(value, type), do: %TypeDB.Concept.Value{value: value, value_type: type}

    test "maps variable names onto fields and unwraps the values" do
      assert %Person{name: "Alice", age: 31, nickname: nil} =
               row(%{"name" => attribute("Alice", "string"), "age" => attribute(31, "integer")})
               |> TypeDB.ConceptRow.to_struct(Person)
    end

    test "a field the query did not select keeps its default" do
      # Selecting a subset is ordinary; the caller wrote the query.
      assert %Person{name: "Alice", age: nil} =
               row(%{"name" => attribute("Alice", "string")})
               |> TypeDB.ConceptRow.to_struct(Person)
    end

    test "a variable with no matching field is reported, not silently dropped" do
      # Kernel.struct/2 answers %Person{name: nil, age: nil, nickname: nil} here
      # and says nothing, which is the whole reason this function exists.
      error =
        assert_raise ArgumentError, fn ->
          row(%{"nmae" => attribute("Alice", "string")})
          |> TypeDB.ConceptRow.to_struct(Person)
        end

      assert error.message =~ ~s(variable "nmae")
      assert error.message =~ ":name"
      assert error.message =~ ":nickname"
    end

    test "a module that is not a struct says so" do
      assert_raise ArgumentError, ~r/is not a struct/, fn ->
        TypeDB.ConceptRow.to_struct(row(%{}), Enum)
      end
    end

    test "an empty row yields the struct's defaults" do
      assert %Person{} == TypeDB.ConceptRow.to_struct(row(%{}), Person)
    end

    test "typed: true casts the values on the way in" do
      built =
        row(%{"name" => attribute("P1Y", "duration")})
        |> TypeDB.ConceptRow.to_struct(Person, typed: true)

      assert %Person{name: %TypeDB.Duration{months: 12}} = built
    end

    test "an option it does not accept is rejected rather than ignored" do
      error =
        assert_raise ArgumentError, fn ->
          TypeDB.ConceptRow.to_struct(row(%{}), Person, tpyed: true)
        end

      assert error.message =~ "unknown option :tpyed"
      assert error.message =~ "to_struct/3"
    end
  end

  describe "decimal casting" do
    test "the TypeQL literal suffix is stripped" do
      # `Decimal` is present here, so this covers only half of it. The other
      # half — that the string fallback is stripped too — is asserted by the
      # consumer project in the "Optional dependencies" CI job, which is the
      # only place the dependency can actually be absent.
      assert Decimal.equal?(TypeDB.Concept.cast("12.345dec", "decimal"), Decimal.new("12.345"))
      assert Decimal.equal?(TypeDB.Concept.cast("12.345", "decimal"), Decimal.new("12.345"))
    end

    test "something that is not a decimal at all comes back unchanged" do
      assert TypeDB.Concept.cast("not a number", "decimal") == "not a number"
    end
  end
end
