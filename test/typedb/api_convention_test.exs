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
