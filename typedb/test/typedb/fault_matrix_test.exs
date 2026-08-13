defmodule TypeDB.FaultMatrixTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Database, Error, FaultAdapter, Server, Transaction, User}

  # Every fault an adapter or a server can produce, against every public call
  # that reaches one. The claim under test is narrow and absolute: whatever
  # happens down there, a caller gets a `%TypeDB.Error{}` — returned or raised —
  # and the connection is still alive afterwards.
  #
  # Anything else is a finding. A `FunctionClauseError` from a decoder, a
  # `MatchError` on a shape nobody expected, an `{:ok, :ok}` where a list was
  # promised: those are the bugs this matrix exists to name.

  @tx %Transaction{conn: nil, id: "tx-1", database: "social", type: :write}

  defp calls(conn) do
    tx = %{@tx | conn: conn}

    [
      {"Database.list/1", fn -> Database.list(conn) end},
      {"Database.get/2", fn -> Database.get(conn, "social") end},
      {"Database.create/2", fn -> Database.create(conn, "social") end},
      {"Database.delete/2", fn -> Database.delete(conn, "social") end},
      {"Database.schema/2", fn -> Database.schema(conn, "social") end},
      {"Database.type_schema/2", fn -> Database.type_schema(conn, "social") end},
      {"Database.exists?/2", fn -> Database.exists?(conn, "social") end},
      {"Database.create_if_not_exists/2", fn -> Database.create_if_not_exists(conn, "social") end},
      {"User.list/1", fn -> User.list(conn) end},
      {"User.get/2", fn -> User.get(conn, "admin") end},
      {"User.create/3", fn -> User.create(conn, "alice", "s3cret") end},
      {"User.set_password/3", fn -> User.set_password(conn, "alice", "s3cret") end},
      {"User.delete/2", fn -> User.delete(conn, "alice") end},
      {"User.exists?/2", fn -> User.exists?(conn, "admin") end},
      {"Server.health/1", fn -> Server.health(conn) end},
      {"Server.version/1", fn -> Server.version(conn) end},
      {"Server.servers/1", fn -> Server.servers(conn) end},
      {"TypeDB.query/4", fn -> TypeDB.query(conn, "social", "match $p isa person;") end},
      {"Transaction.open/4", fn -> Transaction.open(conn, "social", :read) end},
      {"Transaction.query/3", fn -> Transaction.query(tx, "match $p isa person;") end},
      {"Transaction.analyze/3", fn -> Transaction.analyze(tx, "match $p isa person;") end},
      {"Transaction.commit/2", fn -> Transaction.commit(tx) end},
      {"Transaction.rollback/2", fn -> Transaction.rollback(tx) end},
      {"Transaction.close/2", fn -> Transaction.close(tx) end},
      {"TypeDB.transaction/5", fn -> TypeDB.transaction(conn, "social", :write, fn _ -> :ok end) end}
    ]
  end

  # Calls whose success is signalled by the status alone, so a 200 with a body
  # that is nonsense is still a success as far as this layer can tell.
  #
  # `Database.schema/2` and `type_schema/2` answer plain text: a schema is
  # whatever the server sent, and there is nothing to validate it against short
  # of parsing TypeQL. The rest expect no body at all — a 200 on
  # `POST /databases/x` means "created", and there is nothing in it to decode.
  #
  # Everything not on this list decodes JSON, and must reject anything that is
  # not the shape it expects. That is the half of the claim worth pinning: a
  # decoder answering `{:ok, :ok}` where its spec promises a list would sail
  # through an "it returned an error" check.
  @status_only [
    "Database.schema/2",
    "Database.type_schema/2",
    "Database.create/2",
    "Database.delete/2",
    "Database.create_if_not_exists/2",
    "User.create/3",
    "User.set_password/3",
    "User.delete/2",
    "Server.health/1",
    "Transaction.commit/2",
    "Transaction.rollback/2",
    "Transaction.close/2"
  ]

  for fault <- FaultAdapter.faults() do
    @fault fault

    test "#{fault}: every public call answers with a TypeDB.Error and the connection survives" do
      name = :"fault_#{@fault}_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          max_retries: 0,
          retry_on_status: [],
          http: {FaultAdapter, [fault: @fault]}
        )

      on_exit(fn ->
        try do
          TypeDB.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      outcomes = for {label, call} <- calls(name), do: {label, outcome(call)}

      offenders =
        for {label, {:bad, why}} <- outcomes, do: "#{label}: #{why}"

      assert offenders == [],
             "with the #{@fault} fault, these did not produce a TypeDB.Error:\n  " <>
               Enum.join(offenders, "\n  ")

      # Not enough on its own. A decoder that answered `{:ok, :ok}` where its
      # spec promises a list would have passed the check above, so the calls
      # that came back with a *value* are named and pinned too.
      succeeded = for {label, :value} <- outcomes, do: label

      assert succeeded -- @status_only == [],
             "with the #{@fault} fault, these returned a value where the response " <>
               "was not a response:\n  " <> Enum.join(succeeded -- @status_only, "\n  ")

      assert Process.alive?(pid), "the #{@fault} fault killed the connection process"
    end
  end

  # `close/2` treats a 404 as success and `exists?/2` answers a boolean, so a
  # plain value is a legitimate outcome for some of these — what is not
  # legitimate is any exception other than `TypeDB.Error`.
  defp outcome(call) do
    case call.() do
      {:error, %Error{}} -> :error
      {:ok, _value} -> :value
      :ok -> :value
      boolean when is_boolean(boolean) -> :value
      other -> {:bad, "returned #{inspect(other, limit: 3)}"}
    end
  rescue
    exception in Error ->
      _ = exception
      :error

    exception ->
      {:bad, "raised #{inspect(exception.__struct__)}: #{Exception.message(exception)}"}
  catch
    kind, reason -> {:bad, "#{kind} #{inspect(reason, limit: 3)}"}
  end
end
