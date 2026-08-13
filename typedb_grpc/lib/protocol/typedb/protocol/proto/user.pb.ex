defmodule Typedb.Protocol.UserManager.All.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.All.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager.All.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.All.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :users, 1, repeated: true, type: Typedb.Protocol.User
end

defmodule Typedb.Protocol.UserManager.All do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.All",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager.Contains.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Contains.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.UserManager.Contains.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Contains.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :contains, 1, type: :bool
end

defmodule Typedb.Protocol.UserManager.Contains do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Contains",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager.Get.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Get.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.UserManager.Get.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Get.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :user, 1, type: Typedb.Protocol.User
end

defmodule Typedb.Protocol.UserManager.Get do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Get",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager.Create.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Create.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :user, 1, type: Typedb.Protocol.User
end

defmodule Typedb.Protocol.UserManager.Create.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Create.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager.Create do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager.Create",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.UserManager do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.UserManager",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.User.Update.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Update.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :user, 2, type: Typedb.Protocol.User
end

defmodule Typedb.Protocol.User.Update.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Update.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.User.Update do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Update",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.User.Delete.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Delete.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Typedb.Protocol.User.Delete.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Delete.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.User.Delete do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User.Delete",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.User do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.User",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :password, 2, proto3_optional: true, type: :string
end
