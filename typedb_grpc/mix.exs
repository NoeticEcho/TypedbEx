defmodule TypeDB.GRPC.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/NoeticEcho/TypedbEx"

  def project do
    [
      app: :typedb_grpc,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # The generated protobuf modules are machine-written and 3,000 lines wide.
      # Compiling them under --warnings-as-errors would make this package's
      # build hostage to whichever protoc-gen-elixir generated them, so they are
      # excluded from the strict pass rather than edited by hand — editing them
      # is what `mix typedb.grpc.gen` exists to make unnecessary.
      elixirc_options: [debug_info: Mix.env() != :prod],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "TypeDB.GRPC",
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ]
    ]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.publish": :docs]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The point of depending on the HTTP driver rather than vendoring its
      # value types: an application that switches transports keeps every
      # pattern match it wrote. `%TypeDB.Error{}`, `%TypeDB.Concept.Attribute{}`
      # and the rest are the same structs from the same module, so switching is
      # a line in a data-access module rather than a rewrite above it.
      #
      # In this repository it resolves as a path so a change to those structs is
      # visible here without a release; `mix hex.build` uses the version.
      {:typedb, path: "../typedb", override: true},

      # gRPC and protobuf are hard dependencies, unlike this driver's sibling
      # where every transport is optional. There is no second way to speak this
      # protocol, so pretending otherwise would only move the failure later.
      {:grpc, "~> 1.0"},

      # `Google.Rpc.ErrorInfo` and `Google.Rpc.DebugInfo` are where TypeDB puts
      # the error code and the human message, so this driver reads them by name.
      # It arrives transitively through `:grpc` today; depending on a dependency
      # of a dependency is how a build breaks on an unrelated upgrade.
      {:googleapis, "~> 0.1"},
      {:protobuf, "~> 0.17"},
      {:gun, "~> 2.0"},

      # Optional for the same reason and on the same terms as in the sibling
      # package: TypeDB's `decimal` values decode to `Decimal.t()` when the host
      # application already has the library and to a float otherwise. Declared
      # so the version this driver is written against is visible and resolvable,
      # never fetched on its own.
      {:decimal, "~> 2.4 or ~> 3.0", optional: true},
      # Test-only, and only for the shared behaviour suite: it drives `typedb`
      # as well as this package, and `typedb`'s default transport is Finch —
      # which is optional there, so nothing pulls it in here. Running the suite
      # through the default adapter rather than through `:httpc` keeps it
      # comparing what people actually use.
      {:finch, "~> 0.23", only: [:dev, :test]},
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    "A driver for TypeDB 3.12+ in Elixir, built on the TypeDB gRPC API. " <>
      "Streaming answers with no count limit, and transactions that pipeline."
  end

  defp package do
    [
      name: "typedb_grpc",
      licenses: ["Apache-2.0"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/typedb_grpc/CHANGELOG.md",
        "TypeDB" => "https://typedb.com",
        "TypeDB protocol" => "https://github.com/typedb/typedb-protocol"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      # The generated protocol modules are an implementation detail with 3,000
      # lines of machine-written documentation-free structs. They are public
      # only because Elixir has no other visibility.
      filter_modules: fn module, _meta ->
        not String.starts_with?(inspect(module), "Typedb.Protocol")
      end,
      groups_for_modules: [
        Connection: [TypeDB.GRPC, TypeDB.GRPC.Connection, TypeDB.GRPC.Config],
        Querying: [TypeDB.GRPC.Transaction],
        Administration: [TypeDB.GRPC.Database, TypeDB.GRPC.Server, TypeDB.GRPC.User]
      ]
    ]
  end
end
