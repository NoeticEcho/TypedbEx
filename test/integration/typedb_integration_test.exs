defmodule TypeDB.IntegrationTest do
  @moduledoc """
  End-to-end tests against a real TypeDB server.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set. To run them:

      docker compose up -d
      TYPEDB_INTEGRATION_URL=http://localhost:8000 \\
        TYPEDB_INTEGRATION_USERNAME=admin \\
        TYPEDB_INTEGRATION_PASSWORD=password \\
        mix test --include integration

  Each test run creates and drops its own database, so it is safe to point at a
  shared development server — but never at one holding data you care about.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias TypeDB.{Answer, Concept, ConceptRow, Database, Error, Transaction}

  # The same schema `mix typedb.check` validates in CI, so the fixture is proven
  # both syntactically valid and acceptable to a real server.
  @external_resource "priv/typeql/example_schema.tql"
  @schema File.read!("priv/typeql/example_schema.tql")

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_integration

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        timeout: 60_000,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    on_exit(fn ->
      # Linked to the setup_all process, so it may already be shutting down.
      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: name}
  end

  setup %{conn: conn} do
    database = "driver_test_#{System.unique_integer([:positive])}"
    :ok = Database.create(conn, database)
    on_exit(fn -> Database.delete(conn, database) end)

    {:ok, database: database}
  end

  describe "server" do
    test "health and version", %{conn: conn} do
      assert :ok = TypeDB.health(conn)
      assert {:ok, %{distribution: distribution, version: version}} = TypeDB.version(conn)
      assert is_binary(distribution)
      assert version =~ ~r/^3\./
    end

    test "servers", %{conn: conn} do
      assert {:ok, [_ | _]} = TypeDB.Server.servers(conn)
    end
  end

  describe "databases" do
    test "create, list, get, schema and delete", %{conn: conn, database: database} do
      assert {:ok, names} = Database.list(conn)
      assert database in names
      assert {:ok, ^database} = Database.get(conn, database)
      assert Database.exists?(conn, database)

      assert {:ok, _schema} = Database.schema(conn, database)
      assert {:ok, _type_schema} = Database.type_schema(conn, database)

      other = "#{database}_extra"
      assert :ok = Database.create(conn, other)
      assert :ok = Database.delete(conn, other)
      refute Database.exists?(conn, other)
    end

    test "creating a database twice is a no-op that preserves data", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(conn, database, "define attribute name, value string; entity person, owns name;")

      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Alice";))

      assert :ok = Database.create(conn, database)

      assert {:ok, answer} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert length(Answer.rows(answer)) == 1
    end

    test "deleting a database that does not exist errors", %{conn: conn} do
      assert {:error, %Error{status: 400, code: "DBD1"}} = Database.delete(conn, "definitely_not_here")
    end

    test "create_if_not_exists is idempotent", %{conn: conn, database: database} do
      assert :ok = Database.create_if_not_exists(conn, database)
    end

    test "operating on an unknown database errors", %{conn: conn} do
      assert {:error, %Error{status: 404}} = Database.get(conn, "definitely_not_here")
    end
  end

  describe "schema and data" do
    setup %{conn: conn, database: database} do
      assert {:ok, %Answer.Ok{query_type: :schema}} = TypeDB.query(conn, database, @schema)
      :ok
    end

    test "the schema round-trips through the schema endpoint", %{conn: conn, database: database} do
      assert {:ok, schema} = Database.schema(conn, database)
      assert schema =~ "person"
      assert schema =~ "employment"
    end

    test "insert then match", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(conn, database, """
                 insert
                   $alice isa person, has name "Alice", has age 30;
                   $bob isa person, has name "Bob", has age 41;
               """)

      assert {:ok, %Answer.ConceptRows{rows: rows}} =
               TypeDB.query(conn, database, "match $p isa person, has name $name; select $name;",
                 transaction_type: :read
               )

      names = rows |> Enum.map(&ConceptRow.value(&1, "name")) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "instance types are attached by default and omitted on request", %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Alice";))

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person; select $p;", transaction_type: :read)

      assert %Concept.Entity{type: %Concept.EntityType{label: "person"}} = row["p"]

      assert {:ok, %{rows: [bare]}} =
               TypeDB.query(conn, database, "match $p isa person; select $p;",
                 transaction_type: :read,
                 include_instance_types: false
               )

      assert %Concept.Entity{type: nil} = bare["p"]
    end

    test "answer_count_limit truncates and warns", %{conn: conn, database: database} do
      values = Enum.map_join(1..10, " ", fn i -> ~s($p#{i} isa person, has name "P#{i}";) end)
      assert {:ok, _} = TypeDB.query(conn, database, "insert #{values}")

      assert {:ok, answer} =
               TypeDB.query(conn, database, "match $p isa person;",
                 transaction_type: :read,
                 answer_count_limit: 3
               )

      assert length(Answer.rows(answer)) == 3
      assert is_binary(Answer.warning(answer))
    end

    test "typed values come back as native Elixir terms", %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Alice", has age 30;))

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person, has age $age; select $age;",
                 transaction_type: :read
               )

      assert ConceptRow.typed_value(row, "age") == 30
      assert %Concept.Attribute{value_type: "integer"} = row["age"]
    end

    test "relations and role types", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(conn, database, """
                 insert
                   $alice isa person, has name "Alice";
                   $acme isa company, has name "Acme";
                   $e isa employment (employee: $alice, employer: $acme);
               """)

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $e isa employment; select $e;", transaction_type: :read)

      assert %Concept.Relation{type: %Concept.RelationType{label: "employment"}} = row["e"]
    end

    test "fetch produces concept documents", %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Alice";))

      assert {:ok, %Answer.ConceptDocuments{documents: [document]}} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   match $p isa person, has name $n;
                   fetch { "name": $n };
                 """,
                 transaction_type: :read
               )

      assert %{"name" => "Alice"} = document
    end

    test "a malformed query is a server error with a code", %{conn: conn, database: database} do
      assert {:error, %Error{kind: :server, code: code}} =
               TypeDB.query(conn, database, "match $p isa;", transaction_type: :read)

      assert is_binary(code)
    end

    test "a write query is rejected in a read transaction", %{conn: conn, database: database} do
      assert {:error, %Error{kind: :server}} =
               TypeDB.query(conn, database, ~s(insert $p isa person;), transaction_type: :read)
    end
  end

  describe "parameterised queries (given)" do
    setup %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, @schema)
      :ok
    end

    test "given binds one row per input", %{conn: conn, database: database} do
      assert {:ok, answer} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $n: string;
                   insert $p isa person, has name == $n;
                 """,
                 given_rows: [%{"n" => "Alice"}, %{"n" => "Bob"}]
               )

      assert length(Answer.rows(answer)) == 2

      assert {:ok, read} =
               TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
                 transaction_type: :read
               )

      names = read |> Answer.rows() |> Enum.map(&ConceptRow.value(&1, "n")) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "given carries non-string values", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $n: string, $a: integer;
                   insert $p isa person, has name == $n, has age == $a;
                 """,
                 given_rows: [%{"n" => "Alice", "a" => 30}]
               )

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person, has age $a; select $a;",
                 transaction_type: :read
               )

      assert ConceptRow.typed_value(row, "a") == 30
    end

    test "a value that looks like TypeQL is data, not code", %{conn: conn, database: database} do
      # The whole point of `given`, and the reason the driver tags values rather
      # than forwarding raw JSON: quotes, semicolons and newlines are all data.
      injection = ~s(x"; delete $p isa person; insert $q isa person, has name "pwned\n--)

      assert {:ok, _} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $n: string;
                   insert $p isa person, has name == $n;
                 """,
                 given_rows: [%{"n" => injection}]
               )

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
                 transaction_type: :read
               )

      assert ConceptRow.value(row, "n") == injection
    end

    test "given also works inside an explicit transaction", %{conn: conn, database: database} do
      assert :ok =
               TypeDB.transaction(conn, database, :write, fn tx ->
                 {:ok, _} =
                   Transaction.query(
                     tx,
                     """
                       given $n: string;
                       insert $p isa person, has name == $n;
                     """,
                     given_rows: [%{"n" => "Carol"}]
                   )

                 :ok
               end)

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
                 transaction_type: :read
               )

      assert ConceptRow.value(row, "n") == "Carol"
    end

    test "given carries every TypeDB value type", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(conn, database, """
                 define
                   attribute flag, value boolean;
                   attribute ratio, value double;
                   attribute amount, value decimal;
                   attribute born, value date;
                   attribute seen, value datetime;
                   attribute zoned, value datetime-tz;
                   attribute elapsed, value duration;
                   entity sample,
                     owns flag, owns ratio, owns amount, owns born,
                     owns seen, owns zoned, owns elapsed;
               """)

      cases = [
        {"flag", "boolean", true},
        {"ratio", "double", 3.5},
        {"amount", "decimal", %Concept.Value{value: "12.345", value_type: "decimal"}},
        {"born", "date", ~D[2024-03-01]},
        {"seen", "datetime", ~N[2024-03-01 10:30:00]},
        {"zoned", "datetime-tz", TypeDB.DateTimeTZ.parse("2024-03-01T10:30:00+02:00")},
        {"zoned", "datetime-tz", DateTime.from_naive!(~N[2024-03-01 10:30:00], "Etc/UTC")},
        {"elapsed", "duration", TypeDB.Duration.parse("P1Y2M3DT4H5M6S")}
      ]

      for {attribute, value_type, value} <- cases do
        assert {:ok, _} =
                 TypeDB.query(
                   conn,
                   database,
                   """
                     given $v: #{value_type};
                     insert $s isa sample, has #{attribute} == $v;
                   """,
                   given_rows: [%{"v" => value}],
                   commit: false
                 ),
               "expected #{value_type} value #{inspect(value)} to be accepted"
      end
    end

    test "a concept from an earlier answer can be given back", %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Anchor";))

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person; select $p;", transaction_type: :read)

      entity = row["p"]
      assert %Concept.Entity{} = entity

      assert {:ok, %{rows: [found]}} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $p: person;
                   match $p has name $n;
                   select $n;
                 """,
                 given_rows: [%{"p" => entity}],
                 transaction_type: :read
               )

      assert ConceptRow.value(found, "n") == "Anchor"
    end

    test "nil leaves an optional column unbound", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $n: string?;
                   insert $p isa person;
                 """,
                 given_rows: [%{"n" => nil}]
               )
    end

    test "a given stage without rows is rejected by the server", %{conn: conn, database: database} do
      assert {:error, %Error{kind: :server}} =
               TypeDB.query(conn, database, """
                 given $n: string;
                 insert $p isa person, has name == $n;
               """)
    end
  end

  describe "transactions" do
    setup %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, @schema)
      :ok
    end

    test "bracketed write commits", %{conn: conn, database: database} do
      assert :ok =
               TypeDB.transaction(conn, database, :write, fn tx ->
                 {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Alice";))
                 {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Bob";))
                 :ok
               end)

      assert {:ok, answer} =
               TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)

      assert length(Answer.rows(answer)) == 2
    end

    test "a raising block rolls back", %{conn: conn, database: database} do
      assert_raise RuntimeError, "abort", fn ->
        TypeDB.transaction(conn, database, :write, fn tx ->
          {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Ghost";))
          raise "abort"
        end)
      end

      assert {:ok, answer} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert Answer.rows(answer) == []
    end

    test "an error-returning block rolls back", %{conn: conn, database: database} do
      assert {:error, :nope} =
               TypeDB.transaction(conn, database, :write, fn tx ->
                 {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Ghost";))
                 {:error, :nope}
               end)

      assert {:ok, answer} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert Answer.rows(answer) == []
    end

    test "manual rollback keeps the transaction usable", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :write)
      {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Discarded";))
      :ok = Transaction.rollback(tx)
      {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Kept";))
      :ok = Transaction.commit(tx)

      assert {:ok, %{rows: [row]}} =
               TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
                 transaction_type: :read
               )

      assert ConceptRow.value(row, "n") == "Kept"
    end

    test "reads do not see uncommitted writes from another transaction", %{conn: conn, database: database} do
      {:ok, writer} = Transaction.open(conn, database, :write)
      {:ok, _} = Transaction.query(writer, ~s(insert $p isa person, has name "Pending";))

      assert {:ok, answer} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert Answer.rows(answer) == []

      :ok = Transaction.commit(writer)

      assert {:ok, committed} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert length(Answer.rows(committed)) == 1
    end

    test "using a committed transaction errors", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :write)
      :ok = Transaction.commit(tx)

      assert {:error, %Error{}} = Transaction.query(tx, "match $p isa person;")
    end

    test "close is idempotent", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :read)
      assert :ok = Transaction.close(tx)
      assert :ok = Transaction.close(tx)
    end

    test "analyze returns a pipeline structure", %{conn: conn, database: database} do
      {:ok, tx} = Transaction.open(conn, database, :read)
      assert {:ok, structure} = Transaction.analyze(tx, "match $p isa person; select $p;")
      assert is_map(structure)
      :ok = Transaction.close(tx)
    end

    test "commit: false discards the write", %{conn: conn, database: database} do
      assert {:ok, _} =
               TypeDB.query(conn, database, ~s(insert $p isa person, has name "Dry";), commit: false)

      assert {:ok, answer} = TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
      assert Answer.rows(answer) == []
    end
  end

  describe "concurrency" do
    setup %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, @schema)
      :ok
    end

    test "concurrent writers all land", %{conn: conn, database: database} do
      tasks =
        for i <- 1..16 do
          Task.async(fn ->
            TypeDB.query(conn, database, ~s(insert $p isa person, has name "P#{i}";))
          end)
        end

      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert {:ok, answer} =
               TypeDB.query(conn, database, "match $p isa person;",
                 transaction_type: :read,
                 answer_count_limit: 100
               )

      assert length(Answer.rows(answer)) == 16
    end

    test "concurrent reads are served in parallel", %{conn: conn, database: database} do
      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Alice";))

      tasks =
        for _ <- 1..16 do
          Task.async(fn ->
            TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)
          end)
        end

      assert Enum.all?(Task.await_many(tasks, 60_000), &match?({:ok, %Answer.ConceptRows{}}, &1))
    end
  end

  describe "users" do
    test "create, update and delete a user", %{conn: conn} do
      username = "driver_test_user_#{System.unique_integer([:positive])}"

      assert {:ok, users} = TypeDB.User.list(conn)
      assert is_list(users)

      assert :ok = TypeDB.User.create(conn, username, "initial-password")
      assert TypeDB.User.exists?(conn, username)
      assert :ok = TypeDB.User.set_password(conn, username, "another-password")
      assert :ok = TypeDB.User.delete(conn, username)
      refute TypeDB.User.exists?(conn, username)
    end
  end

  describe "authentication" do
    test "bad credentials are reported as unauthenticated", %{conn: conn} do
      config = TypeDB.Connection.config(conn)
      name = :"typedb_integration_bad_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(
          name: name,
          url: config.base_url,
          username: "admin",
          password: "definitely-wrong",
          http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
        )

      assert {:error, %Error{kind: :unauthenticated}} = Database.list(name)

      TypeDB.stop(pid)
    end
  end
end
