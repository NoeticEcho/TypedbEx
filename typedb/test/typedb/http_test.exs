defmodule TypeDB.HTTPTest do
  use ExUnit.Case, async: true

  import TypeDB.Case, only: [assert_unreachable: 1]

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
    # `:inets` registers a profile's manager under this name, which is the only
    # answer to "is it still there" that does not start one by asking.
    defp profile_alive?(profile), do: Process.whereis(:"httpc_#{profile}") != nil

    test "a profile the adapter started is stopped with it" do
      assert {:ok, state} = Httpc.init(:test_conn, [])
      assert state.owned?
      assert profile_alive?(state.profile)

      assert :ok = Httpc.terminate(state)
      refute profile_alive?(state.profile)
    end

    test "a profile the caller named is left alone" do
      # `:profile` names a profile to *use*, not one to take over. An
      # application that runs its own — to share sockets, or because it carries
      # proxy settings — used to lose it when the TypeDB connection stopped, and
      # the breakage landed somewhere else entirely. `TypeDB.HTTP.Finch` has
      # drawn this line with `owned?` since 0.1.x; this adapter had no notion of
      # ownership at all.
      profile = :"typedb_borrowed_#{System.unique_integer([:positive])}"
      {:ok, _pid} = :inets.start(:httpc, [{:profile, profile}])
      on_exit(fn -> :inets.stop(:httpc, profile) end)

      assert {:ok, state} = Httpc.init(:test_conn, profile: profile)
      refute state.owned?

      assert :ok = Httpc.terminate(state)
      assert profile_alive?(profile), "the adapter stopped a profile it did not start"
    end

    test "each connection gets its own profile" do
      # Named per instance, as `TypeDB.HTTP.Finch` names its pool. Sharing one
      # meant the first connection to terminate took the other's transport down.
      assert {:ok, first} = Httpc.init(:same_name, [])
      assert {:ok, second} = Httpc.init(:same_name, [])
      on_exit(fn -> Enum.each([first, second], &Httpc.terminate/1) end)

      refute first.profile == second.profile

      assert :ok = Httpc.terminate(first)
      assert profile_alive?(second.profile), "one connection's shutdown broke a live sibling"
    end

    test "init/1 tolerates an already-started profile" do
      profile = :"typedb_http_reuse_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Httpc.init(:test_conn, profile: profile)
      assert {:ok, second} = Httpc.init(:test_conn, profile: profile)
      on_exit(fn -> :inets.stop(:httpc, profile) end)

      Httpc.terminate(first)
      assert second.profile == profile
      assert profile_alive?(profile)
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

      # The name registers Finch's *Registry*, not the supervisor that owns it,
      # so terminate/1 has to stop the pid start_link returned — stopping the
      # registry only gets it restarted.
      assert is_pid(state.supervisor)
      refute state.supervisor == Process.whereis(state.name)

      assert :ok = FinchAdapter.terminate(state)
      refute Process.alive?(state.supervisor)

      Process.sleep(50)
      assert Process.whereis(state.name) == nil, "the pool came back after terminate/1"
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

      assert_unreachable(FinchAdapter.request(state, :get, "http://127.0.0.1:#{port}/v1/x", [], nil, []))

      FinchAdapter.terminate(state)
    end
  end

  describe "optional dependencies" do
    # `:finch` and `:req` are optional, so this module must COMPILE for someone
    # who left them out — and a struct pattern like `%Finch.Response{}` is
    # expanded at compile time, which `@compile {:no_warn_undefined, ...}` does
    # not cover. Caught by building a consumer project with no finch: the whole
    # package failed to compile, which would have made "runs on OTP alone" false
    # in a worse way than before.
    test "no adapter pattern-matches a struct belonging to an optional dependency" do
      offenders =
        for file <- Path.wildcard("lib/typedb/http/*.ex"),
            {line, index} <- Enum.with_index(File.read!(file) |> String.split("\n"), 1),
            not String.starts_with?(String.trim(line), "#"),
            match = Regex.run(~r/%(Finch|Req|Decimal)(\.\w+)*\{/, line),
            do: "#{file}:#{index}: #{hd(match)}"

      assert offenders == [],
             "these expand an optional dependency's struct at compile time, so the module " <>
               "cannot compile without it:\n" <> Enum.join(offenders, "\n")
    end
  end

  describe "connect timeout" do
    defmodule RecordingAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(_name, opts) do
        send(opts[:test], {:adapter_opts, opts})
        {:ok, :state}
      end

      def request(_s, _m, url, _h, _b, _o) do
        {:error, TypeDB.Error.new(:transport, "not a real adapter: #{url}")}
      end
    end

    # A pool is built once, so this is the only moment the connection's
    # :connect_timeout can reach Mint — which reads it from transport_opts and
    # nowhere else.
    test "Finch turns the connection's :connect_timeout into the pool's transport_opts" do
      assert %{default: pool} = FinchAdapter.pools(connect_timeout: 1234)
      assert pool[:conn_opts][:transport_opts][:timeout] == 1234
    end

    test "a caller's own transport_opts timeout wins, and the rest of them survive" do
      opts = [
        connect_timeout: 1234,
        conn_opts: [transport_opts: [timeout: 99, cacertfile: "/etc/ssl/private-ca.pem"]]
      ]

      assert %{default: pool} = FinchAdapter.pools(opts)
      assert pool[:conn_opts][:transport_opts][:timeout] == 99
      assert pool[:conn_opts][:transport_opts][:cacertfile] == "/etc/ssl/private-ca.pem"
    end

    test "TLS options survive alongside an injected connect timeout" do
      opts = [connect_timeout: 1234, conn_opts: [transport_opts: [cacertfile: "/etc/ssl/private-ca.pem"]]]

      assert %{default: pool} = FinchAdapter.pools(opts)
      assert pool[:conn_opts][:transport_opts][:timeout] == 1234
      assert pool[:conn_opts][:transport_opts][:cacertfile] == "/etc/ssl/private-ca.pem"
    end

    test "an explicit :pools map is left exactly as given" do
      pools = %{"https://a.example" => [size: 2], default: [size: 1]}

      assert FinchAdapter.pools(connect_timeout: 1234, pools: pools) == pools
    end

    test "the connection injects :connect_timeout, and :http may override it" do
      name = :"ct_inject_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          connect_timeout: 777,
          http: {RecordingAdapter, [test: self()]}
        )

      assert_receive {:adapter_opts, opts}
      assert opts[:connect_timeout] == 777
      TypeDB.stop(pid)

      name = :"ct_override_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          connect_timeout: 777,
          http: {RecordingAdapter, [test: self(), connect_timeout: 5]}
        )

      assert_receive {:adapter_opts, opts}
      assert opts[:connect_timeout] == 5
      TypeDB.stop(pid)
    end

    test "Req drops the injected :connect_timeout instead of handing Req an option it rejects" do
      assert {:ok, %Req{}} = Req.init(:req_ct, connect_timeout: 1234)
    end

    @tag :slow
    test "every adapter gives up on a black hole within its budget, and calls it a timeout" do
      # 198.51.100.0/24 is TEST-NET-2: reserved for documentation, routed
      # nowhere, so the SYN is swallowed rather than refused.
      url = "http://198.51.100.1:8000/v1/health"
      budget = 1_000

      adapters = [
        {FinchAdapter, :"finch_blackhole_#{System.unique_integer([:positive])}", [connect_timeout: budget]},
        {Req, :req_blackhole, []},
        {Httpc, :"httpc_blackhole_#{System.unique_integer([:positive])}", []}
      ]

      for {adapter, name, init_opts} <- adapters do
        {:ok, state} = adapter.init(name, init_opts)

        {elapsed, result} =
          :timer.tc(fn ->
            adapter.request(state, :get, url, [], nil, timeout: 30_000, connect_timeout: budget)
          end)

        elapsed = div(elapsed, 1000)

        assert {:error, %TypeDB.Error{kind: :timeout}} = result,
               "#{inspect(adapter)} reported #{inspect(result)} instead of a timeout"

        assert elapsed < budget * 3,
               "#{inspect(adapter)} waited #{elapsed}ms for a #{budget}ms connect budget"

        if function_exported?(adapter, :terminate, 1), do: adapter.terminate(state)
      end
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

    test "a connect timeout does not discard the configured connect options" do
      # Req merges per-request options over the base ones key by key, so setting
      # :connect_options per request replaces whatever was configured at init —
      # and since TLS lives in there, that silently turns off a pinned CA.
      #
      # Asserted on the options actually sent, not on the init state: the init
      # state is immutable and would look identical even if the merge were
      # broken, which is exactly how this went unnoticed.
      {:ok, state} =
        Req.init(:req_ca_test, connect_options: [transport_opts: [cacertfile: "/nonexistent/ca.pem"]])

      sent =
        Req.request_options(state, :get, "http://example.test/v1/databases", [], nil, connect_timeout: 1_000)

      assert sent[:connect_options][:timeout] == 1_000
      assert sent[:connect_options][:transport_opts] == [cacertfile: "/nonexistent/ca.pem"]
    end

    test "a caller's own connect timeout is not overridden by the per-request one" do
      {:ok, state} = Req.init(:req_ct_base, connect_options: [timeout: 42])

      sent = Req.request_options(state, :get, "http://example.test/v1/x", [], nil, connect_timeout: 1_000)

      assert sent[:connect_options][:timeout] == 42
    end

    test "the request still goes out with those options", %{state: _state} do
      {:ok, state} =
        Req.init(:req_ca_live, connect_options: [transport_opts: [cacertfile: "/nonexistent/ca.pem"]])

      {:ok, stub} = echo_stub()

      # Over plain HTTP the pinned CA is simply unused, which is why this
      # succeeds; the point is that carrying it does not break the request.
      assert {:ok, %{status: 200}} =
               Req.request(state, :get, TypeDB.Stub.url(stub) <> "/v1/databases", [], nil,
                 connect_timeout: 1_000
               )
    end

    test "a refused connection is a transport error, not an exception", %{state: state} do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert_unreachable(Req.request(state, :get, "http://127.0.0.1:#{port}/v1/databases", [], nil, []))
    end
  end

  describe "adapter faults are contained" do
    # TypeDB.HTTP is public, so anyone may implement it — and even the shipped
    # Finch adapter raises rather than returns when its pool is exhausted. None of
    # that may escape the {:ok, _} | {:error, %TypeDB.Error{}} contract.
    defmodule Raising do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}
      def request(_s, _m, _u, _h, _b, _o), do: raise("adapter blew up")
    end

    defmodule PoolExhausted do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}

      def request(_s, _m, _u, _h, _b, _o) do
        raise "Finch was unable to provide a connection within the timeout"
      end
    end

    defmodule Throwing do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}
      def request(_s, _m, _u, _h, _b, _o), do: throw(:nope)
    end

    defmodule Exiting do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}
      def request(_s, _m, _u, _h, _b, _o), do: exit(:boom)
    end

    defmodule Garbage do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}
      def request(_s, _m, _u, _h, _b, _o), do: :not_a_response
    end

    defmodule MalformedResponse do
      @moduledoc false
      @behaviour TypeDB.HTTP
      def init(_name, _opts), do: {:ok, :state}
      def request(_s, _m, _u, _h, _b, _o), do: {:ok, %{status: "200", headers: [], body: nil}}
    end

    for {adapter, kind, label} <- [
          {Raising, :transport, "raises"},
          {PoolExhausted, :timeout, "raises because its pool is exhausted"},
          {Throwing, :transport, "throws"},
          {Exiting, :transport, "exits"},
          {Garbage, :transport, "returns something that is not a response"},
          {MalformedResponse, :transport, "returns a response with the wrong field types"}
        ] do
      test "an adapter that #{label} yields a TypeDB.Error, not a crash" do
        name = :"fault_#{System.unique_integer([:positive])}"

        {:ok, pid} =
          TypeDB.start_link(
            name: name,
            url: "http://127.0.0.1:1",
            token: "t",
            max_retries: 0,
            http: {unquote(adapter), []}
          )

        assert {:error, %TypeDB.Error{kind: unquote(kind)}} = TypeDB.Database.list(name)

        TypeDB.stop(pid)
      end
    end

    test "the original fault is kept in :reason for debugging" do
      name = :"fault_reason_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: "http://127.0.0.1:1", token: "t", http: {Raising, []})

      assert {:error, %TypeDB.Error{reason: {%RuntimeError{message: "adapter blew up"}, stacktrace}}} =
               TypeDB.Database.list(name)

      assert is_list(stacktrace)

      TypeDB.stop(pid)
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
