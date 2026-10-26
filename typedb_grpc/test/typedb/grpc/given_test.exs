defmodule TypeDB.GRPC.GivenTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `given` rows into protobuf, and every way that can fail.

  Each failure here must be a `TypeDB.Error` of kind `:encode`, raised while the
  request is built in the caller's process. Anything that slipped past this
  module would instead blow up while the transaction sends the request — in its
  own process, which is the crash the integration suite pins.
  """

  alias TypeDB.GRPC.Given
  alias Typedb.Protocol, as: Proto

  defp encode_error(rows) do
    error = assert_raise TypeDB.Error, fn -> Given.encode_rows(rows) end
    assert error.kind == :encode
    error
  end

  test "no rows is no given stage" do
    assert Given.encode_rows(nil) == nil
    assert Given.encode_rows([]) == nil
  end

  test "atom keys are accepted, as the sibling accepts them" do
    assert %Proto.Query.Req.GivenRows{variables: ["a", "n"]} = Given.encode_rows([%{n: "Alice", a: 1}])
  end

  test "a missing value is an empty entry" do
    assert %Proto.Query.Req.GivenRows{rows: [_, %Proto.Query.Req.GivenRow{entries: [empty]}]} =
             Given.encode_rows([%{"n" => "Alice"}, %{}])

    assert %Proto.Query.Req.GivenEntry{entry: {:empty, _}} = empty
  end

  test "rows that are not a list of maps are an :encode error" do
    encode_error(%{"n" => "Alice"})
    encode_error([:not_a_row])
    encode_error([%{"n" => "Alice"}, [n: "Bob"]])
  end

  test "a term with no TypeDB value is an :encode error" do
    assert encode_error([%{"n" => {:a, :tuple}}]).message =~ "no TypeDB value"
    encode_error([%{"n" => self()}])
  end

  test "an integer outside sint64 is an :encode error rather than a failure while sending" do
    assert %Proto.Query.Req.GivenRows{} = Given.encode_rows([%{"i" => 9_223_372_036_854_775_807}])
    encode_error([%{"i" => 9_223_372_036_854_775_808}])
    encode_error([%{"i" => -9_223_372_036_854_775_809}])
  end

  test "a string that is not UTF-8 is an :encode error" do
    assert encode_error([%{"s" => <<0xFF, 0xFE>>}]).message =~ "not valid UTF-8"
  end
end
