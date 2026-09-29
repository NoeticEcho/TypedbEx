# The notebook renders a table through Kino, which is not a dependency of this
# project and never will be. Defining the one function it calls, under the name
# the notebook calls it by, lets that cell run exactly as written rather than be
# skipped or rewritten — and a stub that returns the row count keeps the cell's
# output meaningful in the log.
defmodule Kino.DataTable do
  @moduledoc false
  def new(rows), do: {:kino_data_table, Enum.count(rows)}
end

defmodule TypeDB.NotebookIntegrationTest do
  @moduledoc """
  Runs the published notebook's cells, in order, against a live server.

  `TypeDB.NotebookTest` checks that the notebook's code parses and that the
  version it installs exists. Neither catches the failure that matters, because
  the notebook is not a document — it is a program a stranger runs, advertised
  from the README with a "Run in Livebook" badge, and the first thing many
  people will do with this driver.

  Two things it caught the first time it ran, both of which had been published
  for releases:

    * `Mix.install/2` did not list `:finch`. Every HTTP adapter's dependency is
      optional, so without it `TypeDB.start_link/1` returns
      `{:error, %TypeDB.Error{kind: :config}}` and the second cell's
      `{:ok, _pid} = …` raises `MatchError`. The notebook was broken for
      everybody who ran it as written, and worked for everybody who tested it
      from inside this project, where `:finch` is already there.
    * The `to_struct/2` cell was itself the failure its own prose warned about:
      `match $p isa person, has name $name, has age $age;` binds `$p` too, and
      `Person` has no `:p` field, so `to_struct/2` raised.

  Cells share bindings, as they do in Livebook, so a failure in one is reported
  against that cell and the rest still run — which is how you find out whether
  one cell is wrong or the notebook is.

  What this file cannot check is the `Mix.install/2` cell, which it skips: the
  dependencies are already loaded here. That is the very blind spot that let the
  missing `:finch` ship — it runs inside a project where `:finch` is present, so
  no amount of running the notebook *here* would have noticed. That half is
  checked by `TypeDB.NotebookTest`, against the text of the declaration rather
  than by running it.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set; see `TypeDB.IntegrationTest`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @notebook Path.expand("../../notebooks/getting_started.livemd", __DIR__)

  test "every cell runs, in order, against a live server" do
    cells = elixir_cells()

    assert length(cells) > 10,
           "the extractor found #{length(cells)} cells; the notebook has more than that"

    {_bindings, failures} =
      cells
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, &run_cell/2)

    assert failures == [],
           "cells that did not run against #{url()}:\n\n" <>
             Enum.map_join(failures, "\n\n", fn {index, code, reason} ->
               "  cell #{index}: #{reason}\n#{indent(code)}"
             end)
  end

  # `Mix.install/2` is the one cell that cannot run here: the dependencies are
  # already loaded, and running it would try to resolve them again. What it
  # declares is checked by `TypeDB.NotebookTest` instead.
  defp run_cell({code, index}, {bindings, failures}) do
    if String.contains?(code, "Mix.install") do
      {bindings, failures}
    else
      {_value, bindings} = Code.eval_string(code, bindings, file: @notebook)
      {bindings, failures}
    end
  rescue
    exception ->
      {bindings, [{index, code, Exception.message(exception)} | failures]}
  catch
    kind, reason ->
      {bindings, [{index, code, "#{kind} #{inspect(reason, limit: 3)}"} | failures]}
  end

  defp url, do: System.fetch_env!("TYPEDB_INTEGRATION_URL")

  # The notebook hard-codes `http://localhost:8000` because that is what its
  # `docker run` line publishes. CI's server is at whatever
  # `TYPEDB_INTEGRATION_URL` says, so the URL is rebound here rather than the
  # notebook edited — the published text stays the text a reader runs.
  defp elixir_cells do
    source = @notebook |> File.read!() |> String.replace("\r\n", "\n")

    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.map(&String.replace(&1, "http://localhost:8000", url()))
  end

  defp indent(code) do
    code |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end
end
