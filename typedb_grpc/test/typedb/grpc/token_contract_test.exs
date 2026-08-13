defmodule TypeDB.GRPC.TokenContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A guard on a deliberate piece of coupling.

  `TypeDB.GRPC.Connection` renews tokens proactively by reading their JWT
  lifetime through `TypeDB.Token`, which is `@moduledoc false` in the sibling
  package — internal on purpose, because *when* to renew is not a promise that
  package wants to make. Using it across the boundary is a choice this monorepo
  makes over keeping a second copy of the same parsing, and the cost of that
  choice is that a change over there could silently stop renewal over here.

  These assertions are that cost, paid. If they go red, the options are to
  follow the change or to vendor the twenty lines — but not to discover it from
  an application whose tokens started expiring mid-request.
  """

  test "the module the connection depends on is still there" do
    assert Code.ensure_loaded?(TypeDB.Token)
    assert function_exported?(TypeDB.Token, :lifetime_ms, 1)
  end

  test "it still reports a lifetime in milliseconds for a real TypeDB token" do
    # The shape a live 3.12.1 issues: HS256, with `iat` and `exp` five minutes
    # apart. Only the difference is used — both claims come from the server's
    # clock, so comparing either against ours would be meaningless.
    issued_at = 1_786_601_595
    expires_at = issued_at + 300

    token = jwt(%{"sub" => "admin", "iat" => issued_at, "exp" => expires_at})

    assert TypeDB.Token.lifetime_ms(token) == 300_000
  end

  test "it still answers :unknown rather than raising on something that is not a JWT" do
    # The connection treats :unknown as "renew reactively instead", which is
    # always correct and one round trip slower. A raise here would take down a
    # connection at sign-in.
    assert TypeDB.Token.lifetime_ms("not-a-jwt") == :unknown
    assert TypeDB.Token.lifetime_ms("") == :unknown
    assert TypeDB.Token.lifetime_ms("a.b.c") == :unknown
  end

  defp jwt(claims) do
    segment = fn map ->
      map |> JSON.encode!() |> Base.url_encode64(padding: false)
    end

    Enum.join(
      [segment.(%{"typ" => "JWT", "alg" => "HS256"}), segment.(claims), "signature-not-checked"],
      "."
    )
  end
end
