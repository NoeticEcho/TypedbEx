defmodule TypeDB.GRPC.Protocol do
  @moduledoc """
  Which version of TypeDB's protocol the generated modules under `lib/protocol`
  were built from.

  This exists because the generated code is committed rather than built, and a
  committed artefact can silently fall behind the thing it was generated from.
  The version is recorded here, beside the code it describes, and
  `TypeDB.GRPC.Server.version/2` reads what the server actually is — so the
  integration suite can compare them and fail loudly on a mismatch instead of
  leaving a decoding bug to be found in somebody's application.

  A mismatch is not automatically a problem: protobuf is designed so that a
  client generated from an older schema keeps working against a newer server,
  and TypeDB's `3.x` line has added fields rather than renumbering them. What a
  mismatch means is that nobody has checked, which is the state worth being
  told about.
  """

  @version "3.12.0"

  @doc """
  The `typedb-protocol` version `lib/protocol` was generated from.

      iex> TypeDB.GRPC.Protocol.version()
      "3.12.0"

  Regenerate with `mix typedb.grpc.gen`, then update this.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Whether a server reporting `server_version` is one this protocol was generated
  for, comparing major and minor and ignoring the patch.

  Patch releases of TypeDB do not change the protocol — `typedb-protocol` is
  versioned with the server and released alongside it, so 3.12.0 and 3.12.1
  share a schema. Comparing the full string would make every patch release a
  false alarm, and an alarm that cries wolf is one nobody reads.

      iex> TypeDB.GRPC.Protocol.compatible?("3.12.1")
      true

      iex> TypeDB.GRPC.Protocol.compatible?("3.11.5")
      false
  """
  @spec compatible?(String.t()) :: boolean()
  def compatible?(server_version) when is_binary(server_version) do
    minor(server_version) == minor(@version)
  end

  defp minor(version) do
    version
    |> String.split(".")
    |> Enum.take(2)
  end
end
