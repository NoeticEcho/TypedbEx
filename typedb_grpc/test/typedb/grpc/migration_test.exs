defmodule TypeDB.GRPC.MigrationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The export file format, without a server.

  What is pinned here is the framing — a varint byte count followed by that many
  bytes — because it is not this driver's format to choose: TypeDB's own drivers
  and its console write these files, and a dump has to be readable by whichever
  of them the operator reaches for. The integration suite proves that claim
  against the real console; this proves the pieces it is made of.
  """

  import Bitwise

  alias TypeDB.GRPC.Migration
  alias Typedb.Protocol, as: Proto

  @tmp Path.join(System.tmp_dir!(), "typedb_grpc_migration_test")

  setup do
    File.mkdir_p!(@tmp)
    path = Path.join(@tmp, "items_#{System.unique_integer([:positive])}.data")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp entity(id) do
    %Proto.Migration.Item{
      item: {:entity, %Proto.Migration.Item.Entity{id: id, label: "person"}}
    }
  end

  defp write(path, items) do
    File.write!(path, Enum.map(items, &Migration.encode/1))
  end

  test "items round-trip through a file", %{path: path} do
    items = Enum.map(1..100, &entity("e#{&1}"))
    write(path, items)

    assert Enum.to_list(Migration.items(path)) == items
  end

  test "the delimiter is a varint, so an item over 127 bytes still frames", %{path: path} do
    # One byte of varint runs out at 127. An entity with a long id crosses it,
    # and a length written as a single byte would frame every later item wrongly
    # rather than failing outright — which is the bug this pins.
    big = entity(String.duplicate("x", 5_000))
    write(path, [entity("small"), big, entity("after")])

    assert [%{item: {:entity, %{id: "small"}}}, ^big, %{item: {:entity, %{id: "after"}}}] =
             Enum.to_list(Migration.items(path))
  end

  test "items are read across chunk boundaries", %{path: path} do
    # The reader pulls 64 KiB at a time, so items straddle the boundary. With
    # ~1 KiB items this file spans several chunks and most items are split.
    items =
      Enum.map(
        1..500,
        &%Proto.Migration.Item{
          item: {:entity, %Proto.Migration.Item.Entity{id: String.duplicate("#{&1}", 300), label: "person"}}
        }
      )

    write(path, items)

    assert File.stat!(path).size > 3 * 64 * 1024
    assert Enum.to_list(Migration.items(path)) == items
  end

  test "an empty file has no items", %{path: path} do
    File.write!(path, "")
    assert Enum.to_list(Migration.items(path)) == []
  end

  test "a truncated file is reported, not silently short", %{path: path} do
    encoded = IO.iodata_to_binary(Enum.map(1..10, &Migration.encode(entity("e#{&1}"))))
    File.write!(path, binary_part(encoded, 0, byte_size(encoded) - 3))

    assert_raise TypeDB.Error, ~r/ends mid-item/, fn -> Enum.to_list(Migration.items(path)) end
  end

  test "an item longer than any item can be is refused before the file is read", %{path: path} do
    # Audit VI, VI-4. Nothing bounded the declared length, so a delimiter this
    # size simply never satisfied "have I got that many bytes yet" — the reader
    # buffered the whole file and only then said it ended mid-item. The memory
    # ceiling was the size of the file.
    huge = <<0x80, 0x80, 0x80, 0x80, 0x01>>
    assert <<0x80, 0x80, 0x80, 0x80, 0x01>> == huge and 0x01 <<< 28 == 268_435_456
    File.write!(path, [huge, :binary.copy(<<0>>, 4 * 1024 * 1024)])

    assert_raise TypeDB.Error, ~r/declares an item of 268435456 bytes/, fn ->
      Enum.to_list(Migration.items(path))
    end
  end

  test "an item just under the ceiling is still an item", %{path: path} do
    # The ceiling has to be generous enough to be invisible: TypeDB's items are
    # entities, attributes and relations. This is a 2 MiB one, which is already
    # absurd for a real graph and nowhere near the limit.
    big = entity(String.duplicate("x", 2 * 1024 * 1024))
    write(path, [big])

    assert Enum.to_list(Migration.items(path)) == [big]
  end

  test "a file that is not an export at all is reported", %{path: path} do
    # Every byte with the continuation bit set: a delimiter that never ends.
    File.write!(path, :binary.copy(<<0xFF>>, 32))

    assert_raise TypeDB.Error, ~r/length delimiter/, fn -> Enum.to_list(Migration.items(path)) end
  end

  test "a well-framed item whose bytes are not an item is reported", %{path: path} do
    # Field 1 (an entity) declared as a length-delimited value, then bytes that
    # are not a valid message. The framing is fine; the content is not.
    garbage = <<0x0A, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    File.write!(path, [Migration.encode(entity("ok")), <<byte_size(garbage)>>, garbage])

    assert_raise TypeDB.Error, ~r/did not decode/, fn -> Enum.to_list(Migration.items(path)) end
  end

  test "the stream is lazy: a corrupt tail does not stop the head being read", %{path: path} do
    good = Enum.map(1..5, &entity("e#{&1}"))
    File.write!(path, [Enum.map(good, &Migration.encode/1), <<0xFF, 0xFF>>])

    assert path |> Migration.items() |> Enum.take(5) == good
  end
end
