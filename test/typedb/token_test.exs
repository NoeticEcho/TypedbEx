defmodule TypeDB.TokenTest do
  use ExUnit.Case, async: true

  alias TypeDB.Token

  doctest TypeDB.Token

  defp jwt(claims) do
    encode = fn term -> term |> TypeDB.JSON.encode!() |> Base.url_encode64(padding: false) end
    encode.(%{"typ" => "JWT", "alg" => "HS256"}) <> "." <> encode.(claims) <> ".signature"
  end

  describe "lifetime_ms/1" do
    test "reads the lifetime from a TypeDB token" do
      # Shape taken from a live TypeDB 3.12.1 sign-in response.
      assert Token.lifetime_ms(jwt(%{"sub" => "admin", "iat" => 1_785_495_151, "exp" => 1_785_500_151})) ==
               5_000_000
    end

    test "uses only the difference, so the local clock is irrelevant" do
      far_past = jwt(%{"iat" => 1_000_000, "exp" => 1_000_060})
      far_future = jwt(%{"iat" => 9_000_000_000, "exp" => 9_000_000_060})

      assert Token.lifetime_ms(far_past) == 60_000
      assert Token.lifetime_ms(far_future) == 60_000
    end

    test "is :unknown for anything that is not a usable JWT" do
      for token <- [
            "not-a-jwt",
            "",
            "a.b",
            "a.b.c.d",
            "header.@@@notbase64@@@.sig",
            jwt(%{"sub" => "admin"}),
            jwt(%{"iat" => 1, "exp" => "later"}),
            jwt(%{"iat" => "now", "exp" => 2}),
            jwt(%{"iat" => 10, "exp" => 10}),
            jwt(%{"iat" => 20, "exp" => 10})
          ] do
        assert Token.lifetime_ms(token) == :unknown, "expected #{inspect(token)} to be unusable"
      end
    end

    test "is :unknown for a non-binary" do
      assert Token.lifetime_ms(nil) == :unknown
      assert Token.lifetime_ms(123) == :unknown
    end

    test "handles base64url padding of every length" do
      # Payload lengths cycle through all four padding cases.
      for subject <- ["a", "ab", "abc", "abcd", "abcde"] do
        token = jwt(%{"sub" => subject, "iat" => 0, "exp" => 30})
        assert Token.lifetime_ms(token) == 30_000
      end
    end
  end

  describe "subject/1" do
    test "reads the sub claim" do
      assert Token.subject(jwt(%{"sub" => "admin", "iat" => 0, "exp" => 30})) == "admin"
    end

    test "is nil when absent or unparseable" do
      assert Token.subject(jwt(%{"iat" => 0, "exp" => 30})) == nil
      assert Token.subject("not-a-jwt") == nil
      assert Token.subject(nil) == nil
    end
  end
end
