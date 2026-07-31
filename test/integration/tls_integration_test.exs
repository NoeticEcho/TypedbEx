defmodule TypeDB.TLSIntegrationTest do
  @moduledoc """
  Verifies the driver's TLS posture against a real TLS-enabled TypeDB server.

  Skipped unless `TYPEDB_TLS_URL` and `TYPEDB_TLS_CACERTFILE` are set.

  To run them, first mint a CA and a server certificate:

      openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 30 -nodes \\
        -subj "/CN=TypeDB Test CA"
      openssl req -newkey rsa:2048 -keyout server.key -out server.csr -nodes \\
        -subj "/CN=localhost"
      printf "subjectAltName=DNS:localhost,IP:127.0.0.1\\nextendedKeyUsage=serverAuth\\n" > ext.cnf
      openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \\
        -out server.pem -days 30 -extfile ext.cnf

  Then start TypeDB with TLS:

      typedb server \\
        --server.http.enabled true --server.http.listen-address 127.0.0.1:8443 \\
        --server.encryption.enabled true \\
        --server.encryption.certificate ./server.pem \\
        --server.encryption.certificate-key ./server.key

  And run:

      TYPEDB_TLS_URL=https://localhost:8443 TYPEDB_TLS_CACERTFILE=./ca.pem \\
        mix test --include tls

  The hostname-mismatch test additionally needs a name that resolves to the
  server but is absent from its certificate; set `TYPEDB_TLS_WRONG_HOST_URL`
  (for example `https://wronghost.test:8443` with a matching `/etc/hosts` entry)
  to enable it.
  """

  use ExUnit.Case, async: false

  @moduletag :tls
  @moduletag :integration
  @moduletag timeout: 60_000

  alias TypeDB.Error

  setup_all do
    url = System.get_env("TYPEDB_TLS_URL")
    cacertfile = System.get_env("TYPEDB_TLS_CACERTFILE")

    if is_nil(url) or is_nil(cacertfile) do
      {:ok, skip: true}
    else
      {:ok,
       url: url,
       cacertfile: cacertfile,
       username: System.get_env("TYPEDB_TLS_USERNAME", "admin"),
       password: System.get_env("TYPEDB_TLS_PASSWORD", "password")}
    end
  end

  setup context do
    if context[:skip], do: {:ok, skip: true}, else: :ok
  end

  test "an untrusted certificate is rejected by default", context do
    # The whole point: no configuration is needed to be safe, only to be
    # permissive. The server's CA is not in the OS trust store.
    conn = start_connection(context, http: {TypeDB.HTTP.Httpc, []}, max_retries: 0)

    assert {:error, %Error{kind: :transport, message: message}} = TypeDB.health(conn)
    assert message =~ "Unknown CA" or message =~ "unknown_ca" or message =~ "certificate"
  end

  test "pinning the CA lets the whole API through", context do
    conn = start_connection(context, http: {TypeDB.HTTP.Httpc, cacertfile: context.cacertfile})

    assert :ok = TypeDB.health(conn)
    assert {:ok, %{version: version}} = TypeDB.version(conn)
    assert version =~ ~r/^3\./

    # Authenticated traffic, i.e. sign-in and a bearer token, over the same
    # verified channel.
    assert {:ok, databases} = TypeDB.databases(conn)
    assert is_list(databases)

    database = "tls_test_#{System.unique_integer([:positive])}"
    assert :ok = TypeDB.create_database(conn, database)

    try do
      assert {:ok, _} =
               TypeDB.query(conn, database, "define attribute name, value string; entity person, owns name;")

      assert {:ok, _} = TypeDB.query(conn, database, ~s(insert $p isa person, has name "Secure";))

      assert {:ok, answer} =
               TypeDB.query(conn, database, "match $p isa person, has name $n; select $n;",
                 transaction_type: :read
               )

      assert [row] = TypeDB.Answer.rows(answer)
      assert TypeDB.ConceptRow.value(row, "n") == "Secure"
    after
      TypeDB.delete_database(conn, database)
    end
  end

  test "a hostname the certificate does not cover is rejected", context do
    case System.get_env("TYPEDB_TLS_WRONG_HOST_URL") do
      nil ->
        # Needs a second name pointing at the same server; skipped when absent.
        :ok

      wrong_host_url ->
        conn =
          start_connection(context,
            url: wrong_host_url,
            http: {TypeDB.HTTP.Httpc, cacertfile: context.cacertfile},
            max_retries: 0
          )

        assert {:error, %Error{kind: :transport, message: message}} = TypeDB.health(conn)
        assert message =~ "hostname_check_failed" or message =~ "handshake"
    end
  end

  defp start_connection(context, overrides) do
    if context[:skip] do
      raise "TLS integration tests require TYPEDB_TLS_URL and TYPEDB_TLS_CACERTFILE"
    end

    name = :"typedb_tls_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          url: context.url,
          username: context.username,
          password: context.password,
          connect_timeout: 5_000
        ],
        overrides
      )

    {:ok, pid} = TypeDB.start_link(opts)

    on_exit(fn ->
      # Linked to the test process, so it may already be shutting down.
      try do
        TypeDB.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end
end
