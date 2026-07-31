defmodule TypeDB.ErrorTest do
  use ExUnit.Case, async: true

  alias TypeDB.Error

  describe "from_response/2" do
    test "decodes a TypeDB error body" do
      error = Error.from_response(400, %{"code" => "TSV9", "message" => "Query failed."})

      assert error.kind == :server
      assert error.code == "TSV9"
      assert error.status == 400
      assert error.message == "Query failed."
    end

    test "401 is unauthenticated regardless of code" do
      assert %Error{kind: :unauthenticated} =
               Error.from_response(401, %{"code" => "AUT3", "message" => "Invalid token supplied."})
    end

    test "an AUT code is unauthenticated regardless of status" do
      assert %Error{kind: :unauthenticated} =
               Error.from_response(403, %{"code" => "AUT4", "message" => "Corrupted accessor."})
    end

    test "408 is a timeout" do
      assert %Error{kind: :timeout} =
               Error.from_response(408, %{"code" => "TSV18", "message" => "Timed out."})
    end

    test "a body that is not a TypeDB error is preserved verbatim" do
      error = Error.from_response(502, "<html>bad gateway</html>")

      assert error.kind == :server
      assert error.code == nil
      assert error.status == 502
      assert error.body == "<html>bad gateway</html>"
      assert error.message =~ "HTTP 502"
    end

    test "a JSON body without the expected keys is preserved" do
      error = Error.from_response(500, %{"unexpected" => true})
      assert error.body == %{"unexpected" => true}
    end
  end

  describe "message/1" do
    test "includes the kind and code" do
      error = Error.new(:server, "Query failed.", code: "TSV9")
      assert Exception.message(error) == "[server] TSV9: Query failed."
    end

    test "omits an absent code" do
      error = Error.new(:transport, "connection refused")
      assert Exception.message(error) == "[transport] connection refused"
    end
  end

  test "is raisable" do
    assert_raise Error, "[config] nope", fn -> raise Error.new(:config, "nope") end
  end
end
