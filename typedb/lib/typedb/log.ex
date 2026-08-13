defmodule TypeDB.Log do
  @moduledoc false

  # Every Logger call in the driver goes through here so that `:log_level` can
  # be honoured in one place, and so that "what does this library log?" has a
  # single answer rather than one per module.

  require Logger

  alias TypeDB.Config

  # `:none` sorts above every real level, so nothing ever clears it.
  @order %{debug: 0, info: 1, warning: 2, error: 3, none: 4}

  @doc "The accepted values of the `:log_level` option, quietest last."
  @spec levels() :: [atom()]
  def levels, do: [:debug, :info, :warning, :error, :none]

  # TypeDB truncates a read at 10,000 answers unless the query asks for more,
  # and says so in a warning on the answer rather than by failing. A caller who
  # counts what came back is then quietly wrong, which is the worst way to be
  # wrong — so the driver says it out loud once, and `TypeDB.Answer.warning/1`
  # is still there for handling it properly.
  #
  # The text is not interpreted: warnings are prose, not error codes, and
  # deciding what one *means* by matching on it would break the first time the
  # server rephrased it.
  # Takes the config, not the connection. It used to take the connection and
  # look it up — and `TypeDB.Connection.config/1` *raises* when the connection is
  # gone, so a query that had already succeeded, whose answer was decoded and in
  # hand, died here instead of returning `{:ok, answer}`. Both triggers are
  # ordinary on their own: a supervisor restarting the connection mid-request,
  # and a read TypeDB truncated at 10,000 rows. Logging must not be able to
  # destroy a result, and every caller holds the config already.
  @spec answer_warning({:ok, term()} | {:error, term()}, Config.t()) ::
          {:ok, term()} | {:error, term()}
  def answer_warning({:ok, answer} = result, %Config{} = config) do
    case TypeDB.Answer.warning(answer) do
      nil ->
        result

      warning ->
        log(
          config,
          :warning,
          fn -> "TypeDB: the server attached a warning to this answer: " <> warning end,
          typedb_connection: config.name
        )

        result
    end
  end

  def answer_warning(other, %Config{}), do: other

  @spec log(Config.t(), atom(), (-> IO.chardata()) | IO.chardata(), keyword()) :: :ok
  def log(%Config{log_level: floor}, level, message, metadata) do
    if @order[level] >= @order[floor] do
      Logger.log(level, message, metadata)
    end

    :ok
  end
end
