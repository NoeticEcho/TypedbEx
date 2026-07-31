defmodule TypeDB.SecurityTest do
  use TypeDB.Case, async: true

  alias TypeDB.{Config, Connection}

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
