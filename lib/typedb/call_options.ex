defmodule TypeDB.CallOptions do
  @moduledoc false

  # `TypeDB.Config` rejects an option `start_link/1` has never heard of, for a
  # reason it states in a comment: `timout: 5_000` used to produce a connection
  # that looked configured and was not. Per-call options had no such check, and
  # the same mistake is worse there, because the default that gets applied is
  # sometimes the dangerous one — `commmit: false` commits, and a query whose
  # `given_rows:` was misspelled runs unparameterised.
  #
  # It raises rather than returning an error: an option name comes from the
  # caller's own source and nothing at runtime can supply a better one. Same
  # rule as an invalid `:transaction_type`. See CONTRIBUTING.md, "Failing:
  # return or raise".

  alias TypeDB.Options

  @request [:timeout, :deadline]

  @doc "Options accepted by `TypeDB.query/4`."
  def query, do: [:transaction_type, :commit, :given_rows] ++ shared()

  @doc "Options accepted by `TypeDB.Transaction.query/3`."
  def transaction_query, do: [:given_rows] ++ @request ++ Options.query_keys()

  @doc "Options accepted by `TypeDB.transaction/5` and `TypeDB.Transaction.open/4`."
  def open, do: @request ++ Options.transaction_keys()

  @doc "Options accepted by a call that only makes a request — commit, rollback, close, analyze."
  def request, do: @request

  defp shared, do: @request ++ Options.query_keys() ++ Options.transaction_keys()

  @doc """
  Returns `:ok`, or raises unless every key in `opts` is one `call` accepts.

  `call` is rendered into the message as the caller writes it, so that the line
  to fix is the one named.
  """
  @spec validate!(keyword(), [atom()], String.t()) :: :ok
  def validate!(opts, accepted, call) do
    # A keyword list is what every one of these functions documents; anything
    # else is the same class of mistake and is reported the same way rather than
    # reaching a `Keyword` function and failing inside it.
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{call} expects a keyword list of options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- accepted do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option#{if length(unknown) > 1, do: "s"} " <>
                "#{Enum.map_join(unknown, ", ", &inspect/1)} passed to #{call}. " <>
                "Accepted: #{accepted |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}."
    end
  end
end
