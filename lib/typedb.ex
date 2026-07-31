defmodule TypeDB do
  @moduledoc """
  A TypeDB 3.x driver for Elixir, built on the TypeDB HTTP API.

  ## Getting started

  Add the connection to your supervision tree:

      children = [
        {TypeDB,
         url: "http://localhost:8000",
         username: "admin",
         password: System.fetch_env!("TYPEDB_PASSWORD")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then query. `TypeDB` is the default connection name:

      TypeDB.query!(TypeDB, "social", \"""
        match
          $p isa person, has name $name;
        select $name;
      \""")
      |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "name"))
      #=> ["Alice", "Bob"]

  ## The two ways to run a query

  `query/4` runs a single query in its own transaction — TypeDB opens it, runs
  the query, and commits or closes it in one round trip. Reads never commit;
  writes and schema changes commit by default, which `commit: false` turns off.

      TypeDB.query(conn, "social", "insert $p isa person, has name 'Alice';")

  `transaction/5` opens a transaction you can run several queries in, committing
  once at the end:

      TypeDB.transaction(conn, "social", :write, fn tx ->
        TypeDB.Transaction.query!(tx, "insert $p isa person, has name 'Alice';")
        TypeDB.Transaction.query!(tx, "insert $p isa person, has name 'Bob';")
      end)

  The block commits on success and rolls back on error or exception. A `:read`
  block never commits.

  ## Answers

  Every query returns a `TypeDB.Answer` — see that module for the three shapes
  and how to consume them.

  ## Errors

  Every function has a `{:ok, _} | {:error, %TypeDB.Error{}}` form and a `!` form
  that raises. `TypeDB.Error` carries TypeDB's own error `:code`, which is what
  you want to branch on.

  ## Concurrency

  Requests run in the calling process, so N processes issue N concurrent
  requests; the connection process is consulted only to mint or renew the auth
  token. Sockets are pooled by the HTTP adapter — `:max_sessions` on
  `TypeDB.HTTP.Httpc` caps how many are opened per host.

  ## What this driver covers

  Everything in the TypeDB HTTP API v1: sign-in and token renewal, databases,
  users, servers, version and health, explicit transactions, one-shot queries,
  and query analysis. TypeDB's gRPC-only features — database import/export and
  streaming answers — are not available over HTTP and so are not here.
  """

  alias TypeDB.{Answer, Connection, Database, Error, Given, Options, Server, Transaction}

  @typedoc "A connection: the registered name of a `TypeDB.Connection` process."
  @type conn :: Connection.t()

  @doc """
  Starts a connection. See `TypeDB.Config` for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: Connection

  @doc false
  defdelegate child_spec(opts), to: Connection

  @doc """
  Stops a connection, by registered name or pid.
  """
  @spec stop(conn() | pid(), term(), timeout()) :: :ok
  defdelegate stop(conn, reason \\ :normal, timeout \\ :infinity), to: Connection

  # ----------------------------------------------------------------------------
  # Queries
  # ----------------------------------------------------------------------------

  @doc """
  Runs a single query in a transaction of its own.

  TypeDB opens the transaction, runs the query, then commits or closes it —
  one HTTP round trip in total, which makes this the cheapest way to run a
  standalone query.

  ## Options

    * `:transaction_type` — `:read`, `:write` or `:schema`. Defaults to
      `:schema`, which accepts every kind of query. Narrow it to `:read` to have
      the server reject an accidental write.
    * `:commit` — whether to commit a write or schema query. Defaults to `true`.
      Read queries never commit.
    * `:given_rows` — input rows for the query's `given` stage; see
      `TypeDB.Transaction.query/3` for how to parameterise a query safely.
    * plus all query and transaction options from `TypeDB.Options`, and
      `:timeout`.

  ## Examples

      TypeDB.query(conn, "social", "match $p isa person; select $p;",
        transaction_type: :read,
        answer_count_limit: 100
      )

      # Dry run: execute the write, then throw it away.
      TypeDB.query(conn, "social", "insert $p isa person;", commit: false)

      # Parameterised, and therefore safe against TypeQL injection.
      TypeDB.query(conn, "social", \"""
        given $n: string;
        insert $p isa person, has name == $n;
      \""", given_rows: [%{"n" => user_supplied_name}])
  """
  @spec query(conn(), String.t(), String.t(), keyword()) :: {:ok, Answer.t()} | {:error, Error.t()}
  def query(conn, database, query, opts \\ []) when is_binary(database) and is_binary(query) do
    transaction_type = Keyword.get(opts, :transaction_type, :schema)

    unless transaction_type in [:read, :write, :schema] do
      raise ArgumentError,
            "invalid :transaction_type #{inspect(transaction_type)}, expected :read, :write or :schema"
    end

    body =
      %{
        "query" => query,
        "databaseName" => database,
        "transactionType" => Atom.to_string(transaction_type)
      }
      |> put_unless_nil("commit", Keyword.get(opts, :commit))
      |> put_unless_nil("queryOptions", Options.query_payload(opts))
      |> put_unless_nil("transactionOptions", Options.transaction_payload(opts))
      |> put_unless_nil("givenRows", Given.encode_rows(Keyword.get(opts, :given_rows)))

    with {:ok, payload} <-
           Connection.request(conn, :post, "/query",
             body: body,
             idempotent: false,
             timeout: opts[:timeout]
           ) do
      Answer.decode(payload)
    end
  end

  @doc """
  Runs a single query, raising `TypeDB.Error` on failure.
  """
  @spec query!(conn(), String.t(), String.t(), keyword()) :: Answer.t()
  def query!(conn, database, query, opts \\ []) do
    case query(conn, database, query, opts) do
      {:ok, answer} -> answer
      {:error, error} -> raise error
    end
  end

  @doc """
  Runs `fun` inside a transaction, committing on success.

  The transaction is committed when `fun` returns, rolled back when it returns
  `{:error, _}`, and rolled back before the exception propagates when it raises,
  throws or exits. `:read` transactions are closed rather than committed, since
  there is nothing to commit.

  Returns whatever `fun` returned, except that a successful `:write`/`:schema`
  block whose commit fails returns `{:error, %TypeDB.Error{}}`.

  ## Options

  Transaction options from `TypeDB.Options`, plus `:timeout`.

  ## Examples

      TypeDB.transaction(conn, "social", :write, fn tx ->
        TypeDB.Transaction.query!(tx, "insert $p isa person, has name 'Alice';")
        TypeDB.Transaction.query!(tx, "insert $p isa person, has name 'Bob';")
        :ok
      end)
      #=> :ok

      # Returning {:error, _} rolls back and returns that error unchanged.
      TypeDB.transaction(conn, "social", :write, fn tx ->
        case TypeDB.Transaction.query(tx, "insert $p isa person;") do
          {:ok, _} -> {:error, :changed_my_mind}
          error -> error
        end
      end)
      #=> {:error, :changed_my_mind}
  """
  @spec transaction(conn(), String.t(), Transaction.type(), (Transaction.t() -> result), keyword()) ::
          result | {:error, Error.t()}
        when result: term()
  def transaction(conn, database, type, fun, opts \\ []) when is_function(fun, 1) do
    case Transaction.open(conn, database, type, opts) do
      {:ok, tx} -> run_transaction(tx, fun)
      {:error, error} -> {:error, error}
    end
  end

  defp run_transaction(tx, fun) do
    result = fun.(tx)

    case result do
      {:error, _reason} ->
        _ = Transaction.rollback(tx)
        _ = Transaction.close(tx)
        result

      _ ->
        finish(tx, result)
    end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      _ = Transaction.rollback(tx)
      _ = Transaction.close(tx)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp finish(%Transaction{type: :read} = tx, result) do
    _ = Transaction.close(tx)
    result
  end

  defp finish(tx, result) do
    case Transaction.commit(tx) do
      :ok -> result
      {:error, error} -> {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Convenience delegates
  # ----------------------------------------------------------------------------

  @doc """
  Returns `:ok` when the server is reachable. See `TypeDB.Server.health/1`.
  """
  @spec health(conn()) :: :ok | {:error, Error.t()}
  defdelegate health(conn), to: Server

  @doc """
  Returns the server distribution and version. See `TypeDB.Server.version/1`.
  """
  @spec version(conn()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate version(conn), to: Server

  @doc """
  Lists databases. See `TypeDB.Database.list/1`.
  """
  @spec databases(conn()) :: {:ok, [String.t()]} | {:error, Error.t()}
  defdelegate databases(conn), to: Database, as: :list

  @doc """
  Creates a database. See `TypeDB.Database.create/2`.
  """
  @spec create_database(conn(), String.t()) :: :ok | {:error, Error.t()}
  defdelegate create_database(conn, name), to: Database, as: :create

  @doc """
  Deletes a database and all of its data. See `TypeDB.Database.delete/2`.
  """
  @spec delete_database(conn(), String.t()) :: :ok | {:error, Error.t()}
  defdelegate delete_database(conn, name), to: Database, as: :delete

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
