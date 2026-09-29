defmodule TypeDB.GuideTest do
  use ExUnit.Case, async: true

  # The guides tell people how to use the driver, and their code is the part
  # most likely to be wrong: nothing compiles it, and prose gets edited into it.
  #
  # This runs one of them. `guides/testing.md` offers an adapter that fails the
  # first two requests and claims that "two failures then a success exercises
  # the retry path end to end" — which was false, because `:max_retries`
  # defaults to 1 and two failures exhausted it. The example demonstrated the
  # give-up path while saying it demonstrated the retry path. Found by copying
  # it into an application and running it.
  #
  # So the module is taken *out of the guide* rather than reimplemented here:
  # a copy would drift, and the point is that the published code works.

  @guide Path.expand("../../guides/testing.md", __DIR__)

  setup_all do
    [module] =
      @guide
      |> elixir_blocks()
      |> Enum.filter(&String.contains?(&1, "defmodule FlakyAdapter"))

    # Guards the extractor: a regex that matched nothing would make every
    # assertion below vacuous.
    assert module =~ "@behaviour TypeDB.HTTP"

    Code.eval_string(module, [], file: @guide)
    :ok
  end

  setup do
    {:ok, stub} = TypeDB.Stub.start_link([])
    {:ok, stub: stub}
  end

  test "the guide's adapter retries twice and then succeeds", %{stub: stub} do
    name = :"guide_retry_#{System.unique_integer([:positive])}"

    # `max_retries: 2` is the line the guide was missing. On the default this
    # same setup fails, which the next test asserts.
    opts = [max_retries: 2] ++ connection(name, stub)

    {:ok, _pid} = start_supervised({TypeDB, opts})

    assert :ok = TypeDB.Server.health(name)
  end

  test "with the default :max_retries the same adapter gives up", %{stub: stub} do
    # The other half: this is what the guide used to show while claiming the
    # opposite, so it is worth stating that the arithmetic is the whole
    # difference rather than something about the adapter.
    name = :"guide_giveup_#{System.unique_integer([:positive])}"

    {:ok, _pid} = start_supervised({TypeDB, connection(name, stub)})

    assert {:error, %TypeDB.Error{kind: :transport}} = TypeDB.Server.health(name)
  end

  test "the guide starts its own connection with enough retries for its adapter" do
    # The two tests above prove the arithmetic. This one proves the guide has
    # it — otherwise the published example still gives up while the suite is
    # green, which is precisely the state this file was written to end.
    [start_link] =
      @guide
      |> elixir_blocks()
      |> Enum.filter(&String.contains?(&1, "TypeDB.start_link("))

    assert start_link =~ "max_retries: 2",
           "guides/testing.md injects two failures but does not raise :max_retries, " <>
             "so its example demonstrates the give-up path it says it does not"
  end

  describe "guides/getting-started.md" do
    # The one guide a stranger reads first, so its walkthrough is run rather
    # than parsed: create a database, define a schema, insert, read the names
    # back. The stub answers all four, so this proves the sequence composes —
    # the function names exist, the options are accepted, and the answer is
    # `Enumerable` with the variable the guide says it has.
    #
    # It cannot prove TypeDB accepts that TypeQL; the guide says which
    # integration test measured each claim it makes about the server.

    @getting_started Path.expand("../../guides/getting-started.md", __DIR__)

    defp walkthrough do
      [block] =
        @getting_started
        |> elixir_blocks()
        |> Enum.filter(&String.contains?(&1, "TypeDB.create_database!"))

      block
    end

    test "the walkthrough runs and hands back the names it says it does" do
      {:ok, stub} = TypeDB.Stub.start_link([])
      on_exit(fn -> stop_quietly(fn -> TypeDB.Stub.stop(stub) end) end)

      name = :"guide_start_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised(
          {TypeDB,
           name: name, url: TypeDB.Stub.url(stub), username: "admin", password: "password", http: adapter()}
        )

      {names, _bindings} = Code.eval_string(walkthrough(), [conn: name], file: @getting_started)

      assert names == ["Alice"]
    end

    test "the walkthrough asks for the transaction type it tells you to pass" do
      # The guide's own advice, checked against the guide's own code: a reader
      # who copies this gets a `:read` read and a `:write` write, not the
      # `:schema` default the paragraph warns about.
      block = walkthrough()

      assert block =~ "transaction_type: :write"
      assert block =~ "transaction_type: :read"
    end

    test "the injection-safe example binds rather than interpolates" do
      [block] =
        @getting_started
        |> elixir_blocks()
        |> Enum.filter(&String.contains?(&1, "given_rows:"))

      assert block =~ "given $n: string;"
      assert block =~ ~s(given_rows: [%{"n" => user_supplied}])

      # `~S` because `"#{}"` is an interpolation producing the empty string, and
      # every string matches that — the first version of this line passed for
      # any guide text at all.
      refute block =~ ~S(#{),
             "the guide's parameterised example interpolates into the query, " <>
               "which is the thing it exists to tell people not to do"
    end
  end

  defp stop_quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  test "every elixir block in every guide parses" do
    # The same guard the notebook has, for the same reason: nothing compiles a
    # guide, so prose edited into code is invisible until a reader hits it.
    guides = Path.wildcard(Path.expand("../../guides/*.md", __DIR__))

    assert length(guides) >= 5

    for guide <- guides, {code, index} <- Enum.with_index(elixir_blocks(guide), 1) do
      assert {:ok, _quoted} = Code.string_to_quoted(code),
             "block #{index} of #{Path.relative_to_cwd(guide)} does not parse:\n\n#{code}"
    end
  end

  test "every elixir block in the README parses, or is an options fragment" do
    readme = Path.expand("../../README.md", __DIR__)
    blocks = elixir_blocks(readme)

    assert length(blocks) > 15

    for {code, index} <- Enum.with_index(blocks, 1) do
      assert parses?(code) or options_fragment?(code),
             "block #{index} of README.md is neither valid Elixir nor a list of options:\n\n#{code}"
    end
  end

  # Two README blocks are deliberately half a keyword list — `http: {…}` shown
  # on its own, with a comment between the alternatives — because that is how
  # you actually write the option. They are still checked, one line at a time.
  defp options_fragment?(code) do
    lines =
      code
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))

    lines != [] and Enum.all?(lines, &parses?("[#{&1}]"))
  end

  defp parses?(code), do: match?({:ok, _quoted}, Code.string_to_quoted(code))

  defp connection(name, stub) do
    [
      name: name,
      url: TypeDB.Stub.url(stub),
      username: "admin",
      password: "password",
      # Nothing here is testing how long a backoff waits.
      retry_backoff: fn _attempt -> 0 end,
      http: {FlakyAdapter, [inner: adapter()]}
    ]
  end

  defp adapter, do: TypeDB.Case.adapter() || {TypeDB.HTTP.Finch, []}

  defp elixir_blocks(path) do
    source = path |> File.read!() |> String.replace("\r\n", "\n")

    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end
end
