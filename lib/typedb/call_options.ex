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
        Enum.each(opts, fn {key, value} -> validate_value!(key, value, call) end)

      unknown ->
        raise ArgumentError,
              "unknown option#{if length(unknown) > 1, do: "s"} " <>
                "#{Enum.map_join(unknown, ", ", &inspect/1)} passed to #{call}. " <>
                "Accepted: #{accepted |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}."
    end
  end

  # `TypeDB.Config` has checked these values since 0.1.0 — `answer_count_limit:
  # 0` there is "invalid :answer_count_limit 0, expected a positive integer, or
  # unset". Passed per call, the same value used to travel to the server, which
  # answers `400 HSR2`: the request-parse code, the same one an oversized body
  # gets, naming no option at all. `0` was worse still, arriving as an empty
  # answer.
  #
  # Only the options whose values are constrained. `:transaction_type` is
  # checked where it is read, and `:given_rows` by `TypeDB.Given`, both with
  # better messages than a table could give.
  @values %{
    answer_count_limit: {&__MODULE__.positive_integer?/1, "a positive integer"},
    transaction_timeout_millis: {&__MODULE__.positive_integer?/1, "a positive integer in milliseconds"},
    schema_lock_acquire_timeout_millis:
      {&__MODULE__.positive_integer?/1, "a positive integer in milliseconds"},
    timeout: {&__MODULE__.timeout?/1, "a positive integer in milliseconds, or :infinity"},
    deadline: {&__MODULE__.timeout?/1, "a positive integer in milliseconds, or :infinity"},
    commit: {&is_boolean/1, "true or false"},
    include_instance_types: {&is_boolean/1, "true or false"},
    include_query_structure: {&is_boolean/1, "true or false"}
  }

  @doc false
  def positive_integer?(value), do: is_integer(value) and value > 0

  @doc false
  def timeout?(:infinity), do: true
  def timeout?(value), do: positive_integer?(value)

  # `nil` is "unset" everywhere in the driver — `TypeDB.Config` stores it for an
  # absent `:answer_count_limit`, and `Wire.put_unless_nil/3` drops it from the
  # request — so `answer_count_limit: user_supplied_limit` keeps working when
  # that limit is nil. Rejecting it here would be the two levels disagreeing
  # again, in the other direction.
  defp validate_value!(_key, nil, _call), do: :ok

  defp validate_value!(key, value, call) do
    case Map.fetch(@values, key) do
      {:ok, {valid?, expected}} ->
        unless valid?.(value) do
          raise ArgumentError,
                "invalid #{inspect(key)} #{inspect(value)} passed to #{call}, expected #{expected}"
        end

      :error ->
        :ok
    end

    :ok
  end
end
