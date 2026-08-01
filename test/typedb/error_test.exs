defmodule TypeDB.ErrorTest do
  use ExUnit.Case, async: true

  alias TypeDB.Error

  doctest TypeDB.Error

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

  describe "retryable?/1" do
    test "transport and timeout failures are worth another go" do
      assert Error.retryable?(Error.new(:transport, "econnrefused"))
      assert Error.retryable?(Error.new(:timeout, "took too long"))
    end

    test "a server status that means 'not now' is retryable" do
      for status <- Error.retryable_statuses() do
        assert Error.retryable?(Error.new(:server, "nope", status: status)), "status #{status}"
      end
    end

    test "a server status that means 'no' is not" do
      for status <- [400, 401, 403, 404, 409, 422, 500] do
        refute Error.retryable?(Error.new(:server, "nope", status: status)), "status #{status}"
      end
    end

    test "the kinds that describe something permanently wrong are not" do
      for kind <- [:unauthenticated, :decode, :encode, :config] do
        refute Error.retryable?(Error.new(kind, "nope")), "kind #{kind}"
      end
    end

    test "every kind has an answer" do
      # A new :kind that nobody thought about here would otherwise raise
      # FunctionClauseError from inside a caller's retry loop.
      # Asserted, so that a kinds/0 that silently returned [] would fail here
      # rather than pass vacuously.
      assert length(kinds()) >= 7

      for kind <- kinds() do
        assert is_boolean(Error.retryable?(Error.new(kind, "x")))
      end
    end

    test "retryable_statuses/0 is what :retry_on_status defaults to" do
      # Two lists that must agree, in one place, or the predicate would answer
      # for a policy the driver does not actually apply.
      assert TypeDB.Config.new!(token: "t").retry_on_status == Error.retryable_statuses()
    end

    defp kinds do
      {:ok, types} = Code.Typespec.fetch_types(TypeDB.Error)
      {:type, {:kind, definition, _args}} = Enum.find(types, &match?({:type, {:kind, _, _}}, &1))
      {:type, _line, :union, members} = definition
      Enum.map(members, fn {:atom, _line, kind} -> kind end)
    end
  end
end
