defmodule Typedb.Protocol.Concept do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Concept",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :concept, 0

  field :entity_type, 1, type: Typedb.Protocol.EntityType, json_name: "entityType", oneof: 0
  field :relation_type, 2, type: Typedb.Protocol.RelationType, json_name: "relationType", oneof: 0

  field :attribute_type, 3,
    type: Typedb.Protocol.AttributeType,
    json_name: "attributeType",
    oneof: 0

  field :role_type, 4, type: Typedb.Protocol.RoleType, json_name: "roleType", oneof: 0
  field :entity, 5, type: Typedb.Protocol.Entity, oneof: 0
  field :relation, 6, type: Typedb.Protocol.Relation, oneof: 0
  field :attribute, 7, type: Typedb.Protocol.Attribute, oneof: 0
end

defmodule Typedb.Protocol.Thing do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Thing",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :thing, 0

  field :entity, 1, type: Typedb.Protocol.Entity, oneof: 0
  field :relation, 2, type: Typedb.Protocol.Relation, oneof: 0
  field :attribute, 3, type: Typedb.Protocol.Attribute, oneof: 0
end

defmodule Typedb.Protocol.Entity do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Entity",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :iid, 1, type: :bytes

  field :entity_type, 2,
    proto3_optional: true,
    type: Typedb.Protocol.EntityType,
    json_name: "entityType"
end

defmodule Typedb.Protocol.Relation do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Relation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :iid, 1, type: :bytes

  field :relation_type, 2,
    proto3_optional: true,
    type: Typedb.Protocol.RelationType,
    json_name: "relationType"
end

defmodule Typedb.Protocol.Attribute do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Attribute",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :iid, 1, type: :bytes

  field :attribute_type, 2,
    proto3_optional: true,
    type: Typedb.Protocol.AttributeType,
    json_name: "attributeType"

  field :value, 3, type: Typedb.Protocol.Value
end

defmodule Typedb.Protocol.Value.Decimal do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Decimal",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :integer, 1, type: :sint64
  field :fractional, 2, type: :uint64
end

defmodule Typedb.Protocol.Value.Date do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Date",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :num_days_since_ce, 1, type: :sint32, json_name: "numDaysSinceCe"
end

defmodule Typedb.Protocol.Value.Datetime do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Datetime",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :seconds, 1, type: :sint64
  field :nanos, 2, type: :uint32
end

defmodule Typedb.Protocol.Value.Datetime_TZ do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Datetime_TZ",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :timezone, 0

  field :datetime, 1, type: Typedb.Protocol.Value.Datetime
  field :named, 2, type: :string, oneof: 0
  field :offset, 3, type: :sint32, oneof: 0
end

defmodule Typedb.Protocol.Value.Duration do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Duration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :months, 1, type: :uint32
  field :days, 2, type: :uint32
  field :nanos, 3, type: :uint64
end

defmodule Typedb.Protocol.Value.Struct do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value.Struct",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :struct_type_name, 1, type: :string, json_name: "structTypeName"
end

defmodule Typedb.Protocol.Value do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :value, 0

  field :boolean, 1, type: :bool, oneof: 0
  field :integer, 2, type: :sint64, oneof: 0
  field :double, 3, type: :double, oneof: 0
  field :decimal, 4, type: Typedb.Protocol.Value.Decimal, oneof: 0
  field :string, 5, type: :string, oneof: 0
  field :date, 6, type: Typedb.Protocol.Value.Date, oneof: 0
  field :datetime, 7, type: Typedb.Protocol.Value.Datetime, oneof: 0

  field :datetime_tz, 8,
    type: Typedb.Protocol.Value.Datetime_TZ,
    json_name: "datetimeTz",
    oneof: 0

  field :duration, 9, type: Typedb.Protocol.Value.Duration, oneof: 0
  field :struct, 10, type: Typedb.Protocol.Value.Struct, oneof: 0
end

defmodule Typedb.Protocol.Type do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Type",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :type, 0

  field :entity_type, 1, type: Typedb.Protocol.EntityType, json_name: "entityType", oneof: 0
  field :relation_type, 2, type: Typedb.Protocol.RelationType, json_name: "relationType", oneof: 0

  field :attribute_type, 3,
    type: Typedb.Protocol.AttributeType,
    json_name: "attributeType",
    oneof: 0

  field :role_type, 4, type: Typedb.Protocol.RoleType, json_name: "roleType", oneof: 0
end

defmodule Typedb.Protocol.RoleType do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RoleType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
end

defmodule Typedb.Protocol.EntityType do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.EntityType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
end

defmodule Typedb.Protocol.RelationType do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.RelationType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
end

defmodule Typedb.Protocol.AttributeType do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.AttributeType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string

  field :value_type, 2,
    proto3_optional: true,
    type: Typedb.Protocol.ValueType,
    json_name: "valueType"
end

defmodule Typedb.Protocol.ValueType.Boolean do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Boolean",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Integer do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Integer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Double do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Double",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Decimal do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Decimal",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.String do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.String",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Date do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Date",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.DateTime do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.DateTime",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.DateTime_TZ do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.DateTime_TZ",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Duration do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Duration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ValueType.Struct do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType.Struct",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.ValueType do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ValueType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :value_type, 0

  field :boolean, 1, type: Typedb.Protocol.ValueType.Boolean, oneof: 0
  field :integer, 2, type: Typedb.Protocol.ValueType.Integer, oneof: 0
  field :double, 3, type: Typedb.Protocol.ValueType.Double, oneof: 0
  field :decimal, 4, type: Typedb.Protocol.ValueType.Decimal, oneof: 0
  field :string, 5, type: Typedb.Protocol.ValueType.String, oneof: 0
  field :date, 6, type: Typedb.Protocol.ValueType.Date, oneof: 0
  field :datetime, 7, type: Typedb.Protocol.ValueType.DateTime, oneof: 0

  field :datetime_tz, 8,
    type: Typedb.Protocol.ValueType.DateTime_TZ,
    json_name: "datetimeTz",
    oneof: 0

  field :duration, 9, type: Typedb.Protocol.ValueType.Duration, oneof: 0
  field :struct, 10, type: Typedb.Protocol.ValueType.Struct, oneof: 0
end
