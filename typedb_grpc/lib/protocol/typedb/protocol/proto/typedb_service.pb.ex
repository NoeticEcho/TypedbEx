defmodule Typedb.Protocol.TypeDB.Service do
  @moduledoc false

  use GRPC.Service, name: "typedb.protocol.TypeDB", protoc_gen_elixir_version: "0.17.0"

  rpc :connection_open, Typedb.Protocol.Connection.Open.Req, Typedb.Protocol.Connection.Open.Res

  rpc :authentication_token_create,
      Typedb.Protocol.Authentication.Token.Create.Req,
      Typedb.Protocol.Authentication.Token.Create.Res

  rpc :servers_all, Typedb.Protocol.ServerManager.All.Req, Typedb.Protocol.ServerManager.All.Res

  rpc :servers_get, Typedb.Protocol.ServerManager.Get.Req, Typedb.Protocol.ServerManager.Get.Res

  rpc :server_version, Typedb.Protocol.Server.Version.Req, Typedb.Protocol.Server.Version.Res

  rpc :users_get, Typedb.Protocol.UserManager.Get.Req, Typedb.Protocol.UserManager.Get.Res

  rpc :users_all, Typedb.Protocol.UserManager.All.Req, Typedb.Protocol.UserManager.All.Res

  rpc :users_contains,
      Typedb.Protocol.UserManager.Contains.Req,
      Typedb.Protocol.UserManager.Contains.Res

  rpc :users_create,
      Typedb.Protocol.UserManager.Create.Req,
      Typedb.Protocol.UserManager.Create.Res

  rpc :users_update, Typedb.Protocol.User.Update.Req, Typedb.Protocol.User.Update.Res

  rpc :users_delete, Typedb.Protocol.User.Delete.Req, Typedb.Protocol.User.Delete.Res

  rpc :databases_get,
      Typedb.Protocol.DatabaseManager.Get.Req,
      Typedb.Protocol.DatabaseManager.Get.Res

  rpc :databases_all,
      Typedb.Protocol.DatabaseManager.All.Req,
      Typedb.Protocol.DatabaseManager.All.Res

  rpc :databases_contains,
      Typedb.Protocol.DatabaseManager.Contains.Req,
      Typedb.Protocol.DatabaseManager.Contains.Res

  rpc :databases_create,
      Typedb.Protocol.DatabaseManager.Create.Req,
      Typedb.Protocol.DatabaseManager.Create.Res

  rpc :databases_import,
      stream(Typedb.Protocol.DatabaseManager.Import.Client),
      stream(Typedb.Protocol.DatabaseManager.Import.Server)

  rpc :database_schema, Typedb.Protocol.Database.Schema.Req, Typedb.Protocol.Database.Schema.Res

  rpc :database_type_schema,
      Typedb.Protocol.Database.TypeSchema.Req,
      Typedb.Protocol.Database.TypeSchema.Res

  rpc :database_delete, Typedb.Protocol.Database.Delete.Req, Typedb.Protocol.Database.Delete.Res

  rpc :database_export,
      Typedb.Protocol.Database.Export.Req,
      stream(Typedb.Protocol.Database.Export.Server)

  rpc :transaction,
      stream(Typedb.Protocol.Transaction.Client),
      stream(Typedb.Protocol.Transaction.Server)
end

defmodule Typedb.Protocol.TypeDB.Stub do
  @moduledoc false

  use GRPC.Stub, service: Typedb.Protocol.TypeDB.Service
end
