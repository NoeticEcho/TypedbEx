defmodule TypeDB.APISnapshotTest do
  use ExUnit.Case, async: true

  # SemVer is otherwise a promise kept by attention. This renders the whole
  # public surface — modules, struct fields, types, callbacks and specs — into a
  # file that is checked in, so that changing the API means changing the
  # snapshot in the same commit, which is the moment to ask whether the change
  # is a minor or a major.
  #
  # It is not a style check. A failure is not necessarily wrong; it is a
  # question.

  @snapshot Path.expand("../api_snapshot.txt", __DIR__)

  # The snapshot is rendered by `Code.Typespec`, whose output is not stable
  # across Elixir versions — 1.18 renders `%TypeDB.Error{}`'s exception field as
  # `__exception__: true` where 1.20 renders `__exception__: term()`. Neither is
  # an API change, so comparing on every version in the matrix would report
  # Elixir upgrades as API breaks. One version is enough to notice a real one.
  @renders_the_snapshot ">= 1.20.0"

  unless Version.match?(System.version(), @renders_the_snapshot) do
    @moduletag skip:
                 "the API snapshot is rendered by Elixir #{@renders_the_snapshot}; " <>
                   "typespec rendering differs on older versions"
  end

  @regenerate """
  Regenerate with:

      TYPEDB_UPDATE_API_SNAPSHOT=1 mix test test/typedb/api_snapshot_test.exs

  then read the diff and decide what it means for the version number. See the
  "Versioning" section of CONTRIBUTING.md.
  """

  test "the public API matches the checked-in snapshot" do
    current = render()

    if System.get_env("TYPEDB_UPDATE_API_SNAPSHOT") == "1" do
      File.write!(@snapshot, current)
      IO.puts("\nRewrote #{Path.relative_to_cwd(@snapshot)}.")
    else
      # A Windows checkout rewrites the file to CRLF unless git is told
      # otherwise, and `render/0` builds LF. `.gitattributes` pins the file, but
      # normalising here as well means the test does not depend on the checkout
      # having been done with it. Found by the Windows job, whose report read
      # "recorded: ## Mix.Tasks.Typedb.Check / current: ## Mix.Tasks.Typedb.Check".
      recorded = @snapshot |> File.read!() |> String.replace("\r\n", "\n")

      assert current == recorded, """
      The public API no longer matches #{Path.relative_to_cwd(@snapshot)}.

      #{first_difference(recorded, current)}

      #{@regenerate}
      """
    end
  end

  # Only the first differing line, because the whole surface diffed is
  # unreadable and the snapshot file itself is the diff worth reading.
  defp first_difference(recorded, current) do
    recorded = String.split(recorded, "\n")
    current = String.split(current, "\n")

    [recorded, current]
    |> Enum.zip_reduce([], fn [a, b], acc -> [{a, b} | acc] end)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.find(fn {{a, b}, _line} -> a != b end)
    |> case do
      {{a, b}, line} -> "First difference, line #{line}:\n  recorded: #{a}\n  current:  #{b}"
      nil -> "The surface has #{length(current) - length(recorded)} more line(s) than recorded."
    end
  end

  test "every published module is filed under exactly one docs group" do
    # Otherwise a new module lands in an unnamed heap at the bottom of the
    # sidebar, which is how a reference page stops being a table of contents.
    grouped =
      Mix.Project.config()[:docs][:groups_for_modules]
      |> Enum.flat_map(fn {_group, modules} -> modules end)

    duplicated = grouped -- Enum.uniq(grouped)
    assert duplicated == [], "filed under more than one group: #{inspect(duplicated)}"

    published = public_modules()

    assert published -- grouped == [],
           "published but not filed under any docs group: #{inspect(published -- grouped)}"

    assert grouped -- published == [],
           "filed under a docs group but not published: #{inspect(grouped -- published)}"
  end

  defp render do
    public_modules()
    |> Enum.map_join("\n", &render_module/1)
  end

  defp public_modules do
    {:ok, modules} = :application.get_key(:typedb, :modules)

    modules
    |> Enum.filter(&published?/1)
    |> Enum.sort()
  end

  # "Public" is exactly what ex_doc publishes: a module hidden from the docs is
  # hidden from the promise too. That is what `@moduledoc false` means here.
  #
  # Test support is compiled into the application under MIX_ENV=test and is
  # documented, so it has to be excluded by where it came from rather than by
  # what it says about itself.
  defp published?(module) do
    Code.ensure_loaded!(module)

    with false <- test_support?(module),
         {:docs_v1, _anno, _lang, _format, doc, _meta, _docs} <- Code.fetch_docs(module) do
      doc != :hidden
    else
      _other -> false
    end
  end

  defp test_support?(module) do
    module.module_info(:compile)
    |> Keyword.get(:source, ~c"")
    |> to_string()
    # Windows reports `D:\a\TypedbEx\test\support\case.ex`, so the separator
    # has to be normalised before asking. Without this the whole of
    # `test/support` counted as public surface — which is how the Windows job
    # earned its keep on its first run.
    |> String.replace("\\", "/")
    |> String.contains?("/test/")
  end

  defp render_module(module) do
    sections =
      [
        render_struct(module),
        render_types(module),
        render_callbacks(module),
        render_functions(module)
      ]
      |> Enum.reject(&(&1 == []))

    "## #{inspect(module)}\n\n" <> Enum.map_join(sections, "\n", &Enum.join(&1, "\n")) <> "\n"
  end

  defp render_struct(module) do
    if function_exported?(module, :__struct__, 0) do
      fields = module.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()
      ["struct #{inspect(fields)}"]
    else
      []
    end
  end

  defp render_types(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    for {kind, type} <- types, kind in [:type, :opaque], into: [] do
      "@#{kind} " <> (type |> Code.Typespec.type_to_quoted() |> Macro.to_string())
    end
    |> Enum.sort()
  end

  defp render_callbacks(module) do
    case Code.Typespec.fetch_callbacks(module) do
      {:ok, callbacks} ->
        for {{name, _arity}, definitions} <- callbacks, definition <- definitions, into: [] do
          "@callback " <> (name |> Code.Typespec.spec_to_quoted(definition) |> Macro.to_string())
        end
        |> Enum.sort()

      :error ->
        []
    end
  end

  # The frozen promise is every line that does not carry @hidden_marker. A
  # `@doc false` function is compiled into the module and so is listed — an
  # appearance or a disappearance still fails the test — but it is not part of
  # the surface SemVer covers, and before 1.0 a reviewer has to be able to tell
  # the two apart by reading the file. Twice in one week a `@doc false` helper
  # turned the snapshot red and was restructured as if it had widened the API.
  @hidden_marker "    # @doc false"

  defp render_functions(module) do
    specs = specs(module)
    hidden = hidden_functions(module)

    for {name, arity} <- module.__info__(:functions),
        not String.starts_with?(Atom.to_string(name), "__"),
        into: [] do
      rendered =
        case Map.fetch(specs, {name, arity}) do
          {:ok, [rendered | _rest]} -> rendered
          :error -> "#{name}/#{arity}"
        end

      if MapSet.member?(hidden, {name, arity}), do: rendered <> @hidden_marker, else: rendered
    end
    |> Enum.sort()
  end

  # A function defined with default arguments has one doc entry, at its widest
  # arity, and `:defaults` says how many narrower heads it generated. Asking
  # only about the widest one would publish `TypeDB.query/2` while hiding
  # `TypeDB.query/3` — or the reverse — for no reason a reader could see.
  defp hidden_functions(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, _doc, _meta, docs} ->
        for {{:function, name, arity}, _anno, _signature, :hidden, meta} <- docs,
            defaults = Map.get(meta, :defaults, 0),
            generated <- (arity - defaults)..arity//1,
            into: MapSet.new() do
          {name, generated}
        end

      _other ->
        MapSet.new()
    end
  end

  defp specs(module) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)

    Map.new(specs, fn {{name, arity}, definitions} ->
      rendered =
        Enum.map(definitions, fn definition ->
          name |> Code.Typespec.spec_to_quoted(definition) |> Macro.to_string()
        end)

      {{name, arity}, rendered}
    end)
  end
end
