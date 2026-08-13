defmodule Typedb.Protocol.Migration.Export.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.Migration.Export.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :server, 0

  field :initial_res, 1,
    type: Typedb.Protocol.Migration.Export.InitialRes,
    json_name: "initialRes",
    oneof: 0

  field :res_part, 2,
    type: Typedb.Protocol.Migration.Export.ResPart,
    json_name: "resPart",
    oneof: 0

  field :done, 3, type: Typedb.Protocol.Migration.Export.Done, oneof: 0
end

defmodule Typedb.Protocol.Migration.Export.InitialRes do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export.InitialRes",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :schema, 1, type: :string
end

defmodule Typedb.Protocol.Migration.Export.ResPart do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export.ResPart",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :items, 1, repeated: true, type: Typedb.Protocol.Migration.Item
end

defmodule Typedb.Protocol.Migration.Export.Done do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export.Done",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Migration.Export do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Export",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Migration.Import.Client.InitialReq do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Client.InitialReq",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :schema, 2, type: :string
end

defmodule Typedb.Protocol.Migration.Import.Client.ReqPart do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Client.ReqPart",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :items, 1, repeated: true, type: Typedb.Protocol.Migration.Item
end

defmodule Typedb.Protocol.Migration.Import.Client.Done do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Client.Done",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Migration.Import.Client do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Client",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :client, 0

  field :initial_req, 1,
    type: Typedb.Protocol.Migration.Import.Client.InitialReq,
    json_name: "initialReq",
    oneof: 0

  field :req_part, 2,
    type: Typedb.Protocol.Migration.Import.Client.ReqPart,
    json_name: "reqPart",
    oneof: 0

  field :done, 3, type: Typedb.Protocol.Migration.Import.Client.Done, oneof: 0
end

defmodule Typedb.Protocol.Migration.Import.Server.Done do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Server.Done",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Migration.Import.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :done, 1, type: Typedb.Protocol.Migration.Import.Server.Done
end

defmodule Typedb.Protocol.Migration.Import do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Import",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Migration.Item.Entity do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Entity",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :label, 2, type: :string
  field :attributes, 3, repeated: true, type: Typedb.Protocol.Migration.Item.OwnedAttribute
end

defmodule Typedb.Protocol.Migration.Item.Attribute do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Attribute",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :label, 2, type: :string
  field :attributes, 3, repeated: true, type: Typedb.Protocol.Migration.Item.OwnedAttribute
  field :value, 4, type: Typedb.Protocol.Migration.MigrationValue
end

defmodule Typedb.Protocol.Migration.Item.Relation.Role.Player do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Relation.Role.Player",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
end

defmodule Typedb.Protocol.Migration.Item.Relation.Role do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Relation.Role",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :players, 2, repeated: true, type: Typedb.Protocol.Migration.Item.Relation.Role.Player
end

defmodule Typedb.Protocol.Migration.Item.Relation do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Relation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :label, 2, type: :string
  field :attributes, 3, repeated: true, type: Typedb.Protocol.Migration.Item.OwnedAttribute
  field :roles, 4, repeated: true, type: Typedb.Protocol.Migration.Item.Relation.Role
end

defmodule Typedb.Protocol.Migration.Item.OwnedAttribute do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.OwnedAttribute",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
end

defmodule Typedb.Protocol.Migration.Item.Header do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Header",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :typedb_version, 1, type: :string, json_name: "typedbVersion"
  field :original_database, 2, type: :string, json_name: "originalDatabase"
end

defmodule Typedb.Protocol.Migration.Item.Checksums do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item.Checksums",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :entity_count, 1, type: :int64, json_name: "entityCount"
  field :attribute_count, 2, type: :int64, json_name: "attributeCount"
  field :relation_count, 3, type: :int64, json_name: "relationCount"
  field :role_count, 4, type: :int64, json_name: "roleCount"
  field :ownership_count, 5, type: :int64, json_name: "ownershipCount"
end

defmodule Typedb.Protocol.Migration.Item do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.Item",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :item, 0

  field :attribute, 1, type: Typedb.Protocol.Migration.Item.Attribute, oneof: 0
  field :entity, 2, type: Typedb.Protocol.Migration.Item.Entity, oneof: 0
  field :relation, 3, type: Typedb.Protocol.Migration.Item.Relation, oneof: 0
  field :header, 15, type: Typedb.Protocol.Migration.Item.Header, oneof: 0
  field :checksums, 16, type: Typedb.Protocol.Migration.Item.Checksums, oneof: 0
end

defmodule Typedb.Protocol.Migration.MigrationValue do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration.MigrationValue",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :value, 0

  field :string, 1, type: :string, oneof: 0
  field :boolean, 2, type: :bool, oneof: 0
  field :integer, 3, type: :int64, oneof: 0
  field :double, 4, type: :double, oneof: 0
  field :datetime_millis, 5, type: :int64, json_name: "datetimeMillis", oneof: 0
  field :decimal, 6, type: Typedb.Protocol.Value.Decimal, oneof: 0
  field :date, 8, type: Typedb.Protocol.Value.Date, oneof: 0
  field :datetime, 9, type: Typedb.Protocol.Value.Datetime, oneof: 0

  field :datetime_tz, 10,
    type: Typedb.Protocol.Value.Datetime_TZ,
    json_name: "datetimeTz",
    oneof: 0

  field :duration, 11, type: Typedb.Protocol.Value.Duration, oneof: 0
  field :struct, 12, type: Typedb.Protocol.Value.Struct, oneof: 0
end

defmodule Typedb.Protocol.Migration do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Migration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
