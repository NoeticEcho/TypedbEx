defmodule TypeDB.SharedBehaviourTest do
  @moduledoc """
  One set of assertions, run against both drivers.

  This is the reason the two packages share a repository. Two transports that
  are meant to be interchangeable will drift, and the drift will be found by
  whoever switches — unless something asserts the same thing about both. That
  is what this is.

  It covers the *overlap* and nothing else: error codes, concept decoding,
  transaction semantics, the shapes an application matches on. The parts that
  genuinely differ — streaming, pipelining, the answer cap — belong in each
  package's own suite, and where a difference is real this file records it
  rather than hiding it.

  Run with both servers reachable:

      TYPEDB_INTEGRATION_URL=http://127.0.0.1:8000 \\
      TYPEDB_GRPC_ADDRESS=127.0.0.1:1729 \\
      mix test --include integration test/behaviour

  A driver whose server is not configured is skipped, and the suite says so
  rather than passing quietly — a green run that exercised one transport is
  the failure this file exists to prevent.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @adapters [TypeDB.Behaviour.Adapter.HTTP, TypeDB.Behaviour.Adapter.GRPC]

  @schema """
  define
    attribute name, value string;
    attribute age, value integer;
    attribute score, value double;
    attribute born, value date;
    attribute at, value datetime;
    attribute at_tz, value datetime-tz;
    attribute lasted, value duration;
    entity person, owns name, owns age, owns score, owns born, owns at, owns at_tz, owns lasted;
    relation friendship, relates friend;
    person plays friendship:friend;
  """

  setup_all do
    configured = Enum.filter(@adapters, & &1.available?())

    unless configured == @adapters do
      missing = (@adapters -- configured) |> Enum.map_join(", ", & &1.name())

      IO.warn("""
      The shared behaviour suite ran against only part of the matrix: #{missing} \
      #{if length(@adapters -- configured) == 1, do: "was", else: "were"} skipped.

      This suite's whole value is comparing the two, so a partial run proves less \
      than it appears to. Set TYPEDB_INTEGRATION_URL and TYPEDB_GRPC_ADDRESS.
      """)
    end

    {:ok, configured: configured}
  end

  for adapter <- @adapters do
    describe "#{adapter.name()}" do
      setup do
        adapter = unquote(adapter)

        if adapter.available?() do
          name = :"shared_#{System.unique_integer([:positive])}"
          {:ok, conn} = adapter.connect(name)

          database = "shared_#{System.unique_integer([:positive])}"
          :ok = adapter.create_database(conn, database)
          on_exit(fn -> adapter.delete_database(conn, database) end)

          {:ok, _} = adapter.query(conn, database, @schema, :schema)

          {:ok, adapter: adapter, conn: conn, database: database}
        else
          {:ok, skip: true}
        end
      end

      @tag adapter: adapter
      test "a database it created exists, and does not after deletion", context do
        skip_or(context, fn %{adapter: adapter, conn: conn} ->
          name = "shared_life_#{System.unique_integer([:positive])}"

          refute adapter.database_exists?(conn, name)
          assert :ok = adapter.create_database(conn, name)
          assert adapter.database_exists?(conn, name)
          assert :ok = adapter.delete_database(conn, name)
          refute adapter.database_exists?(conn, name)
        end)
      end

      test "deleting a database that is not there is DBD1 on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn} ->
          assert {:error, %TypeDB.Error{} = error} =
                   adapter.delete_database(conn, "absent_#{System.unique_integer([:positive])}")

          assert error.kind == :server
          assert error.code == "DBD1"
          refute TypeDB.Error.retryable?(error)
        end)
      end

      test "a query that does not parse is TQL0 on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          assert {:error, %TypeDB.Error{code: "TQL0"} = error} =
                   adapter.query(conn, database, "this is not typeql at all", :read)

          assert error.kind == :server
          refute TypeDB.Error.retryable?(error)
        end)
      end

      test "a type that is not in the schema is INF2 on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          assert {:error, %TypeDB.Error{} = error} =
                   adapter.query(conn, database, "match $x isa unicorn;", :read)

          assert error.code == "INF2"
        end)
      end

      test "a write in a read transaction is refused on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          assert {:error, %TypeDB.Error{} = error} =
                   adapter.query(conn, database, ~s|insert $p isa person, has name "no";|, :read)

          assert error.code != nil, "the refusal carries a code on both transports"
          refute TypeDB.Error.retryable?(error)
        end)
      end

      test "a transaction that is gone is TSV12, and retryable, on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, tx} = adapter.tx_open(conn, database, :write)
          :ok = adapter.tx_close(tx)

          assert {:error, %TypeDB.Error{code: "TSV12"} = error} =
                   adapter.tx_query(tx, ~s|insert $p isa person, has name "gone";|)

          assert TypeDB.Error.retryable?(error),
                 "0.8.0 put TSV12 on retryable_codes/0; both transports must agree"
        end)
      end

      test "concepts decode into the same structs on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, _} =
            adapter.query(
              conn,
              database,
              ~s|insert $p isa person, has name "Alice", has age 30, has score 1.5;|,
              :write
            )

          {:ok, answer} =
            adapter.query(
              conn,
              database,
              "match $p isa person, has name $n, has age $a, has score $s; select $n, $a, $s;",
              :read
            )

          assert [row] = TypeDB.Answer.rows(answer)
          assert %TypeDB.ConceptRow{} = row

          # The contract an application actually depends on when it switches.
          assert TypeDB.ConceptRow.typed_value(row, "n") == "Alice"
          assert TypeDB.ConceptRow.typed_value(row, "a") == 30
          assert TypeDB.ConceptRow.typed_value(row, "s") == 1.5

          assert %TypeDB.Concept.Attribute{
                   value_type: "string",
                   type: %TypeDB.Concept.AttributeType{label: "name"}
                 } = TypeDB.ConceptRow.get(row, "n")

          assert %TypeDB.Concept.Attribute{value_type: "integer"} = TypeDB.ConceptRow.get(row, "a")
          assert %TypeDB.Concept.Attribute{value_type: "double"} = TypeDB.ConceptRow.get(row, "s")
        end)
      end

      test "an entity decodes with an iid and its type on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, _} = adapter.query(conn, database, ~s|insert $p isa person, has name "Iid";|, :write)

          {:ok, answer} =
            adapter.query(conn, database, ~s|match $p isa person, has name "Iid"; select $p;|, :read)

          assert [row] = TypeDB.Answer.rows(answer)

          assert %TypeDB.Concept.Entity{iid: iid, type: %TypeDB.Concept.EntityType{label: "person"}} =
                   TypeDB.ConceptRow.get(row, "p")

          assert is_binary(iid) and iid != ""

          assert String.match?(iid, ~r/^0x[0-9a-f]+$/),
                 """
                 An iid must read as `0x` followed by lowercase hex on both transports.

                 This is not cosmetic: an application stores an iid read over one
                 transport and compares it against one read over the other. The gRPC
                 driver sent bare hex until this assertion caught it, and the two
                 would never have matched.

                 Got: #{inspect(iid)}
                 """
        end)
      end

      test "a date round-trips to the same Date on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, _} =
            adapter.query(
              conn,
              database,
              ~s|insert $p isa person, has name "Dated", has born 1969-07-20;|,
              :write
            )

          {:ok, answer} =
            adapter.query(
              conn,
              database,
              ~s|match $p isa person, has name "Dated", has born $b; select $b;|,
              :read
            )

          assert [row] = TypeDB.Answer.rows(answer)
          assert TypeDB.ConceptRow.typed_value(row, "b") == ~D[1969-07-20]
        end)
      end

      # Added by Audit V, which found that `datetime-tz` decoded to a different
      # type *and* a different instant on the two transports. The suite compared
      # strings, integers, doubles and dates — and temporal types are exactly
      # where two independent decoders drift, because each one is a small pile
      # of arithmetic nobody reads twice.
      test "every temporal type round-trips to the same value on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, _} =
            adapter.query(
              conn,
              database,
              """
              insert $p isa person,
                has name "temporal",
                has born 1969-07-20,
                has at 2024-03-01T12:00:00.000,
                has at_tz 2024-03-01T12:00:00.000+05:00,
                has lasted P1Y2M3DT4H5M6S;
              """,
              :write
            )

          {:ok, answer} =
            adapter.query(
              conn,
              database,
              ~s|match $p isa person, has name "temporal", has born $d, has at $t, has at_tz $z, has lasted $l; select $d, $t, $z, $l;|,
              :read
            )

          assert [row] = TypeDB.Answer.rows(answer)

          assert TypeDB.ConceptRow.typed_value(row, "d") == ~D[1969-07-20]

          assert TypeDB.ConceptRow.typed_value(row, "t") == ~N[2024-03-01 12:00:00.000000],
                 "a naive datetime must be the same naive datetime on both transports"

          assert %TypeDB.DateTimeTZ{} = tz = TypeDB.ConceptRow.typed_value(row, "z"),
                 """
                 A `datetime-tz` must decode to TypeDB.DateTimeTZ on both transports.

                 It has its own struct precisely because a DateTime cannot hold "this
                 wall clock, in this zone" without a tz database, and an application
                 that matches on it keeps matching only if both drivers agree.

                 Got: #{inspect(TypeDB.ConceptRow.typed_value(row, "z"))}
                 """

          assert tz.naive == ~N[2024-03-01 12:00:00.000000],
                 "the wall clock TypeDB was given, not one shifted by the offset"

          assert tz.utc_offset == 18_000

          assert %TypeDB.Duration{months: 14, days: 3} = TypeDB.ConceptRow.typed_value(row, "l")
        end)
      end

      test "reduce count answers an integer on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          for i <- 1..5 do
            {:ok, _} = adapter.query(conn, database, ~s|insert $p isa person, has name "c#{i}";|, :write)
          end

          {:ok, answer} =
            adapter.query(conn, database, "match $p isa person; reduce $c = count;", :read)

          assert [row] = TypeDB.Answer.rows(answer)
          assert TypeDB.ConceptRow.typed_value(row, "c") == 5
        end)
      end

      test "a bracket commits on success on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          adapter.transaction(conn, database, :write, fn tx ->
            {:ok, _} = adapter.tx_query(tx, ~s|insert $p isa person, has name "Committed";|)
          end)

          assert count_named(adapter, conn, database, "Committed") == 1
        end)
      end

      test "a bracket does not commit when the body returns an error on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          assert {:error, :deliberate} =
                   adapter.transaction(conn, database, :write, fn tx ->
                     {:ok, _} = adapter.tx_query(tx, ~s|insert $p isa person, has name "Abandoned";|)
                     {:error, :deliberate}
                   end)

          assert count_named(adapter, conn, database, "Abandoned") == 0
        end)
      end

      test "a bracket does not commit when the body raises on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          assert_raise RuntimeError, "deliberate", fn ->
            adapter.transaction(conn, database, :write, fn tx ->
              {:ok, _} = adapter.tx_query(tx, ~s|insert $p isa person, has name "Raised";|)
              raise "deliberate"
            end)
          end

          assert count_named(adapter, conn, database, "Raised") == 0
        end)
      end

      test "an isolation conflict is STC2 and retryable on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, _} = adapter.query(conn, database, ~s|insert $p isa person, has name "Racer";|, :write)

          {:ok, first} = adapter.tx_open(conn, database, :write)
          {:ok, second} = adapter.tx_open(conn, database, :write)

          rename = fn tx, to ->
            adapter.tx_query(tx, """
              match $p isa person, has name "Racer", has name $old;
              delete has $old of $p;
              insert $p has name "#{to}";
            """)
          end

          {:ok, _} = rename.(first, "Racer_a")
          {:ok, _} = rename.(second, "Racer_b")

          assert :ok = adapter.tx_commit(first)
          assert {:error, %TypeDB.Error{code: "STC2"} = error} = adapter.tx_commit(second)

          assert TypeDB.Error.retryable?(error),
                 "the failure an application is meant to replay must look the same on both"

          adapter.tx_close(second)
        end)
      end

      test "an uncommitted write is invisible to another transaction on both", context do
        skip_or(context, fn %{adapter: adapter, conn: conn, database: database} ->
          {:ok, tx} = adapter.tx_open(conn, database, :write)
          {:ok, _} = adapter.tx_query(tx, ~s|insert $p isa person, has name "Uncommitted";|)

          assert count_named(adapter, conn, database, "Uncommitted") == 0,
                 "isolation is the same promise on both transports"

          assert :ok = adapter.tx_commit(tx)
          assert count_named(adapter, conn, database, "Uncommitted") == 1
        end)
      end
    end
  end

  # This began life asserting that the two transports disagreed about creating a
  # database that already exists — gRPC accepting it, HTTP rejecting it. They do
  # not disagree; `TypeDB.Database.create/3` documents the same no-op, and the
  # claim came from my reading rather than from a measurement. The suite found
  # it on its first run, which is what it is for, so the assertion is kept in
  # the corrected direction.
  describe "things that could differ and must not" do
    test "creating a database that already exists is a no-op on both" do
      for adapter <- @adapters, adapter.available?() do
        name = :"same_#{System.unique_integer([:positive])}"
        {:ok, conn} = adapter.connect(name)
        database = "same_#{System.unique_integer([:positive])}"
        :ok = adapter.create_database(conn, database)
        on_exit(fn -> adapter.delete_database(conn, database) end)

        assert :ok = adapter.create_database(conn, database),
               "#{adapter.name()} rejected a create of an existing database"

        assert adapter.database_exists?(conn, database)
      end
    end

    test "the cluster looks the same through both" do
      # `servers/2` is the one call that describes the deployment rather than
      # the data, and it landed on gRPC long after HTTP had it. The shape is the
      # thing worth pinning: string keys and "address", so that a caller
      # switching transports keeps its pattern matches.
      answers =
        for adapter <- @adapters, adapter.available?() do
          {:ok, conn} = adapter.connect(:"servers_#{System.unique_integer([:positive])}")
          assert {:ok, [_ | _] = servers} = adapter.servers(conn)
          assert Enum.all?(servers, &is_map_key(&1, "address")), "#{adapter.name()} omitted \"address\""
          servers
        end

      if length(answers) == 2 do
        [http, grpc] = answers
        assert Enum.map(http, & &1["address"]) == Enum.map(grpc, & &1["address"])
      end
    end
  end

  defp skip_or(context, fun) do
    if context[:skip], do: :ok, else: fun.(context)
  end

  defp count_named(adapter, conn, database, name) do
    {:ok, answer} =
      adapter.query(conn, database, ~s|match $p isa person, has name == "#{name}"; reduce $c = count;|, :read)

    answer |> TypeDB.Answer.rows() |> hd() |> TypeDB.ConceptRow.typed_value("c")
  end
end
