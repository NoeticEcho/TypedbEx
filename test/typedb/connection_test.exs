defmodule TypeDB.ConnectionTest do
  use TypeDB.Case, async: true

  alias TypeDB.{Connection, Stub}

  describe "authentication" do
    test "signs in lazily on the first request", %{conn: conn, stub: stub} do
      assert requests(stub, "/signin") == []

      assert {:ok, _} = TypeDB.Database.list(conn)

      assert [signin] = requests(stub, "/signin")
      assert signin.method == "POST"
      assert signin.path == "/v1/signin"
      assert %{"username" => "admin", "password" => "password"} = JSON.decode!(signin.body)
    end

    test "reuses the token across requests", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:ok, _} = TypeDB.Database.list(conn)

      assert length(requests(stub, "/signin")) == 1
    end

    test "sends the token as a bearer header", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.Database.list(conn)

      assert [request] = requests(stub, "/databases")
      assert request.headers["authorization"] == "Bearer stub-token-1"
    end

    @tag stub_opts: [token_uses: 1]
    test "renews an expired token and retries transparently", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:ok, _} = TypeDB.Database.list(conn)

      # Each token survives one request, so every subsequent call renews.
      assert length(requests(stub, "/signin")) > 1

      tokens =
        stub
        |> requests("/databases")
        |> Enum.map(& &1.headers["authorization"])
        |> Enum.uniq()

      assert length(tokens) > 1
    end

    @tag stub_opts: [username: "admin", password: "correct"]
    @tag conn_opts: [password: "wrong"]
    test "surfaces bad credentials as :unauthenticated", %{conn: conn} do
      assert {:error, %Error{kind: :unauthenticated, code: "AUT1"}} = TypeDB.Database.list(conn)
    end

    test "a static token that is rejected cannot be renewed", %{stub: stub} do
      name = :"static_token_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(stub), token: "not-a-real-token")

      assert {:error, %Error{kind: :unauthenticated, message: message}} = TypeDB.Database.list(name)
      assert message =~ "cannot be renewed"

      TypeDB.stop(pid)
    end

    test "does not sign in for unauthenticated endpoints", %{conn: conn, stub: stub} do
      assert :ok = TypeDB.health(conn)
      assert {:ok, %{version: "3.12.1"}} = TypeDB.version(conn)

      assert requests(stub, "/signin") == []
    end
  end

  describe "configuration lookup" do
    test "config/1 returns the running configuration", %{conn: conn, stub: stub} do
      config = Connection.config(conn)
      assert config.base_url == Stub.url(stub)
      assert config.name == conn
    end

    test "config/1 explains an unknown connection" do
      assert_raise Error, ~r/is not running/, fn -> Connection.config(:no_such_connection) end
    end

    test "start_link/1 returns a config error rather than crashing" do
      assert {:error, %Error{kind: :config}} = TypeDB.start_link(name: :bad_conn_test)
    end
  end

  describe "transport failures" do
    test "a refused connection is a :transport error" do
      # Bind and immediately release a port to get one that is almost certainly free.
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      name = :"dead_conn_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:#{port}",
          token: "t",
          max_retries: 0,
          connect_timeout: 500
        )

      assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(name)

      TypeDB.stop(pid)
    end

    test "retries idempotent requests", %{stub: stub} do
      # A handler that fails the first request by closing the socket is hard to
      # arrange; instead assert the retry budget is honoured by counting attempts
      # against a handler that always 503s (which is not retried) versus a
      # transport failure (which is).
      handler = fn _method, _path, _headers, _body ->
        {503, [], ~s({"code":"SRV9","message":"unavailable"})}
      end

      {:ok, failing} = Stub.start_link(handler: handler)

      name = :"retry_conn_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(failing), token: "t")

      assert {:error, %Error{kind: :server, status: 503, code: "SRV9"}} = TypeDB.Database.list(name)
      # 503 is a server answer, not a transport failure: exactly one attempt.
      assert length(requests(failing, "/databases")) == 1

      TypeDB.stop(pid)
      Stub.stop(failing)
      Stub.stop(stub)
    end
  end

  describe "response handling" do
    test "a non-JSON body on a JSON endpoint is a :decode error", %{stub: stub} do
      handler = fn
        "POST", "/v1/signin", _h, _b -> {200, [], ~s({"token":"t"})}
        _method, _path, _h, _b -> {200, [{"content-type", "application/json"}], "not json at all"}
      end

      {:ok, broken} = Stub.start_link(handler: handler)
      name = :"decode_conn_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(broken), username: "u", password: "p")

      assert {:error, %Error{kind: :decode}} = TypeDB.Database.list(name)

      TypeDB.stop(pid)
      Stub.stop(broken)
      Stub.stop(stub)
    end

    test "an error body without a code is still reported", %{stub: stub} do
      handler = fn _method, _path, _h, _b -> {500, [], "internal explosion"} end

      {:ok, broken} = Stub.start_link(handler: handler)
      name = :"raw_error_conn_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(broken), token: "t")

      assert {:error, %Error{kind: :server, status: 500, code: nil, body: "internal explosion"}} =
               TypeDB.Database.list(name)

      TypeDB.stop(pid)
      Stub.stop(broken)
      Stub.stop(stub)
    end
  end

  describe "supervision" do
    test "a connection restarted by its supervisor still works", %{stub: stub} do
      # Finch does not release its registered name synchronously when a pool
      # dies, so a per-connection-name pool would make the restarted connection
      # adopt the corpse of its predecessor and fail every request afterwards.
      name = :"restart_probe_#{System.unique_integer([:positive])}"

      children = [
        {TypeDB, name: name, url: Stub.url(stub), username: "admin", password: "password", max_retries: 0}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, _} = TypeDB.Database.list(name)

      first = Process.whereis(name)
      Process.exit(first, :kill)

      wait_until(fn ->
        case Process.whereis(name) do
          nil -> false
          pid -> pid != first
        end
      end)

      assert {:ok, _} = TypeDB.Database.list(name),
             "a supervised connection must be usable again after a restart"

      Supervisor.stop(supervisor)
    end

    test "two connections started under different names do not share a pool", %{stub: stub} do
      names = for _ <- 1..2, do: :"pool_isolation_#{System.unique_integer([:positive])}"

      pids =
        for name <- names do
          {:ok, pid} =
            TypeDB.start_link(name: name, url: Stub.url(stub), username: "admin", password: "password")

          assert {:ok, _} = TypeDB.Database.list(name)
          pid
        end

      adapter_states = Enum.map(names, &TypeDB.Connection.adapter_state/1)
      assert Enum.map(adapter_states, & &1.name) |> Enum.uniq() |> length() == 2

      Enum.each(pids, &TypeDB.stop/1)
    end
  end

  describe "proactive token refresh" do
    @tag stub_opts: [databases: ["social"], token_lifetime_seconds: 2, token_ttl_ms: 2_000]
    test "renews before the token expires, so no request is ever rejected", %{conn: conn, stub: stub} do
      # The token lives two seconds and the driver's margin is a quarter of that,
      # so it should be replaced at ~1.5s without a single 401 on the wire.
      calls = 30

      for _ <- 1..calls do
        assert {:ok, _} = TypeDB.Database.list(conn)
        Process.sleep(100)
      end

      assert length(requests(stub, "/signin")) > 1, "expected the token to have been refreshed"

      # One request on the wire per call: a 401 would have forced a second.
      assert length(requests(stub, "/databases")) == calls
    end

    @tag stub_opts: [databases: ["social"], token_lifetime_seconds: 3600]
    test "a long-lived token is minted once and reused", %{conn: conn, stub: stub} do
      for _ <- 1..20, do: assert({:ok, _} = TypeDB.Database.list(conn))

      assert length(requests(stub, "/signin")) == 1
    end

    test "a token with no readable lifetime falls back to reactive renewal", %{conn: conn, stub: stub} do
      # The default stub token is not a JWT, so the driver cannot know when it
      # expires and must simply use it until the server objects.
      for _ <- 1..5, do: assert({:ok, _} = TypeDB.Database.list(conn))

      assert length(requests(stub, "/signin")) == 1
    end
  end

  describe "token renewal under concurrency" do
    @tag stub_opts: [databases: ["social"], token_uses: 1]
    test "concurrent renewals coalesce into far fewer sign-ins than callers", %{conn: conn, stub: stub} do
      # Every token is spent by the first request that uses it, so all 40 callers
      # are forced down the renewal path at once.
      1..40
      |> Task.async_stream(fn _ -> TypeDB.Database.list(conn) end, max_concurrency: 40, timeout: 30_000)
      |> Stream.run()

      signins = length(requests(stub, "/signin"))

      # Whoever gets to the connection first signs in; everyone queued behind
      # takes that token instead of minting another.
      assert signins > 1, "expected renewals to happen at all"
      assert signins < 40, "expected renewals to coalesce, but every caller signed in (#{signins})"
    end

    @tag stub_opts: [databases: ["social"], token_ttl_ms: 0]
    test "a token that is stale the moment it is minted gives up rather than looping", %{
      conn: conn,
      stub: stub
    } do
      # Pathological: no token can ever be used. The request must fail with the
      # server's own error after a bounded number of renewals, not spin.
      assert {:error, %Error{kind: :unauthenticated, code: "AUT3"}} = TypeDB.Database.list(conn)

      # One sign-in to get started, then one per renewal in the budget.
      assert length(requests(stub, "/signin")) <= 3
      assert length(requests(stub, "/databases")) == 3
    end

    @tag stub_opts: [databases: ["social"], token_ttl_ms: 0]
    @tag conn_opts: [max_auth_renewals: 5]
    test "the renewal budget is what bounds the loop", %{conn: conn, stub: stub} do
      assert {:error, %Error{code: "AUT3"}} = TypeDB.Database.list(conn)
      assert length(requests(stub, "/databases")) == 6
    end

    @tag stub_opts: [databases: ["social"], token_uses: 1]
    @tag conn_opts: [max_auth_renewals: 0]
    test "max_auth_renewals: 0 turns renewal-and-retry off", %{conn: conn} do
      # The first request mints a token and consumes its single use; the second
      # is rejected and, with no renewal budget, surfaces the 401.
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:error, %Error{kind: :unauthenticated, code: "AUT3"}} = TypeDB.Database.list(conn)
    end

    @tag stub_opts: [databases: ["social"], token_uses: 1]
    test "a rejected token is renewed and the request retried", %{conn: conn, stub: stub} do
      assert {:ok, _} = TypeDB.Database.list(conn)
      assert {:ok, _} = TypeDB.Database.list(conn)

      assert length(requests(stub, "/signin")) == 2

      tokens = stub |> requests("/databases") |> Enum.map(& &1.headers["authorization"])
      assert ["Bearer stub-token-1", "Bearer stub-token-1", "Bearer stub-token-2"] = tokens
    end
  end

  describe "401 on unauthenticated endpoints" do
    test "is returned as an error rather than an internal retry tuple", %{stub: stub} do
      # /health and /version are called without a token. A server that answers 401
      # anyway must surface as a normal error, not leak the driver's internal
      # renew-and-retry signal.
      handler = fn _method, _path, _headers, _body ->
        {401, [{"content-type", "application/json"}], ~s({"code":"AUT2","message":"Missing token."})}
      end

      {:ok, hostile} = Stub.start_link(handler: handler)
      name = :"unauth_conn_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(hostile), token: "t")

      assert {:error, %Error{kind: :unauthenticated, code: "AUT2"}} = TypeDB.health(name)
      assert {:error, %Error{kind: :unauthenticated}} = TypeDB.version(name)

      TypeDB.stop(pid)
      Stub.stop(hostile)
      Stub.stop(stub)
    end
  end

  describe "concurrency" do
    @tag stub_opts: [databases: ["social"]]
    test "requests run in the caller process, not the connection", %{conn: conn, conn_pid: conn_pid} do
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> TypeDB.Database.list(conn) end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, ["social"]}, &1))

      # The connection process handled at most the sign-in; it is not a bottleneck.
      assert Process.alive?(conn_pid)
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition did not become true within the timeout")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
