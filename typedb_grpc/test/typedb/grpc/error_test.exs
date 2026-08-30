defmodule TypeDB.GRPC.ErrorTest do
  use ExUnit.Case, async: true

  doctest TypeDB.GRPC.Error

  alias TypeDB.GRPC.Error, as: GRPCError

  # The envelopes below are the ones a live 3.12.1 actually sends, recorded from
  # a real server rather than invented — the same discipline the sibling
  # driver's stub is held to, and for the same reason: this module's whole job
  # is reading a shape that only the server produces.
  defp detail(module, struct) do
    %Google.Protobuf.Any{
      type_url: "type.googleapis.com/#{module}",
      value: struct.__struct__.encode(struct)
    }
  end

  defp error_info(reason, domain) do
    detail("google.rpc.ErrorInfo", %Google.Rpc.ErrorInfo{reason: reason, domain: domain})
  end

  defp debug_info(entries) do
    detail("google.rpc.DebugInfo", %Google.Rpc.DebugInfo{stack_entries: entries})
  end

  describe "from_rpc_error/2" do
    test "reads the TypeDB code out of ErrorInfo" do
      rpc = %GRPC.RPCError{
        status: 3,
        message: "Request generated error",
        details: [
          debug_info([
            "[DBD1] Cannot delete database since it does not exist.",
            "[SRV13] Unable to delete database."
          ]),
          error_info("DBD1", "Database delete")
        ]
      }

      error = GRPCError.from_rpc_error(rpc, "deleting a database")

      assert error.kind == :server
      assert error.code == "DBD1"
      assert error.status == 400
      assert error.reason == {:grpc_status, 3}
      assert error.message =~ "does not exist"
      assert error.message =~ "SRV13", "the cause trace is part of the message, as it is over HTTP"
    end

    test "bad credentials are :unauthenticated, not :server" do
      rpc = %GRPC.RPCError{
        status: 16,
        message: "Unauthenticated",
        details: [
          debug_info(["[AUT1] Invalid credential supplied.", "[SRV15] Error when authenticating."]),
          error_info("AUT1", "Authentication")
        ]
      }

      error = GRPCError.from_rpc_error(rpc, "signing in")

      assert error.kind == :unauthenticated
      assert error.code == "AUT1"
      assert error.status == 401
      refute TypeDB.Error.retryable?(error), "a rejected password is as wrong on the next attempt"
    end

    test "an isolation conflict routes the same as it does over HTTP" do
      # The point of sharing %TypeDB.Error{}: this is the failure an application
      # must replay, and it must be recognisable identically on both transports.
      rpc = %GRPC.RPCError{
        status: 3,
        message: "Request generated error",
        details: [
          debug_info(["[STC2] Transaction uses a lock held by a concurrent commit."]),
          error_info("STC2", "Transaction commit")
        ]
      }

      error = GRPCError.from_rpc_error(rpc, "committing")

      assert error.code == "STC2"
      assert TypeDB.Error.retryable?(error)
    end

    test "a vanished transaction routes the same as it does over HTTP" do
      rpc = %GRPC.RPCError{
        status: 5,
        message: "Not found",
        details: [
          debug_info(["[TSV12] Operation failed: no open transaction."]),
          error_info("TSV12", "Transaction")
        ]
      }

      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.status == 404, "the same status the HTTP API reports for this code"
      assert TypeDB.Error.retryable?(error)
    end

    test "the server being unavailable is retryable on its status alone" do
      # No TypeDB code here — the request never reached TypeDB. This is the case
      # a nil status would have made terminal, and the reason :status is filled
      # at all.
      rpc = %GRPC.RPCError{status: 14, message: "Unavailable", details: []}
      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.kind == :transport
      assert error.status == 503
      assert TypeDB.Error.retryable?(error)
    end

    test "load shedding maps onto the status the sibling driver retries" do
      rpc = %GRPC.RPCError{status: 8, message: "Resource exhausted", details: []}
      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.status == 429
      assert error.status in TypeDB.Error.retryable_statuses()
      assert TypeDB.Error.retryable?(error)
    end

    test "a deadline is a timeout, whatever the transport calls it" do
      rpc = %GRPC.RPCError{status: 4, message: "Deadline exceeded", details: []}
      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.kind == :timeout
      assert TypeDB.Error.retryable?(error)
    end

    test "with no details at all, the context is what names the operation" do
      rpc = %GRPC.RPCError{status: 13, message: "Internal", details: nil}
      error = GRPCError.from_rpc_error(rpc, "opening a transaction")

      # The kind here used to be `:server` and is now `:transport` — see the
      # INTERNAL clause in `kind/1`. What this test is about is unchanged: with
      # nothing from the server to say, the context is what names the operation.
      assert error.kind == :transport
      assert error.code == nil
      assert error.status == 500
      assert error.message == "opening a transaction: Internal"
    end

    # TypeDB attaches ErrorInfo and DebugInfo to every error it generates —
    # measured against 3.12.1, deleting an absent database arrives as status 3
    # carrying both. An INTERNAL with neither did not come from TypeDB: it is
    # the gRPC stack reporting its own connection failure, and calling that
    # `:server` says the server answered when nothing answered at all.
    test "an INTERNAL with no details is the connection failing, not the server" do
      rpc = %GRPC.RPCError{
        status: 13,
        message: "connection_error: protocol_error, Invalid connection preface received",
        details: nil
      }

      error = GRPCError.from_rpc_error(rpc, "opening a connection")

      assert error.kind == :transport
      assert error.code == nil
      assert error.reason == {:grpc_status, 13}
      assert TypeDB.Error.retryable?(error)
    end

    test "an INTERNAL with an empty detail list is the same failure" do
      rpc = %GRPC.RPCError{status: 13, message: "Internal", details: []}

      assert GRPCError.from_rpc_error(rpc, "querying").kind == :transport
    end

    # The other half, and the one that keeps the rule narrow: an INTERNAL that
    # TypeDB itself generated carries its details, and stays `:server`.
    test "an INTERNAL TypeDB itself generated stays :server" do
      rpc = %GRPC.RPCError{
        status: 13,
        message: "Request generated error",
        details: [
          %Google.Protobuf.Any{
            type_url: "type.googleapis.com/google.rpc.ErrorInfo",
            value: Google.Rpc.ErrorInfo.encode(%Google.Rpc.ErrorInfo{reason: "SRV13"})
          }
        ]
      }

      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.kind == :server
      assert error.code == "SRV13"
      assert error.status == 500
    end

    test "a status that is not INTERNAL is unaffected by the details it carries" do
      # The rule is about INTERNAL alone. A rejection is a rejection whether or
      # not the server bothered to explain it.
      assert GRPCError.from_rpc_error(%GRPC.RPCError{status: 3, message: "x", details: nil}, "c").kind ==
               :server

      assert GRPCError.from_rpc_error(%GRPC.RPCError{status: 9, message: "x", details: []}, "c").kind ==
               :server
    end

    test "a detail this build has no schema for does not cost the error" do
      # A newer server attaching something we cannot decode must not turn "the
      # request was rejected" into "the rejection could not be parsed".
      unknown = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.SomethingNewer",
        value: <<0, 1, 2, 3>>
      }

      rpc = %GRPC.RPCError{
        status: 3,
        message: "Request generated error",
        details: [unknown, error_info("TQL0", "Query")]
      }

      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.code == "TQL0"
      assert error.kind == :server
    end

    test "an ErrorInfo whose payload is corrupt is skipped rather than raised on" do
      corrupt = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.ErrorInfo",
        value: <<255, 255, 255, 255>>
      }

      rpc = %GRPC.RPCError{status: 3, message: "Request generated error", details: [corrupt]}
      error = GRPCError.from_rpc_error(rpc, "querying")

      assert error.code == nil
      assert error.message == "querying: Request generated error"
    end
  end

  describe "from_reason/2" do
    test "a connection that was never made is a transport failure" do
      error = GRPCError.from_reason(:econnrefused, "connecting")

      assert error.kind == :transport
      assert error.reason == :econnrefused
      assert error.message =~ "connecting"
      assert TypeDB.Error.retryable?(error)
    end
  end

  describe "http_status/1" do
    test "every gRPC status this driver names has a mapping" do
      for status <- 1..16 do
        assert is_integer(GRPCError.http_status(status)), "gRPC status #{status}"
      end
    end

    test "a status nobody predicted reads as the server misbehaving" do
      assert GRPCError.http_status(99) == 500
    end
  end
end
