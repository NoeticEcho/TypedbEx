defmodule Typedb.Protocol.Version do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.Version",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNSPECIFIED, 0
  field :VERSION, 8
end

defmodule Typedb.Protocol.ExtensionVersion do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.ExtensionVersion",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNSPECIFIED_EXTENSION, 0
  field :EXTENSION, 2
end
