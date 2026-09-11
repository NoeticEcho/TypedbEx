defmodule TypeDB.GRPC.ReconnectIntegrationTest do
  @moduledoc """
  That a connection survives its transport dying underneath it.

  This is the test that was missing on 11.09.2026, when a production pipeline
  moved to this driver and stalled for six hours with nothing in the log but
  timeouts. gun was opened with `retry: 0`, so when the connection dropped the
  gun process died; the adapter kept its pid and kept casting requests into it
  — a cast to a dead process is dropped without a word — and every caller
  waited its full timeout for an answer nobody would send. A fresh connection
  on the same node worked in 92 ms.

  The official drivers reconnect at the channel and never notice. This suite
  is what keeps that true here: kill the transport, and the next call has to go
  through.
  """

  use TypeDB.GRPC.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias TypeDB.GRPC.{Connection, Telemetry, Transaction}

  setup_all do
    if address(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip] do
      :ok
    else
      conn = start_connection()
      {:ok, conn: conn}
    end
  end

  defp watch_connection_events do
    parent = self()
    ref = make_ref()
    handler = "reconnect-#{System.unique_integer([:positive])}"

    events = [Telemetry.connection_event() ++ [:down], Telemetry.connection_event() ++ [:up]]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn [:typedb, :connection, what], _measurements, metadata, _ ->
          send(parent, {ref, what, metadata})
        end,
        nil
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  # gun's state is a record whose shape this test does not depend on beyond one
  # fact: the socket is in it, and a plaintext socket is a port. Closing the port
  # from outside is a TCP close as far as gun can tell.
  defp hang_up(gun) do
    {_state_name, data} = :sys.get_state(gun)
    port = data |> Tuple.to_list() |> Enum.find(&is_port/1)
    assert port, "no plaintext socket in gun's state — is TYPEDB_GRPC_ADDRESS a TLS server?"
    true = :erlang.port_close(port)
  end

  defp kill_transport(conn) do
    # The gun pid is reached through the adapter's private state. That reach is
    # deliberate and pinned by the assertion: the day the adapter renames the
    # key, this fails here, loudly, instead of the connection quietly losing
    # its watcher in production.
    assert {:ok, gun} = Connection.gun_pid(conn),
           "the connection cannot see its gun process — the adapter's state shape has moved"

    assert Process.alive?(gun)
    Process.exit(gun, :kill)
    gun
  end

  test "the next call after the transport dies goes through", context do
    if context[:skip] do
      :ok
    else
      conn = context.conn
      assert :ok = TypeDB.GRPC.health(conn)

      ref = watch_connection_events()
      old_gun = kill_transport(conn)

      assert_receive {^ref, :down, %{connection: ^conn, transport: :grpc}}, 5_000
      assert_receive {^ref, :up, %{connection: ^conn, reconnects: 1}}, 5_000

      # Not merely "a call works": the call works ON A NEW TRANSPORT. Without
      # the second assertion, a driver that somehow kept the old pid alive
      # would pass a test about reconnecting.
      assert :ok = TypeDB.GRPC.health(conn)
      assert {:ok, new_gun} = Connection.gun_pid(conn)
      refute new_gun == old_gun
      assert Process.alive?(new_gun)
    end
  end

  test "a transaction opened after the transport died works", context do
    if context[:skip] do
      :ok
    else
      conn = context.conn
      database = start_database(conn)

      {:ok, _} = TypeDB.GRPC.query(conn, database, "define entity thing;")

      ref = watch_connection_events()
      kill_transport(conn)
      assert_receive {^ref, :up, _}, 5_000

      # A transaction is the long-lived stream, and the thing production was
      # actually doing when it stalled. It has to open on the rebuilt channel
      # with a token minted on the rebuilt channel.
      assert {:ok, 1} =
               Transaction.transaction(conn, database, :write, fn tx ->
                 {:ok, _} = Transaction.query(tx, "insert $t isa thing;")
                 {:ok, answer} = Transaction.query(tx, "match $t isa thing; select $t;")
                 {:ok, length(answer.rows)}
               end)
    end
  end

  test "a transaction in flight when the transport dies fails as :transport, not by hanging",
       context do
    if context[:skip] do
      :ok
    else
      conn = context.conn
      database = start_database(conn)
      {:ok, _} = TypeDB.GRPC.query(conn, database, "define entity thing;")

      result =
        Transaction.transaction(conn, database, :read, fn tx ->
          {:ok, _} = Transaction.query(tx, "match $t isa thing; select $t;")
          kill_transport(conn)
          # Bounded: what this asserts is that the answer comes back at all,
          # and as an error a caller can retry on. The old behaviour was the
          # full `timeout` of silence.
          Transaction.query(tx, "match $t isa thing; select $t;", timeout: 10_000)
        end)

      assert {:error, %TypeDB.Error{kind: :transport}} = result
    end
  end

  test "a transaction in flight when the far side hangs up fails as :transport, not :decode",
       context do
    if context[:skip] do
      :ok
    else
      conn = context.conn
      database = start_database(conn)
      {:ok, _} = TypeDB.GRPC.query(conn, database, "define entity thing;")

      # The graceful close is the one production actually meets — the edge
      # hanging up every few minutes — and it travels a different road from a
      # kill: gun reports `gun_down`, the adapter forwards `{:connection_error,
      # reason}` down every live stream, and until 0.2.2 that arrived as a
      # `:decode` error, which a caller reads as terminal.
      # Not `:gun.shutdown/1`: that is *our* side being polite, and gun lets every
      # open stream finish first — the query below simply succeeds. The far side
      # hanging up is the socket going away under gun, which is what closing it
      # from outside produces: `tcp_closed`, then `gun_down` with every stream
      # listed as killed.
      result =
        Transaction.transaction(conn, database, :read, fn tx ->
          {:ok, _} = Transaction.query(tx, "match $t isa thing; select $t;")
          {:ok, gun} = Connection.gun_pid(conn)
          hang_up(gun)
          Transaction.query(tx, "match $t isa thing; select $t;", timeout: 10_000)
        end)

      assert {:error, %TypeDB.Error{kind: :transport}} = result
    end
  end
end
