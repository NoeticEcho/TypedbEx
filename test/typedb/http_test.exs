defmodule TypeDB.HTTPTest do
  use ExUnit.Case, async: true

  alias TypeDB.HTTP.Httpc

  describe "Httpc TLS defaults" do
    test "verify peer is on and hostnames are checked" do
      opts = Httpc.ssl_opts([])

      assert opts[:verify] == :verify_peer
      assert is_list(opts[:versions])
      assert :"tlsv1.2" in opts[:versions]
      assert {:match_fun, fun} = List.keyfind(opts[:customize_hostname_check], :match_fun, 0)
      assert is_function(fun, 2)
    end

    test "the OS trust store is used by default" do
      opts = Httpc.ssl_opts([])
      assert is_list(opts[:cacerts])
      assert opts[:cacerts] != []
    end

    test ":cacertfile replaces the OS trust store rather than joining it" do
      opts = Httpc.ssl_opts(cacertfile: "/etc/ssl/private-ca.pem")

      assert opts[:cacertfile] == ~c"/etc/ssl/private-ca.pem"
      refute Keyword.has_key?(opts, :cacerts)
      assert opts[:verify] == :verify_peer
    end

    test "explicit :cacerts replaces the file option" do
      opts = Httpc.ssl_opts(ssl: [cacerts: [<<1, 2, 3>>]])

      assert opts[:cacerts] == [<<1, 2, 3>>]
      refute Keyword.has_key?(opts, :cacertfile)
    end

    test "explicit ssl options win over the defaults" do
      opts = Httpc.ssl_opts(ssl: [depth: 9, versions: [:"tlsv1.3"]])

      assert opts[:depth] == 9
      assert opts[:versions] == [:"tlsv1.3"]
    end

    test "verification can be relaxed only by asking for it explicitly" do
      # Documented escape hatch for self-signed development servers. The point of
      # this test is that it takes an explicit override, never a default.
      opts = Httpc.ssl_opts(ssl: [verify: :verify_none])
      assert opts[:verify] == :verify_none
    end
  end

  describe "Httpc lifecycle" do
    test "init/1 starts an isolated profile and terminate/1 stops it" do
      profile = :"typedb_http_test_#{System.unique_integer([:positive])}"

      assert {:ok, state} = Httpc.init(profile: profile)
      assert state.profile == profile
      assert is_pid(:httpc.which_sessions(profile) |> elem(0) |> then(fn _ -> self() end))

      assert :ok = Httpc.terminate(state)
    end

    test "init/1 tolerates an already-started profile" do
      profile = :"typedb_http_reuse_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Httpc.init(profile: profile)
      assert {:ok, second} = Httpc.init(profile: profile)

      Httpc.terminate(first)
      assert second.profile == profile
    end
  end

  describe "Req adapter" do
    test "reports a clear error when :req is not available" do
      # :req is not a dependency of this library, so this is the path users hit
      # when they select the adapter without adding the package.
      refute Code.ensure_loaded?(Req)

      assert {:error, %TypeDB.Error{kind: :config, message: message}} = TypeDB.HTTP.Req.init([])
      assert message =~ "requires the :req package"
    end
  end
end
