defmodule TypeDB.GRPC.DecodeMessageTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `TypeDB.GRPC.Decode.message/1` — the reflection-driven rendering behind
  `analyze/3`.

  It is the one place in this driver that decodes by walking a message's own
  schema rather than by naming fields, so what has to be pinned is the shape it
  produces, not any particular message.
  """

  alias TypeDB.GRPC.Decode
  alias Typedb.Protocol, as: Proto

  defp variable(id), do: %Proto.AnalyzedConjunction.Variable{id: id}

  defp vertex(variable) do
    %Proto.AnalyzedConjunction.ConstraintVertex{vertex: {:variable, variable}}
  end

  defp annotations(optional?) do
    %Proto.AnalyzedConjunction.VariableAnnotations{
      is_optional: optional?,
      annotations: {:instance, %Proto.AnalyzedConjunction.VariableAnnotations.ConceptVariableAnnotations{}}
    }
  end

  test "a oneof becomes a tag beside its inlined fields" do
    constraint = %Proto.AnalyzedConjunction.Constraint{
      span: %Proto.AnalyzedConjunction.Constraint.ConstraintSpan{begin: 9, end: 19},
      constraint:
        {:isa,
         %Proto.AnalyzedConjunction.Constraint.Isa{
           instance: vertex(variable(3)),
           exactness: :SUBTYPES
         }}
    }

    assert %{
             "tag" => "isa",
             "span" => %{"begin" => 9, "end" => 19},
             "instance" => %{"tag" => "variable", "id" => 3},
             "exactness" => "SUBTYPES"
           } = Decode.message(constraint)
  end

  test "a field holding its type's default is rendered, not dropped" do
    # The reason this does not use proto3's JSON mapping. That one omits
    # defaults, and variable 0 is a variable like any other — dropping its id
    # would make `$p` and `$n` indistinguishable in an analysis.
    assert %{"id" => 0} = Decode.message(variable(0))

    assert %{"instance" => %{"id" => 0}} =
             Decode.message(%Proto.AnalyzedConjunction.Constraint.Isa{instance: vertex(variable(0))})
  end

  test "an unset embedded message is nil rather than missing" do
    rendered = Decode.message(%Proto.AnalyzedConjunction.Constraint.Isa{instance: vertex(variable(1))})

    assert Map.has_key?(rendered, "type")
    assert rendered["type"] == nil
  end

  test "repeated fields keep their order" do
    stage = %Proto.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Select{
      variables: Enum.map([2, 0, 1], &variable/1)
    }

    assert %{"variables" => [%{"id" => 2}, %{"id" => 0}, %{"id" => 1}]} = Decode.message(stage)
  end

  test "keys are the schema's json_name, not its field name" do
    rendered = Decode.message(annotations(true))

    assert rendered["isOptional"] == true
    refute Map.has_key?(rendered, "is_optional")
  end

  test "a oneof whose fields would collide keeps its own key instead of overwriting" do
    # `ConstraintVertex`'s `label` holds a `Type`, which carries a tag of its
    # own — so spreading it would overwrite the vertex's. Nesting is untidier
    # and lossless, which is the trade this makes.
    vertex = %Proto.AnalyzedConjunction.ConstraintVertex{
      vertex: {:label, %Proto.Type{type: {:entity_type, %Proto.EntityType{label: "person"}}}}
    }

    assert %{"tag" => "label", "label" => %{"tag" => "entityType", "label" => "person"}} =
             Decode.message(vertex)
  end

  test "a map field is rendered as a map" do
    conjunction = %Proto.AnalyzedConjunction{variable_annotations: %{7 => annotations(false)}}

    assert %{"variableAnnotations" => %{7 => %{"tag" => "instance", "isOptional" => false}}} =
             Decode.message(conjunction)
  end
end
