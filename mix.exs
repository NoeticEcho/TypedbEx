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
        plt_add_apps: [:inets, :ssl, :public_key, :mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
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
      # `:telemetry` is the only hard runtime dependency: every span goes
      # through it, it is one tiny application, and it has no dependencies of
      # its own.
      {:telemetry, "~> 1.0"},

      # Every HTTP adapter's dependency is optional, so the footprint follows
      # the transport you actually select. `:finch` backs the default one and is
      # what nearly everyone wants — add it alongside `:typedb`. Leaving it out
      # is what makes `TypeDB.HTTP.Httpc`'s "runs on OTP alone" true rather than
      # aspirational; `TypeDB.HTTP.Finch.init/2` says so if you forget.
      #
      # Floors are the versions this project actually builds and tests against
      # (see mix.lock), not the oldest that might work. Widening one is a
      # deliberate change made after testing the older version — see
      # CONTRIBUTING's "Versioning" section.
      {:finch, "~> 0.23", optional: true},
      {:req, "~> 0.7", optional: true},

      # `Decimal` is used only if the host application already has it: TypeDB's
      # `decimal` values decode to `Decimal.t()` when it is loaded and stay
      # strings otherwise. Declared so the version this driver expects is
      # visible and resolvable, never fetched on its own.
      {:decimal, "~> 2.4 or ~> 3.0", optional: true},

      # JSON comes from the built-in `JSON` module (Elixir >= 1.18), falling
      # back to `Jason` if the host application happens to depend on it, so it
      # needs no dependency at all. See `TypeDB.JSON`.

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
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md),
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
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_modules: [
        Connection: [TypeDB, TypeDB.Connection, TypeDB.Config, TypeDB.Token, TypeDB.Transport],
        Administration: [TypeDB.Database, TypeDB.User, TypeDB.Server],
        Querying: [
          TypeDB.Transaction,
          TypeDB.Options,
          TypeDB.Options.Query,
          TypeDB.Options.Transaction,
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
        Extending: [
          TypeDB.HTTP,
          TypeDB.HTTP.Finch,
          TypeDB.HTTP.Req,
          TypeDB.HTTP.Httpc,
          TypeDB.JSON,
          TypeDB.JSON.Native,
          TypeDB.JSON.Jason
        ],
        Observability: [TypeDB.Telemetry],
        Errors: [TypeDB.Error]
      ]
    ]
  end
end
