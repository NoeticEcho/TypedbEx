defmodule TypeDB.SecurityTest do
  use TypeDB.Case, async: true

  alias TypeDB.{Config, Connection, Stub}

  test "inspecting a config does not reveal the password" do
    config = Config.new!(url: "http://localhost:8000", username: "admin", password: "hunter2")
    inspected = inspect(config)

    refute inspected =~ "hunter2"
    assert inspected =~ "admin"
  end

  test "inspecting a config does not reveal a static token" do
    refute inspect(Config.new!(token: "s3cr3t-token")) =~ "s3cr3t-token"
  end

  test "a running connection's config does not leak its password", %{conn: conn} do
    refute inspect(Connection.config(conn)) =~ "password"
  end

  describe "secrets in the places that get printed or read" do
    @secret "hunter2-SECRET"
    @tls_secret "KEYPASS-SECRET"

    setup do
      {:ok, stub} = Stub.start_link(databases: ["social"], password: @secret)
      name = :"sec_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: Stub.url(stub),
          username: "admin",
          password: @secret,
          http: {TypeDB.HTTP.Httpc, ssl: [password: ~c"#{@tls_secret}"]}
        )

      on_exit(fn ->
        try do
          TypeDB.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, conn: name, pid: pid, stub: stub}
    end

    # The ETS table is `:protected`, which is the point — it is what lets
    # requests run in the caller's process. That also means any process in the VM
    # can read it, so it must not be where the password lives.
    test "the world-readable ETS table carries no credentials", %{conn: conn} do
      assert {:ok, _} = TypeDB.Database.list(conn)

      assert [{:config, config}] = :ets.lookup(conn, :config)
      assert config.password == nil
      assert config.static_token == nil
    end

    test "a static token is not in the ETS table either", %{stub: stub} do
      name = :"sec_token_#{System.unique_integer([:positive])}"
      {:ok, pid} = TypeDB.start_link(name: name, url: Stub.url(stub), token: "s3cr3t-token")

      assert [{:config, config}] = :ets.lookup(name, :config)
      assert config.static_token == nil

      TypeDB.stop(pid)
    end

    # Every field of the GenServer state renders into a crash report.
    test "nothing in the connection's state renders a secret", %{conn: conn, pid: pid} do
      assert {:ok, _} = TypeDB.Database.list(conn)

      rendered = inspect(:sys.get_state(pid), limit: :infinity)

      refute rendered =~ @secret, "the sign-in password renders in crash reports"
      refute rendered =~ @tls_secret, "the TLS key passphrase renders in crash reports"
    end

    test "the adapter state renders no TLS material", %{conn: conn} do
      assert [{:http_state, http_state}] = :ets.lookup(conn, :http_state)

      refute inspect(http_state, limit: :infinity) =~ @tls_secret
      # The options are still there for the adapter to use; only the render hides.
      assert http_state.ssl_opts[:password] == ~c"#{@tls_secret}"
    end
  end

  test "the connection process state does not leak the password through inspect", %{conn: conn_pid} do
    # Crash reports and observers inspect process state; the password must not be
    # visible there either.
    state = :sys.get_state(Process.whereis(conn_pid))
    refute inspect(state) =~ ~s("password")
  end

  test "database and user names are percent-encoded, so a path cannot be escaped", %{
    conn: conn,
    stub: stub
  } do
    _ = TypeDB.User.get(conn, "../../v1/databases")

    assert [request] = requests(stub, "/users/")

    # The separators are what make traversal possible, and they are encoded, so
    # the whole thing stays a single path segment.
    assert request.path == "/v1/users/..%2F..%2Fv1%2Fdatabases"
    assert request.path |> String.split("/", trim: true) |> length() == 3
  end
end
