defmodule TypeDB.GRPC.ConfigTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The package had no unit tests for `Config`, which is its own small gap: it is
  the one module that can be exercised without a server, and it is where a
  misconfiguration should be caught.
  """

  alias TypeDB.GRPC.Config

  defp address(opts), do: Config.new!([name: :c, username: "u", password: "p"] ++ opts).address

  describe "the address" do
    test "is taken as given when it is one" do
      assert address(address: "127.0.0.1:1729") == "127.0.0.1:1729"
    end

    test "rejects a shape that is not host:port" do
      for bad <- ["localhost", "localhost:", ":1729", "localhost:0", "localhost:70000", "h:x"] do
        assert {:error, %TypeDB.Error{kind: :config}} =
                 Config.new(name: :c, username: "u", password: "p", address: bad),
               "accepted #{inspect(bad)}"
      end
    end
  end

  describe "a :url instead of an :address" do
    test "keeps a port the caller wrote" do
      assert address(url: "http://localhost:1729") == "localhost:1729"
      assert address(url: "typedb://example.com:1730") == "example.com:1730"
    end

    test "uses TypeDB's gRPC port when the caller wrote none" do
      # The scheme's default is what URI fills in, and 80 does not mean the
      # caller wants TypeDB on 80.
      assert address(url: "http://localhost") == "localhost:1729"
      assert address(url: "https://example.com") == "example.com:1729"
    end

    test "keeps 80 or 443 when the caller really wrote them" do
      assert address(url: "http://localhost:80") == "localhost:80"
      assert address(url: "https://example.com:443") == "example.com:443"
    end

    # The three shapes the old substring test got wrong. Each contains ":80"
    # somewhere that is not a port.
    test "a colon-number in the path is not a port" do
      assert address(url: "http://localhost/a:80") == "localhost:1729"
    end

    test "a colon-number in the userinfo is not a port" do
      assert address(url: "http://user:80@localhost") == "localhost:1729"
    end

    test "an IPv6 host is handled by its brackets, not by counting colons" do
      assert address(url: "http://[::1]:1729") == "::1:1729"
      assert address(url: "http://[::1]") == "::1:1729"
    end

    test "rejects something that is not a URL" do
      assert {:error, %TypeDB.Error{kind: :config}} =
               Config.new(name: :c, username: "u", password: "p", url: "not a url")
    end
  end

  describe "credentials" do
    test "needs both halves, or a token" do
      assert {:error, %TypeDB.Error{kind: :config}} =
               Config.new(name: :c, address: "h:1", username: "u")

      assert {:error, %TypeDB.Error{kind: :config}} = Config.new(name: :c, address: "h:1")
      assert %Config{} = Config.new!(name: :c, address: "h:1", token: "t")
    end
  end

  describe "the rest" do
    test "rejects an unknown option rather than ignoring it" do
      assert {:error, %TypeDB.Error{kind: :config}} =
               Config.new(name: :c, address: "h:1", username: "u", password: "p", tiemout: 5)
    end

    test "rejects a timeout that is not one" do
      for {key, value} <- [timeout: 0, call_timeout: -1, connect_timeout: "5s", connect_retries: -1] do
        assert {:error, %TypeDB.Error{kind: :config}} =
                 Config.new([name: :c, address: "h:1", username: "u", password: "p"] ++ [{key, value}]),
               "accepted #{key}: #{inspect(value)}"
      end
    end

    test "never renders the password" do
      config = Config.new!(name: :c, address: "h:1", username: "u", password: "hunter2")
      refute inspect(config) =~ "hunter2"
    end
  end
end
