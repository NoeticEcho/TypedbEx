defmodule Typedb.Protocol.Options.Transaction do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Options.Transaction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :parallel, 1, proto3_optional: true, type: :bool

  field :transaction_timeout_millis, 2,
    proto3_optional: true,
    type: :uint64,
    json_name: "transactionTimeoutMillis"

  field :schema_lock_acquire_timeout_millis, 3,
    proto3_optional: true,
    type: :uint64,
    json_name: "schemaLockAcquireTimeoutMillis"
end

defmodule Typedb.Protocol.Options.Query do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Options.Query",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :include_instance_types, 1,
    proto3_optional: true,
    type: :bool,
    json_name: "includeInstanceTypes"

  field :prefetch_size, 2, proto3_optional: true, type: :uint64, json_name: "prefetchSize"

  field :include_query_structure, 3,
    proto3_optional: true,
    type: :bool,
    json_name: "includeQueryStructure"
end

defmodule Typedb.Protocol.Options.Analyze do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Options.Analyze",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :include_plan, 1, proto3_optional: true, type: :bool, json_name: "includePlan"
end

defmodule Typedb.Protocol.Options do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Options",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
