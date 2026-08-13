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
    test "includes the kind, the status and the code" do
      # All three, because this string is what reaches a log line and an exit
      # reason, where nobody has the struct in front of them to inspect.
      error = Error.new(:server, "Query failed.", code: "TSV9", status: 400)
      assert Exception.message(error) == "[server 400] TSV9: Query failed."
    end

    test "omits whatever is absent" do
      assert Exception.message(Error.new(:transport, "connection refused")) ==
               "[transport] connection refused"

      assert Exception.message(Error.new(:server, "gone", status: 404)) == "[server 404] gone"
      assert Exception.message(Error.new(:server, "nope", code: "TSV1")) == "[server] TSV1: nope"
    end

    test "a real server error carries the status a caller would otherwise have to guess" do
      error = Error.from_response(404, %{"code" => "TSV2", "message" => "Database not found."})
      assert Exception.message(error) == "[server 404] TSV2: Database not found."
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

    test "an isolation conflict is retryable despite its status" do
      # The case the function was written for, and the one it used to get wrong:
      # TypeDB rejects the loser of a concurrent write with a 400, which every
      # other time means "this will fail identically forever".
      assert Error.retryable?(Error.new(:server, "isolation conflict", code: "STC2", status: 400))
    end

    test "a vanished transaction is retryable despite its status" do
      # A transaction that expired, or that TypeDB discarded when a timeout made
      # the driver hang up. Nothing it wrote was committed, so re-running it is
      # the whole of the fix — but it arrives as a 404, which is otherwise the
      # driver's word for "this will not be there next time either".
      assert Error.retryable?(Error.new(:server, "no open transaction", code: "TSV12", status: 404))
    end

    test "every code on the list is retryable at the status it really arrives with" do
      # Guards against a code being added to the list while `retryable?/1` keeps
      # judging by status. The statuses are the ones measured against 3.12.1 in
      # test/integration/error_code_integration_test.exs.
      statuses = %{"STC2" => 400, "TSV12" => 404}

      for code <- Error.retryable_codes() do
        status = Map.fetch!(statuses, code)

        assert Error.retryable?(Error.new(:server, "nope", code: code, status: status)),
               "#{code} at #{status}"

        refute status in Error.retryable_statuses(),
               "#{code} would be retryable on its status alone, so this proves nothing"
      end
    end

    test "another 400 with a code is still not retryable" do
      refute Error.retryable?(Error.new(:server, "no such type", code: "INF2", status: 400))
    end

    test "another 404 with a code is still not retryable" do
      refute Error.retryable?(Error.new(:server, "no such database", code: "DBD1", status: 404))
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
