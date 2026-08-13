defmodule TypeDB.GRPC.Migration do
  @moduledoc false

  # The file format behind `TypeDB.GRPC.Database.export_to_files/5` and
  # `import_from_files/5`.
  #
  # It is not a format this driver invented. TypeDB's own drivers write the data
  # file as a flat sequence of length-delimited `Migration.Item` messages — a
  # varint byte count followed by that many bytes of encoded item, repeated —
  # and the schema file as plain TypeQL. Following them exactly is the whole
  # point: a dump taken by the Rust driver or by TypeDB's console restores
  # through this one, and a dump taken here restores through those.
  #
  # `prost`, which the Rust driver uses, writes the delimiter with
  # `encode_length_delimited`; this writes the same bytes. Nothing here decodes
  # an item's *contents* — items go to the server exactly as they arrived from
  # it — so a protocol that grows a new item kind keeps round-tripping without a
  # change on this side.

  import Bitwise

  alias TypeDB.Error
  alias Typedb.Protocol, as: Proto

  # Read the data file in chunks rather than whole: an exported graph is exactly
  # the kind of file that does not fit in memory, and the point of doing this on
  # a streaming transport is lost if the client buffers it all anyway.
  @chunk_bytes 64 * 1024

  # `prost` writes at most ten bytes of varint, so a delimiter longer than that
  # is not a delimiter.
  @max_varint_bytes 10

  @doc "One item, length-delimited: the varint byte count, then the item."
  @spec encode(struct()) :: [binary()]
  def encode(%Proto.Migration.Item{} = item) do
    encoded = Protobuf.encode(item)
    [varint(IO.iodata_length(encoded)), encoded]
  end

  @doc """
  The items in a data file, as a lazy stream.

  Raises `TypeDB.Error` on a file that is not one — a truncated tail, a
  delimiter that never ends, an item that does not decode. Raising rather than
  returning: this is consumed inside an `Enum.each/2` that is feeding a gRPC
  stream, and there is no half-import worth reporting as a value.
  """
  @spec items(Path.t()) :: Enumerable.t()
  def items(path) do
    path
    |> File.stream!(@chunk_bytes)
    # The end of the file is an event the reducer has to see: a buffer with
    # bytes still in it means a truncated last item, and that is only knowable
    # once nothing more is coming. Appending it rather than using
    # `Stream.transform/4`'s after-fun is what keeps a consumer that stops early
    # — `Enum.take/2`, or a failed send abandoning the rest — from being told
    # the file is corrupt when it simply has not read all of it.
    |> Stream.concat([:eof])
    |> Stream.transform("", &decode_chunk/2)
  end

  defp decode_chunk(:eof, ""), do: {[], ""}

  defp decode_chunk(:eof, rest) do
    raise Error.new(
            :decode,
            "the data file ends mid-item: #{byte_size(rest)} bytes left over after the last " <>
              "complete one. It was truncated, or it is not a TypeDB export."
          )
  end

  defp decode_chunk(chunk, buffer) when is_binary(chunk) do
    {items, rest} = take_items(buffer <> chunk, [])
    {Enum.reverse(items), rest}
  end

  defp take_items(binary, acc) do
    case take_varint(binary, 0, 0) do
      {:ok, length, rest} when byte_size(rest) >= length ->
        <<body::binary-size(^length), tail::binary>> = rest
        take_items(tail, [decode_item(body) | acc])

      # Either the delimiter or the item it announces is still arriving.
      _incomplete ->
        {acc, binary}
    end
  end

  defp decode_item(body) do
    Protobuf.decode(body, Proto.Migration.Item)
  rescue
    exception ->
      reraise Error.new(
                :decode,
                "an item in the data file did not decode as a TypeDB migration item: " <>
                  Exception.message(exception)
              ),
              __STACKTRACE__
  end

  defp take_varint(<<0::1, part::7, rest::binary>>, acc, shift), do: {:ok, acc ||| part <<< shift, rest}

  defp take_varint(<<1::1, part::7, rest::binary>>, acc, shift)
       when shift < (@max_varint_bytes - 1) * 7 do
    take_varint(rest, acc ||| part <<< shift, shift + 7)
  end

  defp take_varint(<<1::1, _part::7, _rest::binary>>, _acc, _shift) do
    raise Error.new(
            :decode,
            "the data file has a length delimiter longer than #{@max_varint_bytes} bytes, " <>
              "which no TypeDB export writes. It is not a TypeDB export, or it is corrupt."
          )
  end

  defp take_varint(<<>>, _acc, _shift), do: :incomplete

  defp varint(value) when value < 0x80, do: <<value>>

  defp varint(value) do
    <<1::1, band(value, 0x7F)::7, varint(bsr(value, 7))::binary>>
  end
end
