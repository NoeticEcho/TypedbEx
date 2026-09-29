defmodule TypeDB.MixProject do
  use Mix.Project

  @version "0.10.4"
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
      test_coverage: [
        # The floor is a number both CI and a development container clear, so
        # that it catches a regression rather than the weather, and it only ever
        # moves up. 83 → 87 once the coverage step began printing the delta.
        #
        # The gap that was never chased down turns out not to exist, and to have
        # had the wrong sign. This comment used to say CI "measures about two
        # points lower than a development container", so the floor was set well
        # under the local reading to compensate. Measured on 42f7fee: **CI reads
        # 88.16% and this container reads 87.93%** — CI is 0.23 points *higher*.
        #
        # 87 rather than 88 for a reason worth stating: a floor above the local
        # reading would be green in CI and red for every contributor running
        # `mix test --cover` before pushing, which is the opposite of a useful
        # gate. It sits below both readings and above everything before them.
        #
        # Modules that run only under another adapter or another JSON codec drag
        # any single run down. CI covers those by running the matrix, not by
        # pretending one run covers everything.
        summary: [threshold: 87],
        ignore_modules: [
          # Test support: measuring the coverage of the thing doing the
          # measuring says nothing about the library.
          TypeDB.Case,
          TypeDB.FaultAdapter,
          ~r/^TypeDB\.Stub/,
          # `TypeDB.Bang` is macros. Everything it generates is attributed to
          # the module that expanded it, so cover reports 0% for code that runs
          # in nearly every test in the suite.
          TypeDB.Bang
        ]
      ]
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

      # JSON comes from the built-in `JSON` module on every supported Elixir, so
      # this driver needs no JSON dependency. `:jason` is declared for the same
      # reason as `:decimal` above — `TypeDB.JSON.Jason` exists for host
      # applications that already have it, and declaring it optional makes the
      # version that codec is written against visible and resolvable without
      # ever fetching it on its own. It also lets the suite drive that codec,
      # which nothing did until 0.6.0. `:req` cannot be relied on to bring it:
      # a dependency of a dependency is not a dependency. See `TypeDB.JSON`.
      {:jason, "~> 1.4", optional: true},

      # Tooling below is never required by consumers of this library.
      #
      # `stream_data` generates the inputs for the round-trip properties over
      # `TypeDB.Duration`, `TypeDB.DateTimeTZ`, `TypeDB.Given` and
      # `TypeDB.Concept` — the boundary where TypeDB's wire format meets Elixir
      # types, and where every subtle bug in this driver has actually been.
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    "A driver for TypeDB 3.12+ in Elixir, built on the TypeDB HTTP API. " <>
      "Databases, users, transactions, TypeQL queries and typed concept answers."
  end

  defp package do
    [
      name: "typedb",
      licenses: ["Apache-2.0"],
      files: ~w(lib guides notebooks .formatter.exs mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/typedb/CHANGELOG.md",
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
      # Two packages share this repository, so a Mix project root is one level
      # below the repository root and ex_doc's default pattern — which is
      # relative to the project — points at a path GitHub does not have. Every
      # "source" link up to and including 0.9.0 was a 404 for that reason.
      source_url_pattern: "#{@source_url}/blob/v#{@version}/typedb/%{path}#L%{line}",
      extras: [
        "README.md",
        # Reading order rather than alphabetical, and the sidebar follows this
        # list: start here, then the two things every application meets
        # (transactions, failures), then the applied ones.
        "guides/getting-started.md",
        "guides/transactions.md",
        "guides/recipes.md",
        "guides/errors-and-retries.md",
        "guides/observability.md",
        "guides/testing.md",
        "notebooks/getting_started.livemd",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r{^guides/},
        Notebooks: ~r{^notebooks/}
      ],
      # Reading order, not alphabetical: connect, ask, read what came back,
      # handle what went wrong, then the things you reach for later. Every
      # published module belongs to exactly one group, which
      # test/typedb/api_snapshot_test.exs asserts — a new module that nobody
      # filed would otherwise land in an unnamed heap at the bottom.
      groups_for_modules: [
        # `TypeDB` on its own and first. It is the facade — nearly everything a
        # caller does goes through it — and it used to sit third inside a group
        # named for something else, which is a poor first thing to find.
        "Start here": [TypeDB],
        Connection: [TypeDB.Connection, TypeDB.Config],
        Querying: [
          TypeDB.Transaction,
          TypeDB.Given,
          TypeDB.Options,
          TypeDB.Options.Query,
          TypeDB.Options.Transaction
        ],
        Answers: [
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
        Errors: [TypeDB.Error],
        Observability: [TypeDB.Telemetry],
        Administration: [TypeDB.Database, TypeDB.User, TypeDB.Server],
        # Split out of one "Extending" group. Choosing a transport is an
        # ordinary thing a user does — `TypeDB.HTTP` carries the table of which
        # adapter to pick and why — and it was filed under a heading that reads
        # as "for people writing plug-ins". The JSON codecs really are that.
        "HTTP adapters": [
          TypeDB.HTTP,
          TypeDB.HTTP.Finch,
          TypeDB.HTTP.Req,
          TypeDB.HTTP.Httpc
        ],
        "JSON codecs": [TypeDB.JSON, TypeDB.JSON.Native, TypeDB.JSON.Jason],
        "Mix tasks": [Mix.Tasks.Typedb.Check]
      ]
    ]
  end
end
