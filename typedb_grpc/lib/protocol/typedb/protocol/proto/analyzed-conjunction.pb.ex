defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.ConstraintExactness",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXACT, 0
  field :SUBTYPES, 1
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Comparison.Comparator do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Comparison.Comparator",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EQUAL, 0
  field :NOT_EQUAL, 1
  field :LESS, 2
  field :GREATER, 3
  field :LESS_OR_EQUAL, 4
  field :GREATER_OR_EQUAL, 5
  field :LIKE, 6
  field :CONTAINS, 7
end

defmodule Typedb.Protocol.AnalyzedConjunction.VariableAnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.VariableAnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :uint32
  field :value, 2, type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations
end

defmodule Typedb.Protocol.AnalyzedConjunction.Variable do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Variable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :uint32
end

defmodule Typedb.Protocol.AnalyzedConjunction.ConstraintVertex.NamedRole do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.ConstraintVertex.NamedRole",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variable, 1, type: Typedb.Protocol.AnalyzedConjunction.Variable
  field :name, 2, type: :string
end

defmodule Typedb.Protocol.AnalyzedConjunction.ConstraintVertex do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.ConstraintVertex",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :vertex, 0

  field :variable, 1, type: Typedb.Protocol.AnalyzedConjunction.Variable, oneof: 0
  field :label, 2, type: Typedb.Protocol.Type, oneof: 0
  field :value, 3, type: Typedb.Protocol.Value, oneof: 0

  field :named_role, 4,
    type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex.NamedRole,
    json_name: "namedRole",
    oneof: 0
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintSpan do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.ConstraintSpan",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :begin, 1, type: :uint64
  field :end, 2, type: :uint64
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Or do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Or",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :branches, 1, repeated: true, type: :uint32
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Not do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Not",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :conjunction, 1, type: :uint32
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Try do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Try",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :conjunction, 1, type: :uint32
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Isa do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Isa",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :type, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Has do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Has",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :owner, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :attribute, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Links do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Links",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :relation, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :player, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :role, 3, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 4,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Kind do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Kind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :kind, 1, type: Typedb.Protocol.ConceptDocument.Node.Leaf.Kind, enum: true
  field :type, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Sub do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Sub",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :subtype, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :supertype, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Owns do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Owns",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :owner, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :attribute, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Relates do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Relates",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :relation, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :role, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Plays do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Plays",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :player, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :role, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :exactness, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintExactness,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Label do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Label",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :type, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :label, 2, type: :string
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Value do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :attribute_type, 1,
    type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex,
    json_name: "attributeType"

  field :value_type, 2, type: Typedb.Protocol.ValueType, json_name: "valueType"
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Comparison do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Comparison",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :lhs, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :rhs, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex

  field :comparator, 3,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.Comparison.Comparator,
    enum: true
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Expression do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Expression",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :text, 1, type: :string
  field :assigned, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :arguments, 3, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.FunctionCall do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.FunctionCall",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :assigned, 2, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :arguments, 3, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.Is do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.Is",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :lhs, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :rhs, 2, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint.IID do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint.IID",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :concept, 1, type: Typedb.Protocol.AnalyzedConjunction.ConstraintVertex
  field :IID, 2, type: :bytes
end

defmodule Typedb.Protocol.AnalyzedConjunction.Constraint do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.Constraint",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :constraint, 0

  field :span, 1, type: Typedb.Protocol.AnalyzedConjunction.Constraint.ConstraintSpan
  field :or, 2, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Or, oneof: 0
  field :not, 3, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Not, oneof: 0
  field :try, 4, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Try, oneof: 0
  field :isa, 5, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Isa, oneof: 0
  field :has, 6, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Has, oneof: 0
  field :links, 7, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Links, oneof: 0
  field :kind, 8, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Kind, oneof: 0
  field :sub, 9, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Sub, oneof: 0
  field :owns, 10, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Owns, oneof: 0
  field :relates, 11, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Relates, oneof: 0
  field :plays, 12, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Plays, oneof: 0
  field :value, 13, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Value, oneof: 0
  field :label, 14, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Label, oneof: 0
  field :comparison, 15, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Comparison, oneof: 0
  field :expression, 16, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Expression, oneof: 0

  field :function_call, 17,
    type: Typedb.Protocol.AnalyzedConjunction.Constraint.FunctionCall,
    json_name: "functionCall",
    oneof: 0

  field :is, 18, type: Typedb.Protocol.AnalyzedConjunction.Constraint.Is, oneof: 0
  field :iid, 19, type: Typedb.Protocol.AnalyzedConjunction.Constraint.IID, oneof: 0
end

defmodule Typedb.Protocol.AnalyzedConjunction.VariableAnnotations.ConceptVariableAnnotations do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.AnalyzedConjunction.VariableAnnotations.ConceptVariableAnnotations",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :types, 1, repeated: true, type: Typedb.Protocol.Type
end

defmodule Typedb.Protocol.AnalyzedConjunction.VariableAnnotations do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction.VariableAnnotations",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :annotations, 0

  field :instance, 1,
    type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations.ConceptVariableAnnotations,
    oneof: 0

  field :type, 2,
    type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations.ConceptVariableAnnotations,
    oneof: 0

  field :value_annotations, 3,
    type: Typedb.Protocol.ValueType,
    json_name: "valueAnnotations",
    oneof: 0

  field :is_optional, 4, type: :bool, json_name: "isOptional"
end

defmodule Typedb.Protocol.AnalyzedConjunction do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AnalyzedConjunction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :constraints, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Constraint

  field :variable_annotations, 2,
    repeated: true,
    type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotationsEntry,
    json_name: "variableAnnotations",
    map: true
end
