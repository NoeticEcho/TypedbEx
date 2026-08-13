defmodule TypeDB.RestartIntegrationTest do
  @moduledoc """
  Takes the server away mid-traffic and gives it back.

  `TypeDB.Connection`'s moduledoc names "a restarted server" as one of the three
  things reactive token renewal exists for, and
  `guides/errors-and-retries.md` talks about an ingress answering "while TypeDB
  restarts". Neither had been run. A restart is not one failure but three at the
  same instant: the token the connection is holding may no longer be honoured,
  every socket in the adapter's pool is dead, and the port itself stops
  answering — and an operator upgrading TypeDB wants to know whether the
  application recovers on its own or has to be restarted after it.

  The answer this suite pins is: on its own. Calls during the outage fail with
  `kind: :transport`, carrying whichever reason the adapter reports, and the
  first call after the port reopens succeeds. Nothing is reset, reopened or
  signalled by the caller.

  Skipped unless `TYPEDB_RESTART_URL`, `TYPEDB_RESTART_STOP` and
  `TYPEDB_RESTART_START` are set — the last two being shell commands that take
  that server down and bring it back:

      docker run -d --name typedb-restart -p 8002:8000 typedb/typedb:3.12.1

      TYPEDB_RESTART_URL=http://127.0.0.1:8002 \\
        TYPEDB_RESTART_STOP="docker stop typedb-restart" \\
        TYPEDB_RESTART_START="docker start typedb-restart" \\
        mix test test/integration/restart_integration_test.exs --include integration

  Stop and start rather than one `restart`, because a restart fast enough to
  miss would leave the outage half of this untested while still passing.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :restart
  @moduletag timeout: 600_000

  alias TypeDB.{Answer, Error}

  # The suite is meaningless without a server it is allowed to kill, and a
  # skipped test that reports as passing is how a job goes green having run
  # nothing.
  if is_nil(System.get_env("TYPEDB_RESTART_URL")) do
    @moduletag skip: "set TYPEDB_RESTART_URL, TYPEDB_RESTART_STOP and TYPEDB_RESTART_START"
  end

  @schema "define attribute name, value string; entity person, owns name;"

  setup_all do
    url = System.fetch_env!("TYPEDB_RESTART_URL")
    username = System.get_env("TYPEDB_RESTART_USERNAME", "admin")
    password = System.get_env("TYPEDB_RESTART_PASSWORD", "password")

    name = :typedb_restart

    {:ok, pid} =
      TypeDB.start_link(
        name: name,
        url: url,
        username: username,
        password: password,
        http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []},
        # A failure during the outage is the observation, not an obstacle: with
        # the default retries a call would spend most of the outage inside one
        # request and report the last attempt rather than the first.
        max_retries: 0,
        connect_timeout: 2_000,
        timeout: 5_000
      )

    Process.unlink(pid)

    database = TypeDB.Case.unique_name("restart")
    :ok = TypeDB.Database.create(name, database)
    {:ok, _} = TypeDB.query(name, database, @schema)

    on_exit(fn ->
      # Best effort: if the server is down because a test left it that way,
      # there is nothing to clean up on it.
      _ = System.cmd("sh", ["-c", System.get_env("TYPEDB_RESTART_START", "true")], stderr_to_stdout: true)
      _ = TypeDB.Database.delete(name, database)

      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, conn: name, database: database}
  end

  test "the connection survives the server going away and coming back", %{
    conn: conn,
    database: database
  } do
    {:ok, _} =
      TypeDB.query(conn, database, ~s|insert $p isa person, has name "before";|, transaction_type: :write)

    # Sockets in the pool, so that the outage costs established connections
    # rather than only refusing new ones. Without this the adapter has nothing
    # stale to recover from and the test proves less than it says.
    burst(conn, database)

    {_, 0} = shell("TYPEDB_RESTART_STOP")

    # During the outage. Every one of these is a failure — what matters is that
    # it is the honest one: a transport failure the caller can classify, not a
    # crash and not an authentication error blamed on the credentials.
    errors = for _ <- 1..5, do: query(conn, database)

    for error <- errors do
      assert {:error, %Error{kind: kind} = raised} = error
      assert kind == :transport, "during the outage a call reported #{kind}: #{raised.message}"
      # The adapter's own reason is passed through rather than flattened, which
      # is what makes `:econnrefused` distinguishable from a refused request.
      assert raised.reason != nil
    end

    {_, 0} = shell("TYPEDB_RESTART_START")

    # Recovery, with no help from the caller: the same connection, never
    # restarted, never told the server came back.
    assert {:ok, answer} = eventually(fn -> query(conn, database) end)
    assert length(Answer.rows(answer)) == 1

    # And under concurrency, where a pool that kept its dead sockets would show
    # what a single sequential call can miss.
    assert burst(conn, database) == %{ok: 12}
  end

  defp query(conn, database) do
    TypeDB.query(conn, database, "match $p isa person, has name $n;", transaction_type: :read)
  end

  defp burst(conn, database) do
    1..12
    |> Task.async_stream(fn _ -> query(conn, database) end, max_concurrency: 12, timeout: 60_000)
    |> Enum.map(fn {:ok, result} -> elem(result, 0) end)
    |> Enum.frequencies()
  end

  # A server takes as long as it takes to open its port again, and how long that
  # is belongs to the machine rather than to the driver.
  defp eventually(fun, remaining \\ 120_000) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, error} when remaining <= 0 ->
        flunk("the server did not come back within two minutes: #{error.message}")

      {:error, _} ->
        Process.sleep(1_000)
        eventually(fun, remaining - 1_000)
    end
  end

  defp shell(variable) do
    System.cmd("sh", ["-c", System.fetch_env!(variable)], stderr_to_stdout: true)
  end
end
