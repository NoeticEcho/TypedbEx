defmodule Typedb.Protocol.DatabaseManager.Get.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Get.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.DatabaseManager.Get.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Get.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: Typedb.Protocol.Database
end

defmodule Typedb.Protocol.DatabaseManager.Get do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Get",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager.All.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.All.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager.All.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.All.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :databases, 1, repeated: true, type: Typedb.Protocol.Database
end

defmodule Typedb.Protocol.DatabaseManager.All do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.All",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager.Contains.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Contains.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.DatabaseManager.Contains.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Contains.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :contains, 1, type: :bool
end

defmodule Typedb.Protocol.DatabaseManager.Contains do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Contains",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager.Create.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Create.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.DatabaseManager.Create.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Create.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: Typedb.Protocol.Database
end

defmodule Typedb.Protocol.DatabaseManager.Create do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Create",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager.Import.Client do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Import.Client",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :client, 1, type: Typedb.Protocol.Migration.Import.Client
end

defmodule Typedb.Protocol.DatabaseManager.Import.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Import.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :server, 1, type: Typedb.Protocol.Migration.Import.Server
end

defmodule Typedb.Protocol.DatabaseManager.Import do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager.Import",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.DatabaseManager do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.DatabaseManager",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database.Schema.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Schema.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.Database.Schema.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Schema.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :schema, 1, type: :string
end

defmodule Typedb.Protocol.Database.Schema do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Schema",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database.TypeSchema.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.TypeSchema.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.Database.TypeSchema.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.TypeSchema.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :schema, 1, type: :string
end

defmodule Typedb.Protocol.Database.TypeSchema do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.TypeSchema",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database.Export.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Export.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :req, 1, type: Typedb.Protocol.Migration.Export.Req
end

defmodule Typedb.Protocol.Database.Export.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Export.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :server, 1, type: Typedb.Protocol.Migration.Export.Server
end

defmodule Typedb.Protocol.Database.Export do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Export",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database.Delete.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Delete.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.Database.Delete.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Delete.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database.Delete do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database.Delete",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Database do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Database",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end
