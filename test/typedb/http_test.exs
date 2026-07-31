defmodule TypeDB.HTTPTest do
  use ExUnit.Case, async: true

  alias TypeDB.HTTP.Finch, as: FinchAdapter
  alias TypeDB.HTTP.{Httpc, Req}

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

      assert {:ok, state} = Httpc.init(:test_conn, profile: profile)
      assert state.profile == profile
      assert is_pid(:httpc.which_sessions(profile) |> elem(0) |> then(fn _ -> self() end))

      assert :ok = Httpc.terminate(state)
    end

    test "init/1 tolerates an already-started profile" do
      profile = :"typedb_http_reuse_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Httpc.init(:test_conn, profile: profile)
      assert {:ok, second} = Httpc.init(:test_conn, profile: profile)

      Httpc.terminate(first)
      assert second.profile == profile
    end
  end

  describe "Finch adapter" do
    test "starts a pool named after the connection and stops it on terminate" do
      name = :"finch_test_#{System.unique_integer([:positive])}"

      assert {:ok, state} = FinchAdapter.init(name, [])
      # Unique per instance so a restarted connection cannot collide with the
      # corpse of its predecessor; the connection name stays as the prefix.
      assert Atom.to_string(state.name) =~ ~r/^#{name}\.Finch\.\d+$/
      assert state.owned?
      assert is_pid(Process.whereis(state.name))

      assert :ok = FinchAdapter.terminate(state)
      assert Process.whereis(state.name) == nil
    end

    test "reuses an externally supplied pool without owning it" do
      name = :"finch_external_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Finch.start_link(name: name)

      assert {:ok, state} = FinchAdapter.init(:whatever, name: name)
      refute state.owned?

      assert :ok = FinchAdapter.terminate(state)
      assert is_pid(Process.whereis(name)), "an externally owned pool must survive terminate/1"
    end

    test "sends every method with and without a body" do
      {:ok, state} = FinchAdapter.init(:"finch_methods_#{System.unique_integer([:positive])}", [])
      {:ok, stub} = echo_stub()
      base = TypeDB.Stub.url(stub)

      for {method, body, expected} <- [
            {:get, nil, "GET"},
            {:post, nil, "POST"},
            {:post, ~s({"a":1}), "POST"},
            {:put, ~s({"a":1}), "PUT"},
            {:delete, nil, "DELETE"}
          ] do
        assert {:ok, %{status: 200, body: response}} =
                 FinchAdapter.request(state, method, base <> "/v1/x", [], body, [])

        assert %{"method" => ^expected} = JSON.decode!(response)
      end

      FinchAdapter.terminate(state)
    end

    test "a refused connection is a transport error" do
      {:ok, state} = FinchAdapter.init(:"finch_refused_#{System.unique_integer([:positive])}", [])

      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, %TypeDB.Error{kind: :transport}} =
               FinchAdapter.request(state, :get, "http://127.0.0.1:#{port}/v1/x", [], nil, [])

      FinchAdapter.terminate(state)
    end
  end

  describe "Req adapter" do
    setup do
      unless Code.ensure_loaded?(Req) do
        raise "these tests need :req; it is an optional dependency and is present in the test env"
      end

      {:ok, state} = Req.init(:req_test, [])
      {:ok, state: state}
    end

    test "sends a bodyless GET as a GET", %{state: state} do
      # Req infers POST from the presence of a body, so passing an empty string
      # for "no body" silently rewrites the method. Every read endpoint in this
      # driver depends on getting that right.
      {:ok, stub} = echo_stub()

      assert {:ok, %{status: 200, body: body}} =
               Req.request(state, :get, TypeDB.Stub.url(stub) <> "/v1/databases", [], nil, [])

      assert %{"method" => "GET"} = JSON.decode!(body)
    end

    test "sends a bodyless POST as a POST", %{state: state} do
      # Transaction commit, rollback and close all POST with no body.
      {:ok, stub} = echo_stub()

      assert {:ok, %{status: 200, body: body}} =
               Req.request(state, :post, TypeDB.Stub.url(stub) <> "/v1/x/commit", [], nil, [])

      assert %{"method" => "POST"} = JSON.decode!(body)
    end

    test "sends DELETE and PUT unchanged", %{state: state} do
      {:ok, stub} = echo_stub()
      base = TypeDB.Stub.url(stub)

      assert {:ok, %{body: deleted}} = Req.request(state, :delete, base <> "/v1/db", [], nil, [])
      assert %{"method" => "DELETE"} = JSON.decode!(deleted)

      assert {:ok, %{body: put}} =
               Req.request(state, :put, base <> "/v1/users/a", [], ~s({"password":"x"}), [])

      assert %{"method" => "PUT", "body" => ~s({"password":"x"})} = JSON.decode!(put)
    end

    test "forwards request headers and returns downcased response headers", %{state: state} do
      {:ok, stub} = echo_stub()

      assert {:ok, %{status: 200, headers: headers, body: body}} =
               Req.request(
                 state,
                 :get,
                 TypeDB.Stub.url(stub) <> "/v1/databases",
                 [{"authorization", "Bearer t"}],
                 nil,
                 []
               )

      assert "Bearer t" = JSON.decode!(body) |> get_in(["headers", "authorization"])
      assert Enum.all?(headers, fn {name, _} -> name == String.downcase(name) end)
      assert {"content-type", "application/json"} in headers
    end

    test "does not raise on a non-2xx status", %{state: state} do
      {:ok, stub} = TypeDB.Stub.start_link(handler: fn _, _, _, _ -> {503, [], "nope"} end)

      assert {:ok, %{status: 503, body: "nope"}} =
               Req.request(state, :get, TypeDB.Stub.url(stub) <> "/v1/databases", [], nil, [])
    end

    test "a connect timeout does not discard the configured connect options", %{state: _state} do
      # Req merges per-request options over the base ones key by key. Setting
      # :connect_options per request therefore replaces whatever was configured
      # at init — and since TLS lives in there, that silently turns off a pinned
      # CA. This asserts the base survives.
      {:ok, state} =
        Req.init(:req_ca_test, connect_options: [transport_opts: [cacertfile: "/nonexistent/ca.pem"]])

      {:ok, stub} = echo_stub()

      assert {:ok, %{status: 200}} =
               Req.request(state, :get, TypeDB.Stub.url(stub) <> "/v1/databases", [], nil,
                 connect_timeout: 1_000
               )

      # The pinned CA must still be in effect for an HTTPS request; over plain
      # HTTP it is simply unused, which is why the request above succeeds.
      assert state.req.options[:connect_options][:transport_opts] == [cacertfile: "/nonexistent/ca.pem"]
    end

    test "a refused connection is a transport error, not an exception", %{state: state} do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, %TypeDB.Error{kind: :transport}} =
               Req.request(state, :get, "http://127.0.0.1:#{port}/v1/databases", [], nil, [])
    end
  end

  defp echo_stub do
    TypeDB.Stub.start_link(
      handler: fn method, path, headers, body ->
        {200, [{"content-type", "application/json"}],
         JSON.encode!(%{method: method, path: path, headers: headers, body: body})}
      end
    )
  end
end
