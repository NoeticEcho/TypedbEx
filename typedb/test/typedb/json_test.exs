defmodule TypeDB.JSONTest do
  use ExUnit.Case, async: false

  alias TypeDB.JSON
  alias TypeDB.JSON.Jason, as: JasonCodec

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

  describe "the Jason codec" do
    # It is documented in the README as `config :typedb, :json_codec,
    # TypeDB.JSON.Jason`, it ships in the package, and until this it was executed
    # by nothing — 0.00% coverage. Published code that nothing runs is published
    # code nobody has checked, which is the same hazard `TypeDB.GuideTest` exists
    # for.
    test "encodes, decodes, and reports malformed input" do
      assert JasonCodec.encode_to_iodata!(%{"a" => [1, true, nil]}) |> IO.iodata_to_binary() ==
               ~s({"a":[1,true,null]})

      assert JasonCodec.decode(~s({"a":[1,true,null]})) == {:ok, %{"a" => [1, true, nil]}}
      assert {:error, %Jason.DecodeError{}} = JasonCodec.decode("{not json")
    end

    test "drives a whole query when configured as the codec" do
      # The configuration the README documents, exercised end to end rather than
      # asserted about: request encoding, response decoding and concept casting
      # all go through it.
      Application.put_env(:typedb, :json_codec, JasonCodec)
      JSON.reset()
      assert JSON.codec() == JasonCodec

      {:ok, stub} = TypeDB.Stub.start_link(databases: ["social"])
      name = :"jason_codec_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TypeDB.start_link(name: name, url: TypeDB.Stub.url(stub), username: "admin", password: "password")

      # Both are linked to this process and die with it, as everywhere else in
      # the suite; an on_exit that stops them races that and exits.
      _ = pid

      assert {:ok, ["social"]} = TypeDB.Database.list(name)

      assert {:ok, answer} =
               TypeDB.query(name, "social", "match $p isa person;", transaction_type: :read)

      assert %TypeDB.Answer.ConceptRows{} = answer
    end
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
