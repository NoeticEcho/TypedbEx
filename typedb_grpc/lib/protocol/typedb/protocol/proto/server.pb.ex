defmodule Typedb.Protocol.Server.ReplicationStatus.Role do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.Server.ReplicationStatus.Role",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :Primary, 0
  field :Candidate, 1
  field :Secondary, 2
end

defmodule Typedb.Protocol.ServerManager.All.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.All.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ServerManager.All.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.All.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :servers, 1, repeated: true, type: Typedb.Protocol.Server
end

defmodule Typedb.Protocol.ServerManager.All do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.All",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ServerManager.Get.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.Get.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ServerManager.Get.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.Get.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :server, 1, type: Typedb.Protocol.Server
end

defmodule Typedb.Protocol.ServerManager.Get do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager.Get",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.ServerManager do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.ServerManager",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Server.ReplicationStatus do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Server.ReplicationStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :uint64

  field :role, 2,
    proto3_optional: true,
    type: Typedb.Protocol.Server.ReplicationStatus.Role,
    enum: true

  field :term, 3, proto3_optional: true, type: :uint64
end

defmodule Typedb.Protocol.Server.Version.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Server.Version.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Server.Version.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Server.Version.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :distribution, 1, type: :string
  field :version, 2, type: :string
end

defmodule Typedb.Protocol.Server.Version do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Server.Version",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :address, 1, proto3_optional: true, type: :string

  field :replication_status, 2,
    proto3_optional: true,
    type: Typedb.Protocol.Server.ReplicationStatus,
    json_name: "replicationStatus"
end
