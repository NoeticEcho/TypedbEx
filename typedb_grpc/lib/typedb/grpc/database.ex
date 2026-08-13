defmodule TypeDB.GRPC.Database do
  @moduledoc """
  Databases, over the unary half of the protocol.

  Mirrors `TypeDB.Database` — same names, same return shapes, same
  `%TypeDB.Error{}` — so that switching transports does not rewrite the code
  that manages databases either.

  Creating a database that already exists succeeds here, and — contrary to what
  this module used to claim — it succeeds over the HTTP API too. TypeDB 3.x
  treats it as a no-op on both. `create_if_not_exists/3` exists so that callers
  who mean the idempotent thing say so, not because the two transports disagree;
  the shared behaviour suite asserts that they do not.
  """

  use TypeDB.GRPC.Bang
  alias TypeDB.Error
  alias TypeDB.GRPC.{Connection, Migration}
  alias TypeDB.GRPC.Error, as: GRPCError
  alias Typedb.Protocol, as: Proto

  @doc "Every database on the server."
  @spec list(Connection.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_all(channel, %Proto.DatabaseManager.All.Req{},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "listing databases",
             operation: :databases_all
           ) do
      {:ok, Enum.map(reply.databases, & &1.name)}
    end
  end

  @doc """
  A database's name, or an error when it does not exist.

  The same contract as `TypeDB.Database.get/3` and as Rust's
  `DatabaseManager::get`: absence is an error carrying the server's own code,
  not a `false`. `exists?/3` is the boolean question, and it raises when it
  cannot ask.

  A name rather than a handle object: everything else in this module is a
  function taking one, so a struct here would be a second way to say the same
  thing.
  """
  @spec get(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_get(channel, %Proto.DatabaseManager.Get.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading database #{inspect(name)}",
             operation: :databases_get,
             database: name
           ) do
      {:ok, reply.database.name}
    end
  end

  @doc """
  Whether `name` exists.

  Raises `TypeDB.Error` for anything other than a clean answer — the same
  contract as `TypeDB.Database.exists?/3`, and for the reason recorded there: a
  boolean cannot express "I could not ask", and answering `false` to that is
  what makes `unless exists?(conn, x), do: create(conn, x)` try to create while
  the server is down.
  """
  @spec exists?(Connection.t(), String.t(), keyword()) :: boolean()
  def exists?(conn, name, opts \\ []) when is_binary(name) do
    case Connection.unary(
           conn,
           fn channel, md ->
             Proto.TypeDB.Stub.databases_contains(
               channel,
               %Proto.DatabaseManager.Contains.Req{name: name},
               metadata: md,
               timeout: timeout(conn, opts)
             )
           end,
           "checking whether database #{inspect(name)} exists",
           operation: :database_exists,
           database: name
         ) do
      {:ok, reply} -> reply.contains
      {:error, error} -> raise error
    end
  end

  @doc """
  Creates a database.

  A no-op for one that already exists, on this transport and over HTTP alike.
  """
  @spec create(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, _reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.databases_create(
                 channel,
                 %Proto.DatabaseManager.Create.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "creating database #{inspect(name)}",
             operation: :database_create,
             database: name
           ) do
      :ok
    end
  end

  @doc "Creates a database unless it is already there."
  @spec create_if_not_exists(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def create_if_not_exists(conn, name, opts \\ []) when is_binary(name) do
    if exists?(conn, name, opts), do: :ok, else: create(conn, name, opts)
  end

  @doc "Deletes a database and everything in it."
  @spec delete(Connection.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, _reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_delete(channel, %Proto.Database.Delete.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "deleting database #{inspect(name)}",
             operation: :database_delete,
             database: name
           ) do
      :ok
    end
  end

  @doc "The database's full schema as TypeQL."
  @spec schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def schema(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_schema(channel, %Proto.Database.Schema.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading the schema of #{inspect(name)}",
             operation: :database_schema,
             database: name
           ) do
      {:ok, reply.schema}
    end
  end

  @doc "The type part of the schema, without the functions."
  @spec type_schema(Connection.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_schema(conn, name, opts \\ []) when is_binary(name) do
    with {:ok, reply} <-
           Connection.unary(
             conn,
             fn channel, md ->
               Proto.TypeDB.Stub.database_type_schema(
                 channel,
                 %Proto.Database.TypeSchema.Req{name: name},
                 metadata: md,
                 timeout: timeout(conn, opts)
               )
             end,
             "reading the type schema of #{inspect(name)}",
             operation: :database_type_schema,
             database: name
           ) do
      {:ok, reply.schema}
    end
  end

  @doc """
  Writes a database's schema and data to two files.

  The one thing this driver does that the HTTP one cannot do at all. TypeDB's
  HTTP API has no export and no import — `/v1/databases/x/export` answers 404
  with a valid token while `/schema` on the same token answers 200 — so a graph
  written through the sibling can be read back only by replaying whatever
  journal the application kept. This is the native thing: the server streams the
  schema and then every entity, attribute and relation, and the pair of files is
  a complete backup.

  `schema_path` gets TypeQL you can read; `data_path` gets the items in TypeDB's
  own binary format, which is the format its other drivers and its console
  write, so a dump is not tied to this driver. Both are truncated if they exist,
  and both are removed again if the export fails part-way — a half-written
  backup that looks like a backup is worse than none.

  Nothing is held in memory: items are written as they arrive.

      :ok = TypeDB.GRPC.Database.export_to_files(conn, "social", "social.tql", "social.data")

  ## Options

    * `:timeout` — how long to wait, defaulting to the connection's. An export
      of a large graph is not a request-sized operation; give it a real budget.
  """
  @spec export_to_files(Connection.t(), String.t(), Path.t(), Path.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def export_to_files(conn, name, schema_path, data_path, opts \\ [])
      when is_binary(name) and is_binary(schema_path) and is_binary(data_path) do
    if Path.expand(schema_path) == Path.expand(data_path) do
      {:error,
       Error.new(:config, "the schema and the data cannot be exported to the same file, #{schema_path}")}
    else
      do_export(conn, name, schema_path, data_path, opts)
    end
  end

  defp do_export(conn, name, schema_path, data_path, opts) do
    with {:ok, _} <-
           Connection.unary(
             conn,
             fn channel, md ->
               export_stream(channel, md, name, schema_path, data_path, timeout(conn, opts))
             end,
             "exporting database #{inspect(name)}",
             operation: :database_export,
             database: name
           ) do
      :ok
    end
  end

  defp export_stream(channel, md, name, schema_path, data_path, timeout) do
    request = %Proto.Database.Export.Req{req: %Proto.Migration.Export.Req{name: name}}

    # A server-streaming call hands back the replies itself; there is no second
    # `recv` step the way there is on the bidirectional streams this driver
    # opens elsewhere.
    with {:ok, replies} <-
           Proto.TypeDB.Stub.database_export(channel, request, metadata: md, timeout: timeout) do
      write_export(replies, schema_path, data_path)
    end
  end

  # Each file is opened inside the cleanup for the one before it, so a failure
  # at any point closes what is open and removes what was created. The `with`
  # this used to be short-circuited on the second open and left the first both
  # open and on disk — Audit VI, VI-2.
  defp write_export(replies, schema_path, data_path) do
    with {:ok, schema_file} <- open_write(schema_path) do
      discarding(schema_path, data_path, fn ->
        try do
          with {:ok, data_file} <- open_write(data_path) do
            try do
              drain_export(replies, schema_file, data_file)
            after
              _ = File.close(data_file)
            end
          end
        after
          _ = File.close(schema_file)
        end
      end)
    end
  end

  # Rust's driver removes both files when an export fails, and so does this:
  # what is on disk after a failed export is a prefix, and a prefix of a backup
  # restores into a database that is missing whatever came after it.
  #
  # A raise or an exit counts as a failure. The reply stream is a gRPC stream
  # consumed lazily, so an adapter fault arrives that way rather than as a
  # return value, and the version of this that only looked at `{:error, _}` left
  # a half-written file behind for exactly the case the files are dangerous in.
  defp discarding(schema_path, data_path, fun) do
    case fun.() do
      {:error, _} = error ->
        discard(schema_path, data_path)
        error

      result ->
        result
    end
  rescue
    exception ->
      discard(schema_path, data_path)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      discard(schema_path, data_path)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp discard(schema_path, data_path) do
    _ = File.rm(schema_path)
    _ = File.rm(data_path)
    :ok
  end

  defp drain_export(replies, schema_file, data_file) do
    Enum.reduce_while(replies, {:ok, :exported}, fn reply, acc ->
      case export_part(reply) do
        {:schema, schema} -> continue(write(schema_file, schema), acc)
        {:items, items} -> continue(write(data_file, Enum.map(items, &Migration.encode/1)), acc)
        :done -> {:halt, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A write that failed ends the export. It used to carry the error along and
  # keep going, which drained the whole of a large export from the server into a
  # file that was already broken before returning the failure — Audit VI, VI-3.
  defp continue(:ok, acc), do: {:cont, acc}
  defp continue({:error, _} = error, _acc), do: {:halt, error}

  defp export_part({:ok, %Proto.Database.Export.Server{server: %{server: {:initial_res, initial}}}}),
    do: {:schema, initial.schema}

  defp export_part({:ok, %Proto.Database.Export.Server{server: %{server: {:res_part, part}}}}),
    do: {:items, part.items}

  defp export_part({:ok, %Proto.Database.Export.Server{server: %{server: {:done, _}}}}), do: :done

  defp export_part({:error, %GRPC.RPCError{} = error}),
    do: {:error, GRPCError.from_rpc_error(error, "exporting a database")}

  defp export_part(other),
    do: {:error, Error.new(:decode, "unexpected export reply: #{inspect(other, limit: 5)}")}

  # `:file.write/2` rather than `IO.binwrite/2`: the latter is typed as never
  # failing, so a full disk part-way through an export would be discovered by
  # whoever tried to restore the backup.
  defp write(file, data) do
    case :file.write(file, data) do
      :ok -> :ok
      {:error, reason} -> {:error, file_error(reason, "writing the export")}
    end
  end

  @doc """
  Creates a database from the two files `export_to_files/5` wrote.

  The database must not already exist — the import creates it, defines the
  schema and then loads the items, and TypeDB refuses to import over something
  that is there. Items are read from disk and sent in batches as the stream
  drains them, so restoring a graph larger than memory is a restore rather than
  a problem.

  The data file is TypeDB's own format, so this restores a dump taken by any of
  its drivers, not only by this one.

      :ok = TypeDB.GRPC.Database.import_from_files(conn, "social_restored", "social.tql", "social.data")

  ## Options

    * `:timeout` — how long to wait for the server to finish, defaulting to the
      connection's. This covers the load, not one request, so it usually wants
      raising.
  """
  @spec import_from_files(Connection.t(), String.t(), Path.t(), Path.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def import_from_files(conn, name, schema_path, data_path, opts \\ [])
      when is_binary(name) and is_binary(schema_path) and is_binary(data_path) do
    with {:ok, schema} <- read_schema(schema_path),
         :ok <- readable(data_path),
         {:ok, _} <-
           Connection.unary(
             conn,
             fn channel, md -> import_stream(channel, md, name, schema, data_path, timeout(conn, opts)) end,
             "importing database #{inspect(name)}",
             operation: :database_import,
             database: name
           ) do
      :ok
    end
  end

  defp import_stream(channel, md, name, schema, data_path, timeout) do
    stream = Proto.TypeDB.Stub.databases_import(channel, metadata: md, timeout: timeout)

    with :ok <-
           send_import(
             stream,
             {:initial_req, %Proto.Migration.Import.Client.InitialReq{name: name, schema: schema}}
           ),
         :ok <- send_items(stream, data_path),
         :ok <- send_import(stream, {:done, %Proto.Migration.Import.Client.Done{}}, end_stream: true),
         {:ok, replies} <- GRPC.Stub.recv(stream, timeout: timeout) do
      await_import(replies)
    end
  end

  # 250 items per message, the batch size TypeDB's own drivers use. Sending them
  # one at a time would make the framing cost the dominant one; sending them all
  # at once would defeat the streaming.
  @import_batch 250

  defp send_items(stream, data_path) do
    data_path
    |> Migration.items()
    |> Stream.chunk_every(@import_batch)
    |> Enum.reduce_while(:ok, fn items, :ok ->
      case send_import(stream, {:req_part, %Proto.Migration.Import.Client.ReqPart{items: items}}) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  rescue
    # `Migration.items/1` raises on a file that is not an export; the caller
    # asked a question and gets an answer rather than a stack trace.
    error in [TypeDB.Error] -> {:error, error}
    error in [File.Error] -> {:error, file_error(error.reason, "reading #{data_path}")}
  end

  defp send_import(stream, client, opts \\ []) do
    message = %Proto.DatabaseManager.Import.Client{client: %Proto.Migration.Import.Client{client: client}}

    case GRPC.Stub.send_request(stream, message, opts) do
      %GRPC.Client.Stream{} -> :ok
      {:error, reason} -> {:error, GRPCError.from_reason(reason, "importing a database")}
    end
  end

  defp await_import(replies) do
    Enum.reduce_while(replies, {:error, Error.new(:transport, "the import stream ended without a reply")}, fn
      {:ok, %Proto.DatabaseManager.Import.Server{}}, _acc ->
        {:halt, {:ok, :imported}}

      {:error, %GRPC.RPCError{} = error}, _acc ->
        {:halt, {:error, GRPCError.from_rpc_error(error, "importing a database")}}

      other, _acc ->
        {:halt, {:error, Error.new(:decode, "unexpected import reply: #{inspect(other, limit: 5)}")}}
    end)
  end

  defp read_schema(path) do
    case File.read(path) do
      {:ok, schema} -> {:ok, schema}
      {:error, reason} -> {:error, file_error(reason, "reading the schema from #{path}")}
    end
  end

  defp readable(path) do
    if File.regular?(path), do: :ok, else: {:error, file_error(:enoent, "reading the data from #{path}")}
  end

  defp open_write(path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> {:error, file_error(reason, "opening #{path}")}
    end
  end

  # A path the caller got wrong is a caller mistake, which is what `:config`
  # names in this driver's error vocabulary. The posix reason travels along, so
  # `:enoent` and `:eacces` stay tellable apart.
  defp file_error(reason, context) do
    Error.new(:config, "#{context}: #{:file.format_error(reason)}", reason: reason)
  end

  defp timeout(conn, opts), do: Keyword.get(opts, :timeout, Connection.config(conn).timeout)

  # -- `!` twins ---------------------------------------------------------------
  #
  # The convention `CLAUDE.md` states and the sibling enforces mechanically:
  # every failing operation has a twin that raises. Generated through macros
  # rather than a shared function so each keeps its own success typing — see
  # `TypeDB.GRPC.Bang`.

  @doc "Every database on the server, raising on failure."
  @spec list!(term(), term()) :: [String.t()]
  def list!(conn, opts \\ []), do: unwrap!(list(conn, opts))

  @doc "A database's name, raising when it does not exist."
  @spec get!(term(), term(), term()) :: String.t()
  def get!(conn, name, opts \\ []), do: unwrap!(get(conn, name, opts))

  @doc "Creates a database, raising on failure."
  @spec create!(term(), term(), term()) :: :ok
  def create!(conn, name, opts \\ []), do: ok!(create(conn, name, opts))

  @doc "Creates a database unless it is there, raising on failure."
  @spec create_if_not_exists!(term(), term(), term()) :: :ok
  def create_if_not_exists!(conn, name, opts \\ []), do: ok!(create_if_not_exists(conn, name, opts))

  @doc "Deletes a database, raising on failure."
  @spec delete!(term(), term(), term()) :: :ok
  def delete!(conn, name, opts \\ []), do: ok!(delete(conn, name, opts))

  @doc "The database's schema, raising on failure."
  @spec schema!(term(), term(), term()) :: String.t()
  def schema!(conn, name, opts \\ []), do: unwrap!(schema(conn, name, opts))

  @doc "The type schema, raising on failure."
  @spec type_schema!(term(), term(), term()) :: String.t()
  def type_schema!(conn, name, opts \\ []), do: unwrap!(type_schema(conn, name, opts))

  @doc "Exports a database to two files, raising on failure."
  @spec export_to_files!(term(), term(), term(), term(), term()) :: :ok
  def export_to_files!(conn, name, schema_path, data_path, opts \\ []),
    do: ok!(export_to_files(conn, name, schema_path, data_path, opts))

  @doc "Imports a database from two files, raising on failure."
  @spec import_from_files!(term(), term(), term(), term(), term()) :: :ok
  def import_from_files!(conn, name, schema_path, data_path, opts \\ []),
    do: ok!(import_from_files(conn, name, schema_path, data_path, opts))
end
