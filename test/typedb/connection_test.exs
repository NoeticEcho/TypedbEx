defmodule TypeDB.ConnectionTest do
  use TypeDB.Case, async: true

  alias TypeDB.{Connection, Stub}
  alias TypeDB.HTTP.Finch, as: FinchAdapter

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

    # 503 is what an ingress or a load balancer answers while TypeDB restarts,
    # which is the case retrying exists for; 400 is TypeDB saying no, which
    # retrying cannot improve.
    defp always_answering(status, code, headers \\ []) do
      handler = fn _method, _path, _headers, _body ->
        {status, headers, ~s({"code":"#{code}","message":"nope"})}
      end

      {:ok, failing} = Stub.start_link(handler: handler)
      on_exit(fn -> stop_quietly(fn -> Stub.stop(failing) end) end)
      failing
    end

    # start_link/1 links to the test process, so by the time on_exit runs the
    # process may already be on its way down; stopping it then exits :shutdown.
    defp stop_quietly(fun) do
      fun.()
    catch
      :exit, _ -> :ok
    end

    defp connection_to(stub, opts) do
      name = :"retry_conn_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link([name: name, url: Stub.url(stub), token: "t"] ++ opts)
      on_exit(fn -> stop_quietly(fn -> TypeDB.stop(pid) end) end)
      name
    end

    test "a status in :retry_on_status is retried, and the server's own error still surfaces" do
      failing = always_answering(503, "SRV9")
      conn = connection_to(failing, max_retries: 1, retry_backoff: fn _ -> 1 end)

      assert {:error, %Error{kind: :server, status: 503, code: "SRV9"}} = TypeDB.Database.list(conn)
      assert length(requests(failing, "/databases")) == 2
    end

    test "a status outside :retry_on_status is not retried" do
      failing = always_answering(400, "DBD1")
      conn = connection_to(failing, max_retries: 3)

      assert {:error, %Error{kind: :server, status: 400}} = TypeDB.Database.list(conn)
      assert length(requests(failing, "/databases")) == 1
    end

    test "retry_on_status: [] opts out entirely" do
      failing = always_answering(503, "SRV9")
      conn = connection_to(failing, max_retries: 3, retry_on_status: [])

      assert {:error, %Error{status: 503}} = TypeDB.Database.list(conn)
      assert length(requests(failing, "/databases")) == 1
    end

    test "a retryable status on a non-idempotent request is not retried" do
      # The same rule as any other retry: a 502 can mean the request reached the
      # server and the answer was lost, so a write is never re-sent.
      failing = always_answering(503, "SRV9")
      conn = connection_to(failing, max_retries: 3, retry_backoff: fn _ -> 1 end)

      assert {:error, %Error{status: 503}} = TypeDB.query(conn, "social", "insert $p isa person;")
      assert length(requests(failing, "/query")) == 1
    end

    test "a numeric retry-after is honoured, bounded by :retry_max_delay" do
      failing = always_answering(429, "SRV9", [{"retry-after", "600"}])

      conn =
        connection_to(failing,
          max_retries: 1,
          retry_max_delay: 60,
          retry_backoff: fn _ -> 1 end
        )

      started = System.monotonic_time(:millisecond)
      assert {:error, %Error{status: 429}} = TypeDB.Database.list(conn)
      elapsed = System.monotonic_time(:millisecond) - started

      # 600s asked for, 60ms allowed, and more than the 1ms the curve wanted.
      assert elapsed >= 60
      assert elapsed < 5_000
      assert length(requests(failing, "/databases")) == 2
    end

    # Fails the first N requests at transport level, then delegates to the real
    # adapter. The only way to see the retry path from the outside.
    defmodule FlakyAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(name, opts) do
        {inner, inner_opts} = Keyword.fetch!(opts, :inner)
        counter = :counters.new(1, [:atomics])

        with {:ok, state} <- inner.init(name, inner_opts) do
          {:ok, {inner, state, counter, Keyword.fetch!(opts, :failures), opts[:test]}}
        end
      end

      # Only /databases is counted and failed; sign-in has to keep working or
      # nothing gets as far as the retry path being tested.
      def request({inner, state, counter, failures, test}, method, url, headers, body, opts) do
        cond do
          String.ends_with?(url, "/databases") ->
            attempt = :counters.get(counter, 1) + 1
            :counters.add(counter, 1, 1)
            send(test, {:attempt, attempt, System.monotonic_time(:millisecond), opts[:timeout]})

            if attempt <= failures do
              {:error, TypeDB.Error.new(:transport, "flaky adapter failing attempt #{attempt}")}
            else
              inner.request(state, method, url, headers, body, opts)
            end

          # Never failed, only observed: /query is the endpoint whose public
          # functions take their own :timeout and :deadline.
          String.ends_with?(url, "/query") ->
            send(test, {:query, opts[:timeout]})
            inner.request(state, method, url, headers, body, opts)

          true ->
            inner.request(state, method, url, headers, body, opts)
        end
      end

      def owner({inner, state, _c, _f, _t}) do
        if function_exported?(inner, :owner, 1), do: inner.owner(state), else: nil
      end

      def terminate({inner, state, _c, _f, _t}) do
        if function_exported?(inner, :terminate, 1), do: inner.terminate(state), else: :ok
      end
    end

    defp flaky_connection(stub, failures, conn_opts) do
      name = :"flaky_#{System.unique_integer([:positive])}"
      inner = TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}

      {:ok, pid} =
        TypeDB.start_link(
          [
            name: name,
            url: Stub.url(stub),
            username: "admin",
            password: "password",
            http: {FlakyAdapter, [inner: inner, failures: failures, test: self()]}
          ] ++ conn_opts
        )

      on_exit(fn ->
        try do
          TypeDB.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      name
    end

    test "a transport failure on an idempotent request is retried", %{stub: stub} do
      conn = flaky_connection(stub, 1, max_retries: 1)

      assert {:ok, _} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, _, _}
      assert_received {:attempt, 2, _, _}
      refute_received {:attempt, 3, _, _}
      # The retry reached the server; the failed attempt never did.
      assert length(requests(stub, "/databases")) == 1
    end

    test ":max_retries bounds the attempts and the last error surfaces", %{stub: stub} do
      conn = flaky_connection(stub, 10, max_retries: 2)

      assert {:error, %Error{kind: :transport, message: message}} = TypeDB.Database.list(conn)
      assert message =~ "attempt 3"

      assert_received {:attempt, 1, _, _}
      assert_received {:attempt, 2, _, _}
      assert_received {:attempt, 3, _, _}
      refute_received {:attempt, 4, _, _}
      assert requests(stub, "/databases") == []
    end

    test "max_retries: 0 means one attempt", %{stub: stub} do
      conn = flaky_connection(stub, 10, max_retries: 0)

      assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, _, _}
      refute_received {:attempt, 2, _, _}
    end

    test ":retry_backoff bounds how long the driver waits between attempts", %{stub: stub} do
      conn = flaky_connection(stub, 10, max_retries: 2, retry_backoff: {:exponential, 100})

      assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, first, _}
      assert_received {:attempt, 2, second, _}
      assert_received {:attempt, 3, third, _}

      # {:exponential, 100} draws from 0..100 and then from 0..200, so only the
      # ceiling is assertable — a jittered draw of zero is a legitimate outcome,
      # and there is no floor to test. The slack is for the scheduler, which can
      # always make a sleep longer than it asked for.
      assert second - first <= 100 + 500
      assert third - second <= 200 + 500

      # The deterministic half of the contract is the function form, below.
    end

    test ":retry_backoff accepts a function of the attempt number", %{stub: stub} do
      conn = flaky_connection(stub, 10, max_retries: 1, retry_backoff: fn attempt -> attempt * 50 end)

      assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, first, _}
      assert_received {:attempt, 2, second, _}
      assert second - first >= 50
    end

    test ":deadline bounds the whole call rather than each attempt", %{stub: stub} do
      # Without it, this configuration would sleep 20 * 40ms between attempts
      # alone, and :timeout would have said nothing about it: :timeout is the
      # budget for one attempt and every retry gets it again.
      conn =
        flaky_connection(stub, 1_000,
          max_retries: 20,
          retry_backoff: fn _ -> 40 end,
          deadline: 250
        )

      started = System.monotonic_time(:millisecond)
      assert {:error, %Error{kind: :timeout, message: message}} = TypeDB.Database.list(conn)
      elapsed = System.monotonic_time(:millisecond) - started

      assert message =~ ":deadline of 250ms"
      # The transport failure that prompted giving up is not thrown away.
      assert message =~ "flaky adapter failing"
      assert elapsed < 250 + 500
    end

    test ":deadline leaves an attempt no more time than it has left", %{stub: stub} do
      conn = flaky_connection(stub, 0, timeout: 60_000, deadline: 300)

      assert {:ok, _} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, _, timeout}
      assert timeout <= 300
    end

    test "without a :deadline an attempt gets its full timeout", %{stub: stub} do
      conn = flaky_connection(stub, 0, timeout: 60_000)

      assert {:ok, _} = TypeDB.Database.list(conn)

      assert_received {:attempt, 1, _, 60_000}
    end

    @tag stub_opts: [databases: ["social"]]
    test "a per-call :deadline overrides the connection's", %{stub: stub} do
      conn = flaky_connection(stub, 0, timeout: 60_000, deadline: 50_000)

      assert {:ok, _} = TypeDB.query(conn, "social", "match $p isa person;")
      assert_received {:query, connection_wide}
      assert connection_wide > 200

      assert {:ok, _} = TypeDB.query(conn, "social", "match $p isa person;", deadline: 200)
      assert_received {:query, per_call}
      assert per_call <= 200
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

    test "the connection goes down with its transport, so a supervisor can rebuild both", %{stub: stub} do
      # trap_exit is on so terminate/2 can clean up, which means a dead pool would
      # otherwise be swallowed and every later request would raise out of the
      # adapter instead of returning a TypeDB.Error.
      name = :"transport_down_#{System.unique_integer([:positive])}"

      children = [
        {TypeDB, name: name, url: Stub.url(stub), username: "admin", password: "password"}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      assert {:ok, _} = TypeDB.Database.list(name)

      connection = Process.whereis(name)
      transport = name |> Connection.adapter_state() |> FinchAdapter.owner()
      assert is_pid(transport)

      Process.exit(transport, :kill)

      wait_until(fn ->
        case Process.whereis(name) do
          nil -> false
          pid -> pid != connection
        end
      end)

      assert {:ok, _} = TypeDB.Database.list(name),
             "the connection must be usable again once the supervisor has rebuilt it"

      Supervisor.stop(supervisor)
    end

    # `c:TypeDB.HTTP.owner/1` documents that "the connection links itself to that
    # process". Finch is linked anyway, because Finch.start_link/1 runs inside
    # init/1 — so an adapter that adopts a pool, or starts one unlinked, is the
    # only thing that proves the connection makes the link itself.
    defmodule UnlinkedOwnerAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(_name, opts) do
        # Deliberately NOT start_link: nothing links this to the connection
        # except the connection choosing to.
        {:ok, pid} = Agent.start(fn -> :pool end)
        send(opts[:test], {:owner, pid})
        {:ok, pid}
      end

      def owner(pid), do: pid
      def request(_pid, _m, _u, _h, _b, _o), do: {:error, TypeDB.Error.new(:transport, "no")}
    end

    test "the connection links to an owner the adapter did not link itself" do
      # The connection is linked to this test process too, and it is about to
      # die on purpose.
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      name = :"unlinked_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          http: {UnlinkedOwnerAdapter, [test: self()]}
        )

      assert_receive {:owner, owner}
      {:links, links} = Process.info(pid, :links)
      assert owner in links, "the connection never linked to the owner"

      Process.exit(owner, :kill)

      wait_until(fn -> not Process.alive?(pid) end)
      refute Process.alive?(pid), "the connection outlived the transport it cannot work without"
      assert_received {:EXIT, ^pid, {:transport_down, :killed}}
    end

    test "an owner that is already dead stops the connection rather than hanging" do
      name = :"deadowner_#{System.unique_integer([:positive])}"
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      {:ok, agent} = Agent.start(fn -> :pool end)
      Process.exit(agent, :kill)
      wait_until(fn -> not Process.alive?(agent) end)

      # init/1 links to a pid that is already gone; the VM answers with
      # {:EXIT, pid, :noproc}, which must be handled like any other transport death.
      result =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          token: "t",
          http: {DeadOwnerAdapter, [pid: agent]}
        )

      case result do
        {:ok, pid} -> wait_until(fn -> not Process.alive?(pid) end)
        {:error, _} -> :ok
      end
    end

    defmodule DeadOwnerAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(_name, opts), do: {:ok, opts[:pid]}
      def owner(pid), do: pid
      def request(_pid, _m, _u, _h, _b, _o), do: {:error, TypeDB.Error.new(:transport, "no")}
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

    defmodule StuckAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      # An adapter that ignores the timeouts it is handed. Real ones should not,
      # but `TypeDB.HTTP` is public and this is the shape of every "my whole pool
      # wedged" incident, so the driver has to survive it.
      def init(_name, opts), do: {:ok, opts[:block_ms]}

      def request(block_ms, _m, url, _h, _b, _o) do
        Process.sleep(block_ms)
        {:error, TypeDB.Error.new(:timeout, "wedged: #{url}")}
      end
    end

    test "callers queued behind a wedged sign-in get an error, and never exit" do
      # Budget: 2 * (timeout + connect_timeout) + 1s of queueing margin, so ~1.1s
      # here. The adapter blocks well past it, which is the only way to overrun a
      # budget derived from the sign-in's own cost.
      name = :"wedged_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: "http://127.0.0.1:1",
          username: "admin",
          password: "password",
          timeout: 50,
          connect_timeout: 10,
          http: {StuckAdapter, [block_ms: 4_000]}
        )

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      results =
        1..6
        |> Task.async_stream(fn _ -> Connection.token(name) end, max_concurrency: 6, timeout: 30_000)
        |> Enum.map(fn {:ok, result} -> result end)

      # None of these may be an exit: `Connection.token/1` is documented to
      # answer {:ok, token} | {:error, %TypeDB.Error{}}, and a caller that has
      # merely queued too long is not a caller that should be killed.
      for result <- results do
        assert {:error, %Error{kind: :timeout, message: message}} = result
        assert message =~ "did not renew its access token"
      end
    end

    # Sign-in runs inside the connection process, so an uncontained adapter fault
    # here takes the connection down with it — and every caller then sees
    # "connection is not running" instead of what actually went wrong.
    defmodule FaultyAtSignInAdapter do
      @moduledoc false
      @behaviour TypeDB.HTTP

      def init(_name, opts), do: {:ok, opts[:fault]}

      def request(:raise, _m, _u, _h, _b, _o), do: raise("adapter blew up")
      def request(:throw, _m, _u, _h, _b, _o), do: throw(:nope)
      def request(:exit, _m, _u, _h, _b, _o), do: exit(:boom)
      def request(:garbage, _m, _u, _h, _b, _o), do: :not_a_response
    end

    for fault <- [:raise, :throw, :exit, :garbage] do
      test "an adapter that #{fault}s during sign-in does not take the connection with it" do
        name = :"signin_fault_#{System.unique_integer([:positive])}"

        {:ok, pid} =
          TypeDB.start_link(
            name: name,
            url: "http://127.0.0.1:1",
            username: "admin",
            password: "password",
            http: {FaultyAtSignInAdapter, [fault: unquote(fault)]}
          )

        assert {:error, %Error{kind: :transport, message: message}} = TypeDB.Database.list(name)
        assert message =~ "/v1/signin"

        assert Process.alive?(pid),
               "the connection died with its adapter, so every later caller sees 'not running'"

        # And it is still usable: the failure was reported, not fatal.
        assert {:error, %Error{kind: :transport}} = TypeDB.Database.list(name)

        TypeDB.stop(pid)
      end
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
