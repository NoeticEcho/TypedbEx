defmodule Typedb.Protocol.ConceptDocument.Node.Leaf.Kind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.ConceptDocument.Node.Leaf.Kind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :Entity, 0
  field :Relation, 1
  field :Attribute, 3
  field :Role, 4
end

defmodule Typedb.Protocol.ConceptRow do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptRow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :row, 1, repeated: true, type: Typedb.Protocol.RowEntry
  field :involved_blocks, 2, proto3_optional: true, type: :bytes, json_name: "involvedBlocks"
end

defmodule Typedb.Protocol.RowEntry.Empty do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RowEntry.Empty",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.RowEntry.ConceptList do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RowEntry.ConceptList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :concepts, 1, repeated: true, type: Typedb.Protocol.Concept
end

defmodule Typedb.Protocol.RowEntry.ValueList do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RowEntry.ValueList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :values, 1, repeated: true, type: Typedb.Protocol.Value
end

defmodule Typedb.Protocol.RowEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RowEntry",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :entry, 0

  field :empty, 1, type: Typedb.Protocol.RowEntry.Empty, oneof: 0
  field :concept, 2, type: Typedb.Protocol.Concept, oneof: 0
  field :value, 3, type: Typedb.Protocol.Value, oneof: 0

  field :concept_list, 4,
    type: Typedb.Protocol.RowEntry.ConceptList,
    json_name: "conceptList",
    oneof: 0

  field :value_list, 5, type: Typedb.Protocol.RowEntry.ValueList, json_name: "valueList", oneof: 0
end

defmodule Typedb.Protocol.ConceptDocument.Node.Map.MapEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node.Map.MapEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Typedb.Protocol.ConceptDocument.Node
end

defmodule Typedb.Protocol.ConceptDocument.Node.Map do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node.Map",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :map, 1,
    repeated: true,
    type: Typedb.Protocol.ConceptDocument.Node.Map.MapEntry,
    map: true
end

defmodule Typedb.Protocol.ConceptDocument.Node.List do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node.List",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :list, 1, repeated: true, type: Typedb.Protocol.ConceptDocument.Node
end

defmodule Typedb.Protocol.ConceptDocument.Node.Leaf.Empty do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node.Leaf.Empty",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ConceptDocument.Node.Leaf do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node.Leaf",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :leaf, 0

  field :empty, 1, type: Typedb.Protocol.ConceptDocument.Node.Leaf.Empty, oneof: 0
  field :entity_type, 10, type: Typedb.Protocol.EntityType, json_name: "entityType", oneof: 0

  field :relation_type, 11,
    type: Typedb.Protocol.RelationType,
    json_name: "relationType",
    oneof: 0

  field :attribute_type, 12,
    type: Typedb.Protocol.AttributeType,
    json_name: "attributeType",
    oneof: 0

  field :role_type, 13, type: Typedb.Protocol.RoleType, json_name: "roleType", oneof: 0
  field :value_type, 15, type: Typedb.Protocol.ValueType, json_name: "valueType", oneof: 0
  field :attribute, 20, type: Typedb.Protocol.Attribute, oneof: 0
  field :value, 21, type: Typedb.Protocol.Value, oneof: 0
  field :kind, 30, type: Typedb.Protocol.ConceptDocument.Node.Leaf.Kind, enum: true, oneof: 0
end

defmodule Typedb.Protocol.ConceptDocument.Node do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument.Node",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :node, 0

  field :map, 1, type: Typedb.Protocol.ConceptDocument.Node.Map, oneof: 0
  field :list, 2, type: Typedb.Protocol.ConceptDocument.Node.List, oneof: 0
  field :leaf, 3, type: Typedb.Protocol.ConceptDocument.Node.Leaf, oneof: 0
end

defmodule Typedb.Protocol.ConceptDocument do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConceptDocument",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :root, 1, type: Typedb.Protocol.ConceptDocument.Node
end
