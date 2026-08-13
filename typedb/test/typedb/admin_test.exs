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

    test "create_if_not_exists/2 still returns the error when the server is unreachable" do
      # It used to go through exists?/2, which now raises — so this function's
      # own contract (return the error) had to stop depending on it.
      name = :"cine_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(name: name, url: "http://127.0.0.1:1", token: "t", max_retries: 0)

      assert_unreachable(Database.create_if_not_exists(name, "social"))

      TypeDB.stop(pid)
    end

    test "create_if_not_exists/2 is idempotent", %{conn: conn} do
      assert :ok = Database.create_if_not_exists(conn, "social")
      assert :ok = Database.create_if_not_exists(conn, "social")
      assert {:ok, ["social"]} = Database.list(conn)
    end

    # Audit III, from a real caller: an application that works through the
    # `TypeDB` facade alone never met `Database.create_if_not_exists/3` — there
    # was no delegate for it — and reimplemented it as "list every database on
    # the server, then check membership". Correct, because `create` is
    # idempotent on TypeDB 3.x, and two round trips to answer a question about
    # one database.
    test "the TypeDB facade can do it in one call", %{conn: conn, stub: stub} do
      assert :ok = TypeDB.create_database_if_not_exists(conn, "brand_new")
      assert :ok = TypeDB.create_database_if_not_exists!(conn, "brand_new")

      assert requests(stub, "/databases/brand_new") != []

      listings = Enum.filter(requests(stub, "/databases"), &(&1.path == "/v1/databases"))
      assert listings == [], "it should not have to list every database to create one"
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
      assert {:error, %Error{status: 404, code: "USU4"}} = User.set_password(conn, "ghost", "x")
    end

    test "delete/2", %{conn: conn} do
      assert :ok = User.create(conn, "alice", "x")
      assert :ok = User.delete(conn, "alice")
      refute User.exists?(conn, "alice")
      assert {:error, %Error{status: 404, code: "USD3"}} = User.delete(conn, "alice")
    end

    # Creating a database that exists succeeds; creating a user that exists does
    # not. The asymmetry is TypeDB's, and it is exactly the kind of thing a stub
    # is free to get wrong until someone checks — so the same assertions run
    # against a live server in test/integration/typedb_integration_test.exs.
    test "create/3 on an existing user is an error, unlike Database.create/2", %{conn: conn} do
      assert :ok = User.create(conn, "alice", "x")

      assert {:error, %Error{kind: :server, status: 400, code: "USC2"}} =
               User.create(conn, "alice", "x")
    end

    test "exists?/2 raises rather than answering false when it could not ask" do
      # A boolean cannot express "I could not ask", and `false` is the answer
      # that makes a caller do the wrong thing:
      # `unless exists?(conn, x), do: create(conn, x)` would try to create while
      # the server is down.
      name = :"unreachable_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(name: name, url: "http://127.0.0.1:1", token: "t", max_retries: 0)

      assert_raise Error, fn -> TypeDB.User.exists?(name, "alice") end
      assert_raise Error, fn -> Database.exists?(name, "social") end

      TypeDB.stop(pid)
    end

    test "get/2 on an unknown user", %{conn: conn} do
      assert {:error, %Error{status: 404, code: "SRV4"}} = User.get(conn, "ghost")
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
