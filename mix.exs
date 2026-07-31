defmodule TypeDB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/NoeticEcho/TypedbEx"

  def project do
    [
      app: :typedb,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "TypeDB",
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:inets, :ssl, :public_key],
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ],
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.publish": :docs]]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # This driver has *no* runtime dependencies. JSON is handled by the
      # built-in `JSON` module (Elixir >= 1.18), falling back to `Jason` if the
      # host application happens to depend on it. See `TypeDB.JSON`.
      #
      # Tooling below is never required by consumers of this library.
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    "A TypeDB 3.x driver for Elixir, built on the TypeDB HTTP API. " <>
      "Databases, users, transactions, TypeQL queries and typed concept answers."
  end

  defp package do
    [
      name: "typedb",
      licenses: ["Apache-2.0"],
      maintainers: ["NoeticEcho"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "TypeDB" => "https://typedb.com",
        "TypeDB HTTP API" => "https://typedb.com/docs/reference/typedb-http-api/"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Connection: [TypeDB, TypeDB.Connection, TypeDB.Config],
        Administration: [TypeDB.Database, TypeDB.User, TypeDB.Server],
        Querying: [
          TypeDB.Transaction,
          TypeDB.Options,
          TypeDB.Given,
          TypeDB.Answer,
          TypeDB.Answer.Ok,
          TypeDB.Answer.ConceptRows,
          TypeDB.Answer.ConceptDocuments,
          TypeDB.ConceptRow
        ],
        Concepts: [
          TypeDB.Concept,
          TypeDB.Concept.Entity,
          TypeDB.Concept.Relation,
          TypeDB.Concept.Attribute,
          TypeDB.Concept.Value,
          TypeDB.Concept.EntityType,
          TypeDB.Concept.RelationType,
          TypeDB.Concept.AttributeType,
          TypeDB.Concept.RoleType,
          TypeDB.Duration,
          TypeDB.DateTimeTZ
        ],
        Extending: [TypeDB.HTTP, TypeDB.HTTP.Httpc, TypeDB.HTTP.Req, TypeDB.JSON],
        Errors: [TypeDB.Error]
      ]
    ]
  end
end
