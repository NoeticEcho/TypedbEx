defmodule TypeDB.AnswerTruncationTest do
  use ExUnit.Case, async: true

  # `truncated?/1` is deliberately not a match against the notice's text: the
  # text belongs to the server, this driver's versioning does not cover it, and
  # a rephrasing would silently turn a caller's guard back into `false` — which
  # is the failure the function exists to prevent. Issue #1.
  #
  # `TypeDB.TruncationIntegrationTest` is the other half: it pins what the
  # server actually does, against every TypeDB in the matrix.

  alias TypeDB.Answer

  @notice "Read query results limit (10000) exceeded. Not all answers are returned."

  test "false when the server attached no warning" do
    refute Answer.truncated?(%Answer.Ok{query_type: :write})
    refute Answer.truncated?(%Answer.ConceptRows{query_type: :read, rows: []})
    refute Answer.truncated?(%Answer.ConceptDocuments{query_type: :read, documents: []})
  end

  test "true for every answer shape" do
    assert Answer.truncated?(%Answer.Ok{query_type: :write, warning: @notice})
    assert Answer.truncated?(%Answer.ConceptRows{query_type: :read, rows: [], warning: @notice})

    assert Answer.truncated?(%Answer.ConceptDocuments{
             query_type: :read,
             documents: [],
             warning: @notice
           })
  end

  test "a rephrased notice still reads as truncated" do
    # The point of not matching on the text. If TypeDB says it differently
    # tomorrow, a caller's guard must not quietly start answering false.
    rephrased = %Answer.ConceptRows{
      query_type: :read,
      rows: [],
      warning: "Result set capped at 10000; remaining answers were dropped."
    }

    assert Answer.truncated?(rephrased)
  end

  test "the row count is not consulted" do
    # Both directions, which is what makes `length(rows) == limit` unusable:
    # a complete answer can be exactly the size of the cap, and a truncated one
    # can be smaller than it.
    full = %Answer.ConceptRows{query_type: :read, rows: Enum.to_list(1..10_000)}
    refute Answer.truncated?(full)

    short = %Answer.ConceptRows{query_type: :read, rows: [1, 2], warning: @notice}
    assert Answer.truncated?(short)
  end
end
