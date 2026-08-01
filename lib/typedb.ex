defmodule TypeDB do
  @moduledoc """
  A driver for TypeDB 3.12 and newer, built on the TypeDB HTTP API.

  Older 3.x is not supported; see the README for what breaks and why.

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
  Every function takes the connection's registered name as its first argument;
  `conn` below is that name, `TypeDB` unless you chose another.

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

  Every function in this module and in `TypeDB.Database`, `TypeDB.User`,
  `TypeDB.Server` and `TypeDB.Transaction` that can fail has both a
  `{:ok, _} | {:error, %TypeDB.Error{}}` form and a `!` form that raises.
  `TypeDB.Error` carries TypeDB's own error `:code`, which is what you want to
  branch on.

  The one exception is `transaction/5`: it returns whatever your block returned,
  so its `{:error, _}` may be your own value rather than an exception, and a
  bang form would have to guess whether to raise it.

  ## How long a call can take

  Four options interact, and only the last of them bounds the call rather than
  one attempt. With the defaults:

  | | default | what it bounds |
  | --- | --- | --- |
  | `:connect_timeout` | `10_000` | opening the socket |
  | `:timeout` | `60_000` | waiting for one response |
  | `:max_retries` | `1` | how many extra attempts |
  | `:retry_max_delay` | `5_000` | one wait between attempts |
  | `:deadline` | `:infinity` | **the whole call** |

  So a retryable call costs at worst

      (max_retries + 1) * (connect_timeout + timeout) + max_retries * retry_max_delay

  which is a little over two minutes by default, plus one more
  `connect_timeout + timeout` if the call has to mint a token first. Raising
  `:max_retries` multiplies the first term — that is the arithmetic `:deadline`
  exists for, since setting it makes the whole expression irrelevant: no call
  outlives its budget, each attempt is given only what the budget has left, and
  a retry that could not finish inside it is not started.

  Retries and their backoffs happen in the calling process. Nothing is queued
  behind a connection, but nothing is running in the caller either.

  ## Logging

  The driver logs sparingly, and nothing at all on the happy path — use
  `TypeDB.Telemetry` for that. This is everything it can say:

  | level | when |
  | --- | --- |
  | `debug` | a request is about to be retried |
  | `debug` | a connection process received a message it does not understand |
  | `warning` | retries were exhausted and the call is giving up |
  | `warning` | a token renewal failed |
  | `error` | a connection's transport died and the connection is stopping |

  `TypeDB.HTTP.Httpc` additionally warns once at start-up when it can find no
  OS trust store, carrying `:typedb_adapter` rather than `:typedb_connection`:
  it happens while the adapter is being built, before there is a connection to
  name or a `:log_level` to consult.

  Set `:log_level` on the connection to raise the floor, or `:none` to silence
  it — see `TypeDB.Config`. It applies per connection, so one noisy connection
  can be quietened without filtering the whole application's Logger by module.

  Every line carries `:typedb_connection` in its Logger metadata, and the
  retry and give-up lines additionally carry `:typedb_method`, `:typedb_path`,
  `:typedb_attempt` and `:typedb_error_kind`. Configure your backend to keep
  them:

      config :logger, :default_formatter,
        metadata: [:typedb_connection, :typedb_error_kind]

  Credentials never appear in a log line or in metadata; see `TypeDB.Config`
  for how the connection keeps them out of crash reports too.

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

  What that costs you in practice, and the four other things worth knowing
  before they surprise you in production, are in the
  [Limitations](readme.html#limitations) section of the README: answers arrive
  whole, a connection points at one server, retries block the caller, and one
  connection means one HTTP pool.
  """

  alias TypeDB.{Answer, Connection, Database, Error, Given, Options, Server, Telemetry, Transaction, Wire}

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
      `:schema`, the only type that accepts every kind of query.

      **A `:schema` transaction takes TypeDB's exclusive, database-wide schema
      lock for the duration of the call.** One-shot queries left on the default
      therefore serialise against each other, and against anything else holding
      that lock. Pass `transaction_type: :read` for reads and `:write` for data
      changes — both are concurrent — and leave the default to `define` and
      `undefine`. Narrowing also has the server reject an accidental write.
    * `:commit` — whether to commit a write or schema query. Defaults to `true`.
      Read queries never commit.
    * `:given_rows` — input rows for the query's `given` stage; see
      `TypeDB.Transaction.query/3` for how to parameterise a query safely.
    * plus all query and transaction options from `TypeDB.Options`, and
      `:timeout` and `:deadline` — the first bounds one attempt, the second the
      whole call including retries. See `TypeDB.Config`.

  ## Raises

  Unlike the rest of this module, `query/4` has two failure paths. Anything the
  *server* rejects comes back as `{:error, %TypeDB.Error{}}`; anything rejected
  before the request is built raises, because there is no request to fail:

    * `ArgumentError` for an invalid `:transaction_type` — that is a literal in
      your source, not data.
    * `TypeDB.Error` with kind `:encode` for a `:given_rows` value the driver
      cannot turn into a TypeDB wire value, including a negative
      `TypeDB.Duration`.

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
      |> Wire.put_unless_nil("commit", Keyword.get(opts, :commit))
      |> Wire.put_unless_nil("queryOptions", Options.query_payload(opts, query_defaults(conn)))
      |> Wire.put_unless_nil("transactionOptions", Options.transaction_payload(opts))
      |> Wire.put_unless_nil("givenRows", Given.encode_rows(Keyword.get(opts, :given_rows)))

    with {:ok, payload} <-
           Connection.request(conn, :post, "/query",
             body: body,
             # A read runs in a transaction the server opens and closes for it,
             # so a re-send after a dropped packet changes nothing.
             idempotent: transaction_type == :read,
             metadata: %{database: database, transaction_type: transaction_type},
             timeout: opts[:timeout],
             deadline: opts[:deadline]
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

  Transaction options from `TypeDB.Options`, plus `:timeout` and `:deadline`,
  which are forwarded to the request that opens the transaction.

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
    metadata = %{connection: conn, database: database, type: type}

    # The one span that covers more than a single request: open, the block's
    # queries, and the commit or rollback that ends it. Nothing else can measure
    # how long a unit of work held a transaction open.
    Telemetry.span_transaction(metadata, fn ->
      case Transaction.open(conn, database, type, opts) do
        {:ok, tx} -> run_transaction(tx, fun, metadata)
        {:error, error} -> {{:error, error}, Map.put(metadata, :error, error)}
      end
    end)
  end

  defp run_transaction(tx, fun, metadata) do
    result = fun.(tx)

    case result do
      {:error, _reason} ->
        {result, Map.put(metadata, :outcome, abandon(tx))}

      _ ->
        finish(tx, result, metadata)
    end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      _ = abandon(tx)
      :erlang.raise(kind, reason, stacktrace)
  end

  # A read transaction has nothing to roll back, and TypeDB says so — `400 TSV3`,
  # "Read transactions cannot be rolled back, since they cannot modify data".
  # Sending it anyway spends a round trip to be told off.
  defp abandon(%Transaction{type: :read} = tx) do
    _ = Transaction.close(tx)
    :close
  end

  defp abandon(tx) do
    _ = Transaction.rollback(tx)
    _ = Transaction.close(tx)
    :rollback
  end

  defp finish(%Transaction{type: :read} = tx, result, metadata) do
    _ = Transaction.close(tx)
    {result, Map.put(metadata, :outcome, :close)}
  end

  defp finish(tx, result, metadata) do
    case commit_outcome(tx) do
      {:ok, outcome} -> {result, Map.put(metadata, :outcome, outcome)}
      {:error, error} -> {{:error, error}, Map.merge(metadata, %{outcome: :commit_failed, error: error})}
    end
  end

  defp commit_outcome(tx) do
    case Transaction.commit(tx) do
      :ok ->
        {:ok, :commit}

      # A commit the server rejected has already finished the transaction. A
      # commit that never reached the server has not: without this the
      # transaction stays open until TypeDB's own timeout expires, holding its
      # schema lock for as long as that takes.
      {:error, %Error{kind: kind} = error} when kind in [:transport, :timeout] ->
        _ = Transaction.close(tx)
        {:error, error}

      {:error, error} ->
        {:error, error}
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
  Returns `:ok` when the server is reachable, raising otherwise.
  See `TypeDB.Server.health!/1`.
  """
  @spec health!(conn()) :: :ok
  defdelegate health!(conn), to: Server

  @doc """
  Returns the server distribution and version. See `TypeDB.Server.version/1`.
  """
  @spec version(conn()) :: {:ok, Server.version()} | {:error, Error.t()}
  defdelegate version(conn), to: Server

  @doc """
  Returns the server distribution and version, raising on failure.
  See `TypeDB.Server.version!/1`.
  """
  @spec version!(conn()) :: Server.version()
  defdelegate version!(conn), to: Server

  @doc """
  Lists databases. See `TypeDB.Database.list/1`.
  """
  @spec databases(conn()) :: {:ok, [String.t()]} | {:error, Error.t()}
  defdelegate databases(conn), to: Database, as: :list

  @doc """
  Lists databases, raising on failure. See `TypeDB.Database.list!/1`.
  """
  @spec databases!(conn()) :: [String.t()]
  defdelegate databases!(conn), to: Database, as: :list!

  @doc """
  Creates a database. See `TypeDB.Database.create/2`.
  """
  @spec create_database(conn(), String.t()) :: :ok | {:error, Error.t()}
  defdelegate create_database(conn, name), to: Database, as: :create

  @doc """
  Creates a database, raising on failure. See `TypeDB.Database.create!/2`.
  """
  @spec create_database!(conn(), String.t()) :: :ok
  defdelegate create_database!(conn, name), to: Database, as: :create!

  @doc """
  Deletes a database and all of its data. See `TypeDB.Database.delete/2`.
  """
  @spec delete_database(conn(), String.t()) :: :ok | {:error, Error.t()}
  defdelegate delete_database(conn, name), to: Database, as: :delete

  @doc """
  Deletes a database, raising on failure. See `TypeDB.Database.delete!/2`.
  """
  @spec delete_database!(conn(), String.t()) :: :ok
  defdelegate delete_database!(conn, name), to: Database, as: :delete!

  @doc false
  @spec query_defaults(conn()) :: keyword()
  def query_defaults(conn) do
    case Connection.config(conn).answer_count_limit do
      nil -> []
      limit -> [answer_count_limit: limit]
    end
  end
end
