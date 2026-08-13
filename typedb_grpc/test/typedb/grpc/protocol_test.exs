defmodule TypeDB.GRPC.ProtocolTest do
  use ExUnit.Case, async: true

  doctest TypeDB.GRPC.Protocol

  alias TypeDB.GRPC.Protocol
  alias Typedb.Protocol.Options, as: QueryOptions

  test "the generated modules exist for the version claimed" do
    # A cheap guard against `lib/protocol` being deleted, half-generated, or
    # generated from something that is not TypeDB's schema: the version says
    # 3.12, so the service stub and the transaction messages that version
    # defines have to be loadable.
    assert Code.ensure_loaded?(Typedb.Protocol.TypeDB.Stub)
    assert Code.ensure_loaded?(Typedb.Protocol.Transaction.Req)
    assert Code.ensure_loaded?(Typedb.Protocol.Query.Req.GivenRows)
    assert Code.ensure_loaded?(Typedb.Protocol.Options.Query)
  end

  test "the answer count limit the HTTP API has is absent here" do
    # Not a trivia test. The absence of a cap is the main reason this package
    # exists, and it is a property of the schema rather than of this code — so
    # if a future protocol adds one, that is a design change to be noticed here
    # rather than discovered by an application whose reads start truncating.
    fields = QueryOptions.Query.__message_props__().field_props

    names = fields |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()

    assert names == ["include_instance_types", "include_query_structure", "prefetch_size"],
           """
           The query options in TypeDB's gRPC schema have changed.

           `prefetch_size` is a batch size, not a ceiling — the HTTP API's
           `answerCountLimit` has no counterpart here, which is why answers over
           this transport stream without a cap. If a limit has appeared, the
           README's claim needs revisiting.

           Now: #{inspect(names)}
           """
  end

  describe "compatible?/1" do
    test "a patch release of the same minor is compatible" do
      assert Protocol.compatible?(Protocol.version())
      assert Protocol.compatible?("3.12.99")
    end

    test "a different minor is not" do
      refute Protocol.compatible?("3.11.5")
      refute Protocol.compatible?("3.13.0")
      refute Protocol.compatible?("4.12.0")
    end
  end
end
