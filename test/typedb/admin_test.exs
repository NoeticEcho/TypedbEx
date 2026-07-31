defmodule TypeDB.AdminTest do
  use TypeDB.Case, async: true

  alias TypeDB.{Server, User}

  describe "databases" do
    @tag stub_opts: [databases: ["social", "analytics"]]
    test "list/1 returns names, sorted by the server", %{conn: conn} do
      assert {:ok, ["analytics", "social"]} = Database.list(conn)
    end

    test "list/1 on an empty server", %{conn: conn} do
      assert {:ok, []} = Database.list(conn)
    end

    test "create/2 then list/1", %{conn: conn} do
      assert :ok = Database.create(conn, "social")
      assert {:ok, ["social"]} = Database.list(conn)
    end

    test "create/2 twice is a no-op, matching TypeDB 3.x", %{conn: conn} do
      assert :ok = Database.create(conn, "social")
      assert :ok = Database.create(conn, "social")
      assert {:ok, ["social"]} = Database.list(conn)
    end

    test "create_if_not_exists/2 is idempotent", %{conn: conn} do
      assert :ok = Database.create_if_not_exists(conn, "social")
      assert :ok = Database.create_if_not_exists(conn, "social")
      assert {:ok, ["social"]} = Database.list(conn)
    end

    @tag stub_opts: [databases: ["social"]]
    test "get/2 and exists?/2", %{conn: conn} do
      assert {:ok, "social"} = Database.get(conn, "social")
      assert Database.exists?(conn, "social")
      refute Database.exists?(conn, "nope")
      assert {:error, %Error{status: 404}} = Database.get(conn, "nope")
    end

    @tag stub_opts: [databases: ["social"]]
    test "delete/2", %{conn: conn} do
      assert :ok = Database.delete(conn, "social")
      assert {:ok, []} = Database.list(conn)
      assert {:error, %Error{status: 400, code: "DBD1"}} = Database.delete(conn, "social")
    end

    @tag stub_opts: [databases: ["social"]]
    test "schema/2 and type_schema/2 return TypeQL text", %{conn: conn} do
      assert {:ok, schema} = Database.schema(conn, "social")
      assert schema =~ "entity person"

      assert {:ok, type_schema} = Database.type_schema(conn, "social")
      assert type_schema =~ "define"
    end

    test "database names are percent-encoded in the path", %{conn: conn, stub: stub} do
      _ = Database.get(conn, "my db/../etc")

      assert [request] = requests(stub, "/databases/")
      refute String.contains?(request.path, "/../")
      assert String.contains?(request.path, "%2F")
    end

    test "bang variants raise", %{conn: conn} do
      assert_raise Error, fn -> Database.delete!(conn, "nope") end
      assert :ok = Database.create!(conn, "social")
      assert ["social"] = Database.list!(conn)
    end

    test "TypeDB facade delegates", %{conn: conn} do
      assert :ok = TypeDB.create_database(conn, "social")
      assert {:ok, ["social"]} = TypeDB.databases(conn)
      assert :ok = TypeDB.delete_database(conn, "social")
    end
  end

  describe "users" do
    test "list/1 includes the bootstrap admin", %{conn: conn} do
      assert {:ok, ["admin"]} = User.list(conn)
    end

    test "create/3 then get/2", %{conn: conn} do
      assert :ok = User.create(conn, "alice", "s3cret")
      assert {:ok, "alice"} = User.get(conn, "alice")
      assert User.exists?(conn, "alice")
    end

    test "create/3 sends the password in the body", %{conn: conn, stub: stub} do
      assert :ok = User.create(conn, "alice", "s3cret")

      assert [request] = requests(stub, "/users/alice")
      assert JSON.decode!(request.body) == %{"password" => "s3cret"}
    end

    test "set_password/3 uses PUT", %{conn: conn, stub: stub} do
      assert :ok = User.create(conn, "alice", "old")
      assert :ok = User.set_password(conn, "alice", "new")

      assert %{method: "PUT"} = stub |> requests("/users/alice") |> List.last()
    end

    test "set_password/3 on an unknown user", %{conn: conn} do
      assert {:error, %Error{status: 404}} = User.set_password(conn, "ghost", "x")
    end

    test "delete/2", %{conn: conn} do
      assert :ok = User.create(conn, "alice", "x")
      assert :ok = User.delete(conn, "alice")
      refute User.exists?(conn, "alice")
      assert {:error, %Error{status: 404}} = User.delete(conn, "alice")
    end
  end

  describe "server" do
    test "health/1 needs no authentication", %{conn: conn} do
      assert :ok = Server.health(conn)
    end

    test "version/1", %{conn: conn} do
      assert {:ok, %{distribution: "TypeDB CE", version: "3.12.1"}} = Server.version(conn)
    end

    test "servers/1", %{conn: conn} do
      assert {:ok, [%{"address" => "127.0.0.1:1729"}]} = Server.servers(conn)
    end
  end
end
