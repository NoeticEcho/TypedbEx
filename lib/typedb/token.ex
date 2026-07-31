defmodule TypeDB.Token do
  @moduledoc """
  Reads the lifetime out of a TypeDB access token.

  TypeDB issues JWTs whose payload carries `iat` and `exp`. The driver reads
  those claims — it never verifies the signature, which is the server's business
  — so that it can renew a token *before* sending a request that would be
  rejected, instead of discovering the expiry from a `401`.

  Only the **lifetime** (`exp - iat`) is used, never the absolute times. Both
  claims come from the server's clock, so their difference is meaningful while
  comparing either against the local clock would not be.

  A token that is not a JWT, or carries no usable claims, yields
  `:unknown` — the driver then falls back to renewing reactively on `401`, which
  is always correct, just one round trip slower.
  """

  @typedoc "Token lifetime in milliseconds, or `:unknown`."
  @type lifetime :: pos_integer() | :unknown

  @doc """
  Returns the token's lifetime in milliseconds, or `:unknown`.

      iex> TypeDB.Token.lifetime_ms("not-a-jwt")
      :unknown
  """
  @spec lifetime_ms(String.t()) :: lifetime()
  def lifetime_ms(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- decode_segment(payload),
         {:ok, claims} <- TypeDB.JSON.decode(json),
         %{"iat" => issued_at, "exp" => expires_at} <- claims,
         true <- is_integer(issued_at) and is_integer(expires_at) do
      positive_lifetime((expires_at - issued_at) * 1000)
    else
      _ -> :unknown
    end
  end

  def lifetime_ms(_token), do: :unknown

  defp positive_lifetime(lifetime) when is_integer(lifetime) and lifetime > 0, do: lifetime
  defp positive_lifetime(_lifetime), do: :unknown

  @doc """
  Returns the subject (`sub`) claim, or `nil`.

  Only useful for diagnostics: it is the username the token was minted for.
  """
  @spec subject(String.t()) :: String.t() | nil
  def subject(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- decode_segment(payload),
         {:ok, %{"sub" => subject}} <- TypeDB.JSON.decode(json),
         true <- is_binary(subject) do
      subject
    else
      _ -> nil
    end
  end

  def subject(_token), do: nil

  # JWT segments are base64url without padding.
  defp decode_segment(segment) do
    padded = segment <> String.duplicate("=", rem(4 - rem(byte_size(segment), 4), 4))

    case Base.url_decode64(padded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end
end
