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
