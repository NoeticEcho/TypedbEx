defmodule TypeDB.DefaultLoggerTest do
  # `attach_default_logger/1` installs a *global* telemetry handler, so these
  # tests would otherwise log the traffic of every other test running beside
  # them — and capture_log/1 would catch it.
  use TypeDB.Case, async: false

  describe "attach_default_logger/1" do
    import ExUnit.CaptureLog

    setup do
      on_exit(fn -> TypeDB.Telemetry.detach_default_logger() end)
      :ok
    end

    @tag stub_opts: [databases: ["social"]]
    test "writes a line per operation", %{conn: conn} do
      assert :ok = TypeDB.Telemetry.attach_default_logger(:info)

      log = capture_log(fn -> TypeDB.Database.get(conn, "social") end)

      assert log =~ "[info]"
      assert log =~ "TypeDB GET /databases/:name"
      assert log =~ "ms"
    end

    @tag stub_opts: [databases: ["social"]]
    test "writes a line per bracketed transaction", %{conn: conn} do
      assert :ok = TypeDB.Telemetry.attach_default_logger(:info)

      log = capture_log(fn -> TypeDB.transaction(conn, "social", :write, fn _tx -> :ok end) end)

      assert log =~ "TypeDB transaction write on social"
      assert log =~ "outcome=commit"
    end

    test "reports the error on a failed call", %{conn: conn} do
      assert :ok = TypeDB.Telemetry.attach_default_logger(:info)

      log = capture_log(fn -> TypeDB.Database.get(conn, "nope") end)

      assert log =~ "server:"
    end

    test "attaching twice is refused rather than doubling the lines" do
      assert :ok = TypeDB.Telemetry.attach_default_logger()
      assert {:error, :already_exists} = TypeDB.Telemetry.attach_default_logger()
    end

    @tag stub_opts: [databases: ["social"]]
    test "nothing is logged unless it is attached", %{conn: conn} do
      assert capture_log(fn -> TypeDB.Database.get(conn, "social") end) == ""
    end

    test "detaching stops it", %{conn: conn} do
      assert :ok = TypeDB.Telemetry.attach_default_logger(:info)
      assert :ok = TypeDB.Telemetry.detach_default_logger()

      assert capture_log(fn -> TypeDB.Database.list(conn) end) == ""
    end
  end
end
