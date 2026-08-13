defmodule TypeDB.GRPC.TLSIntegrationTest do
  @moduledoc """
  The driver's TLS posture, against a real TLS-enabled TypeDB.

  The assertion that matters is the negative one: a server this machine does not
  trust must be **refused**, not accepted with a shrug. A driver that verified
  nothing would pass every positive test in this file.

  Skipped unless `TYPEDB_GRPC_TLS_ADDRESS` and `TYPEDB_GRPC_TLS_CACERTFILE` are
  set. To run them, mint a CA and a server certificate:

      openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 30 -nodes \\
        -subj "/CN=TypeDB Test CA"
      openssl req -newkey rsa:2048 -keyout server.key -out server.csr -nodes \\
        -subj "/CN=localhost"
      printf "subjectAltName=DNS:localhost,IP:127.0.0.1\\nextendedKeyUsage=serverAuth\\n" > ext.cnf
      openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \\
        -out server.pem -days 30 -extfile ext.cnf

  Start TypeDB with encryption on — it covers the gRPC port as well as the HTTP
  one:

      typedb server \\
        --server.http.enabled true --server.http.listen-address 127.0.0.1:8443 \\
        --server.address 127.0.0.1:1730 \\
        --server.encryption.enabled true \\
        --server.encryption.certificate ./server.pem \\
        --server.encryption.certificate-key ./server.key

  And run:

      TYPEDB_GRPC_TLS_ADDRESS=localhost:1730 \\
      TYPEDB_GRPC_TLS_CACERTFILE=./ca.pem \\
      mix test --include tls
  """

  use ExUnit.Case, async: false

  # Deliberately *not* tagged `:integration`: this needs its own TLS-enabled
  # server, so `--include integration` must not drag it in. The sibling's TLS
  # suite makes the same choice for the same reason.
  @moduletag :tls
  @moduletag timeout: 120_000

  alias TypeDB.GRPC.Connection

  setup_all do
    address = System.get_env("TYPEDB_GRPC_TLS_ADDRESS")
    cacertfile = System.get_env("TYPEDB_GRPC_TLS_CACERTFILE")

    if is_nil(address) or is_nil(cacertfile) do
      {:ok, skip: true}
    else
      {:ok,
       address: address,
       cacertfile: cacertfile,
       username: System.get_env("TYPEDB_GRPC_TLS_USERNAME", "admin"),
       password: System.get_env("TYPEDB_GRPC_TLS_PASSWORD", "password")}
    end
  end

  setup context do
    unless context[:skip] do
      # `start_link/1` links, and a connection whose `init/1` stops takes its
      # caller with it unless the caller traps. Getting this wrong is how a test
      # for a failure hangs instead of asserting one.
      Process.flag(:trap_exit, true)
    end

    :ok
  end

  defp start(context, opts) do
    name = :"tls_#{System.unique_integer([:positive])}"

    result =
      Connection.start_link(
        [
          name: name,
          address: context.address,
          username: context.username,
          password: context.password
        ] ++ opts
      )

    case result do
      {:ok, pid} ->
        on_exit(fn -> stop(pid) end)
        {:ok, name}

      other ->
        other
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Connection.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  describe "a server whose certificate this machine trusts" do
    test "connects, and everything works over it", context do
      if context[:skip] do
        :ok
      else
        {:ok, conn} =
          start(context, tls: true, tls_opts: [cacertfile: context.cacertfile])

        assert :ok = TypeDB.GRPC.health(conn)
        assert {:ok, %{version: version}} = TypeDB.GRPC.version(conn)
        assert version =~ ~r/^\d+\.\d+\.\d+/

        database = "tls_#{System.unique_integer([:positive])}"
        on_exit(fn -> TypeDB.GRPC.delete_database(conn, database) end)

        assert :ok = TypeDB.GRPC.create_database(conn, database)

        assert {:ok, _} =
                 TypeDB.GRPC.query(
                   conn,
                   database,
                   "define attribute name, value string; entity person, owns name;"
                 )

        assert {:ok, _} =
                 TypeDB.GRPC.query(conn, database, ~s|insert $p isa person, has name "over tls";|,
                   transaction_type: :write
                 )

        assert {:ok, answer} =
                 TypeDB.GRPC.query(conn, database, "match $p isa person, has name $n; select $n;",
                   transaction_type: :read
                 )

        assert [row] = TypeDB.Answer.rows(answer)
        assert TypeDB.ConceptRow.typed_value(row, "n") == "over tls"
      end
    end

    test ":tls_root_ca is the same thing without the :ssl vocabulary", context do
      if context[:skip] do
        :ok
      else
        # The shorthand for a private CA, and the counterpart of Rust's
        # `enabled_with_root_ca`. Worth its own test rather than trusting the
        # unit test on `ssl_options/1`: what matters is that `:ssl` accepts what
        # this produces, and only a handshake can say that.
        {:ok, conn} = start(context, tls: true, tls_root_ca: context.cacertfile)

        assert :ok = TypeDB.GRPC.health(conn)
      end
    end

    test "a streamed read works over TLS too", context do
      if context[:skip] do
        :ok
      else
        {:ok, conn} = start(context, tls: true, tls_opts: [cacertfile: context.cacertfile])

        database = "tlss_#{System.unique_integer([:positive])}"
        on_exit(fn -> TypeDB.GRPC.delete_database(conn, database) end)
        :ok = TypeDB.GRPC.create_database(conn, database)

        {:ok, _} =
          TypeDB.GRPC.query(
            conn,
            database,
            "define attribute name, value string; entity person, owns name;"
          )

        {:ok, _} =
          TypeDB.GRPC.query(conn, database, "given $n: string; insert $p isa person, has name == $n;",
            transaction_type: :write,
            given_rows: for(i <- 1..300, do: %{"n" => "p#{i}"})
          )

        assert TypeDB.GRPC.stream(conn, database, "match $p isa person, has name $n; select $n;")
               |> Enum.count() == 300
      end
    end
  end

  describe "a server whose certificate this machine does not trust" do
    test "is refused rather than accepted", context do
      if context[:skip] do
        :ok
      else
        # The whole point of the suite. `tls: true` now means "verify against
        # this machine's trust store" — a hundred and fifty real CAs — and the
        # test CA is not one of them, so `verify_peer` must reject it. TypeDB is
        # a database: accepting an unverified server means handing credentials
        # to whoever answers the port.
        assert {:error, %TypeDB.Error{kind: :transport} = error} = start(context, tls: true)

        assert error.message =~ "unknown_ca" or error.message =~ "tls_alert",
               """
               Connecting to a server signed by an untrusted CA failed, which is right,
               but not for a reason that mentions TLS:

                 #{error.message}

               If verification has been turned off somewhere and this is now failing for
               an unrelated reason, the suite would keep passing while the driver stopped
               checking anything.
               """
      end
    end

    test "fails quickly, rather than after the adapter's hundred retries", context do
      if context[:skip] do
        :ok
      else
        # `:connect_retries` defaults to 0 for this reason. The gun adapter's own
        # default is 100, which turns "this certificate will never be trusted"
        # into a wait of tens of seconds ending in a bare `:timeout` — a failure
        # that reads as a slow server. Measured at about 200 ms with the default.
        {micros, {:error, %TypeDB.Error{}}} = :timer.tc(fn -> start(context, tls: true) end)

        assert micros < 5_000_000,
               "an untrusted CA took #{div(micros, 1000)}ms to refuse; :connect_retries is not 0"
      end
    end

    test "connects when verification is switched off explicitly", context do
      if context[:skip] do
        :ok
      else
        # Not an endorsement — an assertion that the escape hatch is an explicit
        # act rather than the default. If this ever passes *without*
        # `verify: :verify_none`, the default has silently become insecure.
        {:ok, conn} = start(context, tls: true, tls_opts: [verify: :verify_none])
        assert :ok = TypeDB.GRPC.health(conn)
      end
    end
  end

  describe "TLS and plaintext are not interchangeable" do
    test "a plaintext client against a TLS port fails, but only on the first call", context do
      if context[:skip] do
        :ok
      else
        # Recorded rather than fixed, because it cannot be fixed here. The TCP
        # connection to a TLS port succeeds — the server accepts the socket and
        # then waits for a ClientHello that never comes — so there is nothing
        # for the driver to notice at connect time. Neither `:connect_retries`
        # nor `:connect_timeout` bounds it: both are about establishing the
        # channel, and the channel *is* established.
        #
        # What the caller sees is a timeout on the first request. That is a poor
        # diagnosis for a misconfiguration, and the reason to say so here rather
        # than leave it to be discovered.
        # `call_timeout` as well as `timeout`, and that is its own small lesson:
        # the first call on a connection signs in first, and a per-call
        # `:timeout` bounds the RPC while `:call_timeout` bounds the wait on the
        # connection process doing the signing in. Passing only the former left
        # this test sitting for the full thirty seconds.
        # All three bounds, and each covers something the others do not: the
        # channel coming up, the wait on the connection process, and the RPC
        # that process makes. Leaving the last at its default meant the
        # connection stayed wedged in a sixty-second sign-in and teardown waited
        # for it, so the test took two minutes while asserting in three seconds.
        assert {:ok, conn} =
                 start(context, connect_timeout: 2_000, call_timeout: 3_000, timeout: 3_000)

        assert {:error, %TypeDB.Error{kind: kind}} = TypeDB.GRPC.version(conn, timeout: 3_000)

        assert kind in [:timeout, :transport],
               "a plaintext client reached a TLS port and got an answer, which it must not"
      end
    end
  end
end
