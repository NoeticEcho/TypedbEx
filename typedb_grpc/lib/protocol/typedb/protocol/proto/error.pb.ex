defmodule Typedb.Protocol.Error do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Error",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :error_code, 1, type: :string, json_name: "errorCode"
  field :domain, 2, type: :string
  field :stack_trace, 3, repeated: true, type: :string, json_name: "stackTrace"
end
