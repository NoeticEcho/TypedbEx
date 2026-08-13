defmodule TypeDB.NotebookTest do
  use ExUnit.Case, async: true

  # A notebook whose code does not compile is worse than no notebook: it is
  # advertised from the README with a "Run in Livebook" badge, so the first
  # thing a stranger does with this driver may well be to run it.
  #
  # Parsing is not running — that needs a server and a Livebook — but it catches
  # the failure that actually happens, which is prose edited into code.
  @notebook Path.expand("../../notebooks/getting_started.livemd", __DIR__)

  test "every elixir block in the notebook parses" do
    blocks = elixir_blocks()

    # Guards the extractor as well as the notebook: a regex that silently
    # matched nothing would make this test pass forever.
    assert length(blocks) > 10

    for {code, index} <- Enum.with_index(blocks, 1) do
      assert {:ok, _quoted} = Code.string_to_quoted(code),
             "block #{index} of #{Path.relative_to_cwd(@notebook)} does not parse:\n\n#{code}"
    end
  end

  # A Windows checkout rewrites the notebook to CRLF unless git is told
  # otherwise, and then `^```elixir\n` matches nothing at all. `.gitattributes`
  # pins it, and normalising here as well means the test does not depend on the
  # checkout having been done with it.
  defp elixir_blocks do
    source = @notebook |> File.read!() |> String.replace("\r\n", "\n")

    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  test "the notebook installs the version this project is" do
    # `Mix.install([{:typedb, "~> 0.2"}])` pinned to a version that no longer
    # exists installs nothing, and says so only once someone runs it.
    requirement =
      ~r/\{:typedb, "([^"]+)"\}/
      |> Regex.run(File.read!(@notebook), capture: :all_but_first)
      |> hd()

    version = Mix.Project.config()[:version]

    assert Version.match?(version, requirement),
           "the notebook installs typedb #{requirement}, which #{version} does not satisfy"
  end
end
