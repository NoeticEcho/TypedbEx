defmodule Mix.Tasks.Typedb.Check do
  @shortdoc "Validates TypeQL files with the typeql-check CLI"

  @moduledoc """
  Statically validates TypeQL files, without a running TypeDB server.

      mix typedb.check
      mix typedb.check priv/typeql/schema.tql
      mix typedb.check "priv/**/*.tql" "test/fixtures/*.tql"

  With no arguments, every `**/*.tql` file under `priv/` is checked.

  This wraps TypeDB's `typeql-check` CLI, which parses a query and reports syntax
  errors. Install it first — see
  <https://typedb.com/docs/home/install/typeql-check/>:

      # macOS
      brew install typedb/tap/typeql-check

      # Linux
      sudo apt install typeql-check

  The task exits non-zero when any file fails to parse, so it drops straight into
  a CI pipeline. If `typeql-check` is not installed, the task says so and exits
  non-zero rather than silently passing.

  ## Options

    * `--binary PATH` — path to the `typeql-check` executable. Defaults to
      `typeql-check` on `PATH`, overridable with the `TYPEQL_CHECK` environment
      variable.
    * `--warn-only` — report problems but exit `0`.

  ## What it does and does not catch

  `typeql-check` validates *syntax*. It knows nothing about your schema, so an
  undefined type or a mistyped attribute still parses cleanly and will only fail
  when TypeDB runs it. Use `TypeDB.Transaction.analyze/3` against a real database
  for schema-aware checking.
  """

  use Mix.Task

  @switches [binary: :string, warn_only: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, patterns} = OptionParser.parse!(argv, strict: @switches)

    binary = opts[:binary] || System.get_env("TYPEQL_CHECK") || "typeql-check"
    patterns = if patterns == [], do: ["priv/**/*.tql"], else: patterns

    case System.find_executable(binary) do
      nil ->
        Mix.raise("""
        #{binary} was not found on your PATH.

        Install it with one of:

            brew install typedb/tap/typeql-check    # macOS
            sudo apt install typeql-check           # Linux

        See https://typedb.com/docs/home/install/typeql-check/ for other platforms,
        or pass --binary PATH.
        """)

      executable ->
        case expand(patterns) do
          [] ->
            Mix.shell().info("No TypeQL files matched #{Enum.join(patterns, ", ")}.")

          files ->
            files
            |> Enum.map(&check(executable, &1))
            |> report(opts[:warn_only] == true)
        end
    end
  end

  defp expand(patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp check(executable, file) do
    case System.cmd(executable, [File.read!(file)], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, file}
      {output, _status} -> {:error, file, String.trim(output)}
    end
  end

  defp report(results, warn_only?) do
    failures = for {:error, file, output} <- results, do: {file, output}

    Enum.each(failures, fn {file, output} ->
      Mix.shell().error("#{file}\n#{indent(output)}\n")
    end)

    checked = length(results)
    failed = length(failures)

    cond do
      failed == 0 ->
        Mix.shell().info("Checked #{checked} TypeQL #{pluralise(checked, "file")}, all valid.")

      warn_only? ->
        Mix.shell().error("#{failed} of #{checked} TypeQL files failed to parse.")

      true ->
        Mix.raise("#{failed} of #{checked} TypeQL files failed to parse.")
    end
  end

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"
end
