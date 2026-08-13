defmodule Typedb.Protocol.Connection.Open.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Connection.Open.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :version, 1, type: Typedb.Protocol.Version, enum: true

  field :extension_version, 5,
    type: Typedb.Protocol.ExtensionVersion,
    json_name: "extensionVersion",
    enum: true

  field :driver_lang, 2, type: :string, json_name: "driverLang"
  field :driver_version, 3, type: :string, json_name: "driverVersion"
  field :authentication, 4, type: Typedb.Protocol.Authentication.Token.Create.Req
end

defmodule Typedb.Protocol.Connection.Open.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Connection.Open.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :server_duration_millis, 1, type: :uint64, json_name: "serverDurationMillis"
  field :connection_id, 2, type: Typedb.Protocol.ConnectionID, json_name: "connectionId"
  field :servers_all, 3, type: Typedb.Protocol.ServerManager.All.Res, json_name: "serversAll"
  field :authentication, 4, type: Typedb.Protocol.Authentication.Token.Create.Res
end

defmodule Typedb.Protocol.Connection.Open do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Connection.Open",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Connection do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Connection",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ConnectionID do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ConnectionID",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :bytes
end
