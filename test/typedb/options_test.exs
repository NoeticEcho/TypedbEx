defmodule TypeDB.OptionsTest do
  use ExUnit.Case, async: true

  alias TypeDB.Options

  describe "query_payload/1" do
    test "returns nil when nothing was set" do
      assert Options.query_payload([]) == nil
      assert Options.query_payload(nil) == nil
      assert Options.query_payload(%Options.Query{}) == nil
    end

    test "camelizes keys" do
      assert Options.query_payload(
               include_instance_types: true,
               answer_count_limit: 10,
               include_query_structure: false
             ) == %{
               "includeInstanceTypes" => true,
               "answerCountLimit" => 10,
               "includeQueryStructure" => false
             }
    end

    test "keeps false, which is a meaningful value" do
      assert Options.query_payload(include_instance_types: false) == %{"includeInstanceTypes" => false}
    end

    test "ignores unrelated keys" do
      assert Options.query_payload(answer_count_limit: 5, timeout: 1_000, banana: true) == %{
               "answerCountLimit" => 5
             }
    end

    test "accepts the struct form" do
      assert Options.query_payload(%Options.Query{answer_count_limit: 3}) == %{"answerCountLimit" => 3}
    end
  end

  describe "transaction_payload/1" do
    test "returns nil when nothing was set" do
      assert Options.transaction_payload([]) == nil
      assert Options.transaction_payload(%Options.Transaction{}) == nil
    end

    test "camelizes keys" do
      assert Options.transaction_payload(
               transaction_timeout_millis: 1_000,
               schema_lock_acquire_timeout_millis: 2_000
             ) == %{
               "transactionTimeoutMillis" => 1_000,
               "schemaLockAcquireTimeoutMillis" => 2_000
             }
    end

    test "does not pick up query options" do
      assert Options.transaction_payload(answer_count_limit: 5) == nil
    end
  end

  test "the two option sets do not overlap" do
    assert Options.query_keys() -- Options.transaction_keys() == Options.query_keys()
  end
end
