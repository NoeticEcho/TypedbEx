defmodule TypeDB.GRPC.APIConventionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The convention `CLAUDE.md` states — every failing operation returns
  `{:error, %TypeDB.Error{}}` and has a `!` twin that raises — checked
  mechanically, because it is the kind of rule that decays the moment somebody
  adds a function in a hurry.

  Audit V found this package with thirty functions returning `{:error, _}` and
  two twins. This test is what stops that recurring; the sibling has had one
  since 0.1.0.
  """

  @modules [
    TypeDB.GRPC,
    TypeDB.GRPC.Database,
    TypeDB.GRPC.Server,
    TypeDB.GRPC.Transaction,
    TypeDB.GRPC.User
  ]

  # Plumbing rather than API. `Connection` is the extension point a custom
  # caller drives, and the sibling exempts its `request/4` for the same reason:
  # a `!` twin there would be raising on behalf of code that is already deciding
  # how to handle failure. Recorded here rather than left implicit, so that
  # adding to the list is a visible act.
  @exempt %{
    TypeDB.GRPC => [
      # Returns whatever the block returns, so there is nothing to unwrap.
      transaction: 5,
      # Already raises; a stream cannot hand back an error tuple lazily.
      stream: 4
    ],
    TypeDB.GRPC.Transaction => [
      transaction: 5,
      stream: 3,
      # `@doc false` primitives the Stream is built on.
      stream_start: 3,
      stream_next: 3,
      stream_cancel: 2
    ]
  }

  defp returns_error?(module, name, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)

    case List.keyfind(specs, {name, arity}, 0) do
      nil -> false
      {_, definitions} -> Enum.any?(definitions, &mentions_error?(name, &1))
    end
  end

  defp mentions_error?(name, definition) do
    name
    |> Code.Typespec.spec_to_quoted(definition)
    |> Macro.to_string()
    |> String.contains?("{:error, ")
  end

  # Everything else under the namespace is plumbing an application does not
  # call, a value type with nothing that can fail, or test support — `Case` is
  # compiled only in `:test`, which is the only environment this runs in.
  # `Migration` is the file format behind `Database.export_to_files/5` — bytes
  # in and bytes out, with no operation of its own for a `!` twin to wrap.
  @not_api ~w(Bang Telemetry Protocol Config Connection Decode Error Case Migration)

  defp public_api?(module) do
    case inspect(module) do
      "TypeDB.GRPC." <> rest -> rest not in @not_api
      "TypeDB.GRPC" -> true
      _ -> false
    end
  end

  defp exported(module) do
    module.__info__(:functions)
    |> Enum.map(fn {name, arity} -> {name, arity} end)
  end

  test "every module in the public surface is listed here" do
    # A new module that nobody added would otherwise be checked by nothing.
    {:ok, modules} = :application.get_key(:typedb_grpc, :modules)

    public = Enum.filter(modules, &public_api?/1)

    assert Enum.sort(public) == Enum.sort(@modules), """
    The set of modules with a public, failing API has changed.

    Add the new one to @modules so its `!` twins are checked, or to the
    exemption list above with a reason.
    """
  end

  for module <- @modules do
    test "#{inspect(module)}: every failing function has a ! twin" do
      module = unquote(module)
      exempt = Map.get(@exempt, module, [])
      functions = exported(module)

      missing =
        for {name, arity} <- functions,
            not String.ends_with?(Atom.to_string(name), "!"),
            not String.starts_with?(Atom.to_string(name), "__"),
            {name, arity} not in exempt,
            returns_error?(module, name, arity),
            {:"#{name}!", arity} not in functions,
            do: "#{name}/#{arity}"

      assert missing == [], """
      #{inspect(module)} has functions that can fail and have no `!` twin:

        #{Enum.join(missing, "\n  ")}

      Either add the twin — `def name!(args), do: unwrap!(name(args))` — or add
      the function to @exempt with a reason.
      """
    end

    test "#{inspect(module)}: every ! twin has a plain counterpart" do
      module = unquote(module)
      functions = exported(module)

      orphans =
        for {name, arity} <- functions,
            String.ends_with?(Atom.to_string(name), "!"),
            plain = String.trim_trailing(Atom.to_string(name), "!"),
            {String.to_atom(plain), arity} not in functions,
            do: "#{name}/#{arity}"

      assert orphans == [], "#{inspect(module)} has ! functions with no plain twin: #{inspect(orphans)}"
    end
  end
end
