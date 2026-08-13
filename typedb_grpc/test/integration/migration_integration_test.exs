defmodule TypeDB.GRPC.MigrationIntegrationTest do
  @moduledoc """
  Export and import against a real server.

  The capability this transport has and the HTTP one does not: TypeDB's HTTP API
  answers 404 for `/v1/databases/x/export`, so a graph written through the
  sibling driver can only be read back by replaying whatever the application
  logged. Here the server streams it.

  The claim that matters most is not that a round trip works — it is that the
  files are TypeDB's, not this driver's. Set `TYPEDB_CONSOLE` to the `typedb`
  binary and the suite proves that against the real console, in both directions
  and byte for byte. Without it that one test says so and skips.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.GRPC.{Database, Transaction}

  setup_all do
    if address(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip] do
      :ok
    else
      conn = start_connection()
      dir = Path.join(System.tmp_dir!(), "typedb_grpc_migration_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok,
       conn: conn,
       dir: dir,
       schema_path: Path.join(dir, "schema.tql"),
       data_path: Path.join(dir, "data.typedb")}
    end
  end

  defp seed(conn, people) do
    database = start_database(conn, "mig")

    {:ok, _} =
      Transaction.transaction(conn, database, :schema, fn tx ->
        Transaction.query(tx, """
          define
            attribute name, value string;
            attribute age, value integer;
            entity person, owns name, owns age;
            relation friendship, relates friend;
            entity peer sub person, plays friendship:friend;
        """)
      end)

    if people > 0 do
      {:ok, _} =
        Transaction.transaction(conn, database, :write, fn tx ->
          Transaction.query(
            tx,
            "given $n: string, $a: integer; insert $p isa peer, has name == $n, has age == $a;",
            given_rows: for(i <- 1..people, do: %{"n" => "person-#{i}", "a" => i})
          )
        end)
    end

    database
  end

  defp count(conn, database, pattern) do
    {:ok, answer} =
      Transaction.transaction(conn, database, :read, fn tx ->
        Transaction.query(tx, "match #{pattern} reduce $c = count;")
      end)

    answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c")
  end

  defp restored_name(conn) do
    name = "mig_restored_#{System.unique_integer([:positive])}"
    on_exit(fn -> Database.delete(conn, name) end)
    name
  end

  defp console(binary, command) do
    System.cmd(
      binary,
      ["console", "--address", address(), "--tls-disabled", "--command", command] ++
        ["--username", credentials()[:username], "--password", credentials()[:password]],
      stderr_to_stdout: true
    )
  end

  describe "a round trip" do
    test "everything that went in comes back out", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      source = seed(conn, 500)

      assert :ok = Database.export_to_files(conn, source, schema_path, data_path)

      # The schema file is TypeQL a person can read, not a blob.
      schema = File.read!(schema_path)
      assert schema =~ "entity person"
      assert schema =~ "relation friendship"

      assert File.stat!(data_path).size > 0

      restored = restored_name(conn)
      assert :ok = Database.import_from_files(conn, restored, schema_path, data_path)

      assert count(conn, restored, "$p isa peer;") == 500
      assert count(conn, restored, "$p isa person;") == 500
      assert count(conn, restored, "$p isa person, has name $n;") == 500

      # The subtype and its role survive, not just the instance count. The
      # server pretty-prints a schema across lines, so this matches what it
      # writes rather than what the define query said.
      restored_schema = Database.schema!(conn, restored)
      assert restored_schema =~ ~r/entity peer,\s+sub person/
      assert restored_schema =~ ~r/plays friendship:friend/
    end

    test "an empty database round-trips too", %{conn: conn, schema_path: schema_path, data_path: data_path} do
      source = seed(conn, 0)

      assert :ok = Database.export_to_files(conn, source, schema_path, data_path)

      restored = restored_name(conn)
      assert :ok = Database.import_from_files(conn, restored, schema_path, data_path)
      assert count(conn, restored, "$p isa person;") == 0
    end

    test "the ! twins do the same thing", %{conn: conn, schema_path: schema_path, data_path: data_path} do
      source = seed(conn, 3)

      assert :ok = Database.export_to_files!(conn, source, schema_path, data_path)

      restored = restored_name(conn)
      assert :ok = Database.import_from_files!(conn, restored, schema_path, data_path)
      assert count(conn, restored, "$p isa person;") == 3
    end

    test "the facade reaches both", %{conn: conn, schema_path: schema_path, data_path: data_path} do
      source = seed(conn, 2)

      assert :ok = TypeDB.GRPC.export_database(conn, source, schema_path, data_path)

      restored = restored_name(conn)
      assert :ok = TypeDB.GRPC.import_database(conn, restored, schema_path, data_path)
      assert count(conn, restored, "$p isa person;") == 2
    end
  end

  describe "the file format is TypeDB's, not this driver's" do
    @tag :console
    test "the console reads what this driver writes, and the other way round", %{
      conn: conn,
      dir: dir,
      schema_path: schema_path,
      data_path: data_path
    } do
      console = System.get_env("TYPEDB_CONSOLE")

      if console && File.exists?(console) do
        interop(conn, console, dir, schema_path, data_path)
      else
        # Skipped rather than failed when the console is not on this machine:
        # it is the same posture as the rest of the suite, which skips without a
        # server rather than pretending the absence is a defect. CI runs TypeDB
        # as a service container and has no console binary on the runner, so
        # this one is a local check — run it after touching the file format.
        IO.puts(:stderr, "skipping the console interop test: set TYPEDB_CONSOLE to the typedb binary")
      end
    end
  end

  defp interop(conn, console, dir, schema_path, data_path) do
    source = seed(conn, 50)
    assert :ok = Database.export_to_files(conn, source, schema_path, data_path)

    # 1. this driver's dump, restored by the console.
    from_driver = restored_name(conn)
    assert {_, 0} = console(console, "database import #{from_driver} #{schema_path} #{data_path}")

    # 2. the console's dump, restored by this driver.
    console_schema = Path.join(dir, "console.tql")
    console_data = Path.join(dir, "console.typedb")
    assert {_, 0} = console(console, "database export #{source} #{console_schema} #{console_data}")

    from_console = restored_name(conn)
    assert :ok = Database.import_from_files(conn, from_console, console_schema, console_data)
    assert count(conn, from_console, "$p isa person;") == 50

    # And the two dumps of the same database are the same bytes. That is the
    # strongest form of the claim: not "both are readable" but "both are the
    # same file".
    assert File.read!(console_data) == File.read!(data_path)
  end

  describe "what goes wrong" do
    test "one file for both is refused before anything is written", %{conn: conn, dir: dir} do
      source = seed(conn, 1)
      path = Path.join(dir, "both")

      assert {:error, %TypeDB.Error{kind: :config} = error} =
               Database.export_to_files(conn, source, path, path)

      assert error.message =~ "same file"
      refute File.exists?(path)
    end

    test "exporting a database that is not there leaves no files behind", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      assert {:error, %TypeDB.Error{kind: :server}} =
               Database.export_to_files(
                 conn,
                 "absent_#{System.unique_integer([:positive])}",
                 schema_path,
                 data_path
               )

      # A prefix of a backup restores into a database missing whatever came
      # after it, so a failed export leaves nothing that could be mistaken for
      # one.
      refute File.exists?(schema_path)
      refute File.exists?(data_path)
    end

    test "importing over a database that exists is the server's refusal", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      source = seed(conn, 5)
      :ok = Database.export_to_files(conn, source, schema_path, data_path)

      assert {:error, %TypeDB.Error{kind: :server}} =
               Database.import_from_files(conn, source, schema_path, data_path)

      # The database it refused to overwrite is untouched.
      assert count(conn, source, "$p isa person;") == 5
    end

    test "a missing schema file is a caller error, not a crash", %{
      conn: conn,
      dir: dir,
      data_path: data_path
    } do
      File.write!(data_path, "")

      assert {:error, %TypeDB.Error{kind: :config, reason: :enoent}} =
               Database.import_from_files(conn, restored_name(conn), Path.join(dir, "nope.tql"), data_path)
    end

    test "a missing data file is a caller error, not a crash", %{
      conn: conn,
      dir: dir,
      schema_path: schema_path
    } do
      File.write!(schema_path, "define entity person;")

      assert {:error, %TypeDB.Error{kind: :config, reason: :enoent}} =
               Database.import_from_files(conn, restored_name(conn), schema_path, Path.join(dir, "nope.data"))
    end

    test "a data file that is not an export is a decode error", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      File.write!(schema_path, "define entity person;")
      File.write!(data_path, :binary.copy(<<0xFF>>, 64))

      assert {:error, %TypeDB.Error{kind: :decode}} =
               Database.import_from_files(conn, restored_name(conn), schema_path, data_path)
    end

    test "a truncated data file is a decode error rather than a short import", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      source = seed(conn, 100)
      :ok = Database.export_to_files(conn, source, schema_path, data_path)

      full = File.read!(data_path)
      File.write!(data_path, binary_part(full, 0, byte_size(full) - 5))

      assert {:error, %TypeDB.Error{kind: :decode}} =
               Database.import_from_files(conn, restored_name(conn), schema_path, data_path)
    end
  end
end
