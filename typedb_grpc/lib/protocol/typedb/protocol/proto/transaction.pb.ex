defmodule Typedb.Protocol.Transaction.Type do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.Transaction.Type",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :READ, 0
  field :WRITE, 1
  field :SCHEMA, 2
end

defmodule Typedb.Protocol.Transaction.Client do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Client",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reqs, 1, repeated: true, type: Typedb.Protocol.Transaction.Req
end

defmodule Typedb.Protocol.Transaction.Server do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Server",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :server, 0

  field :res, 1, type: Typedb.Protocol.Transaction.Res, oneof: 0
  field :res_part, 2, type: Typedb.Protocol.Transaction.ResPart, json_name: "resPart", oneof: 0
end

defmodule Typedb.Protocol.Transaction.Req.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Req.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Typedb.Protocol.Transaction.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :req, 0

  field :req_id, 1, type: :bytes, json_name: "reqId"

  field :metadata, 2,
    repeated: true,
    type: Typedb.Protocol.Transaction.Req.MetadataEntry,
    map: true

  field :open_req, 3, type: Typedb.Protocol.Transaction.Open.Req, json_name: "openReq", oneof: 0
  field :query_req, 4, type: Typedb.Protocol.Query.Req, json_name: "queryReq", oneof: 0

  field :stream_req, 5,
    type: Typedb.Protocol.Transaction.StreamSignal.Req,
    json_name: "streamReq",
    oneof: 0

  field :commit_req, 6,
    type: Typedb.Protocol.Transaction.Commit.Req,
    json_name: "commitReq",
    oneof: 0

  field :rollback_req, 7,
    type: Typedb.Protocol.Transaction.Rollback.Req,
    json_name: "rollbackReq",
    oneof: 0

  field :close_req, 8,
    type: Typedb.Protocol.Transaction.Close.Req,
    json_name: "closeReq",
    oneof: 0

  field :analyze_req, 9, type: Typedb.Protocol.Analyze.Req, json_name: "analyzeReq", oneof: 0
end

defmodule Typedb.Protocol.Transaction.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :res, 0

  field :req_id, 1, type: :bytes, json_name: "reqId"
  field :open_res, 2, type: Typedb.Protocol.Transaction.Open.Res, json_name: "openRes", oneof: 0

  field :query_initial_res, 3,
    type: Typedb.Protocol.Query.InitialRes,
    json_name: "queryInitialRes",
    oneof: 0

  field :commit_res, 5,
    type: Typedb.Protocol.Transaction.Commit.Res,
    json_name: "commitRes",
    oneof: 0

  field :rollback_res, 6,
    type: Typedb.Protocol.Transaction.Rollback.Res,
    json_name: "rollbackRes",
    oneof: 0

  field :analyze_res, 9, type: Typedb.Protocol.Analyze.Res, json_name: "analyzeRes", oneof: 0
end

defmodule Typedb.Protocol.Transaction.ResPart do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.ResPart",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :res_part, 0

  field :req_id, 1, type: :bytes, json_name: "reqId"
  field :query_res, 2, type: Typedb.Protocol.Query.ResPart, json_name: "queryRes", oneof: 0

  field :stream_res, 3,
    type: Typedb.Protocol.Transaction.StreamSignal.ResPart,
    json_name: "streamRes",
    oneof: 0
end

defmodule Typedb.Protocol.Transaction.Open.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Open.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :database, 1, type: :string
  field :type, 2, type: Typedb.Protocol.Transaction.Type, enum: true
  field :options, 3, type: Typedb.Protocol.Options.Transaction
  field :network_latency_millis, 4, type: :uint64, json_name: "networkLatencyMillis"
end

defmodule Typedb.Protocol.Transaction.Open.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Open.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :server_duration_millis, 2, type: :uint64, json_name: "serverDurationMillis"
end

defmodule Typedb.Protocol.Transaction.Open do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Open",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Commit.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Commit.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Commit.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Commit.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Commit do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Commit",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Rollback.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Rollback.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Rollback.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Rollback.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Rollback do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Rollback",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Close.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Close.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Close.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Close.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.Close do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.Close",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.GetSchemaExceptions.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.GetSchemaExceptions.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.GetSchemaExceptions.Res do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.GetSchemaExceptions.Res",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :exceptions, 1, repeated: true, type: Typedb.Protocol.Transaction.SchemaException
end

defmodule Typedb.Protocol.Transaction.GetSchemaExceptions do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.GetSchemaExceptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.SchemaException do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.SchemaException",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: :string
  field :message, 2, type: :string
end

defmodule Typedb.Protocol.Transaction.StreamSignal.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.StreamSignal.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.StreamSignal.ResPart.Continue do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.StreamSignal.ResPart.Continue",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.StreamSignal.ResPart.Done do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.StreamSignal.ResPart.Done",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction.StreamSignal.ResPart do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.StreamSignal.ResPart",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :state, 0

  field :continue, 1, type: Typedb.Protocol.Transaction.StreamSignal.ResPart.Continue, oneof: 0
  field :done, 2, type: Typedb.Protocol.Transaction.StreamSignal.ResPart.Done, oneof: 0
  field :error, 3, type: Typedb.Protocol.Error, oneof: 0
end

defmodule Typedb.Protocol.Transaction.StreamSignal do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction.StreamSignal",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Transaction do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Transaction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
