defmodule Typedb.Protocol.Query.Type do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "typedb.protocol.Query.Type",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :READ, 0
  field :WRITE, 1
  field :SCHEMA, 2
end

defmodule Typedb.Protocol.Query.Req.GivenRows do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.Req.GivenRows",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :variables, 1, repeated: true, type: :string
  field :rows, 2, repeated: true, type: Typedb.Protocol.Query.Req.GivenRow
end

defmodule Typedb.Protocol.Query.Req.GivenRow do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.Req.GivenRow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :entries, 1, repeated: true, type: Typedb.Protocol.Query.Req.GivenEntry
end

defmodule Typedb.Protocol.Query.Req.GivenEntry.EmptyEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.Req.GivenEntry.EmptyEntry",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Typedb.Protocol.Query.Req.GivenEntry do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.Req.GivenEntry",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :entry, 0

  field :empty, 1, type: Typedb.Protocol.Query.Req.GivenEntry.EmptyEntry, oneof: 0
  field :value, 2, type: Typedb.Protocol.Value, oneof: 0
  field :thing, 3, type: Typedb.Protocol.Thing, oneof: 0
end

defmodule Typedb.Protocol.Query.Req do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.Req",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :options, 1, type: Typedb.Protocol.Options.Query
  field :query, 2, type: :string
  field :given, 3, type: Typedb.Protocol.Query.Req.GivenRows
end

defmodule Typedb.Protocol.Query.InitialRes.Ok.Done do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.InitialRes.Ok.Done",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :query_type, 1, type: Typedb.Protocol.Query.Type, json_name: "queryType", enum: true
end

defmodule Typedb.Protocol.Query.InitialRes.Ok.ConceptDocumentStream do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.InitialRes.Ok.ConceptDocumentStream",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :query_type, 2, type: Typedb.Protocol.Query.Type, json_name: "queryType", enum: true
end

defmodule Typedb.Protocol.Query.InitialRes.Ok.ConceptRowStream do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.InitialRes.Ok.ConceptRowStream",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :column_variable_names, 1, repeated: true, type: :string, json_name: "columnVariableNames"
  field :query_type, 2, type: Typedb.Protocol.Query.Type, json_name: "queryType", enum: true

  field :query_structure, 3,
    proto3_optional: true,
    type: Typedb.Protocol.Analyze.Res.AnalyzedQuery.Pipeline,
    json_name: "queryStructure"
end

defmodule Typedb.Protocol.Query.InitialRes.Ok do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.InitialRes.Ok",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :ok, 0

  field :done, 1, type: Typedb.Protocol.Query.InitialRes.Ok.Done, oneof: 0

  field :concept_document_stream, 3,
    type: Typedb.Protocol.Query.InitialRes.Ok.ConceptDocumentStream,
    json_name: "conceptDocumentStream",
    oneof: 0

  field :concept_row_stream, 4,
    type: Typedb.Protocol.Query.InitialRes.Ok.ConceptRowStream,
    json_name: "conceptRowStream",
    oneof: 0
end

defmodule Typedb.Protocol.Query.InitialRes do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.InitialRes",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :res, 0

  field :error, 1, type: Typedb.Protocol.Error, oneof: 0
  field :ok, 2, type: Typedb.Protocol.Query.InitialRes.Ok, oneof: 0
end

defmodule Typedb.Protocol.Query.ResPart.ConceptDocumentsRes do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.ResPart.ConceptDocumentsRes",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :documents, 1, repeated: true, type: Typedb.Protocol.ConceptDocument
end

defmodule Typedb.Protocol.Query.ResPart.ConceptRowsRes do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.ResPart.ConceptRowsRes",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rows, 1, repeated: true, type: Typedb.Protocol.ConceptRow
end

defmodule Typedb.Protocol.Query.ResPart do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query.ResPart",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :res, 0

  field :documents_res, 1,
    type: Typedb.Protocol.Query.ResPart.ConceptDocumentsRes,
    json_name: "documentsRes",
    oneof: 0

  field :rows_res, 2,
    type: Typedb.Protocol.Query.ResPart.ConceptRowsRes,
    json_name: "rowsRes",
    oneof: 0
end

defmodule Typedb.Protocol.Query do
  @moduledoc false

  use Protobuf,
    full_name: "typedb.protocol.Query",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
