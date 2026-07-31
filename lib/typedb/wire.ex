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
  Puts `value` under `key` unless it is `nil`.

  `false` is a value, not an absence, so this tests for `nil` rather than
  truthiness.
  """
  @spec put_unless_nil(map(), term(), term()) :: map()
  def put_unless_nil(map, _key, nil), do: map
  def put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
