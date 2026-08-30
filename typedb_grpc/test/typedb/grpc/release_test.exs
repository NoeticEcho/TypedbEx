defmodule TypeDB.GRPC.ReleaseTest do
  @moduledoc """
  The parts of a release that nothing else checks in time.

  `.github/workflows/release-grpc.yml` refuses a tag that disagrees with
  `mix.exs` or with `CHANGELOG.md`, but only once the tag has been pushed — and
  a pushed tag is the point of no return. These are the same questions asked of
  a working tree, plus three the workflow does not ask at all: the version in
  the README's installation snippet, the link definition at the bottom of the
  changelog, and the requirement on the sibling package.
  """

  use ExUnit.Case, async: true

  @version Mix.Project.config()[:version]
  @root Path.expand("../../..", __DIR__)

  @readme Path.join(@root, "README.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @sibling Path.join(@root, "../typedb/mix.exs")

  test "the README installs the version this package is" do
    requirement =
      ~r/\{:typedb_grpc, "([^"]+)"\}/
      |> Regex.run(File.read!(@readme), capture: :all_but_first)
      |> hd()

    assert Version.match?(@version, requirement),
           "README.md tells people to install typedb_grpc #{requirement}, " <>
             "which this package's #{@version} does not satisfy"
  end

  test "the CHANGELOG has a section for this version" do
    assert File.read!(@changelog) =~ ~r/^## \[#{Regex.escape(@version)}\]/m,
           "CHANGELOG.md has no '## [#{@version}]' section, and the release workflow " <>
             "refuses the tag without one"
  end

  test "the CHANGELOG defines the link for this version" do
    assert File.read!(@changelog) =~ ~r/^\[#{Regex.escape(@version)}\]: http/m,
           "CHANGELOG.md has no '[#{@version}]: …' link definition at the bottom"
  end

  test "documentation points at this package's own tag and subdirectory" do
    # This package's tags are prefixed, because two packages in one repository
    # cannot both answer to `v*` — and ex_doc builds source links relative to
    # the Mix project root, which is one level below the repository root. Get
    # either wrong and every "source" link on hexdocs is a 404, as every one of
    # them was in 0.1.0, which got both wrong.
    docs = Mix.Project.config()[:docs]

    assert docs[:source_ref] == "typedb_grpc-v#{@version}"

    pattern = docs[:source_url_pattern]
    assert is_binary(pattern), "docs must set an explicit :source_url_pattern"
    assert pattern =~ "/typedb_grpc/%{path}", "the source link must carry the package's subdirectory"
    assert pattern =~ "blob/typedb_grpc-v#{@version}/", "the source link must use this package's tag"
  end

  describe "the requirement on the sibling package" do
    setup do
      requirement =
        Mix.Project.config()[:deps]
        |> Enum.find(&(elem(&1, 0) == :typedb))
        |> elem(1)

      # In this repository the dependency is a path, and the version requirement
      # only appears when `TYPEDB_GRPC_PUBLISH` is set. The published shape is
      # what these tests are about, so read the literal either way.
      requirement =
        if is_binary(requirement) do
          requirement
        else
          ~r/@typedb_requirement "([^"]+)"/
          |> Regex.run(File.read!(Path.join(@root, "mix.exs")), capture: :all_but_first)
          |> hd()
        end

      {:ok, requirement: requirement, sibling: sibling_version()}
    end

    test "is satisfied by the sibling in this repository", %{
      requirement: requirement,
      sibling: sibling
    } do
      assert Version.match?(sibling, requirement),
             "this package requires typedb #{requirement}, and the typedb in this " <>
               "repository is #{sibling} — a release would resolve to an older one from hex"
    end

    test "does not reach across the sibling's next minor", %{
      requirement: requirement,
      sibling: sibling
    } do
      # CONTRIBUTING's own rule: while typedb is in 0.x, a minor carries anything
      # a 1.x would call breaking. `~> 0.10` admits 0.11 and would therefore let
      # a breaking sibling in silently; `~> 0.10.0` does not.
      %Version{major: major, minor: minor} = Version.parse!(sibling)
      next_minor = "#{major}.#{minor + 1}.0"

      refute Version.match?(next_minor, requirement),
             "this package requires typedb #{requirement}, which admits #{next_minor} — " <>
               "and a minor of typedb may break it. Pin the minor: \"~> #{major}.#{minor}.0\""
    end
  end

  defp sibling_version do
    ~r/@version "([^"]+)"/
    |> Regex.run(File.read!(@sibling), capture: :all_but_first)
    |> hd()
  end
end
