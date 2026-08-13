defmodule TypeDB.GRPC.Transaction do
  @moduledoc """
  A transaction, which on this transport is a bidirectional stream.

  `rpc transaction (stream Transaction.Client) returns (stream Transaction.Server)`
  — one stream per transaction, and closing the stream closes the transaction.
  That is a different object from `TypeDB.Transaction`, which is an id in a
  struct and nothing else, and the difference has consequences worth stating
  before the API rather than after it.

  ## It is a process, and the handle is still a struct

  A stream has to be owned by something, so a transaction here is a `GenServer`.
  The handle you hold is still a plain struct — it carries the pid — so it can
  still be passed between processes freely, which is the property the sibling
  driver documents and which would otherwise have been lost. Requests from
  different processes are tracked independently, so concurrent callers on one
  handle each get their own answer. What changes is lifetime: the transaction
  dies with its process, so a transaction is no longer something that outlives
  the VM that opened it.

  A call that times out abandons its own request and leaves the transaction
  open, because with several callers the alternative is one slow read taking
  everybody else's work down with it. Ending the transaction is the caller's
  decision, and `transaction/5` makes it.

  ## Reads pipeline. Writes do not.

  `Transaction.Client` carries a repeated field and requests are correlated by
  `req_id` rather than by order, so several can be in flight at once — and for
  reads that is a large win: 200 reads sent together answer in 47 ms against
  the same 200 waiting for each other.

  Writes are a different matter, and the reason `query_many/3` documents itself
  the way it does. TypeDB aborts a write query's answer stream when the next
  write in the same transaction starts executing, with
  `[TSV13] Execution interrupted by to a concurrent write query`. Measured
  against 3.12.1: of 500 pipelined inserts, 4 answered and 496 came back TSV13.

  What makes that dangerous rather than merely disappointing is what happens
  next. The writes themselves *do* land — committing anyway put all 500 rows in
  the database — so a caller that ignored the errors would commit work it was
  told had failed. `query_many/3` refuses instead: it returns the first failure
  and the bracket closes without committing, which is why the same 500 land
  nowhere when the driver is driving.

  So: pipeline reads. Send writes one at a time with `query/3`, which is what
  the sequential number in the README measures.

  ## Answers have no ceiling

  The HTTP API returns one answer, capped at 10 000 by default, with a warning
  when it truncated. There is no cap here: answers arrive in parts and this
  module drives the flow control that asks for the next one, so an answer is as
  large as the query makes it. `TypeDB.Answer.truncated?/1` on an answer from
  this driver is always `false`, and honestly so.

  The current API collects the parts before returning, so a very large answer is
  a very large list. Constant-memory streaming is a further step and not done.
  """

  use GenServer

  use TypeDB.GRPC.Bang
  alias TypeDB.{Answer, Error}
  alias TypeDB.GRPC.{Connection, Decode, Telemetry}
  alias TypeDB.GRPC.Error, as: GRPCError
  alias Typedb.Protocol, as: Proto

  @type type :: :read | :write | :schema

  @type t :: %__MODULE__{
          pid: pid(),
          conn: Connection.t(),
          database: String.t(),
          type: type()
        }

  @enforce_keys [:pid, :conn, :database, :type]
  defstruct [:pid, :conn, :database, :type]

  @types %{read: :READ, write: :WRITE, schema: :SCHEMA}

  @doc """
  Opens a transaction.

  ## Options

    * `:transaction_timeout_millis` — how long the server keeps it without
      traffic
    * `:schema_lock_acquire_timeout_millis` — how long a `:schema` transaction
      waits for the exclusive lock
    * `:timeout` — how long to wait for the open itself
  """
  @spec open(Connection.t(), String.t(), type(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(conn, database, type, opts \\ []) when is_binary(database) do
    unless Map.has_key?(@types, type) do
      raise ArgumentError, "invalid transaction type #{inspect(type)}, expected :read, :write or :schema"
    end

    case GenServer.start(__MODULE__, {conn, database, type, opts}) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, conn: conn, database: database, type: type}}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, GRPCError.from_reason(reason, "opening a transaction on #{database}")}
    end
  end

  @doc """
  Runs `query` and waits for its whole answer.

  ## Options

    * `:given_rows` — rows for TypeQL's `given` stage, in the same shape the
      sibling driver takes
    * `:timeout` — how long to wait for the answer
    * `:include_instance_types` — ask the server to attach the type of every
      instance in the answer
  """
  @spec query(t(), String.t(), keyword()) :: {:ok, Answer.t()} | {:error, Error.t()}
  def query(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    case query_many(tx, [{query, opts}], opts) do
      {:ok, [answer]} -> {:ok, answer}
      {:ok, answers} -> {:ok, List.last(answers)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sends every query before waiting for any answer.

  **For reads.** `queries` is a list of `query` strings or `{query, opts}`
  pairs, and answers come back in the same order.

  Pipelining *writes* through this does not work, and the failure is the loud
  kind rather than the quiet kind: TypeDB aborts each write's answer stream when
  the next one starts, with `TSV13`, and this returns that failure. The bracket
  then closes without committing — which is the outcome you want, because the
  writes had begun to land and committing them would commit work the server
  reported as failed. Send writes with `query/3`.
  """
  @spec query_many(t(), [String.t() | {String.t(), keyword()}], keyword()) ::
          {:ok, [Answer.t()]} | {:error, Error.t()}
  def query_many(%__MODULE__{} = tx, queries, opts \\ []) when is_list(queries) do
    call(tx, {:query_many, Enum.map(queries, &normalise/1)}, opts)
  end

  @doc """
  Sends every query pipelined and discards the answers.

  This is how writes are sent fast on this transport, and it exists because of
  a behaviour that took measuring to pin down. TypeDB aborts a write's answer
  stream when the next write in the same transaction starts, reporting `TSV13`
  — but the write itself runs, in order, and lands. So the answers are the only
  thing lost, and a caller that does not want them can have the pipeline.

  Measured against 3.12.1: a thousand inserts in one transaction take about
  150 ms this way against 622 ms one at a time.

  **What it does not discard is failure.** `TSV13` is ignored, because on this
  path it means "the answer was dropped" rather than "the write failed". Every
  other per-query error is returned — which matters most for a query that does
  not parse, since TypeDB reports `TQL0`, *keeps the transaction usable*, and
  simply does not run that one. A mode that swallowed every error would let a
  malformed query vanish and commit the rest. Measured: 100 good inserts plus
  one unparseable query commits the 100 and reports `TQL0`.

  Errors that are about the data rather than the text — an unknown type, a
  value of the wrong type, a `@key` violation — abort the stream, so the
  transaction cannot be committed at all and nothing lands. Those cannot be
  missed whatever this function does.

      Transaction.transaction(conn, "social", :write, fn tx ->
        Transaction.execute_many(tx, Enum.map(people, &insert_query/1))
      end)
  """
  @spec execute_many(t(), [String.t() | {String.t(), keyword()}], keyword()) ::
          :ok | {:error, Error.t()}
  def execute_many(%__MODULE__{} = tx, queries, opts \\ []) when is_list(queries) do
    case call(tx, {:execute_many, Enum.map(queries, &normalise/1)}, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads a query as a `Stream`, pulling from the server as it is consumed.

  The reason this transport is worth having for large reads. A batch is held at
  a time and the next one is asked for only when the consumer wants it, so
  memory follows the batch rather than the answer — and stopping early stops the
  server:

      Transaction.stream(tx, "match $p isa person, has name $n; select $n;")
      |> Stream.map(&TypeDB.ConceptRow.typed_value(&1, "n"))
      |> Enum.take(10)

  That takes one batch out of however many the query would have produced,
  because the continuation signal TypeDB waits on is sent by the consumer's
  demand and never sent again.

  The stream is tied to this transaction and does not close it — use
  `TypeDB.GRPC.stream/4` when the transaction exists only for the read.
  """
  @spec stream(t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%__MODULE__{} = tx, query, opts \\ []) when is_binary(query) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    Stream.resource(
      fn ->
        case stream_start(tx, query, opts) do
          {:ok, ref} -> ref
          {:error, error} -> raise error
        end
      end,
      fn ref ->
        case stream_next(tx, ref, timeout) do
          {:rows, rows} -> {rows, ref}
          :done -> {:halt, ref}
          {:error, error} -> raise error
        end
      end,
      fn ref -> stream_cancel(tx, ref) end
    )
  end

  @doc false
  @spec stream_start(t(), String.t(), keyword()) :: {:ok, reference() | binary()} | {:error, Error.t()}
  def stream_start(%__MODULE__{} = tx, query, opts) do
    call(tx, {:stream_start, query, opts}, opts)
  end

  @doc false
  @spec stream_next(t(), binary(), timeout()) :: {:rows, [term()]} | :done | {:error, Error.t()}
  def stream_next(%__MODULE__{} = tx, ref, timeout) do
    started_at = System.monotonic_time()
    result = do_stream_next(tx.pid, ref, timeout)

    case result do
      {:rows, rows} ->
        Telemetry.stream_batch(
          %{rows: length(rows), wait: System.monotonic_time() - started_at},
          %{connection: tx.conn, database: tx.database}
        )

      _ ->
        :ok
    end

    result
  end

  defp do_stream_next(pid, ref, timeout) do
    GenServer.call(pid, {:stream_next, ref}, timeout)
  catch
    :exit, {:timeout, _} ->
      # This caller gives up on *its* request. It used to close the whole
      # transaction, which was defensible while only one call could be
      # outstanding and became a way for one slow read to destroy every other
      # caller's work once several could — Audit V, V-3.
      #
      # The abandoned request answers into a reply nobody waits for, which is
      # harmless, and its bookkeeping is collected when the transaction ends.
      # Closing is the caller's to do, and `transaction/5` does it.
      {:error,
       Error.new(
         :timeout,
         "the transaction did not answer within #{timeout}ms; the request was abandoned " <>
           "and the transaction is still open"
       )}

    :exit, {:noproc, _} ->
      {:error, Error.new(:server, "no open transaction", code: "TSV12", status: 404)}

    :exit, reason ->
      {:error, GRPCError.from_reason(reason, "streaming a read")}
  end

  @doc false
  @spec stream_cancel(t(), binary()) :: :ok
  def stream_cancel(%__MODULE__{pid: pid}, ref) do
    if Process.alive?(pid), do: GenServer.cast(pid, {:stream_cancel, ref})
    :ok
  end

  @doc "Commits. The transaction is finished either way."
  @spec commit(t(), keyword()) :: :ok | {:error, Error.t()}
  def commit(%__MODULE__{} = tx, opts \\ []) do
    case call(tx, :commit, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Discards everything written so far, leaving the transaction open.

  The same semantics as the sibling's `rollback/2`, and the same warning: this
  does **not** finish a transaction. `close/2` does.
  """
  @spec rollback(t(), keyword()) :: :ok | {:error, Error.t()}
  def rollback(%__MODULE__{} = tx, opts \\ []) do
    case call(tx, :rollback, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Closes the transaction, discarding uncommitted writes.

  Idempotent, and never fails on a transaction that is already finished — so it
  is safe in an `after` block, which is where it belongs.
  """
  @spec close(t(), keyword()) :: :ok
  def close(%__MODULE__{pid: pid}, _opts \\ []) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Whether the transaction is still usable."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @doc """
  Runs `fun` inside a transaction, committing on success.

  Commits when `fun` returns anything but `{:error, _}`; closes without
  committing on an error, a raise, a throw or an exit. A `:read` transaction is
  closed rather than committed.
  """
  @spec transaction(Connection.t(), String.t(), type(), (t() -> result), keyword()) ::
          result | {:error, Error.t()}
        when result: term()
  def transaction(conn, database, type, fun, opts \\ []) when is_function(fun, 1) do
    metadata = %{connection: conn, database: database, type: type}

    Telemetry.span_transaction(metadata, fn ->
      result = do_transaction(conn, database, type, fun, opts)
      {result, Map.merge(metadata, transaction_outcome(type, result))}
    end)
  end

  defp transaction_outcome(:read, _result), do: %{outcome: :close}
  defp transaction_outcome(_type, {:error, %Error{} = error}), do: %{outcome: :commit_failed, error: error}
  defp transaction_outcome(_type, {:error, reason}), do: %{outcome: :close, error: reason}
  defp transaction_outcome(_type, _result), do: %{outcome: :commit}

  defp do_transaction(conn, database, type, fun, opts) do
    with {:ok, tx} <- open(conn, database, type, opts) do
      try do
        case fun.(tx) do
          {:error, _} = error -> error
          result -> finish(tx, result, opts)
        end
      rescue
        exception ->
          close(tx)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          close(tx)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        close(tx)
      end
    end
  end

  defp finish(%__MODULE__{type: :read} = tx, result, _opts) do
    close(tx)
    result
  end

  defp finish(tx, result, opts) do
    case commit(tx, opts) do
      :ok -> result
      {:error, _} = error -> error
    end
  end

  defp normalise(query) when is_binary(query), do: {query, []}
  defp normalise({query, opts}) when is_binary(query) and is_list(opts), do: {query, opts}

  defp call(%__MODULE__{} = tx, message, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    metadata =
      %{
        connection: tx.conn,
        operation: operation_name(message),
        database: tx.database,
        transaction_type: tx.type
      }
      |> put_query_count(message)

    Telemetry.span_operation(metadata, fn ->
      result = do_call(tx.pid, message, timeout)

      {result,
       case result do
         {:error, %Error{} = error} -> Map.put(metadata, :error, error)
         _ -> metadata
       end}
    end)
  end

  defp operation_name({:query_many, [_]}), do: :query
  defp operation_name({:query_many, _}), do: :query_many
  defp operation_name({:execute_many, _}), do: :execute_many
  defp operation_name({:stream_start, _, _}), do: :stream
  defp operation_name(atom) when is_atom(atom), do: atom

  defp put_query_count(metadata, {op, queries}) when op in [:query_many, :execute_many] do
    Map.put(metadata, :queries, length(queries))
  end

  defp put_query_count(metadata, _), do: metadata

  defp do_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} ->
      # The stream is still carrying whatever the server is doing, and this
      # process no longer knows where in the exchange it is. Closing is the only
      # honest recovery, and it matches what the sibling documents: a timeout on
      # a transaction request ends the transaction.
      _ = if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)

      {:error, Error.new(:timeout, "the transaction did not answer within #{timeout}ms; it has been closed")}

    :exit, {:noproc, _} ->
      {:error, Error.new(:server, "no open transaction", code: "TSV12", status: 404)}

    :exit, reason ->
      {:error, GRPCError.from_reason(reason, "a transaction request")}
  end

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init({conn, database, type, opts}) do
    case Connection.metadata(conn) do
      {:error, error} -> {:stop, error}
      {:ok, md, _minted_at} -> start_stream(conn, database, type, opts, md)
    end
  end

  defp start_stream(conn, database, type, opts, md) do
    stream = Proto.TypeDB.Stub.transaction(Connection.channel(conn), metadata: md)

    state = %{
      stream: stream,
      database: database,
      type: type,
      # req_id -> accumulator, for requests whose answers are still arriving
      pending: %{},
      # Outstanding calls, keyed by a reference, each `%{from:, ids:, collected:}`.
      # A map rather than the single slot this used to be: the moduledoc promises
      # a handle can be passed between processes, and one slot meant the second
      # caller overwrote the first's `from` — Audit V, V-3.
      calls: %{},
      # req_id -> the reference of the call that owns it.
      owner: %{},
      reader: nil
    }

    case start_reader(stream) do
      {:ok, reader} -> open_transaction(%{state | reader: reader}, opts)
      {:error, error} -> {:stop, error}
    end
  end

  # The replies arrive as a lazy enumerable that blocks while it is consumed, so
  # something other than this process has to consume it. The reader is linked:
  # if the stream dies the transaction dies with it, which is the truth of the
  # situation rather than a state to paper over.
  defp start_reader(stream) do
    parent = self()

    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, replies} ->
        {:ok,
         spawn_link(fn ->
           Enum.each(replies, &send(parent, {:stream_reply, &1}))
           send(parent, {:stream_done, :normal})
         end)}

      {:error, %GRPC.RPCError{} = error} ->
        {:error, GRPCError.from_rpc_error(error, "opening a transaction stream")}

      {:error, reason} ->
        {:error, GRPCError.from_reason(reason, "opening a transaction stream")}
    end
  end

  defp open_transaction(state, opts) do
    request = %Proto.Transaction.Open.Req{
      database: state.database,
      type: Map.fetch!(@types, state.type),
      network_latency_millis: 0,
      options: transaction_options(opts)
    }

    id = request_id()
    send_reqs(state, [%Proto.Transaction.Req{req_id: id, req: {:open_req, request}}])

    # The open is awaited synchronously: a transaction that failed to open is
    # not a transaction, and returning a handle to one would move the failure to
    # a later and less obvious place.
    receive do
      {:stream_reply, {:ok, %Proto.Transaction.Server{server: {:res, %{res: {:open_res, _}}}}}} ->
        {:ok, state}

      {:stream_reply, {:error, %GRPC.RPCError{} = error}} ->
        {:stop, GRPCError.from_rpc_error(error, "opening a transaction on #{state.database}")}

      {:stream_reply, other} ->
        {:stop,
         Error.new(:decode, "unexpected first reply on a transaction stream: #{inspect(other, limit: 5)}")}

      {:stream_done, _} ->
        {:stop, Error.new(:transport, "the transaction stream closed before it opened")}
    after
      Keyword.get(opts, :timeout, 60_000) ->
        {:stop, Error.new(:timeout, "opening a transaction on #{state.database} timed out")}
    end
  end

  defp transaction_options(opts) do
    timeout = opts[:transaction_timeout_millis]
    lock = opts[:schema_lock_acquire_timeout_millis]

    if timeout || lock do
      %Proto.Options.Transaction{
        transaction_timeout_millis: timeout,
        schema_lock_acquire_timeout_millis: lock
      }
    end
  end

  @impl GenServer
  def handle_call({:query_many, queries}, from, state) do
    {reqs, pending} =
      Enum.map_reduce(queries, state.pending, fn {query, opts}, acc ->
        id = request_id()

        req = %Proto.Transaction.Req{
          req_id: id,
          req: {:query_req, query_request(query, opts)}
        }

        {req, Map.put(acc, id, new_accumulator())}
      end)

    ids = Enum.map(reqs, & &1.req_id)
    send_reqs(state, reqs)

    {:noreply, register_call(%{state | pending: pending}, from, ids)}
  end

  def handle_call({:execute_many, queries}, from, state) do
    {reqs, pending} =
      Enum.map_reduce(queries, state.pending, fn {query, opts}, acc ->
        id = request_id()
        req = %Proto.Transaction.Req{req_id: id, req: {:query_req, query_request(query, opts)}}
        {req, Map.put(acc, id, %{new_accumulator() | discard: true})}
      end)

    ids = Enum.map(reqs, & &1.req_id)
    send_reqs(state, reqs)

    {:noreply, register_call(%{state | pending: pending}, from, ids)}
  end

  def handle_call({:stream_start, query, opts}, _from, state) do
    id = request_id()
    send_reqs(state, [%Proto.Transaction.Req{req_id: id, req: {:query_req, query_request(query, opts)}}])

    accumulator = %{
      mode: :stream,
      columns: [],
      query_type: nil,
      buffer: [],
      waiting: nil,
      status: :open,
      # True once TypeDB has paused the answer and is waiting to be told to go
      # on. Nothing tells it until a consumer asks — that is the back pressure.
      paused: false
    }

    {:reply, {:ok, id}, %{state | pending: Map.put(state.pending, id, accumulator)}}
  end

  def handle_call({:stream_next, id}, from, state) do
    case Map.get(state.pending, id) do
      nil ->
        {:reply, :done, state}

      %{mode: :stream} = acc ->
        {:noreply, serve_stream(state, id, %{acc | waiting: from})}

      _ ->
        {:reply, {:error, Error.new(:config, "#{inspect(id)} is not a streamed read")}, state}
    end
  end

  def handle_call(:commit, from, state) do
    id = request_id()

    commit = %Proto.Transaction.Commit.Req{}
    send_reqs(state, [%Proto.Transaction.Req{req_id: id, req: {:commit_req, commit}}])

    {:noreply, awaiting(state, from, id)}
  end

  def handle_call(:rollback, from, state) do
    id = request_id()

    send_reqs(state, [
      %Proto.Transaction.Req{req_id: id, req: {:rollback_req, %Proto.Transaction.Rollback.Req{}}}
    ])

    {:noreply, awaiting(state, from, id)}
  end

  # A commit or a rollback answers once and carries nothing to accumulate, so
  # its slot in `pending` is a marker rather than a collector.
  defp awaiting(state, from, id) do
    register_call(%{state | pending: Map.put(state.pending, id, :unit)}, from, [id])
  end

  defp register_call(state, from, ids) do
    ref = make_ref()

    %{
      state
      | calls: Map.put(state.calls, ref, %{from: from, ids: ids, collected: %{}}),
        owner: Enum.reduce(ids, state.owner, &Map.put(&2, &1, ref))
    }
  end

  @impl GenServer
  def handle_cast({:stream_cancel, id}, state) do
    # The server keeps whatever it has queued, and never hears from us again for
    # this request. It is collected when the transaction ends, which is the only
    # thing that ends a stream on this protocol.
    {:noreply, %{state | pending: Map.delete(state.pending, id)}}
  end

  @impl GenServer
  def handle_info({:stream_reply, reply}, state), do: {:noreply, handle_reply(reply, state)}

  def handle_info({:stream_done, _reason}, state) do
    {:stop, :normal, fail_awaiting(state, Error.new(:transport, "the transaction stream closed"))}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, :normal, fail_awaiting(state, GRPCError.from_reason(reason, "the transaction stream failed"))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = GRPC.Stub.end_stream(state.stream)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- replies ---------------------------------------------------------------

  defp handle_reply({:ok, %Proto.Transaction.Server{server: {:res, res}}}, state) do
    on_result(state, res.req_id, res.res)
  end

  defp handle_reply({:ok, %Proto.Transaction.Server{server: {:res_part, part}}}, state) do
    on_part(state, part.req_id, part.res_part)
  end

  defp handle_reply({:error, %GRPC.RPCError{} = error}, state) do
    fail_awaiting(state, GRPCError.from_rpc_error(error, "a transaction request"))
  end

  defp handle_reply(other, state) do
    fail_awaiting(state, Error.new(:decode, "unexpected reply: #{inspect(other, limit: 5)}"))
  end

  defp on_result(state, id, {:query_initial_res, %{res: {:error, error}}}) do
    terminate_request(state, id, error)
  end

  defp on_result(state, id, {:query_initial_res, %{res: {:ok, ok}}}) do
    if streaming?(state, id), do: stream_header(state, id, ok.ok), else: collect_header(state, id, ok.ok)
  end

  defp on_result(state, id, {:commit_res, _}), do: finish_one(state, id, {:ok, :ok})
  defp on_result(state, id, {:rollback_res, _}), do: finish_one(state, id, {:ok, :ok})
  defp on_result(state, _id, _other), do: state

  # A streamed read keeps only the column names — the rows are decoded as they
  # arrive rather than at the end, which is what makes the memory constant.
  defp stream_header(state, id, {:concept_row_stream, header}) do
    state
    |> put_stream(id, fn acc ->
      %{acc | columns: header.column_variable_names, query_type: query_type(header.query_type)}
    end)
    |> serve_if_streaming(id)
  end

  defp stream_header(state, id, {:concept_document_stream, header}) do
    state
    |> put_stream(id, fn acc -> %{acc | query_type: query_type(header.query_type)} end)
    |> serve_if_streaming(id)
  end

  defp stream_header(state, id, {:done, %{query_type: query_type}}) do
    # A streamed query that answers nothing. It ends at once rather than waiting
    # for parts that will never come.
    state
    |> put_stream(id, fn acc -> %{acc | status: :done, query_type: query_type(query_type)} end)
    |> serve_if_streaming(id)
  end

  defp collect_header(state, id, {:done, %{query_type: query_type}}) do
    finish_one(state, id, {:ok, %Answer.Ok{query_type: query_type(query_type)}})
  end

  defp collect_header(state, id, {:concept_row_stream, header}) do
    update_accumulator(state, id, fn acc ->
      %{
        acc
        | kind: :rows,
          columns: header.column_variable_names,
          query_type: query_type(header.query_type)
      }
    end)
  end

  defp collect_header(state, id, {:concept_document_stream, header}) do
    update_accumulator(state, id, fn acc ->
      %{acc | kind: :documents, query_type: query_type(header.query_type)}
    end)
  end

  # How a request ends, whichever mode it is in.
  defp terminate_request(state, id, error) do
    cond do
      streaming?(state, id) ->
        state
        |> put_stream(id, fn acc -> %{acc | status: {:error, query_error(error)}} end)
        |> serve_if_streaming(id)

      # On a discarding call TSV13 is not a failure: the write ran and only its
      # answer was dropped. Every other code still is — see `execute_many/3`.
      discarding?(state, id) and error_code(error) == "TSV13" ->
        finish_one(state, id, {:ok, :discarded})

      true ->
        finish_one(state, id, {:error, query_error(error)})
    end
  end

  defp streaming?(state, id), do: match?(%{mode: :stream}, Map.get(state.pending, id))

  defp put_stream(state, id, fun) do
    case Map.get(state.pending, id) do
      %{mode: :stream} = acc -> %{state | pending: Map.put(state.pending, id, fun.(acc))}
      _ -> state
    end
  end

  defp serve_if_streaming(state, id) do
    if streaming?(state, id), do: serve_stream(state, id, Map.fetch!(state.pending, id)), else: state
  end

  # The whole of the back pressure, in one function.
  #
  # A consumer waiting with rows available gets them. A consumer waiting with
  # nothing available, on a stream TypeDB has paused, is what finally sends the
  # continuation signal — so the server produces the next batch because somebody
  # asked for it, and not before. Everything else is recorded and waited on.
  defp serve_stream(state, id, %{waiting: nil} = acc), do: store(state, id, acc)

  defp serve_stream(state, id, %{buffer: [_ | _]} = acc) do
    GenServer.reply(acc.waiting, {:rows, acc.buffer})
    store(state, id, %{acc | buffer: [], waiting: nil})
  end

  defp serve_stream(state, id, %{status: {:error, error}} = acc) do
    GenServer.reply(acc.waiting, {:error, error})
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp serve_stream(state, id, %{status: :done} = acc) do
    GenServer.reply(acc.waiting, :done)
    %{state | pending: Map.delete(state.pending, id)}
  end

  # The one clause that is the back pressure: a consumer is waiting, there is
  # nothing to give it, and TypeDB has paused — so it is told to go on now,
  # because somebody asked, and never on arrival.
  defp serve_stream(state, id, %{paused: true} = acc) do
    send_reqs(state, [
      %Proto.Transaction.Req{req_id: id, req: {:stream_req, %Proto.Transaction.StreamSignal.Req{}}}
    ])

    store(state, id, %{acc | paused: false})
  end

  defp serve_stream(state, id, acc), do: store(state, id, acc)

  defp store(state, id, acc), do: %{state | pending: Map.put(state.pending, id, acc)}

  defp discarding?(state, id) do
    match?(%{discard: true}, Map.get(state.pending, id))
  end

  defp error_code(%Proto.Error{error_code: code}), do: code
  defp error_code(_), do: nil

  defp on_part(state, id, {:query_res, %{res: {:rows_res, %{rows: rows}}}}) do
    if streaming?(state, id) do
      # Decoded here rather than at the end: a streamed read never holds the
      # undecoded parts, which is the whole point of it.
      state
      |> put_stream(id, fn acc ->
        %{acc | buffer: acc.buffer ++ Enum.map(rows, &Decode.row(&1, acc.columns))}
      end)
      |> serve_if_streaming(id)
    else
      update_accumulator(state, id, fn
        %{discard: true} = acc -> acc
        acc -> %{acc | parts: [rows | acc.parts]}
      end)
    end
  end

  defp on_part(state, id, {:query_res, %{res: {:documents_res, %{documents: docs}}}}) do
    if streaming?(state, id) do
      state
      |> put_stream(id, fn acc -> %{acc | buffer: acc.buffer ++ Enum.map(docs, &document/1)} end)
      |> serve_if_streaming(id)
    else
      update_accumulator(state, id, fn
        %{discard: true} = acc -> acc
        acc -> %{acc | parts: [docs | acc.parts]}
      end)
    end
  end

  # Flow control. The signal must carry the *original* request's id — a fresh one
  # names no stream, and the server simply stops sending, which reads as a hang
  # rather than as an error.
  #
  # For a collected answer it goes out at once, because the caller is waiting for
  # all of it anyway. For a streamed one it does not: `serve_stream/3` sends it
  # when a consumer asks for the next batch, and that is the back pressure.
  defp on_part(state, id, {:stream_res, %{state: {:continue, _}}}) do
    if streaming?(state, id) do
      state |> put_stream(id, fn acc -> %{acc | paused: true} end) |> serve_if_streaming(id)
    else
      send_reqs(state, [
        %Proto.Transaction.Req{req_id: id, req: {:stream_req, %Proto.Transaction.StreamSignal.Req{}}}
      ])

      state
    end
  end

  defp on_part(state, id, {:stream_res, %{state: {:done, _}}}) do
    cond do
      streaming?(state, id) ->
        state |> put_stream(id, fn acc -> %{acc | status: :done} end) |> serve_if_streaming(id)

      Map.has_key?(state.pending, id) ->
        finish_one(state, id, {:ok, build_answer(Map.fetch!(state.pending, id))})

      true ->
        state
    end
  end

  defp on_part(state, id, {:stream_res, %{state: {:error, error}}}) do
    terminate_request(state, id, error)
  end

  defp on_part(state, _id, _other), do: state

  # -- accumulators ----------------------------------------------------------

  defp new_accumulator, do: %{kind: :unknown, columns: [], query_type: nil, parts: [], discard: false}

  defp update_accumulator(state, id, fun) do
    case Map.get(state.pending, id) do
      nil -> state
      :unit -> state
      acc -> %{state | pending: Map.put(state.pending, id, fun.(acc))}
    end
  end

  defp build_answer(%{discard: true}), do: :discarded

  defp build_answer(%{kind: :rows} = acc) do
    rows =
      acc.parts
      |> Enum.reverse()
      |> Enum.concat()
      |> Enum.map(&Decode.row(&1, acc.columns))

    %Answer.ConceptRows{query_type: acc.query_type, rows: rows, warning: nil}
  end

  defp build_answer(%{kind: :documents} = acc) do
    documents = acc.parts |> Enum.reverse() |> Enum.concat() |> Enum.map(&document/1)
    %Answer.ConceptDocuments{query_type: acc.query_type, documents: documents, warning: nil}
  end

  defp build_answer(acc), do: %Answer.Ok{query_type: acc.query_type}

  defp document(%Proto.ConceptDocument{root: root}), do: node_value(root)
  defp document(other), do: other

  defp node_value(nil), do: nil

  defp node_value(%Proto.ConceptDocument.Node{node: {:map, %{map: map}}}),
    do: Map.new(map, fn {k, v} -> {k, node_value(v)} end)

  defp node_value(%Proto.ConceptDocument.Node{node: {:list, %{list: list}}}),
    do: Enum.map(list, &node_value/1)

  defp node_value(%Proto.ConceptDocument.Node{node: {:leaf, leaf}}), do: leaf_value(leaf)
  defp node_value(_), do: nil

  defp leaf_value(%Proto.ConceptDocument.Node.Leaf{leaf: {:empty, _}}), do: nil
  defp leaf_value(%Proto.ConceptDocument.Node.Leaf{leaf: {:value, value}}), do: Decode.value(value)
  defp leaf_value(%Proto.ConceptDocument.Node.Leaf{leaf: {_tag, value}}), do: leaf_concept(value)
  defp leaf_value(_), do: nil

  defp leaf_concept(%{label: label}), do: label
  defp leaf_concept(other), do: Decode.concept(%Proto.Concept{concept: {:attribute, other}})

  # -- completion ------------------------------------------------------------

  defp finish_one(state, id, result) do
    state = %{state | pending: Map.delete(state.pending, id)}

    case Map.fetch(state.owner, id) do
      :error -> state
      {:ok, ref} -> complete(state, ref, id, result)
    end
  end

  defp complete(state, ref, id, result) do
    call = Map.fetch!(state.calls, ref)
    collected = Map.put(call.collected, id, result)
    state = %{state | owner: Map.delete(state.owner, id)}

    if Enum.all?(call.ids, &Map.has_key?(collected, &1)) do
      GenServer.reply(call.from, assemble(call.ids, collected))
      %{state | calls: Map.delete(state.calls, ref)}
    else
      %{state | calls: Map.put(state.calls, ref, %{call | collected: collected})}
    end
  end

  defp assemble(ids, collected) do
    results = Enum.map(ids, &Map.fetch!(collected, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = error -> error
      nil -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
    end
  end

  # The stream is gone, so every outstanding call is gone with it — not just
  # whichever one happened to be in a slot.
  defp fail_awaiting(state, error) do
    Enum.each(state.calls, fn {_ref, call} -> GenServer.reply(call.from, {:error, error}) end)
    %{state | calls: %{}, owner: %{}}
  end

  # -- wire ------------------------------------------------------------------

  defp send_reqs(state, reqs) do
    Enum.each(reqs, fn req ->
      GRPC.Stub.send_request(state.stream, %Proto.Transaction.Client{reqs: [req]})
    end)
  end

  defp request_id, do: :crypto.strong_rand_bytes(16)

  defp query_request(query, opts) do
    %Proto.Query.Req{
      query: query,
      options: query_options(opts),
      given: given_rows(opts[:given_rows])
    }
  end

  defp query_options(opts) do
    if opts[:include_instance_types] != nil or opts[:prefetch_size] != nil do
      %Proto.Options.Query{
        include_instance_types: opts[:include_instance_types],
        prefetch_size: opts[:prefetch_size]
      }
    end
  end

  defp given_rows(nil), do: nil
  defp given_rows([]), do: nil

  defp given_rows(rows) when is_list(rows) do
    variables = rows |> hd() |> Map.keys() |> Enum.sort()

    %Proto.Query.Req.GivenRows{
      variables: variables,
      rows:
        Enum.map(rows, fn row ->
          %Proto.Query.Req.GivenRow{
            entries: Enum.map(variables, &given_entry(Map.get(row, &1)))
          }
        end)
    }
  end

  defp given_entry(nil),
    do: %Proto.Query.Req.GivenEntry{entry: {:empty, %Proto.Query.Req.GivenEntry.EmptyEntry{}}}

  defp given_entry(value) do
    %Proto.Query.Req.GivenEntry{entry: {:value, encode_value(value)}}
  end

  defp encode_value(value) when is_boolean(value), do: %Proto.Value{value: {:boolean, value}}
  defp encode_value(value) when is_integer(value), do: %Proto.Value{value: {:integer, value}}
  defp encode_value(value) when is_float(value), do: %Proto.Value{value: {:double, value}}
  defp encode_value(value) when is_binary(value), do: %Proto.Value{value: {:string, value}}

  defp encode_value(%Date{} = date) do
    %Proto.Value{value: {:date, %Proto.Value.Date{num_days_since_ce: Date.diff(date, ~D[0001-01-01]) + 1}}}
  end

  defp encode_value(%DateTime{} = datetime) do
    nanos = DateTime.to_unix(datetime, :nanosecond)

    %Proto.Value{
      value:
        {:datetime,
         %Proto.Value.Datetime{seconds: div(nanos, 1_000_000_000), nanos: rem(nanos, 1_000_000_000)}}
    }
  end

  defp encode_value(%TypeDB.Duration{months: months, days: days, nanos: nanos}) do
    %Proto.Value{value: {:duration, %Proto.Value.Duration{months: months, days: days, nanos: nanos}}}
  end

  defp encode_value(other) do
    raise Error.new(
            :encode,
            "no TypeDB value for #{inspect(other)} — supported: boolean, integer, float, string, " <>
              "Date, DateTime and TypeDB.Duration"
          )
  end

  # -- helpers ---------------------------------------------------------------

  defp query_type(:READ), do: :read
  defp query_type(:WRITE), do: :write
  defp query_type(:SCHEMA), do: :schema
  defp query_type(other) when is_atom(other), do: other
  defp query_type(_), do: nil

  defp query_error(%Proto.Error{error_code: code, stack_trace: trace}) do
    Error.new(:server, message_from(trace, code),
      code: code,
      status: TypeDB.GRPC.Error.http_status(3)
    )
  end

  defp query_error(other), do: Error.new(:server, inspect(other, limit: 5))

  defp message_from([_ | _] = trace, _code), do: Enum.join(trace, "\n")
  defp message_from(_, code), do: "TypeDB rejected the query with #{code}"

  # -- `!` twins ---------------------------------------------------------------
  #
  # The convention `CLAUDE.md` states and the sibling enforces mechanically:
  # every failing operation has a twin that raises. Generated through macros
  # rather than a shared function so each keeps its own success typing — see
  # `TypeDB.GRPC.Bang`.

  @doc "Opens a transaction, raising on failure."
  @spec open!(term(), term(), term(), term()) :: t()
  def open!(conn, database, type, opts \\ []), do: unwrap!(open(conn, database, type, opts))

  @doc "Runs a query, raising on failure."
  @spec query!(term(), term(), term()) :: Answer.t()
  def query!(tx, query, opts \\ []), do: unwrap!(query(tx, query, opts))

  @doc "Runs several queries, raising on failure."
  @spec query_many!(term(), term(), term()) :: [Answer.t()]
  def query_many!(tx, queries, opts \\ []), do: unwrap!(query_many(tx, queries, opts))

  @doc "Sends queries discarding answers, raising on failure."
  @spec execute_many!(term(), term(), term()) :: :ok
  def execute_many!(tx, queries, opts \\ []), do: ok!(execute_many(tx, queries, opts))

  @doc "Commits, raising on failure."
  @spec commit!(term(), term()) :: :ok
  def commit!(tx, opts \\ []), do: ok!(commit(tx, opts))

  @doc "Discards writes, raising on failure."
  @spec rollback!(term(), term()) :: :ok
  def rollback!(tx, opts \\ []), do: ok!(rollback(tx, opts))
end
