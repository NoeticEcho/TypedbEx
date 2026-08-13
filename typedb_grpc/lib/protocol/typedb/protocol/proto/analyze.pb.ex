defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable.SortDirection do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable.SortDirection",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ASC, 0
  field :DESC, 1
end

defmodule Typedb.Protocol.Analyze.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :options, 1, type: Typedb.Protocol.Options.Analyze
  field :query, 2, type: :string
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpStream do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpStream",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variables, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpSingle do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpSingle",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :selector, 1, type: :string
  field :variables, 2, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpCheck do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpCheck",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpReduce do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpReduce",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reducers, 1, repeated: true, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Reducer
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :return_operation, 0

  field :stream, 1,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpStream,
    oneof: 0

  field :single, 2,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpSingle,
    oneof: 0

  field :check, 3,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpCheck,
    oneof: 0

  field :reduce, 4,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation.ReturnOpReduce,
    oneof: 0
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Function",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :body, 1, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline
  field :arguments, 2, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable

  field :arguments_annotations, 3,
    repeated: true,
    type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations,
    json_name: "argumentsAnnotations"

  field :return_annotations, 4,
    repeated: true,
    type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations,
    json_name: "returnAnnotations"

  field :return_operation, 5,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function.ReturnOperation,
    json_name: "returnOperation"
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven.VariableAnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven.VariableAnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :uint32
  field :value, 2, type: Typedb.Protocol.AnalyzedConjunction.VariableAnnotations
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variables, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable

  field :variable_annotations, 2,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven.VariableAnnotationsEntry,
    json_name: "variableAnnotations",
    map: true
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfoEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfoEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :uint32
  field :value, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfo
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfo do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Match do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Match",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :block, 1, type: :uint32
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Insert do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Insert",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :block, 1, type: :uint32
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Put do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Put",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :block, 1, type: :uint32
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Update do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Update",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :block, 1, type: :uint32
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Delete do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Delete",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :block, 1, type: :uint32

  field :deleted_variables, 2,
    repeated: true,
    type: Typedb.Protocol.AnalyzedConjunction.Variable,
    json_name: "deletedVariables"
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Select do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Select",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variables, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variable, 1, type: Typedb.Protocol.AnalyzedConjunction.Variable

  field :direction, 2,
    type:
      Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable.SortDirection,
    enum: true
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sort_variables, 1,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort.SortVariable,
    json_name: "sortVariables"
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Require do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Require",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variables, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Offset do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Offset",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :offset, 1, type: :uint64
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Limit do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Limit",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :limit, 1, type: :uint64
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Distinct do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Distinct",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce.ReduceAssign do
  @moduledoc false

  use Protobuf,
    full_name:
      "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce.ReduceAssign",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :assigned, 1, type: Typedb.Protocol.AnalyzedConjunction.Variable
  field :reducer, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Reducer
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reducers, 1,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce.ReduceAssign

  field :groupby, 2, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :stage, 0

  field :match, 1,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Match,
    oneof: 0

  field :insert, 2,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Insert,
    oneof: 0

  field :put, 3,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Put,
    oneof: 0

  field :update, 4,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Update,
    oneof: 0

  field :delete, 5,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Delete,
    oneof: 0

  field :select, 6,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Select,
    oneof: 0

  field :sort, 7,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Sort,
    oneof: 0

  field :require, 8,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Require,
    oneof: 0

  field :offset, 9,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Offset,
    oneof: 0

  field :limit, 10,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Limit,
    oneof: 0

  field :distinct, 11,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Distinct,
    oneof: 0

  field :reduce, 12,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage.Reduce,
    oneof: 0
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Pipeline",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :conjunctions, 1, repeated: true, type: Typedb.Protocol.AnalyzedConjunction

  field :stages, 2,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.PipelineStage

  field :variable_info, 3,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline.VariableInfoEntry,
    json_name: "variableInfo",
    map: true

  field :outputs, 4, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Reducer do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Reducer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reducer, 1, type: :string
  field :variables, 2, repeated: true, type: Typedb.Protocol.AnalyzedConjunction.Variable
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Object.FetchEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Fetch.Object.FetchEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Object do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Fetch.Object",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :fetch, 1,
    repeated: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Object.FetchEntry,
    map: true
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Leaf do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Fetch.Leaf",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :annotations, 1, repeated: true, type: Typedb.Protocol.ValueType
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery.Fetch",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :node, 0

  field :object, 1, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Object, oneof: 0
  field :list, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch, oneof: 0
  field :leaf, 3, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch.Leaf, oneof: 0
end

defmodule Typedb.Protocol.Analyze.Res.AnalyzedQuery do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res.AnalyzedQuery",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :source, 1, type: :string
  field :query, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline
  field :preamble, 3, repeated: true, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Function
  field :fetch, 4, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Fetch
  field :given, 5, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.AnalyzedGiven
end

defmodule Typedb.Protocol.Analyze.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :result, 0

  field :err, 1, type: Typedb.Protocol.Error, oneof: 0
  field :ok, 2, type: Typedb.Protocol.Analyze.Res.AnalyzedQuery, oneof: 0
end

defmodule Typedb.Protocol.Analyze do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Analyze",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
