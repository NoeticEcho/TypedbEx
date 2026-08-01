defmodule TypeDB.ErrorCodeIntegrationTest do
  @moduledoc """
  Pins TypeDB's error codes for every failing operation.

  The stub in `test/support/` is only useful while it behaves like the server,
  and it has been wrong about codes repeatedly: five of the codes it returned
  were invented, and each one was asserted by a unit test, so the suite agreed
  with itself and with nothing else.

  This file is the check. Every assertion here was recorded from a live TypeDB
  3.12.1 rather than reasoned about, and the stub is written to match. When they
  disagree, the server is right.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set; see `TypeDB.IntegrationTest`
  for how to run it.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias TypeDB.{Database, Error, Transaction, User}

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_error_codes

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    # Unlinked, so the connection outlives the setup_all process long enough for
    # on_exit to drop the database through it.
    Process.unlink(pid)

    database = "error_codes_#{System.unique_integer([:positive])}"
    :ok = Database.create(name, database)

    {:ok, _} =
      TypeDB.query(name, database, "define attribute name, value string; entity person, owns name;")

    on_exit(fn ->
      _ = Database.delete(name, database)

      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: name, database: database}
  end

  describe "databases" do
    test "a database that does not exist", %{conn: conn} do
      assert {:error, %Error{status: 404, code: "HSR4"}} = Database.get(conn, "nope")
      assert {:error, %Error{status: 400, code: "DBD1"}} = Database.delete(conn, "nope")

      # A 404 here, and a 400 for the same database on /transactions/open below.
      assert {:error, %Error{status: 404, code: "SRV3"}} = Database.schema(conn, "nope")
      assert {:error, %Error{status: 404, code: "SRV3"}} = Database.type_schema(conn, "nope")
    end

    test "creating one that exists is not an error", %{conn: conn, database: database} do
      # Unlike creating a user, below. The asymmetry is TypeDB's.
      assert :ok = Database.create(conn, database)
    end
  end

  describe "users" do
    setup %{conn: conn} do
      username = "ec_user_#{System.unique_integer([:positive])}"
      :ok = User.create(conn, username, "s3cret")
      on_exit(fn -> User.delete(conn, username) end)
      {:ok, username: username}
    end

    test "a user that does not exist", %{conn: conn} do
      assert {:error, %Error{status: 404, code: "SRV4"}} = User.get(conn, "ghost")
      assert {:error, %Error{status: 404, code: "USD3"}} = User.delete(conn, "ghost")
      assert {:error, %Error{status: 404, code: "USU4"}} = User.set_password(conn, "ghost", "x")
    end

    test "a user that does exist", %{conn: conn, username: username} do
      assert {:error, %Error{status: 400, code: "USC2"}} = User.create(conn, username, "x")
    end

    test "the bootstrap admin cannot be deleted", %{conn: conn} do
      assert {:error, %Error{status: 400, code: "USD1"}} = User.delete(conn, "admin")
    end
  end

  describe "transactions" do
    test "opening one on a database that does not exist", %{conn: conn} do
      # 400 and SRV3 — not the 404 the request shape suggests, and not a
      # transaction code. The stub returned 404 TSV2 for two years of nobody
      # checking.
      assert {:error, %Error{status: 400, code: "SRV3"}} = Transaction.open(conn, "nope", :read)
    end

    test "committing a read transaction", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :read)
      assert {:error, %Error{status: 400, code: "TSV2"}} = Transaction.commit(tx)
    end

    test "rolling back a read transaction", %{conn: conn, database: database} do
      # Which is why TypeDB.transaction/5 closes a failed read block rather than
      # rolling it back.
      {:ok, tx} = Transaction.open(conn, database, :read)
      assert {:error, %Error{status: 400, code: "TSV3"}} = Transaction.rollback(tx)
      assert :ok = Transaction.close(tx)
    end

    test "anything at all on a transaction that has finished", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :write)
      assert :ok = Transaction.commit(tx)

      assert {:error, %Error{status: 404, code: "TSV12"}} = Transaction.query(tx, "match $p isa person;")
      assert {:error, %Error{status: 404, code: "TSV12"}} = Transaction.commit(tx)
      assert {:error, %Error{status: 404, code: "TSV12"}} = Transaction.rollback(tx)

      # Except closing it, which succeeds — that is the state we wanted.
      assert :ok = Transaction.close(tx)
      assert :ok = Transaction.close(tx)
    end
  end

  describe "queries" do
    test "a syntax error", %{conn: conn, database: database} do
      assert {:error, %Error{status: 400, code: "TQL0"}} = TypeDB.query(conn, database, "matsh $p;")
    end

    test "a type that is not in the schema", %{conn: conn, database: database} do
      assert {:error, %Error{status: 400, code: "INF2"}} =
               TypeDB.query(conn, database, "match $p isa nonexistent;", transaction_type: :read)
    end

    test "a write in a read transaction", %{conn: conn, database: database} do
      assert {:error, %Error{status: 400, code: "TSV9"}} =
               TypeDB.query(conn, database, "insert $p isa person;", transaction_type: :read)
    end

    test "a schema change in a write transaction", %{conn: conn, database: database} do
      assert {:error, %Error{status: 400, code: "TSV8"}} =
               TypeDB.query(conn, database, "define entity dog;", transaction_type: :write)
    end

    test "a database that does not exist", %{conn: conn} do
      assert {:error, %Error{status: 400, code: "SRV3"}} =
               TypeDB.query(conn, "nope", "match $p isa person;", transaction_type: :read)
    end

    test "selecting a variable the query never bound", %{conn: conn, database: database} do
      assert {:error, %Error{status: 400, code: "REP18"}} =
               TypeDB.query(conn, database, "match $p isa person; select $nope;", transaction_type: :read)
    end
  end

  describe "authentication" do
    test "the wrong password", %{conn: conn} do
      config = TypeDB.Connection.config(conn)
      name = :"ec_bad_password_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(name: name, url: config.base_url, username: "admin", password: "wrong")

      assert {:error, %Error{kind: :unauthenticated, status: 401, code: "AUT1"}} =
               Database.list(name)

      TypeDB.stop(pid)
    end

    test "a token the server does not recognise", %{conn: conn} do
      config = TypeDB.Connection.config(conn)
      name = :"ec_bad_token_#{System.unique_integer([:positive])}"

      {:ok, pid} = TypeDB.start_link(name: name, url: config.base_url, token: "not-a-token")

      # The driver's own message, since a static token cannot be renewed — but
      # it inherits the server's code.
      assert {:error, %Error{kind: :unauthenticated, code: "AUT3"}} = Database.list(name)

      TypeDB.stop(pid)
    end
  end
end
