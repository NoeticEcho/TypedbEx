defmodule TypeDB.TokenRenewalIntegrationTest do
  @moduledoc """
  Drives token renewal against a real server whose tokens expire in seconds.

  TypeDB's default token lifetime is far longer than any request, so renewal is
  almost never exercised by an ordinary integration run. This suite shortens the
  lifetime until expiry lands in the middle of live traffic, which is the only
  way to see whether renewal actually holds up.

  Skipped unless `TYPEDB_SHORT_TOKEN_URL` is set. Start a second server with:

      typedb server \\
        --server.listen-address 127.0.0.1:1731 \\
        --server.http.enabled true --server.http.listen-address 127.0.0.1:8001 \\
        --server.authentication.token-expiration-seconds 5 \\
        --storage.data-directory /tmp/typedb-short-token

  Then:

      TYPEDB_SHORT_TOKEN_URL=http://127.0.0.1:8001 \\
        TYPEDB_SHORT_TOKEN_SECONDS=5 mix test --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :token_renewal
  @moduletag timeout: 300_000

  alias TypeDB.{Answer, Database, Transaction}

  @schema "define attribute name, value string; entity person, owns name;"

  # Reporting three passing tests when the server they need is not configured is
  # worse than reporting none: CI showed green for a suite that never ran.
  @moduletag :short_token
  if is_nil(System.get_env("TYPEDB_SHORT_TOKEN_URL")) do
    @moduletag skip: "set TYPEDB_SHORT_TOKEN_URL to run the token renewal suite"
  end

  setup_all do
    case System.get_env("TYPEDB_SHORT_TOKEN_URL") do
      nil ->
        {:ok, skip: true}

      url ->
        name = :typedb_short_token
        ttl = String.to_integer(System.get_env("TYPEDB_SHORT_TOKEN_SECONDS", "5"))

        {:ok, pid} =
          TypeDB.start_link(
            name: name,
            url: url,
            username: System.get_env("TYPEDB_SHORT_TOKEN_USERNAME", "admin"),
            password: System.get_env("TYPEDB_SHORT_TOKEN_PASSWORD", "password"),
            http: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}
          )

        on_exit(fn ->
          # Linked to the test process, so it may already be shutting down.
          try do
            TypeDB.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok, conn: name, ttl_ms: ttl * 1_000}
    end
  end

  setup context do
    database = TypeDB.Case.unique_name("renewal_test")
    :ok = Database.create(context.conn, database)
    {:ok, _} = TypeDB.query(context.conn, database, @schema)
    on_exit(fn -> Database.delete(context.conn, database) end)

    {:ok, database: database}
  end

  test "a wide concurrent burst survives token expiry", context do
    %{conn: conn, database: database, ttl_ms: ttl_ms} = context

    # Warm the connection pool, then wait out the token so the burst starts
    # with one that is already dead.
    assert {:ok, _} = Database.list(conn)
    Process.sleep(ttl_ms + 1_000)

    results =
      1..200
      |> Task.async_stream(
        fn _ -> TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read) end,
        max_concurrency: 200,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    failures = Enum.reject(results, &match?({:ok, _}, &1))
    assert failures == [], "#{length(failures)}/200 failed, e.g. #{inspect(Enum.take(failures, 2))}"
  end

  test "concurrent writes across an expiry all land", context do
    %{conn: conn, database: database, ttl_ms: ttl_ms} = context

    assert {:ok, _} = Database.list(conn)
    Process.sleep(ttl_ms + 1_000)

    results =
      1..100
      |> Task.async_stream(
        fn i -> TypeDB.query(conn, database, ~s(insert $p isa person, has name "W#{i}";)) end,
        max_concurrency: 100,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.reject(results, &match?({:ok, _}, &1)) == []

    assert {:ok, answer} =
             TypeDB.query(conn, database, "match $p isa person;",
               transaction_type: :read,
               answer_count_limit: 10_000
             )

    assert length(Answer.rows(answer)) == 100
  end

  test "a transaction that outlives its token still commits", context do
    %{conn: conn, database: database, ttl_ms: ttl_ms} = context

    assert :ok =
             TypeDB.transaction(conn, database, :write, fn tx ->
               # The token that opened this transaction is gone by the time the
               # query and the commit go out.
               Process.sleep(ttl_ms + 1_000)
               {:ok, _} = Transaction.query(tx, ~s(insert $p isa person, has name "Patient";))
               :ok
             end)

    assert {:ok, answer} =
             TypeDB.query(conn, database, "match $p isa person;", transaction_type: :read)

    assert length(Answer.rows(answer)) == 1
  end
end
