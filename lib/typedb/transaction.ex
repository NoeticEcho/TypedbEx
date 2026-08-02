defmodule TypeDB.Transaction do
  @moduledoc """
  Explicit transactions.

  A transaction is a lightweight handle: an id plus the connection it belongs to.
  It is a plain struct, not a process, so it can be passed between processes
  freely — TypeDB tracks the transaction server-side.

  ## Bracketed usage (preferred)

  `TypeDB.transaction/5` commits on success and rolls back on error or exception,
  which is what you want almost always:

      TypeDB.transaction(conn, "social", :write, fn tx ->
        {:ok, _} = TypeDB.Transaction.query(tx, "insert $p isa person, has name 'Alice';")
        {:ok, _} = TypeDB.Transaction.query(tx, "insert $p isa person, has name 'Bob';")
      end)

  ## Manual usage

  When the commit point is not lexically scoped:

      {:ok, tx} = TypeDB.Transaction.open(conn, "social", :write)
      {:ok, _answer} = TypeDB.Transaction.query(tx, "insert $p isa person;")
      :ok = TypeDB.Transaction.commit(tx)

  Always pair `open/4` with `commit/1`, `rollback/1` or `close/1`. An abandoned
  transaction holds server-side resources until its
  `transaction_timeout_millis` elapses — and a `:schema` transaction holds the
  exclusive schema lock for that whole time, blocking every other schema change.

  ## Transaction types

    * `:read` — read-only, no commit needed. Multiple readers run concurrently.
    * `:write` — data changes. Concurrent writers are allowed; conflicting
      commits fail at commit time.
    * `:schema` — schema changes. Takes an exclusive, database-wide lock.

  A query is rejected if it needs more than the transaction grants: a `define`
  requires `:schema`, an `insert` requires `:write` or `:schema`.
  """

  use TypeDB.Bang

  alias TypeDB.{Answer, CallOptions, Connection, Error, Given, Options, Wire}

  @type type :: :read | :write | :schema

  @type t :: %__MODULE__{
          conn: Connection.t(),
          id: String.t(),
          database: String.t(),
          type: type()
        }

  @enforce_keys [:conn, :id, :database, :type]
  defstruct [:conn, :id, :database, :type]

  # The transaction's own path carries its id, but not the database it belongs
  # to or what kind it is — both of which are what you want to group metrics by.
  defp tx_metadata(%__MODULE__{} = tx), do: %{database: tx.database, transaction_type: tx.type}

  @doc """
  Opens a transaction on `database`.

  ## Options

  Transaction options (see `TypeDB.Options`) plus `:timeout` and `:deadline` for
  the HTTP request itself. Any other key raises `ArgumentError`.

      TypeDB.Transaction.open(conn, "social", :schema,
        schema_lock_acquire_timeout_millis: 30_000
      )
  """
  @spec open(Connection.t(), String.t(), type(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(conn, database, type, opts \\ [])

  # An `ArgumentError` naming the value, rather than the `FunctionClauseError`
  # the guard alone produced: the type is a literal in the caller's source, so
  # the failure should say which literal is wrong. Same treatment as
  # `TypeDB.query/4`'s `:transaction_type`.
  def open(_conn, database, type, _opts) when is_binary(database) and type not in [:read, :write, :schema] do
    raise ArgumentError,
          "invalid transaction type #{inspect(type)}, expected :read, :write or :schema"
  end

  def open(conn, database, type, opts)
      when is_binary(database) and type in [:read, :write, :schema] do
    CallOptions.validate!(opts, CallOptions.open(), "TypeDB.Transaction.open/4")

    body =
      %{"databaseName" => database, "transactionType" => Atom.to_string(type)}
      |> Wire.put_unless_nil("transactionOptions", Options.transaction_payload(opts))

    case Connection.request(conn, :post, "/transactions/open",
           body: body,
           # A retried open can leave an orphan if the first one succeeded and
           # the answer was lost. For :read that costs a pinned snapshot until
           # TypeDB's own transaction timeout; for :write and :schema it costs
           # the locks, so those stay one-shot.
           idempotent: type == :read,
           metadata: %{database: database, transaction_type: type},
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, %{"transactionId" => id}} when is_binary(id) ->
        {:ok, %__MODULE__{conn: conn, id: id, database: database, type: type}}

      {:ok, other} ->
        {:error, Error.new(:decode, "transaction open response had no transactionId", body: other)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Opens a transaction, raising on failure.
  """
  @spec open!(Connection.t(), String.t(), type(), keyword()) :: t()
  def open!(conn, database, type, opts \\ []) do
    unwrap!(open(conn, database, type, opts))
  end

  @doc """
  Runs a TypeQL query inside the transaction.

  Nothing is persisted until `commit/1`.

  ## Options

  Query options (see `TypeDB.Options`) plus:

    * `:timeout` — overrides the connection timeout for this request. Long
      analytical reads usually want this. It bounds one attempt; `:deadline`
      bounds the call.
    * `:deadline` — overrides the connection's `:deadline`: a wall-clock budget
      in ms for this call including any retries.
    * `:given_rows` — input rows for the query's `given` stage. See
      "Parameterised queries" below.

  ## Examples

      TypeDB.Transaction.query(tx, "match $p isa person; select $p;",
        include_instance_types: false,
        answer_count_limit: 1_000
      )

  ## Parameterised queries

  Never interpolate user input into a query string — TypeQL injection is as real
  as SQL injection. Use TypeDB's `given` stage (3.12+) instead: the values travel
  beside the query rather than inside it, so they can never be parsed as TypeQL.

      TypeDB.Transaction.query(tx, \"""
        given $n: string;
        insert $p isa person, has name == $n;
      \""", given_rows: [%{"n" => "Alice"}, %{"n" => "Bob"}])

  The rest of the pipeline runs once per row, which also makes this the fast way
  to write many rows: one request and one query compilation instead of N.

  Declare every input variable in the `given` stage, and mark optional columns
  with `?`:

      given $name: string, $age: integer?;

  A query with a `given` stage requires rows, and rows require a `given` stage.
  Each row is a map of variable name to a plain Elixir term or a concept from an
  earlier answer; `nil` leaves an optional column unbound. `TypeDB.Given` lists
  the accepted types and explains why the driver encodes them rather than
  forwarding raw JSON.

  ## Raises

  A `:given_rows` value the driver cannot encode raises `TypeDB.Error` with kind
  `:encode`. That happens while the request is being built, so there is no
  request to return an error for. An option this function does not accept raises
  `ArgumentError`, for the same reason and one step earlier. Everything the
  *server* rejects comes back as `{:error, %TypeDB.Error{}}` as usual.
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, Answer.t()} | {:error, Error.t()}
  def query(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    CallOptions.validate!(opts, CallOptions.transaction_query(), "TypeDB.Transaction.query/3")

    body =
      %{"query" => query}
      |> Wire.put_unless_nil("queryOptions", Options.query_payload(opts, TypeDB.query_defaults(tx.conn)))
      |> Wire.put_unless_nil("givenRows", Given.encode_rows(Keyword.get(opts, :given_rows)))

    with {:ok, payload} <-
           Connection.request(tx.conn, :post, "/transactions/#{tx.id}/query",
             body: body,
             # A read query changes nothing, so re-sending it after a dropped
             # packet is free. In a write or schema transaction it is not.
             idempotent: tx.type == :read,
             metadata: tx_metadata(tx),
             timeout: opts[:timeout],
             deadline: opts[:deadline]
           ) do
      payload |> Answer.decode() |> TypeDB.Log.answer_warning(tx.conn)
    end
  end

  @doc """
  Runs a query, raising on failure.
  """
  @spec query!(t(), String.t(), keyword()) :: Answer.t()
  def query!(%__MODULE__{} = tx, query, opts \\ []), do: unwrap!(query(tx, query, opts))

  @doc """
  Asks TypeDB to analyse a query without running it.

  Returns the decoded pipeline structure: the query's stages, variables, and
  inferred types. Useful for query tooling and for checking that a query
  type-checks against the current schema before shipping it.

  > #### Not covered by this driver's versioning {: .warning}
  >
  > The map is TypeDB's, passed through verbatim with string keys, and it is
  > the one return value in this driver that SemVer does not cover. It is a
  > diagnostic surface: the endpoint is not in TypeDB's published HTTP API
  > reference, and its shape tracks the server rather than this package, so a
  > TypeDB upgrade can change it inside a patch release of the driver.
  >
  > Modelling it as a struct would be a promise the driver cannot keep — every
  > server change would either break the struct or be silently dropped by it.
  > Match defensively, and do not build anything load-bearing on the shape.
  """
  @spec analyze(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def analyze(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Transaction.analyze/3")

    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/analyze",
           body: %{"query" => query},
           # Analysis does not execute the query.
           idempotent: true,
           metadata: tx_metadata(tx),
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, structure} when is_map(structure) ->
        {:ok, structure}

      # A 200 with an empty body decodes to `:ok`, which is not a map and not
      # what this function's spec promises. Every other JSON endpoint pattern-
      # matches the shape it expects; this one passed anything through, and
      # returned `{:ok, :ok}` to a caller told to expect a map.
      {:ok, other} ->
        {:error,
         Error.new(:decode, "the analyze endpoint returned #{inspect(other)}, not a structure", body: other)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Analyses a query, raising on failure.
  """
  @spec analyze!(t(), String.t(), keyword()) :: map()
  def analyze!(%__MODULE__{} = tx, query, opts \\ []), do: unwrap!(analyze(tx, query, opts))

  @doc """
  Commits the transaction.

  The transaction is finished afterwards, whether or not the commit succeeded —
  a failed commit does not leave anything to roll back.

  Committing a `:read` transaction is an error; use `close/1`.

  ## Options

    * `:timeout` — overrides the connection's `:timeout` for this call. A commit
      is usually the most expensive request a transaction makes, since it is
      where the server does the work, so it is the one most likely to want more
      time than an ordinary query.
    * `:deadline` — overrides the connection's `:deadline`: a wall-clock budget
      in ms for this call including any retries.
  """
  @spec commit(t(), keyword()) :: :ok | {:error, Error.t()}
  def commit(%__MODULE__{} = tx, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Transaction.commit/2")

    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/commit",
           idempotent: false,
           metadata: tx_metadata(tx),
           expect: :empty,
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Commits the transaction, raising on failure.
  """
  @spec commit!(t(), keyword()) :: :ok
  def commit!(%__MODULE__{} = tx, opts \\ []), do: ok!(commit(tx, opts))

  @doc """
  Discards everything written so far, leaving the transaction open.

  The transaction returns to the state it had when opened, so you can retry
  inside the same transaction rather than reopening one.

  Takes the same `:timeout` and `:deadline` options as `commit/2`.
  """
  @spec rollback(t(), keyword()) :: :ok | {:error, Error.t()}
  def rollback(%__MODULE__{} = tx, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Transaction.rollback/2")

    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/rollback",
           # Rolling back twice reaches the same state as rolling back once.
           idempotent: true,
           metadata: tx_metadata(tx),
           expect: :empty,
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Discards everything written so far, raising on failure.
  """
  @spec rollback!(t(), keyword()) :: :ok
  def rollback!(%__MODULE__{} = tx, opts \\ []), do: ok!(rollback(tx, opts))

  @doc """
  Closes the transaction, discarding uncommitted writes.

  Closing is idempotent and never fails on an already-closed transaction — it is
  safe to call in an `after` block.

  Takes the same `:timeout` and `:deadline` options as `commit/2`.
  """
  @spec close(t(), keyword()) :: :ok | {:error, Error.t()}
  def close(%__MODULE__{} = tx, opts \\ []) do
    CallOptions.validate!(opts, CallOptions.request(), "TypeDB.Transaction.close/2")

    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/close",
           # Idempotent by design, and a 404 from a second close is treated as
           # success below.
           idempotent: true,
           metadata: tx_metadata(tx),
           expect: :empty,
           timeout: opts[:timeout],
           deadline: opts[:deadline]
         ) do
      {:ok, _} -> :ok
      # The server treats closing an unknown transaction as a no-op; a 404 here
      # means someone else already closed it, which is the state we wanted.
      {:error, %Error{status: 404}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Closes the transaction, raising on failure.
  """
  @spec close!(t(), keyword()) :: :ok
  def close!(%__MODULE__{} = tx, opts \\ []), do: ok!(close(tx, opts))
end
