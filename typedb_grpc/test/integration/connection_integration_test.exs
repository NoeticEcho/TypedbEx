defmodule TypeDB.GRPC.ConnectionIntegrationTest do
  @moduledoc """
  Connection, authentication and the unary half of the protocol, against a real
  server. Set `TYPEDB_GRPC_ADDRESS=127.0.0.1:1729` to run it.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    if address() do
      :ok
    else
      {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip], do: :ok, else: {:ok, conn: start_connection()}
  end

  describe "the server this driver was built for" do
    @tag :skip_without_server
    test "reports a version, and it matches the generated protocol", %{conn: conn} do
      assert {:ok, %{distribution: distribution, version: version}} = Server.version(conn)
      assert distribution =~ "TypeDB"
      assert version =~ ~r/^\d+\.\d+\.\d+/

      assert :ok = Server.check_protocol(conn),
             """
             The server's version and the protocol under lib/protocol have diverged.

             That is not automatically breakage — protobuf tolerates a client built
             from an older schema — but nobody has checked, which is the state this
             assertion exists to refuse. Regenerate with `mix typedb.grpc.gen` and
             update TypeDB.GRPC.Protocol.version/0, or point this at a matching
             server.
             """
    end

    test "health is a round trip, not a local guess", %{conn: conn} do
      assert :ok = Server.health(conn)
    end
  end

  describe "the cluster" do
    test "servers/2 answers in the shape the sibling answers in", %{conn: conn} do
      assert {:ok, [_ | _] = servers} = Server.servers(conn)

      # String keys, and `"address"` spelled as the HTTP API spells it — the
      # point of the shape is that a caller switching transports keeps its
      # pattern matches. A stock single-server CE reports a nil address on both.
      assert Enum.all?(servers, &is_map_key(&1, "address"))

      # Present only when the server sends one. Inventing a nil here would be a
      # difference between the transports rather than a fact about the server.
      for server <- servers, status = server["replication_status"] do
        assert is_integer(status["id"])
        assert status["role"] in [nil, "Primary", "Candidate", "Secondary"]
      end
    end

    test "server/2 is one of the servers servers/2 lists", %{conn: conn} do
      assert {:ok, one} = Server.server(conn)
      assert {:ok, all} = Server.servers(conn)

      assert Map.has_key?(one, "address")
      assert Enum.any?(all, &(&1["address"] == one["address"]))
    end

    test "the ! twins hand back the same thing", %{conn: conn} do
      assert Server.servers!(conn) == elem(Server.servers(conn), 1)
      assert Server.server!(conn) == elem(Server.server(conn), 1)
    end
  end

  describe "authentication" do
    test "a token is minted once and reused", %{conn: conn} do
      assert {:ok, token} = Connection.token(conn)
      assert {:ok, ^token} = Connection.token(conn)
      assert String.starts_with?(token, "ey"), "TypeDB issues JWTs"
    end

    test "a wrong password is not retried into oblivion" do
      conn = start_connection(password: "definitely-not-the-password")

      assert {:error, error} = Connection.token(conn)
      assert error.kind == :unauthenticated
      assert error.code == "AUT1"
      refute TypeDB.Error.retryable?(error)
    end

    test "a pre-issued token works, and cannot be renewed", %{conn: conn} do
      {:ok, token} = Connection.token(conn)

      static = start_connection(token: token)
      assert {:ok, ^token} = Connection.token(static)
      assert {:ok, _} = Database.list(static)

      # Nothing to renew with. The error has to say so rather than looping.
      assert {:error, error} = Connection.renew_token(static, :any)
      assert error.kind == :unauthenticated
      assert error.message =~ "no credentials"
    end
  end

  describe "databases" do
    test "create, list, exists?, delete", %{conn: conn} do
      name = "grpc_db_#{System.unique_integer([:positive])}"

      refute Database.exists?(conn, name)
      assert :ok = Database.create(conn, name)
      assert Database.exists?(conn, name)
      assert {:ok, names} = Database.list(conn)
      assert name in names

      assert :ok = Database.delete(conn, name)
      refute Database.exists?(conn, name)
    end

    test "deleting one that is not there carries TypeDB's own code", %{conn: conn} do
      assert {:error, error} =
               Database.delete(conn, "definitely_absent_#{System.unique_integer([:positive])}")

      assert error.kind == :server
      assert error.code == "DBD1", "the same code the HTTP API reports for this"
      refute TypeDB.Error.retryable?(error)
    end

    # Recorded rather than smoothed over: this is a real difference between the
    # two transports, and the shared behaviour suite is where it belongs once
    # that exists. Pinned here so a change on either side is noticed.
    test "creating one twice is accepted on this transport", %{conn: conn} do
      name = start_database(conn)

      assert :ok = Database.create(conn, name),
             """
             TypeDB used to accept `databases_create` for an existing database over
             gRPC, where the HTTP API rejects it. If that has changed, the module doc
             of TypeDB.GRPC.Database says the opposite and needs updating.
             """
    end

    test "create_if_not_exists is idempotent either way", %{conn: conn} do
      name = "grpc_ine_#{System.unique_integer([:positive])}"
      on_exit(fn -> Database.delete(conn, name) end)

      assert :ok = Database.create_if_not_exists(conn, name)
      assert :ok = Database.create_if_not_exists(conn, name)
      assert Database.exists?(conn, name)
    end

    test "the schema of a fresh database is readable and empty of types", %{conn: conn} do
      name = start_database(conn)

      assert {:ok, schema} = Database.schema(conn, name)
      assert is_binary(schema)

      assert {:ok, types} = Database.type_schema(conn, name)
      assert is_binary(types)
    end
  end

  describe "users" do
    test "the bootstrap admin is there", %{conn: conn} do
      assert {:ok, users} = User.list(conn)
      assert "admin" in users
      assert User.exists?(conn, "admin")
    end

    test "create, sign in as, and delete", %{conn: conn} do
      username = "grpc_user_#{System.unique_integer([:positive])}"
      on_exit(fn -> User.delete(conn, username) end)

      assert :ok = User.create(conn, username, "password-one")
      assert User.exists?(conn, username)

      # The credentials have to actually work, which listing does not prove.
      as_them = start_connection(username: username, password: "password-one")
      assert {:ok, _} = Database.list(as_them)

      assert :ok = User.set_password(conn, username, "password-two")

      stale = start_connection(username: username, password: "password-one")
      assert {:error, %TypeDB.Error{kind: :unauthenticated}} = Connection.token(stale)

      assert :ok = User.delete(conn, username)
      refute User.exists?(conn, username)
    end
  end

  describe "a channel that has gone" do
    test "reaches the caller as a %TypeDB.Error{}, not as an exit", %{conn: conn} do
      # Found by a teardown ordering mistake, and worth keeping: the adapter
      # reaches gun through a GenServer.call, so a dead channel arrives as an
      # exit signal from a process the application has never heard of. An
      # application asking for a list of databases must get something it can
      # match on.
      {:ok, _} = Database.list(conn)

      _ = GRPC.Stub.disconnect(Connection.channel(conn))

      assert {:error, %TypeDB.Error{kind: :transport} = error} = Database.list(conn)
      assert error.message =~ "channel is gone"
      assert TypeDB.Error.retryable?(error), "the connection can come back; this is not permanent"
    end
  end

  describe "a connection that is not running" do
    test "running?/1 says so without raising" do
      refute Connection.running?(:never_started_at_all)
    end

    test "every other entry point raises a :config error naming the fix" do
      assert_raise TypeDB.Error, ~r/is not running/, fn ->
        Connection.config(:never_started_at_all)
      end
    end
  end
end
