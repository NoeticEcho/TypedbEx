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

  alias TypeDB.{Answer, Connection, Error, Given, Options}

  @type type :: :read | :write | :schema

  @type t :: %__MODULE__{
          conn: Connection.t(),
          id: String.t(),
          database: String.t(),
          type: type()
        }

  @enforce_keys [:conn, :id, :database, :type]
  defstruct [:conn, :id, :database, :type]

  @doc """
  Opens a transaction on `database`.

  ## Options

  Transaction options (see `TypeDB.Options`) plus `:timeout` for the HTTP request
  itself.

      TypeDB.Transaction.open(conn, "social", :schema,
        schema_lock_acquire_timeout_millis: 30_000
      )
  """
  @spec open(Connection.t(), String.t(), type(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(conn, database, type, opts \\ [])
      when is_binary(database) and type in [:read, :write, :schema] do
    body =
      %{"databaseName" => database, "transactionType" => Atom.to_string(type)}
      |> put_unless_nil("transactionOptions", Options.transaction_payload(opts))

    case Connection.request(conn, :post, "/transactions/open",
           body: body,
           idempotent: false,
           timeout: opts[:timeout]
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
      analytical reads usually want this.
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
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, Answer.t()} | {:error, Error.t()}
  def query(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    body =
      %{"query" => query}
      |> put_unless_nil("queryOptions", Options.query_payload(opts))
      |> put_unless_nil("givenRows", Given.encode_rows(Keyword.get(opts, :given_rows)))

    with {:ok, payload} <-
           Connection.request(tx.conn, :post, "/transactions/#{tx.id}/query",
             body: body,
             idempotent: false,
             timeout: opts[:timeout]
           ) do
      Answer.decode(payload)
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
  inferred types. The shape is defined by TypeDB and is passed through
  unchanged, because it is a diagnostic surface rather than a stable API.

  Useful for query tooling and for checking that a query type-checks against the
  current schema before shipping it.
  """
  @spec analyze(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def analyze(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    Connection.request(tx.conn, :post, "/transactions/#{tx.id}/analyze",
      body: %{"query" => query},
      idempotent: false,
      timeout: opts[:timeout]
    )
  end

  @doc """
  Commits the transaction.

  The transaction is finished afterwards, whether or not the commit succeeded —
  a failed commit does not leave anything to roll back.

  Committing a `:read` transaction is an error; use `close/1`.
  """
  @spec commit(t()) :: :ok | {:error, Error.t()}
  def commit(%__MODULE__{} = tx) do
    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/commit",
           idempotent: false,
           expect: :empty
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Commits the transaction, raising on failure.
  """
  @spec commit!(t()) :: :ok
  def commit!(%__MODULE__{} = tx) do
    case commit(tx) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Discards everything written so far, leaving the transaction open.

  The transaction returns to the state it had when opened, so you can retry
  inside the same transaction rather than reopening one.
  """
  @spec rollback(t()) :: :ok | {:error, Error.t()}
  def rollback(%__MODULE__{} = tx) do
    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/rollback",
           idempotent: false,
           expect: :empty
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Closes the transaction, discarding uncommitted writes.

  Closing is idempotent and never fails on an already-closed transaction — it is
  safe to call in an `after` block.
  """
  @spec close(t()) :: :ok | {:error, Error.t()}
  def close(%__MODULE__{} = tx) do
    case Connection.request(tx.conn, :post, "/transactions/#{tx.id}/close", idempotent: false, expect: :empty) do
      {:ok, _} -> :ok
      # The server treats closing an unknown transaction as a no-op; a 404 here
      # means someone else already closed it, which is the state we wanted.
      {:error, %Error{status: 404}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end
