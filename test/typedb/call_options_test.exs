defmodule TypeDB.CallOptionsTest do
  use TypeDB.Case, async: true

  # An option key comes from the caller's own source. Accepting one the driver
  # has never heard of means silently applying the default instead, which is how
  # `given:` for `given_rows:` runs a query unparameterised and `commmit: false`
  # commits. `TypeDB.Config` has rejected unknown *connection* options since
  # 0.1.0 for the same reason; this is the rest of the surface.

  alias TypeDB.{CallOptions, Options}

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
      {"TypeDB.Transaction.close/2", CallOptions.request(), fn opts -> Transaction.close(tx, opts) end}
    ]
  end

  setup %{conn: conn} do
    {:ok, tx} = Transaction.open(conn, "social", :read)
    {:ok, tx: tx}
  end

  test "a misspelled option raises, naming the option and the call", %{conn: conn, tx: tx} do
    for {name, _accepted, call} <- calls(conn, tx) do
      error = assert_raise(ArgumentError, fn -> call.(timout: 5_000) end)

      assert error.message =~ "unknown option :timout"
      assert error.message =~ name
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
        assert error.message =~ name
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
      for module <- [TypeDB, Transaction],
          {function, arity} <- module.__info__(:functions),
          not String.starts_with?(Atom.to_string(function), "__"),
          # `start_link/1` and its two delegates take a keyword list too, and
          # `TypeDB.Config` has validated it since 0.1.0.
          function not in [:child_spec, :start_link, :stop],
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
