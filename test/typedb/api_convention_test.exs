defmodule TypeDB.APIConventionTest do
  use TypeDB.Case, async: true

  # `TypeDB`'s moduledoc promises a `!` form for everything that can fail. That
  # promise went unkept for fifteen functions until someone read the docs and got
  # an UndefinedFunctionError. Derived from the specs rather than from a list, so
  # a new function joins this test by existing.
  @modules [TypeDB, TypeDB.Database, TypeDB.User, TypeDB.Server, TypeDB.Transaction]

  # `TypeDB.transaction/5` returns whatever the block returned, so its {:error, _}
  # is the caller's own value and may not be an exception at all. A bang variant
  # would have to guess whether to raise it; the block can raise for itself.
  @exempt [{TypeDB, :transaction, 5}]

  describe "the ! convention" do
    # `function_exported?/3` answers false for a module that has not been loaded
    # yet, and in the test VM they are loaded lazily — so the whole suite would
    # pass or fail on the seed without this.
    setup do
      Enum.each(@modules, &Code.ensure_loaded!/1)
      :ok
    end

    test "every function that can fail has a ! sibling" do
      missing =
        for module <- @modules,
            {{name, arity}, _spec} <- fallible_specs(module),
            {module, name, arity} not in @exempt,
            not function_exported?(module, :"#{name}!", arity),
            do: "#{inspect(module)}.#{name}/#{arity}"

      assert missing == [],
             "these can return {:error, _} but have no ! variant: #{Enum.join(missing, ", ")}"
    end

    test "the exemptions still name functions that exist" do
      for {module, name, arity} <- @exempt do
        assert function_exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} is exempt from the ! convention but does not exist"
      end
    end

    test "every ! function has a non-bang sibling" do
      orphans =
        for module <- @modules,
            {name, arity} <- module.__info__(:functions),
            String.ends_with?(Atom.to_string(name), "!"),
            plain = name |> Atom.to_string() |> String.trim_trailing("!") |> String.to_atom(),
            not function_exported?(module, plain, arity),
            do: "#{inspect(module)}.#{name}/#{arity}"

      assert orphans == []
    end

    test "a ! function raises the same TypeDB.Error its sibling returns", %{conn: conn} do
      assert {:error, %Error{code: "SRV4"} = error} = TypeDB.User.get(conn, "nobody")
      assert_raise Error, Exception.message(error), fn -> TypeDB.User.get!(conn, "nobody") end
    end

    test "a ! function returns the value, not the tuple", %{conn: conn} do
      assert {:ok, databases} = TypeDB.Database.list(conn)
      assert TypeDB.Database.list!(conn) == databases
      assert :ok = TypeDB.Server.health!(conn)
    end
  end

  describe "a value the caller could plausibly pass" do
    # CONTRIBUTING's "Failing: return or raise" ends with a rule this driver was
    # breaking fifteen times over:
    #
    #   Never a bare FunctionClauseError from a public function for a value a
    #   caller could plausibly pass. […] Add a clause that raises ArgumentError
    #   with the accepted values.
    #
    # A database name is the likeliest thing in this API to arrive from
    # configuration as nil or as an atom, and every function taking one answered
    # with `no function clause matching in TypeDB.Database.create/2` — which
    # names an internal clause and helps nobody.
    #
    # Derived from the specs, not from a list, so a new function joins by
    # existing. Every probe passes a bad value in a `String.t()` position and
    # valid values everywhere else, so each call raises in the guard and no
    # request is ever made.
    setup do
      Enum.each(@modules, &Code.ensure_loaded!/1)
      :ok
    end

    test "is rejected with ArgumentError, never FunctionClauseError", %{conn: conn} do
      {probes, unbuildable} = string_probes(conn)

      # A probe list that silently shrank would make this test pass by testing
      # nothing, so what could not be built is named rather than dropped.
      assert unbuildable == [],
             "could not build arguments for: #{Enum.join(unbuildable, ", ")}"

      assert length(probes) >= 15,
             "expected at least the fifteen known String.t() positions, got #{length(probes)}"

      bad =
        for {label, call} <- probes,
            error = raised_by(call),
            not is_struct(error, ArgumentError),
            do: "#{label} raised #{inspect(error.__struct__)}: #{Exception.message(error)}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "and the message says what was expected", %{conn: conn} do
      {probes, _} = string_probes(conn)

      for {label, call} <- probes do
        message = Exception.message(raised_by(call))

        assert message =~ "expected a string",
               "#{label} raised ArgumentError without saying what it wanted: #{message}"
      end
    end

    defp raised_by(call) do
      call.()
      flunk("the call did not raise")
    rescue
      error -> error
    end

    # Every `String.t()` parameter of every public function in @modules, each
    # paired with a call that puts a non-binary there.
    defp string_probes(conn) do
      tx = %TypeDB.Transaction{conn: conn, id: "probe", database: "social", type: :read}

      Enum.reduce(@modules, {[], []}, fn module, acc ->
        {:ok, specs} = Code.Typespec.fetch_specs(module)
        Enum.reduce(specs, acc, &probes_for(module, &1, conn, tx, &2))
      end)
    end

    defp probes_for(module, {{name, arity}, [definition | _]}, conn, tx, acc) do
      params = spec_params(name, definition)

      params
      |> Enum.with_index()
      |> Enum.filter(fn {param, _index} -> param == "String.t()" end)
      |> Enum.reduce(acc, fn {_param, index}, {probes, unbuildable} ->
        label = "#{inspect(module)}.#{name}/#{arity} argument #{index + 1}"

        case build_args(params, index, conn, tx) do
          {:ok, args} -> {[{label, fn -> apply(module, name, args) end} | probes], unbuildable}
          :error -> {probes, [label | unbuildable]}
        end
      end)
    end

    defp build_args(params, probe_index, conn, tx) do
      params
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {param, index}, {:ok, args} ->
        case argument(param, index == probe_index, conn, tx) do
          {:ok, value} -> {:cont, {:ok, [value | args]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, args} -> {:ok, Enum.reverse(args)}
        :error -> :error
      end
    end

    # `:not_a_string` rather than nil: an atom is what a database name read from
    # application config actually looks like when someone forgot to stringify it.
    defp argument("String.t()", true, _conn, _tx), do: {:ok, :not_a_string}
    defp argument("String.t()", false, _conn, _tx), do: {:ok, "probe"}
    defp argument("conn()", _probe?, conn, _tx), do: {:ok, conn}
    defp argument("TypeDB.Connection.t()", _probe?, conn, _tx), do: {:ok, conn}
    defp argument("t()", _probe?, _conn, tx), do: {:ok, tx}
    defp argument("TypeDB.Transaction.t()", _probe?, _conn, tx), do: {:ok, tx}
    defp argument("keyword()", _probe?, _conn, _tx), do: {:ok, []}
    defp argument("type()", _probe?, _conn, _tx), do: {:ok, :read}
    defp argument("TypeDB.Transaction.type()", _probe?, _conn, _tx), do: {:ok, :read}
    defp argument("(TypeDB.Transaction.t() -> result)", _probe?, _conn, _tx), do: {:ok, fn _tx -> :ok end}
    defp argument(_other, _probe?, _conn, _tx), do: :error

    # `transaction/5` carries a `when result: term()`, so its quoted spec is
    # wrapped in a `:when` the others do not have.
    defp spec_params(name, definition) do
      name
      |> Code.Typespec.spec_to_quoted(definition)
      |> unwrap_when()
      |> case do
        {:"::", _meta, [{^name, _m, args}, _return]} -> Enum.map(args || [], &Macro.to_string/1)
        _other -> []
      end
    end

    defp unwrap_when({:when, _meta, [spec, _guards]}), do: spec
    defp unwrap_when(spec), do: spec
  end

  describe "the TypeDB delegates" do
    # `TypeDB.version/1` was specced `{:ok, map()}` while `TypeDB.Server.version/1`
    # promised a concrete two-key map — so the convenience delegate was strictly
    # less useful than the thing it delegates to, and nothing noticed. A
    # defdelegate is the same function under another name; its spec should say
    # the same thing.
    @delegates [
      {TypeDB, :health, 1, TypeDB.Server, :health},
      {TypeDB, :health!, 1, TypeDB.Server, :health!},
      {TypeDB, :version, 1, TypeDB.Server, :version},
      {TypeDB, :version!, 1, TypeDB.Server, :version!},
      {TypeDB, :databases, 1, TypeDB.Database, :list},
      {TypeDB, :databases!, 1, TypeDB.Database, :list!},
      {TypeDB, :create_database, 2, TypeDB.Database, :create},
      {TypeDB, :create_database!, 2, TypeDB.Database, :create!},
      {TypeDB, :delete_database, 2, TypeDB.Database, :delete},
      {TypeDB, :delete_database!, 2, TypeDB.Database, :delete!}
    ]

    # Same hazard as the block above, and it bit here: `function_exported?/3`
    # answers false for a module the test VM has not loaded yet, so this passed
    # or failed on the seed. CI caught it on two of the four Elixir/OTP entries
    # once the adapter loop stopped being limited to the newest one.
    setup do
      for {module, _, _, target_module, _} <- @delegates do
        Code.ensure_loaded!(module)
        Code.ensure_loaded!(target_module)
      end

      :ok
    end

    test "each one's return type matches the function it delegates to" do
      mismatched =
        for {module, name, arity, target_module, target_name} <- @delegates,
            returns = return_type(module, name, arity),
            target_returns = return_type(target_module, target_name, arity),
            returns != target_returns,
            do:
              "#{inspect(module)}.#{name}/#{arity} returns #{returns}, but " <>
                "#{inspect(target_module)}.#{target_name}/#{arity} returns #{target_returns}"

      assert mismatched == [], Enum.join(mismatched, "\n")
    end

    test "every delegate in the list still exists" do
      for {module, name, arity, target_module, target_name} <- @delegates do
        assert function_exported?(module, name, arity)
        assert function_exported?(target_module, target_name, arity)
      end
    end

    # Compared as rendered text, with module qualifiers stripped: the same type
    # renders as `version()` when read from the module that defines it and
    # `TypeDB.Server.version()` when read from the module that refers to it, and
    # neither spelling is the interesting difference. `map()` versus `version()`
    # is.
    defp return_type(module, name, arity) do
      {:ok, specs} = Code.Typespec.fetch_specs(module)

      {_signature, [spec | _]} = Enum.find(specs, fn {sig, _} -> sig == {name, arity} end)

      name
      |> Code.Typespec.spec_to_quoted(spec)
      |> Macro.to_string()
      |> String.split("::", parts: 2)
      |> List.last()
      |> String.trim()
      |> String.replace(~r/(?:[A-Z][A-Za-z0-9_]*\.)+([a-z_][A-Za-z0-9_]*)\(/, "\\1(")
    end
  end

  describe "the raise-or-return rule" do
    # See "Failing: return or raise" in CONTRIBUTING. The part worth enforcing
    # mechanically is the last clause: a public function must never answer a
    # plausible bad value with a FunctionClauseError, which names an internal
    # clause and tells the caller nothing about what was expected.
    setup do
      stub = start_supervised!({TypeDB.Stub, []})
      name = :"convention_#{System.unique_integer([:positive])}"
      {:ok, _pid} = TypeDB.start_link(name: name, url: TypeDB.Stub.url(stub), token: "t")
      {:ok, conn: name}
    end

    test "an enum argument is rejected by name, not by clause", %{conn: conn} do
      # Computed so the compile-time type checker does not flag the bad calls.
      bad = String.to_atom("sideways")

      for call <- [
            fn -> TypeDB.Transaction.open(conn, "social", bad) end,
            fn -> TypeDB.query(conn, "social", "match $p isa person;", transaction_type: bad) end
          ] do
        error = assert_raise ArgumentError, call

        assert error.message =~ "sideways"
        assert error.message =~ ":read"
        assert error.message =~ ":write"
        assert error.message =~ ":schema"
      end
    end

    test "a value that cannot reach the wire raises TypeDB.Error, not ArgumentError" do
      # One `rescue TypeDB.Error` at a call site has to cover everything the
      # driver can throw on the way to the server.
      for call <- [
            fn -> TypeDB.Given.encode_rows([%{"n" => {:not, :encodable}}]) end,
            fn -> TypeDB.Duration.to_iso8601(%TypeDB.Duration{months: -1}) end
          ] do
        assert %Error{kind: :encode} = assert_raise(Error, call)
      end
    end
  end

  describe "Logger metadata" do
    # Credo's MissedMetadataKeyInLoggerConfig check used to guard this, but it
    # can only see literal `Logger.<level>` calls; every driver log line now
    # goes through `TypeDB.Log.log/4`, where the level is a runtime argument.
    # This is the replacement guard, and it checks the stronger property: that
    # the keys the code emits are exactly the keys the docs promise.
    test "the metadata keys the driver emits are the ones TypeDB documents" do
      emitted =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn file -> Regex.scan(~r/\b(typedb_[a-z_]+):/, File.read!(file)) end)
        |> Enum.map(fn [_match, key] -> key end)
        |> MapSet.new()

      documented =
        ~r/`:(typedb_[a-z_]+)`/
        |> Regex.scan(logging_section())
        |> Enum.map(fn [_match, key] -> key end)
        |> MapSet.new()

      assert MapSet.difference(emitted, documented) == MapSet.new(),
             "these metadata keys are emitted but not documented in the Logging section of TypeDB"

      assert MapSet.difference(documented, emitted) == MapSet.new(),
             "these metadata keys are documented but no longer emitted"
    end

    defp logging_section do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(TypeDB)

      [_before, logging] = String.split(moduledoc, "## Logging", parts: 2)
      [section | _rest] = String.split(logging, "\n  ## ", parts: 2)
      section
    end
  end

  # A spec whose return type mentions the atom :error — which, in this codebase,
  # means `{:error, TypeDB.Error.t()}`. Remote types such as `GenServer.on_start/0`
  # are opaque here and are therefore not treated as fallible, which is what we
  # want: `start_link/1` has no business raising.
  defp fallible_specs(module) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)

    for {{name, _arity} = signature, definitions} <- specs,
        not String.ends_with?(Atom.to_string(name), "!"),
        Enum.any?(definitions, &mentions_error?/1),
        do: {signature, definitions}
  end

  defp mentions_error?({:atom, _anno, :error}), do: true
  defp mentions_error?(term) when is_tuple(term), do: term |> Tuple.to_list() |> mentions_error?()
  defp mentions_error?(terms) when is_list(terms), do: Enum.any?(terms, &mentions_error?/1)
  defp mentions_error?(_term), do: false
end
