defmodule Typedb.Protocol.Authentication.Token.Create.Req.Password do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication.Token.Create.Req.Password",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :username, 1, type: :string
  field :password, 2, type: :string
end

defmodule Typedb.Protocol.Authentication.Token.Create.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication.Token.Create.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :credentials, 0

  field :password, 1, type: Typedb.Protocol.Authentication.Token.Create.Req.Password, oneof: 0
end

defmodule Typedb.Protocol.Authentication.Token.Create.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication.Token.Create.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :token, 1, type: :string
end

defmodule Typedb.Protocol.Authentication.Token.Create do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication.Token.Create",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Authentication.Token do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication.Token",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Authentication do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Authentication",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
