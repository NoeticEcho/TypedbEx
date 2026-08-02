defmodule TypeDB.CallOptionsTest do
  use TypeDB.Case, async: true

  # An option key comes from the caller's own source. Accepting one the driver
  # has never heard of means silently applying the default instead, which is how
  # `given:` for `given_rows:` runs a query unparameterised and `commmit: false`
  # commits. `TypeDB.Config` has rejected unknown *connection* options since
  # 0.1.0 for the same reason; this is the rest of the surface.

  alias TypeDB.{CallOptions, Database, Options, Server, User}

  @moduletag stub_opts: [databases: ["social"]]

  # Every public function that takes options, what it accepts, and one call of
  # it. A function added without a row here is caught by the last test.
  defp calls(conn, tx) do
    [
      {"TypeDB.query/4", CallOptions.query(),
       fn opts -> TypeDB.query(conn, "social", "match $p isa person;", opts) end},
      {"TypeDB.transaction/5", CallOptions.open(),
       fn opts -> TypeDB.transaction(conn, "social", :read, fn _tx -> :ok end, opts) end},
      {"TypeDB.Transaction.open/4", CallOptions.open(),
       fn opts -> Transaction.open(conn, "social", :read, opts) end},
      {"TypeDB.Transaction.query/3", CallOptions.transaction_query(),
       fn opts -> Transaction.query(tx, "match $p isa person;", opts) end},
      {"TypeDB.Transaction.analyze/3", CallOptions.request(),
       fn opts -> Transaction.analyze(tx, "match $p isa person;", opts) end},
      {"TypeDB.Transaction.commit/2", CallOptions.request(), fn opts -> Transaction.commit(tx, opts) end},
      {"TypeDB.Transaction.rollback/2", CallOptions.request(), fn opts -> Transaction.rollback(tx, opts) end},
      {"TypeDB.Transaction.close/2", CallOptions.request(), fn opts -> Transaction.close(tx, opts) end},

      # Administration. Every one of these makes a request, so every one takes
      # the same `:timeout` and `:deadline` as everything else that does.
      {"TypeDB.Database.list/2", CallOptions.request(), fn opts -> Database.list(conn, opts) end},
      {"TypeDB.Database.get/3", CallOptions.request(), fn opts -> Database.get(conn, "social", opts) end},
      {"TypeDB.Database.create/3", CallOptions.request(),
       fn opts -> Database.create(conn, "social", opts) end},
      {"TypeDB.Database.create_if_not_exists/3", CallOptions.request(),
       fn opts -> Database.create_if_not_exists(conn, "social", opts) end},
      {"TypeDB.Database.exists?/3", CallOptions.request(),
       fn opts -> Database.exists?(conn, "social", opts) end},
      {"TypeDB.Database.delete/3", CallOptions.request(),
       fn opts -> Database.delete(conn, "social", opts) end},
      {"TypeDB.Database.schema/3", CallOptions.request(),
       fn opts -> Database.schema(conn, "social", opts) end},
      {"TypeDB.Database.type_schema/3", CallOptions.request(),
       fn opts -> Database.type_schema(conn, "social", opts) end},
      {"TypeDB.User.list/2", CallOptions.request(), fn opts -> User.list(conn, opts) end},
      {"TypeDB.User.get/3", CallOptions.request(), fn opts -> User.get(conn, "admin", opts) end},
      {"TypeDB.User.exists?/3", CallOptions.request(), fn opts -> User.exists?(conn, "admin", opts) end},
      {"TypeDB.User.create/4", CallOptions.request(),
       fn opts -> User.create(conn, "alice", "password", opts) end},
      {"TypeDB.User.set_password/4", CallOptions.request(),
       fn opts -> User.set_password(conn, "admin", "password", opts) end},
      {"TypeDB.User.delete/3", CallOptions.request(), fn opts -> User.delete(conn, "alice", opts) end},
      {"TypeDB.Server.health/2", CallOptions.request(), fn opts -> Server.health(conn, opts) end},
      {"TypeDB.Server.version/2", CallOptions.request(), fn opts -> Server.version(conn, opts) end},
      {"TypeDB.Server.servers/2", CallOptions.request(), fn opts -> Server.servers(conn, opts) end},

      # The convenience delegates on `TypeDB` forward their options, so they
      # validate them too — a delegate that silently dropped `:timeout` would be
      # worse than one that never took it.
      {"TypeDB.databases/2", CallOptions.request(), fn opts -> TypeDB.databases(conn, opts) end},
      {"TypeDB.create_database/3", CallOptions.request(),
       fn opts -> TypeDB.create_database(conn, "social", opts) end},
      {"TypeDB.delete_database/3", CallOptions.request(),
       fn opts -> TypeDB.delete_database(conn, "social", opts) end},
      {"TypeDB.health/2", CallOptions.request(), fn opts -> TypeDB.health(conn, opts) end},
      {"TypeDB.version/2", CallOptions.request(), fn opts -> TypeDB.version(conn, opts) end}
    ]
  end

  # A `defdelegate` is the same function under another name, so its validation —
  # and therefore its error message — belongs to the function it forwards to.
  # Making a delegate name itself would mean hand-writing five wrappers to gain
  # nothing; the message still says exactly which function rejected the option.
  @delegated_to %{
    "TypeDB.databases/2" => "TypeDB.Database.list/2",
    "TypeDB.create_database/3" => "TypeDB.Database.create/3",
    "TypeDB.delete_database/3" => "TypeDB.Database.delete/3",
    "TypeDB.health/2" => "TypeDB.Server.health/2",
    "TypeDB.version/2" => "TypeDB.Server.version/2"
  }

  defp named_in_message(name), do: Map.get(@delegated_to, name, name)

  setup %{conn: conn} do
    {:ok, tx} = Transaction.open(conn, "social", :read)
    {:ok, tx: tx}
  end

  test "a misspelled option raises, naming the option and the call", %{conn: conn, tx: tx} do
    for {name, _accepted, call} <- calls(conn, tx) do
      error = assert_raise(ArgumentError, fn -> call.(timout: 5_000) end)

      assert error.message =~ "unknown option :timout"
      assert error.message =~ named_in_message(name)
      # The accepted set is in the message, because the fix is to pick one of
      # them and a message that does not say what they are sends you to the docs.
      assert error.message =~ ":timeout"
    end
  end

  test "several unknown options are all named", %{conn: conn, tx: tx} do
    for {_name, _accepted, call} <- calls(conn, tx) do
      error = assert_raise(ArgumentError, fn -> call.(nope: 1, also_nope: 2) end)
      assert error.message =~ "unknown options :nope, :also_nope"
    end
  end

  test "every accepted option is accepted", %{conn: conn, tx: tx} do
    # The other half of the check: a list that rejects what the function
    # documents would be worse than no list at all.
    for {name, accepted, call} <- calls(conn, tx), option <- accepted do
      try do
        call.([{option, value_for(option)}])
      rescue
        error in ArgumentError ->
          flunk("#{name} rejected #{inspect(option)}, which it accepts: #{error.message}")
      end
    end
  end

  test "options that are not a keyword list are reported as such", %{conn: conn} do
    error =
      assert_raise(ArgumentError, fn ->
        TypeDB.query(conn, "social", "match $p isa person;", [:transaction_type])
      end)

    # A map — the other shape people reach for — is caught by the type checker
    # at compile time, and by the same clause at runtime where it cannot see it.
    assert error.message =~ "expects a keyword list"
  end

  describe "option values" do
    # The name of an option has been checked since 0.3.0 and its value was not,
    # so `answer_count_limit: 0` reached the server and came back as an empty
    # answer, while `-1` and `"10"` came back as `400 HSR2` — the request-parse
    # code, naming no option. `TypeDB.Config` had rejected all three since
    # 0.1.0. The two levels now agree.
    # `nil` is deliberately absent from every row: it means "unset" throughout
    # the driver, so `answer_count_limit: maybe_a_limit` keeps working. The
    # cross-check below is what noticed — `TypeDB.Config` accepts it too.
    @bad %{
      answer_count_limit: [0, -1, "10", 1.5],
      transaction_timeout_millis: [0, -1, "x"],
      schema_lock_acquire_timeout_millis: [0, -1, "x"],
      timeout: [0, -1, "x"],
      deadline: [0, -1, "x"],
      commit: [0, "true"],
      include_instance_types: [0, "true"],
      include_query_structure: [0, "true"]
    }

    @good %{
      answer_count_limit: [1, 10_000, nil],
      transaction_timeout_millis: [1, 60_000],
      schema_lock_acquire_timeout_millis: [1, 60_000],
      timeout: [1, 60_000, :infinity],
      deadline: [1, 60_000, :infinity],
      commit: [true, false],
      include_instance_types: [true, false],
      include_query_structure: [true, false]
    }

    test "a value the option cannot take raises, naming the option and the call", %{
      conn: conn,
      tx: tx
    } do
      for {name, accepted, call} <- calls(conn, tx),
          {option, values} <- @bad,
          option in accepted,
          value <- values do
        error = assert_raise(ArgumentError, fn -> call.([{option, value}]) end)

        assert error.message =~ "invalid #{inspect(option)} #{inspect(value)}"
        assert error.message =~ named_in_message(name)
      end
    end

    test "the values it can take are accepted", %{conn: conn, tx: tx} do
      for {name, accepted, call} <- calls(conn, tx),
          {option, values} <- @good,
          option in accepted,
          value <- values do
        try do
          call.([{option, value}])
        rescue
          error in ArgumentError ->
            flunk("#{name} rejected #{inspect(option)}: #{inspect(value)} — #{error.message}")
        end
      end
    end

    test "every constrained option is checked the same way TypeDB.Config checks it" do
      # The two live in different modules and would otherwise drift. Anything
      # `Config` rejects at start-up, a call rejects too.
      for {option, values} <- @bad, option in TypeDB.Config.known_options(), value <- values do
        assert {:error, %TypeDB.Error{kind: :config}} =
                 TypeDB.Config.new([{:url, "http://example.com"}, {:token, "t"}, {option, value}]),
               "TypeDB.Config accepts #{inspect(option)}: #{inspect(value)}, a call does not"
      end
    end
  end

  describe "an administrative call's own budget" do
    @describetag :slow

    # Accepting an option and forwarding it are different things, and only the
    # second is worth having. A socket that accepts the connection and never
    # answers puts the *receive* timeout — the one `:timeout` names — in the way,
    # where a refused or black-holed address would measure the connect timeout
    # instead and prove nothing about this.
    setup do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      accepter = spawn_link(fn -> accept_forever(listener) end)

      on_exit(fn ->
        Process.unlink(accepter)
        Process.exit(accepter, :kill)
        :gen_tcp.close(listener)
      end)

      name = :"silent_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:#{port}",
          token: "t",
          connect_timeout: 2_000,
          timeout: 8_000,
          max_retries: 0
        )

      {:ok, silent: name}
    end

    defp accept_forever(listener) do
      {:ok, _socket} = :gen_tcp.accept(listener)
      accept_forever(listener)
    end

    defp elapsed_ms(fun), do: fun |> :timer.tc() |> elem(0) |> div(1000)

    test "a per-call :timeout is shorter than the connection's", %{silent: conn} do
      # The connection would wait eight seconds. Measured rather than asserted
      # about, because "the option is accepted" was true before this change too.
      assert elapsed_ms(fn -> TypeDB.Server.health(conn, timeout: 500) end) in 400..2_000
      assert elapsed_ms(fn -> TypeDB.Database.list(conn, timeout: 400) end) in 300..2_000
      assert elapsed_ms(fn -> TypeDB.User.list(conn, timeout: 400) end) in 300..2_000
    end

    test "a per-call :deadline bounds the whole call, delegates included", %{silent: conn} do
      assert elapsed_ms(fn -> TypeDB.databases(conn, deadline: 600) end) in 500..2_000
      assert elapsed_ms(fn -> TypeDB.health(conn, deadline: 600) end) in 500..2_000
    end
  end

  test "the accepted sets are the union of the driver's own keys and TypeDB.Options'" do
    # `TypeDB.Options` is where a new query or transaction option gets added,
    # and it is one module away from the lists here. This is the line that
    # fails when only one of the two has been updated.
    assert Enum.sort(CallOptions.query()) ==
             Enum.sort(
               [:transaction_type, :commit, :given_rows, :timeout, :deadline] ++
                 Options.query_keys() ++ Options.transaction_keys()
             )

    assert Enum.sort(CallOptions.transaction_query()) ==
             Enum.sort([:given_rows, :timeout, :deadline] ++ Options.query_keys())

    assert Enum.sort(CallOptions.open()) ==
             Enum.sort([:timeout, :deadline] ++ Options.transaction_keys())

    assert Enum.sort(CallOptions.request()) == [:deadline, :timeout]
  end

  test "every public function taking options validates them", %{conn: conn, tx: tx} do
    # The list in this file is hand-written, so it can fall behind the code. The
    # public surface cannot: anything with a trailing `opts` and no row above is
    # a function that accepts typos in silence.
    covered =
      calls(conn, tx)
      |> Enum.map(fn {name, _accepted, _call} -> name end)
      |> MapSet.new()

    takes_options =
      for module <- [TypeDB, Transaction, Database, User, Server],
          {function, arity} <- module.__info__(:functions),
          not String.starts_with?(Atom.to_string(function), "__"),
          # `start_link/1` and its two delegates take a keyword list too, and
          # `TypeDB.Config` has validated it since 0.1.0.
          function not in [:child_spec, :start_link, :stop],
          # `query_defaults/1` returns a keyword list rather than taking one.
          function != :query_defaults,
          takes_options?(module, function, arity),
          into: MapSet.new() do
        "#{inspect(module)}.#{function}/#{arity}"
      end

    # `!` twins delegate to the function they wrap, which is where the check is.
    takes_options = MapSet.reject(takes_options, &String.contains?(&1, "!"))

    assert MapSet.difference(takes_options, covered) |> MapSet.to_list() == []
  end

  # A `keyword()` *argument*, not a `keyword()` return — `query_defaults/1`
  # returns one and takes none, and would otherwise look like a function that
  # had been forgotten.
  defp takes_options?(module, function, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)

    case List.keyfind(specs, {function, arity}, 0) do
      {_key, [definition | _rest]} ->
        function
        |> Code.Typespec.spec_to_quoted(definition)
        |> arguments(function)
        |> Enum.any?(&(Macro.to_string(&1) =~ "keyword()"))

      nil ->
        false
    end
  end

  # `transaction/5`'s spec carries a `when result: term()`, so the quoted form
  # is wrapped in a `:when` that the other five do not have.
  defp arguments({:when, _meta, [spec, _guards]}, function), do: arguments(spec, function)
  defp arguments({:"::", _meta, [{function, _m, args}, _return]}, function), do: args || []

  defp value_for(:transaction_type), do: :read
  defp value_for(:commit), do: false
  defp value_for(:given_rows), do: nil
  defp value_for(:timeout), do: 5_000
  defp value_for(:deadline), do: 5_000
  defp value_for(:include_instance_types), do: true
  defp value_for(:include_query_structure), do: false
  defp value_for(:answer_count_limit), do: 10
  defp value_for(:transaction_timeout_millis), do: 5_000
  defp value_for(:schema_lock_acquire_timeout_millis), do: 5_000
end
