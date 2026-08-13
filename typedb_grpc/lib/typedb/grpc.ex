defmodule TypeDB.GRPC do
  @moduledoc """
  TypeDB over gRPC — the entry point.

  Shaped after `TypeDB`, the sibling package's facade, so that the difference
  between the two transports shows up where it is real rather than in the
  spelling of every call:

      {:ok, _pid} = TypeDB.GRPC.start_link(
        name: :graph,
        address: "127.0.0.1:1729",
        username: "admin",
        password: "password"
      )

      {:ok, answer} = TypeDB.GRPC.query(:graph, "social", "match $p isa person;",
        transaction_type: :read)

  Answers decode into `TypeDB.Concept` structs and failures arrive as
  `%TypeDB.Error{}` — the sibling's, not copies — so code above the data-access
  layer does not know which transport it is on.

  ## Where the two genuinely differ

    * **`query/4` is not a one-shot.** The protocol has no query outside a
      transaction, so this opens one, runs the query and finishes it. That is
      what the HTTP API does server-side for its one-shot too, but here the
      round trips are yours and a request-serving workload pays for them —
      measured, 200 independent point reads cost 249 ms here against 213 ms
      over HTTP.
    * **Answers have no ceiling.** There is no `answer_count_limit`, nothing
      truncates, and `TypeDB.Answer.truncated?/1` is always `false`.
    * **Reads can stream.** `stream/4` hands back an `Enumerable` that pulls
      from the server as it is consumed, so an answer larger than memory is a
      read rather than a problem.
    * **Writes go one at a time inside a transaction**, or through
      `TypeDB.GRPC.Transaction.execute_many/3` when their answers are not
      wanted. See that function for why.
  """

  alias TypeDB.{Answer, Error}
  alias TypeDB.GRPC.{Connection, Database, Server, Transaction}

  @type conn :: Connection.t()

  @doc """
  Starts a connection. See `TypeDB.GRPC.Config.new/1` for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: Connection

  @doc false
  defdelegate child_spec(opts), to: Connection

  @doc "Stops a connection."
  @spec stop(conn() | pid(), term(), timeout()) :: :ok
  defdelegate stop(conn, reason \\ :normal, timeout \\ :infinity), to: Connection

  @doc """
  Whether `conn` can serve a call.

  Answers about this node's connection process, not about TypeDB — the same
  caveat as `TypeDB.running?/1`. `health/2` is the question about the server.
  """
  @spec running?(conn()) :: boolean()
  defdelegate running?(conn), to: Connection

  @doc """
  Runs one query in a transaction of its own.

  ## Options

    * `:transaction_type` — `:read`, `:write` or `:schema`. Defaults to
      `:schema`, matching `TypeDB.query/4`: it is the only type that accepts
      every kind of query, and it is also the one that takes the exclusive
      schema lock, so pass the type you mean.
    * `:given_rows` — rows for TypeQL's `given` stage
    * `:timeout` — how long to wait
    * `:transaction_timeout_millis`, `:schema_lock_acquire_timeout_millis`

  A `:write` or `:schema` query commits; a `:read` closes.
  """
  @spec query(conn(), String.t(), String.t(), keyword()) ::
          {:ok, Answer.t()} | {:error, Error.t()}
  def query(conn, database, query, opts \\ []) when is_binary(query) do
    type = Keyword.get(opts, :transaction_type, :schema)

    Transaction.transaction(conn, database, type, fn tx -> Transaction.query(tx, query, opts) end, opts)
  end

  @doc "Runs one query, raising `TypeDB.Error` on failure."
  @spec query!(conn(), String.t(), String.t(), keyword()) :: Answer.t()
  def query!(conn, database, query, opts \\ []) do
    case query(conn, database, query, opts) do
      {:ok, answer} -> answer
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads a query as a `Stream`, pulling from the server as it is consumed.

  The thing this transport can do that the other cannot. The stream holds one
  batch at a time and asks TypeDB for the next only when the consumer wants it,
  so memory follows the batch rather than the answer:

      TypeDB.GRPC.stream(conn, "social", "match $p isa person, has name $n; select $n;")
      |> Stream.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
      |> Enum.each(&IO.puts/1)

  The transaction lives for as long as the stream does and is closed when it
  ends, including when the consumer stops early — `Enum.take/2` over a stream of
  ten million rows reads a batch, not ten million.

  Reads only. `:transaction_type` defaults to `:read` here rather than to
  `:schema`, because a stream of a `define` is not a thing anybody wants.
  """
  @spec stream(conn(), String.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(conn, database, query, opts \\ []) when is_binary(query) do
    type = Keyword.get(opts, :transaction_type, :read)
    timeout = Keyword.get(opts, :timeout, 60_000)

    Stream.resource(
      fn ->
        with {:ok, tx} <- Transaction.open(conn, database, type, opts),
             {:ok, ref} <- Transaction.stream_start(tx, query, opts) do
          {tx, ref}
        else
          {:error, error} -> raise error
        end
      end,
      fn {tx, ref} ->
        case Transaction.stream_next(tx, ref, timeout) do
          {:rows, rows} -> {rows, {tx, ref}}
          :done -> {:halt, {tx, ref}}
          {:error, error} -> raise error
        end
      end,
      # Runs on a normal end, on an early `Enum.take/2`, and on a raise — which
      # is what keeps a transaction from outliving the stream that opened it.
      fn {tx, _ref} -> Transaction.close(tx) end
    )
  end

  @doc """
  Runs `fun` inside one transaction, committing on success.

  Commits when `fun` returns anything but `{:error, _}`; closes without
  committing on an error, a raise, a throw or an exit.
  """
  @spec transaction(conn(), String.t(), Transaction.type(), (Transaction.t() -> result), keyword()) ::
          result | {:error, Error.t()}
        when result: term()
  defdelegate transaction(conn, database, type, fun, opts \\ []), to: Transaction

  @doc "Whether the server is reachable and answering."
  @spec health(conn(), keyword()) :: :ok | {:error, Error.t()}
  defdelegate health(conn, opts \\ []), to: Server

  @doc "The server's distribution and version."
  @spec version(conn(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate version(conn, opts \\ []), to: Server

  @doc "Every database on the server."
  @spec databases(conn(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  defdelegate databases(conn, opts \\ []), to: Database, as: :list

  @doc "Creates a database. A no-op for one that already exists."
  @spec create_database(conn(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  defdelegate create_database(conn, name, opts \\ []), to: Database, as: :create

  @doc "Creates a database unless it is already there."
  @spec create_database_if_not_exists(conn(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  defdelegate create_database_if_not_exists(conn, name, opts \\ []),
    to: Database,
    as: :create_if_not_exists

  @doc "Deletes a database and everything in it."
  @spec delete_database(conn(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  defdelegate delete_database(conn, name, opts \\ []), to: Database, as: :delete
end
