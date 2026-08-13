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

    test "nil is the same as nothing set" do
      assert Options.transaction_payload(nil) == nil
    end
  end

  # The two used to build their payloads by different routes for the same job,
  # and only one of them took defaults. They are one path now, so the same
  # inputs have to behave the same way on both.
  describe "the two payload builders agree" do
    for {label, payload, struct, key, wire} <- [
          {"query", :query_payload, Options.Query, :answer_count_limit, "answerCountLimit"},
          {"transaction", :transaction_payload, Options.Transaction, :transaction_timeout_millis,
           "transactionTimeoutMillis"}
        ] do
      test "#{label}: defaults fill in what the caller did not set" do
        assert apply(Options, unquote(payload), [[], [{unquote(key), 7}]]) == %{unquote(wire) => 7}
      end

      test "#{label}: the caller's value wins over a default" do
        assert apply(Options, unquote(payload), [[{unquote(key), 1}], [{unquote(key), 7}]]) ==
                 %{unquote(wire) => 1}
      end

      test "#{label}: defaults apply to nil and to a struct too" do
        defaults = [{unquote(key), 7}]

        assert apply(Options, unquote(payload), [nil, defaults]) == %{unquote(wire) => 7}

        assert apply(Options, unquote(payload), [struct(unquote(struct)), defaults]) ==
                 %{unquote(wire) => 7}
      end

      test "#{label}: a struct and the equivalent keyword list produce the same payload" do
        from_struct = apply(Options, unquote(payload), [struct(unquote(struct), [{unquote(key), 3}]), []])
        from_list = apply(Options, unquote(payload), [[{unquote(key), 3}], []])

        assert from_struct == from_list
        assert from_struct == %{unquote(wire) => 3}
      end
    end
  end

  test "the two option sets do not overlap" do
    assert Options.query_keys() -- Options.transaction_keys() == Options.query_keys()
  end
end
