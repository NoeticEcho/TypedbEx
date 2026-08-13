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
  and byte for byte; without it that one test says so and skips. CI's
  `grpc_migration_interop` job fetches a console matching the server it runs
  and fails if it cannot, so the claim is checked on every push.
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

  # Every value type TypeDB has, in one database.
  #
  # The framing this driver writes is meant to be opaque to what an item holds —
  # items go out exactly as they arrived — so the way to find out whether that
  # is true is to put the awkward ones through it: a decimal with TypeDB's fixed
  # 19-digit scale, a zoned datetime, a duration that keeps months, days and
  # nanos apart. A dump of only strings and integers would prove none of them.
  @rich_schema """
  define
    attribute name, value string;
    attribute flag, value boolean;
    attribute age, value integer;
    attribute score, value double;
    attribute price, value decimal;
    attribute born, value date;
    attribute at, value datetime;
    attribute at_tz, value datetime-tz;
    attribute lasted, value duration;
    entity person,
      owns name @key, owns flag, owns age, owns score, owns price,
      owns born, owns at, owns at_tz, owns lasted;
    relation friendship, relates friend @card(0..);
    person plays friendship:friend;
  """

  defp seed_rich(conn) do
    database = start_database(conn, "migrich")

    {:ok, _} =
      Transaction.transaction(conn, database, :schema, fn tx ->
        Transaction.query(tx, @rich_schema)
      end)

    {:ok, _} =
      Transaction.transaction(conn, database, :write, fn tx ->
        Transaction.query(tx, """
          insert
            $a isa person,
              has name "one", has flag true, has age -42, has score 1.5,
              has price 3.141592653589793238dec,
              has born 1969-07-20,
              has at 2024-03-01T12:00:00.000,
              has at_tz 2024-03-01T12:00:00.000+05:00,
              has lasted P1Y2M3DT4H5M6S;
            $b isa person,
              has name "two", has flag false, has age 0, has score -0.25,
              has price -0.0000000000000000001dec,
              has born 0001-01-01,
              has at 9999-12-31T23:59:59.999,
              has at_tz 1970-01-01T00:00:00.000-11:30,
              has lasted P0Y;
            (friend: $a, friend: $b) isa friendship;
        """)
      end)

    database
  end

  defp values(conn, database, name) do
    {:ok, answer} =
      Transaction.transaction(conn, database, :read, fn tx ->
        Transaction.query(tx, """
          match $p isa person, has name == "#{name}",
            has flag $f, has age $g, has score $s, has price $pr,
            has born $b, has at $t, has at_tz $z, has lasted $l;
          select $f, $g, $s, $pr, $b, $t, $z, $l;
        """)
      end)

    row = answer |> TypeDB.Answer.rows() |> hd()

    Map.new(~w(f g s pr b t z l), &{&1, TypeDB.ConceptRow.typed_value(row, &1)})
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

    test "every value type comes back as the same value", %{
      conn: conn,
      schema_path: schema_path,
      data_path: data_path
    } do
      source = seed_rich(conn)
      before = %{"one" => values(conn, source, "one"), "two" => values(conn, source, "two")}

      assert :ok = Database.export_to_files(conn, source, schema_path, data_path)

      restored = restored_name(conn)
      assert :ok = Database.import_from_files(conn, restored, schema_path, data_path)

      # Value by value rather than count by count. A dump is only a backup if a
      # decimal comes back with its scale, a zoned datetime with its offset, and
      # a duration with months, days and nanos still held apart.
      for name <- ["one", "two"] do
        assert values(conn, restored, name) == before[name], "#{name} changed across the round trip"
      end

      assert %TypeDB.DateTimeTZ{} = before["one"]["z"]
      assert %TypeDB.Duration{months: 14, days: 3} = before["one"]["l"]
      assert count(conn, restored, "$f isa friendship;") == 1
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
      case System.get_env("TYPEDB_CONSOLE") do
        nil ->
          # Skipped rather than failed when the console is not on this machine:
          # the same posture as the rest of the suite, which skips without a
          # server rather than pretending the absence is a defect. The
          # `grpc_migration_interop` CI job sets it, so this is covered on every
          # push and not only when somebody remembers.
          IO.puts(:stderr, "skipping the console interop test: set TYPEDB_CONSOLE to the typedb binary")

        "" ->
          IO.puts(:stderr, "skipping the console interop test: TYPEDB_CONSOLE is empty")

        console ->
          # Set but unusable is a different thing from unset, and it must not
          # pass quietly: that is exactly how a CI job goes green while proving
          # nothing.
          assert File.exists?(console), "TYPEDB_CONSOLE is set to #{console}, which is not there"
          interop(conn, console, dir, schema_path, data_path)
      end
    end
  end

  defp interop(conn, console, dir, schema_path, data_path) do
    # The rich database rather than the plain one: a format claim made only over
    # strings and integers is a claim about the easy half. This carries a
    # decimal at TypeDB's fixed scale, a zoned datetime, and a duration.
    source = seed_rich(conn)
    before = values(conn, source, "one")

    assert :ok = Database.export_to_files(conn, source, schema_path, data_path)

    # 1. this driver's dump, restored by the console.
    from_driver = restored_name(conn)

    assert {output, 0} = console(console, "database import #{from_driver} #{schema_path} #{data_path}"),
           "the console refused this driver's dump"

    assert output =~ "Successfully imported"
    assert values(conn, from_driver, "one") == before
    assert count(conn, from_driver, "$f isa friendship;") == 1

    # 2. the console's dump, restored by this driver.
    console_schema = Path.join(dir, "console.tql")
    console_data = Path.join(dir, "console.typedb")

    assert {_, 0} = console(console, "database export #{source} #{console_schema} #{console_data}"),
           "the console could not export the database this driver wrote"

    from_console = restored_name(conn)
    assert :ok = Database.import_from_files(conn, from_console, console_schema, console_data)
    assert values(conn, from_console, "one") == before
    assert count(conn, from_console, "$p isa person;") == 2

    # And the two dumps of the same database are the same bytes. That is the
    # strongest form of the claim: not "both are readable" but "both are the
    # same file".
    assert File.read!(console_data) == File.read!(data_path),
           "this driver's data file and the console's differ for the same database"

    assert File.read!(console_schema) == File.read!(schema_path)
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

    test "a data file that cannot be opened leaves no schema file either", %{
      conn: conn,
      dir: dir,
      schema_path: schema_path
    } do
      source = seed(conn, 2)

      # Audit VI, VI-2. The schema file opens first and the data file second, so
      # a failure on the second used to leave the first open and on disk — an
      # empty file that looks like a backup, which the module's own docs promise
      # cannot happen.
      assert {:error, %TypeDB.Error{kind: :config, reason: :enoent}} =
               Database.export_to_files(conn, source, schema_path, Path.join(dir, "no/such/dir/data"))

      refute File.exists?(schema_path)
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
