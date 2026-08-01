defmodule Consumer.MixProject do
  use Mix.Project

  # A throwaway application that depends on the driver and nothing else.
  #
  # Optional dependencies of a dependency are not fetched for its consumers, so
  # this is the only place the driver can be compiled and run with `finch`,
  # `req`, `decimal` and `jason` genuinely absent. The one bug that reached
  # hex — a `%Finch.Response{}` struct pattern, which made the package fail to
  # *compile* for anyone without finch — was invisible to a matrix that varied
  # only Elixir and OTP, and would have been caught here in one job.
  #
  # WITH_OPTIONAL=1 flips it to the other extreme, so both edges are covered.

  def project do
    [app: :consumer, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

  defp deps do
    [{:typedb, path: System.get_env("TYPEDB_PATH") || "../../.."}] ++ optional()
  end

  defp optional do
    if System.get_env("WITH_OPTIONAL") == "1" do
      [{:finch, "~> 0.23"}, {:req, "~> 0.7"}, {:decimal, "~> 2.4"}, {:jason, "~> 1.4"}]
    else
      []
    end
  end
end
