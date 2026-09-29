defmodule TypeDB.DateTimeTZOffsetIntegrationTest do
  @moduledoc """
  Which fixed offsets TypeDB actually takes, and what it does with the others.

  `TypeDB.Wire.utc_offset!/1` refuses two kinds of offset and says in its error
  message what TypeDB would have done instead. That message is a claim about a
  server, and the stub is not the server — so the claim is measured here rather
  than asserted in a docstring:

    * `±HH:MM:SS` is a TypeQL syntax error, so a sub-minute offset has no form
      to be written in. The driver used to drop the seconds, which produced a
      literal TypeDB accepts and which names a different instant — the failure
      mode with no symptom.
    * `+24:00` and above are syntax errors too, which is what `+99:59` — the old
      renderer's output for a large offset — came back as.

  Skipped unless `TYPEDB_INTEGRATION_URL` is set.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias TypeDB.{Database, DateTimeTZ, Error, Wire}

  @schema "define attribute ts, value datetime-tz; entity moment, owns ts;"

  setup_all do
    {:ok, _pid} = TypeDB.start_link([name: :typedb_offset_integration] ++ connection_options())

    database = TypeDB.Case.unique_name("offset_test")
    :ok = Database.create(:typedb_offset_integration, database)
    {:ok, _} = TypeDB.query(:typedb_offset_integration, database, @schema)

    on_exit(fn ->
      {:ok, cleanup} = TypeDB.start_link([name: :typedb_offset_cleanup] ++ connection_options())
      Database.delete(:typedb_offset_cleanup, database)
      TypeDB.stop(cleanup)
    end)

    {:ok, conn: :typedb_offset_integration, database: database}
  end

  defp connection_options do
    [
      url: System.fetch_env!("TYPEDB_INTEGRATION_URL"),
      username: System.get_env("TYPEDB_INTEGRATION_USERNAME", "admin"),
      password: System.get_env("TYPEDB_INTEGRATION_PASSWORD", "password"),
      http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
    ]
  end

  # The literal goes into the query text on purpose. `given_rows` would send it
  # through the encoder under test, and the question here is what TypeQL's own
  # parser accepts — which is the ground the encoder has to stand on.
  defp insert(conn, database, literal) do
    TypeDB.query(conn, database, "insert $m isa moment, has ts #{literal};", transaction_type: :write)
  end

  describe "what TypeQL's datetime-tz literal accepts" do
    @stamp "2024-03-01T10:30:00.000000000"

    test "a whole-minute offset, anywhere in ±23:59", %{conn: conn, database: database} do
      for offset <- ~w(+00:00 -00:00 +01:00 -05:00 +05:30 +14:00 +23:59 -23:59) do
        assert {:ok, _} = insert(conn, database, @stamp <> offset),
               "TypeDB refused #{offset}, which TypeDB.Wire.utc_offset! is willing to render"
      end
    end

    test "not an offset carrying seconds", %{conn: conn, database: database} do
      for offset <- ~w(+00:01:15 -00:01:15 +01:01:15) do
        assert {:error, %Error{}} = insert(conn, database, @stamp <> offset),
               "TypeDB accepted #{offset}; if it takes seconds now, the driver should render them"
      end
    end

    test "not an offset at or beyond a day", %{conn: conn, database: database} do
      for offset <- ~w(+24:00 -24:00 +99:59) do
        assert {:error, %Error{}} = insert(conn, database, @stamp <> offset),
               "TypeDB accepted #{offset}, so the driver's range is narrower than the server's"
      end
    end

    test "an IANA zone name, which is what a sub-minute offset should become", %{
      conn: conn,
      database: database
    } do
      # The advice in the error message: London's offset in 1800 was -75 seconds
      # and cannot be written as one, but the zone name carries it exactly.
      assert {:ok, _} = insert(conn, database, "1800-01-01T00:00:00.000000000 Europe/London")
    end
  end

  describe "what the driver renders" do
    test "every offset the encoder renders, the server takes", %{conn: conn, database: database} do
      # Both ends and a handful between, through the encoder rather than past
      # it: this is the pair of claims that matter together — the driver refuses
      # what the server refuses, and renders what the server takes.
      for seconds <- [0, 60, -60, 19_800, -18_000, 50_400, 86_340, -86_340] do
        value = DateTimeTZ.new(~N[2024-03-01 10:30:00], seconds)

        assert {:ok, _} =
                 TypeDB.query(
                   conn,
                   database,
                   "given $t: datetime-tz; insert $m isa moment, has ts == $t;",
                   transaction_type: :write,
                   given_rows: [%{"t" => value}]
                 ),
               "TypeDB refused #{value}"
      end
    end

    test "a value written by the driver comes back as the driver wrote it", %{
      conn: conn,
      database: database
    } do
      written = DateTimeTZ.new(~N[2024-06-01 12:34:56.123456], 19_800)

      {:ok, _} =
        TypeDB.query(conn, database, "given $t: datetime-tz; insert $m isa moment, has ts == $t;",
          transaction_type: :write,
          given_rows: [%{"t" => written}]
        )

      {:ok, answer} =
        TypeDB.query(
          conn,
          database,
          "match $m isa moment, has ts $t; $t == #{written}; select $t;",
          transaction_type: :read
        )

      assert [row] = TypeDB.Answer.rows(answer)
      read = row.data["t"].value

      assert DateTimeTZ.parse(read).raw == DateTimeTZ.to_iso8601(written)
    end

    test "the refusals name offsets the server would have mishandled" do
      # The two the encoder will not write, and what the old renderer produced
      # for them — measured above to be, respectively, silently wrong and a
      # syntax error.
      assert %Error{kind: :encode} = catch_error(Wire.utc_offset!(-75))
      assert %Error{kind: :encode} = catch_error(Wire.utc_offset!(359_999))
    end
  end
end
