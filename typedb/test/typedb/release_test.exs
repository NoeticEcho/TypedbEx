defmodule TypeDB.ReleaseTest do
  @moduledoc """
  The parts of a release that nothing else checks in time.

  `.github/workflows/release.yml` already refuses a tag whose number disagrees
  with `mix.exs`, and one whose `CHANGELOG.md` has no section — but it checks
  after the tag is pushed, and CONTRIBUTING calls the tag the point of no
  return. Recovering means deleting a tag from a remote and re-cutting it.

  These are the same questions asked while it is still a working tree, plus the
  two the workflow cannot ask: the version in the README's installation snippet,
  which is the first thing anybody copies, and the link definition at the bottom
  of the changelog, which CONTRIBUTING itself calls "the line that gets
  forgotten".
  """

  use ExUnit.Case, async: true

  @version Mix.Project.config()[:version]
  @root Path.expand("../..", __DIR__)

  @readme Path.join(@root, "README.md")
  @changelog Path.join(@root, "CHANGELOG.md")

  test "the README installs the version this project is" do
    requirement =
      ~r/\{:typedb, "([^"]+)"\}/
      |> Regex.run(File.read!(@readme), capture: :all_but_first)
      |> hd()

    assert Version.match?(@version, requirement),
           "README.md tells people to install typedb #{requirement}, " <>
             "which this project's #{@version} does not satisfy"
  end

  test "the CHANGELOG has a section for this version" do
    assert File.read!(@changelog) =~ ~r/^## \[#{Regex.escape(@version)}\]/m,
           "CHANGELOG.md has no '## [#{@version}]' section, and the release workflow " <>
             "refuses the tag without one"
  end

  test "the CHANGELOG defines the link for this version" do
    assert File.read!(@changelog) =~ ~r/^\[#{Regex.escape(@version)}\]: http/m,
           "CHANGELOG.md has no '[#{@version}]: …' link definition at the bottom; " <>
             "the heading renders as literal brackets on hexdocs without it"
  end

  test "documentation links into this repository's own subdirectory" do
    # ex_doc builds source links relative to the Mix project root, which in this
    # monorepo is one level below the repository root. Without an explicit
    # pattern every "source" link on hexdocs is a 404 — as every one of them was
    # up to and including 0.9.0.
    pattern = Mix.Project.config()[:docs][:source_url_pattern]

    assert is_binary(pattern), "docs must set an explicit :source_url_pattern"
    assert pattern =~ "/typedb/%{path}", "the source link must carry the package's subdirectory"
    assert pattern =~ "blob/v#{@version}/", "the source link must point at this version's tag"
  end
end
