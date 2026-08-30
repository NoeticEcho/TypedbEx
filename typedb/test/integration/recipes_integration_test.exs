defmodule TypeDB.RecipesIntegrationTest do
  @moduledoc """
  Runs the recipes from `guides/recipes.md` against a real server.

  That guide is the most copy-pasted surface the project has — someone reading
  it wants the paging query, not an explanation of paging — and every recipe in
  it is TypeQL, which is TypeDB's to change. `guides/*.md` code blocks are
  parsed by `TypeDB.GuideTest`; parsing is not running, and a `sort` clause that
  stops being accepted parses perfectly.

  So this is the other half: the same queries, executed. When it fails against
  the `latest` job in the integration matrix, the guide is wrong and a reader
  would have found out the hard way.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set; see `TypeDB.IntegrationTest`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias TypeDB.{Answer, ConceptRow, Database, Transaction}

  defmodule Person do
    @moduledoc false
    defstruct [:name, :age]
  end

  @rows 5_000

  setup_all do
    url = System.fetch_env!("TYPEDB_INTEGRATION_URL")
    username = System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin")
    password = System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password")

    name = :typedb_recipes

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
      )

    Process.unlink(pid)

    database = TypeDB.Case.unique_name("recipes")

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

  @schema """
    define
      attribute name, value string;
      attribute email, value string;
      attribute note, value string;
      attribute age, value integer;
      entity person, owns name @key, owns age, owns email, owns note;
  """

  test "the recipes work", %{conn: conn, database: database} do
    # One test rather than several: the recipes build on each other — you cannot
    # page rows you have not loaded — and a database per recipe would spend more
    # time on setup than on the thing being checked.

    # "Get the schema in place at boot": create_if_not_exists, then define, and
    # define again, because the guide says a migration can run on every boot.
    assert :ok = Database.create_if_not_exists(conn, database)
    assert {:ok, _} = TypeDB.query(conn, database, @schema)
    assert {:ok, _} = TypeDB.query(conn, database, @schema)

    # "Load a lot of rows".
    people = for i <- 1..@rows, do: %{name: "p#{String.pad_leading("#{i}", 5, "0")}", age: rem(i, 90)}

    people
    |> Stream.map(fn person -> %{"n" => person.name, "a" => person.age} end)
    |> Stream.chunk_every(2_000)
    |> Enum.each(fn batch ->
      assert {:ok, _} =
               TypeDB.query(
                 conn,
                 database,
                 """
                   given $n: string, $a: integer;
                   insert $p isa person, has name == $n, has age == $a;
                 """,
                 transaction_type: :write,
                 given_rows: batch
               )
    end)

    # "Count without fetching".
    assert count(conn, database) == @rows

    # "Load a lot of rows" again, to check the guide's claim that a `match`
    # bigger than the cap comes back truncated rather than failing — which is
    # the reason the paging recipe exists.
    assert {:ok, whole} =
             TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
               transaction_type: :read
             )

    assert length(Answer.rows(whole)) == @rows
    assert Answer.warning(whole) == nil

    # Paging, with the guide's query verbatim.
    assert page(conn, database, 0, 3) == ["p00001", "p00002", "p00003"]
    assert page(conn, database, 3, 2) == ["p00004", "p00005"]

    # A deep offset returns the rows it should, which is the half of "deep
    # offsets are cheap" that can be asserted rather than timed.
    assert page(conn, database, @rows - 2, 5) == ["p0#{@rows - 1}", "p0#{@rows}"]

    # The Stream.resource recipe.
    assert conn |> stream(database, 1_000) |> Enum.count() == @rows

    # Paging inside one :read transaction, for a consistent snapshot.
    paged =
      TypeDB.transaction(conn, database, :read, fn tx ->
        Enum.flat_map(0..4, fn n ->
          {:ok, answer} =
            Transaction.query(tx, """
              match $p isa person, has name $n;
              select $n;
              sort $n;
              offset #{n * 1_000};
              limit 1000;
            """)

          Enum.map(answer, &ConceptRow.value(&1, "n"))
        end)
      end)

    assert length(paged) == @rows

    # "Upsert": `put` is idempotent, and does not update.
    for _ <- 1..2 do
      assert {:ok, _} =
               TypeDB.query(conn, database, ~s|put $p isa person, has name "Alice", has age 30;|,
                 transaction_type: :write
               )
    end

    assert count(conn, database, ~s|, has name "Alice"|) == 1

    # The guide's warning: `put` with a changed attribute is a key violation,
    # not an update.
    assert {:error, %TypeDB.Error{status: 400, code: "CNT9"} = error} =
             TypeDB.query(conn, database, ~s|put $p isa person, has name "Alice", has age 31;|,
               transaction_type: :write
             )

    assert error.message =~ "has been violated"

    # What does update, with `delete has $old of $p`.
    assert {:ok, _} =
             TypeDB.query(
               conn,
               database,
               """
                 given $name: string, $age: integer;
                 match $p isa person, has name == $name, has age $old;
                 delete has $old of $p;
                 insert $p has age == $age;
               """,
               transaction_type: :write,
               given_rows: [%{"name" => "Alice", "age" => 31}]
             )

    assert {:ok, ages} =
             TypeDB.query(conn, database, ~s|match $p isa person, has name "Alice", has age $a; select $a;|,
               transaction_type: :read
             )

    assert Enum.map(ages, &ConceptRow.typed_value(&1, "a")) == [31]

    # "Does this exist", which stops at one rather than counting.
    assert {:ok, _} =
             TypeDB.query(
               conn,
               database,
               ~s|match $p isa person, has name "Alice"; insert $p has email "a@b.io";|,
               transaction_type: :write
             )

    assert exists?(conn, database, "a@b.io")
    refute exists?(conn, database, "nobody@example.com")

    # "Map rows onto your own structs", which needs the `select` stage.
    assert [%Person{name: "Alice", age: 31} | _rest] =
             conn
             |> TypeDB.query!(
               database,
               """
                 match $p isa person, has name $name, has age $age;
                 select $name, $age;
                 sort $name;
                 limit 2;
               """,
               transaction_type: :read
             )
             |> Enum.map(&ConceptRow.to_struct(&1, Person, typed: true))

    # "Read your own writes".
    TypeDB.transaction(conn, database, :write, fn tx ->
      assert {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Carol";))
      assert {:ok, answer} = Transaction.query(tx, ~s(match $p isa person, has name "Carol";))
      assert length(Answer.rows(answer)) == 1
    end)

    # "Delete a lot of rows".
    Stream.repeatedly(fn ->
      {:ok, answer} =
        TypeDB.query(conn, database, "match $p isa person; limit 2000; delete $p;", transaction_type: :write)

      length(Answer.rows(answer))
    end)
    |> Enum.take_while(&(&1 > 0))

    assert count(conn, database) == 0
  end

  test "the request body size limit is what the guides say it is", %{conn: conn} do
    # Its own database: ExUnit orders tests within a module by seed, and the
    # recipes test counts every person and then deletes them all.
    database = TypeDB.Case.unique_name("recipes_size")
    on_exit(fn -> Database.delete(conn, database) end)

    # The bulk-load recipe batches by payload size rather than row count. On
    # 3.12 that is a limit; on 3.13 it is portability. Both halves are bisected
    # to the KiB through this driver and written down in `guides/recipes.md`,
    # `guides/errors-and-retries.md` and `TypeDB.Transaction.query/3`:
    #
    #   3.12.1      2047 KiB accepted, 2048 KiB refused with 400 HSR2
    #   3.13.0-rc0  every size tried accepted, up to 512 MiB; none refused
    #
    # This test asserts whichever of the two the server in front of it is, so a
    # server that moves the limit again fails a build rather than a reader's
    # bulk load. The `latest` job in the integration matrix is the one to watch.
    assert :ok = Database.create_if_not_exists(conn, database)
    assert {:ok, _} = TypeDB.query(conn, database, @schema)

    query = """
      given $n: string, $t: string;
      insert $p isa person, has name == $n, has note == $t;
    """

    # Rows of a known size, so the body can be aimed either side of the line.
    rows = fn prefix, count ->
      for i <- 1..count, do: %{"n" => "#{prefix}-#{i}", "t" => String.duplicate("x", 1_000)}
    end

    under = rows.("under", 1_800)
    over = rows.("over", 2_100)

    assert body_bytes(query, under) < 2 * 1024 * 1024
    assert body_bytes(query, over) > 2 * 1024 * 1024

    # Under 2 MiB is accepted by every server this driver supports.
    assert {:ok, _} = TypeDB.query(conn, database, query, transaction_type: :write, given_rows: under)

    # And the rows from that batch are all there, so "accepted" means the whole
    # batch landed rather than part of it.
    assert count(conn, database, ~s|, has note $t|) == 1_800

    result = TypeDB.query(conn, database, query, transaction_type: :write, given_rows: over)

    if enforces_body_limit?(conn) do
      assert {:error, %TypeDB.Error{status: 400, code: "HSR2"} = error} = result
      assert error.message =~ "length limit exceeded"
    else
      assert {:ok, _} = result
      assert count(conn, database, ~s|, has note $t|) == 1_800 + 2_100
    end
  end

  # TypeDB 3.13 stopped enforcing a request body limit. Compared on major and
  # minor alone: the server reports `3.13.0-rc0`, and `Version.match?/2` reads a
  # pre-release as *below* `3.13.0`, which would put a release candidate on the
  # wrong side of the very line it moved.
  defp enforces_body_limit?(conn) do
    {:ok, %{version: version}} = TypeDB.Server.version(conn)
    %Version{major: major, minor: minor} = Version.parse!(version)

    {major, minor} < {3, 13}
  end

  # What the driver will actually send: the tagged wire form, not the maps.
  defp body_bytes(query, rows) do
    byte_size(TypeDB.JSON.encode!(%{"query" => query, "givenRows" => TypeDB.Given.encode_rows(rows)}))
  end

  defp page(conn, database, offset, size) do
    {:ok, answer} =
      TypeDB.query(
        conn,
        database,
        """
          match $p isa person, has name $n;
          select $n;
          sort $n;
          offset #{offset};
          limit #{size};
        """,
        transaction_type: :read
      )

    Enum.map(answer, &ConceptRow.value(&1, "n"))
  end

  defp stream(conn, database, size) do
    Stream.resource(
      fn -> 0 end,
      fn offset ->
        case page(conn, database, offset, size) do
          [] -> {:halt, offset}
          names -> {names, offset + length(names)}
        end
      end,
      fn _offset -> :ok end
    )
  end

  defp count(conn, database, filter \\ "") do
    {:ok, answer} =
      TypeDB.query(conn, database, "match $p isa person#{filter}; reduce $n = count;",
        transaction_type: :read
      )

    answer |> Answer.rows() |> hd() |> ConceptRow.typed_value("n")
  end

  defp exists?(conn, database, email) do
    {:ok, answer} =
      TypeDB.query(
        conn,
        database,
        """
          given $e: string;
          match $p isa person, has email == $e;
          limit 1;
        """,
        transaction_type: :read,
        given_rows: [%{"e" => email}]
      )

    Answer.rows(answer) != []
  end
end
