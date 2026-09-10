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

  describe "keepalive" do
    # Measured 10.09.2026 against a TypeDB Cloud cluster from another host: a fully
    # handshaken HTTP/2 connection that says nothing is closed by the far end at 59.0 s
    # on 1729, 59.1 on 443 and 60.0 on 80 — the gRPC port included, so it is the
    # cluster's edge and not the HTTP API. Sixty seconds is the documented default idle
    # timeout of nginx, AWS ALB and HAProxy alike. The same connection, sent a PING every
    # 20 s, was still open at 119 s.
    #
    # What it is NOT is TypeDB's own timeout: the HTTP API answers an execution timeout
    # with 408 and the transaction lifetime defaults to five minutes, while this arrives
    # as a bare socket close with no status of any kind.
    test "is on by default, because the transport's default is off" do
      config = Config.new!(name: :c, address: "h:1", username: "u", password: "p")

      assert config.keepalive == 20_000
      assert config.keepalive_tolerance == 3
    end

    test "and a tolerance always comes with it" do
      # Not a nicety. gun reads the tolerance with `map_get/2`, which raises on a missing
      # key, and `gun_http2:init/4` gives it no default — it only defaults the two window
      # sizes. Nothing reaches that line today because `default_keepalive()` is
      # `infinity`, so a keepalive set without a tolerance takes the connection process
      # down with `{badkey, keepalive_tolerance}` on its first tick. A sixty-second
      # problem traded for an immediate one.
      for ms <- [1, 20_000, 3_600_000] do
        config = Config.new!(name: :c, address: "h:1", username: "u", password: "p", keepalive: ms)

        assert is_integer(config.keepalive_tolerance),
               "keepalive #{ms} left the tolerance unset, which raises inside gun"
      end
    end

    test "and it can be turned off, which is what :infinity means everywhere else here" do
      config =
        Config.new!(name: :c, address: "h:1", username: "u", password: "p", keepalive: :infinity)

      assert config.keepalive == :infinity
    end

    test "rejects a keepalive or a tolerance that is not one" do
      for {key, value} <- [
            keepalive: 0,
            keepalive: -1,
            keepalive: "20s",
            keepalive_tolerance: -1,
            keepalive_tolerance: "three"
          ] do
        assert {:error, %TypeDB.Error{kind: :config}} =
                 Config.new([name: :c, address: "h:1", username: "u", password: "p"] ++ [{key, value}]),
               "accepted #{key}: #{inspect(value)}"
      end
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

  describe "plaintext_to_remote?/1" do
    defp at(address, opts \\ []) do
      Config.new!(
        [
          name: :"plain_#{System.unique_integer([:positive])}",
          address: address,
          username: "admin",
          password: "password"
        ] ++ opts
      )
    end

    test "a local server is not a warning" do
      # A warning every local user sees is a warning nobody reads, and TypeDB CE
      # ships without encryption, so this is the ordinary case.
      refute Config.plaintext_to_remote?(at("127.0.0.1:1729"))
      refute Config.plaintext_to_remote?(at("localhost:1729"))
      refute Config.plaintext_to_remote?(at("127.0.0.2:1729"))
    end

    test "a server anywhere else, without TLS, is" do
      assert Config.plaintext_to_remote?(at("typedb.internal:1729"))
      assert Config.plaintext_to_remote?(at("10.0.0.5:1729"))
      assert Config.plaintext_to_remote?(at("192.168.1.10:1729"))
    end

    test "TLS settles it wherever the server is" do
      refute Config.plaintext_to_remote?(at("typedb.internal:1729", tls: true))
      refute Config.plaintext_to_remote?(at("10.0.0.5:1729", tls: true))
    end
  end
end
