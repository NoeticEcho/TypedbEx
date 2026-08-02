defmodule TypeDB.TruncationIntegrationTest do
  @moduledoc """
  What TypeDB does when a read is bigger than its cap.

  Written for issue #1, reported by an application that holds a knowledge graph
  and reads a slice of it before every step. A slice that silently loses its
  tail does not fail: it produces a shorter book that is internally consistent,
  passes every downstream check, and reaches a reader. The failure has no
  symptom until somebody reads to the end.

  `TypeDB.Answer.truncated?/1` is the guard, and it is defined as "the server
  attached a warning" rather than as a match against the notice's text. That
  choice is only safe while somebody watches what the server actually warns
  about — which is this file, running against every TypeDB in the CI matrix. If
  TypeDB rephrases its notice, nothing here breaks. If it starts warning about
  something *other* than truncation, or stops warning at all, this goes red in
  this repository rather than going quiet in somebody's application.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set; see `TypeDB.IntegrationTest`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.{Answer, Database}

  @rows 8

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_truncation

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    Process.unlink(pid)

    database = "truncation_#{System.unique_integer([:positive])}"
    :ok = Database.create(name, database)

    {:ok, _} =
      TypeDB.query(name, database, "define attribute text, value string; entity sentence, owns text;")

    values = for i <- 1..@rows, do: %{"t" => "s#{i}"}

    {:ok, _} =
      TypeDB.query(
        name,
        database,
        "given $t: string; insert $s isa sentence, has text == $t;",
        transaction_type: :write,
        given_rows: values
      )

    on_exit(fn ->
      _ = Database.delete(name, database)

      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: name, database: database}
  end

  defp read(conn, database, opts) do
    {:ok, answer} =
      TypeDB.query(
        conn,
        database,
        "match $s isa sentence, has text $t; select $t;",
        [transaction_type: :read] ++ opts
      )

    answer
  end

  test "a read under the cap is not truncated", %{conn: conn, database: database} do
    answer = read(conn, database, answer_count_limit: @rows * 2)

    assert length(Answer.rows(answer)) == @rows
    refute Answer.truncated?(answer)
    assert Answer.warning(answer) == nil
  end

  test "a read over the cap is truncated", %{conn: conn, database: database} do
    answer = read(conn, database, answer_count_limit: 2)

    assert length(Answer.rows(answer)) == 2
    assert Answer.truncated?(answer)
    assert Answer.warning(answer) =~ "2"
  end

  # The case that makes `truncated?/1` worth having rather than being spelled
  # `length(rows) == limit` at the call site. TypeDB warns only when it really
  # had more, so a complete answer the exact size of the cap is *not* truncated
  # — and the count cannot tell the two apart.
  test "a read of exactly the cap, with nothing beyond it, is not truncated", %{
    conn: conn,
    database: database
  } do
    answer = read(conn, database, answer_count_limit: @rows)

    assert length(Answer.rows(answer)) == @rows,
           "the premise of this test is that the cap is exactly the row count"

    refute Answer.truncated?(answer),
           "a complete answer the size of the cap must not read as truncated — " <>
             "this is why the row count is not a usable signal"

    assert Answer.warning(answer) == nil
  end

  # A `limit` clause inside the query truncates below the cap, so the count is
  # not sufficient in the other direction either.
  test "a query's own limit does not make an answer truncated", %{conn: conn, database: database} do
    {:ok, answer} =
      TypeDB.query(conn, database, "match $s isa sentence, has text $t; select $t; limit 3;",
        transaction_type: :read
      )

    assert length(Answer.rows(answer)) == 3
    refute Answer.truncated?(answer), "the caller asked for three; that is not truncation"
  end

  test "documents truncate the same way rows do", %{conn: conn, database: database} do
    {:ok, answer} =
      TypeDB.query(conn, database, "match $s isa sentence, has text $t; fetch { 'text': $t };",
        transaction_type: :read,
        answer_count_limit: 2
      )

    assert %Answer.ConceptDocuments{} = answer
    assert length(Answer.documents(answer)) == 2
    assert Answer.truncated?(answer)
  end

  # The reason `truncated?/1` does not match on the text — and the reason this
  # file exists. The notice is the server's prose and this driver's versioning
  # does not cover it, so it is recorded here rather than depended on: when it
  # changes, this fails and somebody decides what it means, instead of a guard
  # somewhere quietly answering false.
  test "the notice TypeDB currently sends", %{conn: conn, database: database} do
    warning = read(conn, database, answer_count_limit: 2) |> Answer.warning()

    assert warning == "Read query results limit (2) exceeded. Not all answers are returned.",
           """
           TypeDB's truncation notice has changed. Nothing is broken — `truncated?/1`
           is defined by the warning's presence, not its text, which is why this is a
           failing assertion rather than a production incident. Update the expected
           string, and check that the server still warns for the same reasons.

           Now: #{inspect(warning)}
           """
  end
end
