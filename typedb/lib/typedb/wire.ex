defmodule TypeDB.Wire do
  @moduledoc false

  # Small helpers shared by the modules that build requests. Internal: nothing
  # here is part of the public API.

  @doc """
  Percent-encodes a value for use as a single path segment.

  `URI.char_unreserved?/1` rather than `URI.encode_www_form/1`: a database or
  user name containing a slash, a space or a `+` must survive the round trip
  exactly, and www-form encoding turns a space into `+`.
  """
  @spec path_segment(String.t()) :: String.t()
  def path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc """
  Returns `value` when it is a string, raising `ArgumentError` otherwise.

  A database name, a username or a query is data the caller wrote down, and the
  likeliest way for one to be wrong is to arrive from configuration as `nil` or
  as an atom. Guarding with `is_binary/1` alone answers that with
  `FunctionClauseError`, which names an internal clause and helps nobody —
  CONTRIBUTING's "Failing: return or raise" forbids it in as many words. One
  helper rather than fifteen hand-written clauses, so the message cannot drift.

  `what` names the argument as its documentation does, e.g. `"database name"`.
  """
  @spec string!(term(), String.t()) :: String.t()
  def string!(value, _what) when is_binary(value), do: value

  def string!(value, what) do
    raise ArgumentError, "invalid #{what} #{inspect(value)}, expected a string"
  end

  @doc """
  Renders a fixed UTC offset in seconds as TypeQL's `±HH:MM`.

  Raises `TypeDB.Error` with kind `:encode` for an offset TypeDB cannot write.
  Measured against TypeDB 3.12.1, whose `datetime-tz` literal takes `-23:59` to
  `+23:59` and nothing else: `+00:01:15` and `+24:00` are both syntax errors —
  see `test/integration/datetime_tz_offset_integration_test.exs`.

  Both refusals replace something worse. A sub-minute offset used to have its
  seconds dropped, which produced a literal TypeDB *accepts* and which names a
  different instant — and a time zone database hands out exactly such an offset
  for any pre-1900 timestamp, `-75` seconds for London. An out-of-range one used
  to render as `+99:59`, which came back from the server as a TypeQL syntax
  error pointing at a column number.

  One function rather than one per caller, because a rule in two places drifts:
  `TypeDB.DateTimeTZ.new/2` and `TypeDB.Given`'s `DateTime` clause had the same
  renderer written out twice, and both were wrong in the same two ways.
  """
  @spec utc_offset!(integer()) :: String.t()
  def utc_offset!(seconds) when is_integer(seconds) and rem(seconds, 60) != 0 do
    raise TypeDB.Error.new(
            :encode,
            "cannot render a UTC offset of #{seconds} seconds: TypeDB writes a fixed offset " <>
              "as ±HH:MM and rejects ±HH:MM:SS outright, so the seconds could only be dropped — " <>
              "and a dropped second is a timestamp that names a different instant, silently. " <>
              "Round the offset to a whole minute, or pass the IANA zone name instead, which " <>
              "TypeDB stores exactly."
          )
  end

  def utc_offset!(seconds) when is_integer(seconds) and abs(seconds) >= 86_400 do
    raise TypeDB.Error.new(
            :encode,
            "cannot render a UTC offset of #{seconds} seconds: TypeDB accepts -23:59 to +23:59, " <>
              "and anything outside that is a TypeQL syntax error pointing at a column number. " <>
              "Failing here says what is actually wrong."
          )
  end

  def utc_offset!(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(seconds)
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))

    sign <> pad.(div(total, 3600)) <> ":" <> pad.(div(rem(total, 3600), 60))
  end

  @doc """
  Connection-level defaults for a query's options.

  Takes the config rather than the connection, so that a caller which already
  holds one does not read the connection's table twice — and so that nothing on
  the path *after* a response has arrived has to look the connection up again.
  See `TypeDB.Log.answer_warning/2`.
  """
  @spec query_defaults(TypeDB.Config.t()) :: keyword()
  def query_defaults(%TypeDB.Config{answer_count_limit: nil}), do: []
  def query_defaults(%TypeDB.Config{answer_count_limit: limit}), do: [answer_count_limit: limit]

  @doc """
  Puts `value` under `key` unless it is `nil`.

  `false` is a value, not an absence, so this tests for `nil` rather than
  truthiness.
  """
  @spec put_unless_nil(map(), term(), term()) :: map()
  def put_unless_nil(map, _key, nil), do: map
  def put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
