defmodule TypeDB.JSONTest do
  use ExUnit.Case, async: false

  alias TypeDB.JSON

  defmodule ShoutingCodec do
    @moduledoc false
    @behaviour TypeDB.JSON

    @impl true
    def encode_to_iodata!(_term), do: "ENCODED"

    @impl true
    def decode(_binary), do: {:ok, :decoded}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:typedb, :json_codec)
      JSON.reset()
    end)

    JSON.reset()
    :ok
  end

  test "resolves the built-in codec on modern Elixir" do
    assert JSON.codec() == TypeDB.JSON.Native
  end

  test "round-trips a payload" do
    assert JSON.encode!(%{"a" => [1, true, nil]}) == ~s({"a":[1,true,null]})
    assert JSON.decode(~s({"a":[1,true,null]})) == {:ok, %{"a" => [1, true, nil]}}
  end

  test "reports malformed JSON rather than raising" do
    assert {:error, _reason} = JSON.decode("{not json")
  end

  test "encode!/1 flattens iodata" do
    assert is_binary(JSON.encode!(%{"a" => 1}))
    assert IO.iodata_to_binary(JSON.encode_to_iodata!(%{"a" => 1})) == ~s({"a":1})
  end

  test "an application-configured codec wins" do
    Application.put_env(:typedb, :json_codec, ShoutingCodec)
    JSON.reset()

    assert JSON.codec() == ShoutingCodec
    assert JSON.encode!(%{"a" => 1}) == "ENCODED"
    assert JSON.decode("anything") == {:ok, :decoded}
  end

  test "the resolved codec is memoised" do
    assert JSON.codec() == TypeDB.JSON.Native

    # Changing configuration without resetting keeps the memoised codec, which is
    # what makes the hot path an ETS read rather than a resolution.
    Application.put_env(:typedb, :json_codec, ShoutingCodec)
    assert JSON.codec() == TypeDB.JSON.Native

    JSON.reset()
    assert JSON.codec() == ShoutingCodec
  end
end
