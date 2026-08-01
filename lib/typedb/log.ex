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

  @spec log(Config.t(), atom(), (-> IO.chardata()) | IO.chardata(), keyword()) :: :ok
  def log(%Config{log_level: floor}, level, message, metadata) do
    if @order[level] >= @order[floor] do
      Logger.log(level, message, metadata)
    end

    :ok
  end
end
